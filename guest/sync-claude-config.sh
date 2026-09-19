#!/bin/bash
#
# agent-box — carry a small, named set of personal Claude Code configuration
# files from the host into the guest, and mark /work as a trusted folder.
#
# Runs in the guest, as the unprivileged guest user. Invoked at the end of
# provisioning and again before every `agentbox start`, `run`, `shell` and
# `claude`. It is cheap and idempotent, so running it often is the point: a
# file edited on the host is picked up on the next launch.
#
# Usage: sync-claude-config.sh [--quiet]
#
# Source: /opt/agent-box-config/claude/   (the host's ~/.config/agent-box/guest/claude)
# Target: $CLAUDE_CONFIG_DIR              (the guest's ~/.claude)
#
# The copy is an ALLOWLIST of names, not a mirror. The source directory is a
# subdirectory of a mount the host user edits by hand; a blind copy would
# happily carry a `.credentials.json` from the host into a VM running against
# a repository that is not the host's own, which is the exact direction of
# leak this whole project exists to prevent. So the names that may cross are
# written down here, and anything credential-shaped is refused out loud rather
# than ignored quietly — a silent skip looks identical to a successful copy.

set -uo pipefail

CONFIG_MOUNT="${AGENT_BOX_CONFIG_DIR:-/opt/agent-box-config}"
SRC="${CONFIG_MOUNT}/claude"
DEST="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
TRUST_PROJECT="${AGENT_BOX_WORK:-/work}"

QUIET=0
case "${1:-}" in
    --quiet) QUIET=1 ;;
    "") ;;
    *) printf 'sync-claude-config: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

log()  { [ "$QUIET" -eq 1 ] || printf 'sync-claude-config: %s\n' "$*"; }
warn() { printf 'sync-claude-config: %s\n' "$*" >&2; }
die()  { printf 'sync-claude-config: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "must not run as root; the config directory belongs to the guest user"

# Files that may cross. Anything else in the source directory is left behind.
ALLOWED_FILES=(CLAUDE.md settings.json supervisor.json governor.json)

# Names that must NEVER cross, reported rather than skipped. Matched as shell
# patterns against the entry name.
DENIED_PATTERNS=('.credentials.json' '*.token' 'projects' 'plugins' 'history*' 'todos' '.claude.json' 'shell-snapshots' 'statsig')

refused=0
stripped=0

is_denied() {
    local name="$1" pat
    for pat in "${DENIED_PATTERNS[@]}"; do
        # shellcheck disable=SC2053  # a pattern match is exactly what is wanted
        [[ "$name" == $pat ]] && return 0
    done
    return 1
}

install_file() {
    local src="$1" dest="$2"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        log "unchanged ${dest#"$DEST"/}"
        return 0
    fi
    # 0600: the config directory holds nothing another account needs to read,
    # and one of these files may hold a supervisor budget or personal prose.
    install -m 0600 "$src" "$dest" || die "could not write ${dest}"
    log "copied    ${dest#"$DEST"/}"
}

# settings.json is not opaque, and treating it as opaque is how a credential
# crosses a name-based allowlist. The Claude Code settings format has keys that
# hold or mint one: `env` is merged into the CLI's own process environment, so
# `"env": {"ANTHROPIC_API_KEY": "..."}` is a literal key that arrives after
# every shell-environment check has passed; `apiKeyHelper` is a command the CLI
# runs to produce one; `awsAuthRefresh` and `awsCredentialExport` do the same
# for Bedrock. This is not exotic misuse — it is the ordinary content of the
# very file a person would copy in to get their settings.
#
# So the object is filtered rather than the file copied, each removal is named
# the way a refusal is, and anything anywhere in the document whose value looks
# like an Anthropic key goes too.
#
# The file has two owners, which is why this is a merge and not a copy. The
# operator owns their preferences. The CLI owns `enabledPlugins` and
# `extraKnownMarketplaces`, which is where `claude plugin install` records what
# it did — so a wholesale copy silently disables every plugin the guest just
# installed. Those two keys are also machine-specific in the other direction:
# the host's `extraKnownMarketplaces` names a path on the host that does not
# exist in the guest, so carrying it in would both break and leak a host path.
# They are therefore stripped from the incoming file and preserved from the
# guest's own.
install_settings_json() {
    local src="$1" dest="$2" tmp rc
    tmp=$(mktemp "${DEST}/.settings.json.XXXXXX") || die "could not create a temporary file in ${DEST}"

    python3 - "$src" "$tmp" "$dest" <<'PY'
import json, os, sys

# Keys that can hold or mint a credential. Removed and named.
BANNED = ("env", "apiKeyHelper", "awsAuthRefresh", "awsCredentialExport")
# Keys the guest's own CLI owns. Never taken from the host, always kept from
# the guest's existing file.
GUEST_OWNED = ("enabledPlugins", "extraKnownMarketplaces")

src, dest, existing = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(src, encoding="utf-8") as fh:
        data = json.load(fh)
except (ValueError, UnicodeDecodeError) as exc:
    print("sync-claude-config: REFUSED settings.json — it does not parse as JSON (%s)" % exc,
          file=sys.stderr)
    raise SystemExit(3)

if not isinstance(data, dict):
    print("sync-claude-config: REFUSED settings.json — the top level is not a JSON object",
          file=sys.stderr)
    raise SystemExit(3)

removed = []

for key in BANNED:
    if key in data:
        del data[key]
        removed.append(key)

for key in GUEST_OWNED:
    if key in data:
        del data[key]
        print("sync-claude-config: settings.json:%s is the guest CLI's own; the host copy "
              "is not carried over" % key, file=sys.stderr)

kept = {}
if os.path.exists(existing):
    try:
        with open(existing, encoding="utf-8") as fh:
            previous = json.load(fh)
        if isinstance(previous, dict):
            kept = {k: previous[k] for k in GUEST_OWNED if k in previous}
    except (ValueError, UnicodeDecodeError, OSError):
        kept = {}

data.update(kept)
for key in sorted(kept):
    print("sync-claude-config: settings.json:%s preserved from the guest" % key,
          file=sys.stderr)


def strip_keys(node, path):
    """Drop any key anywhere whose value is a string that looks like an API key."""
    if isinstance(node, dict):
        for key in list(node):
            value = node[key]
            if isinstance(value, str) and value.startswith("sk-ant-"):
                del node[key]
                removed.append(".".join(path + [str(key)]))
            else:
                strip_keys(value, path + [str(key)])
    elif isinstance(node, list):
        for index, value in enumerate(node):
            strip_keys(value, path + [str(index)])


strip_keys(data, [])

for key in removed:
    print("sync-claude-config: STRIPPED settings.json:%s — credential-bearing "
          "settings never cross into the guest" % key, file=sys.stderr)

with open(dest, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")

raise SystemExit(4 if removed else 0)
PY
    rc=$?

    case "$rc" in
        0) ;;
        # 4: keys were removed. The file still crosses, filtered — counted
        # apart from a refusal, because "refused" and "copied without its
        # credential" are different outcomes and the summary should not blur
        # them.
        4) stripped=$((stripped + 1)) ;;
        3) rm -f "$tmp"; refused=$((refused + 1)); return 0 ;;
        *) rm -f "$tmp"; die "could not filter ${src} (python3 exited ${rc})" ;;
    esac

    chmod 0600 "$tmp" || die "could not set the mode on ${tmp}"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        log "unchanged settings.json"
        return 0
    fi
    mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "could not write ${dest}"; }
    log "copied    settings.json (filtered)"
}

# rules/ is the one target directory this script owns outright, so it is the
# one place a deletion on the host can safely be mirrored. Copying without
# pruning would leave a rule the operator deleted still shaping what the agent
# does inside the VM, with nothing on the host to show for it — and a stale
# standing instruction is invisible from the outside in a way a stale
# CLAUDE.md is not.
#
# Only this directory, and only .md files in it. The rest of the config
# directory belongs to the CLI.
sync_rules_dir() {
    local src_rules="$1" rule name found_rule=0
    install -d -m 0700 "${DEST}/rules" || die "could not create ${DEST}/rules"

    for rule in "$src_rules"/*.md; do
        [ -f "$rule" ] || continue
        install_file "$rule" "${DEST}/rules/$(basename "$rule")"
        found_rule=1
    done
    [ "$found_rule" -eq 1 ] || log "rules/ has no .md files"

    for rule in "${DEST}"/rules/*.md; do
        [ -f "$rule" ] || continue
        name=$(basename "$rule")
        [ -f "${src_rules}/${name}" ] && continue
        rm -f "$rule" || die "could not remove ${rule}"
        log "pruned    rules/${name} (no longer on the host)"
    done
}

# ---------------------------------------------------------------------------
# 1. The config directory itself
# ---------------------------------------------------------------------------

install -d -m 0700 "$DEST" || die "could not create ${DEST}"

# ---------------------------------------------------------------------------
# 2. The allowlisted files
# ---------------------------------------------------------------------------

if [ ! -d "$SRC" ]; then
    log "no ${SRC} on the host config mount; nothing to carry over"
else
    for entry in "$SRC"/* "$SRC"/.*; do
        [ -e "$entry" ] || continue
        name=$(basename "$entry")
        case "$name" in .|..) continue ;; esac

        if is_denied "$name"; then
            warn "REFUSED ${name} — credentials, history and installed state never cross into the guest"
            refused=$((refused + 1))
            continue
        fi

        # A symlink resolves inside the guest, so one pointing at a host path
        # is simply broken here — which is also why it is not an escape route.
        # Refuse it by name rather than letting it fall through to a message
        # about the allowlist, which would send the operator looking in the
        # wrong place.
        if [ -L "$entry" ]; then
            warn "REFUSED ${name} — it is a symlink; only real files are copied, and a link to a host path does not resolve inside the guest"
            refused=$((refused + 1))
            continue
        fi

        if [ "$name" = "rules" ] && [ -d "$entry" ]; then
            sync_rules_dir "$entry"
            continue
        fi

        allowed=0
        for want in "${ALLOWED_FILES[@]}"; do
            [ "$name" = "$want" ] && allowed=1 && break
        done

        if [ "$allowed" -eq 0 ]; then
            log "skipped   ${name} (not on the carry-over allowlist)"
        elif [ ! -f "$entry" ]; then
            # On the allowlist but not a regular file. Saying "not on the
            # allowlist" here sends the reader to edit a list that already
            # contains the name.
            log "skipped   ${name} (on the allowlist, but not a regular file)"
        elif [ "$name" = "settings.json" ]; then
            install_settings_json "$entry" "${DEST}/${name}"
        else
            install_file "$entry" "${DEST}/${name}"
        fi
    done

    # The loop only reaches sync_rules_dir when the host still has a rules
    # directory. Removing the whole directory on the host has to prune too,
    # or the deletion that is hardest to notice is the one that does nothing.
    if [ ! -d "${SRC}/rules" ] && [ -d "${DEST}/rules" ]; then
        for stale in "${DEST}"/rules/*.md; do
            [ -f "$stale" ] || continue
            rm -f "$stale" || die "could not remove ${stale}"
            log "pruned    rules/$(basename "$stale") (the host has no rules/ directory)"
        done
    fi
fi

# ---------------------------------------------------------------------------
# 3. Mark /work as trusted
# ---------------------------------------------------------------------------
#
# Claude Code asks about an unfamiliar folder before it will act in it, and
# records the answer in .claude.json — which lives inside CLAUDE_CONFIG_DIR
# when that variable is set (verified: running the CLI with CLAUDE_CONFIG_DIR
# pointed at an empty directory creates .claude.json there, not in $HOME).
# Until the folder is trusted, a repository's own .claude/settings.json — its
# extraKnownMarketplaces and enabledPlugins among them — is inert under `-p`.
#
# There is exactly one folder in this VM, it was scanned by preflight on the
# host before the VM was allowed to mount it, and a headless run has no way to
# answer a dialog. So it is trusted here, deliberately and visibly, rather than
# by a flag buried in a launch command.
#
# The merge is a read-modify-write of someone else's file format: never clobber
# it, never drop keys, and never leave a half-written file behind.
#
# Two hazards, because this runs before every launch and the CLI owns the file:
#
# - Concurrency. Two launches, or a launch alongside a running session, can
#   interleave. An flock on a sibling lockfile serialises this script against
#   itself. It cannot serialise it against the CLI, which is why the second
#   guard matters more.
# - A file caught mid-write. It will not parse. The earlier version renamed it
#   aside and started fresh, which is the worst possible response: the running
#   session's live config — other projects' trust decisions, its history — ends
#   up in a `.corrupt-` file nobody looks at, and the session then writes its
#   own state over the two-key replacement. So: re-read once after a short
#   pause, and if it still does not parse, say so and exit non-zero WITHOUT
#   touching the file. The caller treats a failed sync as non-fatal, so the
#   cost is one launch running with the trust flag unset, which is recoverable.
#   Displacing a live config is not.

python3 - "$DEST/.claude.json" "$TRUST_PROJECT" "$QUIET" <<'PY'
import fcntl, json, os, sys, tempfile, time

path, project, quiet = sys.argv[1], sys.argv[2], sys.argv[3] == "1"


def say(message):
    if not quiet:
        print(message)


def load(where):
    """Return (data, error). A missing file is an empty object, not an error."""
    if not os.path.exists(where):
        return {}, None
    try:
        with open(where, encoding="utf-8") as fh:
            return json.load(fh), None
    except (ValueError, UnicodeDecodeError) as exc:
        return None, exc


lock_path = path + ".lock"
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

    data, error = load(path)
    if error is not None:
        # Most likely someone else's partial write. Give it a moment.
        time.sleep(0.5)
        data, error = load(path)

    if error is not None:
        print("sync-claude-config: %s does not parse (%s). Leaving it exactly as it is — "
              "another process may be writing it. %s was not marked as trusted."
              % (path, error, project), file=sys.stderr)
        raise SystemExit(1)

    if not isinstance(data, dict):
        print("sync-claude-config: %s is not a JSON object; refusing to touch it" % path,
              file=sys.stderr)
        raise SystemExit(1)

    projects = data.setdefault("projects", {})
    if not isinstance(projects, dict):
        print("sync-claude-config: projects in %s is not an object; refusing to touch it" % path,
              file=sys.stderr)
        raise SystemExit(1)

    entry = projects.setdefault(project, {})
    if not isinstance(entry, dict):
        print("sync-claude-config: projects[%r] is not an object; refusing to touch it" % project,
              file=sys.stderr)
        raise SystemExit(1)

    # Onboarding: the interactive CLI walks a fresh config through a theme
    # picker and then a "Select login method" screen, and that screen appears
    # even with CLAUDE_CODE_OAUTH_TOKEN in the environment (verified on
    # 2.1.263: `agentbox claude` on a fresh box lands in the browser OAuth
    # flow; `-p` skips onboarding, which is why `run` and `verify-auth` never
    # saw it). Marking onboarding done is what makes the token the only
    # credential the CLI ever asks for. The theme is only set when absent.
    changes = []
    if data.get("hasCompletedOnboarding") is not True:
        data["hasCompletedOnboarding"] = True
        data.setdefault("theme", "dark")
        changes.append("marked onboarding complete")
    if entry.get("hasTrustDialogAccepted") is not True:
        entry["hasTrustDialogAccepted"] = True
        changes.append("marked %s as trusted" % project)
    if not changes:
        say("sync-claude-config: %s is already trusted" % project)
        raise SystemExit(0)

    # Same directory, so the replace is atomic on the same filesystem.
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".claude.json.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    say("sync-claude-config: " + "; ".join(changes))
finally:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
    finally:
        os.close(lock_fd)
PY
trust_rc=$?
[ "$trust_rc" -eq 0 ] || die "could not mark ${TRUST_PROJECT} as trusted (python3 exited ${trust_rc})"

if [ "$refused" -gt 0 ]; then
    warn "${refused} file(s) were refused; they are still on the host, they were simply not copied in"
fi
if [ "$stripped" -gt 0 ]; then
    warn "${stripped} file(s) crossed with credential-bearing keys removed; the host copy is untouched"
fi

exit 0
