#!/bin/bash
# Launch an app inside the split tunnel (under group "vpnonly").
#
# usage: sudo ./run.sh                          pick from a list
#        sudo ./run.sh CapCut                   match by name
#        sudo ./run.sh /Applications/CapCut.app full path
#        sudo ./run.sh /usr/bin/curl https://api.ipify.org
set -euo pipefail
RUSER="${SUDO_USER:?run with sudo}"
DIR="$(cd "$(dirname "$0")" && pwd)"
RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')

# WebKit hands its connections to system processes that never carry our group,
# so no per-app VPN on macOS can route these. Offering them would be a switch
# that silently does nothing.
cannot_route() {
    case "$(basename "$1")" in
        Safari.app|"Safari Technology Preview.app") return 0 ;;
        *) return 1 ;;
    esac
}

list_apps() {
    for d in /Applications "$RHOME/Applications" /Applications/Utilities; do
        [ -d "$d" ] || continue
        for app in "$d"/*.app; do
            [ -d "$app" ] || continue
            cannot_route "$app" && continue
            printf '%s\n' "$app"
        done
    done | sort -f -t/ -k99
}

TARGET="${1:-}"
[ "$#" -gt 0 ] && shift || true

# No argument: show what's installed and let them pick a number.
if [ -z "$TARGET" ]; then
    IFS=$'\n' read -r -d '' -a APPS < <(list_apps && printf '\0')
    [ "${#APPS[@]}" -gt 0 ] || { echo "no apps found in /Applications"; exit 1; }
    echo "Apps on this Mac:"
    i=1
    for app in "${APPS[@]}"; do
        printf '%4d  %s\n' "$i" "$(basename "$app" .app)"
        i=$((i + 1))
    done
    echo
    printf 'Pick a number (or q to quit): '
    read -r choice </dev/tty
    case "$choice" in
        q|Q|"") echo "nothing launched"; exit 0 ;;
        *[!0-9]*) echo "not a number"; exit 1 ;;
    esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "${#APPS[@]}" ] || { echo "out of range"; exit 1; }
    TARGET="${APPS[$((choice - 1))]}"
    echo
fi

# A bare name like "CapCut": find it rather than making them type a path.
if [ ! -e "$TARGET" ]; then
    MATCHES=$(list_apps | grep -i "/${TARGET}[^/]*\.app$" || true)
    COUNT=$(printf '%s' "$MATCHES" | grep -c . || true)
    if [ "$COUNT" -eq 1 ]; then
        TARGET="$MATCHES"
    elif [ "$COUNT" -gt 1 ]; then
        echo "more than one app matches '$TARGET':"
        printf '%s\n' "$MATCHES" | sed 's|.*/|  |; s|\.app$||'
        exit 1
    else
        echo "no app matches '$TARGET'. Run without arguments to see the list."
        exit 1
    fi
fi

if cannot_route "$TARGET"; then
    echo "$(basename "$TARGET" .app) can't be routed: WebKit makes its connections"
    echo "from system processes that don't carry the group, so the firewall has"
    echo "nothing to match. Chrome, Firefox, Arc and Brave all work."
    exit 1
fi

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
    echo "launched through the tunnel (pid $!): $(basename "$TARGET" .app)"
    echo "check it with: sudo $DIR/status.sh"
else
    exec "$DIR/vpnrun" "$RUSER" "$BIN" "$@"
fi
