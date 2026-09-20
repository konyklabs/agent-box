#!/usr/bin/env python3
"""agent-box -- read a run's sensors and print them, scrubbed, inside the guest.

This runs in the guest and never on the host. That is the whole point of it:
everything here reads the model's own output, which is untrusted text, and the
one thing that must never cross to the host's terminal is a fragment of the
OAuth token. Scrubbing on the host would mean the unscrubbed bytes had already
crossed. So the boundary is here, and `agentbox logs`, `agentbox runs` and
`agentbox status` are thin wrappers that run this over `limactl shell`.

Three sensors, one merged feed:

  events.jsonl   the raw `claude -p --output-format stream-json` output
  hooks.jsonl    one object per hook event, written by guest/hook-event.sh
  console.log    what agent-run.sh itself printed, each line stamped

The transcript JSONL that Claude Code keeps under $CLAUDE_CONFIG_DIR/projects
is deliberately NOT read: it is an internal format that changes between
releases, and a log that breaks on upgrade is worse than no log.

Modes:

  run-format.py [RUNID] [-f] [--json]        one run, newest by default
  run-format.py --summary [RUNID]            that run's scrubbed summary
  run-format.py --list [--json]              every run, newest first
  run-format.py --sessions-in [--json]       format a session list from stdin
  run-format.py --channel-list [--json]      what this box said to the host
  run-format.py --channel-read ID [--json]   one of those messages, scrubbed
  run-format.py --survivors-in [--json]      format a leftovers list from stdin
  run-format.py --box-json ...               one JSON line describing this box
  run-format.py --box-text ...               the same, as one line of text
  run-format.py --box-triage --triage-facts JSON
                                             this box's triage verdict, and the
                                             watermark line the host records
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import stat
import sys
import time
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
STATE_DIR = os.environ.get("ABX_STATE_DIR", os.path.join(HOME, ".agent-box"))
RUNS_DIR = os.environ.get("ABX_RUNS_DIR", os.path.join(STATE_DIR, "runs"))
TOKEN_FILE = os.environ.get(
    "ABX_TOKEN_FILE", os.path.join(HOME, ".config", "agent-box", "token")
)
# The one mounted repository, as guest/lib.sh's ABX_WORK_DIR sees it. What is
# read from under here is the host's disk -- and, for the channel, the host's own
# words; what is written to it crosses with no second chance to redact.
WORK_DIR = os.environ.get("AGENT_BOX_WORK", "/work")

TEXT_LIMIT = 160
DETAIL_LIMIT = 120
# A path an agent chose: a worktree a run left behind, a ledger entry. Long
# enough to recognise, short enough that a hostile one cannot flood a terminal.
PATH_LIMIT = 200
# One triage reason, of at most six.
REASON_LIMIT = 120
# The channel's two sizes: the body the sanctioned writer will produce, and the
# file size above which a reader refuses a message outright rather than reading
# it. The second is not a truncation -- a file that large was not written by the
# tool, so the honest answer about it is `invalid`.
CHANNEL_BODY_LIMIT = 16384
CHANNEL_FILE_LIMIT = 65536

# A mode whose block this checkout does not carry fails loudly from its own
# stub, which prints its message and returns 1: a dispatched mode with an empty
# body that printed nothing and exited 0 would read to every caller as "there is
# nothing to report". The shell side's `die` in its stubs says the same for the
# same reason. Each message is written out inside its stub rather than shared
# from here, so the last stub to be replaced takes the last of that wording with
# it -- the finish slice greps this file for the phrase and expects none left.

# System events the CLI emits for its own bookkeeping, several per turn, that
# tell an operator nothing: token-count estimates while the model thinks,
# and the start and progress pings of its own background tasks.
NOISY_SYSTEM_SUBTYPES = frozenset({"thinking_tokens", "task_started", "task_notification"})

# Hook events that say something the stream does not. PreToolUse and
# PostToolUse are left out on purpose: the stream already carries the tool call
# and its result, and printing both makes every tool use three lines.
HOOKS_WORTH_PRINTING = ("Notification", "SubagentStart", "SubagentStop", "Stop")


# ---------------------------------------------------------------------------
# The scrub
# ---------------------------------------------------------------------------
#
# The same rule as abx_scrub_token in guest/lib.sh, in Python because this is
# the process that prints: the first and last eight characters of the token are
# enough to recognise the credential and are replaced wherever they appear.
# Neither fragment is ever printed, and a token file that is missing or
# implausibly short yields no fragments at all rather than empty ones -- an
# empty fragment would splice the replacement between every character.


def _token_fragments():
    try:
        with open(TOKEN_FILE, encoding="utf-8", errors="replace") as fh:
            tok = fh.read().strip()
    except OSError:
        return ()
    if len(tok) < 20:
        return ()
    return (tok[:8], tok[-8:])


_FRAGMENTS = _token_fragments()

# The credential's SHAPE, not this box's particular credential.
#
# The head-and-tail fragments are the right tool for the leak CHECK in
# agent-run.sh, which only has to recognise the token. They are not enough for
# a redactor: a 110-character token printed through `agentbox logs` would lose
# sixteen characters and keep ninety-four, and the prefix is public knowledge.
# So the whole match goes, and this also covers a credential that is not the
# one in this box's token file — one the model read from somewhere else, or one
# printed by `env` in a nested process.
_CREDENTIAL = re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")

# C0 controls, DEL, and the C1 range. Model output and tmux session names both
# reach the host's terminal through this file, and an escape sequence there can
# repaint the operator's screen, hide a line, or drive whatever is recording it.
_CONTROLS = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")


def scrub(value):
    """Redact credentials and strip control characters, on the way to a terminal."""
    if not isinstance(value, str):
        return value
    value = _CREDENTIAL.sub("<redacted>", value)
    for fragment in _FRAGMENTS:
        if fragment:
            value = value.replace(fragment, "<redacted>")
    return _CONTROLS.sub("", value)


def scrub_obj(obj):
    """Scrub every string in a nested structure, on the way out to the host.

    A non-finite float is `null` for the same reason a control byte is nothing.
    `json.loads` accepts `NaN`, `Infinity` and `-Infinity`, and `json.dumps`
    emits them back as bare words that no JSON reader has to accept — and the
    numbers in these documents (`cost_usd`, `turns`, `elapsed_s`) come out of
    events.jsonl, which is a file in the agent's own home. One such number would
    take the WHOLE guest half of `status --json` down to the host's fallback
    literal, because the host refuses a document it cannot recognise as JSON
    (`channel_json_shape_ok`): every sensor null and the firewall reported as
    `unknown` for a box that is running and whose mode is known. `null` is the
    contract's word for a number nobody could read, and this is one of those.
    """
    if isinstance(obj, str):
        return scrub(obj)
    if isinstance(obj, dict):
        return {k: scrub_obj(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub_obj(v) for v in obj]
    if isinstance(obj, float) and not math.isfinite(obj):
        return None
    return obj


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


def parse_ts(value):
    """ISO 8601 with or without milliseconds, Z or offset, to an aware UTC dt."""
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def first_line(value, limit):
    if value is None:
        return None
    text = str(value).replace("\r\n", "\n").replace("\r", "\n")
    line = text.split("\n", 1)[0].strip()
    if not line:
        # A first line that is blank is less useful than the first line that
        # is not, which is what a tool result with a leading newline has.
        for candidate in text.split("\n"):
            if candidate.strip():
                line = candidate.strip()
                break
    if len(line) > limit:
        line = line[: limit - 3] + "..."
    return line or None


def read_json_lines(path):
    """Yield (index, object) for each parsable line. Partial lines are skipped.

    A file being appended to while it is read can end mid-line, so a line that
    does not parse is dropped rather than being an error: on the next poll it
    will be complete.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for index, line in enumerate(fh):
                line = line.strip()
                if not line:
                    continue
                try:
                    yield index, json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def tail_lines(path, count, budget=512 * 1024):
    """The last `count` lines, reading at most `budget` bytes from the end.

    `agentbox status --watch` asks for the last tool line once every few
    seconds while the run is still writing. events.jsonl is the raw stream of a
    live run and grows without bound, so parsing it whole to find the last line
    means the monitor competes for the guest's CPU with the agent it is
    supposed to be watching.

    Opened like `read_message` and `_read_head`, for the reason given there: the
    files this reads (events.jsonl, hooks.jsonl) are in the agent's own home, a
    blocking `open()` on a FIFO planted with one of their names never returns,
    and this is on the path `agentbox status` takes for every running box.
    """
    text = ""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return []
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return []
        seeked = info.st_size > budget
        if seeked:
            os.lseek(fd, info.st_size - budget, os.SEEK_SET)
        data = b""
        while len(data) < budget:
            chunk = os.read(fd, budget - len(data))
            if not chunk:
                break
            data += chunk
        text = data.decode("utf-8", errors="replace")
        if seeked:
            # Drop the partial line the seek landed inside.
            _, _, text = text.partition("\n")
    except OSError:
        return []
    finally:
        os.close(fd)
    lines = [line for line in text.splitlines() if line.strip()]
    return lines[-count:]


def tool_input_head(name, tool_input):
    """The one field worth showing per tool. Mirrors guest/hook-event.sh."""
    if not isinstance(tool_input, dict):
        return None
    if name == "Bash":
        value = tool_input.get("command")
    elif name in ("Agent", "Task"):
        value = tool_input.get("description")
    elif name in ("Grep", "Glob"):
        value = tool_input.get("pattern")
    else:
        value = (
            tool_input.get("file_path")
            or tool_input.get("command")
            or tool_input.get("pattern")
            or tool_input.get("description")
        )
    return first_line(value, DETAIL_LIMIT)


def tool_result_text(block):
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        ]
        joined = "\n".join(p for p in parts if p)
        if joined:
            return joined
    return None


def fmt_cost(value):
    # `-` for no reading, and for a number that is not one: see fmt_duration.
    # `"$%.4f" % float("nan")` is `$nan`, which is not a cost.
    if value is None or not isinstance(value, (int, float)) or isinstance(value, bool):
        return "-"
    if isinstance(value, float) and not math.isfinite(value):
        return "-"
    return "$%.4f" % value


def fmt_duration(seconds):
    """A number of seconds as `12s` / `3m04s` / `2h05m`, or `-` for no reading.

    `-` also covers a number that is not one. Every value that reaches here came
    out of a JSON file in the agent's own home, `json.loads` accepts `NaN` and
    `Infinity`, and `int(float("inf"))` raises OverflowError — which, on the
    `--box-json` path, is an empty document and a whole box reported as
    unreachable with its firewall unknown. A run that wrote a duration nobody can
    read has no duration to show, and that is what `-` says.
    """
    if seconds is None or not isinstance(seconds, (int, float)) or isinstance(seconds, bool):
        return "-"
    if isinstance(seconds, float) and not math.isfinite(seconds):
        return "-"
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)


# ---------------------------------------------------------------------------
# A run
# ---------------------------------------------------------------------------


RUNID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}$")

# The status file is an ordinary file in the guest user's home, and the agent
# runs as that user. Its contents are input, not data: they decide what this
# program does AND they are printed to the host's terminal as the final line of
# `logs`. Anything that is not one of the five shapes below is `unknown`, and
# the bytes that were there are never returned to a caller and never printed.
STATUS_RE = re.compile(r"^(running|exit:stopped|exit:lost|exit:[0-9]+)$")


class BadRunid(ValueError):
    pass


class Run:
    """One run directory, read fresh every time it is asked a question."""

    def __init__(self, runid, root=None):
        # %Y%m%d-%H%M%S and nothing else. os.path.join with `../../.ssh` names a
        # directory outside the run tree, and the six file names this class
        # reads are one added name away from mattering.
        if not RUNID_RE.match(runid or ""):
            raise BadRunid("not a run id: %r" % (runid,))
        self.runid = runid
        self.dir = root or os.path.join(RUNS_DIR, runid)
        self._warned_status = False

    # -- the flat files ----------------------------------------------------

    @property
    def meta(self):
        try:
            with open(os.path.join(self.dir, "meta.json"), encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    @property
    def status(self):
        raw = read_text(os.path.join(self.dir, "status")).strip()
        if STATUS_RE.match(raw):
            return raw
        if raw and not self._warned_status:
            self._warned_status = True
            # The runid, never the value. Echoing it is most of what would make
            # it dangerous, and it is the thing this check exists to stop.
            print(
                "run-format: %s has a status this program does not recognise; "
                "treating it as unknown" % self.runid,
                file=sys.stderr,
            )
        return "unknown"

    @property
    def was_stopped(self):
        """Did `stop-run` interrupt this run?

        A separate file, not a status of its own, because the status has to go
        on carrying the exit code the run really finished with. Writing
        `exit:stopped` over that code lost information in every case and lost a
        guarantee in one: `exit:3` means the leak check found the token, and
        `logs` refuses to print such a run. A stop that landed on a leaking run
        used to erase the 3 and with it the refusal.
        """
        return os.path.exists(os.path.join(self.dir, "stopped"))

    @property
    def is_waiting(self):
        """Did the run stop to ask the operator something?

        A marker beside the status, like `stopped`, for the same reason: the
        status keeps the exit code. agent-run.sh writes it when the run left a
        question in /work/.agent-box/ask.md during its own lifetime, and copies
        the question to ask.md in the run directory.
        """
        return os.path.exists(os.path.join(self.dir, "waiting"))

    # running  the process is alive and the run is going
    # done     it ended on its own with exit 0
    # failed   it ended on its own with a non-zero exit
    # stopped  `agentbox stop-run` interrupted it and it ended
    # lost     it said running, and neither its tmux session nor its recorded
    #          pid was there; what happened to it is not known
    # waiting  it ended after writing a question for the operator; `agentbox
    #          resume` answers it. A stop outranks a question.
    # unknown  there is no status file to read
    @property
    def state(self):
        status = self.status
        if status == "running":
            return "running"
        if status == "exit:stopped":
            return "stopped"
        if status == "exit:lost":
            return "lost"
        if status == "exit:3":
            # A leaking run is `failed`, whether or not it was also stopped.
            # The leak is the headline and the refusal below keys off the
            # status, so nothing may reinterpret this one.
            return "failed"
        if status.startswith("exit:"):
            if self.was_stopped:
                return "stopped"
            if self.is_waiting:
                return "waiting"
            return "done" if status == "exit:0" else "failed"
        return "unknown"

    @property
    def exit_code(self):
        """The code the run exited with, or None when there is not one.

        A stopped run now HAS one, because the stop no longer overwrites it:
        it is null only when the status itself carries no number, which is
        `running`, `exit:stopped`, `exit:lost` and `unknown`.
        """
        status = self.status
        if not status.startswith("exit:"):
            return None
        tail = status[len("exit:") :]
        try:
            return int(tail)
        except ValueError:
            return None

    @property
    def started_at(self):
        return parse_ts(self.meta.get("started_at"))

    @property
    def ended_at(self):
        if self.state == "running":
            return None
        try:
            return datetime.fromtimestamp(
                os.path.getmtime(os.path.join(self.dir, "status")), timezone.utc
            )
        except OSError:
            return None

    @property
    def elapsed_s(self):
        start = self.started_at
        if not start:
            return None
        end = self.ended_at or datetime.now(timezone.utc)
        return max(0, int((end - start).total_seconds()))

    @property
    def files_changed(self):
        """Parsed back out of the scrubbed summary, which is where it is written."""
        for line in read_text(os.path.join(self.dir, "summary.txt")).splitlines():
            if line.startswith("files"):
                _, _, tail = line.partition(":")
                head = tail.strip().split(" ", 1)[0]
                try:
                    return int(head)
                except ValueError:
                    return None
        return None

    @property
    def result_event(self):
        """The `result` event, which the CLI emits last, found from the end."""
        for line in reversed(tail_lines(os.path.join(self.dir, "events.jsonl"), 200)):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict) and obj.get("type") == "result":
                return obj
        return None

    # -- the merged feed ---------------------------------------------------

    def records(self):
        """Every sensor line, merged by time, oldest first.

        Only the assistant and user events in the stream carry a timestamp of
        their own. A `system` or `result` event inherits the last one seen,
        which keeps the stream in its own order while letting hook lines and
        console lines -- both of which are stamped as they are written -- land
        between the stream events they happened between. The secondary sort key
        is (source, line number), so two things in the same second never swap
        places between one read and the next.
        """
        records = []
        anchor = self.started_at or EPOCH

        # 1. the console: what agent-run.sh printed, "<ISO> <text>" per line.
        #
        # Only lines that are terminated. A poll that catches the file mid-write
        # would otherwise print the half of the line that had arrived, record
        # its index as printed, and then never print the finished line —
        # `logs -f` dedupes on that index. A partial tail simply waits for the
        # next poll.
        console_text = read_text(os.path.join(self.dir, "console.log"))
        console_lines = console_text.splitlines()
        if console_lines and not console_text.endswith("\n"):
            console_lines.pop()
        for index, line in enumerate(console_lines):
            if not line.strip():
                continue
            stamp, _, rest = line.partition(" ")
            when = parse_ts(stamp)
            if when is None:
                when, rest = anchor, line
            # A blank line the script printed for spacing is spacing, not an
            # event, and a log full of "status" lines with nothing after them
            # is harder to read than one without them.
            if not rest.strip():
                continue
            records.append(
                {
                    "ts": when,
                    "sort": (when, 0, index),
                    "kind": "status",
                    "text": rest.rstrip(),
                    "tool": None,
                    "detail": None,
                    "id": ("console", index),
                }
            )

        # 2. the stream. Only `assistant` and `user` events carry a timestamp
        # of their own; `system` and `result` do not. Each of those inherits
        # the last one seen, and the ones BEFORE the first timestamped event
        # inherit that first one instead of the run's start time — otherwise
        # the CLI's own start-up lines sort ahead of the console lines that
        # genuinely came before them, which is the wrong story about what
        # happened in what order.
        stream = [
            (index, obj)
            for index, obj in read_json_lines(os.path.join(self.dir, "events.jsonl"))
            if isinstance(obj, dict)
        ]
        own_stamps = [parse_ts(obj.get("timestamp")) for _, obj in stream]
        carried = next((t for t in own_stamps if t), None) or anchor
        for (index, obj), own in zip(stream, own_stamps):
            if own:
                carried = own
            for sub, rec in enumerate(self._stream_records(obj)):
                rec["ts"] = carried
                rec["sort"] = (carried, 1, index * 100 + sub)
                rec["id"] = ("events", index * 100 + sub)
                records.append(rec)

        # 3. the hooks.
        for index, obj in read_json_lines(os.path.join(self.dir, "hooks.jsonl")):
            rec = self._hook_record(obj)
            if rec is None:
                continue
            when = parse_ts(obj.get("ts")) or carried
            rec["ts"] = when
            rec["sort"] = (when, 2, index)
            rec["id"] = ("hooks", index)
            records.append(rec)

        records.sort(key=lambda r: r["sort"])
        return records

    @staticmethod
    def _stream_records(obj):
        kind = obj.get("type")

        if kind == "assistant":
            message = obj.get("message") or {}
            for block in message.get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = first_line(block.get("text"), TEXT_LIMIT)
                    if text:
                        yield {
                            "kind": "text",
                            "text": text,
                            "tool": None,
                            "detail": None,
                        }
                elif block.get("type") == "tool_use":
                    name = block.get("name") or "tool"
                    yield {
                        "kind": "tool",
                        "text": name,
                        "tool": name,
                        "detail": tool_input_head(name, block.get("input")),
                    }
            return

        if kind == "user":
            message = obj.get("message") or {}
            content = message.get("content")
            if not isinstance(content, list):
                return
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    text = first_line(tool_result_text(block), TEXT_LIMIT)
                    yield {
                        "kind": "tool_result",
                        "text": text or "(no output)",
                        "tool": None,
                        "detail": "error" if block.get("is_error") else None,
                    }
            return

        if kind == "system":
            subtype = obj.get("subtype")
            if subtype == "init":
                yield {
                    "kind": "status",
                    "text": "session started, model %s, claude %s"
                    % (obj.get("model") or "?", obj.get("claude_code_version") or "?"),
                    "tool": None,
                    "detail": None,
                }
            elif subtype == "hook_started":
                # The response carries everything the start does, plus the
                # outcome. Printing both doubles every hook.
                return
            elif subtype in NOISY_SYSTEM_SUBTYPES:
                return
            elif subtype == "hook_response":
                outcome = obj.get("outcome")
                stderr = first_line(obj.get("stderr"), DETAIL_LIMIT)
                if outcome == "success" and not stderr:
                    return
                yield {
                    "kind": "hook",
                    "text": "%s %s" % (obj.get("hook_name") or "hook", outcome or "?"),
                    "tool": None,
                    "detail": stderr,
                }
            else:
                detail = first_line(
                    obj.get("message") or obj.get("error") or None, DETAIL_LIMIT
                )
                yield {
                    "kind": "status",
                    "text": str(subtype or "system"),
                    "tool": None,
                    "detail": detail,
                }
            return

        if kind == "result":
            duration = obj.get("duration_ms")
            yield {
                "kind": "result",
                "text": "%s  turns=%s  cost=%s  duration=%s  is_error=%s"
                % (
                    obj.get("subtype") or "?",
                    obj.get("num_turns"),
                    fmt_cost(obj.get("total_cost_usd")),
                    fmt_duration(duration / 1000.0 if duration else None),
                    "true" if obj.get("is_error") else "false",
                ),
                "tool": None,
                "detail": first_line(obj.get("result"), DETAIL_LIMIT),
            }
            return

    @staticmethod
    def _hook_record(obj):
        if not isinstance(obj, dict):
            return None
        event = obj.get("event")
        failed = obj.get("ok") is False
        if event not in HOOKS_WORTH_PRINTING and not failed:
            return None
        head = obj.get("input_head")
        text = str(event or "hook")
        if failed and obj.get("tool"):
            text = "%s failed: %s" % (event or "hook", obj.get("tool"))
        return {
            "kind": "hook",
            "text": text,
            "tool": obj.get("tool"),
            "detail": first_line(head, DETAIL_LIMIT),
        }

    # -- summaries ---------------------------------------------------------

    def list_row(self):
        meta = self.meta
        result = self.result_event or {}
        return {
            "runid": self.runid,
            "state": self.state,
            "exit_code": self.exit_code,
            "model": meta.get("model"),
            "branch": meta.get("branch"),
            "started_at": iso(self.started_at),
            "duration_s": self.elapsed_s,
            "turns": result.get("num_turns"),
            "cost_usd": result.get("total_cost_usd"),
            "files_changed": self.files_changed,
            # int when this run swept, null when it never did: see
            # `_run_survivors`. No column in the text table -- a count of what a
            # finished run left behind belongs where a person is asking about
            # leftovers, and `agentbox leftovers` is that place.
            "survivors": _run_survivors(self.dir),
            "heal_attempt": meta.get("heal_attempt"),
            "heal_parent": meta.get("heal_parent"),
            "resume_of": meta.get("resume_of"),
            "review_of": meta.get("review_of"),
            "review_model": meta.get("review_model"),
        }

    def tail_summary(self):
        """The last tool line and the last assistant line, from the tail only.

        Deliberately not `records()`: that reads and parses all three sensor
        files in full, which is the wrong cost for something a watch loop asks
        for every few seconds.
        """
        last_tool = None
        last_text = None
        for line in tail_lines(os.path.join(self.dir, "events.jsonl"), 200):
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if not isinstance(obj, dict):
                continue
            for rec in self._stream_records(obj):
                if rec["kind"] == "tool":
                    last_tool = rec["text"] + (
                        "  " + rec["detail"] if rec.get("detail") else ""
                    )
                elif rec["kind"] == "text":
                    last_text = rec["text"]
        return last_tool, last_text

    def status_object(self):
        meta = self.meta
        result = self.result_event or {}
        last_tool, last_text = self.tail_summary()
        return {
            "id": self.runid,
            "state": self.state,
            "exit": self.exit_code,
            "model": meta.get("model"),
            "branch": meta.get("branch"),
            "started_at": iso(self.started_at),
            "elapsed_s": self.elapsed_s,
            "turns": result.get("num_turns"),
            "cost_usd": result.get("total_cost_usd"),
            "last_tool": last_tool,
            "last_text": last_text,
        }


def all_runids():
    try:
        names = os.listdir(RUNS_DIR)
    except OSError:
        return []
    runids = [
        name
        for name in names
        if os.path.isdir(os.path.join(RUNS_DIR, name))
        and os.path.isfile(os.path.join(RUNS_DIR, name, "meta.json"))
    ]
    # The runid is %Y%m%d-%H%M%S, so a reverse string sort is newest first.
    return sorted(runids, reverse=True)


def newest_runid():
    runids = all_runids()
    return runids[0] if runids else None


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------


def emit_text(rec):
    when = rec["ts"].strftime("%H:%M:%S") if rec["ts"] else "--:--:--"
    label = {
        "text": "text",
        "tool": "tool",
        "tool_result": "out",
        "hook": "hook",
        "result": "result",
        "status": "status",
    }.get(rec["kind"], rec["kind"])
    body = rec.get("text") or ""
    if rec["kind"] == "tool" and rec.get("detail"):
        body = "%s  %s" % (rec["text"], rec["detail"])
    elif rec.get("detail") and rec["kind"] != "tool":
        body = "%s  %s" % (body, rec["detail"])
    print("%s  %-6s  %s" % (when, label, scrub(body)), flush=True)


def emit_json(rec, runid):
    print(
        json.dumps(
            scrub_obj(
                {
                    "ts": iso(rec["ts"]),
                    "run": runid,
                    "kind": rec["kind"],
                    "text": rec.get("text"),
                    "tool": rec.get("tool"),
                    "detail": rec.get("detail"),
                }
            ),
            separators=(",", ":"),
        ),
        flush=True,
    )


def emit_status_line(run, as_json):
    rec = {
        "ts": run.ended_at or datetime.now(timezone.utc),
        "kind": "status",
        "text": run.status,
        "tool": None,
        "detail": run.state,
    }
    if as_json:
        emit_json(rec, run.runid)
    else:
        emit_text(rec)


# agent-run.sh exits 3, and writes that into `status`, when its leak check
# found the OAuth token in output that reaches the host. Printing that run's
# events afterwards hands the operator the credential a second time, on the
# terminal the exit-3 path exists to protect.
LEAK_BANNER = """\
!! agent-box: this run's leak check found the OAuth token in output that
!! reaches the host, so its events are NOT being printed.
!!
!! Rotate the token now: claude.ai -> Settings -> Claude Code -> revoke it,
!! then `claude setup-token` and `agentbox token <repo>`.
!!
!! To print them anyway, knowing they may carry the credential:
!!   agentbox logs <repo> %s --force-unsafe"""


def cmd_logs(args):
    runid = args.runid or newest_runid()
    if not runid:
        print("no runs yet", file=sys.stderr)
        return 1
    run = Run(runid)
    if not os.path.isdir(run.dir):
        print("no such run: %s" % runid, file=sys.stderr)
        return 1

    printed = set()
    refused = [False]

    def flush():
        if run.status == "exit:3" and not args.force_unsafe:
            if not refused[0]:
                refused[0] = True
                print(LEAK_BANNER % runid, file=sys.stderr, flush=True)
            return
        for rec in run.records():
            if rec["id"] in printed:
                continue
            printed.add(rec["id"])
            if args.json:
                emit_json(rec, runid)
            else:
                emit_text(rec)

    if not args.follow:
        flush()
        emit_status_line(run, args.json)
        return 0

    while run.state == "running":
        flush()
        time.sleep(1.0)
    # One more pass after the status changed. The console is written through a
    # pipe, so its last lines can land a moment after the status file does.
    time.sleep(1.0)
    flush()
    emit_status_line(run, args.json)
    return 0


def cmd_summary(args):
    """summary.txt, scrubbed here rather than catted from the host mount."""
    runid = args.runid or newest_runid()
    if not runid:
        print("no runs yet", file=sys.stderr)
        return 1
    run = Run(runid)
    if not os.path.isdir(run.dir):
        print("no such run: %s" % runid, file=sys.stderr)
        return 1
    if run.status == "exit:3" and not args.force_unsafe:
        print(LEAK_BANNER % runid, file=sys.stderr, flush=True)
        return 0
    text = read_text(os.path.join(run.dir, "summary.txt"))
    if not text.strip():
        print("no summary for %s" % runid, file=sys.stderr)
        return 0
    for line in text.splitlines():
        print(scrub(line))
    return 0


def _run_or_complain(args):
    runid = args.runid or newest_runid()
    if not runid:
        print("no runs yet", file=sys.stderr)
        return None
    run = Run(runid)
    if not os.path.isdir(run.dir):
        print("no such run: %s" % runid, file=sys.stderr)
        return None
    return run


def cmd_ask(args):
    """The question a waiting run left, scrubbed. The agent wrote it."""
    run = _run_or_complain(args)
    if run is None:
        return 1
    if run.status == "exit:3" and not args.force_unsafe:
        print(LEAK_BANNER % run.runid, file=sys.stderr, flush=True)
        return 0
    text = read_text(os.path.join(run.dir, "ask.md"))
    if not text.strip():
        print("run %s left no question (state: %s)" % (run.runid, run.state), file=sys.stderr)
        return 1
    for line in text.splitlines():
        print(scrub(line))
    return 0


def cmd_last_text(args):
    """The last assistant line of a run, scrubbed: what it said before it ended."""
    run = _run_or_complain(args)
    if run is None:
        return 1
    _, last_text = run.tail_summary()
    if last_text:
        print(scrub(last_text))
    return 0


def cmd_learnings(args):
    """/work/.agent-box/learnings.md, scrubbed. Written by the runs, read by people."""
    path = os.path.join(WORK_DIR, ".agent-box", "learnings.md")
    text = read_text(path)
    if not text.strip():
        print("no learnings recorded yet (%s)" % path, file=sys.stderr)
        return 1
    for line in text.splitlines():
        print(scrub(line))
    return 0


# --- sessions --------------------------------------------------------------
#
# run-ctl.sh gathers them from tmux and builds the array with jq, so what
# arrives here is well-formed JSON with correctly escaped names. It is printed
# from here, and not from there, for the reason every other output is: the
# session name is chosen by whoever created the session, and inside a run that
# is the agent. A name is a place a whole OAuth token fits.
#
# A row also says which of the box's sessions DID THE WORK and which merely
# share its disk, which is the question a list of names cannot answer: `kind`
# and `runid` name the owner, `produced` names the branch a run left behind, and
# `state` is the row's own vocabulary. Everything here is rebuilt from validated
# parts, never copied through: the producer is trusted to be well-formed JSON
# and nothing more.

# The whole vocabulary of `kind`. An unrecognised word becomes `other`, the row
# that claims the least: neither a run's session nor one agent-box tracks.
SESSION_KINDS = frozenset({"run", "session", "other"})

# What a `session` row's state may say. A session is not a run: nothing records
# `stopped`, `waiting` or `lost` about one, so those three words are unreachable
# here and a consumer that shows them would be showing a state that cannot be.
SESSION_STATES = frozenset({"running", "ended", "unknown"})

# The status file's word, for a session. `exit:stopped` and `exit:lost` are runs'
# words and fall through to `unknown`, which is what they mean for a session.
_SESSION_EXIT_RE = re.compile(r"^exit:[0-9]+$")


def _session_age(value):
    """Seconds since the session was created, or None when nobody could tell.

    A negative age is a clock that moved, not an age: the row says it could not
    tell rather than claiming a session started in the future.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        seconds = int(value)
    except (ValueError, OverflowError):
        return None
    return seconds if seconds >= 0 else None


def _session_last_event(value):
    """The two fields the contract names, and nothing that rode along beside.

    Scrubbed BEFORE it is cut, never after: hooks.jsonl is agent-writable, and a
    credential that straddles the cut would otherwise be trimmed below the
    redactor's 20-character floor and keep its leading characters. The whole
    credential has to be there for the redactor to see it.
    """
    if not isinstance(value, dict):
        return None
    ts = value.get("ts")
    event = value.get("event")
    ts = first_line(scrub(ts), DETAIL_LIMIT) if isinstance(ts, str) else None
    event = first_line(scrub(event), DETAIL_LIMIT) if isinstance(event, str) else None
    # Two blank strings are no event at all, and they must read the same on the
    # second pass as on the first: box-status.sh pipes `sessions --json` into
    # --sessions, so every row goes through here twice per `status` refresh.
    if ts is None and event is None:
        return None
    return {"ts": ts, "event": event}


def _session_produced(kind, value):
    """What a run produced: the branch its work is on. Null for any other row.

    A run row always carries the object, with a null branch when the run has no
    branch of its own -- `{"branch": null}` and `null` are different answers, and
    the second one is reserved for "this row is not a run's".
    """
    if kind != "run":
        return None
    branch = value.get("branch") if isinstance(value, dict) else None
    if not isinstance(branch, str) or not branch:
        return {"branch": None}
    return {"branch": scrub(branch)[:PATH_LIMIT]}


def _session_state(kind, runid, raw, mapped):
    """The row's state, in the vocabulary its kind allows.

    A `run` row's state is the RUN's state, read from the run directory here and
    not taken from the guest shell's `raw_state`: the two markers that turn an
    exit code into `stopped` or `waiting` are files beside the status, and
    `Run.state` is the one place in this program that reads them. A run id that
    reached this function was matched against RUNID_RE first, so the directory it
    names is inside the run tree.

    A `session` row has only its status file, and `running` / `exit:<code>` are
    the only two words it can say about itself.
    """
    if kind == "run":
        if not runid:
            return "unknown"
        run = Run(runid)
        # A regular file, or no answer. `sessions` is the one caller that reaches
        # a run directory named by a TMUX SESSION rather than by all_runids(), so
        # the directory need not exist and nothing filtered what is in it: the
        # agent can put a FIFO or a device where the status goes, and the read
        # would then block forever, with no timeout anywhere between here and the
        # host's terminal. Nothing but a regular file is a status.
        if not os.path.isfile(os.path.join(run.dir, "status")):
            return "unknown"
        return run.state
    if kind == "session":
        if raw == "running":
            return "running"
        if _SESSION_EXIT_RE.match(raw or ""):
            return "ended"
        # No raw status in the row at all means this row has been through here
        # already: box-status.sh pipes `sessions --json` into --sessions, so the
        # mapping runs twice over the same rows and must not undo itself. The
        # type test is not decoration: `in` on a frozenset raises TypeError for
        # an unhashable value, and one list from a future producer would turn a
        # single bad row into a traceback instead of a row that says unknown.
        if raw is None and isinstance(mapped, str) and mapped in SESSION_STATES:
            return mapped
        return "unknown"
    return "unknown"


def _sessions_or_none(raw, where):
    try:
        parsed = json.loads(raw) if raw else []
    except ValueError:
        # Never an empty list. An empty list is indistinguishable from "this box
        # has no sessions", and a monitor that shows no sessions for a box that
        # has one is worse than a monitor that says it could not tell.
        print(
            "run-format: %s did not produce parsable JSON; reporting the "
            "session list as unknown" % where,
            file=sys.stderr,
        )
        return None
    return parsed if isinstance(parsed, list) else None


def _clean_sessions(sessions):
    out = []
    for item in sessions or []:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        # isinstance first: `in` on a frozenset hashes its argument, and a list
        # or an object here would raise TypeError and lose the whole list --
        # every key of the box's status object with it, on the --box-json path.
        if not isinstance(kind, str) or kind not in SESSION_KINDS:
            kind = "other"
        runid = item.get("runid")
        if not (isinstance(runid, str) and RUNID_RE.match(runid)):
            runid = None
        raw = item.get("raw_state")
        if not isinstance(raw, str):
            raw = None
        # The seven keys of the contract, in its order, and nothing else. The row
        # is rebuilt rather than copied so that `raw_state` stops here -- it is
        # the shell's working note, not an answer -- and so that a key nobody
        # validated cannot ride along to a consumer as if it had been.
        out.append(
            scrub_obj(
                {
                    "name": scrub(str(item.get("name", "")))[:80],
                    "kind": kind,
                    "runid": runid,
                    "state": _session_state(kind, runid, raw, item.get("state")),
                    "age_s": _session_age(item.get("age_s")),
                    "last_event": _session_last_event(item.get("last_event")),
                    "produced": _session_produced(kind, item.get("produced")),
                }
            )
        )
    return out


def cmd_sessions(args):
    raw = sys.stdin.read()
    sessions = _sessions_or_none(raw, "run-ctl.sh sessions")
    if sessions is None:
        return 1
    sessions = _clean_sessions(sessions)
    if args.json:
        print(json.dumps(sessions, separators=(",", ":")))
        return 0
    if not sessions:
        print("no tmux sessions")
        return 0
    # KIND and STATE before AGE, because "which of these is a run and how did it
    # end" is the question this table is read for. The run id and the branch are
    # in --json: a name and a kind are what fit a terminal line.
    print("%-24s  %-7s  %-8s  %-10s  %s" % ("SESSION", "KIND", "STATE", "AGE", "LAST EVENT"))
    for item in sessions:
        event = item.get("last_event") or {}
        if isinstance(event, dict) and event.get("event"):
            shown = "%s %s" % (event.get("ts") or "?", event.get("event"))
        else:
            shown = "-"
        age = item.get("age_s")
        print(
            "%-24s  %-7s  %-8s  %-10s  %s"
            % (
                item.get("name", "?"),
                item.get("kind") or "?",
                item.get("state") or "?",
                "%ss" % age if age is not None else "-",
                shown,
            )
        )
    return 0


# --- leftovers -------------------------------------------------------------
#
# What earlier runs left running, read from the resource ledger a run keeps in
# the guest home. Two shapes come out of the same rows, so that `agentbox
# leftovers` and the `leftovers` object of `status --json` can never disagree
# about what is still up: the rows themselves (`cmd_survivors`) and the folded
# summary a monitor renders a column from (`_fold_leftovers`).
#
# Every row is untrusted text. `value` is a path or a name the agent chose and
# `detail` is a command line it chose, so the ledger is exactly the file an
# agent would write a credential into on purpose. Nothing here is executed,
# nothing is compared arithmetically, and every field is scrubbed and capped
# before it is printed.

# The scan in the guest stops at this many rows and says so on its own stderr.
# No field in a row carries that fact, so the reader infers it from the count:
# a list that came back at the cap is treated as possibly incomplete, which is
# what `truncated` says. The cap lives in two places -- here and in the guest's
# ledger reader -- and changing one means changing both.
LEFTOVERS_SCAN_LIMIT = 200

# What one row's identity may be, per class. A port is `tcp:65535`, a pid is
# digits, a tmux name is capped where a session name is capped, and a worktree
# is a path the agent chose. An unrecognised class is capped like a path rather
# than dropped: the ledger's `kind` domain is deliberately open, so a later
# version adding one must not make this reader silently lose its rows.
LEFTOVER_VALUE_LIMITS = {"proc": 12, "port": 12, "tmux": 80, "worktree": PATH_LIMIT}
LEFTOVER_KIND_LIMIT = 16

# The folded summary's per-class caps: (key, kind, how many). A person acting on
# this needs to know there are leftovers and of what kind; the full list is one
# `agentbox leftovers` away and is where completeness belongs.
LEFTOVERS_FOLD_CAPS = (("ports", "port", 20), ("worktrees", "worktree", 10), ("tmux", "tmux", 10))
LEFTOVERS_RUNS_CAP = 10

# How many ledger lines one run's survivor count reads. The sampler appends only
# pairs it has not recorded yet, so a real ledger is tens of lines; this is the
# bound that keeps `runs --json` cheap when one is not real.
LEDGER_LINE_LIMIT = 4000


def _leftovers_or_none(raw, where):
    """The leftovers rows, or None when nobody could answer.

    Unlike `_sessions_or_none`, an EMPTY string is None and not an empty list.
    box-status.sh passes the empty string through on purpose when the ledger
    reader is missing or failed, and "this box has nothing left running" and
    "nobody could tell" are different answers: the second one must not render
    as a clean box.
    """
    if not raw or not raw.strip():
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        parsed = None
    if not isinstance(parsed, list):
        print(
            "run-format: %s did not produce a parsable JSON array; reporting "
            "the leftovers as unknown" % where,
            file=sys.stderr,
        )
        return None
    return parsed


def _clean_leftovers(rows):
    """One row per (kind, value), scrubbed, capped, and shape-checked.

    Five keys, always present, `runid`/`detail`/`since` nullable. `runid: null`
    means present but recorded by no run.

    The rows carry no phase to order duplicates by, so the first of a pair wins
    and the guest's own order is kept. The runid survives only if it is a runid:
    a row the box cannot attribute reads as unattributed rather than carrying
    invented bytes on towards `agentbox logs`. `since` is re-rendered from a
    parsed timestamp rather than passed through, which is the same discipline
    `abx_status_read` applies to a status file -- an unrecognised value is not
    echoed back, it is absent.

    Every displayed field goes through `first_line`, `kind` and `value`
    included. `scrub` strips control characters but keeps `\\n` on purpose (a
    newline is not a terminal escape), and a path or a session name the agent
    chose may legally contain one -- so without this a single row could print a
    second line of its own at column 0 in the five-column table, reading as
    `no leftovers`, as another row, or as a line from `agentbox` itself.
    Two values that differ only past their first line therefore fold into one
    row, which is the right side to err on: the row still names the leftover,
    and the sweep acts on the guest's own ledger, never on this display.
    """
    out = []
    seen = set()
    for item in rows or []:
        if not isinstance(item, dict):
            continue
        kind = first_line(scrub(str(item.get("kind") or "")), LEFTOVER_KIND_LIMIT)
        value = first_line(
            scrub(str(item.get("value") or "")),
            LEFTOVER_VALUE_LIMITS.get(kind, PATH_LIMIT),
        )
        # A row without a class or an identity names nothing that could be
        # looked at, and it is the identity that is the deduplication key.
        if not kind or not value:
            continue
        if (kind, value) in seen:
            continue
        seen.add((kind, value))
        runid = item.get("runid")
        detail = item.get("detail")
        out.append(
            {
                "runid": runid if isinstance(runid, str) and RUNID_RE.match(runid) else None,
                "kind": kind,
                "value": value,
                "detail": first_line(scrub(detail), DETAIL_LIMIT) if isinstance(detail, str) else None,
                "since": iso(parse_ts(item.get("since"))),
            }
        )
        if len(out) >= LEFTOVERS_SCAN_LIMIT:
            break
    return out


def _fold_leftovers(rows):
    """The `leftovers` object of `status --json`, or None.

    Built here and nowhere else, so the status object and `agentbox leftovers`
    read the same rows the same way. The status slice's one call site is
    `_fold_leftovers(_leftovers_or_none(args.leftovers, "the leftovers scan"))`:
    both halves are null-safe, so there is nothing to branch on there.

    Every key is ALWAYS present, because a
    consumer renders a column from this and must not have to branch on a missing
    one; a clean box is zeros and empty lists. The whole object is `null` -- not
    zeros -- when the scan could not run, which is the `sessions` rule: unknown
    beats a guess.
    """
    if rows is None:
        return None
    folded = {
        "procs": 0,
        "ports": [],
        "worktrees": [],
        "tmux": [],
        "runs": [],
        # Of the rows as they arrived, before the pairs were folded: the cap was
        # reached in the guest, and a fold cannot un-reach it.
        "truncated": len(rows) >= LEFTOVERS_SCAN_LIMIT,
    }
    for row in _clean_leftovers(rows):
        kind = row["kind"]
        if kind == "proc":
            # An integer, uncapped: it is a count and not a list, so a big one
            # costs a reader nothing and is the honest number.
            folded["procs"] += 1
        for key, want, cap in LEFTOVERS_FOLD_CAPS:
            if kind == want and len(folded[key]) < cap:
                folded[key].append(row["value"])
        runid = row["runid"]
        if runid and runid not in folded["runs"] and len(folded["runs"]) < LEFTOVERS_RUNS_CAP:
            folded["runs"].append(runid)
    return folded


def _run_survivors(run_dir):
    """How many resources this run left behind, or None if it never swept.

    Distinct (kind, value) pairs whose last recorded phase is `survived`,
    counted only when the ledger carries the sweep's closing `swept` line. A run
    with no such line was hard-killed or predates the ledger, and 0 there would
    be a claim -- "it left nothing running" -- that nothing checked.

    `baseline` lines are read and ignored, like every reader ignores them: the
    writer has already subtracted the baseline from what it records as observed,
    and a reader that subtracted it again is a second copy of that rule to drift
    away from the first.
    """
    swept = False
    phases = {}
    for count, (_index, obj) in enumerate(read_json_lines(os.path.join(run_dir, "owned.jsonl"))):
        if count >= LEDGER_LINE_LIMIT:
            break
        if not isinstance(obj, dict):
            continue
        phase = obj.get("phase")
        if phase == "swept":
            swept = True
            continue
        kind, value = obj.get("kind"), obj.get("value")
        if not isinstance(phase, str) or not isinstance(kind, str) or not isinstance(value, str):
            continue
        phases[(kind, value)] = phase
    if not swept:
        return None
    return sum(1 for phase in phases.values() if phase == "survived")


def cmd_survivors(args):
    """The rows of what earlier runs left running. Reports; never cleans."""
    raw = sys.stdin.read()
    rows = _leftovers_or_none(raw, "run-ledger.sh survivors")
    if rows is None:
        return 1
    rows = _clean_leftovers(rows)
    if args.json:
        print(json.dumps(rows, separators=(",", ":")))
        return 0
    if not rows:
        print("no leftovers")
        return 0
    print("%-15s  %-8s  %-22s  %-20s  %s" % ("RUN", "KIND", "VALUE", "SINCE", "DETAIL"))
    for row in rows:
        print(
            "%-15s  %-8s  %-22s  %-20s  %s"
            % (
                row["runid"] or "-",
                row["kind"],
                row["value"],
                row["since"] or "-",
                row["detail"] or "-",
            )
        )
    return 0


LIST_COLUMNS = (
    ("runid", "RUNID", 15),
    ("state", "STATE", 8),
    ("exit_code", "EXIT", 4),
    ("model", "MODEL", 8),
    ("branch", "BRANCH", 30),
    ("started_at", "STARTED", 20),
    ("duration_s", "DUR", 7),
    ("turns", "TURNS", 5),
    ("cost_usd", "COST", 9),
    ("files_changed", "FILES", 5),
)


def cmd_list(args):
    rows = [Run(runid).list_row() for runid in all_runids()]
    if args.json:
        print(json.dumps(scrub_obj(rows), separators=(",", ":")))
        return 0
    if not rows:
        print("no runs yet")
        return 0
    header = "  ".join("%-*s" % (width, title) for _, title, width in LIST_COLUMNS)
    print(header)
    for row in rows:
        cells = []
        for key, _, width in LIST_COLUMNS:
            value = row.get(key)
            if key == "duration_s":
                shown = fmt_duration(value)
            elif key == "cost_usd":
                shown = fmt_cost(value)
            elif value is None:
                shown = "-"
            else:
                shown = str(value)
            cells.append("%-*s" % (width, scrub(shown)))
        print("  ".join(cells).rstrip())
    return 0


# --- the channel -----------------------------------------------------------
#
# The two read paths for messages on the mount. Reading is done here, in Python,
# rather than in the shell, for the reason every other read is: a message in
# `to-host/` was written by the model, and one in `to-box/` arrives on a mount
# whose contents the host controls -- both are untrusted bytes that must be
# shape-checked and scrubbed before anything prints them. `read_message`,
# `cmd_channel_list` and `cmd_channel_read` belong to the channel slice; the
# skeleton owns the caps above, the names, and the dispatch.
#
# Both modes read the `to-host` direction: the host asks this program what the
# box said, because the box's bytes must be scrubbed before they cross. The
# guest's own inbox (`to-box`, which the host wrote) is read by guest/channel.sh
# in shell, so that the delivery hook depends on nothing but bash -- the
# direction parameter below is what keeps that asymmetry visible rather than
# built into the path.

# The same shape as abx_valid_msgid in guest/lib.sh and valid_msgid in
# bin/agentbox: the writer's UTC second plus a two-digit sequence. Three
# implementations because the id is a file name on a mount either side may have
# written, and each side checks it before it becomes a path.
MSGID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[0-9]{2}$")

CHANNEL_DIR = os.path.join(WORK_DIR, ".agent-box", "channel")

# One header line of the message format: a short lower-case key, a colon, a
# space, and at most 200 characters that do not include a newline.
_HEADER_LINE_RE = re.compile(r"^([a-z]{2,12}): (.{0,200})$")
# The header block's own bounds. A file whose first 12 lines or 2048 bytes do
# not reach a blank line is not carrying headers this reader will find, which is
# the honest answer for something the sanctioned writer did not produce.
CHANNEL_HEADER_LINES = 12
CHANNEL_HEADER_BYTES = 2048
# What a listing shows, newest first. The host counts up to 1000 names itself;
# this is how many of them are opened and rendered.
CHANNEL_LIST_LIMIT = 50
CHANNEL_SUBJECT_LIMIT = 120

_ISO_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
_TYPE_RE = re.compile(r"^(handoff|question|note|request)$")
# `claude` is the standing session, `run-<runid>` a headless run, `shell`
# anything else in the box. Nothing else can be written by the sanctioned path:
# claude-session.sh exports the name only for the standing session.
_SESSION_RE = re.compile(r"^(claude|shell|run-[0-9]{8}-[0-9]{6})$")
_COMMIT_RE = re.compile(r"^([0-9a-f]{40}|[0-9a-f]{64})$")
_DIRTY_RE = re.compile(r"^[0-9]{1,6}$")
_VERDICT_RE = re.compile(r"^(accepted|changes)$")
_BRANCH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$")


def _valid_branch(value):
    """git's refusals, as far as this reader needs them.

    The same shape as abx_valid_branch in guest/lib.sh. It matters here because
    the host hands a branch name from a message to `git rev-parse`: a value that
    fails this reads as null, and a null branch is what makes the host say the
    message names no usable branch instead of running git on the box's bytes.
    """
    if not _BRANCH_RE.match(value or ""):
        return False
    return not (
        ".." in value or "//" in value or value.endswith("/") or value.endswith(".lock")
    )


def _valid_subject(value):
    return bool(value) and len(value) <= CHANNEL_SUBJECT_LIMIT


# key -> the test its value must pass. A known key whose value fails reads as
# null and is named in the row's `invalid` list: never silently dropped, and
# never echoed. An unknown key is dropped without comment -- the format is
# allowed to grow on the other side of the mount without this reader failing.
_HEADER_RULES = (
    ("created", lambda v: bool(_ISO_RE.match(v))),
    ("type", lambda v: bool(_TYPE_RE.match(v))),
    ("session", lambda v: bool(_SESSION_RE.match(v))),
    ("branch", _valid_branch),
    ("commit", lambda v: bool(_COMMIT_RE.match(v))),
    ("dirty", lambda v: bool(_DIRTY_RE.match(v))),
    ("re", lambda v: bool(MSGID_RE.match(v))),
    ("verdict", lambda v: bool(_VERDICT_RE.match(v))),
    ("subject", _valid_subject),
)
_HEADER_KEYS = tuple(key for key, _ in _HEADER_RULES)
_HEADER_RULE_MAP = dict(_HEADER_RULES)

# The row's key order is the contract's (docs/daily-use.md, the `untrusted`
# object): id first, then the headers, then the two facts this reader adds.
_ROW_KEYS = ("id",) + _HEADER_KEYS + ("bytes", "invalid")


def _empty_row(msgid):
    row = {key: None for key in _ROW_KEYS}
    row["id"] = msgid
    row["invalid"] = []
    row["body"] = ""
    row["truncated"] = False
    return row


def _unreadable_row(msgid, reason):
    """A file that is not a message, as a row that says so and shows nothing.

    The reason travels inside `invalid` rather than in a key of its own, so the
    row keys stay exactly the ones the contract lists. It is one of five fixed
    strings written here, never anything read from the file.
    """
    row = _empty_row(msgid)
    row["invalid"] = ["file:%s" % reason]
    return row


def _parse_headers(head, row):
    """Fill `row` from the header block. False when this is not one.

    First occurrence wins, unknown keys are dropped, and the block is bounded
    both ways: a file that arrives with 4000 bytes of `a: b` lines gets the
    first 12 of them read and the rest ignored.
    """
    seen = set()
    total = 0
    parsed = 0
    for index, line in enumerate(head.split("\n")):
        if index >= CHANNEL_HEADER_LINES:
            break
        total += len(line.encode("utf-8", errors="replace")) + 1
        if total > CHANNEL_HEADER_BYTES:
            break
        match = _HEADER_LINE_RE.match(line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        if key in seen:
            continue
        seen.add(key)
        if key not in _HEADER_KEYS:
            continue
        parsed += 1
        if _HEADER_RULE_MAP[key](value):
            row[key] = int(value) if key == "dirty" else value
        elif key not in row["invalid"]:
            row["invalid"].append(key)
    # `type` is structural, not decoration: without it nobody can say what the
    # file is, and a reader that printed its body anyway would be printing bytes
    # nothing vouches for. A bad `branch` is the other case -- the message is
    # real and one of its claims is not, which is what `invalid` is for.
    return parsed > 0 and row["type"] is not None


def read_message(direction, msgid, body_limit=CHANNEL_BODY_LIMIT):
    """One message file, read the only way a file on this mount may be read.

    `O_NOFOLLOW`, so a symlink named like a message cannot make this open the
    token file; `O_NONBLOCK`, so a FIFO with a message's name answers at once
    instead of hanging the reader, and `fstat` then refuses it for not being a
    regular file; one bounded read, so a file too large to be a message is
    recognised rather than read whole.

    Always returns a row. A file that cannot be read is a row whose `invalid`
    says which of five fixed things went wrong and whose every content field is
    null: no byte of such a file reaches the caller.
    """
    row = _empty_row(msgid)
    if not MSGID_RE.match(msgid or ""):
        # The id is not echoed: it arrived as an argument, and an argument that
        # failed its shape is exactly the text not to put back on a terminal.
        return _unreadable_row("", "not a message id")
    if direction not in ("to-host", "to-box"):
        return _unreadable_row(msgid, "not a direction")
    path = os.path.join(CHANNEL_DIR, direction, msgid + ".md")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return _unreadable_row(msgid, "no such message")
    except OSError:
        # ELOOP for a symlink under O_NOFOLLOW, ENXIO or EISDIR for the rest.
        # `islink` only words the answer; the refusal already happened, and it
        # happened without following anything.
        return _unreadable_row(
            msgid, "not a regular file" if os.path.islink(path) else "unreadable"
        )
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return _unreadable_row(msgid, "not a regular file")
        if info.st_size > CHANNEL_FILE_LIMIT:
            return _unreadable_row(msgid, "too large")
        if info.st_size == 0:
            # A reservation whose content never arrived, or a crash mid-send.
            # Its writer sweeps it; a reader treats it as nothing.
            return _unreadable_row(msgid, "empty")
        data = b""
        while len(data) < info.st_size:
            chunk = os.read(fd, info.st_size - len(data))
            if not chunk:
                break
            data += chunk
    except OSError:
        return _unreadable_row(msgid, "unreadable")
    finally:
        os.close(fd)

    row["bytes"] = info.st_size
    text = data.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")
    head, _, body = text.partition("\n\n")
    if not _parse_headers(head, row):
        return _unreadable_row(msgid, "bad header")
    # The body's cap is in bytes, so it is cut in bytes and decoded afterwards:
    # cutting the string would count a multibyte character as one.
    body_bytes = body.encode("utf-8", errors="replace")
    row["truncated"] = len(body_bytes) > body_limit
    row["body"] = body_bytes[:body_limit].decode("utf-8", errors="replace")
    return row


def _message_row(row):
    """The row as the contract lists it: no body, no truncation flag."""
    return {key: row[key] for key in _ROW_KEYS}


def _standing_or_none():
    """The standing session's object, once the status slice builds it.

    `standing_object()` belongs to that slice, because it is the same object
    `status --json` carries and two producers would eventually disagree about
    it. Until it lands the channel listing says `null`, which is the contract's
    word for "nobody could answer" -- not a second, differently shaped copy.
    Contract for the status slice: `standing_object()`, no arguments, a dict
    with the keys of spec 2.1 or None.
    """
    builder = globals().get("standing_object")
    return builder() if builder is not None else None


def _standing_line(standing):
    """The standing object as the one line the text listing carries.

    The host prints it behind its bar, so it holds what the operator needs to
    see without a JSON parser: who, what state, since when, the declared task,
    the last tool and the last thing the session said.
    """
    if not isinstance(standing, dict):
        return "none"
    parts = [
        str(standing.get("name") or "claude"),
        str(standing.get("state") or "unknown"),
    ]
    if standing.get("since"):
        parts.append("since %s" % standing["since"])
    for label, key, limit in (
        ("task:", "task", 200),
        ("last:", "last_tool", DETAIL_LIMIT),
        ("said:", "last_text", TEXT_LIMIT),
    ):
        value = first_line(standing.get(key), limit)
        if value:
            parts.append("%s %s" % (label, value))
    return scrub(" ".join(parts))


def _channel_names(direction):
    """Message ids in one direction, newest first. Names only.

    The same rule as the host's `channel_ids`: a name that is not
    `<id>.md` is not a message, a symlink with that name is not a message, and a
    zero-byte file is a reservation in flight. None of the rejects is echoed --
    the caller is told nothing about them, because a name is guest-chosen text.
    """
    out = []
    try:
        entries = os.scandir(os.path.join(CHANNEL_DIR, direction))
    except OSError:
        return out
    with entries:
        for entry in entries:
            name = entry.name
            if not name.endswith(".md") or not MSGID_RE.match(name[:-3]):
                continue
            try:
                if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                    continue
                if entry.stat(follow_symlinks=False).st_size == 0:
                    continue
            except OSError:
                continue
            out.append(name[:-3])
    out.sort(reverse=True)
    return out


def cmd_channel_list(args):
    """What this box has said to the host, and how the standing session is.

    The `to-host` direction only: this is the host's view of the box. The box's
    own inbox is `abx inbox`, which reads `to-box` in shell.
    """
    rows = [
        read_message("to-host", msgid)
        for msgid in _channel_names("to-host")[:CHANNEL_LIST_LIMIT]
    ]
    standing = _standing_or_none()
    if args.json:
        obj = {
            "standing": scrub_obj(standing),
            "messages": [scrub_obj(_message_row(row)) for row in rows],
        }
        print(json.dumps(obj, separators=(",", ":")))
        return 0
    print("STANDING %s" % _standing_line(standing))
    for row in rows:
        if row["invalid"] and row["invalid"][0].startswith("file:"):
            # The id, the word, and one of this file's own five reasons. The
            # message is listed rather than dropped, and nothing of it printed.
            print("%s invalid - - %s" % (row["id"], row["invalid"][0][len("file:"):]))
            continue
        print(
            "%s %s %s %s %s"
            % (
                row["id"],
                scrub(row["type"] or "-"),
                scrub(row["session"] or "-"),
                scrub(row["branch"] or "-"),
                scrub(first_line(row["subject"], CHANNEL_SUBJECT_LIMIT) or "-"),
            )
        )
    return 0


def _leaking_sender(row):
    """The runid of a leak-flagged sender, or None.

    A run whose leak check found the token wrote its handoff before the check
    ran. Printing it hands the operator the credential on the terminal the
    exit-3 path exists to protect, so it is refused the way `logs` and `ask`
    refuse that run's other output.
    """
    session = row.get("session") or ""
    if not session.startswith("run-"):
        return None
    runid = session[len("run-"):]
    try:
        run = Run(runid)
    except BadRunid:
        return None
    return runid if run.status == "exit:3" else None


def cmd_channel_read(args):
    """One message from the box, as a parseable line and then its body.

    Line 1 is `META key=value ...`, the `read_live_egress` shape: the host picks
    the values out with `sed` and validates each one, so a value it does not
    recognise is dropped rather than printed. Every line after it is body, which
    the host prints behind its bar.
    """
    row = read_message("to-host", args.channel_read or "")
    if row["invalid"] and row["invalid"][0].startswith("file:"):
        print("invalid: %s" % row["invalid"][0][len("file:"):])
        return 1
    runid = _leaking_sender(row)
    if runid and not args.force_unsafe:
        print(LEAK_BANNER % runid, file=sys.stderr, flush=True)
        print("invalid: the sending run's leak check found the token")
        return 1
    if args.json:
        obj = _message_row(row)
        obj["body"] = row["body"]
        obj["truncated"] = row["truncated"]
        print(json.dumps(scrub_obj(obj), separators=(",", ":")))
        return 0
    print(
        "META type=%s session=%s branch=%s commit=%s dirty=%s created=%s bytes=%d truncated=%d"
        % (
            scrub(row["type"] or "-"),
            scrub(row["session"] or "-"),
            scrub(row["branch"] or "-"),
            scrub(row["commit"] or "-"),
            "-" if row["dirty"] is None else row["dirty"],
            scrub(row["created"] or "-"),
            row["bytes"] or 0,
            1 if row["truncated"] else 0,
        )
    )
    print("")
    for line in row["body"].split("\n"):
        print(scrub(line))
    return 0


# ---------------------------------------------------------------------------
# The box's own status object
# ---------------------------------------------------------------------------
#
# `--box-json` is the one document four separate sensors meet in, and it is the
# only one a host consumer (`agentbox status --json`, porthole) is allowed to
# read: the standing session's private state, the toolchain snapshot root wrote
# at boot, the resource ledger a finished run left, and the tmux session list.
# Every one of them is a file in the guest, which means every one of them is
# either a file the agent can write or a file that may simply be absent — so the
# rule for all four is the one `_sessions_or_none` already states: a shape that
# does not validate is `null`, which means "nobody could answer", and is never
# the same answer as zero.
#
# The keys and their domains are the contract; a consumer branches on values,
# never on a key being there. That is why nothing below is omitted on a box
# where the thing it describes does not exist.

# The standing interactive session: one per box, named once here.
STANDING_SESSION = "claude"
SESSIONS_DIR = os.environ.get("ABX_SESSIONS_DIR", os.path.join(STATE_DIR, "sessions"))

# Where liveness is read from. A path rather than a literal for the reason
# run-ledger.sh gives for its own (`run-ledger.sh:267`): the same code is then
# exercisable on a machine that has no /proc at all, which is where the host-side
# checks for this file run. Nothing an agent can reach decides this — the host
# invokes box-status.sh through `limactl shell` with an environment of its own.
PROC_DIR = os.environ.get("ABX_PROC_DIR", "/proc")

# A hook event name, as guest/channel.sh's sed accepts one. The last event is
# what the state word is derived from, so a name that is not a name is no name.
HOOK_EVENT_RE = re.compile(r"^[A-Za-z]{1,40}$")

# How much of the session's sensor log the state word costs: the last lines of
# one bounded read (`tail_lines` reads at most 512 KiB from the end). `status
# --watch` asks for this every few seconds while the session is working, and the
# log grows for as long as the session lives.
STANDING_TAIL_LINES = 40
# The task line, the same cap channel.sh writes it with (CH_TASK_LIMIT).
STANDING_TASK_LIMIT = 200
# A tool name, before its input head is appended.
STANDING_TOOL_LIMIT = 40

# The `runs-seen` set: one run id per line, written by the delivery hook. Read
# bounded, because it is a file in the agent's own home; 2000 ids is more runs
# than a box will ever hold and 16 bytes is one id and its newline.
RUNS_SEEN_LIMIT = 2000
# How many run directories the unseen count looks at, newest first. The notice
# the count exists for announces at most five runs, and `status --watch` pays
# for this on every tick.
RUNS_UNSEEN_SCAN_LIMIT = 200

# The snapshot's state word, as `status --json` may carry it: spec 2.1 and
# amendment A10, which porthole matches exactly. guest/toolcheck.sh's own
# `--box-only` snapshot writes one of these three and nothing else
# (`toolcheck.sh:snapshot_box` validates the same set on the way back in);
# `project_mismatch`, the fourth word of toolchain.md 1.1, belongs to a scan
# that reads the repository and is never in a box-only snapshot. A snapshot
# carrying anything else failed its shape, and a failed shape is `null`.
TOOLCHAIN_STATES = frozenset({"ok", "findings", "unknown"})


def _read_head(path, limit):
    """The first `limit` bytes of a file the standing session writes, or "".

    Bounded, unlike `read_text`, because these are read on every `status --watch`
    tick and they are the agent's own files: a task line it decided to make a
    megabyte long would otherwise be read in full, in the guest, several times a
    minute. Nothing longer than one short line survives the caps below anyway.

    Opened the way `read_message` opens a file on the mount, and for the same
    reason: every path this reads is in the agent's own home, so
    `mkfifo ~/.agent-box/sessions/claude/task` is one command away and a plain
    blocking `open()` on a FIFO never returns. The host runs this once per
    running box, inside `agentbox status`, with no timeout around the call — so
    one box's FIFO would hang the whole fleet listing, and `status --watch` and
    porthole's poll with it. `O_NONBLOCK` makes the open answer at once, `fstat`
    then refuses anything that is not a regular file, and `O_NOFOLLOW` refuses a
    symlink aimed at the token file.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return ""
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return ""
        data = b""
        while len(data) < limit:
            chunk = os.read(fd, limit - len(data))
            if not chunk:
                break
            data += chunk
    except OSError:
        return ""
    finally:
        os.close(fd)
    return data.decode("utf-8", errors="replace")


def _mtime_iso(path):
    """A file's mtime as an ISO timestamp, or None."""
    try:
        return iso(datetime.fromtimestamp(os.path.getmtime(path), timezone.utc))
    except OSError:
        return None


def _standing_pid(session_dir):
    """The pid the session recorded, digits only, or None."""
    line = _read_head(os.path.join(session_dir, "pid"), 64).split("\n", 1)[0].strip()
    return line if line.isdigit() else None


def _standing_alive(pid):
    """Is that pid this box's standing session?

    Both halves are needed, and this is `abx_session_alive` (guest/lib.sh) in
    Python: the pid file survives a hard VM stop, and after the reboot that
    number belongs to somebody else. A pid that is alive but is not a
    claude-session.sh reads as dead, which is the truth about the session.
    """
    if not pid:
        return False
    raw = _read_head(os.path.join(PROC_DIR, pid, "cmdline"), 4096)
    return "claude-session.sh" in raw.replace("\x00", " ")


def _standing_tail(session_dir):
    """(last event name, its timestamp, last tool line) from the session's log.

    guest/hook-event.sh writes one object per line: `ts`, `event`, `tool`,
    `input_head`. The event name decides the state word, so it is matched
    against a name's shape before it is believed; the tool line is display text
    and is scrubbed and capped like a run's.

    All three come from the log's TAIL, which is what bounds the cost of a
    display a watch loop redraws: a session whose last tool call is further back
    than that reports no last tool rather than paying for the whole log.
    """
    event = None
    when = None
    tool = None
    for line in tail_lines(os.path.join(session_dir, "hooks.jsonl"), STANDING_TAIL_LINES):
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        stamp = parse_ts(obj.get("ts"))
        if stamp:
            when = stamp
        name = obj.get("event")
        if isinstance(name, str) and HOOK_EVENT_RE.match(name):
            event = name
        called = obj.get("tool")
        if isinstance(called, str) and called.strip():
            text = first_line(scrub(called), STANDING_TOOL_LIMIT)
            head = obj.get("input_head")
            if text and isinstance(head, str) and head.strip():
                text = "%s  %s" % (text, first_line(scrub(head), DETAIL_LIMIT))
            tool = first_line(text, DETAIL_LIMIT)
    return event, when, tool


def _standing_state(alive, event):
    """`working`, `idle`, `waiting` or `gone`.

    The same four words `guest/channel.sh:standing_state` prints for the host's
    `request`, derived the same way from the same two facts, because a box that
    told `request` one thing and `status` another about the same session would
    make both unusable. Its known limit is this one's: the sensor logs `Stop`
    when a turn ends even if a hook then keeps the session going, so this can
    read `idle` for a moment while the session is in fact working. It corrects
    itself at the next event and nothing irreversible is decided on the word.
    """
    if not alive:
        return "gone"
    if event == "Notification":
        return "waiting"
    if event in ("Stop", None):
        return "idle"
    return "working"


def _runs_unseen(session_dir):
    """Ended runs this session has not been told about yet.

    A SET, not a watermark: `runs-seen` holds every id already announced, so a
    long run that ends after a newer short one is still counted. `running` and
    `unknown` are not ended and are not counted -- the second one especially,
    since it is what a run with a status file nobody can parse reads as.
    """
    seen = set()
    raw = _read_head(os.path.join(session_dir, "runs-seen"), RUNS_SEEN_LIMIT * 16)
    for line in raw.split("\n")[:RUNS_SEEN_LIMIT]:
        line = line.strip()
        if RUNID_RE.match(line):
            seen.add(line)
    unseen = 0
    for runid in all_runids()[:RUNS_UNSEEN_SCAN_LIMIT]:
        if runid in seen:
            continue
        if Run(runid).status in ("running", "unknown"):
            continue
        unseen += 1
    return unseen


def standing_object():
    """The standing in-box session, or None when this box has never had one.

    None means exactly that: `sessions/claude/` does not exist, which is the
    contract's "nobody could answer" for a box where no session was ever
    started. A session that has ended leaves its directory behind and is
    reported as `gone` -- a fact, and a different one.

    This is also the function `_standing_or_none` calls for `--channel-list`, so
    the channel listing and `status --json` describe the session with one
    object built in one place.
    """
    session_dir = os.path.join(SESSIONS_DIR, STANDING_SESSION)
    if not os.path.isdir(session_dir):
        return None
    alive = _standing_alive(_standing_pid(session_dir))
    event, when, tool = _standing_tail(session_dir)
    return {
        "name": STANDING_SESSION,
        "state": _standing_state(alive, event),
        # When the state last changed as far as this box can tell: the newest
        # event in the session's own log, or -- before it has logged one -- when
        # the session recorded its pid.
        "since": iso(when) or _mtime_iso(os.path.join(session_dir, "pid")),
        "task": first_line(
            scrub(_read_head(os.path.join(session_dir, "task"), 4096)),
            STANDING_TASK_LIMIT,
        ),
        "last_tool": tool,
        "last_text": first_line(
            scrub(_read_head(os.path.join(session_dir, "last-text"), 4096)),
            TEXT_LIMIT,
        ),
        "runs_unseen": _runs_unseen(session_dir),
    }


def _toolchain_or_none(raw):
    """The `toolchain` object of spec 2.1, or None when the snapshot is no good.

    The input is `/var/lib/agent-box/toolcheck.json` as box-status.sh read it:
    root-owned, written by `toolcheck.sh --json --box-only` at the end of
    provisioning, and absent on a box provisioned by an older checkout. Four
    keys come out of it -- the state word, the two counts a header line is
    rendered from, and when it was taken -- and the rest of the snapshot (every
    tool's pin, version and path) is `agentbox toolcheck`'s to print, not a
    status document's.

    Shape, never bytes: the state word must be one of three, the counts must be
    counts, and the timestamp is re-rendered from a parsed one rather than
    passed through. Anything else is None, including a truncated document -- the
    read is capped, so a snapshot too large to be one reads as unanswered rather
    than as half a reading.
    """
    if not raw or not raw.strip():
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    state = _word(parsed.get("state"), TOOLCHAIN_STATES)
    if state is None:
        return None
    counts = parsed.get("counts")
    if not isinstance(counts, dict):
        return None
    missing = _count(counts.get("missing"))
    off_pin = _count(counts.get("off_pin"))
    if missing is None or off_pin is None:
        return None
    return {
        "state": state,
        "missing": missing,
        "off_pin": off_pin,
        "checked_at": iso(parse_ts(parsed.get("generated_at"))),
    }


def _toolchain_text(toolchain):
    """The `tools=` field of the text line: `ok`, `<N>missing`, `<N>off-pin`, `?`.

    `?` is the word for "nobody could answer", so it covers both an unreadable
    snapshot and one that answered `unknown`. A snapshot with findings that are
    neither missing nor off-pin -- a tool whose version could not be read at all
    -- has no count to name and is the third `?`: the JSON carries
    `state:"findings"` for it, which is what a monitor renders its notice from.
    Missing before off-pin when there are both: a tool that is not there is the
    one to act on first, and `agentbox toolcheck` prints the rest by name.
    """
    if not isinstance(toolchain, dict) or toolchain.get("state") not in ("ok", "findings"):
        return "?"
    if toolchain.get("missing"):
        return "%dmissing" % toolchain["missing"]
    if toolchain.get("off_pin"):
        return "%doff-pin" % toolchain["off_pin"]
    return "ok" if toolchain.get("state") == "ok" else "?"


def _leftovers_text(leftovers):
    """The `left=` field: the four counts, `?` when nobody could answer, or "".

    Omitted entirely on an all-zero reading, because a clean box is the ordinary
    case and a line that says so about four things at once is a line nobody
    reads. The counts are the folded object's own, caps included, so this field
    and `status --json` can never disagree.
    """
    if leftovers is None:
        return "?"
    procs = leftovers.get("procs") or 0
    ports = len(leftovers.get("ports") or ())
    worktrees = len(leftovers.get("worktrees") or ())
    tmux = len(leftovers.get("tmux") or ())
    if not (procs or ports or worktrees or tmux):
        return ""
    return "%dproc,%dport,%dwt,%dtmux" % (procs, ports, worktrees, tmux)


def cmd_box_json(args):
    sessions = _sessions_or_none(args.sessions, "the session list")
    if sessions is not None:
        sessions = _clean_sessions(sessions)
    runid = newest_runid()
    obj = {
        "claude_version": args.claude_version or None,
        "firewall": args.firewall or "unknown",
        "run": Run(runid).status_object() if runid else None,
        "runs_total": len(all_runids()),
        # null, not [], when it could not be read: see _sessions_or_none.
        "sessions": sessions,
        # null when this box has never had a standing session; `gone` when it
        # had one and the process is not there any more.
        "standing": standing_object(),
        "toolchain": _toolchain_or_none(args.toolchain),
        # Both halves are null-safe, so there is nothing to branch on here:
        # _fold_leftovers(None) is None, which is the scan's "nobody could
        # answer" carried through to the key.
        "leftovers": _fold_leftovers(_leftovers_or_none(args.leftovers, "the leftovers scan")),
    }
    # PRESENT ONLY when there is something to say: the mode is unknown, or the
    # mode file and the live ruleset disagree. Not `null` on a healthy box.
    #
    # The distinction is the contract's, and it is worth keeping: every other
    # nullable key here means "this fact was asked for and is unavailable", so
    # a null `firewall_detail` on a box that is working reads as a fourth
    # unknown rather than as nothing to report. Absent means agreed.
    if args.firewall_detail:
        obj["firewall_detail"] = args.firewall_detail
    print(json.dumps(scrub_obj(obj), separators=(",", ":")))
    return 0


def cmd_box_text(args):
    """The same facts as --box-json, as one line for a terminal.

    The same four sensors, in the order spec 2.1 fixes for them: the standing
    session, the toolchain, what earlier runs left running, then the run. Each
    one is a short field rather than a sentence, and two of them are omitted
    when there is nothing to say -- a box with no session and nothing left
    behind is the ordinary case, and a line that reports four absences is a line
    an operator stops reading.
    """
    sessions = _sessions_or_none(args.sessions, "the session list")
    if sessions is not None:
        sessions = _clean_sessions(sessions)
    runid = newest_runid()
    parts = ["fw=%s" % (args.firewall or "unknown")]
    if args.firewall_detail:
        parts.append("(%s)" % args.firewall_detail)
    if args.claude_version:
        parts.append("claude=%s" % scrub(args.claude_version.split()[0]))
    parts.append("runs=%d" % len(all_runids()))
    parts.append("tmux=%s" % ("?" if sessions is None else len(sessions)))
    standing = standing_object()
    if standing is not None:
        parts.append("session=%s:%s" % (standing["name"], standing["state"]))
    parts.append("tools=%s" % _toolchain_text(_toolchain_or_none(args.toolchain)))
    left = _leftovers_text(
        _fold_leftovers(_leftovers_or_none(args.leftovers, "the leftovers scan"))
    )
    if left:
        parts.append("left=%s" % left)
    if runid:
        run = Run(runid).status_object()
        parts.append(
            "run %s %s %s turns=%s cost=%s"
            % (
                run["id"],
                run["state"],
                fmt_duration(run["elapsed_s"]),
                run["turns"] if run["turns"] is not None else "-",
                fmt_cost(run["cost_usd"]),
            )
        )
        tail = run["last_tool"] or run["last_text"]
        if tail:
            parts.append("last: %s" % tail)
    else:
        parts.append("no runs")
    print(scrub("  ".join(parts)))
    return 0


# --- triage ----------------------------------------------------------------
#
# One finished verdict about this box, built in the guest because the verdict
# needs the run state and the host is not allowed to parse guest bytes. The
# host's own facts come in as arguments (`--triage-facts`), which is why nothing
# here has to reach back to the host for anything.
#
# `--triage-facts` is ONE JSON object, built by guest/box-triage.sh with `jq -n`
# out of what it gathered in this box and what the host told it. Every value is
# read through `_count` or `_word` below, so a gatherer that went wrong, a
# missing command or a hostile string lands as `null` or is ignored rather than
# reaching the output: this program prints to the operator's terminal, and one
# box must never be able to spoil the report for the rest of the fleet.
#
# Two lines are printed, and the second one is the only thing the host reads
# back out of this call:
#
#   1. the verdict object (or, with `text` set in the facts, the padded text
#      fragment the host prints after its own three columns)
#   2. `boxonly=yes|no bytes=<digits>` — the watermark, which the host validates
#      by `case` and records against the instance so that a STOPPED box can
#      still answer "is there work only in there". Nothing else crosses in a
#      shape the host inspects.

TRIAGE_VERDICTS = ("active", "waiting", "attention", "idle", "parked", "spent", "unknown")
TRIAGE_ACTIONS = ("keep", "pause", "remove", "ask")

# The closed set of reason codes, documented and asserted. A consumer may switch
# on a code; `text` is display-only and capped. Every code below is a literal in
# this file and nothing from the facts ever becomes one -- which is what makes
# "only listed codes are emitted" a property rather than a hope.
TRIAGE_CODES = (
    "run-active",
    "session-working",
    "run-waiting",
    "session-waiting",
    "run-lost",
    "leftovers",
    "firewall-unknown",
    "handoff-unread",
    "session-open",
    "request-queued",
    "box-only-state",
    "guest-repo",
    "unexported-commits",
    "dirty-tree",
    "bench-stale",
    "no-reading",
    "repo-gone",
    "not-git",
    "box-silent",
)

# The vocabularies each fact is allowed to use. A word outside its set is not an
# error to report, it is a fact nobody supplied.
STANDING_STATES = ("working", "idle", "waiting", "gone")
SCARCE_WORDS = ("none", "disk", "compute", "both")
BENCH_WORDS = ("yes", "no", "stale")
REPO_WORDS = ("ok", "missing", "not-git")
FIREWALL_WORDS = ("deny", "observe", "open", "unknown")

# run-ctl.sh's own vocabulary, which bin/agentbox:valid_run_state also accepts.
_RUN_STATE_RE = re.compile(r"^(running|unknown|exit:(?:stopped|lost|waiting|[0-9]{1,6}))$")

# At most six reasons, so a box with a lot wrong with it cannot flood a terminal
# or a porthole header. The order they are collected in is their priority.
MAX_REASONS = 6
# A count larger than this is not a count, it is somebody's idea of a joke.
COUNT_MAX = 10 ** 15


def _count(value):
    """A non-negative integer from one fact, or None. Never raises.

    Every number in the facts object was produced by a `wc -l`, a `du -sk` or a
    host argument, and each of those can be empty, a word, or absent. One
    mis-shaped value must not stop the box being reported at all -- the same
    rule the host applies to a guest number before arithmetic.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        return None
    if number < 0 or number > COUNT_MAX:
        return None
    return number


def _word(value, allowed, default=None):
    """One of `allowed`, or the default. A long or hostile string is not a word."""
    return value if isinstance(value, str) and value in allowed else default


def _human_bytes(number):
    """A byte count as a short human string: the BOX-ONLY column's whole job."""
    if number is None:
        return "?"
    for unit, size in (("G", 1024 ** 3), ("M", 1024 ** 2), ("K", 1024)):
        if number >= size:
            scaled = float(number) / size
            return ("%.1f%s" % (scaled, unit)) if scaled < 10 else ("%d%s" % (scaled, unit))
    return "%d" % number


def _leftover_count(value):
    """How many things earlier runs left running, from item 4's object or list.

    Tolerant on purpose: the ledger reader is another slice's, its shape is
    `{procs, ports[], worktrees[], tmux[], runs[], truncated}` for `status`, and
    a list of rows is what a survivors call returns. Anything else is "nobody
    answered", which is not the same as zero.
    """
    if isinstance(value, list):
        return len(value)
    if isinstance(value, dict):
        total = 0
        for key in ("procs", "ports", "worktrees", "tmux"):
            item = value.get(key)
            if isinstance(item, list):
                total += len(item)
            else:
                number = _count(item)
                if number is not None:
                    total += number
        return total
    return None


def _triage_facts(raw):
    """The facts object, or None when it did not parse."""
    try:
        parsed = json.loads(raw) if raw else None
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def _box_only_object(facts, as_of):
    return {
        "known": True,
        "as_of": as_of,
        "state_bytes": _count(facts.get("state_bytes")),
        "claude_state_bytes": _count(facts.get("claude_state_bytes")),
        "transcripts": _count(facts.get("transcripts")),
        "docker_images": _count(facts.get("docker_images")),
        "docker_volumes": _count(facts.get("docker_volumes")),
        "guest_repos": _count(facts.get("guest_repos")),
        "home_files": _count(facts.get("home_files")),
    }


def _box_only_categories(box_only):
    """The categories a destroy would take, named, largest question first.

    Naming them is the point. "Box-only" as one number is the answer that made
    an operator destroy a box with a named volume in it; "2 docker volumes"
    is the answer that does not.

    Ordered by how irreplaceable the thing is, which is not how large it is: a
    repository and a named volume first, then the loose files an agent wrote into
    the home instead of the mount (a patch, a note -- nothing reproduces those),
    then docker images and transcripts, which a rebuild and a re-run can replace.
    """
    named = []
    for key, one, many in (
        ("guest_repos", "git repository", "git repositories"),
        ("docker_volumes", "docker volume", "docker volumes"),
        ("home_files", "file in the box's home", "files in the box's home"),
        ("docker_images", "docker image", "docker images"),
        ("transcripts", "run transcript", "run transcripts"),
    ):
        number = box_only.get(key)
        if number:
            named.append("%d %s" % (number, one if number == 1 else many))
    return named


def _triage_reasons(facts, box_only):
    """Every applicable reason, in priority order, and the verdict-bearing ones.

    Returns (reasons, verdict). Reasons are additive -- an active box with
    uncommitted work says both -- while the verdict comes from the first
    verdict-bearing reason that applies, so precedence is visible here rather
    than spread across branches.
    """
    reasons = []
    verdict = None

    run_state = facts.get("run_state")
    run_state = run_state if isinstance(run_state, str) and _RUN_STATE_RE.match(run_state) else None
    standing = _word(facts.get("standing"), STANDING_STATES)
    firewall = _word(facts.get("firewall"), FIREWALL_WORDS, "unknown")
    leftovers = _leftover_count(facts.get("leftovers"))
    handoffs = _count(facts.get("handoffs_unread")) or 0
    requests = _count(facts.get("requests_queued")) or 0
    unexported = _count(facts.get("unexported_commits")) or 0
    dirty = _count(facts.get("dirty_files")) or 0
    bench = _word(facts.get("bench"), BENCH_WORDS)
    repo = _word(facts.get("repo"), REPO_WORDS, "ok")

    def add(code, text, gives=None):
        nonlocal verdict
        reasons.append({"code": code, "text": first_line(text, REASON_LIMIT)})
        if gives and verdict is None:
            verdict = gives

    # Verdict-bearing, in priority order.
    if run_state == "running":
        add("run-active", "a run is working", "active")
    if standing == "working":
        add("session-working", "a standing session is working", "active")
    if run_state == "exit:waiting":
        add("run-waiting", "a run is waiting for an answer", "waiting")
    if standing == "waiting":
        add("session-waiting", "a standing session is waiting for an answer", "waiting")
    if run_state == "exit:lost":
        add("run-lost", "the newest run is lost; nobody knows how it ended", "attention")
    if leftovers:
        add(
            "leftovers",
            "%d thing%s an earlier run left running are still there"
            % (leftovers, "" if leftovers == 1 else "s"),
            "attention",
        )
    if firewall == "unknown":
        add("firewall-unknown", "the firewall mode cannot be read in this box", "attention")
    if handoffs:
        add(
            "handoff-unread",
            "%d handoff%s from this box %s unread"
            % (handoffs, "" if handoffs == 1 else "s", "is" if handoffs == 1 else "are"),
            "attention",
        )

    # Not verdict-bearing: they change the ACTION, or they are simply worth
    # saying. `session-open` is X3's: a stop ends a standing session, so a box
    # with one open is asked about rather than paused.
    if standing == "idle":
        add("session-open", "a standing session is open; stopping the box would end it")
    if requests:
        add(
            "request-queued",
            "%d request%s queued for this box"
            % (requests, " is" if requests == 1 else "s are"),
        )
    named = _box_only_categories(box_only)
    if named:
        add("box-only-state", "only inside this box: %s" % ", ".join(named))
    repos = box_only.get("guest_repos")
    if repos:
        add(
            "guest-repo",
            "%d git repositor%s in the box's home %s on no host disk at all"
            % (repos, "y" if repos == 1 else "ies", "is" if repos == 1 else "are"),
        )
    if unexported:
        # NEVER "only inside the box": /work IS the host's repository directory,
        # so these commits survive a destroy. They are a reason to finish the
        # work, not a reason to keep a VM, and this is the one misunderstanding
        # the command exists to prevent.
        add(
            "unexported-commits",
            "%d commit%s on agent branches are on no remote"
            % (unexported, "" if unexported == 1 else "s"),
        )
    if dirty:
        add(
            "dirty-tree",
            "%d file%s in the working tree %s not committed"
            % (dirty, "" if dirty == 1 else "s", "is" if dirty == 1 else "are"),
        )
    if bench == "stale":
        add("bench-stale", "the bench is behind the branch this box is on")
    if repo == "missing":
        add("repo-gone", "the repository directory is not on the host any more")
    elif repo == "not-git":
        add("not-git", "the mounted directory is not a git repository")

    return reasons[:MAX_REASONS], verdict


def _triage_action(verdict, reasons, scarce):
    if verdict != "idle":
        return "keep"
    codes = {reason["code"] for reason in reasons}
    # A stop ends a standing session and loses what a queued request was for.
    # Both are answered by asking, never by pausing behind the operator's back.
    if "session-open" in codes or "request-queued" in codes:
        return "ask"
    if scarce in ("compute", "both"):
        return "pause"
    return "keep"


def _triage_stand_in(text_mode):
    """Every key present, saying the box did not answer. The host has the same
    literal for the case where this program never ran at all."""
    obj = {
        "verdict": "unknown",
        "action": "ask",
        "reasons": [{"code": "box-silent", "text": "the box did not answer the triage call"}],
        "box_only": {
            "known": False,
            "as_of": None,
            "state_bytes": None,
            "claude_state_bytes": None,
            "transcripts": None,
            "docker_images": None,
            "docker_volumes": None,
            "guest_repos": None,
            "home_files": None,
        },
        "dirty_files": None,
    }
    if text_mode:
        return "%-10s %-7s %-9s %s" % (
            obj["verdict"],
            obj["action"],
            "?",
            obj["reasons"][0]["text"],
        )
    return json.dumps(obj, separators=(",", ":"))


def cmd_box_triage(args):
    facts = _triage_facts(args.triage_facts)
    # The mode travels inside the facts object rather than as a flag of its own:
    # the argument list is the skeleton's, and the payload is this mode's.
    text_mode = bool(facts.get("text")) if facts else False
    if facts is None:
        # The facts are this box's own, so unparsable facts mean the gatherer
        # broke, not that somebody attacked the host. Either way the honest
        # answer is the stand-in, with every key present, and no watermark: a
        # reading that did not happen must not be recorded as one.
        print(_triage_stand_in(text_mode))
        print("run-format: the triage facts did not parse; reporting this box as silent",
              file=sys.stderr)
        return 0

    as_of = facts.get("as_of")
    as_of = as_of if isinstance(as_of, str) and parse_ts(as_of) else None
    box_only = _box_only_object(facts, as_of)
    reasons, verdict = _triage_reasons(facts, box_only)
    verdict = verdict or "idle"
    scarce = _word(facts.get("scarce"), SCARCE_WORDS, "none")
    action = _triage_action(verdict, reasons, scarce)

    categories = _box_only_categories(box_only)
    bytes_total = (box_only["state_bytes"] or 0) + (box_only["claude_state_bytes"] or 0)

    if text_mode:
        why = reasons[0]["text"] if reasons else "nothing is only inside this box"
        column = _human_bytes(bytes_total) if categories else "0"
        print(scrub("%-10s %-7s %-9s %s" % (verdict, action, column, why)))
    else:
        obj = {
            "verdict": verdict,
            "action": action,
            "reasons": reasons,
            "box_only": box_only,
            # The working tree's dirty count is a GUEST fact since the host may
            # not run `git status` in a mounted repository (docs/decisions.md),
            # so it is reported beside `box_only` rather than inside the host's
            # `unexported` object where the shape once put it.
            "dirty_files": _count(facts.get("dirty_files")),
        }
        print(json.dumps(scrub_obj(obj), separators=(",", ":")))

    # The watermark. `yes` is by CATEGORY, not by byte count: ~/.agent-box and
    # ~/.claude exist in every box and a box with no transcript, no repository, no
    # loose file in its home and no docker volume holds no work, whatever it
    # weighs. The byte count is the two state directories only, so a box whose one
    # box-only thing is a loose file reads `yes` with a small number beside it --
    # the categories are the claim, the bytes are only the size of the state dirs.
    print("boxonly=%s bytes=%d" % ("yes" if categories else "no", bytes_total))
    return 0


def cmd_scrub_stdin(_args):
    """Copy stdin to stdout, scrubbed.

    The narrowest possible use of this file: some other guest script has
    produced text that is about to cross to the host, and the rule is that the
    redaction happens in the guest so the unredacted bytes never make the trip.
    `agentbox egress-log` is the caller — the destinations an agent reached for
    are the agent's output as much as anything it printed.
    """
    for line in sys.stdin:
        sys.stdout.write(scrub(line.rstrip("\n")) + "\n")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="run-format.py", description="print an agent-box run, scrubbed"
    )
    parser.add_argument("runid", nargs="?", help="run id; the newest run by default")
    parser.add_argument("-f", "--follow", action="store_true", help="follow until it ends")
    parser.add_argument("--json", action="store_true", help="one JSON object per line")
    parser.add_argument("--list", action="store_true", help="list runs instead")
    parser.add_argument("--summary", action="store_true", help="print summary.txt, scrubbed")
    parser.add_argument("--ask", action="store_true", help="print the question a waiting run left, scrubbed")
    parser.add_argument("--last-text", action="store_true", help="print the run's last assistant line, scrubbed")
    parser.add_argument("--learnings", action="store_true", help="print /work/.agent-box/learnings.md, scrubbed")
    parser.add_argument("--sessions-in", action="store_true", help="format a session list from stdin")
    parser.add_argument(
        "--survivors-in",
        action="store_true",
        help="format a leftovers list from stdin",
    )
    parser.add_argument(
        "--channel-list", action="store_true", help="list this box's channel messages"
    )
    # The default is None, not "", because this flag both SELECTS the mode and
    # carries its argument. An empty id is a caller bug, and the mode that was
    # asked for is the one that must answer for it: dispatching on truthiness
    # would send `--channel-read ""` to the log printer instead, which prints a
    # run's console output and exits 0 -- a wrong answer, framed as a message,
    # where the reader would have said `invalid` and failed.
    parser.add_argument(
        "--channel-read",
        default=None,
        metavar="ID",
        help="print one channel message, scrubbed",
    )
    parser.add_argument(
        "--force-unsafe",
        action="store_true",
        help="print a leak-flagged run's output anyway",
    )
    parser.add_argument(
        "--scrub-stdin",
        action="store_true",
        help="copy stdin to stdout, scrubbed and control-stripped",
    )
    parser.add_argument("--box-json", action="store_true", help="one JSON line per box")
    parser.add_argument("--box-text", action="store_true", help="one text line per box")
    parser.add_argument(
        "--box-triage", action="store_true", help="one JSON line: this box's triage verdict"
    )
    parser.add_argument("--claude-version", default="")
    parser.add_argument("--firewall", default="unknown")
    parser.add_argument("--firewall-detail", default="")
    parser.add_argument("--sessions", default="[]")
    # The gathered halves the status and triage scripts pass in. Each default is
    # the value that means "nobody answered", so a box whose gatherer is missing
    # reports null rather than an empty reading: "[]" parses to an empty list and
    # "" to nothing at all, which is the distinction _sessions_or_none draws.
    parser.add_argument("--leftovers", default="[]")
    parser.add_argument("--toolchain", default="")
    parser.add_argument("--triage-facts", default="")
    args = parser.parse_args(argv)

    if args.scrub_stdin:
        return cmd_scrub_stdin(args)
    if args.box_text:
        return cmd_box_text(args)
    if args.box_json:
        return cmd_box_json(args)
    if args.box_triage:
        return cmd_box_triage(args)
    if args.sessions_in:
        return cmd_sessions(args)
    if args.survivors_in:
        return cmd_survivors(args)
    if args.channel_list:
        return cmd_channel_list(args)
    if args.channel_read is not None:
        return cmd_channel_read(args)
    if args.list:
        return cmd_list(args)
    if args.summary:
        return cmd_summary(args)
    if args.ask:
        return cmd_ask(args)
    if args.last_text:
        return cmd_last_text(args)
    if args.learnings:
        return cmd_learnings(args)
    return cmd_logs(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BadRunid as exc:
        print("run-format: %s" % exc, file=sys.stderr)
        sys.exit(2)
    except BrokenPipeError:
        # `agentbox logs -f | head` is an ordinary thing to do.
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
