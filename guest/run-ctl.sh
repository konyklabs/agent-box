#!/bin/bash
#
# agent-box — start, stop and list the tmux sessions a box is running.
#
# Runs in the guest, as the unprivileged guest user. Invoked by
# `agentbox run`, `agentbox stop-run` and `agentbox sessions`.
#
# Usage:
#   run-ctl.sh start --runid R --slug S --brief PATH [--model M]
#                    [--max-turns N] [--max-budget-usd X]
#                    [--heal-left N --heal-max M --heal-attempt K --heal-parent R]
#                    [--heal-delay S] [--origin R] [--resume-of R] [--delay S]
#                    [--review-model M] [--review-of R]
#   run-ctl.sh heal  --of RUNID [--parent-state failed|lost]
#   run-ctl.sh resume --of RUNID            (the operator's answer on stdin)
#   run-ctl.sh review --of RUNID [--parent-state done]
#                    (start the second-model review the run asked for)
#   run-ctl.sh ask   [runid]
#   run-ctl.sh learnings
#   run-ctl.sh stop  [runid]
#   run-ctl.sh sessions [--json]
#   run-ctl.sh state [runid]
#   run-ctl.sh runs [--json]
#   run-ctl.sh reconcile
#   run-ctl.sh latest
#
# Why this exists rather than the host assembling tmux commands: the host CLI's
# job is to talk to limactl, and nothing else. A `tmux new-session -d -s ...`
# built on the host is guest knowledge written down in the wrong place, in a
# string no linter reads and no test can run on its own.

set -uo pipefail

die() { printf 'run-ctl: %s\n' "$*" >&2; exit 1; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

command -v tmux >/dev/null 2>&1 || die "tmux is not installed in this guest"

# ---------------------------------------------------------------------------
# start
# ---------------------------------------------------------------------------

cmd_start() {
    local runid="" slug="task" model="sonnet" brief="" max_turns="" max_budget=""
    # The heal and resume lineage. All optional; a plain `agentbox run` sets
    # none of them and the run is its own origin.
    local heal_left="" heal_max="" heal_attempt="" heal_parent="" heal_delay="" origin="" resume_of="" delay=""
    local review_model="" review_of=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --review-model)   review_model="${2:?--review-model needs a value}"; shift 2 ;;
            --review-of)      review_of="${2:?--review-of needs a value}"; shift 2 ;;
            --runid)          runid="${2:?--runid needs a value}"; shift 2 ;;
            --slug)           slug="${2:?--slug needs a value}"; shift 2 ;;
            --model)          model="${2:?--model needs a value}"; shift 2 ;;
            --brief)          brief="${2:?--brief needs a value}"; shift 2 ;;
            --max-turns)      max_turns="${2:?--max-turns needs a value}"; shift 2 ;;
            --max-budget-usd) max_budget="${2:?--max-budget-usd needs a value}"; shift 2 ;;
            --heal-left)      heal_left="${2:?--heal-left needs a value}"; shift 2 ;;
            --heal-max)       heal_max="${2:?--heal-max needs a value}"; shift 2 ;;
            --heal-attempt)   heal_attempt="${2:?--heal-attempt needs a value}"; shift 2 ;;
            --heal-parent)    heal_parent="${2:?--heal-parent needs a value}"; shift 2 ;;
            --heal-delay)     heal_delay="${2:?--heal-delay needs a value}"; shift 2 ;;
            --origin)         origin="${2:?--origin needs a value}"; shift 2 ;;
            --resume-of)      resume_of="${2:?--resume-of needs a value}"; shift 2 ;;
            --delay)          delay="${2:?--delay needs a value}"; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    for _n in "$heal_left" "$heal_max" "$heal_attempt" "$heal_delay" "$delay"; do
        case "$_n" in ''|*[!0-9]*) [ -z "$_n" ] || die "heal counts and delays are whole numbers, got '${_n}'" ;; esac
    done
    for _r in "$heal_parent" "$origin" "$resume_of" "$review_of"; do
        [ -z "$_r" ] || abx_valid_runid "$_r" || die "not a run id: ${_r}"
    done
    [ -z "$review_model" ] || [ "$review_model" != "$model" ] \
        || die "the review model is the run model (${model}); a review on the same model is not a second opinion"

    [ -n "$runid" ] || die "start needs --runid"
    [ -n "$brief" ] || die "start needs --brief"
    # A bare name is a file the host has already copied into the briefs
    # directory. That keeps the guest home's location out of the host CLI,
    # which does not know what the guest user's home is called.
    case "$brief" in /*) ;; *) brief="${ABX_BRIEFS_DIR}/${brief}" ;; esac
    [ -f "$brief" ] || die "brief not found: ${brief}"

    local session="run-${runid}"
    if tmux has-session -t "=${session}" 2>/dev/null; then
        die "a tmux session named ${session} is already running"
    fi

    local args=(--runid "$runid" --slug "$slug" --model "$model"
                --brief "$brief" --session "$session")
    [ -n "$max_turns" ]    && args+=(--max-turns "$max_turns")
    [ -n "$max_budget" ]   && args+=(--max-budget-usd "$max_budget")
    [ -n "$heal_left" ]    && args+=(--heal-left "$heal_left")
    [ -n "$heal_max" ]     && args+=(--heal-max "$heal_max")
    [ -n "$heal_attempt" ] && args+=(--heal-attempt "$heal_attempt")
    [ -n "$heal_parent" ]  && args+=(--heal-parent "$heal_parent")
    [ -n "$heal_delay" ]   && args+=(--heal-delay "$heal_delay")
    [ -n "$origin" ]       && args+=(--origin "$origin")
    [ -n "$resume_of" ]    && args+=(--resume-of "$resume_of")
    [ -n "$delay" ]        && args+=(--delay "$delay")
    [ -n "$review_model" ] && args+=(--review-model "$review_model")
    [ -n "$review_of" ]    && args+=(--review-of "$review_of")

    # Detached, so the limactl shell that started it can return immediately.
    # The tmux server outlives that shell, which is the whole point: a run is
    # not tied to the terminal that launched it.
    tmux new-session -d -s "$session" -- \
        "${ABX_LIB_DIR}/agent-run.sh" "${args[@]}" \
        || die "tmux refused to start ${session}"

    # Do not return until the run is readable. The caller's next move is
    # `logs`, `runs` or `--wait`, and every one of those looks for meta.json;
    # returning the instant tmux forks would race the run into existence and
    # report "no such run" for a run that was about to be perfectly fine.
    local dir waited=0
    dir=$(abx_run_dir "$runid")
    while [ "$waited" -lt 30 ]; do
        [ -f "${dir}/meta.json" ] && break
        sleep 1
        waited=$((waited + 1))
    done
    [ -f "${dir}/meta.json" ] \
        || printf 'run-ctl: WARNING: %s has not written meta.json after %ss\n' "$runid" "$waited" >&2

    printf '%s\n' "$session"
}

# ---------------------------------------------------------------------------
# stop
# ---------------------------------------------------------------------------
#
# SIGINT to the claude process, not SIGKILL to the session. Claude Code treats
# an interrupt as "stop after this step", so the run gets the chance to write
# its result event; killing the pane leaves the run directory saying `running`
# for ever. The session is only killed once the status file has moved, or after
# 20 seconds, whichever comes first.

cmd_stop() {
    local runid="${1:-}" dir state session pane_pid waited

    if [ -z "$runid" ]; then
        # The newest RUNNING run, not simply the newest. A quick task started
        # after the long one finishes first, and `stop-run` with no argument
        # would otherwise address the finished one and leave the long one
        # burning budget, while printing that it had stopped something.
        runid=$(newest_running) || true
        if [ -z "$runid" ]; then
            die "no run is running. 'agentbox runs <repo>' lists what there is."
        fi
        printf 'run-ctl: stopping %s, the newest running run\n' "$runid"
    fi

    dir=$(abx_run_dir "$runid")
    [ -d "$dir" ] || die "no such run: ${runid}"

    state=$(derived_state "$dir")
    if [ "$state" != "running" ]; then
        die "run ${runid} already ended with ${state}; refusing to overwrite its record"
    fi

    session="run-${runid}"
    if ! tmux has-session -t "=${session}" 2>/dev/null; then
        # The status says running and the session is gone. That is the orphan
        # case, and it has its own state: `exit:lost` says the run's fate is
        # unknown, which is true, where `exit:stopped` would claim this command
        # stopped something it never reached.
        reconcile_run "$runid"
        printf 'run-ctl: %s has no tmux session; recorded it as %s\n' \
            "$runid" "$(abx_status_read "$dir")"
        return 0
    fi

    # Before any signal, and after the check above: the run reads this file in
    # its exit trap and records `exit:stopped` itself. The stopper cannot tell
    # an interrupted run from one that happened to finish in the same second,
    # and Claude Code exits 0 on an interrupt (issue #14), so inferring it from
    # out here recorded stopped runs as `done`. The run knows; this is how it
    # is told to look.
    printf '%s\n' "$(abx_now_iso)" > "${dir}/stop-requested"
    chmod 600 "${dir}/stop-requested" 2>/dev/null || true

    # The CLI, and only the CLI.
    #
    # Signalling every process under the pane hits two things that are not the
    # CLI: agent-run.sh itself, and the console tee holding the read end of its
    # stdout. Killing the tee left agent-run.sh writing into a pipe nobody was
    # reading, so it died of SIGPIPE without running its exit trap — no
    # summary, and no status written by the one process that knew what had
    # happened. That is why the run records its own pid for the CLI, and why
    # this walks down from there rather than down from the pane.
    local claude_pid="" pid signalled=0 tries=0

    pane_pid=$(tmux list-panes -t "=${session}" -F '#{pane_pid}' 2>/dev/null | head -1)

    # The pid file appears a second or two into a run, after the preconditions
    # and the branch. Waiting for it is the difference between interrupting the
    # CLI and interrupting the script that is about to start it — and the
    # second of those used to let the CLI be launched anyway, by a script whose
    # only reaction to the signal was to set a flag.
    while [ "$tries" -lt 10 ]; do
        claude_pid=$(read_claude_pid "$dir")
        [ -z "$claude_pid" ] || break
        # It may already be over rather than not yet begun.
        [ "$(abx_status_read "$dir")" = "running" ] || break
        sleep 1
        tries=$((tries + 1))
    done

    if [ -z "$claude_pid" ] && [ -z "$pane_pid" ]; then
        # Nothing to signal at all. Saying a stop was requested when none was
        # delivered leaves a marker that turns the run's next genuine failure
        # into a reported stop, so the request is withdrawn along with the
        # attempt.
        rm -f "${dir}/stop-requested"
        printf 'run-ctl: %s has a session but no process to signal; nothing was stopped\n' "$runid" >&2
        return 1
    fi

    if [ -n "$claude_pid" ]; then
        if ! command -v pgrep >/dev/null 2>&1; then
            # Probed directly. The signalled count cannot detect this: the
            # CLI's own pid is always in the list, so the count is never zero.
            # Inside this branch, because in the other one there is no CLI to
            # signal and the sentence would not be true.
            printf 'run-ctl: WARNING: pgrep is not installed, so only the CLI itself will be signalled, not its children\n' >&2
        fi
        for pid in $(abx_descendants_deepest_first "$claude_pid"); do
            kill -INT "$pid" 2>/dev/null && signalled=$((signalled + 1))
        done
        [ "$signalled" -gt 0 ] || printf 'run-ctl: WARNING: could not signal the CLI (pid %s)\n' "$claude_pid" >&2
    else
        # No CLI, after waiting for one. The run is in its preconditions or on
        # its way out; the script's own handler forwards a later signal and,
        # if the CLI has not started, makes sure it never does.
        printf 'run-ctl: no CLI process for %s; interrupting the run script\n' "$runid"
        [ -z "$pane_pid" ] || kill -INT "$pane_pid" 2>/dev/null || true
    fi

    waited=0
    while [ "$waited" -lt 20 ]; do
        [ "$(abx_status_read "$dir")" = "running" ] || break
        tmux has-session -t "=${session}" 2>/dev/null || break
        sleep 1
        waited=$((waited + 1))
    done

    # The run may have recorded its own exit while we waited. That code is the
    # truth about what happened and this command does not get to overwrite it.
    state=$(abx_status_read "$dir")
    if [ "$state" != "running" ]; then
        tmux kill-session -t "=${session}" 2>/dev/null || true
        if [ -e "${dir}/stopped" ]; then
            printf 'run-ctl: %s stopped after %ss (%s). Nothing was reverted: the work tree is as the run left it.\n' \
                "$runid" "$waited" "$state"
        elif [ "$state" = "exit:0" ]; then
            # "By itself" is reserved for a run that really did finish on its
            # own terms while we were waiting, which is the one case where this
            # command changed nothing.
            printf 'run-ctl: %s ended by itself after %ss with %s; nothing was reverted\n' \
                "$runid" "$waited" "$state"
        else
            printf 'run-ctl: %s ended after %ss with %s; nothing was reverted\n' \
                "$runid" "$waited" "$state"
        fi
        return 0
    fi

    # Still running after twenty seconds. Escalate on the CLI before touching
    # the session: closing the session while the CLI is alive orphans it in its
    # own process group, where it goes on running and going on spending, and
    # this command would meanwhile be reporting the run as stopped.
    claude_pid=$(read_claude_pid "$dir")
    if [ -n "$claude_pid" ]; then
        printf 'run-ctl: %s did not answer SIGINT; sending SIGTERM to the CLI\n' "$runid" >&2
        kill -TERM -"$claude_pid" 2>/dev/null || kill -TERM "$claude_pid" 2>/dev/null || true
        tries=0
        while [ "$tries" -lt 10 ]; do
            kill -0 "$claude_pid" 2>/dev/null || break
            sleep 1
            tries=$((tries + 1))
        done
        if kill -0 "$claude_pid" 2>/dev/null; then
            # The stop did not take, so the request is withdrawn. Left on disk
            # it would make the run's next failure — for any unrelated reason —
            # record itself as a stop, and `run --wait` would return 130 where
            # the run had actually failed.
            rm -f "${dir}/stop-requested"
            printf 'run-ctl: %s is STILL RUNNING: the CLI (pid %s) survived SIGINT and SIGTERM.\n' \
                "$runid" "$claude_pid" >&2
            printf 'run-ctl: the run is left recorded as running. It is still spending; stop it by hand.\n' >&2
            return 1
        fi
    fi

    tmux kill-session -t "=${session}" 2>/dev/null || true

    # exit:stopped is a claim that the run is over, so it is written only once
    # that has been observed: no session, and no surviving pane process.
    local gone=0
    tries=0
    while [ "$tries" -lt 10 ]; do
        if process_tree_gone "$pane_pid" "$session"; then gone=1; break; fi
        sleep 1
        tries=$((tries + 1))
    done

    if [ "$gone" -ne 1 ]; then
        rm -f "${dir}/stop-requested"
        printf 'run-ctl: %s did not stop: its session or its process is still there after %ss.\n' \
            "$runid" "$((waited + tries))" >&2
        printf 'run-ctl: the run is left recorded as running rather than claimed to be stopped.\n' >&2
        return 1
    fi

    # process_tree_gone short-circuits to "gone" on the session check alone
    # when there is no pane pid, which is not proof that the run's own process
    # has finished. Writing a status on that basis can land on top of an
    # `exit:3` the run wrote a moment later, and the leak refusal keys on that
    # exact string. Without the proof, this command does not write.
    if [ -z "$pane_pid" ]; then
        rm -f "${dir}/stop-requested"
        printf 'run-ctl: %s: tmux reported no pane process, so there is no proof the run has ended.\n' \
            "$runid" >&2
        printf 'run-ctl: the run is left recorded as running rather than claimed to be stopped.\n' >&2
        return 1
    fi

    # One last read. The run could have finished in the moment between the loop
    # above and here, and its own exit code outranks anything written from out
    # here — exit 3 above all, which is the leak check's and must never be
    # replaced.
    state=$(abx_status_read "$dir")
    if [ "$state" != "running" ]; then
        printf 'run-ctl: %s ended with %s as its session was closed; nothing was reverted\n' \
            "$runid" "$state"
        return 0
    fi

    # Worded differently from the branch above on purpose. There, the run
    # recorded its own stop and this command only reported it. Here it did not,
    # so the session was closed and the status written from outside — a
    # materially weaker claim, and one an operator should be able to tell apart.
    abx_status_write "$dir" "exit:stopped"
    printf 'run-ctl: %s stopped after %ss by closing its session; it did not record its own exit. Nothing was reverted.\n' \
        "$runid" "$waited"
}

# The CLI's pid as the run recorded it, if it is still alive. Empty otherwise.
read_claude_pid() {
    local dir="${1:?}" pid
    pid=$(cat "${dir}/claude-pid" 2>/dev/null | head -1) || pid=""
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$pid" 2>/dev/null || return 0
    printf '%s' "$pid"
}

# No tmux session, and no pane process. Both, because either alone can be true
# of a run that is still going.
process_tree_gone() {
    local pane="${1:-}" session="${2:?}"
    tmux has-session -t "=${session}" 2>/dev/null && return 1
    [ -n "$pane" ] || return 0
    kill -0 "$pane" 2>/dev/null && return 1
    [ -z "$(pgrep -P "$pane" 2>/dev/null)" ] || return 1
    return 0
}

# ---------------------------------------------------------------------------
# reconcile
# ---------------------------------------------------------------------------
#
# A run whose process died without running its EXIT trap — the VM stopped under
# it, a stray `tmux kill-server`, the guest out of memory — leaves `running` in
# its status file for ever. `runs` then lists it as running, `status` shows an
# elapsed time that grows without end, and `logs -f` blocks with nothing coming.
#
# So `runs`, `status` and `agentbox start` reconcile first: a run that says it
# is running, has no tmux session, and whose recorded pid is not alive, becomes
# `exit:lost`. Lost rather than failed, because what happened to it is exactly
# what nobody knows.

reconcile_run() {
    local runid="${1:?}" dir pid
    dir="${ABX_RUNS_DIR}/${runid}"
    [ -d "$dir" ] || return 0
    [ "$(abx_status_read "$dir")" = "running" ] || return 0
    tmux has-session -t "=run-${runid}" 2>/dev/null && return 0
    pid=$(cat "${dir}/pid" 2>/dev/null) || pid=""
    case "$pid" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$pid" 2>/dev/null && return 0 ;;
    esac
    abx_status_write "$dir" "exit:lost"
    printf 'run-ctl: %s was left recorded as running with nothing behind it; marked exit:lost\n' \
        "$runid" >&2
}

cmd_reconcile() {
    local d runid
    [ -d "$ABX_RUNS_DIR" ] || return 0
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        reconcile_run "$runid"
    done
}

# The newest run whose status is still `running`, or nothing.
newest_running() {
    local d runid newest=""
    [ -d "$ABX_RUNS_DIR" ] || return 1
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        [ "$(abx_status_read "$d")" = "running" ] || continue
        newest="$runid"
    done
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# ---------------------------------------------------------------------------
# sessions
# ---------------------------------------------------------------------------

# The raw list, as JSON, built by jq so that a session name containing a quote
# or a brace cannot forge or erase an entry. Printing is somebody else's job:
# see cmd_sessions.
#
# Seven fields per row, because "this box has three tmux sessions" does not say
# which of them did the work: `kind` and `runid` name the row's owner, `produced`
# names what a run left behind, and `raw_state` is the status file's own word,
# mapped to the reported vocabulary by run-format.py. Every one of them arrives
# through --arg or --argjson: the name is agent-chosen, and the only reason a
# name full of JSON cannot forge a row is that nothing here concatenates.
sessions_json() {
    local now raw name created fmt first=1
    now=$(date +%s)
    # A REAL tab, produced by printf, because tmux does not expand \t in a
    # format string — it emits a literal backslash and a t, which puts the
    # timestamp inside the name and leaves every age at zero. The creation time
    # comes first as well, so that a name containing a tab, a space or a
    # newline cannot be mistaken for the field before it.
    fmt=$(printf '#{session_created}\t#{session_name}')
    raw=$(tmux list-sessions -F "$fmt" 2>/dev/null) || raw=""

    printf '['
    while IFS=$'\t' read -r created name; do
        [ -n "$name" ] || continue
        case "$created" in ''|*[!0-9]*) created="$now" ;; esac
        [ "$first" -eq 1 ] || printf ','
        first=0
        jq -cn --arg name "$name" \
               --arg kind "$(session_kind "$name")" \
               --arg runid "$(session_runid "$name")" \
               --arg raw_state "$(session_raw_state "$name")" \
               --argjson age "$((now - created))" \
               --argjson last "$(last_event_json "$name")" \
               --argjson produced "$(session_produced_json "$name")" \
               '{name: $name, kind: $kind,
                 runid: (if $runid == "" then null else $runid end),
                 raw_state: $raw_state, age_s: $age, last_event: $last,
                 produced: $produced}'
    done <<< "$raw"
    printf ']'
}

# Through run-format.py, like every other output. A tmux session name is chosen
# by whoever created the session, and inside a run that is the agent: one
# `tmux new-session -s "$CLAUDE_CODE_OAUTH_TOKEN"` would otherwise print the
# whole credential to the host terminal. This was the one guest-to-host path
# that never met the scrubber.
cmd_sessions() {
    local as_json=""
    [ "${1:-}" = "--json" ] && as_json="--json"
    sessions_json | python3 "${ABX_LIB_DIR}/run-format.py" --sessions-in $as_json
}

# The last hook event a session recorded, which is the cheapest honest answer
# to "is anything still happening in there". Interactive sessions keep theirs
# under ~/.agent-box/sessions/<name>; a run keeps its under the run directory.
# Always valid JSON, so the jq above can take it with --argjson.
session_hooks_file() {
    local name="${1:?}"
    case "$name" in
        run-*)
            abx_valid_runid "${name#run-}" || return 1
            printf '%s/hooks.jsonl' "$(abx_run_dir "${name#run-}")" ;;
        *)
            abx_valid_session_name "$name" || return 1
            printf '%s/hooks.jsonl' "$(abx_session_dir "$name")" ;;
    esac
}

last_event_json() {
    local f out
    f=$(session_hooks_file "$1" 2>/dev/null) || { printf 'null'; return 0; }
    [ -n "$f" ] && [ -s "$f" ] || { printf 'null'; return 0; }
    out=$(tail -1 "$f" | jq -c '{ts: .ts, event: .event}' 2>/dev/null) || out=""
    [ -n "$out" ] || out="null"
    printf '%s' "$out"
}

# Did this session do the work, or does it only share the disk? Three answers,
# and the same prefix routing session_hooks_file above already does:
#
#   run      the session a run started: `run-` and a valid run id, so there is a
#            run directory with a status, a brief and a branch behind it
#   session  a name with a session directory of its own under ~/.agent-box —
#            the standing session, and anything else agent-box itself tracks
#   other    neither: a shell somebody opened, a devserver the agent started
#
# A name is checked before it is used to build a path, and `run-` wins over a
# session directory of the same name: a run id is the more specific claim.
session_kind() {
    local name="${1:?}"
    case "$name" in
        run-*)
            if abx_valid_runid "${name#run-}"; then printf 'run'; return 0; fi ;;
    esac
    if abx_valid_session_name "$name" && [ -d "$(abx_session_dir "$name")" ]; then
        printf 'session'
        return 0
    fi
    printf 'other'
}

# The run id behind a `run-` session, or nothing at all. Nothing becomes `null`
# in the row, which is the honest answer for a session that is not a run's.
session_runid() {
    local name="${1:?}"
    case "$name" in
        run-*) abx_valid_runid "${name#run-}" && printf '%s' "${name#run-}" ;;
    esac
    return 0
}

# The status FILE's word for whichever directory the row names, not a derived
# state: `running`, `exit:<code>`, `exit:stopped`, `exit:lost` or `unknown`,
# through abx_status_read, so bytes that are none of those are never echoed.
#
# The mapping to what a caller reads lives in run-format.py, in one place for
# both vocabularies. For a `session` row that raw word is all there is, and it
# maps to running / ended / unknown. For a `run` row run-format.py reads the run
# directory itself instead of trusting this, because the two markers that turn
# an exit code into `stopped` or `waiting` are files beside the status that no
# single word can carry.
session_raw_state() {
    local name="${1:?}" dir
    case "$(session_kind "$name")" in
        run)     dir=$(abx_run_dir "${name#run-}") ;;
        session) dir=$(abx_session_dir "$name") ;;
        *)       printf 'unknown'; return 0 ;;
    esac
    printf '%s' "$(abx_status_read "$dir")"
}

# What a run produced, which is the branch its work is on: the one fact that
# tells a finished run apart from a session that merely ran in the same box.
# `null` for every other kind of row, and always valid JSON, so --argjson
# cannot lose the whole row to a missing meta.json (the last_event_json rule).
session_produced_json() {
    local name="${1:?}" runid out dir
    runid=$(session_runid "$name")
    [ -n "$runid" ] || { printf 'null'; return 0; }
    dir=$(abx_run_dir "$runid")
    # A regular file, or the same answer a missing meta.json already gives. The
    # run id here comes from a TMUX SESSION NAME, so nothing says the run
    # directory exists or that meta.json is a file: a FIFO in its place would
    # block jq, and with it `agentbox sessions` and every `status` that folds
    # this box in. The same rule abx_status_read follows for the status.
    [ -f "${dir}/meta.json" ] || { printf '{"branch":null}'; return 0; }
    out=$(jq -cn --arg b "$(meta_field "$dir" branch)" \
        '{branch: (if $b == "" then null else $b end)}' 2>/dev/null) || out=""
    [ -n "$out" ] || out='null'
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# latest
# ---------------------------------------------------------------------------

# The state a caller should act on, derived exactly the way run-format.py
# derives it — the two must agree, because one drives `run --wait` and the
# notification watcher and the other drives `runs` and `status --json`.
#
# The status file keeps the code the run exited with; a `stopped` marker beside
# it says the run was interrupted. `exit:3` is never reinterpreted: it is the
# leak check's, and `logs` keys its refusal off exactly that string.
#
# Every state emitted here must be accepted by bin/agentbox:valid_run_state, or
# the host silently calls it unknown (agent-box#24).
derived_state() {
    local dir="${1:?}" raw
    raw=$(abx_status_read "$dir")
    case "$raw" in
        # Two exemptions, and run-format.py tests both before it looks at the
        # marker. exit:3 because the leak is the headline. exit:lost because a
        # lost run's fate is by definition unknown: the marker and the status
        # are written two statements apart in finish(), so a marker with
        # `exit:lost` beside it means finish() started and did not get to
        # write its status — exactly the case where claiming a clean stop
        # would be a guess.
        exit:3|exit:lost) ;;
        exit:*)
            # A stop outranks a question: an interrupted run that had also
            # written ask.md was stopped, and saying `waiting` would invite an
            # answer nobody is going to read.
            if [ -e "${dir}/stopped" ]; then raw="exit:stopped"
            elif [ -e "${dir}/waiting" ]; then raw="exit:waiting"
            fi ;;
    esac
    printf '%s' "$raw"
}

# What the host reads to decide what `run --wait` should exit with and when a
# `--notify` watcher should fire.
cmd_state() {
    local runid="${1:-}"
    if [ -z "$runid" ]; then
        runid=$(cmd_latest) || true
        [ -n "$runid" ] || { printf 'unknown\n'; return 0; }
    fi
    printf '%s\n' "$(derived_state "$(abx_run_dir "$runid")")"
}

# `runs`, with the orphan reconciliation in front of it, in one round trip.
cmd_runs() {
    cmd_reconcile
    exec python3 "${ABX_LIB_DIR}/run-format.py" --list "$@"
}

cmd_latest() {
    [ -d "$ABX_RUNS_DIR" ] || return 1
    local newest=""
    local d
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        newest=${d##*/}
    done
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

# ---------------------------------------------------------------------------
# heal, resume, ask, learnings
# ---------------------------------------------------------------------------
#
# The self-healing loop lives here, in the guest, because the point of it is a
# box that recovers with nobody at the host. A failed run with heal budget left
# starts its own follow-up; a run that stopped to ask records `waiting` and is
# resumed with the operator's answer; both follow-ups carry the ORIGINAL brief,
# never a nested heal brief, so the chain cannot grow a prompt.

# A field from a run's meta.json, or empty.
meta_field() {
    local dir="${1:?}" key="${2:?}"
    jq -r --arg k "$key" 'if has($k) and .[$k] != null then (.[$k]|tostring) else empty end' \
        "${dir}/meta.json" 2>/dev/null | head -1
}

# A fresh run id that is not the one given: two runs cannot share a second.
fresh_runid_after() {
    local avoid="${1:-}" id
    id=$(date -u +%Y%m%d-%H%M%S)
    while [ "$id" = "$avoid" ] || [ -d "${ABX_RUNS_DIR}/${id}" ]; do
        sleep 1
        id=$(date -u +%Y%m%d-%H%M%S)
    done
    printf '%s' "$id"
}

# The brief every follow-up is built on: the run's own origin's brief, so a
# heal of a heal still carries the operator's words and not last attempt's
# preamble. Falls back to the run's own brief when there is no origin.
origin_brief_of() {
    local dir="${1:?}" runid="${2:?}" origin f
    origin=$(meta_field "$dir" origin)
    [ -n "$origin" ] && abx_valid_runid "$origin" || origin="$runid"
    f="${ABX_BRIEFS_DIR}/${origin}.md"
    [ -f "$f" ] || f="${ABX_BRIEFS_DIR}/${runid}.md"
    [ -f "$f" ] || return 1
    printf '%s\t%s' "$origin" "$f"
}

# Substitute {KEY} placeholders in a template with values read from files, so
# a value containing a slash, an ampersand or a newline cannot break the
# template. The last placeholder, {BRIEF}, is the whole original brief.
render_template() {
    # render_template TEMPLATE OUT KEY=FILE...
    local tpl="${1:?}" out="${2:?}"; shift 2
    python3 - "$tpl" "$out" "$@" <<'PYX'
import sys
tpl, out = sys.argv[1], sys.argv[2]
text = open(tpl, encoding="utf-8", errors="replace").read()
for kv in sys.argv[3:]:
    key, _, path = kv.partition("=")
    try:
        val = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        val = ""
    text = text.replace("{" + key + "}", val.rstrip("\n"))
with open(out, "w", encoding="utf-8") as fh:
    fh.write(text)
PYX
}

# Start a follow-up of `parent` from `brief`, inheriting model, caps, origin,
# delay and the remaining heal budget as given. Prints the child run id.
start_followup() {
    # start_followup PARENT_DIR PARENT_RUNID BRIEF_PATH CHILD_RUNID HEAL_LEFT KIND [MODEL]
    local pdir="${1:?}" parent="${2:?}" brief="${3:?}" child="${4:?}" heal_left="${5:?}" kind="${6:?}" model_override="${7:-}"
    local model slug branch turns budget heal_max attempt origin heal_delay delay="" review_model
    model=$(meta_field "$pdir" model); [ -n "$model" ] || model="sonnet"
    [ -z "$model_override" ] || model="$model_override"
    slug=$(meta_field "$pdir" slug)
    if [ -z "$slug" ]; then
        branch=$(meta_field "$pdir" branch)
        slug=${branch#agent/}; slug=${slug%-"$parent"}
    fi
    [ -n "$slug" ] || slug="task"
    turns=$(meta_field "$pdir" max_turns)
    budget=$(meta_field "$pdir" max_budget_usd)
    heal_max=$(meta_field "$pdir" heal_max)
    attempt=$(meta_field "$pdir" heal_attempt); [ -n "$attempt" ] || attempt=0
    origin=$(meta_field "$pdir" origin); [ -n "$origin" ] || origin="$parent"
    heal_delay=$(meta_field "$pdir" heal_delay)
    review_model=$(meta_field "$pdir" review_model)
    # A review of the origin's work is still owed after a heal or a resume, so
    # the reviewer's name travels down the chain. It never travels into a
    # review: that run reviews, it is not reviewed.
    case "$kind" in review) review_model="" ;; esac
    [ -z "$review_model" ] || [ "$review_model" != "$model" ] || review_model=""

    local args=(--runid "$child" --slug "$slug" --model "$model" --brief "$brief" --origin "$origin")
    [ -n "$review_model" ] && args+=(--review-model "$review_model")
    [ -n "$turns" ]  && args+=(--max-turns "$turns")
    [ -n "$budget" ] && args+=(--max-budget-usd "$budget")
    [ -n "$heal_max" ] && args+=(--heal-max "$heal_max")
    [ -n "$heal_delay" ] && args+=(--heal-delay "$heal_delay")
    args+=(--heal-left "$heal_left")
    case "$kind" in
        heal)
            args+=(--heal-parent "$parent" --heal-attempt "$((attempt + 1))")
            [ -z "$heal_delay" ] || args+=(--delay "$heal_delay") ;;
        resume)
            args+=(--resume-of "$parent")
            # A resumed run keeps the attempt count it had, so a heal after a
            # resume still counts against the same budget.
            [ "$attempt" -eq 0 ] || args+=(--heal-attempt "$attempt") ;;
        review)
            args+=(--review-of "$parent") ;;
    esac
    cmd_start "${args[@]}" >/dev/null || return 1
    printf '%s\n' "$child"
}

cmd_heal() {
    local of="" parent_state="" parent_exit="" dir state heal_left child brief origin_line origin obrief
    while [ $# -gt 0 ]; do
        case "$1" in
            --of)           of="${2:?--of needs a run id}"; shift 2 ;;
            --parent-state) parent_state="${2:?--parent-state needs a value}"; shift 2 ;;
            --parent-exit)  parent_exit="${2:?--parent-exit needs a value}"; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    [ -n "$of" ] || die "heal needs --of RUNID"
    dir=$(abx_run_dir "$of")
    [ -f "${dir}/meta.json" ] || die "no such run: ${of}"

    # The run's own finish() calls this while its status still says running,
    # and tells us what it is about to record. Anyone else asks the record.
    if [ -n "$parent_state" ]; then
        state="$parent_state"
    else
        case "$(derived_state "$dir")" in
            exit:lost) state="lost" ;;
            exit:3)    state="leak" ;;
            exit:stopped) state="stopped" ;;
            exit:waiting) state="waiting" ;;
            exit:0)    state="done" ;;
            exit:*)    state="failed" ;;
            *)         state="running" ;;
        esac
    fi
    case "$state" in
        failed|lost) ;;
        *) die "run ${of} is ${state}; only a failed or lost run is healed" ;;
    esac

    heal_left=$(meta_field "$dir" heal_left)
    case "$heal_left" in ''|*[!0-9]*) heal_left=0 ;; esac
    if [ "$heal_left" -le 0 ]; then
        printf 'run-ctl: %s has no heal budget left; not starting a follow-up\n' "$of" >&2
        return 2
    fi

    origin_line=$(origin_brief_of "$dir" "$of") || die "no brief on record for ${of}; cannot heal it"
    origin=${origin_line%%$'\t'*}; obrief=${origin_line#*$'\t'}

    child=$(fresh_runid_after "$of")
    brief="${ABX_BRIEFS_DIR}/${child}.md"

    local tmp; tmp=$(mktemp -d -t agent-box-heal.XXXXXX)
    local attempt heal_max
    attempt=$(meta_field "$dir" heal_attempt); [ -n "$attempt" ] || attempt=0
    heal_max=$(meta_field "$dir" heal_max); [ -n "$heal_max" ] || heal_max=$((attempt + heal_left))
    printf '%s' "$((attempt + 1))"                    > "${tmp}/ATTEMPT"
    printf '%s' "$heal_max"                           > "${tmp}/MAX"
    printf '%s' "$of"                                 > "${tmp}/PARENT"
    printf '%s' "$state"                              > "${tmp}/STATE"
    # The run's own exit code when it told us (its status file still says
    # running while its exit path is calling this); the record otherwise.
    if [ -n "$parent_exit" ]; then printf '%s' "$parent_exit" > "${tmp}/EXIT"
    else printf '%s' "$(abx_status_read "$dir" | sed 's/^exit://')" > "${tmp}/EXIT"; fi
    printf '%s' "$(meta_field "$dir" branch)"         > "${tmp}/BRANCH"
    jq -r 'select(.type=="result") | .subtype // "-"' "${dir}/events.jsonl" 2>/dev/null | tail -1 > "${tmp}/RESULT"
    [ -s "${tmp}/RESULT" ] || printf -- '-' > "${tmp}/RESULT"
    # The console tail, stripped of its timestamps and cut to what a diagnosis
    # needs. Raw, because it stays inside the guest: this text becomes the next
    # run's prompt and never crosses to the host.
    tail -n 25 "${dir}/console.log" 2>/dev/null | sed -E 's/^[0-9T:-]+Z //' | cut -c1-400 > "${tmp}/TAIL"
    [ -s "${tmp}/TAIL" ] || printf '(no console output recorded)' > "${tmp}/TAIL"
    python3 "${ABX_LIB_DIR}/run-format.py" --last-text "$of" 2>/dev/null | cut -c1-1200 > "${tmp}/LAST_TEXT"
    [ -s "${tmp}/LAST_TEXT" ] || printf '(none)' > "${tmp}/LAST_TEXT"
    cp "$obrief" "${tmp}/BRIEF"

    ( umask 077; render_template "${ABX_LIB_DIR}/heal-brief.md" "$brief" \
        ATTEMPT="${tmp}/ATTEMPT" MAX="${tmp}/MAX" PARENT="${tmp}/PARENT" STATE="${tmp}/STATE" \
        EXIT="${tmp}/EXIT" BRANCH="${tmp}/BRANCH" RESULT="${tmp}/RESULT" TAIL="${tmp}/TAIL" \
        LAST_TEXT="${tmp}/LAST_TEXT" BRIEF="${tmp}/BRIEF" )
    rm -rf "$tmp"
    chmod 600 "$brief" 2>/dev/null || true

    start_followup "$dir" "$of" "$brief" "$child" "$((heal_left - 1))" heal \
        || die "could not start the heal run for ${of}"
}

# The commit the chain was cut from: the origin's base when it recorded one,
# else this run's own.
base_commit_of() {
    local dir="${1:?}" origin base
    origin=$(meta_field "$dir" origin)
    if [ -n "$origin" ] && abx_valid_runid "$origin" && [ -f "${ABX_RUNS_DIR}/${origin}/meta.json" ]; then
        base=$(meta_field "${ABX_RUNS_DIR}/${origin}" base_commit)
    fi
    [ -n "${base:-}" ] || base=$(meta_field "$dir" base_commit)
    [ -n "$base" ] || return 1
    printf '%s' "$base"
}

cmd_review() {
    local of="" parent_state="" dir state reviewer base ahead child brief origin_line obrief
    while [ $# -gt 0 ]; do
        case "$1" in
            --of)           of="${2:?--of needs a run id}"; shift 2 ;;
            --parent-state) parent_state="${2:?--parent-state needs a value}"; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    [ -n "$of" ] || die "review needs --of RUNID"
    dir=$(abx_run_dir "$of")
    [ -f "${dir}/meta.json" ] || die "no such run: ${of}"

    if [ -n "$parent_state" ]; then
        state="$parent_state"
    else
        case "$(derived_state "$dir")" in
            exit:0) state="done" ;;
            running) state="running" ;;
            *) state="other" ;;
        esac
    fi
    [ "$state" = "done" ] || die "run ${of} is ${state}; only a run that ended done is reviewed"
    [ -z "$(meta_field "$dir" review_of)" ] || die "run ${of} is itself a review; not reviewing a review"

    reviewer=$(meta_field "$dir" review_model)
    [ -n "$reviewer" ] || die "run ${of} did not ask for a review (no review model on record)"

    base=$(base_commit_of "$dir") || die "run ${of} recorded no base commit; cannot bound the diff"
    ahead=$(git -C "$ABX_WORK_DIR" rev-list --count "${base}..HEAD" 2>/dev/null) || ahead=""
    case "$ahead" in ''|*[!0-9]*) die "cannot count commits past ${base} in ${ABX_WORK_DIR}" ;; esac
    if [ "$ahead" -eq 0 ] && [ -z "$(git -C "$ABX_WORK_DIR" status --porcelain 2>/dev/null)" ]; then
        printf 'nothing to review: no commits past %s and a clean tree\n' "$(git -C "$ABX_WORK_DIR" rev-parse --short "$base")"
        return 2
    fi

    origin_line=$(origin_brief_of "$dir" "$of") || die "no brief on record for ${of}; cannot review it"
    obrief=${origin_line#*$'\t'}

    child=$(fresh_runid_after "$of")
    brief="${ABX_BRIEFS_DIR}/${child}.md"

    local tmp; tmp=$(mktemp -d -t agent-box-review.XXXXXX)
    printf '%s' "$of"                                  > "${tmp}/PARENT"
    printf '%s' "$(meta_field "$dir" model)"           > "${tmp}/MODEL"
    printf '%s' "$reviewer"                            > "${tmp}/REVIEWER"
    printf '%s' "$(meta_field "$dir" branch)"          > "${tmp}/BRANCH"
    printf '%s' "$base"                                > "${tmp}/BASE"
    # The commit list stays inside the guest: it becomes the reviewer's prompt.
    git -C "$ABX_WORK_DIR" log --oneline "${base}..HEAD" 2>/dev/null | head -50 > "${tmp}/COMMITS"
    [ -s "${tmp}/COMMITS" ] || printf '(no commits; uncommitted changes only)' > "${tmp}/COMMITS"
    git -C "$ABX_WORK_DIR" diff --stat "${base}" 2>/dev/null | tail -40 > "${tmp}/STAT"
    [ -s "${tmp}/STAT" ] || printf '(empty)' > "${tmp}/STAT"
    python3 "${ABX_LIB_DIR}/run-format.py" --last-text "$of" 2>/dev/null | cut -c1-1200 > "${tmp}/LAST_TEXT"
    [ -s "${tmp}/LAST_TEXT" ] || printf '(none)' > "${tmp}/LAST_TEXT"
    cp "$obrief" "${tmp}/BRIEF"

    ( umask 077; render_template "${ABX_LIB_DIR}/review-brief.md" "$brief" \
        PARENT="${tmp}/PARENT" MODEL="${tmp}/MODEL" REVIEWER="${tmp}/REVIEWER" BRANCH="${tmp}/BRANCH" \
        BASE="${tmp}/BASE" COMMITS="${tmp}/COMMITS" STAT="${tmp}/STAT" LAST_TEXT="${tmp}/LAST_TEXT" \
        BRIEF="${tmp}/BRIEF" )
    rm -rf "$tmp"
    chmod 600 "$brief" 2>/dev/null || true

    # The review keeps whatever heal budget the reviewed run had left: a review
    # that dies on the environment is healed like any other run.
    local heal_left; heal_left=$(meta_field "$dir" heal_left)
    case "$heal_left" in ''|*[!0-9]*) heal_left=0 ;; esac
    start_followup "$dir" "$of" "$brief" "$child" "$heal_left" review "$reviewer" \
        || die "could not start the review run for ${of}"
}

# The newest run recorded as waiting, or nothing.
newest_waiting() {
    local d runid newest=""
    [ -d "$ABX_RUNS_DIR" ] || return 1
    for d in "$ABX_RUNS_DIR"/*/; do
        [ -f "${d}meta.json" ] || continue
        d=${d%/}
        runid=${d##*/}
        abx_valid_runid "$runid" || continue
        [ "$(derived_state "$d")" = "exit:waiting" ] || continue
        newest="$runid"
    done
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

cmd_resume() {
    local of="" dir state child brief origin_line obrief heal_left
    while [ $# -gt 0 ]; do
        case "$1" in
            --of) of="${2:?--of needs a run id}"; shift 2 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    if [ -z "$of" ]; then
        of=$(newest_waiting) || die "no run is waiting. 'agentbox runs <repo>' lists what there is."
        printf 'run-ctl: resuming %s, the newest waiting run\n' "$of" >&2
    fi
    dir=$(abx_run_dir "$of")
    [ -f "${dir}/meta.json" ] || die "no such run: ${of}"
    state=$(derived_state "$dir")
    case "$state" in
        running) die "run ${of} is still running; stop it or wait for it" ;;
        exit:3)  die "run ${of} tripped the leak check; rotate the token before anything else" ;;
    esac

    local tmp; tmp=$(mktemp -d -t agent-box-resume.XXXXXX)
    # The answer arrives on stdin, so it is never an argument and never in a
    # process listing. Empty is refused: a resume with nothing to say is a
    # re-run, and `agentbox run` is how you do one of those.
    cat > "${tmp}/ANSWER"
    [ -s "${tmp}/ANSWER" ] || { rm -rf "$tmp"; die "the answer is empty; nothing to resume with"; }

    origin_line=$(origin_brief_of "$dir" "$of") || { rm -rf "$tmp"; die "no brief on record for ${of}; cannot resume it"; }
    obrief=${origin_line#*$'\t'}

    if [ -f "${dir}/ask.md" ]; then
        cut -c1-4000 "${dir}/ask.md" > "${tmp}/ASK"
    else
        printf '(the run did not leave a question; the operator is giving instructions)' > "${tmp}/ASK"
    fi
    printf '%s' "$of" > "${tmp}/PARENT"
    printf '%s' "${state#exit:}" > "${tmp}/STATE"
    printf '%s' "$(meta_field "$dir" branch)" > "${tmp}/BRANCH"
    cp "$obrief" "${tmp}/BRIEF"

    child=$(fresh_runid_after "$of")
    brief="${ABX_BRIEFS_DIR}/${child}.md"
    ( umask 077; render_template "${ABX_LIB_DIR}/resume-brief.md" "$brief" \
        PARENT="${tmp}/PARENT" STATE="${tmp}/STATE" BRANCH="${tmp}/BRANCH" \
        ASK="${tmp}/ASK" ANSWER="${tmp}/ANSWER" BRIEF="${tmp}/BRIEF" )
    rm -rf "$tmp"
    chmod 600 "$brief" 2>/dev/null || true

    heal_left=$(meta_field "$dir" heal_left)
    case "$heal_left" in ''|*[!0-9]*) heal_left=0 ;; esac

    # The question has been answered; a stale ask.md must not mark the next
    # run as waiting the moment it starts.
    rm -f "${AGENT_BOX_WORK:-/work}/.agent-box/ask.md" 2>/dev/null || true

    start_followup "$dir" "$of" "$brief" "$child" "$heal_left" resume \
        || die "could not start the resumed run for ${of}"
}

# The question a waiting run left, scrubbed on its way out.
cmd_ask() {
    local runid="${1:-}"
    if [ -z "$runid" ]; then
        runid=$(newest_waiting) || die "no run is waiting."
    fi
    abx_valid_runid "$runid" || die "not a run id: ${runid}"
    exec python3 "${ABX_LIB_DIR}/run-format.py" --ask "$runid"
}

# What the runs wrote down, scrubbed on its way out.
cmd_learnings() {
    exec python3 "${ABX_LIB_DIR}/run-format.py" --learnings
}

# ---------------------------------------------------------------------------

case "${1:-}" in
    start)    shift; cmd_start "$@" ;;
    stop)     shift; cmd_stop "$@" ;;
    sessions)  shift; cmd_sessions "$@" ;;
    state)     shift; cmd_state "$@" ;;
    runs)      shift; cmd_runs "$@" ;;
    reconcile) shift; cmd_reconcile ;;
    latest)    shift; cmd_latest ;;
    heal)      shift; cmd_heal "$@" ;;
    resume)    shift; cmd_resume "$@" ;;
    review)    shift; cmd_review "$@" ;;
    ask)       shift; cmd_ask "$@" ;;
    learnings) shift; cmd_learnings ;;
    *) die "usage: run-ctl.sh start|stop|sessions|state|runs|reconcile|latest|heal|resume|review|ask|learnings" ;;
esac
