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
  run-format.py --survivors-in [--json]      format a leftovers list from stdin
  run-format.py --box-json ...               one JSON line describing this box
  run-format.py --box-text ...               the same, as one line of text
"""

from __future__ import annotations

import argparse
import json
import os
import re
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
    """Scrub every string in a nested structure, on the way out to the host."""
    if isinstance(obj, str):
        return scrub(obj)
    if isinstance(obj, dict):
        return {k: scrub_obj(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub_obj(v) for v in obj]
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
    """
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            if size > budget:
                fh.seek(size - budget)
                fh.readline()  # drop the partial line the seek landed inside
            data = fh.read()
    except OSError:
        return []
    text = data.decode("utf-8", errors="replace")
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
    return "-" if value is None else "$%.4f" % value


def fmt_duration(seconds):
    if seconds is None:
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
        cleaned = dict(item)
        cleaned["name"] = scrub(str(item.get("name", "")))[:80]
        out.append(scrub_obj(cleaned))
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
    print("%-24s  %-10s  %s" % ("SESSION", "AGE", "LAST EVENT"))
    for item in sessions:
        event = item.get("last_event") or {}
        if isinstance(event, dict) and event.get("event"):
            shown = "%s %s" % (event.get("ts") or "?", event.get("event"))
        else:
            shown = "-"
        print(
            "%-24s  %-10s  %s"
            % (item.get("name", "?"), "%ss" % item.get("age_s", "?"), shown)
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
    """
    out = []
    seen = set()
    for item in rows or []:
        if not isinstance(item, dict):
            continue
        kind = scrub(str(item.get("kind") or ""))[:16]
        value = scrub(str(item.get("value") or ""))[: LEFTOVER_VALUE_LIMITS.get(kind, PATH_LIMIT)]
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


def cmd_channel_list(_args):
    print("run-format: the channel listing is not built in this checkout", file=sys.stderr)
    return 1


def cmd_channel_read(_args):
    print("run-format: the channel reader is not built in this checkout", file=sys.stderr)
    return 1


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
    """The same facts as --box-json, as one line for a terminal."""
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
# here has to reach back to the host for anything. `cmd_box_triage` belongs to
# the triage slice; the skeleton owns the name, the caps and the dispatch.


def cmd_box_triage(_args):
    print("run-format: the box triage is not built in this checkout", file=sys.stderr)
    return 1


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
