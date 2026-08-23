#!/bin/bash
# usage: group.sh <user> <vpn_xxxx>
# Ensures a dedicated group exists for one app. Prints its gid.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

[ "$(id -u)" = 0 ] || { echo "must run as root"; exit 1; }
RUSER="${1:?usage: group.sh <user> <group>}"
GROUP="${2:?usage: group.sh <user> <group>}"
[ "$RUSER" != "root" ] || { echo "refusing to operate for root"; exit 1; }
case "$RUSER" in *[!A-Za-z0-9._-]*) echo "refusing odd username"; exit 1 ;; esac

# Refuse to act on behalf of a different account than the one that invoked us:
# without this, the passwordless rule would let a user run programs as someone
# else, or point the tunnel at another account's key material.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [ "$RUSER" != "$SUDO_USER" ]; then
    echo "refusing: asked to act for '$RUSER' but invoked by '$SUDO_USER'"; exit 1
fi

case "$GROUP" in
    vpn_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "invalid VPNonly group"; exit 1 ;;
esac

# Group IDs are the security identity PF actually matches. Serialize their
# allocation globally so two passwordless calls cannot choose the same GID
# and silently make two apps share one routing identity.
STATE_ROOT=/var/run/vpnonly
GROUP_LOCK="$STATE_ROOT/.group-lock"
safe_root_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -f '%u:%g:%Lp' "$1" 2>/dev/null)" = "0:0:700" ]
}
safe_lock_file() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -f '%u:%g:%Lp' "$1" 2>/dev/null)" = "0:0:600" ]
}
if [ -e "$STATE_ROOT" ] || [ -L "$STATE_ROOT" ]; then
    safe_root_dir "$STATE_ROOT" || { echo "unsafe VPNonly runtime directory"; exit 1; }
else
    mkdir -m 700 "$STATE_ROOT"
    chown root:wheel "$STATE_ROOT"
    chmod 700 "$STATE_ROOT"
fi

LOCK_HELD=0
release_group_lock() {
    if [ "$LOCK_HELD" -eq 1 ] && safe_lock_file "$GROUP_LOCK" &&
       [ "$(cat "$GROUP_LOCK" 2>/dev/null)" = "$$" ]; then
        rm -f "$GROUP_LOCK"
    fi
}
trap release_group_lock EXIT
tries=0
while ! /usr/bin/shlock -p $$ -f "$GROUP_LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || { echo "BUSY: another VPNonly app identity is being created"; exit 9; }
    /bin/sleep 0.1
done
LOCK_HELD=1
safe_lock_file "$GROUP_LOCK" || { echo "unsafe VPNonly group lock"; exit 1; }

gid_is_unique() {
    dscl . -list /Groups PrimaryGroupID 2>/dev/null |
        awk -v wanted_gid="$1" -v wanted_group="$2" '
            $2 == wanted_gid { count++; if ($1 != wanted_group) bad=1 }
            END { exit !(count == 1 && !bad) }
        '
}

if GID=$(dscl . -read "/Groups/$GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}') && [ -n "${GID:-}" ]; then
    case "$GID" in ""|*[!0-9]*) echo "invalid existing group id"; exit 1 ;; esac
    [ "$GID" -ge 7100 ] && [ "$GID" -lt 7900 ] ||
        { echo "existing group id is outside VPNonly's range"; exit 1; }
    gid_is_unique "$GID" "$GROUP" ||
        { echo "VPNonly group id collides with another group"; exit 1; }
    echo "GID $GID"
    exit 0
fi

# allocate from a private range so we never collide with system or user ids
USED=$(dscl . -list /Groups PrimaryGroupID | awk '$2>=7100 && $2<7900 {print $2}' | sort -n | tail -1)
GID=$(( ${USED:-7099} + 1 ))
[ "$GID" -lt 7900 ] || { echo "VPNonly group range is full"; exit 1; }
dseditgroup -o create -i "$GID" -r "VPNonly app group" "$GROUP" >/dev/null
CREATED_GID=$(dscl . -read "/Groups/$GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}') || {
    echo "couldn't verify the new VPNonly group"; exit 1
}
[ "$CREATED_GID" = "$GID" ] && gid_is_unique "$GID" "$GROUP" || {
    echo "new VPNonly group id was not unique"; exit 1
}
echo "GID $GID"
