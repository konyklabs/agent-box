#!/bin/bash
#
# agent-box — an interactive Claude Code session inside the guest, at /work.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox claude <repo> [claude args...]` and by `agentbox session <repo>`.
#
# Usage: claude-session.sh [--tmux NAME] [--session-name NAME]
#                          [--brief PATH] [--model M] [claude args...]
#
# This is the interactive half of the box. `agentbox run` is the headless half
# and gets a scrubbed summary, a branch and a leak check; this one hands the
# terminal straight to the CLI, which is what makes it useful and also what
# makes it unscrubbed — see docs/decisions.md. The preconditions are the same
# ones agent-run.sh insists on, from the same file, because "an interactive
# session" is not a reason to run an agent with the firewall down or with an
# API key quietly outranking the subscription token.
#
# --tmux runs the session inside a named tmux session so it can be left and
# come back to. The token is exported only in the inner invocation, never in
# the process that starts the tmux server: a tmux server holds the environment
# of whichever client started it and hands it to every later session, so
# exporting the credential on the outside would put it in sessions that have
# nothing to do with the agent.
#
# One of these sessions per box is THE STANDING SESSION, named `claude`: it is
# recorded (a pid file the host can ask about), hooked (the channel's delivery
# hook, so the host's requests arrive in it by themselves) and told what an
# interactive session here works under. `agentbox session` names it explicitly;
# `agentbox claude` takes the name when it is free and a terminal is attached.
# Everything else — a second session, a `-p` invocation, `--version` — runs
# exactly as it did before, untracked, and is told so once.

set -uo pipefail

die() { printf 'agent-box claude: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="${ABX_LIB_DIR}/claude-session.sh"
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

WORK_DIR="${AGENT_BOX_WORK:-/work}"
export TZ=UTC

TMUX_NAME=""
SESSION_NAME=""
BRIEF=""
MODEL=""
FORWARD=()

while [ $# -gt 0 ]; do
    case "$1" in
        --tmux)         TMUX_NAME="${2:?--tmux needs a value}"; shift 2 ;;
        --session-name) SESSION_NAME="${2:?--session-name needs a value}"; shift 2 ;;
        --brief)        BRIEF="${2:?--brief needs a value}"; shift 2 ;;
        --model)        MODEL="${2:?--model needs a value}"; shift 2 ;;
        *)              FORWARD+=("$1"); shift ;;
    esac
done

abx_assert_environment die

[ -d "$WORK_DIR" ] || die "${WORK_DIR} is not mounted"

# ---------------------------------------------------------------------------
# The standing session: one tracked, hooked, interactive session per box
# ---------------------------------------------------------------------------
#
# `agentbox session` names its session explicitly (`--tmux claude`, which becomes
# `--session-name claude` in the process inside tmux). `agentbox claude` passes
# the operator's arguments straight through and names nothing, so the block below
# is what makes the two converge on one session: a terminal, no --print, and the
# name free. A session that takes the name is tracked, is given the hook settings
# and receives the host's requests; one that does not is exactly what it was
# before this existed.
#
# The lock is held from the liveness check through the pid write, because two
# `agentbox claude` invocations racing for the name is the case a check without a
# lock gets wrong. It is a file on the guest's own disk, never on the mount.

STANDING_LOCK_HELD=no

standing_lock() {
    [ "$STANDING_LOCK_HELD" = no ] || return 0
    abx_private_dir "$ABX_SESSIONS_DIR"
    command -v flock >/dev/null 2>&1 || { STANDING_LOCK_HELD=unavailable; return 0; }
    # Created with an ordinary redirect first: a failed `exec` redirection is the
    # one failure that can take a non-interactive shell down with it.
    : > "${ABX_SESSIONS_DIR}/.standing.lock" 2>/dev/null || return 0
    exec 8>>"${ABX_SESSIONS_DIR}/.standing.lock" || return 0
    flock -w 5 8 || return 0
    STANDING_LOCK_HELD=yes
}

standing_unlock() {
    [ "$STANDING_LOCK_HELD" = yes ] || return 0
    exec 8>&-
    STANDING_LOCK_HELD=no
}

# The pid the records name, for a message that has to say which process holds the
# session. Digits or nothing: it is read from a file in a directory the agent can
# write to, and it reaches a terminal.
standing_pid() {
    local pid=""
    pid=$(head -1 "${ABX_SESSIONS_DIR}/${1:?}/pid" 2>/dev/null) || pid=""
    case "$pid" in ''|*[!0-9]*) printf 'unknown\n' ;; *) printf '%s\n' "$pid" ;; esac
}

# A CLI invocation that prints and exits is not a session: it holds no terminal,
# it ends in seconds, and a request delivered into it is a request nobody read.
FORWARD_PRINTS=no
for arg in ${FORWARD[@]+"${FORWARD[@]}"}; do
    case "$arg" in
        -p|--print|--version|-v|--help|-h) FORWARD_PRINTS=yes ;;
    esac
done

if [ -z "$TMUX_NAME" ] && [ -z "$SESSION_NAME" ] && [ "$FORWARD_PRINTS" = no ] \
   && [ -t 0 ] && [ -t 1 ]; then
    standing_lock
    if abx_session_alive "$ABX_STANDING_SESSION"; then
        # Not a refusal: a second interactive session is a reasonable thing to
        # want. It is simply not the one the host talks to, and saying so here is
        # what stops somebody waiting for a request that is being delivered to
        # another pane. On stderr, because stdout is about to become the CLI's.
        printf 'agent-box claude: the standing session "%s" is already running (agentbox attach); this one is untracked and receives no host requests\n' \
            "$ABX_STANDING_SESSION" >&2
        standing_unlock
    else
        SESSION_NAME="$ABX_STANDING_SESSION"
    fi
fi

# ---------------------------------------------------------------------------
# The outer half: put the session inside tmux and hand over
# ---------------------------------------------------------------------------
#
# `new-session -A` attaches to the session if it is already there and creates
# it otherwise, which is exactly what "leave it and come back" means. When it
# attaches, the command below is ignored — the session that is already running
# keeps running.

if [ -n "$TMUX_NAME" ]; then
    command -v tmux >/dev/null 2>&1 || die "tmux is not installed in this guest"
    # A live session of that name OUTSIDE tmux (an `agentbox claude` that took the
    # standing name in a plain terminal) would make the inner process below refuse
    # — inside a brand-new pane, where the message vanishes with the pane. So the
    # refusal happens here, in the process the operator is looking at.
    if ! tmux has-session -t "=$TMUX_NAME" 2>/dev/null && abx_session_alive "$TMUX_NAME"; then
        die "the session \"${TMUX_NAME}\" is already running in this box as pid $(standing_pid "$TMUX_NAME"), outside tmux; leave that one or end it before starting this"
    fi
    INNER=("$SELF" --session-name "$TMUX_NAME")
    [ -n "$BRIEF" ] && INNER+=(--brief "$BRIEF")
    [ -n "$MODEL" ] && INNER+=(--model "$MODEL")
    [ "${#FORWARD[@]}" -gt 0 ] && INNER+=("${FORWARD[@]}")
    exec tmux new-session -A -s "$TMUX_NAME" -- "${INNER[@]}"
fi

# ---------------------------------------------------------------------------
# The inner half: the session itself
# ---------------------------------------------------------------------------

SETTINGS_ARGS=()
if [ -n "$SESSION_NAME" ]; then
    SESSION_DIR=$(abx_session_dir "$SESSION_NAME")
    # Under the lock the implicit path may already hold: the check and the pid
    # write are one operation, or two launches can both decide the name is free.
    standing_lock
    if abx_session_alive "$SESSION_NAME"; then
        standing_unlock
        die "the session \"${SESSION_NAME}\" is already running in this box as pid $(standing_pid "$SESSION_NAME"); its records and its host requests belong to that process"
    fi
    abx_private_dir "$ABX_SESSIONS_DIR"
    abx_private_dir "$SESSION_DIR"
    abx_status_write "$SESSION_DIR" "running"
    # The pid, and the cmdline of that pid, are what `abx_session_alive` reads:
    # the pid file survives a hard VM stop, and after a reboot that number belongs
    # to somebody else. Written before the lock is dropped.
    printf '%s\n' "$$" > "${SESSION_DIR}/pid"
    chmod 600 "${SESSION_DIR}/pid" 2>/dev/null || true
    standing_unlock
    # Only when there is somewhere to write. hook-event.sh exits 0 doing
    # nothing without this, so wiring the hooks up with nowhere for them to go
    # would spawn a process per tool call to achieve exactly that.
    export AGENT_BOX_EVENTS_DIR="$SESSION_DIR"
    # The channel's delivery hook short-circuits on this variable before it does
    # anything else, so only the standing session is subscribed: a run, an
    # untracked shell and a differently-named session all read as empty and
    # receive nothing. It is exported here and nowhere else.
    if [ "$SESSION_NAME" = "$ABX_STANDING_SESSION" ]; then
        export ABX_CHANNEL_SESSION="$SESSION_NAME"
    fi
    mapfile -t SETTINGS_ARGS < <(abx_hook_settings_args)

    session_finish() {
        local rc=$?
        abx_status_write "$SESSION_DIR" "exit:${rc}"
        # The name is free again the moment this process is gone. Liveness does
        # not depend on the file being removed — the cmdline check covers a crash
        # — but leaving it makes every later reader ask the kernel about a pid
        # that ended weeks ago.
        rm -f "${SESSION_DIR}/pid"
    }
    trap session_finish EXIT
fi

# The box's own bookkeeping under the mount, kept out of the repository's tracked
# files. Unconditional and before anything writes there: a box where only
# `agentbox session` was ever used otherwise shows `.agent-box/` as untracked
# content in the repository the host is about to commit from. A directory that is
# not a git repository is left alone.
abx_exclude_state_dir "$WORK_DIR"

# Where this repository pins a tool at a version this box does not have. Warn-only
# by contract, and until now it reached headless runs alone: a run gets it above
# its brief, and an interactive session got nothing at all. It is printed for the
# operator here and — when this session is tracked — written beside the session's
# own state, so that the SessionStart card can carry the same text into the
# model's context instead of computing it again inside a hook.
TOOLCHAIN_REPORT=$(abx_toolchain_report)
if [ -n "$TOOLCHAIN_REPORT" ]; then
    printf '%s\n' "$TOOLCHAIN_REPORT"
fi
if [ -n "$SESSION_NAME" ]; then
    if [ -n "$TOOLCHAIN_REPORT" ]; then
        printf '%s\n' "$TOOLCHAIN_REPORT" > "${SESSION_DIR}/toolchain-report.txt"
        chmod 600 "${SESSION_DIR}/toolchain-report.txt" 2>/dev/null || true
    else
        # A clean box says nothing, and says nothing STALELY: a report left from
        # the session before this one would be injected as though it were this
        # box's answer today.
        rm -f "${SESSION_DIR}/toolchain-report.txt"
    fi
fi

# Session-only plugin roots from the read-only host config mount.
PLUGIN_ARGS=()
mapfile -t PLUGIN_ARGS < <(abx_plugin_dir_args)
abx_report_plugin_dirs "${PLUGIN_ARGS[@]}"

MODEL_ARGS=()
[ -n "$MODEL" ] && MODEL_ARGS=(--model "$MODEL")

# The brief becomes the session's first prompt. It is read here rather than
# passed as a path, so a brief that has already been copied into the guest can
# be deleted afterwards without the session losing it.
PROMPT_ARGS=()
if [ -n "$BRIEF" ]; then
    # A bare name is a file the host has already copied into the briefs
    # directory, the same convention run-ctl.sh uses: the host CLI does not
    # know what the guest user's home is called and must not have to guess.
    case "$BRIEF" in /*) ;; *) BRIEF="${ABX_BRIEFS_DIR}/${BRIEF}" ;; esac
    [ -f "$BRIEF" ] || die "brief not found: ${BRIEF}"
    PROMPT_ARGS=("$(cat "$BRIEF")")
fi

abx_export_token

cd "$WORK_DIR" || die "cannot enter ${WORK_DIR}"

# exec, so the CLI owns the terminal and its exit status is the one the host
# sees. The token is in this process's environment and goes no further: it is
# not on the guest's disk outside the 0600 token file, not in argv, and not in
# anything written to /work.
#
# With a session directory the EXIT trap above has to run, so the CLI is a
# child rather than a replacement: without that, a session would stay `running`
# for ever after it ended.
if [ -n "$SESSION_NAME" ]; then
    claude "${PLUGIN_ARGS[@]}" "${SETTINGS_ARGS[@]}" "${MODEL_ARGS[@]}" \
        "${FORWARD[@]}" "${PROMPT_ARGS[@]}"
    exit $?
fi

exec claude "${PLUGIN_ARGS[@]}" "${MODEL_ARGS[@]}" "${FORWARD[@]}" "${PROMPT_ARGS[@]}"
