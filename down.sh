#!/bin/bash
# Tear down the split tunnel: stop the WireGuard interface VPNonly created and
# remove its firewall rules. Nothing else on the machine is touched.
#
# One thing is deliberately left behind. An app launched through vpnrun keeps
# the vpnonly group until it exits, and macOS cannot take it out of the group
# while it runs. If any such app is still open, only the `pass` rule goes and
# the `block return` rule stays loaded, so the app is refused rather than
# quietly moved onto your normal connection. That is the kill switch, and it
# has to hold across a deliberate disconnect as much as a dropped one. Quit
# the app (Turn off in `vpnonly` quits and reopens it outside the group) and
# the next down.sh or up.sh clears the rest; `vpnonly` does that by itself
# once the last held app is gone.
set -uo pipefail

ANCHOR="com.apple/vpnonly-cli"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RUSER="${SUDO_USER:-$USER}"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"

IF="${IF:-}"
[ -n "$IF" ] && : || IF=$(cat "$CONF/tunnel-if" 2>/dev/null || true)

# Whatever still runs with the group, one line per app bundle (or per binary,
# for something launched by path). ps pads the gid, hence the sub().
VPNGID=$(dscl . -read /Groups/vpnonly PrimaryGroupID 2>/dev/null | awk '{print $2}')
HELD=""
if [ -n "$VPNGID" ]; then
    HELD=$(ps -axo rgid=,comm= 2>/dev/null | awk -v g="$VPNGID" '$1 == g {
        sub(/^[ \t]*[0-9]+[ \t]+/, "")
        if (match($0, /[^\/]*\.app\//)) print substr($0, RSTART, RLENGTH - 5)
        else print $0
    }' | sort -u)
fi

# Everything here touches only our own anchor, so nobody else's rules are
# affected. Loading a ruleset into it replaces translation and filter rules
# together in one transaction; `-F rules` alone would leave a NAT rule behind,
# and `-F all` reaches the global state table.
if [ -n "$HELD" ]; then
    # Swap to the block rule alone. One load, so there is no instant in which
    # the group has no rule, and nothing new enters the tunnel while it comes
    # down. The rule is the same one up.sh loads.
    PFRULES=$(mktemp)
    printf 'block return out quick on ! lo0 from any to any group vpnonly\n' > "$PFRULES"
    if pfctl -q -a "$ANCHOR" -f "$PFRULES" 2>/dev/null; then
        echo "PF: route removed, kill switch kept for apps still in the group"
    else
        # Leave whatever is loaded. Once the interface is gone the route-to
        # rule drops rather than passes, so this still fails closed.
        echo "PF: could not reload the kill switch on its own; leaving the rules as they are" >&2
    fi
    rm -f "$PFRULES"
    # A block rule is only enforced while PF is enabled, and the enable
    # reference is ours to hold. Take one if we have none (an older down.sh
    # released it) or if PF has been switched off under us; releasing any old
    # reference only after the new one is held keeps the count off zero.
    if [ ! -s "$CONF/pf-token" ] || ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
        NEW_TOKEN=$(pfctl -E 2>&1 | awk '/Token/{print $NF}')
        if [ -n "$NEW_TOKEN" ]; then
            [ -s "$CONF/pf-token" ] && pfctl -X "$(cat "$CONF/pf-token")" 2>/dev/null
            printf '%s\n' "$NEW_TOKEN" > "$CONF/pf-token"
            chown "$RUSER" "$CONF/pf-token" 2>/dev/null || true
            echo "PF: enabled, reference held for the kill switch"
        fi
    fi
elif pfctl -q -a "$ANCHOR" -f /dev/null 2>/dev/null; then
    echo "PF: VPNonly's rules removed"
else
    echo "PF: no VPNonly rules were loaded"
fi

if [ -n "$IF" ]; then
    # Connections through the tunnel were established with `keep state`, so
    # they would otherwise linger for a minute after the pass rule goes. Drop
    # them, and an app's next packet meets the rules loaded now: refused if it
    # is still in the group, its normal route once it has been reopened
    # outside it.
    pfctl -i "$IF" -F states 2>/dev/null || true
fi

# The enable reference is what keeps PF evaluating our anchor. Release it only
# once no rule of ours needs enforcing any more.
if [ -s "$CONF/pf-token" ] && [ -z "$HELD" ]; then
    pfctl -X "$(cat "$CONF/pf-token")" 2>/dev/null && echo "PF: enable reference released"
    rm -f "$CONF/pf-token"
fi

# Stop only the process we started. Matching on a name pattern would kill any
# wireguard-go on this Mac, including another VPN's, and the kernel picks our
# interface name at runtime so the command line does not even contain it.
PID=$(cat "$CONF/tunnel-pid" 2>/dev/null || true)
case "$PID" in ''|*[!0-9]*) PID="" ;; esac
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    CMD=$(ps -p "$PID" -o command= 2>/dev/null || true)
    case "$CMD" in
        *wireguard-go*)
            kill -TERM "$PID" 2>/dev/null
            for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
            kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null
            echo "WireGuard: ${IF:-tunnel} stopped"
            ;;
        *)  echo "WireGuard: recorded process is not ours, left alone" ;;
    esac
else
    echo "WireGuard: nothing running to stop"
fi
[ -n "$IF" ] && rm -f "/var/run/wireguard/$IF.sock" 2>/dev/null

rm -f "$CONF/tunnel-if" "$CONF/tunnel-ip" "$CONF/tunnel-pid" "$CONF/tunnel-host" "$CONF/tunnel-endpoint" 2>/dev/null

if [ -n "$HELD" ]; then
    echo
    echo "Still open, held offline by the kill switch:"
    printf '%s\n' "$HELD" | sed 's/^/  /'
    echo "macOS fixes an app's group when it starts, so these cannot be moved back"
    echo "onto your normal connection while they run. Quit them, or use Turn off in"
    echo "vpnonly, which quits and reopens them. The block clears once they are gone."
fi
echo "Done."
