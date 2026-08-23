#!/bin/bash
# usage: down.sh [user]
# Stops only the WireGuard process recorded in VPNonly's root-owned state.
# Firewall policy is managed separately by route.sh, so block-only rules can
# remain asserted throughout a reconnect.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

DIR0="$(cd "$(dirname "$0")" && pwd)"
WG="$DIR0/bin/wg"
WG_GO="$DIR0/bin/wireguard-go"

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
RUSER="${1:-${SUDO_USER:-}}"
[ -n "$RUSER" ] || { echo "usage: down.sh <user>"; exit 1; }
case "$RUSER" in *[!A-Za-z0-9._-]*) echo "refusing odd username: $RUSER"; exit 1 ;; esac
[ "$RUSER" != root ] || { echo "refusing to operate for root"; exit 1; }
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && [ "$RUSER" != "$SUDO_USER" ]; then
    echo "refusing: asked to act for '$RUSER' but invoked by '$SUDO_USER'"; exit 1
fi
[ -x "$WG" ] && [ -x "$WG_GO" ] || { echo "bundled WireGuard tools are missing"; exit 1; }

STATE_ROOT=/var/run/vpnonly
STATE="$STATE_ROOT/$RUSER"
LOCK_DIR="$STATE_ROOT/.lock-$RUSER"
LOCK_HELD=0
LOCK_PID_TMP=""

valid_interface() {
    case "$1" in utun[0-9]*) ;; *) return 1 ;; esac
    case "${1#utun}" in ''|*[!0-9]*) return 1 ;; esac
}

valid_pid() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 1 ] 2>/dev/null
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

remove_known_state() {
    safe_root_dir "$STATE" || return 1
    /bin/rm -f "$STATE/interface" "$STATE/pid" "$STATE/client-ip" "$STATE/host" \
               "$STATE/.setup-pid" "$STATE/.setup-interface" \
               "$STATE"/.setup-pid.* "$STATE"/.setup-interface.* \
               "$STATE"/.interface-name.* "$STATE"/.interface.* \
               "$STATE"/.pid.* "$STATE"/.client-ip.* "$STATE"/.host.*
    /bin/rmdir "$STATE"
}

root_process_has_command() {
    local pid="$1" expected="$2" uid command
    valid_pid "$pid" || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    uid=$(/bin/ps -ww -p "$pid" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]') || return 1
    [ "$uid" = 0 ] || return 1
    command=$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null) || return 1
    [ "$command" = "$expected" ]
}

process_is_ours() { root_process_has_command "$1" "$WG_GO -f utun"; }
legacy_process_is_ours() { root_process_has_command "$1" "$WG_GO utun9"; }

release_lock() {
    set +e
    [ -n "$LOCK_PID_TMP" ] && /bin/rm -f "$LOCK_PID_TMP"
    if [ "$LOCK_HELD" -eq 1 ] && safe_root_dir "$LOCK_DIR"; then
        if safe_state_file "$LOCK_DIR/pid" &&
           [ "$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ]; then
            /bin/rm -f "$LOCK_DIR/pid"
            /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
        elif [ ! -e "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ]; then
            # We created this directory but failed before publishing its PID.
            # No contender can own it, so do not strand a 30-second stale lock.
            /bin/rm -f "$LOCK_DIR"/.pid.*
            /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
        fi
    fi
}
trap release_lock EXIT

# Serialize start/stop. Without this, a stop arriving while up.sh is still
# configuring could report DISCONNECTED and then watch that in-flight start
# publish a tunnel a moment later.
if [ -e "$STATE_ROOT" ] || [ -L "$STATE_ROOT" ]; then
    safe_root_dir "$STATE_ROOT" || { echo "unsafe VPNonly runtime directory"; exit 1; }
else
    /bin/mkdir -m 700 "$STATE_ROOT" || exit 1
    /usr/sbin/chown root:wheel "$STATE_ROOT"
    /bin/chmod 700 "$STATE_ROOT"
fi
if ! /bin/mkdir -m 700 "$LOCK_DIR" 2>/dev/null; then
    safe_root_dir "$LOCK_DIR" || { echo "unsafe VPNonly operation lock"; exit 1; }
    if safe_state_file "$LOCK_DIR/pid"; then
        LOCK_PID=$(/bin/cat "$LOCK_DIR/pid") || exit 1
        if valid_pid "$LOCK_PID" && kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "BUSY: another VPNonly tunnel operation is running"; exit 9
        elif ! valid_pid "$LOCK_PID"; then
            LOCK_MTIME=$(/usr/bin/stat -f '%m' "$LOCK_DIR/pid" 2>/dev/null || echo 0)
            NOW=$(/bin/date +%s)
            if [ "$LOCK_MTIME" -gt 0 ] 2>/dev/null &&
               [ $((NOW - LOCK_MTIME)) -lt 30 ] 2>/dev/null; then
                echo "BUSY: another VPNonly tunnel operation is starting"; exit 9
            fi
        fi
    elif [ -e "$LOCK_DIR/pid" ] || [ -L "$LOCK_DIR/pid" ]; then
        echo "unsafe VPNonly operation lock state"; exit 1
    else
        LOCK_MTIME=$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || echo 0)
        NOW=$(/bin/date +%s)
        if [ "$LOCK_MTIME" -gt 0 ] 2>/dev/null &&
           [ $((NOW - LOCK_MTIME)) -lt 30 ] 2>/dev/null; then
            echo "BUSY: another VPNonly tunnel operation is starting"; exit 9
        fi
    fi
    /bin/rm -f "$LOCK_DIR/pid" "$LOCK_DIR"/.pid.*
    /bin/rmdir "$LOCK_DIR" 2>/dev/null || { echo "BUSY: another VPNonly tunnel operation is running"; exit 9; }
    /bin/mkdir -m 700 "$LOCK_DIR" 2>/dev/null || { echo "BUSY: another VPNonly tunnel operation is running"; exit 9; }
fi
LOCK_HELD=1
/usr/sbin/chown root:wheel "$LOCK_DIR"
/bin/chmod 700 "$LOCK_DIR"
safe_root_dir "$LOCK_DIR" || { echo "couldn't create safe VPNonly operation lock"; exit 1; }
LOCK_PID_TMP=$(/usr/bin/mktemp "$LOCK_DIR/.pid.XXXXXX") ||
    { echo "couldn't record VPNonly operation lock"; exit 1; }
printf '%s\n' "$$" > "$LOCK_PID_TMP" || exit 1
/bin/chmod 600 "$LOCK_PID_TMP" || exit 1
/usr/sbin/chown root:wheel "$LOCK_PID_TMP" || exit 1
/bin/mv -f "$LOCK_PID_TMP" "$LOCK_DIR/pid" || exit 1
LOCK_PID_TMP=""

IF=""
PID=""
LEGACY=0
PROVISIONAL=0
MISSING_OWNED_IF=0
MISSING_SOCKET_ID=""

if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    safe_root_dir "$STATE" || { echo "unsafe VPNonly tunnel state"; exit 1; }
    if safe_state_file "$STATE/interface" &&
       safe_state_file "$STATE/pid" &&
       safe_state_file "$STATE/client-ip" &&
       safe_state_file "$STATE/host"; then
        IF=$(/bin/cat "$STATE/interface") || exit 1
        PID=$(/bin/cat "$STATE/pid") || exit 1
        valid_interface "$IF" || { echo "invalid VPNonly interface state"; exit 1; }
        valid_pid "$PID" || { echo "invalid VPNonly process state"; exit 1; }
        SOCKET="/var/run/wireguard/$IF.sock"
        if ! process_is_ours "$PID"; then
            # A crash can leave a complete, trusted record after both the exact
            # process and its kernel interface are already gone. A SIGKILL can
            # leave only the root-owned UAPI socket behind; that is safe to
            # remove only while the recorded interface is absent.
            if ! /sbin/ifconfig "$IF" >/dev/null 2>&1; then
                if [ -e "$SOCKET" ] || [ -L "$SOCKET" ]; then
                    safe_root_socket "$SOCKET" || {
                        echo "unsafe stale VPNonly tunnel socket"; exit 1
                    }
                    /bin/rm -f "$SOCKET" || exit 1
                fi
                remove_known_state || { echo "couldn't clear stale VPNonly tunnel state"; exit 1; }
                echo "DISCONNECTED"
                exit 0
            fi
            echo "VPNonly tunnel ownership could not be verified"
            exit 1
        fi
        if /sbin/ifconfig "$IF" >/dev/null 2>&1; then
            [ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] &&
                [ "$(/usr/bin/stat -f '%u' "$SOCKET" 2>/dev/null)" = 0 ] &&
                "$WG" show "$IF" >/dev/null 2>&1 || {
                    echo "VPNonly tunnel socket could not be verified"; exit 1
                }
        else
            # status.sh deliberately calls this state down so the app can
            # fail closed and recover. The exact recorded daemon may still be
            # alive after a kernel/interface failure; stop that PID without
            # making a usable interface or UAPI socket a precondition.
            MISSING_OWNED_IF=1
            if [ -e "$SOCKET" ] || [ -L "$SOCKET" ]; then
                safe_root_socket "$SOCKET" || {
                    echo "unsafe socket for missing VPNonly interface"; exit 1
                }
                MISSING_SOCKET_ID=$(/usr/bin/stat -f '%d:%i' "$SOCKET" 2>/dev/null) || exit 1
            fi
        fi
    elif safe_state_file "$STATE/.setup-pid"; then
        # Recover an interrupted start before it had enough state to become
        # visible as Connected. The provisional root record still binds us to
        # the exact process, so no interface-name search is needed.
        PROVISIONAL=1
        PID=$(/bin/cat "$STATE/.setup-pid") || exit 1
        valid_pid "$PID" || { echo "invalid provisional VPNonly process"; exit 1; }
        if [ -e "$STATE/.setup-interface" ] || [ -L "$STATE/.setup-interface" ]; then
            safe_state_file "$STATE/.setup-interface" ||
                { echo "unsafe provisional VPNonly interface state"; exit 1; }
            IF=$(/bin/cat "$STATE/.setup-interface") || exit 1
            valid_interface "$IF" || { echo "invalid provisional VPNonly interface"; exit 1; }
            SOCKET="/var/run/wireguard/$IF.sock"
        else
            NAME_FILE=""
            for candidate in "$STATE"/.interface-name.*; do
                [ -e "$candidate" ] || [ -L "$candidate" ] || continue
                [ -z "$NAME_FILE" ] || { echo "ambiguous provisional VPNonly interface state"; exit 1; }
                safe_state_file "$candidate" || { echo "unsafe provisional VPNonly name state"; exit 1; }
                NAME_FILE="$candidate"
            done
            if [ -n "$NAME_FILE" ] && [ -s "$NAME_FILE" ]; then
                IF=$(/bin/cat "$NAME_FILE") || exit 1
                valid_interface "$IF" || { echo "invalid provisional VPNonly interface name"; exit 1; }
                SOCKET="/var/run/wireguard/$IF.sock"
            fi
        fi
        if ! process_is_ours "$PID" && /bin/kill -0 "$PID" 2>/dev/null; then
            wait_exec=0
            while /bin/kill -0 "$PID" 2>/dev/null &&
                  ! process_is_ours "$PID" && [ "$wait_exec" -lt 5 ]; do
                /bin/sleep 0.1
                wait_exec=$((wait_exec + 1))
            done
            if /bin/kill -0 "$PID" 2>/dev/null && ! process_is_ours "$PID"; then
                echo "BUSY: VPNonly tunnel setup is still starting"
                exit 9
            fi
        fi
        if ! process_is_ours "$PID"; then
            if [ -z "$IF" ] || ! /sbin/ifconfig "$IF" >/dev/null 2>&1; then
                if [ -n "${SOCKET:-}" ] && { [ -e "$SOCKET" ] || [ -L "$SOCKET" ]; }; then
                    safe_root_socket "$SOCKET" || {
                        echo "unsafe stale provisional VPNonly socket"; exit 1
                    }
                    /bin/rm -f "$SOCKET" || exit 1
                fi
                remove_known_state || { echo "couldn't clear stale provisional state"; exit 1; }
                echo "DISCONNECTED"
                exit 0
            fi
            echo "provisional VPNonly tunnel ownership could not be verified"
            exit 1
        fi
    else
        echo "incomplete VPNonly tunnel state"
        exit 1
    fi
else
    # One-time migration for the fixed-name engine. The full command, root UID,
    # installed binary path and UAPI socket must all agree; a foreign utun9 is
    # never adopted or touched.
    PID=$(/usr/bin/pgrep -U 0 -f -x "$WG_GO utun9" 2>/dev/null | /usr/bin/head -n 1 || true)
    if [ -n "$PID" ] && [ -S /var/run/wireguard/utun9.sock ] &&
       legacy_process_is_ours "$PID"; then
        IF=utun9
        SOCKET=/var/run/wireguard/utun9.sock
        LEGACY=1
    else
        echo "DISCONNECTED"
        exit 0
    fi
fi

if [ "$LEGACY" -eq 1 ]; then
    legacy_process_is_ours "$PID" || { echo "VPNonly tunnel ownership changed before teardown"; exit 1; }
else
    process_is_ours "$PID" || { echo "VPNonly tunnel ownership changed before teardown"; exit 1; }
fi
/bin/kill -TERM "$PID" 2>/dev/null || { echo "couldn't signal VPNonly's tunnel process"; exit 1; }

deadline=40
while [ "$deadline" -gt 0 ]; do
    if [ "$LEGACY" -eq 1 ]; then legacy_process_is_ours "$PID" || break
    else process_is_ours "$PID" || break
    fi
    /bin/sleep 0.1
    deadline=$((deadline - 1))
done

# Remove the UAPI socket only while the exact process originally validated is
# still alive. This asks wireguard-go to exit without risking a newly reused
# interface or PID.
still_ours=0
if [ "$LEGACY" -eq 1 ]; then legacy_process_is_ours "$PID" && still_ours=1
else process_is_ours "$PID" && still_ours=1
fi
if [ "$still_ours" -eq 1 ] && [ -n "${SOCKET:-}" ] &&
   [ "$MISSING_OWNED_IF" -eq 0 ]; then
    /bin/rm -f "$SOCKET" 2>/dev/null || true
    deadline=20
    while [ "$deadline" -gt 0 ]; do
        if [ "$LEGACY" -eq 1 ]; then legacy_process_is_ours "$PID" || break
        else process_is_ours "$PID" || break
        fi
        /bin/sleep 0.1
        deadline=$((deadline - 1))
    done
fi

if [ "$LEGACY" -eq 1 ]; then
    legacy_process_is_ours "$PID" && /bin/kill -KILL "$PID" 2>/dev/null || true
else
    process_is_ours "$PID" && /bin/kill -KILL "$PID" 2>/dev/null || true
fi

# SIGKILL is asynchronous. In the missing-interface recovery path there is no
# interface to wait on, so independently wait for the exact process identity
# to disappear before deciding that teardown failed or removing its record.
deadline=20
while [ "$deadline" -gt 0 ]; do
    if [ "$LEGACY" -eq 1 ]; then legacy_process_is_ours "$PID" || break
    else process_is_ours "$PID" || break
    fi
    /bin/sleep 0.1
    deadline=$((deadline - 1))
done

if [ -n "$IF" ]; then
    deadline=20
    while /sbin/ifconfig "$IF" >/dev/null 2>&1 && [ "$deadline" -gt 0 ]; do
        /bin/sleep 0.1
        deadline=$((deadline - 1))
    done
fi
if [ "$LEGACY" -eq 1 ]; then
    legacy_process_is_ours "$PID" && { echo "VPNonly's tunnel did not stop"; exit 1; }
else
    process_is_ours "$PID" && { echo "VPNonly's tunnel did not stop"; exit 1; }
fi
[ -n "$IF" ] && /sbin/ifconfig "$IF" >/dev/null 2>&1 &&
    { echo "VPNonly's tunnel interface did not disappear"; exit 1; }

if [ "$LEGACY" -eq 0 ]; then
    if [ "$MISSING_OWNED_IF" -eq 1 ] &&
       { [ -e "$SOCKET" ] || [ -L "$SOCKET" ]; }; then
        # Remove only the same root-owned socket observed before signalling.
        # A newly-created path could belong to a replacement process and is
        # never inferred to be ours merely from its interface name.
        [ -n "$MISSING_SOCKET_ID" ] && safe_root_socket "$SOCKET" &&
            [ "$(/usr/bin/stat -f '%d:%i' "$SOCKET" 2>/dev/null)" = "$MISSING_SOCKET_ID" ] || {
                echo "VPNonly tunnel socket changed during teardown"; exit 1
            }
        /bin/rm -f "$SOCKET" || exit 1
    fi
    remove_known_state || { echo "couldn't clear VPNonly tunnel state"; exit 1; }
fi
echo "DISCONNECTED"
