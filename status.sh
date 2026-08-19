#!/bin/bash
# What's actually happening: is the tunnel up, what does the outside world see
# from inside the group versus normally, and which processes are in the group.
#
#   ./status.sh          (sudo only needed for the per-app exit IP)
set -uo pipefail

IF="${IF:-utun9}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if ifconfig "$IF" >/dev/null 2>&1; then
    ADDR=$(ifconfig "$IF" | awk '/inet /{print $2}')
    echo "tunnel:   up on $IF ($ADDR)"
    # Interface counters only ever climb, so this says whether anything has
    # ever crossed, not whether it's working right now.
    RX=$(netstat -ibn -I "$IF" 2>/dev/null | awk 'NR==2{for(i=1;i<=NF;i++) if($i ~ /^<Link/){j=i+1; if($j ~ /:/) j++; print $(j+2); exit}}')
    echo "received: ${RX:-0} bytes"
else
    echo "tunnel:   down"
fi

if dscl . -read /Groups/vpnonly >/dev/null 2>&1; then
    GID=$(dscl . -read /Groups/vpnonly PrimaryGroupID 2>/dev/null | awk '{print $2}')
    INSIDE=$(ps -axo pid,rgid,comm | awk -v g="$GID" '$2==g {print "  " $1 "  " $3}')
    if [ -n "$INSIDE" ]; then
        echo "in vpn:"
        echo "$INSIDE"
    else
        echo "in vpn:   nothing running in the group"
    fi
else
    echo "in vpn:   group not created yet (run up.sh)"
fi

echo -n "your ip:  "
curl -s --max-time 8 https://api.ipify.org || echo "(no answer)"
echo
if [ "$(id -u)" = 0 ]; then
    echo -n "vpn ip:   "
    "$DIR/run.sh" "${SUDO_USER:-$USER}" vpnonly /usr/bin/curl -s --max-time 8 https://api.ipify.org || echo "(no answer)"
    echo
else
    echo "vpn ip:   run with sudo to see the exit IP from inside the tunnel"
fi
