#!/bin/bash
# usage: up.sh <user> nord <country>
#        up.sh <user> profile <id>
#
# Brings up the WireGuard tunnel. Never touches the default route, and never
# routes anything by itself — route.sh decides which app groups go through it.
#
# Key material is always read from files owned by the user (mode 600), never
# passed on the command line where `ps` could see it.
set -eEuo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

DIR0="$(cd "$(dirname "$0")" && pwd)"
RUSER="${1:?usage: up.sh <user> nord|profile <arg>}"
MODE="${2:-nord}"
ARG="${3:-}"

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
[ "$RUSER" != "root" ] || { echo "refusing to operate for root"; exit 1; }
case "$RUSER" in
    *[!A-Za-z0-9._-]*) echo "refusing odd username: $RUSER"; exit 1 ;;
esac
id "$RUSER" >/dev/null 2>&1 || { echo "no such user: $RUSER"; exit 1; }

# Refuse to act on behalf of a different account than the one that invoked us:
# without this, the passwordless rule would let a user run programs as someone
# else, or point the tunnel at another account's key material.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ "$RUSER" != "$SUDO_USER" ]; then
    echo "refusing: asked to act for '$RUSER' but invoked by '$SUDO_USER'"; exit 1
fi

WG="$DIR0/bin/wg"
WG_GO="$DIR0/bin/wireguard-go"
VPNPARSE="$DIR0/bin/vpnparse"
[ -x "$WG" ] || { echo "bundled wg is missing"; exit 1; }
[ -x "$WG_GO" ] || { echo "bundled wireguard-go is missing"; exit 1; }
[ -x "$VPNPARSE" ] || { echo "bundled vpnparse is missing"; exit 1; }

RHOME=$(dscl . -read "/Users/$RUSER" NFSHomeDirectory | awk '{print $2}')
CONF="$RHOME/.config/vpnonly"
STATE_ROOT="/var/run/vpnonly"
STATE_DIR="$STATE_ROOT/$RUSER"
LOCK_DIR="$STATE_ROOT/.lock-$RUSER"
WGSET=""
PROFILE_TMP=""
NAME_TMP=""
NEW_PID=""
NEW_IF=""
LOCK_HELD=0
LOCK_PID_TMP=""
STATE_CREATED=0
STATE_COMMITTED=0
MANAGING_NEW=0

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

safe_root_socket() {
    [ -S "$1" ] && [ ! -L "$1" ] &&
        [ "$(/usr/bin/stat -f '%u' "$1" 2>/dev/null)" = 0 ]
}

root_process_has_command() {
    local pid="$1" expected="$2" uid command
    valid_pid "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    uid=$(/bin/ps -ww -p "$pid" -o uid= 2>/dev/null |
        /usr/bin/tr -d '[:space:]') || return 1
    [ "$uid" = "0" ] || return 1
    command=$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null) || return 1
    [ "$command" = "$expected" ]
}

process_is_ours() {
    root_process_has_command "$1" "$WG_GO -f utun"
}

stop_exact_process() {
    local pid="$1" i=0
    process_is_ours "$pid" || return 0
    kill -TERM "$pid" 2>/dev/null || true
    while process_is_ours "$pid" && [ "$i" -lt 30 ]; do
        /bin/sleep 0.1
        i=$((i + 1))
    done
    if process_is_ours "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
        i=0
        while process_is_ours "$pid" && [ "$i" -lt 20 ]; do
            /bin/sleep 0.1
            i=$((i + 1))
        done
    fi
    process_is_ours "$pid" && return 1
    return 0
}

legacy_process_is_ours() {
    root_process_has_command "$1" "$WG_GO utun9"
}

stop_legacy_process() {
    local pid="$1" i=0
    legacy_process_is_ours "$pid" || return 0
    kill -TERM "$pid" 2>/dev/null || true
    while legacy_process_is_ours "$pid" && [ "$i" -lt 30 ]; do
        /bin/sleep 0.1
        i=$((i + 1))
    done
    if legacy_process_is_ours "$pid"; then
        kill -KILL "$pid" 2>/dev/null || true
        /bin/sleep 0.2
    fi
}

remove_known_state() {
    safe_root_dir "$STATE_DIR" || return 0
    rm -f "$STATE_DIR/interface" "$STATE_DIR/pid" \
          "$STATE_DIR/client-ip" "$STATE_DIR/host" \
          "$STATE_DIR/.setup-pid" "$STATE_DIR/.setup-interface" \
          "$STATE_DIR"/.setup-pid.* "$STATE_DIR"/.setup-interface.* \
          "$STATE_DIR"/.interface-name.* "$STATE_DIR"/.interface.* \
          "$STATE_DIR"/.pid.* "$STATE_DIR"/.client-ip.* "$STATE_DIR"/.host.*
    rmdir "$STATE_DIR" 2>/dev/null || true
}

wait_interface_gone() {
    local interface="$1" i=0
    valid_interface "$interface" || return 0
    while ifconfig "$interface" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do
        /bin/sleep 0.1
        i=$((i + 1))
    done
    ! ifconfig "$interface" >/dev/null 2>&1
}

recover_new_interface() {
    local candidate
    valid_interface "$NEW_IF" && return 0
    [ -n "$NAME_TMP" ] || return 0
    [ -e "$NAME_TMP" ] || [ -L "$NAME_TMP" ] || return 0
    safe_state_file "$NAME_TMP" || return 1
    [ -s "$NAME_TMP" ] || return 0
    candidate=$(cat "$NAME_TMP") || return 1
    valid_interface "$candidate" || return 1
    NEW_IF="$candidate"
}

# Stops and fully accounts for an uncommitted child. Failure deliberately
# preserves the root record/name file so down.sh can retry without guessing.
cleanup_managed_new() {
    local socket
    [ "$MANAGING_NEW" -eq 1 ] && [ "$STATE_COMMITTED" -eq 0 ] || return 0
    recover_new_interface || return 1
    if [ -n "$NEW_PID" ] && valid_pid "$NEW_PID"; then
        if process_is_ours "$NEW_PID"; then
            stop_exact_process "$NEW_PID" || return 1
        elif kill -0 "$NEW_PID" 2>/dev/null; then
            # The just-forked child may not have exec'd wireguard-go yet. Do
            # not erase its only recovery record while any process has the PID.
            return 1
        fi
    fi
    if valid_interface "$NEW_IF"; then
        wait_interface_gone "$NEW_IF" || return 1
        socket="/var/run/wireguard/$NEW_IF.sock"
        if [ -e "$socket" ] || [ -L "$socket" ]; then
            safe_root_socket "$socket" || return 1
            rm -f "$socket" || return 1
        fi
    fi
    return 0
}

cleanup_exit() {
    local cleanup_ok=1
    set +e
    trap - ERR
    [ -n "$WGSET" ] && rm -f "$WGSET"
    [ -n "$PROFILE_TMP" ] && rm -f "$PROFILE_TMP"
    [ -n "$LOCK_PID_TMP" ] && rm -f "$LOCK_PID_TMP"
    cleanup_managed_new || cleanup_ok=0
    if [ "$cleanup_ok" -eq 1 ] && [ "$STATE_CREATED" -eq 1 ] &&
       [ "$STATE_COMMITTED" -eq 0 ]; then
        remove_known_state
    fi
    if [ "$cleanup_ok" -eq 1 ] || [ "$STATE_COMMITTED" -eq 1 ]; then
        [ -n "$NAME_TMP" ] && rm -f "$NAME_TMP"
    fi
    if [ "$LOCK_HELD" -eq 1 ] && safe_root_dir "$LOCK_DIR"; then
        if safe_state_file "$LOCK_DIR/pid" &&
           [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$LOCK_DIR/pid"
            rmdir "$LOCK_DIR" 2>/dev/null
        elif [ ! -e "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ]; then
            rm -f "$LOCK_DIR"/.pid.*
            rmdir "$LOCK_DIR" 2>/dev/null
        fi
    fi
}

abort_new_tunnel() {
    local rc="$1"
    trap - ERR
    set +e
    if cleanup_managed_new; then
        remove_known_state
        MANAGING_NEW=0
    fi
    exit "$rc"
}

trap cleanup_exit EXIT
trap 'abort_new_tunnel $?' ERR
trap 'abort_new_tunnel 129' HUP
trap 'abort_new_tunnel 130' INT
trap 'abort_new_tunnel 143' TERM

if [ -e "$STATE_ROOT" ] || [ -L "$STATE_ROOT" ]; then
    safe_root_dir "$STATE_ROOT" || {
        echo "unsafe VPNonly runtime directory: $STATE_ROOT" >&2
        exit 1
    }
else
    mkdir -m 700 "$STATE_ROOT"
    chown root:wheel "$STATE_ROOT"
    chmod 700 "$STATE_ROOT"
fi
safe_root_dir "$STATE_ROOT" || {
    echo "couldn't create safe VPNonly runtime directory" >&2
    exit 1
}

if ! mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
    safe_root_dir "$LOCK_DIR" || {
        echo "unsafe VPNonly operation lock" >&2
        exit 1
    }
    if safe_state_file "$LOCK_DIR/pid"; then
        LOCK_PID=$(cat "$LOCK_DIR/pid") || exit 1
        if valid_pid "$LOCK_PID" && kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "BUSY: another VPNonly tunnel operation is running" >&2
            exit 9
        elif ! valid_pid "$LOCK_PID"; then
            LOCK_MTIME=$(/usr/bin/stat -f '%m' "$LOCK_DIR/pid" 2>/dev/null || echo 0)
            NOW=$(/bin/date +%s)
            if [ "$LOCK_MTIME" -gt 0 ] 2>/dev/null &&
               [ $((NOW - LOCK_MTIME)) -lt 30 ] 2>/dev/null; then
                echo "BUSY: another VPNonly tunnel operation is starting" >&2
                exit 9
            fi
        fi
    elif [ -e "$LOCK_DIR/pid" ] || [ -L "$LOCK_DIR/pid" ]; then
        echo "unsafe VPNonly operation lock state" >&2
        exit 1
    else
        # mkdir is the ownership primitive. A second process can arrive in the
        # tiny window before the owner writes pid; never steal a fresh lock.
        LOCK_MTIME=$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || echo 0)
        NOW=$(/bin/date +%s)
        if [ "$LOCK_MTIME" -gt 0 ] 2>/dev/null &&
           [ $((NOW - LOCK_MTIME)) -lt 30 ] 2>/dev/null; then
            echo "BUSY: another VPNonly tunnel operation is starting" >&2
            exit 9
        fi
    fi
    rm -f "$LOCK_DIR/pid" "$LOCK_DIR"/.pid.*
    if ! rmdir "$LOCK_DIR" 2>/dev/null ||
       ! mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
        echo "BUSY: another VPNonly tunnel operation is running" >&2
        exit 9
    fi
fi
LOCK_HELD=1
chown root:wheel "$LOCK_DIR"
chmod 700 "$LOCK_DIR"
safe_root_dir "$LOCK_DIR" || {
    echo "couldn't create safe VPNonly operation lock" >&2
    exit 1
}
LOCK_PID_TMP=$(mktemp "$LOCK_DIR/.pid.XXXXXX") || exit 1
printf '%s\n' "$$" > "$LOCK_PID_TMP" || exit 1
chmod 600 "$LOCK_PID_TMP" || exit 1
chown root:wheel "$LOCK_PID_TMP" || exit 1
mv -f "$LOCK_PID_TMP" "$LOCK_DIR/pid" || exit 1
LOCK_PID_TMP=""

# A surviving tunnel is ours only when every root-owned state field and the
# exact foreground process agree. Interface existence by itself proves
# nothing: macOS assigns utun devices to many unrelated services.
if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
    safe_root_dir "$STATE_DIR" || {
        echo "unsafe VPNonly user runtime directory: $STATE_DIR" >&2
        exit 1
    }
    for name in interface pid client-ip host; do
        if [ -e "$STATE_DIR/$name" ] || [ -L "$STATE_DIR/$name" ]; then
            safe_state_file "$STATE_DIR/$name" || {
                echo "unsafe VPNonly runtime state: $name" >&2
                exit 1
            }
        fi
    done
    if safe_state_file "$STATE_DIR/interface" &&
       safe_state_file "$STATE_DIR/pid" &&
       safe_state_file "$STATE_DIR/client-ip" &&
       safe_state_file "$STATE_DIR/host"; then
        OLD_IF=$(cat "$STATE_DIR/interface")
        OLD_PID=$(cat "$STATE_DIR/pid")
        OLD_IP=$(cat "$STATE_DIR/client-ip")
        OLD_HOST=$(cat "$STATE_DIR/host")
        if valid_interface "$OLD_IF" && valid_pid "$OLD_PID" &&
           valid_ipv4 "$OLD_IP" &&
           [ -n "$OLD_HOST" ] && [[ "$OLD_HOST" != *[[:space:]]* ]] &&
           process_is_ours "$OLD_PID" &&
           ifconfig "$OLD_IF" >/dev/null 2>&1 &&
           [ -S "/var/run/wireguard/$OLD_IF.sock" ] &&
           "$WG" show "$OLD_IF" >/dev/null 2>&1; then
            echo "ALREADY_UP interface=$OLD_IF host=$OLD_HOST"
            exit 0
        fi
        # A root-owned stale record may identify one of our exact foreground
        # processes. Stop only that PID; never search or kill by interface.
        OLD_OWNED=0
        if process_is_ours "$OLD_PID"; then
            OLD_OWNED=1
            stop_exact_process "$OLD_PID" || {
                echo "existing VPNonly tunnel could not be stopped" >&2
                exit 1
            }
        fi
        if [ "$OLD_OWNED" -eq 1 ] && valid_interface "$OLD_IF"; then
            wait_interface_gone "$OLD_IF" || {
                echo "existing VPNonly interface did not disappear" >&2
                exit 1
            }
            OLD_SOCKET="/var/run/wireguard/$OLD_IF.sock"
            if [ -e "$OLD_SOCKET" ] || [ -L "$OLD_SOCKET" ]; then
                safe_root_socket "$OLD_SOCKET" || {
                    echo "existing VPNonly socket became unsafe" >&2
                    exit 1
                }
                rm -f "$OLD_SOCKET"
            fi
        elif [ "$OLD_OWNED" -eq 0 ] && valid_interface "$OLD_IF" &&
             ! ifconfig "$OLD_IF" >/dev/null 2>&1 &&
             safe_root_socket "/var/run/wireguard/$OLD_IF.sock"; then
            # wireguard-go can leave its UAPI socket behind after SIGKILL.
            # Trusted state + an absent interface makes this stale socket ours;
            # never remove it while an interface with that name exists.
            rm -f "/var/run/wireguard/$OLD_IF.sock"
        fi
    fi
    if safe_state_file "$STATE_DIR/.setup-pid"; then
        SETUP_PID=$(cat "$STATE_DIR/.setup-pid") || exit 1
        valid_pid "$SETUP_PID" || {
            echo "invalid VPNonly provisional process state" >&2
            exit 1
        }
        SETUP_IF=""
        if [ -e "$STATE_DIR/.setup-interface" ] || [ -L "$STATE_DIR/.setup-interface" ]; then
            safe_state_file "$STATE_DIR/.setup-interface" || {
                echo "unsafe VPNonly provisional tunnel state" >&2
                exit 1
            }
            SETUP_IF=$(cat "$STATE_DIR/.setup-interface") || exit 1
            valid_interface "$SETUP_IF" || {
                echo "invalid VPNonly provisional interface state" >&2
                exit 1
            }
        else
            # wireguard-go writes the kernel-selected name before up.sh can
            # atomically publish .setup-interface. Recover that narrow crash
            # window from the root-only name file instead of losing ownership.
            SETUP_NAME_FILE=""
            for candidate in "$STATE_DIR"/.interface-name.*; do
                [ -e "$candidate" ] || [ -L "$candidate" ] || continue
                [ -z "$SETUP_NAME_FILE" ] || {
                    echo "ambiguous VPNonly provisional interface state" >&2
                    exit 1
                }
                safe_state_file "$candidate" || {
                    echo "unsafe VPNonly provisional name state" >&2
                    exit 1
                }
                SETUP_NAME_FILE="$candidate"
            done
            if [ -n "$SETUP_NAME_FILE" ] && [ -s "$SETUP_NAME_FILE" ]; then
                SETUP_IF=$(cat "$SETUP_NAME_FILE") || exit 1
                valid_interface "$SETUP_IF" || {
                    echo "invalid VPNonly provisional interface name" >&2
                    exit 1
                }
            fi
        fi
        SETUP_OWNED=0
        if ! process_is_ours "$SETUP_PID" && kill -0 "$SETUP_PID" 2>/dev/null; then
            # The recorded child may be in nohup's tiny pre-exec window. Give
            # it a moment to become the exact WireGuard command; a different
            # live process is never treated as stale/dead state.
            SETUP_WAIT=0
            while kill -0 "$SETUP_PID" 2>/dev/null &&
                  ! process_is_ours "$SETUP_PID" && [ "$SETUP_WAIT" -lt 5 ]; do
                /bin/sleep 0.1
                SETUP_WAIT=$((SETUP_WAIT + 1))
            done
            if kill -0 "$SETUP_PID" 2>/dev/null && ! process_is_ours "$SETUP_PID"; then
                echo "BUSY: VPNonly tunnel setup is still starting" >&2
                exit 9
            fi
        fi
        if process_is_ours "$SETUP_PID"; then
            SETUP_OWNED=1
            stop_exact_process "$SETUP_PID" || {
                echo "provisional VPNonly tunnel could not be stopped" >&2
                exit 1
            }
        fi
        if [ "$SETUP_OWNED" -eq 1 ] && [ -n "$SETUP_IF" ]; then
            wait_interface_gone "$SETUP_IF" || {
                echo "provisional VPNonly interface did not disappear" >&2
                exit 1
            }
            SETUP_SOCKET="/var/run/wireguard/$SETUP_IF.sock"
            if [ -e "$SETUP_SOCKET" ] || [ -L "$SETUP_SOCKET" ]; then
                safe_root_socket "$SETUP_SOCKET" || {
                    echo "provisional VPNonly socket became unsafe" >&2
                    exit 1
                }
                rm -f "$SETUP_SOCKET"
            fi
        elif [ "$SETUP_OWNED" -eq 0 ] && [ -n "$SETUP_IF" ] &&
             ! ifconfig "$SETUP_IF" >/dev/null 2>&1 &&
             safe_root_socket "/var/run/wireguard/$SETUP_IF.sock"; then
            rm -f "/var/run/wireguard/$SETUP_IF.sock"
        fi
    elif [ -e "$STATE_DIR/.setup-pid" ] || [ -L "$STATE_DIR/.setup-pid" ]; then
        echo "unsafe VPNonly provisional process state" >&2
        exit 1
    fi
    remove_known_state
fi

WGSET=$(mktemp); chmod 600 "$WGSET"
CANDIDATES=""

# Nord hands back several recommended servers. Writing one of them into the
# wg-setconf file is the only difference between attempts, so keep it in one
# place the retry loop can call again.
write_nord_peer() {
    {
        echo "[Interface]"
        echo "PrivateKey = $PRIVATE_KEY"
        echo "[Peer]"
        echo "PublicKey = $2"
        echo "Endpoint = $1:51820"
        echo "AllowedIPs = 0.0.0.0/0"
        echo "PersistentKeepalive = 25"
    } > "$WGSET"
}

case "$MODE" in
# ── NordVPN: their API hands us a server for the country you picked ─────────
nord)
    COUNTRY="${ARG:-sg}"
    KEYFILE="$CONF/wg.key"
    /usr/bin/sudo -u "$RUSER" /bin/test -f "$KEYFILE" 2>/dev/null || {
        echo "NOKEY: no readable WireGuard key"; exit 2
    }
    PRIVATE_KEY=$(/usr/bin/sudo -u "$RUSER" /bin/cat "$KEYFILE" 2>/dev/null) || {
        echo "NOKEY: the WireGuard key could not be read safely"; exit 2
    }
    [ "${#PRIVATE_KEY}" -eq 44 ] && [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
        echo "NOKEY: the WireGuard key is invalid"; exit 2
    }
    CLIENT_IP=10.5.0.2          # NordLynx always assigns this

    COUNTRIES_JSON=$(curl -sf --max-time 15 https://api.nordvpn.com/v1/servers/countries || true)
    [ -n "$COUNTRIES_JSON" ] || { echo "NONET: can't reach NordVPN (no internet, or their API is down)"; exit 3; }

    CID=$(printf '%s' "$COUNTRIES_JSON" |
        "$VPNPARSE" country-id "$COUNTRY" 2>/dev/null || true)
    case "$CID" in
        ''|*[!0-9]*) echo "BADCOUNTRY: no NordVPN servers found for '$COUNTRY'"; exit 4 ;;
    esac

    REC_JSON=$(curl -sf --max-time 15 "https://api.nordvpn.com/v1/servers/recommendations?filters\[country_id\]=$CID&filters\[servers_technologies\]\[identifier\]=wireguard_udp&limit=5" || true)
    [ -n "$REC_JSON" ] || { echo "NONET: can't reach NordVPN server list"; exit 3; }

    SERVER_LINES=$(printf '%s' "$REC_JSON" |
        "$VPNPARSE" nord-servers 2>/dev/null || true)
    SERVER_COUNT=$(printf '%s\n' "$SERVER_LINES" | awk 'NF == 3 { n++ } END { print n + 0 }')
    [ "$SERVER_COUNT" -gt 0 ] 2>/dev/null || {
        echo "NOSERVER: NordVPN returned no usable server for '$COUNTRY'"; exit 5
    }
    # Rotate by a random offset rather than pinning every attempt to item zero,
    # so a later self-heal does not deterministically re-pick a failing
    # endpoint. Keep the whole rotated list: the handshake stage below tries the
    # next one instead of turning a single dead server into an error the user
    # has to read and act on.
    OFFSET=$((RANDOM % SERVER_COUNT))
    CANDIDATES=$(printf '%s\n' "$SERVER_LINES" | /usr/bin/awk -v off="$OFFSET" '
        NF == 3 { lines[c++] = $0 }
        END { for (i = 0; i < c; i++) print lines[(i + off) % c] }')

    HOST=""; STATION=""; PUBKEY=""
    read -r HOST STATION PUBKEY <<< "$(printf '%s\n' "$CANDIDATES" | /usr/bin/head -n 1)"
    [ -n "${PUBKEY:-}" ] || { echo "NOSERVER: NordVPN returned no usable server for '$COUNTRY'"; exit 5; }

    write_nord_peer "$STATION" "$PUBKEY"
    LABEL="$HOST"
    ;;

# ── Any other provider: a WireGuard config the user imported ───────────────
profile)
    [ -n "$ARG" ] || { echo "BADPROFILE: no profile given"; exit 7; }
    case "$ARG" in *[!A-Za-z0-9._-]*) echo "BADPROFILE: bad id"; exit 7 ;; esac
    PCONF="$CONF/profiles/$ARG.conf"
    /usr/bin/sudo -u "$RUSER" /bin/test -f "$PCONF" 2>/dev/null || {
        echo "NOPROFILE: $ARG is not readable"; exit 7
    }

    # Reduce the provider's config to what `wg setconf` accepts, and pull out
    # the interface address (Mullvad hands out 10.64.x.x, others differ).
    # Read as the customer, not root. A user-controlled symlink can therefore
    # never make the privileged parser open a root-only file.
    PROFILE_TMP=$(mktemp)
    /usr/bin/sudo -u "$RUSER" /bin/cat "$PCONF" > "$PROFILE_TMP" 2>/dev/null || {
        echo "BADCONFIG: that config could not be read safely"; exit 8
    }
    PARSED=$("$VPNPARSE" wg-config "$PROFILE_TMP" "$WGSET" 2>&1) || { echo "BADCONFIG: $PARSED"; exit 8; }
    CLIENT_IP=$(echo "$PARSED" | awk '{print $1}')
    LABEL=$(echo "$PARSED" | awk '{print $2}')
    ;;
*)
    echo "usage: up.sh <user> nord|profile <arg>"; exit 1 ;;
esac

[ -x "$DIR0/vpnrun" ] || { echo "vpnrun missing from engine"; exit 1; }
valid_ipv4 "$CLIENT_IP" || {
    echo "provider returned an invalid tunnel address" >&2
    exit 1
}

# Do not silently build VPNonly inside another full-device VPN. The selected
# provider endpoint itself must use a normal physical route; a foreign tunnel
# here means the outer WireGuard packets would be nested inside that product's
# routing and kill-switch policy.
if [ "$MODE" = "nord" ]; then
    OUTER_HOST="$STATION"
else
    case "$LABEL" in
        \[*\]:*) OUTER_HOST=${LABEL#\[}; OUTER_HOST=${OUTER_HOST%%\]*} ;;
        *) OUTER_HOST=${LABEL%:*} ;;
    esac
fi
OUTER_IF=$(/sbin/route -n get "$OUTER_HOST" 2>/dev/null |
    awk '/interface:/{print $2; exit}' || true)
case "$OUTER_IF" in
    utun*|ppp*|ipsec*)
        echo "CONFLICTVPN: another full-device VPN is active on $OUTER_IF" >&2
        exit 11
        ;;
esac

# One-time migration from the fixed utun9 engine. The executable path,
# root UID, complete command, and UAPI socket must all agree before we touch
# it. An arbitrary utun9 interface is never adopted or stopped.
LEGACY_PID=$(/usr/bin/pgrep -U 0 -f -x "$WG_GO utun9" 2>/dev/null |
    /usr/bin/head -n 1 || true)
if [ -n "$LEGACY_PID" ] && [ -S /var/run/wireguard/utun9.sock ] &&
   legacy_process_is_ours "$LEGACY_PID"; then
    stop_legacy_process "$LEGACY_PID"
    legacy_process_is_ours "$LEGACY_PID" && {
        echo "legacy VPNonly tunnel could not be stopped" >&2
        exit 1
    }
    rm -f /var/run/wireguard/utun9.sock
    tries=0
    while ifconfig utun9 >/dev/null 2>&1 && [ "$tries" -lt 20 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    if ifconfig utun9 >/dev/null 2>&1; then
        echo "legacy VPNonly interface did not disappear" >&2
        exit 1
    fi
fi

mkdir -m 700 "$STATE_DIR"
STATE_CREATED=1
chown root:wheel "$STATE_DIR"
chmod 700 "$STATE_DIR"
safe_root_dir "$STATE_DIR" || {
    echo "couldn't create safe VPNonly runtime state" >&2
    exit 1
}

write_setup_state() {
    local name="$1" value="$2" tmp
    safe_root_dir "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/.$name.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp"
    chmod 600 "$tmp"
    chown root:wheel "$tmp"
    mv -f "$tmp" "$STATE_DIR/.$name"
}

# `utun` asks the kernel to choose an unused number atomically. The name file
# is written by wireguard-go after allocation; -f keeps the exact PID we start
# as the long-lived process, so teardown never needs a broad pkill pattern.
NAME_TMP=$(mktemp "$STATE_DIR/.interface-name.XXXXXX")
chmod 600 "$NAME_TMP"
chown root:wheel "$NAME_TMP"
MANAGING_NEW=1
# WG_NAT_SOURCE makes the bundled wireguard-go rewrite each packet's inner
# IPv4 source to the tunnel address. PF cannot do this itself: macOS
# evaluates translation rules against the interface the OS originally chose,
# so a route-to'd packet skips them and arrives with the LAN source, which
# providers that enforce cryptokey routing (Mullvad, Proton, stock servers)
# silently drop. NordLynx NATs any inner source, which hid this for months.
WG_TUN_NAME_FILE="$NAME_TMP" WG_NAT_SOURCE="$CLIENT_IP" /usr/bin/nohup "$WG_GO" -f utun \
    </dev/null >/dev/null 2>&1 &
NEW_PID=$!
write_setup_state setup-pid "$NEW_PID"

tries=0
while [ ! -s "$NAME_TMP" ] && [ "$tries" -lt 50 ]; do
    kill -0 "$NEW_PID" 2>/dev/null || {
        echo "wireguard-go exited before creating an interface" >&2
        abort_new_tunnel 1
    }
    /bin/sleep 0.1
    tries=$((tries + 1))
done
[ -s "$NAME_TMP" ] || {
    echo "wireguard-go did not report its interface" >&2
    abort_new_tunnel 1
}
NEW_IF=$(cat "$NAME_TMP")
valid_interface "$NEW_IF" || {
    echo "wireguard-go reported an invalid interface" >&2
    abort_new_tunnel 1
}
process_is_ours "$NEW_PID" || {
    echo "wireguard-go process identity could not be verified" >&2
    abort_new_tunnel 1
}
write_setup_state setup-interface "$NEW_IF"

tries=0
while { [ ! -S "/var/run/wireguard/$NEW_IF.sock" ] ||
        ! ifconfig "$NEW_IF" >/dev/null 2>&1 ||
        ! "$WG" show "$NEW_IF" >/dev/null 2>&1; } && [ "$tries" -lt 50 ]; do
    process_is_ours "$NEW_PID" || {
        echo "wireguard-go stopped during setup" >&2
        abort_new_tunnel 1
    }
    /bin/sleep 0.1
    tries=$((tries + 1))
done
[ -S "/var/run/wireguard/$NEW_IF.sock" ] &&
    ifconfig "$NEW_IF" >/dev/null 2>&1 &&
    "$WG" show "$NEW_IF" >/dev/null 2>&1 || {
        echo "wireguard-go control socket was not ready" >&2
        abort_new_tunnel 1
    }

"$WG" setconf "$NEW_IF" "$WGSET"
ifconfig "$NEW_IF" inet "$CLIENT_IP" "$CLIENT_IP" netmask 255.255.255.255 mtu 1420 up

# A local utun is not a connection. Temporarily use a one-second keepalive to
# force a WireGuard initiation, and do not publish ownership state or report
# Connected until the provider has completed a handshake.
#
# One dead server should not become a dialog the user has to read. The provider
# handed back several; try the next before giving up. Reconfiguring the peer on
# the interface we already own is enough — there is no need to tear the tunnel
# down, so ownership state and the interface name stay put across attempts.
CANDIDATE_COUNT=$(printf '%s\n' "$CANDIDATES" | /usr/bin/awk 'NF == 3 { n++ } END { print n + 0 }')
[ "$CANDIDATE_COUNT" -le 3 ] 2>/dev/null || CANDIDATE_COUNT=3
[ "$CANDIDATE_COUNT" -ge 1 ] 2>/dev/null || CANDIDATE_COUNT=1

ATTEMPT=1
LATEST=0
while : ; do
    PEERS=$("$WG" show "$NEW_IF" peers 2>/dev/null)
    [ -n "$PEERS" ] || {
        echo "NOHANDSHAKE: provider configuration has no WireGuard peer" >&2
        abort_new_tunnel 12
    }
    for pk in $PEERS; do
        "$WG" set "$NEW_IF" peer "$pk" persistent-keepalive 1
    done

    # 8s per candidate. A WireGuard handshake is a single round trip, so this is
    # already generous, and three of them still beat one 12s wait end to end.
    LATEST=0
    tries=0
    while [ "$LATEST" -eq 0 ] 2>/dev/null && [ "$tries" -lt 80 ]; do
        LATEST=$("$WG" show "$NEW_IF" latest-handshakes 2>/dev/null |
            awk 'NF == 2 && $2 ~ /^[0-9]+$/ && $2 > latest { latest=$2 }
                 END { print latest + 0 }' || echo 0)
        [ "$LATEST" -gt 0 ] 2>/dev/null && break
        process_is_ours "$NEW_PID" || {
            echo "WireGuard stopped while contacting the provider" >&2
            abort_new_tunnel 1
        }
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    [ "$LATEST" -gt 0 ] 2>/dev/null && break

    # Out of attempts, or nothing left to fall back to (an imported profile
    # names exactly one server, so it fails here on the first pass).
    [ "$ATTEMPT" -lt "$CANDIDATE_COUNT" ] || {
        echo "NOHANDSHAKE: the VPN server did not answer" >&2
        abort_new_tunnel 12
    }

    ATTEMPT=$((ATTEMPT + 1))
    NEXT=$(printf '%s\n' "$CANDIDATES" |
        /usr/bin/awk -v want="$ATTEMPT" 'NF == 3 { n++; if (n == want) { print; exit } }')
    [ -n "$NEXT" ] || {
        echo "NOHANDSHAKE: the VPN server did not answer" >&2
        abort_new_tunnel 12
    }
    NHOST=""; NSTATION=""; NPUBKEY=""
    read -r NHOST NSTATION NPUBKEY <<< "$NEXT"
    [ -n "${NPUBKEY:-}" ] || {
        echo "NOHANDSHAKE: the VPN server did not answer" >&2
        abort_new_tunnel 12
    }
    echo "RETRY: $LABEL did not answer, trying $NHOST" >&2
    write_nord_peer "$NSTATION" "$NPUBKEY"
    "$WG" setconf "$NEW_IF" "$WGSET"
    LABEL="$NHOST"
done

# Once verified, use the conventional 25-second keepalive to preserve NAT
# mappings without turning health checks into unnecessary traffic.
for pk in $PEERS; do
    "$WG" set "$NEW_IF" peer "$pk" persistent-keepalive 25 2>/dev/null || true
done

process_is_ours "$NEW_PID" &&
    [ -S "/var/run/wireguard/$NEW_IF.sock" ] &&
    "$WG" show "$NEW_IF" >/dev/null 2>&1 || {
        echo "WireGuard tunnel did not survive configuration" >&2
        abort_new_tunnel 1
    }

case "$LABEL" in ''|*[[:space:]]*)
    echo "provider returned an unsafe host label" >&2
    abort_new_tunnel 1
    ;;
esac

atomic_state_write() {
    local name="$1" value="$2" tmp
    safe_root_dir "$STATE_DIR" || return 1
    tmp=$(mktemp "$STATE_DIR/.$name.XXXXXX") || return 1
    printf '%s\n' "$value" > "$tmp" || return 1
    chmod 600 "$tmp" || return 1
    chown root:wheel "$tmp" || return 1
    mv -f "$tmp" "$STATE_DIR/$name"
}

# Commit the interface last. Its presence means all other root-only fields are
# complete, and no state is published until configuration has fully succeeded.
atomic_state_write pid "$NEW_PID"
atomic_state_write client-ip "$CLIENT_IP"
atomic_state_write host "$LABEL"
atomic_state_write interface "$NEW_IF"
/bin/rm -f "$STATE_DIR/.setup-pid" "$STATE_DIR/.setup-interface"
STATE_COMMITTED=1
MANAGING_NEW=0
echo "CONNECTED interface=$NEW_IF host=$LABEL"
