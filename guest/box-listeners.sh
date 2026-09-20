#!/bin/bash
#
# agent-box — which of this box's forwarded ports actually have a listener.
#
# Runs in the guest, as the unprivileged guest user, called once per `agentbox
# ports` with every forwarded port in one argument. It answers the guest half of
# the question "why is this forward quiet": nothing listening in the box, or
# something listening somewhere a forward cannot reach.
#
# The contract is three fields per line and nothing else:
#
#   <port> yes <loopback|any|other>     something is listening
#   <port> no  -                        nothing is
#
# A forward targets the guest's 127.0.0.1:PORT, so `loopback` and `any` answer
# through it and `other` — a socket bound to one specific non-loopback address —
# does not. The host computes `reaches` from that; this script never decides it,
# because the other half of the answer is the host port and the box has no
# business knowing anything about the host.
#
# One line per port ASKED, in the order asked, even when nothing is listening: a
# missing row would read on the host as "the box did not answer", which is a
# different fact. Everything goes out through run-format.py's scrubber, like every
# other thing this box says to the host — these lines are digits and fixed words
# by construction, and the rule is the rule: the redaction happens in the guest.

set -uo pipefail

die() { printf 'box-listeners: %s\n' "$*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: box-listeners.sh PORT[,PORT...]"
PORTS="$1"
# The host wrote this list from its own record, and it is still checked here: a
# list that is not digits and commas is a bug on the way in, not something to
# guess about.
case "$PORTS" in
    ''|*[!0-9,]*) die "usage: box-listeners.sh PORT[,PORT...]" ;;
esac

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=guest/lib.sh
. "${ABX_LIB_DIR}/lib.sh"

# Every TCP listener in this box, once, from /proc — no `ss`, no package to
# install (see guest/lib.sh). UDP is not a forward: Lima's portForwards are TCP.
LISTENERS=$(abx_listeners | awk '$1 == "tcp" { print $2, $3 }')

# The widest binding a port has, because that is the one that decides whether the
# forward answers: a process listening on both 127.0.0.1 and one other address is
# reachable, and reporting `other` for it would send somebody debugging a box that
# works. `any` (0.0.0.0 or ::) beats `loopback`, which beats `other`.
widest_scope() {
    local want="${1:?}" p s best=""
    # An explicit IFS, because the caller's loop splits a comma list: a function
    # that reads fields must not depend on what the caller left in IFS.
    while IFS=' ' read -r p s; do
        [ "$p" = "$want" ] || continue
        case "$s" in
            any)      printf 'any'; return 0 ;;
            loopback) best=loopback ;;
            other)    [ -n "$best" ] || best=other ;;
        esac
    done <<EOF
$LISTENERS
EOF
    [ -z "$best" ] || printf '%s' "$best"
}

# Split on commas without leaving IFS changed for everything below it, which is
# how the scope reader came to see one field per LINE instead of two.
PORT_LIST=()
IFS=',' read -r -a PORT_LIST <<< "$PORTS"

{
    for port in ${PORT_LIST[@]+"${PORT_LIST[@]}"}; do
        # A trailing or doubled comma produces an empty field; skip it rather
        # than printing a row for a port nobody asked about.
        [ -n "$port" ] || continue
        scope=$(widest_scope "$port")
        if [ -n "$scope" ]; then
            printf '%s yes %s\n' "$port" "$scope"
        else
            printf '%s no -\n' "$port"
        fi
    done
} | python3 "${ABX_LIB_DIR}/run-format.py" --scrub-stdin
