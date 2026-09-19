#!/bin/bash
#
# agent-box — the per-run resource ledger: what a run started, what it closed,
# and what outlived it.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# guest/agent-run.sh around a run (baseline before the CLI, a sampler while it
# works, one sweep after it), by guest/box-status.sh for `agentbox status`, and
# by `agentbox leftovers` — both of those through the `survivors` subcommand.
#
# Usage:
#   run-ledger.sh baseline  <runid>
#   run-ledger.sh observe   <runid> --pgid N [--quiet]
#   run-ledger.sh sweep     <runid> --pgid N [--spare P[,P...]]
#   run-ledger.sh survivors [--json]
#
# The ledger is ~/.agent-box/runs/<runid>/owned.jsonl: one JSON object per line,
# five keys always present (ts, phase, kind, value, detail), appended and never
# rewritten, so a hard kill cannot corrupt it. It stays in the guest home and
# never on the mount, because `detail` carries command lines the model chose and
# /work is the host's disk.
#
#   phase  baseline  what was already there before the run started. Evidence
#                    only: it answers "why did the run think it owned 5173",
#                    and every reader below drops these lines rather than
#                    re-doing the subtraction the writer already did.
#          observed  a resource this run started, baseline-subtracted already.
#          closed    the sweep stopped or removed it.
#          survived  it was still there when the sweep had finished.
#          swept     one line per completed sweep. Its presence is what tells a
#                    reader that a run's survivor count is a settled fact
#                    rather than an absence of information.
#   kind   proc | port | worktree | tmux, plus `clock` on the baseline's one
#          bookkeeping line. The domain is open on purpose — a container class
#          is a follow-up — so every reader tolerates a kind it does not know.
#
# Two things this file deliberately will not do:
#
#   - a worktree is never pruned, only removed by path. Git's pruning verb takes
#     no path and removes the administrative entry of EVERY worktree whose
#     directory is missing, which inside this box includes the host-side bench:
#     its path exists on the host and not here, and its entry lives in
#     /work/.git/worktrees on the mount, which this box can write. A worktree
#     that will not come out is reported and left where it is.
#   - a process whose start time cannot be read is never signalled, and never
#     hidden either: it is reported as a survivor whose ownership is
#     `unverifiable`. A pid is not an identity — the pid recorded during a run
#     and the pid of that number after it are the same number and may be
#     different processes — so the only thing that makes a kill safe is the
#     start time, and where that is unreadable there is nothing to be safe on.

set -uo pipefail

die() { printf 'run-ledger: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# Before the first write, not after: the ledger and the markers beside it are
# 600 and the run directory 700, and a mkdir under the inherited umask would
# leave them readable to anything else running in the box.
umask 077

# The writer's half of the caps run-format.py's reader enforces again
# (PATH_LIMIT 200, DETAIL_LIMIT 120). Capped at both ends because either side
# alone is one upgrade away from being the only one.
VALUE_LIMIT=200
DETAIL_LIMIT=120

# One observe pass records at most this many NEW resources and one survivors
# scan reports at most this many rows. Both bounds are what keeps a ledger a
# ledger rather than a log of an agent's afternoon.
PASS_ROW_CAP=200
SURVIVOR_ROW_CAP=200

# How many processes the marker scan will look at before it stops. A box runs
# tens of processes; the cap means a fork bomb inside the box cannot turn a
# sweep into a walk of every pid on it.
MARKED_SCAN_CAP=500

# The separator inside the lines this script passes between its own functions.
# ASCII 28, the file separator, produced by printf rather than written as an
# escape so it is one byte here and in jq's `--arg`. Every value written or read
# below has its control characters removed, so no value can carry this byte and
# split a line of its own — the same reason run-ctl.sh's session list uses a
# real tab. Not ASCII 1: bash uses that byte internally to mark quoting, and a
# string containing it comes out of a word expansion with the byte eaten
# (measured on bash 3.2.57, where `IFS=$'\001' read` splits nothing).
FS=$(printf '\034')

# How long each signal in the sweep's ladder is given before the next one.
# Named rather than inline so the wait is one fact and not three.
WAIT_INT=5
WAIT_TERM=3
WAIT_KILL=2

# ---------------------------------------------------------------------------
# The ledger
# ---------------------------------------------------------------------------

# Control characters out, length capped. A value is an identity — a pid, a port
# reference, a worktree path, a tmux session name — and the last two are chosen
# by the agent. A newline in one would split a JSONL record in two and a tab or
# this file's own separator would split an internal line; all of them are
# removed here, at the one place that writes a value, so every reader further
# down can be line-based. A path that really does contain a control character
# therefore appears in the ledger without it, which is why nothing is ever
# REMOVED by matching a ledger value against the filesystem: the sweep matches
# against git's and tmux's own lists, and a value that has been stripped simply
# does not match, and is reported instead.
ledger_clean() {
    local s="${1:-}" limit="${2:?}"
    s=$(printf '%s' "$s" | tr -d '\000-\037\177')
    printf '%s' "${s:0:$limit}"
}

ledger_file() { printf '%s/owned.jsonl' "${1:?}"; }

# One line, appended. jq builds it, so a brace or a quote in a value cannot
# forge or erase a record, and every field stays a string: the readers compare
# values, none of them does arithmetic on one.
ledger_append() {
    local file="${1:?}" phase="${2:?}" kind="${3:?}" value="${4:-}" detail="${5:-}"
    local line
    value=$(ledger_clean "$value" "$VALUE_LIMIT")
    detail=$(ledger_clean "$detail" "$DETAIL_LIMIT")
    line=$(jq -cn --arg ts "$(abx_now_iso)" \
                  --arg phase "$phase" \
                  --arg kind "$kind" \
                  --arg value "$value" \
                  --arg detail "$detail" \
                  '{ts: $ts, phase: $phase, kind: $kind, value: $value,
                    detail: (if $detail == "" then null else $detail end)}' 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line" >> "$file" 2>/dev/null || return 1
    chmod 600 "$file" 2>/dev/null || true
    return 0
}

# The ledger reduced to one line per (kind,value): the LAST phase it reached,
# the FIRST timestamp it was seen at, and the newest detail. `fromjson?` skips a
# line that does not parse — a torn write, or a line somebody planted by hand —
# rather than failing the whole read, which is the idiom agent-run.sh already
# uses on the event stream.
#
# Lines are `phase FS kind FS value FS ts FS detail`.
ledger_state() {
    local file="${1:?}"
    [ -s "$file" ] || return 0
    jq -R -r -s --arg fs "$FS" '
        [ splits("\n") | fromjson? | select(type == "object") ]
        | map(select((.phase // "") != "baseline"))
        | reduce .[] as $r ({};
            (($r.kind // "") + "\u001c" + ($r.value // "")) as $k
            | .[$k] = {phase:  ($r.phase // ""),
                       kind:   ($r.kind // ""),
                       value:  ($r.value // ""),
                       ts:     ((.[$k].ts) // ($r.ts // "")),
                       detail: ($r.detail // "")})
        | to_entries[] | .value
        | [.phase, .kind, .value, .ts, .detail] | join($fs)
    ' "$file" 2>/dev/null || true
}

# The pairs the baseline recorded, as `kind FS value` lines.
ledger_baseline_pairs() {
    local file="${1:?}"
    [ -s "$file" ] || return 0
    jq -R -r -s --arg fs "$FS" '
        [ splits("\n") | fromjson? | select(type == "object") ]
        | map(select((.phase // "") == "baseline"))
        | .[] | [(.kind // ""), (.value // "")] | join($fs)
    ' "$file" 2>/dev/null || true
}

# Has this run been swept? One `grep` over the file rather than a second jq
# pass: the question is only whether the marker line exists.
ledger_was_swept() {
    local file="${1:?}"
    [ -s "$file" ] || return 1
    grep -q '"phase":"swept"' "$file" 2>/dev/null
}

# The box's uptime when the baseline was taken, in whole seconds.
ledger_baseline_uptime() {
    local file="${1:?}" v=""
    [ -s "$file" ] || return 1
    v=$(jq -R -r -s '
        [ splits("\n") | fromjson? | select(type == "object") ]
        | map(select((.phase // "") == "baseline" and (.kind // "") == "clock"))
        | last | (.value // "")
    ' "$file" 2>/dev/null) || return 1
    case "$v" in ''|null|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$v"
}

# Is this (kind,value) in that set of `kind FS value` lines?
set_has() {
    local set="${1:-}" kind="${2:?}" value="${3:-}"
    [ -n "$set" ] || return 1
    printf '%s\n' "$set" | grep -qxF "${kind}${FS}${value}"
}

# ---------------------------------------------------------------------------
# The clock, and what makes a process ours
# ---------------------------------------------------------------------------

# /proc/uptime's first field, truncated to a whole second. Truncated BEFORE it
# is compared: bash's integer test errors out on `12345.67`, and a guard that
# errors is a guard that is not there.
box_uptime_seconds() {
    local raw="" rest=""
    [ -r /proc/uptime ] || return 1
    read -r raw rest < /proc/uptime 2>/dev/null || return 1
    raw="${raw%%.*}"
    case "$raw" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$raw"
}

# Clock ticks per second, which is what /proc/<pid>/stat's start time is
# counted in. 100 on every Linux this project runs on; read rather than
# assumed, and assumed only if the read fails.
clock_ticks() {
    local t=""
    t=$(getconf CLK_TCK 2>/dev/null) || t=""
    case "$t" in ''|*[!0-9]*) t=100 ;; esac
    printf '%s\n' "$t"
}

# The start-time threshold in clock ticks: a process that started at or after
# this point started after the baseline, so it can be one of this run's.
#
# The baseline's uptime is a whole second and the threshold is therefore up to
# one second early, so a process that started in the same second as the
# baseline and just before it reads as ours. It would also have to be in the
# run's process group or carry the run's own marker to be a candidate at all,
# which is what makes that second harmless rather than a hole.
starttime_threshold() {
    local up="${1:-}" tck
    case "$up" in ''|*[!0-9]*) return 1 ;; esac
    tck=$(clock_ticks)
    printf '%s\n' "$((up * tck))"
}

# Is this pid one this run started? Three answers, not two:
#
#   yes       it started at or after the baseline, so it is this run's
#   no        it predates the baseline, so it is somebody else's
#   unproven  its start time cannot be read, or there is no baseline to
#             compare it with
#
# `unproven` exists because the alternative is to guess, and both guesses are
# bad: treating it as ours SIGKILLs a stranger (the operator's standing
# session, after a pid was recycled), and treating it as somebody else's
# reports a clean box while a listener from this run holds a port. So it is
# neither closed nor hidden — see the sweep.
proc_ownership() {
    local pid="${1:?}" threshold="${2:-}" started=""
    case "$threshold" in ''|*[!0-9]*) printf 'unproven\n'; return 0 ;; esac
    started=$(abx_proc_starttime "$pid") || { printf 'unproven\n'; return 0; }
    if [ "$started" -ge "$threshold" ]; then printf 'yes\n'; else printf 'no\n'; fi
}

# The command that pid is running, for the ledger's `detail`. From /proc, which
# is where the whole file's process facts come from; `ps` is the fallback so
# that the same code can be exercised on a host that has no /proc at all.
# Model-chosen text, so it is capped and control-stripped by the writer and it
# is in agent-run.sh's leak-check list.
proc_detail() {
    local pid="${1:?}" out=""
    if [ -r "/proc/${pid}/cmdline" ]; then
        out=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null) || out=""
    fi
    [ -n "$out" ] || out=$(ps -o args= -p "$pid" 2>/dev/null | head -1) || out=""
    printf '%s' "$out"
}

# The pids this run might own:
#
#   1. its process group. `set -m` in agent-run.sh gives the CLI its own group
#      whose pgid is the CLI's pid, and a group lives as long as one member
#      does, so `pgrep -g` still enumerates it after the leader has been
#      reaped — which is the state every sweep runs in.
#   2. the pids it recorded earlier and that are still alive: at sweep time the
#      CLI is gone and a descendant walk from it finds nothing, so what the
#      sampler saw is the only record of a process that has since reparented.
#   3. any process whose own env block names THIS run's events directory, which
#      is how a child that left the group with setsid is still found. Tested
#      with `grep -q` and nothing else (see the one line below): that file holds
#      the OAuth token of every process started with it, so its contents are
#      never read into a variable, never printed, and never matched loosely.
#
# A standing interactive session's processes are in none of these: they are in
# no run's process group and they carry the SESSION's directory, not a run's.
# That is what makes "a dev server the operator started is never swept" a
# property of the candidate set rather than a promise in a document.
candidate_pids() {
    local pgid="${1:?}" run_dir="${2:?}" threshold="${3:-}" observed="${4:-}"
    local out="" p d line kind value scanned=0
    case "$pgid" in ''|*[!0-9]*) pgid=0 ;; esac
    if [ "$pgid" -gt 1 ] && command -v pgrep >/dev/null 2>&1; then
        for p in $(pgrep -g "$pgid" 2>/dev/null); do
            case "$p" in ''|*[!0-9]*) continue ;; esac
            out="${out}${p}
"
        done
    fi
    # The ones already in the ledger, still alive.
    if [ -n "$observed" ]; then
        while IFS="$FS" read -r kind value; do
            [ "$kind" = "proc" ] || continue
            case "$value" in ''|*[!0-9]*) continue ;; esac
            kill -0 "$value" 2>/dev/null || continue
            out="${out}${value}
"
        done <<EOF
$observed
EOF
    fi
    # The marker scan, bounded three ways: the cap, the start-time guard before
    # the grep, and grep's own failure on a file this user may not read (which
    # is every process that is not ours).
    for d in /proc/[0-9]*; do
        [ "$scanned" -lt "$MARKED_SCAN_CAP" ] || break
        [ -d "$d" ] || continue
        scanned=$((scanned + 1))
        p="${d##*/}"
        [ "$(proc_ownership "$p" "$threshold")" = "yes" ] || continue
        grep -qzxF "AGENT_BOX_EVENTS_DIR=${run_dir}" "${d}/environ" 2>/dev/null || continue
        out="${out}${p}
"
    done
    [ -n "$out" ] || return 0
    printf '%s' "$out" | sort -u
}

# The candidate set minus the pids nobody may signal: this script, its own
# children, pid 1, and whatever the caller spared (the run's shell, its console
# tee, the sampler). Deepest-first, because a parent that is killed first
# reparents its children to pid 1 where the group no longer finds them.
expand_and_filter_pids() {
    local pids="${1:-}" spare="${2:-}" p q out="" expanded=""
    for p in $pids; do
        expanded="${expanded}$(abx_descendants_deepest_first "$p")
"
    done
    for p in $(printf '%s' "$expanded" | sort -u); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        [ "$p" -gt 1 ] || continue
        [ "$p" != "$$" ] || continue
        [ "$p" != "$PPID" ] || continue
        for q in $spare; do
            [ "$p" = "$q" ] && { p=""; break; }
        done
        [ -n "$p" ] || continue
        out="${out}${p}
"
    done
    [ -n "$out" ] || return 0
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The five classes, enumerated
# ---------------------------------------------------------------------------
#
# Each emits `kind FS value FS detail FS exempt` lines. `exempt` is 1 for a row
# that is recorded even when the baseline already had it, which is exactly one
# case: a port whose owning socket belongs to one of this run's own processes.
# The port was bound by this run whoever else was listening on it before.

# Is the socket table readable at all? An unreadable one is not an empty one,
# and the difference is a run that reports "nothing was left running" while a
# listener holds the port the next run needs.
sockets_readable() {
    [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ] || [ -r /proc/net/udp ] || [ -r /proc/net/udp6 ]
}

# inode -> pid for the candidate set only. One walk of each candidate's open
# file descriptors, never a walk of /proc: who the candidates are is the
# question this file has already answered.
candidate_sockets() {
    local pids="${1:-}" p fd target inode
    for p in $pids; do
        [ -d "/proc/${p}/fd" ] || continue
        for fd in /proc/"${p}"/fd/*; do
            target=$(readlink "$fd" 2>/dev/null) || continue
            case "$target" in
                socket:\[*\]) ;;
                *) continue ;;
            esac
            inode="${target#socket:[}"
            inode="${inode%]}"
            case "$inode" in ''|*[!0-9]*) continue ;; esac
            printf '%s %s\n' "$inode" "$p"
        done
    done
}

# Two independent sources, because either one alone has a hole:
#
#   (a) the socket's owning pid is one of this run's processes. Recorded even
#       when the baseline already had that port, because a port bound by this
#       run is this run's whoever was listening on it before.
#   (b) the port appeared since the baseline and belongs to no process this run
#       can see. That is what catches a double-forked daemon which reparented
#       to pid 1 and left the group behind.
collect_ports() {
    local pids="${1:-}" base="${2:-}" sockets proto port scope inode owner ref
    sockets=$(candidate_sockets "$pids")
    abx_listeners | while read -r proto port scope inode; do
        ref="${proto}:${port}"
        abx_valid_port_ref "$ref" || continue
        owner=""
        if [ -n "$sockets" ]; then
            owner=$(printf '%s\n' "$sockets" | awk -v i="$inode" '$1 == i { print $2; exit }')
        fi
        if [ -n "$owner" ]; then
            printf 'port%s%s%s%s%s%s\n' "$FS" "$ref" "$FS" "pid ${owner}, ${scope}" "$FS" 1
        elif ! set_has "$base" port "$ref"; then
            printf 'port%s%s%s%s%s%s\n' "$FS" "$ref" "$FS" "no owning process visible, ${scope}" "$FS" 0
        fi
    done
}

# Worktrees registered against the mounted repository. One command catches both
# a worktree under /work and one in the guest home, because both register in
# /work/.git/worktrees. The FIRST record is the main worktree and is always
# dropped, and so is anything equal to the mount itself.
collect_worktrees() {
    local base="${1:-}" line path="" branch="" first=1 raw
    raw=$(git -C "$ABX_WORK_DIR" worktree list --porcelain 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                path="${line#worktree }"
                branch=""
                if [ "$first" -eq 1 ]; then
                    first=0
                    path=""
                fi ;;
            "branch "*)
                branch="${line#branch refs/heads/}" ;;
            "")
                if [ -n "$path" ] && [ "$path" != "$ABX_WORK_DIR" ] \
                   && ! set_has "$base" worktree "$path"; then
                    printf '%s%s%s%s%s%s%s\n' \
                        worktree "$FS" "$path" "$FS" "${branch:+branch ${branch}}" "$FS" 0
                fi
                path=""
                branch="" ;;
        esac
    done <<EOF
$raw

EOF
}

# tmux sessions, minus the run's own pane, minus every session the operator has
# (a session directory under ~/.agent-box/sessions is what makes a session
# theirs), and minus the literal `shell`, which `agentbox shell` creates without
# a session directory and which is therefore a named blind spot rather than a
# guess.
collect_tmux() {
    local base="${1:-}" runid="${2:?}" name raw
    command -v tmux >/dev/null 2>&1 || return 0
    raw=$(tmux list-sessions -F '#{session_name}' 2>/dev/null) || return 0
    [ -n "$raw" ] || return 0
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" != "shell" ] || continue
        [ "$name" != "run-${runid}" ] || continue
        case "$name" in
            run-*) abx_valid_runid "${name#run-}" && continue ;;
        esac
        if abx_valid_session_name "$name" && [ -d "${ABX_SESSIONS_DIR}/${name}" ]; then
            continue
        fi
        set_has "$base" tmux "$name" && continue
        printf '%s%s%s%s%s%s%s\n' tmux "$FS" "$name" "$FS" "" "$FS" 0
    done <<EOF
$raw
EOF
}

collect_procs() {
    local pids="${1:-}" p
    for p in $pids; do
        printf '%s%s%s%s%s%s%s\n' proc "$FS" "$p" "$FS" "$(proc_detail "$p")" "$FS" 0
    done
}

# ---------------------------------------------------------------------------
# baseline
# ---------------------------------------------------------------------------

# What is already running, so that what the run leaves behind can be told from
# what was there all along. No `proc` baseline: it would be a list of every
# process in the box, and what the process class uses instead is the start-time
# guard, which needs one number rather than a list.
cmd_baseline() {
    local runid="${1:-}" dir file up tck kind value detail exempt
    [ -n "$runid" ] || die "usage: run-ledger.sh baseline <runid>"
    dir=$(abx_run_dir "$runid")
    [ -d "$dir" ] || die "no run directory for ${runid}"
    file=$(ledger_file "$dir")
    if [ ! -e "$file" ]; then
        : > "$file" 2>/dev/null || die "cannot write ${file}"
        chmod 600 "$file" 2>/dev/null || true
    fi

    up=$(box_uptime_seconds) || up=""
    tck=$(clock_ticks)
    if [ -n "$up" ]; then
        ledger_append "$file" baseline clock "$up" \
            "whole seconds of uptime; ${tck} clock ticks per second" \
            || printf 'run-ledger: NOTE: could not write the resource ledger\n'
    else
        printf 'run-ledger: NOTE: the box uptime is unreadable; this run will report processes it cannot prove it owns rather than stopping them\n'
    fi

    if sockets_readable; then
        # The baseline's own detail, not the enumerator's: with no candidate pids
        # to map a socket to, every row would otherwise read "no owning process
        # visible", which is true of the enumeration and misleading about sshd.
        collect_ports "" "" | while IFS="$FS" read -r kind value detail exempt; do
            ledger_append "$file" baseline "$kind" "$value" "bound before the run started" || true
        done
    else
        printf 'run-ledger: NOTE: could not read the socket table; this run will not track listeners\n'
    fi
    collect_worktrees "" | while IFS="$FS" read -r kind value detail exempt; do
        ledger_append "$file" baseline "$kind" "$value" "$detail" || true
    done
    collect_tmux "" "$runid" | while IFS="$FS" read -r kind value detail exempt; do
        ledger_append "$file" baseline "$kind" "$value" "$detail" || true
    done

    collision_note "$runid"
}

# What earlier runs left behind, named before this run starts, so that
# `agentbox logs` shows the cause above the failure it caused. A run never
# refuses to start over a survivor: nobody is at the host to clear it.
#
# COUNTS and validated port references only, never a `detail` and never a
# worktree path or a tmux name. Both of those are chosen by an agent, this text
# lands in console.log, and console.log is in the leak check's list: one earlier
# run whose ledger holds the token in a command line would otherwise make every
# later run exit 3, for ever, over a file nobody can see from the host.
collision_note() {
    local self="${1:?}" rows runid kind value detail since
    local total=0 ports="" runs=""
    rows=$(survivor_rows "$self") || rows=""
    [ -n "$rows" ] || return 0
    while IFS="$FS" read -r runid kind value detail since; do
        [ -n "$kind" ] || continue
        total=$((total + 1))
        case "$runid" in
            '') ;;
            *) printf '%s\n' "$runs" | grep -qxF "$runid" || runs="${runs}${runid}
" ;;
        esac
        if [ "$kind" = "port" ] && abx_valid_port_ref "$value"; then
            ports="${ports}${value} "
        fi
    done <<EOF
$rows
EOF
    [ "$total" -gt 0 ] || return 0
    printf 'run-ledger: NOTE: %s resource(s) from earlier work are still present and may collide; see agentbox leftovers\n' "$total"
    [ -z "$ports" ] || printf 'run-ledger: NOTE: ports still bound: %s\n' "${ports% }"
    if [ -n "$runs" ]; then
        printf 'run-ledger: NOTE: recorded by run(s): %s\n' "$(printf '%s' "$runs" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# observe
# ---------------------------------------------------------------------------

# One pass: what is ours right now, minus what the baseline already had, minus
# what the ledger already knows. The dedup is the writer's job as well as the
# reader's — without it a four-hour run with one dev server writes 960 copies
# of the same line and the caps in `status` are spent on one port.
observe_pass() {
    local run_dir="${1:?}" pgid="${2:?}" quiet="${3:-0}"
    local file base state known threshold up pids rows added=0
    local kind value detail exempt sk svalue
    file=$(ledger_file "$run_dir")
    if [ ! -e "$file" ]; then
        : > "$file" 2>/dev/null || return 1
        chmod 600 "$file" 2>/dev/null || true
    fi

    base=$(ledger_baseline_pairs "$file")
    state=$(ledger_state "$file")
    known=""
    if [ -n "$state" ]; then
        # Every phase but `baseline` counts as known, and ledger_state has
        # already dropped those, so the phase itself is not read here.
        while IFS="$FS" read -r _ sk svalue _; do
            [ -n "$sk" ] || continue
            known="${known}${sk}${FS}${svalue}
"
        done <<EOF
$state
EOF
    fi

    up=$(ledger_baseline_uptime "$file") || up=""
    threshold=$(starttime_threshold "$up") || threshold=""
    pids=$(candidate_pids "$pgid" "$run_dir" "$threshold" "$known")
    pids=$(expand_and_filter_pids "$pids" "")

    rows=$(collect_procs "$pids")
    if sockets_readable; then
        rows="${rows}$(collect_ports "$pids" "$base")
"
    fi
    rows="${rows}$(collect_worktrees "$base")
"
    rows="${rows}$(collect_tmux "$base" "${run_dir##*/}")
"

    while IFS="$FS" read -r kind value detail exempt; do
        [ -n "$kind" ] || continue
        [ "$added" -lt "$PASS_ROW_CAP" ] || break
        set_has "$known" "$kind" "$value" && continue
        if [ "${exempt:-0}" != "1" ] && set_has "$base" "$kind" "$value"; then
            continue
        fi
        ledger_append "$file" observed "$kind" "$value" "$detail" || continue
        known="${known}${kind}${FS}${value}
"
        added=$((added + 1))
        [ "$quiet" = "1" ] || printf 'run-ledger: observed %s %s\n' "$kind" "$value"
    done <<EOF
$rows
EOF
    return 0
}

cmd_observe() {
    local runid="" pgid="" quiet=0 dir
    while [ $# -gt 0 ]; do
        case "$1" in
            --pgid)  pgid="${2:?--pgid needs a value}"; shift 2 ;;
            --quiet) quiet=1; shift ;;
            -*)      die "unknown option: $1" ;;
            *)       [ -z "$runid" ] || die "usage: run-ledger.sh observe <runid> --pgid N [--quiet]"
                     runid="$1"; shift ;;
        esac
    done
    [ -n "$runid" ] || die "usage: run-ledger.sh observe <runid> --pgid N [--quiet]"
    case "$pgid" in ''|*[!0-9]*) die "--pgid takes a process group id" ;; esac
    dir=$(abx_run_dir "$runid")
    [ -d "$dir" ] || die "no run directory for ${runid}"
    observe_pass "$dir" "$pgid" "$quiet"
}

# ---------------------------------------------------------------------------
# sweep
# ---------------------------------------------------------------------------

# In this order, and the order is the design:
#
#   1. re-observe, so the ledger is current before anything is closed;
#   2. tmux sessions, because killing a session kills its panes and takes pids
#      out of step 3;
#   3. processes;
#   4. worktrees, which a live process in them would keep git from removing;
#   5. ports, which are never closed directly — a port is closed by closing the
#      process holding it, so this step only records what is still bound;
#   6. the `owned-clear` marker and the `swept` line;
#   7. the one `hygiene` line the run's summary keeps.
cmd_sweep() {
    local runid="" pgid="" spare="" dir file
    while [ $# -gt 0 ]; do
        case "$1" in
            --pgid)  pgid="${2:?--pgid needs a value}"; shift 2 ;;
            --spare) spare="${2:?--spare needs a value}"; shift 2 ;;
            -*)      die "unknown option: $1" ;;
            *)       [ -z "$runid" ] || die "usage: run-ledger.sh sweep <runid> --pgid N [--spare P,P]"
                     runid="$1"; shift ;;
        esac
    done
    [ -n "$runid" ] || die "usage: run-ledger.sh sweep <runid> --pgid N [--spare P,P]"
    case "$pgid" in ''|*[!0-9]*) die "--pgid takes a process group id" ;; esac
    dir=$(abx_run_dir "$runid")
    [ -d "$dir" ] || die "no run directory for ${runid}"
    file=$(ledger_file "$dir")

    local spare_pids="" p
    for p in $(printf '%s' "$spare" | tr ',' ' '); do
        case "$p" in ''|*[!0-9]*) continue ;; esac
        spare_pids="${spare_pids}${p} "
    done

    observe_pass "$dir" "$pgid" 1 || true

    local closed_proc=0 closed_tmux=0 closed_wt=0
    local surv_proc=0 surv_port=0 surv_wt=0 surv_tmux=0 surv_ports=""
    local unsafe_tmux=0
    local state phase kind value ts detail

    state=$(ledger_state "$file")

    # --- 2. tmux ------------------------------------------------------------
    local have_tmux=0
    command -v tmux >/dev/null 2>&1 && have_tmux=1
    while IFS="$FS" read -r phase kind value ts detail; do
        [ "$kind" = "tmux" ] || continue
        case "$phase" in observed|survived) ;; *) continue ;; esac
        if [ "$have_tmux" -eq 0 ]; then
            surv_tmux=$((surv_tmux + 1))
            ledger_append "$file" survived tmux "$value" "tmux is not installed" || true
            continue
        fi
        if ! abx_valid_session_name "$value"; then
            # Not closed, and the name is NOT echoed: it is agent-chosen text
            # and this line reaches the host's terminal.
            unsafe_tmux=$((unsafe_tmux + 1))
            surv_tmux=$((surv_tmux + 1))
            ledger_append "$file" survived tmux "$value" "the name is not in the safe shape" || true
            continue
        fi
        if ! tmux_has_session "$value"; then
            ledger_append "$file" closed tmux "$value" "already gone" || true
            continue
        fi
        if tmux kill-session -t "=${value}" 2>/dev/null; then
            closed_tmux=$((closed_tmux + 1))
            ledger_append "$file" closed tmux "$value" "kill-session" || true
        else
            surv_tmux=$((surv_tmux + 1))
            ledger_append "$file" survived tmux "$value" "kill-session failed" || true
        fi
    done <<EOF
$state
EOF

    # --- 3. processes -------------------------------------------------------
    local up threshold observed_pids="" pids="" remaining="" stage own
    up=$(ledger_baseline_uptime "$file") || up=""
    threshold=$(starttime_threshold "$up") || threshold=""
    while IFS="$FS" read -r phase kind value ts detail; do
        [ "$kind" = "proc" ] || continue
        case "$phase" in observed|survived) ;; *) continue ;; esac
        case "$value" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$value" 2>/dev/null || { ledger_append "$file" closed proc "$value" "already gone" || true; continue; }
        observed_pids="${observed_pids}${value} "
    done <<EOF
$state
EOF
    pids=$(candidate_pids "$pgid" "$dir" "$threshold" "")
    pids=$(printf '%s\n%s\n' "$pids" "$(printf '%s' "$observed_pids" | tr ' ' '\n')" | sort -u)
    pids=$(expand_and_filter_pids "$pids" "$spare_pids")

    # Without pgrep there is no process group and no descendant walk, so the only
    # processes this sweep can reach are the ones the sampler recorded. Said out
    # loud rather than reported as a clean box, which is the wording run-ctl.sh
    # already uses for the same missing tool.
    if ! command -v pgrep >/dev/null 2>&1; then
        printf 'hygiene   : pgrep is missing; only the processes this run recorded could be found\n'
    fi

    # The triage, before a single signal: only a process whose start time proves
    # it began after the baseline is signalled. One whose start time cannot be
    # read is neither signalled nor hidden, and one that predates the baseline
    # is not this run's business at all — it is not recorded either way, because
    # a line about a stranger's process is a false claim about this run.
    local kill_set=""
    for p in $pids; do
        kill -0 "$p" 2>/dev/null || continue
        own=$(proc_ownership "$p" "$threshold")
        case "$own" in
            yes) kill_set="${kill_set}${p} " ;;
            unproven)
                surv_proc=$((surv_proc + 1))
                ledger_append "$file" survived proc "$p" "unverifiable" || true ;;
            *) ;;
        esac
    done

    remaining="$kill_set"
    for stage in INT TERM KILL; do
        [ -n "$remaining" ] || break
        for p in $remaining; do
            kill -"$stage" "$p" 2>/dev/null || true
        done
        case "$stage" in
            INT)  remaining=$(wait_for_exit "$remaining" "$WAIT_INT") ;;
            TERM) remaining=$(wait_for_exit "$remaining" "$WAIT_TERM") ;;
            *)    remaining=$(wait_for_exit "$remaining" "$WAIT_KILL") ;;
        esac
    done
    # Only the set that was actually signalled produces a line, so a stranger's
    # process that happened to exit during the ladder is never claimed as closed.
    for p in $kill_set; do
        case " ${remaining} " in
            *" ${p} "*)
                surv_proc=$((surv_proc + 1))
                ledger_append "$file" survived proc "$p" "would not stop" || true ;;
            *)
                closed_proc=$((closed_proc + 1))
                ledger_append "$file" closed proc "$p" "signalled" || true ;;
        esac
    done

    # --- 4. worktrees -------------------------------------------------------
    local registered
    registered=$(git -C "$ABX_WORK_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p') || registered=""
    while IFS="$FS" read -r phase kind value ts detail; do
        [ "$kind" = "worktree" ] || continue
        case "$phase" in observed|survived) ;; *) continue ;; esac
        if ! printf '%s\n' "$registered" | grep -qxF "$value"; then
            ledger_append "$file" closed worktree "$value" "no longer registered" || true
            continue
        fi
        worktree_is_removable "$value"
        case "$?" in
            0) ;;
            2) surv_wt=$((surv_wt + 1))
               ledger_append "$file" survived worktree "$value" "no such directory in this box" || true
               continue ;;
            *) surv_wt=$((surv_wt + 1))
               ledger_append "$file" survived worktree "$value" "outside this run's reach" || true
               continue ;;
        esac
        if git -C "$ABX_WORK_DIR" worktree remove --force -- "$value" >/dev/null 2>&1; then
            closed_wt=$((closed_wt + 1))
            ledger_append "$file" closed worktree "$value" "worktree remove --force" || true
        else
            # No prune, ever: it takes no path and would delete the
            # administrative entry of every worktree whose directory is not
            # here, the host's bench included.
            surv_wt=$((surv_wt + 1))
            ledger_append "$file" survived worktree "$value" "could not be removed" || true
        fi
    done <<EOF
$state
EOF

    # --- 5. ports -----------------------------------------------------------
    #
    # A port is never closed directly: it is closed by closing the process
    # holding it, which step 3 has just done. So this step only reads the socket
    # table again and records what is still bound.
    local bound=""
    if sockets_readable; then
        bound=$(abx_listeners | awk '{ print $1 ":" $2 }')
        while IFS="$FS" read -r phase kind value ts detail; do
            [ "$kind" = "port" ] || continue
            case "$phase" in observed|survived) ;; *) continue ;; esac
            if printf '%s\n' "$bound" | grep -qxF "$value"; then
                surv_port=$((surv_port + 1))
                surv_ports="${surv_ports}${value} "
                ledger_append "$file" survived port "$value" "still bound after the sweep" || true
            else
                ledger_append "$file" closed port "$value" "no longer bound" || true
            fi
        done <<EOF
$state
EOF
    else
        printf 'hygiene   : could not read the socket table; listeners were not tracked\n'
    fi

    # --- 6. the markers ----------------------------------------------------
    local survivors_total=$((surv_proc + surv_port + surv_wt + surv_tmux))
    if [ "$survivors_total" -eq 0 ]; then
        : > "${dir}/owned-clear" 2>/dev/null && chmod 600 "${dir}/owned-clear" 2>/dev/null || true
    else
        rm -f "${dir}/owned-clear" 2>/dev/null || true
    fi
    ledger_append "$file" swept run "$runid" \
        "closed ${closed_proc} proc, ${closed_tmux} tmux, ${closed_wt} worktree; survived ${survivors_total}" || true

    # --- 7. the line the summary keeps -------------------------------------
    [ "$unsafe_tmux" -eq 0 ] \
        || printf 'hygiene   : %s tmux session(s) had a name that is not in the safe shape; they were left alone\n' "$unsafe_tmux"
    hygiene_line "$closed_proc" "$closed_tmux" "$closed_wt" \
                 "$surv_proc" "$surv_port" "$surv_wt" "$surv_tmux" "$surv_ports"
    return 0
}

# Poll a set of pids for up to N seconds; print the ones still alive.
wait_for_exit() {
    local pids="${1:-}" secs="${2:?}" waited=0 p left=""
    while :; do
        left=""
        for p in $pids; do
            kill -0 "$p" 2>/dev/null && left="${left}${p} "
        done
        [ -n "$left" ] || break
        [ "$waited" -lt "$secs" ] || break
        sleep 1
        waited=$((waited + 1))
    done
    printf '%s' "$left"
}

tmux_has_session() {
    local name="${1:?}"
    command -v tmux >/dev/null 2>&1 || return 1
    tmux has-session -t "=${name}" 2>/dev/null
}

# May the sweep remove this worktree? Removal deletes files with `--force`, so
# the answer is three-valued and the caller reports which one it got:
#
#   0  removable: an existing directory here, not the mount and not a parent of
#      it, resolving under the mount or under the guest's home — which is where
#      a run's worktrees are made;
#   2  there is no such directory in this box, which is what a worktree the HOST
#      registered looks like from in here. Reported, never touched;
#   1  it is somewhere else entirely.
#
# Both sides of every containment test are resolved physically, because a path
# with a symlink in it compares unequal to the same place spelled another way,
# and this is the test that decides whether a directory is deleted.
worktree_is_removable() {
    local path="${1:?}" real="" work="" home=""
    [ -d "$path" ] || return 2
    real=$(cd "$path" 2>/dev/null && pwd -P) || return 2
    [ -n "$real" ] || return 2
    [ "$real" != "/" ] || return 1
    work=$(cd "$ABX_WORK_DIR" 2>/dev/null && pwd -P) || work="$ABX_WORK_DIR"
    home=$(cd "$HOME" 2>/dev/null && pwd -P) || home="$HOME"
    [ "$real" != "$work" ] || return 1
    case "${work}/" in "${real}"/*) return 1 ;; esac
    case "${real}/" in
        "${work}"/*) return 0 ;;
        "${home}"/*) return 0 ;;
    esac
    return 1
}

# The one line the run's console and its summary.txt both carry. Counts, and
# port references that passed their shape test — no path, no tmux name, no
# `detail`, nothing from another run.
hygiene_line() {
    local cp="${1:-0}" ct="${2:-0}" cw="${3:-0}" sp="${4:-0}" spo="${5:-0}" sw="${6:-0}" st="${7:-0}" ports="${8:-}"
    local closed="" left="" out=""
    [ "$cp" -eq 0 ] || closed="${closed}${closed:+, }$(plural "$cp" process processes)"
    [ "$ct" -eq 0 ] || closed="${closed}${closed:+, }$(plural "$ct" 'tmux session' 'tmux sessions')"
    [ "$cw" -eq 0 ] || closed="${closed}${closed:+, }$(plural "$cw" worktree worktrees)"
    [ "$sp" -eq 0 ] || left="${left}${left:+, }$(plural "$sp" process processes)"
    [ "$spo" -eq 0 ] || left="${left}${left:+, }$(plural "$spo" listener listeners)"
    [ "$sw" -eq 0 ] || left="${left}${left:+, }$(plural "$sw" worktree worktrees)"
    [ "$st" -eq 0 ] || left="${left}${left:+, }$(plural "$st" 'tmux session' 'tmux sessions')"
    [ -z "$closed" ] || out="closed ${closed}"
    if [ -n "$left" ]; then
        out="${out}${out:+; }${left} survived"
        [ -z "$ports" ] || out="${out} (${ports% })"
    fi
    [ -n "$out" ] || out="nothing was left running"
    printf 'hygiene   : %s\n' "$out"
}

plural() {
    local n="${1:?}" one="${2:?}" many="${3:?}"
    if [ "$n" -eq 1 ]; then printf '%s %s' "$n" "$one"; else printf '%s %s' "$n" "$many"; fi
}

# ---------------------------------------------------------------------------
# survivors
# ---------------------------------------------------------------------------

# Every run's entries that are still present, plus what is present and no run
# recorded. Bounded by design: a `stat` per run directory, and two commands for
# the whole box — never a walk of /proc, and never a per-row `git`.
#
# Lines are `runid FS kind FS value FS detail FS since`, and `runid` is empty
# for a row no run recorded. It is used twice: by `cmd_survivors`, which turns
# it into the JSON the host reads, and by the collision note a run prints
# before it starts.
survivor_rows() {
    local skip="${1:-}"
    local d runid file state phase kind value ts detail rows=0
    local bound="" worktrees="" tmuxes="" seen="" sock_ok=0
    sockets_readable && sock_ok=1
    [ "$sock_ok" -eq 0 ] || bound=$(abx_listeners | awk '{ print $1 ":" $2 }')
    worktrees=$(git -C "$ABX_WORK_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p') || worktrees=""
    if command -v tmux >/dev/null 2>&1; then
        tmuxes=$(tmux list-sessions -F '#{session_name}' 2>/dev/null) || tmuxes=""
    fi

    [ -d "$ABX_RUNS_DIR" ] || return 0
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -d "$d" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        [ "$runid" != "$skip" ] || continue
        # One stat settles a run that has been swept clean, which is what keeps
        # this cheap on a box with a hundred runs behind it.
        [ ! -e "${d}/owned-clear" ] || continue
        file=$(ledger_file "$d")
        [ -s "$file" ] || continue
        state=$(ledger_state "$file")
        [ -n "$state" ] || continue
        local present=0 absent=0
        while IFS="$FS" read -r phase kind value ts detail; do
            [ -n "$kind" ] || continue
            case "$phase" in observed|survived) ;; *) continue ;; esac
            if resource_present "$kind" "$value" "$sock_ok" "$bound" "$worktrees" "$tmuxes"; then
                present=$((present + 1))
                [ "$rows" -lt "$SURVIVOR_ROW_CAP" ] || continue
                rows=$((rows + 1))
                seen="${seen}${kind}${FS}${value}
"
                printf '%s%s%s%s%s%s%s%s%s\n' \
                    "$runid" "$FS" "$kind" "$FS" "$value" "$FS" "$detail" "$FS" "$ts"
            else
                absent=$((absent + 1))
            fi
        done <<EOF
$state
EOF
        # A run that was hard-killed never reaches a sweep, so nothing would
        # ever settle its ledger and every `status` would re-probe it for the
        # life of the box. When every entry reads absent, this read settles it —
        # a write during a read, like `reconcile`'s.
        if [ "$present" -eq 0 ] && [ "$absent" -gt 0 ] && ! ledger_was_swept "$file"; then
            : > "${d}/owned-clear" 2>/dev/null && chmod 600 "${d}/owned-clear" 2>/dev/null || true
        fi
    done

    # What is present and no run recorded. Worktrees and tmux sessions only:
    # finding the owner of an unattributed PORT needs the walk of every process
    # in the box that this function exists to avoid, so it is a stated blind
    # spot rather than a slow scan.
    local path name
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ "$path" != "$ABX_WORK_DIR" ] || continue
        set_has "$seen" worktree "$path" && continue
        [ "$rows" -lt "$SURVIVOR_ROW_CAP" ] || break
        rows=$((rows + 1))
        printf '%s%s%s%s%s%s%s%s%s\n' "" "$FS" worktree "$FS" "$path" "$FS" "recorded by no run" "$FS" ""
    done <<EOF
$(printf '%s\n' "$worktrees" | sed 1d)
EOF
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" != "shell" ] || continue
        case "$name" in
            run-*) abx_valid_runid "${name#run-}" && continue ;;
        esac
        if abx_valid_session_name "$name" && [ -d "${ABX_SESSIONS_DIR}/${name}" ]; then
            continue
        fi
        set_has "$seen" tmux "$name" && continue
        [ "$rows" -lt "$SURVIVOR_ROW_CAP" ] || break
        rows=$((rows + 1))
        printf '%s%s%s%s%s%s%s%s%s\n' "" "$FS" tmux "$FS" "$name" "$FS" "recorded by no run" "$FS" ""
    done <<EOF
$tmuxes
EOF
    [ "$rows" -lt "$SURVIVOR_ROW_CAP" ] \
        || printf 'run-ledger: the survivor scan stopped at %s rows\n' "$SURVIVOR_ROW_CAP" >&2
    return 0
}

# Is that resource still there? Membership in a list this scan already took,
# for every class but a process — which is the only one a signal can be sent
# to, and therefore the only one `kill -0` is the right question for. A tmux
# name or a worktree path is never passed back to tmux or to git here, so a
# name that is not in the safe shape can still be reported.
resource_present() {
    local kind="${1:?}" value="${2:-}" sock_ok="${3:-0}"
    local bound="${4:-}" worktrees="${5:-}" tmuxes="${6:-}"
    case "$kind" in
        proc)
            case "$value" in ''|*[!0-9]*) return 1 ;; esac
            kill -0 "$value" 2>/dev/null ;;
        port)
            # An unreadable socket table is not an empty one: with no reading,
            # the honest answer is not "gone", so the row is neither reported
            # as present nor counted as absent evidence for `owned-clear`.
            [ "$sock_ok" -eq 1 ] || return 1
            printf '%s\n' "$bound" | grep -qxF "$value" ;;
        worktree)
            printf '%s\n' "$worktrees" | grep -qxF "$value" ;;
        tmux)
            printf '%s\n' "$tmuxes" | grep -qxF "$value" ;;
        *) return 1 ;;
    esac
}

# The rows as the host reads them: through run-format.py, like every other
# guest-to-host path. `detail` holds command lines the model chose and `value`
# holds paths and session names it chose, so the scrub and the caps happen
# inside the box, before the bytes reach a terminal.
cmd_survivors() {
    local as_json="" runid kind value detail since first=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) as_json="--json"; shift ;;
            *)      die "usage: run-ledger.sh survivors [--json]" ;;
        esac
    done
    {
        printf '['
        while IFS="$FS" read -r runid kind value detail since; do
            [ -n "$kind" ] || continue
            [ "$first" -eq 1 ] || printf ','
            first=0
            jq -cn --arg runid "$runid" \
                   --arg kind "$kind" \
                   --arg value "$value" \
                   --arg detail "$detail" \
                   --arg since "$since" \
                   '{runid:  (if $runid == "" then null else $runid end),
                     kind:   $kind,
                     value:  $value,
                     detail: (if $detail == "" then null else $detail end),
                     since:  (if $since == "" then null else $since end)}'
        done <<EOF
$(survivor_rows "")
EOF
        printf ']'
    } | python3 "${ABX_LIB_DIR}/run-format.py" --survivors-in ${as_json:+"$as_json"}
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
    baseline)  shift; cmd_baseline "$@" ;;
    observe)   shift; cmd_observe "$@" ;;
    sweep)     shift; cmd_sweep "$@" ;;
    survivors) shift; cmd_survivors "$@" ;;
    -h|--help) sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)         die "usage: run-ledger.sh baseline|observe|sweep|survivors" ;;
esac
