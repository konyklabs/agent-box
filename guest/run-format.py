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
  run-format.py --box-json ...               one JSON line describing this box
  run-format.py --box-text ...               the same, as one line of text
  run-format.py --box-triage --triage-facts JSON
                                             this box's triage verdict, and the
                                             watermark line the host records
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
# the guest home. `_leftovers_or_none`, `_clean_leftovers`, `_fold_leftovers` and
# the body of `cmd_survivors` belong to the slice that builds the ledger; the
# skeleton owns the name, the dispatch and the `--leftovers` argument, so the
# status object and this mode cannot disagree about either.


def cmd_survivors(_args):
    print("run-format: the leftovers reader is not built in this checkout", file=sys.stderr)
    return 1


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
