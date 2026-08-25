#!/bin/bash
# Tear down the split tunnel: remove VPNonly's firewall rules and stop the
# WireGuard interface it created. Nothing else on the machine is touched.
set -uo pipefail

ANCHOR="com.apple/vpnonly-cli"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RUSER="${SUDO_USER:-$USER}"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"

IF="${IF:-}"
[ -n "$IF" ] && : || IF=$(cat "$CONF/tunnel-if" 2>/dev/null || true)

# Clearing our own anchor cannot affect anyone else's rules. Loading an empty
# ruleset removes translation and filter rules together; `-F rules` alone would
# leave the NAT rule behind, and `-F all` reaches the global state table.
if pfctl -q -a "$ANCHOR" -f /dev/null 2>/dev/null; then
    echo "PF: VPNonly's rules removed"
else
    echo "PF: no VPNonly rules were loaded"
fi

if [ -n "$IF" ]; then
    # Connections through the tunnel were established with `keep state`, so they
    # would otherwise linger for a minute after the rules go. Drop them and apps
    # reconnect over the normal route straight away.
    pfctl -i "$IF" -F states 2>/dev/null || true
fi

if [ -s "$CONF/pf-token" ]; then
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

rm -f "$CONF/tunnel-if" "$CONF/tunnel-ip" "$CONF/tunnel-pid" 2>/dev/null
echo "Done."
