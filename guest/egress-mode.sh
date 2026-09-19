#!/bin/bash
#
# agent-box — what egress mode this box is ACTUALLY in.
#
# Read the ruleset, not the file. The file is what somebody asked for; the
# ruleset is what the kernel is doing, and every reporter that told an operator
# "deny" because a file said so was one rebuild failure away from saying it
# about a box that permits everything.
#
# Prints one line, already scrubbed:
#
#   live=<deny|observe|open|unknown>  what the ruleset is doing
#   file=<deny|observe|open|none>     what /etc/agent-box/egress-mode claims
#   agree=<yes|no>                    no means the two conflict, or live is unknown
#   detail=<text>                     why, when there is anything to say
#
# `detail` and `agree` are separate on purpose. A box with no mode file and an
# unambiguous ruleset has something worth saying and nothing wrong with it: it
# should report the mode it is plainly in, with the missing file as information.
# Only a real conflict, or a ruleset that matches none of the three shapes, is a
# disagreement.
#
# It scrubs its own output rather than being piped through the scrubber by the
# caller. The host's guest_shell redirects stdin from /dev/null — deliberately,
# so that ssh cannot eat a caller's input — which silently empties any pipe
# built out of two of them. One script, one call, no pipe to lose.

set -uo pipefail

ABX_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE_FILE="${AGENT_BOX_EGRESS_MODE_FILE:-/etc/agent-box/egress-mode}"
CHAIN_OUT="AGENTBOX-OUT"
IPSET_NAME="allowed-domains"
IPSET_RESOLVED="allowed-resolved"
IPT_WAIT=5

file_mode="none"
if [ -r "$MODE_FILE" ]; then
    case "$(tr -d '[:space:]' < "$MODE_FILE" 2>/dev/null)" in
        deny) file_mode=deny ;; observe) file_mode=observe ;; open) file_mode=open ;;
        *) file_mode=none ;;
    esac
fi

live="unknown"
detail=""
agree="yes"

# `sudo -n`: this runs from box-status.sh as the unprivileged guest user.
rules=$(sudo -n iptables -w "$IPT_WAIT" -S "$CHAIN_OUT" 2>/dev/null | sed -n '2,$p') || rules=""
policy=$(sudo -n iptables -w "$IPT_WAIT" -S 2>/dev/null | grep -- '-P OUTPUT') || policy=""

# Every ACCEPT this chain is supposed to contain. Anything else that accepts,
# anywhere before the terminal rule, means the chain is not one of the three
# shapes — judging the LAST rule alone would report `deny` for a chain with an
# ACCEPT inserted in front of the REJECT, which is the one edit that would
# matter most and the one it would miss.
expected_accept() {
    case "$1" in
        *"-o lo -j ACCEPT")                                      return 0 ;;
        *"ctstate RELATED,ESTABLISHED -j ACCEPT")                return 0 ;;
        *"-o docker0 -j ACCEPT")                                 return 0 ;;
        *"-o br+ -j ACCEPT")                                     return 0 ;;
        *"--dport 53 -j ACCEPT")                                 return 0 ;;
        *"--dport 67:68 -j ACCEPT")                              return 0 ;;
        *"--match-set ${IPSET_NAME} dst -j ACCEPT")              return 0 ;;
        *"--match-set ${IPSET_RESOLVED} dst -j ACCEPT")          return 0 ;;
        *"--hashlimit-name abx_egress"*"-j ACCEPT")              return 0 ;;
    esac
    return 1
}

if [ -z "$rules" ] || [ -z "$policy" ]; then
    live="unknown"; agree="no"; detail="the ruleset could not be read"
else
    tail_rule=$(printf '%s\n' "$rules" | tail -1)
    body=$(printf '%s\n' "$rules" | sed '$d')
    unexpected=""
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        case "$r" in *"-j ACCEPT") ;; *) continue ;; esac
        # Accumulated, not assigned: with two unexpected accepts in the chain,
        # naming only the last one sends the operator to fix half of it.
        expected_accept "$r" || unexpected="${unexpected}${unexpected:+, }${r}"
    done < <(printf '%s\n' "$body")

    if [ -n "$unexpected" ]; then
        live="unknown"; agree="no"
        detail="${CHAIN_OUT} has an accept this box did not put there: ${unexpected}"
    else
        case "$policy" in
            *ACCEPT*)
                # Open requires BOTH: the policy open AND our chain present and
                # ending in an accept. A box whose firewall unit never ran also
                # has an ACCEPT policy, and calling that "open" would report an
                # unconfigured box as a deliberately configured one.
                if [ "$tail_rule" = "-A ${CHAIN_OUT} -j ACCEPT" ]; then
                    live=open
                else
                    live=unknown; agree="no"
                    detail="the OUTPUT policy is ACCEPT but ${CHAIN_OUT} does not end in ACCEPT; the firewall may never have run"
                fi
                ;;
            *DROP*)
                if printf '%s\n' "$rules" | grep -q -- '-j LOG --log-prefix' \
                    && [ "$tail_rule" = "-A ${CHAIN_OUT} -j ACCEPT" ]; then
                    live=observe
                elif printf '%s\n' "$tail_rule" | grep -q -- '-j REJECT'; then
                    live=deny
                else
                    live=unknown; agree="no"
                    detail="${CHAIN_OUT} matches none of the three known shapes"
                fi
                ;;
            *)
                live=unknown; agree="no"
                detail="the OUTPUT policy is neither ACCEPT nor DROP"
                ;;
        esac
    fi
fi

# A conflict is a disagreement. A missing file is not: the ruleset is
# unambiguous and saying `unknown` about it would be less true, not more
# careful.
if [ "$agree" = "yes" ]; then
    if [ "$file_mode" != "none" ] && [ "$live" != "$file_mode" ]; then
        agree="no"
        detail="the mode file says '${file_mode}' but the live ruleset is '${live}'"
    elif [ "$file_mode" = "none" ]; then
        detail="no mode file on this box; reporting what the ruleset does"
    fi
fi

printf 'live=%s file=%s agree=%s detail=%s\n' "$live" "$file_mode" "$agree" "$detail" \
    | python3 "${ABX_LIB_DIR}/run-format.py" --scrub-stdin
