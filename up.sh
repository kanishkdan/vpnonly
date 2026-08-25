#!/bin/bash
# Bring up the split tunnel: a WireGuard interface plus PF rules that route ONLY
# traffic from unix group "vpnonly" through it. The system default route is
# never touched, so everything else on the machine keeps its normal path.
#
# usage: sudo ./up.sh                       NordVPN, Singapore exit (default)
#        sudo COUNTRY=us ./up.sh            NordVPN, choose exit country
#        sudo ./up.sh mullvad-sg.conf       any provider: hand it their .conf
set -euo pipefail

CLIENT_IP="${CLIENT_IP:-10.5.0.2}"      # NordLynx always assigns 10.5.0.2
COUNTRY="${COUNTRY:-sg}"
ANCHOR="com.apple/vpnonly-cli"
WG=/opt/homebrew/bin/wg
WG_GO=/opt/homebrew/bin/wireguard-go
[ -x "$WG" ] || WG=/usr/local/bin/wg
[ -x "$WG_GO" ] || WG_GO=/usr/local/bin/wireguard-go
[ -x "$WG" ] && [ -x "$WG_GO" ] || {
    echo "wireguard-go and wg not found. Install them first:"
    echo "  brew install wireguard-go wireguard-tools"
    exit 1
}

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
RUSER="${SUDO_USER:?run via sudo from your normal user}"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"
# Resolve through symlinks so this works when installed on PATH (Homebrew
# links bin/vpnonly to libexec, and $0 would otherwise point at the link).
SELF="$0"
while [ -L "$SELF" ]; do
    LINK=$(readlink "$SELF")
    case "$LINK" in
        /*) SELF="$LINK" ;;
        *)  SELF="$(dirname "$SELF")/$LINK" ;;
    esac
done
DIR="$(cd "$(dirname "$SELF")" && pwd)"
KEYFILE="$CONF/wg.key"
mkdir -p "$CONF"; chown "$RUSER" "$CONF"

if [ -z "${1:-}" ] && [ ! -f "$KEYFILE" ]; then
    echo "no key at $KEYFILE"
    echo "either: ./fetch-creds.sh            (NordVPN)"
    echo "or:     sudo ./up.sh your-provider.conf"
    exit 1
fi

if [ -s "$CONF/tunnel-if" ] && ifconfig "$(cat "$CONF/tunnel-if")" >/dev/null 2>&1; then
    echo "a vpnonly tunnel is already up on $(cat "$CONF/tunnel-if") — run down.sh first"
    exit 1
fi

# PF evaluates anchors nested under com.apple/*, which is where our rules go.
# If something has replaced the main ruleset, an anchor we load would never be
# evaluated: rules present, traffic unaffected, no error anywhere. Refuse
# instead, rather than claim protection we cannot deliver.
pfctl -s rules 2>/dev/null | grep -Eq '^[[:space:]]*anchor "com\.apple/\*" all[[:space:]]*$' || {
    echo "This Mac's main PF ruleset is not the stock one, so VPNonly's anchor"
    echo "would never be evaluated. Nothing has been changed."
    exit 1
}

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

# Another full-device VPN holding the default route would carry our own
# encrypted traffic inside its tunnel, which usually breaks on MTU.
OUTER=$(route -n get "$STATION" 2>/dev/null | awk '/interface:/{print $2; exit}' || true)
case "$OUTER" in
    utun*|ppp*|ipsec*)
        echo "Another VPN is active on $OUTER and owns the route to $STATION."
        echo "Disconnect it first. Nothing has been changed."
        exit 1
        ;;
esac

# --- group + launcher --------------------------------------------------------
dseditgroup -o read vpnonly >/dev/null 2>&1 || \
    dseditgroup -o create -r "VPN-only apps (vpnonly)" vpnonly
[ -x "$DIR/vpnrun" ] || cc -O2 -o "$DIR/vpnrun" "$DIR/vpnrun.c"

# --- WireGuard interface -----------------------------------------------------
# Ask the kernel for a free utunN rather than claiming a fixed name. Anything
# else on this Mac may already hold utun0..utun9, and adopting an interface we
# do not own means reporting a connection that isn't ours.
NAMEFILE=$(mktemp)
WG_TUN_NAME_FILE="$NAMEFILE" nohup "$WG_GO" -f utun </dev/null >/dev/null 2>&1 &
WG_PID=$!
for _ in $(seq 1 50); do [ -s "$NAMEFILE" ] && break; sleep 0.1; done
IF=$(cat "$NAMEFILE" 2>/dev/null || true); rm -f "$NAMEFILE"
case "$IF" in
    utun[0-9]*) ;;
    *) echo "wireguard-go did not report an interface"; exit 1 ;;
esac
echo "interface: $IF"

for _ in $(seq 1 50); do
    [ -S "/var/run/wireguard/$IF.sock" ] && ifconfig "$IF" >/dev/null 2>&1 && break
    sleep 0.1
done

if [ "${FROM_CONF:-0}" = 1 ]; then
    "$WG" setconf "$IF" "$CONF/wg-session.conf"
else
    "$WG" set "$IF" private-key "$KEYFILE" \
        peer "$PUBKEY" endpoint "$STATION:$PORT" \
        allowed-ips 0.0.0.0/0 persistent-keepalive 25
fi
ifconfig "$IF" inet "$CLIENT_IP" "$CLIENT_IP" netmask 255.255.255.255 mtu 1420 up

printf '%s\n' "$IF" > "$CONF/tunnel-if"
printf '%s\n' "$CLIENT_IP" > "$CONF/tunnel-ip"
printf '%s\n' "$WG_PID" > "$CONF/tunnel-pid"
chown "$RUSER" "$CONF/tunnel-if" "$CONF/tunnel-ip" "$CONF/tunnel-pid"

# --- PF: steer group traffic into the tunnel ---------------------------------
# Everything goes in VPNonly's own anchor. /etc/pf.conf is never read, rebuilt
# or reloaded, so other firewall tools keep their rules and we keep ours.
#
# Rule order matters: both rules are `quick`, so the first match wins and the
# pass must come first. `on ! lo0` keeps loopback out of it, or a routed app
# would lose its own localhost connections. `return` rather than `drop` so a
# blocked app fails immediately instead of hanging until it times out.
PFRULES=$(mktemp)
{
    printf 'nat on %s inet from any to any -> %s\n' "$IF" "$CLIENT_IP"
    printf 'pass out quick on ! lo0 route-to (%s %s) inet proto { tcp udp } from any to any group vpnonly keep state\n' "$IF" "$CLIENT_IP"
    printf 'block return out quick on ! lo0 from any to any group vpnonly\n'
} > "$PFRULES"

pfctl -n -a "$ANCHOR" -f "$PFRULES" 2>/dev/null || {
    echo "generated PF rules failed validation; nothing loaded"; rm -f "$PFRULES"; exit 1
}
# pfctl prints a warning about flushing the main ruleset whenever -f is used,
# even when loading into an anchor, which cannot touch the main ruleset. Keep
# the message for real failures, drop it when the load succeeded.
if ! PF_MSG=$(pfctl -q -a "$ANCHOR" -f "$PFRULES" 2>&1); then
    echo "$PF_MSG" >&2
    rm -f "$PFRULES"
    exit 1
fi
rm -f "$PFRULES"
pfctl -E 2>&1 | awk '/Token/{print $NF}' > "$CONF/pf-token" || true
chown "$RUSER" "$CONF/pf-token" 2>/dev/null || true

# --- verify -------------------------------------------------------------------
echo -n "exit IP via tunnel: "
"$DIR/vpnrun" "$RUSER" /usr/bin/curl -s --max-time 15 https://api.ipify.org || echo -n "(no reply yet)"
echo
echo -n "your normal IP:     "
curl -s --max-time 10 https://api.ipify.org; echo
echo
printf '  \e[2mTunnel up. Nothing is routed through it yet.\n'
printf '  Run \e[0mvpnonly\e[2m to put an app inside it.\e[0m\n' 
