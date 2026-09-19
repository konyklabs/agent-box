#!/bin/bash
#
# agent-box — register marketplaces and install plugins inside the guest, from
# a plain list the host supplies.
#
# Runs in the guest, as the unprivileged guest user. Invoked at the end of
# provisioning (after the firewall is up, deliberately: the install pulls from
# GitHub, so it doubles as a live test of the GitHub range rule) and on demand
# by `agentbox plugins <repo> [--update]`.
#
# Usage: install-plugins.sh [--update]
#
# Input: /opt/agent-box-config/plugins.txt, one directive per line, '#' starts
# a comment. Two directives:
#
#   marketplace <owner/repo | url | local path>
#   install     <plugin@marketplace>
#
# The marketplace NAME is the one in the marketplace's own manifest, which is
# not always the repository name — `claude plugin marketplace list` prints it
# after an add. See docs/daily-use.md.
#
# Exit status:
#   0  everything asked for is registered and installed
#   5  the marketplace was unreachable inside the timeout — a network answer
#   4  the CLI refused for want of an account; run `agentbox token` first, then
#      `agentbox plugins <repo>`
#   1  something else failed
#   2  the input was malformed
#
# Provisioning treats a non-zero exit as a warning, never as a boot failure:
# plugins are a convenience, and none of the isolation depends on them.

set -uo pipefail

CONFIG_MOUNT="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
PLUGINS_FILE="${CONFIG_MOUNT}/plugins.txt"
UPDATE=0

export PATH="${HOME}/.local/bin:${PATH}"

log()  { printf 'install-plugins: %s\n' "$*"; }
warn() { printf 'install-plugins: %s\n' "$*" >&2; }
die()  { printf 'install-plugins: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
    --update) UPDATE=1 ;;
    "") ;;
    *) die "unknown argument: $1" ;;
esac

[ "$(id -u)" -ne 0 ] || die "must not run as root; plugins install into the guest user's config directory"

if [ ! -f "$PLUGINS_FILE" ]; then
    log "no ${PLUGINS_FILE} on the host config mount; nothing to install"
    exit 0
fi

command -v claude >/dev/null 2>&1 || { warn "claude is not on PATH"; exit 1; }
command -v python3 >/dev/null 2>&1 || { warn "python3 is not present"; exit 1; }

# ---------------------------------------------------------------------------
# Is this failure "you are not logged in"?
# ---------------------------------------------------------------------------
#
# The token is not in the VM at provisioning time — it is typed in afterwards,
# by `agentbox token` — so the honest question is whether an explicit CLI
# install needs an account at all. Rather than guess, the failure is
# classified: an auth-shaped message becomes exit 4 and a clear instruction,
# anything else stays a plain failure. test/smoke.sh records which of the two
# actually happens on a fresh guest.
looks_like_auth_failure() {
    printf '%s' "$1" | grep -qiE \
        'not logged in|please log ?in|sign ?in|authenticat|unauthori[sz]ed|invalid api key|no credentials|credentials not found|oauth|401'
}

AUTH_BLOCKED=0
FAILED=0
UNREACHABLE=0

# ---------------------------------------------------------------------------
# Every CLI call is bounded and reads nothing
# ---------------------------------------------------------------------------
#
# `</dev/null` because the CLI must never be able to consume this script's
# stdin, and because an unexpected prompt should fail immediately instead of
# waiting for an answer that is not coming.
#
# `timeout` because not every network failure is a fast one. The standing
# ruleset ends in REJECT, so a host that is simply off the allowlist fails
# immediately — but the cases that matter here are the ones that do not: an
# allowlisted GitHub that accepts the connection and then stops answering, a
# rebuild mid-flight, or the hard-closed state after a failed firewall init,
# where the policy is DROP and there is no DNS rule at all. Any of those hangs.
# This runs from provisioning on every boot, so `limactl start` would block on
# it while the operator watched a create that looked like it was working —
# precisely the failure mode the decisions entry on DISABLE_AUTOUPDATER calls
# the worst kind. Bounded, it fails closed and says why.
ABX_CLI_TIMEOUT="${ABX_CLI_TIMEOUT:-120}"
ABX_TIMEOUT_RC=124

if command -v timeout >/dev/null 2>&1; then
    bounded() { timeout "$ABX_CLI_TIMEOUT" "$@" </dev/null; }
else
    warn "timeout(1) is not present; CLI calls will not be time-bounded"
    bounded() { "$@" </dev/null; }
fi

# ---------------------------------------------------------------------------
# State queries
# ---------------------------------------------------------------------------

marketplace_registered() {
    local ref="$1" json
    json=$(bounded claude plugin marketplace list --json 2>/dev/null) || return 1
    printf '%s' "$json" | python3 -c '
import json, sys
ref = sys.argv[1]
try:
    entries = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(entries, list):
    sys.exit(1)
for e in entries:
    if not isinstance(e, dict):
        continue
    if ref in (e.get("name"), e.get("repo"), e.get("path"), e.get("source"), e.get("url")):
        sys.exit(0)
sys.exit(1)
' "$ref"
}

plugin_installed() {
    local spec="$1" json
    json=$(bounded claude plugin list --json 2>/dev/null) || return 1
    printf '%s' "$json" | python3 -c '
import json, sys

# The CLI reports installed plugins as "<name>@<marketplace>". When the spec
# names a marketplace, that whole identity must match: a supervisor installed
# from somewhere else is a different plugin wearing the same name, and calling
# it "already installed" means the guest quietly runs code from a source the
# operator did not ask for. A bare-name spec has no marketplace to compare, so
# there the name is all there is.
spec = sys.argv[1]
name = spec.split("@", 1)[0]
exact_only = "@" in spec
try:
    entries = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(entries, list):
    sys.exit(1)
for e in entries:
    if not isinstance(e, dict):
        continue
    ident = e.get("id") or ""
    if ident == spec or (not exact_only and ident.split("@", 1)[0] == name):
        sys.exit(0)
sys.exit(1)
' "$spec"
}

# ---------------------------------------------------------------------------
# Actions. Each captures output so a failure can be classified and shown once.
# ---------------------------------------------------------------------------

run_cli() {
    local what="$1"; shift
    local out rc
    out=$(bounded "$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        log "${what}: ok"
        return 0
    fi
    if [ "$rc" -eq "$ABX_TIMEOUT_RC" ]; then
        UNREACHABLE=1
        warn "${what}: no answer within ${ABX_CLI_TIMEOUT}s — the marketplace is unreachable"
    elif looks_like_auth_failure "$out"; then
        AUTH_BLOCKED=1
        warn "${what}: refused, and the message names authentication"
    else
        FAILED=1
        warn "${what}: failed (exit ${rc})"
    fi
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    return "$rc"
}

# ---------------------------------------------------------------------------
# Walk the file
# ---------------------------------------------------------------------------
#
# Read into an array first, rather than looping with the file on stdin. With
# `done < "$PLUGINS_FILE"` the file IS the loop body's stdin, and the body
# invokes the CLI: anything it read for a prompt or a TTY probe would eat the
# remaining directives. The observable result would not be an error — it would
# be the later `install` lines silently never running, followed by "done" and
# exit 0. Every CLI call also gets `</dev/null` from `bounded`, so this is
# belt and braces on a failure that is invisible when it happens.

INSTALL_SPECS=()
LINES=()
# Checked, because the failure this guards against is the one that looks like
# success: a mapfile that does not run leaves LINES empty, every directive is
# skipped, and the script reports "done" and exits 0.
mapfile -t LINES < "$PLUGINS_FILE" \
    || die "could not read ${PLUGINS_FILE} (mapfile exited $?); no directive was applied"

for raw in ${LINES[@]+"${LINES[@]}"}; do
    line="${raw%%#*}"
    # Trim leading and trailing whitespace without invoking anything.
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue

    directive="${line%%[[:space:]]*}"
    argument="${line#"$directive"}"
    argument="${argument#"${argument%%[![:space:]]*}"}"

    # Arguments reach the CLI as argv, so quoting and metacharacters are inert
    # — but a leading dash is not. `marketplace --help` would become
    # `claude plugin marketplace add --help`, which prints help, exits 0, and
    # is logged as a successful registration. A file that is wrong should say
    # so, not succeed at nothing.
    case "$argument" in
        -*) die "a '${directive}' argument must not start with '-': ${raw}" ;;
    esac

    case "$directive" in
        marketplace)
            [ -n "$argument" ] || die "a 'marketplace' line needs a source: ${raw}"
            if marketplace_registered "$argument"; then
                log "marketplace ${argument}: already registered"
            else
                run_cli "marketplace add ${argument}" claude plugin marketplace add "$argument" || true
            fi
            ;;
        install)
            [ -n "$argument" ] || die "an 'install' line needs a plugin: ${raw}"
            INSTALL_SPECS+=("$argument")
            ;;
        *)
            die "unknown directive '${directive}' in ${PLUGINS_FILE}: ${raw}"
            ;;
    esac
done

# `marketplace update` is one call for all of them, so it happens between the
# two passes rather than per line.
if [ "$UPDATE" -eq 1 ]; then
    run_cli "marketplace update" claude plugin marketplace update || true
fi

for spec in "${INSTALL_SPECS[@]:-}"; do
    [ -n "$spec" ] || continue
    if plugin_installed "$spec"; then
        if [ "$UPDATE" -eq 1 ]; then
            # `update` rather than uninstall-and-install: it is the CLI's own
            # affordance for this, and it does not tear down a plugin's data
            # directory on the way past.
            run_cli "update ${spec}" claude plugin update --yes "${spec%%@*}" || true
        else
            log "install ${spec}: already installed"
        fi
        continue
    fi
    # --yes: required whenever stdin or stdout is not a TTY, which is every
    # invocation from provisioning and from `agentbox plugins`.
    run_cli "install ${spec}" claude plugin install --yes "$spec" || true
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

if [ "$UNREACHABLE" -eq 1 ]; then
    cat >&2 <<EOF
install-plugins: the marketplace was unreachable — no answer within ${ABX_CLI_TIMEOUT}s.

The VM is up and everything else about it works; it just could not fetch the
plugins. That is a network answer, not a plugin one. In order of likelihood:

    agentbox firewall-check <repo>   # is the GitHub range rule intact?
    agentbox plugins <repo>          # then try again

EOF
    exit 5
fi

if [ "$AUTH_BLOCKED" -eq 1 ]; then
    cat >&2 <<'EOF'
install-plugins: the CLI would not install plugins without an account.

Nothing was left half-done. Put the token in first and run the install again:

    agentbox token   <repo>      # paste the OAuth token, once
    agentbox plugins <repo>      # then this step

EOF
    exit 4
fi

[ "$FAILED" -eq 0 ] || exit 1

log "done"
exit 0
