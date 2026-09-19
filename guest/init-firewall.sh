#!/bin/bash
#
# agent-box — default-deny egress for the guest and for its containers.
#
# Derived from Anthropic's reference devcontainer firewall,
# https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh
# (fetched 2026-09-04). The structure has since diverged substantially; the
# differences that matter are listed in docs/decisions.md.
#
# The central property: THE LIVE RULESET IS NEVER REMOVED. The reference script
# flushes, rebuilds incrementally, and sets the policy to DROP at the end, which
# means every error path between the flush and the end leaves the machine wide
# open — and the rebuild itself runs with no rules at all. Here the new state is
# built off to one side and swapped in atomically:
#
#   * addresses go into a second ipset which is `ipset swap`ped with the live
#     one only once it is fully populated;
#   * rules go into three chains this script owns outright — AGENTBOX-IN,
#     AGENTBOX-OUT and AGENTBOX-FWD — which are replaced in one
#     `iptables-restore --noflush` transaction.
#
# The second property, new with the Docker profile: THIS SCRIPT OWNS ITS OWN
# CHAINS AND NOTHING ELSE. Docker installs six chains of its own (DOCKER,
# DOCKER-USER, DOCKER-FORWARD, DOCKER-CT, DOCKER-BRIDGE, DOCKER-INTERNAL) and
# does not recreate them if something else empties them — only a daemon restart
# does. An `iptables-restore` without `--noflush` replaces the entire filter
# table, so the previous version of this script silently cut every container off
# the network on each 15-minute tick once Docker was installed. `--noflush` with
# a file that declares only our own chains replaces exactly those and leaves
# every other chain, including Docker's, untouched. Verified in the guest, not
# assumed: see docs/decisions.md.
#
# So the rebuild runs *under* the standing deny. It needs only DNS to the
# configured resolvers and the GitHub ranges, both of which the standing ruleset
# already permits from the previous run. On the very first run there is no
# ruleset yet and the machine is briefly open, which is unavoidable and is why
# provisioning installs everything before this ever runs.
#
# Runs as root, from agent-box-firewall.service and its 15-minute timer, and —
# with --docker-hook — from docker.service's ExecStartPost.

# -E (errtrace) matters: without it the ERR trap installed below is NOT
# inherited by shell functions, command substitutions or subshells, and the
# whole fail-closed argument rests on that trap.
set -eEuo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
CONFIG_DIR="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
ALLOWLIST_BASE="${BOX_DIR}/guest/allowlist.base"
# Mounted read-only from the host's ~/.config/agent-box. Optional.
ALLOWLIST_LOCAL="${CONFIG_DIR}/allowlist.local"

# Overridable so that test/smoke.sh can drive the failure path deliberately.
GH_META_URL="${AGENT_BOX_GH_META_URL:-https://api.github.com/meta}"

IPSET_NAME="allowed-domains"
IPSET_TMP="allowed-domains-new"
# What the resolver feeds, kept apart from what the rebuild builds.
#
# One set with two populations distinguished by their timeout was the first
# design and it was wrong in two ways that only show up later. Removing a
# suffix from the allowlist did not remove reach, because the preserve loop
# carried its addresses forward for ever; and the read-then-swap had a window
# in which an address added between the two was dropped. Two sets, referenced
# by the same accept rule, have neither problem: the rebuild owns one and
# never touches the other, and "stop allowing this" is a flush.
IPSET_RESOLVED="allowed-resolved"
# Entries live an hour. Nothing renews them on a cache hit, which is why
# dnsmasq's own cache must expire first — see DNS_CACHE_TTL below.
RESOLVED_TTL=3600
# A quarter of the entry lifetime. The rule this enforces is worth stating on
# its own: dnsmasq feeds the set only when it FORWARDS an answer, so if its
# cache outlived the set entry there would be a window in which the name
# resolves from cache, nothing is re-added, and the host has silently gone
# dark. Cache TTL strictly less than entry TTL, always.
DNS_CACHE_TTL=900

# --- the egress mode ----------------------------------------------------------
#
# One per box, chosen at create and changed only by `agentbox egress`. The file
# is the guest's copy of the record the host also keeps; provisioning writes it
# once and never overwrites it, so a mode changed after create survives every
# later `agentbox start`.
#
#   deny     non-allowlisted traffic is REJECTed. The default, and unchanged.
#   observe  non-allowlisted NEW connections are logged and then allowed.
#   open     no egress filtering at all. INPUT is untouched in every mode.
EGRESS_MODE_FILE="${AGENT_BOX_EGRESS_MODE_FILE:-/etc/agent-box/egress-mode}"
read_egress_mode() {
    local m=""
    [ -r "$EGRESS_MODE_FILE" ] && m=$(tr -d '[:space:]' < "$EGRESS_MODE_FILE" 2>/dev/null)
    case "$m" in
        deny|observe|open) printf '%s' "$m" ;;
        "") printf 'deny' ;;
        *)  log "WARN: unrecognised egress mode '${m}' in ${EGRESS_MODE_FILE}; using deny" >&2
            printf 'deny' ;;
    esac
}
# `--mode <m>` overrides the file for THIS run only, and nothing writes the
# file. That is what makes `agentbox egress` transactional: the new mode is
# applied and verified first, and the file is written only once it has held.
# Writing the file first and rebuilding second left a failed change armed —
# the CLI reported that nothing had happened and the 15-minute timer applied it
# a quarter of an hour later.
# Scanned rather than positional, so `--mode X --verify-only` means what it
# reads as. `--verify-only` used to be tested as `$1` alone, which made the
# order load-bearing in a way nothing said.
EGRESS_MODE_OVERRIDE=""
ABX_VERIFY_ONLY=0
ABX_DOCKER_HOOK=0
for _i in "$@"; do
    case "${_prev:-}" in
        --mode) EGRESS_MODE_OVERRIDE="$_i" ;;
    esac
    case "$_i" in
        --verify-only) ABX_VERIFY_ONLY=1 ;;
        --docker-hook) ABX_DOCKER_HOOK=1 ;;
        # Only the separated form is read above, so `--mode=deny` would fall
        # through to the mode FILE and rebuild the firewall in a mode nobody
        # asked for. A silent wrong-mode rebuild is the worst failure this
        # script has, so the joined form is refused instead of ignored. The
        # value is not echoed back: it came from a caller's argv.
        #
        # printf and not log(), which is defined further down this file and is
        # therefore not a command yet at this point in it.
        --mode=*)
            printf 'ERROR: --mode takes its value as a separate argument: --mode <deny|observe|open>\n' >&2
            exit 2 ;;
    esac
    _prev="$_i"
done
unset _prev
if [ -n "$EGRESS_MODE_OVERRIDE" ]; then
    case "$EGRESS_MODE_OVERRIDE" in
        deny|observe|open) ;;
        *) log "ERROR: --mode expects deny, observe or open, got '${EGRESS_MODE_OVERRIDE}'" >&2; exit 2 ;;
    esac
    EGRESS_MODE="$EGRESS_MODE_OVERRIDE"
else
    EGRESS_MODE=$(read_egress_mode)
fi

# dnsmasq answers on loopback and feeds the set as it resolves. See the
# resolver section below and docs/decisions.md.
DNSMASQ_CONF="${AGENT_BOX_DNSMASQ_CONF:-/etc/dnsmasq.d/agent-box.conf}"
# Where the rebuild records a hash of the feed rules it generated, so that
# verify() can tell whether the file on disk is still the one the allowlist
# implies. Declared HERE, with the other constants, and not beside the function
# that writes it: verify() runs in two paths and `--verify-only` never reaches
# the rebuild body, so a variable defined there is unbound under `set -u` and
# kills the verification partway through. That has now happened twice.
DNSMASQ_FEED_HASH=""
DNSMASQ_HASH_FILE="${AGENT_BOX_DNSMASQ_HASH:-/run/agent-box-dnsmasq-feed.sha256}"
DNSMASQ_ADDR="127.0.0.1"
# The prefix observe mode stamps on a logged connection. `agentbox egress-log`
# greps the kernel journal for exactly this.
LOG_PREFIX="agent-box-egress: "

# --- what the last rebuild actually resolved ---------------------------------
#
# A state file beside the set, one line per allowlisted name, holding the
# addresses that rebuild put in. It exists so that verify() can ask a question
# it could not otherwise ask without the network: does the LIVE set still
# contain what the last rebuild resolved?
#
# Finding T2. Making the outbound probes advisory was right, and it left the
# fatal set with no member that asserts the allowlist permits anything.
# `allowlist-rule` looks like it covers that and does not: it greps the chain
# for a rule referencing the set, which is equally true of a set holding
# nothing. Meanwhile one unresolvable name is a WARN and a `continue`, and
# `resolved_any` is satisfied by a single name out of nineteen — so a rebuild
# during a partial DNS failure could swap in a set holding the GitHub ranges
# and almost nothing else, exit 0, and leave every operator-facing signal green
# on a box where no agent can reach the model API.
RESOLVED_STATE="${AGENT_BOX_RESOLVED_STATE:-/run/agent-box-firewall-resolved}"
# The one name whose absence makes the box useless rather than merely degraded.
# Its resolution failure is a rebuild failure, and its addresses missing from
# the live set is a fatal verification failure.
CRITICAL_NAME="api.anthropic.com"

# The three chains this script owns. Everything it does to the filter table is
# confined to these plus the policies and the jumps that reach them.
CHAIN_IN="AGENTBOX-IN"
CHAIN_OUT="AGENTBOX-OUT"
CHAIN_FWD="AGENTBOX-FWD"
# Docker's documented place for user rules. FORWARD jumps here unconditionally,
# before DOCKER-FORWARD, and since Engine 28.0.1 the chain has no implicit
# RETURN of its own.
DOCKER_USER="DOCKER-USER"

# --- serialising two writers ------------------------------------------------
#
# There are two ways this script's rebuild is driven and they are not the same
# mechanism. The timer restarts the systemd unit, which serialises against
# itself because a Type=oneshot unit that is already running will not start
# twice. `agentbox firewall-check` used to exec the script directly under sudo,
# which systemd knows nothing about — and both paths mutate the same global
# kernel state under fixed names. IPSET_TMP is a constant, so one run's
# `ipset destroy` lands on the other's half-filled set; the loser either fails
# its next `ipset add` (a failed unit, which blocks every agent run) or, worse,
# wins the swap with a set that holds almost nothing, and the live allowlist is
# silently short while every check still reports PASS.
#
# Two layers. `flock` on one file, taken by every writer, is the real fix.
# `-w` on every iptables call is the cheap one, and it covers the xtables lock
# even for a writer that predates this file or bypasses it.
LOCK_FILE="${AGENT_BOX_FW_LOCK:-/run/agent-box-firewall.lock}"
# Overridable so the contention branches can be exercised without a two-minute
# test. Finding T7: until now the only branch of take_fw_lock that had ever run
# was the success path, and the three that decide what happens when two writers
# meet were the whole point of the mechanism.
LOCK_WAIT_REBUILD="${AGENT_BOX_LOCK_WAIT:-120}"
LOCK_WAIT_HOOK="${AGENT_BOX_LOCK_WAIT_HOOK:-30}"
IPT_WAIT=5

# Returns 0 if the lock was taken, 1 if it timed out, and 0 if locking is not
# available at all — a box without flock or without a writable /run is not made
# safer by refusing to configure its firewall.
take_fw_lock() {
    local secs="${1:?}"
    command -v flock >/dev/null 2>&1 || return 0
    # The braces are load-bearing. `exec` with no command applies its
    # redirections to THIS shell and keeps them, so a bare
    # `exec 9>"$LOCK_FILE" 2>/dev/null` would silence the script's own stderr
    # for the whole run — including the hard-close recovery instructions, which
    # are the one thing an operator locked out of their box needs to read.
    # Written that way first, and the smoke caught it: the hard close happened
    # correctly and said nothing at all. Grouping scopes the 2>/dev/null to the
    # open attempt, which is all it was ever meant to cover.
    { exec 9>"$LOCK_FILE"; } 2>/dev/null || return 0
    flock -w "$secs" 9 || return 1
    return 0
}

# IFS is left alone deliberately: with IFS=$'\n\t', `log a b` would join its
# arguments with a newline instead of a space.
log() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Chain plumbing
# ---------------------------------------------------------------------------

docker_installed() { command -v docker >/dev/null 2>&1; }

# A REACHABLE daemon, not an installed binary. The distinction is the whole of
# finding B2, and it is a boot-time deadlock rather than a cosmetic one:
# docker.service carries `After=agent-box-firewall.service`, so while this unit
# runs at boot the daemon is queued behind it. docker.socket, however, is
# already listening — so an unbounded `docker image inspect` connects, systemd
# queues the docker.service start job that cannot run until this unit finishes,
# and the unit waits for a reply that cannot come. Measured on a --docker box:
# ten minutes in, `docker image inspect alpine:3` still running as a child of
# init-firewall.sh, `docker.service start waiting` behind
# `agent-box-firewall.service start running`, multi-user.target blocked, and
# TimeoutStartUSec=infinity, so nothing would ever have broken it.
#
# The bound is what makes this safe: `timeout` turns the deadlock into a
# five-second skip. Every other container call below is bounded for the same
# reason — the firewall unit must never be held open by the runtime it exists
# to constrain.
DOCKER_INFO_TIMEOUT=5
# 30s each, per the review. Nothing here pulls, so a probe is one container
# start plus one bounded wget; 30 seconds is generous for that and short enough
# that two of them cannot meaningfully delay a boot.
DOCKER_PROBE_TIMEOUT=30
docker_daemon_up() {
    timeout "$DOCKER_INFO_TIMEOUT" docker info >/dev/null 2>&1
}

# The chain exists only once dockerd has run at least once.
chain_exists() {
    local ipt="$1" chain="$2"
    "$ipt" -w "$IPT_WAIT" -n -L "$chain" >/dev/null 2>&1
}

# The interface the default route leaves by. Traffic forwarded out of anything
# else — a Docker bridge — is container-to-container or a published port, never
# egress, and must not be filtered by the allowlist.
uplink_iface() {
    # No `exit` in the awk, and that is not style. `awk '{...; exit}' ` closes
    # the pipe as soon as it has what it wants, so `ip route` is killed with
    # SIGPIPE whenever its output is longer than the pipe buffer — which on a
    # --docker box with a couple of user-defined networks it is. Under
    # `set -o pipefail` the pipeline then returns 141, and at every call site
    # here the result is assigned with a plain command substitution, so `set -e`
    # takes the whole script down.
    #
    # It went unseen because the plain box's routing table is three lines and
    # fits in the buffer. Adding a caller inside verify() surfaced it on the
    # Docker instance: the run died immediately after `out-chain-first`, and
    # `agentbox firewall-check` exited 141 with the table half printed.
    #
    # Reading to EOF and keeping the first match costs nothing and cannot race.
    ip route 2>/dev/null | awk '/^default/ && !seen { print $5; seen = 1 }'
}

# The two rules that must LEAD AGENTBOX-FWD (v4), emitted as bare rule bodies so
# that both places which build the chain can use them: the full rebuild, which
# prints them into an iptables-restore file, and docker_hook's fallback, which
# appends them with `iptables -A`.
#
# One function because there were two, and they disagreed. The rebuild grew the
# inbound DROP; the hook's fallback did not, so the branch that exists precisely
# to cover the window before the first full rebuild — a fresh --docker box's
# first daemon start, and the flush-and-restart recovery the hard-close message
# recommends — installed a chain that was closed for egress and open inbound.
# That is finding R3, and it reopened B1 in the one window B1's rule was for.
#
# Order matters and is asserted by the smoke: DROP first, RETURN second. The
# reverse would return the inbound packet to DOCKER-FORWARD before it was judged.
fwd_leading_rules() {
    local uplink="$1"
    [ -n "$uplink" ] || return 0
    printf -- '-i %s -m conntrack --ctstate NEW -j DROP\n' "$uplink"
    printf -- '! -o %s -j RETURN\n' "$uplink"
}

# Docker's default bridge address. Docker uses 172.17.0.1 unless it is told
# otherwise, and guest/provision.sh writes that same address into daemon.json's
# `dns`, so the two are consistent by construction rather than by coincidence.
DOCKER_BRIDGE_DEFAULT="172.17.0.1"

# The bridge address, or nothing.
#
# `|| true` is load-bearing: on a box without Docker `ip addr show dev docker0`
# exits non-zero, and under `set -e` with the ERR trap installed that is not
# "no bridge", it is a rebuild failure that hard-closes the guest.
#
# And the fallback matters as much. This unit is ordered BEFORE docker.service,
# so at boot docker0 does not exist yet and deriving the address gives nothing —
# dnsmasq would then never listen where containers are told to look, and every
# container on the box would be unable to resolve anything. When Docker is
# installed, its default address is used whether or not the interface has
# appeared, and `bind-dynamic` (see the config) binds to it when it does.
# ONE author. daemon.json's `dns` is what containers are actually told to use,
# so that file is the source of truth and this reads it rather than deriving the
# same value a second way. Two independent derivations of "the container
# resolver address" can disagree, and the failure when they do is silent: the
# firewall permits one address and containers query another.
DOCKER_DAEMON_JSON="${AGENT_BOX_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}"
docker_bridge_addr() {
    local a=""
    if [ -r "$DOCKER_DAEMON_JSON" ] && command -v jq >/dev/null 2>&1; then
        a=$(jq -r '.dns[0] // empty' "$DOCKER_DAEMON_JSON" 2>/dev/null || true)
    fi
    # Falling back rather than failing: a box whose daemon.json has no `dns`
    # (an older one, or one an operator edited) still needs an address here.
    if [ -z "$a" ]; then
        a=$(ip -4 -o addr show dev docker0 2>/dev/null \
            | awk 'NR == 1 { print $4 }' | cut -d/ -f1 || true)
    fi
    if [ -z "$a" ] && docker_installed; then
        a="$DOCKER_BRIDGE_DEFAULT"
    fi
    printf '%s' "$a"
}

ensure_chain() {
    local ipt="$1" chain="$2"
    chain_exists "$ipt" "$chain" || "$ipt" -w "$IPT_WAIT" -N "$chain"
}

# `iptables -S CHAIN` prints the chain's own declaration first, so the Nth rule
# is the (N+1)th line. This returns the first rule, or the empty string.
first_rule() {
    local ipt="$1" chain="$2"
    "$ipt" -w "$IPT_WAIT" -S "$chain" 2>/dev/null | sed -n '2p'
}

# Make `-j TARGET` rule 1 of CHAIN, idempotently, leaving no duplicates.
#
# Insert first and delete afterwards, never the other way round: deleting first
# would leave an instant in which the chain does not reach our rules at all, and
# for DOCKER-USER that instant is one in which containers are unfiltered.
ensure_jump_first() {
    local ipt="$1" chain="$2" target="$3" want line n
    want="-A ${chain} -j ${target}"
    if [ "$(first_rule "$ipt" "$chain")" != "$want" ]; then
        "$ipt" -w "$IPT_WAIT" -I "$chain" 1 -j "$target"
    fi
    # Every further copy, removed from the top down. The first match is the one
    # just placed (or already correct) at rule 1; the second is a duplicate.
    while :; do
        line=$("$ipt" -w "$IPT_WAIT" -S "$chain" 2>/dev/null | grep -n -x -F -- "$want" | sed -n '2p' | cut -d: -f1) || true
        [ -n "$line" ] || break
        n=$((line - 1))
        "$ipt" -w "$IPT_WAIT" -D "$chain" "$n"
    done
}

# The jumps that make the three chains reachable. DOCKER-USER only exists once
# Docker has run, and this is called both before and after the restore, so a
# chain that appears in between is still picked up.
ensure_jumps() {
    local ipt="$1"
    ensure_jump_first "$ipt" INPUT  "$CHAIN_IN"
    ensure_jump_first "$ipt" OUTPUT "$CHAIN_OUT"
    if chain_exists "$ipt" "$DOCKER_USER"; then
        ensure_jump_first "$ipt" "$DOCKER_USER" "$CHAIN_FWD"
    fi
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
#
# These assert the mechanism, not one symptom. A check that only proves
# "example.com did not connect" passes just as happily when DNS is broken, when
# curl is missing, or when the ruleset was never applied at all.

# A literal address outside every allowlist and outside the host subnet, so it
# tests the REJECT rule rather than name resolution. 198.51.100.0/24 is
# TEST-NET-2 (RFC 5737) and is not routable anywhere.
LITERAL_BLOCKED_IP="198.51.100.42"
# A public resolver that is not the guest's configured one.
FOREIGN_RESOLVER="9.9.9.9"
# Small, and already needed as the container probe's own userland.
PROBE_IMAGE="alpine:3"

# busybox wget exits non-zero both when it cannot connect and when the server
# answers with an HTTP error, and the difference is the whole point of the
# check: an answered request means the connection was permitted. Prints
# "connected", "blocked" or "error: ..." on stdout.
#
# `download timed out` is deliberately NOT in the blocked list, which is finding
# T4. The chain this probe tests ends in REJECT, not DROP, so a container our
# rules refuse gets an immediate ICMP admin-prohibited and busybox says
# "can't connect" or "Connection refused". A timeout is the one signature the
# ruleset under test cannot produce — it means the probe did not reach a verdict
# — so reading it as proof of blocking would let an absence pass the check that
# R2 made fatal. It falls through to "error:", which is a WARN.
container_probe() {
    local url="$1" out rc
    out=$(timeout "$DOCKER_PROBE_TIMEOUT" docker run --rm --network bridge "$PROBE_IMAGE" \
              wget -T 5 -q -O /dev/null "$url" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'connected'
    elif printf '%s' "$out" | grep -q 'server returned error'; then
        printf 'connected'
    elif printf '%s' "$out" | grep -qE "can't connect|bad address|network is unreachable|Connection refused|Permission denied"; then
        printf 'blocked'
    else
        printf 'error: %s' "$(printf '%s' "$out" | tr '\n' ' ')"
    fi
}

verify() {
    # Two counters. The line between them is NOT "local versus remote" — an
    # earlier version of this comment said that and the code never matched it,
    # which is finding R4. It is the direction the check fails in.
    #
    # `failures` are checks that can only fail on AFFIRMATIVE evidence that the
    # ruleset is wrong: a policy that is not DROP, a jump that is not there, or
    # something reachable that the allowlist says must not be. A remote host
    # having a bad minute cannot produce any of them. Note what that includes:
    # `literal-ip-denied`, `foreign-dns-denied` and `egress-denied` all send
    # packets, and all three are still fatal, because the only way they fail is
    # by something answering that should have been refused. That is a fact about
    # this box.
    #
    # `warnings` are checks that fail on an ABSENCE — something allowlisted did
    # not answer. api.anthropic.com, github.com and the container's reach to the
    # model API are all in this half. An absence is exactly what an outage, a
    # rate limit, a CDN rotating an address or a captive network produces, and
    # this function's return value is the unit's exit status: a failed unit
    # aborts provisioning under `set -e`, and the EXIT trap's second failed
    # restart hard-closes the guest down to loopback and ssh. Handing that
    # trigger to a third party is the defect; a ten-minute `agentbox create`
    # must not end in a dead box because an API was briefly slow.
    #
    # Only `failures` sets the exit status. `warnings` are reported in the log
    # and in `agentbox firewall-check`'s output, and that is all.
    local failures=0 warnings=0

    # --- the mechanism itself ---------------------------------------------

    log "egress mode: ${EGRESS_MODE}"

    # What "correct" means is the mode's promise, not one fixed ruleset. Each
    # branch checks what that mode undertakes to do and nothing else — an open
    # box asserting OUTPUT DROP would be a check that fails when the box is
    # working, which teaches an operator to ignore it.
    case "$EGRESS_MODE" in
        open)
            if iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P OUTPUT ACCEPT'; then
                log "PASS  mode-open          OUTPUT is unfiltered, as 'open' promises"
            else
                log "FAIL  mode-open          the mode is 'open' but the OUTPUT policy is not ACCEPT"
                failures=$((failures + 1))
            fi
            ;;
        observe)
            # Never silently deny: the whole point of observe is that traffic
            # gets through and is recorded. A missing ACCEPT would make it a
            # slower deny mode that nobody was told about.
            if iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null | grep -q -- '-j LOG --log-prefix'; then
                log "PASS  mode-observe-log   ${CHAIN_OUT} logs non-allowlisted connections"
            else
                log "FAIL  mode-observe-log   the mode is 'observe' but nothing logs"
                failures=$((failures + 1))
            fi
            if [ "$(iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null | tail -1)" = "-A ${CHAIN_OUT} -j ACCEPT" ]; then
                log "PASS  mode-observe-pass  ${CHAIN_OUT} ends in ACCEPT, so nothing is silently denied"
            else
                log "FAIL  mode-observe-pass  the mode is 'observe' but ${CHAIN_OUT} does not end in ACCEPT"
                failures=$((failures + 1))
            fi
            # Per destination, not one bucket for the chain: with a single
            # global limit a chatty host exhausts the budget and every other
            # destination goes unrecorded, which is the one thing observe is
            # for. The shape is checked, not just the presence of a limit.
            if iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null \
                | grep -q -- '--hashlimit-mode dstip,dstport'; then
                log "PASS  mode-observe-rate  the log is rate-limited per destination"
            else
                log "FAIL  mode-observe-rate  the log limit is not per destination; one host can hide the others"
                failures=$((failures + 1))
            fi
            # observe relaxes the allowlist and keeps the resolver restriction.
            if iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null \
                | grep -q -- '--dport 53 -j REJECT'; then
                log "PASS  mode-observe-dns   DNS to a non-permitted server is still refused"
            else
                log "FAIL  mode-observe-dns   observe is not holding the resolver restriction"
                failures=$((failures + 1))
            fi
            if iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
                log "PASS  policy-drop        iptables OUTPUT policy is DROP"
            else
                log "FAIL  policy-drop        iptables OUTPUT policy is not DROP"
                failures=$((failures + 1))
            fi
            ;;
        *)
            if iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
                log "PASS  policy-drop        iptables OUTPUT policy is DROP"
            else
                log "FAIL  policy-drop        iptables OUTPUT policy is not DROP"
                failures=$((failures + 1))
            fi
            ;;
    esac

    if ip6tables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'; then
        log "PASS  policy-drop-v6     ip6tables OUTPUT policy is DROP"
    else
        log "FAIL  policy-drop-v6     ip6tables OUTPUT policy is not DROP"
        failures=$((failures + 1))
    fi

    # In every mode, including open: the policy is what catches anything that
    # falls off the end of Docker's chains, and open does not change that.
    if iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P FORWARD DROP'; then
        log "PASS  forward-drop       iptables FORWARD policy is DROP"
    else
        log "FAIL  forward-drop       iptables FORWARD policy is not DROP"
        failures=$((failures + 1))
    fi

    # In every mode, and named as its own check because `open` is exactly when
    # someone will want to know it is still true: the way in is unchanged.
    # The exact shape, not a substring. `--dport 22 -j ACCEPT` also matches a
    # rule accepting ssh from ANY source, which is a materially different box —
    # under vz the subnet is the host plus every other VM on it. The source and
    # the conntrack rule are both named.
    # The gateway is derived HERE rather than read from HOST_IP. verify() runs
    # in two paths — at the end of a rebuild, where HOST_IP is set, and under
    # `--verify-only`, where nothing has set it — and reading it under `set -u`
    # killed the whole function on the second path with `unbound variable`. A
    # check that aborts verification is worse than the check it replaced.
    local vgw want_ssh want_ct in_ok=1
    vgw=$(ip route 2>/dev/null | awk '/^default/ && !seen { print $3; seen = 1 }')
    want_ct="-A ${CHAIN_IN} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    [ "$(first_rule iptables INPUT)" = "-A INPUT -j ${CHAIN_IN}" ] || in_ok=0
    iptables -w "$IPT_WAIT" -S "$CHAIN_IN" 2>/dev/null | grep -qxF -- "$want_ct" || in_ok=0
    iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P INPUT DROP' || in_ok=0
    if [ -n "$vgw" ]; then
        # The source matters: `--dport 22 -j ACCEPT` on its own also matches a
        # rule accepting ssh from ANY source, and under vz the subnet is the
        # host plus every other VM on it.
        want_ssh="-A ${CHAIN_IN} -s ${vgw}/32 -p tcp -m tcp --dport 22 -j ACCEPT"
        iptables -w "$IPT_WAIT" -S "$CHAIN_IN" 2>/dev/null | grep -qxF -- "$want_ssh" || in_ok=0
    else
        # No default route: the hard close's any-source fallback is the only
        # shape available, and saying so is better than failing a box whose
        # routing is gone for an unrelated reason.
        iptables -w "$IPT_WAIT" -S "$CHAIN_IN" 2>/dev/null | grep -q -- '--dport 22 -j ACCEPT' || in_ok=0
    fi
    if [ "$in_ok" -eq 1 ]; then
        log "PASS  inbound-intact     INPUT is DROP, reaches ${CHAIN_IN}, and ssh is accepted from ${vgw:-any source} only"
    else
        log "FAIL  inbound-intact     the inbound path is not intact in the exact shape expected"
        failures=$((failures + 1))
    fi

    if [ "$(first_rule iptables OUTPUT)" = "-A OUTPUT -j ${CHAIN_OUT}" ]; then
        log "PASS  out-chain-first    OUTPUT rule 1 jumps to ${CHAIN_OUT}"
    else
        log "FAIL  out-chain-first    OUTPUT rule 1 is not the ${CHAIN_OUT} jump"
        failures=$((failures + 1))
    fi

    # The two chains say "this interface is not egress" in different languages.
    # AGENTBOX-FWD asks the routing table (`! -o $UPLINK`); AGENTBOX-OUT names
    # docker0 and the `br+` wildcard, which in iptables is a prefix match on
    # "br". Those accepts sit AHEAD of the ipset match and the terminal REJECT,
    # so if the uplink itself were ever matched by one of them, every packet
    # leaving this guest would be accepted unfiltered and every other check here
    # would still pass. It is not the case on any box this has run on — the
    # uplink is eth0 — and it costs one comparison to know rather than assume.
    #
    # The alternative, using `! -o $UPLINK` in AGENTBOX-OUT too, was considered
    # and rejected: it would accept traffic out of ANY future interface,
    # including a tunnel, which is a wider hole than the one being closed.
    # Naming the bridges explicitly is deny-by-default for interfaces nobody
    # anticipated; this check is what makes the naming safe.
    local vuplink
    vuplink=$(uplink_iface || true)
    case "$vuplink" in
        br*|docker0)
            log "FAIL  uplink-not-bridge  the uplink is '${vuplink}', which ${CHAIN_OUT}'s bridge accepts would match, bypassing the allowlist"
            failures=$((failures + 1))
            ;;
        "")
            log "FAIL  uplink-not-bridge  no default route, so the uplink cannot be identified"
            failures=$((failures + 1))
            ;;
        *)
            log "PASS  uplink-not-bridge  the uplink '${vuplink}' is not matched by ${CHAIN_OUT}'s bridge accepts"
            ;;
    esac

    if iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null | grep -q -- "--match-set ${IPSET_NAME} dst -j ACCEPT"; then
        log "PASS  allowlist-rule     the ${IPSET_NAME} ipset is referenced"
    else
        log "FAIL  allowlist-rule     no rule references the ${IPSET_NAME} ipset"
        failures=$((failures + 1))
    fi

    # --- the holes a name-based probe cannot see --------------------------

    # The three checks below assert that something is REFUSED, which is only
    # what the box promises in deny mode. In observe and open it is reachable
    # on purpose, so asserting otherwise would report a working box as broken.
    # foreign-dns-denied is checked in observe too, and that is the point of
    # the exception: observe relaxes the allowlist and keeps the resolver
    # restriction, so the check that proves it must not be skipped with the
    # others.
    if [ "$EGRESS_MODE" = "observe" ]; then
        log "SKIP  literal-ip-denied  the mode is 'observe'; non-allowlisted traffic is allowed by design"
        log "SKIP  egress-denied      the mode is 'observe'"
        if dig +time=2 +tries=1 "@${FOREIGN_RESOLVER}" example.com >/dev/null 2>&1; then
            log "FAIL  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} succeeded in observe mode; the resolver restriction is not held"
            failures=$((failures + 1))
        else
            log "PASS  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} refused, as observe still promises"
        fi
    elif [ "$EGRESS_MODE" != "deny" ]; then
        log "SKIP  literal-ip-denied  the mode is '${EGRESS_MODE}'; non-allowlisted traffic is allowed by design"
        log "SKIP  foreign-dns-denied the mode is '${EGRESS_MODE}'"
        log "SKIP  egress-denied      the mode is '${EGRESS_MODE}'"
    else

    # Bypassing DNS entirely: a literal address must still be refused.
    if curl -sS -m 5 -o /dev/null "https://${LITERAL_BLOCKED_IP}/" 2>/dev/null; then
        log "FAIL  literal-ip-denied  ${LITERAL_BLOCKED_IP} was reachable by address"
        failures=$((failures + 1))
    else
        log "PASS  literal-ip-denied  ${LITERAL_BLOCKED_IP} refused by address"
    fi

    # Port 53 to an arbitrary resolver is an exfiltration channel: a query name
    # is data. Only the configured resolvers may be reached.
    if dig +time=2 +tries=1 "@${FOREIGN_RESOLVER}" example.com >/dev/null 2>&1; then
        log "FAIL  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} succeeded"
        failures=$((failures + 1))
    else
        log "PASS  foreign-dns-denied DNS to ${FOREIGN_RESOLVER} refused"
    fi

    # --- the allowlist does what it says ----------------------------------

    if curl -sS -m 5 -o /dev/null https://example.com 2>/dev/null; then
        log "FAIL  egress-denied      https://example.com was reachable"
        failures=$((failures + 1))
    else
        log "PASS  egress-denied      https://example.com blocked as expected"
    fi

    fi  # end of the deny-only probes

    # The resolver the set depends on. Its being down is a local fact, readable
    # from systemd, and it is affirmative evidence rather than an absence — so
    # it is fatal. The consequence is worth naming in the message because it is
    # not obvious: with dnsmasq down nothing resolves at all, so the box fails
    # CLOSED rather than open, and the symptom an operator sees is every name
    # failing rather than a hole.
    if command -v dnsmasq >/dev/null 2>&1; then
        if systemctl is-active --quiet dnsmasq 2>/dev/null; then
            log "PASS  resolver-up        dnsmasq is running, so names resolve and feed the set"
        else
            log "FAIL  resolver-up        dnsmasq is NOT running: nothing will resolve, so the box is closed to everything by name"
            failures=$((failures + 1))
        fi
    else
        log "SKIP  resolver-up        dnsmasq is not installed on this instance"
    fi

    # --- the resolver's configuration IS part of the allowlist -------------
    #
    # dnsmasq decides which addresses enter the allowed set, so its config file
    # is as much the allowlist as allowlist.base is, and nothing checked it. A
    # dropped `ipset=` line silently stops a suffix working; an added one
    # silently admits a subtree; a second config source could add either
    # without touching this file at all. Three checks, all local.
    if ! command -v dnsmasq >/dev/null 2>&1; then
        log "SKIP  resolver-conf      dnsmasq is not installed on this instance"
    else
        local conf_ok=1 running_conf feed_now feed_then
        # (a) the running daemon is reading OUR file, and only our file.
        running_conf=$(tr '\0' '\n' < /proc/"$(pgrep -x dnsmasq | head -1)"/cmdline 2>/dev/null \
                       | sed -n 's/^--conf-file=//p' | awk 'NR == 1' || true)
        if [ "$running_conf" != "$DNSMASQ_CONF" ]; then
            log "FAIL  resolver-conf      dnsmasq is running with conf-file '${running_conf:-<none>}', not ${DNSMASQ_CONF}"
            conf_ok=0
        elif grep -qE '^[[:space:]]*(conf-dir|conf-file|addn-hosts)=' "$DNSMASQ_CONF" 2>/dev/null; then
            log "FAIL  resolver-conf      ${DNSMASQ_CONF} pulls in another configuration source"
            conf_ok=0
        fi
        # (b) the feed rules on disk are the ones this allowlist implies.
        feed_now=$(grep '^ipset=' "$DNSMASQ_CONF" 2>/dev/null | sort | sha256sum | awk '{print $1}')
        feed_then=$(cat "$DNSMASQ_HASH_FILE" 2>/dev/null || printf '')
        if [ -z "$feed_then" ]; then
            log "FAIL  resolver-conf      no recorded feed hash; the rebuild did not write ${DNSMASQ_HASH_FILE}"
            conf_ok=0
        elif [ "$feed_now" != "$feed_then" ]; then
            log "FAIL  resolver-conf      the ipset rules in ${DNSMASQ_CONF} are not the ones the allowlist generated"
            conf_ok=0
        fi
        # (c) and it parses, because a file dnsmasq rejects is a resolver that
        # will not come back after the next restart.
        if ! dnsmasq --test --conf-file="$DNSMASQ_CONF" >/dev/null 2>&1; then
            log "FAIL  resolver-conf      dnsmasq --test rejects ${DNSMASQ_CONF}"
            conf_ok=0
        fi
        # The two protections that decide what an answer may put in the set.
        # The VALUES, not merely the presence of the words. `max-cache-ttl=99999`
        # satisfies a presence check and breaks the one relationship the feed
        # depends on, and a `rebind-domain-ok=*` next to `stop-dns-rebind`
        # switches the protection off for everything while leaving the line
        # that appears to enable it.
        local mct
        mct=$(sed -n 's/^max-cache-ttl=//p' "$DNSMASQ_CONF" 2>/dev/null | head -1)
        if [ -z "$mct" ]; then
            log "FAIL  resolver-conf      ${DNSMASQ_CONF} is missing max-cache-ttl"
            conf_ok=0
        elif ! [ "$mct" -lt "$RESOLVED_TTL" ] 2>/dev/null; then
            log "FAIL  resolver-conf      max-cache-ttl=${mct} is not below the entry lifetime ${RESOLVED_TTL}; a host can go dark silently"
            conf_ok=0
        fi
        if ! grep -qE '^stop-dns-rebind([[:space:]]|$)' "$DNSMASQ_CONF" 2>/dev/null; then
            log "FAIL  resolver-conf      ${DNSMASQ_CONF} is missing stop-dns-rebind"
            conf_ok=0
        elif grep -qE '^rebind-domain-ok=(\*|/\*/)?$' "$DNSMASQ_CONF" 2>/dev/null; then
            log "FAIL  resolver-conf      rebind-domain-ok exempts everything, so stop-dns-rebind protects nothing"
            conf_ok=0
        fi
        if [ "$conf_ok" -eq 1 ]; then
            log "PASS  resolver-conf      dnsmasq reads only our file, its feed matches the allowlist, and it parses"
            failures=$((failures + 0))
        else
            failures=$((failures + 1))
        fi
    fi

    # The allowlist PERMITS something, asserted without the network. This is
    # the fatal counterpart to the advisory probes below, and finding T2: with
    # those made advisory, nothing fatal was left that could notice a box which
    # is correctly closed and completely useless.
    #
    # It reads what the last rebuild recorded for the one name that matters and
    # asks the kernel whether the live set still holds it. Both halves are
    # local. It fails only on affirmative evidence — the set exists, the file
    # says these addresses were put in it, and they are not there — which is
    # the same direction-of-failure rule every other fatal check follows.
    if [ ! -r "$RESOLVED_STATE" ]; then
        log "FAIL  allowlist-holds    no rebuild has recorded its resolutions at ${RESOLVED_STATE}"
        failures=$((failures + 1))
    else
        local crit_ips crit_missing=0 crit_total=0 ip
        crit_ips=$(awk -v n="$CRITICAL_NAME" '$1 == n { for (i = 2; i <= NF; i++) print $i }' \
                       "$RESOLVED_STATE" 2>/dev/null | sort -u)
        if [ -z "$crit_ips" ]; then
            log "FAIL  allowlist-holds    the last rebuild recorded no address for ${CRITICAL_NAME}"
            failures=$((failures + 1))
        else
            while read -r ip; do
                [ -n "$ip" ] || continue
                crit_total=$((crit_total + 1))
                ipset test "$IPSET_NAME" "$ip" >/dev/null 2>&1 || crit_missing=$((crit_missing + 1))
            done < <(printf '%s\n' "$crit_ips")
            if [ "$crit_missing" -eq 0 ]; then
                log "PASS  allowlist-holds    the live set holds all ${crit_total} recorded address(es) for ${CRITICAL_NAME}"
            else
                log "FAIL  allowlist-holds    ${crit_missing} of ${crit_total} recorded address(es) for ${CRITICAL_NAME} are missing from the live set"
                failures=$((failures + 1))
            fi
        fi
    fi

    # The two below are the ones that fail on an absence, so they are advisory.
    # Everything above this line fails only when something answered that should
    # not have.
    local code
    if code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ 2>/dev/null) \
        && [ -n "$code" ] && [ "$code" != "000" ]; then
        log "PASS  anthropic-allowed  https://api.anthropic.com/ returned HTTP ${code}"
    else
        log "WARN  anthropic-allowed  https://api.anthropic.com/ did not answer"
        warnings=$((warnings + 1))
    fi

    if curl -sS -m 10 -o /dev/null https://github.com 2>/dev/null; then
        log "PASS  github-allowed     https://github.com reachable"
    else
        log "WARN  github-allowed     https://github.com unreachable"
        warnings=$((warnings + 1))
    fi

    # --- containers obey the same allowlist -------------------------------
    #
    # Skipped, out loud, on an instance created without --docker: the checks
    # below are about a runtime that is not installed, and a silent skip reads
    # exactly like a pass.

    if ! docker_installed; then
        log "SKIP  docker-user-jump   Docker is not installed on this instance"
        log "SKIP  docker-egress      Docker is not installed on this instance"
        log "SKIP  docker-allowed     Docker is not installed on this instance"
    elif ! docker_daemon_up; then
        # Not a failure, and saying so is the point. At boot the daemon is
        # ordered after this unit deliberately, so DOCKER-USER does not exist
        # yet and no container can run; the jump is installed by the
        # ExecStartPost hook the moment dockerd starts. Failing here would put
        # the unit in `failed`, and guest/lib.sh refuses to start an agent on a
        # box whose firewall unit is not active — a false report of an
        # unprotected box, on a box that is in fact protected.
        log "SKIP  docker-user-jump   the Docker daemon is not running (checked for ${DOCKER_INFO_TIMEOUT}s)"
        log "SKIP  docker-egress      the Docker daemon is not running"
        log "SKIP  docker-allowed     the Docker daemon is not running"
    else
        if chain_exists iptables "$DOCKER_USER"; then
            if [ "$(first_rule iptables "$DOCKER_USER")" = "-A ${DOCKER_USER} -j ${CHAIN_FWD}" ]; then
                log "PASS  docker-user-jump   ${DOCKER_USER} rule 1 jumps to ${CHAIN_FWD}"
            else
                log "FAIL  docker-user-jump   ${DOCKER_USER} rule 1 is not the ${CHAIN_FWD} jump"
                failures=$((failures + 1))
            fi
        else
            log "FAIL  docker-user-jump   Docker is installed but ${DOCKER_USER} does not exist"
            failures=$((failures + 1))
        fi

        # This unit does NOT pull. It used to, on the reasoning that the pull
        # was itself the registry test — and that made a Docker Hub hiccup able
        # to decide whether a new box was usable, because verify() is the
        # script's exit status, provisioning restarts this unit under `set -e`,
        # and the EXIT trap's second failure hard-closes the guest. An
        # anonymous 429 from Docker Hub would have left a ten-minute
        # `agentbox create` exiting non-zero and a brand-new VM on loopback and
        # ssh only. The timer would also have re-pulled every fifteen minutes,
        # on a box whose own documentation recommends `docker system prune -af`,
        # which deletes the image.
        #
        # So: probe with what is already here, and say so when there is nothing
        # to probe with. `docker pull alpine:3` as a registry test lives in the
        # smoke test, where a failure is a test result rather than a boot
        # outcome.
        if ! timeout "$DOCKER_INFO_TIMEOUT" docker image inspect "$PROBE_IMAGE" >/dev/null 2>&1; then
            log "SKIP  docker-egress      ${PROBE_IMAGE} is not present locally; not pulling from inside the firewall unit"
            log "SKIP  docker-allowed     ${PROBE_IMAGE} is not present locally"
        else
            # Three ways, not two. container_probe already separates them and
            # the old code threw the distinction away. `connected` means a
            # container DID reach a host the allowlist forbids — affirmative
            # evidence that DOCKER-USER is not reaching AGENTBOX-FWD, or that
            # AGENTBOX-FWD is not filtering. No outage, rate limit or registry
            # hiccup can produce it, and it is the exact containment breach this
            # profile exists to prevent, so it is fatal. `error:` means the
            # probe itself did not run — inconclusive, and a warning.
            local r
            if [ "$EGRESS_MODE" != "deny" ]; then
                log "SKIP  docker-egress      the mode is '${EGRESS_MODE}'; container egress is allowed by design"
                r=""
            else
            r=$(container_probe https://example.com)
            case "$r" in
                blocked)
                    log "PASS  docker-egress      a container could not reach https://example.com" ;;
                connected)
                    log "FAIL  docker-egress      a container REACHED https://example.com; container egress is not filtered"
                    failures=$((failures + 1)) ;;
                *)
                    log "WARN  docker-egress      the container probe was inconclusive: ${r}"
                    warnings=$((warnings + 1)) ;;
            esac
            fi

            r=$(container_probe https://api.anthropic.com/)
            if [ "$r" = "connected" ]; then
                log "PASS  docker-allowed     a container reached https://api.anthropic.com/"
            else
                log "WARN  docker-allowed     a container could not reach https://api.anthropic.com/: ${r}"
                warnings=$((warnings + 1))
            fi
        fi
    fi

    if [ "$failures" -ne 0 ]; then
        log "firewall verification: ${failures} check(s) FAILED, ${warnings} warning(s)"
        return 1
    fi
    if [ "$warnings" -ne 0 ]; then
        log "firewall verification: ruleset checks all PASS, ${warnings} advisory warning(s) — see WARN above"
        return 0
    fi
    log "firewall verification: all checks PASS"
    return 0
}

# `iptables -S` needs CAP_NET_ADMIN, so verification is a root operation too.
# `agentbox firewall-check` runs this under sudo for that reason.
if [ "$ABX_VERIFY_ONLY" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR: --verify-only must run as root (it reads the ruleset)" >&2
        exit 1
    fi
    verify
    exit $?
fi

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: init-firewall.sh must run as root" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The Docker hook
# ---------------------------------------------------------------------------
#
# docker.service's ExecStartPost. A daemon restart recreates whatever of its own
# chains are missing, and the 15-minute timer is far too coarse a net to catch
# the window: for up to fifteen minutes containers would forward through
# DOCKER-FORWARD with nothing of ours in front of it. This runs synchronously as
# part of the restart instead, so there is no window at all.
#
# It does one thing — put the AGENTBOX-FWD jump back at DOCKER-USER rule 1 — and
# deliberately does not rebuild anything, because a rebuild needs DNS and
# api.github.com and must never be on the critical path of starting a daemon.

# Every iptables call the hook makes goes through this, so that the v4/v6 split
# is applied uniformly instead of at the four sites that happened to be written
# as `if ! cmd`. That was finding T1: the empty-chain fallback's appends were
# plain commands in a function called plainly, so under `set -e` a v6 failure
# exited the whole script before the `fatal` variable was ever consulted — and
# with the `-` gone from ExecStartPost, systemd stops docker.service on that.
# The guard existed, was correct, and was unreachable from the branch that
# needed it most.
#
# HOOK_RC accumulates; HOOK_FATAL says which arm we are on. Both are globals
# because this must be callable from anywhere inside docker_hook without
# depending on where bash happens to have scoped a local.
HOOK_RC=0
HOOK_FATAL=1
hook_ipt() {
    if "$@"; then
        return 0
    fi
    if [ "$HOOK_FATAL" -eq 1 ]; then
        log "ERROR: docker-hook: command failed: $*" >&2
        HOOK_RC=1
    else
        log "WARN: docker-hook: command failed on the v6 arm, which is advisory: $*"
    fi
    return 0
}

docker_hook() {
    local ipt uplink
    uplink=$(uplink_iface || true)
    HOOK_RC=0

    for ipt in iptables ip6tables; do
        # The v4 arm has to succeed; the v6 arm must never be able to take the
        # daemon down with it. Docker's own daemon.json here sets "ipv6": false
        # and Engine 28 still creates the v6 chains, so the v6 arm normally
        # works — but "normally" is not a thing to hang a service start on. A
        # kernel without ip6_tables, or an Engine built with v6 management off,
        # would make this hook exit non-zero, and an ExecStartPost that exits
        # non-zero makes systemd stop the service. A box created --docker would
        # then have no Docker at all, explained by one journal line from a
        # firewall script. v6 egress is closed by policy in any case, so a
        # missing v6 DOCKER-USER is a warning, not a failure.
        HOOK_FATAL=1
        [ "$ipt" = "iptables" ] || HOOK_FATAL=0
        if ! command -v "$ipt" >/dev/null 2>&1; then
            # Split by arm, which makes the enumeration uniform: after this,
            # every v4 outcome other than success sets HOOK_RC. A kernel with no
            # v6 support is the case the advisory arm exists for. A guest with
            # no `iptables` is not a degraded outcome — it is the total absence
            # of the filtering this hook is the last step of, and returning 0
            # there would let systemd start a daemon whose containers forward
            # through DOCKER-FORWARD with nothing in front of them.
            if [ "$HOOK_FATAL" -eq 1 ]; then
                log "ERROR: docker-hook: ${ipt} is not installed; containers cannot be filtered" >&2
                HOOK_RC=1
            else
                log "WARN: docker-hook: ${ipt} is not installed; skipping (v6 is advisory)"
            fi
            continue
        fi
        if ! chain_exists "$ipt" "$CHAIN_FWD"; then
            hook_ipt "$ipt" -w "$IPT_WAIT" -N "$CHAIN_FWD"
        fi
        if ! chain_exists "$ipt" "$CHAIN_FWD"; then
            log "WARN: docker-hook: could not ensure ${CHAIN_FWD} in ${ipt}"
            [ "$HOOK_FATAL" -eq 1 ] && HOOK_RC=1
            continue
        fi
        # An empty chain would let everything through to DOCKER-FORWARD. If the
        # full rebuild has not run yet, close the chain rather than leave it
        # open, and let the next timer tick fill it in properly.
        if [ -z "$(first_rule "$ipt" "$CHAIN_FWD")" ]; then
            log "WARN: ${CHAIN_FWD} (${ipt}) was empty; closing it until the next rebuild"
            if [ "$ipt" = "iptables" ]; then
                # The same leading pair the full rebuild emits, from the same
                # function, so this branch can never drift open again.
                while read -r _r; do
                    [ -n "$_r" ] || continue
                    # shellcheck disable=SC2086  # $_r is a rule body and must word-split.
                    hook_ipt "$ipt" -w "$IPT_WAIT" -A "$CHAIN_FWD" $_r
                done < <(fwd_leading_rules "$uplink")
                hook_ipt "$ipt" -w "$IPT_WAIT" -A "$CHAIN_FWD" -j REJECT --reject-with icmp-admin-prohibited
            else
                hook_ipt "$ipt" -w "$IPT_WAIT" -A "$CHAIN_FWD" -j REJECT --reject-with icmp6-adm-prohibited
            fi
        fi
        # v4 failures are real failures: with no `-` on the ExecStartPost, a
        # non-zero return here stops a daemon whose containers this script
        # cannot filter, which is the correct outcome. v6 egress is closed by
        # policy, so its arm stays advisory.
        hook_ipt "$ipt" -w "$IPT_WAIT" -P FORWARD DROP
        if chain_exists "$ipt" "$DOCKER_USER"; then
            ensure_jump_first "$ipt" "$DOCKER_USER" "$CHAIN_FWD" || true
            if [ "$(first_rule "$ipt" "$DOCKER_USER")" = "-A ${DOCKER_USER} -j ${CHAIN_FWD}" ]; then
                log "docker-hook: ${ipt} ${DOCKER_USER} rule 1 is the ${CHAIN_FWD} jump"
            elif [ "$HOOK_FATAL" -eq 1 ]; then
                log "ERROR: docker-hook could not place the ${CHAIN_FWD} jump in ${ipt} ${DOCKER_USER}" >&2
                HOOK_RC=1
            else
                log "WARN: docker-hook could not place the ${CHAIN_FWD} jump in ${ipt} ${DOCKER_USER}"
            fi
        elif [ "$HOOK_FATAL" -eq 1 ]; then
            log "ERROR: docker-hook found no ${DOCKER_USER} chain in ${ipt}" >&2
            HOOK_RC=1
        else
            log "WARN: docker-hook found no ${DOCKER_USER} chain in ${ipt} (v6 egress is closed by policy)"
        fi
    done
    return "$HOOK_RC"
}

if [ "$ABX_DOCKER_HOOK" -eq 1 ]; then
    # The same lock the rebuild takes, so the hook cannot append to
    # AGENTBOX-FWD while a restore is replacing it. A shorter wait than the
    # rebuild's, and it proceeds anyway on a timeout: this runs as docker's
    # ExecStartPost, so blocking here blocks the daemon starting, and a rebuild
    # in flight will place the jump itself when it finishes. The `-w` on every
    # iptables call is what actually makes the unlocked path safe.
    take_fw_lock "$LOCK_WAIT_HOOK" \
        || log "WARN: docker-hook proceeding without the rebuild lock after ${LOCK_WAIT_HOOK}s"
    docker_hook
    exit $?
fi

# ---------------------------------------------------------------------------
# One rebuild at a time
# ---------------------------------------------------------------------------
#
# Taken before anything is fetched, resolved or written, and held for the rest
# of the run. Two rebuilds racing corrupt the ipset swap: IPSET_TMP is a fixed
# name, so one run's `ipset destroy` lands on the other's half-filled set.
#
# A timeout here is a real anomaly rather than a busy machine — a rebuild is
# seconds — so it fails rather than proceeding, and it fails before touching
# anything, which leaves the standing ruleset exactly as it was.
if ! take_fw_lock "$LOCK_WAIT_REBUILD"; then
    log "ERROR: another firewall rebuild has held ${LOCK_FILE} for more than ${LOCK_WAIT_REBUILD}s" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Failing closed
# ---------------------------------------------------------------------------

standing_deny_in_place() {
    iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- '-P OUTPUT DROP'
}

# Nothing below tears down the live ruleset, so an error normally leaves the
# previous deny ruleset intact — which is already the safe outcome, and is
# recoverable, because the next timer tick can still reach DNS and GitHub to
# rebuild.
#
# Slamming everything shut to lo-only on any error would be strictly worse than
# that: the rebuild needs DNS and api.github.com, so a box cut down to loopback
# could never rebuild itself and would stay off the network until restarted. The
# hard close is therefore reserved for the case where it is the only safe option
# — an error with no standing deny ruleset to fall back on.
# Both the ERR trap and every explicit error exit go through here. Routing the
# explicit exits through the trap's logic is the point: a bare `exit 1` bypasses
# an ERR trap entirely, so on a first run — where there is no standing ruleset to
# fall back on — it would leave the machine with ACCEPT policies and no rules.
_close_and_exit() {
    local rc="$1" reason="$2"
    trap - ERR
    ipset destroy "$IPSET_TMP" 2>/dev/null || true

    # The failure path has to know the mode, because "fail closed" means
    # different things in each and meant the wrong one in two of the three.
    #
    # In `open` the operator has said this box has no egress filtering. A
    # rebuild that fails — a GitHub meta fetch on a bad afternoon — would have
    # slammed it shut to loopback and ssh, which is not a safer version of what
    # they asked for, it is a different box. The open ruleset stays and the
    # failure is logged.
    #
    # In `observe` the standing ruleset is log-and-permit, and
    # `standing_deny_in_place` reads the OUTPUT policy, which observe also sets
    # to DROP — so the old code took the "previous deny ruleset is left in
    # place" branch and said `deny` about a box that permits everything. The
    # ruleset was right; the sentence was false, which is worse than either.
    case "$EGRESS_MODE" in
        open)
            # "Left as it is" assumes there is something to leave. On the first
            # rebuild of an `open` box there is not: the chains have never been
            # built, INPUT is whatever the kernel started with, and claiming
            # nothing was closed would be true about egress and wrong about the
            # box — it would be wide open inbound as well, which no mode asks
            # for. INPUT is DROP in every mode, so it is placed here.
            if chain_exists iptables "$CHAIN_IN" && [ -n "$(first_rule iptables "$CHAIN_IN")" ]; then
                log "ERROR: ${reason}; the mode is 'open', so the unfiltered egress ruleset is left as it is" >&2
                log "Nothing has been closed. Fix the cause and re-run 'agentbox firewall-check'." >&2
                exit "$rc"
            fi
            log "ERROR: ${reason}; the mode is 'open' and no ruleset has ever been built, so inbound is being closed" >&2
            log "Egress is left unfiltered, as 'open' asks. Only the way IN is being shut." >&2
            ensure_chain iptables "$CHAIN_IN" 2>/dev/null || true
            iptables -w "$IPT_WAIT" -F "$CHAIN_IN" 2>/dev/null || true
            iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -i lo -j ACCEPT 2>/dev/null || true
            iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
            _ogw=$(ip route 2>/dev/null | awk '/^default/ && !seen { print $3; seen = 1 }')
            if [ -n "${_ogw:-}" ]; then
                iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -s "${_ogw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
            else
                iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
            fi
            ensure_jump_first iptables INPUT "$CHAIN_IN" 2>/dev/null || true
            iptables -w "$IPT_WAIT" -P INPUT DROP 2>/dev/null || true
            log "Inbound is closed; ssh from the host still works." >&2
            exit "$rc"
            ;;
        observe)
            if standing_deny_in_place; then
                log "ERROR: ${reason}; the mode is 'observe', so the previous OBSERVE ruleset is left in place — it logs and PERMITS, it does not deny" >&2
                exit "$rc"
            fi
            ;;
    esac

    if standing_deny_in_place; then
        log "ERROR: ${reason}; the previous deny ruleset is left in place" >&2
        exit "$rc"
    fi
    log "ERROR: ${reason}; there is no standing ruleset, so all egress is being closed" >&2

    # The gateway may not be known yet: the two earliest failures happen before
    # HOST_IP is assigned, so derive it here, and fall back to accepting port 22
    # from any source, which is safe behind the hypervisor's NAT.
    local gw="${HOST_IP:-}"
    [ -n "$gw" ] || gw=$(ip route 2>/dev/null | awk '/^default/ && !seen { print $3; seen = 1 }') || gw=""

    # Only the three builtin chains are flushed, never the whole table. `-F`
    # with no argument would empty Docker's chains too, and Docker recreates
    # them only on a daemon restart — so a hard close would leave a machine
    # whose containers stay broken long after the firewall recovered.
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        "$ipt" -w "$IPT_WAIT" -P INPUT DROP   2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -P FORWARD DROP 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -P OUTPUT DROP  2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F INPUT   2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F FORWARD 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F OUTPUT  2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_IN"  2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_OUT" 2>/dev/null || true
        ensure_chain "$ipt" "$CHAIN_FWD" 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F "$CHAIN_IN"  2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F "$CHAIN_OUT" 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -F "$CHAIN_FWD" 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -A "$CHAIN_IN"  -i lo -j ACCEPT 2>/dev/null || true
        "$ipt" -w "$IPT_WAIT" -A "$CHAIN_OUT" -o lo -j ACCEPT 2>/dev/null || true
    done

    # Closing egress must not also lock the operator out. Lima reaches this
    # guest over TCP to port 22, so a lo-only ruleset drops both new
    # `limactl shell` connections and any session already open — including the
    # one needed to run the recovery printed below. These three rules keep that
    # door open without opening egress: no NEW outbound connection is permitted,
    # only replies on connections that already exist.
    iptables -w "$IPT_WAIT" -A "$CHAIN_IN"  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    iptables -w "$IPT_WAIT" -A "$CHAIN_OUT" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    if [ -n "$gw" ]; then
        iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -s "${gw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    else
        iptables -w "$IPT_WAIT" -A "$CHAIN_IN" -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    fi
    # Containers, if any, are cut off with everything else.
    iptables  -w "$IPT_WAIT" -A "$CHAIN_FWD" -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null || true
    ip6tables -w "$IPT_WAIT" -A "$CHAIN_FWD" -j REJECT --reject-with icmp6-adm-prohibited  2>/dev/null || true
    ensure_jumps iptables  2>/dev/null || true
    ensure_jumps ip6tables 2>/dev/null || true

    # The same two independently-gated claims as the provisioner's hard close.
    # F1 was written against that copy; this one had the identical unconditional
    # sentence, and it is the copy the smoke's first-run test exercises. Every
    # command above is `|| true`, so "SSH still works" has to be read back
    # rather than asserted — and the reachability of the rule matters, not just
    # its placement: an AGENTBOX-IN full of accepts is worth nothing if INPUT
    # does not jump to it.
    local hc_policies=1 hc_ssh=1 hc_pol
    for hc_pol in INPUT FORWARD OUTPUT; do
        iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- "-P ${hc_pol} DROP" || hc_policies=0
    done
    [ "$(first_rule iptables INPUT)" = "-A INPUT -j ${CHAIN_IN}" ] || hc_ssh=0
    iptables -w "$IPT_WAIT" -S "$CHAIN_IN" 2>/dev/null | grep -q -- '--dport 22 -j ACCEPT' || hc_ssh=0
    iptables -w "$IPT_WAIT" -S "$CHAIN_IN" 2>/dev/null | grep -q -- 'ctstate RELATED,ESTABLISHED -j ACCEPT' || hc_ssh=0

    if [ "$hc_policies" -eq 1 ]; then
        log "Egress is closed." >&2
    else
        log "ERROR: egress may be OPEN — the policies are not all DROP." >&2
    fi
    if [ "$hc_ssh" -eq 1 ]; then
        log "SSH from the host still works." >&2
    else
        log "ERROR: you may be LOCKED OUT — INPUT does not reach ${CHAIN_IN}, or the ssh accept is missing." >&2
        log "A shell will not help: fix it from the hypervisor console, or destroy and recreate the instance." >&2
        log "From a console: 'iptables -P INPUT ACCEPT; iptables -I INPUT 1 -j ${CHAIN_IN}'." >&2
    fi
    # Unchanged, and deliberately so: in THIS state the OUTPUT policy is what
    # blocks — the hard close leaves AGENTBOX-OUT holding only the loopback and
    # established accepts, with no terminal REJECT — so the policy alone
    # reopens egress. The chain flush that the emptied-allowlist recovery needs
    # is a different state and a different remedy; see docs/decisions.md.
    log "Recovery: 'sudo iptables -P OUTPUT ACCEPT; sudo iptables -F', then 'sudo systemctl restart agent-box-firewall.service'." >&2
    log "If this instance runs Docker, add 'sudo systemctl restart docker' — flushing the table above empties Docker's own chains and only a daemon restart puts them back." >&2
    exit "$rc"
}

fail_closed() {
    local rc=$?
    _close_and_exit "$rc" "the rebuild failed (exit ${rc})"
}

# Use instead of `exit 1` anywhere after the trap is installed.
die_fw() {
    _close_and_exit 1 "$*"
}

trap fail_closed ERR

# ---------------------------------------------------------------------------
# Inputs: the allowlist, the resolvers, the host gateway, the uplink
# ---------------------------------------------------------------------------

# Every non-comment, non-blank token in an allowlist file, whatever its form.
read_allowlist_raw() {
    local file="$1"
    [ -f "$file" ] || return 0
    sed -e 's/#.*$//' -e 's/[[:space:]]//g' "$file" | grep -v '^$' || true
}

# Three line forms now, and they are classified rather than filtered:
#
#   api.example.com    an exact name. Pre-resolved on every rebuild, so the box
#                      works before anything has looked it up, and also handed
#                      to dnsmasq so a rotated address is picked up live.
#   10.0.0.0/8         a CIDR. Added to the set directly; no resolution needed.
#   .staging.example   a suffix (leading dot, or a `*.` prefix). Cannot be
#   *.staging.example  pre-resolved — that is the whole point of it — so it
#                      exists only as a dnsmasq rule, and the set gains an
#                      address the first time the guest looks one up.
#
# An unrecognised line is reported rather than silently dropped, which the old
# grep-filter did.
# Every octet 0-255 and the prefix 0-32. Shape is not validity.
cidr4_in_range() {
    local a="${1%%/*}" p="${1##*/}" o
    [ "$p" -le 32 ] 2>/dev/null || return 1
    local IFS=.
    # shellcheck disable=SC2086  # splitting on dots is the point.
    set -- $a
    [ $# -eq 4 ] || return 1
    for o in "$@"; do
        [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

classify_allowlist_line() {
    local t="$1"
    case "$t" in
        */*)
            # CIDR, v4 or v6, with the RANGES checked and not only the shape.
            # `999.1.2.3/99` matched the old pattern and went to `ipset add`,
            # which failed — and a failed add under `set -e` took the whole
            # rebuild down, so one typo in allowlist.local closed the box. A
            # malformed line is a warning and a skip now, never a rebuild
            # failure.
            if printf '%s' "$t" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'; then
                if cidr4_in_range "$t"; then printf 'cidr4'; else printf 'bad'; fi
            elif printf '%s' "$t" | grep -qE '^[0-9A-Fa-f:]+/[0-9]{1,3}$'; then
                if [ "${t##*/}" -le 128 ] 2>/dev/null; then printf 'cidr6'; else printf 'bad'; fi
            else
                printf 'bad'
            fi ;;
        \*.*|.*)
            # The same hostname grammar as an exact name, applied to what is
            # left after the dot. `.exa mple..com` reached dnsmasq unchecked
            # before, and a line dnsmasq rejects is a resolver that will not
            # start — one bad character in allowlist.local taking the box's
            # name resolution with it. A bad line never reaches the file.
            if valid_hostname "$(suffix_domain "$t")"; then
                printf 'suffix'
            else
                printf 'bad'
            fi ;;
        *)
            if valid_hostname "$t"; then
                printf 'name'
            else
                printf 'bad'
            fi ;;
    esac
}

# `.staging.example` and `*.staging.example` both mean the same thing to
# dnsmasq, which wants the bare domain.
suffix_domain() {
    printf '%s' "${1#\*}" | sed 's/^\.//'
}

# A real hostname: labels of letters, digits and hyphens, not starting or
# ending with a hyphen, joined by SINGLE dots.
#
# The looser pattern this replaces allowed a dot anywhere in the middle, so
# `example..com` passed — and it passed because whitespace is stripped from
# every line before validation, which turns `.exa mple..com` into something
# that then looks almost plausible. An empty label is not a hostname, and the
# check that is supposed to stop a bad line reaching dnsmasq has to know that.
valid_hostname() {
    printf '%s' "${1:-}" \
        | grep -qE '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$'
}

[ -f "$ALLOWLIST_BASE" ] || die_fw "allowlist not found at ${ALLOWLIST_BASE}"

ALL_LINES=$(read_allowlist_raw "$ALLOWLIST_BASE")
if [ -f "$ALLOWLIST_LOCAL" ]; then
    log "Reading local allowlist ${ALLOWLIST_LOCAL}"
    ALL_LINES=$(printf '%s\n%s\n' "$ALL_LINES" "$(read_allowlist_raw "$ALLOWLIST_LOCAL")")
else
    log "No local allowlist at ${ALLOWLIST_LOCAL} (that is fine)"
fi
# `|| true` so an empty result reaches the explicit check below instead of
# killing the script through pipefail with no explanation.
ALL_LINES=$(printf '%s\n' "$ALL_LINES" | grep -v '^$' | sort -u || true)

DOMAINS=""
CIDRS4=""
CIDRS6=""
SUFFIXES=""
BAD_LINES=""
while read -r _line; do
    [ -n "$_line" ] || continue
    case "$(classify_allowlist_line "$_line")" in
        name)   DOMAINS=$(printf '%s\n%s' "$DOMAINS" "$_line") ;;
        cidr4)  CIDRS4=$(printf '%s\n%s' "$CIDRS4" "$_line") ;;
        cidr6)  CIDRS6=$(printf '%s\n%s' "$CIDRS6" "$_line") ;;
        suffix) SUFFIXES=$(printf '%s\n%s' "$SUFFIXES" "$(suffix_domain "$_line")") ;;
        *)      BAD_LINES=$(printf '%s\n%s' "$BAD_LINES" "$_line") ;;
    esac
done < <(printf '%s\n' "$ALL_LINES")
DOMAINS=$(printf '%s\n' "$DOMAINS" | grep -v '^$' | sort -u || true)
CIDRS4=$(printf '%s\n' "$CIDRS4" | grep -v '^$' | sort -u || true)
CIDRS6=$(printf '%s\n' "$CIDRS6" | grep -v '^$' | sort -u || true)
SUFFIXES=$(printf '%s\n' "$SUFFIXES" | grep -v '^$' | sort -u || true)
BAD_LINES=$(printf '%s\n' "$BAD_LINES" | grep -v '^$' | sort -u || true)

[ -n "$DOMAINS" ] || die_fw "the allowlist holds no resolvable names"

log "Allowlisted names:"
printf '%s\n' "$DOMAINS" | sed 's/^/  /'
if [ -n "$CIDRS4" ]; then
    log "Allowlisted address ranges:"
    printf '%s\n' "$CIDRS4" | sed 's/^/  /'
fi
if [ -n "$CIDRS6" ]; then
    # Accepted and reported as inert, per the spec: v6 egress is closed
    # entirely, so a v6 range cannot admit anything until that changes.
    log "IPv6 ranges accepted but INERT while v6 egress is closed:"
    printf '%s\n' "$CIDRS6" | sed 's/^/  /'
fi
if [ -n "$SUFFIXES" ]; then
    log "Allowlisted domain suffixes (matched live, as the guest resolves them):"
    printf '%s\n' "$SUFFIXES" | sed 's/^/  /'
fi
if [ -n "$BAD_LINES" ]; then
    log "WARN: allowlist lines in no recognised form, ignored:"
    printf '%s\n' "$BAD_LINES" | sed 's/^/  /'
fi

# The only resolvers the guest may talk to. Without this restriction port 53 is
# an open channel to any host on the internet: a query name is data, and a
# lookup against an attacker-controlled resolver never touches an allowlisted
# address.
#
# Ubuntu may point /etc/resolv.conf at systemd-resolved on 127.0.0.53, in which
# case the addresses that actually leave the machine are the upstream servers in
# /run/systemd/resolve/resolv.conf, so both files are consulted. Docker reads
# the same second file for containers on the default bridge, which is why the
# forward chain permits exactly these addresses too.
collect_resolvers() {
    local f
    for f in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
        [ -r "$f" ] || continue
        awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' "$f" || true
    done | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' \
         | grep -v '^127\.' \
         | sort -u || true
}

RESOLVERS=$(collect_resolvers)

HOST_IP=$(ip route | awk '/^default/ && !seen { print $3; seen = 1 }')
[ -n "$HOST_IP" ] || die_fw "failed to detect the default gateway"
log "Host gateway: ${HOST_IP}"

# Resolved once, here, so the restore file and the resolver config cannot
# disagree about where containers should be sending their queries.
DNSMASQ_BRIDGE=$(docker_bridge_addr)
[ -z "$DNSMASQ_BRIDGE" ] || log "Container resolver address: ${DNSMASQ_BRIDGE}"

UPLINK=$(uplink_iface || true)
[ -n "$UPLINK" ] || die_fw "failed to detect the uplink interface"
log "Uplink interface: ${UPLINK}"

if [ -z "$RESOLVERS" ]; then
    # A loopback-only resolv.conf with no discoverable upstream: Lima's host
    # resolver lives on the gateway, so fall back to that rather than opening
    # port 53 to everything.
    RESOLVERS="$HOST_IP"
    log "No non-loopback resolver found; falling back to the gateway"
fi
log "Permitted resolvers:"
printf '%s\n' "$RESOLVERS" | sed 's/^/  /'

# ---------------------------------------------------------------------------
# Build the new address set beside the live one
# ---------------------------------------------------------------------------

# The live set must exist for `ipset swap` to work; -exist makes this a no-op
# on every run after the first.
#
# Exactly as it always was: no timeout on this one. Everything in it is put
# there by this rebuild and replaced by the next swap, which is the lifetime it
# has always had. Giving it a default timeout was the first design; it made
# `ipset create -exist` fail against a set an older box already had without one,
# and the ERR trap turned that into a hard close on upgrade.
# `-exist` is a no-op only when the existing set has the SAME parameters. It is
# an error when they differ, and both directions have now happened on real
# boxes: a set built before the timeout was introduced, and a set built during
# the window when the main set carried one. Under the ERR trap either is a
# rebuild failure that hard-closes the guest on upgrade, for a set that could
# simply have been migrated.
#
# `ipset swap` carries the new header across and works between sets of the same
# TYPE whatever their parameters, so a temp set is all the migration needs.
ensure_set() {
    local name="${1:?}" ; shift
    if ipset create "$name" "$@" -exist 2>/dev/null; then
        return 0
    fi
    log "Set ${name} exists with different parameters; migrating it"
    local mig="${name}-migrate"
    ipset destroy "$mig" 2>/dev/null || true
    ipset create "$mig" "$@"
    ipset swap "$mig" "$name"
    ipset destroy "$mig"
}

ensure_set "$IPSET_NAME" hash:net
ipset destroy "$IPSET_TMP" 2>/dev/null || true
ipset create "$IPSET_TMP" hash:net

# The resolver's set. Created if absent and otherwise left exactly alone: the
# rebuild must never swap it, copy it, or clear it except when the suffix list
# itself changes, which is handled after the config is written.
ensure_set "$IPSET_RESOLVED" hash:net timeout "$RESOLVED_TTL"

log "Fetching GitHub IP ranges from ${GH_META_URL}..."
gh_ranges=$(curl -sS -m 20 "$GH_META_URL" || true)
[ -n "$gh_ranges" ] || die_fw "failed to fetch GitHub IP ranges from ${GH_META_URL}"
printf '%s' "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null \
    || die_fw "the GitHub meta response is missing required fields"

# `|| true` on both pipelines: grep exits 1 when it matches nothing, and under
# pipefail that would abort the script. The explicit emptiness check below is
# what fails closed, with a message.
if command -v aggregate >/dev/null 2>&1; then
    gh_cidrs=$(printf '%s' "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9.]+/[0-9]+$' | aggregate -q || true)
else
    gh_cidrs=$(printf '%s' "$gh_ranges" | jq -r '(.web + .api + .git)[]' | grep -E '^[0-9.]+/[0-9]+$' | sort -u || true)
fi
[ -n "$gh_cidrs" ] || die_fw "GitHub meta yielded no IPv4 ranges"

gh_count=0
while read -r cidr; do
    [ -n "$cidr" ] || continue
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        die_fw "invalid CIDR from GitHub meta: ${cidr}"
    fi
    ipset add "$IPSET_TMP" "$cidr" -exist
    gh_count=$((gh_count + 1))
done < <(printf '%s\n' "$gh_cidrs")
log "Added ${gh_count} GitHub ranges"

# The operator's own ranges: no resolution, no expiry, straight in. This is
# what makes "the whole VPN range is reachable" one line instead of a list of
# every host behind it.
cidr_count=0
if [ -n "$CIDRS4" ]; then
    while read -r _c; do
        [ -n "$_c" ] || continue
        ipset add "$IPSET_TMP" "$_c" -exist
        cidr_count=$((cidr_count + 1))
    done < <(printf '%s\n' "$CIDRS4")
    log "Added ${cidr_count} allowlisted address range(s)"
fi

# Resolve the way the applications resolve, and more than once.
#
# Two separate problems, both found by a smoke check that curls each
# allowlisted name from inside the guest under the standing deny.
#
# The first is that `dig` and the rest of the system do not agree. `dig` sends
# its query to the nameserver in resolv.conf — Lima's host resolver on the
# gateway — while curl, Node, apt and every other program go through glibc to
# systemd-resolved on 127.0.0.53, which has its own cache. For a name with
# several A records that barely matters, because the sets overlap. For
# cdn.playwright.dev, an Azure Front Door endpoint that answers with exactly
# ONE A record on a near-zero TTL, the two paths returned different addresses
# in the same second: `dig` saw 150.171.109.113 while curl connected to
# 150.171.109.70. The firewall pinned the first and rejected the second, and
# the symptom is indistinguishable from a name that was never on the allowlist.
# So `getent ahostsv4` — the same path the applications take — is unioned with
# `dig`, which still contributes the fuller multi-address answers.
#
# The second is rotation: a CDN hands out part of its pool per query, so one
# lookup per rebuild pins one slice of it for fifteen minutes. More passes,
# spaced past the TTL, collect more of the pool — spaced deliberately, because
# repeated lookups inside one short TTL are answered from the cache and see the
# same address every time.
#
# The pass count DEFAULTS TO ONE, which is a measurement rather than a
# preference. Three passes turned a first boot from 59 seconds into 611 —
# past Lima's own start budget, so `agentbox create` failed — and on the case
# that prompted all this they changed nothing, because the two-path union had
# already fixed it. Raise AGENT_BOX_RESOLVE_PASSES if a particular CDN needs
# the breadth and the extra boot time is acceptable.
RESOLVE_PASSES="${AGENT_BOX_RESOLVE_PASSES:-1}"
RESOLVE_GAP="${AGENT_BOX_RESOLVE_GAP:-3}"
# `getent` takes no timeout of its own and NSS can block for a long time while
# systemd-resolved is still coming up, which is exactly when this script first
# runs. Bounded, because a firewall rebuild that hangs delays the boot it is
# part of.
GETENT_TIMEOUT="${AGENT_BOX_GETENT_TIMEOUT:-3}"

# Every IPv4 address this guest could reach the name by, from both paths.
resolve_ipv4() {
    local d="$1"
    {
        dig +short +timeout=3 +tries=2 A "$d" 2>/dev/null || true
        timeout "$GETENT_TIMEOUT" getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' || true
    } | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' | sort -u || true
}

resolved_any=0
critical_resolved=0
# Rewritten from scratch by this rebuild, and only moved into place once the
# swap has happened, so the file can never describe a set that is not live.
RESOLVED_TMP="${RESOLVED_STATE}.new"
: > "$RESOLVED_TMP"
pass=1
while [ "$pass" -le "$RESOLVE_PASSES" ]; do
    pass_seen=0
    while read -r domain; do
        [ -n "$domain" ] || continue
        ips=$(resolve_ipv4 "$domain")
        if [ -z "$ips" ]; then
            # One unresolvable name must not take the whole rebuild down; the
            # next timer tick retries, and the live set keeps its contents
            # until the swap. Reported once, not once per pass.
            [ "$pass" -eq 1 ] && log "WARN: could not resolve ${domain}; skipping"
            continue
        fi
        n=0
        while read -r ip; do
            [ -n "$ip" ] || continue
            # -exist makes a repeat harmless, which is what lets the passes
            # accumulate rather than conflict.
            ipset add "$IPSET_TMP" "$ip" -exist
            n=$((n + 1))
        done < <(printf '%s\n' "$ips")
        pass_seen=$((pass_seen + n))
        resolved_any=1
        [ "$domain" = "$CRITICAL_NAME" ] && critical_resolved=1
        # One line per name per pass; verify() unions them. Recorded after the
        # adds, so a line here means those addresses reached the tmp set.
        printf '%s %s\n' "$domain" "$(printf '%s' "$ips" | tr '\n' ' ')" >> "$RESOLVED_TMP"
        [ "$pass" -eq 1 ] && log "Added ${n} address(es) for ${domain}"
    done < <(printf '%s\n' "$DOMAINS")
    if [ "$pass" -gt 1 ]; then
        log "Resolution pass ${pass}: ${pass_seen} address(es) seen"
    fi
    pass=$((pass + 1))
    [ "$pass" -le "$RESOLVE_PASSES" ] && sleep "$RESOLVE_GAP"
done

[ "$resolved_any" -eq 1 ] || die_fw "not a single allowlisted name resolved"
# Not a WARN and a continue. Without this name the box cannot reach the model
# API, which is the one thing it exists to do, and swapping in a set that omits
# it would produce a guest that looks healthy and cannot work. die_fw keeps the
# standing ruleset — the previous set stays live, addresses and all — and exits
# non-zero, so the unit fails visibly and the next tick retries.
[ "$critical_resolved" -eq 1 ] \
    || die_fw "${CRITICAL_NAME} did not resolve; refusing to swap in a set without it"
log "Address set holds $(ipset save "$IPSET_TMP" | grep -c '^add ' || true) entries after ${RESOLVE_PASSES} pass(es)"

# Atomic from the kernel's point of view: rules referencing the set start
# matching the new contents on the next packet, with no gap in between.
# No preserve loop. The resolver's addresses are in a set of their own that
# this swap does not touch, so there is nothing to carry and no window between
# reading and swapping in which an address can be lost.
ipset swap "$IPSET_TMP" "$IPSET_NAME"
ipset destroy "$IPSET_TMP"
# Only now: until the swap, the file would describe a set that is not live.
#
# Checked, not `|| true`. This was the last unchecked write in a mechanism built
# to replace an unchecked assumption, and a silent failure here answers
# allowlist-holds WRONGLY rather than leaving it unanswered: a surviving file
# from a previous rebuild is judged against the set this rebuild just swapped
# in, which passes while proving nothing and then fails spuriously the moment
# the CDN rotates. The stale file goes first, so that if the move fails the next
# verify says "no rebuild has recorded its resolutions" — true and actionable —
# rather than comparing against yesterday.
#
# The swap has already happened, so the live set is this rebuild's; what fails
# here is the record of it. die_fw keeps whatever ruleset is in force and exits
# non-zero, so the unit fails visibly and the next tick retries, with the
# journal naming the real fault instead of the allowlist.
if ! mv -f "$RESOLVED_TMP" "$RESOLVED_STATE"; then
    rm -f "$RESOLVED_STATE" 2>/dev/null || true
    die_fw "could not record the resolutions at ${RESOLVED_STATE}"
fi
log "Address set swapped in"

# --- the resolver that feeds the set -----------------------------------------
#
# dnsmasq on loopback, with `ipset=/<domain>/<set>` for every allowlisted name
# and every allowlisted suffix, so the set follows what the guest actually
# resolves. A suffix line has no other way to work — `.staging.example` cannot
# be pre-resolved — and for exact names it also closes the CDN-rotation gap the
# pinning entry in docs/decisions.md describes, because the address a rebuild
# pinned an hour ago stops being the only one that works.
#
# systemd-resolved stays in front of it, with its own cache turned off, so
# every process keeps resolving through 127.0.0.53 exactly as before and every
# lookup reaches dnsmasq. That configuration is written once by provisioning;
# what is rewritten here, on every rebuild, is only the list of names.
# What dnsmasq should be answering on. Loopback always; on a Docker box also the
# default bridge's address, because a container's resolver is the daemon's and
# a container that cannot reach dnsmasq cannot make a suffix line work — and,
# worse, feeds nothing, so its lookups never authorise anything.
dnsmasq_listen_addrs() {
    printf '%s\n' "$DNSMASQ_ADDR"
    local br
    br=$(docker_bridge_addr)
    [ -z "$br" ] || printf '%s\n' "$br"
}

write_dnsmasq_conf() {
    local tmp="${DNSMASQ_CONF}.new" d a
    install -d -m 0755 "$(dirname "$DNSMASQ_CONF")"
    {
        printf '# Written by agent-box init-firewall.sh. Do not edit.\n'
        while read -r a; do
            [ -n "$a" ] || continue
            printf 'listen-address=%s\n' "$a"
        done < <(dnsmasq_listen_addrs)
        # `bind-dynamic`, not `bind-interfaces`: the docker bridge does not exist
        # when this unit first runs, and `bind-interfaces` binds once at start
        # and never notices an address appearing later. Both still restrict
        # dnsmasq to the addresses named above — this is not `bind-interfaces`
        # traded for listening everywhere.
        printf 'bind-dynamic\n'
        printf 'no-resolv\n'
        # Only the resolvers the firewall already permits. dnsmasq is the one
        # process that talks to them now.
        while read -r ns; do
            [ -n "$ns" ] || continue
            printf 'server=%s\n' "$ns"
        done < <(printf '%s\n' "$RESOLVERS")
        printf 'cache-size=1000\n'
        # Strictly below the set entry's lifetime. dnsmasq feeds the set only on
        # a FORWARDED answer, so a cache that outlived the entry would leave a
        # window where the name still resolves and the address is no longer
        # allowed — the host goes dark and nothing says why.
        printf 'max-cache-ttl=%s\n' "$DNS_CACHE_TTL"
        # An upstream answer that names a private or loopback address would
        # otherwise put the hypervisor gateway, or the guest itself, into the
        # allowed set — an allowlisted suffix becoming a way to reach the host.
        printf 'stop-dns-rebind\n'
        printf 'rebind-localhost-ok\n'
        # Names the guest must never be able to resolve to something local.
        printf 'domain-needed\n'
        printf 'bogus-priv\n'
        # The feed: SUFFIX LINES ONLY.
        #
        # An exact name is not fed, and that is the whole distinction. dnsmasq's
        # `ipset=/example.com/set` matches example.com AND every subdomain of
        # it, so feeding exact names turned every entry in allowlist.base into a
        # wildcard for its subtree — `api.anthropic.com` would have admitted
        # anything.anthropic.com the moment something resolved it. Exact names
        # are pre-resolved by this rebuild and pinned; a dot line is a subtree
        # and follows the resolver. A rotating host that needs the feed says so
        # by being written with the dot.
        while read -r d; do
            [ -n "$d" ] || continue
            printf 'ipset=/%s/%s\n' "$d" "$IPSET_RESOLVED"
        done < <(printf '%s\n' "$SUFFIXES" | grep -v '^$' | sort -u)
        # Query logging, in observe mode only: it is how `agentbox egress-log`
        # puts a name to an address, and it is a privacy and volume cost that
        # the quiet default should not pay.
        if [ "$EGRESS_MODE" = "observe" ]; then
            printf 'log-queries\n'
        fi
    } > "$tmp"
    chown root:root "$tmp" 2>/dev/null || true
    chmod 0644 "$tmp"

    # What verify() compares against: the feed rules alone, so an unrelated
    # edit elsewhere in the file is not mistaken for a tampered allowlist and
    # a tampered allowlist is not hidden by an unrelated edit.
    DNSMASQ_FEED_HASH=$(grep '^ipset=' "$tmp" | sort | sha256sum | awk '{print $1}')
    printf '%s\n' "$DNSMASQ_FEED_HASH" > "$DNSMASQ_HASH_FILE" 2>/dev/null || true

    if [ -f "$DNSMASQ_CONF" ] && cmp -s "$tmp" "$DNSMASQ_CONF"; then
        rm -f "$tmp"
        return 1   # unchanged; no restart needed
    fi
    mv -f "$tmp" "$DNSMASQ_CONF"
    return 0
}

if command -v dnsmasq >/dev/null 2>&1; then
    if write_dnsmasq_conf; then
        # A suffix has been added or removed, so the resolver's set no longer
        # corresponds to the rules that filled it. Flushed rather than reasoned
        # about: an entry fed by a suffix that is no longer allowlisted must
        # stop being reachable, and there is no way to tell from an address
        # which rule put it there. The cost is one re-lookup for the suffixes
        # that ARE still allowed, which is the cheaper mistake.
        ipset flush "$IPSET_RESOLVED" 2>/dev/null || true
        log "Resolver configuration changed; flushed ${IPSET_RESOLVED} and restarting dnsmasq"
        if ! dnsmasq --test --conf-file="$DNSMASQ_CONF" >/dev/null 2>&1; then
            log "ERROR: the generated dnsmasq configuration does not parse" >&2
            die_fw "refusing to restart dnsmasq with a configuration it rejects"
        fi
        systemctl restart dnsmasq 2>/dev/null \
            || log "WARN: could not restart dnsmasq; suffix matching will lag until it restarts" >&2
    else
        log "Resolver configuration unchanged"
    fi
else
    if [ -n "$SUFFIXES" ]; then
        log "WARN: dnsmasq is not installed, so these suffix lines match nothing:" >&2
        printf '%s\n' "$SUFFIXES" | sed 's/^/  /' >&2
    fi
fi

# ---------------------------------------------------------------------------
# Apply the ruleset, one transaction per table
# ---------------------------------------------------------------------------

RULES=$(mktemp)
RULES6=$(mktemp)
trap 'rm -f "$RULES" "$RULES6"' EXIT

# The chains must exist, and be reached, BEFORE the restore sets the policies to
# DROP. On a first run they are empty at this point and traffic falls through to
# the policy, which is still whatever it was; on every later run they already
# hold the previous ruleset, so there is no instant in which the box is both
# closed by policy and missing its accept rules.
for _ipt in iptables ip6tables; do
    ensure_chain "$_ipt" "$CHAIN_IN"
    ensure_chain "$_ipt" "$CHAIN_OUT"
    ensure_chain "$_ipt" "$CHAIN_FWD"
    ensure_jumps "$_ipt"
done

{
    printf '*filter\n'
    # Declaring a builtin chain under --noflush sets its policy and leaves its
    # rules alone; declaring a user chain replaces its contents outright. That
    # asymmetry is what this file is built around, and it is why the accept
    # rules live in chains of our own rather than in INPUT and OUTPUT directly.
    #
    # INPUT is DROP in every mode. `open` is about what the guest may reach and
    # never about what may reach the guest: the ssh accept from the hypervisor
    # gateway stays the only way in, whatever the mode. IPv6 also stays closed
    # in every mode — there is no v6 allowlist to open, so opening it would be
    # opening it entirely rather than opening it to the same places.
    #
    # FORWARD stays DROP in `open` too. Setting it to ACCEPT undid the thing
    # AGENTBOX-FWD's RETURN was chosen to preserve: with the policy open, a
    # packet that falls off the end of Docker's chains is accepted by the
    # policy instead of dropped, so container-to-container isolation and
    # Docker's own rules stop being the last word. Open means this box stops
    # judging egress, which is done in the chains — not that the kernel stops
    # applying what Docker asked for.
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    if [ "$EGRESS_MODE" = "open" ]; then
        printf ':OUTPUT ACCEPT [0:0]\n'
    else
        printf ':OUTPUT DROP [0:0]\n'
    fi
    printf ':%s - [0:0]\n' "$CHAIN_IN"
    printf ':%s - [0:0]\n' "$CHAIN_OUT"
    printf ':%s - [0:0]\n' "$CHAIN_FWD"

    # --- inbound ---------------------------------------------------------
    printf -- '-A %s -i lo -j ACCEPT\n' "$CHAIN_IN"
    # Replies to connections already established in either direction.
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_IN"
    # `limactl shell`. Inbound, port 22 only, and only from the hypervisor's
    # gateway — not the whole subnet, which under vz is the host plus every
    # other VM on the machine.
    printf -- '-A %s -s %s/32 -p tcp --dport 22 -j ACCEPT\n' "$CHAIN_IN" "$HOST_IP"

    # A container asking the guest's resolver. This is INBOUND, which is not
    # where it looks like it belongs: the query is addressed to the bridge's
    # OWN address, so the kernel delivers it locally through INPUT rather than
    # forwarding it. The rule was written into the forward chain first and
    # containers still could not resolve anything, which is how the distinction
    # was found.
    #
    # Narrow on purpose: only from the bridge, only to the bridge address, only
    # port 53. It does not open the guest to the container for anything else.
    #
    # From EVERY docker bridge, not only docker0. A container on a user-defined
    # network — which is every `docker compose` project — arrives on a `br-<id>`
    # interface, so `-i docker0` alone left compose stacks with no DNS at all
    # while the default bridge worked, which is the shape of bug that gets
    # blamed on the application.
    if [ -n "$DNSMASQ_BRIDGE" ]; then
        for _in in docker0 'br+'; do
            printf -- '-A %s -i %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_IN" "$_in" "$DNSMASQ_BRIDGE"
            printf -- '-A %s -i %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_IN" "$_in" "$DNSMASQ_BRIDGE"
        done
    fi

    # --- the guest's own egress -------------------------------------------
    printf -- '-A %s -o lo -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_OUT"

    # Reaching this guest's own containers is not egress. A published port is
    # served by docker-proxy (or by a DNAT to the container address), and either
    # way the packet leaves the host namespace through a Docker bridge, never
    # through the uplink. Named interfaces rather than address ranges, because
    # the bridge subnets are assigned by Docker and change per network.
    printf -- '-A %s -o docker0 -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -o br+ -j ACCEPT\n' "$CHAIN_OUT"

    # DNS, to the configured resolvers only.
    while read -r ns; do
        [ -n "$ns" ] || continue
        printf -- '-A %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_OUT" "$ns"
        printf -- '-A %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_OUT" "$ns"
    done < <(printf '%s\n' "$RESOLVERS")

    # DHCP lease renewal on a long-running instance.
    printf -- '-A %s -p udp --dport 67:68 -j ACCEPT\n' "$CHAIN_OUT"

    # The allowlist. Deliberately no blanket accept toward the host subnet:
    # everything the guest legitimately needs from the host is either an
    # already-established connection, DNS above, or carried over vsock.
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_OUT" "$IPSET_NAME"
    # The resolver's own set, alongside and never merged with it. Two rules
    # rather than two populations in one set: the rebuild owns the first and
    # replaces it wholesale, dnsmasq owns the second and its entries expire.
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_OUT" "$IPSET_RESOLVED"

    # And then the mode decides. Everything above this point is identical in
    # all three: loopback, established, the guest's own containers, DNS to the
    # permitted resolvers, DHCP, and the allowlist itself. What differs is only
    # what happens to a connection that matched none of them.
    case "$EGRESS_MODE" in
        deny)
            # Rejected rather than dropped, so a blocked call fails immediately
            # instead of hanging until a timeout.
            printf -- '-A %s -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_OUT"
            ;;
        observe)
            # Observe relaxes the ALLOWLIST. It does not relax the resolver
            # restriction, and that is a deliberate exception rather than an
            # oversight: port 53 to an arbitrary server is an exfiltration
            # channel whose payload is the query name, so "allowed and logged"
            # would be a channel that carries data out and records only that
            # something was sent. The permitted resolvers were accepted higher
            # up, so anything reaching here on 53 is a foreign one.
            printf -- '-A %s -p udp --dport 53 -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_OUT"
            printf -- '-A %s -p tcp --dport 53 -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_OUT"
            # Log the attempt, then allow it. NEW only, so one connection is one
            # line rather than one per packet.
            #
            # `hashlimit` keyed on destination and port, not a single global
            # `limit`: with one bucket for the whole chain, a chatty host —
            # a telemetry endpoint retrying, or an agent that has noticed the
            # log — exhausts the budget and every OTHER destination goes
            # unrecorded. Per destination, drowning the log costs a new address
            # each time. The limit drops LOG LINES, never packets: the ACCEPT
            # below is unconditional and outside it.
            printf -- '-A %s -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 6/minute --hashlimit-burst 12 --hashlimit-mode dstip,dstport --hashlimit-name %s --hashlimit-htable-expire 600000 -j ACCEPT\n' \
                "$CHAIN_OUT" "abx_egress"
            printf -- '-A %s -m conntrack --ctstate NEW -j LOG --log-prefix "%s" --log-level info\n' \
                "$CHAIN_OUT" "$LOG_PREFIX"
            printf -- '-A %s -j ACCEPT\n' "$CHAIN_OUT"
            ;;
        open)
            printf -- '-A %s -j ACCEPT\n' "$CHAIN_OUT"
            ;;
    esac

    # --- what containers may forward --------------------------------------
    #
    # Reached from DOCKER-USER rule 1, which FORWARD jumps to before anything of
    # Docker's own.
    #
    # Rule 1 is inbound, and it is here because the rest of this chain judges
    # egress only. `docker run -p 8080:80` publishes on 0.0.0.0 by default;
    # Docker DNATs such a packet in PREROUTING, so it is FORWARDed (in = uplink,
    # out = a docker bridge) and never reaches INPUT, whose DROP policy is what
    # implements "nothing the guest listens on is reachable from outside it".
    # Without this rule the RETURN below would hand that packet to
    # DOCKER-FORWARD, which accepts published-port traffic by construction. NEW
    # only: the reply leg of a container's own outbound connection also arrives
    # on the uplink, and is ESTABLISHED.
    #
    # Lima's own --forward is unaffected, and the reason is structural rather
    # than lucky: it is served over ssh, so the connection to the published port
    # is opened by sshd INSIDE the guest and leaves through OUTPUT, never
    # crossing FORWARD from the uplink. Measured both ways in the smoke test.
    #
    # One behaviour change this rule does make, worth knowing before debugging a
    # silent container timeout: conntrack forgets a UDP flow after 30 seconds
    # unreplied, 120 replied. A container that opens a UDP flow to a peer and
    # then hears nothing for longer than that loses its entry, so the peer's
    # next datagram arrives on the uplink as NEW and is dropped rather than
    # returned to DOCKER-FORWARD. Before this rule it would have been accepted.
    # Arguably the rule doing its job; either way, it is where to look.
    # Anything not leaving by the uplink — container to container, a published
    # port coming the other way — is returned unjudged after that, because it is
    # not egress and DOCKER-FORWARD is the chain that decides it. Both rules come
    # from fwd_leading_rules, which docker_hook's fallback also uses.
    while read -r _r; do
        [ -n "$_r" ] || continue
        printf -- '-A %s %s\n' "$CHAIN_FWD" "$_r"
    done < <(fwd_leading_rules "$UPLINK")
    printf -- '-A %s -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n' "$CHAIN_FWD"
    # A container's DNS goes to dnsmasq on the bridge address, and to nothing
    # else. It used to be permitted straight to the upstream resolvers, which
    # meant a container's lookups never passed through dnsmasq and therefore
    # never fed the set — so a suffix line worked in the guest and silently did
    # not work in a container. daemon.json points containers here.
    _br="$DNSMASQ_BRIDGE"
    if [ -n "$_br" ]; then
        printf -- '-A %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$_br"
        printf -- '-A %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$_br"
    else
        # No bridge yet: fall back to the upstreams so a box without Docker,
        # or one whose daemon has not started, still resolves.
        while read -r ns; do
            [ -n "$ns" ] || continue
            printf -- '-A %s -d %s/32 -p udp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$ns"
            printf -- '-A %s -d %s/32 -p tcp --dport 53 -j ACCEPT\n' "$CHAIN_FWD" "$ns"
        done < <(printf '%s\n' "$RESOLVERS")
    fi
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_FWD" "$IPSET_NAME"
    printf -- '-A %s -m set --match-set %s dst -j ACCEPT\n' "$CHAIN_FWD" "$IPSET_RESOLVED"
    # Containers follow the box's mode, for the same reason they follow its
    # allowlist: "what this box may reach" should not have two answers.
    case "$EGRESS_MODE" in
        deny)
            printf -- '-A %s -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_FWD"
            ;;
        observe)
            # Same shape as the guest's own chain, including the DNS exception:
            # a container may reach the permitted resolvers (accepted above) and
            # nothing else on port 53.
            printf -- '-A %s -p udp --dport 53 -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_FWD"
            printf -- '-A %s -p tcp --dport 53 -j REJECT --reject-with icmp-admin-prohibited\n' "$CHAIN_FWD"
            printf -- '-A %s -m conntrack --ctstate NEW -m hashlimit --hashlimit-above 6/minute --hashlimit-burst 12 --hashlimit-mode dstip,dstport --hashlimit-name %s --hashlimit-htable-expire 600000 -j ACCEPT\n' \
                "$CHAIN_FWD" "abx_fwd"
            printf -- '-A %s -m conntrack --ctstate NEW -j LOG --log-prefix "%s" --log-level info\n' \
                "$CHAIN_FWD" "$LOG_PREFIX"
            printf -- '-A %s -j ACCEPT\n' "$CHAIN_FWD"
            ;;
        open)
            # ACCEPT here is the EGRESS LEG only, and that is why it is safe.
            # Everything that is not leaving by the uplink already RETURNed at
            # the top of this chain, back to Docker's own rules and their
            # isolation between networks; what reaches this line is a container
            # talking to the outside, which is exactly what open stops judging.
            # The FORWARD policy is untouched, so anything falling off the end
            # of Docker's chains is still dropped by the kernel.
            printf -- '-A %s -j ACCEPT\n' "$CHAIN_FWD"
            ;;
    esac

    printf 'COMMIT\n'
} > "$RULES"

iptables-restore -w "$IPT_WAIT" --noflush < "$RULES"
log "IPv4 ruleset applied"

# IPv6: no allowlist is maintained for it, so it is closed completely. Not
# best-effort — a failure here fails the unit, because a silently open v6 stack
# is a way around every rule above. Docker's daemon.json sets "ipv6": false, but
# Docker still creates its v6 chains, so the same chain-ownership rule applies:
# only ours are declared here.
{
    printf '*filter\n'
    printf ':INPUT DROP [0:0]\n'
    printf ':FORWARD DROP [0:0]\n'
    printf ':OUTPUT DROP [0:0]\n'
    printf ':%s - [0:0]\n' "$CHAIN_IN"
    printf ':%s - [0:0]\n' "$CHAIN_OUT"
    printf ':%s - [0:0]\n' "$CHAIN_FWD"
    printf -- '-A %s -i lo -j ACCEPT\n' "$CHAIN_IN"
    printf -- '-A %s -o lo -j ACCEPT\n' "$CHAIN_OUT"
    printf -- '-A %s -j REJECT --reject-with icmp6-adm-prohibited\n' "$CHAIN_FWD"
    printf 'COMMIT\n'
} > "$RULES6"

ip6tables-restore -w "$IPT_WAIT" --noflush < "$RULES6"
log "IPv6 ruleset applied (closed)"

# Again, after the restore. The jumps live in chains this script does not own,
# so nothing above can have removed them — but DOCKER-USER may have come into
# existence while the rebuild was running, and this is where that is noticed.
ensure_jumps iptables
ensure_jumps ip6tables
log "Chain jumps in place"

log "Firewall configuration complete"

# The lock covered the ipset swap and the restore, and both are done. verify()
# reads the ruleset and sends probes; it mutates nothing and needs no lock.
# Holding it there was finding T5: two 30-second container probes and two
# 10-second curls can add a hundred seconds to a hold whose waiters are bounded
# at 120 and 30 seconds, so the hook's fallback to the unlocked path happened in
# exactly the window the hook's lock was added for.
# Braces again, for the reason recorded on take_fw_lock: a bare
# `exec 9>&- 2>/dev/null` would make the stderr redirection permanent and
# silence everything verify() has to say below.
{ exec 9>&-; } 2>/dev/null || true
trap - ERR
verify
