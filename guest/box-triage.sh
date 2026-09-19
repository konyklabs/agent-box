#!/bin/bash
#
# agent-box — one JSON line (or one padded text fragment) saying whether this box
# can be paused or removed, and what exists only inside it, for `agentbox triage`.
#
# Runs in the guest, as the unprivileged guest user, once per running box per
# triage. Shaped like box-status.sh, and here for the same two reasons: the
# verdict needs the run state, which is a guest fact, and everything printed has
# to be scrubbed before it crosses to the host's terminal, which happens in
# guest/run-format.py.
#
# The host's own facts arrive as ARGUMENTS — a one-word scarcity and a few counts
# — so that nothing here reaches back to the host for anything. None of them is a
# host path: `--bench yes|no|stale`, never the bench's location. The reverse
# direction is the careful one, and it is one line long: the host reads back only
# the `boxonly=… bytes=…` line run-format.py prints last, validated by `case`.
#
# Every gatherer below is allowed to fail. A missing `docker`, an unreadable
# state directory, a `run-ledger.sh` from a checkout that does not have one yet:
# each lands as `null` in the facts object, which run-format.py reports as "not
# known" rather than as zero. A triage that cannot describe one box still has to
# describe the rest of the fleet.

set -uo pipefail

die() { printf 'box-triage: %s\n' "$*" >&2; exit 1; }

SCARCE="none"
REPO_STATE="ok"
BENCH="no"
UNEXPORTED=""
HANDOFFS=""
REQUESTS=""
TEXT_MODE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --scarce)
            case "${2:-}" in
                none|disk|compute|both) SCARCE="$2" ;;
                *) die "--scarce takes none, disk, compute or both" ;;
            esac
            shift 2 ;;
        --repo)
            case "${2:-}" in
                ok|missing|not-git) REPO_STATE="$2" ;;
                *) die "--repo takes ok, missing or not-git" ;;
            esac
            shift 2 ;;
        --bench)
            case "${2:-}" in
                yes|no|stale) BENCH="$2" ;;
                *) die "--bench takes yes, no or stale" ;;
            esac
            shift 2 ;;
        --unexported-commits) UNEXPORTED="${2:-}"; shift 2 ;;
        --handoffs-unread)    HANDOFFS="${2:-}";   shift 2 ;;
        --requests-queued)    REQUESTS="${2:-}";   shift 2 ;;
        --text) TEXT_MODE=true; shift ;;
        *) die "usage: box-triage.sh --scarce W [--repo W] [--bench W] [--unexported-commits N] [--handoffs-unread N] [--requests-queued N] [--text]" ;;
    esac
done

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# Digits, or `null` for jq. Every count below goes through it, including the
# host's: an argument this script did not produce is checked like anything else.
jnum() { case "${1:-}" in ''|*[!0-9]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# `du -sk` in bytes, or empty. A directory that is not there is not an error:
# ~/.claude does not exist until Claude Code has run once.
dir_bytes() {
    local kib
    [ -d "${1:-}" ] || return 0
    kib=$(du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}')
    case "$kib" in ''|*[!0-9]*) return 0 ;; esac
    printf '%s' "$((kib * 1024))"
}

# --- the run, reconciled first ---------------------------------------------
#
# The same source box-status.sh uses, in the same order, so that triage and
# status can never disagree about what this box is doing. A run whose process
# died without its EXIT trap says `running` for ever until something reconciles
# it, and a box reported `active` on the strength of that is a box nobody dares
# stop.
"${ABX_LIB_DIR}/run-ctl.sh" reconcile >/dev/null 2>&1 || true
RUN_STATE=$("${ABX_LIB_DIR}/run-ctl.sh" state 2>/dev/null | tr -d '\r\n')

# --- the standing session --------------------------------------------------
#
# Item 8's sensor, when this checkout has it. A box whose standing session is
# working or waiting is not idle, whatever the runs say — stopping it would end
# the session, which is the failure this reason code exists to prevent.
STANDING=""
if [ -x "${ABX_LIB_DIR}/channel.sh" ]; then
    STANDING=$("${ABX_LIB_DIR}/channel.sh" standing-state 2>/dev/null | tr -d '\r\n')
fi

# --- the working tree ------------------------------------------------------
#
# `git status` runs HERE and never on the host: `.git/config`, `.git/hooks` and
# `.gitattributes` in the mounted repository are writable from inside this box,
# and `status` runs `core.fsmonitor` and clean filters. Inside the box that is
# the box's own business; on the host it would be arbitrary execution as the
# operator. See docs/decisions.md.
DIRTY=""
if git -C "$ABX_WORK_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    DIRTY=$(git -C "$ABX_WORK_DIR" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
fi

# --- what a destroy would take ---------------------------------------------
#
# The precise list, not the loose one. Commits on `agent/*` branches and the
# working tree are NOT here: /work is the host's own directory. What is here is
# what exists on no host disk at all — run transcripts, Claude Code's state,
# repositories somebody cloned into the box's home, and docker volumes.
STATE_BYTES=$(dir_bytes "$ABX_STATE_DIR")
CLAUDE_BYTES=$(dir_bytes "$ABX_CLAUDE_CONFIG_DIR")

TRANSCRIPTS=0
if [ -d "$ABX_RUNS_DIR" ]; then
    for _d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${_d}meta.json" ] || continue
        TRANSCRIPTS=$((TRANSCRIPTS + 1))
    done
fi

# Depth-bounded on purpose: this runs while an agent may be working, and a full
# walk of a home directory with a node_modules tree in it is not a free read.
GUEST_REPOS=$(find "$HOME" -maxdepth 3 -name .git -not -path "${ABX_WORK_DIR}/*" 2>/dev/null \
    | wc -l | tr -d ' ')

# Docker, and only when the daemon actually answers: `command -v docker` is true
# in a box where the socket is not there, and a hang here would hold up the
# whole fleet report.
DOCKER_IMAGES=""
DOCKER_VOLUMES=""
if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then
    DOCKER_IMAGES=$(docker image ls -q 2>/dev/null | wc -l | tr -d ' ')
    DOCKER_VOLUMES=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
fi

# --- the firewall ----------------------------------------------------------
#
# From the LIVE ruleset, like status: the mode file is what somebody asked for.
FIREWALL="unknown"
if _mode_line=$("${ABX_LIB_DIR}/egress-mode.sh" 2>/dev/null); then
    _live=$(printf '%s' "$_mode_line" | sed -n 's/.*live=\([a-z]*\).*/\1/p')
    _agree=$(printf '%s' "$_mode_line" | sed -n 's/.*agree=\([a-z]*\).*/\1/p')
    if [ "${_agree:-no}" = "yes" ]; then
        FIREWALL="${_live:-unknown}"
    fi
fi

# --- what earlier runs left running ----------------------------------------
#
# Item 4's ledger, when this checkout has it. Validated as JSON before it is
# spliced: an unparsable answer would take the whole facts object down with it,
# and then this box would report nothing at all.
LEFTOVERS="null"
if [ -x "${ABX_LIB_DIR}/run-ledger.sh" ]; then
    _left=$("${ABX_LIB_DIR}/run-ledger.sh" survivors --json 2>/dev/null)
    if [ -n "$_left" ] && printf '%s' "$_left" | jq -e . >/dev/null 2>&1; then
        LEFTOVERS="$_left"
    fi
fi

# --- one facts object, one python start ------------------------------------
#
# Built with jq rather than by hand, because several of these are numbers and one
# hand-built object with an empty count in it is a syntax error that reports the
# box as silent. Without jq there is no facts object and run-format.py says so:
# fail-soft, with every key present, is the contract.
FACTS=$(jq -n \
    --argjson text "$TEXT_MODE" \
    --arg scarce "$SCARCE" \
    --arg repo "$REPO_STATE" \
    --arg bench "$BENCH" \
    --arg run_state "$RUN_STATE" \
    --arg standing "$STANDING" \
    --arg firewall "$FIREWALL" \
    --arg as_of "$(abx_now_iso)" \
    --argjson unexported_commits "$(jnum "$UNEXPORTED")" \
    --argjson handoffs_unread "$(jnum "$HANDOFFS")" \
    --argjson requests_queued "$(jnum "$REQUESTS")" \
    --argjson dirty_files "$(jnum "$DIRTY")" \
    --argjson state_bytes "$(jnum "$STATE_BYTES")" \
    --argjson claude_state_bytes "$(jnum "$CLAUDE_BYTES")" \
    --argjson transcripts "$(jnum "$TRANSCRIPTS")" \
    --argjson guest_repos "$(jnum "$GUEST_REPOS")" \
    --argjson docker_images "$(jnum "$DOCKER_IMAGES")" \
    --argjson docker_volumes "$(jnum "$DOCKER_VOLUMES")" \
    --argjson leftovers "$LEFTOVERS" \
    '{text:$text, scarce:$scarce, repo:$repo, bench:$bench, run_state:$run_state,
      standing:$standing, firewall:$firewall, as_of:$as_of,
      unexported_commits:$unexported_commits, handoffs_unread:$handoffs_unread,
      requests_queued:$requests_queued, dirty_files:$dirty_files,
      state_bytes:$state_bytes, claude_state_bytes:$claude_state_bytes,
      transcripts:$transcripts, guest_repos:$guest_repos,
      docker_images:$docker_images, docker_volumes:$docker_volumes,
      leftovers:$leftovers}' 2>/dev/null)

exec python3 "${ABX_LIB_DIR}/run-format.py" --box-triage --triage-facts "$FACTS"
