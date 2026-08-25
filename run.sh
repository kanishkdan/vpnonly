#!/bin/bash
# Launch an app inside the split tunnel (under group "vpnonly").
#
# usage: sudo ./run.sh                          pick from a list
#        sudo ./run.sh CapCut                   match by name
#        sudo ./run.sh /Applications/CapCut.app full path
#        sudo ./run.sh /usr/bin/curl https://api.ipify.org
set -euo pipefail
RUSER="${SUDO_USER:?run with sudo}"
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

# No argument: let them choose. Arrow keys when we have a terminal, a numbered
# prompt when we don't (piped input, CI, a dumb terminal).
if [ -z "$TARGET" ]; then
    IFS=$'\n' read -r -d '' -a APPS < <(list_apps && printf '\0')
    [ "${#APPS[@]}" -gt 0 ] || { echo "no apps found in /Applications"; exit 1; }

    if [ -t 0 ] && [ -t 1 ]; then
        # Draw on the alternate screen, like less or vim. Relative cursor moves
        # break as soon as the list is long enough to scroll the terminal, and
        # this also leaves the scrollback exactly as it was on exit.
        rows=$(tput lines 2>/dev/null || echo 24)
        view=$((rows - 4)); [ "$view" -lt 3 ] && view=3 || true
        [ "${#APPS[@]}" -lt "$view" ] && view=${#APPS[@]} || true
        sel=0; top=0
        restore() { printf '\e[?25h\e[?1049l'; }
        trap 'restore; exit 130' INT
        printf '\e[?1049h\e[?25l'
        while :; do
            [ "$sel" -lt "$top" ] && top=$sel || true
            [ "$sel" -ge $((top + view)) ] && top=$((sel - view + 1)) || true
            printf '\e[H\e[J'
            printf '  Which app should go through the VPN?\n\n'
            i=$top
            while [ "$i" -lt $((top + view)) ] && [ "$i" -lt "${#APPS[@]}" ]; do
                name=$(basename "${APPS[$i]}" .app)
                if [ "$i" -eq "$sel" ]; then
                    printf '\e[7m> %s\e[0m\n' "$name"
                else
                    printf '  %s\n' "$name"
                fi
                i=$((i + 1))
            done
            printf '\n  \e[2m%d of %d · arrows to move · enter to pick · q to quit\e[0m' \
                $((sel + 1)) "${#APPS[@]}"

            IFS= read -rsn1 key </dev/tty || { restore; exit 1; }
            case "$key" in
                $'\e')
                    # No timeout: macOS ships bash 3.2, which rejects a
                    # fractional -t outright, so the two bytes after ESC were
                    # never read and arrow keys did nothing. An arrow always
                    # sends all three bytes at once, so blocking here is safe.
                    IFS= read -rsn2 rest </dev/tty || rest=""
                    case "$rest" in
                        '[A') [ "$sel" -gt 0 ] && sel=$((sel - 1)) || true ;;
                        '[B') [ "$sel" -lt $((${#APPS[@]} - 1)) ] && sel=$((sel + 1)) || true ;;
                    esac ;;
                k) [ "$sel" -gt 0 ] && sel=$((sel - 1)) || true ;;
                j) [ "$sel" -lt $((${#APPS[@]} - 1)) ] && sel=$((sel + 1)) || true ;;
                q|Q) restore; echo "nothing launched"; exit 0 ;;
                "") break ;;
            esac
        done
        restore
        TARGET="${APPS[$sel]}"
    else
        echo "Apps on this Mac:"
        i=1
        for app in "${APPS[@]}"; do
            printf '%4d  %s\n' "$i" "$(basename "$app" .app)"
            i=$((i + 1))
        done
        printf 'Pick a number (or q to quit): '
        read -r choice
        case "$choice" in
            q|Q|"") echo "nothing launched"; exit 0 ;;
            *[!0-9]*) echo "not a number"; exit 1 ;;
        esac
        [ "$choice" -ge 1 ] && [ "$choice" -le "${#APPS[@]}" ] || { echo "out of range"; exit 1; }
        TARGET="${APPS[$((choice - 1))]}"
    fi
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
