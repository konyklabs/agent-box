#!/bin/bash
#
# agent-box — one JSON line describing this box, for `agentbox status`.
#
# Runs in the guest, as the unprivileged guest user. ONE invocation per running
# box per refresh: `agentbox status --watch` redraws every few seconds, and a
# status display that costs three `limactl shell` round trips per box is a
# status display nobody leaves running.
#
# It prints the object the host wraps in `name`, `instance` and `repo` — the
# three things the host already knows and the guest has no business being told.
# Everything printed has been through the scrub in guest/run-format.py, which
# is why the assembly happens here rather than on the host: the unscrubbed
# bytes must not cross the terminal boundary in the first place.

set -uo pipefail

die() { printf 'box-status: %s\n' "$*" >&2; exit 1; }

# --text prints the same facts as one human line instead of one JSON object.
# Both come out of the same place for the same reason: whichever the host asks
# for, the scrub has already happened by the time it crosses.
MODE="--box-json"
case "${1:-}" in
    --text) MODE="--box-text" ;;
    "")     ;;
    *)      die "usage: box-status.sh [--text]" ;;
esac

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# --- the CLI's version, from a cache -------------------------------------
#
# `status --watch` calls this every few seconds. Spawning the CLI each time to
# ask its version costs a process in the guest per refresh, competing with the
# agent this is supposed to be observing. The version only changes when
# `agentbox update` changes it, and that command removes this file.
CLAUDE_VERSION=""
VERSION_CACHE="${ABX_STATE_DIR}/claude-version"
if [ -r "$VERSION_CACHE" ]; then
    CLAUDE_VERSION=$(head -1 "$VERSION_CACHE" 2>/dev/null)
fi
if [ -z "$CLAUDE_VERSION" ] && command -v claude >/dev/null 2>&1; then
    CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
    if [ -n "$CLAUDE_VERSION" ]; then
        abx_private_dir "$ABX_STATE_DIR" 2>/dev/null || true
        printf '%s\n' "$CLAUDE_VERSION" > "$VERSION_CACHE" 2>/dev/null || true
    fi
fi

# --- the egress mode --------------------------------------------------------
#
# The `firewall` field is the MODE now: deny, observe, open or unknown. It is
# derived from the LIVE RULESET by guest/egress-mode.sh, never from the mode
# file — a file is what somebody asked for, and reporting it as fact is how a
# box that permits everything comes to be described as denying.
#
# When the file and the ruleset disagree, the answer is `unknown` and
# `firewall_detail` says what both of them said. Unknown is the honest answer
# to "which of these two do you believe", and picking one silently is not.
FIREWALL="unknown"
FIREWALL_DETAIL=""
if MODE_LINE=$("${ABX_LIB_DIR}/egress-mode.sh" 2>/dev/null); then
    _live=$(printf '%s' "$MODE_LINE" | sed -n 's/.*live=\([a-z]*\).*/\1/p')
    _agree=$(printf '%s' "$MODE_LINE" | sed -n 's/.*agree=\([a-z]*\).*/\1/p')
    FIREWALL_DETAIL=$(printf '%s' "$MODE_LINE" | sed -n 's/.*detail=//p')
    # A DISAGREEMENT is unknown. A detail on its own is not: a box with no mode
    # file has an unambiguous ruleset and something worth mentioning, and
    # reporting `unknown` about it would be less true rather than more careful.
    if [ "${_agree:-no}" = "yes" ]; then
        FIREWALL="${_live:-unknown}"
        # And the JSON carries no detail in this case, even when the reader had
        # something to say. The contract is that `firewall_detail` appears only
        # when the mode is unknown or the two sources conflict; a note about a
        # missing mode file is information for a person, and it is printed by
        # `agentbox egress` where a person is reading. Putting it in the
        # contract would make a healthy box look like it had a problem.
        FIREWALL_DETAIL=""
    else
        FIREWALL="unknown"
    fi
fi

# --- orphaned runs --------------------------------------------------------
#
# A run whose process died without its EXIT trap says `running` for ever. This
# is one of the three places that reconciles it, and the cheapest: `status` is
# the command someone runs to find out what is going on.
#
# STDOUT is redirected, not only stderr: this script's stdout IS the JSON object
# the host splices into `status --json`, so one stray line from anything called
# here corrupts the document. `reconcile` prints nothing today; the redirect is
# what makes that a property of this file rather than a fact about that one.
"${ABX_LIB_DIR}/run-ctl.sh" reconcile >/dev/null 2>&1 || true

# --- tmux sessions ---------------------------------------------------------
#
# Already scrubbed and control-stripped by run-format.py, and built with jq
# before that, so what arrives here is well-formed JSON. An empty string is
# passed straight through rather than being turned into `[]`: run-format.py
# reports an unreadable list as null, which a consumer can tell apart from a
# box that genuinely has no sessions.
#
# Which is why the no-tmux arm is the empty string as well. `[]` there would
# claim this box has no sessions where the truth is that nobody could look — the
# same lie the host's not-running literal used to tell about a box it never
# reached, and the distinction the null/`[]` rule exists to keep usable.
SESSIONS=''
if command -v tmux >/dev/null 2>&1; then
    SESSIONS=$("${ABX_LIB_DIR}/run-ctl.sh" sessions --json 2>/dev/null) || SESSIONS=''
fi

# --- what earlier runs left running ----------------------------------------
#
# The resource ledger's own reader, in the guest, as JSON rows; run-format.py
# folds them into the `leftovers` object and `agentbox leftovers` prints the same
# rows, so the two can never disagree about what is still up.
#
# The empty string is deliberate in both arms, for the reason above: a box whose
# ledger reader is missing (a box provisioned by an older checkout) or failed
# reports `leftovers: null`, and a box that really has nothing left running
# reports zeros.
LEFTOVERS=''
if [ -x "${ABX_LIB_DIR}/run-ledger.sh" ]; then
    LEFTOVERS=$("${ABX_LIB_DIR}/run-ledger.sh" survivors --json 2>/dev/null) || LEFTOVERS=''
fi

# --- the toolchain snapshot ------------------------------------------------
#
# Root writes it at the end of provisioning, and provisioning re-runs at every
# start, so on a box started since this checkout landed it is current. Read from
# the file rather than swept live for the same reason the CLI version is cached
# above: `status --watch` ticks every few seconds, and a dozen `--version` calls
# per tick would compete with the agent this is supposed to be observing.
#
# The read is CAPPED at 4096 bytes. The four fields the status object takes from
# it are the first of the document (the snapshot's own `tools` array follows
# them), and a document too long for the cap is cut, fails to parse, and reports
# `toolchain: null` — unanswered, never half-read.
TOOLCHAIN=''
if [ -r /var/lib/agent-box/toolcheck.json ]; then
    TOOLCHAIN=$(head -c 4096 /var/lib/agent-box/toolcheck.json 2>/dev/null) || TOOLCHAIN=''
fi

# --- the run, the totals, and the scrub ------------------------------------
exec python3 "${ABX_LIB_DIR}/run-format.py" "$MODE" \
    --claude-version "$CLAUDE_VERSION" \
    --firewall "$FIREWALL" \
    --firewall-detail "$FIREWALL_DETAIL" \
    --sessions "$SESSIONS" \
    --leftovers "$LEFTOVERS" \
    --toolchain "$TOOLCHAIN"
