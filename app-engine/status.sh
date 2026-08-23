#!/bin/bash
# Reports only a VPNonly-owned tunnel and its newest completed handshake.
# Root-owned runtime state binds the kernel interface to the exact process we
# launched; an unrelated utun device is never treated as VPNonly's tunnel.
set -uo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

DIR0="$(cd "$(dirname "$0")" && pwd)"
WG="$DIR0/bin/wg"
WG_GO="$DIR0/bin/wireguard-go"
STATE_ROOT="/var/run/vpnonly"

[ "$#" -eq 0 ] || { echo "status.sh takes no arguments" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

RUSER="${SUDO_USER:-}"
[ -n "$RUSER" ] || { echo "status requires SUDO_USER" >&2; exit 1; }
[ "$RUSER" != "root" ] || { echo "refusing to report state for root" >&2; exit 1; }
case "$RUSER" in
    *[!A-Za-z0-9._-]*) echo "refusing odd username: $RUSER" >&2; exit 1 ;;
esac
STATE_DIR="$STATE_ROOT/$RUSER"

valid_interface() {
    case "$1" in utun[0-9]*) ;; *) return 1 ;; esac
    case "${1#utun}" in ''|*[!0-9]*) return 1 ;; esac
}

valid_pid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 1 ] 2>/dev/null
}

valid_ipv4() {
    local a b c d extra octet
    case "$1" in ''|.*|*.|*..*|*[!0-9.]*) return 1 ;; esac
    IFS=. read -r a b c d extra <<< "$1"
    [ -z "$extra" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        case "$octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "$octet" -le 255 ] 2>/dev/null || return 1
    done
}

safe_root_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$1" 2>/dev/null)" = "0:0:700" ]
}

safe_state_file() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(/usr/bin/stat -f '%u:%g:%Lp' "$1" 2>/dev/null)" = "0:0:600" ]
}

process_is_ours() {
    local pid="$1" uid command
    valid_pid "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    uid=$(/bin/ps -ww -p "$pid" -o uid= 2>/dev/null |
        /usr/bin/tr -d '[:space:]') || return 1
    [ "$uid" = "0" ] || return 1
    command=$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null) || return 1
    [ "$command" = "$WG_GO -f utun" ]
}

unavailable() {
    echo "VPNonly tunnel state is unavailable" >&2
    exit 1
}

# A truly absent root-owned record means down. Anything present but unsafe,
# partial, stale, or inconsistent is unknown rather than a false disconnect.
if [ ! -e "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ]; then
    echo "STATUS tunnel=0 interface=none latest_handshake=0"
    exit 0
fi
safe_root_dir "$STATE_ROOT" || unavailable

if [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]; then
    echo "STATUS tunnel=0 interface=none latest_handshake=0"
    exit 0
fi
safe_root_dir "$STATE_DIR" || unavailable

for name in interface pid client-ip host; do
    safe_state_file "$STATE_DIR/$name" || unavailable
done

IF=$(cat "$STATE_DIR/interface") || unavailable
PID=$(cat "$STATE_DIR/pid") || unavailable
CLIENT_IP=$(cat "$STATE_DIR/client-ip") || unavailable
HOST=$(cat "$STATE_DIR/host") || unavailable

valid_interface "$IF" || unavailable
valid_pid "$PID" || unavailable
valid_ipv4 "$CLIENT_IP" || unavailable
case "$HOST" in ''|*[[:space:]]*) unavailable ;; esac

[ -x "$WG" ] && [ -x "$WG_GO" ] || unavailable
# A complete root-owned record names the only interface VPNonly could own. If
# that interface no longer exists, the tunnel is definitively down even when a
# crashed process left stale state behind. If the name was reused, ifconfig
# succeeds and the stricter process/socket checks below still return unknown.
if ! ifconfig "$IF" >/dev/null 2>&1; then
    echo "STATUS tunnel=0 interface=none latest_handshake=0"
    exit 0
fi
process_is_ours "$PID" || unavailable
SOCKET="/var/run/wireguard/$IF.sock"
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] &&
    [ "$(/usr/bin/stat -f '%u' "$SOCKET" 2>/dev/null)" = 0 ] || unavailable
"$WG" show "$IF" >/dev/null 2>&1 || unavailable

RAW=$("$WG" show "$IF" latest-handshakes 2>/dev/null) || unavailable
LATEST=$(printf '%s\n' "$RAW" | /usr/bin/awk '
    NF == 0 { next }
    NF != 2 || $2 !~ /^[0-9]+$/ { bad=1; next }
    { found=1; if (($2 + 0) > (latest + 0)) latest=$2 }
    END {
        if (bad || !found) exit 1
        print latest
    }
') || unavailable
case "$LATEST" in ''|*[!0-9]*) unavailable ;; esac

echo "STATUS tunnel=1 interface=$IF latest_handshake=$LATEST"
