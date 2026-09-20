#!/bin/bash
#
# agent-box — guest provisioning. Runs as root on every boot, from the
# `provision` block in lima/agent-box.yaml. Must be idempotent.
#
# Usage: provision.sh <guest-username> <guest-home-directory>
#                     [--docker BOOL] [--playwright BOOL] [--rosetta BOOL]
#
# The first two arguments are supplied by Lima, which expands {{.User}} and
# {{.Home}} in the provision script. They are not guessed: Lima's builtin
# default guest home is /home/<user>.guest (with /home/<user>.linux as an
# accessible alias), not /home/<user>.
#
# The three flags carry the optional profile chosen by `agentbox create`. Each
# arrives as the literal string "true" or "false" through a template parameter.

set -euo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
# Read-only mount of the host's ~/.config/agent-box. May be empty.
CONFIG_DIR="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
BOX_USER="${1:?usage: provision.sh <username> <home> [--docker BOOL] [--playwright BOOL] [--rosetta BOOL]}"
BOX_HOME="${2:?usage: provision.sh <username> <home> [--docker BOOL] [--playwright BOOL] [--rosetta BOOL]}"
shift 2

log() { printf '[agent-box provision] %s\n' "$*"; }

WANT_DOCKER=false
WANT_PLAYWRIGHT=false
WANT_ROSETTA=false
# The create-time mode. Written to the guest ONCE, below, and never overwritten:
# `agentbox egress` changes the running box's mode, and Lima re-runs this script
# on every start with the original create-time parameters, so overwriting here
# would silently undo a deliberate change on the next restart.
WANT_EGRESS=deny
EGRESS_MODE_FILE=/etc/agent-box/egress-mode

as_bool() {
    case "${1:-}" in
        true|True|TRUE|yes|1)   printf 'true' ;;
        false|False|FALSE|no|0) printf 'false' ;;
        *) log "ERROR: expected true or false, got '${1:-}'" >&2; exit 1 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --docker)     WANT_DOCKER=$(as_bool "${2:-}"); shift 2 ;;
        --playwright) WANT_PLAYWRIGHT=$(as_bool "${2:-}"); shift 2 ;;
        --rosetta)    WANT_ROSETTA=$(as_bool "${2:-}"); shift 2 ;;
        --egress)
            case "${2:-}" in
                deny|observe|open) WANT_EGRESS="$2" ;;
                *) log "ERROR: --egress expects deny, observe or open, got '${2:-}'" >&2; exit 1 ;;
            esac
            shift 2 ;;
        *) log "ERROR: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

log "profile: docker=${WANT_DOCKER} playwright=${WANT_PLAYWRIGHT} rosetta=${WANT_ROSETTA} egress=${WANT_EGRESS}"

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root" >&2
    exit 1
fi

if [ ! -d "$BOX_DIR/guest" ]; then
    log "ERROR: ${BOX_DIR} is not mounted (expected the agent-box checkout)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0. Network access during provisioning
# ---------------------------------------------------------------------------
#
# Provisioning re-runs on every `limactl start`. From the second boot onward the
# firewall service is enabled and comes up at multi-user.target, and
# archive.ubuntu.com is not on the allowlist — so any apt work on a later boot
# would fail and take the whole start down with it. Whenever there is genuinely
# something to download, the firewall is stopped for the duration and started
# again at the end. When there is nothing to do, it is never touched.

FIREWALL_UNIT="agent-box-firewall.service"
FIREWALL_WAS_STOPPED=0
# The chains init-firewall.sh owns. Everything this script does to the filter
# table is confined to these, for the same reason the firewall script is:
# `iptables -F` with no argument empties Docker's chains as well, and Docker
# puts them back only when the daemon restarts.
AGENTBOX_CHAINS=(AGENTBOX-IN AGENTBOX-OUT AGENTBOX-FWD)
# The same constant and the same reasoning as guest/init-firewall.sh. iptables
# 1.8.x without -w does not queue on a held xtables lock: it prints "Another app
# is currently holding the xtables lock" and exits non-zero. Every call below
# used to discard that with `2>/dev/null || true`, in the one function whose job
# is to close a box that has just failed to provision — while dockerd, restarted
# moments earlier, is reinstalling its own rules and holding that very lock.
IPT_WAIT=5

# Run one iptables command, tolerate its failure, and SAY SO. The blanket
# `2>/dev/null || true` was finding T3's other half: a failure produced no
# output at all and the summary line asserted the outcome rather than checking
# it. Returns 0 always; the caller reads FW_CLOSE_ERRORS.
FW_CLOSE_ERRORS=0
ipt_try() {
    local out
    if out=$("$@" 2>&1); then
        return 0
    fi
    FW_CLOSE_ERRORS=$((FW_CLOSE_ERRORS + 1))
    log "WARN: firewall command failed: $* :: $(printf '%s' "$out" | tr '\n' ' ')" >&2
    return 0
}

open_network_for_provisioning() {
    [ "$FIREWALL_WAS_STOPPED" -eq 0 ] || return 0
    if systemctl is-active --quiet "$FIREWALL_UNIT" 2>/dev/null; then
        log "Stopping ${FIREWALL_UNIT} for the duration of the downloads"
        systemctl stop "$FIREWALL_UNIT" || true
        # Stopping a oneshot unit does not undo its rules.
        local ipt chain
        for ipt in iptables ip6tables; do
            command -v "$ipt" >/dev/null 2>&1 || continue
            ipt_try "$ipt" -w "$IPT_WAIT" -P INPUT ACCEPT
            ipt_try "$ipt" -w "$IPT_WAIT" -P FORWARD ACCEPT
            ipt_try "$ipt" -w "$IPT_WAIT" -P OUTPUT ACCEPT
            for chain in "${AGENTBOX_CHAINS[@]}"; do
                ipt_try "$ipt" -w "$IPT_WAIT" -F "$chain"
            done
        done
        FIREWALL_WAS_STOPPED=1
    fi
}

# Opening the network above is the same shape as the failure this project fixed
# in init-firewall.sh, just moved into the provisioner: from here to the restart
# at the very end, any failure under `set -e` would leave the VM with no rules
# and ACCEPT policies. agent-run refuses to run in that state, but it is exactly
# the state someone opens `agentbox shell` to debug in — with unrestricted
# egress. So the window is closed on the way out, whatever the exit status.
close_network_on_exit() {
    local rc=$?
    trap - EXIT
    [ "$FIREWALL_WAS_STOPPED" -eq 1 ] || exit "$rc"
    if [ "$rc" -eq 0 ]; then
        exit "$rc"
    fi
    log "Provisioning failed (exit ${rc}) with the firewall stopped; restoring it"
    if systemctl restart "$FIREWALL_UNIT"; then
        log "Firewall restored"
    else
        log "ERROR: could not restart ${FIREWALL_UNIT}; closing all egress instead" >&2
        local gw ipt chain
        gw=$(ip route 2>/dev/null | awk '/^default/ && !seen { print $3; seen = 1 }') || gw=""
        # Only the three builtin chains, never the whole table. See the comment
        # on AGENTBOX_CHAINS above.
        FW_CLOSE_ERRORS=0
        for ipt in iptables ip6tables; do
            command -v "$ipt" >/dev/null 2>&1 || continue
            ipt_try "$ipt" -w "$IPT_WAIT" -P INPUT DROP
            ipt_try "$ipt" -w "$IPT_WAIT" -P FORWARD DROP
            ipt_try "$ipt" -w "$IPT_WAIT" -P OUTPUT DROP
            ipt_try "$ipt" -w "$IPT_WAIT" -F INPUT
            ipt_try "$ipt" -w "$IPT_WAIT" -F FORWARD
            ipt_try "$ipt" -w "$IPT_WAIT" -F OUTPUT
            for chain in "${AGENTBOX_CHAINS[@]}"; do
                "$ipt" -w "$IPT_WAIT" -N "$chain" 2>/dev/null || true
                ipt_try "$ipt" -w "$IPT_WAIT" -F "$chain"
            done
            ipt_try "$ipt" -w "$IPT_WAIT" -A AGENTBOX-IN  -i lo -j ACCEPT
            ipt_try "$ipt" -w "$IPT_WAIT" -A AGENTBOX-OUT -o lo -j ACCEPT
            ipt_try "$ipt" -w "$IPT_WAIT" -I INPUT  1 -j AGENTBOX-IN
            ipt_try "$ipt" -w "$IPT_WAIT" -I OUTPUT 1 -j AGENTBOX-OUT
            if "$ipt" -w "$IPT_WAIT" -n -L DOCKER-USER >/dev/null 2>&1; then
                ipt_try "$ipt" -w "$IPT_WAIT" -I DOCKER-USER 1 -j AGENTBOX-FWD
            fi
        done
        # Same reasoning as the hard close in init-firewall.sh: egress stays
        # shut, but the operator can still get in to see why. A VM that failed
        # to provision is exactly the one someone needs a shell on.
        ipt_try iptables -w "$IPT_WAIT" -A AGENTBOX-IN  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ipt_try iptables -w "$IPT_WAIT" -A AGENTBOX-OUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        local ssh_rule_placed=0
        if [ -n "$gw" ]; then
            iptables -w "$IPT_WAIT" -A AGENTBOX-IN -s "${gw}/32" -p tcp --dport 22 -j ACCEPT 2>/dev/null \
                && ssh_rule_placed=1
        else
            iptables -w "$IPT_WAIT" -A AGENTBOX-IN -p tcp --dport 22 -j ACCEPT 2>/dev/null \
                && ssh_rule_placed=1
        fi
        [ "$ssh_rule_placed" -eq 1 ] || FW_CLOSE_ERRORS=$((FW_CLOSE_ERRORS + 1))
        ipt_try iptables  -w "$IPT_WAIT" -A AGENTBOX-FWD -j REJECT --reject-with icmp-admin-prohibited
        ipt_try ip6tables -w "$IPT_WAIT" -A AGENTBOX-FWD -j REJECT --reject-with icmp6-adm-prohibited

        # Read back rather than assert, and read back TWO separate things.
        #
        # The old code printed "Egress is closed" unconditionally. The first fix
        # gated it on the policies plus `ssh_rule_placed`, which is the rule
        # having been appended INTO AGENTBOX-IN — and said nothing about whether
        # INPUT still jumps there. The hard close flushes INPUT and reinstates
        # the jump through ipt_try, whose whole contract is that a failure is
        # tolerated and counted, so "policies took" and "the append took" are
        # both satisfiable with the jump missing. INPUT is then empty with
        # policy DROP: the ssh ACCEPT, the loopback ACCEPT and the
        # ESTABLISHED/RELATED ACCEPT all sit in a chain no packet reaches, and
        # both new and existing SSH connections die.
        #
        # That is the worse direction. An open box can be closed from a shell; a
        # locked-out box cannot be fixed from one at all. So the two claims are
        # gated independently and neither vouches for the other.
        local policies_ok=1 pol
        for pol in INPUT FORWARD OUTPUT; do
            iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -qx -- "-P ${pol} DROP" || policies_ok=0
        done

        # Reachability, not just placement: rule 1 of INPUT must be the jump,
        # and AGENTBOX-IN must hold both the port 22 accept and the conntrack
        # accept that keeps an already-open session alive.
        local ssh_ok=1
        [ "$(iptables -w "$IPT_WAIT" -S INPUT 2>/dev/null | sed -n '2p')" = "-A INPUT -j AGENTBOX-IN" ] || ssh_ok=0
        iptables -w "$IPT_WAIT" -S AGENTBOX-IN 2>/dev/null | grep -q -- '--dport 22 -j ACCEPT' || ssh_ok=0
        iptables -w "$IPT_WAIT" -S AGENTBOX-IN 2>/dev/null | grep -q -- 'ctstate RELATED,ESTABLISHED -j ACCEPT' || ssh_ok=0
        [ "$ssh_rule_placed" -eq 1 ] || ssh_ok=0

        if [ "$policies_ok" -eq 1 ]; then
            log "Egress is closed." >&2
        else
            log "ERROR: egress may be OPEN — the policies are not all DROP." >&2
        fi
        if [ "$ssh_ok" -eq 1 ]; then
            log "SSH from the host still works." >&2
        else
            log "ERROR: you may be LOCKED OUT of this VM — INPUT does not reach AGENTBOX-IN, or the ssh accept is missing." >&2
            log "A shell will not help: fix it from the hypervisor console, or destroy and recreate the instance." >&2
        fi
        if [ "$policies_ok" -eq 1 ] && [ "$ssh_ok" -eq 1 ]; then
            [ "$FW_CLOSE_ERRORS" -eq 0 ] \
                || log "NOTE: ${FW_CLOSE_ERRORS} firewall command(s) failed on the way there; see the WARN lines above." >&2
        else
            log "The hard close did not complete (${FW_CLOSE_ERRORS} command(s) failed); see the WARN lines above." >&2
            log "Recovery: 'sudo iptables -P INPUT ACCEPT; sudo iptables -I INPUT 1 -j AGENTBOX-IN', then 'sudo systemctl restart ${FIREWALL_UNIT}'." >&2
            log "Check 'sudo iptables -S' before using this box." >&2
            log "If this instance runs Docker, add 'sudo systemctl restart docker'." >&2
        fi
    fi
    exit "$rc"
}
trap close_network_on_exit EXIT

# ---------------------------------------------------------------------------
# 1. Packages
# ---------------------------------------------------------------------------

# tmux is not decoration: `agentbox run` is detached by default and every
# interactive session is meant to be left and come back to, so a box without it
# has no way to hold a run that outlives the shell that started it.
# procps is not decoration either: `agentbox stop-run` finds the CLI by walking
# the pane's process tree with pgrep, and without it only the wrapper script is
# signalled — the model never sees the interrupt, the wait runs its full course
# and the session is killed mid-write.
# dnsmasq is on every box, not only ones with suffix lines. It is what makes the
# address set follow what the guest actually resolves, which is the fix for a
# rotating CDN as much as it is the mechanism for a domain suffix.
REQUIRED_PKGS=(iptables ipset dnsutils jq curl git ca-certificates tmux procps dnsmasq)
# gnupg is only needed to check the Docker repository key's fingerprint, so it
# is not asked for on an instance that does not want Docker.
#
# Nothing else is added to this list, and that is deliberate. The baseline
# toolchain needs five archive packages — xz-utils, unzip, zip, python3-venv,
# python3-pip — and guest/install-toolchain.sh installs them itself, under the
# standing deny. Listed here instead they would be `missing_required` on every
# box created before this version, and a missing required package is exactly
# what reopens the network: every existing box would spend one apt run with
# ACCEPT policies and the AGENTBOX chains flushed, the first time it started
# under the new checkout. No box reopens its firewall window for a formatter.
[ "$WANT_DOCKER" = true ] && REQUIRED_PKGS+=(gnupg)
# `aggregate` merges the GitHub CIDR list; the firewall works without it.
OPTIONAL_PKGS=(aggregate)
# Attempted once, then never again, and this marker is what makes "once" true.
# An optional package that is permanently unavailable — dropped from the
# archive, missing on this architecture — is missing on every subsequent boot
# too. Folded into the same `missing` list as the required ones, it would call
# open_network_for_provisioning() at every single start, so a box would spend an
# apt run with ACCEPT policies and the AGENTBOX chains flushed, every morning,
# for ever, to retry something that cannot succeed. Only a missing REQUIRED
# package may reopen the network now.
OPTIONAL_MARKER=/var/lib/agent-box/optional-pkgs-attempted
install -d -m 0755 /var/lib/agent-box

# Masked BEFORE apt can start it. dnsmasq's postinst starts the service with
# the stock configuration, which listens on every interface; on a box that
# reaches the internet through a shared subnet that is an open resolver, for as
# long as provisioning takes. Unmasked in section 1e once our own config is
# written and has passed `dnsmasq --test`.
if ! systemctl is-enabled dnsmasq >/dev/null 2>&1; then
    systemctl mask dnsmasq >/dev/null 2>&1 || true
fi

missing_required=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing_required+=("$pkg")
done
missing_optional=()
for pkg in "${OPTIONAL_PKGS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing_optional+=("$pkg")
done

try_optional=0
if [ ${#missing_optional[@]} -gt 0 ] && [ ! -f "$OPTIONAL_MARKER" ]; then
    try_optional=1
fi

if [ ${#missing_required[@]} -gt 0 ] || [ "$try_optional" -eq 1 ]; then
    if [ ${#missing_required[@]} -gt 0 ]; then
        log "Installing: ${missing_required[*]}"
    fi
    if [ "$try_optional" -eq 1 ]; then
        log "Attempting optional packages, once: ${missing_optional[*]}"
    fi
    open_network_for_provisioning
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=180 update
    if [ ${#missing_required[@]} -gt 0 ]; then
        apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${REQUIRED_PKGS[@]}"
    fi
    if [ "$try_optional" -eq 1 ]; then
        # Best-effort, so a missing one cannot fail the boot — and recorded
        # either way, because the marker means "attempted", not "succeeded".
        if apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${OPTIONAL_PKGS[@]}"; then
            printf 'installed %s at %s\n' "${OPTIONAL_PKGS[*]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPTIONAL_MARKER"
        else
            log "WARN: optional packages unavailable; continuing, and not retrying on later boots"
            log "WARN: to retry, delete ${OPTIONAL_MARKER} and start the box again"
            printf 'attempted and FAILED %s at %s\n' "${OPTIONAL_PKGS[*]}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OPTIONAL_MARKER"
        fi
    fi
else
    log "All packages already present"
fi

# ---------------------------------------------------------------------------
# 1b. Docker Engine, rootful, from Docker's own apt repository
# ---------------------------------------------------------------------------
#
# Rootful rather than the rootless engine Lima's own docker template installs.
# Rootless Docker does its packet filtering inside a network namespace and
# populates none of the DOCKER* chains in the host namespace, so there would be
# no DOCKER-USER for the egress allowlist to hook into and no way to hold
# containers to it. See docs/decisions.md.
#
# The five packages are the set Docker's own install page names. The
# repository key is fetched once and its fingerprint checked before apt is ever
# pointed at the repository, so a substituted key is caught here rather than
# trusted silently.

# Docker's release signing key, "Docker Release (CE deb) <docker@docker.com>",
# rsa4096, created 2017-02-22. Docker's current install pages give the key's
# URL but no longer print the fingerprint next to it, so this value is pinned
# from the key served at that URL and read back with `gpg --show-keys` in this
# guest on 2026-09-05. It is a pin against a future substitution, not a proof
# of the key's provenance today — that distinction is stated in
# docs/decisions.md rather than glossed over.
DOCKER_GPG_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

install_docker() {
    local missing_docker=() pkg fprs
    for pkg in "${DOCKER_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing_docker+=("$pkg")
    done

    if [ ${#missing_docker[@]} -gt 0 ]; then
        log "Installing Docker Engine: ${missing_docker[*]}"
        open_network_for_provisioning
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc.new
        fprs=$(gpg --show-keys --with-colons --fingerprint /etc/apt/keyrings/docker.asc.new \
                   | awk -F: '/^fpr:/ {print $10}')
        if ! printf '%s\n' "$fprs" | grep -qx "$DOCKER_GPG_FPR"; then
            rm -f /etc/apt/keyrings/docker.asc.new
            log "ERROR: the key at download.docker.com does not carry ${DOCKER_GPG_FPR}." >&2
            log "ERROR: fingerprints seen: $(printf '%s' "$fprs" | tr '\n' ' ')" >&2
            return 1
        fi
        mv -f /etc/apt/keyrings/docker.asc.new /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        log "Docker repository key verified (${DOCKER_GPG_FPR})"

        local codename
        # shellcheck disable=SC1091  # a distribution file, not part of this repo.
        codename=$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
        [ -n "$codename" ] || { log "ERROR: could not read the Ubuntu codename from /etc/os-release" >&2; return 1; }
        cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=180 update
        apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${DOCKER_PKGS[@]}"
    else
        log "Docker Engine already installed"
    fi

    # IPv6 is closed at the firewall and no v6 allowlist is maintained, so a
    # container must not have a v6 address to reach anything by. Stated here as
    # well, rather than relied on as a default that could change.
    #
    # And `dns`: containers must resolve through the guest's dnsmasq, not
    # through the host's resolver directly. Two reasons, and the second is the
    # one that bites. A container that bypasses dnsmasq never feeds the address
    # set, so a suffix line does not work inside a container at all — the
    # feature silently applies to the guest and not to the thing the guest was
    # built to run. And once the firewall permits DNS only to the bridge
    # address, a container using the daemon's inherited resolver has no DNS at
    # all. 172.17.0.1 is docker0's address, which the daemon creates before any
    # container starts.
    install -d -m 0755 /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "ipv6": false,
  "dns": ["172.17.0.1"]
}
EOF
    # "iptables" is deliberately absent: it defaults to true, and true is what
    # populates DOCKER-USER — the chain the egress allowlist hooks into. Setting
    # it false would leave containers unfiltered by anything.

    # Membership takes effect on the next login, which for this VM means the
    # next `agentbox shell`, not this provisioning run.
    if id -nG "$BOX_USER" | tr ' ' '\n' | grep -qx docker; then
        log "${BOX_USER} is already in the docker group"
    else
        log "Adding ${BOX_USER} to the docker group"
        usermod -aG docker "$BOX_USER"
    fi

    systemctl enable docker.service >/dev/null 2>&1 || true
    systemctl enable containerd.service >/dev/null 2>&1 || true
}

if [ "$WANT_DOCKER" = true ]; then
    install_docker
else
    log "Docker not requested for this instance"
fi

# ---------------------------------------------------------------------------
# 1c. The baseline toolchain is NOT installed here
# ---------------------------------------------------------------------------
#
# Node, Playwright's system libraries and the browser used to be installed in
# this section: inside the open network window, and only when --playwright was
# passed at create time. Both halves of that were wrong.
#
# A create-time flag can never reach an existing box — create params are frozen
# for a box's life — so a toolchain that is meant to be on every box has to be
# unconditional provisioner code instead of a profile.
#
# And a download that happens in the open window succeeds even when its host is
# off the allowlist, so nothing notices until an agent needs the same host later.
# Installing under the standing deny makes a create a live test of every
# allowlist entry, which is the argument §6 already makes about plugins.
#
# So the whole toolchain — Node included — is installed by
# guest/install-toolchain.sh in §4b below, after the firewall is up, from the
# versions and digests in guest/toolchain.pins. --playwright is still parsed,
# because lima/agent-box.yaml always passes it and as_bool() exits 1 on an
# unknown value, and it now changes nothing.

if [ "$WANT_PLAYWRIGHT" = true ]; then
    log "note: --playwright is ignored; the toolchain is baseline on every box"
fi

if [ "$WANT_ROSETTA" = true ]; then
    # Nothing to install: Rosetta is a host feature Lima exposes to the guest,
    # enabled by `limactl create --rosetta`, which mounts it and registers it
    # with binfmt_misc. All this can do is say whether it actually arrived.
    if [ -e /proc/sys/fs/binfmt_misc/rosetta ]; then
        log "Rosetta is registered with binfmt_misc"
    else
        log "WARN: --rosetta was requested but /proc/sys/fs/binfmt_misc/rosetta is absent; linux/amd64 images will not run"
    fi
fi

# ---------------------------------------------------------------------------
# 1e. The egress mode, and the resolver that feeds the allowlist
# ---------------------------------------------------------------------------

# Written once. `agentbox egress` owns it afterwards, and Lima re-runs this
# script with the create-time parameters on every start — so writing it
# unconditionally would revert a deliberate change at the next restart.
install -d -m 0755 /etc/agent-box
if [ -f "$EGRESS_MODE_FILE" ]; then
    log "egress mode already set to '$(tr -d "[:space:]" < "$EGRESS_MODE_FILE")'; leaving it"
else
    printf '%s\n' "$WANT_EGRESS" > "$EGRESS_MODE_FILE"
    chmod 0644 "$EGRESS_MODE_FILE"
    log "egress mode set to '${WANT_EGRESS}'"
fi

# dnsmasq answers on 127.0.0.1 and adds every address it resolves for an
# allowlisted name or suffix to the address set. init-firewall.sh writes its
# name list on every rebuild; what is set up here is the plumbing that puts it
# in the path of every lookup.
#
# systemd-resolved stays in front rather than being removed, and that is the
# whole design decision. /etc/resolv.conf on this image is a symlink to
# resolved's stub, Lima and cloud-init both rewrite resolver state on boot, and
# fighting them for that file is a fight this script would keep losing. Instead
# resolved keeps the stub at 127.0.0.53, its upstream becomes dnsmasq, and its
# own cache is turned OFF so that every lookup reaches dnsmasq and every answer
# feeds the set. Nothing else in the guest has to know.
#
# Measured on this image: with Cache=no and Domains=~., `getent ahostsv4` on a
# fresh name produced `ipset add allowed-domains <addr> <suffix>` in dnsmasq's
# log and the address appeared in the set.
install -d -m 0755 /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/agent-box.conf <<'EOF'
# Managed by agent-box provisioning. Do not edit.
#
# DNS=127.0.0.1 sends every lookup to dnsmasq, which feeds the egress
# allowlist as it resolves. Domains=~. makes that the route for ALL names,
# ahead of anything DHCP puts on the link. Cache=no is not an optimisation
# choice: a cached answer here would never reach dnsmasq, so the address would
# never be added to the set and the connection would be refused.
[Resolve]
DNS=127.0.0.1
Domains=~.
Cache=no
DNSStubListener=yes
EOF

# dnsmasq must read OUR file and nothing else, and writing the file was not
# enough to make that true: Ubuntu's unit runs the daemon with no `--conf-file`,
# so it reads /etc/dnsmasq.conf, which pulls in all of /etc/dnsmasq.d. The
# allowlist would then be whatever that directory happened to contain — a
# package drop-in, a leftover, anything with an `ipset=` line in it.
#
# The drop-in below replaces ExecStart with an explicit `--conf-file=`, which
# makes our file the entire configuration. verify() checks that the running
# process really has that argument, so a drop-in that stops being applied is a
# failure rather than a silent widening.
install -d -m 0755 /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/agent-box.conf <<'EOF'
# Managed by agent-box provisioning. Do not edit.
#
# `--conf-file=` makes agent-box.conf the ONLY configuration dnsmasq reads:
# no /etc/dnsmasq.conf, no conf-dir, no package drop-ins. The resolver decides
# which addresses enter the egress allowlist, so its configuration is part of
# the allowlist and must have exactly one author.
[Service]
ExecStart=
ExecStart=/usr/sbin/dnsmasq -x /run/dnsmasq/dnsmasq.pid -u dnsmasq --conf-file=/etc/dnsmasq.d/agent-box.conf --local-service
EOF
systemctl daemon-reload

# A minimal file so dnsmasq can start before the firewall has ever written its
# own; init-firewall.sh replaces this on the first rebuild.
install -d -m 0755 /etc/dnsmasq.d
if [ ! -f /etc/dnsmasq.d/agent-box.conf ]; then
    _gw=$(ip route 2>/dev/null | awk '/^default/ && !seen { print $3; seen = 1 }')
    {
        printf '# Placeholder written by provisioning; init-firewall.sh owns this file.\n'
        printf 'listen-address=127.0.0.1\n'
        printf 'bind-dynamic\n'
        printf 'no-resolv\n'
        [ -n "$_gw" ] && printf 'server=%s\n' "$_gw"
        printf 'cache-size=1000\n'
    } > /etc/dnsmasq.d/agent-box.conf
fi
chmod 0644 /etc/dnsmasq.d/agent-box.conf

# dnsmasq ships a /etc/default/dnsmasq that reads /etc/resolv.conf for its
# upstreams. Ours are named explicitly with `no-resolv`, and reading a
# resolv.conf that points back at 127.0.0.53 would be a loop.
if [ -f /etc/default/dnsmasq ]; then
    if grep -q '^IGNORE_RESOLVCONF=' /etc/default/dnsmasq; then
        sed -i 's/^IGNORE_RESOLVCONF=.*/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq
    else
        printf 'IGNORE_RESOLVCONF=yes\n' >> /etc/default/dnsmasq
    fi
fi

# Validated before it is ever served from, and the ORDER matters. Installing
# the package starts the daemon immediately with the distribution's default
# configuration, which binds every interface and forwards for anyone who asks —
# an open resolver on the uplink for the length of provisioning, on a box whose
# entire premise is that it does not offer services to the network. So the unit
# is masked before the package lands (above), configured here, checked, and
# only then unmasked and started.
if ! dnsmasq --test --conf-file=/etc/dnsmasq.d/agent-box.conf >/dev/null 2>&1; then
    log "ERROR: the generated dnsmasq configuration does not parse; leaving dnsmasq masked" >&2
    exit 1
fi
systemctl unmask dnsmasq >/dev/null 2>&1 || true
systemctl enable dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq || log "WARN: dnsmasq did not start; name resolution will fail until it does"
systemctl restart systemd-resolved || log "WARN: systemd-resolved did not restart"
log "resolver: systemd-resolved (cache off) -> dnsmasq 127.0.0.1 -> the permitted upstreams"

# ---------------------------------------------------------------------------
# 2. Optional corporate CA
# ---------------------------------------------------------------------------
#
# A TLS-intercepting proxy re-signs every connection with its own root. Without
# that root in the trust store, both curl and Node reject everything. The file
# comes from the host's ~/.config/agent-box/ca.pem through the read-only config
# mount; it is never copied into this repository.

CA_SRC=""
if [ -f "${CONFIG_DIR}/ca.pem" ]; then
    CA_SRC="${CONFIG_DIR}/ca.pem"
fi

NODE_CA_LINE=""
if [ -n "$CA_SRC" ]; then
    log "Installing extra CA from ${CA_SRC}"
    install -m 0644 "$CA_SRC" /usr/local/share/ca-certificates/agent-box-extra-ca.crt
    update-ca-certificates
    NODE_CA_LINE='NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt'
else
    if [ -f /usr/local/share/ca-certificates/agent-box-extra-ca.crt ]; then
        log "Removing a previously installed extra CA"
        rm -f /usr/local/share/ca-certificates/agent-box-extra-ca.crt
        update-ca-certificates --fresh >/dev/null 2>&1 || true
    fi
    log "No extra CA supplied"
fi

# ---------------------------------------------------------------------------
# 3. Guest environment
# ---------------------------------------------------------------------------
#
# Lima does not expand template variables in the template's `env:` block, so
# CLAUDE_CONFIG_DIR — which needs the guest home — is set here instead. Lima
# rewrites /etc/environment during boot, before provisioning runs, so appending
# on every boot is both necessary and safe.

ENV_MARKER='# --- agent-box ---'
if grep -qF "$ENV_MARKER" /etc/environment 2>/dev/null; then
    sed -i "/${ENV_MARKER}/,\$d" /etc/environment
fi
{
    printf '%s\n' "$ENV_MARKER"
    printf 'CLAUDE_CONFIG_DIR=%s/.claude\n' "$BOX_HOME"
    # No background self-update. An update is a new binary arriving over the
    # network in the middle of a run, quietly changing the thing under test,
    # and if the download were ever blocked the first symptom would be a slow
    # start nobody can account for. `agentbox update <repo>` does it on
    # purpose instead; `claude update` by hand still works.
    printf 'DISABLE_AUTOUPDATER=1\n'
    # The toolchain's environment. In /etc/environment as well as profile.d
    # because neither alone covers every caller: pam_env reads this file for
    # every session including `limactl shell -- cmd`, and profile.d is the
    # login-shell copy. This file takes no `export` and does no expansion, so
    # PATH itself stays in profile.d only.
    #
    # Three of these are load-bearing rather than hygiene:
    #   PLAYWRIGHT_BROWSERS_PATH  the shared, agent-owned browser directory the
    #                             provisioner installs Chromium into
    #   npm_config_prefix         without it `npm i -g` as the agent fails with
    #                             EACCES on /opt/node/lib/node_modules
    #   MISE_USE_VERSIONS_HOST    mise resolves version lists from
    #                             mise-versions.jdx.dev, which is not on the
    #                             allowlist and will not be; with it off, mise
    #                             falls back to the GitHub API, which the
    #                             meta-range rule already permits — so
    #                             `mise install` works under the standing deny.
    #                             The _TRACK sibling is the anonymous download
    #                             statistics. Both names are docs-sourced and
    #                             must be confirmed against `mise settings` in a
    #                             guest before the pull request.
    printf 'PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright\n'
    printf 'npm_config_prefix=/opt/npm-global\n'
    printf 'npm_config_update_notifier=false\n'
    printf 'SEMGREP_SEND_METRICS=off\n'
    printf 'SEMGREP_ENABLE_VERSION_CHECK=0\n'
    printf 'MISE_USE_VERSIONS_HOST=false\n'
    printf 'MISE_USE_VERSIONS_HOST_TRACK=false\n'
    printf 'MISE_NOT_FOUND_AUTO_INSTALL=false\n'
    printf 'UV_NO_MODIFY_PATH=1\n'
    [ -n "$NODE_CA_LINE" ] && printf '%s\n' "$NODE_CA_LINE"
} >> /etc/environment

cat > /etc/profile.d/agent-box.sh <<EOF
# Managed by agent-box provisioning. Do not edit.
export PATH="\$HOME/.local/bin:/opt/npm-global/bin:\$PATH"
export CLAUDE_CONFIG_DIR="${BOX_HOME}/.claude"
export DISABLE_TELEMETRY=1
export DISABLE_ERROR_REPORTING=1
export DISABLE_AUTOUPDATER=1
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export npm_config_prefix=/opt/npm-global
export npm_config_update_notifier=false
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0
export MISE_USE_VERSIONS_HOST=false
export MISE_USE_VERSIONS_HOST_TRACK=false
export MISE_NOT_FOUND_AUTO_INSTALL=false
export UV_NO_MODIFY_PATH=1
EOF
[ -n "$NODE_CA_LINE" ] && printf 'export %s\n' "$NODE_CA_LINE" >> /etc/profile.d/agent-box.sh
chmod 0644 /etc/profile.d/agent-box.sh

install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.config/agent-box"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/runs"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/sessions"
install -d -m 0700 -o "$BOX_USER" -g "$BOX_USER" "${BOX_HOME}/.agent-box/briefs"

# A generic git identity, so a brief that asks the agent to commit works instead
# of stopping at "Please tell me who you are" or improvising one. Deliberately
# not the host user's name or address: nothing identifying belongs in a commit
# the agent makes. --system, so it applies without writing into the work repo.
git config --system user.name  'agent-box'
git config --system user.email 'agent-box@localhost'
git config --system init.defaultBranch main
# /work is owned by the host uid over virtiofs; without this git refuses to
# operate in it as "dubious ownership".
git config --system --replace-all safe.directory '/work'

# ---------------------------------------------------------------------------
# 4. Claude Code, installed as the unprivileged guest user
# ---------------------------------------------------------------------------
#
# The CLI refuses --dangerously-skip-permissions when running as root, which is
# the whole reason the agent runs as this user rather than root.

CLAUDE_BIN="${BOX_HOME}/.local/bin/claude"
if [ -x "$CLAUDE_BIN" ]; then
    log "Claude Code already installed at ${CLAUDE_BIN}"
else
    log "Installing Claude Code as ${BOX_USER}"
    open_network_for_provisioning
    # pipefail inside the inner shell: without it, a failed curl feeds an empty
    # script to bash, which exits 0 and reports a successful install that did
    # nothing. The failure would otherwise surface much later, as "claude is not
    # on PATH" from a run, with nothing pointing back at the download.
    sudo -u "$BOX_USER" -H bash -lc 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
    if [ ! -x "$CLAUDE_BIN" ]; then
        log "ERROR: the installer finished but ${CLAUDE_BIN} is not executable" >&2
        exit 1
    fi
    log "Claude Code installed at ${CLAUDE_BIN}"
fi

# ---------------------------------------------------------------------------
# 5. The egress firewall, as a service and a refresh timer
# ---------------------------------------------------------------------------
#
# Allowlisted names are resolved to addresses, and CDN addresses rotate, so the
# rules are rebuilt every 15 minutes.

cat > /etc/systemd/system/agent-box-firewall.service <<EOF
[Unit]
Description=agent-box egress allowlist
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${BOX_DIR}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BOX_DIR}/guest/init-firewall.sh
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# A RemainAfterExit oneshot ignores a plain `start` once it is active, so the
# timer drives a second unit that restarts it.
cat > /etc/systemd/system/agent-box-firewall-refresh.service <<EOF
[Unit]
Description=Rebuild the agent-box egress allowlist
RequiresMountsFor=${BOX_DIR}

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl restart agent-box-firewall.service
EOF

cat > /etc/systemd/system/agent-box-firewall.timer <<'EOF'
[Unit]
Description=Refresh the agent-box egress allowlist every 15 minutes

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min
Unit=agent-box-firewall-refresh.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

# Started last, so that the package and Claude Code downloads above are not
# blocked by the very rules being installed. `restart` rather than `start`,
# because a RemainAfterExit oneshot that is already active ignores `start` —
# which on a later boot would leave the rules from before the stop above.
log "Enabling the egress firewall"
systemctl enable "$FIREWALL_UNIT"
systemctl restart "$FIREWALL_UNIT"
systemctl enable --now agent-box-firewall.timer

# ---------------------------------------------------------------------------
# 5b. Holding the Docker daemon to the same firewall
# ---------------------------------------------------------------------------
#
# Two lines, and both matter.
#
# `After=agent-box-firewall.service` orders the daemon behind the firewall on
# every boot, so AGENTBOX-FWD exists before dockerd creates DOCKER-USER.
#
# `ExecStartPost=-` puts the AGENTBOX-FWD jump at DOCKER-USER rule 1 as part of
# starting the daemon. Without it, a `systemctl restart docker` at 12:01 would
# leave containers reaching whatever they liked until the 15-minute timer next
# fired.
#
# What closes that window, stated as the mechanism rather than as a slogan: the
# hook runs before the daemon is considered started, so `systemctl restart
# docker` does not RETURN until the jump is back. That is not the same as "no
# window at all", which is what this comment used to claim and is an overclaim
# — dockerd starts containers carrying a restart policy during its own startup,
# which completes before ExecStartPost is invoked. What makes that harmless is a
# separate fact, measured: Docker preserves DOCKER-USER's contents across a
# daemon restart, so the jump is normally still in place throughout. The hook is
# for the case where it was not — a fresh install, or a table flush followed by
# a restart.
#
# There is deliberately NO leading `-`, and the first pass of this round briefly
# added one. That was finding R5: the review offered two alternatives — guard
# the ip6tables arm, OR mark the ExecStartPost advisory — and both were applied,
# which is one too many. The v6 guard alone removes the failure it was for. The
# `-` on top removed the only thing the hook can still refuse for, which is a v4
# failure to place the jump, and a daemon that cannot be filtered is exactly the
# daemon that should not start. Fail-closed is the whole point of the ordering
# above; making the last step advisory undoes it.
#
# Written after the firewall units exist, because the drop-in names one of them.

if [ "$WANT_DOCKER" = true ]; then
    install -d -m 0755 /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/agent-box-firewall.conf <<EOF
# Managed by agent-box provisioning. Do not edit.
[Unit]
After=${FIREWALL_UNIT}
Wants=${FIREWALL_UNIT}

[Service]
ExecStartPost=${BOX_DIR}/guest/init-firewall.sh --docker-hook
EOF

    # The socket, owned by the guest user by name.
    #
    # `usermod -aG docker` above is correct and insufficient. Supplementary
    # groups are fixed when an SSH connection authenticates, and Lima
    # multiplexes every `limactl shell` over one long-lived connection opened
    # before provisioning ran — so the new group would not be in effect until
    # the VM was stopped and started, and `docker info` would say "permission
    # denied" on a box that had just been built to run Docker. Verified in a
    # guest on 2026-09-05, not assumed. Naming the user on the socket makes it
    # work in the session that created it. Lima's own docker template does the
    # same thing for the same reason.
    install -d -m 0755 /etc/systemd/system/docker.socket.d
    cat > /etc/systemd/system/docker.socket.d/agent-box-user.conf <<EOF
# Managed by agent-box provisioning. Do not edit.
[Socket]
SocketUser=${BOX_USER}
EOF

    systemctl daemon-reload
    log "Restarting docker so the firewall hook and the socket owner take effect"
    systemctl restart docker.socket
    systemctl restart docker.service
fi

# ---------------------------------------------------------------------------
# 4b. The baseline toolchain, under the standing deny
# ---------------------------------------------------------------------------
#
# After §5, not before it, for the reason §6 below already gives about plugins: a
# download inside the open window succeeds even when its host is off the
# allowlist, and nothing notices until an agent needs the same host later.
# Installing here makes every create a live test of every allowlist entry.
#
# Never allowed to fail the boot, for the same reason as the plugin install and
# with more at stake: this code runs on every EXISTING box the first time it
# starts under a new checkout, and those boxes hold real work. A toolchain
# problem is a warning and a retry on the next start, never a failed boot.
#
# And bounded, because fail-soft has to cover TIME as well as exit status: under
# the standing deny a blocked or stalled address is DROPPED rather than refused,
# so an unbounded install can sit in connect and the operator sees `agentbox
# create` hang with no output and no way to tell it from a wedge. An hour is far
# more than the install needs; reaching it is a warning and a retry on the next
# start, like every other failure here.

log "Installing the baseline toolchain from ${BOX_DIR}/guest/toolchain.pins"
timeout -k 30 3600 "${BOX_DIR}/guest/install-toolchain.sh" --user "$BOX_USER" \
    || log "WARN: parts of the toolchain are missing, or it ran out of time; 'agentbox toolcheck <repo>' names them"

# ---------------------------------------------------------------------------
# 6. Personal configuration and plugins, as the guest user, under the firewall
# ---------------------------------------------------------------------------
#
# Both steps run AFTER the firewall is back up, deliberately. The plugin
# install pulls from GitHub, which the allowlist permits through the ranges
# fetched from api.github.com/meta, so this is also a live test of that rule on
# every first boot: if the GitHub range rule ever breaks, the install says so
# here rather than the next time someone needs it.
#
# Neither is allowed to fail the boot. The isolation properties — the mounts,
# the firewall, the non-root user, the token handling — do not depend on either
# one, and a VM that will not start because a marketplace was unreachable is
# worse than a VM without a plugin.

# A login shell, so /etc/profile.d/agent-box.sh (written above) supplies PATH
# and CLAUDE_CONFIG_DIR. The arguments go through as arguments rather than
# being pasted into the command string, so nothing here depends on the paths
# being free of shell metacharacters.
run_as_box_user() {
    sudo -u "$BOX_USER" -H bash -lc 'exec "$@"' bash "$@"
}

log "Syncing personal Claude Code configuration from the host config mount"
run_as_box_user "${BOX_DIR}/guest/sync-claude-config.sh" \
    || log "WARN: sync-claude-config.sh exited non-zero; continuing"

log "Installing plugins listed in ${CONFIG_DIR}/plugins.txt, if any"
run_as_box_user "${BOX_DIR}/guest/install-plugins.sh" \
    || log "WARN: install-plugins.sh exited non-zero; run 'agentbox plugins <repo>' after 'agentbox token <repo>'"

# ---------------------------------------------------------------------------
# 6b. The toolchain snapshot the host reads
# ---------------------------------------------------------------------------
#
# Written last, as the box user (it must not be able to write anywhere root can),
# then moved into place by root. `status` and `toolcheck --project-only` read
# this file rather than sweeping every tool's --version on demand; when it is
# absent they say the box half is unknown, which is what an old box looks like.
#
# Guarded on the script existing: an older checkout has no toolcheck.sh, and a
# box must still start.
if [ -x "${BOX_DIR}/guest/toolcheck.sh" ]; then
    log "Recording the toolchain snapshot"
    if run_as_box_user "${BOX_DIR}/guest/toolcheck.sh" --json --box-only \
            > /var/lib/agent-box/toolcheck.json.tmp 2>/dev/null; then
        mv /var/lib/agent-box/toolcheck.json.tmp /var/lib/agent-box/toolcheck.json
        chmod 0644 /var/lib/agent-box/toolcheck.json
    else
        rm -f /var/lib/agent-box/toolcheck.json.tmp
        log "WARN: could not write the toolchain snapshot; 'agentbox toolcheck <repo>' still sweeps live"
    fi
fi

log "Provisioning complete"
