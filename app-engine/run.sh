#!/bin/bash
# usage: run.sh <user> <vpn_group> </Applications/App.app or /path/to/binary> [args...]
# Launches a program tagged with its VPN group. Whether that group's traffic
# actually goes through the tunnel is decided separately by route.sh.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

DIR="$(cd "$(dirname "$0")" && pwd)"
RUSER="${1:?usage: run.sh <user> <group> <app> [args...]}"; shift
GROUP="${1:?usage: run.sh <user> <group> <app> [args...]}"; shift
[ "$RUSER" != "root" ] || { echo "refusing to launch as root"; exit 1; }
case "$RUSER" in *[!A-Za-z0-9._-]*) echo "refusing odd username"; exit 1 ;; esac
case "$GROUP" in
    vpn_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "invalid VPNonly group"; exit 1 ;;
esac

# Refuse to act on behalf of a different account than the one that invoked us:
# without this, the passwordless rule would let a user run programs as someone
# else, or point the tunnel at another account's key material.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ "$RUSER" != "$SUDO_USER" ]; then
    echo "refusing: asked to act for '$RUSER' but invoked by '$SUDO_USER'"; exit 1
fi

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
TARGET="${1:?usage: run.sh <user> <group> <app> [args...]}"; shift || true

if /usr/bin/sudo -u "$RUSER" /bin/test -d "$TARGET" 2>/dev/null && [[ "$TARGET" == *.app ]]; then
    # TARGET is caller-controlled. Resolve bundle metadata with the customer's
    # own privileges so a symlink can never turn this passwordless root script
    # into a reader for another account's plist.
    EXE=$(/usr/bin/sudo -u "$RUSER" /usr/bin/defaults read \
        "$TARGET/Contents/Info" CFBundleExecutable 2>/dev/null) || {
        echo "couldn't read that app's executable safely"; exit 1
    }
    case "$EXE" in
        ""|.|..|*/*|*\\*|*$'\n'*|*$'\r'*)
            echo "invalid app executable name"; exit 1
            ;;
    esac
    BIN="$TARGET/Contents/MacOS/$EXE"
    GUI=1
else
    BIN="$TARGET"
    GUI=0
fi
/usr/bin/sudo -u "$RUSER" /bin/test -x "$BIN" 2>/dev/null ||
    { echo "not executable for that account"; exit 1; }
[ -x "$DIR/vpnrun" ] || { echo "vpnrun missing from engine"; exit 1; }

if [ "$GUI" = 1 ]; then
    "$DIR/vpnrun" "$RUSER" "$GROUP" "$BIN" "$@" >/dev/null 2>&1 &
    echo "LAUNCHED pid=$! bin=$BIN"
else
    exec "$DIR/vpnrun" "$RUSER" "$GROUP" "$BIN" "$@"
fi
