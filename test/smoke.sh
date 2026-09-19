#!/usr/bin/env bash
#
# agent-box — end-to-end smoke test.
#
# Builds throwaway repositories, runs preflight against them, creates a real
# Lima instance, checks the isolation and firewall properties from inside it,
# restarts it to prove provisioning is idempotent under the firewall, and
# destroys it again. Everything it creates is temporary except Lima's downloaded
# image cache, which is deliberately left in place.
#
# Usage: test/smoke.sh
#
# Two development aids, neither of which may appear in a pull request's evidence:
# SMOKE_STOP_AFTER=<step label> stops the run at the next step boundary and
# prints STOPPED AFTER <label> above the RESULT line, and SMOKE_KEEP=1 leaves the
# boxes and the temporary repositories in place for the next iteration. The
# output pasted for a change has to come from a run with neither set.
#
# Run it from a terminal, or detach it with a launcher that resets signal
# dispositions (python's subprocess with preexec_fn, say). A background job of
# a non-interactive shell (`nohup test/smoke.sh &`) inherits SIGINT as IGNORED,
# and the `status --watch` interrupt check then waits on a process that cannot
# receive the signal. Three lines below that start with FAIL are the guest's
# own firewall report, echoed by steps that break the resolver on purpose and
# then check the report says so; the RESULT line at the end is the verdict.
#
# Exit 0 if every check passed, 1 otherwise.
#
# Note on `limactl validate`: it has no --param flag, so validating the bare
# template only ever exercises the /tmp placeholders. To validate the real mount
# paths, this script materialises a copy of the template with the parameters
# substituted the way bin/agentbox passes them and validates that, then confirms
# the substitution with `limactl template yq`. That pair is the runnable form of
# the "validate with params set" requirement.

set -uo pipefail

BOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AGENTBOX="${BOX_DIR}/bin/agentbox"
LIMACTL="${LIMACTL:-limactl}"

TMP_ROOT=$(mktemp -d -t agent-box-smoke.XXXXXX)
# A hermetic host config dir, so the test never reads, writes or deletes the
# real one. It is mounted read-only into the guest, so it must exist.
export AGENT_BOX_CONFIG_DIR="${TMP_ROOT}/config"
export AGENT_BOX_BLOCKLIST="${AGENT_BOX_CONFIG_DIR}/blocklist.txt"
# Only config/guest is mounted into the VM; blocklist.txt sits in the parent and
# must never appear inside the guest.
mkdir -p "${AGENT_BOX_CONFIG_DIR}/guest"

SMOKE_ID="smoke$$"
CLEAN_REPO="${TMP_ROOT}/${SMOKE_ID}"
DIRTY_REPO="${TMP_ROOT}/dirty-${SMOKE_ID}"
TERM_REPO="${TMP_ROOT}/term-${SMOKE_ID}"
INSTANCE="agent-box-${SMOKE_ID}"

# The second instance: the same box with the Docker and browser-testing
# profile. A separate VM rather than a flag on the first, because the profile
# is fixed at create time and the point is to prove both shapes work.
DOCKER_REPO="${TMP_ROOT}/dk-${SMOKE_ID}"
DOCKER_INSTANCE="agent-box-dk-${SMOKE_ID}"
# A third, short-lived box: `status` listing more than one box is the only way
# to see a box go missing from it, and one box can never show that.
SECOND_REPO="${TMP_ROOT}/second-${SMOKE_ID}"
SECOND_INSTANCE="agent-box-second-${SMOKE_ID}"
# A SECOND forwarded port, carrying a container published the ordinary way
# (`-p N:80`, which binds 0.0.0.0), and one port deliberately left out of
# --forward. Together they pin down both halves of the claim the whole design
# rests on: what --forward reaches, and what nothing reaches.
#
# Derived from this run's pid, not hardcoded, and probed free in the preamble
# below. Three fixed ports were an undeclared precondition: an unrelated process
# holding one of them made step 12 report a FIREWALL BREACH ("nothing answers on
# host 127.0.0.1:${UNFORWARDED_PORT}") for what was really a port collision.
# 20000-27999 is above the privileged ports and below both 32768 and macOS's
# ephemeral range (49152-65535, `sysctl net.inet.ip.portrange.first`), so the
# kernel never hands one of these out as a source port for the many outbound
# connections this suite makes. Do not re-hardcode them.
FORWARD_PORT=$((20000 + ($$ % 8000)))
FORWARD_PORT2=$((FORWARD_PORT + 1))
UNFORWARDED_PORT=$((FORWARD_PORT + 2))

# The host's python, for parsing JSON the guest produced. Named once so the
# assertions below read as assertions rather than as plumbing.
PY="${PY:-python3}"

PASS=0
FAIL=0
# Advisory. Counted and printed, never fatal, and deliberately a third category
# rather than a quiet pass: a check that is allowed not to hold still has to say
# when it did not. Exactly one check uses it — see cdn.playwright.dev below.
WARN=0

hr()   { printf '%s\n' '==============================================================='; }
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
adv()  { WARN=$((WARN + 1)); printf 'WARN  %s\n' "$*"; }

# The verdict for an early exit, in one place. Three of them used to print their
# own copy of the RESULT block, which is how a fourth early exit becomes a fourth
# copy. (The suite's own ending is written out at the bottom of the file, for a
# reason stated there.)
#
# With a label it prints STOPPED AFTER <label> first, so a transcript truncated
# by SMOKE_STOP_AFTER can never be mistaken for a full run. CONTRIBUTING.md's
# "paste the output" means an unfiltered run, and this line is what makes that
# checkable by a reader rather than by trust.
summarise_and_exit() {
    [ -z "${1:-}" ] || printf 'STOPPED AFTER %s\n' "$1"
    hr
    printf 'RESULT: %s passed, %s failed, %s advisory\n' "$PASS" "$FAIL" "$WARN"
    hr
    [ "$FAIL" -eq 0 ]
    exit
}

# The step banner, and the only place SMOKE_STOP_AFTER is honoured. The label is
# the banner's first word without its trailing dot, so `step "8h. status: …"` is
# step 8h. The test is against the step that just FINISHED, which is the honest
# thing this can implement: a run stops at a step boundary and what you get is a
# prefix of the suite — stopping after 8h skips two VM creates.
SMOKE_LAST_STEP=""
# Set by cleanup() before it calls step(), because cleanup is the EXIT trap: a
# stop firing from inside it would exit before the three destroys and leave three
# real VMs and $TMP_ROOT behind.
SMOKE_IN_CLEANUP=0
step() {
    hr; printf '## %s\n' "$*"; hr
    local label="${1%% *}"
    label="${label%.}"
    if [ -n "${SMOKE_STOP_AFTER:-}" ] && [ "$SMOKE_IN_CLEANUP" -eq 0 ] \
       && [ "$SMOKE_LAST_STEP" = "$SMOKE_STOP_AFTER" ]; then
        summarise_and_exit "$SMOKE_LAST_STEP"
    fi
    SMOKE_LAST_STEP="$label"
}

# Set while the stand-in CLI is in place, so that an abort restores the real
# one rather than leaving it parked at claude.real.
STANDIN_INSTALLED=0

# Background processes a step started and wants killed however the suite ends —
# a listener holding a port, a waiter on a channel. Appended to by the step,
# emptied by nobody: cleanup kills them all.
SMOKE_BG_PIDS=()

cleanup() {
    local rc=$? inst pid
    SMOKE_IN_CLEANUP=1
    step "cleanup"
    for pid in ${SMOKE_BG_PIDS[@]+"${SMOKE_BG_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done
    if [ "${STANDIN_INSTALLED:-0}" -eq 1 ]; then
        printf 'restoring the real Claude Code in %s\n' "$INSTANCE"
        # shellcheck disable=SC2016  # $HOME must expand in the guest.
        "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
            bash -lc 'mv -f "$HOME/.local/bin/claude.real" "$HOME/.local/bin/claude"' \
            >/dev/null 2>&1 || true
        STANDIN_INSTALLED=0
    fi
    # SMOKE_KEEP is a development aid: it leaves the boxes and the temporary
    # repositories in place so the next iteration reuses them. It keeps $TMP_ROOT
    # too, because $CLEAN_REPO is mounted into the box that is being kept.
    if [ "${SMOKE_KEEP:-0}" = "1" ]; then
        printf 'SMOKE_KEEP=1: leaving these in place\n'
        for inst in "$INSTANCE" "$DOCKER_INSTANCE" "$SECOND_INSTANCE"; do
            if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$inst"; then
                printf '  instance %s\n' "$inst"
            fi
        done
        printf '  %s\n' "$TMP_ROOT"
        printf 'Destroy them yourself when you are done: agentbox destroy <name>; rm -rf %s\n' "$TMP_ROOT"
        exit "$rc"
    fi
    for inst in "$INSTANCE" "$DOCKER_INSTANCE" "$SECOND_INSTANCE"; do
        if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$inst"; then
            printf 'destroying %s\n' "$inst"
            "$AGENTBOX" destroy "$inst" || "$LIMACTL" delete --force "$inst" || true
        fi
    done
    rm -rf "$TMP_ROOT"
    printf 'Lima image cache under ~/Library/Caches/lima/download is left in place on purpose.\n'
    exit "$rc"
}
trap cleanup EXIT

# Every host prerequisite this suite assumes, checked in one second instead of an
# hour. A missing `jq` turns two dozen `jq -e … >/dev/null 2>&1` contract
# assertions into their else branch, so the suite fails loudly and about the
# wrong thing. `mktemp`, `dirname` and `cd` are already load-bearing above this
# line and cannot be protected from here; they are listed for the operator's
# benefit, not as a guard.
#
# Below the EXIT trap on purpose: this check and the port probe under it both
# exit, and $TMP_ROOT exists from the top of the file — above the trap they would
# leave a temporary directory behind every time they fired.
PREREQ_MISSING=0
for _cmd in jq python3 git limactl curl script mktemp sed; do
    command -v "$_cmd" >/dev/null 2>&1 || { printf 'PREREQ MISSING %s\n' "$_cmd"; PREREQ_MISSING=1; }
done
unset _cmd
if [ "$PREREQ_MISSING" -eq 1 ]; then
    bad "a host prerequisite is missing; nothing below would mean anything"
    summarise_and_exit
fi

# The three host ports, probed free before a single VM is built. This is a
# check-then-use with the whole suite as its window — step 11 binds them tens of
# minutes from now — and it is not trying to close that: `create` refuses a held
# forward and names the holder, which is the recoverable end of the same problem.
# What the probe buys is the collision that is already there being named here
# rather than read as a firewall breach four VMs later.
host_port_free() { ! (exec 3<>"/dev/tcp/127.0.0.1/${1:?}") 2>/dev/null; }
_tries=0
while [ "$_tries" -lt 40 ]; do
    if host_port_free "$FORWARD_PORT" && host_port_free "$FORWARD_PORT2" && host_port_free "$UNFORWARDED_PORT"; then
        break
    fi
    printf 'ports %s/%s/%s: one is busy, moving up\n' "$FORWARD_PORT" "$FORWARD_PORT2" "$UNFORWARDED_PORT"
    FORWARD_PORT=$((FORWARD_PORT + 3))
    [ "$FORWARD_PORT" -le 27997 ] || FORWARD_PORT=20000
    FORWARD_PORT2=$((FORWARD_PORT + 1))
    UNFORWARDED_PORT=$((FORWARD_PORT + 2))
    _tries=$((_tries + 1))
done
unset _tries
if host_port_free "$FORWARD_PORT" && host_port_free "$FORWARD_PORT2" && host_port_free "$UNFORWARDED_PORT"; then
    printf 'host ports: %s and %s forwarded, %s deliberately not\n' \
        "$FORWARD_PORT" "$FORWARD_PORT2" "$UNFORWARDED_PORT"
else
    bad "no three consecutive free host ports in 20000-27999; free some and run this again"
    summarise_and_exit
fi

# An explicit --workdir stops limactl from trying to cd into the host's
# working directory inside the guest, which warns on stderr every time.
guest()  { "$LIMACTL" shell --workdir /work "$INSTANCE" -- "$@"; }
dguest() { "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- "$@"; }

# A run's own summary, read and scrubbed inside the guest.
guest_summary() {
    "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
        python3 /opt/agent-box/guest/run-format.py --summary "$1"
}

# Run a command with a wall-clock bound and capture its exit status. macOS has
# no `timeout(1)`, and one step below makes a real model call that must not be
# able to wedge the suite.
BOUNDED_RC=0
run_bounded() {
    local secs="$1" out="$2"; shift 2
    "$@" > "$out" 2>&1 &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$secs" ]; then
            printf 'run_bounded: exceeded %ss, killing\n' "$secs" >> "$out"
            kill -9 "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null
            BOUNDED_RC=124
            return 124
        fi
        sleep 2; waited=$((waited + 2))
    done
    wait "$pid"; BOUNDED_RC=$?
    return "$BOUNDED_RC"
}

# Wait until the guest answers again. Used after a step that deliberately cuts
# the guest's own network down to loopback.
wait_for_guest() {
    local secs="${1:-120}" waited=0
    while [ "$waited" -lt "$secs" ]; do
        if "$LIMACTL" shell --workdir /work "$INSTANCE" -- true >/dev/null 2>&1; then
            return 0
        fi
        sleep 3; waited=$((waited + 3))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Feature slots
# ---------------------------------------------------------------------------
#
# The slices of roadmap#146 each add their assertions inside one marked slot,
# planted below in advance and separated by a blank line, so that no two slices
# edit the same lines and no two hunks touch. A slot is a start line and an end
# line, both beginning `# ---- `, naming the label and the owning slice.
#
# Every slot in this file is listed here with its owner, and nothing may be
# planted that is not listed: the list and the markers are checked against each
# other, which is what tells a missing slot from a filled one. When every slice
# has landed, FIN deletes the markers and this block with them.
#
# SLOTS 3f=H1 3g=H2 3h=C2 5c=TA 5d=TB 5e=TB 5f=TB 8d2=M1 8d3=TB 8f-lost=M1
# SLOTS 8g-kind=W 8k=C2 8l=C3 8m=C2 8j2=S1 8j3=S2 9-ch=C2 9-tc=TA
# SLOTS 9f-triage=H3 9i=H3 11-pre=H1 11b=H1

# ===========================================================================
step "1. preflight on a clean repository (expect exit 0)"
# ===========================================================================

mkdir -p "$CLEAN_REPO"
git init -q "$CLEAN_REPO"
cat > "${CLEAN_REPO}/hello.txt" <<'EOF'
A generic end-to-end test repository. Nothing secret, nothing proprietary.
EOF

"$AGENTBOX" preflight "$CLEAN_REPO"
rc=$?
if [ "$rc" -eq 0 ]; then ok "clean repo preflight exited 0"; else bad "clean repo preflight exited ${rc}, expected 0"; fi

# ===========================================================================
step "2. preflight on a repository with a planted credential (expect exit 1)"
# ===========================================================================

mkdir -p "$DIRTY_REPO"
git init -q "$DIRTY_REPO"
# A syntactically valid but fake AWS access key id: AKIA + 16 uppercase chars.
FAKE_KEY="AKIA$(printf 'QRSTUVWXYZ234567')"
printf 'aws_access_key_id = %s\n' "$FAKE_KEY" > "${DIRTY_REPO}/credentials.ini"

DIRTY_OUT="${TMP_ROOT}/dirty.out"
"$AGENTBOX" preflight "$DIRTY_REPO" > "$DIRTY_OUT" 2>&1
rc=$?
cat "$DIRTY_OUT"

if [ "$rc" -eq 1 ]; then ok "planted-credential preflight exited 1"; else bad "planted-credential preflight exited ${rc}, expected 1"; fi
if grep -q 'credentials.ini' "$DIRTY_OUT"; then ok "the offending path was reported"; else bad "the offending path was not reported"; fi
if grep -qF "$FAKE_KEY" "$DIRTY_OUT"; then bad "the credential itself was echoed"; else ok "the credential itself was not echoed"; fi

# ===========================================================================
step "3. preflight honours the host blocklist, locations only (expect exit 1)"
# ===========================================================================

SECRET_TERM="widgetronic"
printf '%s\n' "$SECRET_TERM" > "$AGENT_BOX_BLOCKLIST"
mkdir -p "$TERM_REPO"
git init -q "$TERM_REPO"
printf 'The %s integration notes.\n' "$SECRET_TERM" > "${TERM_REPO}/notes.md"

TERM_OUT="${TMP_ROOT}/term.out"
"$AGENTBOX" preflight "$TERM_REPO" > "$TERM_OUT" 2>&1
rc=$?
cat "$TERM_OUT"

if [ "$rc" -eq 1 ]; then ok "blocklist preflight exited 1"; else bad "blocklist preflight exited ${rc}, expected 1"; fi
if grep -q 'notes.md' "$TERM_OUT"; then ok "the offending path was reported"; else bad "the offending path was not reported"; fi
if grep -qiF "$SECRET_TERM" "$TERM_OUT"; then bad "the blocklist term was echoed"; else ok "the blocklist term was not echoed"; fi

# ===========================================================================
step "3b. preflight finds a blocklist term that survives only in git history"
# ===========================================================================
#
# The whole .git directory is mounted into the VM, so a term in a commit message
# or in a deleted file is just as readable to the agent as one in the tree.

HIST_REPO="${TMP_ROOT}/hist-${SMOKE_ID}"
mkdir -p "$HIST_REPO"
git init -q "$HIST_REPO"
git -C "$HIST_REPO" config user.name  'smoke test'
git -C "$HIST_REPO" config user.email 'smoke@localhost'
printf 'nothing to see\n' > "${HIST_REPO}/a.txt"
git -C "$HIST_REPO" add a.txt
git -C "$HIST_REPO" commit -q -m "notes about the ${SECRET_TERM} rollout"
# The working tree is clean of the term; only the commit message carries it.
if grep -rqiF "$SECRET_TERM" "$HIST_REPO" --exclude-dir=.git 2>/dev/null; then
    bad "setup error: the term is still in the working tree"
else
    ok "the working tree is clean of the term (history-only case)"
fi

HIST_OUT="${TMP_ROOT}/hist.out"
"$AGENTBOX" preflight "$HIST_REPO" > "$HIST_OUT" 2>&1
rc=$?
cat "$HIST_OUT"
if [ "$rc" -eq 1 ]; then ok "history-only blocklist preflight exited 1"; else bad "history-only blocklist preflight exited ${rc}, expected 1"; fi
if grep -q 'commit message' "$HIST_OUT"; then ok "the offending commit was reported"; else bad "the offending commit was not reported"; fi
if grep -qiF "$SECRET_TERM" "$HIST_OUT"; then bad "the blocklist term was echoed"; else ok "the blocklist term was not echoed from history"; fi

rm -f "$AGENT_BOX_BLOCKLIST"

# ===========================================================================
step "3c. limactl validate with the parameters bin/agentbox actually passes"
# ===========================================================================

PARAM_YAML="${TMP_ROOT}/agent-box-params.yaml"
sed -e "s#^  repo: \"/tmp\"#  repo: \"${CLEAN_REPO}\"#" \
    -e "s#^  box: \"/tmp\"#  box: \"${BOX_DIR}\"#" \
    -e "s#^  config: \"/tmp\"#  config: \"${AGENT_BOX_CONFIG_DIR}/guest\"#" \
    "${BOX_DIR}/lima/agent-box.yaml" > "$PARAM_YAML"

if "$LIMACTL" validate "${BOX_DIR}/lima/agent-box.yaml"; then
    ok "the committed template validates"
else
    bad "the committed template does not validate"
fi

if "$LIMACTL" validate "$PARAM_YAML"; then
    ok "the template validates with real parameters"
else
    bad "the template does not validate with real parameters"
fi

printf -- '--- resolved mounts ---\n'
MOUNTS=$("$LIMACTL" template yq "$PARAM_YAML" '.mounts' 2>&1 | grep -E 'location|mountPoint|writable')
printf '%s\n' "$MOUNTS"
if printf '%s' "$MOUNTS" | grep -q '/opt/agent-box-config'; then
    ok "the host config directory is a declared mount"
else
    bad "the host config directory is not a declared mount"
fi

# ===========================================================================
step "3d. stage the host-side plugin and personal-config files"
# ===========================================================================
#
# Everything here goes into the hermetic config directory, which is mounted
# read-only at /opt/agent-box-config. It must exist BEFORE create, because
# provisioning reads it: the plugin install runs on first boot, after the
# firewall comes up.

GUEST_CFG="${AGENT_BOX_CONFIG_DIR}/guest"
CLAUDE_MARKER="agent-box-smoke-marker-${SMOKE_ID}"
MARKETPLACE_REPO="konyklabs/claude-plugins"
# The registered NAME comes from the marketplace's own manifest, not from the
# repository name: .claude-plugin/marketplace.json on that public repo's main
# branch declares "konyklabs-plugins".
MARKETPLACE_NAME="konyklabs-plugins"
# The plugin the marketplace actually publishes. It is a real public
# marketplace, so this name tracks whatever it publishes: it was `governor`
# until 2026-09-05, when konyklabs/claude-plugins renamed it to `supervisor` on
# main and every install here began failing with `Plugin "governor" not found
# in marketplace "konyklabs-plugins"`. A fixture naming a plugin that no longer
# exists tests the error path and reports it as a broken plugin mechanism.
PLUGIN_UNDER_TEST="supervisor"

mkdir -p "${GUEST_CFG}/claude/rules" \
         "${GUEST_CFG}/plugin-dir/demo/.claude-plugin" \
         "${GUEST_CFG}/plugin-dir/demo/commands"

# The two allowlist forms that cannot be exercised by the base file: a range,
# and a suffix. TEST-NET-1 is reserved and routed nowhere, which is what makes
# it a good range to assert on — in range it is allowed and times out, out of
# range it is refused immediately, and the difference is measurable. iana.org
# is a real, stable name that nothing else in the allowlist covers.
ALLOWED_CIDR="192.0.2.0/24"
CIDR_IN="192.0.2.7"
CIDR_OUT="198.51.100.7"
ALLOWED_SUFFIX=".iana.org"
# The resolver's own set, kept apart from the rebuild's. Named here so the
# assertions can say which set they mean.
IPSET_RESOLVED_NAME="allowed-resolved"
# An exact name that is NOT otherwise allowlisted, to prove a bare line is fed
# to nothing and pinned by the rebuild instead.
EXACT_HOST="www.rfc-editor.org"
SUFFIX_HOST="www.iana.org"
cat > "${GUEST_CFG}/allowlist.local" <<EOF
# staged by test/smoke.sh
${ALLOWED_CIDR}
${ALLOWED_SUFFIX}
${EXACT_HOST}
2001:db8::/32
this is not a valid line!!
999.1.2.3/24
10.0.0.0/99
EOF

cat > "${GUEST_CFG}/plugins.txt" <<EOF
# agent-box smoke test
marketplace ${MARKETPLACE_REPO}
install ${PLUGIN_UNDER_TEST}@${MARKETPLACE_NAME}
EOF

cat > "${GUEST_CFG}/claude/CLAUDE.md" <<EOF
# smoke

${CLAUDE_MARKER}
EOF

printf '{}\n' > "${GUEST_CFG}/claude/governor.json"
printf '# a rule\n\nNothing to see.\n' > "${GUEST_CFG}/claude/rules/smoke.md"

# A settings.json shaped like the one a person would really copy in: a harmless
# setting next to an `env` block holding an API key. That block is merged into
# the CLI's own process environment, so it would arrive AFTER the shell
# environment check in lib.sh has already passed. The harmless key must survive
# the crossing and the credential must not.
SETTINGS_HARMLESS_KEY="includeCoAuthoredBy"
SETTINGS_FAKE_KEY="sk-ant-fake-smoke-key-must-not-cross"
cat > "${GUEST_CFG}/claude/settings.json" <<EOF
{
  "${SETTINGS_HARMLESS_KEY}": false,
  "env": {"ANTHROPIC_API_KEY": "${SETTINGS_FAKE_KEY}"},
  "apiKeyHelper": "echo sk-ant-nor-this"
}
EOF

# Staged deliberately: the sync is an allowlist, and a credential-shaped file
# left in the source directory must be refused out loud rather than skipped in
# silence, because a silent skip looks exactly like a successful copy.
printf '{"fake":"this must never be copied into the guest"}\n' > "${GUEST_CFG}/claude/.credentials.json"

cat > "${GUEST_CFG}/plugin-dir/demo/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "demo",
  "description": "A minimal plugin, loaded per session by the agent-box smoke test.",
  "version": "0.1.0"
}
EOF

cat > "${GUEST_CFG}/plugin-dir/demo/commands/hello.md" <<'EOF'
---
description: Say hello from the demo plugin.
---

Reply with the single word: hello
EOF

printf -- '--- staged under %s ---\n' "$GUEST_CFG"
find "$GUEST_CFG" -type f | sed "s#^${GUEST_CFG}/##" | sort
if [ -f "${GUEST_CFG}/plugins.txt" ] && [ -f "${GUEST_CFG}/plugin-dir/demo/.claude-plugin/plugin.json" ]; then
    ok "the host-side plugin and config files are staged"
else
    bad "the host-side plugin and config files are not staged"
fi

# ===========================================================================
step "3e. create refuses without an egress mode, and honours a standing default"
# ===========================================================================
#
# The mode has no default on purpose: a box's reach is the one thing nobody
# should end up with by accident. The only way to skip the flag is to have
# written the default down yourself, and even then create says so.

NOEG_OUT="${TMP_ROOT}/no-egress.out"
run_bounded 60 "$NOEG_OUT" "$AGENTBOX" create "$CLEAN_REPO"
noeg_rc=$BOUNDED_RC
cat "$NOEG_OUT"
if [ "$noeg_rc" -ne 0 ]; then
    ok "create without --egress refuses (exit ${noeg_rc})"
else
    bad "create without --egress went ahead"
fi
for word in deny observe open; do
    if grep -q "^  ${word} " "$NOEG_OUT"; then
        ok "the refusal explains '${word}'"
    else
        bad "the refusal does not explain '${word}'"
    fi
done
# The load-bearing half is the instance-absence check on the same line. Nothing
# creates ${CLEAN_REPO}/.agent-box until a GUEST run writes into it, so at this
# position the directory test is vacuous; it is kept because it is correct and
# becomes meaningful if this step ever moves. A new step must not copy the vacuous
# half and take it for proof that a command left nothing behind.
if [ ! -d "${CLEAN_REPO}/.agent-box" ] && ! "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$INSTANCE"; then
    ok "and it created nothing before refusing"
else
    bad "create left state behind after refusing"
fi

BADEG_OUT="${TMP_ROOT}/bad-egress.out"
run_bounded 60 "$BADEG_OUT" "$AGENTBOX" create "$CLEAN_REPO" --egress sideways
cat "$BADEG_OUT"
if grep -q 'must be one of' "$BADEG_OUT"; then
    ok "an unknown mode is named and refused"
else
    bad "an unknown mode was not refused clearly"
fi

# The standing default. It is read from the host config, and create has to say
# which mode it took AND where it came from — a default you can see is a
# different thing from one you inherited.
printf 'egress: observe\n' > "${AGENT_BOX_CONFIG_DIR}/config"
DEFEG_OUT="${TMP_ROOT}/default-egress.out"
# --cpus 0 stops it after the mode is resolved and before anything is built.
run_bounded 60 "$DEFEG_OUT" "$AGENTBOX" create "$CLEAN_REPO" --cpus 0
cat "$DEFEG_OUT"
if grep -q 'must be a whole number of CPUs' "$DEFEG_OUT"; then
    ok "the host default was accepted, so create got as far as the sizing check"
else
    bad "create did not accept the host config default"
fi
printf 'egress: sideways\n' > "${AGENT_BOX_CONFIG_DIR}/config"
BADDEF_OUT="${TMP_ROOT}/bad-default.out"
run_bounded 60 "$BADDEF_OUT" "$AGENTBOX" create "$CLEAN_REPO"
cat "$BADDEF_OUT"
if grep -q "sets 'egress: sideways'" "$BADDEF_OUT"; then
    ok "an invalid standing default is named as the problem, once"
else
    bad "an invalid standing default was not reported clearly"
fi
rm -f "${AGENT_BOX_CONFIG_DIR}/config"

# ---- slot:3f (owner H1) ----
# ---- end slot:3f ----

# ---- slot:3g (owner H2) ----
# ---- end slot:3g ----

# ---- slot:3h (owner C2) ----
# ---- end slot:3h ----

# ===========================================================================
step "4. create a real instance from the clean repository"
# ===========================================================================

printf 'This downloads an Ubuntu image on a cold cache and then provisions.\n'
START_TS=$(date +%s)
"$AGENTBOX" create "$CLEAN_REPO" --egress deny
rc=$?
printf 'create took %s seconds\n' "$(( $(date +%s) - START_TS ))"
if [ "$rc" -eq 0 ]; then ok "agentbox create succeeded"; else bad "agentbox create exited ${rc}"; fi

if "$LIMACTL" list --quiet | grep -qxF "$INSTANCE"; then
    ok "instance ${INSTANCE} exists"
else
    bad "instance ${INSTANCE} does not exist; the remaining guest checks cannot run"
    summarise_and_exit
fi

"$LIMACTL" list

# ===========================================================================
step "5. isolation checks inside the guest"
# ===========================================================================

printf -- '--- id ---\n'
GUEST_ID=$(guest id 2>/dev/null)
printf '%s\n' "$GUEST_ID"
if printf '%s' "$GUEST_ID" | grep -q 'uid=0('; then
    bad "the guest shell is root"
else
    ok "the guest shell is not root"
fi

printf -- '\n--- /work is writable and shared with the host ---\n'
STAMP="written-by-guest-$(date +%s)"
if guest sh -c "printf '%s\n' '${STAMP}' > /work/guest-wrote-this.txt"; then
    if [ -f "${CLEAN_REPO}/guest-wrote-this.txt" ] && grep -qF "$STAMP" "${CLEAN_REPO}/guest-wrote-this.txt"; then
        ok "a file written in /work appeared on the host"
    else
        bad "the file written in /work did not appear on the host"
    fi
else
    bad "/work is not writable from the guest"
fi

printf -- '\n--- the host home directory is not mounted ---\n'
USERS_OUT=$(guest sh -c 'ls -A /Users 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$USERS_OUT"
if printf '%s' "$USERS_OUT" | grep -q '::rc=0' && [ -n "$(printf '%s' "$USERS_OUT" | sed 's/::rc=.*//' | tr -d '[:space:]')" ]; then
    bad "/Users exists in the guest and is not empty"
else
    ok "/Users is absent or empty in the guest"
fi

printf -- '\n--- the three intended mounts, and only those ---\n'
MNT=$(guest sh -c 'findmnt -t virtiofs -o TARGET,SOURCE,OPTIONS 2>/dev/null || mount | grep -i virtiofs')
printf '%s\n' "$MNT"
for want in /work /opt/agent-box /opt/agent-box-config; do
    if printf '%s' "$MNT" | grep -q -- "$want"; then
        ok "mount present: ${want}"
    else
        bad "mount missing: ${want}"
    fi
done

printf -- '\n--- the agent-box checkout is read-only ---\n'
RO_OUT=$(guest sh -c 'touch /opt/agent-box/should-not-be-writable 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$RO_OUT"
if printf '%s' "$RO_OUT" | grep -q '::rc=0'; then
    bad "/opt/agent-box is writable; it should be read-only"
    rm -f "${BOX_DIR}/should-not-be-writable"
else
    ok "/opt/agent-box is read-only"
fi

printf -- '\n--- the host config mount is read-only ---\n'
ROC_OUT=$(guest sh -c 'touch /opt/agent-box-config/should-not-be-writable 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$ROC_OUT"
if printf '%s' "$ROC_OUT" | grep -q '::rc=0'; then
    bad "/opt/agent-box-config is writable; it should be read-only"
    rm -f "${AGENT_BOX_CONFIG_DIR}/should-not-be-writable"
else
    ok "/opt/agent-box-config is read-only"
fi

printf -- '\n--- the blocklist never reaches the guest ---\n'
# The parent config dir holds the blocklist; only config/guest is mounted.
#
# The probe term is generated at run time. Using the fixed SECRET_TERM would
# report a false positive, because this very file contains that word in its
# source and the checkout is itself one of the mounts being grepped.
BLOCK_PROBE="blockprobe$(date +%s)x$$"
printf '%s\n' "$BLOCK_PROBE" > "$AGENT_BOX_BLOCKLIST"
BL=$(guest sh -c 'ls -la /opt/agent-box-config/ 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$BL"
if guest test -e /opt/agent-box-config/blocklist.txt; then
    bad "/opt/agent-box-config/blocklist.txt exists in the guest"
else
    ok "/opt/agent-box-config/blocklist.txt does not exist in the guest"
fi
# Stronger: the term itself must not be readable anywhere in any mount.
if guest sh -c "grep -rqiF '${BLOCK_PROBE}' /opt/agent-box-config /opt/agent-box /work 2>/dev/null"; then
    bad "the blocklist term is readable somewhere inside the guest"
else
    ok "the blocklist term is not readable in any guest mount"
fi
rm -f "$AGENT_BOX_BLOCKLIST"

printf -- '\n--- the host proxy environment was not copied in ---\n'
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
PROXY_OUT=$(guest sh -c 'echo "http_proxy=${http_proxy:-<unset>} https_proxy=${https_proxy:-<unset>}"' 2>/dev/null)
printf '%s\n' "$PROXY_OUT"
if printf '%s' "$PROXY_OUT" | grep -q 'http_proxy=<unset> https_proxy=<unset>'; then
    ok "no proxy variables in the guest environment"
else
    bad "proxy variables reached the guest environment"
fi

printf -- '\n--- the guest git identity is generic ---\n'
GIT_ID=$(guest sh -c 'git config --get user.name; git config --get user.email' 2>/dev/null)
printf '%s\n' "$GIT_ID"
if printf '%s' "$GIT_ID" | grep -q 'agent-box'; then
    ok "a generic git identity is configured"
else
    bad "no git identity is configured in the guest"
fi

# ---- slot:5c (owner TA) ----
# ---- end slot:5c ----

# ---- slot:5d (owner TB) ----
# ---- end slot:5d ----

# ---- slot:5e (owner TB) ----
# ---- end slot:5e ----

# ---- slot:5f (owner TB) ----
# ---- end slot:5f ----

# ===========================================================================
step "6. the egress firewall"
# ===========================================================================

printf -- '--- systemctl is-active agent-box-firewall ---\n'
FW_STATE=$(guest systemctl is-active agent-box-firewall 2>/dev/null)
printf '%s\n' "$FW_STATE"
if [ "$FW_STATE" = "active" ]; then ok "agent-box-firewall is active"; else bad "agent-box-firewall is ${FW_STATE}"; fi

printf -- '\n--- systemctl is-active agent-box-firewall.timer ---\n'
TIMER_STATE=$(guest systemctl is-active agent-box-firewall.timer 2>/dev/null)
printf '%s\n' "$TIMER_STATE"
if [ "$TIMER_STATE" = "active" ]; then ok "the 15-minute refresh timer is active"; else bad "the refresh timer is ${TIMER_STATE}"; fi

printf -- '\n--- agentbox firewall-check ---\n'
FW_OUT="${TMP_ROOT}/firewall.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT" 2>&1
rc=$?
cat "$FW_OUT"
if [ "$rc" -eq 0 ]; then ok "firewall-check exited 0"; else bad "firewall-check exited ${rc}"; fi
for check in policy-drop policy-drop-v6 allowlist-rule allowlist-holds literal-ip-denied \
             foreign-dns-denied egress-denied anthropic-allowed github-allowed \
             uplink-not-bridge inbound-intact resolver-up resolver-conf; do
    if grep -q "^PASS  ${check}" "$FW_OUT"; then
        ok "firewall check ${check}"
    else
        bad "firewall check ${check}"
    fi
done

printf -- '\n--- the ruleset, as applied ---\n'
guest sudo iptables -S 2>/dev/null
printf -- '\n--- ip6tables policies ---\n'
V6=$(guest sudo ip6tables -S 2>/dev/null | grep '^-P')
printf '%s\n' "$V6"
if printf '%s' "$V6" | grep -qx -- '-P OUTPUT DROP'; then
    ok "ip6tables OUTPUT policy is DROP"
else
    bad "ip6tables OUTPUT policy is not DROP"
fi

printf -- '\n--- a non-allowlisted host by name is refused ---\n'
BLOCKED=$(guest sh -c 'curl -sS -m 5 -o /dev/null https://example.com 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$BLOCKED"
if printf '%s' "$BLOCKED" | grep -q '::rc=0'; then
    bad "example.com was reachable"
else
    ok "example.com was refused"
fi

printf -- '\n--- a non-allowlisted host by literal address is refused ---\n'
LIT=$(guest sh -c 'curl -sS -m 5 -o /dev/null https://198.51.100.42/ 2>&1'; printf '::rc=%s' "$?")
printf '%s\n' "$LIT"
if printf '%s' "$LIT" | grep -q '::rc=0'; then
    bad "a literal non-allowlisted address was reachable"
else
    ok "a literal non-allowlisted address was refused"
fi

printf -- '\n--- DNS to a foreign resolver is refused ---\n'
# dig's own exit status, not a pipeline's: `dig | tail` would report tail's.
FDNS=$(guest sh -c 'dig +time=2 +tries=1 @9.9.9.9 example.com 2>&1; printf "::rc=%s" "$?"' 2>/dev/null | tail -4)
printf '%s\n' "$FDNS"
if printf '%s' "$FDNS" | grep -q '::rc=0'; then
    bad "DNS to 9.9.9.9 succeeded"
else
    ok "DNS to 9.9.9.9 was refused"
fi

# ===========================================================================
step "7. Claude Code, the environment, and verify-auth"
# ===========================================================================

printf -- '--- claude --version (login shell) ---\n'
VER_OUT=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$VER_OUT"
if printf '%s' "$VER_OUT" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "claude --version printed a version"
else
    bad "claude --version did not print a version"
fi

printf -- '\n--- the guest environment ---\n'
# shellcheck disable=SC2016  # these must expand in the guest, not on the host.
guest sh -c 'echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"; echo "DISABLE_TELEMETRY=${DISABLE_TELEMETRY:-<unset>}"; echo "DISABLE_ERROR_REPORTING=${DISABLE_ERROR_REPORTING:-<unset>}"; echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:+<set>}${ANTHROPIC_API_KEY:-<unset>}"'

printf -- '\n--- verify-auth refuses cleanly with no token ---\n'
VA_OUT="${TMP_ROOT}/verify-auth.out"
"$AGENTBOX" verify-auth "$CLEAN_REPO" > "$VA_OUT" 2>&1
rc=$?
cat "$VA_OUT"
if [ "$rc" -ne 0 ]; then ok "verify-auth exited non-zero without a token"; else bad "verify-auth exited 0 without a token"; fi
if grep -q 'no token at' "$VA_OUT"; then
    ok "verify-auth named the missing token as the reason"
else
    bad "verify-auth did not name the missing token"
fi
if grep -qi 'browser\|log in' "$VA_OUT"; then
    bad "verify-auth fell through to an interactive login"
else
    ok "verify-auth did not fall through to an interactive login"
fi

printf -- '\n--- limactl shell does not allocate a pty for piped stdin ---\n'
# The token subcommand relies on this: with a pty, the guest would echo the
# pasted token back onto the host terminal and into scrollback.
TTY_OUT=$(printf 'x' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- tty 2>&1)
printf '%s\n' "$TTY_OUT"
if printf '%s' "$TTY_OUT" | grep -qi 'not a tty'; then
    ok "no pty is allocated when stdin is a pipe"
else
    bad "a pty was allocated for piped stdin; the token could be echoed"
fi

# ===========================================================================
step "7b. personal config carry-over, plugins, and the interactive subcommand"
# ===========================================================================
#
# Everything staged in step 3d, checked from inside the guest. The plugin
# install ran during provisioning, after the firewall came up, so it is also a
# live test of the GitHub range rule.

printf -- '--- python3 is present (the config sync and the plugin checks need it) ---\n'
PY_OUT=$(guest python3 --version 2>&1)
printf '%s\n' "$PY_OUT"
if printf '%s' "$PY_OUT" | grep -qE 'Python 3\.[0-9]+'; then
    ok "python3 is present in the guest"
else
    bad "python3 is not present in the guest"
fi

printf -- '\n--- the carried-over CLAUDE.md and governor.json ---\n'
CARRY_OUT="${TMP_ROOT}/carry.out"
guest bash -l > "$CARRY_OUT" 2>&1 <<'SH'
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR}"
echo "--- CLAUDE.md ---"
cat "${CLAUDE_CONFIG_DIR}/CLAUDE.md" 2>&1
echo "--- listing ---"
ls -A "${CLAUDE_CONFIG_DIR}" 2>&1
echo "--- rules ---"
ls -A "${CLAUDE_CONFIG_DIR}/rules" 2>&1
echo "--- settings.json as installed ---"
cat "${CLAUDE_CONFIG_DIR}/settings.json" 2>&1
for f in governor.json rules/smoke.md; do
    if [ -f "${CLAUDE_CONFIG_DIR}/${f}" ]; then echo "PRESENT ${f}"; else echo "MISSING ${f}"; fi
done
if [ -e "${CLAUDE_CONFIG_DIR}/.credentials.json" ]; then
    echo "CRED-PRESENT"
else
    echo "CRED-ABSENT"
fi
SH
cat "$CARRY_OUT"

if grep -qF "$CLAUDE_MARKER" "$CARRY_OUT"; then
    ok "the host CLAUDE.md was carried into the guest config directory"
else
    bad "the host CLAUDE.md did not reach the guest config directory"
fi
if grep -qx 'PRESENT governor.json' "$CARRY_OUT"; then
    ok "governor.json was carried over"
else
    bad "governor.json was not carried over"
fi
if grep -qx 'PRESENT rules/smoke.md' "$CARRY_OUT"; then
    ok "rules/*.md were carried over"
else
    bad "rules/*.md were not carried over"
fi
if grep -qx 'CRED-ABSENT' "$CARRY_OUT"; then
    ok "the staged .credentials.json was NOT copied into the guest"
else
    bad "a .credentials.json reached the guest config directory"
fi

# settings.json crosses, but filtered. A name-based allowlist cannot see inside
# a file, and this file's `env` block is a credential.
if grep -q "\"${SETTINGS_HARMLESS_KEY}\"" "$CARRY_OUT"; then
    ok "the harmless settings.json key survived the crossing"
else
    bad "the harmless settings.json key did not survive the crossing"
fi
if grep -q '"env"' "$CARRY_OUT"; then
    bad "the settings.json env block reached the guest"
else
    ok "the settings.json env block did NOT reach the guest"
fi
if grep -q '"apiKeyHelper"' "$CARRY_OUT"; then
    bad "the settings.json apiKeyHelper reached the guest"
else
    ok "the settings.json apiKeyHelper did NOT reach the guest"
fi
if grep -qF "$SETTINGS_FAKE_KEY" "$CARRY_OUT"; then
    bad "the fake API key from settings.json reached the guest"
else
    ok "the fake API key from settings.json did NOT reach the guest"
fi

printf -- '\n--- the refusal and the stripping are logged, not silent ---\n'
SYNC_OUT="${TMP_ROOT}/sync.out"
guest /opt/agent-box/guest/sync-claude-config.sh > "$SYNC_OUT" 2>&1
rc=$?
cat "$SYNC_OUT"
if [ "$rc" -eq 0 ]; then ok "sync-claude-config exited 0 on a second run (idempotent)"; else bad "sync-claude-config exited ${rc} on a second run"; fi
if grep -q 'REFUSED .credentials.json' "$SYNC_OUT"; then
    ok "the refusal of .credentials.json was reported"
else
    bad "the refusal of .credentials.json was not reported"
fi
if grep -q 'STRIPPED settings.json:env' "$SYNC_OUT" && grep -q 'STRIPPED settings.json:apiKeyHelper' "$SYNC_OUT"; then
    ok "each stripped settings.json key was named"
else
    bad "the stripped settings.json keys were not named"
fi

printf -- '\n--- a settings.json edited inside the guest cannot smuggle a key past the precondition ---\n'
# The filter above covers the file that crosses the mount. This covers the
# other way in: a settings.json written directly inside the guest. Without the
# check in lib.sh, `env.ANTHROPIC_API_KEY` would be injected by the CLI after
# abx_assert_environment had already approved the shell environment, and the
# run would bill an API account instead of the subscription. A token is planted
# too, so the refusal cannot be the "no token" one.
#
# agent-run.sh is invoked directly rather than through `agentbox run`, because
# the host command re-syncs the config first and would repair the poisoned file
# before the guest ever saw it. Bypassing that is the point: the guard has to
# hold on the file as it stands, not only on the file as the mount supplies it.
POISON_OUT="${TMP_ROOT}/poisoned-settings.out"
POISON_TOKEN="sk-ant-oat01-POISONHEADzzzzzzzzzzzzzzzzPOISONTAIL"
guest bash -l <<SH
umask 077
printf '%s' '${POISON_TOKEN}' > "\$HOME/.config/agent-box/token"
chmod 600 "\$HOME/.config/agent-box/token"
cp "\${CLAUDE_CONFIG_DIR}/settings.json" /tmp/settings.json.smokebak
printf '{"env":{"ANTHROPIC_API_KEY":"%s"}}\n' '${SETTINGS_FAKE_KEY}' > "\${CLAUDE_CONFIG_DIR}/settings.json"
SH
printf 'Do nothing.\n' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    /opt/agent-box/guest/agent-run.sh --slug poison --brief - > "$POISON_OUT" 2>&1
poison_rc=$?
cat "$POISON_OUT"
if [ "$poison_rc" -ne 0 ]; then
    ok "agent-run refused while settings.json carried a credential"
else
    bad "agent-run proceeded with a credential-bearing settings.json"
fi
if [ -d "${CLEAN_REPO}/.agent-box" ] || git -C "$CLEAN_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -q '^agent/poison'; then
    bad "agent-run changed something before refusing over settings.json"
else
    ok "agent-run changed nothing before refusing over settings.json"
fi
if grep -q 'credential-bearing keys' "$POISON_OUT" && grep -q 'settings.json' "$POISON_OUT"; then
    ok "the refusal named settings.json and the key"
else
    bad "the refusal did not name settings.json"
fi
if grep -qF "$SETTINGS_FAKE_KEY" "$POISON_OUT"; then
    bad "the refusal echoed the key's value"
else
    ok "the refusal did not echo the key's value"
fi
# Put the guest back the way it was: the filtered settings.json, no token.
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
guest bash -l -c 'mv -f /tmp/settings.json.smokebak "${CLAUDE_CONFIG_DIR}/settings.json"; rm -f "$HOME/.config/agent-box/token"'

printf -- '\n--- /work is marked as a trusted folder ---\n'
TRUST_OUT="${TMP_ROOT}/trust.out"
guest bash -l > "$TRUST_OUT" 2>&1 <<'SH'
jq -r --arg p /work '.projects[$p].hasTrustDialogAccepted' "${CLAUDE_CONFIG_DIR}/.claude.json"
SH
cat "$TRUST_OUT"
if grep -qx 'true' "$TRUST_OUT"; then
    ok 'projects["/work"].hasTrustDialogAccepted is true'
else
    bad 'projects["/work"].hasTrustDialogAccepted is not true'
fi

printf -- '\n--- DISABLE_AUTOUPDATER in the login environment ---\n'
# shellcheck disable=SC2016  # must expand in the guest, not on the host.
AU_OUT=$(guest bash -lc 'echo "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER:-<unset>}"' 2>&1)
printf '%s\n' "$AU_OUT"
if printf '%s' "$AU_OUT" | grep -qx 'DISABLE_AUTOUPDATER=1'; then
    ok "DISABLE_AUTOUPDATER=1 in the login environment"
else
    bad "DISABLE_AUTOUPDATER is not 1 in the login environment"
fi

printf -- '\n--- agentbox plugins: the on-demand path, and whether it needs an account ---\n'
PLUG_OUT="${TMP_ROOT}/plugins.out"
run_bounded 300 "$PLUG_OUT" "$AGENTBOX" plugins "$CLEAN_REPO"
plug_rc=$BOUNDED_RC
cat "$PLUG_OUT"
printf 'agentbox plugins exit status: %s\n' "$plug_rc"

printf -- '\n--- claude plugin marketplace list / claude plugin list ---\n'
PLIST_OUT="${TMP_ROOT}/plugin-list.out"
MK_OUT="${TMP_ROOT}/marketplace-list.out"
INST_OUT="${TMP_ROOT}/installed-list.out"
guest bash -l > "$MK_OUT" 2>&1 <<'SH'
claude plugin marketplace list 2>&1
SH
guest bash -l > "$INST_OUT" 2>&1 <<'SH'
claude plugin list 2>&1
SH
{ printf -- '--- marketplaces ---\n'; cat "$MK_OUT"; printf -- '--- installed ---\n'; cat "$INST_OUT"; } | tee "$PLIST_OUT"

# One of two things is true, and the point of the step is to record which.
# Either an explicit CLI install works with no account in the VM, or it does
# not and the documented fallback is what the operator sees.
#
# The installed check asserts the full identity, `<plugin>@konyklabs-plugins`,
# against the installed listing alone. A bare plugin name would also match the
# marketplace listing, and a plugin of that name from some other marketplace.
if grep -q "$MARKETPLACE_NAME" "$MK_OUT" && grep -q "${PLUGIN_UNDER_TEST}@${MARKETPLACE_NAME}" "$INST_OUT"; then
    ok "PLUGIN PATH: install needs NO account — ${MARKETPLACE_NAME} is registered and ${PLUGIN_UNDER_TEST} is installed"
    if [ "$plug_rc" -eq 0 ]; then
        ok "agentbox plugins exited 0 on an already-satisfied plugins.txt"
    else
        bad "agentbox plugins exited ${plug_rc} although the plugin is installed"
    fi
    # Installed is not the same as usable. `claude plugin install` records the
    # enable in settings.json, which is the very file the config sync carries
    # over — so a sync that copied it wholesale would disable every plugin the
    # guest had just installed, and the listing above would still say it was
    # installed. That is the failure this line exists to catch.
    if grep -q 'disabled' "$INST_OUT"; then
        bad "${PLUGIN_UNDER_TEST} is installed but DISABLED — the config sync clobbered enabledPlugins"
    else
        ok "${PLUGIN_UNDER_TEST} survived the config sync still enabled"
    fi
elif [ "$plug_rc" -eq 4 ] && grep -q 'would not install plugins without an account' "$PLUG_OUT"; then
    ok "PLUGIN PATH: install NEEDS an account — the documented fallback was printed and the exit status was 4"
    if grep -q 'agentbox plugins <repo>' "$PLUG_OUT"; then
        ok "the fallback names 'agentbox plugins' as the next step"
    else
        bad "the fallback does not name the next step"
    fi
else
    bad "neither plugin path held: exit ${plug_rc}, and the listings show neither the marketplace nor the fallback"
fi

printf -- '\n--- a session-only plugin from the read-only config mount ---\n'
DEMO_OUT="${TMP_ROOT}/demo-plugin.out"
guest bash -l > "$DEMO_OUT" 2>&1 <<'SH'
claude --plugin-dir /opt/agent-box-config/plugin-dir/demo plugin list 2>&1
SH
cat "$DEMO_OUT"
# `demo@inline` is the identity the CLI prints for a --plugin-dir plugin, and
# it prints it only under Session-only plugins. A bare `demo` would also match
# the directory path in the `Path:` line, which the CLI prints whether or not
# the plugin loaded.
if grep -q 'demo@inline' "$DEMO_OUT"; then
    ok "--plugin-dir loaded demo from the read-only host config mount"
else
    bad "--plugin-dir did not load demo"
fi
if grep -qE 'Status:.*(loaded|enabled)' "$DEMO_OUT"; then
    ok "the CLI reported the session plugin as loaded, not merely listed"
else
    bad "the CLI did not report the session plugin as loaded"
fi

printf -- '\n--- agentbox claude refuses cleanly with no token ---\n'
AC_OUT="${TMP_ROOT}/agentbox-claude.out"
run_bounded 60 "$AC_OUT" "$AGENTBOX" claude "$CLEAN_REPO" --version
ac_rc=$BOUNDED_RC
cat "$AC_OUT"
if [ "$ac_rc" -ne 0 ]; then ok "agentbox claude exited non-zero without a token"; else bad "agentbox claude exited 0 without a token"; fi
if grep -q 'no token at' "$AC_OUT"; then
    ok "agentbox claude named the missing token as the reason"
else
    bad "agentbox claude did not name the missing token"
fi
if grep -qi 'browser\|log in' "$AC_OUT"; then
    bad "agentbox claude fell through to an interactive login"
else
    ok "agentbox claude did not fall through to an interactive login"
fi

printf -- '\n--- agentbox update reports a version either side of the update ---\n'
UP_OUT="${TMP_ROOT}/update.out"
run_bounded 300 "$UP_OUT" "$AGENTBOX" update "$CLEAN_REPO"
up_rc=$BOUNDED_RC
cat "$UP_OUT"
if [ "$up_rc" -eq 0 ]; then ok "agentbox update exited 0"; else bad "agentbox update exited ${up_rc}"; fi
if grep -qE '^agentbox: before: .*[0-9]+\.[0-9]+\.[0-9]+' "$UP_OUT" && grep -qE '^agentbox: after: +.*[0-9]+\.[0-9]+\.[0-9]+' "$UP_OUT"; then
    ok "agentbox update printed the version before and after"
else
    bad "agentbox update did not print both versions"
fi

# ===========================================================================
step "7c. install-plugins rejects a bad directive and bounds its CLI calls"
# ===========================================================================
#
# Both paths need a plugins.txt other than the one on the read-only mount, so
# they use AGENT_BOX_CONFIG_DIR to point the script at a writable directory in
# the guest. Neither can be exercised on the host: the script needs bash 4's
# mapfile and coreutils `timeout`, and this Mac has bash 3.2 and neither.

printf -- '--- a directive argument that starts with a dash is refused ---\n'
DASH_OUT="${TMP_ROOT}/plugins-dash.out"
guest bash -l > "$DASH_OUT" 2>&1 <<'SH'
rm -rf /tmp/abx-badcfg
mkdir -p /tmp/abx-badcfg
printf 'marketplace --help\n' > /tmp/abx-badcfg/plugins.txt
AGENT_BOX_CONFIG_DIR=/tmp/abx-badcfg /opt/agent-box/guest/install-plugins.sh
echo "RC=$?"
SH
cat "$DASH_OUT"
guest sh -c 'rm -rf /tmp/abx-badcfg'
if grep -q 'RC=2' "$DASH_OUT"; then
    ok "a malformed directive exited 2"
else
    bad "a malformed directive did not exit 2"
fi
if grep -q "must not start with '-'" "$DASH_OUT"; then
    ok "a leading-dash argument was refused by name"
else
    bad "a leading-dash argument was not refused"
fi
if grep -q 'marketplace add --help: ok' "$DASH_OUT"; then
    bad "the CLI was invoked with the dash argument as a flag"
else
    ok "the CLI was never invoked with the dash argument"
fi

printf -- '\n--- a CLI call that never answers is bounded and reported as unreachable ---\n'
# A stub `claude` that hangs, reached through a temporary HOME because the
# script prepends "$HOME/.local/bin" to PATH. This reproduces the shape of an
# unresponsive marketplace exactly, with no dependency on the network being
# broken at the time.
HANG_OUT="${TMP_ROOT}/plugins-hang.out"
run_bounded 90 "$HANG_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -l -c '
rm -rf /tmp/abx-hang
mkdir -p /tmp/abx-hang/.local/bin /tmp/abx-hang/cfg
printf "#!/bin/sh\nsleep 300\n" > /tmp/abx-hang/.local/bin/claude
chmod +x /tmp/abx-hang/.local/bin/claude
printf "marketplace someone/never-answers\n" > /tmp/abx-hang/cfg/plugins.txt
HOME=/tmp/abx-hang AGENT_BOX_CONFIG_DIR=/tmp/abx-hang/cfg ABX_CLI_TIMEOUT=3 \
    /opt/agent-box/guest/install-plugins.sh
echo "RC=$?"
'
cat "$HANG_OUT"
guest sh -c 'rm -rf /tmp/abx-hang'
if grep -q 'RC=5' "$HANG_OUT"; then
    ok "an unanswering CLI call exited 5, the unreachable-marketplace status"
else
    bad "an unanswering CLI call did not exit 5"
fi
if grep -q 'the marketplace is unreachable' "$HANG_OUT"; then
    ok "the timeout was reported as an unreachable marketplace"
else
    bad "the timeout was not reported as an unreachable marketplace"
fi
if grep -q 'firewall-check' "$HANG_OUT"; then
    ok "the unreachable message names the next thing to run"
else
    bad "the unreachable message does not name a next step"
fi

# ===========================================================================
step "8. agent-run refuses to start without a token"
# ===========================================================================

# --wait, because these four checks are about the exit status and the message
# reaching the caller. Runs are detached by default now, so the plain form
# returns 0 with the run still starting; the detached path is the next step.
RUN_OUT="${TMP_ROOT}/run.out"
printf 'Do nothing.\n' > "${TMP_ROOT}/noop-brief.md"
run_bounded 240 "$RUN_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
rc=$BOUNDED_RC
cat "$RUN_OUT"
if [ "$rc" -ne 0 ]; then ok "agent-run exited non-zero without a token"; else bad "agent-run exited 0 without a token"; fi
if grep -q 'no token at' "$RUN_OUT"; then
    ok "agent-run explained that the token is missing"
else
    bad "agent-run did not name the missing token as the reason"
fi
if [ -d "${CLEAN_REPO}/.agent-box" ]; then
    bad "agent-run created state despite refusing to run"
else
    ok "agent-run changed nothing before refusing"
fi

# ===========================================================================
step "8a. a DETACHED run without a token fails fast, and says so afterwards"
# ===========================================================================
#
# The default shape: `run` returns as soon as the task has started, and the
# record of what happened is read back with `runs` and `logs`. A run that dies
# in its preconditions has no terminal to have printed on, so this is the only
# way that failure is ever seen.

DET_OUT="${TMP_ROOT}/detached.out"
run_bounded 90 "$DET_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
det_rc=$BOUNDED_RC
cat "$DET_OUT"
if [ "$det_rc" -eq 0 ]; then ok "a detached run returned 0 immediately"; else bad "a detached run exited ${det_rc}"; fi

DET_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$DET_OUT" | head -1)
printf 'detached runid: %s\n' "${DET_RUNID:-<none>}"
if [ -n "$DET_RUNID" ]; then ok "the run id was printed"; else bad "no run id was printed"; fi

# It fails in its preconditions, so it is over in seconds; poll rather than
# assume.
DET_STATE=""
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    DET_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$DET_RUNID" 2>/dev/null | tr -d '\r\n')
    case "$DET_STATE" in running|"") sleep 2 ;; *) break ;; esac
done
printf 'state: %s\n' "$DET_STATE"

DET_RUNS="${TMP_ROOT}/detached-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$DET_RUNS" 2>&1
cat "$DET_RUNS"
if grep -q "$DET_RUNID" "$DET_RUNS" && grep -qE "${DET_RUNID}.*failed" "$DET_RUNS"; then
    ok "runs lists the detached run as failed"
else
    bad "runs does not list the detached run as failed"
fi
case "$DET_STATE" in
    exit:0)  bad "the tokenless run recorded exit:0" ;;
    exit:*)  ok "the run recorded a non-zero exit (${DET_STATE})" ;;
    *)       bad "the run never left state '${DET_STATE}'" ;;
esac

DET_LOGS="${TMP_ROOT}/detached-logs.out"
run_bounded 60 "$DET_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$DET_RUNID"
cat "$DET_LOGS"
if grep -q 'no token at' "$DET_LOGS"; then
    ok "logs shows the reason the detached run failed"
else
    bad "logs does not show why the detached run failed"
fi

# ===========================================================================
step "8b. the token leak check fires and exits 3"
# ===========================================================================
#
# The check must catch the token reaching the host's disk. It runs after a real
# `claude -p` call, so a fake token is planted first: the call will fail
# authentication, which is fine — the leak check runs regardless, and what is
# being tested is that a hit reaches the caller as exit 3 rather than being lost
# in a subshell.

FAKE_TOKEN="sk-ant-oat01-SMOKEHEADzzzzzzzzzzzzzzzzzzzzSMOKETAIL"
guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"
if guest sh -c 'test -d /work/.git'; then
    ok "the work repo is present in the guest"
else
    bad "the work repo is missing in the guest"
fi

# A tracked file, so that the planted token shows up in `git diff` — which is
# one of the streams the check reads.
guest sh -c 'cd /work && git add -A && git commit -q -m "smoke base" 2>&1 | tail -1; true'
guest sh -c "cd /work && printf 'leaked: %s\\n' '${FAKE_TOKEN}' >> hello.txt"
printf -- '--- git diff in the guest now carries the fake token ---\n'
guest sh -c 'cd /work && git diff --stat'

LEAK_OUT="${TMP_ROOT}/leak.out"
run_bounded 300 "$LEAK_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
leak_rc=$BOUNDED_RC
cat "$LEAK_OUT"
printf 'agentbox run exit status: %s\n' "$leak_rc"

if [ "$leak_rc" -eq 3 ]; then
    ok "agent-run exited 3 when the token appeared in output reaching the host"
else
    bad "agent-run exited ${leak_rc}; expected 3 for a token leak"
fi
# The report has two halves now. `logs` refuses a leak-flagged run's events, so
# what --wait shows is the banner; the line naming the stream is in the output
# the banner is withholding, and --force-unsafe is how you get it.
if grep -q 'leak check found the OAuth token' "$LEAK_OUT"; then
    ok "the leak was reported to the operator, with what to do about it"
else
    bad "the leak was not reported"
fi
LEAK_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$LEAK_OUT" | head -1)
if [ -n "$LEAK_RUNID" ]; then
    LEAK_FORCED="${TMP_ROOT}/leak-forced.out"
    run_bounded 60 "$LEAK_FORCED" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAK_RUNID" --force-unsafe
    if grep -q 'SECURITY: the token appears in' "$LEAK_FORCED"; then
        ok "--force-unsafe shows the leak report, naming the stream"
    else
        bad "--force-unsafe did not show the leak report"
    fi
    if grep -qF "$FAKE_TOKEN" "$LEAK_FORCED"; then
        bad "--force-unsafe echoed the token value"
    else
        ok "--force-unsafe still did not echo the token value"
    fi
else
    bad "could not read the leaking run's id back"
fi
if grep -qF "$FAKE_TOKEN" "$LEAK_OUT"; then
    bad "the token value itself was echoed by the leak report"
else
    ok "the leak report did not echo the token value"
fi

printf -- '\n--- clean up the planted token and the modified file ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; true'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -rf /work/.agent-box $HOME/.agent-box/runs' || true

# The planted token must be gone from the work tree, or step 9's preflight will
# legitimately refuse to start the VM.
if grep -rqF "$FAKE_TOKEN" "$CLEAN_REPO" 2>/dev/null; then
    bad "the planted token is still in the work tree on the host"
else
    ok "the planted token is gone from the work tree"
fi

# ===========================================================================
step "8d. a detached run that reaches the CLI: the run directory, runs, logs"
# ===========================================================================
#
# With a fake token in place the run gets all the way to a real `claude` call
# and fails authentication. That is the interesting case for the sensors: there
# is a run directory, an event stream, a status, and a formatted log — and none
# of it may carry a fragment of the token.

guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"

AUTH_OUT="${TMP_ROOT}/authfail.out"
run_bounded 90 "$AUTH_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$AUTH_OUT"
AUTH_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$AUTH_OUT" | head -1)
printf 'runid: %s\n' "${AUTH_RUNID:-<none>}"
if [ -n "$AUTH_RUNID" ]; then
    ok "the fake-token run started and printed its id"
else
    # Not a fabricated id: `logs` for one that does not exist returns fast and
    # non-zero, which would make every assertion below report a pass for a run
    # that never happened.
    bad "the fake-token run printed no id; skipping the checks that depend on it"
    summarise_and_exit
fi

# `logs -f` must come back on its own when the run ends. Started here, while
# the run is still going, which is the only way that claim means anything.
FOLLOW_OUT="${TMP_ROOT}/logs-follow.out"
FOLLOW_T0=$(date +%s)
run_bounded 300 "$FOLLOW_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID" -f
follow_rc=$BOUNDED_RC
FOLLOW_ELAPSED=$(( $(date +%s) - FOLLOW_T0 ))
cat "$FOLLOW_OUT"
printf 'logs -f returned after %ss with status %s\n' "$FOLLOW_ELAPSED" "$follow_rc"
# Exit 0, not merely "not killed". A `logs` that failed instantly — a run id
# that does not exist, an instance that stopped answering — also returns
# non-124, and would report a pass for something that never followed anything.
if [ "$follow_rc" -eq 0 ]; then
    ok "logs -f returned on its own, with exit 0, when the run ended"
else
    bad "logs -f exited ${follow_rc}; it did not follow the run to its end"
fi
if grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}  status  exit:' "$FOLLOW_OUT"; then
    ok "logs -f ended with the run's status line"
else
    bad "logs -f did not print the run's status line"
fi

printf -- '\n--- the run directory as it stands in the guest ---\n'
RUNDIR_OUT="${TMP_ROOT}/rundir.out"
guest sh -c "ls -la \$HOME/.agent-box/runs/${AUTH_RUNID}" > "$RUNDIR_OUT" 2>&1
cat "$RUNDIR_OUT"
for f in meta.json events.jsonl status console.log hooks.jsonl summary.txt; do
    if grep -q " ${f}\$" "$RUNDIR_OUT"; then
        ok "the run directory has ${f}"
    else
        bad "the run directory is missing ${f}"
    fi
done
printf -- '\n--- meta.json ---\n'
guest sh -c "cat \$HOME/.agent-box/runs/${AUTH_RUNID}/meta.json" 2>&1

printf -- '\n--- runs --json, in the form a caller assembling a command line uses ---\n'
# `--` before the operands. A caller that did not type the path cannot know
# whether it begins with a dash, and this is the only way it can say so.
RUNSJ="${TMP_ROOT}/runs.json"
"$AGENTBOX" runs --json -- "$CLEAN_REPO" > "$RUNSJ" 2>&1
cat "$RUNSJ"
if jq -e . "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json -- <repo> works with the operand after a double dash"
else
    bad "runs --json -- <repo> did not produce JSON"
fi
if jq -e . "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json parses"
else
    bad "runs --json does not parse"
fi
if jq -e --arg r "$AUTH_RUNID" 'map(select(.runid == $r and .state == "failed")) | length == 1' "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json lists the run with state failed"
else
    bad "runs --json does not list the run as failed"
fi
if jq -e --arg r "$AUTH_RUNID" 'map(select(.runid == $r))[0] | has("exit_code") and has("model") and has("branch") and has("started_at") and has("duration_s") and has("turns") and has("cost_usd") and has("files_changed")' "$RUNSJ" >/dev/null 2>&1; then
    ok "runs --json carries every documented key"
else
    bad "runs --json is missing documented keys"
fi

printf -- '\n--- logs, formatted ---\n'
LOGS_OUT="${TMP_ROOT}/logs.out"
run_bounded 90 "$LOGS_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID"
cat "$LOGS_OUT"
if grep -qE '^[0-9]{2}:[0-9]{2}:[0-9]{2}  (status|text|tool|out|hook|result) ' "$LOGS_OUT"; then
    ok "logs printed formatted event lines"
else
    bad "logs printed no formatted event lines"
fi
FAKE_HEAD=${FAKE_TOKEN:0:8}
FAKE_TAIL=${FAKE_TOKEN: -8}
if grep -qF "$FAKE_HEAD" "$LOGS_OUT" || grep -qF "$FAKE_TAIL" "$LOGS_OUT"; then
    bad "logs printed a fragment of the token"
else
    ok "logs printed neither the token's head nor its tail"
fi

printf -- '\n--- logs --json ---\n'
LOGSJ="${TMP_ROOT}/logs.json"
run_bounded 90 "$LOGSJ" "$AGENTBOX" logs "$CLEAN_REPO" "$AUTH_RUNID" --json
head -5 "$LOGSJ"
LOGSJ_BAD=0
LOGSJ_LINES=0
while IFS= read -r jline; do
    [ -n "$jline" ] || continue
    LOGSJ_LINES=$((LOGSJ_LINES + 1))
    printf '%s' "$jline" | jq -e 'has("ts") and has("run") and has("kind") and has("text") and has("tool") and has("detail")' >/dev/null 2>&1 \
        || LOGSJ_BAD=$((LOGSJ_BAD + 1))
done < "$LOGSJ"
printf '%s lines, %s malformed\n' "$LOGSJ_LINES" "$LOGSJ_BAD"
if [ "$LOGSJ_LINES" -gt 0 ] && [ "$LOGSJ_BAD" -eq 0 ]; then
    ok "every logs --json line parses and carries the required keys"
else
    bad "logs --json produced ${LOGSJ_LINES} lines with ${LOGSJ_BAD} malformed"
fi
if grep -qF "$FAKE_HEAD" "$LOGSJ" || grep -qF "$FAKE_TAIL" "$LOGSJ"; then
    bad "logs --json printed a fragment of the token"
else
    ok "logs --json printed neither the token's head nor its tail"
fi

# ---- slot:8d2 (owner M1) ----
# ---- end slot:8d2 ----

# ---- slot:8d3 (owner TB) ----
# ---- end slot:8d3 ----

# ===========================================================================
step "8a2. heal: a failed run with budget starts its own follow-up, and the chain ends"
# ===========================================================================
#
# The fake token from 8d is still in place, so the run reaches the CLI and fails
# there — a failure of the agent's work, which is what heal is for. A run that
# dies in its preconditions is deliberately NOT healed (see docs/daily-use.md).
# This proves the mechanism and its bound: one follow-up, told what failed,
# itself failing at the same auth, and no third.

HEAL_OUT="${TMP_ROOT}/heal.out"
run_bounded 90 "$HEAL_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --heal 1 --heal-delay 1
cat "$HEAL_OUT"
HEAL_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$HEAL_OUT" | head -1)
if grep -q 'heal: up to 1 follow-up' "$HEAL_OUT"; then ok "run announced the heal budget"; else bad "run did not announce the heal budget"; fi

HEAL_CHILD=""
for _attempt in $(seq 1 30); do
    HEAL_CHILD=$(guest bash -c "grep -l '\"heal_parent\": \"${HEAL_RUNID}\"' \$HOME/.agent-box/runs/*/meta.json 2>/dev/null | head -1 | xargs -r dirname | xargs -r basename" 2>/dev/null | tr -d '\r\n')
    [ -n "$HEAL_CHILD" ] && break
    sleep 2
done
printf 'heal child: %s\n' "${HEAL_CHILD:-<none>}"
if [ -n "$HEAL_CHILD" ] && [ "$HEAL_CHILD" != "$HEAL_RUNID" ]; then ok "the failed run started a follow-up"; else bad "no follow-up run was started"; fi

if [ -n "$HEAL_CHILD" ]; then
    CHILD_STATE=""
    for _attempt in $(seq 1 30); do
        CHILD_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$HEAL_CHILD" 2>/dev/null | tr -d '\r\n')
        case "$CHILD_STATE" in running|"") sleep 2 ;; *) break ;; esac
    done
    printf 'child state: %s\n' "$CHILD_STATE"
    case "$CHILD_STATE" in
        exit:0) bad "the tokenless follow-up recorded exit:0" ;;
        exit:[0-9]*) ok "the follow-up ended with a non-zero exit" ;;
        *) bad "the follow-up never ended (${CHILD_STATE})" ;;
    esac
    CHILD_LEFT=$(guest bash -c "jq -r '.heal_left' \$HOME/.agent-box/runs/${HEAL_CHILD}/meta.json" 2>/dev/null | tr -d '\r\n')
    if [ "$CHILD_LEFT" = "0" ]; then ok "the follow-up has no heal budget left"; else bad "the follow-up's heal_left is '${CHILD_LEFT}', expected 0"; fi
    GRAND=$(guest bash -c "grep -l '\"heal_parent\": \"${HEAL_CHILD}\"' \$HOME/.agent-box/runs/*/meta.json 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r\n')
    if [ "${GRAND:-0}" = "0" ]; then ok "the chain stopped: no third run"; else bad "a third run was started past the budget"; fi
    if guest bash -c "grep -q 'Heal attempt 1 of 1 for run ${HEAL_RUNID}' \$HOME/.agent-box/briefs/${HEAL_CHILD}.md && grep -q 'The original brief follows' \$HOME/.agent-box/briefs/${HEAL_CHILD}.md"; then
        ok "the follow-up's brief names the failed run and carries the original brief"
    else
        bad "the follow-up's brief is not the rendered heal template"
    fi
    HEAL_RUNS="${TMP_ROOT}/heal-runs.json"
    "$AGENTBOX" runs "$CLEAN_REPO" --json > "$HEAL_RUNS" 2>/dev/null
    if python3 -c "import json,sys; d=json.load(open('$HEAL_RUNS')); d=d if isinstance(d,list) else d.get('runs',[]); sys.exit(0 if any(r.get('heal_parent')=='$HEAL_RUNID' and r.get('heal_attempt')==1 for r in d) else 1)"; then
        ok "runs --json carries heal_parent and heal_attempt"
    else
        bad "runs --json does not carry the heal lineage"
    fi
fi

step "8a3. waiting and resume: a question is recorded, shown, answered and continued"
# ===========================================================================
#
# A synthetic waiting run, the way the stop tests build theirs, because reaching
# the end of a real run needs a token this box does not have. What is real: the
# derived state, `ask`, and `resume` building the follow-up from the original
# brief and the answer, then starting it.

WAITING=20260101-333333
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${WAITING}"
rm -rf "\$d"; mkdir -p "\$d" "\$HOME/.agent-box/briefs"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
printf '2026-01-01T03:33:33Z\n' > "\$d/waiting"
printf 'Which option, A or B?\n' > "\$d/ask.md"
printf '{"runid":"${WAITING}","model":"sonnet","branch":"agent/ask-${WAITING}","brief":"${WAITING}.md","started_at":"2026-01-01T03:33:33Z","tmux":null,"max_turns":7,"max_budget_usd":null,"claude_version":null,"slug":"ask","origin":"${WAITING}","heal_left":2,"heal_max":2}\n' > "\$d/meta.json"
printf '# Brief: the original words\n\nDo the thing.\n' > "\$HOME/.agent-box/briefs/${WAITING}.md"
mkdir -p /work/.agent-box; printf 'stale question\n' > /work/.agent-box/ask.md
SH
WAIT_RUNS="${TMP_ROOT}/waiting-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$WAIT_RUNS" 2>&1
if grep -qE "${WAITING}.*waiting" "$WAIT_RUNS"; then ok "runs shows the waiting state"; else bad "runs does not show waiting"; cat "$WAIT_RUNS"; fi
ASK_OUT="${TMP_ROOT}/ask.out"
run_bounded 60 "$ASK_OUT" "$AGENTBOX" ask "$CLEAN_REPO" "$WAITING"
if grep -q 'Which option, A or B?' "$ASK_OUT"; then ok "ask prints the question"; else bad "ask did not print the question"; cat "$ASK_OUT"; fi
ASK_NEWEST="${TMP_ROOT}/ask-newest.out"
run_bounded 60 "$ASK_NEWEST" "$AGENTBOX" ask "$CLEAN_REPO"
if grep -q 'Which option, A or B?' "$ASK_NEWEST"; then ok "ask with no run id finds the newest waiting run"; else bad "ask with no run id did not find the waiting run"; fi

RESUME_OUT="${TMP_ROOT}/resume.out"
run_bounded 90 "$RESUME_OUT" "$AGENTBOX" resume "$CLEAN_REPO" "$WAITING" --answer "Option B, and say why."
cat "$RESUME_OUT"
RESUMED=$(sed -n 's/^agentbox: resumed as run \([0-9-]*\) .*/\1/p' "$RESUME_OUT" | head -1)
if [ -n "$RESUMED" ]; then ok "resume started a follow-up run (${RESUMED})"; else bad "resume did not start a run"; fi
if [ -n "$RESUMED" ]; then
    if guest bash -c "grep -q 'Option B, and say why.' \$HOME/.agent-box/briefs/${RESUMED}.md && grep -q 'Which option, A or B?' \$HOME/.agent-box/briefs/${RESUMED}.md && grep -q 'the original words' \$HOME/.agent-box/briefs/${RESUMED}.md"; then
        ok "the resumed brief carries the question, the answer and the original brief"
    else
        bad "the resumed brief is missing the question, the answer or the original"
    fi
    RES_META=$(guest bash -c "jq -c '[.resume_of,.origin,.heal_left,.max_turns,.model]' \$HOME/.agent-box/runs/${RESUMED}/meta.json" 2>/dev/null | tr -d '\r\n')
    printf 'resumed meta: %s\n' "$RES_META"
    if [ "$RES_META" = "[\"${WAITING}\",\"${WAITING}\",2,7,\"sonnet\"]" ]; then
        ok "the resumed run inherits origin, heal budget, caps and model"
    else
        bad "the resumed run's lineage is wrong: ${RES_META}"
    fi
    if guest test ! -e /work/.agent-box/ask.md; then ok "resume cleared the stale ask.md from the mount"; else bad "ask.md is still in the mount after resume"; fi
fi
EMPTY_OUT="${TMP_ROOT}/resume-empty.out"
run_bounded 60 "$EMPTY_OUT" "$AGENTBOX" resume "$CLEAN_REPO" "$WAITING" --answer ""
if [ "$BOUNDED_RC" -ne 0 ] && grep -qiE 'empty|needs --answer' "$EMPTY_OUT"; then ok "resume refuses an empty answer"; else bad "resume accepted an empty answer"; cat "$EMPTY_OUT"; fi

step "8a4. review on a second model: refused on the same model, started from a done run, skipped when empty"
# ===========================================================================
#
# Same shape as 8a3: synthetic done runs, because a real one needs a token. What
# is real: the CLI's same-model refusal, `run-ctl.sh review` rendering the
# template and starting the follow-up with the reviewer's model and lineage,
# the empty case returning 2, and a review never being reviewed.

SAME_OUT="${TMP_ROOT}/review-same.out"
run_bounded 60 "$SAME_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --model sonnet --review sonnet
if [ "$BOUNDED_RC" -ne 0 ] && grep -q 'not a second opinion' "$SAME_OUT"; then ok "run refuses --review on the run's own model"; else bad "run accepted --review on the same model"; cat "$SAME_OUT"; fi

REVIEWED=20260101-444444
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${REVIEWED}"
rm -rf "\$d"; mkdir -p "\$d" "\$HOME/.agent-box/briefs"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
base=\$(git -C /work rev-parse HEAD)
printf '{"runid":"${REVIEWED}","model":"sonnet","branch":"agent/task-${REVIEWED}","brief":"${REVIEWED}.md","started_at":"2026-01-01T04:44:44Z","tmux":null,"max_turns":7,"max_budget_usd":null,"claude_version":null,"slug":"task","origin":"${REVIEWED}","heal_left":1,"heal_max":1,"review_model":"haiku","base_commit":"%s"}\n' "\$base" > "\$d/meta.json"
printf '# Brief: the original words\n\nDo the thing.\n' > "\$HOME/.agent-box/briefs/${REVIEWED}.md"
SH
# A clean tree at the base: nothing to review, exit 2, no follow-up.
EMPTY_REV="${TMP_ROOT}/review-empty.out"
guest bash -lc "/opt/agent-box/guest/run-ctl.sh review --of ${REVIEWED}; echo rc=\$?" > "$EMPTY_REV" 2>&1
if grep -q 'nothing to review' "$EMPTY_REV" && grep -q 'rc=2' "$EMPTY_REV"; then ok "review of a run with no commits and a clean tree says so and returns 2"; else bad "empty review case: $(cat "$EMPTY_REV")"; fi

# Dirty the tree: now there is something to review, and a follow-up starts.
guest bash -lc 'printf "reviewed change\n" >> /work/README.md'
REV_OUT="${TMP_ROOT}/review-start.out"
guest bash -lc "/opt/agent-box/guest/run-ctl.sh review --of ${REVIEWED}; echo rc=\$?" > "$REV_OUT" 2>&1
cat "$REV_OUT"
REV_CHILD=$(grep -oE '^[0-9]{8}-[0-9]{6}$' "$REV_OUT" | head -1)
if [ -n "$REV_CHILD" ] && grep -q 'rc=0' "$REV_OUT"; then ok "review started follow-up run ${REV_CHILD}"; else bad "review did not start a follow-up"; fi
if [ -n "$REV_CHILD" ]; then
    REV_META=$(guest bash -c "jq -c '[.review_of, .model, .review_model, .origin, .heal_left]' \$HOME/.agent-box/runs/${REV_CHILD}/meta.json" 2>/dev/null | tr -d '\r\n')
    if [ "$REV_META" = "[\"${REVIEWED}\",\"haiku\",null,\"${REVIEWED}\",1]" ]; then
        ok "the review runs on the reviewer's model, names the run it reviews, asks for no review of itself"
    else
        bad "the review's lineage is wrong: ${REV_META}"
    fi
    if guest bash -c "grep -q '^# Review of run ${REVIEWED} on a second model' \$HOME/.agent-box/briefs/${REV_CHILD}.md && grep -q 'Do the thing.' \$HOME/.agent-box/briefs/${REV_CHILD}.md"; then
        ok "the review's brief is the rendered template around the original brief"
    else
        bad "the review's brief is not the rendered review template"
    fi
    "$AGENTBOX" stop-run "$CLEAN_REPO" "$REV_CHILD" > /dev/null 2>&1 || true
    AGAIN="${TMP_ROOT}/review-again.out"
    guest bash -lc "/opt/agent-box/guest/run-ctl.sh review --of ${REV_CHILD} --parent-state done" > "$AGAIN" 2>&1 || true
    if grep -q 'not reviewing a review' "$AGAIN"; then ok "a review is never reviewed"; else bad "a review of a review was not refused: $(cat "$AGAIN")"; fi
fi
guest bash -lc 'git -C /work checkout -q -- README.md; git -C /work checkout -q main 2>/dev/null || git -C /work checkout -q master 2>/dev/null || true'

step "8e. hook-event.sh turns one hook payload into one line"
# ===========================================================================

HOOK_OUT="${TMP_ROOT}/hook-event.out"
guest bash -l > "$HOOK_OUT" 2>&1 <<'SH'
set -u
# Inside the state root: hook-event.sh refuses any destination outside it, and
# a mktemp -d under /tmp is exactly the case it refuses.
d="$HOME/.agent-box/sessions/hooktest"
rm -rf "$d"; mkdir -p "$d"
printf '%s' '{"session_id":"abc123","cwd":"/work","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/work/src/x.py","old_string":"a"}}' \
    | AGENT_BOX_EVENTS_DIR="$d" /opt/agent-box/guest/hook-event.sh
echo "RC=$?"
echo "--- hooks.jsonl ---"
cat "$d/hooks.jsonl"
echo "--- fields ---"
jq -r '"event=\(.event) tool=\(.tool) input_head=\(.input_head) session=\(.session_id) ok=\(.ok)"' "$d/hooks.jsonl"
echo "--- with no events dir, it writes nothing and exits 0 ---"
printf '%s' '{"hook_event_name":"Stop"}' | /opt/agent-box/guest/hook-event.sh
echo "RC_NODIR=$?"
rm -rf "$d"
SH
cat "$HOOK_OUT"
if grep -q '^RC=0' "$HOOK_OUT"; then ok "hook-event.sh exited 0"; else bad "hook-event.sh did not exit 0"; fi
if grep -q 'event=PreToolUse tool=Edit input_head=/work/src/x.py session=abc123 ok=null' "$HOOK_OUT"; then
    ok "the hook line carries the expected fields"
else
    bad "the hook line does not carry the expected fields"
fi
if grep -q '^RC_NODIR=0' "$HOOK_OUT"; then
    ok "hook-event.sh exits 0 with no events directory"
else
    bad "hook-event.sh did not exit 0 with no events directory"
fi

# ===========================================================================
step "8f. stop-run: it signals, it observes, and it refuses what it should"
# ===========================================================================
#
# The stand-in traps INT and writes a marker, so the assertion can distinguish
# "the process was interrupted" from "cmd_stop wrote a status file". With an
# unconditional write and a stand-in that ignores signals, this step used to
# pass even if nothing was ever signalled.

STANDIN=20260101-000000
guest bash -l > "${TMP_ROOT}/standin.out" 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${STANDIN}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '{"runid":"${STANDIN}","model":"sonnet","branch":null,"brief":"stand-in","started_at":"2026-01-01T00:00:00Z","tmux":"run-${STANDIN}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
rm -f /tmp/abx-standin-interrupted
cat > /tmp/abx-standin.sh <<'INNER'
#!/bin/bash
# Loops, so that killing the inner sleep is not enough to end it. Only SIGINT
# to this process writes the marker — which is what makes the assertion mean
# "the pane process was interrupted" rather than "something died".
trap 'touch /tmp/abx-standin-interrupted; exit 130' INT
while :; do sleep 300 & wait \$!; done
INNER
chmod +x /tmp/abx-standin.sh
tmux new-session -d -s "run-${STANDIN}" -- /tmp/abx-standin.sh
sleep 1
tmux has-session -t "=run-${STANDIN}" && echo STANDIN-UP
SH
cat "${TMP_ROOT}/standin.out"
if grep -q 'STANDIN-UP' "${TMP_ROOT}/standin.out"; then
    ok "the stand-in run session is up and trapping INT"
else
    bad "the stand-in run session did not start"
fi

STOP_OUT="${TMP_ROOT}/stop-run.out"
STOP_T0=$(date +%s)
run_bounded 90 "$STOP_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$STANDIN"
stop_rc=$BOUNDED_RC
STOP_ELAPSED=$(( $(date +%s) - STOP_T0 ))
cat "$STOP_OUT"
printf 'stop-run took %ss\n' "$STOP_ELAPSED"
if [ "$stop_rc" -eq 0 ]; then ok "stop-run exited 0"; else bad "stop-run exited ${stop_rc}"; fi

if guest test -e /tmp/abx-standin-interrupted; then
    ok "the stand-in actually received SIGINT"
else
    bad "the stand-in was never signalled; the stop was a status write, not a stop"
fi
if [ "$STOP_ELAPSED" -lt 20 ]; then
    ok "the stop completed in ${STOP_ELAPSED}s, before the 20s fallback"
else
    bad "the stop took ${STOP_ELAPSED}s; it fell through to killing the session"
fi

STOP_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$STANDIN" 2>/dev/null | tr -d '\r\n')
printf 'state after stop-run: %s\n' "$STOP_STATE"
if [ "$STOP_STATE" = "exit:stopped" ]; then
    ok "the run records exit:stopped"
else
    bad "the run records '${STOP_STATE}', not exit:stopped"
fi
if guest tmux has-session -t "=run-${STANDIN}" 2>/dev/null; then
    bad "the tmux session survived stop-run"
else
    ok "the tmux session was closed"
fi
if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${STANDIN}.*stopped"; then
    ok "runs shows the stopped run as stopped"
else
    bad "runs does not show the stopped run as stopped"
fi

printf -- '\n--- stopping a run that has already ended is refused, not overwritten ---\n'
AGAIN_OUT="${TMP_ROOT}/stop-again.out"
run_bounded 60 "$AGAIN_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$STANDIN"
again_rc=$BOUNDED_RC
cat "$AGAIN_OUT"
if [ "$again_rc" -ne 0 ] && grep -q 'already ended' "$AGAIN_OUT"; then
    ok "stop-run refused a run that had already ended"
else
    bad "stop-run did not refuse a run that had already ended"
fi

printf -- '\n--- a finished run keeps its own exit code ---\n'
FINISHED=20260101-111111
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${FINISHED}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
printf '{"runid":"${FINISHED}","model":"sonnet","branch":null,"brief":"finished","started_at":"2026-01-01T11:11:11Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
KEEP_OUT="${TMP_ROOT}/stop-finished.out"
run_bounded 60 "$KEEP_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO" "$FINISHED"
cat "$KEEP_OUT"
KEEP_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$FINISHED" 2>/dev/null | tr -d '\r\n')
printf 'state of the finished run afterwards: %s\n' "$KEEP_STATE"
if [ "$KEEP_STATE" = "exit:0" ]; then
    ok "a finished run's exit code survived stop-run"
else
    bad "stop-run overwrote a finished run's exit code with '${KEEP_STATE}'"
fi

printf -- '\n--- with nothing running, stop-run says so instead of picking one ---\n'
NONE_OUT="${TMP_ROOT}/stop-none.out"
run_bounded 60 "$NONE_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO"
none_rc=$BOUNDED_RC
cat "$NONE_OUT"
if [ "$none_rc" -ne 0 ] && grep -q 'no run is running' "$NONE_OUT"; then
    ok "stop-run with no argument refused when nothing was running"
else
    bad "stop-run with no argument did not refuse when nothing was running"
fi

printf -- '\n--- with no argument it picks the newest RUNNING run, not the newest ---\n'
OLD_RUNNING=20260101-222222
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${OLD_RUNNING}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '{"runid":"${OLD_RUNNING}","model":"sonnet","branch":null,"brief":"old-running","started_at":"2026-01-01T22:22:22Z","tmux":"run-${OLD_RUNNING}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
rm -f /tmp/abx-old-interrupted
cat > /tmp/abx-old.sh <<'INNER'
#!/bin/bash
trap 'touch /tmp/abx-old-interrupted; exit 130' INT
while :; do sleep 300 & wait \$!; done
INNER
chmod +x /tmp/abx-old.sh
tmux new-session -d -s "run-${OLD_RUNNING}" -- /tmp/abx-old.sh
sleep 1
SH
# A finished run with a NEWER id than the running one, so that "newest" and
# "newest running" are genuinely different answers and the assertion below can
# tell which one stop-run used.
NEWEST_FINISHED=20260101-333333
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${NEWEST_FINISHED}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:0\n' > "\$d/status"
printf '{"runid":"${NEWEST_FINISHED}","model":"sonnet","branch":null,"brief":"newest-finished","started_at":"2026-01-01T33:33:33Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
PICK_OUT="${TMP_ROOT}/stop-pick.out"
run_bounded 90 "$PICK_OUT" "$AGENTBOX" stop-run "$CLEAN_REPO"
cat "$PICK_OUT"
if grep -q "stopping ${OLD_RUNNING}" "$PICK_OUT"; then
    ok "stop-run chose the newest RUNNING run, not the newest run"
else
    bad "stop-run did not choose the newest running run"
fi
NEWEST_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$NEWEST_FINISHED" 2>/dev/null | tr -d '\r\n')
if [ "$NEWEST_STATE" = "exit:0" ]; then
    ok "the newer finished run was left alone"
else
    bad "the newer finished run was rewritten to '${NEWEST_STATE}'"
fi

printf -- '\n--- a run left saying running with nothing behind it becomes lost ---\n'
ORPHAN=20260101-444444
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${ORPHAN}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'running\n' > "\$d/status"
printf '999999\n' > "\$d/pid"
printf '{"runid":"${ORPHAN}","model":"sonnet","branch":null,"brief":"orphan","started_at":"2026-01-01T44:44:44Z","tmux":"run-${ORPHAN}","max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
ORPHAN_RUNS="${TMP_ROOT}/orphan-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$ORPHAN_RUNS" 2>&1
cat "$ORPHAN_RUNS"
ORPHAN_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$ORPHAN" 2>/dev/null | tr -d '\r\n')
printf 'orphan state after runs: %s\n' "$ORPHAN_STATE"
if [ "$ORPHAN_STATE" = "exit:lost" ]; then
    ok "runs reconciled the orphaned run to exit:lost"
else
    bad "the orphaned run is still '${ORPHAN_STATE}'; it would say running for ever"
fi
if grep -qE "${ORPHAN}.*lost" "$ORPHAN_RUNS"; then
    ok "runs shows it in the lost state"
else
    bad "runs does not show the lost state"
fi

# ---- slot:8f-lost (owner M1) ----
# ---- end slot:8f-lost ----

printf -- '\n--- procps is installed, which is what makes the signal find claude ---\n'
if guest sh -c 'command -v pgrep >/dev/null 2>&1'; then
    ok "pgrep is present in the guest"
else
    bad "pgrep is missing; stop-run cannot find the process tree"
fi

guest sh -c 'rm -f /tmp/abx-standin.sh /tmp/abx-old.sh /tmp/abx-standin-interrupted /tmp/abx-old-interrupted' || true
guest sh -c "rm -rf \$HOME/.agent-box/runs/${STANDIN} \$HOME/.agent-box/runs/${FINISHED} \$HOME/.agent-box/runs/${OLD_RUNNING} \$HOME/.agent-box/runs/${NEWEST_FINISHED} \$HOME/.agent-box/runs/${ORPHAN}" || true

# ===========================================================================
step "8g. tmux sessions are listed, and a detached one can be attached to"
# ===========================================================================

guest tmux new-session -d -s shell -- sleep 600
SESS_OUT="${TMP_ROOT}/sessions.out"
"$AGENTBOX" sessions "$CLEAN_REPO" > "$SESS_OUT" 2>&1
cat "$SESS_OUT"
if grep -qE '^shell ' "$SESS_OUT"; then
    ok "sessions lists the detached shell session"
else
    bad "sessions does not list the detached shell session"
fi

SESSJ="${TMP_ROOT}/sessions.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$SESSJ" 2>&1
cat "$SESSJ"
if jq -e 'map(select(.name == "shell")) | length == 1' "$SESSJ" >/dev/null 2>&1; then
    ok "sessions --json lists it with a name"
else
    bad "sessions --json does not list it"
fi
if jq -e 'map(select(.name == "shell"))[0] | has("age_s")' "$SESSJ" >/dev/null 2>&1; then
    ok "sessions --json carries an age"
else
    bad "sessions --json carries no age"
fi

# attach needs a terminal, so it gets one: `script` allocates a pty on macOS.
# A detach-client from the other side is what has to make it return.
printf -- '\n--- attach -r returns when the session detaches it ---\n'
ATTACH_OUT="${TMP_ROOT}/attach.out"
( sleep 8; "$LIMACTL" shell --workdir /work "$INSTANCE" -- tmux detach-client -s shell >/dev/null 2>&1 ) &
DETACHER=$!
ATTACH_T0=$(date +%s)
run_bounded 60 "$ATTACH_OUT" script -q /dev/null "$AGENTBOX" attach "$CLEAN_REPO" shell -r
attach_rc=$BOUNDED_RC
ATTACH_ELAPSED=$(( $(date +%s) - ATTACH_T0 ))
wait "$DETACHER" 2>/dev/null
head -20 "$ATTACH_OUT"
printf 'attach returned after %ss with status %s\n' "$ATTACH_ELAPSED" "$attach_rc"
# The detacher waits 8 seconds before detaching, so a genuine pass cannot be
# quicker than that. Without the elapsed check this step would pass if attach
# failed instantly, or if the subcommand did not exist at all.
if [ "$attach_rc" -eq 0 ] && [ "$ATTACH_ELAPSED" -ge 8 ]; then
    ok "attach held the session for ${ATTACH_ELAPSED}s and returned 0 when it was detached"
else
    bad "attach exited ${attach_rc} after ${ATTACH_ELAPSED}s; expected 0 after at least 8s"
fi
guest tmux kill-session -t '=shell' 2>/dev/null || true

# ---- slot:8g-kind (owner W) ----
# ---- end slot:8g-kind ----

# ===========================================================================
step "8h. status: the JSON contract, and --watch leaving on Ctrl-C"
# ===========================================================================
#
# Scoped to this instance. `agentbox status` with no argument reaches into
# every agent-box VM on the machine, and a test must not run anything inside a
# VM it did not create.

STATUS_OUT="${TMP_ROOT}/status.out"
"$AGENTBOX" status "$CLEAN_REPO" > "$STATUS_OUT" 2>&1
cat "$STATUS_OUT"
# `fw=` is the egress MODE now, not the OUTPUT policy: deny, observe, open or
# unknown. This box is deny.
if grep -q "$INSTANCE" "$STATUS_OUT" && grep -q 'fw=deny' "$STATUS_OUT"; then
    ok "status names the box and reports the firewall as drop"
else
    bad "status does not name the box with fw=deny"
fi

STATUSJ="${TMP_ROOT}/status.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$STATUSJ" 2>&1
cat "$STATUSJ"
if jq -e . "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json parses"
else
    bad "status --json does not parse"
fi
if jq -e '.generated_at and (.boxes | length == 1)' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json has generated_at and exactly this box"
else
    bad "status --json is not shaped as documented"
fi
if jq -e '.boxes[0] | .firewall == "deny"' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json reports the egress mode as deny"
else
    bad "status --json does not report the egress mode as deny"
fi
# Present only when there is something to say. `null` on a healthy box would
# read as a fourth unknown rather than as nothing to report, because every
# other nullable key in this object means "asked for and unavailable".
if jq -e '.boxes[0] | has("firewall_detail") | not' "$STATUSJ" >/dev/null 2>&1; then
    ok "and firewall_detail is absent on a healthy box, not null"
else
    bad "firewall_detail is present on a healthy box: $(jq -c '.boxes[0].firewall_detail' "$STATUSJ" 2>/dev/null)"
fi
if jq -e '.boxes[0] | has("name") and has("instance") and has("repo") and has("state") and has("claude_version") and has("run") and has("runs_total") and has("sessions")' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json carries every documented key"
else
    bad "status --json is missing documented keys"
fi
if jq -e '.boxes[0].run | has("id") and has("state") and has("elapsed_s") and has("turns") and has("cost_usd") and has("last_tool")' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json includes the current run object"
else
    bad "status --json has no run object"
fi
# The newest run stays in `run` after it has finished, with its state, its exit
# code and its total duration. Every run in this suite has ended by now, so a
# `run` of null here would mean the object disappears the moment it matters.
if jq -e '.boxes[0].run | .state == "failed" and .exit == 1 and (.elapsed_s | type) == "number"' "$STATUSJ" >/dev/null 2>&1; then
    ok "the newest run stays in status --json after it finished, with its exit code"
else
    bad "status --json does not keep a finished run with its state and exit code"
fi
if jq -e '.boxes[0].sessions | type == "array"' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json includes the session list"
else
    bad "status --json has no session list"
fi
if jq -e '.boxes[0].runs_total >= 1' "$STATUSJ" >/dev/null 2>&1; then
    ok "status --json counts the runs"
else
    bad "status --json does not count the runs"
fi

printf -- '\n--- a box whose guest status script fails is still LISTED ---\n'
# A box must never disappear from status. The thing that describes a box
# failing is not the box being absent, and the two need different words:
# reporting a running box as "(not running)" is a false statement about it,
# and dropping it from the JSON is worse — a consumer cannot notice a box that
# is not there.
#
# The script is broken by bind-mounting a failing one over it, because
# /opt/agent-box is a read-only mount and this is the only way to make the real
# code path fail without editing the code under test.
BREAK_OUT="${TMP_ROOT}/status-broken.out"
guest sudo bash -c '
printf "#!/bin/sh\nexit 1\n" > /tmp/abx-false-status
chmod 0755 /tmp/abx-false-status
mount --bind /tmp/abx-false-status /opt/agent-box/guest/box-status.sh && echo BIND_OK
/opt/agent-box/guest/box-status.sh; echo "SCRIPT_RC=$?"' > "$BREAK_OUT" 2>&1
cat "$BREAK_OUT"
if grep -q '^BIND_OK' "$BREAK_OUT" && grep -q '^SCRIPT_RC=1' "$BREAK_OUT"; then
    ok "the guest status script was really broken, so the checks below are not vacuous"
else
    bad "could not break the guest status script; the checks below would prove nothing"
fi

BROKENJ="${TMP_ROOT}/status-broken.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$BROKENJ" 2>/dev/null || true
cat "$BROKENJ"
if jq -e --arg n "$INSTANCE" '[.boxes[] | select(.instance == $n)] | length == 1' "$BROKENJ" >/dev/null 2>&1; then
    ok "the box is still listed when its guest script fails"
else
    bad "the box disappeared from status --json when its guest script failed"
fi
if jq -e --arg n "$INSTANCE" '.boxes[] | select(.instance == $n) | .state == "running" and .firewall == "unknown"' "$BROKENJ" >/dev/null 2>&1; then
    ok "and it is reported as running with firewall unknown"
else
    bad "a running box with a broken status script is not reported as running/unknown"
fi
# The other half of the presence rule: whenever the mode is unknown, the key is
# there and says why. An unexplained unknown is the thing this avoids.
if jq -e --arg n "$INSTANCE" '.boxes[] | select(.instance == $n) | (.firewall_detail // "") | length > 0' "$BROKENJ" >/dev/null 2>&1; then
    ok "and firewall_detail says why it is unknown"
else
    bad "firewall is unknown with no firewall_detail to explain it"
fi

BROKENT="${TMP_ROOT}/status-broken.txt"
"$AGENTBOX" status "$CLEAN_REPO" > "$BROKENT" 2>/dev/null || true
cat "$BROKENT"
if grep -q "$INSTANCE" "$BROKENT"; then
    ok "the text listing shows it too"
else
    bad "the text listing dropped the box"
fi
if grep -q 'not running' "$BROKENT"; then
    bad "a RUNNING box with a broken status script was reported as '(not running)'"
else
    ok "and does not call a running box 'not running'"
fi

guest sudo umount /opt/agent-box/guest/box-status.sh >/dev/null 2>&1 || true
UNBROKE="${TMP_ROOT}/status-unbroken.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$UNBROKE" 2>/dev/null || true
if jq -e '.boxes[0].firewall == "deny"' "$UNBROKE" >/dev/null 2>&1; then
    ok "and the box is back to reporting its real mode afterwards"
else
    bad "the box did not recover after the status script was restored"
fi

printf -- '\n--- status --watch 30 leaves within three seconds of SIGINT ---\n'
# THIRTY, not one. The spec's bound is three seconds whatever SECS is, and with
# --watch 1 the assertion cannot fail: a shell that simply waited out the
# interval would still be inside the bound. Thirty is far outside it, so this
# only passes if the interrupt is acted on rather than deferred.
WATCH_OUT="${TMP_ROOT}/watch.out"
# `set -m`, not decoration: without job control a non-interactive shell starts
# an asynchronous command with SIGINT ignored, and a signal the child cannot
# receive would make this step prove nothing.
set -m
"$AGENTBOX" status "$CLEAN_REPO" --watch 30 > "$WATCH_OUT" 2>&1 &
WATCH_PID=$!
set +m
sleep 6
kill -INT "$WATCH_PID" 2>/dev/null
WATCH_T0=$(date +%s)
WATCH_LEFT=0
for _attempt in 1 2 3 4 5 6; do
    kill -0 "$WATCH_PID" 2>/dev/null || { WATCH_LEFT=1; break; }
    sleep 0.5
done
wait "$WATCH_PID" 2>/dev/null
WATCH_ELAPSED=$(( $(date +%s) - WATCH_T0 ))
tail -5 "$WATCH_OUT"
printf 'watch exited after %ss (flag %s)\n' "$WATCH_ELAPSED" "$WATCH_LEFT"
if [ "$WATCH_LEFT" -eq 1 ] && [ "$WATCH_ELAPSED" -le 3 ]; then
    ok "status --watch exited within 3s of SIGINT"
else
    bad "status --watch took ${WATCH_ELAPSED}s to exit after SIGINT"
fi

# ===========================================================================
step "8i. hostile bytes from the guest are never executed or printed here"
# ===========================================================================
#
# The agent runs as the guest user with a Bash tool, so every file the host CLI
# reads out of the guest is a file the agent can write. Each check below plants
# the bytes an agent could plant and asserts the host neither runs them nor
# shows them.

PWN_MARKER="${TMP_ROOT}/PWNED"
rm -f "$PWN_MARKER"
HOSTILE_RUNID=20260102-000000
# Closes the AppleScript string literal and continues as AppleScript, where
# `do shell script` runs on the HOST, outside the VM. Also carries the array
# -subscript form that bash's arithmetic evaluator expands inside `[ -eq ]`.
HOSTILE_STATE="exit:0\" & (do shell script \"touch ${PWN_MARKER}\") & \"x[\$(touch ${PWN_MARKER})]"

guest bash -l > "${TMP_ROOT}/hostile-setup.out" 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${HOSTILE_RUNID}"
mkdir -p "\$d"; chmod 700 "\$d"
printf '%s' '${HOSTILE_STATE}' > "\$d/status"
printf '{"runid":"${HOSTILE_RUNID}","model":"sonnet","branch":null,"brief":"hostile","started_at":"2026-01-02T00:00:00Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
: > "\$d/events.jsonl"
: > "\$d/console.log"
wc -c < "\$d/status"
SH
cat "${TMP_ROOT}/hostile-setup.out"

printf -- '\n--- B-01/B-07: the host reads that state through three commands ---\n'
WATCH_RUN_OUT="${TMP_ROOT}/watch-run.out"
run_bounded 60 "$WATCH_RUN_OUT" "$AGENTBOX" watch-run "$INSTANCE" "$HOSTILE_RUNID" "$CLEAN_REPO"
cat "$WATCH_RUN_OUT"
HOSTILE_LOGS="${TMP_ROOT}/hostile-logs.out"
run_bounded 60 "$HOSTILE_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$HOSTILE_RUNID"
cat "$HOSTILE_LOGS"
HOSTILE_STATUS="${TMP_ROOT}/hostile-status.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$HOSTILE_STATUS" 2>&1
HOSTILE_RUNS="${TMP_ROOT}/hostile-runs.out"
"$AGENTBOX" runs "$CLEAN_REPO" > "$HOSTILE_RUNS" 2>&1

if [ -e "$PWN_MARKER" ]; then
    bad "SECURITY: guest-written bytes executed a command on the host"
    rm -f "$PWN_MARKER"
else
    ok "no guest-written byte executed anything on the host"
fi
if grep -q 'do shell script' "$WATCH_RUN_OUT" "$HOSTILE_LOGS" "$HOSTILE_STATUS" "$HOSTILE_RUNS" 2>/dev/null; then
    bad "the hostile state was echoed back to the host terminal"
else
    ok "the hostile state was never echoed to the host terminal"
fi
if grep -q 'not a run state' "$WATCH_RUN_OUT"; then
    ok "the host reported the unrecognised state instead of using it"
else
    bad "the host did not report the unrecognised state"
fi
if grep -q 'unknown' "$HOSTILE_RUNS"; then
    ok "runs shows the hostile run in an unknown state"
else
    bad "runs did not fall back to unknown for the hostile state"
fi

printf -- '\n--- B-08: a run id that is not a run id is refused on the host ---\n'
# shellcheck disable=SC2016  # these must stay literal; that is the point.
for bad_id in '../../.ssh' 'x[$(touch /tmp/nope)]' '2026-1-2'; do
    TRAV_OUT="${TMP_ROOT}/traversal.out"
    "$AGENTBOX" logs "$CLEAN_REPO" "$bad_id" > "$TRAV_OUT" 2>&1
    trav_rc=$?
    printf 'logs %-22s -> rc=%s %s\n' "$bad_id" "$trav_rc" "$(head -1 "$TRAV_OUT")"
    if [ "$trav_rc" -ne 0 ] && grep -q 'not a run id' "$TRAV_OUT"; then
        ok "logs refused the run id ${bad_id}"
    else
        bad "logs did not refuse the run id ${bad_id}"
    fi
    "$AGENTBOX" stop-run "$CLEAN_REPO" "$bad_id" > "$TRAV_OUT" 2>&1
    trav_rc=$?
    if [ "$trav_rc" -ne 0 ] && grep -q 'not a run id' "$TRAV_OUT"; then
        ok "stop-run refused the run id ${bad_id}"
    else
        bad "stop-run did not refuse the run id ${bad_id}"
    fi
done
# shellcheck disable=SC2016  # $HOME must expand in the guest.
if guest sh -c 'test -e "$HOME/.ssh/status"'; then
    bad "a status file was written outside the runs directory"
else
    ok "nothing was written outside the runs directory"
fi

printf -- '\n--- B-02: a tmux session named after the token is not printed ---\n'
guest tmux new-session -d -s "$FAKE_TOKEN" -- sleep 300 2>/dev/null || true
SESS_TOK="${TMP_ROOT}/sessions-token.out"
"$AGENTBOX" sessions "$CLEAN_REPO" > "$SESS_TOK" 2>&1
cat "$SESS_TOK"
SESS_TOKJ="${TMP_ROOT}/sessions-token.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$SESS_TOKJ" 2>&1
cat "$SESS_TOKJ"
if grep -qF "$FAKE_TOKEN" "$SESS_TOK" "$SESS_TOKJ"; then
    bad "SECURITY: sessions printed the whole token"
else
    ok "sessions did not print the token"
fi
if grep -qF "$FAKE_HEAD" "$SESS_TOK" "$SESS_TOKJ" || grep -qF "$FAKE_TAIL" "$SESS_TOK" "$SESS_TOKJ"; then
    bad "sessions printed a fragment of the token"
else
    ok "sessions printed neither the token's head nor its tail"
fi
if grep -q 'redacted' "$SESS_TOK"; then
    ok "sessions redacted the credential-shaped session name"
else
    bad "sessions did not redact the credential-shaped session name"
fi
guest tmux kill-session -t "=${FAKE_TOKEN}" 2>/dev/null || true

printf -- '\n--- B-05: a session name full of JSON cannot forge or erase a row ---\n'
guest tmux new-session -d -s 'shell' -- sleep 300 2>/dev/null || true
JSON_NAME='x","age_s":0},{"name":"ghost'
guest tmux new-session -d -s "$JSON_NAME" -- sleep 300 2>/dev/null || true
FORGE="${TMP_ROOT}/sessions-forge.json"
"$AGENTBOX" sessions "$CLEAN_REPO" --json > "$FORGE" 2>&1
cat "$FORGE"
if jq -e . "$FORGE" >/dev/null 2>&1; then
    ok "sessions --json still parses with a hostile session name"
else
    bad "a hostile session name broke sessions --json"
fi
if jq -e 'map(select(.name == "ghost")) | length == 0' "$FORGE" >/dev/null 2>&1; then
    ok "no session row was forged"
else
    bad "a session row was forged by the name"
fi
FORGE_STATUS="${TMP_ROOT}/status-forge.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$FORGE_STATUS" 2>&1
if jq -e '.boxes[0].sessions | type == "array" and length >= 2' "$FORGE_STATUS" >/dev/null 2>&1; then
    ok "status --json still lists the real sessions"
else
    bad "status --json lost the session list to a hostile name"
fi
guest tmux kill-session -t "=${JSON_NAME}" 2>/dev/null || true
guest tmux kill-session -t '=shell' 2>/dev/null || true

printf -- '\n--- B-03: a whole credential in a tool result is dropped, not trimmed ---\n'
LEAKY_RUNID=20260103-000000
OTHER_CRED="sk-ant-oat01-AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDD"
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${LEAKY_RUNID}"
mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:3\n' > "\$d/status"
printf '{"runid":"${LEAKY_RUNID}","model":"sonnet","branch":null,"brief":"leaky","started_at":"2026-01-03T00:00:00Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
printf '%s\n' '{"type":"user","timestamp":"2026-01-03T00:00:01.000Z","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"CLAUDE_CODE_OAUTH_TOKEN=${OTHER_CRED}"}]}]}}' > "\$d/events.jsonl"
: > "\$d/console.log"
SH
LEAKY_OUT="${TMP_ROOT}/leaky-logs.out"
run_bounded 60 "$LEAKY_OUT" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAKY_RUNID"
cat "$LEAKY_OUT"
if grep -qF "$OTHER_CRED" "$LEAKY_OUT"; then
    bad "SECURITY: logs printed a whole credential from a leak-flagged run"
else
    ok "logs printed no credential for the leak-flagged run"
fi
if grep -q 'leak check found the OAuth token' "$LEAKY_OUT"; then
    ok "logs printed the leak banner instead of the events"
else
    bad "logs did not print the leak banner"
fi
LEAKY_FORCED="${TMP_ROOT}/leaky-forced.out"
run_bounded 60 "$LEAKY_FORCED" "$AGENTBOX" logs "$CLEAN_REPO" "$LEAKY_RUNID" --force-unsafe
cat "$LEAKY_FORCED"
if grep -qF "$OTHER_CRED" "$LEAKY_FORCED"; then
    bad "SECURITY: --force-unsafe printed the credential verbatim"
else
    ok "even --force-unsafe drops the whole credential, not just its ends"
fi
if grep -q 'redacted' "$LEAKY_FORCED"; then
    ok "the credential was replaced by a redaction marker"
else
    bad "no redaction marker where the credential was"
fi

printf -- '\n--- B-09: the hook command refuses a destination outside the state root ---\n'
HOOKC_OUT="${TMP_ROOT}/hook-contain.out"
guest bash -l > "$HOOKC_OUT" 2>&1 <<'SH'
set -u
rm -rf /tmp/abx-outside && mkdir -p /tmp/abx-outside
printf '%s' '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/work/x"}}' \
    | AGENT_BOX_EVENTS_DIR=/tmp/abx-outside /opt/agent-box/guest/hook-event.sh
echo "RC_OUTSIDE=$?"
echo "FILES_OUTSIDE=$(find /tmp/abx-outside -type f | wc -l | tr -d ' ')"
d="$HOME/.agent-box/sessions/linktest"
rm -rf "$d" && mkdir -p "$d"
ln -s /tmp/abx-outside/stolen.jsonl "$d/hooks.jsonl"
printf '%s' '{"session_id":"s","hook_event_name":"Stop"}' \
    | AGENT_BOX_EVENTS_DIR="$d" /opt/agent-box/guest/hook-event.sh
echo "RC_SYMLINK=$?"
echo "SYMLINK_TARGET=$( [ -e /tmp/abx-outside/stolen.jsonl ] && echo WRITTEN || echo untouched )"
rm -rf /tmp/abx-outside "$d"
SH
cat "$HOOKC_OUT"
if grep -q 'RC_OUTSIDE=0' "$HOOKC_OUT" && grep -q 'FILES_OUTSIDE=0' "$HOOKC_OUT"; then
    ok "the hook wrote nothing outside the state root, and still exited 0"
else
    bad "the hook wrote outside the state root or failed"
fi
if grep -q 'SYMLINK_TARGET=untouched' "$HOOKC_OUT"; then
    ok "the hook refused a hooks.jsonl that is a symlink"
else
    bad "the hook followed a symlink out of the state root"
fi

printf -- '\n--- B-10: the state root itself is 700 ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
STATE_MODE=$(guest sh -c 'stat -c "%a" "$HOME/.agent-box"' 2>/dev/null)
printf 'mode of ~/.agent-box: %s\n' "$STATE_MODE"
if [ "$STATE_MODE" = "700" ]; then
    ok "the state root is 700"
else
    bad "the state root is ${STATE_MODE}, expected 700"
fi
# And the case provisioning does not cover: a state root created by a script,
# under a permissive umask. abx_private_dir has to make the parent private too,
# or the layout the spec states is not what the code guarantees on its own.
MODE_OUT="${TMP_ROOT}/state-mode.out"
guest bash -l > "$MODE_OUT" 2>&1 <<'SH'
die() { printf 'lib refused: %s\n' "$*" >&2; exit 1; }
rm -rf /tmp/abx-modetest
export ABX_STATE_DIR=/tmp/abx-modetest
export ABX_RUNS_DIR=/tmp/abx-modetest/runs
# shellcheck source=/dev/null
. /opt/agent-box/guest/lib.sh
umask 022
abx_private_dir "$ABX_RUNS_DIR"
abx_private_dir "${ABX_RUNS_DIR}/20260101-000000"
stat -c '%a %n' /tmp/abx-modetest /tmp/abx-modetest/runs /tmp/abx-modetest/runs/20260101-000000
rm -rf /tmp/abx-modetest
SH
cat "$MODE_OUT"
if [ "$(grep -c '^700 ' "$MODE_OUT")" -eq 3 ]; then
    ok "a state root created by a script is 700 all the way down, under umask 022"
else
    bad "a script-created state root is not 700 all the way down"
fi

printf -- '\n--- B-12: --settings merges the hooks rather than replacing them ---\n'
MERGE_OUT="${TMP_ROOT}/settings-merge.out"
guest bash -l > "$MERGE_OUT" 2>&1 <<'SH'
set -u
w=/tmp/abx-merge; rm -rf "$w"; mkdir -p "$w/cfg" "$w/out" "$w/proj"
printf '#!/bin/sh\ncat >/dev/null\ntouch %s/out/user.marker\nexit 0\n' "$w" > "$w/hook-user.sh"
printf '#!/bin/sh\ncat >/dev/null\ntouch %s/out/extra.marker\nexit 0\n' "$w" > "$w/hook-extra.sh"
chmod +x "$w/hook-user.sh" "$w/hook-extra.sh"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/hook-user.sh"}]}]}}\n' "$w" > "$w/cfg/settings.json"
printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/hook-extra.sh"}]}]}}\n' "$w" > "$w/extra.json"
cd "$w/proj"
# `< /dev/null`, and it is load-bearing: this whole script arrives on bash's
# stdin, so a claude that inherits it eats the rest of the script and the two
# echoes below never run.
CLAUDE_CONFIG_DIR="$w/cfg" CLAUDE_CODE_OAUTH_TOKEN='sk-ant-oat01-MERGEHEADzzzzzzzzzzzzzzzzzzzzMERGETAIL' \
  timeout 120 claude -p --model haiku --settings "$w/extra.json" 'hi' >/dev/null 2>&1 </dev/null
echo "USER_HOOK=$( [ -f "$w/out/user.marker" ] && echo RAN || echo absent )"
echo "EXTRA_HOOK=$( [ -f "$w/out/extra.marker" ] && echo RAN || echo absent )"
rm -rf "$w"
SH
cat "$MERGE_OUT"
if grep -q 'USER_HOOK=RAN' "$MERGE_OUT" && grep -q 'EXTRA_HOOK=RAN' "$MERGE_OUT"; then
    ok "--settings MERGES hook arrays with the user settings.json"
else
    bad "--settings did not merge; the sensor's hooks can be displaced (see docs/decisions.md)"
fi

printf -- '\n--- B-12: a repository settings.json with hooks is refused ---\n'
REPOSET="${TMP_ROOT}/repo-settings.out"
guest sh -c 'mkdir -p /work/.claude && printf "%s\n" "{\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"touch /tmp/repo-hook-ran\"}]}]}}" > /work/.claude/settings.json'
printf 'Do nothing.\n' | "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    /opt/agent-box/guest/agent-run.sh --slug reposettings --brief - > "$REPOSET" 2>&1
reposet_rc=$?
cat "$REPOSET"
if [ "$reposet_rc" -ne 0 ] && grep -q 'hooks' "$REPOSET" && grep -q '/work/.claude/settings.json' "$REPOSET"; then
    ok "agent-run refused a repository settings.json carrying hooks, and named it"
else
    bad "agent-run did not refuse a repository settings.json carrying hooks"
fi
guest sh -c 'rm -rf /work/.claude /tmp/repo-hook-ran'

# Clean up everything this step planted in the guest.
guest sh -c "rm -rf \$HOME/.agent-box/runs/${HOSTILE_RUNID} \$HOME/.agent-box/runs/${LEAKY_RUNID}" || true

# ---- slot:8k (owner C2) ----
# ---- end slot:8k ----

# ---- slot:8l (owner C3) ----
# ---- end slot:8l ----

# ---- slot:8m (owner C2) ----
# ---- end slot:8m ----

# ===========================================================================
step "8j. an interrupted run is recorded as stopped, not as done (issue #14)"
# ===========================================================================
#
# Claude Code exits 0 when it is interrupted and says so only in its result
# event, so a run that was stopped used to be recorded as `done` with exit 0.
# A stand-in CLI reproduces that shape exactly, without a model call and
# without the real credential path: it never reads a token and never prints
# one.
#
# The stand-in has to sit where the real one does. guest/lib.sh puts
# "$HOME/.local/bin" at the FRONT of PATH, so prepending a directory of our own
# would lose to the real binary; the real one is moved aside for the duration
# of this step and put back at the end, which is asserted.

guest bash -l > "${TMP_ROOT}/standin-install.out" 2>&1 <<'SH'
set -u
# (a) interrupted: prints an init line, then on SIGINT the shape issue #14 is
# about — error_during_execution, is_error true, exit status 0.
cat > /tmp/abx-claude-stop <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    printf -- '--include-hook-events --max-budget-usd --settings --verbose\n'; exit 0 ;;
esac
on_int() {
    printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"duration_ms":900,"total_cost_usd":0}\n'
    exit 0
}
trap on_int INT
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
sleep 120 &
wait $!
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"duration_ms":1000,"total_cost_usd":0}\n'
exit 0
INNER
# (b) failed without any signal: the CLI's own verdict says error, and it still
# exits 0.
cat > /tmp/abx-claude-fail <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    printf -- '--include-hook-events --max-budget-usd --settings --verbose\n'; exit 0 ;;
esac
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"duration_ms":500,"total_cost_usd":0}\n'
exit 0
INNER
# (c) slow preconditions: --help blocks for longer than run-ctl waits for the
# pid file, so a stop lands while the run is still before its launch.
cat > /tmp/abx-claude-slowhelp <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    sleep 12; printf -- '--include-hook-events --settings --verbose\n'; exit 0 ;;
esac
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"duration_ms":10,"total_cost_usd":0}\n'
exit 0
INNER
chmod +x /tmp/abx-claude-stop /tmp/abx-claude-fail /tmp/abx-claude-slowhelp
mv "$HOME/.local/bin/claude" "$HOME/.local/bin/claude.real"
cp /tmp/abx-claude-stop "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
claude --version
SH
cat "${TMP_ROOT}/standin-install.out"
STANDIN_INSTALLED=1
if grep -q 'standin' "${TMP_ROOT}/standin-install.out"; then
    ok "the stand-in CLI is in place"
else
    bad "the stand-in CLI could not be installed; the rest of this step is meaningless"
fi

# A token, because agent-run refuses without one. It is never read by the
# stand-in and never printed by it.
guest sh -c "umask 077; printf '%s' '${FAKE_TOKEN}' > \$HOME/.config/agent-box/token; chmod 600 \$HOME/.config/agent-box/token"

printf -- '\n--- (a) a detached run, stopped while it is going ---\n'
STOPPED_OUT="${TMP_ROOT}/issue14-run.out"
run_bounded 90 "$STOPPED_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$STOPPED_OUT"
S14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$STOPPED_OUT" | head -1)
printf 'runid: %s\n' "${S14_RUNID:-<none>}"
if [ -z "$S14_RUNID" ]; then
    bad "the run did not start; skipping the rest of 8j"
    S14_RUNID=""
fi

if [ -n "$S14_RUNID" ]; then
    # Wait until the stand-in is genuinely running, so the stop lands on it
    # rather than on the preconditions.
    S14_READY=0
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if guest sh -c "grep -q '\"subtype\":\"init\"' \$HOME/.agent-box/runs/${S14_RUNID}/events.jsonl 2>/dev/null"; then
            S14_READY=1; break
        fi
        sleep 2
    done
    if [ "$S14_READY" -eq 1 ]; then ok "the stand-in run reached the CLI"; else bad "the stand-in run never reached the CLI"; fi

    S14_STOP="${TMP_ROOT}/issue14-stop.out"
    S14_T0=$(date +%s)
    run_bounded 90 "$S14_STOP" "$AGENTBOX" stop-run "$CLEAN_REPO" "$S14_RUNID"
    S14_ELAPSED=$(( $(date +%s) - S14_T0 ))
    cat "$S14_STOP"
    printf 'stop-run took %ss\n' "$S14_ELAPSED"
    if grep -q "${S14_RUNID} stopped after" "$S14_STOP"; then
        ok "run-ctl reported the run as stopped"
    else
        bad "run-ctl did not report the run as stopped"
    fi
    # The two stop paths are worded differently. This one must be the path
    # where the RUN recorded its own exit, not the one where the session was
    # closed and the status written from outside.
    if grep -q 'did not record its own exit' "$S14_STOP"; then
        bad "the run did not record its own stop; the status was written from outside"
    else
        ok "the run recorded its own stop; run-ctl only reported it"
    fi
    if [ "$S14_ELAPSED" -lt 20 ]; then
        ok "the stop completed in ${S14_ELAPSED}s, without falling through to the 20s fallback"
    else
        bad "the stop took ${S14_ELAPSED}s; it fell through to closing the session"
    fi
    if grep -q 'ended by itself' "$S14_STOP"; then
        bad "run-ctl still claims the run ended by itself"
    else
        ok "run-ctl no longer claims the run ended by itself"
    fi

    # The DERIVED state, which is what the host acts on. The status file keeps
    # the run's own exit code; the two assertions below check that pair.
    S14_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$S14_RUNID" 2>/dev/null | tr -d '\r\n')
    printf 'derived state: %s\n' "$S14_STATE"
    if [ "$S14_STATE" = "exit:stopped" ]; then
        ok "the run's derived state is stopped"
    else
        bad "the run's derived state is '${S14_STATE}', not exit:stopped"
    fi

    S14_JSON="${TMP_ROOT}/issue14-runs.json"
    "$AGENTBOX" runs "$CLEAN_REPO" --json > "$S14_JSON" 2>&1
    cat "$S14_JSON"
    # The exit code SURVIVES the stop now: the status file keeps the number and
    # a separate marker says the run was stopped. Overwriting the code was how
    # the leak check's exit 3 used to be erased.
    if jq -e --arg r "$S14_RUNID" 'map(select(.runid == $r and .state == "stopped" and .exit_code == 1)) | length == 1' "$S14_JSON" >/dev/null 2>&1; then
        ok "runs --json reports it stopped, keeping the exit code the run ended with"
    else
        bad "runs --json does not report it stopped with its own exit code"
    fi
    S14_RAW=$(guest sh -c "cat \$HOME/.agent-box/runs/${S14_RUNID}/status" 2>/dev/null | tr -d '\r\n')
    if [ "$S14_RAW" = "exit:1" ] && guest sh -c "test -f \$HOME/.agent-box/runs/${S14_RUNID}/stopped"; then
        ok "the status file kept exit:1 and the stop is a marker beside it"
    else
        bad "the status file is '${S14_RAW}' and the stop marker is missing"
    fi

    S14_BRANCH=$(guest sh -c "jq -r '.branch // empty' \$HOME/.agent-box/runs/${S14_RUNID}/meta.json" 2>/dev/null | tr -d '\r\n')
    printf 'branch: %s\n' "${S14_BRANCH:-<none>}"
    if [ -n "$S14_BRANCH" ] && guest sh -c "git -C /work rev-parse --verify --quiet '${S14_BRANCH}' >/dev/null"; then
        ok "the run's branch still exists; nothing was reverted"
    else
        bad "the run's branch is gone after a stop"
    fi

    # The summary the run wrote, read back through the guest so it is scrubbed.
    # It must be THIS run's summary and it must say stopped: a run that was
    # killed before it could write one would otherwise leave the previous
    # run's summary in place and look fine.
    S14_SUMMARY="${TMP_ROOT}/issue14-summary.out"
    run_bounded 60 "$S14_SUMMARY" guest_summary "$S14_RUNID"
    cat "$S14_SUMMARY"
    if grep -q "runid     : ${S14_RUNID}" "$S14_SUMMARY" && grep -q 'state     : stopped' "$S14_SUMMARY"; then
        ok "the run wrote its own summary, naming the state as stopped"
    else
        bad "the run did not write a summary saying stopped"
    fi
    if grep -q 'Nothing was reverted' "$S14_SUMMARY"; then
        ok "the summary says nothing was reverted"
    else
        bad "the summary does not say nothing was reverted"
    fi
fi

printf -- '\n--- (a2) run --wait on a run that gets stopped returns 130 ---\n'
WAIT_OUT="${TMP_ROOT}/issue14-wait.out"
set -m
"$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait > "$WAIT_OUT" 2>&1 &
WAIT_PID=$!
set +m
W14_READY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if guest /opt/agent-box/guest/run-ctl.sh state 2>/dev/null | grep -qx 'running'; then
        W14_READY=1; break
    fi
    sleep 2
done
sleep 3
run_bounded 90 "${TMP_ROOT}/issue14-wait-stop.out" "$AGENTBOX" stop-run "$CLEAN_REPO"
cat "${TMP_ROOT}/issue14-wait-stop.out"
wait "$WAIT_PID"; wait_rc=$?
cat "$WAIT_OUT"
printf 'run --wait exit status: %s (ready flag %s)\n' "$wait_rc" "$W14_READY"
if [ "$wait_rc" -eq 130 ]; then
    ok "run --wait returned 130 for a run that was stopped"
else
    bad "run --wait returned ${wait_rc}; expected 130 for a stopped run"
fi
if grep -q 'summary' "$WAIT_OUT"; then
    ok "run --wait printed the summary for the stopped run"
else
    bad "run --wait printed no summary for the stopped run"
fi

printf -- '\n--- (a3) a stop that lands on a leaking run stays exit:3 ---\n'
# The leak check and the stop used to fight over one field: the stop wrote
# exit:stopped over the 3, `logs` gates its refusal on exactly `exit:3`, and so
# the credential the exit-3 path exists to withhold was printed. The token is
# put where the leak check will find it, in the unstaged diff.
guest sh -c "cd /work && printf 'leaked: %s\\n' '${FAKE_TOKEN}' >> hello.txt"
LEAKSTOP_OUT="${TMP_ROOT}/issue14-leakstop.out"
run_bounded 90 "$LEAKSTOP_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$LEAKSTOP_OUT"
LS_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$LEAKSTOP_OUT" | head -1)
printf 'runid: %s\n' "${LS_RUNID:-<none>}"
if [ -n "$LS_RUNID" ]; then
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        guest sh -c "grep -q '\"subtype\":\"init\"' \$HOME/.agent-box/runs/${LS_RUNID}/events.jsonl 2>/dev/null" && break
        sleep 2
    done
    run_bounded 90 "${TMP_ROOT}/issue14-leakstop-stop.out" "$AGENTBOX" stop-run "$CLEAN_REPO" "$LS_RUNID"
    cat "${TMP_ROOT}/issue14-leakstop-stop.out"
    LS_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$LS_RUNID" 2>/dev/null | tr -d '\r\n')
    printf 'status file: %s\n' "$LS_STATE"
    if [ "$LS_STATE" = "exit:3" ]; then
        ok "a stop that coincided with a leak left the status at exit:3"
    else
        bad "the leaking run recorded '${LS_STATE}'; exit:3 was overwritten"
    fi
    if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${LS_RUNID}.*failed"; then
        ok "runs reports the leaking run as failed, not stopped"
    else
        bad "runs does not report the leaking run as failed"
    fi
    LS_LOGS="${TMP_ROOT}/issue14-leakstop-logs.out"
    run_bounded 60 "$LS_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$LS_RUNID"
    cat "$LS_LOGS"
    if grep -q 'leak check found the OAuth token' "$LS_LOGS"; then
        ok "logs still refuses the run and prints the leak banner"
    else
        bad "logs did not print the leak banner; the stop disabled the refusal"
    fi
    if grep -qF "$FAKE_TOKEN" "$LS_LOGS" || grep -qF "$FAKE_HEAD" "$LS_LOGS" || grep -qF "$FAKE_TAIL" "$LS_LOGS"; then
        bad "SECURITY: logs printed the credential for the stopped leaking run"
    else
        ok "logs printed no credential for the stopped leaking run"
    fi
fi
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; true'

printf -- '\n--- (a4) a stop before the CLI starts must not start it ---\n'
# run-ctl waits for the pid file, and when it never appears it interrupts the
# run script instead. The script must then SKIP the launch: interrupting a
# script whose only reaction was to set a flag used to let the CLI start
# anyway, and closing the session afterwards orphaned it in its own process
# group, still running and still spending, while the run was reported stopped.
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest bash -l -c 'cp /tmp/abx-claude-slowhelp "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"'
EARLY_OUT="${TMP_ROOT}/issue14-early.out"
run_bounded 90 "$EARLY_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
cat "$EARLY_OUT"
E14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$EARLY_OUT" | head -1)
printf 'runid: %s\n' "${E14_RUNID:-<none>}"
if [ -n "$E14_RUNID" ]; then
    EARLY_STOP="${TMP_ROOT}/issue14-early-stop.out"
    run_bounded 120 "$EARLY_STOP" "$AGENTBOX" stop-run "$CLEAN_REPO" "$E14_RUNID"
    cat "$EARLY_STOP"
    if grep -q 'no CLI process' "$EARLY_STOP"; then
        ok "stop-run waited for the pid, found none, and said so"
    else
        bad "stop-run did not report the missing CLI process"
    fi
    # Wait for the run to finish reacting.
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        E14_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$E14_RUNID" 2>/dev/null | tr -d '\r\n')
        [ "$E14_STATE" = "running" ] || break
        sleep 2
    done
    printf 'status file: %s\n' "$E14_STATE"
    E14_EVENTS=$(guest sh -c "wc -c < \$HOME/.agent-box/runs/${E14_RUNID}/events.jsonl" 2>/dev/null | tr -d ' \r\n')
    printf 'events.jsonl bytes: %s\n' "${E14_EVENTS:-?}"
    if [ "${E14_EVENTS:-1}" = "0" ]; then
        ok "the CLI was never launched after the stop was requested"
    else
        bad "the CLI ran anyway after the stop was requested (${E14_EVENTS} bytes of events)"
    fi
    E14_LOGS="${TMP_ROOT}/issue14-early-logs.out"
    run_bounded 60 "$E14_LOGS" "$AGENTBOX" logs "$CLEAN_REPO" "$E14_RUNID"
    cat "$E14_LOGS"
    if grep -q 'not launching it' "$E14_LOGS"; then
        ok "the run said it was not launching the CLI"
    else
        bad "the run did not say it had skipped the launch"
    fi
    if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${E14_RUNID}.*stopped"; then
        ok "runs reports the never-launched run as stopped"
    else
        bad "runs does not report the never-launched run as stopped"
    fi
fi

printf -- '\n--- (a5) a CLI that ignores signals: no stop is claimed, no marker is left ---\n'
# `stop-run` must never report a stop it did not achieve, and must not leave
# `stop-requested` behind when it gives up: a marker left on disk turns the
# run's next genuine failure into a reported stop, and `run --wait` would then
# return 130 where the run had actually failed.
guest bash -l > /dev/null 2>&1 <<'SH'
cat > /tmp/abx-claude-deaf <<'INNER'
#!/bin/bash
case "${1:-}" in
    --version) printf '2.1.261-standin (Claude Code)\n'; exit 0 ;;
    --help)    printf -- '--include-hook-events --settings --verbose\n'; exit 0 ;;
esac
trap '' INT TERM
printf '{"type":"system","subtype":"init","model":"stand-in","claude_code_version":"stand-in"}\n'
while :; do sleep 5; done
INNER
chmod +x /tmp/abx-claude-deaf
cp /tmp/abx-claude-deaf "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/claude"
SH
DEAF_OUT="${TMP_ROOT}/issue14-deaf.out"
run_bounded 90 "$DEAF_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md"
D14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$DEAF_OUT" | head -1)
printf 'runid: %s\n' "${D14_RUNID:-<none>}"
if [ -n "$D14_RUNID" ]; then
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        guest sh -c "grep -q '\"subtype\":\"init\"' \$HOME/.agent-box/runs/${D14_RUNID}/events.jsonl 2>/dev/null" && break
        sleep 2
    done
    DEAF_STOP="${TMP_ROOT}/issue14-deaf-stop.out"
    run_bounded 120 "$DEAF_STOP" "$AGENTBOX" stop-run "$CLEAN_REPO" "$D14_RUNID"
    deaf_rc=$BOUNDED_RC
    cat "$DEAF_STOP"
    if [ "$deaf_rc" -ne 0 ]; then
        ok "stop-run reported failure rather than claiming a stop it did not achieve"
    else
        bad "stop-run exited 0 for a CLI that ignored both signals"
    fi
    if grep -q 'STILL RUNNING' "$DEAF_STOP"; then
        ok "stop-run said the CLI survived SIGINT and SIGTERM"
    else
        bad "stop-run did not say the CLI had survived"
    fi
    DEAF_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$D14_RUNID" 2>/dev/null | tr -d '\r\n')
    printf 'derived state: %s\n' "$DEAF_STATE"
    if [ "$DEAF_STATE" = "running" ]; then
        ok "the run is still recorded as running, which is the truth"
    else
        bad "the run was recorded '${DEAF_STATE}' while its CLI was still alive"
    fi
    if guest sh -c "test -e \$HOME/.agent-box/runs/${D14_RUNID}/stop-requested"; then
        bad "the abandoned stop left stop-requested on disk"
    else
        ok "the abandoned stop withdrew its stop-requested marker"
    fi
    # This stand-in cannot be asked to leave, so it is killed by the pid the
    # run recorded — not by closing the session, which would leave it orphaned
    # in its own process group. The run then finishes on its own terms, and
    # that is the point of the next assertion: an abandoned stop must not come
    # back to relabel the failure that follows it.
    guest bash -l > /dev/null 2>&1 <<SH
p=\$(cat "\$HOME/.agent-box/runs/${D14_RUNID}/claude-pid" 2>/dev/null)
case "\$p" in ''|*[!0-9]*) ;; *) kill -9 "\$p" 2>/dev/null ;; esac
SH
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        DEAF_AFTER=$(guest /opt/agent-box/guest/run-ctl.sh state "$D14_RUNID" 2>/dev/null | tr -d '\r\n')
        [ "$DEAF_AFTER" = "running" ] || break
        sleep 2
    done
    printf 'state once the CLI was killed: %s\n' "$DEAF_AFTER"
    if [ "$DEAF_AFTER" = "exit:stopped" ]; then
        bad "the withdrawn stop came back: a later failure was recorded as a stop"
    else
        ok "the later failure was recorded as a failure, not as the abandoned stop"
    fi
    if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${D14_RUNID}.*failed"; then
        ok "runs shows it failed rather than stopped"
    else
        bad "runs does not show it as failed"
    fi
fi

printf -- '\n--- (a6) the two derivation rules agree, including exit:lost with a marker ---\n'
# run-ctl derives the state for `run --wait` and the notification watcher;
# run-format derives it for `runs` and `status --json`. A run whose finish()
# wrote its marker and then died before its status is exactly the case where
# the two used to disagree: one said stopped, the other said lost.
AGREE_ID=20260102-111111
guest bash -l > /dev/null 2>&1 <<SH
set -u
d="\$HOME/.agent-box/runs/${AGREE_ID}"
rm -rf "\$d"; mkdir -p "\$d"; chmod 700 "\$d"
printf 'exit:lost\n' > "\$d/status"
printf '2026-01-02T11:11:11Z\n' > "\$d/stopped"
printf '{"runid":"${AGREE_ID}","model":"sonnet","branch":null,"brief":"agree","started_at":"2026-01-02T11:11:11Z","tmux":null,"max_turns":null,"max_budget_usd":null,"claude_version":null}\n' > "\$d/meta.json"
SH
AGREE_CTL=$(guest /opt/agent-box/guest/run-ctl.sh state "$AGREE_ID" 2>/dev/null | tr -d '\r\n')
AGREE_FMT=$("$AGENTBOX" runs "$CLEAN_REPO" --json 2>/dev/null | jq -r --arg r "$AGREE_ID" 'map(select(.runid == $r))[0].state // "missing"')
printf 'run-ctl says %s; run-format says %s\n' "$AGREE_CTL" "$AGREE_FMT"
if [ "$AGREE_CTL" = "exit:lost" ] && [ "$AGREE_FMT" = "lost" ]; then
    ok "exit:lost with a stop marker reads lost from both derivation rules"
else
    bad "the two rules disagree: run-ctl '${AGREE_CTL}' vs run-format '${AGREE_FMT}'"
fi
guest sh -c "rm -rf \$HOME/.agent-box/runs/${AGREE_ID}"

printf -- '\n--- (b) the CLI exits 0 but says is_error: that is a failed run ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest bash -l -c 'cp /tmp/abx-claude-fail "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"'
FAIL_OUT="${TMP_ROOT}/issue14-fail.out"
run_bounded 120 "$FAIL_OUT" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/noop-brief.md" --wait
fail_rc=$BOUNDED_RC
cat "$FAIL_OUT"
printf 'run --wait exit status: %s\n' "$fail_rc"
F14_RUNID=$(sed -n 's/^agentbox: run \([0-9-]*\) started.*/\1/p' "$FAIL_OUT" | head -1)
F14_STATE=$(guest /opt/agent-box/guest/run-ctl.sh state "$F14_RUNID" 2>/dev/null | tr -d '\r\n')
printf 'status file: %s\n' "$F14_STATE"
if [ "$F14_STATE" = "exit:1" ]; then
    ok "a CLI that exits 0 while reporting is_error is recorded as exit:1"
else
    bad "the run recorded '${F14_STATE}', not exit:1"
fi
if "$AGENTBOX" runs "$CLEAN_REPO" | grep -qE "${F14_RUNID}.*failed"; then
    ok "runs shows it as failed"
else
    bad "runs does not show it as failed"
fi
if [ "$fail_rc" -ne 0 ]; then
    ok "run --wait returned non-zero for the failed run"
else
    bad "run --wait returned 0 for a run the CLI said had failed"
fi
if grep -q 'is_error=true; recording this run as failed' "$FAIL_OUT"; then
    ok "agent-run said why it overrode the exit status"
else
    bad "agent-run did not explain the override"
fi

# ---- slot:8j2 (owner S1) ----
# ---- end slot:8j2 ----

# ---- slot:8j3 (owner S2) ----
# ---- end slot:8j3 ----

printf -- '\n--- no token fragment left this step ---\n'
if grep -qF "$FAKE_HEAD" "$STOPPED_OUT" "$S14_STOP" "$WAIT_OUT" "$FAIL_OUT" 2>/dev/null \
   || grep -qF "$FAKE_TAIL" "$STOPPED_OUT" "$S14_STOP" "$WAIT_OUT" "$FAIL_OUT" 2>/dev/null; then
    bad "a token fragment reached the host in step 8j"
else
    ok "no token fragment reached the host in step 8j"
fi

printf -- '\n--- the real CLI is put back ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest bash -l -c 'mv -f "$HOME/.local/bin/claude.real" "$HOME/.local/bin/claude"' || true
STANDIN_INSTALLED=0
guest sh -c 'rm -f /tmp/abx-claude-stop /tmp/abx-claude-fail /tmp/abx-claude-slowhelp /tmp/abx-claude-deaf'
REAL_VER=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$REAL_VER"
if printf '%s' "$REAL_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' && ! printf '%s' "$REAL_VER" | grep -q standin; then
    ok "the real Claude Code is back on PATH"
else
    bad "the real Claude Code was not restored"
fi
# shellcheck disable=SC2016  # $HOME must expand in the guest.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; true'

printf -- '\n--- clean up the planted token and the run state ---\n'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -f $HOME/.config/agent-box/token'
guest sh -c 'cd /work && git checkout -- . 2>/dev/null; git checkout --quiet main 2>/dev/null; true'
# shellcheck disable=SC2016  # $HOME must expand in the guest, not on the host.
guest sh -c 'rm -rf /work/.agent-box $HOME/.agent-box/runs $HOME/.agent-box/briefs' || true
if grep -rqF "$FAKE_TOKEN" "$CLEAN_REPO" 2>/dev/null; then
    bad "the planted token is still in the work tree after the sensor checks"
else
    ok "the work tree is clean of the planted token after the sensor checks"
fi

# ===========================================================================
step "8c. a first-run failure fails CLOSED without locking the operator out"
# ===========================================================================
#
# This is the FW-1 case: an error when there is no standing ruleset to fall back
# on. The rules are cleared to simulate a first boot, the GitHub meta endpoint is
# pointed at a closed port so the fetch fails, and the OUTPUT policy must be DROP
# afterwards rather than ACCEPT.
#
# The simulation runs as a detached transient unit so that it survives whatever
# happens to the network. It deliberately does NOT recover: the whole point of
# this step is to observe the hard-closed state from the host and to run the
# documented recovery over a real `limactl shell`, which is only possible if the
# hard close keeps SSH working.

FIRSTRUN_LOG=/tmp/agent-box-firstrun.log
guest sudo systemd-run --unit=agent-box-firstrun-test --collect /bin/sh -c "
exec > ${FIRSTRUN_LOG} 2>&1
echo '--- simulating a first-run state: no rules, no ipset ---'
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X 2>/dev/null
ipset destroy allowed-domains 2>/dev/null
echo \"BEFORE_POLICY=\$(iptables -S | grep -- '-P OUTPUT')\"
echo '--- running init-firewall.sh with an unreachable meta endpoint ---'
AGENT_BOX_GH_META_URL=http://127.0.0.1:9/meta /opt/agent-box/guest/init-firewall.sh
echo \"INIT_RC=\$?\"
if iptables -S | grep -qx -- '-P OUTPUT DROP'; then echo 'RESULT=POLICY-DROP'; else echo 'RESULT=POLICY-OPEN'; fi
iptables -S
echo 'SIMULATION_COMPLETE=1'
"

# The hard close is now in force and nothing has recovered it.
printf -- '--- can the operator still reach the guest while it is hard-closed? ---\n'
SHELL_OK=0
SHELL_PROBE="${TMP_ROOT}/shell-probe.out"
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if run_bounded 20 "$SHELL_PROBE" "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
        sh -c 'grep -q SIMULATION_COMPLETE /tmp/agent-box-firstrun.log && echo SHELL-ALIVE'
    then
        if grep -q 'SHELL-ALIVE' "$SHELL_PROBE"; then SHELL_OK=1; break; fi
    fi
    sleep 3
done
cat "$SHELL_PROBE"
if [ "$SHELL_OK" -eq 1 ]; then
    ok "limactl shell still answers while the hard close is in force"
else
    bad "limactl shell does not answer while the hard close is in force"
fi

printf -- '\n--- the transient unit log ---\n'
FR_OUT="${TMP_ROOT}/firstrun.out"
guest sudo cat "$FIRSTRUN_LOG" > "$FR_OUT" 2>&1
cat "$FR_OUT"

if grep -q '^RESULT=POLICY-DROP' "$FR_OUT"; then
    ok "a first-run failure left the OUTPUT policy at DROP"
else
    bad "a first-run failure did not leave the OUTPUT policy at DROP"
fi
if grep -q 'INIT_RC=0' "$FR_OUT"; then
    bad "init-firewall.sh reported success despite an unreachable meta endpoint"
else
    ok "init-firewall.sh failed as expected on the unreachable meta endpoint"
fi
if grep -q 'there is no standing ruleset' "$FR_OUT"; then
    ok "the hard-close branch was the one taken"
else
    bad "the hard-close branch was not taken"
fi
# In AGENTBOX-IN, which INPUT rule 1 jumps to. The accept rules moved out of
# the builtin chains when the firewall started owning chains rather than the
# whole table, so both halves are asserted: the rule, and the jump that reaches
# it. A rule in an unreachable chain would let the operator out just as surely.
if grep -qE '^-A AGENTBOX-IN .*--dport 22 -j ACCEPT' "$FR_OUT" \
    && grep -qx -- '-A INPUT -j AGENTBOX-IN' "$FR_OUT"; then
    ok "the hard-close ruleset keeps inbound port 22, in a chain INPUT reaches"
else
    bad "the hard-close ruleset does not keep inbound port 22"
fi

# Shell access must not have come at the cost of the thing being tested.
printf -- '\n--- egress is genuinely closed in that state ---\n'
EG_OUT="${TMP_ROOT}/hardclose-egress.out"
if run_bounded 30 "$EG_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- \
    sh -c 'curl -sS -m 8 -o /dev/null https://github.com'
then
    bad "github.com was still reachable during the hard close"
else
    ok "github.com was unreachable during the hard close"
fi
cat "$EG_OUT"

# The documented recovery, run over the shell the hard close left open — which
# is the claim the printed message makes.
printf -- '\n--- running the documented recovery over that shell ---\n'
if guest sudo sh -c 'iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F'; then
    ok "the first documented recovery step ran over limactl shell"
else
    bad "the first documented recovery step could not be run over limactl shell"
fi
if guest sudo systemctl restart agent-box-firewall.service; then
    ok "the second documented recovery step restarted the firewall"
else
    bad "the second documented recovery step failed"
fi

FW_OUT3="${TMP_ROOT}/firewall3.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT3" 2>&1
rc=$?
cat "$FW_OUT3"
if [ "$rc" -eq 0 ]; then ok "firewall-check passes again after the recovery"; else bad "firewall-check fails after the recovery"; fi

# ===========================================================================
step "9. provisioning is idempotent across a stop/start with the firewall up"
# ===========================================================================
#
# From the second boot onward the firewall service starts at multi-user.target
# and archive.ubuntu.com is not on the allowlist, so a provisioner that ran apt
# unconditionally would fail and take the whole start down with it.

printf -- '--- limactl stop ---\n'
if "$AGENTBOX" stop "$CLEAN_REPO"; then
    ok "agentbox stop exited 0"
else
    bad "agentbox stop did not exit 0"
fi

# ---- slot:9-ch (owner C2) ----
# ---- end slot:9-ch ----

printf -- '\n--- limactl start (re-runs provisioning under the firewall) ---\n'
RESTART_TS=$(date +%s)
"$AGENTBOX" start "$CLEAN_REPO"
rc=$?
printf 'restart took %s seconds\n' "$(( $(date +%s) - RESTART_TS ))"
if [ "$rc" -eq 0 ]; then ok "agentbox start exited 0 after a stop"; else bad "agentbox start exited ${rc} after a stop"; fi

printf -- '\n--- the firewall is active again after the restart ---\n'
FW_STATE2=$(guest systemctl is-active agent-box-firewall 2>/dev/null)
printf '%s\n' "$FW_STATE2"
if [ "$FW_STATE2" = "active" ]; then ok "agent-box-firewall is active after restart"; else bad "agent-box-firewall is ${FW_STATE2} after restart"; fi

printf -- '\n--- claude survived the restart ---\n'
VER2=$("$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -lc 'claude --version' 2>&1)
printf '%s\n' "$VER2"
if printf '%s' "$VER2" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
    ok "claude is still installed after the restart"
else
    bad "claude is missing after the restart"
fi

printf -- '\n--- a firewall rebuild under the standing deny succeeds ---\n'
# This is the case the old script could not survive: rebuilding while the deny
# ruleset is already in force.
REBUILD="${TMP_ROOT}/rebuild.out"
guest sudo systemctl restart agent-box-firewall.service > "$REBUILD" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then ok "the firewall rebuilt while the deny was in force"; else bad "the firewall rebuild failed under the standing deny (exit ${rc})"; cat "$REBUILD"; fi

FW_OUT2="${TMP_ROOT}/firewall2.out"
"$AGENTBOX" firewall-check "$CLEAN_REPO" > "$FW_OUT2" 2>&1
rc=$?
cat "$FW_OUT2"
if [ "$rc" -eq 0 ]; then ok "firewall-check still passes after the rebuild"; else bad "firewall-check failed after the rebuild"; fi

# ---- slot:9-tc (owner TA) ----
# ---- end slot:9-tc ----

# ===========================================================================
step "9b. resize changes the VM's shape and the box comes back"
# ===========================================================================
#
# `resize` is new in this branch, is documented in README and daily-use.md as
# the answer to a full disk, and had no coverage at all — only its error paths,
# exercised on the host. The happy path is the stop, the `limactl edit --set`,
# the restart, and whether the guest agrees afterwards.
#
# Memory rather than disk: it moves in both directions, so the box is left as it
# was found, and it does not depend on the guest growing a filesystem.

RESIZE_BEFORE=$("$LIMACTL" list --format '{{.Memory}}' "$INSTANCE" 2>/dev/null)
printf 'memory before: %s\n' "$RESIZE_BEFORE"

RESIZE_OUT="${TMP_ROOT}/resize.out"
run_bounded 900 "$RESIZE_OUT" "$AGENTBOX" resize "$CLEAN_REPO" --memory 7GiB
resize_rc=$BOUNDED_RC
tail -5 "$RESIZE_OUT"
if [ "$resize_rc" -eq 0 ]; then
    ok "agentbox resize exited 0"
else
    bad "agentbox resize exited ${resize_rc}"
fi

RESIZE_AFTER=$("$LIMACTL" list --format '{{.Memory}}' "$INSTANCE" 2>/dev/null)
printf 'memory after: %s\n' "$RESIZE_AFTER"
# limactl prints it humanised, so compare on the number rather than the string.
if printf '%s' "$RESIZE_AFTER" | grep -q '7'; then
    ok "limactl reports the new memory size after the resize"
else
    bad "limactl still reports ${RESIZE_AFTER} after a resize to 7GiB"
fi

if wait_for_guest 180; then
    ok "the box answers again after the resize"
else
    bad "the box does not answer after the resize"
fi
GUESTMEM_OUT="${TMP_ROOT}/guest-mem.out"
guest bash -c "awk '/MemTotal/ {print \"GUEST_MEMTOTAL_KB=\" \$2}' /proc/meminfo" > "$GUESTMEM_OUT" 2>&1
cat "$GUESTMEM_OUT"
GUESTMEM_KB=$(sed -n 's/^GUEST_MEMTOTAL_KB=//p' "$GUESTMEM_OUT" | head -1)
# 7GiB is 7340032 KiB; the guest always reports a little less than the whole.
if [ -n "$GUESTMEM_KB" ] && [ "$GUESTMEM_KB" -gt 6500000 ]; then
    ok "the guest itself sees the larger memory (${GUESTMEM_KB} kB)"
else
    bad "the guest does not see the larger memory (${GUESTMEM_KB:-<unread>} kB)"
fi

# ===========================================================================
step "9c. the allowlist's new line forms: a range and a suffix"
# ===========================================================================
#
# A CIDR needs no resolution and never expires. A suffix cannot be pre-resolved
# at all — that is the point of it — so it works only through the guest's own
# resolver, which adds each address as the guest looks it up. The distinction
# that proves which mechanism did the work is the ipset TIMEOUT: everything the
# rebuild adds is `timeout 0`, everything dnsmasq adds carries the set default.

ALLOW_OUT="${TMP_ROOT}/allowforms.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell.
run_bounded 300 "$ALLOW_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
echo \"CIDR_IN_SET=\$(sudo ipset test allowed-domains ${CIDR_IN} >/dev/null 2>&1 && echo yes || echo no)\"
echo \"CIDR_OUT_SET=\$(sudo ipset test allowed-domains ${CIDR_OUT} >/dev/null 2>&1 && echo yes || echo no)\"
# In range: allowed by the filter, so the connection is attempted and times out
# against an address nothing answers on. Out of range: REJECTed at once. curl
# tells them apart — 28 is a timeout, 7 is a refused connection.
curl -sS -m 4 -o /dev/null https://${CIDR_IN}/ 2>/dev/null; echo \"CIDR_IN_CURL=\$?\"
curl -sS -m 4 -o /dev/null https://${CIDR_OUT}/ 2>/dev/null; echo \"CIDR_OUT_CURL=\$?\"
echo \"V6_INERT=\$(sudo journalctl -u agent-box-firewall.service -b --no-pager | grep -c 'INERT' || true)\"
echo \"BAD_LINE_WARNED=\$(sudo journalctl -u agent-box-firewall.service -b --no-pager | grep -c 'no recognised form' || true)\"
# The suffix. It is never pre-resolved by the rebuild — that is what makes it a
# suffix — so anything the set holds for it came from the resolver.
getent ahostsv4 ${SUFFIX_HOST} >/dev/null 2>&1 || true
sleep 2
SA=\$(getent ahostsv4 ${SUFFIX_HOST} | awk '{print \$1; exit}')
echo \"SUFFIX_ADDR=\$SA\"
# An empty address would make the grep below match the FIRST line of the set
# and report it as this host's entry — the assertion would pass hardest
# exactly when the name did not resolve at all.
if [ -z \"\$SA\" ]; then
    echo \"SUFFIX_ENTRY=RESOLUTION-FAILED\"
else
    echo \"SUFFIX_ENTRY=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -F \"\$SA\" | head -1)\"
fi
curl -sS -m 10 -o /dev/null -w 'SUFFIX_HTTP=%{http_code}\n' https://${SUFFIX_HOST}/ 2>/dev/null || echo 'SUFFIX_HTTP=000'
"
cat "$ALLOW_OUT"

if grep -q '^CIDR_IN_SET=yes' "$ALLOW_OUT"; then
    ok "an address inside an allowlisted range is in the set"
else
    bad "an address inside an allowlisted range is not in the set"
fi
if grep -q '^CIDR_OUT_SET=no' "$ALLOW_OUT"; then
    ok "an address outside it is not"
else
    bad "an address outside the allowlisted range is in the set"
fi
if grep -q '^CIDR_IN_CURL=28' "$ALLOW_OUT"; then
    ok "the in-range address is permitted by the filter (it times out, not refused)"
else
    bad "the in-range address was not permitted: $(sed -n 's/^CIDR_IN_CURL=//p' "$ALLOW_OUT")"
fi
if grep -q '^CIDR_OUT_CURL=7' "$ALLOW_OUT"; then
    ok "the out-of-range address is refused immediately"
else
    bad "the out-of-range address was not refused: $(sed -n 's/^CIDR_OUT_CURL=//p' "$ALLOW_OUT")"
fi
if grep -qE '^V6_INERT=[1-9]' "$ALLOW_OUT"; then
    ok "an IPv6 range is accepted and reported as inert"
else
    bad "the IPv6 range was not reported as inert"
fi
if grep -qE '^BAD_LINE_WARNED=[1-9]' "$ALLOW_OUT"; then
    ok "a line in no recognised form is warned about, not silently dropped"
else
    bad "a malformed allowlist line was dropped silently"
fi
SUFFIX_ENTRY=$(sed -n 's/^SUFFIX_ENTRY=//p' "$ALLOW_OUT" | head -1)
printf 'the suffix host resolved to: %s\n' "$(sed -n 's/^SUFFIX_ADDR=//p' "$ALLOW_OUT" | head -1)"
printf 'its set entry: %s\n' "${SUFFIX_ENTRY:-<none>}"
# `timeout <non-zero>` is the proof it came from dnsmasq: the rebuild adds
# everything with `timeout 0`, so a live timeout cannot have come from there.
if printf '%s' "$SUFFIX_ENTRY" | grep -qE 'timeout [1-9]'; then
    ok "the suffix host's address entered the set via the resolver, not the rebuild"
else
    bad "the suffix host's address is absent, or was added by the rebuild rather than the resolver"
fi
if grep -q '^SUFFIX_HTTP=200' "$ALLOW_OUT"; then
    ok "a host under an allowlisted suffix is reachable"
else
    bad "a host under an allowlisted suffix is not reachable"
fi

printf -- '\n--- a rebuild keeps what the resolver added ---\n'
# The measurement that decided this: dnsmasq feeds the set when it FORWARDS an
# answer and not when it serves one from its own cache, so "the next lookup
# will re-add it" is not true, and a rebuild that forgot would black-hole the
# host for the rest of its TTL.
PRESERVE_OUT="${TMP_ROOT}/preserve.out"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$PRESERVE_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
SA=\$(getent ahostsv4 ${SUFFIX_HOST} | awk '{print \$1; exit}')
sudo systemctl restart agent-box-firewall.service
if [ -z \"\$SA\" ]; then
    echo \"AFTER_REBUILD=RESOLUTION-FAILED\"
else
    echo \"AFTER_REBUILD=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -F \"\$SA\" | head -1)\"
fi
sudo journalctl -u agent-box-firewall.service -b --no-pager | grep 'Carried' | tail -1
curl -sS -m 10 -o /dev/null -w 'STILL_HTTP=%{http_code}\n' https://${SUFFIX_HOST}/ 2>/dev/null || echo 'STILL_HTTP=000'
"
cat "$PRESERVE_OUT"
if grep -qE '^AFTER_REBUILD=add .*timeout [1-9]' "$PRESERVE_OUT"; then
    ok "the resolver-added address survived the rebuild, with its remaining time"
else
    bad "the rebuild forgot the resolver-added address"
fi
# Nothing is "carried" any more, and that is the fix rather than a regression:
# the resolver's addresses live in a set the rebuild does not touch, so they
# survive because they were never in the set being replaced. The assertion that
# matters is the one above — the entry is still there, with its timeout still
# running — plus the one below, that the host is still reachable.
if grep -qE '^AFTER_REBUILD=add .*timeout' "$PRESERVE_OUT"; then
    ok "the entry kept its timeout, so it is the resolver's and not a fresh pin"
else
    bad "the surviving entry is not a resolver entry"
fi
if grep -q '^STILL_HTTP=200' "$PRESERVE_OUT"; then
    ok "and the suffix host is still reachable after the rebuild"
else
    bad "the suffix host became unreachable after a rebuild"
fi

# ===========================================================================
step "9c2. exact means exact; a dot line means the subtree"
# ===========================================================================
#
# The distinction the whole feed rests on. An exact name is pre-resolved and
# pinned; feeding it to the resolver as well would have made every line in
# allowlist.base a wildcard for its subtree. Only dot lines are fed.

EXACT_OUT="${TMP_ROOT}/exact-vs-suffix.out"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$EXACT_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
echo \"FEED_LINES=\$(grep -c '^ipset=' /etc/dnsmasq.d/agent-box.conf || true)\"
echo \"FEED_HAS_SUFFIX=\$(grep -c '^ipset=/iana.org/' /etc/dnsmasq.d/agent-box.conf || true)\"
echo \"FEED_HAS_EXACT=\$(grep -c '^ipset=/${EXACT_HOST}/' /etc/dnsmasq.d/agent-box.conf || true)\"
echo \"FEED_HAS_ANTHROPIC=\$(grep -c '^ipset=/api.anthropic.com/' /etc/dnsmasq.d/agent-box.conf || true)\"
echo \"CONF_FILE_ARG=\$(tr '\\0' '\\n' < /proc/\$(pgrep -x dnsmasq | head -1)/cmdline | grep -c -- '--conf-file=/etc/dnsmasq.d/agent-box.conf' || true)\"
echo \"REBIND=\$(grep -c '^stop-dns-rebind' /etc/dnsmasq.d/agent-box.conf || true)\"
echo \"CACHETTL=\$(sed -n 's/^max-cache-ttl=//p' /etc/dnsmasq.d/agent-box.conf | head -1)\"
"
cat "$EXACT_OUT"
if grep -qE '^FEED_HAS_SUFFIX=[1-9]' "$EXACT_OUT"; then
    ok "the dot line is fed to the resolver"
else
    bad "the dot line is not fed to the resolver"
fi
if grep -q '^FEED_HAS_EXACT=0' "$EXACT_OUT" && grep -q '^FEED_HAS_ANTHROPIC=0' "$EXACT_OUT"; then
    ok "exact names are NOT fed, so a bare line cannot admit its subtree"
else
    bad "an exact name was fed to the resolver; every bare line is a wildcard"
fi
if grep -qE '^FEED_LINES=[1-9]' "$EXACT_OUT"; then
    ok "the feed has rules at all, so the two checks above are not vacuous"
else
    bad "the resolver config has no feed rules"
fi
if grep -qE '^CONF_FILE_ARG=[1-9]' "$EXACT_OUT"; then
    ok "dnsmasq is running with our config as its only conf-file"
else
    bad "dnsmasq is not reading our configuration"
fi
if grep -qE '^REBIND=[1-9]' "$EXACT_OUT"; then
    ok "stop-dns-rebind is set, so an answer cannot name a private address"
else
    bad "stop-dns-rebind is missing"
fi
CACHE_TTL=$(sed -n 's/^CACHETTL=//p' "$EXACT_OUT" | head -1)
printf 'max-cache-ttl=%s against an entry lifetime of 3600\n' "${CACHE_TTL:-<unset>}"
if [ -n "$CACHE_TTL" ] && [ "$CACHE_TTL" -lt 3600 ]; then
    ok "the resolver cache expires before the set entry does"
else
    bad "max-cache-ttl is not below the entry lifetime; a host can go dark silently"
fi

printf -- '\n--- tampering with the feed is caught ---\n'
# The resolver's config IS the allowlist. A line added to it by anything other
# than the rebuild must be reported, not obeyed.
TAMPER_OUT="${TMP_ROOT}/feed-tamper.out"
run_bounded 300 "$TAMPER_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c '
set -u
sudo cp /etc/dnsmasq.d/agent-box.conf /tmp/abx-conf.bak
printf "ipset=/evil.example/allowed-resolved\n" | sudo tee -a /etc/dnsmasq.d/agent-box.conf >/dev/null
sudo /opt/agent-box/guest/init-firewall.sh --verify-only 2>&1 | grep -E "resolver-conf" || true
echo "--- restored ---"
sudo cp /tmp/abx-conf.bak /etc/dnsmasq.d/agent-box.conf
sudo /opt/agent-box/guest/init-firewall.sh --verify-only 2>&1 | grep -E "resolver-conf" || true'
cat "$TAMPER_OUT"
if grep -q 'FAIL  resolver-conf' "$TAMPER_OUT"; then
    ok "a feed rule the allowlist did not generate is reported as a failure"
else
    bad "the resolver config can be edited without verification noticing"
fi
if grep -q 'PASS  resolver-conf' "$TAMPER_OUT"; then
    ok "and it passes again once the file is put back"
else
    bad "resolver-conf did not pass after the file was restored"
fi

printf -- '\n--- removing a suffix removes the reach it granted ---\n'
# The reason the resolver's addresses live in a set of their own: with one set
# and a preserve loop, deleting a line left its addresses in place for ever.
REMOVE_OUT="${TMP_ROOT}/suffix-remove.out"
cp "${GUEST_CFG}/allowlist.local" "${TMP_ROOT}/allowlist.local.bak"
grep -v '^\.iana\.org$' "${TMP_ROOT}/allowlist.local.bak" > "${GUEST_CFG}/allowlist.local"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$REMOVE_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
echo \"BEFORE=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -c '^add ' || true)\"
sudo systemctl restart agent-box-firewall.service
echo \"AFTER=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -c '^add ' || true)\"
echo \"FEED_STILL=\$(grep -c '^ipset=/iana.org/' /etc/dnsmasq.d/agent-box.conf || true)\"
curl -sS -m 8 -o /dev/null -w 'GONE_HTTP=%{http_code}\n' https://${SUFFIX_HOST}/ 2>/dev/null || echo 'GONE_HTTP=000'
"
cat "$REMOVE_OUT"
if grep -q '^FEED_STILL=0' "$REMOVE_OUT"; then
    ok "the removed suffix is gone from the resolver's rules"
else
    bad "the removed suffix is still fed"
fi
if grep -q '^AFTER=0' "$REMOVE_OUT"; then
    ok "and the addresses it had granted were flushed, not carried forward"
else
    bad "removing a suffix left its addresses in the set"
fi
if grep -q '^GONE_HTTP=000' "$REMOVE_OUT"; then
    ok "the host it admitted is no longer reachable"
else
    bad "the host is still reachable after its suffix was removed"
fi
cp "${TMP_ROOT}/allowlist.local.bak" "${GUEST_CFG}/allowlist.local"
guest sudo systemctl restart agent-box-firewall.service >/dev/null 2>&1 || true

printf -- '\n--- a malformed line is a warning, not a dead box ---\n'
# Two bad CIDRs are staged in allowlist.local from the start: 999.1.2.3/24 and
# 10.0.0.0/99. The box came up, which is most of the assertion.
BADLINE_OUT="${TMP_ROOT}/badline.out"
guest sudo journalctl -u agent-box-firewall.service -b --no-pager > "$BADLINE_OUT" 2>&1 || true
if grep -q 'no recognised form' "$BADLINE_OUT"; then
    ok "the malformed lines are named in the log"
else
    bad "a malformed allowlist line was not reported"
fi
if grep -q '999.1.2.3/24' "$BADLINE_OUT" && grep -q '10.0.0.0/99' "$BADLINE_OUT"; then
    ok "and each one is named individually, ranges checked and not just shape"
else
    bad "an out-of-range CIDR was accepted as valid"
fi
if guest sudo systemctl is-active --quiet agent-box-firewall.service; then
    ok "and the firewall is active despite them"
else
    bad "a malformed allowlist line took the firewall down"
fi

# ===========================================================================
step "9d. no resolver means no resolution: the box fails CLOSED"
# ===========================================================================
#
# The whole allowlist now depends on a daemon. The question is which way it
# fails when that daemon is not there, and the answer has to be closed.

CLOSED_OUT="${TMP_ROOT}/failclosed.out"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$CLOSED_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
sudo systemctl stop dnsmasq
echo \"DNSMASQ=\$(systemctl is-active dnsmasq || true)\"
getent ahostsv4 ${SUFFIX_HOST} >/dev/null 2>&1 && echo 'RESOLVES=yes' || echo 'RESOLVES=no'
curl -sS -m 8 -o /dev/null https://api.anthropic.com/ 2>/dev/null; echo \"ANTHROPIC_RC=\$?\"
sudo /opt/agent-box/guest/init-firewall.sh --verify-only 2>&1 | grep -E 'resolver-up' || true
echo '--- and back ---'
sudo systemctl start dnsmasq
sleep 2
echo \"DNSMASQ_AGAIN=\$(systemctl is-active dnsmasq || true)\"
sudo /opt/agent-box/guest/init-firewall.sh --verify-only 2>&1 | grep -E 'resolver-up' || true
"
cat "$CLOSED_OUT"
if grep -q '^DNSMASQ=inactive' "$CLOSED_OUT"; then
    ok "dnsmasq was really stopped, so the checks below are not vacuous"
else
    bad "dnsmasq did not stop"
fi
if grep -q '^RESOLVES=no' "$CLOSED_OUT"; then
    ok "with the resolver down, a name no longer resolves"
else
    bad "a name still resolved with the resolver down"
fi
if grep -q '^ANTHROPIC_RC=0' "$CLOSED_OUT"; then
    bad "the box was still reaching hosts with its resolver down"
else
    ok "the box is closed, not open, with its resolver down"
fi
if grep -q 'FAIL  resolver-up' "$CLOSED_OUT"; then
    ok "and verification says exactly why"
else
    bad "verification did not name the resolver"
fi
if grep -q 'PASS  resolver-up' "$CLOSED_OUT"; then
    ok "starting it again clears the check"
else
    bad "the resolver check did not clear after a restart"
fi

# ===========================================================================
step "9e. the three egress modes, switched on a live box"
# ===========================================================================
#
# deny -> observe -> open -> deny, with a verification after each, and the
# things each mode promises asserted while it is in force. `status --json`
# is read in every state, because the mode is what the `firewall` field means
# now and a stale value there would be worse than none.

mode_of_status() {
    "$AGENTBOX" status "$CLEAN_REPO" --json 2>/dev/null \
        | "$PY" -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d["boxes"][0].get("firewall", "?"))
except Exception:
    print("?")' 2>/dev/null || printf '?'
}

printf -- '--- deny, where we start ---\n'
DENY_MODE=$(mode_of_status); printf 'status --json firewall=%s\n' "$DENY_MODE"
if [ "$DENY_MODE" = "deny" ]; then
    ok "status --json reports the mode as deny"
else
    bad "status --json reports '${DENY_MODE}' on a deny box"
fi
if [ "$("$AGENTBOX" egress "$CLEAN_REPO" 2>/dev/null)" = "deny" ]; then
    ok "agentbox egress shows deny"
else
    bad "agentbox egress does not show deny"
fi

printf -- '\n--- deny -> observe ---\n'
OBS_OUT="${TMP_ROOT}/egress-observe.out"
run_bounded 300 "$OBS_OUT" "$AGENTBOX" egress "$CLEAN_REPO" observe
obs_rc=$BOUNDED_RC
cat "$OBS_OUT"
if [ "$obs_rc" -eq 0 ]; then ok "agentbox egress observe exited 0"; else bad "agentbox egress observe exited ${obs_rc}"; fi
if grep -q 'NOTE:' "$OBS_OUT"; then
    ok "it said what observe does"
else
    bad "it did not explain observe"
fi
if grep -q '^PASS  mode-observe-log' "$OBS_OUT"; then
    ok "verification: the log rule is in place"
else
    bad "no log rule in observe mode"
fi
if grep -q '^PASS  mode-observe-pass' "$OBS_OUT"; then
    ok "verification: the chain ends in ACCEPT, never a silent deny"
else
    bad "observe mode could be silently denying"
fi
OBS_MODE=$(mode_of_status)
if [ "$OBS_MODE" = "observe" ]; then ok "status --json reports observe"; else bad "status --json reports '${OBS_MODE}' on an observe box"; fi

printf -- '\n--- and it allows, and records, a non-allowlisted host ---\n'
OBSCONN_OUT="${TMP_ROOT}/observe-conn.out"
run_bounded 120 "$OBSCONN_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c '
curl -sS -m 10 -o /dev/null -w "OBS_HTTP=%{http_code}\n" https://example.com/ 2>/dev/null || echo "OBS_HTTP=000"'
cat "$OBSCONN_OUT"
if grep -q '^OBS_HTTP=200' "$OBSCONN_OUT"; then
    ok "observe mode let a non-allowlisted host through"
else
    bad "observe mode did not let a non-allowlisted host through"
fi
sleep 3

EGLOG_OUT="${TMP_ROOT}/egress-log.out"
"$AGENTBOX" egress-log "$CLEAN_REPO" --since 10m > "$EGLOG_OUT" 2>&1 || true
cat "$EGLOG_OUT"
if grep -q 'example.com' "$EGLOG_OUT"; then
    ok "egress-log shows the connection with the name the guest resolved"
else
    bad "egress-log did not show the connection, or could not name it"
fi
EGJSON_OUT="${TMP_ROOT}/egress-log.json"
"$AGENTBOX" egress-log "$CLEAN_REPO" --since 10m --json > "$EGJSON_OUT" 2>&1 || true
if "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["mode"]=="observe"; assert any(r.get("name")=="example.com" for r in d["destinations"])' "$EGJSON_OUT" 2>/dev/null; then
    ok "egress-log --json parses and carries the mode and the name"
else
    bad "egress-log --json is not the documented shape"
    cat "$EGJSON_OUT"
fi
EGAL_OUT="${TMP_ROOT}/egress-log.allowlist"
"$AGENTBOX" egress-log "$CLEAN_REPO" --since 10m --as-allowlist > "$EGAL_OUT" 2>&1 || true
cat "$EGAL_OUT"
if grep -qx 'example.com' "$EGAL_OUT"; then
    ok "--as-allowlist emits the name as an allowlist line"
else
    bad "--as-allowlist did not emit the name"
fi
if grep -q 'judgement call' "$EGAL_OUT" || ! grep -q '^#.*port ' "$EGAL_OUT"; then
    ok "--as-allowlist says that unnamed addresses are a judgement call, or had none"
else
    bad "--as-allowlist emitted bare addresses without saying they are a judgement"
fi

printf -- '\n--- observe -> open ---\n'
OPEN_OUT="${TMP_ROOT}/egress-open.out"
run_bounded 300 "$OPEN_OUT" "$AGENTBOX" egress "$CLEAN_REPO" open
open_rc=$BOUNDED_RC
cat "$OPEN_OUT"
if [ "$open_rc" -eq 0 ]; then ok "agentbox egress open exited 0"; else bad "agentbox egress open exited ${open_rc}"; fi
if grep -q 'WARNING' "$OPEN_OUT"; then
    ok "it warned about what open gives up"
else
    bad "switching to open printed no warning"
fi
if grep -q '^PASS  mode-open' "$OPEN_OUT"; then
    ok "verification: OUTPUT is unfiltered"
else
    bad "open mode did not verify as unfiltered"
fi
if grep -q '^PASS  inbound-intact' "$OPEN_OUT"; then
    ok "verification: the inbound path is still intact in open mode"
else
    bad "the INPUT chain was not asserted in open mode"
fi
OPEN_MODE=$(mode_of_status)
if [ "$OPEN_MODE" = "open" ]; then ok "status --json reports open"; else bad "status --json reports '${OPEN_MODE}' on an open box"; fi

OPENCONN_OUT="${TMP_ROOT}/open-conn.out"
run_bounded 120 "$OPENCONN_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c '
curl -sS -m 10 -o /dev/null -w "OPEN_HTTP=%{http_code}\n" https://1.1.1.1/ 2>/dev/null || echo "OPEN_HTTP=000"
sudo iptables -S | grep -E "^-P (INPUT|OUTPUT)" | sed "s/^/POLICY /"'
cat "$OPENCONN_OUT"
if grep -qE '^OPEN_HTTP=(2|3)[0-9][0-9]' "$OPENCONN_OUT"; then
    ok "open mode reached an address on no list at all"
else
    bad "open mode did not reach an off-list address"
fi
if grep -qx 'POLICY -P INPUT DROP' "$OPENCONN_OUT"; then
    ok "INPUT is still DROP with egress open"
else
    bad "open mode changed the INPUT policy"
fi

printf -- '\n--- open -> deny, back where we started ---\n'
BACK_OUT="${TMP_ROOT}/egress-deny.out"
run_bounded 300 "$BACK_OUT" "$AGENTBOX" egress "$CLEAN_REPO" deny
back_rc=$BOUNDED_RC
cat "$BACK_OUT"
if [ "$back_rc" -eq 0 ]; then ok "agentbox egress deny exited 0"; else bad "agentbox egress deny exited ${back_rc}"; fi
if grep -q '^PASS  egress-denied' "$BACK_OUT"; then
    ok "verification: the allowlist refuses again"
else
    bad "deny mode did not refuse again"
fi
if grep -q '^PASS  literal-ip-denied' "$BACK_OUT"; then
    ok "verification: a literal address is refused again"
else
    bad "a literal address was not refused after returning to deny"
fi
BACK_MODE=$(mode_of_status)
if [ "$BACK_MODE" = "deny" ]; then ok "status --json reports deny again"; else bad "status --json reports '${BACK_MODE}' after returning to deny"; fi

# A stopped box still has to answer, from the host's own record.
printf -- '\n--- and the mode is known even when the box is not running ---\n'
if [ "$("$AGENTBOX" egress "$CLEAN_REPO" 2>/dev/null)" = "deny" ]; then
    ok "agentbox egress shows the mode of a running box from the guest"
else
    bad "agentbox egress does not show the mode"
fi
if grep -qx 'egress=deny' "${AGENT_BOX_CONFIG_DIR}/instances/${INSTANCE}" 2>/dev/null; then
    ok "the host recorded the mode too, so a stopped box can still be asked"
else
    bad "the host has no record of this box's mode"
fi

# ===========================================================================
step "9f. two boxes at once: status lists BOTH"
# ===========================================================================
#
# The regression test for a box vanishing from status. `limactl shell` is ssh
# and ssh reads its own stdin; called inside the loop that reads the box list
# from a here-document, it consumed the remaining lines, so the loop saw one
# entry and every box after the first disappeared from the one command whose
# job is to say which boxes exist. One box could never show it.

mkdir -p "$SECOND_REPO"
git init -q "$SECOND_REPO"
printf 'a second throwaway repository, for the two-box status check\n' > "${SECOND_REPO}/hello.txt"

SEC_CREATE="${TMP_ROOT}/second-create.out"
run_bounded 1200 "$SEC_CREATE" "$AGENTBOX" create "$SECOND_REPO" --egress deny
sec_rc=$BOUNDED_RC
tail -3 "$SEC_CREATE"
if [ "$sec_rc" -eq 0 ]; then
    ok "a second box was created"
else
    bad "the second box could not be created (exit ${sec_rc})"
fi

if [ "$sec_rc" -eq 0 ]; then
    TWOJ="${TMP_ROOT}/two-boxes.json"
    # No repo argument: this is the all-boxes path, which is the one that broke.
    # It lists every agent-box instance on the machine, so it is filtered to the
    # two this test made before anything is judged.
    "$AGENTBOX" status --json > "$TWOJ" 2>/dev/null || true
    "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
want = {sys.argv[2], sys.argv[3]}
got = {b["instance"] for b in d["boxes"]}
print("listed:", " ".join(sorted(got)))
missing = want - got
print("MISSING=" + (",".join(sorted(missing)) if missing else "none"))
for b in d["boxes"]:
    if b["instance"] in want:
        print("BOX %s state=%s firewall=%s claude=%s" % (
            b["instance"], b["state"], b["firewall"],
            "yes" if b.get("claude_version") else "no"))
' "$TWOJ" "$INSTANCE" "$SECOND_INSTANCE" > "${TMP_ROOT}/two-boxes.txt" 2>&1 || true
    cat "${TMP_ROOT}/two-boxes.txt"

    if grep -q '^MISSING=none' "${TMP_ROOT}/two-boxes.txt"; then
        ok "status --json lists both running boxes"
    else
        bad "status --json dropped a box: $(sed -n 's/^MISSING=//p' "${TMP_ROOT}/two-boxes.txt")"
    fi
    # The second box's guest fields must be POPULATED, not merely present: the
    # bug's signature was a box appearing with everything unknown because its
    # guest was never asked.
    if grep -qE "^BOX ${SECOND_INSTANCE} state=running firewall=deny claude=yes" "${TMP_ROOT}/two-boxes.txt"; then
        ok "and the second box's guest fields are populated, not defaulted"
    else
        bad "the second box is listed but its guest was never asked"
    fi

    TWOT="${TMP_ROOT}/two-boxes.txt.out"
    "$AGENTBOX" status > "$TWOT" 2>/dev/null || true
    cat "$TWOT"
    if grep -q "$INSTANCE" "$TWOT" && grep -q "$SECOND_INSTANCE" "$TWOT"; then
        ok "the text listing shows both too"
    else
        bad "the text listing dropped a box"
    fi

    # C16: the host's record goes with the instance.
    if [ -f "${AGENT_BOX_CONFIG_DIR}/instances/${SECOND_INSTANCE}" ]; then
        ok "the second box has a host-side mode record"
    else
        bad "no host-side mode record for the second box"
    fi
    "$AGENTBOX" destroy "$SECOND_INSTANCE" >/dev/null 2>&1 || true
    if [ -f "${AGENT_BOX_CONFIG_DIR}/instances/${SECOND_INSTANCE}" ]; then
        bad "destroy left the host-side mode record behind"
    else
        ok "destroy removed the host-side mode record"
    fi
fi

# ---- slot:9f-triage (owner H3) ----
# ---- end slot:9f-triage ----

# ===========================================================================
step "9g. the resolver keeps feeding: cache expiry, mode survival, bad input"
# ===========================================================================

printf -- '--- an expired entry is re-fed by the next lookup ---\n'
# dnsmasq feeds the set only when it FORWARDS an answer, so the relationship
# that has to hold is cache TTL < entry TTL. Deleting the entry by hand is the
# same situation as the entry expiring, without waiting an hour for it.
REFEED_OUT="${TMP_ROOT}/refeed.out"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$REFEED_OUT" "$LIMACTL" shell --workdir /work "$INSTANCE" -- bash -c "
set -u
getent ahostsv4 ${SUFFIX_HOST} >/dev/null 2>&1 || true
sleep 1
SA=\$(getent ahostsv4 ${SUFFIX_HOST} | awk '{print \$1; exit}')
echo \"ADDR=\$SA\"
if [ -z \"\$SA\" ]; then echo 'REFED=RESOLUTION-FAILED'; exit 0; fi
sudo ipset del ${IPSET_RESOLVED_NAME} \"\$SA\" 2>/dev/null || true
echo \"AFTER_DEL=\$(sudo ipset test ${IPSET_RESOLVED_NAME} \"\$SA\" >/dev/null 2>&1 && echo present || echo gone)\"
# Past the cache bound, so the next lookup is forwarded and therefore feeds.
sudo systemctl restart dnsmasq
sleep 2
getent ahostsv4 ${SUFFIX_HOST} >/dev/null 2>&1 || true
sleep 2
echo \"REFED=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -c . || true)\"
curl -sS -m 10 -o /dev/null -w 'REFED_HTTP=%{http_code}\n' https://${SUFFIX_HOST}/ 2>/dev/null || echo 'REFED_HTTP=000'
"
cat "$REFEED_OUT"
if grep -q '^AFTER_DEL=gone' "$REFEED_OUT"; then
    ok "the entry was really removed, so the re-feed check is not vacuous"
else
    bad "could not remove the entry"
fi
if grep -q '^REFED_HTTP=200' "$REFEED_OUT"; then
    ok "the next lookup re-fed the set and the host is reachable again"
else
    bad "an expired entry was not re-fed by the next lookup"
fi

printf -- '\n--- egress-log --since rejects a duration it cannot mean ---\n'
SINCE_OUT="${TMP_ROOT}/since-bad.out"
run_bounded 60 "$SINCE_OUT" "$AGENTBOX" egress-log "$CLEAN_REPO" --since "last tuesday"
since_rc=$BOUNDED_RC
cat "$SINCE_OUT"
if [ "$since_rc" -ne 0 ] && grep -q 'takes a number and one of' "$SINCE_OUT"; then
    ok "a malformed --since is a usage error, not an empty window"
else
    bad "a malformed --since was accepted"
fi

printf -- '\n--- a mode survives a stop and a start ---\n'
# Provisioning re-runs on every start with the CREATE-time parameters, so its
# write-once guard is the only thing stopping a restart reverting a deliberate
# change. Nothing tested it.
"$AGENTBOX" egress "$CLEAN_REPO" observe >/dev/null 2>&1 || true
MODE_BEFORE=$("$AGENTBOX" egress "$CLEAN_REPO" 2>/dev/null)
printf 'mode before the restart: %s\n' "$MODE_BEFORE"
SURV_OUT="${TMP_ROOT}/mode-survive.out"
run_bounded 300 "$SURV_OUT" "$AGENTBOX" stop "$INSTANCE"
run_bounded 900 "$SURV_OUT" "$AGENTBOX" start "$CLEAN_REPO"
surv_rc=$BOUNDED_RC
tail -2 "$SURV_OUT"
if [ "$surv_rc" -ne 0 ]; then
    bad "agentbox start exited ${surv_rc} after a mode change"
else
    ok "the box restarted after a mode change"
fi
if wait_for_guest 240; then
    MODE_AFTER=$("$AGENTBOX" egress "$CLEAN_REPO" 2>/dev/null)
    printf 'mode after the restart: %s\n' "$MODE_AFTER"
    if [ "$MODE_AFTER" = "observe" ]; then
        ok "the mode survived the restart; provisioning did not revert it"
    else
        bad "the mode reverted to '${MODE_AFTER}' on restart; the write-once guard failed"
    fi
else
    bad "the box did not come back after the restart"
fi
"$AGENTBOX" egress "$CLEAN_REPO" deny >/dev/null 2>&1 || true

# ===========================================================================
step "9h. the live reading, and a mode change that has to be all or nothing"
# ===========================================================================
#
# Two things one box can prove and the host's own record cannot.
#
# The mode every reporter shows must come from the RULESET. Planting a
# disagreement — the file saying one thing, the kernel doing another — is the
# only way to tell a reader that reads the ruleset from one that reads the file
# and is right by luck. The host's record cannot know the difference.

printf -- '--- a planted disagreement is reported, not believed ---\n'
DISAGREE_OUT="${TMP_ROOT}/disagree.out"
# shellcheck disable=SC2016  # the expansion is the guest's, not this shell's.
guest sudo bash -c '
cp /etc/agent-box/egress-mode /tmp/abx-mode.bak
printf "open\n" > /etc/agent-box/egress-mode
echo "FILE_NOW=$(cat /etc/agent-box/egress-mode)"' > "$DISAGREE_OUT" 2>&1
cat "$DISAGREE_OUT"

DIS_CLI="${TMP_ROOT}/disagree-cli.out"
"$AGENTBOX" egress "$CLEAN_REPO" > "$DIS_CLI" 2>&1 || true
cat "$DIS_CLI"
if grep -qx 'unknown' "$DIS_CLI"; then
    ok "agentbox egress reports unknown when the file and the ruleset disagree"
else
    bad "agentbox egress believed one of the two: $(head -1 "$DIS_CLI")"
fi
if grep -q "mode file says 'open'" "$DIS_CLI" && grep -q "ruleset is 'deny'" "$DIS_CLI"; then
    ok "and it names both, so the reader can tell which to fix"
else
    bad "the disagreement was not explained"
fi

DIS_JSON="${TMP_ROOT}/disagree.json"
"$AGENTBOX" status "$CLEAN_REPO" --json > "$DIS_JSON" 2>/dev/null || true
if jq -e '.boxes[0].firewall == "unknown"' "$DIS_JSON" >/dev/null 2>&1 \
    && jq -e '.boxes[0] | has("firewall_detail")' "$DIS_JSON" >/dev/null 2>&1; then
    ok "status --json reports unknown with a detail on a disagreeing box"
else
    bad "status --json did not report the disagreement"
    cat "$DIS_JSON"
fi

# The banner, in the place an operator is about to set an agent going. `run`
# without a token stops at the token check, which is after the banner.
DIS_RUN="${TMP_ROOT}/disagree-run.out"
printf 'Do nothing.\n' > "${TMP_ROOT}/dis-brief.md"
run_bounded 240 "$DIS_RUN" "$AGENTBOX" run "$CLEAN_REPO" "${TMP_ROOT}/dis-brief.md" --wait
cat "$DIS_RUN"
if grep -q 'egress mode: UNKNOWN' "$DIS_RUN"; then
    ok "run says so on its first line, where somebody is about to start an agent"
else
    bad "run did not warn about the disagreement"
fi

guest sudo cp /tmp/abx-mode.bak /etc/agent-box/egress-mode
if [ "$("$AGENTBOX" egress "$CLEAN_REPO" 2>/dev/null)" = "deny" ]; then
    ok "and the reading is right again once the file is put back"
else
    bad "the mode did not read correctly after the file was restored"
fi

printf -- '\n--- a mode change that fails leaves nothing armed ---\n'
# Writing the mode file first and rebuilding second left a failed change armed:
# the CLI said nothing had happened and the 15-minute timer applied it a
# quarter of an hour later.
#
# The rebuild is made to fail through /etc/hosts rather than through the unit's
# environment, and the difference matters: `agentbox egress` now runs the script
# directly with `--mode`, so a systemd drop-in on the unit would not be read and
# the "failure" would quietly succeed. glibc consults /etc/hosts before DNS, so
# this reaches the curl the rebuild actually makes.
ARMED_OUT="${TMP_ROOT}/armed.out"
guest sudo bash -c '
cp /etc/hosts /tmp/abx-hosts.bak
printf "127.0.0.1 api.github.com\n" >> /etc/hosts
echo BREAK_OK' > "$ARMED_OUT" 2>&1
cat "$ARMED_OUT"
if grep -q '^BREAK_OK' "$ARMED_OUT"; then
    ok "the rebuild was really made to fail, so the checks below are not vacuous"
else
    bad "could not break the rebuild; the checks below would prove nothing"
fi

FAILCHANGE="${TMP_ROOT}/failchange.out"
run_bounded 300 "$FAILCHANGE" "$AGENTBOX" egress "$CLEAN_REPO" observe
fc_rc=$BOUNDED_RC
cat "$FAILCHANGE"
if [ "$fc_rc" -ne 0 ]; then
    ok "a mode change whose rebuild fails exits non-zero"
else
    bad "a failing mode change reported success"
fi
ARMED_STATE="${TMP_ROOT}/armed-state.out"
# shellcheck disable=SC2016  # the expansion is the guest's, not this shell's.
guest sudo bash -c '
echo "MODE_FILE=$(cat /etc/agent-box/egress-mode)"
echo "LIVE=$(/opt/agent-box/guest/egress-mode.sh)"
cp /tmp/abx-hosts.bak /etc/hosts' > "$ARMED_STATE" 2>&1
cat "$ARMED_STATE"
if grep -qx 'MODE_FILE=deny' "$ARMED_STATE"; then
    ok "the guest mode file was NOT left holding the mode that failed"
else
    bad "a failed change left '$(sed -n 's/^MODE_FILE=//p' "$ARMED_STATE")' armed for the timer to apply"
fi
if grep -qx 'egress=deny' "${AGENT_BOX_CONFIG_DIR}/instances/${INSTANCE}" 2>/dev/null; then
    ok "and the host record still says the mode the box is actually on"
else
    bad "the host record and the box disagree after a failed change"
fi
# The ruleset too, not just the two records: a revert that wrote the files and
# left the kernel on the new mode would satisfy everything above.
if grep -q '^LIVE=live=deny' "$ARMED_STATE"; then
    ok "and the live ruleset is back on the previous mode"
else
    bad "the live ruleset was left on the mode that failed: $(sed -n 's/^LIVE=//p' "$ARMED_STATE")"
fi
guest sudo systemctl restart agent-box-firewall.service >/dev/null 2>&1 || true

# ---- slot:9i (owner H3) ----
# ---- end slot:9i ----

# ===========================================================================
step "10. destroy the instance, by bare name"
# ===========================================================================
#
# By name rather than by path, which is what makes a VM removable after its
# repository directory is gone.

"$AGENTBOX" destroy "$INSTANCE"
rc=$?
if [ "$rc" -eq 0 ]; then ok "agentbox destroy exited 0 for a bare instance name"; else bad "agentbox destroy exited ${rc}"; fi

printf -- '\n--- limactl list ---\n'
"$LIMACTL" list 2>&1
if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$INSTANCE"; then
    bad "${INSTANCE} is still listed after destroy"
else
    ok "${INSTANCE} is gone from limactl list"
fi

# ===========================================================================
step "11. a second instance with the Docker and browser-testing profile"
# ===========================================================================
#
# Everything from here down is about the opt-in profile: Docker Engine inside
# the guest, containers held to the same egress allowlist, a forwarded port,
# Node 22 with Playwright's system libraries, and Rosetta for amd64 images.
#
# A separate VM, not a flag on the first one. The profile is fixed at create
# time — that is the whole design — so the only way to test both shapes is to
# build both.

# ---- slot:11-pre (owner H1) ----
# ---- end slot:11-pre ----

mkdir -p "$DOCKER_REPO"
git init -q "$DOCKER_REPO"
cat > "${DOCKER_REPO}/hello.txt" <<'EOF'
A second throwaway repository, for the Docker and Playwright profile.
EOF

printf 'This installs Docker Engine, Node 22 and Playwright system libraries.\n'
printf 'It is slower than the first create; it is not stuck.\n'
DK_CREATE_OUT="${TMP_ROOT}/dk-create.out"
DK_TS=$(date +%s)
# FORWARD_PORT twice, deliberately: the flag accumulates across repeats and
# across a comma list, so a duplicate must be collapsed rather than prepending
# two identical portForwards entries and printing the first port twice in the
# summary. The ports are the $$-derived ones from the preamble, never literals.
# The summary assertion below is what proves it.
run_bounded 2400 "$DK_CREATE_OUT" "$AGENTBOX" create "$DOCKER_REPO" \
    --egress deny --docker --playwright --rosetta \
    --forward "${FORWARD_PORT},${FORWARD_PORT}" --forward "${FORWARD_PORT2}"
dk_rc=$BOUNDED_RC
cat "$DK_CREATE_OUT"
printf 'docker-profile create took %s seconds\n' "$(( $(date +%s) - DK_TS ))"
if [ "$dk_rc" -eq 0 ]; then ok "agentbox create --docker --playwright --rosetta succeeded"; else bad "that create exited ${dk_rc}"; fi

if grep -q 'WARNING: --forward' "$DK_CREATE_OUT"; then
    ok "--forward printed the widening warning"
else
    bad "--forward printed no warning"
fi
if grep -qE "^  forwarded +${FORWARD_PORT} ${FORWARD_PORT2}\$" "$DK_CREATE_OUT"; then
    ok "the summary records both forwarded ports, with the repeated one collapsed"
else
    bad "the summary does not read 'forwarded   ${FORWARD_PORT} ${FORWARD_PORT2}'; a repeated --forward was not de-duplicated"
fi
if grep -qE '^agentbox: sizing: 4 cpus, 8GiB memory, 60GiB disk$' "$DK_CREATE_OUT"; then
    ok "--docker raised the default sizing to 4/8GiB/60GiB"
else
    bad "--docker did not print the raised default sizing"
fi

if "$LIMACTL" list --quiet | grep -qxF "$DOCKER_INSTANCE"; then
    ok "instance ${DOCKER_INSTANCE} exists"
else
    bad "instance ${DOCKER_INSTANCE} does not exist; the remaining Docker checks cannot run"
    summarise_and_exit
fi

printf -- '\n--- the sizing Lima actually gave it ---\n'
"$LIMACTL" list "$DOCKER_INSTANCE"

# ---- slot:11b (owner H1) ----
# ---- end slot:11b ----

# ===========================================================================
step "12. Docker inside the guest, under the same allowlist"
# ===========================================================================

printf -- '--- docker info, as the NON-ROOT guest user ---\n'
# Not under sudo. A box where only root can talk to the daemon is a box the
# agent cannot use, and the agent is never root.
DI_OUT="${TMP_ROOT}/docker-info.out"
run_bounded 120 "$DI_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    docker info --format '{{.ServerVersion}} {{.SecurityOptions}}'
cat "$DI_OUT"
if [ "$BOUNDED_RC" -eq 0 ] && grep -qE '^[0-9]+\.[0-9]+' "$DI_OUT"; then
    ok "docker info works as the non-root guest user"
else
    bad "docker info failed as the non-root guest user"
fi
# The rootless engine reports name=rootless among its security options and
# populates none of the DOCKER* chains, so this is the check that the profile
# installed the engine the allowlist can actually hook into.
if grep -q 'name=rootless' "$DI_OUT"; then
    bad "the daemon is rootless; DOCKER-USER would not exist"
else
    ok "the daemon is rootful, which is what populates DOCKER-USER"
fi

printf -- '\n--- docker pull alpine:3 through the allowlist ---\n'
PULL_OUT="${TMP_ROOT}/docker-pull.out"
run_bounded 300 "$PULL_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    docker pull alpine:3
pull_rc=$BOUNDED_RC
tail -5 "$PULL_OUT"
if [ "$pull_rc" -eq 0 ]; then
    ok "docker pull alpine:3 succeeded, so the registry names are on the allowlist"
else
    bad "docker pull alpine:3 exited ${pull_rc}"
fi

printf -- '\n--- DOCKER-USER rule 1 ---\n'
DU_OUT="${TMP_ROOT}/docker-user.out"
dguest sudo iptables -S DOCKER-USER > "$DU_OUT" 2>&1
cat "$DU_OUT"
if [ "$(sed -n '2p' "$DU_OUT")" = "-A DOCKER-USER -j AGENTBOX-FWD" ]; then
    ok "DOCKER-USER rule 1 jumps to AGENTBOX-FWD"
else
    bad "DOCKER-USER rule 1 is not the AGENTBOX-FWD jump"
fi

printf -- '\n--- Docker chains are intact and ours sit beside them ---\n'
dguest sudo iptables -S 2>/dev/null | grep -E '^-N|^-P|^-A (FORWARD|DOCKER-USER)'

printf -- '\n--- container egress obeys the allowlist ---\n'
CEG_OUT="${TMP_ROOT}/container-egress.out"
dguest bash -c '
docker run --rm alpine:3 wget -T 5 -q -O /dev/null https://example.com 2>&1
echo "EXAMPLE_RC=$?"
docker run --rm alpine:3 wget -T 5 -q -O /dev/null https://api.anthropic.com/ 2>&1
echo "ANTHROPIC_RC=$?"
' > "$CEG_OUT" 2>&1
cat "$CEG_OUT"
# Positively, both halves. `if grep EXAMPLE_RC=0 then bad else ok` scored the
# ABSENCE of evidence as the pass: a regression that stopped every `docker run`
# from working at all — the socket-owner drop-in is exactly the kind of thing
# that could — would have printed this as a PASS on a box where containers were
# never tested. The line has to be there, and it has to say non-zero.
if ! grep -q '^EXAMPLE_RC=' "$CEG_OUT"; then
    bad "the container egress probe produced no EXAMPLE_RC line; containers were not tested"
elif grep -q '^EXAMPLE_RC=0' "$CEG_OUT"; then
    bad "a container reached https://example.com"
else
    ok "a container could not reach https://example.com"
fi
# busybox wget exits 1 on an HTTP error too, so "connected" means either a zero
# exit or an answer from the server. A refused connection says so explicitly.
if grep -q '^ANTHROPIC_RC=0' "$CEG_OUT" || grep -q 'server returned error' "$CEG_OUT"; then
    ok "a container reached https://api.anthropic.com/"
else
    bad "a container could not reach https://api.anthropic.com/"
fi

printf -- '\n--- two containers on a user-defined network reach each other ---\n'
C2C_OUT="${TMP_ROOT}/c2c.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell's.
run_bounded 300 "$C2C_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
set -e
docker network create abxnet >/dev/null 2>&1 || true
docker rm -f abxsrv >/dev/null 2>&1 || true
docker run -d --name abxsrv --network abxnet alpine:3 \
    sh -c "while true; do printf \"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nHELLO\" | nc -l -p 8000; done" >/dev/null
sleep 3
# $? of the docker run, not of the echo that used to sit between them: the
# old form always reported 0, so half the assertion below could never fail.
c2c_out=$(docker run --rm --network abxnet alpine:3 wget -T 5 -q -O - http://abxsrv:8000/ 2>&1); c2c_rc=$?
printf "%s\n" "$c2c_out"
echo "C2C_RC=$c2c_rc"
docker rm -f abxsrv >/dev/null 2>&1 || true
'
cat "$C2C_OUT"
if grep -q 'HELLO' "$C2C_OUT" && grep -q '^C2C_RC=0' "$C2C_OUT"; then
    ok "two containers on a user-defined network reached each other"
else
    bad "container-to-container traffic on a user-defined network did not work"
fi

printf -- '\n--- a compose stack, published on the forwarded port ---\n'
STACK_OUT="${TMP_ROOT}/stack.out"
run_bounded 600 "$STACK_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c "
set -e
rm -rf /tmp/abx-stack && mkdir -p /tmp/abx-stack
cat > /tmp/abx-stack/compose.yaml <<'YML'
services:
  web:
    image: python:3-alpine
    command: python -m http.server 8000
    ports:
      - \"127.0.0.1:${FORWARD_PORT}:8000\"
YML
cd /tmp/abx-stack
docker compose up -d
for i in \$(seq 1 30); do
    code=\$(curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:${FORWARD_PORT}/ 2>/dev/null || true)
    [ \"\$code\" = 200 ] && break
    sleep 2
done
echo \"GUEST_HTTP=\$code\"
"
cat "$STACK_OUT"
if grep -q '^GUEST_HTTP=200' "$STACK_OUT"; then
    ok "the compose stack answers at 127.0.0.1:${FORWARD_PORT} inside the guest"
else
    bad "the compose stack does not answer inside the guest"
fi

printf -- '\n--- and on the host, through the forwarded port ---\n'
HOST_HTTP=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
    HOST_HTTP=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FORWARD_PORT}/" 2>/dev/null || true)
    [ "$HOST_HTTP" = "200" ] && break
    sleep 2
done
printf 'host curl http://127.0.0.1:%s/ -> %s\n' "$FORWARD_PORT" "${HOST_HTTP:-<no answer>}"
if [ "$HOST_HTTP" = "200" ]; then
    ok "the forwarded port answers on the host at 127.0.0.1:${FORWARD_PORT}"
else
    bad "the forwarded port does not answer on the host"
fi

printf -- '\n--- the default holds: what --forward reaches, and what nothing reaches ---\n'
# Three claims are made in three places — lima/agent-box.yaml, README's Limits,
# and docs/decisions.md — that nothing the guest listens on is reachable from
# outside it unless --forward said so. `docker run -p N:80` publishes on
# 0.0.0.0, Docker DNATs the inbound packet in PREROUTING, and it is then
# FORWARDed rather than INPUTed: it never meets the INPUT DROP policy those
# claims rest on. AGENTBOX-FWD rule 1 is what makes them true, and this is the
# test of it. The forwarded twin is published exactly the same way, so the two
# differ only in whether the port was named at create time.
PUB_OUT="${TMP_ROOT}/published.out"
run_bounded 300 "$PUB_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c "
sudo iptables -S AGENTBOX-FWD | sed -n '2p' | sed 's/^/FWD_RULE1=/'
UPLINK=\$(ip route | awk '/^default/ {print \$5; exit}')
echo \"UPLINK=\$UPLINK\"
ip -4 -o addr show dev \"\$UPLINK\" | awk '{print \$4}' | cut -d/ -f1 | sed 's/^/GUEST_ADDR=/'
docker rm -f abx-unforwarded abx-forwarded >/dev/null 2>&1 || true
docker run -d --name abx-unforwarded -p ${UNFORWARDED_PORT}:80 python:3-alpine python -m http.server 80 >/dev/null
docker run -d --name abx-forwarded   -p ${FORWARD_PORT2}:80   python:3-alpine python -m http.server 80 >/dev/null
sleep 4
docker ps --format '{{.Names}} {{.Ports}}'
for i in \$(seq 1 15); do
    a=\$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:${UNFORWARDED_PORT}/ 2>/dev/null || true)
    b=\$(curl -sS -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:${FORWARD_PORT2}/ 2>/dev/null || true)
    [ \"\$a\" = 200 ] && [ \"\$b\" = 200 ] && break
    sleep 2
done
echo \"GUEST_UNFORWARDED=\$a\"
echo \"GUEST_FORWARDED=\$b\"
"
cat "$PUB_OUT"

# Rule 1, by shape. A published port reachable from nowhere proves nothing if
# the reason is that the container never came up.
if grep -qE '^FWD_RULE1=-A AGENTBOX-FWD -i [a-z0-9]+ -m conntrack --ctstate NEW -j DROP$' "$PUB_OUT"; then
    ok "AGENTBOX-FWD rule 1 drops NEW connections arriving on the uplink"
else
    bad "AGENTBOX-FWD rule 1 is not the inbound drop"
fi
if grep -q '^GUEST_UNFORWARDED=200' "$PUB_OUT"; then
    ok "the unforwarded container is published and answers inside the guest"
else
    bad "the unforwarded container does not answer inside the guest; the checks below would be vacuous"
fi
if grep -q '^GUEST_FORWARDED=200' "$PUB_OUT"; then
    ok "the forwarded container is published and answers inside the guest"
else
    bad "the forwarded container does not answer inside the guest"
fi

GUEST_ADDR=$(sed -n 's/^GUEST_ADDR=//p' "$PUB_OUT" | head -1)
printf 'the guest is at %s\n' "${GUEST_ADDR:-<unknown>}"
if [ -n "$GUEST_ADDR" ]; then
    VM_HTTP=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://${GUEST_ADDR}:${UNFORWARDED_PORT}/" 2>/dev/null || true)
    printf 'host curl http://%s:%s/ -> %s\n' "$GUEST_ADDR" "$UNFORWARDED_PORT" "${VM_HTTP:-<no answer>}"
    if [ "$VM_HTTP" = "200" ]; then
        bad "a published container port is reachable from the Mac at the VM's address"
    else
        ok "a published container port is NOT reachable from the Mac at the VM's address"
    fi
else
    bad "could not read the guest's address, so the VM-address check did not run"
fi

LOOP_HTTP=$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${UNFORWARDED_PORT}/" 2>/dev/null || true)
printf 'host curl http://127.0.0.1:%s/ -> %s\n' "$UNFORWARDED_PORT" "${LOOP_HTTP:-<no answer>}"
if [ "$LOOP_HTTP" = "200" ]; then
    bad "a port that was never named to --forward answers on the host"
else
    ok "a port that was never named to --forward does not answer on the host"
fi

# And the other half: --forward still works for the ORDINARY publish form, so
# rule 1 has not broken the one hole the design deliberately keeps. Lima serves
# a forwarded port over ssh, from inside the guest, so it never crosses FORWARD
# from the uplink — this is the assertion that says so out loud.
FWD2_HTTP=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
    FWD2_HTTP=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FORWARD_PORT2}/" 2>/dev/null || true)
    [ "$FWD2_HTTP" = "200" ] && break
    sleep 2
done
printf 'host curl http://127.0.0.1:%s/ -> %s\n' "$FORWARD_PORT2" "${FWD2_HTTP:-<no answer>}"
if [ "$FWD2_HTTP" = "200" ]; then
    ok "a 0.0.0.0-published port that WAS named to --forward answers on the host"
else
    bad "--forward no longer reaches a container published the ordinary way"
fi

printf -- '\n--- a daemon restart leaves no unfiltered window ---\n'
# ExecStartPost, not the 15-minute timer. `systemctl restart docker` returning
# means the hook has already run, so the jump must be back immediately — not
# eventually.
RESTART_OUT="${TMP_ROOT}/docker-restart.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell's.
run_bounded 300 "$RESTART_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
# The deletion is asserted, not swallowed. `|| true` on it meant that if the
# rule ever stopped matching this exact form, the chain would still hold the
# jump, the pre-restart print below would contain it, and the whole check would
# pass without the ExecStartPost hook having been exercised at all.
if sudo iptables -D DOCKER-USER -j AGENTBOX-FWD 2>/dev/null; then
    echo "DELETE_RC=0"
else
    echo "DELETE_RC=1"
fi
echo "--- jump deliberately removed ---"
sudo iptables -S DOCKER-USER
sudo systemctl restart docker
echo "RESTART_RC=$?"
echo "--- immediately after the restart returned ---"
# Rule 1 specifically, which is what the spec asks for and what the earlier
# check does. `-S` prints the chain declaration first, so the 2nd line is rule 1.
echo "POST_RULE1=$(sudo iptables -S DOCKER-USER | sed -n "2p")"
sudo iptables -S DOCKER-USER
docker run --rm alpine:3 echo CONTAINER_STILL_RUNS
'
cat "$RESTART_OUT"
if grep -q '^RESTART_RC=0' "$RESTART_OUT"; then
    ok "systemctl restart docker exited 0"
else
    bad "systemctl restart docker did not exit 0"
fi
if grep -q '^DELETE_RC=0' "$RESTART_OUT"; then
    ok "the AGENTBOX-FWD jump was really removed before the restart"
else
    bad "the jump could not be removed, so the restart check would prove nothing"
fi
if grep -qx 'POST_RULE1=-A DOCKER-USER -j AGENTBOX-FWD' "$RESTART_OUT"; then
    ok "DOCKER-USER rule 1 is the AGENTBOX-FWD jump as soon as the restart returned"
else
    bad "DOCKER-USER rule 1 is not the AGENTBOX-FWD jump after the restart"
fi
if grep -q 'CONTAINER_STILL_RUNS' "$RESTART_OUT"; then
    ok "a container still runs after the daemon restart"
else
    bad "no container could run after the daemon restart"
fi

printf -- '\n--- the hook fallback closes AGENTBOX-FWD inbound too ---\n'
# docker_hook has a second branch: when AGENTBOX-FWD is EMPTY it fills the chain
# itself rather than leaving it open. That branch is reached on a fresh
# --docker box's first daemon start and after the hard-close recovery, and it
# used to write only `! -o eth0 -j RETURN` plus the REJECT — closed for egress
# and wide open inbound, which is exactly the hole rule 1 exists to close, in
# exactly the window the hook exists to cover. Both builders now emit the pair
# from one function; this is the branch the full rebuild never reaches.
FALLBACK_OUT="${TMP_ROOT}/hook-fallback.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell's.
run_bounded 300 "$FALLBACK_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
sudo iptables -F AGENTBOX-FWD
echo "FLUSHED_RULE1=$(sudo iptables -S AGENTBOX-FWD | sed -n "2p")"
sudo systemctl restart docker
echo "FB_RULE1=$(sudo iptables -S AGENTBOX-FWD | sed -n "2p")"
echo "FB_RULE2=$(sudo iptables -S AGENTBOX-FWD | sed -n "3p")"
sudo iptables -S AGENTBOX-FWD
'
cat "$FALLBACK_OUT"
if grep -qx 'FLUSHED_RULE1=' "$FALLBACK_OUT"; then
    ok "AGENTBOX-FWD was really empty before the restart, so the fallback branch was taken"
else
    bad "AGENTBOX-FWD was not empty; the fallback branch was not exercised"
fi
if grep -qE '^FB_RULE1=-A AGENTBOX-FWD -i [a-z0-9]+ -m conntrack --ctstate NEW -j DROP$' "$FALLBACK_OUT"; then
    ok "the hook fallback leads with the inbound DROP, like the full rebuild"
else
    bad "the hook fallback rebuilt AGENTBOX-FWD without the inbound DROP"
fi
if grep -qE '^FB_RULE2=-A AGENTBOX-FWD ! -o [a-z0-9]+ -j RETURN$' "$FALLBACK_OUT"; then
    ok "the hook fallback puts the uplink RETURN second, after the drop"
else
    bad "the hook fallback's second rule is not the uplink RETURN"
fi

printf -- '\n--- a forced firewall rebuild leaves Docker chains intact ---\n'
# `restart`, not `start`: agent-box-firewall is a RemainAfterExit oneshot, so
# `start` on an already-active unit does nothing at all and would make this
# check vacuous. This is the case the old whole-table `iptables-restore` broke:
# it replaced the filter table every fifteen minutes and took Docker's chains
# with it.
REBUILD_OUT="${TMP_ROOT}/dk-rebuild.out"
run_bounded 300 "$REBUILD_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
sudo systemctl restart agent-box-firewall.service
echo "FW_RC=$?"
echo "--- DOCKER-FORWARD ---"
sudo iptables -S DOCKER-FORWARD
echo "--- DOCKER-USER ---"
sudo iptables -S DOCKER-USER
docker run --rm alpine:3 echo CONTAINER_AFTER_REBUILD
'
cat "$REBUILD_OUT"
if grep -q '^FW_RC=0' "$REBUILD_OUT"; then
    ok "the firewall rebuilt on an instance running Docker"
else
    bad "the firewall rebuild failed on an instance running Docker"
fi
if [ "$(sed -n '/--- DOCKER-FORWARD ---/,/--- DOCKER-USER ---/p' "$REBUILD_OUT" | grep -c '^-A DOCKER-FORWARD')" -gt 0 ]; then
    ok "DOCKER-FORWARD still holds Docker's own rules after the rebuild"
else
    bad "DOCKER-FORWARD was emptied by the rebuild"
fi
if grep -q -- '-A DOCKER-USER -j AGENTBOX-FWD' "$REBUILD_OUT"; then
    ok "the AGENTBOX-FWD jump survived the rebuild"
else
    bad "the AGENTBOX-FWD jump did not survive the rebuild"
fi
if grep -q 'CONTAINER_AFTER_REBUILD' "$REBUILD_OUT"; then
    ok "a container still runs after a firewall rebuild"
else
    bad "no container could run after a firewall rebuild"
fi

printf -- '\n--- firewall-check on the Docker instance ---\n'
DFW_OUT="${TMP_ROOT}/dk-firewall.out"
run_bounded 300 "$DFW_OUT" "$AGENTBOX" firewall-check "$DOCKER_REPO"
dfw_rc=$BOUNDED_RC
cat "$DFW_OUT"
if [ "$dfw_rc" -eq 0 ]; then ok "firewall-check exited 0 on the Docker instance"; else bad "firewall-check exited ${dfw_rc} on the Docker instance"; fi
for check in policy-drop policy-drop-v6 forward-drop out-chain-first allowlist-rule \
             allowlist-holds literal-ip-denied foreign-dns-denied egress-denied \
             anthropic-allowed github-allowed \
             uplink-not-bridge inbound-intact resolver-up resolver-conf \
             docker-user-jump docker-egress docker-allowed; do
    if grep -q "^PASS  ${check}" "$DFW_OUT"; then
        ok "firewall check ${check} (docker instance)"
    else
        bad "firewall check ${check} (docker instance)"
    fi
done

# ===========================================================================
step "12b. Node, Playwright and Rosetta"
# ===========================================================================

printf -- '--- node and npx ---\n'
NODE_OUT="${TMP_ROOT}/node.out"
"$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -lc 'node --version; npm --version' > "$NODE_OUT" 2>&1
cat "$NODE_OUT"
if grep -qE '^v22\.' "$NODE_OUT"; then
    ok "node --version is 22.x"
else
    bad "node --version is not 22.x"
fi

# The pin, read from the provisioner rather than restated here, so the two can
# never drift. `npx --yes playwright --version` resolves the `latest` dist-tag
# again at test time, so on its own it asserts nothing about the pin and would
# keep passing after 1.63.0 stopped being latest.
PLAYWRIGHT_PIN=$(sed -n 's/^PLAYWRIGHT_VERSION="\(.*\)"$/\1/p' "${BOX_DIR}/guest/provision.sh" | head -1)
printf 'the pin in guest/provision.sh is %s\n' "${PLAYWRIGHT_PIN:-<unread>}"
if [ -n "$PLAYWRIGHT_PIN" ]; then
    ok "guest/provision.sh carries a pinned Playwright version"
else
    bad "no PLAYWRIGHT_VERSION pin found in guest/provision.sh"
fi

PW_OUT="${TMP_ROOT}/playwright.out"
run_bounded 300 "$PW_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    bash -lc "npx --yes playwright@${PLAYWRIGHT_PIN} --version"
cat "$PW_OUT"
if grep -qiE "Version ${PLAYWRIGHT_PIN}" "$PW_OUT"; then
    ok "the pinned Playwright ${PLAYWRIGHT_PIN} resolves and runs in the guest"
else
    bad "playwright@${PLAYWRIGHT_PIN} did not report version ${PLAYWRIGHT_PIN}"
fi

# And that the pin is what provisioning actually used: the marker file
# install_playwright_deps writes names the version it ran.
PWMARK_OUT="${TMP_ROOT}/playwright-marker.out"
dguest bash -c 'cat /var/lib/agent-box/playwright-deps-installed 2>&1' > "$PWMARK_OUT" 2>&1
cat "$PWMARK_OUT"
if grep -q "playwright@${PLAYWRIGHT_PIN} install-deps" "$PWMARK_OUT"; then
    ok "install-deps was run from the pinned version, per its own marker"
else
    bad "the install-deps marker does not name playwright@${PLAYWRIGHT_PIN}"
fi

printf -- '\n--- a Playwright system library is installed ---\n'
NSS_OUT="${TMP_ROOT}/libnss3.out"
dguest bash -c 'dpkg -s libnss3 2>&1 | grep -E "^(Package|Status):"' > "$NSS_OUT" 2>&1
cat "$NSS_OUT"
if grep -q 'Status: install ok installed' "$NSS_OUT"; then
    ok "libnss3 is installed, so install-deps really ran"
else
    bad "libnss3 is not installed"
fi

printf -- '\n--- and a real browser download, through the allowlist, in deny mode ---\n'
# Installing the system libraries proves apt reached the archive. It does not
# prove the browser can be fetched, and those are different hosts: Playwright
# 1.63 asks cdn.playwright.dev and is answered 307 to storage.googleapis.com,
# which was off-list until a real download found it. Only a real download
# finds a redirect, so the suite now does one.
#
# `--with-deps` is deliberately NOT used: the deps are already installed and it
# would turn this into an apt test as well.
BROWSER_OUT="${TMP_ROOT}/browser-download.out"
run_bounded 900 "$BROWSER_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    bash -lc "rm -rf ~/.cache/ms-playwright && npx --yes playwright@${PLAYWRIGHT_PIN} install chromium 2>&1 | tail -20; echo \"INSTALL_RC=\${PIPESTATUS[0]}\""
browser_rc=$BOUNDED_RC
cat "$BROWSER_OUT"
if [ "$browser_rc" -eq 0 ] && grep -q '^INSTALL_RC=0' "$BROWSER_OUT"; then
    ok "playwright install chromium succeeded under the standing deny"
else
    bad "playwright install chromium failed under the standing deny (exit ${browser_rc})"
fi
# The binary, not just a zero exit: a cached or skipped install would also
# exit 0, and the point is that the bytes crossed the allowlist.
BROWSER_BIN_OUT="${TMP_ROOT}/browser-bin.out"
dguest bash -lc 'find ~/.cache/ms-playwright -maxdepth 3 -type f -name headless_shell -o -maxdepth 3 -type f -name chrome 2>/dev/null | head -3; du -sh ~/.cache/ms-playwright 2>/dev/null | tail -1' > "$BROWSER_BIN_OUT" 2>&1
cat "$BROWSER_BIN_OUT"
if grep -qE 'chrome|headless_shell' "$BROWSER_BIN_OUT"; then
    ok "a Chromium binary is on disk, so the download really crossed the allowlist"
else
    bad "no Chromium binary after the install"
fi
# And it runs. A downloaded browser that cannot start is a download, not a
# browser, and this is the one thing the Playwright half never proved.
BROWSER_RUN_OUT="${TMP_ROOT}/browser-run.out"
run_bounded 300 "$BROWSER_RUN_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- \
    bash -lc "cd /tmp && npx --yes playwright@${PLAYWRIGHT_PIN} screenshot --browser chromium about:blank /tmp/abx-shot.png 2>&1 | tail -5; ls -l /tmp/abx-shot.png 2>&1 | tail -1"
cat "$BROWSER_RUN_OUT"
if grep -q '/tmp/abx-shot.png' "$BROWSER_RUN_OUT" && ! grep -qi 'no such file' "$BROWSER_RUN_OUT"; then
    ok "the downloaded Chromium actually launches and renders"
else
    bad "the downloaded Chromium did not launch"
fi

printf -- '\n--- python3-venv and pip, for pytest-playwright ---\n'
PY3_OUT="${TMP_ROOT}/py3.out"
dguest bash -c 'python3 -m venv --help >/dev/null 2>&1 && echo VENV_OK; python3 -m pip --version 2>&1 | head -1' > "$PY3_OUT" 2>&1
cat "$PY3_OUT"
if grep -q 'VENV_OK' "$PY3_OUT"; then
    ok "python3 -m venv is available"
else
    bad "python3 -m venv is not available"
fi
if grep -q '^pip ' "$PY3_OUT"; then
    ok "python3 -m pip is available"
else
    bad "python3 -m pip is not available"
fi

printf -- '\n--- Rosetta runs a linux/amd64 image ---\n'
ROS_OUT="${TMP_ROOT}/rosetta.out"
run_bounded 300 "$ROS_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
ls -l /proc/sys/fs/binfmt_misc/ 2>&1 | head -5
docker run --rm --platform linux/amd64 alpine:3 uname -m
'
cat "$ROS_OUT"
if grep -qx 'x86_64' "$ROS_OUT"; then
    ok "a linux/amd64 container reports x86_64, so Rosetta is doing the work"
else
    bad "a linux/amd64 container did not report x86_64"
fi

printf -- '\n--- the names added to the base allowlist are reachable under it ---\n'
# Provisioning downloads with the firewall stopped, so a name it needed could
# be missing from allowlist.base and nothing would notice until an agent tried
# to use it later. These are checked from inside the running guest, under the
# standing deny. Any HTTP status counts: an answer proves the connection was
# permitted, and 401 or 403 from a registry is an answer.
AL_OUT="${TMP_ROOT}/allowlist-reach.out"
# Each name is tried up to six times. That is not papering over flakiness: the
# allowlist pins addresses and several of these names sit behind CDNs that hand
# out one address from a rotating pool, so a single attempt tests the pool
# lottery rather than the allowlist. Six attempts against a set holding most of
# a pool is the shape a real download has, and a name that is genuinely absent
# still fails all six.
# shellcheck disable=SC2016  # $u and $code must expand in the guest, not here.
run_bounded 600 "$AL_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
for u in http://ports.ubuntu.com/ \
         https://download.docker.com/linux/ubuntu/gpg \
         https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt \
         https://cdn.playwright.dev/ \
         https://storage.googleapis.com/ \
         https://ghcr.io/v2/ \
         https://pkg-containers.githubusercontent.com/ \
         https://production.cloudflare.docker.com/ \
         https://production.cloudfront.docker.com/ \
         https://auth.docker.io/ \
         https://registry-1.docker.io/v2/; do
    code=000
    for _try in 1 2 3 4 5 6; do
        code=$(curl -sS -m 12 -o /dev/null -w "%{http_code}" "$u" 2>/dev/null || true)
        [ -n "$code" ] && [ "$code" != 000 ] && break
        sleep 2
    done
    # Six failures means the pinned address is not one this name is answering
    # on. For most hosts that means the entry is missing, which is the defect
    # this check exists to find. For a CDN that hands out one address from a
    # rotating pool it can also just mean the pool moved since the last rebuild,
    # and the documented remedy for that is a rebuild — daily-use.md tells the
    # operator to run `agentbox firewall-check`, which restarts this very unit.
    # So the retry runs the remedy and tries again: a name that is genuinely
    # absent still fails, and this asserts that the advice we give actually
    # works.
    # Only the host the retry was written for. Applied to all ten, a genuinely
    # missing entry — the defect this check exists to find — paid a firewall
    # restart plus six more twelve-second attempts before reporting, and ten
    # such hosts ran past the bound on this step, at which point run_bounded
    # kills it and nothing has been written at all.
    # (No apostrophes below this line: the whole block is one single-quoted
    # argument to bash -c, and one would end it.)
    case "$u" in *cdn.playwright.dev*) retry_this=1 ;; *) retry_this=0 ;; esac
    if [ "${code:-000}" = 000 ] && [ "$retry_this" -eq 1 ]; then
        printf "REBUILD-RETRY %s\n" "$u"
        sudo systemctl restart agent-box-firewall.service >/dev/null 2>&1 || true
        for _try in 1 2 3 4 5 6; do
            code=$(curl -sS -m 12 -o /dev/null -w "%{http_code}" "$u" 2>/dev/null || true)
            [ -n "$code" ] && [ "$code" != 000 ] && break
            sleep 3
        done
    fi
    printf "REACH %s %s\n" "${code:-000}" "$u"
done
'
# REBUILD-RETRY too, or the evidence that the documented remedy was tried is
# filtered out of the displayed output while sitting in the file.
al_rc=$BOUNDED_RC
grep -E '^(REACH|REBUILD-RETRY)' "$AL_OUT" || cat "$AL_OUT"
# Its own status, so a kill at the bound is reported as itself rather than as
# ten reachability failures with no output behind them.
if [ "$al_rc" -eq 0 ]; then
    ok "the reachability probe completed within its bound"
else
    bad "the reachability probe exited ${al_rc} (124 means it hit run_bounded's limit)"
fi
# The three added last are the ones the review found unexercised: the two Docker
# Hub blob CDNs (one of which was added only after a real pull was redirected to
# it and refused) and the ghcr blob host, whose entry the allowlist's own comment
# flags as community-sourced.
for host in ports.ubuntu.com download.docker.com nodejs.org cdn.playwright.dev \
            storage.googleapis.com ghcr.io \
            auth.docker.io registry-1.docker.io pkg-containers.githubusercontent.com \
            production.cloudflare.docker.com production.cloudfront.docker.com; do
    if grep -E "^REACH [1-5][0-9][0-9] " "$AL_OUT" | grep -q -- "${host}"; then
        ok "allowlisted and reachable: ${host}"
    elif [ "$host" = cdn.playwright.dev ]; then
        # Advisory, and only this one host. The box does not promise that this
        # name is reachable at an arbitrary later moment, and the check was
        # asserting something stronger than the design offers.
        #
        # It is an Azure Front Door endpoint answering with a single A record on
        # a near-zero TTL, out of a pool it rotates through faster than any
        # rebuild can sample. Measured from the host, six lookups in thirty
        # seconds returned five different addresses across two unrelated /16s.
        # The allowlist pins addresses; one resolution pass cannot hold that.
        #
        # What the box does promise still holds and is still tested elsewhere:
        # the name is on the allowlist, and Playwright's browsers are fetched
        # during provisioning with the network open. An agent that needs a
        # browser later has the documented remedy — `agentbox firewall-check`,
        # which rebuilds — and the retry above runs exactly that before giving
        # up, so a WARN here means the remedy did not help either.
        #
        # api.anthropic.com and github.com stay hard: they are not behind a
        # pool like this and the box does promise them.
        adv "advisory: ${host} did not answer, even after a rebuild — see the address-pinning entry in docs/decisions.md"
    else
        bad "allowlisted but NOT reachable: ${host}"
    fi
done

printf -- '\n--- a container resolves through the guest resolver, and feeds it ---\n'
# Before this, a container inherited the daemon's resolver and went straight to
# the upstream, so its lookups never passed through dnsmasq: a suffix line
# worked in the guest and silently did not work inside a container, which is
# the thing the guest exists to run. daemon.json points containers at the
# bridge address and the forward chain permits DNS to that address only.
CDNS_OUT="${TMP_ROOT}/container-dns.out"
# shellcheck disable=SC2016  # guest expansions.
run_bounded 300 "$CDNS_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c "
set -u
echo \"DAEMON_DNS=\$(sudo sed -n 's/.*\"dns\".*\\[\"\\([0-9.]*\\)\".*/\\1/p' /etc/docker/daemon.json | head -1)\"
echo \"CONTAINER_RESOLV=\$(docker run --rm alpine:3 cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ {print \$2; exit}')\"
sudo ipset flush ${IPSET_RESOLVED_NAME}
echo \"SET_BEFORE=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -c '^add ' || true)\"
docker run --rm alpine:3 nslookup ${SUFFIX_HOST} >/dev/null 2>&1 || true
sleep 2
echo \"SET_AFTER=\$(sudo ipset save ${IPSET_RESOLVED_NAME} | grep -c '^add ' || true)\"
# The status of the wget, not of the tail that was reading its output. A bare
# dollar-question after a pipeline is the LAST command status, so the old form
# read tail exit status, which is 0 whatever the container did: the assertion
# could not fail.
out=\$(docker run --rm alpine:3 wget -T 8 -q -O /dev/null https://${SUFFIX_HOST}/ 2>&1); rc=\$?
printf '%s\\n' \"\$out\" | tail -1
echo \"CONTAINER_FETCH=\$rc\"

# And an OFF-list host must fail for the firewall's reason, not because DNS
# broke. busybox says 'bad address' when it could not resolve and
# 'can't connect' or 'Connection refused' when the packet was refused; only the
# second proves the allowlist did the work, and reading them as the same thing
# would let a total DNS outage pass as containment.
oout=\$(docker run --rm alpine:3 wget -T 8 -q -O /dev/null https://example.com/ 2>&1); orc=\$?
echo \"OFFLIST_RC=\$orc\"
if printf '%s' \"\$oout\" | grep -qi 'bad address'; then
    echo 'OFFLIST_REASON=dns'
elif printf '%s' \"\$oout\" | grep -qiE \"can't connect|refused|unreachable|prohibited\"; then
    echo 'OFFLIST_REASON=refused'
elif [ \"\$orc\" -eq 0 ]; then
    echo 'OFFLIST_REASON=reached'
else
    echo \"OFFLIST_REASON=other: \$(printf '%s' \"\$oout\" | tr '\\n' ' ')\"
fi
"
cat "$CDNS_OUT"
if grep -qE '^CONTAINER_RESOLV=172\.' "$CDNS_OUT"; then
    ok "a container resolves through the guest's own resolver, not the upstream"
else
    bad "a container is not pointed at the guest resolver"
fi
if grep -q '^SET_BEFORE=0' "$CDNS_OUT" && grep -qE '^SET_AFTER=[1-9]' "$CDNS_OUT"; then
    ok "a container's lookup feeds the resolved set, so suffix lines work inside containers"
else
    bad "a container's lookup did not feed the set"
fi
if grep -q '^CONTAINER_FETCH=0' "$CDNS_OUT"; then
    ok "and the container then reaches the suffix-matched host"
else
    bad "the container could not reach the suffix-matched host"
fi
if grep -q '^OFFLIST_REASON=refused' "$CDNS_OUT"; then
    ok "an off-list host is refused for the firewall's reason, not a DNS failure"
elif grep -q '^OFFLIST_REASON=dns' "$CDNS_OUT"; then
    bad "the off-list host failed to RESOLVE; that is not containment, it is broken DNS"
elif grep -q '^OFFLIST_REASON=reached' "$CDNS_OUT"; then
    bad "a container reached an off-list host"
else
    bad "the off-list probe was inconclusive: $(sed -n 's/^OFFLIST_REASON=//p' "$CDNS_OUT")"
fi

printf -- '\n--- a real pull from ghcr.io, not just a reachable /v2/ ---\n'
# `https://ghcr.io/v2/` answering 401 proves the registry API is reachable; it
# does NOT prove a layer can be fetched, because the blobs come from
# pkg-containers.githubusercontent.com. Nothing in the suite pulled from ghcr,
# so that entry was carried on a community-sourced comment. distroless/static is
# a few hundred kilobytes and has a linux/arm64 manifest.
GHCR_OUT="${TMP_ROOT}/ghcr-pull.out"
run_bounded 300 "$GHCR_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
docker rmi ghcr.io/distroless/static:latest >/dev/null 2>&1 || true
if docker pull -q ghcr.io/distroless/static:latest; then echo "GHCR_PULL_RC=0"; else echo "GHCR_PULL_RC=1"; fi
docker image inspect ghcr.io/distroless/static:latest --format "GHCR_ARCH={{.Architecture}}" 2>&1 | tail -1
'
cat "$GHCR_OUT"
if grep -q '^GHCR_PULL_RC=0' "$GHCR_OUT"; then
    ok "a real layer pull from ghcr.io succeeded through the allowlist"
else
    bad "pulling from ghcr.io failed; ghcr.io and pkg-containers.githubusercontent.com are on the allowlist but untested until now"
fi

printf -- '\n--- and a name that is not on it still is not ---\n'
NAL_OUT="${TMP_ROOT}/allowlist-negative.out"
dguest bash -c 'curl -sS -m 8 -o /dev/null -w "%{http_code}" https://cdn.quay.io/ 2>&1; echo ""' > "$NAL_OUT" 2>&1
cat "$NAL_OUT"
if grep -qE '^(000)?$|Could not|refused|prohibited|unreachable|Failed' "$NAL_OUT"; then
    ok "cdn.quay.io, left commented out in allowlist.base, is refused"
else
    bad "cdn.quay.io answered although it is not on the allowlist"
fi

printf -- '\n--- tear the stack down ---\n'
dguest bash -c 'cd /tmp/abx-stack && docker compose down 2>&1 | tail -2; docker network rm abxnet >/dev/null 2>&1; true'

# ===========================================================================
step "12bb. an empty allowlist is a FAILURE, not a green box with no egress"
# ===========================================================================
#
# Finding T2. Making the outbound probes advisory left the fatal set with no
# member that asserts the allowlist permits anything: `allowlist-rule` checks
# that the CHAIN references the set, which is equally true of a set holding
# nothing. A rebuild during a partial DNS failure could therefore swap in a set
# with the GitHub ranges and little else, exit 0, and leave every signal green
# on a box where no agent can reach the model API.
#
# The new check reads what the last rebuild recorded and asks the kernel whether
# the live set still holds it — local, no network, and it can only fail on
# affirmative evidence. This empties the set and asserts it says so.

EMPTY_OUT="${TMP_ROOT}/empty-allowlist.out"
# shellcheck disable=SC2016  # every expansion here is the guest, not this shell.
run_bounded 300 "$EMPTY_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
set -u
# The 15-minute refresh timer is live for the whole smoke, and this step spends
# twenty to forty seconds with the allowlist deliberately empty. A tick in that
# window refills the set and rewrites the record, --verify-only then correctly
# exits 0, and the step reports "verify passed on a box whose allowlist holds
# nothing" — the precise opposite of what happened. Roughly one run in
# twenty-five, on an assertion whose entire value is being trusted when it
# fires. So the timer is suspended for the duration and started again below.
sudo systemctl stop agent-box-firewall.timer
echo "TIMER_STOPPED=$(systemctl is-active agent-box-firewall.timer || true)"
echo "RECORDED_CRIT=$(sudo awk "/^api.anthropic.com /" /run/agent-box-firewall-resolved | wc -l | tr -d " ")"
sudo ipset flush allowed-domains
echo "SET_ENTRIES=$(sudo ipset save allowed-domains | grep -c "^add " || true)"
sudo /opt/agent-box/guest/init-firewall.sh --verify-only > /tmp/abx-empty-verify.log 2>&1
echo "VERIFY_RC=$?"
# Sampled again at the verdict, not only before it: the guard has to hold over
# the window it guards, not at one instant before it.
echo "SET_ENTRIES_AFTER=$(sudo ipset save allowed-domains | grep -c "^add " || true)"
grep -E "^(PASS|FAIL|WARN)  allowlist-holds" /tmp/abx-empty-verify.log || echo "NO-ALLOWLIST-HOLDS-LINE"
echo "--- and the box is repaired before anything else runs ---"
# Egress has to be opened by hand FIRST, and that is a real property rather
# than a test artefact: an emptied allowlist is self-sealing. The rebuild needs
# api.github.com for the meta ranges, api.github.com is only reachable through
# the ipset, and the ipset is what was emptied — so the unit fails, which is
# what a naive restart measured.
#
# And the POLICY is not what refuses it. AGENTBOX-OUT is jumped from OUTPUT
# rule 1 and ends in REJECT, so the packet is rejected inside the chain and
# never reaches the policy at all; setting OUTPUT to ACCEPT on its own changed
# nothing, which the second attempt measured. The chain has to be flushed too.
# This is exactly what open_network_for_provisioning does, for the same reason.
sudo iptables -w 5 -P OUTPUT ACCEPT
sudo iptables -w 5 -F AGENTBOX-OUT
echo "OPENED=$(curl -sS -m 10 -o /dev/null -w "%{http_code}" https://api.github.com/meta 2>/dev/null || true)"
sudo systemctl restart agent-box-firewall.service
echo "REPAIR_RC=$?"
sudo /opt/agent-box/guest/init-firewall.sh --verify-only > /tmp/abx-repair-verify.log 2>&1
echo "REVERIFY_RC=$?"
grep -E "^(PASS|FAIL)  allowlist-holds" /tmp/abx-repair-verify.log || true
sudo systemctl start agent-box-firewall.timer
echo "TIMER_RESTARTED=$(systemctl is-active agent-box-firewall.timer || true)"
'
cat "$EMPTY_OUT"

if grep -qE '^RECORDED_CRIT=[1-9]' "$EMPTY_OUT"; then
    ok "the rebuild recorded what it resolved for api.anthropic.com"
else
    bad "no recorded resolution for api.anthropic.com; the new check has nothing to read"
fi
if grep -q '^TIMER_STOPPED=inactive' "$EMPTY_OUT"; then
    ok "the refresh timer was suspended, so no tick can refill the set mid-step"
else
    bad "the refresh timer was not suspended; this step can report a false failure"
fi
if grep -q '^SET_ENTRIES=0' "$EMPTY_OUT"; then
    ok "the live set was really emptied, so the check below is not vacuous"
else
    bad "the live set was not emptied"
fi
# NOT asserted as still empty at the end, and the reason is the resolver: every
# name verify() itself looks up is fed straight back into the set by dnsmasq, so
# the set legitimately refills DURING the verification. What makes the check
# below deterministic is ordering rather than emptiness — allowlist-holds runs
# before any of verify's own outbound probes, so it reads the set while it is
# still empty. The count here is reported for the reader, not judged.
printf 'entries in the set after the verify: %s (refilled by the resolver; expected)\n' \
    "$(sed -n 's/^SET_ENTRIES_AFTER=//p' "$EMPTY_OUT" | head -1)"
if grep -q '^VERIFY_RC=0' "$EMPTY_OUT"; then
    bad "verify passed on a box whose allowlist holds nothing"
else
    ok "verify FAILED on a box whose allowlist holds nothing"
fi
if grep -q '^FAIL  allowlist-holds' "$EMPTY_OUT"; then
    ok "and it named the allowlist as the reason"
else
    bad "verify failed without naming the allowlist"
fi
if grep -qE '^OPENED=[1-5][0-9][0-9]' "$EMPTY_OUT"; then
    ok "flushing AGENTBOX-OUT and opening the policy really restores egress"
else
    bad "egress was not open after the manual recovery, so the rebuild could not have worked"
fi
if grep -q '^REPAIR_RC=0' "$EMPTY_OUT"; then
    ok "opening egress and rebuilding repairs the box"
else
    bad "the repair rebuild failed"
fi
if grep -q '^REVERIFY_RC=0' "$EMPTY_OUT" && grep -q '^PASS  allowlist-holds' "$EMPTY_OUT"; then
    ok "and allowlist-holds passes again afterwards"
else
    bad "allowlist-holds still fails after the repair"
fi
if grep -q '^TIMER_RESTARTED=active' "$EMPTY_OUT"; then
    ok "the refresh timer is running again, so the box is left as it was found"
else
    bad "the refresh timer was left stopped; every later step now has no 15-minute rebuild"
fi

# ===========================================================================
step "12c. the rebuild lock: a second writer waits, times out, and touches nothing"
# ===========================================================================
#
# Finding T7. Every green run so far took the lock uncontended, so the only
# branch of take_fw_lock that had ever executed was the success path — and the
# three that decide what happens when two writers meet are the entire reason
# the lock exists. AGENT_BOX_FW_LOCK and AGENT_BOX_LOCK_WAIT are here for this.
#
# A background `flock` on the real lock file stands in for a rebuild in
# progress. Two claims: a rebuild that cannot get the lock exits 1 and leaves
# the standing ruleset byte-identical, and the hook proceeds anyway with a WARN,
# because blocking there would block the daemon starting.

LOCK_OUT="${TMP_ROOT}/lock-contention.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell.
run_bounded 300 "$LOCK_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
set -u
LOCK=/run/agent-box-firewall.lock
BEFORE=$(sudo iptables -w 5 -S AGENTBOX-OUT | md5sum | cut -d" " -f1)
echo "BEFORE_MD5=$BEFORE"

# Hold it for 25s. The redirection has to happen INSIDE sudo: the lock file is
# created by the firewall script as root, so the guest user cannot open it for
# writing and `9>$LOCK` out here would fail before flock ever ran.
sudo sh -c "exec 9>$LOCK; flock -x 9; sleep 25" &
HOLDER=$!
sleep 3
echo "HOLDER_ALIVE=$(kill -0 $HOLDER 2>/dev/null && echo yes || echo no)"

echo "--- a rebuild, with a 5s patience ---"
sudo env AGENT_BOX_LOCK_WAIT=5 /opt/agent-box/guest/init-firewall.sh > /tmp/abx-lock-rebuild.log 2>&1
echo "REBUILD_RC=$?"
grep -c "has held" /tmp/abx-lock-rebuild.log | sed "s/^/REBUILD_SAW_LOCK_MSG=/"

echo "--- the hook, with a 3s patience ---"
sudo env AGENT_BOX_LOCK_WAIT_HOOK=3 /opt/agent-box/guest/init-firewall.sh --docker-hook > /tmp/abx-lock-hook.log 2>&1
echo "HOOK_RC=$?"
grep -c "proceeding without the rebuild lock" /tmp/abx-lock-hook.log | sed "s/^/HOOK_SAW_WARN=/"

wait $HOLDER 2>/dev/null || true
AFTER=$(sudo iptables -w 5 -S AGENTBOX-OUT | md5sum | cut -d" " -f1)
echo "AFTER_MD5=$AFTER"
echo "--- rebuild log ---"; tail -5 /tmp/abx-lock-rebuild.log
echo "--- hook log ---";    tail -5 /tmp/abx-lock-hook.log
'
cat "$LOCK_OUT"

if grep -q '^HOLDER_ALIVE=yes' "$LOCK_OUT"; then
    ok "the stand-in writer is holding the lock, so the checks below are not vacuous"
else
    bad "the stand-in writer did not hold the lock; the contention checks proved nothing"
fi
if grep -q '^REBUILD_RC=1' "$LOCK_OUT"; then
    ok "a rebuild that cannot take the lock exits 1"
else
    bad "a rebuild that cannot take the lock did not exit 1"
fi
if grep -q '^REBUILD_SAW_LOCK_MSG=1' "$LOCK_OUT"; then
    ok "it said why: another rebuild has held the lock"
else
    bad "the rebuild did not report the lock as the reason"
fi
LOCK_BEFORE=$(sed -n 's/^BEFORE_MD5=//p' "$LOCK_OUT" | head -1)
LOCK_AFTER=$(sed -n 's/^AFTER_MD5=//p' "$LOCK_OUT" | head -1)
printf 'AGENTBOX-OUT before=%s after=%s\n' "${LOCK_BEFORE:-?}" "${LOCK_AFTER:-?}"
if [ -n "$LOCK_BEFORE" ] && [ "$LOCK_BEFORE" = "$LOCK_AFTER" ]; then
    ok "the refused rebuild left the standing ruleset byte-identical"
else
    bad "the standing ruleset changed while a rebuild was refused the lock"
fi
if grep -q '^HOOK_RC=0' "$LOCK_OUT"; then
    ok "the hook still succeeds when it cannot take the lock"
else
    bad "the hook failed when it could not take the lock; that would stop docker.service"
fi
if grep -q '^HOOK_SAW_WARN=1' "$LOCK_OUT"; then
    ok "the hook said it was proceeding without the lock"
else
    bad "the hook did not warn that it proceeded without the lock"
fi

# ===========================================================================
step "12d. a --docker box comes back from a stop/start without deadlocking"
# ===========================================================================
#
# The regression test for a boot deadlock that this suite could not have caught,
# because it only ever created a --docker instance and destroyed it — step 9's
# stop/start runs on the plain box.
#
# docker.service carries `After=agent-box-firewall.service`, so at boot the
# daemon is queued behind the firewall unit. docker.socket is listening anyway,
# so an unbounded `docker image inspect` inside verify() connected, systemd
# queued the docker.service start job that could not run until the firewall unit
# finished, and the unit waited for a reply that could never come. Measured
# before the fix: ten minutes in, `docker.service start waiting` behind
# `agent-box-firewall.service start running`, multi-user.target blocked,
# TimeoutStartUSec=infinity, and guest/lib.sh refusing every run because a unit
# stuck in `activating` is not active.
#
# So the assertions below are about the unit and the job queue, not about a
# symptom: a box can look reachable while its boot is still wedged.

DK_STOP_OUT="${TMP_ROOT}/dk-stop.out"
run_bounded 300 "$DK_STOP_OUT" "$AGENTBOX" stop "$DOCKER_INSTANCE"
dk_stop_rc=$BOUNDED_RC
tail -3 "$DK_STOP_OUT"
if [ "$dk_stop_rc" -eq 0 ]; then
    ok "agentbox stop exited 0 on the Docker instance"
else
    bad "agentbox stop exited ${dk_stop_rc} on the Docker instance"
fi

DK_START_OUT="${TMP_ROOT}/dk-start.out"
DK_START_T0=$(date +%s)
run_bounded 900 "$DK_START_OUT" "$AGENTBOX" start "$DOCKER_REPO"
dk_start_rc=$BOUNDED_RC
printf 'docker-profile restart took %s seconds\n' "$(( $(date +%s) - DK_START_T0 ))"
tail -3 "$DK_START_OUT"
if [ "$dk_start_rc" -eq 0 ]; then
    ok "agentbox start exited 0 on the Docker instance"
else
    bad "agentbox start exited ${dk_start_rc} on the Docker instance"
fi

# Independently of what limactl reported. The guest-side facts below are the
# deadlock test; `agentbox start`'s exit status also depends on Lima's own
# readiness probes, which is a different thing and is asserted separately above.
dk_up=0
for _try in $(seq 1 30); do
    if "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- true >/dev/null 2>&1; then
        dk_up=1; break
    fi
    sleep 5
done
if [ "$dk_up" -eq 1 ]; then
    ok "the Docker instance answers again after the restart"
else
    bad "the Docker instance never answered after the restart"
fi

DK_BOOT_OUT="${TMP_ROOT}/dk-boot.out"
# shellcheck disable=SC2016  # every expansion here is the guest's, not this shell's.
run_bounded 180 "$DK_BOOT_OUT" "$LIMACTL" shell --workdir /work "$DOCKER_INSTANCE" -- bash -c '
echo "FW_STATE=$(systemctl is-active agent-box-firewall.service)"
echo "DOCKER_STATE=$(systemctl is-active docker.service)"
echo "QUEUED_JOBS=$(systemctl list-jobs --no-legend 2>/dev/null | wc -l | tr -d " ")"
systemctl list-jobs --no-pager 2>&1 | sed "s/^/JOBS: /"
# The exact expression guest/lib.sh gates every run on.
if systemctl is-active --quiet agent-box-firewall.service; then
    echo "RUN_GATE=passes"
else
    echo "RUN_GATE=fails"
fi
echo "--- the docker checks on this boot ---"
sudo journalctl -u agent-box-firewall.service -b --no-pager 2>&1 \
    | grep -E "docker-user-jump|docker-egress|docker-allowed" | tail -6
'
cat "$DK_BOOT_OUT"

if grep -q '^FW_STATE=active' "$DK_BOOT_OUT"; then
    ok "the firewall unit is active after the restart, not activating or failed"
else
    bad "the firewall unit is not active after the restart: $(sed -n 's/^FW_STATE=//p' "$DK_BOOT_OUT")"
fi
if grep -q '^DOCKER_STATE=active' "$DK_BOOT_OUT"; then
    ok "docker.service started after the restart"
else
    bad "docker.service did not start after the restart"
fi
if grep -q '^QUEUED_JOBS=0' "$DK_BOOT_OUT"; then
    ok "systemd has no jobs still waiting, so the boot completed"
else
    bad "systemd still has queued jobs after the restart, which is the deadlock's signature"
fi
if grep -q '^RUN_GATE=passes' "$DK_BOOT_OUT"; then
    ok "the run precondition guest/lib.sh applies passes immediately after start"
else
    bad "the run precondition fails after start; agentbox run would refuse on a protected box"
fi
# SKIP at boot is the correct outcome, PASS is correct once the daemon is up,
# and FAIL is the bug. Any FAIL among the three is what put the unit in failed.
if grep -qE '^(FAIL)  docker-(user-jump|egress|allowed)' "$DK_BOOT_OUT"; then
    bad "a container check FAILED on the boot-time firewall run"
else
    ok "no container check FAILED on the boot-time firewall run"
fi

# And the thing the deadlock actually broke, end to end: agent-run's own
# precondition. RUN_GATE above evaluates the exact expression guest/lib.sh
# applies, which is the load-bearing assertion. This one drives the real command
# and asserts the firewall is not what it complains about — the box has no
# token, so it must stop at the token and nowhere else.
DK_RUN_OUT="${TMP_ROOT}/dk-run.out"
printf 'Do nothing.\n' > "${TMP_ROOT}/dk-noop-brief.md"
run_bounded 240 "$DK_RUN_OUT" "$AGENTBOX" run "$DOCKER_REPO" "${TMP_ROOT}/dk-noop-brief.md" --wait
cat "$DK_RUN_OUT"
if grep -q 'egress firewall is not active' "$DK_RUN_OUT"; then
    bad "agent-run refused on the firewall right after a restart, which is the deadlock's symptom"
else
    ok "agent-run did not refuse on the firewall after a restart"
fi
if grep -q 'no token at' "$DK_RUN_OUT"; then
    ok "agent-run got as far as the token check on the restarted Docker box"
else
    bad "agent-run stopped somewhere other than the token check"
fi

# ===========================================================================
step "13. destroy the Docker instance"
# ===========================================================================

"$AGENTBOX" destroy "$DOCKER_INSTANCE"
rc=$?
if [ "$rc" -eq 0 ]; then ok "agentbox destroy exited 0 for the Docker instance"; else bad "agentbox destroy exited ${rc} for the Docker instance"; fi

printf -- '\n--- limactl list ---\n'
"$LIMACTL" list 2>&1
if "$LIMACTL" list --quiet 2>/dev/null | grep -qxF "$DOCKER_INSTANCE"; then
    bad "${DOCKER_INSTANCE} is still listed after destroy"
else
    ok "${DOCKER_INSTANCE} is gone from limactl list"
fi

# ===========================================================================
# The suite's own ending, written out rather than calling summarise_and_exit.
# Measured with shellcheck 0.11.0: with this replaced by the call, shellcheck
# loses track of the two functions this file invokes indirectly — `cleanup`
# through the EXIT trap and `guest_summary` through run_bounded — and reports
# SC2329 "never invoked" for both. The helper is what the three EARLY exits use,
# which is what stops a fourth copy of this block appearing in the middle of the
# file; the last three lines of a test suite are not that risk.
hr
printf 'RESULT: %s passed, %s failed, %s advisory\n' "$PASS" "$FAIL" "$WARN"
hr
[ "$FAIL" -eq 0 ]
