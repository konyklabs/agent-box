#!/bin/bash
#
# agent-box — every baseline tool at its pin, and where this repository pins one
# differently.
#
# Runs in the guest, as the unprivileged box user. Two halves, answering two
# different questions:
#
#   the box half      is every tool in guest/toolchain.pins installed, at the
#                     version that file names? Asked by running each tool and
#                     reading its own answer, because a marker file lies after
#                     somebody moves a binary.
#   the project half  does the repository mounted at /work pin a tool at a
#                     version this box does not have? Read out of the project's
#                     own files by guest/project-pins.py, which never executes
#                     any of them.
#
# Exit status is the answer a script reads, and it is three-valued on purpose:
#
#   0   every baseline tool is at its pin, and nothing in this repository differs
#   10  a baseline tool is missing or off its pin — this box is not at baseline
#   11  the box is clean, and this repository pins something differently
#   1   usage, or something this script could not do at all (the house rule) —
#       including a live sweep whose pins file could not be read, which checked
#       no tool against a pin and so cannot answer 0
#
# 10 and 11 are deliberately far apart from 1: a script that gates on "the box
# is broken" must not read a typo'd flag as the same event.
#
# Nothing here blocks anything. A finding is warn-only by contract for the
# launch paths (see docs/decisions.md): the box's isolation does not depend on a
# formatter being present, and a box that refuses to open a shell because a
# download failed is worse than a box without a formatter. The exit status is
# there so a caller can gate deliberately, which `agentbox create` does.
#
# Everything printed goes through guest/run-format.py first. The versions are
# programs' own output and the project half is read out of the host's disk;
# neither is a constant, and both reach a terminal on the host.

set -uo pipefail

die() { printf 'toolcheck: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# Both overridable so the host can exercise this script against a fixture
# without a VM, the way every other path in lib.sh is overridable.
PINS_FILE="${ABX_PINS_FILE:-${ABX_LIB_DIR}/toolchain.pins}"
SNAPSHOT_FILE="${ABX_TOOLCHECK_SNAPSHOT:-/var/lib/agent-box/toolcheck.json}"
PROJECT_PINS="${ABX_LIB_DIR}/project-pins.py"
RUN_FORMAT="${ABX_LIB_DIR}/run-format.py"
BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}"

AS_JSON=0
PROJECT_ONLY=0
BOX_ONLY=0
FINDINGS_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --json)           AS_JSON=1; shift ;;
        --project-only)   PROJECT_ONLY=1; shift ;;
        --box-only)       BOX_ONLY=1; shift ;;
        --findings-only)  FINDINGS_ONLY=1; shift ;;
        *) die "unknown argument '$1'; usage: toolcheck.sh [--json] [--project-only] [--box-only] [--findings-only]" ;;
    esac
done
[ "$PROJECT_ONLY" -eq 1 ] && [ "$BOX_ONLY" -eq 1 ] \
    && die "--project-only and --box-only ask for different halves; pass one"
[ "$AS_JSON" -eq 1 ] && [ "$FINDINGS_ONLY" -eq 1 ] \
    && die "--findings-only is the text form; --json always carries every row"

# ---------------------------------------------------------------------------
# The pins
# ---------------------------------------------------------------------------
#
# Read back with the idiom test/smoke.sh already uses on this file, rather than
# sourced: only the *_VERSION keys are wanted here, every one of them is a
# literal, and a `.` on a committed file is a habit worth not having in a script
# whose other half reads the untrusted half of the box.
read_pin() {
    local key="${1:?}" value
    [ -r "$PINS_FILE" ] || return 0
    value=$(sed -n "s/^${key}=\"\\(.*\\)\"\$/\\1/p" "$PINS_FILE" | head -1)
    # Same rule as every other guest-origin token: shape first, and a value
    # that fails it is dropped rather than printed.
    case "$value" in
        ''|*[!A-Za-z0-9.+_-]*) return 0 ;;
        *) printf '%s' "$value" ;;
    esac
}

# ---------------------------------------------------------------------------
# The box half
# ---------------------------------------------------------------------------
#
# One line per tool, because the output formats genuinely differ and guessing is
# how a green check becomes meaningless. This IS the version-extraction table of
# the design: to add a tool, add its line.
#
# UNVERIFIED: only `playwright`'s `Version ` prefix and `actionlint`'s
# three-line output are source-confirmed, and `trufflehog` writes its version to
# stderr, which is why the redirection is not decoration. Every line here is a
# lead until somebody has run it in a guest — which is what smoke 5c does by
# asserting that every row reads `ok` on a fresh box, so a wrong extractor fails
# loudly at build time instead of quietly for ever.
tool_version() {
    case "${1:?}" in
        uv)           uv --version 2>/dev/null | awk '{print $2}' ;;
        ruff)         ruff --version 2>/dev/null | awk '{print $2}' ;;
        basedpyright) basedpyright --version 2>/dev/null | awk 'NR==1{print $2}' ;;
        mise)         mise --version 2>/dev/null | sed -n 's/^\([0-9][0-9.]*\).*/\1/p' ;;
        node)         node --version 2>/dev/null | tr -d 'v' ;;
        npm)          npm --version 2>/dev/null | head -1 ;;
        playwright)   playwright --version 2>/dev/null | awk '{print $NF}' ;;
        semgrep)      semgrep --version 2>/dev/null | head -1 ;;
        trufflehog)   trufflehog --version 2>&1 | awk 'NR==1{print $2}' ;;
        actionlint)   actionlint -version 2>/dev/null | awk 'NR==1{print $1}' ;;
        dprint)       dprint --version 2>/dev/null | awk '{print $2}' ;;
        jq)           jq --version 2>/dev/null | sed 's/^jq-//' ;;
        zip)          zip -v 2>/dev/null | sed -n 's/^This is Zip \([0-9][0-9.]*\).*/\1/p' | head -1 ;;
        unzip)        unzip -v 2>/dev/null | awk 'NR==1{print $2}' ;;
        tar)          tar --version 2>/dev/null | awk 'NR==1{print $NF}' ;;
        claude)       claude --version 2>/dev/null | awk '{print $1}' ;;
        *)            return 0 ;;
    esac
}

# The tools, in the order the pins file names them, so a diff of two runs reads
# as a diff. The pin key is empty for the four the distribution provides and for
# the CLI, which is the one tool this box deliberately does not pin (see
# docs/decisions.md, and CLAUDE_CODE_VERSION="latest" in the pins file, which is
# a statement rather than an omission).
tool_table() {
    cat <<'TOOLS'
uv UV_VERSION
ruff RUFF_VERSION
basedpyright BASEDPYRIGHT_VERSION
mise MISE_VERSION
node NODE_VERSION
npm NODE_NPM_VERSION
playwright PLAYWRIGHT_VERSION
chromium PLAYWRIGHT_CHROMIUM_REVISION
semgrep SEMGREP_VERSION
trufflehog TRUFFLEHOG_VERSION
actionlint ACTIONLINT_VERSION
dprint DPRINT_VERSION
jq -
zip -
unzip -
tar -
claude -
TOOLS
}

# Chromium is not a program that answers `--version`: it is a directory under
# the shared browser path whose name carries the revision the installed
# Playwright asked for, plus an executable inside it. The revision is read back
# from what is installed, never chosen here.
#
# The subdirectory carries the architecture, so the name differs per host:
# `chrome-linux64` on x86_64 and `chrome-linux-arm64` on this Mac's guests
# (measured on a real box: Playwright 1.63 revision 1243 unpacks
# `chromium-1243/chrome-linux-arm64/chrome`). An earlier version of this
# function looked only for `chrome-linux/chrome`, which exists on neither, so a
# correctly installed browser read as missing on every box, `toolcheck` exited
# non-zero for ever, and `create` ended with a false NOT READY. Match the
# executable by glob rather than by naming the layouts, so the next rename is
# not another false alarm.
chromium_found() {
    local dir exe
    for dir in "${BROWSERS_PATH}"/chromium-*; do
        [ -d "$dir" ] || continue
        for exe in "$dir"/chrome-linux*/chrome "$dir"/chrome-linux*/headless_shell \
                   "$dir"/chrome-*/chrome "$dir"/chrome-*/headless_shell; do
            if [ -x "$exe" ]; then
                printf '%s' "${dir##*/chromium-}"
                return 0
            fi
        done
    done
    return 0
}

# A tool's name or version, validated. The rule is bin/agentbox's own for a run
# state, applied to a new field: a value that does not match its shape is not
# printed, not compared, and not passed on.
valid_token() {
    case "${1:-}" in
        ''|*[!A-Za-z0-9.+_-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A path from `command -v`, validated for the same reason before it enters the
# JSON.
valid_path() {
    case "${1:-}" in
        /*) case "$1" in *[!A-Za-z0-9/._+-]*) return 1 ;; *) return 0 ;; esac ;;
        *) return 1 ;;
    esac
}

# Filled by sweep_box: one `name|pinned|found|state|path` line per tool, and the
# four counters. `-` stands for "no value", which no validated token can be.
BOX_ROWS=""
BOX_STATE="ok"
# 0 when a LIVE sweep could not read the pins file. Kept apart from BOX_STATE
# because the two facts are independent: `command -v` answers "is this tool
# here" whether or not a pin was readable, and only the comparison against a pin
# is lost. Conflating them is how a box with a tool missing reported itself
# clean.
PINS_READABLE=1
N_OK=0
N_MISSING=0
N_OFFPIN=0
N_UNREADABLE=0

sweep_box() {
    local name key pin found path state
    [ -r "$PINS_FILE" ] || PINS_READABLE=0
    while read -r name key; do
        [ -n "$name" ] || continue
        pin=""
        [ "$key" = "-" ] || pin=$(read_pin "$key")
        # `latest` is the pins file saying a version is deliberately not fixed.
        [ "$pin" = "latest" ] && pin=""
        found=""
        path=""
        if [ "$name" = "chromium" ]; then
            found=$(chromium_found)
        elif path=$(command -v "$name" 2>/dev/null); then
            found=$(tool_version "$name")
        else
            path=""
        fi
        valid_token "$found" || found=""
        valid_path "$path" || path=""

        # Present, pinned and readable is the only case that can be compared.
        # An UNPINNED tool that is present is `ok`: presence is the whole claim
        # this box makes about the distribution's zip and about the CLI, and
        # reporting one as a finding because an extractor guessed wrong would be
        # a false alarm in front of every brief.
        if [ "$name" = "chromium" ]; then
            if [ -z "$found" ]; then state="missing"
            elif [ -n "$pin" ] && [ "$found" != "$pin" ]; then state="off_pin"
            else state="ok"
            fi
        elif [ -z "$path" ]; then
            state="missing"
        elif [ -z "$pin" ]; then
            state="ok"
        elif [ -z "$found" ]; then
            state="unreadable"
        elif [ "$found" = "$pin" ]; then
            state="ok"
        else
            state="off_pin"
        fi

        case "$state" in
            ok)         N_OK=$((N_OK + 1)) ;;
            missing)    N_MISSING=$((N_MISSING + 1)) ;;
            off_pin)    N_OFFPIN=$((N_OFFPIN + 1)) ;;
            unreadable) N_UNREADABLE=$((N_UNREADABLE + 1)) ;;
        esac
        BOX_ROWS="${BOX_ROWS}${name}|${pin:--}|${found:--}|${state}|${path:--}
"
    done <<EOF
$(tool_table)
EOF
    # The roll-up runs even when the pins file could not be read. A tool that is
    # not on PATH is missing on `command -v`'s authority alone, and that is a
    # finding a caller must see: an unreadable pins file used to return before
    # this point, which made `--box-only --findings-only` print `ruff is missing`
    # and exit 0 — and `agentbox create` then reported a box with no formatter as
    # ready, the exact case amendment A3 exists to prevent.
    #
    # `unknown` is left for the case where nothing is wrong by name and nothing
    # could be compared to a pin either: not `ok`, because no pin was checked.
    if [ $((N_MISSING + N_OFFPIN + N_UNREADABLE)) -gt 0 ]; then
        BOX_STATE="findings"
    elif [ "$PINS_READABLE" -eq 0 ]; then
        BOX_STATE="unknown"
    else
        BOX_STATE="ok"
    fi
}

# ---------------------------------------------------------------------------
# The box half, from the snapshot instead
# ---------------------------------------------------------------------------
#
# `--project-only` is the mode the launch paths use: it must not spend a dozen
# `--version` calls in front of every brief. The snapshot is written at the end
# of provisioning, and provisioning re-runs at every start, so on a box that has
# been started since it was written it is current.
SNAPSHOT_AT=""
snapshot_box() {
    local raw recorded="unknown"
    BOX_STATE="unknown"
    [ -r "$SNAPSHOT_FILE" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    raw=$(jq -r '.state // "unknown"' "$SNAPSHOT_FILE" 2>/dev/null) || return 0
    case "$raw" in ok|findings|unknown) recorded="$raw" ;; *) return 0 ;; esac
    raw=$(jq -r '.generated_at // ""' "$SNAPSHOT_FILE" 2>/dev/null)
    case "$raw" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) SNAPSHOT_AT="$raw" ;;
    esac
    # EVERY row, not only the findings: the project half compares the project's
    # specifiers against these versions, so a snapshot cut down to what is wrong
    # would leave `--project-only` — the mode every launch path uses — unable to
    # say that anything matches or differs at all.
    #
    # Each field validated by shape before it is printed or compared: the file
    # is written by root in the guest, but it is still a file, and R4 does not
    # make an exception for a file we wrote ourselves.
    raw=$(jq -r '
        .tools[]? | [.name, (.pinned // "-"), (.found // "-"), .state, (.path // "-")] | join("|")
    ' "$SNAPSHOT_FILE" 2>/dev/null)
    local name pin found state kept=""
    while IFS='|' read -r name pin found state _; do
        [ -n "$name" ] || continue
        valid_token "$name" || continue
        valid_token "$pin" || pin="-"
        valid_token "$found" || found="-"
        case "$state" in
            ok)         N_OK=$((N_OK + 1)) ;;
            missing)    N_MISSING=$((N_MISSING + 1)) ;;
            off_pin)    N_OFFPIN=$((N_OFFPIN + 1)) ;;
            unreadable) N_UNREADABLE=$((N_UNREADABLE + 1)) ;;
            *)          continue ;;
        esac
        kept="${kept}${name}|${pin}|${found}|${state}|-
"
    done <<EOF
$raw
EOF
    BOX_ROWS="$kept"
    if [ $((N_MISSING + N_OFFPIN + N_UNREADABLE)) -gt 0 ]; then
        BOX_STATE="findings"
    elif [ "$recorded" = "findings" ]; then
        # The snapshot says something is wrong and not one row survived
        # validation. `ok` would be a lie and `findings` would name nothing, so
        # the honest answer is that the box half is not known.
        BOX_STATE="unknown"
    else
        BOX_STATE="$recorded"
    fi
}

# ---------------------------------------------------------------------------
# The project half
# ---------------------------------------------------------------------------

P_MISMATCH=0
P_UNPARSEABLE=0
P_UNKNOWN=0
PROJECT_TEXT=""
PROJECT_JSON="[]"

# The box's versions, as the one JSON argument project-pins.py takes. Assembled
# from validated tokens only, which is what makes printf safe here.
box_versions_json() {
    local name pin found state path first=1
    printf '{'
    while IFS='|' read -r name pin found state path; do
        [ -n "$name" ] || continue
        [ "$found" = "-" ] && continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '"%s":"%s"' "$name" "$found"
    done <<EOF
$BOX_ROWS
EOF
    printf '}'
}

scan_project() {
    local counts out
    local -a extra=()
    command -v python3 >/dev/null 2>&1 || return 0
    [ -r "$PROJECT_PINS" ] || return 0
    counts=$(mktemp) || return 0
    [ "$FINDINGS_ONLY" -eq 0 ] || extra=(--findings-only)
    if [ "$AS_JSON" -eq 1 ]; then
        out=$(python3 "$PROJECT_PINS" --json --counts-file "$counts" \
                  --box-versions "$(box_versions_json)" "$ABX_WORK_DIR" 2>/dev/null)
        # A partial answer is not spliced into a JSON object: an array is an
        # array, or this half is empty and says nothing.
        case "$out" in '['*']') PROJECT_JSON="$out" ;; esac
    else
        PROJECT_TEXT=$(python3 "$PROJECT_PINS" ${extra[@]+"${extra[@]}"} --counts-file "$counts" \
                           --box-versions "$(box_versions_json)" "$ABX_WORK_DIR" 2>/dev/null)
    fi
    local key value
    while IFS='=' read -r key value; do
        case "$value" in ''|*[!0-9]*) continue ;; esac
        case "$key" in
            mismatch)    P_MISMATCH="$value" ;;
            unparseable) P_UNPARSEABLE="$value" ;;
            unknown)     P_UNKNOWN="$value" ;;
        esac
    done < "$counts"
    rm -f "$counts"
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

state_word() {
    case "${1:?}" in
        ok)         printf 'ok' ;;
        missing)    printf 'MISSING' ;;
        off_pin)    printf 'OFF-PIN' ;;
        unreadable) printf 'UNREADABLE' ;;
        *)          printf '%s' "$1" ;;
    esac
}

# One finding, as a sentence, so that a caller can prefix it with NOT READY or
# WARNING and the line still reads. `agentbox create` and `agentbox start` both
# do exactly that.
finding_line() {
    local name="$1" pin="$2" found="$3" state="$4"
    case "$state" in
        missing)    printf '%s is missing' "$name" ;;
        off_pin)    printf '%s is %s' "$name" "$found" ;;
        unreadable) printf '%s is installed but does not report a version this box can read' "$name" ;;
    esac
    [ "$pin" = "-" ] || printf ' (pinned %s)' "$pin"
    printf '\n'
}

print_box_table() {
    local name pin found state path
    printf 'TOOL            PINNED        FOUND         STATE\n'
    while IFS='|' read -r name pin found state path; do
        [ -n "$name" ] || continue
        [ "$pin" = "-" ] && pin='(unpinned)'
        printf '%-16s%-14s%-14s%s\n' "$name" "$pin" "$found" "$(state_word "$state")"
    done <<EOF
$BOX_ROWS
EOF
}

print_box_findings() {
    local name pin found state path
    # A live sweep that could not read its own pins compared nothing to a pin,
    # and that is a finding about the box, so it goes where the findings go:
    # `create` prefixes it NOT READY, `start` prefixes it WARNING, and neither
    # can print "every baseline tool is at its pin" over it. The snapshot path
    # (`--project-only`) never reads the pins file, so it never says this.
    [ "$PROJECT_ONLY" -eq 1 ] || [ "$PINS_READABLE" -eq 1 ] \
        || printf 'the toolchain pin file could not be read, so no tool could be checked against a pin\n'
    while IFS='|' read -r name pin found state path; do
        [ -n "$name" ] || continue
        case "$state" in missing|off_pin|unreadable) ;; *) continue ;; esac
        finding_line "$name" "$pin" "$found" "$state"
    done <<EOF
$BOX_ROWS
EOF
}

summary_line() {
    local box_part proj_part
    case "$BOX_STATE" in
        unknown)
            if [ "$PROJECT_ONLY" -eq 1 ]; then
                box_part="box-side snapshot unavailable; run 'agentbox toolcheck <repo>' for a live sweep"
            else
                box_part="the pins file could not be read, so no tool could be checked"
            fi
            ;;
        ok)
            box_part='every baseline tool is at its pin'
            [ "$PROJECT_ONLY" -eq 1 ] && box_part="the box-side snapshot says every baseline tool is at its pin"
            ;;
        *)
            box_part="${N_MISSING} missing, ${N_OFFPIN} off-pin"
            [ "$N_UNREADABLE" -eq 0 ] || box_part="${box_part}, ${N_UNREADABLE} unreadable"
            [ "$PROJECT_ONLY" -eq 0 ] || box_part="${box_part} (from the snapshot${SNAPSHOT_AT:+ recorded ${SNAPSHOT_AT}})"
            # The table's PINNED column reads `(unpinned)` for every row when the
            # pins file could not be read, which on its own looks like a box that
            # pins nothing. Say which it is.
            [ "$PINS_READABLE" -eq 1 ] \
                || box_part="${box_part}; the pins file could not be read, so no version was compared to a pin"
            ;;
    esac
    if [ "$BOX_ONLY" -eq 1 ]; then
        printf 'toolcheck: %s\n' "$box_part"
        return 0
    fi
    if [ "$P_MISMATCH" -gt 0 ]; then
        proj_part="${P_MISMATCH} project mismatch"
        [ "$P_MISMATCH" -eq 1 ] || proj_part="${proj_part}es"
    elif [ "$BOX_STATE" = "unknown" ] && [ "$P_UNKNOWN" -gt 0 ]; then
        # Not "nothing differs": nothing could be COMPARED, which is a different
        # answer and the one an operator has to be told apart from a clean box.
        proj_part="${P_UNKNOWN} project pin(s) this box's own versions are not known well enough to compare"
    else
        proj_part='this repository pins nothing differently'
        [ "$P_UNPARSEABLE" -eq 0 ] || proj_part="${proj_part} (${P_UNPARSEABLE} unreadable)"
    fi
    printf 'toolcheck: %s; %s\n' "$box_part" "$proj_part"
}

# The whole report, on stdout, returning the status the caller exits with. It is
# a function so that the scrub can be one pipe around all of it.
report() {
    if [ "$AS_JSON" -eq 1 ]; then
        print_json
        report_status
        return
    fi
    # The box half first. `--project-only` prints its findings rather than a
    # table: the table is a live sweep's answer, and printing the snapshot's rows
    # in the same shape would read as one.
    local box_text
    if [ "$PROJECT_ONLY" -eq 1 ] || [ "$FINDINGS_ONLY" -eq 1 ]; then
        box_text=$(print_box_findings)
    else
        box_text=$(print_box_table)
    fi
    [ -z "$box_text" ] || printf '%s\n' "$box_text"

    if [ "$FINDINGS_ONLY" -eq 1 ]; then
        # Nothing at all when there is nothing to say: this is what goes in
        # front of a brief, and a clean box adds no words to one. No heading
        # either — the caller's section owns that (agent-run.sh writes the
        # `## Toolchain` heading, claude-session.sh prints it under its own).
        [ -z "$PROJECT_TEXT" ] || printf '%s\n' "$PROJECT_TEXT"
        # One exception to "nothing when there is nothing to say": when the box
        # half is not known, the project's pins were not compared to anything,
        # and silence here is a false answer rather than no answer. Convention 4
        # has already told the agent that any difference is printed above its
        # brief, so a repository pinning node 22 against a box at node 24 would
        # read as agreement. This is a finding about the REPORT, which is why it
        # belongs in the brief; summary_line already composes the sentence.
        [ "$BOX_STATE" != "unknown" ] || [ "$P_UNKNOWN" -eq 0 ] || summary_line
        report_status
        return
    fi
    if [ -n "$PROJECT_TEXT" ]; then
        [ -z "$box_text" ] || printf '\n'
        printf '%s\n' "$PROJECT_TEXT"
        printf '\n'
    elif [ -n "$box_text" ]; then
        printf '\n'
    fi
    summary_line
    report_status
}

# ok, findings, project_mismatch or unknown — the box half first, because a box
# that is not at baseline is the more urgent fact and the one a script gates on.
report_state() {
    case "$BOX_STATE" in
        findings) printf 'findings'; return 0 ;;
        unknown)  printf 'unknown';  return 0 ;;
    esac
    if [ "$BOX_ONLY" -eq 0 ] && [ "$P_MISMATCH" -gt 0 ]; then
        printf 'project_mismatch'
    else
        printf 'ok'
    fi
}

report_status() {
    [ "$BOX_STATE" = "findings" ] && return 10
    # A LIVE sweep that could not read its own pins verified nothing, so 0 —
    # which every caller reads as "at baseline" — is the one answer it must not
    # give. 1 is this script's own word for "something it could not do at all"
    # (see the header), and the launch paths turn it into a NOTE rather than a
    # readiness claim, which is the honest shape: the box may be fine, and
    # nobody checked. Before the mismatch test on purpose: 11 says the box is
    # clean and the repository differs, and the box is not known clean here.
    #
    # The snapshot path keeps 0. An absent snapshot is the ordinary fail-soft
    # case for `--project-only`, which runs in front of every brief, and the
    # findings-only arm above now says so in words instead.
    if [ "$BOX_STATE" = "unknown" ] && [ "$PROJECT_ONLY" -eq 0 ]; then
        return 1
    fi
    if [ "$BOX_ONLY" -eq 0 ] && [ "$P_MISMATCH" -gt 0 ]; then
        return 11
    fi
    return 0
}

# A validated token as a JSON string, or null for the `-` placeholder. `null`
# means "nobody could answer", which is the same convention status --json uses.
json_or_null() {
    if [ "$1" = "-" ]; then printf 'null'; else printf '"%s"' "$1"; fi
}

# Assembled here rather than in Python because every value in it is either a
# literal or a token that has already been through valid_token/valid_path —
# which is what makes a printf-built object safe to read as a contract.
print_json() {
    local name pin found state path first=1
    printf '{"generated_at":"%s","pins_file":"%s","state":"%s",' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PINS_FILE" "$(report_state)"
    printf '"counts":{"ok":%s,"missing":%s,"off_pin":%s,"unreadable":%s,"project_mismatch":%s,"unparseable":%s},' \
        "$N_OK" "$N_MISSING" "$N_OFFPIN" "$N_UNREADABLE" "$P_MISMATCH" "$P_UNPARSEABLE"
    printf '"tools":['
    while IFS='|' read -r name pin found state path; do
        [ -n "$name" ] || continue
        [ "$first" -eq 1 ] || printf ','
        first=0
        printf '{"name":"%s","pinned":%s,"found":%s,"state":"%s","path":%s}' \
            "$name" "$(json_or_null "$pin")" "$(json_or_null "$found")" \
            "$state" "$(json_or_null "$path")"
    done <<EOF
$BOX_ROWS
EOF
    printf '],"project":%s}\n' "$PROJECT_JSON"
}

# ---------------------------------------------------------------------------
# Run it
# ---------------------------------------------------------------------------

if [ "$PROJECT_ONLY" -eq 1 ]; then
    snapshot_box
else
    sweep_box
fi
[ "$BOX_ONLY" -eq 1 ] || scan_project

# The scrub is not optional and there is no unscrubbed fallback: what this
# prints is a dozen programs' own output and a scan of the host's disk, and the
# rule is that the redaction happens in the guest so the unredacted bytes never
# make the trip. `pipefail` is what keeps 10 and 11 alive across the pipe.
[ -r "$RUN_FORMAT" ] || die "${RUN_FORMAT} is missing; refusing to print guest output unscrubbed"
command -v python3 >/dev/null 2>&1 || die "python3 is missing; refusing to print guest output unscrubbed"
report | python3 "$RUN_FORMAT" --scrub-stdin
exit $?
