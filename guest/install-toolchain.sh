#!/bin/bash
#
# agent-box — install the baseline toolchain named by guest/toolchain.pins.
#
# Runs as root in the guest, from guest/provision.sh, on every boot, AFTER the
# egress firewall is up. Idempotent: a tool already at its pin costs one marker
# read and one --version call.
#
# Usage: install-toolchain.sh --user <box-user> [--pins FILE]
#
# Two properties are the whole design, and both are about a box that already
# holds somebody's work:
#
# 1. FAIL-SOFT. No failure here may fail a boot. Every tool installs in its own
#    function; a failure is a WARN and a counted return, and no marker is
#    written for a tool that failed, so the next `agentbox start` retries it.
#    The exit status is 1 when something is missing and the provisioner turns
#    that into one warning line; `agentbox toolcheck <repo>` names what is
#    missing. Nothing about the box's isolation depends on any of these tools.
# 2. IT NEVER REOPENS THE NETWORK. There is deliberately no
#    open_network_for_provisioning() here — that is the point, not an omission.
#    Every download crosses the standing allowlist, so a create is a live test
#    of every entry, and an existing box's firewall window is never reopened to
#    install a formatter. The five packages this script needs from the archive
#    are installed under the same deny (the Ubuntu archives are on the base
#    allowlist), and a failure there is a WARN too.
#
# Every digest comes from guest/toolchain.pins, NOT from a checksum file beside
# the asset: fetching both from the same place proves only that the two agree,
# which was the defect in the install_node22 this replaces.
#
# Exit status: 0 everything is at its pin (or nothing needed doing), 1 at least
# one tool is not.

set -uo pipefail

BOX_DIR="${AGENT_BOX_DIR:-/opt/agent-box}"
PINS="${BOX_DIR}/guest/toolchain.pins"
REQ_DIR="${BOX_DIR}/guest/toolchain"
MARKER_DIR=/var/lib/agent-box/toolchain
TOOLS_DIR=/opt/abx-tools
BIN_DIR=/usr/local/bin
NODE_PREFIX=/opt/node
# The prefix the --playwright profile used. Removed once the new one answers, so
# a box does not carry two Node trees for ever.
OLD_NODE_PREFIX=/opt/node22
BROWSERS_PATH=/opt/ms-playwright
NPM_PREFIX=/opt/npm-global
BOX_USER=""

# The disk floor below which this script does nothing at all. An ESTIMATE: the
# baseline is 1.5-2.5 GiB and a browser install needs room to unpack. A box that
# is nearly full must be resized, not filled further.
MIN_FREE_MIB=4096

log()  { printf '[agent-box toolchain] %s\n' "$*"; }
warn() { printf '[agent-box toolchain] WARN: %s\n' "$*" >&2; }

# Fail-soft has to cover TIME as well as exit status. This script runs inside a
# boot, so nothing in it may block for ever: the egress default is deny, which
# DROPS rather than rejects, so a connect to an off-allowlist or stalled address
# waits out its timeout instead of erroring, and a tool that phones home on
# --version stalls every single start. Every download is bounded by curl's own
# flags; every version probe goes through bounded(); and the provisioner bounds
# this whole script with `timeout` at the call site, so the worst case is a
# warning, never an `agentbox create` that sits there with no output.
#
# `timeout` is in coreutils (Essential in the guest image). The fallback is for
# an image without it: unbounded, as before, rather than broken.
TIMEOUT_CMD=$(command -v timeout 2>/dev/null) || TIMEOUT_CMD=""
PROBE_SECS=15

# semgrep phones home unless told not to, and this script runs behind the box's
# default-deny firewall: the call is blackholed, not refused, so `semgrep
# --version` hangs until the probe's timeout kills it and reads as "not at its
# pin". Measured in a real guest, cloud-init's environment (PATH and HOME, no
# profile): without these two the probe exits 124 with no output; with them it
# prints 1.177.0 and exits 0. That is why semgrep, alone of twelve tools,
# reinstalled itself on every boot. The box's login shells get these from
# /etc/profile.d and /etc/environment, neither of which a provisioning shell
# reads, so the script sets them for itself.
export SEMGREP_SEND_METRICS=off
export SEMGREP_ENABLE_VERSION_CHECK=0

bounded() {
    local secs="$1"; shift
    if [ -n "$TIMEOUT_CMD" ]; then
        "$TIMEOUT_CMD" "$secs" "$@"
    else
        "$@"
    fi
}

usage() {
    cat >&2 <<'EOF'
usage: install-toolchain.sh --user <box-user> [--pins FILE]

Installs the baseline toolchain from guest/toolchain.pins. Root, in the guest,
under the standing egress deny.

  exit 0  every pin is satisfied
  exit 1  at least one tool is missing or off its pin (the boot continues)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            [ $# -ge 2 ] || { usage; exit 1; }
            BOX_USER="$2"; shift 2 ;;
        --pins)
            [ $# -ge 2 ] || { usage; exit 1; }
            PINS="$2"; shift 2 ;;
        *) warn "unknown argument: $1"; usage; exit 1 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { warn "must run as root"; exit 1; }
case "$BOX_USER" in
    "") warn "--user <box-user> is required"; exit 1 ;;
    *[!A-Za-z0-9._-]*) warn "--user is not a plain user name"; exit 1 ;;
esac
id -u "$BOX_USER" >/dev/null 2>&1 || { warn "no such user: ${BOX_USER}"; exit 1; }

# ---------------------------------------------------------------------------
# The pins, and the shape of every value read out of them
# ---------------------------------------------------------------------------
#
# The file is a committed part of the read-only /opt/agent-box mount, so it is
# sourced rather than parsed. Every value is still shape-checked before it
# reaches a URL, a file name or a `sha256sum -c` line: this is the one file in
# the design whose contents become a download, and a typo in it should fail by
# name rather than inside curl's argument list.

if [ ! -f "$PINS" ]; then
    warn "no pins file at ${PINS}; nothing to install"
    exit 1
fi
# shellcheck source=/dev/null
. "$PINS" || { warn "could not read ${PINS}"; exit 1; }

pin() {
    local name="$1"
    printf '%s' "${!name:-}"
}

valid_version() {
    case "${1:-}" in
        ""|*[!A-Za-z0-9._+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

valid_sha256() {
    case "${1:-}" in
        ""|*[!0-9a-f]*) return 1 ;;
        *) [ "${#1}" -eq 64 ] ;;
    esac
}

valid_url() {
    case "${1:-}" in
        https://*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9:/._~%+@?=-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 0: the disk, the directories, the five packages
# ---------------------------------------------------------------------------

free_mib() {
    local avail
    avail=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')
    case "${avail:-}" in
        ""|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$((avail / 1024))"
}

FREE=$(free_mib) || FREE=""
if [ -n "$FREE" ] && [ "$FREE" -lt "$MIN_FREE_MIB" ]; then
    warn "skipping the toolchain install: ${FREE} MiB free; agentbox resize <repo> --disk 40GiB"
    exit 0
fi
log "starting; ${FREE:-<unknown>} MiB free on /"

install -d -m 0755 /var/lib/agent-box
install -d -m 0755 "$MARKER_DIR"
install -d -m 0755 "$TOOLS_DIR"
# Both of these hold state rather than a program, so both are owned by the
# agent. Root-owned, `npm i -g` fails with EACCES for the agent — a defect this
# fixes — and a project pinning its own Playwright version could not add its own
# browser build, which is exactly the case that must work.
install -d -m 0755 -o "$BOX_USER" -g "$BOX_USER" "$BROWSERS_PATH"
install -d -m 0755 -o "$BOX_USER" -g "$BOX_USER" "$NPM_PREFIX"

export PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH"
# Nothing here resolves a version from a registry, so uv must not go looking for
# an interpreter either: the requirement files were compiled for the image's own
# python3, and a managed download would be a second, unpinned Python.
export UV_PYTHON_DOWNLOADS=never
export UV_NO_MODIFY_PATH=1

have_pkg() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

ensure_packages() {
    local pkg
    local missing=()
    # xz-utils unpacks the Node tarball, unzip unpacks dprint, python3-venv and
    # python3-pip carry the uv-managed venvs, zip is in the baseline list.
    for pkg in xz-utils unzip zip python3-venv python3-pip; do
        have_pkg "$pkg" || missing+=("$pkg")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    log "installing ${missing[*]} from the archive, under the standing deny"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=180 update >/dev/null 2>&1 \
        || warn "apt-get update failed under the deny; trying the install anyway"
    if ! apt-get -o DPkg::Lock::Timeout=180 install -y --no-install-recommends "${missing[@]}"; then
        warn "could not install ${missing[*]}; the tools that need them are skipped by name below"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Markers: what is installed, and the two tests that answer it
# ---------------------------------------------------------------------------
#
# A marker alone lies after somebody moves a binary; a --version call alone
# costs a process per boot for a tool that answers slowly (semgrep is the one).
# So both: the marker says this version, AND the program answers with it.

marker_file() { printf '%s/%s.installed' "$MARKER_DIR" "$1"; }

marker_says() {
    local f first
    f=$(marker_file "$1")
    [ -f "$f" ] || return 1
    first=$(head -1 "$f" 2>/dev/null) || return 1
    case "$first" in "$2 "*) return 0 ;; *) return 1 ;; esac
}

write_marker() {
    local tool="$1" version="$2" digest="${3:--}" f
    f=$(marker_file "$tool")
    printf '%s %s %s\n' "$version" "$digest" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f"
    chmod 0644 "$f"
}

# Does the program answer with the version we pinned? A fixed-string match over
# the whole of its output, stdout and stderr together: the formats genuinely
# differ (trufflehog writes to stderr, actionlint prints three lines, playwright
# prefixes "Version ") and an extractor per tool belongs in toolcheck.sh, which
# reports. This function only has to decide whether to download.
#
# The single-dash retry is for actionlint, whose documented flag is `-version`.
# Guessing wrong in the other direction would be expensive and silent: the tool
# would be re-downloaded on every boot for ever, which is precisely what smoke's
# "the second boot never reopened the firewall" step is there to catch.
#
# Bounded, because this is the one call every boot makes for every tool: twelve
# steps × one probe each on a box where nothing needs installing. A tool that
# blocks on its own update check (trufflehog asks oss.trufflehog.org, which is
# not on the allowlist, so the packet is dropped rather than refused) would make
# every `agentbox start` pay that stall, twice. A probe that does not answer is
# named and treated as "not at its pin", which is what it is.
answers_with() {
    local want="$1" bin="$2" out rc
    # The probe runs with a known PATH, because one of these tools needs one:
    # semgrep shells out to `uname -s` and dies without it ("Fatal error:
    # exception Failure: run ['uname' '-s']: No such file or directory", exit 2),
    # measured in a real guest. Read as "not at its pin", that made semgrep the
    # one tool that reinstalled itself on every boot while the other eleven were
    # skipped — the idempotency this function decides. Nothing else about the
    # environment is changed: the metrics and version-check switches this script
    # sets for semgrep still come from the caller.
    local probe_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    out=$(PATH="${PATH:-}:${probe_path}" bounded "$PROBE_SECS" "$bin" --version 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
        out=$(PATH="${PATH:-}:${probe_path}" bounded "$PROBE_SECS" "$bin" -version 2>&1); rc=$?
    fi
    if [ "$rc" -eq 124 ]; then
        warn "${bin}: the version probe did not answer within ${PROBE_SECS}s"
        return 1
    fi
    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$out" | grep -qF -- "$want"
}

satisfied() {
    local tool="$1" version="$2" bin="$3"
    marker_says "$tool" "$version" || return 1
    answers_with "$version" "$bin" || return 1
    return 0
}

CHANGED=0
FAILED=0
FAILED_TOOLS=""

failed() {
    FAILED=$((FAILED + 1))
    FAILED_TOOLS="${FAILED_TOOLS} $1"
}
skipped() { warn "$1 skipped: $2"; }

# ---------------------------------------------------------------------------
# Download, verify against OUR digest, unpack, swap into place
# ---------------------------------------------------------------------------

ARCH=$(dpkg --print-architecture 2>/dev/null)
case "$ARCH" in
    arm64) ARCH_KEY=ARM64 ;;
    amd64) ARCH_KEY=AMD64 ;;
    *)
        warn "no toolchain builds known for dpkg architecture '${ARCH:-<unknown>}'; nothing installed"
        exit 1 ;;
esac

# Returns 1 unless the asset arrived and matched, so there is one place in the
# script where "verified" is defined.
fetch_verify() {
    local url="$1" want_sha="$2" out="$3"
    valid_url "$url"         || { warn "not a usable URL in the pins: ${url}"; return 1; }
    valid_sha256 "$want_sha" || { warn "not a sha256 in the pins for ${url}"; return 1; }
    # --connect-timeout, because a dropped SYN is the normal failure here: an
    # asset host that is off the allowlist, or the near-zero-TTL resolver race
    # guest/allowlist.base documents, would otherwise sit in connect for the
    # whole --max-time. --retry-max-time bounds the retry loop as a whole, so
    # one bad asset cannot cost 3 × 600 s of a boot.
    curl -fsSL --connect-timeout 20 --retry 3 --retry-delay 2 \
         --retry-max-time 600 --max-time 600 "$url" -o "$out" || {
        warn "download failed: ${url}"; return 1; }
    printf '%s  %s\n' "$want_sha" "$(basename "$out")" \
        | (cd "$(dirname "$out")" && sha256sum -c -) >/dev/null 2>&1 || {
        warn "digest mismatch for ${url}"; return 1; }
    return 0
}

unpack_into() {
    local dir="$1" file="$2" url="$3" strip="${4:-0}"
    case "$url" in
        *.tar.gz|*.tgz) tar -xzf "$file" --strip-components="$strip" -C "$dir" ;;
        *.tar.xz)       tar -xJf "$file" --strip-components="$strip" -C "$dir" ;;
        *.zip)          unzip -q -o "$file" -d "$dir" ;;
        *)              install -m 0755 "$file" "${dir}/asset" ;;
    esac
}

# One binary on the default PATH, out of an archive or a bare release file.
#
# The swap is the point: install_node22 did `rm -rf $NODE_PREFIX` before its
# tar, so a failed unpack left no Node at all and three dangling symlinks in
# /usr/local/bin. Here the old file survives until the new one is complete and
# the last step is a rename inside /usr/local/bin.
install_binary_tool() {
    local tool="$1" version="$2" url="$3" sha="$4" binname="$5"; shift 5
    local tmp found extra
    tmp=$(mktemp -d) || { warn "${tool}: no temporary directory"; return 1; }
    install -d -m 0755 "${tmp}/x"
    if ! fetch_verify "$url" "$sha" "${tmp}/asset"; then rm -rf "$tmp"; return 1; fi
    if ! unpack_into "${tmp}/x" "${tmp}/asset" "$url"; then
        warn "${tool}: could not unpack the asset"; rm -rf "$tmp"; return 1
    fi
    found=$(find "${tmp}/x" -maxdepth 3 -type f -name "$binname" 2>/dev/null | head -1)
    # A bare release binary unpacks as "asset"; it is the only file there.
    [ -n "$found" ] || found=$(find "${tmp}/x" -maxdepth 1 -type f -name asset 2>/dev/null | head -1)
    if [ -z "$found" ]; then
        warn "${tool}: no ${binname} inside the asset"; rm -rf "$tmp"; return 1
    fi
    if ! install -m 0755 "$found" "${BIN_DIR}/.${binname}.new"; then
        warn "${tool}: could not stage /usr/local/bin/${binname}"; rm -rf "$tmp"; return 1
    fi
    if ! mv -f "${BIN_DIR}/.${binname}.new" "${BIN_DIR}/${binname}"; then
        warn "${tool}: could not move ${binname} into place"
        rm -f "${BIN_DIR}/.${binname}.new"; rm -rf "$tmp"; return 1
    fi
    # Anything shipped beside the main binary that an agent will reach for (uvx
    # beside uv): installed when the asset carries it, never required.
    for extra in "$@"; do
        found=$(find "${tmp}/x" -maxdepth 3 -type f -name "$extra" 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            install -m 0755 "$found" "${BIN_DIR}/.${extra}.new" \
                && mv -f "${BIN_DIR}/.${extra}.new" "${BIN_DIR}/${extra}"
        fi
    done
    rm -rf "$tmp"
    write_marker "$tool" "$version" "$sha"
    CHANGED=$((CHANGED + 1))
    log "${tool} ${version} installed at ${BIN_DIR}/${binname}"
    return 0
}

# The seven tools that are a single binary in a release asset.
do_binary_tool() {
    local tool="$1" prefix="$2" binname="$3"; shift 3
    local version url sha
    version=$(pin "${prefix}_VERSION")
    url=$(pin "${prefix}_URL_${ARCH_KEY}")
    sha=$(pin "${prefix}_SHA256_${ARCH_KEY}")
    if ! valid_version "$version"; then
        warn "${tool}: no usable ${prefix}_VERSION in the pins"
        failed "$tool"
        return 1
    fi
    if satisfied "$tool" "$version" "${BIN_DIR}/${binname}"; then
        log "${tool} ${version} already at its pin"
        return 0
    fi
    install_binary_tool "$tool" "$version" "$url" "$sha" "$binname" "$@" \
        || { failed "$tool"; return 1; }
    return 0
}

install_node() {
    local version npm_version url sha tmp b
    version=$(pin NODE_VERSION)
    npm_version=$(pin NODE_NPM_VERSION)
    url=$(pin "NODE_URL_${ARCH_KEY}")
    sha=$(pin "NODE_SHA256_${ARCH_KEY}")
    valid_version "$version" || { warn "node: no usable NODE_VERSION in the pins"; return 1; }
    if satisfied node "$version" "${NODE_PREFIX}/bin/node"; then
        log "node ${version} already at its pin"
        # The old tree goes only once the new one answers, never before.
        [ ! -d "$OLD_NODE_PREFIX" ] || { rm -rf "$OLD_NODE_PREFIX"; log "removed ${OLD_NODE_PREFIX}"; }
        return 0
    fi
    have_pkg xz-utils || { skipped node "xz-utils is not installed"; return 1; }
    tmp=$(mktemp -d) || return 1
    install -d -m 0755 "${tmp}/x"
    if ! fetch_verify "$url" "$sha" "${tmp}/asset"; then rm -rf "$tmp"; return 1; fi
    if ! unpack_into "${tmp}/x" "${tmp}/asset" "$url" 1; then
        warn "node: could not unpack the tarball"; rm -rf "$tmp"; return 1
    fi
    if [ ! -x "${tmp}/x/bin/node" ]; then
        warn "node: no bin/node inside the tarball"; rm -rf "$tmp"; return 1
    fi
    rm -rf "${NODE_PREFIX}.old"
    [ ! -d "$NODE_PREFIX" ] || mv "$NODE_PREFIX" "${NODE_PREFIX}.old"
    if ! mv "${tmp}/x" "$NODE_PREFIX"; then
        warn "node: could not move the new tree into ${NODE_PREFIX}"
        [ ! -d "${NODE_PREFIX}.old" ] || mv "${NODE_PREFIX}.old" "$NODE_PREFIX"
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "${NODE_PREFIX}.old" "$tmp"
    for b in node npm npx; do
        ln -sfn "${NODE_PREFIX}/bin/${b}" "${BIN_DIR}/${b}"
    done
    # The bundled npm version is a pinned fact too, asserted rather than
    # installed: a tarball carrying a different npm than the pins record is a
    # drift somebody should see.
    if valid_version "$npm_version" && ! answers_with "$npm_version" "${NODE_PREFIX}/bin/npm"; then
        warn "node ${version} bundles a different npm than the pinned ${npm_version}"
    fi
    write_marker node "$version" "$sha"
    CHANGED=$((CHANGED + 1))
    log "node ${version} installed at ${NODE_PREFIX} (npm ${npm_version})"
    [ ! -d "$OLD_NODE_PREFIX" ] || { rm -rf "$OLD_NODE_PREFIX"; log "removed ${OLD_NODE_PREFIX}"; }
    return 0
}

# ---------------------------------------------------------------------------
# The Python tools: one uv-managed venv each, every wheel hash-pinned
# ---------------------------------------------------------------------------
#
# `uv pip install --require-hashes` refuses anything whose sha256 is not in the
# requirement file, transitive dependencies included. That is what makes
# "checksum-verified" true for these three without a human pasting digests: the
# files are compiled by host/refresh-pins.sh and committed.

# The version the requirement file pins for the tool itself. The pins file and
# the requirements file are two artefacts that have to agree: host/refresh-pins.sh
# writes both, but an operator can commit a half-finished bump, and then the
# install would put one version on the box and write_marker would record the
# other — after which `satisfied` is false on every boot for ever and the tool is
# torn down and re-downloaded each time, silently, because the install succeeds.
# So the disagreement fails by name instead. uv writes the line as
# `<name>==<version> \`, the name normalised to lower case with dashes.
req_pinned_version() {
    local tool="$1" req="$2"
    sed -n "s/^${tool}==\\([A-Za-z0-9._+-]*\\).*\$/\\1/p" "$req" 2>/dev/null | head -1
}

# Put the previous install back, after a failed upgrade of it. `had` is 1 when
# there was one to put back. The /usr/local/bin symlinks point at
# ${venv}/bin/<tool>, so restoring the directory restores them too.
restore_venv() {
    local tool="$1" venv="$2" had="$3"
    [ "$had" -eq 1 ] || return 0
    rm -rf "$venv"
    if mv "${venv}.old" "$venv"; then
        log "${tool}: the previous install is still in place at ${venv}"
    else
        warn "${tool}: the previous install could not be put back at ${venv}"
    fi
}

install_python_tool() {
    local tool="$1" version="$2" req="${REQ_DIR}/$3"; shift 3
    local venv="${TOOLS_DIR}/${tool}" bin req_version had_venv=0
    valid_version "$version" || { warn "${tool}: no usable version in the pins"; return 1; }
    if satisfied "$tool" "$version" "${venv}/bin/$1"; then
        log "${tool} ${version} already at its pin"
        return 0
    fi
    command -v uv >/dev/null 2>&1 || { skipped "$tool" "uv is not installed"; return 1; }
    have_pkg python3-venv    || { skipped "$tool" "python3-venv is not installed"; return 1; }
    [ -f "$req" ] || { warn "${tool}: no requirement file at ${req}"; return 1; }
    req_version=$(req_pinned_version "$tool" "$req")
    if [ "$req_version" != "$version" ]; then
        warn "${tool}: the pins say ${version} but ${req} pins ${req_version:-no ${tool}== line}; not installing"
        return 1
    fi
    # The swap, and it is the same shape as install_binary_tool's and
    # install_node's: the working tool survives a failed upgrade.
    #
    # It is also what makes this step idempotent at all. `uv venv` REFUSES a
    # path that already holds a virtual environment — measured with the pinned
    # uv 0.12.17: "error: Failed to create virtual environment / cause: A
    # virtual environment already exists at: <path>", exit 2 — so a second call
    # on the same path fails, which means a pin bump and the retry this script's
    # header promises after a failed install would BOTH have been dead ends.
    #
    # The new venv is built at its FINAL path, not at a temporary one that is
    # then renamed: uv bakes absolute paths into a venv's console scripts, so a
    # venv built at ${venv}.new and moved would leave every entry point pointing
    # at a directory that no longer exists. So the OLD tree is renamed aside
    # first and moved back if anything below fails.
    rm -rf "${venv}.old"
    if [ -e "$venv" ]; then
        if ! mv "$venv" "${venv}.old"; then
            warn "${tool}: could not move the previous install aside at ${venv}"
            return 1
        fi
        had_venv=1
    fi
    if ! uv venv --python python3 "$venv" >/dev/null 2>&1; then
        warn "${tool}: could not create the venv at ${venv}"
        restore_venv "$tool" "$venv" "$had_venv"
        return 1
    fi
    if ! uv pip install --python "${venv}/bin/python" --require-hashes -r "$req" >/dev/null 2>&1; then
        warn "${tool} ${version}: 'uv pip install --require-hashes' failed"
        rm -rf "$venv"
        restore_venv "$tool" "$venv" "$had_venv"
        return 1
    fi
    # Every entry point is checked before any symlink is repointed: a half-built
    # venv must not leave /usr/local/bin pointing into a tree this function is
    # about to remove.
    for bin in "$@"; do
        if [ ! -x "${venv}/bin/${bin}" ]; then
            warn "${tool}: ${bin} is not in the venv"
            rm -rf "$venv"
            restore_venv "$tool" "$venv" "$had_venv"
            return 1
        fi
    done
    for bin in "$@"; do
        ln -sfn "${venv}/bin/${bin}" "${BIN_DIR}/${bin}"
    done
    rm -rf "${venv}.old"
    write_marker "$tool" "$version"
    CHANGED=$((CHANGED + 1))
    log "${tool} ${version} installed at ${venv}"
    return 0
}

# ---------------------------------------------------------------------------
# Playwright's system libraries, and one browser
# ---------------------------------------------------------------------------
#
# `install-deps` runs from the pinned local install, not `npx --yes
# playwright@<pin>` as root: even pinned, npx resolves and executes a freshly
# downloaded package tree as root in a guest that has read-write virtiofs on the
# host's repository. The Python wheel was installed with recorded hashes and
# bundles its own Node driver, so it does the same apt work from code we
# verified. The npx path is gone.

PLAYWRIGHT_BIN="${TOOLS_DIR}/playwright/bin/playwright"

install_playwright_deps() {
    local version="$1"
    valid_version "$version" || return 1
    if [ ! -x "$PLAYWRIGHT_BIN" ]; then
        skipped playwright-deps "the pinned playwright is not installed"
        return 1
    fi
    if marker_says playwright-deps "$version"; then
        log "playwright ${version} system libraries already installed"
        return 0
    fi
    # Step 10 failing does not stop step 11, and on a pin bump the venv still
    # holds the previous release until step 10 replaces it. install-deps installs
    # the system libraries THAT release asks for, so running whatever binary is
    # there and then stamping the marker with the pin would make the marker a
    # false record — and smoke's "install-deps was run from the pinned version,
    # per its own marker" would pass on a box where it was not. The binary has to
    # agree first.
    if ! answers_with "$version" "$PLAYWRIGHT_BIN"; then
        skipped playwright-deps "the installed playwright is not at the pinned ${version}"
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    if ! "$PLAYWRIGHT_BIN" install-deps >/dev/null 2>&1; then
        warn "playwright ${version} install-deps failed; a browser may not start"
        return 1
    fi
    write_marker playwright-deps "$version"
    CHANGED=$((CHANGED + 1))
    log "playwright ${version} system libraries installed"
    # The npx-era marker, removed once its replacement exists.
    rm -f /var/lib/agent-box/playwright-deps-installed
    return 0
}

# The revision is read back out of the installed playwright-core's
# browsers.json, never chosen here: it is a function of the pinned Playwright
# version. The pins file records what was observed at bump time, so a drift is
# visible instead of silent.
installed_chromium_revision() {
    local py="${TOOLS_DIR}/playwright/bin/python" out=""
    [ -x "$py" ] || return 1
    out=$("$py" -c '
import json, pathlib, playwright
p = pathlib.Path(playwright.__file__).parent / "driver" / "package" / "browsers.json"
for b in json.loads(p.read_text()).get("browsers", []):
    if b.get("name") == "chromium":
        print(b.get("revision", ""))
        break
' 2>/dev/null)
    case "${out:-}" in
        ""|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$out"
}

# As the agent, into the shared browser path the agent owns: root-owned it would
# be unwritable, and a project pinning a different Playwright could not add its
# own build. The environment goes in as an argument, not through sudo's env,
# which the guest's sudoers does not have to permit.
run_as_box_user() {
    sudo -u "$BOX_USER" -H bash -lc \
        'export PLAYWRIGHT_BROWSERS_PATH="$1"; shift; exec "$@"' \
        bash "$BROWSERS_PATH" "$@"
}

install_chromium() {
    local pinned_rev found_rev
    pinned_rev=$(pin PLAYWRIGHT_CHROMIUM_REVISION)
    if [ ! -x "$PLAYWRIGHT_BIN" ]; then
        skipped chromium "the pinned playwright is not installed"
        return 1
    fi
    if ! found_rev=$(installed_chromium_revision); then
        warn "chromium: could not read the browser revision out of the installed playwright"
        return 1
    fi
    if [ "$found_rev" != "$pinned_rev" ]; then
        warn "chromium: the installed playwright asks for revision ${found_rev}, the pins record ${pinned_rev}"
    fi
    if marker_says chromium "$found_rev" && [ -d "${BROWSERS_PATH}/chromium-${found_rev}" ]; then
        log "chromium ${found_rev} already installed at ${BROWSERS_PATH}"
        return 0
    fi
    if ! run_as_box_user "$PLAYWRIGHT_BIN" install chromium >/dev/null 2>&1; then
        warn "chromium ${found_rev} could not be downloaded; a browser test will say so on first use"
        return 1
    fi
    if [ ! -d "${BROWSERS_PATH}/chromium-${found_rev}" ]; then
        warn "chromium: the install reported success but ${BROWSERS_PATH}/chromium-${found_rev} is not there"
        return 1
    fi
    write_marker chromium "$found_rev"
    CHANGED=$((CHANGED + 1))
    log "chromium ${found_rev} installed at ${BROWSERS_PATH}"
    return 0
}

# ---------------------------------------------------------------------------
# The twelve steps, in order. A dependent's skip says why.
# ---------------------------------------------------------------------------

APT_OK=1
ensure_packages || APT_OK=0

log "1/12 uv";         do_binary_tool uv UV uv uvx
log "2/12 ruff";       do_binary_tool ruff RUFF ruff
log "3/12 node";       install_node || failed node
log "4/12 mise";       do_binary_tool mise MISE mise
log "5/12 trufflehog"; do_binary_tool trufflehog TRUFFLEHOG trufflehog
log "6/12 actionlint"; do_binary_tool actionlint ACTIONLINT actionlint

log "7/12 dprint"
if have_pkg unzip; then
    do_binary_tool dprint DPRINT dprint
else
    skipped dprint "unzip is not installed"
    failed dprint
fi

log "8/12 basedpyright"
install_python_tool basedpyright "$(pin BASEDPYRIGHT_VERSION)" \
    basedpyright.requirements.txt basedpyright basedpyright-langserver \
    || failed basedpyright

log "9/12 semgrep"
install_python_tool semgrep "$(pin SEMGREP_VERSION)" \
    semgrep.requirements.txt semgrep \
    || failed semgrep

log "10/12 playwright"
install_python_tool playwright "$(pin PLAYWRIGHT_VERSION)" \
    playwright.requirements.txt playwright \
    || failed playwright

log "11/12 playwright install-deps"
install_playwright_deps "$(pin PLAYWRIGHT_VERSION)" || failed playwright-deps

log "12/12 chromium"
install_chromium || failed chromium

# ---------------------------------------------------------------------------
# What happened
# ---------------------------------------------------------------------------

if [ "$APT_OK" -eq 0 ]; then
    warn "the archive packages could not be installed; that is what the skips above name"
fi

if [ "$FAILED" -eq 0 ] && [ "$CHANGED" -eq 0 ]; then
    # Asserted by smoke as the idempotency proof: a second boot that says this
    # and does not reopen the firewall is a second boot that installed nothing.
    log "All toolchain pins already satisfied"
    exit 0
fi

if [ "$FAILED" -gt 0 ]; then
    warn "not at baseline:${FAILED_TOOLS}"
    warn "run 'agentbox toolcheck <repo>' for the by-name report; the next 'agentbox start' retries"
    exit 1
fi

log "toolchain: ${CHANGED} tool(s) installed or updated to their pins"
exit 0
