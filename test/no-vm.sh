#!/usr/bin/env bash
#
# agent-box — no-VM regression checks.
#
# Eleven checks the implementers wrote as throwaway scripts while reviewing
# bin/agentbox, guest/lib.sh and the status document, promoted here so a
# regression in any of them fails a test run instead of waiting for someone to
# remember a fixture under /tmp. Every function under test is pulled out of the
# real file with `sed`, never by sourcing bin/agentbox whole — it ends in a
# command dispatch that would try to run one with no arguments — and every
# fixture (throwaway git repositories, fabricated /proc files, a fabricated run
# directory, a FIFO where a sensor expects a file) is built by this script and
# thrown away with it. The one whole-command check drives `agentbox status`
# itself over test/fake-limactl, which is a stand-in and not a VM.
#
# No VM, no limactl, no network. Seconds to run.
#
# Usage: test/no-vm.sh
# Exit 0 if every check passed, 1 otherwise.

set -uo pipefail

BOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENTBOX="${BOX_DIR}/bin/agentbox"
LIBSH="${BOX_DIR}/guest/lib.sh"
RUNFORMAT="${BOX_DIR}/guest/run-format.py"
SMOKE="${BOX_DIR}/test/smoke.sh"
PY="${PY:-python3}"
# shellcheck disable=SC2034  # read by die(), sourced dynamically from bin/agentbox below
PROG=agentbox

WORK=$(mktemp -d -t agent-box-no-vm.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'bad  %s\n' "$1"; }
section() { printf -- '\n-- %s --\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. repo_git: the fsmonitor / hooksPath / pager escape (bin/agentbox verdict 4)
# ---------------------------------------------------------------------------
#
# A repository can name a program in its own .git/config three ways, and only
# one of the three does anything when the caller captures output in `$(...)`.
# The vacuity guard is therefore not optional: without it, a check that
# captures output the way the first draft of this one did would pass whether
# or not repo_git protects anything at all.
check_repo_git() {
    section "repo_git: the fsmonitor / hooksPath / pager escape"
    local rg="${WORK}/repo-git"
    mkdir -p "$rg"

    sed -n '/^repo_git() {/,/^}/p' "$AGENTBOX" > "${rg}/repo_git.sh"
    if [ -s "${rg}/repo_git.sh" ]; then ok "repo_git extracted from bin/agentbox"
    else bad "could not extract repo_git from bin/agentbox"; return; fi
    if grep -q -- '--no-pager' "${rg}/repo_git.sh" \
       && grep -q 'core.fsmonitor=false' "${rg}/repo_git.sh" \
       && grep -q 'core.hooksPath=/dev/null' "${rg}/repo_git.sh"; then
        ok "repo_git carries all three protections"
    else
        bad "repo_git is missing one of --no-pager / core.fsmonitor=false / core.hooksPath=/dev/null"
    fi

    local m="${rg}/markers" repo="${rg}/hostile"
    mkdir -p "$m"
    git init -q "$repo"
    (
        cd "$repo" || exit 1
        git config user.email a@b.c
        git config user.name check
        printf x > f
        git add f
        git commit -qm init
        git config core.fsmonitor "touch ${m}/RAN-fsmonitor; false"
        mkdir -p .git/evilhooks
        printf '#!/bin/sh\ntouch %s/RAN-hook\n' "$m" > .git/evilhooks/post-checkout
        chmod +x .git/evilhooks/post-checkout
        git config core.hooksPath "$(pwd)/.git/evilhooks"
        for v in rev-parse rev-list symbolic-ref for-each-ref; do
            git config "pager.${v}" "touch ${m}/RAN-pager-${v}; cat"
        done
    ) >/dev/null 2>&1

    cat > "${rg}/verbs.sh" <<'SH'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$1"
R="$2"; M="$3"
rm -f "${M}"/RAN-*
if [ -t 1 ]; then printf 'stdout: a terminal\n'; else printf 'stdout: not a terminal\n'; fi
# Deliberately NOT redirected: git decides whether to page from its OWN
# stdout's isatty(), so piping each call to /dev/null here would make every
# call look like a non-terminal regardless of the pty this script runs under
# (or does not), and the pty-based assertion below would pass whether or not
# repo_git carries --no-pager. Real repo output is allowed to reach this
# script's own stdout, same as vacuous.sh; the caller only greps for the
# markers, never for the repository's text.
repo_git "$R" rev-parse --abbrev-ref HEAD
repo_git "$R" rev-list --count HEAD
repo_git "$R" symbolic-ref --short HEAD
repo_git "$R" for-each-ref --format='%(refname:short)' refs/heads
if [ -n "$(ls -A "$M" 2>/dev/null)" ]; then ls "$M" | sed 's/^/RAN: /'; else printf 'nothing from the repository ran\n'; fi
SH
    cat > "${rg}/vacuous.sh" <<'SH'
#!/bin/bash
# The guard: the SAME verbs with no protection at all must trip the markers,
# or the checks below prove nothing about repo_git's flags. Git decides
# whether to page from its OWN stdout's tty-ness, so this must NOT redirect
# output the way an easy first draft of this check did (`>/dev/null` turns
# stdout into a pipe and silently makes the guard vacuous) — the git output
# itself is noise the caller's `case` patterns already ignore.
set -uo pipefail
R="$1"; M="$2"
rm -f "${M}"/RAN-*
if [ -t 1 ]; then printf 'stdout: a terminal\n'; else printf 'stdout: not a terminal\n'; fi
git -C "$R" rev-parse --abbrev-ref HEAD
git -C "$R" rev-list --count HEAD
git -C "$R" symbolic-ref --short HEAD
git -C "$R" for-each-ref --format='%(refname:short)' refs/heads
if [ -n "$(ls -A "$M" 2>/dev/null)" ]; then ls "$M" | sed 's/^/RAN: /'; else printf 'nothing ran\n'; fi
SH
    # Not named pty.py: that shadows the stdlib module it imports.
    cat > "${rg}/ptyrun.py" <<'PY'
import os, pty, sys
sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))
PY

    local out
    out=$("$PY" "${rg}/ptyrun.py" bash "${rg}/vacuous.sh" "$repo" "$m" 2>&1 | tr -d '\r')
    case "$out" in
        *"RAN: RAN-pager-"*) ok "vacuity guard: an unprotected pager.<verb> does fire under a pty" ;;
        *) bad "vacuity guard: no pager fired even unprotected (this git/pty exercises nothing): ${out}" ;;
    esac

    rm -f "${m}"/RAN-*
    ( cd "$repo" && git status >/dev/null 2>&1 ) || true
    if [ -e "${m}/RAN-fsmonitor" ]; then ok "vacuity guard: plain 'git status' DOES run the planted fsmonitor program"
    else bad "vacuity guard: plain 'git status' did not trip the fsmonitor marker; the fixture is dead"; fi

    out=$(bash "${rg}/verbs.sh" "${rg}/repo_git.sh" "$repo" "$m" 2>&1)
    case "$out" in
        *"nothing from the repository ran"*) ok "repo_git with stdout captured: nothing from the repository ran" ;;
        *) bad "repo_git with stdout captured: something ran: ${out}" ;;
    esac

    rm -f "${m}"/RAN-*
    out=$("$PY" "${rg}/ptyrun.py" bash "${rg}/verbs.sh" "${rg}/repo_git.sh" "$repo" "$m" 2>&1 | tr -d '\r')
    case "$out" in
        *"stdout: a terminal"*) : ;;
        *) bad "the pty did not give git a terminal; this check proves nothing: ${out}" ;;
    esac
    case "$out" in
        *"nothing from the repository ran"*) ok "repo_git under a pty: no pager, no fsmonitor, no hook ran" ;;
        *) bad "repo_git under a pty: a guest-chosen program ran on the host: ${out}" ;;
    esac
}

# ---------------------------------------------------------------------------
# 2. host_clip: invalid UTF-8 and control bytes (bin/agentbox host_clip)
# ---------------------------------------------------------------------------
#
# Run inside a `set -euo pipefail` caller doing a separate declare-then-assign
# (bin/agentbox's own style, SC2155): that combination is how a `tr`-based
# host_clip used to kill its caller outright on the very first hostile byte.
check_host_clip() {
    section "host_clip: invalid UTF-8 and control bytes"
    local hc="${WORK}/host-clip"
    mkdir -p "$hc"

    sed -n '/^host_clip() {/,/^}/p' "$AGENTBOX" > "${hc}/host_clip.sh"
    if [ -s "${hc}/host_clip.sh" ]; then ok "host_clip extracted from bin/agentbox"
    else bad "could not extract host_clip from bin/agentbox"; return; fi

    cat > "${hc}/caller.sh" <<'SH'
#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
. "$1"
hx() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
printf 'reached the first call\n'
local_out=""
local_out=$(host_clip $'py\xffthon' 80)
printf 'invalid byte -> %s\n' "$(hx "$local_out")"
local_out=$(host_clip $'no\x1b[31mde\tjs\n\rx' 80)
printf 'C0 controls  -> %s\n' "$(hx "$local_out")"
local_out=$(host_clip $'a\xc2\x9b31mb' 80)
printf 'U+009B CSI   -> %s\n' "$(hx "$local_out")"
local_out=$(host_clip abcdefgh 3)
printf 'cap 3        -> [%s]\n' "$local_out"
local_out=$(host_clip '' 8)
printf 'empty cap 8  -> [%s]\n' "$local_out"
printf 'reached the end\n'
SH

    local L out rc
    for L in en_US.UTF-8 C; do
        out=$(LC_ALL="$L" bash "${hc}/caller.sh" "${hc}/host_clip.sh" 2>&1); rc=$?
        if [ "$rc" -eq 0 ] && case "$out" in *"reached the end"*) true ;; *) false ;; esac; then
            ok "host_clip (LC_ALL=${L}): the caller survives every byte (set -e did not kill it)"
        else
            bad "host_clip (LC_ALL=${L}): the caller died part-way, rc=${rc}: ${out}"
        fi
        case "$out" in
            *"invalid byte -> 7079ff74686f6e"*) ok "host_clip (LC_ALL=${L}): an invalid UTF-8 byte passes through, nothing truncated" ;;
            *"invalid byte -> 7079"$'\n'*) bad "host_clip (LC_ALL=${L}): truncated at the invalid byte (the old tr abort)" ;;
            *) bad "host_clip (LC_ALL=${L}): unexpected result for the invalid byte: ${out}" ;;
        esac
        case "$out" in
            *"C0 controls  -> 6e6f5b33316d64656a7378"*) ok "host_clip (LC_ALL=${L}): C0 controls stripped, the rest kept" ;;
            *) bad "host_clip (LC_ALL=${L}): C0 controls not stripped as expected: ${out}" ;;
        esac
        case "$out" in
            *"U+009B CSI   -> 6133316d62"*) ok "host_clip (LC_ALL=${L}): the C1 CSI (U+009B) is gone" ;;
            *) bad "host_clip (LC_ALL=${L}): U+009B survived: ${out}" ;;
        esac
        case "$out" in
            *"cap 3        -> [abc]"*) ok "host_clip (LC_ALL=${L}): the character cap still works" ;;
            *) bad "host_clip (LC_ALL=${L}): cap did not clip to 3: ${out}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 3. the instance-meta race (bin/agentbox meta_lock / write_instance_meta*)
# ---------------------------------------------------------------------------
#
# Two real bash processes per round, so the tmp name's `$$` differs exactly as
# it does between two live `agentbox` invocations: one writes `keepalive on`
# then `repo` the way `cmd_keepalive` does, the other writes triage's three
# `boxonly` keys as a group. Either writer erasing the other's keys is the
# failure the record's own lock comment names. 50 rounds, not the 200 the
# review round used to be sure: even with no lock this loses keys on every
# single round on this host (measured while writing this check), so 50 already
# leaves no room for a coincidence and keeps the whole suite in single-digit
# seconds.
check_meta_race() {
    section "the instance-meta race (meta_lock / write_instance_meta*)"
    local mr="${WORK}/meta-race" rounds=50
    mkdir -p "$mr"

    {
        sed -n '/^META_LOCK_TRIES=/p' "$AGENTBOX"
        sed -n '/^meta_lock() {/,/^}/p' "$AGENTBOX"
        sed -n '/^meta_unlock() /p' "$AGENTBOX"
        sed -n '/^write_instance_meta() {/,/^}/p' "$AGENTBOX"
        sed -n '/^read_instance_meta_raw() {/,/^}/p' "$AGENTBOX"
        sed -n '/^backfill_instance_repo() {/,/^}/p' "$AGENTBOX"
        sed -n '/^write_instance_meta_multi() {/,/^}/p' "$AGENTBOX"
    } > "${mr}/writers.sh"
    if [ "$(grep -c '^[A-Za-z_]*() {\|^[A-Za-z_]*() ' "${mr}/writers.sh")" -eq 6 ]; then
        ok "all six meta helpers extracted from bin/agentbox"
    else
        bad "expected six extracted functions, got:"
        grep -n '^[A-Za-z_]*(' "${mr}/writers.sh"
        return
    fi

    cat > "${mr}/writer.sh" <<'SH'
#!/bin/bash
set -uo pipefail
INSTANCE_META_DIR="$1"
instance_meta_file() { printf '%s/%s' "$INSTANCE_META_DIR" "${1:?}"; }
# shellcheck source=/dev/null
. "$2"
case "$3" in
  keepalive) write_instance_meta box keepalive on; write_instance_meta box repo /Users/x/dev/app ;;
  multi)     write_instance_meta_multi box boxonly=yes boxonly_bytes=12345 boxonly_at=2026-09-19T00:00:00Z ;;
esac
SH

    local meta="${mr}/instances" lostK=0 lostM=0 lostR=0 strays=0 n
    mkdir -p "$meta"
    for _ in $(seq 1 "$rounds"); do
        rm -rf "${meta:?}"/*
        printf 'egress=deny\n' > "${meta}/box"
        bash "${mr}/writer.sh" "$meta" "${mr}/writers.sh" keepalive &
        bash "${mr}/writer.sh" "$meta" "${mr}/writers.sh" multi &
        wait
        grep -q '^keepalive=on$' "${meta}/box" || lostK=$((lostK + 1))
        grep -q '^boxonly=yes$'  "${meta}/box" || lostM=$((lostM + 1))
        grep -q '^egress=deny$'  "${meta}/box" || lostR=$((lostR + 1))
        # watchdog_run iterates this directory and treats every entry as an
        # instance name; a leaked lock dir or tmp file would be picked up by it.
        n=$(find "$meta" -mindepth 1 ! -name box | wc -l | tr -d ' ')
        [ "$n" -eq 0 ] || strays=$((strays + n))
    done
    if [ "$lostK" -eq 0 ]; then ok "${rounds} concurrent rounds: keepalive=on never lost"
    else bad "keepalive=on was erased ${lostK}/${rounds} times"; fi
    if [ "$lostM" -eq 0 ]; then ok "${rounds} concurrent rounds: the boxonly group never lost"
    else bad "the boxonly group was erased ${lostM}/${rounds} times"; fi
    if [ "$lostR" -eq 0 ]; then ok "${rounds} concurrent rounds: a key neither writer touched survives"
    else bad "a key neither writer touched was lost ${lostR}/${rounds} times"; fi
    if [ "$strays" -eq 0 ]; then ok "${rounds} concurrent rounds: no lock or tmp leftovers in the record directory"
    else bad "${strays} lock or tmp leftovers in the record directory"; fi

    rm -rf "${meta:?}"/*
    cat > "${mr}/bf.sh" <<'SH'
#!/bin/bash
set -uo pipefail
INSTANCE_META_DIR="$1"
instance_meta_file() { printf '%s/%s' "$INSTANCE_META_DIR" "${1:?}"; }
# shellcheck source=/dev/null
. "$2"
for _ in 1 2 3 4 5; do backfill_instance_repo box /Users/x/dev/app; done
printf 'repo lines: %s\n' "$(grep -c '^repo=' "$(instance_meta_file box)")"
before=$(stat -f %m "$(instance_meta_file box)")
sleep 1
for _ in 1 2 3; do backfill_instance_repo box /Users/x/dev/app; done
after=$(stat -f %m "$(instance_meta_file box)")
[ "$before" = "$after" ] && printf 'mtime unchanged: yes\n' || printf 'mtime unchanged: NO (%s -> %s)\n' "$before" "$after"
backfill_instance_repo box /Users/x/dev/other
grep -q '^repo=/Users/x/dev/other$' "$(instance_meta_file box)" && printf 'changed value written: yes\n' || printf 'changed value written: NO\n'
SH
    local out
    out=$(bash "${mr}/bf.sh" "$meta" "${mr}/writers.sh" 2>&1)
    case "$out" in *"repo lines: 1"*) ok "backfill_instance_repo: exactly one repo= line after five calls" ;;
        *) bad "backfill_instance_repo wrote more than one repo= line: ${out}" ;; esac
    case "$out" in *"mtime unchanged: yes"*) ok "backfill_instance_repo: no rewrite when the value already matches" ;;
        *) bad "backfill_instance_repo rewrites the file on every call: ${out}" ;; esac
    case "$out" in *"changed value written: yes"*) ok "backfill_instance_repo: a changed value still lands" ;;
        *) bad "backfill_instance_repo dropped a changed value: ${out}" ;; esac
}

# ---------------------------------------------------------------------------
# 4. valid_run_state (bin/agentbox valid_run_state)
# ---------------------------------------------------------------------------
check_valid_run_state() {
    section "valid_run_state: exit:lost accepted, hostile states rejected"
    local vr="${WORK}/vrs"
    mkdir -p "$vr"

    sed -n '/^valid_run_state() {/,/^}/p' "$AGENTBOX" > "${vr}/vrs.sh"
    if [ -s "${vr}/vrs.sh" ]; then ok "valid_run_state extracted from bin/agentbox"
    else bad "could not extract valid_run_state from bin/agentbox"; return; fi
    # shellcheck source=/dev/null
    . "${vr}/vrs.sh"

    local s
    for s in running exit:stopped exit:waiting exit:lost exit:0 exit:255; do
        if valid_run_state "$s"; then ok "valid_run_state accepts ${s}"
        else bad "valid_run_state rejects ${s} (should accept)"; fi
    done

    local pwn="${vr}/PWNED"
    # A state that looks like it might reach a shell somewhere downstream. This
    # function never evals or expands anything it is handed, and this check
    # exists to keep it that way: a future rewrite that grew a case arm doing
    # something clever with the value would trip it.
    local hostile='exit:0"; touch '"${pwn}"'; echo "x'
    for s in "$hostile" exit: exit:lostx exit:0x lost ''; do
        if valid_run_state "$s"; then bad "valid_run_state accepts hostile/malformed '${s}' (should reject)"
        else ok "valid_run_state rejects '${s:-<empty>}'"; fi
    done
    if [ -e "$pwn" ]; then bad "SECURITY: the hostile state executed something"
    else ok "the hostile state executed nothing"; fi
}

# ---------------------------------------------------------------------------
# 5. require_brief (bin/agentbox require_brief, abs_file, die)
# ---------------------------------------------------------------------------
#
# The vacuity guard here is `abs_file` called directly on the same missing
# in-repo-relative path: it must die WITHOUT the "there is a ... in ..." hint,
# proving the hint is require_brief's own guard clause and not something
# abs_file already did. Without this comparison, a require_brief that always
# fell straight through to abs_file would pass every other assertion below.
check_require_brief() {
    section "require_brief (agent-box#5): the four paths"
    local rb="${WORK}/require-brief"
    mkdir -p "$rb"

    {
        sed -n '/^die() { /p' "$AGENTBOX"
        sed -n '/^abs_file() {/,/^}/p' "$AGENTBOX"
        sed -n '/^require_brief() {/,/^}/p' "$AGENTBOX"
    } > "${rb}/require_brief.sh"
    if [ "$(grep -c '^die() \|^abs_file() \|^require_brief() ' "${rb}/require_brief.sh")" -eq 3 ]; then
        ok "die, abs_file and require_brief extracted from bin/agentbox"
    else
        bad "expected three extracted functions, got:"
        grep -n '^[a-z_]*(' "${rb}/require_brief.sh"
        return
    fi
    # shellcheck source=/dev/null
    . "${rb}/require_brief.sh"

    local repo="${rb}/repo" elsewhere="${rb}/elsewhere" out rc resolved
    mkdir -p "$repo" "$elsewhere"
    printf 'x\n' > "${repo}/in-repo.md"
    resolved=$(cd "$repo" && pwd -P)/in-repo.md

    out=$( (cd "$elsewhere" && require_brief "$repo" "in-repo.md") 2>&1 ); rc=$?
    case "$out" in
        *"there is a in-repo.md in ${repo}"*"name it as ${repo}/in-repo.md"*"cd there first"*)
            ok "require_brief: a relative brief missing here but present in the repo names it" ;;
        *) bad "require_brief did not give the in-repo hint: ${out}" ;;
    esac
    [ "$rc" -ne 0 ] || bad "require_brief exited 0 on a missing file"

    out=$( (cd "$elsewhere" && require_brief "$repo" "missing.md") 2>&1 ); rc=$?
    case "$out" in
        *"there is a"*) bad "require_brief invented an in-repo hint for a file that is not in the repo either: ${out}" ;;
        *"not a file: missing.md") ok "require_brief: missing everywhere stays the plain message" ;;
        *) bad "require_brief: unexpected message for missing-everywhere: ${out}" ;;
    esac
    [ "$rc" -ne 0 ] || bad "require_brief exited 0 on a missing file"

    out=$(require_brief "$repo" "${rb}/nope-abs.md" 2>&1); rc=$?
    case "$out" in
        *"there is a"*) bad "require_brief hinted on an absolute path (the guard should skip these): ${out}" ;;
        "agentbox: not a file: ${rb}/nope-abs.md") ok "require_brief: a missing absolute path stays the plain message" ;;
        *) bad "require_brief: unexpected message for a missing absolute path: ${out}" ;;
    esac
    [ "$rc" -ne 0 ] || bad "require_brief exited 0 on a missing file"

    out=$( (cd "$repo" && require_brief "$repo" "in-repo.md") 2>&1 ); rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$resolved" ]; then ok "require_brief: a brief that exists resolves to its absolute path"
    else bad "require_brief: the positive path returned '${out}' (rc=${rc}), wanted '${resolved}'"; fi

    out=$( (cd "$elsewhere" && abs_file "in-repo.md") 2>&1 ); rc=$?
    case "$out" in
        *"there is a"*) bad "vacuity guard failed: abs_file alone already gives the hint, so require_brief adds nothing" ;;
        "agentbox: not a file: in-repo.md") ok "vacuity guard: abs_file alone gives the plain message, no hint" ;;
        *) bad "vacuity guard: unexpected message from abs_file alone: ${out}" ;;
    esac
    [ "$rc" -ne 0 ] || bad "vacuity guard: abs_file exited 0 on a missing file"
}

# ---------------------------------------------------------------------------
# 6. the slot-list checker (test/smoke.sh's own SLOTS registry)
# ---------------------------------------------------------------------------
#
# Every slot a slice plants must be listed once in the `# SLOTS` header with
# its owner, and planted once as a start/end marker pair; FIN deletes both the
# markers and the header, at which point 0 listed / 0 planted is the right
# answer. Run first against a synthetic, deliberately broken registry (the
# vacuity guard: a checker that always says OK proves nothing), then for real
# against this checkout's test/smoke.sh.
check_slot_list() {
    section "the slot-list checker (test/smoke.sh SLOTS registry)"
    local sl="${WORK}/slots"
    mkdir -p "$sl"

    cat > "${sl}/check_slots.py" <<'PY'
"""Slot-registry check for test/smoke.sh.

Every slot a slice plants must be listed once in the `# SLOTS` header block
with its owner, and planted once as a start/end marker pair. FIN deletes the
markers AND the header block, at which point this reports 0 listed / 0
planted, which is the right answer for a finished suite.

Usage: check_slots.py <path to test/smoke.sh>
"""
import re
import sys

path = sys.argv[1]
text = open(path).read()
lines = text.splitlines()

listed = {}
dupes_listed = []
for ln in lines:
    m = re.match(r'^# SLOTS (.*)$', ln)
    if not m:
        continue
    for pair in m.group(1).split():
        label, _, owner = pair.partition('=')
        if label in listed:
            dupes_listed.append(label)
        listed[label] = owner

start = re.findall(r'^# ---- slot:(\S+) \(owner (\S+)\) ----$', text, re.M)
end = re.findall(r'^# ---- end slot:(\S+) ----$', text, re.M)

start_labels = [s[0] for s in start]
end_labels = list(end)
order = []
for lab in start_labels:
    if lab not in order:
        order.append(lab)

print(f"listed: {len(listed)}  start markers: {len(start_labels)}  end markers: {len(end_labels)}")
print("order in file: " + " ".join(order))

problems = []
if dupes_listed:
    problems.append(f"listed twice in the header: {dupes_listed}")
for lab in start_labels:
    if start_labels.count(lab) != 1:
        problems.append(f"slot {lab} planted {start_labels.count(lab)} times")
        break
if sorted(start_labels) != sorted(end_labels):
    problems.append(f"start/end mismatch: only-start={sorted(set(start_labels) - set(end_labels))} "
                    f"only-end={sorted(set(end_labels) - set(start_labels))}")
if sorted(listed) != sorted(set(start_labels)):
    problems.append(f"header vs planted: listed-not-planted={sorted(set(listed) - set(start_labels))} "
                    f"planted-not-listed={sorted(set(start_labels) - set(listed))}")
for lab, owner in start:
    if listed.get(lab) != owner:
        problems.append(f"slot {lab}: marker says owner {owner}, header says {listed.get(lab)}")

# The header block must itself spell no marker, or FIN's "= 0" stops meaning
# anything.
for ln in lines:
    if ln.startswith('# SLOTS') and 'slot:' in ln:
        problems.append("the SLOTS header block spells a marker; FIN's grep would still match it")

if problems:
    for p in problems:
        print("FAIL " + p)
    sys.exit(1)

if listed:
    print("OK every listed slot is planted once, with its owner, and nothing else is")
else:
    print("OK no slots listed and none planted (the finished shape FIN leaves behind)")
PY

    cat > "${sl}/broken-smoke.sh" <<'BROKEN'
#!/usr/bin/env bash
# SLOTS 1a=X 1b=Y
# ---- slot:1a (owner X) ----
echo one
# ---- end slot:1a ----
# ---- slot:1c (owner Z) ----
echo two
# ---- end slot:1c ----
BROKEN
    local out rc
    out=$("$PY" "${sl}/check_slots.py" "${sl}/broken-smoke.sh" 2>&1); rc=$?
    if [ "$rc" -ne 0 ] && case "$out" in *"1b"*"has no end marker"*|*"planted-not-listed"*"1c"*) true ;; *) false ;; esac; then
        ok "vacuity guard: the checker fails a deliberately broken registry (1b listed but never planted, 1c planted but never listed)"
    else
        bad "vacuity guard: the checker did not catch the broken registry: rc=${rc} ${out}"
    fi

    if [ -f "$SMOKE" ]; then
        out=$("$PY" "${sl}/check_slots.py" "$SMOKE" 2>&1); rc=$?
        if [ "$rc" -eq 0 ] && case "$out" in *"OK "*) true ;; *) false ;; esac; then
            ok "test/smoke.sh: every listed slot is planted once, with its owner, and nothing else is"
        else
            bad "test/smoke.sh's own slot registry has a problem: ${out}"
        fi
    else
        bad "test/smoke.sh not found at ${SMOKE}"
    fi
}

# ---------------------------------------------------------------------------
# 7. abx_proc_starttime with a newline in comm (guest/lib.sh)
# ---------------------------------------------------------------------------
#
# /proc prints a process's name unescaped, so a name containing a newline
# splits /proc/PID/stat across lines; reading only the first line cuts the
# record before the kernel's closing `)` and answers "no start time" for a
# process that is running perfectly well. Only the /proc PATH is redirected
# (by sed, on the text this script just extracted, not on a second copy of the
# whole file), so the fixture proves the shipped strip-through-the-last-`)`
# logic and not a rewritten stand-in for it.
check_proc_starttime() {
    section "abx_proc_starttime: a newline in comm (guest/lib.sh)"
    local sp="${WORK}/starttime"
    mkdir -p "${sp}/procpid"

    sed -n '/^abx_proc_starttime() {/,/^}/p' "$LIBSH" \
        | sed "s#/proc/\${pid}/stat#${sp}/procpid/\${pid}.stat#g" > "${sp}/starttime.sh"
    if [ -s "${sp}/starttime.sh" ] && grep -q "${sp}/procpid" "${sp}/starttime.sh"; then
        ok "abx_proc_starttime extracted from guest/lib.sh, /proc path redirected"
    else
        bad "could not extract or redirect abx_proc_starttime from guest/lib.sh"; return
    fi
    # shellcheck source=/dev/null
    . "${sp}/starttime.sh"

    printf '4242 (x) R 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0 0 0\n' \
        > "${sp}/procpid/4242.stat"
    printf '4243 (x\ny) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0 0 0\n' \
        > "${sp}/procpid/4243.stat"
    printf '4244 (a) b\ny) S 1 1 1 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 555 0 0 0 0\n' \
        > "${sp}/procpid/4244.stat"
    printf '5 (x) R not numbers here at all\n' > "${sp}/procpid/5.stat"

    local got rc
    got=$(abx_proc_starttime 4242)
    if [ "$got" = 987654 ]; then ok "abx_proc_starttime: an ordinary comm reads field 22"
    else bad "abx_proc_starttime: ordinary comm gave '${got}', wanted 987654"; fi

    got=$(abx_proc_starttime 4243)
    if [ "$got" = 987654 ]; then ok "abx_proc_starttime: survives a newline in comm"
    else bad "abx_proc_starttime: newline in comm gave '${got}', wanted 987654 (head -1 regression?)"; fi

    got=$(abx_proc_starttime 4244)
    if [ "$got" = 555 ]; then ok "abx_proc_starttime: survives a comm holding both ) and a newline"
    else bad "abx_proc_starttime: ) + newline in comm gave '${got}', wanted 555"; fi

    abx_proc_starttime 'x;id' >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 1 ]; then ok "abx_proc_starttime: refuses a non-numeric pid"
    else bad "abx_proc_starttime: accepted a non-numeric pid (rc=${rc})"; fi

    abx_proc_starttime 99999 >/dev/null 2>&1; rc=$?
    if [ "$rc" -eq 1 ]; then ok "abx_proc_starttime: refuses a missing stat file"
    else bad "abx_proc_starttime: did not refuse a missing stat file (rc=${rc})"; fi

    got=$(abx_proc_starttime 5 2>/dev/null); rc=$?
    if [ "$got" = "" ] && [ "$rc" -eq 1 ]; then ok "abx_proc_starttime: prints nothing for a short/malformed line"
    else bad "abx_proc_starttime: short line gave '${got}' rc=${rc}"; fi
}

# ---------------------------------------------------------------------------
# 8. the channel-read empty-id dispatch (guest/run-format.py)
# ---------------------------------------------------------------------------
#
# `--channel-read` both selects the mode and carries its argument. Dispatching
# on truthiness sends `--channel-read ""` to the log printer instead of the
# reader, which prints a run's console output framed as the answer and exits
# 0. The fixture's events.jsonl carries a line the log printer can print, so
# "the reader answered, not the log printer" is a real assertion and not true
# only because there was nothing to print.
check_channel_read() {
    section "the channel-read empty-id dispatch (guest/run-format.py)"
    if ! command -v "$PY" >/dev/null 2>&1; then
        bad "no python3 on PATH; cannot run this check"; return
    fi
    if [ ! -f "$RUNFORMAT" ]; then
        bad "guest/run-format.py not found at ${RUNFORMAT}"; return
    fi

    local cr="${WORK}/channel-read" run
    run="${cr}/state/runs/20260919-213042"
    mkdir -p "$run" "${cr}/work"
    printf '{"runid":"20260919-213042"}\n' > "${run}/meta.json"
    printf '%s\n' '{"type":"assistant","timestamp":"2026-09-19T21:30:42Z","message":{"content":[{"type":"text","text":"RUN LOG LINE that is not a channel message"}]}}' \
        > "${run}/events.jsonl"
    printf 'exit:0\n' > "${run}/state"

    local out rc id
    out=$(ABX_STATE_DIR="${cr}/state" AGENT_BOX_WORK="${cr}/work" "$PY" "$RUNFORMAT" 2>&1); rc=$?
    case "${out}:${rc}" in
        *"RUN LOG LINE"*:0) ok "vacuity guard: with no mode flag the fixture's run IS printed (exit 0)" ;;
        *) bad "vacuity guard: the fixture printed nothing to distinguish the reader from the log printer: ${out} (rc=${rc})" ;;
    esac

    for id in '' ' ' 'not-an-id' '../../etc/passwd' '20260919-153012-00'; do
        out=$(ABX_STATE_DIR="${cr}/state" AGENT_BOX_WORK="${cr}/work" "$PY" "$RUNFORMAT" --channel-read "$id" 2>&1); rc=$?
        case "$out" in
            *"RUN LOG LINE"*) bad "--channel-read '${id}' printed the run's log instead of answering as the reader" ;;
            *) if [ "$rc" -ne 0 ]; then ok "--channel-read '${id}' answers as the reader (exit ${rc}), never the log printer"
               else bad "--channel-read '${id}' exited 0 instead of failing as the (stub) reader"; fi ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 9. render_status's TEXT column: one row per box, whatever the guest says
# ---------------------------------------------------------------------------
#
# `channel_bar` states the premise this rests on: the guest scrubs its own
# output and the guest user has sudo over the renderer that does the scrubbing,
# so the host redoes what it can. The barred text keeps the newline because the
# bar makes a second line harmless; the status TABLE cannot be barred, so it has
# to lose more — a newline in one box's line prints a second row at column 0
# that an operator cannot tell from a box.
#
# Through the real `render_status`, over test/fake-limactl, with a handler
# standing in for the box's renderer. Nothing here builds a VM.
check_status_text_clamp() {
    section "render_status: a hostile guest text line is one row, and has no escape in it"
    local sc="${WORK}/status-clamp" cfg fake repo handler out rows
    cfg="${sc}/config"; fake="${sc}/fake"; repo="${sc}/app"; handler="${sc}/handler"
    mkdir -p "${cfg}/instances" "$fake" "$repo"
    printf 'repo=%s\n' "$repo" > "${cfg}/instances/agent-box-app"
    printf 'agent-box-app|Running|%s|4|6GiB|40GiB|%s\n' "$repo" "${sc}/lima" > "${fake}/instances"

    cat > "$handler" <<'HANDLER_EOF'
#!/usr/bin/env bash
shift
case "$*" in
    *box-status.sh*--text)
        case "${ST_TEXT_MODE:-row}" in
            # A whole extra row, at column 0, naming a box that does not exist.
            row) printf 'fw=deny  runs=0\nagent-box-ghost                running   fw=deny  (forged row)\n' ;;
            # U+009B in UTF-8: a CSI to a terminal in 8-bit mode, which can
            # erase and repaint the rows already printed above this one.
            csi) printf 'fw=deny  runs=0  \302\233\062K\302\233\061A(repainted)\n' ;;
            # A tab, which moves the column the rest of the table is aligned on.
            tab) printf 'fw=deny\truns=0\n' ;;
            esc) printf 'fw=deny  runs=0  \033[2K\033[1A(repainted)\n' ;;
        esac ;;
    *) exit 1 ;;
esac
HANDLER_EOF
    chmod +x "$handler"

    local mode
    for mode in row csi tab esc; do
        out="${sc}/out.${mode}"
        ST_TEXT_MODE="$mode" AGENT_BOX_CONFIG_DIR="$cfg" LIMACTL="${BOX_DIR}/test/fake-limactl" \
        FAKE_LIMA_DIR="$fake" FAKE_LIMA_SHELL="$handler" "$AGENTBOX" status > "$out" 2>&1
        # The header plus exactly one box row, for the one instance that exists.
        rows=$(wc -l < "$out" | tr -d ' ')
        if [ "$rows" = 2 ]; then
            ok "${mode}: one box prints one row (header + 1)"
        else
            bad "${mode}: one box printed ${rows} lines: $(LC_ALL=C cat -v "$out" | tr '\n' '/')"
        fi
        # A box row is a line that STARTS with a box name; what the guest says
        # inside its own cell is its own business. So the count of rows is the
        # assertion, not the absence of the word: `agent-box-ghost` may appear
        # in the third column of the one real row, and does.
        local named
        named=$(grep -c '^agent-box-' "$out" | tr -d ' ')
        if [ "$named" = 1 ] && grep -q '^agent-box-app ' "$out"; then
            ok "${mode}: exactly one line begins with a box name, and it is the real one"
        else
            bad "${mode}: ${named} lines begin with a box name: $(LC_ALL=C cat -v "$out" | tr '\n' '/')"
        fi
        # No control byte at all, and no C1 in either spelling. `cat -v` is what
        # makes the assertion readable when it fails: an ESC is `^[`, and the
        # UTF-8 C1 block is `M-BM-^[`-shaped.
        if LC_ALL=C grep -q '[[:cntrl:]]' <(LC_ALL=C tr -d '\n' < "$out"); then
            bad "${mode}: a control byte reached the listing: $(LC_ALL=C cat -v "$out" | tr '\n' '/')"
        else
            ok "${mode}: no control byte survives to the terminal"
        fi
        if LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$out"; then
            bad "${mode}: the UTF-8 C1 block survives: $(LC_ALL=C cat -v "$out" | tr '\n' '/')"
        else
            ok "${mode}: no U+0080-U+009F survives either"
        fi
    done
    # Vacuity guard: the box's own words DO reach the column, so the checks above
    # are about what is stripped and not about an empty cell.
    if grep -q 'fw=deny' "${sc}/out.row"; then
        ok "vacuity guard: the guest's legitimate text still reaches the column"
    else
        bad "vacuity guard: nothing of the guest's answer reached the listing at all"
    fi
}

# ---------------------------------------------------------------------------
# 10. The toolchain snapshot is kept when the check RAN, whatever it found
# ---------------------------------------------------------------------------
#
# `toolcheck.sh --json` prints the document and THEN returns its status, so exit
# 10 ("a baseline tool is missing or off its pin") arrives with a complete
# reading on stdout. A provisioner that gates the `mv` on exit 0 discards
# exactly the snapshot `status --json`'s `toolchain` key exists to carry, and the
# only box that would ever report findings is a box that has none.
check_toolchain_snapshot_keep() {
    section "provision.sh: a findings snapshot is kept, a failed run's output is not"
    local tk="${WORK}/toolchain-keep" f
    mkdir -p "$tk"

    sed -n '/^toolcheck_snapshot_worth_keeping() {/,/^}/p' "${BOX_DIR}/guest/provision.sh" \
        > "${tk}/fn.sh"
    if [ -s "${tk}/fn.sh" ]; then
        ok "toolcheck_snapshot_worth_keeping extracted from guest/provision.sh"
    else
        bad "could not extract toolcheck_snapshot_worth_keeping from guest/provision.sh"; return
    fi
    # And the call site really uses it: a helper nothing calls proves nothing.
    if grep -q 'toolcheck_snapshot_worth_keeping "' "${BOX_DIR}/guest/provision.sh" \
       && ! grep -q 'if run_as_box_user ' "${BOX_DIR}/guest/provision.sh"; then
        ok "and the snapshot's mv is gated on it, not on toolcheck's exit status alone"
    else
        bad "provision.sh still gates the snapshot on toolcheck's exit status"
    fi
    # shellcheck source=/dev/null
    . "${tk}/fn.sh"

    f="${tk}/snap.json"
    printf '{"generated_at":"2026-09-19T13:58:02Z","state":"findings","counts":{"missing":1,"off_pin":0}}\n' > "$f"
    if toolcheck_snapshot_worth_keeping 10 "$f"; then
        ok "status 10 with a complete document: kept (the findings case)"
    else
        bad "status 10 with a complete document was discarded"
    fi
    if toolcheck_snapshot_worth_keeping 0 "$f"; then
        ok "status 0 with a complete document: kept"
    else
        bad "status 0 with a complete document was discarded"
    fi
    if toolcheck_snapshot_worth_keeping 11 "$f"; then
        ok "status 11 (project mismatch): kept"
    else
        bad "status 11 was discarded"
    fi
    if toolcheck_snapshot_worth_keeping 1 "$f"; then
        bad "status 1 was kept; 1 is the status that means the script could not do its job"
    else
        ok "status 1: discarded, whatever is on stdout"
    fi
    if toolcheck_snapshot_worth_keeping 127 "$f"; then
        bad "status 127 (no such command) was kept"
    else
        ok "status 127: discarded"
    fi
    : > "$f"
    if toolcheck_snapshot_worth_keeping 10 "$f"; then
        bad "an empty file was kept"
    else
        ok "an empty file: discarded even on an accepted status"
    fi
    printf '{"generated_at":"2026-09-19T13:58:02Z","state":"findi' > "$f"
    if toolcheck_snapshot_worth_keeping 10 "$f"; then
        bad "a half-written document was kept"
    else
        ok "a write cut off half-way: discarded (it does not close where an object closes)"
    fi
    if toolcheck_snapshot_worth_keeping 10 "${tk}/no-such-file"; then
        bad "a missing file was kept"
    else
        ok "a file that is not there: discarded"
    fi
}

# ---------------------------------------------------------------------------
# 11. --box-json against the agent's own files: no bare NaN, no hang on a FIFO
# ---------------------------------------------------------------------------
#
# Every file the standing-session and run sensors read is in the agent's own
# home, so both of these are one command away for the thing being observed. The
# host has no timeout around its `limactl shell`, so a reader that blocks takes
# out `agentbox status` for every box in the fleet, not just this one; and a
# document carrying a bare `NaN` is refused whole by the host's shape check,
# which reports the box as unreachable with its firewall unknown.
check_box_json_hostile_values() {
    section "--box-json: a non-finite number is null, and a FIFO does not hang the reader"
    local hv="${WORK}/hostile-values" state runs sessions proc out rid f rc
    hv="${WORK}/hostile-values"
    state="${hv}/state"; runs="${state}/runs"; sessions="${state}/sessions"; proc="${hv}/proc"
    mkdir -p "$runs" "$sessions" "$proc"

    box_json_here() {
        ABX_STATE_DIR="$state" ABX_RUNS_DIR="$runs" ABX_SESSIONS_DIR="$sessions" \
        ABX_PROC_DIR="$proc" ABX_TOKEN_FILE="${hv}/no-token" \
            "$PY" "$RUNFORMAT" --box-json --firewall deny --sessions '' --toolchain ''
    }

    # `json.loads` accepts NaN and Infinity, so the agent can put one in its own
    # events.jsonl and `json.dumps` will hand it back as a bare word.
    rid=20260919-120000
    mkdir -p "${runs}/${rid}"
    printf '{"runid":"%s","model":"sonnet","branch":null,"brief":"b","started_at":"2026-09-19T12:00:00Z"}\n' \
        "$rid" > "${runs}/${rid}/meta.json"
    printf 'exit:0\n' > "${runs}/${rid}/status"
    printf '{"type":"result","num_turns":3,"total_cost_usd":NaN,"duration_ms":Infinity}\n' \
        > "${runs}/${rid}/events.jsonl"
    out=$(box_json_here 2>&1)
    case "$out" in
        *NaN*|*Infinity*) bad "--box-json emitted a bare NaN/Infinity: ${out}" ;;
        *) ok "a non-finite number in the agent's events.jsonl does not reach the document as a bare word" ;;
    esac
    # And the document is one the HOST will splice: its own shape check, pulled
    # out of bin/agentbox, is the consumer that would otherwise refuse the whole
    # guest half and report the box as unreachable.
    sed -n '/^channel_json_shape_ok() {/,/^}/p' "$AGENTBOX" > "${hv}/shape.sh"
    if [ -s "${hv}/shape.sh" ]; then
        # shellcheck source=/dev/null
        . "${hv}/shape.sh"
        if channel_json_shape_ok "$out"; then
            ok "and the host's own shape check accepts the document"
        else
            bad "the host's shape check refuses the document: the whole guest half becomes the fallback"
        fi
        # Vacuity guard: the same check really does refuse a bare NaN.
        if channel_json_shape_ok '{"cost_usd":NaN}'; then
            bad "vacuity guard: the host's shape check accepts a bare NaN, so the check above proves nothing"
        else
            ok "vacuity guard: the host's shape check does refuse a bare NaN"
        fi
    else
        bad "could not extract channel_json_shape_ok from bin/agentbox"
    fi
    if printf '%s' "$out" | grep -q '"cost_usd":null'; then
        ok "the unreadable number is null, which is the contract's word for it"
    else
        bad "cost_usd is not null: $(printf '%s' "$out" | head -c 300)"
    fi
    rm -rf "${runs:?}/${rid}"

    # A FIFO named like any file the standing-session sensor reads. A blocking
    # open never returns, and `status` has no timeout around the guest call.
    for f in pid task last-text runs-seen hooks.jsonl; do
        rm -rf "${sessions:?}/claude"
        mkdir -p "${sessions}/claude"
        printf '77\n' > "${sessions}/claude/pid"
        rm -f "${sessions}/claude/${f}"
        mkfifo "${sessions}/claude/${f}"
        out=$(box_json_here 2>&1 &
              bg=$!
              ( sleep 5; kill -9 "$bg" 2>/dev/null ) >/dev/null 2>&1 &
              killer=$!
              wait "$bg" 2>/dev/null
              kill "$killer" 2>/dev/null)
        rc=$?
        case "$out" in
            *'"standing"'*) ok "a FIFO at sessions/claude/${f}: --box-json still answers" ;;
            *) bad "a FIFO at sessions/claude/${f}: no answer (rc=${rc}), out='$(printf '%s' "$out" | head -c 120)'" ;;
        esac
    done
    rm -rf "${sessions:?}/claude"
}

check_repo_git
check_host_clip
check_meta_race
check_valid_run_state
check_require_brief
check_slot_list
check_proc_starttime
check_channel_read
check_status_text_clamp
check_toolchain_snapshot_keep
check_box_json_hostile_values

printf -- '\nRESULT: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
