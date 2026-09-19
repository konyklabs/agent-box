#!/bin/bash
#
# agent-box — re-fetch every pinned toolchain asset, record the digest it
# actually answered with, and rewrite guest/toolchain.pins.
#
# Usage: refresh-pins.sh [--set KEY=VALUE]... [--out FILE] [--skip-python]
#
# This is the only thing that writes guest/toolchain.pins. A bump is two steps:
# run this with the new version (`--set RUFF_VERSION=0.17.0`, or edit the file
# and re-run with no arguments), then `agentbox start <repo>` on each box.
#
# Versions are an operator's choice and are never discovered here: nothing asks
# a project what its latest release is, so re-running this script twice in a row
# produces the same file. What IS discovered is every digest. Each asset is
# downloaded — not its published checksum file, the asset — and hashed locally,
# because fetching an artefact and its checksum from the same place proves only
# that the two agree. That was the defect in the old install_node22, which read
# the version out of SHASUMS256.txt and then verified the tarball against the
# same file.
#
# Two values are read back rather than chosen, and they are the reason this
# script downloads instead of trusting a release page:
#   NODE_NPM_VERSION             — out of the Node tarball's own npm package.json
#   PLAYWRIGHT_CHROMIUM_REVISION — out of playwright-core's browsers.json at the
#                                  pinned tag
#
# The Python tools carry no URL and no digest of their own: their requirement
# files are compiled with `uv pip compile --generate-hashes --universal`, which
# records a sha256 for every wheel including the transitive ones, and
# `uv pip install --require-hashes` in the guest refuses anything unlisted.
#
# Exit codes: 0 the file was rewritten, 1 a fetch or a digest failed and
# nothing was written, 2 usage error.
#
# Output discipline: URLs, versions, digests and byte counts only. It fetches
# from the public internet on the host, so it is never run inside a box.

set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BOX_DIR=$(cd "${SELF_DIR}/.." && pwd)
PINS="${BOX_DIR}/guest/toolchain.pins"
REQ_DIR="${BOX_DIR}/guest/toolchain"
SKIP_PYTHON=0
OVERRIDES=""

info() { printf 'refresh-pins: %s\n' "$*"; }
warn() { printf 'refresh-pins: %s\n' "$*" >&2; }
die()  { printf 'refresh-pins: %s\n' "$*" >&2; exit 1; }

usage() {
    cat >&2 <<'EOF'
usage: refresh-pins.sh [--set KEY=VALUE]... [--out FILE] [--skip-python]

Re-fetches every asset named by guest/toolchain.pins, records the sha256 it
actually saw, and rewrites the file. Versions come from the file itself unless
--set overrides one.

  --set KEY=VALUE   set a version before fetching (e.g. --set RUFF_VERSION=0.17.0)
  --out FILE        write to FILE instead of guest/toolchain.pins
  --skip-python     leave guest/toolchain/*.requirements.txt alone

  exit 0  the file was rewritten
  exit 1  a fetch or a digest failed; nothing was written
  exit 2  usage error
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --set)
            [ $# -ge 2 ] || { usage; exit 2; }
            case "$2" in
                [A-Z]*=*) OVERRIDES="${OVERRIDES}${2}"$'\n' ;;
                *) warn "--set expects KEY=VALUE, got '$2'"; exit 2 ;;
            esac
            shift 2 ;;
        --out)
            [ $# -ge 2 ] || { usage; exit 2; }
            PINS="$2"; shift 2 ;;
        --skip-python) SKIP_PYTHON=1; shift ;;
        -h|--help) usage; exit 2 ;;
        *) warn "unknown argument: $1"; usage; exit 2 ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "curl is not installed"
command -v jq   >/dev/null 2>&1 || die "jq is not installed (brew install jq)"
# Named, not silently skipped: the Python half of the toolchain is hash-pinned
# by uv and by nothing else.
[ "$SKIP_PYTHON" -eq 1 ] || command -v uv >/dev/null 2>&1 \
    || die "uv is not installed (brew install uv), and the Python requirement files are compiled with it"

TMP=$(mktemp -d -t agent-box-refresh-pins.XXXXXX) || die "could not create a temporary directory"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Versions in, digests out
# ---------------------------------------------------------------------------

# The same read idiom test/smoke.sh uses on this file, so there is exactly one
# way to read a pin anywhere in the project.
read_pin() {
    local key="$1"
    [ -f "$PINS" ] || return 0
    sed -n "s/^${key}=\"\\(.*\\)\"\$/\\1/p" "$PINS" | head -1
}

version_of() {
    local key="$1" v
    v=$(printf '%s' "$OVERRIDES" | sed -n "s/^${key}=\\(.*\\)\$/\\1/p" | head -1)
    [ -n "$v" ] || v=$(read_pin "$key")
    printf '%s' "$v"
}

# A version reaches a URL and a file name, so it is shape-checked before it is
# used, not after.
valid_version() {
    case "${1:-}" in
        ""|*[!A-Za-z0-9._+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

sha256_of() {
    local f="$1" h=""
    if command -v shasum >/dev/null 2>&1; then
        h=$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
        h=$(sha256sum "$f" 2>/dev/null | awk '{print $1}')
    fi
    case "$h" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
            [ "${#h}" -eq 64 ] || return 1
            printf '%s' "$h" ;;
        *) return 1 ;;
    esac
}

# Downloads one asset and sets FETCH_SHA / FETCH_BYTES, or counts a failure.
# The digest goes into globals rather than stdout so the table below is the
# whole of this script's stdout: a caller reading the evidence and a caller
# reading the value are the same caller here.
FETCH_FAILURES=0
FETCH_SHA=""
FETCH_BYTES=""
fetch_digest() {
    local url="$1" label="$2" file="${TMP}/asset" code=""
    FETCH_SHA=""
    FETCH_BYTES=""
    rm -f "$file"
    code=$(curl -fsSL --retry 3 --retry-delay 2 --max-time 900 \
               -o "$file" -w '%{http_code}' "$url" 2>/dev/null)
    if [ "$code" != "200" ]; then
        warn "FAIL ${label}: HTTP ${code:-<none>} for ${url}"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        return 1
    fi
    FETCH_BYTES=$(wc -c < "$file" | tr -d ' ')
    if ! FETCH_SHA=$(sha256_of "$file"); then
        warn "FAIL ${label}: could not hash the downloaded asset"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        return 1
    fi
    printf '%-34s %s  %s bytes  HTTP %s\n' "$label" "$FETCH_SHA" "$FETCH_BYTES" "$code"
}

# One line per architecture per tool. Written out as a table rather than seven
# near-identical blocks, and every name here was answered 200 on 2026-09-19.
asset_url() {
    local tool="$1" ver="$2" arch="$3"
    case "${tool}/${arch}" in
        uv/arm64)  printf 'https://github.com/astral-sh/uv/releases/download/%s/uv-aarch64-unknown-linux-gnu.tar.gz' "$ver" ;;
        uv/amd64)  printf 'https://github.com/astral-sh/uv/releases/download/%s/uv-x86_64-unknown-linux-gnu.tar.gz' "$ver" ;;
        ruff/arm64) printf 'https://github.com/astral-sh/ruff/releases/download/%s/ruff-aarch64-unknown-linux-gnu.tar.gz' "$ver" ;;
        ruff/amd64) printf 'https://github.com/astral-sh/ruff/releases/download/%s/ruff-x86_64-unknown-linux-gnu.tar.gz' "$ver" ;;
        node/arm64) printf 'https://nodejs.org/dist/v%s/node-v%s-linux-arm64.tar.xz' "$ver" "$ver" ;;
        node/amd64) printf 'https://nodejs.org/dist/v%s/node-v%s-linux-x64.tar.xz' "$ver" "$ver" ;;
        mise/arm64) printf 'https://github.com/jdx/mise/releases/download/v%s/mise-v%s-linux-arm64' "$ver" "$ver" ;;
        mise/amd64) printf 'https://github.com/jdx/mise/releases/download/v%s/mise-v%s-linux-x64' "$ver" "$ver" ;;
        trufflehog/arm64) printf 'https://github.com/trufflesecurity/trufflehog/releases/download/v%s/trufflehog_%s_linux_arm64.tar.gz' "$ver" "$ver" ;;
        trufflehog/amd64) printf 'https://github.com/trufflesecurity/trufflehog/releases/download/v%s/trufflehog_%s_linux_amd64.tar.gz' "$ver" "$ver" ;;
        actionlint/arm64) printf 'https://github.com/rhysd/actionlint/releases/download/v%s/actionlint_%s_linux_arm64.tar.gz' "$ver" "$ver" ;;
        actionlint/amd64) printf 'https://github.com/rhysd/actionlint/releases/download/v%s/actionlint_%s_linux_amd64.tar.gz' "$ver" "$ver" ;;
        dprint/arm64) printf 'https://github.com/dprint/dprint/releases/download/%s/dprint-aarch64-unknown-linux-gnu.zip' "$ver" ;;
        dprint/amd64) printf 'https://github.com/dprint/dprint/releases/download/%s/dprint-x86_64-unknown-linux-gnu.zip' "$ver" ;;
        *) return 1 ;;
    esac
}

BINARY_TOOLS="uv ruff node mise trufflehog actionlint dprint"
PYTHON_TOOLS="basedpyright semgrep playwright"

key_prefix() {
    # tr, not ${x^^}: this runs on the host's bash 3.2.
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

REQUIRED_KEYS=""
for t in $BINARY_TOOLS $PYTHON_TOOLS; do
    REQUIRED_KEYS="${REQUIRED_KEYS} $(key_prefix "$t")_VERSION"
done

MISSING=""
for k in $REQUIRED_KEYS; do
    v=$(version_of "$k")
    valid_version "$v" || MISSING="${MISSING} ${k}"
done
if [ -n "$MISSING" ]; then
    warn "no usable version for:${MISSING}"
    warn "pass each one as --set KEY=VALUE, or fix ${PINS}"
    exit 2
fi

info "pins file: ${PINS}"
info "fetching every asset; nothing is written until all of them verify"
printf '\n%-34s %-64s %s\n' 'ASSET' 'SHA256' 'SIZE'

# ---------------------------------------------------------------------------
# The binary tools
# ---------------------------------------------------------------------------

DIGESTS=""   # lines: "<KEY_PREFIX> <arch> <sha256> <bytes> <url>"
NODE_TARBALL=""
for tool in $BINARY_TOOLS; do
    prefix=$(key_prefix "$tool")
    ver=$(version_of "${prefix}_VERSION")
    for arch in arm64 amd64; do
        url=$(asset_url "$tool" "$ver" "$arch") || die "no asset URL known for ${tool}/${arch}"
        if fetch_digest "$url" "${tool} ${ver} ${arch}"; then
            DIGESTS="${DIGESTS}${prefix} ${arch} ${FETCH_SHA} ${FETCH_BYTES} ${url}"$'\n'
            # Keep the Node arm64 tarball: npm's version is read out of it below.
            if [ "$tool" = node ] && [ "$arch" = arm64 ]; then
                NODE_TARBALL="${TMP}/node-arm64.tar.xz"
                cp "${TMP}/asset" "$NODE_TARBALL"
            fi
        fi
    done
done

# ---------------------------------------------------------------------------
# The two values that are read back, never chosen
# ---------------------------------------------------------------------------

NODE_VERSION=$(version_of NODE_VERSION)
NODE_NPM_VERSION=""
if [ -n "$NODE_TARBALL" ]; then
    if tar -xJOf "$NODE_TARBALL" \
           "node-v${NODE_VERSION}-linux-arm64/lib/node_modules/npm/package.json" \
           > "${TMP}/npm-package.json" 2>/dev/null; then
        NODE_NPM_VERSION=$(jq -r '.version // empty' "${TMP}/npm-package.json" 2>/dev/null)
    fi
    if valid_version "$NODE_NPM_VERSION"; then
        printf '%-34s %s\n' "npm (read out of the tarball)" "$NODE_NPM_VERSION"
    else
        warn "FAIL npm: no version in the Node tarball's npm/package.json"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        NODE_NPM_VERSION=""
    fi
fi

# browsers.json at the pinned tag, which is what the installed playwright-core
# carries. The guest reads the same value back out of the install and toolcheck
# reports a drift, so this is a record, not a choice.
PLAYWRIGHT_VERSION=$(version_of PLAYWRIGHT_VERSION)
PLAYWRIGHT_CHROMIUM_REVISION=""
BROWSERS_URL="https://raw.githubusercontent.com/microsoft/playwright/v${PLAYWRIGHT_VERSION}/packages/playwright-core/browsers.json"
if curl -fsSL --retry 3 --max-time 120 -o "${TMP}/browsers.json" "$BROWSERS_URL" 2>/dev/null; then
    PLAYWRIGHT_CHROMIUM_REVISION=$(jq -r \
        '.browsers[] | select(.name=="chromium") | .revision // empty' \
        "${TMP}/browsers.json" 2>/dev/null | head -1)
fi
case "$PLAYWRIGHT_CHROMIUM_REVISION" in
    ""|*[!0-9]*)
        warn "FAIL chromium revision: no numeric chromium revision at ${BROWSERS_URL}"
        FETCH_FAILURES=$((FETCH_FAILURES + 1))
        PLAYWRIGHT_CHROMIUM_REVISION="" ;;
    *) printf '%-34s %s\n' "chromium revision (browsers.json)" "$PLAYWRIGHT_CHROMIUM_REVISION" ;;
esac

# ---------------------------------------------------------------------------
# The Python tools: one requirement file each, hashes compiled
# ---------------------------------------------------------------------------
#
# --universal, so one file covers both architectures and both are resolved
# against the same version set; --generate-hashes, so --require-hashes in the
# guest has something to refuse against; --python-version 3.12, which is what
# the guest image ships and what the venvs are built with.

compile_requirements() {
    local tool="$1" ver="$2" out="${REQ_DIR}/${1}.requirements.txt"
    mkdir -p "$REQ_DIR" || return 1
    printf '%s==%s\n' "$tool" "$ver" > "${TMP}/${tool}.in"
    if ! uv pip compile "${TMP}/${tool}.in" \
            --generate-hashes --universal --python-version 3.12 \
            --quiet --output-file "$out" 2>"${TMP}/${tool}.err"; then
        warn "FAIL ${tool}: uv pip compile failed"
        sed -n '1,8p' "${TMP}/${tool}.err" >&2
        return 1
    fi
    # The header uv writes names the input file by its temporary path and the
    # output by its absolute one. Both are rewritten: the committed file says
    # how to regenerate itself, and no path from the machine that ran this
    # script ends up in a committed artefact.
    sed -e "s|${TMP}/${tool}.in|(host/refresh-pins.sh: ${tool}==${ver})|g" \
        -e "s|${BOX_DIR}/||g" \
        "$out" > "${TMP}/${tool}.req" && mv "${TMP}/${tool}.req" "$out"
    printf '%-34s %s\n' "${tool} ${ver} requirements" \
        "$(grep -c -- '--hash=sha256:' "$out" | tr -d ' ') hashes"
}

if [ "$SKIP_PYTHON" -eq 0 ]; then
    for tool in $PYTHON_TOOLS; do
        prefix=$(key_prefix "$tool")
        compile_requirements "$tool" "$(version_of "${prefix}_VERSION")" \
            || FETCH_FAILURES=$((FETCH_FAILURES + 1))
    done
else
    info "--skip-python: the requirement files were left as they are"
fi

# ---------------------------------------------------------------------------
# Write, or refuse to
# ---------------------------------------------------------------------------

if [ "$FETCH_FAILURES" -gt 0 ]; then
    warn "${FETCH_FAILURES} asset(s) failed; ${PINS} was NOT changed"
    exit 1
fi

digest_for() {
    printf '%s' "$DIGESTS" | sed -n "s/^${1} ${2} \\([0-9a-f]*\\) .*\$/\\1/p" | head -1
}
url_for() {
    printf '%s' "$DIGESTS" | sed -n "s/^${1} ${2} [0-9a-f]* [0-9]* \\(.*\\)\$/\\1/p" | head -1
}

NEW="${TMP}/toolchain.pins"
{
    cat <<EOF
# agent-box — the toolchain pins. ONE file. Nothing here floats.
#
# Bump with host/refresh-pins.sh, which re-fetches every asset, records the
# digest it actually saw, and refuses to write a line it could not verify.
# Then \`agentbox start <repo>\` on each box. A box never moves on its own.
#
# Read one value with the same idiom test/smoke.sh uses:
#   sed -n 's/^KEY="\\(.*\\)"\$/\\1/p' guest/toolchain.pins
# URLs are written out in full rather than composed from the version above
# them, so that read returns a usable value to a reader that is not a shell.
#
# fetched: $(date -u +%Y-%m-%d)
EOF
    for tool in $BINARY_TOOLS; do
        prefix=$(key_prefix "$tool")
        printf '\n%s_VERSION="%s"\n' "$prefix" "$(version_of "${prefix}_VERSION")"
        if [ "$tool" = node ]; then
            printf '# What that tarball bundles. Read out of its own npm/package.json,\n'
            printf '# asserted by toolcheck, never installed separately.\n'
            printf 'NODE_NPM_VERSION="%s"\n' "$NODE_NPM_VERSION"
        fi
        for arch in ARM64 AMD64; do
            lower=$(printf '%s' "$arch" | tr '[:upper:]' '[:lower:]')
            printf '%s_URL_%s="%s"\n'    "$prefix" "$arch" "$(url_for "$prefix" "$lower")"
            printf '%s_SHA256_%s="%s"\n' "$prefix" "$arch" "$(digest_for "$prefix" "$lower")"
        done
    done
    cat <<EOF

# The Python tools carry no URL or digest here: each is installed from
# guest/toolchain/<tool>.requirements.txt with \`uv pip install
# --require-hashes\`, which refuses any wheel — transitive ones included — whose
# sha256 is not in that file. The files are compiled by host/refresh-pins.sh
# with \`uv pip compile --generate-hashes --universal --python-version 3.12\`.
BASEDPYRIGHT_VERSION="$(version_of BASEDPYRIGHT_VERSION)"
SEMGREP_VERSION="$(version_of SEMGREP_VERSION)"
PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION}"
# The browser build the pinned Playwright asks for. Read back from
# playwright-core's browsers.json, never chosen: it is a function of the
# Playwright version, and recording it is what makes a drift visible.
PLAYWRIGHT_CHROMIUM_REVISION="${PLAYWRIGHT_CHROMIUM_REVISION}"

# Claude Code. See docs/decisions.md, "Why Claude Code is the one version the
# box does not pin". \`latest\` here is a statement, not an omission:
# DISABLE_AUTOUPDATER=1 means the box never moves on its own, and
# \`agentbox update <repo>\` is the deliberate move.
CLAUDE_CODE_VERSION="latest"
EOF
} > "$NEW"

# One last refusal: no empty value may reach the file.
if grep -nE '^[A-Z][A-Z0-9_]*=""$' "$NEW" >&2; then
    warn "the lines above have no value; ${PINS} was NOT changed"
    exit 1
fi

mkdir -p "$(dirname "$PINS")" || die "could not create $(dirname "$PINS")"
mv "$NEW" "$PINS" || die "could not write ${PINS}"
chmod 0644 "$PINS"

printf '\n'
info "wrote ${PINS}"
[ "$SKIP_PYTHON" -eq 1 ] || info "wrote ${REQ_DIR}/*.requirements.txt"
info "next: 'agentbox start <repo>' on each box, which installs to the new pins"
