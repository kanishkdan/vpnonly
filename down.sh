#!/bin/bash
# Tear down the split tunnel: restore stock PF rules, remove the WireGuard
# interface. Leaves the system exactly as it was.
set -uo pipefail

IF="${IF:-utun9}"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RUSER="${SUDO_USER:-$USER}"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"

# Connections opened through the tunnel were established with `keep state`, so
# they'd otherwise linger for a minute after the rules go away. Drop them and
# apps reconnect over the normal route straight away.
pfctl -i "$IF" -F states 2>/dev/null || true
pfctl -q -f /etc/pf.conf && echo "PF: stock ruleset restored"
if [ -s "$CONF/pf-token" ]; then
    pfctl -X "$(cat "$CONF/pf-token")" 2>/dev/null && echo "PF: enable reference released"
    rm -f "$CONF/pf-token"
fi

if pkill -f "wireguard-go $IF"; then
    echo "WireGuard: $IF stopped"
else
    echo "WireGuard: $IF was not running"
fi
rm -f "/var/run/wireguard/$IF.sock" 2>/dev/null
echo "Done."
