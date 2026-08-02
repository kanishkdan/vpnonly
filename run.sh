#!/bin/bash
# Launch an app inside the split tunnel (under group "vpnonly").
# usage: sudo ./run.sh /Applications/CapCut.app
#        sudo ./run.sh /usr/bin/curl https://api.ipify.org
set -euo pipefail
RUSER="${SUDO_USER:?run with sudo}"
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${1:?usage: sudo ./run.sh </Applications/App.app or /path/to/binary> [args...]}"
shift || true

if [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    EXE=$(defaults read "$TARGET/Contents/Info" CFBundleExecutable)
    BIN="$TARGET/Contents/MacOS/$EXE"
else
    BIN="$TARGET"
fi
[ -x "$BIN" ] || { echo "not executable: $BIN"; exit 1; }
[ -x "$DIR/vpnrun" ] || { echo "vpnrun not built — run up.sh first"; exit 1; }

if [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    "$DIR/vpnrun" "$RUSER" "$BIN" "$@" >/dev/null 2>&1 &
    echo "launched through tunnel (pid $!): $BIN"
else
    exec "$DIR/vpnrun" "$RUSER" "$BIN" "$@"
fi
