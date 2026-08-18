#!/bin/bash
# Bring up the split tunnel: a WireGuard interface + PF rules that route ONLY
# traffic from unix group "vpnonly" through it. The system default route is
# never touched; everything else on the machine keeps its normal path.
#
# usage: sudo ./up.sh                       NordVPN, Singapore exit (default)
#        sudo COUNTRY=us ./up.sh            NordVPN, choose exit country
#        sudo ./up.sh mullvad-sg.conf       any provider: just hand it the
#                                           .conf file they gave you
set -euo pipefail

IF="${IF:-utun9}"
CLIENT_IP="${CLIENT_IP:-10.5.0.2}"      # NordLynx always assigns 10.5.0.2
COUNTRY="${COUNTRY:-sg}"
WG=/opt/homebrew/bin/wg
WG_GO=/opt/homebrew/bin/wireguard-go
[ -x "$WG" ] || WG=/usr/local/bin/wg
[ -x "$WG_GO" ] || WG_GO=/usr/local/bin/wireguard-go

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RUSER="${SUDO_USER:?run via sudo from your normal user}"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"
DIR="$(cd "$(dirname "$0")" && pwd)"
KEYFILE="$CONF/wg.key"
if [ -z "${1:-}" ] && [ ! -f "$KEYFILE" ]; then
    echo "no key at $KEYFILE"
    echo "either: ./fetch-creds.sh            (NordVPN)"
    echo "or:     sudo ./up.sh your-provider.conf"
    exit 1
fi

if ifconfig "$IF" >/dev/null 2>&1; then
    echo "$IF already exists — run down.sh first"; exit 1
fi

# --- pick a server -----------------------------------------------------------
# The easy path: a WireGuard .conf from any provider. parse-wg.py pulls out the
# endpoint, the server key and the tunnel address, so nothing has to be typed
# by hand or guessed at.
PROVIDER_CONF="${1:-}"
if [ -n "$PROVIDER_CONF" ]; then
    [ -f "$PROVIDER_CONF" ] || { echo "no such file: $PROVIDER_CONF"; exit 1; }
    PARSED=$("$DIR/parse-wg.py" "$PROVIDER_CONF" "$CONF/wg-session.conf") || exit 1
    CLIENT_IP=$(echo "$PARSED" | awk '{print $1}')
    ENDPOINT=$(echo "$PARSED" | awk '{print $2}')
    STATION="${ENDPOINT%:*}"; PORT="${ENDPOINT##*:}"
    HOST="$STATION"
    PUBKEY=""            # already in the parsed session file
    FROM_CONF=1
    echo "config: $PROVIDER_CONF  (tunnel address $CLIENT_IP)"
elif [ -n "${ENDPOINT:-}" ]; then
    STATION="${ENDPOINT%:*}"; PORT="${ENDPOINT##*:}"
    PUBKEY="${PEER_KEY:?set PEER_KEY=<server public key> when using ENDPOINT}"
    HOST="$STATION"
else
    PORT=51820
    CID=$(curl -sf https://api.nordvpn.com/v1/servers/countries | python3 -c "
import json,sys
cs=json.load(sys.stdin)
print(next(c['id'] for c in cs if c['code'].lower()=='$COUNTRY'.lower()))")
    read -r HOST STATION PUBKEY <<< "$(curl -sf "https://api.nordvpn.com/v1/servers/recommendations?filters\[country_id\]=$CID&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=1" | python3 -c "
import json,sys
s=json.load(sys.stdin)[0]
pk=next(m['value'] for t in s['technologies'] if t['identifier']=='wireguard_udp' for m in t.get('metadata',[]))
print(s['hostname'], s['station'], pk)")"
fi
echo "server: $HOST ($STATION:$PORT)"

# --- group + launcher --------------------------------------------------------
dseditgroup -o read vpnonly >/dev/null 2>&1 || \
    dseditgroup -o create -r "VPN-only apps (vpnonly)" vpnonly
[ -x "$DIR/vpnrun" ] || cc -O2 -o "$DIR/vpnrun" "$DIR/vpnrun.c"

# --- WireGuard interface -----------------------------------------------------
"$WG_GO" "$IF"
if [ "${FROM_CONF:-0}" = 1 ]; then
    "$WG" setconf "$IF" "$CONF/wg-session.conf"
else
    "$WG" set "$IF" private-key "$KEYFILE" \
        peer "$PUBKEY" endpoint "$STATION:$PORT" \
        allowed-ips 0.0.0.0/0 persistent-keepalive 25
fi
ifconfig "$IF" inet "$CLIENT_IP" "$CLIENT_IP" netmask 255.255.255.255 mtu 1420 up

# --- PF: steer group traffic into the tunnel ---------------------------------
# Merged ruleset = stock /etc/pf.conf + our NAT (inserted in the translation
# section) + filter rules at the end. /etc/pf.conf itself is never modified;
# down.sh reloads it verbatim.
PFMERGED="$CONF/pf-merged.conf"
{
    echo 'set skip on lo0'
    awk -v nat="nat on $IF inet from any to any -> $CLIENT_IP" \
        '{print} /^rdr-anchor/{print nat}' /etc/pf.conf
    # kill switch: if the tunnel is down, group traffic is blocked, not leaked
    echo "block return out proto { tcp udp } from any to any group vpnonly"
    echo "pass out quick route-to ($IF $CLIENT_IP) inet proto { tcp udp } from any to any group vpnonly keep state"
} > "$PFMERGED"
grep -q "nat on $IF" "$PFMERGED" || { echo "failed to insert NAT rule (non-stock /etc/pf.conf? see README)"; exit 1; }

pfctl -q -f "$PFMERGED"
pfctl -E 2>&1 | awk '/Token/{print $NF}' > "$CONF/pf-token" || true

# --- verify -------------------------------------------------------------------
echo -n "exit IP via tunnel: "
"$DIR/vpnrun" "$RUSER" /usr/bin/curl -s --max-time 15 https://api.ipify.org || echo -n "(no reply yet)"
echo
echo -n "your normal IP:     "
curl -s --max-time 10 https://api.ipify.org; echo
echo "Tunnel up. Launch an app inside it:  sudo $DIR/run.sh /Applications/YourApp.app"
