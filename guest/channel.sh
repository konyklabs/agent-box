#!/bin/bash
#
# agent-box — the box's side of the channel to the host.
#
# Runs in the guest, as the unprivileged guest user, and is on the PATH of every
# session and run as `abx` (guest/bin/abx). The agent inside the box calls it to
# hand work over, to ask something, and to read the requests the host queues for
# it; the host never runs it except through `limactl shell`.
#
# Usage:
#   channel.sh handoff [--branch B] [--re ID] [--subject S] [--allow-dirty]
#                                       the body on stdin; prints the id
#   channel.sh ask  [--re ID] TEXT|-    a question for the host's session
#   channel.sh note [--re ID] TEXT|-    anything else worth saying
#   channel.sh inbox [--all]            requests from the host
#   channel.sh read ID                  one request in full; records it delivered
#   channel.sh done ID [--note TEXT]    that request is dealt with
#   channel.sh status [TEXT | --clear]  both sides now; TEXT declares the task
#   channel.sh standing-state           internal: one word, for the host
#   channel.sh hook EVENT               internal: delivery into this session
#
# The mailbox is two directories on the mount — `<repo>/.agent-box/channel/`,
# `to-host/` for what this box says and `to-box/` for what the host queues — and
# one message is one immutable file `<id>.md`: headers, a blank line, a markdown
# body. Published by reserve-then-rename, so a reader never sees half of one.
#
# Three rules decide almost every line below.
#
# 1. Each side believes only its own disk. The empty sidecar files this script
#    writes (`<id>.delivered`, `<id>.done`) are the BOX's word about itself, for
#    the host to read; the ones the host writes (`<id>.read`, `<id>.done` in
#    `to-host/`) are the host's word, for this side to read. Neither side reads
#    its own sidecars back, so neither can be made to forget what it did by
#    something written on a shared mount.
#
# 2. Everything that leaves this box is scrubbed on the way IN. A body and a
#    subject go through run-format.py --scrub-stdin before they are written, so a
#    token fragment never reaches the host's disk in the first place. The host
#    scrubs again on the way out, because the guest's renderer is not a trust
#    anchor — but the write-time scrub is what keeps the credential off the
#    host's filesystem and out of its backups.
#
# 3. The mount is shared, so every path is checked before it is used. A message
#    is read only when it is a regular file, not a symlink, not empty and not
#    larger than a message can be; a name that is not `<id>.md` is not a message;
#    no write onto the mount is a bare redirect.
#
# The delivery half — the hook that shows a request to the standing session — is
# the next slice's; the sets it needs are computed here (`channel_open_ids`,
# `channel_unseen_ids`) so that one definition serves both it and these verbs.

set -uo pipefail

die() { printf 'abx: %s\n' "$*" >&2; exit 1; }
say() { printf 'abx: %s\n' "$*"; }

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

export TZ=UTC
# Every file this script creates is private by default: message files are 600,
# the state directories 700. A umask is the only way to get that without a
# window in which the file exists and is world-readable.
umask 077

CH_TO_HOST="${ABX_CHANNEL_DIR}/to-host"
CH_TO_BOX="${ABX_CHANNEL_DIR}/to-box"
CH_HOST_STATUS="${ABX_CHANNEL_DIR}/host-status"

# The caps of the message format. The body cap is what the sanctioned writer
# will produce; the file cap is the size above which a reader refuses a file
# outright, because a file that large was not written by this tool.
CH_BODY_LIMIT=16384
CH_ASK_LIMIT=4096
CH_FILE_LIMIT=65536
CH_SUBJECT_LIMIT=120
CH_TASK_LIMIT=200
CH_HEADER_LINES=12
CH_HEADER_BYTES=2048
# Beyond this many messages waiting in one direction the writer refuses and says
# what to do about it. An unread mailbox is a person not reading, and filling it
# further helps nobody.
CH_PENDING_LIMIT=200
# How many of this box's own messages `status` shows.
CH_STATUS_LIMIT=10

# C0 controls, DEL. Deleted from anything read off the mount before it reaches a
# terminal — the same set the host's own bar strips, and for the same reason: an
# escape sequence can repaint a screen or hide a line. Tab and newline are kept,
# and the UTF-8 continuation bytes are left alone so multibyte text survives.
CH_CONTROLS='\000-\010\013-\037\177'

# Which session this process belongs to. claude-session.sh exports it for the
# standing session and for nothing else, so a run and an untracked shell both
# read as empty here — and what is empty cannot record a delivery against a
# session that never saw the message.
CH_SESSION="${ABX_CHANNEL_SESSION:-}"

CH_WORKDIR=""

# ---------------------------------------------------------------------------
# Directories, names and shapes
# ---------------------------------------------------------------------------

# For a reader: are the channel's directories there and plain? Silent, and it
# creates nothing. An absent mailbox is not an error — the first writer makes it,
# and until then there is genuinely nothing to list.
channel_dirs_present() {
    local d
    for d in "${ABX_WORK_DIR}/.agent-box" "$ABX_CHANNEL_DIR" "$CH_TO_HOST" "$CH_TO_BOX"; do
        [ ! -L "$d" ] || return 1
        [ -d "$d" ] || return 1
    done
    return 0
}

# For a writer: make them, or refuse. The containment lives in lib.sh, shared
# with the delivery hook, and it refuses a path component that is a symlink or
# not a directory rather than following it.
#
# The git exclude entry goes in at the same moment: the channel is the second
# thing this project writes under the mount, and a repository that starts
# reporting `.agent-box/` as untracked content is a repository whose owner has
# to think about our files.
channel_require_dirs() {
    abx_exclude_state_dir "$ABX_WORK_DIR"
    abx_channel_dirs || die "refusing: a component of ${ABX_CHANNEL_DIR} is a symlink or not a directory; the channel cannot be used until that is fixed"
}

# A private scratch directory under the guest home, removed on exit. A message
# is built here and copied to the mount as one finished file: building it in
# place would let a reader on the other side see a message that is still being
# written, and /tmp is not the right place either — the guest home is where
# everything else this project keeps privately lives.
channel_workdir() {
    [ -z "$CH_WORKDIR" ] || return 0
    abx_private_dir "$ABX_STATE_DIR"
    CH_WORKDIR=$(mktemp -d "${ABX_STATE_DIR}/.tmp.channel.XXXXXX") \
        || die "cannot create a private temporary directory under ${ABX_STATE_DIR}"
    chmod 700 "$CH_WORKDIR" 2>/dev/null || true
    # shellcheck disable=SC2064  # expanded now on purpose: the trap must remove the directory this call created, not whatever the variable says later.
    trap "rm -rf '${CH_WORKDIR}'" EXIT
}

# Message ids in one direction, oldest first. NAMES only, and every one of them
# shape-matched before it is printed: a file name on this mount is chosen by
# whoever wrote it, which in `to-box/` is the host and in `to-host/` is the model.
#
# One `find`, bounded: `-type f` excludes a symlink wearing a message's name,
# `-size +0c` excludes a reservation whose content has not arrived, and the head
# bounds a directory somebody filled.
#
# A name with a newline in it arrives here as TWO lines, and each half can be
# shaped exactly like a message name — `A<LF>B.md` yields `A` and `B.md`, both of
# which pass the shape on their own and neither of which names a file. So the
# shape is not enough: the line has to be the whole path the id reconstructs, and
# that path has to be a message file still. Without both, one such name in
# `to-box/` puts an id in OPEN that `abx done` can never clear, and a hundred in
# `to-host/` push the pending count past its limit and stop this box publishing.
channel_ids() {
    local dir="${1:?}" line id
    dir="${dir%/}"
    [ -d "$dir" ] || return 0
    while IFS= read -r line; do
        id="${line##*/}"
        id="${id%.md}"
        abx_valid_msgid "$id" || continue
        [ "$line" = "${dir}/${id}.md" ] || continue
        [ -f "${dir}/${id}.md" ] && [ ! -L "${dir}/${id}.md" ] || continue
        printf '%s\n' "$id"
    done < <(find "$dir" -maxdepth 1 -type f -size +0c -name '[0-9]*.md' 2>/dev/null |
        head -n 1000 | sort)
}

# Newest first, for the listings a person reads.
channel_ids_desc() {
    channel_ids "${1:?}" | sort -r
}

channel_pending_count() {
    channel_ids "${1:?}" | grep -c '' || true
}

# A file's size in bytes, digits and nothing else, or non-zero.
#
# It is a function because `wc -c < file` pads its answer with spaces on BSD and
# not on GNU, and a count that is compared, shape-checked or put in a message
# must not depend on which of those is installed. Every byte count below comes
# from here.
channel_bytes() {
    local n
    n=$(wc -c < "${1:?}" 2>/dev/null) || return 1
    n="${n//[[:space:]]/}"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$n"
}

# Is this file a message at all? The four questions that must be answered before
# anything opens it, in the order that makes each one meaningful.
channel_message_ok() {
    local f="${1:?}" bytes
    [ ! -L "$f" ] || return 1
    [ -f "$f" ] || return 1
    [ -s "$f" ] || return 1
    bytes=$(channel_bytes "$f") || return 1
    [ "$bytes" -le "$CH_FILE_LIMIT" ] || return 1
    return 0
}

# One header value, kept only if it passes the shape its key demands. Every
# field below is either a fixed vocabulary or a pattern, because these values
# are printed, compared and (on the host, for the branch and the commit) handed
# to git. Anything else reads as absent and is named in CH_H_INVALID: never
# silently dropped, never echoed.
channel_valid_iso() {
    case "${1:-}" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
        *) return 1 ;;
    esac
}

channel_valid_commit() {
    local v="${1:-}"
    case "${#v}" in 40|64) ;; *) return 1 ;; esac
    case "$v" in *[!0-9a-f]*) return 1 ;; esac
    return 0
}

channel_valid_oneline() {
    local v="${1:-}"
    [ -n "$v" ] || return 1
    case "$v" in *[[:cntrl:]]*) return 1 ;; esac
    return 0
}

# Headers into CH_H_* globals, first occurrence wins, unknown keys dropped.
# Returns non-zero when the file is not a message: not readable as one, or
# carrying no header this reader recognises. The header block is bounded both
# ways so that a file with four thousand `a: b` lines costs twelve reads.
channel_parse_headers() {
    local f="${1:?}" line key value seen=" " n=0 total=0 parsed=0
    CH_H_CREATED=""
    CH_H_TYPE=""
    CH_H_SESSION=""
    CH_H_BRANCH=""
    CH_H_COMMIT=""
    CH_H_DIRTY=""
    CH_H_RE=""
    CH_H_VERDICT=""
    CH_H_SUBJECT=""
    CH_H_INVALID=""
    channel_message_ok "$f" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || break
        n=$((n + 1))
        [ "$n" -le "$CH_HEADER_LINES" ] || break
        total=$((total + ${#line} + 1))
        [ "$total" -le "$CH_HEADER_BYTES" ] || break
        case "$line" in *': '*) ;; *) continue ;; esac
        key="${line%%: *}"
        value="${line#*: }"
        case "$key" in
            ''|*[!a-z]*) continue ;;
        esac
        [ "${#key}" -ge 2 ] && [ "${#key}" -le 12 ] || continue
        [ "${#value}" -le 200 ] || continue
        case "$seen" in *" ${key} "*) continue ;; esac
        seen="${seen}${key} "
        parsed=$((parsed + 1))
        channel_take_header "$key" "$value"
    done < "$f"
    # `type` is structural: without it nobody can say what the file is, and a
    # reader that showed its body anyway would be showing bytes that nothing
    # vouches for. A bad `branch` is the other case — the message is real and one
    # of its claims is not, which is what CH_H_INVALID is for.
    [ "$parsed" -gt 0 ] && [ -n "$CH_H_TYPE" ]
}

channel_take_header() {
    local key="${1:?}" value="${2-}"
    case "$key" in
        created)
            if channel_valid_iso "$value"; then CH_H_CREATED="$value"; else channel_mark_invalid created; fi ;;
        type)
            case "$value" in
                handoff|question|note|request) CH_H_TYPE="$value" ;;
                *) channel_mark_invalid type ;;
            esac ;;
        session)
            case "$value" in
                claude|shell) CH_H_SESSION="$value" ;;
                run-*) if abx_valid_runid "${value#run-}"; then CH_H_SESSION="$value"; else channel_mark_invalid session; fi ;;
                *) channel_mark_invalid session ;;
            esac ;;
        branch)
            if abx_valid_branch "$value"; then CH_H_BRANCH="$value"; else channel_mark_invalid branch; fi ;;
        commit)
            if channel_valid_commit "$value"; then CH_H_COMMIT="$value"; else channel_mark_invalid commit; fi ;;
        dirty)
            case "$value" in
                ''|*[!0-9]*) channel_mark_invalid dirty ;;
                *) if [ "${#value}" -le 6 ]; then CH_H_DIRTY="$value"; else channel_mark_invalid dirty; fi ;;
            esac ;;
        re)
            if abx_valid_msgid "$value"; then CH_H_RE="$value"; else channel_mark_invalid re; fi ;;
        verdict)
            case "$value" in
                accepted|changes) CH_H_VERDICT="$value" ;;
                *) channel_mark_invalid verdict ;;
            esac ;;
        subject)
            if channel_valid_oneline "$value" && [ "${#value}" -le "$CH_SUBJECT_LIMIT" ]; then
                CH_H_SUBJECT="$value"
            else
                channel_mark_invalid subject
            fi ;;
    esac
}

channel_mark_invalid() {
    CH_H_INVALID="${CH_H_INVALID}${CH_H_INVALID:+,}${1:?}"
}

# The body: everything after the first blank line, control-stripped and capped.
# The cap is applied last, so a body that is cut is cut at the byte the caller
# asked for; `awk` never sees an unbounded file because channel_message_ok has
# already refused anything that could not be a message.
#
# `LC_ALL=C` on the awk as well as the tr, and it is not cosmetic: a message file
# comes off a shared mount and can hold any byte at all. In a UTF-8 locale awk
# ABORTS on a byte that is not valid UTF-8 (measured: `towc: multibyte conversion
# failure`, exit 2) and the caller gets an empty body — the same trap the tool's
# own `host_clip` records. Under C the bytes go through untouched and `tr` strips
# the controls, so a body is read whatever the other side wrote.
channel_body() {
    local f="${1:?}" bytes="${2:-$CH_BODY_LIMIT}"
    channel_message_ok "$f" || return 1
    LC_ALL=C awk 'body { print; next } /^$/ { body = 1 }' "$f" |
        LC_ALL=C tr -d "$CH_CONTROLS" | head -c "$bytes"
}

# ---------------------------------------------------------------------------
# What the box has and has not dealt with: the two sets
# ---------------------------------------------------------------------------
#
# OPEN and UNSEEN are different sets and the difference is the whole of the
# delivery guarantee:
#
#   OPEN    a request the host queued that this box has not marked done. It is
#           the operator's outstanding ask, and it stays outstanding across
#           /clear, compaction, a resumed session and a restarted box, because
#           nothing but `abx done` takes an id out of it.
#   UNSEEN  OPEN minus what this session has already been shown (channel.seen).
#           It exists to keep the high-frequency hooks quiet inside one live
#           context, and for nothing else.
#
# A hook that computed only UNSEEN would stop re-showing a request the model read
# and has not finished with — exactly the case the operator's own card tells it
# to defer — the moment the context holding it was compacted or cleared. So the
# two are named separately here, and the slice that injects them uses OPEN where
# a context is new and UNSEEN where it is not.

channel_session_dir() {
    [ -n "$CH_SESSION" ] || return 1
    abx_valid_session_name "$CH_SESSION" || return 1
    printf '%s/%s' "$ABX_SESSIONS_DIR" "$CH_SESSION"
}

channel_seen_file() {
    local dir
    dir=$(channel_session_dir) || return 1
    printf '%s/channel.seen' "$dir"
}

channel_seen_has() {
    local f
    f=$(channel_seen_file) || return 1
    [ -f "$f" ] || return 1
    grep -qxF "${1:?}" "$f" 2>/dev/null
}

# Append, never rewrite: two of these can run at once (a hook and a manual
# read), and a single short line appended with one write stays whole.
channel_seen_add() {
    local dir f
    dir=$(channel_session_dir) || return 1
    f="${dir}/channel.seen"
    channel_seen_has "${1:?}" && return 0
    abx_private_dir "$dir"
    printf '%s\n' "$1" >> "$f" || return 1
    chmod 600 "$f" 2>/dev/null || true
    return 0
}

channel_is_done() {
    local id="${1:?}"
    [ -e "${CH_TO_BOX}/${id}.done" ] || [ -L "${CH_TO_BOX}/${id}.done" ]
}

channel_open_ids() {
    local id
    while IFS= read -r id; do
        if channel_is_done "$id"; then continue; fi
        printf '%s\n' "$id"
    done < <(channel_ids "$CH_TO_BOX")
}

channel_unseen_ids() {
    local id
    while IFS= read -r id; do
        if channel_seen_has "$id"; then continue; fi
        printf '%s\n' "$id"
    done < <(channel_open_ids)
}

# What the box will say about one of the host's requests: its own word, from its
# own records. `delivered` is true when this session has seen it OR the sidecar
# on the mount says a session did — the sidecar outlives the session, which is
# what makes a request delivered once and not once per context.
channel_state_to_box() {
    local id="${1:?}"
    if channel_is_done "$id"; then
        printf 'done\n'
        return 0
    fi
    if [ -e "${CH_TO_BOX}/${id}.delivered" ] || channel_seen_has "$id"; then
        printf 'delivered\n'
        return 0
    fi
    printf 'queued\n'
}

# What the HOST has said about one of this box's messages, read from the host's
# courtesy sidecars. This is the trusted direction: the host writes them, the box
# only reads them, and a box that lied to itself here would only be lying to its
# own operator's screen.
channel_state_to_host() {
    local id="${1:?}"
    if [ -e "${CH_TO_HOST}/${id}.done" ]; then
        printf 'done\n'
    elif [ -e "${CH_TO_HOST}/${id}.read" ]; then
        printf 'read\n'
    else
        printf 'sent\n'
    fi
}

# An empty file on the mount, created only if the name is free. Never a bare
# redirect: `: > name` follows a symlink and truncates its target, and the other
# writer on this mount is on the other side of the boundary.
channel_sidecar() {
    local f="${1:?}"
    if [ -e "$f" ] || [ -L "$f" ]; then
        return 0
    fi
    ( set -C; : > "$f" ) 2>/dev/null || return 1
    chmod 600 "$f" 2>/dev/null || true
    return 0
}

# The critical section that makes "shown, then recorded" safe when a hook and a
# manual `abx read` race: both take this lock, so a message is shown once and
# recorded once. A box without flock(1) is not a box this project builds, but the
# lock is advisory anyway — losing it costs a message shown twice, never a
# message lost.
channel_lock() {
    local dir
    dir=$(channel_session_dir) || return 1
    abx_private_dir "$dir"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"${dir}/channel.lock" || return 1
    flock -w 3 9 || return 0
}

# Step 7 of the delivery contract, in the order the contract gives, and the order
# is the point: the sidecar on the mount is the slow write (virtiofs), the seen
# line is the authoritative one (guest ext4, the session's own disk). A process
# killed between them shows the message again under the same id; a process killed
# after them has recorded everything it showed.
channel_record_delivered() {
    local id="${1:?}"
    channel_sidecar "${CH_TO_BOX}/${id}.delivered" || true
    channel_seen_add "$id" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# One request, framed for a model to read
# ---------------------------------------------------------------------------
#
# The frame is host-authored text around a host-written body, and it says three
# things a model needs: which id this is (so `abx done <id>` is unambiguous),
# that the request is the operator's side speaking within the box conventions,
# and what to do when the work is finished. The delivery hook and `abx read`
# build it from this one function, so a request looks the same however it arrived.
#
# BUDGET is in bytes and bounds the body alone. A body that does not fit is cut
# with a line naming the command that prints the whole of it.
#
# A body that could not be READ is a different thing from a body that is empty,
# and the difference matters here more than anywhere else in this file: `abx read`
# records the id as delivered the moment this function returns 0, so a swallowed
# failure would frame an empty request, write `.delivered` on the mount and put
# the id in `channel.seen` — telling the host the request arrived while the model
# saw none of it. The floor's promise is late, never lost, so this fails instead.
channel_request_frame() {
    local id="${1:?}" budget="${2:-$CH_BODY_LIMIT}" f body bytes cut="" verdict="" head2=""
    f="${CH_TO_BOX}/${id}.md"
    channel_parse_headers "$f" || return 1
    body=$(channel_body "$f" "$((budget + 1))") || return 1
    bytes=$(printf '%s' "$body" | wc -c)
    bytes="${bytes//[[:space:]]/}"
    if [ "$bytes" -gt "$budget" ]; then
        body=$(printf '%s' "$body" | head -c "$budget") || true
        cut="[cut: full text with abx read ${id}]"
    fi
    case "$CH_H_VERDICT" in
        accepted) verdict="ACCEPTED" ;;
        changes)  verdict="CHANGES" ;;
    esac
    [ -n "$CH_H_RE" ] && head2="re: your message ${CH_H_RE}"
    if [ -n "$verdict" ]; then
        head2="${head2}${head2:+ · }verdict: ${verdict}"
    fi

    printf "[agent-box request %s] from the host's controlling session" "$id"
    [ -n "$CH_H_CREATED" ] && printf ', %s' "$CH_H_CREATED"
    printf '\n'
    [ -n "$head2" ] && printf '%s\n' "$head2"
    [ -n "$CH_H_SUBJECT" ] && printf 'subject: %s\n' "$CH_H_SUBJECT"
    printf -- '----\n%s\n' "$body"
    [ -n "$cut" ] && printf '%s\n' "$cut"
    printf -- '----\n'
    printf '[end of request %s] Reach a safe point first. When dealt with: abx done %s\n' "$id" "$id"
    printf 'A new handoff for the same branch: abx handoff --re %s\n' "$id"
    return 0
}

# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

# Everything this box writes to the mount goes through the guest's own scrubber
# first. It is a hard requirement, not a nicety: without it the sanctioned path
# would be the one that puts the credential on the host's disk.
channel_scrub() {
    command -v python3 >/dev/null 2>&1 \
        || die "python3 is missing in this box; a message is scrubbed before it is written, so nothing can be published without it"
    python3 "${ABX_LIB_DIR}/run-format.py" --scrub-stdin
}

# `mv -fT` (GNU) replaces the destination name itself; `mv -f` alone, onto a
# name that has become a symlink to a directory, moves the file INTO that
# directory — outside the mailbox. `-fh` is the BSD spelling of the same
# protection, tried second so this path can also be exercised on a Mac; the
# guarded plain `mv` is the last resort and refuses rather than follows.
channel_mv_onto() {
    local src="${1:?}" dst="${2:?}"
    if ! mv -fT "$src" "$dst" 2>/dev/null; then
        if ! mv -fh "$src" "$dst" 2>/dev/null; then
            [ ! -L "$dst" ] && [ ! -d "$dst" ] || return 1
            mv -f "$src" "$dst" 2>/dev/null || return 1
        fi
    fi
    [ -f "$dst" ] && [ ! -L "$dst" ]
}

channel_publish_abort() {
    local tmp="${1-}" res="${2-}"
    shift 2
    [ -z "$tmp" ] || rm -f "$tmp" 2>/dev/null || true
    # A reservation is removed only while it is still empty: once the message is
    # in it, it is somebody else's to read.
    if [ -n "$res" ] && [ -f "$res" ] && [ ! -s "$res" ]; then
        rm -f "$res" 2>/dev/null || true
    fi
    die "$*"
}

# Reserve a name, copy the staged file beside it, check that every byte arrived,
# then rename onto the reservation. Prints the id.
#
# The reservation is a zero-byte file created under noclobber: the create is the
# atomic step, so two writers in the same second cannot agree on one id. Readers
# skip zero-byte files, so a crash between the reservation and the rename leaves
# something ignorable that the writer's own sweep removes later.
#
# The byte-count check is what a full disk needs: a truncated copy must not be
# renamed into place and read as a message that ends mid-sentence.
channel_publish() {
    local dir="${1:?}" staged="${2:?}" id="" res="" tmp="" stamp nn n tries=0 sbytes tbytes
    [ "$(channel_pending_count "$dir")" -lt "$CH_PENDING_LIMIT" ] \
        || die "refusing: ${CH_PENDING_LIMIT} messages are already waiting in ${dir}. The other side reads them with 'agentbox handoff <repo>'; nothing more is published until it does"
    while [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        stamp=$(date -u +%Y%m%d-%H%M%S)
        n=0
        while [ "$n" -lt 100 ]; do
            nn=$(printf '%02d' "$n")
            n=$((n + 1))
            res="${dir}/${stamp}-${nn}.md"
            if [ -e "$res" ] || [ -L "$res" ]; then continue; fi
            ( set -C; : > "$res" ) 2>/dev/null || continue
            id="${stamp}-${nn}"
            break
        done
        [ -n "$id" ] && break
        sleep 1
    done
    [ -n "$id" ] || die "the mailbox already holds a message for every sequence number of this second; try again"
    tmp="${dir}/.tmp.${id}.$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
    ( set -C; cat "$staged" > "$tmp" ) 2>/dev/null \
        || channel_publish_abort "$tmp" "$res" "could not write into ${dir} (is the mount writable?); nothing was published"
    sbytes=$(channel_bytes "$staged") \
        || channel_publish_abort "$tmp" "$res" "the staged message could not be measured; nothing was published"
    tbytes=$(channel_bytes "$tmp") \
        || channel_publish_abort "$tmp" "$res" "the copy of the message could not be measured; nothing was published"
    if [ "$sbytes" != "$tbytes" ]; then
        channel_publish_abort "$tmp" "$res" "the copy of the message into ${dir} is ${tbytes} of ${sbytes} bytes (a full disk?); nothing was published"
    fi
    channel_mv_onto "$tmp" "$res" \
        || channel_publish_abort "$tmp" "$res" "could not publish the message as ${id}; nothing was published"
    chmod 600 "$res" 2>/dev/null || true
    printf '%s\n' "$id"
}

# What goes in the `session:` header: the standing session if this process
# belongs to it, the run if it belongs to one, otherwise `shell`.
#
# Those three are the whole vocabulary, and the reader on the other side enforces
# it, so this writer must not invent a fourth: a name that is not the standing
# session's is `shell`, not itself. Only claude-session.sh sets the variable, and
# only to the standing name, so the first branch is the standing session and
# nothing else can reach it.
channel_session_label() {
    local runid
    if [ -n "$CH_SESSION" ] && [ "$CH_SESSION" = "$ABX_STANDING_SESSION" ]; then
        printf '%s\n' "$CH_SESSION"
        return 0
    fi
    runid="${AGENT_BOX_EVENTS_DIR:-}"
    runid="${runid%/}"
    runid="${runid##*/}"
    if [ -n "${AGENT_BOX_EVENTS_DIR:-}" ] && abx_valid_runid "$runid"; then
        case "${AGENT_BOX_EVENTS_DIR}" in
            "${ABX_RUNS_DIR}"/*) printf 'run-%s\n' "$runid"; return 0 ;;
        esac
    fi
    printf 'shell\n'
}

# The body a verb was given, scrubbed, into the private workdir. TEXT or `-`;
# stdin when the verb takes it there. Prints nothing; sets CH_BODY_FILE.
#
# Every write here is status-checked, and a byte count is no substitute for it.
# The staging steps are the one place in this file where a partial write cannot be
# caught downstream: channel_publish compares the staged file with its copy, and
# a short staged file and its faithful copy are the same size, so the publish
# agrees with itself and the operator is told the message went. Two things really
# do this — the scrubber refusing a byte that is not valid UTF-8 (it decodes
# strictly, and stdio has already flushed what came before the bad byte), and a
# full disk. Either one silently cuts a `## Verify` section off a handoff, which
# is exactly the failure the host cannot see. So: refuse, and publish nothing.
channel_stage_body() {
    local source="${1:?}" text="${2-}" cap="${3:?}" raw bytes
    channel_workdir
    raw="${CH_WORKDIR}/raw"
    CH_BODY_FILE="${CH_WORKDIR}/body"
    case "$source" in
        stdin)
            [ ! -t 0 ] || die "the body goes on stdin (end it with Ctrl-D), or pass it as an argument"
            cat > "$raw" || die "refusing: the body could not be read in full (is this box's disk full?); nothing was published" ;;
        text) printf '%s\n' "$text" > "$raw" \
            || die "refusing: the body could not be written in full (is this box's disk full?); nothing was published" ;;
    esac
    bytes=$(channel_bytes "$raw") || die "the body could not be measured"
    [ "$bytes" -le "$cap" ] \
        || die "refusing: the body is ${bytes} bytes and the cap is ${cap}. Shorten it, or leave the detail in a file on the branch and say where"
    channel_scrub < "$raw" > "$CH_BODY_FILE" \
        || die "refusing: the body could not be redacted in full, so it is not safe to publish and would be cut where the redaction stopped; nothing was published. A byte that is not valid UTF-8 in the body does this — write it as text and try again"
    bytes=$(channel_bytes "$CH_BODY_FILE") || die "the body could not be measured after redaction"
    [ "$bytes" -le "$cap" ] \
        || die "refusing: the body is ${bytes} bytes after redaction and the cap is ${cap}"
    [ "$bytes" -gt 0 ] || die "refusing: the body is empty"
    return 0
}

# A subject the writer did not give: the first line of the body that says
# something, cut to the cap. Scrubbed already, since it comes from the scrubbed
# file.
#
# Headings are skipped rather than used, because the handoff format starts every
# body with `## Changed` and a mailbox in which every subject reads "Changed"
# tells the operator nothing. The first heading is kept as the fallback for a
# body that is nothing but headings.
channel_default_subject() {
    local f="${1:?}" line text heading=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *[[:cntrl:]]*) continue ;; esac
        text="$line"
        case "$text" in
            '') continue ;;
            '#'*)
                while [ "${text:0:1}" = '#' ]; do text="${text:1}"; done
                text="${text# }"
                [ -n "$heading" ] || heading="$text"
                continue ;;
        esac
        printf '%s\n' "${text:0:$CH_SUBJECT_LIMIT}"
        return 0
    done < "$f"
    [ -n "$heading" ] && printf '%s\n' "${heading:0:$CH_SUBJECT_LIMIT}"
    return 0
}

# Assemble the file and publish it. The header order is the format's; every value
# has already been validated by its caller, which is why nothing here re-checks.
#
# The assembly's own status is checked for the reason channel_stage_body gives: the
# body is the last thing written and the biggest, so a disk that fills cuts the
# message here, where channel_publish's byte check cannot see it. `cat` is the
# group's last command, so the group's status is the body write's status.
channel_write_message() {
    local dir="${1:?}" type="${2:?}" subject="${3-}" re="${4-}" branch="${5-}" commit="${6-}" dirty="${7-}"
    local staged
    channel_workdir
    staged="${CH_WORKDIR}/message"
    if ! {
        printf 'created: %s\n' "$(abx_now_iso)"
        printf 'type: %s\n' "$type"
        printf 'session: %s\n' "$(channel_session_label)"
        [ -n "$branch" ] && printf 'branch: %s\n' "$branch"
        [ -n "$commit" ] && printf 'commit: %s\n' "$commit"
        [ -n "$dirty" ] && printf 'dirty: %s\n' "$dirty"
        [ -n "$re" ] && printf 're: %s\n' "$re"
        [ -n "$subject" ] && printf 'subject: %s\n' "$subject"
        printf '\n'
        cat "$CH_BODY_FILE"
    } > "$staged"; then
        die "refusing: the message could not be assembled in full (is this box's disk full?); nothing was published"
    fi
    channel_publish "$dir" "$staged"
}

# ---------------------------------------------------------------------------
# handoff
# ---------------------------------------------------------------------------
#
# The one verb with preconditions, because a handoff is a claim about a commit
# and the host is going to verify the branch rather than this tree. Each refusal
# names the mistake and what to do about it: an agent that cannot tell why its
# handoff was refused writes the same one again.

cmd_handoff() {
    local branch="" re="" subject="" allow_dirty=no commit="" dirty="" id="" short=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --branch)      branch="${2:?--branch needs a value}"; shift 2 ;;
            --re)          re="${2:?--re needs a value}"; shift 2 ;;
            --subject)     subject="${2:?--subject needs a value}"; shift 2 ;;
            --allow-dirty) allow_dirty=yes; shift ;;
            --)            shift; break ;;
            -*)            die "unknown option: $1" ;;
            *)             die "handoff takes no arguments; the body goes on stdin" ;;
        esac
    done
    [ $# -eq 0 ] || die "handoff takes no arguments; the body goes on stdin"

    command -v git >/dev/null 2>&1 || die "git is missing in this box"
    git -C "$ABX_WORK_DIR" rev-parse --git-dir >/dev/null 2>&1 \
        || die "refusing: ${ABX_WORK_DIR} is not a git repository, so there is no branch to hand over. Use 'abx note' for anything else"

    if [ -z "$branch" ]; then
        branch=$(git -C "$ABX_WORK_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null) \
            || die "refusing: HEAD is detached, so there is no current branch. Pass --branch B"
    fi
    abx_valid_branch "$branch" || die "refusing: that is not a usable branch name"
    commit=$(git -C "$ABX_WORK_DIR" rev-parse -q --verify "refs/heads/${branch}^{commit}" 2>/dev/null) \
        || die "refusing: there is no branch ${branch} in ${ABX_WORK_DIR}. Commit on it first, or pass --branch with the branch you mean"
    channel_valid_commit "$commit" || die "git did not name a commit for ${branch}"

    dirty=$(git -C "$ABX_WORK_DIR" status --porcelain 2>/dev/null | grep -c '' || true)
    case "$dirty" in ''|*[!0-9]*) dirty=0 ;; esac
    if [ "$dirty" -gt 0 ] && [ "$allow_dirty" = no ]; then
        die "refusing: ${dirty} uncommitted files in ${ABX_WORK_DIR}. A handoff describes a commit; the host verifies the branch, not this tree. Commit, or pass --allow-dirty and say why under \"## Unproven\""
    fi

    [ -n "$re" ] && { abx_valid_msgid "$re" || die "not a message id: ${re}"; }

    channel_stage_body stdin "" "$CH_BODY_LIMIT"
    grep -q '^## Changed' "$CH_BODY_FILE" \
        || die "refusing: the body has no \"## Changed\" section. Say what changed, so the host knows what it is verifying"
    grep -q '^## Verify' "$CH_BODY_FILE" \
        || die "refusing: the body has no \"## Verify\" section. Give the exact commands, as they are to be run"
    grep -q '^## Unproven' "$CH_BODY_FILE" \
        || die "refusing: the body has no \"## Unproven\" section. Say what was not proven; \"nothing\" is an answer"

    [ -n "$subject" ] || subject=$(channel_default_subject "$CH_BODY_FILE")
    subject="${subject:0:$CH_SUBJECT_LIMIT}"
    channel_valid_oneline "$subject" || subject="handoff on ${branch}"

    channel_require_dirs
    # `|| exit` because channel_publish's refusals happen inside a command
    # substitution, where `die` ends the subshell and nothing else: without this
    # a failed publish would be followed by a success line naming no id.
    id=$(channel_write_message "$CH_TO_HOST" handoff "$subject" "$re" "$branch" "$commit" "$dirty") || exit 1
    [ -n "$id" ] || die "the handoff was not published"
    short="${commit:0:7}"
    say "handoff ${id} written for the host (${branch} at ${short}). Do not push; the host prepares the PR"
}

# ---------------------------------------------------------------------------
# ask, note
# ---------------------------------------------------------------------------

cmd_ask()  { channel_say_something ask question "$CH_ASK_LIMIT" "$@"; }
cmd_note() { channel_say_something note note "$CH_BODY_LIMIT" "$@"; }

channel_say_something() {
    local verb="${1:?}" type="${2:?}" cap="${3:?}" re="" id="" subject=""
    shift 3
    while [ $# -gt 0 ]; do
        case "$1" in
            --re) re="${2:?--re needs a value}"; shift 2 ;;
            --)   shift; break ;;
            -)    break ;;
            -*)   die "unknown option: $1" ;;
            *)    break ;;
        esac
    done
    [ $# -gt 0 ] || die "usage: abx ${verb} [--re ID] TEXT|-   ('-' reads the text from stdin)"
    [ -n "$re" ] && { abx_valid_msgid "$re" || die "not a message id: ${re}"; }
    if [ "$1" = "-" ]; then
        channel_stage_body stdin "" "$cap"
    else
        channel_stage_body text "$*" "$cap"
    fi
    subject=$(channel_default_subject "$CH_BODY_FILE")
    channel_require_dirs
    id=$(channel_write_message "$CH_TO_HOST" "$type" "$subject" "$re") || exit 1
    [ -n "$id" ] || die "the message was not published"
    case "$type" in
        question) say "question ${id} written for the host. It arrives when a session on the host runs 'agentbox channel' or its hook fires; nothing in this box waits for the answer" ;;
        *)        say "note ${id} written for the host" ;;
    esac
}

# ---------------------------------------------------------------------------
# inbox, read, done
# ---------------------------------------------------------------------------

cmd_inbox() {
    local all=no id state rows=0
    case "${1:-}" in
        --all) all=yes; shift ;;
        "")    ;;
        *)     die "usage: abx inbox [--all]" ;;
    esac
    [ $# -eq 0 ] || die "usage: abx inbox [--all]"
    if ! channel_dirs_present; then
        say "no channel directory on the mount yet, so nothing from the host"
        return 0
    fi
    while IFS= read -r id; do
        state=$(channel_state_to_box "$id")
        [ "$all" = yes ] || [ "$state" != "done" ] || continue
        if [ "$rows" -eq 0 ]; then
            printf '%-20s  %-9s  %-20s  %-8s  %s\n' ID STATE RE VERDICT SUBJECT
        fi
        rows=$((rows + 1))
        if channel_parse_headers "${CH_TO_BOX}/${id}.md"; then
            printf '%-20s  %-9s  %-20s  %-8s  %s\n' \
                "$id" "$state" "${CH_H_RE:--}" "${CH_H_VERDICT:--}" "${CH_H_SUBJECT:--}"
        else
            # Listed, never dropped, and nothing of it shown: a file in to-box/
            # that is not a message is still something the operator should see.
            printf '%-20s  %-9s  %-20s  %-8s  %s\n' "$id" "$state" - - "(not a readable message)"
        fi
    done < <(channel_ids "$CH_TO_BOX")
    if [ "$rows" -eq 0 ]; then
        say "no open requests from the host"
        return 0
    fi
    say "read one in full: abx read <id>"
}

cmd_read() {
    local id="${1:-}" frame=""
    abx_valid_msgid "$id" || die "usage: abx read <id>   (an id from 'abx inbox')"
    [ $# -eq 1 ] || die "usage: abx read <id>"
    channel_dirs_present || die "there is no channel directory on the mount, so there is nothing to read"
    channel_message_ok "${CH_TO_BOX}/${id}.md" \
        || die "no readable request ${id} in this box's inbox (see 'abx inbox')"
    # Show, then record, and both inside the lock: a delivery hook running at the
    # same moment then shows this message once between the two of them.
    if [ -n "$CH_SESSION" ]; then
        channel_lock || true
    fi
    frame=$(channel_request_frame "$id") || die "request ${id} is not a readable message"
    printf '%s\n' "$frame"
    if [ -n "$CH_SESSION" ]; then
        channel_record_delivered "$id" || say "note: this request could not be recorded as delivered; it will be shown again"
    else
        # Recording it here would tell the host, and the standing session's own
        # seen set, that the session has read something it never saw.
        printf 'abx: note: this is not the standing session, so nothing was recorded as delivered\n' >&2
    fi
}

cmd_done() {
    local id="${1:-}" note="" nid=""
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --note) note="${2:?--note needs a value}"; shift 2 ;;
            --)     shift; break ;;
            *)      die "usage: abx done <id> [--note TEXT]" ;;
        esac
    done
    abx_valid_msgid "$id" || die "usage: abx done <id> [--note TEXT]   (an id from 'abx inbox')"
    channel_dirs_present || die "there is no channel directory on the mount, so there is nothing to mark"
    [ -e "${CH_TO_BOX}/${id}.md" ] || die "no request ${id} in this box's inbox (see 'abx inbox')"
    channel_require_dirs
    channel_sidecar "${CH_TO_BOX}/${id}.done" \
        || die "could not mark ${id} done (is the mount writable?)"
    if [ -n "$note" ]; then
        channel_stage_body text "$note" "$CH_BODY_LIMIT"
        nid=$(channel_write_message "$CH_TO_HOST" note "$(channel_default_subject "$CH_BODY_FILE")" "$id") || exit 1
        say "request ${id} marked done; note ${nid} written for the host"
        return 0
    fi
    say "request ${id} marked done"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

cmd_status() {
    local shown=0 id state detail
    case "${1:-}" in
        --clear) channel_set_task "" ;;
        "")      ;;
        -*)      die "usage: abx status [TEXT | --clear]" ;;
        *)       channel_set_task "$*" ;;
    esac

    channel_print_host_status
    channel_print_self

    if ! channel_dirs_present; then
        say "no channel directory on the mount yet: nothing has been sent either way"
        return 0
    fi

    say "to the host:"
    while IFS= read -r id; do
        [ "$shown" -lt "$CH_STATUS_LIMIT" ] || break
        shown=$((shown + 1))
        state=$(channel_state_to_host "$id")
        if channel_parse_headers "${CH_TO_HOST}/${id}.md"; then
            detail=$(channel_to_host_detail)
        else
            detail="(not a readable message)"
        fi
        printf '  %s  %-6s %s\n' "$id" "$state" "$detail"
    done < <(channel_ids_desc "$CH_TO_HOST")
    [ "$shown" -gt 0 ] || printf '  nothing yet\n'

    shown=0
    say "from the host:"
    while IFS= read -r id; do
        shown=$((shown + 1))
        state=$(channel_state_to_box "$id")
        if channel_parse_headers "${CH_TO_BOX}/${id}.md"; then
            printf '  %s  %-9s %-8s %s\n' "$id" "$state" "${CH_H_VERDICT:--}" "${CH_H_SUBJECT:--}"
        else
            printf '  %s  %-9s %-8s %s\n' "$id" "$state" - "(not a readable message)"
        fi
    done < <(channel_open_ids)
    if [ "$shown" -gt 0 ]; then
        printf '  read one: abx read <id>   ·   dealt with: abx done <id>\n'
    else
        printf '  nothing open\n'
    fi
}

# One of this box's own messages, as the line `abx status` shows: who wrote it,
# what it is, which commit it is a claim about, and — when one of its headers did
# not pass its shape — that the message carries a claim nothing can use. The
# invalid list is shown rather than swallowed: a handoff whose branch line is
# malformed is a handoff the host will refuse to check, and the agent that wrote
# it is the one that can fix it.
channel_to_host_detail() {
    local detail="${CH_H_TYPE:--}"
    [ -n "$CH_H_SESSION" ] && detail="${detail} ${CH_H_SESSION}"
    if [ -n "$CH_H_BRANCH" ]; then
        detail="${detail} ${CH_H_BRANCH}"
        [ -n "$CH_H_COMMIT" ] && detail="${detail}@${CH_H_COMMIT:0:7}"
    fi
    if [ -n "$CH_H_DIRTY" ] && [ "$CH_H_DIRTY" != 0 ]; then
        detail="${detail} dirty:${CH_H_DIRTY}"
    fi
    [ -n "$CH_H_RE" ] && detail="${detail} re:${CH_H_RE}"
    detail="${detail}  ${CH_H_SUBJECT:--}"
    [ -n "$CH_H_INVALID" ] && detail="${detail}  [invalid: ${CH_H_INVALID}]"
    printf '%s\n' "$detail"
}

channel_set_task() {
    local text="${1-}" dir f
    dir=$(channel_session_dir) \
        || die "refusing: this is not the standing in-box session, so it has no task to declare. The host starts one with 'agentbox session <repo>'"
    abx_private_dir "$dir"
    f="${dir}/task"
    if [ -z "$text" ]; then
        rm -f "$f" 2>/dev/null || true
        say "task cleared"
        return 0
    fi
    case "$text" in *[[:cntrl:]]*) die "refusing: a task is one line of plain text" ;; esac
    text="${text:0:$CH_TASK_LIMIT}"
    printf '%s\n' "$text" > "$f" || die "could not write ${f}"
    chmod 600 "$f" 2>/dev/null || true
    say "task recorded: ${text}"
}

# The host's own line about itself, from the file only the host writes. Trusted
# direction, so it is read — but capped and control-stripped like everything
# else, because a file on this mount is still a file anybody in this box can
# rewrite, and then it would be this box lying to its own screen.
channel_print_host_status() {
    local line out seen="" task="" last=""
    if [ ! -f "$CH_HOST_STATUS" ] || [ -L "$CH_HOST_STATUS" ]; then
        say "host side: nothing recorded yet (the host writes it when it looks at this box)"
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            'seen: '*) [ -n "$seen" ] || seen="${line#seen: }" ;;
            'task: '*) [ -n "$task" ] || task="${line#task: }" ;;
            'last: '*) [ -n "$last" ] || last="${line#last: }" ;;
        esac
    done < <(head -c "$CH_HEADER_BYTES" "$CH_HOST_STATUS" 2>/dev/null |
        LC_ALL=C tr -d "$CH_CONTROLS")
    channel_valid_iso "$seen" || seen=""
    out="host side: seen ${seen:-never}"
    [ -n "$task" ] && out="${out}  task: ${task:0:$CH_TASK_LIMIT}"
    [ -n "$last" ] && out="${out}  last: ${last:0:$CH_SUBJECT_LIMIT}"
    say "$out"
}

channel_print_self() {
    local state task="" dir
    state=$(standing_state)
    dir=$(channel_session_dir) || dir=""
    if [ -n "$dir" ] && [ -f "${dir}/task" ]; then
        task=$(head -c "$CH_TASK_LIMIT" "${dir}/task" 2>/dev/null | head -1) || task=""
    fi
    if [ -n "$CH_SESSION" ]; then
        say "this session: ${CH_SESSION} (${state})${task:+  task: ${task}}"
    else
        say "this session: untracked (the standing session is ${state}); it receives no requests"
    fi
}

# ---------------------------------------------------------------------------
# standing-state
# ---------------------------------------------------------------------------
#
# One word for the host, which uses it to end `agentbox request` with what will
# actually happen to the request. The vocabulary is fixed and the host validates
# it: none, gone, waiting, idle, working.
#
# Liveness is the pid file plus the cmdline of that pid (lib.sh), never the
# `status` file and never tmux: after a hard VM stop the pid file survives and
# that number belongs to somebody else.
#
# Known limit: the sensor writes a Stop line when a turn ends even if a hook then
# keeps the session going, so this can read `idle` for a moment while the session
# is in fact working. It corrects itself at the next event, and nothing decides
# anything irreversible on the word.
standing_state() {
    local dir last
    dir="${ABX_SESSIONS_DIR}/${ABX_STANDING_SESSION}"
    if [ ! -d "$dir" ]; then
        printf 'none\n'
        return 0
    fi
    if ! abx_session_alive "$ABX_STANDING_SESSION"; then
        printf 'gone\n'
        return 0
    fi
    last=$(channel_last_hook_event "$dir")
    case "$last" in
        Notification) printf 'waiting\n' ;;
        Stop|'')      printf 'idle\n' ;;
        *)            printf 'working\n' ;;
    esac
}

# The last event name in the session's own sensor log, or nothing. sed rather
# than jq: this is called from the host's `request` and from `status`, and a
# missing jq must not make either of them silent.
channel_last_hook_event() {
    local f="${1:?}/hooks.jsonl" line ev=""
    [ -f "$f" ] && [ ! -L "$f" ] || return 0
    line=$(tail -n 1 "$f" 2>/dev/null) || true
    ev=$(printf '%s' "$line" | sed -n 's/.*"event":"\([A-Za-z]\{1,40\}\)".*/\1/p' | head -n 1) || true
    printf '%s\n' "$ev"
}

# ---------------------------------------------------------------------------
# hook EVENT — delivery into the standing session (the next slice)
# ---------------------------------------------------------------------------
#
# The hook is what makes a request arrive by itself: `additionalContext` on
# SessionStart, UserPromptSubmit and PostToolUse, and a blocking `decision` on
# Stop. It belongs to the slice that also wires guest/hooks.settings.json, and it
# is built on the two sets above: OPEN where the context is new (SessionStart
# fires on startup, resume, clear, compact and fork, and each of those is a
# context that has been told nothing), UNSEEN on the high-frequency events.
#
# Whatever it does, it exits 0. Claude Code reads exit status 2 from a
# UserPromptSubmit hook as "block this prompt and erase it", and a delivery
# mechanism that can lock an operator out of their own session is worse than no
# delivery mechanism. The stub therefore also exits 0, and says what it is on
# stderr rather than on stdout, where the only valid answers are nothing at all
# and one JSON object.
cmd_hook() {
    printf 'abx: the delivery hook is not built in this checkout\n' >&2
    return 0
}

# ---------------------------------------------------------------------------

case "${1:-}" in
    handoff)        shift; cmd_handoff "$@" ;;
    ask)            shift; cmd_ask "$@" ;;
    note)           shift; cmd_note "$@" ;;
    inbox)          shift; cmd_inbox "$@" ;;
    read)           shift; cmd_read "$@" ;;
    done)           shift; cmd_done "$@" ;;
    status)         shift; cmd_status "$@" ;;
    standing-state) shift; standing_state ;;
    hook)           shift; cmd_hook "$@" ;;
    *) die "usage: abx handoff|ask|note|inbox|read|done|status   (see 'abx status' for both sides now)" ;;
esac
