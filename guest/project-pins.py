#!/usr/bin/env python3
"""agent-box — what this repository pins, and where that differs from this box.

Reads bytes out of the mounted repository and compares the versions it finds
with the versions this box carries. NOTHING HERE IS EVER EXECUTED: no
`mise exec`, no `npm ls`, no `uv run`, no `pre-commit`, no shell. /work is the
host's own repository over virtiofs, writable by the agent and written by
whoever wrote the repository, so it is the untrusted half of the box's design
and it is read the way untrusted input is read — bounded, shape-validated, and
never echoed back when a token does not match its shape.

Stdlib only (`tomllib` is in the guest's python3.12), and no YAML parser: the
workflow files are matched with anchored regexes and every row carries
`file:line`, so what this prints is "detected at", never "parsed".

Three outputs, one scan:

    (default)        the text block `toolcheck.sh` prints under its own table
    --findings-only  the same block with only the rows that have something to say
    --json           the `project` array of toolcheck's JSON object, on one line

and, with `--counts-file`, the counts as `key=value` lines for the caller's
summary line and exit status — the caller is bash, which has no business
parsing JSON.

The box's own versions come in as `--box-versions '{"node":"24.21.0",…}'`. A
tool this box has no opinion about is reported as exactly that rather than as a
mismatch: the box is not the authority on a project's Java version.
"""

import argparse
import json
import os
import re
import stat
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - python3.10 and older
    tomllib = None

# Bounds. Every one of them exists because the directory being read is the
# host's disk and its contents are chosen by whoever wrote the repository.
MAX_FILES = 60
MAX_BYTES = 256 * 1024
MAX_ROWS = 400
PATH_LIMIT = 200
LOOKAHEAD = 12  # lines a mapped `uses:` may claim a bare `version:` within

# The literal token a version that does not match its shape becomes. The
# rejected bytes are never returned to a caller: see docs/decisions.md on the
# run status, which is the same rule applied to a different field.
UNPARSEABLE = "<unparseable>"

# A version or a specifier, as written in a project's own file. Wider than a
# plain version because a specifier is one of the things being reported
# (`>=0.12`, `^22.0.0`, `20.x`), and still narrow enough that nothing that
# reaches a terminal or a JSON string can carry a control byte or a quote.
#
# The design spells the first character class `[A-Za-z0-9]`, which would make
# every specifier form unparseable — including the `uv required-version >=0.12`
# row its own example prints as a match. The leading class here is that set plus
# the comparison characters the rest of the pattern already allows, and `-` is
# still excluded from the first position, which is the hazard an anchored first
# character exists for: a token that could be read as an option.
VERSION_RE = re.compile(r"^[A-Za-z0-9><=~^*][A-Za-z0-9._+>=<~^*-]{0,63}$")
# `@` and `/` because an npm scope is part of a package's name (`@playwright/test`).
TOOL_RE = re.compile(r"^[A-Za-z0-9@][A-Za-z0-9._@/+-]{0,39}$")
# A path is printed too, and a repository may hold a file whose name is not.
# A leading dot, because most of the files this reads have one.
SAFE_PATH_RE = re.compile(r"^[A-Za-z0-9.][A-Za-z0-9._/-]{0,199}$")
CONTROLS = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")

# A project's tool name to the name this box uses for the same tool. A name
# that is not here is a tool the box carries no pin for, which is reported as
# `(box has no opinion)` — informational, never a mismatch.
BOX_TOOL = {
    "node": "node",
    "nodejs": "node",
    "npm": "npm",
    "uv": "uv",
    "ruff": "ruff",
    "mise": "mise",
    "basedpyright": "basedpyright",
    "semgrep": "semgrep",
    "playwright": "playwright",
    "@playwright/test": "playwright",
    "trufflehog": "trufflehog",
    "actionlint": "actionlint",
    "dprint": "dprint",
}

# The five hyphenated workflow keys carry their tool in the key name, so an
# anchored regex is enough and no YAML context is needed.
WORKFLOW_KEYS = {
    "node-version": "node",
    "python-version": "python",
    "uv-version": "uv",
    "dprint-version": "dprint",
    "ruff-version": "ruff",
}

# A bare `version:` does not carry its tool: it is one of the most common
# `with:` inputs in GitHub Actions (setup-go, setup-java, setup-buildx,
# setup-helm, pnpm/action-setup). So it is read ONLY inside a step whose
# `uses:` this map knows, and everything else is simply not reported — the
# honest behaviour, and the one that needs no YAML parser.
ACTION_TOOL = {
    "astral-sh/ruff-action": "ruff",
    "astral-sh/setup-uv": "uv",
    "jdx/mise-action": "mise",
    "dprint/check": "dprint",
    "rhysd/actionlint": "actionlint",
}

# The four Python tools whose pin in a project's own dependency metadata is
# worth comparing. Everything else in a project's dependencies is the project's
# business, not the box's.
PY_TOOLS = ("ruff", "basedpyright", "semgrep", "playwright")

MISE_FILES = (
    "mise.toml",
    ".mise.toml",
    "mise/config.toml",
    ".config/mise.toml",
    ".config/mise/config.toml",
)

# A row's state. `mismatch` is the only one that makes the caller exit 11.
FINDING_STATES = ("mismatch", "unparseable", "refused")


# ---------------------------------------------------------------------------
# Shape validation
# ---------------------------------------------------------------------------


def strip_controls(text):
    """C0, DEL and C1 out of anything that may reach a terminal."""
    return CONTROLS.sub("", text) if isinstance(text, str) else ""


def safe_version(raw):
    """A version or specifier token, or the literal <unparseable>.

    The bytes that failed are dropped here and never travel any further, which
    is the whole reason this function exists rather than a `str.strip()` at
    each call site.
    """
    if not isinstance(raw, str):
        return UNPARSEABLE
    token = strip_controls(raw).strip().strip("\"'")
    if not token or not VERSION_RE.match(token):
        return UNPARSEABLE
    return token


def safe_tool(raw):
    """A tool name, or the literal <unparseable>."""
    if not isinstance(raw, str):
        return UNPARSEABLE
    name = strip_controls(raw).strip().strip("\"'")
    if not name or not TOOL_RE.match(name):
        return UNPARSEABLE
    return name


def safe_path(rel):
    """A repository-relative path, or None when it is not printable as one."""
    cleaned = strip_controls(rel)[:PATH_LIMIT]
    return cleaned if SAFE_PATH_RE.match(cleaned) else None


# ---------------------------------------------------------------------------
# Version comparison — "does the project's specifier admit the box's version"
# ---------------------------------------------------------------------------

CLAUSE_RE = re.compile(r"^(==|!=|>=|<=|~=|>|<|\^|~|=)?\s*v?([0-9][0-9A-Za-z.*+-]*)$")


def _parts(value):
    """A dotted numeric version as (tuple, is_prefix), or (None, False).

    A segment that is not a number makes the whole comparison `unknown` rather
    than a guess: `1.2.3-beta4` and `lts/iron` are not things this can order.
    A `x` or `*` segment ends the tuple and marks it as a prefix, which is what
    `20.x` means.
    """
    text = value.strip()
    if text[:1] in ("v", "V"):
        text = text[1:]
    out = []
    for seg in text.split("."):
        if seg in ("x", "X", "*"):
            return (tuple(out), True) if out else (None, False)
        if not seg.isdigit():
            return None, False
        out.append(int(seg))
    return (tuple(out), False) if out else (None, False)


def _pad(left, right):
    """Two tuples at the same length, so 24 and 22.19.0 can be compared."""
    width = max(len(left), len(right))
    return (
        left + (0,) * (width - len(left)),
        right + (0,) * (width - len(right)),
    )


def _upper_caret(spec):
    """npm's ^: the next segment that is allowed to change."""
    for index, value in enumerate(spec):
        if value != 0:
            return spec[:index] + (value + 1,)
    return spec[:-1] + (spec[-1] + 1,) if spec else (1,)


def _upper_tilde(op, spec):
    """~ and PEP 440's ~=: the last named segment may change, nothing above it.

    The two spellings differ on a two-segment specifier and nowhere else:
    `~=1.2` admits every 1.x, while npm's `~1.2` admits only 1.2.x. Both are
    implemented rather than one being read as the other, because a wrong
    MISMATCH in a brief costs an agent a detour.
    """
    if len(spec) > 2:
        return spec[:-2] + (spec[-2] + 1,)
    if len(spec) == 2:
        return (spec[0] + 1,) if op == "~=" else (spec[0], spec[1] + 1)
    return (spec[0] + 1,)


def _clause_ok(op, spec, prefix, box):
    if op in ("==", "=", ""):
        # A specifier with fewer segments than the box's version names that
        # line: `22` in a .nvmrc or a .tool-versions means the 22 series, and
        # every file this reads spells an exact pin in full.
        width = min(len(spec), len(box)) if prefix or len(spec) < len(box) else len(box)
        left, right = _pad(spec[:width], box[:width])
        return left == right
    if op == "!=":
        return not _clause_ok("==", spec, prefix, box)
    left, right = _pad(spec, box)
    if op == ">=":
        return right >= left
    if op == ">":
        return right > left
    if op == "<=":
        return right <= left
    if op == "<":
        return right < left
    if op == "^":
        upper_l, upper_r = _pad(_upper_caret(spec), box)
        return right >= left and upper_r < upper_l
    if op in ("~", "~="):
        upper_l, upper_r = _pad(_upper_tilde(op, spec), box)
        return right >= left and upper_r < upper_l
    return False


def admits(spec, box):
    """match, mismatch or unknown — never a guess dressed as an answer."""
    box_parts, _ = _parts(box)
    if box_parts is None:
        return "unknown"
    clauses = [c.strip() for c in spec.split(",") if c.strip()]
    if not clauses:
        return "unknown"
    for clause in clauses:
        matched = CLAUSE_RE.match(clause)
        if not matched:
            return "unknown"
        spec_parts, prefix = _parts(matched.group(2))
        if spec_parts is None:
            return "unknown"
        if not _clause_ok(matched.group(1) or "==", spec_parts, prefix, box_parts):
            return "mismatch"
    return "match"


# ---------------------------------------------------------------------------
# The scan
# ---------------------------------------------------------------------------


class Scan:
    """One pass over one directory, with every bound in one place."""

    def __init__(self, root, box_versions):
        self.root = root
        self.box = box_versions
        self.rows = []
        self.files_read = 0
        self.files_skipped = 0
        self.truncated = 0

    # --- reading ----------------------------------------------------------

    def _symlinked(self, rel):
        """True when the path, or any directory on the way to it, is a link.

        Checked component by component: a `.github` that is a symlink is as
        much of an escape as a `.python-version` that is one, and the refusal
        has to name the thing the operator can see.
        """
        current = self.root
        for part in rel.split("/"):
            current = os.path.join(current, part)
            if os.path.islink(current):
                return True
        return False

    def refuse(self, rel, why):
        self.files_skipped += 1
        self.add(rel, None, None, None, state="refused", note=why)

    def read(self, rel):
        """The file's text, or None with a refusal recorded.

        A directory on the way to it that does not exist is not a refusal: most
        of the candidate files are absent in most repositories, and saying so
        about each one would bury what was actually found.
        """
        if self.files_read + self.files_skipped >= MAX_FILES:
            return None
        path = os.path.join(self.root, rel)
        if not os.path.lexists(path):
            return None
        if self._symlinked(rel):
            self.refuse(rel, "is a symlink")
            return None
        try:
            info = os.stat(path)
        except OSError:
            self.refuse(rel, "could not be read")
            return None
        if not stat.S_ISREG(info.st_mode):
            # A FIFO would block the read for as long as nobody wrote to it.
            self.refuse(rel, "is not a regular file")
            return None
        if info.st_size > MAX_BYTES:
            self.refuse(rel, "is larger than the %d KiB read cap" % (MAX_BYTES // 1024))
            return None
        try:
            with open(path, "rb") as handle:
                raw = handle.read(MAX_BYTES + 1)
        except OSError:
            self.refuse(rel, "could not be read")
            return None
        if len(raw) > MAX_BYTES:
            self.truncated += 1
            raw = raw[:MAX_BYTES]
        self.files_read += 1
        return raw.decode("utf-8", errors="replace")

    # --- rows -------------------------------------------------------------

    def add(self, rel, line, tool, project, state=None, note=None):
        if len(self.rows) >= MAX_ROWS:
            return
        printable = safe_path(rel) or "<unsafe path>"
        box_version = None
        if state is None:
            box_tool = BOX_TOOL.get(tool.lower()) if tool else None
            if project == UNPARSEABLE:
                state = "unparseable"
                box_version = self.box.get(box_tool) if box_tool else None
            elif box_tool is None:
                state = "no_opinion"
            else:
                box_version = self.box.get(box_tool)
                state = "unknown" if not box_version else admits(project, box_version)
        self.rows.append(
            {
                "file": printable,
                "line": line,
                "tool": tool,
                "project": project,
                "box": box_version,
                "state": state,
                "note": note,
            }
        )

    def add_pin(self, rel, line, raw_tool, raw_version):
        self.add(rel, line, safe_tool(raw_tool), safe_version(raw_version))

    # --- the files --------------------------------------------------------

    def run(self):
        self.scan_mise()
        self.scan_tool_versions()
        self.scan_single_version_files()
        self.scan_pyproject()
        self.scan_uv_lock()
        self.scan_package_json()
        self.scan_package_lock()
        self.scan_workflows()
        return self.rows

    def scan_mise(self):
        for rel in MISE_FILES:
            text = self.read(rel)
            if text is None:
                continue
            data = parse_toml(text)
            if data is None:
                self.add(rel, None, None, None, state="unparseable", note="is not readable as TOML")
                continue
            min_version = data.get("min_version")
            if isinstance(min_version, str):
                self.add_pin(rel, line_of(text, "min_version"), "mise", min_version)
            tools = data.get("tools")
            if not isinstance(tools, dict):
                continue
            for name, value in tools.items():
                spec = mise_spec(value)
                if spec is None:
                    continue
                self.add_pin(rel, line_of(text, str(name)), name, spec)

    def scan_tool_versions(self):
        rel = ".tool-versions"
        text = self.read(rel)
        if text is None:
            return
        for number, line in enumerate(text.splitlines(), 1):
            bare = line.split("#", 1)[0].strip()
            if not bare:
                continue
            fields = bare.split()
            if len(fields) < 2:
                continue
            # Several versions on one line is legal (asdf reads them in order);
            # the first is the one that is used, and the one reported.
            self.add_pin(rel, number, fields[0], fields[1])

    def scan_single_version_files(self):
        for rel, tool in ((".python-version", "python"), (".nvmrc", "node"), (".node-version", "node")):
            text = self.read(rel)
            if text is None:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                bare = line.split("#", 1)[0].strip()
                if not bare:
                    continue
                self.add_pin(rel, number, tool, bare)
                break

    def scan_pyproject(self):
        rel = "pyproject.toml"
        text = self.read(rel)
        if text is None:
            return
        data = parse_toml(text)
        if data is None:
            self.add(rel, None, None, None, state="unparseable", note="is not readable as TOML")
            return
        uv_table = data.get("tool", {}).get("uv", {}) if isinstance(data.get("tool"), dict) else {}
        if isinstance(uv_table, dict) and isinstance(uv_table.get("required-version"), str):
            self.add_pin(rel, line_of(text, "required-version"), "uv", uv_table["required-version"])
        for requirement in pyproject_requirements(data):
            name, spec = split_requirement(requirement)
            # A dependency with no version at all pins nothing, so it is not a
            # finding of any kind — not even an unparseable one.
            if name is None or not spec or name.lower() not in PY_TOOLS:
                continue
            self.add_pin(rel, line_of(text, name), name, spec)

    def scan_uv_lock(self):
        rel = "uv.lock"
        text = self.read(rel)
        if text is None:
            return
        data = parse_toml(text)
        if data is None:
            self.add(rel, None, None, None, state="unparseable", note="is not readable as TOML")
            return
        packages = data.get("package")
        if not isinstance(packages, list):
            return
        for entry in packages:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            version = entry.get("version")
            if not isinstance(name, str) or name.lower() not in PY_TOOLS:
                continue
            if not isinstance(version, str):
                continue
            self.add_pin(rel, line_of(text, '"%s"' % name), name, version)

    def scan_package_json(self):
        rel = "package.json"
        text = self.read(rel)
        if text is None:
            return
        data = parse_json(text)
        if not isinstance(data, dict):
            self.add(rel, None, None, None, state="unparseable", note="is not readable as JSON")
            return
        engines = data.get("engines")
        if isinstance(engines, dict) and isinstance(engines.get("node"), str):
            self.add_pin(rel, line_of(text, '"node"'), "node", engines["node"])
        for section in ("devDependencies", "dependencies"):
            table = data.get(section)
            if not isinstance(table, dict):
                continue
            for name in ("playwright", "@playwright/test"):
                spec = table.get(name)
                if isinstance(spec, str):
                    self.add_pin(rel, line_of(text, '"%s"' % name), name, spec)

    def scan_package_lock(self):
        rel = "package-lock.json"
        text = self.read(rel)
        if text is None:
            return
        data = parse_json(text)
        if not isinstance(data, dict):
            self.add(rel, None, None, None, state="unparseable", note="is not readable as JSON")
            return
        # Lockfile 2 and 3 key packages by their path; version 1 by their name.
        wanted = ("playwright", "@playwright/test")
        packages = data.get("packages")
        if isinstance(packages, dict):
            for key, entry in packages.items():
                name = key.split("node_modules/")[-1]
                if name in wanted and isinstance(entry, dict) and isinstance(entry.get("version"), str):
                    self.add_pin(rel, line_of(text, '"%s"' % key), name, entry["version"])
        legacy = data.get("dependencies")
        if isinstance(legacy, dict):
            for name in wanted:
                entry = legacy.get(name)
                if isinstance(entry, dict) and isinstance(entry.get("version"), str):
                    self.add_pin(rel, line_of(text, '"%s"' % name), name, entry["version"])

    def scan_workflows(self):
        directory = ".github/workflows"
        path = os.path.join(self.root, directory)
        if not os.path.lexists(path):
            return
        if self._symlinked(directory):
            self.refuse(directory, "is a symlink")
            return
        if not os.path.isdir(path):
            return
        try:
            # One non-recursive listing, no globbing through symlinks.
            names = sorted(
                entry.name
                for entry in os.scandir(path)
                if entry.name.endswith((".yml", ".yaml")) and not entry.is_symlink()
            )
        except OSError:
            self.refuse(directory, "could not be listed")
            return
        for name in names:
            rel = "%s/%s" % (directory, name)
            if self.files_read + self.files_skipped >= MAX_FILES:
                self.files_skipped += 1
                continue
            text = self.read(rel)
            if text is None:
                continue
            self.scan_workflow_text(rel, text)

    def scan_workflow_text(self, rel, text):
        key_re = re.compile(
            r"^\s*(%s)\s*:\s*(.+?)\s*$" % "|".join(WORKFLOW_KEYS), re.IGNORECASE
        )
        uses_re = re.compile(r"^(\s*)-?\s*uses\s*:\s*['\"]?([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)")
        version_re = re.compile(r"^\s*version\s*:\s*(.+?)\s*$")
        item_re = re.compile(r"^\s*-\s")
        step_tool = None
        step_line = 0
        for number, line in enumerate(text.splitlines(), 1):
            bare = line.split("#", 1)[0]
            found_key = key_re.match(bare)
            if found_key:
                tool = WORKFLOW_KEYS[found_key.group(1).lower()]
                self.add_pin(rel, number, tool, found_key.group(2))
            found_uses = uses_re.match(bare)
            if found_uses:
                step_tool = ACTION_TOOL.get(found_uses.group(2))
                step_line = number
                continue
            if step_tool is None:
                continue
            # The attribution ends at the next list item or after a few lines:
            # a `version:` further away than that belongs to another step, and
            # guessing at it is the failure this bound exists to prevent.
            if item_re.match(bare) or number - step_line > LOOKAHEAD:
                step_tool = None
                continue
            found_version = version_re.match(bare)
            if found_version:
                self.add_pin(rel, number, step_tool, found_version.group(1))
                step_tool = None


def parse_toml(text):
    if tomllib is None:
        return None
    try:
        return tomllib.loads(text)
    except Exception:
        return None


def parse_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def mise_spec(value):
    """A [tools] entry's version, whichever of the three shapes it has."""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        for item in value:
            spec = mise_spec(item)
            if spec is not None:
                return spec
        return None
    if isinstance(value, dict) and isinstance(value.get("version"), str):
        return value["version"]
    return None


def pyproject_requirements(data):
    """Every dependency string worth looking at, from the five usual places."""
    out = []
    project = data.get("project")
    if isinstance(project, dict):
        for value in (project.get("dependencies"),):
            if isinstance(value, list):
                out.extend(v for v in value if isinstance(v, str))
        optional = project.get("optional-dependencies")
        if isinstance(optional, dict):
            for value in optional.values():
                if isinstance(value, list):
                    out.extend(v for v in value if isinstance(v, str))
    groups = data.get("dependency-groups")
    if isinstance(groups, dict):
        for value in groups.values():
            if isinstance(value, list):
                out.extend(v for v in value if isinstance(v, str))
    tool = data.get("tool") if isinstance(data.get("tool"), dict) else {}
    uv_table = tool.get("uv") if isinstance(tool.get("uv"), dict) else {}
    if isinstance(uv_table.get("dev-dependencies"), list):
        out.extend(v for v in uv_table["dev-dependencies"] if isinstance(v, str))
    poetry = tool.get("poetry") if isinstance(tool.get("poetry"), dict) else {}
    poetry_groups = poetry.get("group") if isinstance(poetry.get("group"), dict) else {}
    for group in poetry_groups.values():
        table = group.get("dependencies") if isinstance(group, dict) else None
        if isinstance(table, dict):
            out.extend("%s%s" % (k, v) for k, v in table.items() if isinstance(v, str))
    return out[:MAX_ROWS]


REQUIREMENT_RE = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(\[[^\]]*\])?\s*(.*)$")


def split_requirement(requirement):
    """A requirement string as (name, specifier), or (None, None).

    An environment marker or a direct URL makes the specifier one this cannot
    interpret; it is reported as `unknown`, which is what the comparison does
    with a specifier it does not recognise anyway.
    """
    matched = REQUIREMENT_RE.match(requirement)
    if not matched:
        return None, None
    spec = matched.group(3).split(";")[0].strip()
    return matched.group(1), spec


def line_of(text, *needles):
    """The 1-based line holding every needle, or None.

    `tomllib` and `json` give no positions, and a finding without `file:line`
    is not checkable by the person or the agent reading it. Searching the raw
    text for the key is approximate by construction, which is exactly why the
    report says "detected at" and never "parsed at".
    """
    for number, line in enumerate(text.splitlines(), 1):
        if all(needle in line for needle in needles):
            return number
    return None


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

STATE_WORD = {
    "mismatch": "MISMATCH",
    "match": "match",
    "unknown": "(cannot be compared)",
    "no_opinion": "(box has no opinion)",
    "unparseable": "UNPARSEABLE",
}


def render_row(row):
    if row["state"] == "refused":
        return "  refused: %s %s" % (row["file"], row["note"] or "was not read")
    where = row["file"] if row["line"] is None else "%s:%d" % (row["file"], row["line"])
    left = "%-27s %s %s" % (where, row["tool"] or "?", row["project"] or "?")
    word = STATE_WORD.get(row["state"], row["state"])
    if row["state"] == "no_opinion" or not row["box"]:
        right = word
    else:
        right = "box %-14s %s" % (row["box"], word)
    return "  %-52s %s" % (left, right)


def counts_of(scan):
    tally = {
        "mismatch": 0,
        "match": 0,
        "unknown": 0,
        "no_opinion": 0,
        "unparseable": 0,
        "refused": 0,
    }
    for row in scan.rows:
        if row["state"] in tally:
            tally[row["state"]] += 1
    tally["rows"] = len(scan.rows)
    tally["files_read"] = scan.files_read
    tally["files_skipped"] = scan.files_skipped
    tally["truncated"] = scan.truncated
    return tally


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="project-pins.py",
        description="where this repository pins a tool differently from this box",
    )
    parser.add_argument("directory", help="the repository to read (never executed)")
    parser.add_argument("--json", action="store_true", help="print the project array, one line")
    parser.add_argument(
        "--findings-only", action="store_true", help="print only the rows with something to say"
    )
    parser.add_argument("--box-versions", default="", help="JSON object of this box's versions")
    parser.add_argument("--counts-file", default="", help="write the counts as key=value lines")
    args = parser.parse_args(argv)

    box_versions = {}
    if args.box_versions:
        parsed = parse_json(args.box_versions)
        if isinstance(parsed, dict):
            box_versions = {
                k: safe_version(v) for k, v in parsed.items() if isinstance(v, str) and v
            }
            box_versions = {k: v for k, v in box_versions.items() if v != UNPARSEABLE}

    root = args.directory
    scan = Scan(root, box_versions)
    if os.path.isdir(root) and not os.path.islink(root):
        scan.run()
    rows = scan.rows

    if args.counts_file:
        try:
            with open(args.counts_file, "w", encoding="utf-8") as handle:
                for key, value in sorted(counts_of(scan).items()):
                    handle.write("%s=%d\n" % (key, value))
        except OSError:
            pass

    if args.json:
        # The `project` array of toolcheck's JSON object. The internal `note`
        # is dropped: the contract in the design has six keys.
        print(
            json.dumps(
                [{k: v for k, v in row.items() if k != "note"} for row in rows],
                separators=(",", ":"),
            )
        )
        return 0

    shown = [r for r in rows if not args.findings_only or r["state"] in FINDING_STATES]
    if not shown:
        return 0
    if args.findings_only:
        print("project pins in %s that differ from this box:" % root)
    else:
        print("project pins detected in %s:" % root)
    for row in shown:
        print(render_row(row))
    if scan.files_skipped or scan.truncated:
        print(
            "  (read %d files, at most %d; %d not read)"
            % (scan.files_read, MAX_FILES, scan.files_skipped)
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
