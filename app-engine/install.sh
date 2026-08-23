#!/bin/bash
# One-time privileged install: copies the engine to a root-owned location and
# adds a narrowly-scoped sudoers rule so the menu bar app can operate the
# tunnel without prompting for a password on every click.
#
# Security model: the engine directory is owned by root and not writable by
# any user, and the sudoers rule allows ONLY these exact scripts. The scripts
# refuse to operate for root, vpnrun refuses to launch anything as uid 0, and
# only groups named vpn_* can ever be created or routed.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

[ "$(id -u)" = 0 ] || { echo "install.sh must run as root" >&2; exit 1; }

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="/Library/Application Support/VPNonly/engine"

# The passwordless rule is granted to one named user, not to %admin: on a Mac
# with several admin accounts, a blanket rule would let any of them run these
# as root without a password.
INSTALL_USER="${1:-${SUDO_USER:-}}"
[ -n "$INSTALL_USER" ] || { echo "usage: install.sh <username>"; exit 1; }
case "$INSTALL_USER" in
    *[!A-Za-z0-9._-]*) echo "refusing odd username: $INSTALL_USER"; exit 1 ;;
esac
[ "$INSTALL_USER" != "root" ] || { echo "refusing to install for root"; exit 1; }
id "$INSTALL_USER" >/dev/null 2>&1 || { echo "no such user: $INSTALL_USER"; exit 1; }

STATE_ROOT=/var/run/vpnonly
INSTALL_LOCK="$STATE_ROOT/.lock-$INSTALL_USER"
INSTALL_LOCK_HELD=0
LOCK_PID_TMP=""
GLOBAL_INSTALL_LOCK="$STATE_ROOT/.install-lock"
GLOBAL_INSTALL_LOCK_HELD=0
GLOBAL_LOCK_PID_TMP=""
TMP=""
ACTIVE_RULES=""
ACTIVE_NAT=""
ACTIVE_CHILD_RULES=""
ACTIVE_CHILD_NAT=""
ACTIVE_GROUPS_FILE=""
ACTIVE_CHILD_GROUPS_FILE=""
LEGACY_GROUPS_FILE=""
GROUP_DIRECTORY=""
BLOCK_CONF=""
ROLLBACK_CONF=""
ROUTED_SNAPSHOT=""
TOKEN_SNAPSHOT=""
MERGED_SNAPSHOT=""
ROOT_GROUPS_SNAPSHOT=""
POST_RULES=""
POST_NAT=""
PRECOMMIT_RULES=""
PRECOMMIT_NAT=""
GROUPS_TMP=""
ROOT_TOKEN_TMP=""
REFS_BEFORE_FILE=""
REFS_AFTER_FILE=""
ENABLE_CAPTURE=""
TOKEN_PUBLISH_TMP=""
PF_ENABLE_STARTED=0
OWNER_TMP=""

safe_root_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -f '%u:%g:%Lp' "$1" 2>/dev/null)" = "0:0:700" ]
}

safe_root_file() {
    local path="$1" allow_empty="${2:-0}" max_size="${3:-128}" mode size
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -f '%u' "$path" 2>/dev/null)" = 0 ] || return 1
    mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
    case "$mode" in ""|*[!0-7]*) return 1 ;; esac
    [ $((8#$mode & 022)) -eq 0 ] || return 1
    size=$(stat -f '%z' "$path" 2>/dev/null) || return 1
    [ "$size" -le "$max_size" ] || return 1
    [ "$allow_empty" -eq 1 ] || [ "$size" -gt 0 ] || return 1
}

safe_root_owned_dir() {
    local path="$1" mode
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    [ "$(stat -f '%u:%g' "$path" 2>/dev/null)" = "0:0" ] || return 1
    mode=$(stat -f '%Lp' "$path" 2>/dev/null) || return 1
    case "$mode" in ""|*[!0-7]*) return 1 ;; esac
    [ $((8#$mode & 022)) -eq 0 ]
}

valid_pid() {
    case "$1" in ""|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 1 ] 2>/dev/null
}

read_vpnonly_sudoers_owner() {
    /usr/bin/awk '
        /^[[:space:]]*#(include|includedir)[[:space:]]/ { invalid=1; next }
        /^[[:space:]]*($|#)/ { next }
        $1 == "Cmnd_Alias" && $2 == "VPNONLY" && $3 == "=" {
            aliases++
            next
        }
        NF == 4 && $1 ~ /^[A-Za-z0-9._-]+$/ &&
        $2 == "ALL=(root)" && $3 == "NOPASSWD:" && $4 == "VPNONLY" {
            grantees++
            owner=$1
            next
        }
        { invalid=1 }
        END {
            if (!invalid && aliases == 1 && grantees == 1 && owner != "root") print owner
            else exit 1
        }' "$1"
}

resolve_install_owner_values() {
    local recorded="$1" sudoers="$2" dest_present="$3" sudoers_present="$4" requested="$5" resolved
    if [ -n "$recorded" ] && [ -n "$sudoers" ] && [ "$recorded" != "$sudoers" ]; then
        return 2
    fi
    resolved="$recorded"
    [ -n "$resolved" ] || resolved="$sudoers"
    if [ -n "$resolved" ] && [ "$resolved" != "$requested" ]; then
        return 3
    fi
    if [ -z "$resolved" ] && { [ "$dest_present" -eq 1 ] || [ "$sudoers_present" -eq 1 ]; }; then
        return 4
    fi
    printf '%s\n' "$resolved"
}

ensure_root_dir() {
    local path="$1"
    [ ! -L "$path" ] || { echo "Unsafe VPNonly runtime directory: $path" >&2; exit 1; }
    if [ ! -e "$path" ]; then mkdir -m 700 "$path"; fi
    [ -d "$path" ] && [ ! -L "$path" ] &&
        [ "$(stat -f '%u' "$path" 2>/dev/null)" = 0 ] || {
        echo "Unsafe VPNonly runtime directory: $path" >&2; exit 1
    }
    chown root:wheel "$path"
    chmod 700 "$path"
}

cleanup_install() {
    set +e
    for file in "$TMP" "$ACTIVE_RULES" "$ACTIVE_NAT" \
                "$ACTIVE_CHILD_RULES" "$ACTIVE_CHILD_NAT" \
                "$ACTIVE_GROUPS_FILE" "$ACTIVE_CHILD_GROUPS_FILE" \
                "$LEGACY_GROUPS_FILE" "$BLOCK_CONF" "$ROLLBACK_CONF" \
                "$GROUP_DIRECTORY" \
                "$ROUTED_SNAPSHOT" "$TOKEN_SNAPSHOT" "$MERGED_SNAPSHOT" "$ROOT_GROUPS_SNAPSHOT" \
                "$POST_RULES" "$POST_NAT" "$PRECOMMIT_RULES" "$PRECOMMIT_NAT" \
                "$GROUPS_TMP" "$REFS_BEFORE_FILE" \
                "$REFS_AFTER_FILE" "$ENABLE_CAPTURE" "$OWNER_TMP"; do
        [ -n "$file" ] && rm -f "$file"
    done
    # Once pfctl -E has started, these files are the only evidence of a token
    # that may already be live. A signal must preserve them for retry/reboot;
    # only a confirmed -X or a fully published primary token makes deletion safe.
    if [ "$PF_ENABLE_STARTED" -eq 0 ]; then
        [ -n "$ROOT_TOKEN_TMP" ] && rm -f "$ROOT_TOKEN_TMP"
        [ -n "$TOKEN_PUBLISH_TMP" ] && rm -f "$TOKEN_PUBLISH_TMP"
    fi
    [ -n "$LOCK_PID_TMP" ] && rm -f "$LOCK_PID_TMP"
    if [ "$INSTALL_LOCK_HELD" -eq 1 ] && safe_root_dir "$INSTALL_LOCK"; then
        if safe_root_file "$INSTALL_LOCK/pid" 0 32 &&
           [ "$(cat "$INSTALL_LOCK/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$INSTALL_LOCK/pid"
            rmdir "$INSTALL_LOCK" 2>/dev/null || true
        elif [ ! -e "$INSTALL_LOCK/pid" ] && [ ! -L "$INSTALL_LOCK/pid" ]; then
            rm -f "$INSTALL_LOCK"/.pid.*
            rmdir "$INSTALL_LOCK" 2>/dev/null || true
        fi
    fi
    [ -n "$GLOBAL_LOCK_PID_TMP" ] && rm -f "$GLOBAL_LOCK_PID_TMP"
    if [ "$GLOBAL_INSTALL_LOCK_HELD" -eq 1 ] && safe_root_dir "$GLOBAL_INSTALL_LOCK"; then
        if safe_root_file "$GLOBAL_INSTALL_LOCK/pid" 0 32 &&
           [ "$(cat "$GLOBAL_INSTALL_LOCK/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$GLOBAL_INSTALL_LOCK/pid"
            rmdir "$GLOBAL_INSTALL_LOCK" 2>/dev/null || true
        elif [ ! -e "$GLOBAL_INSTALL_LOCK/pid" ] && [ ! -L "$GLOBAL_INSTALL_LOCK/pid" ]; then
            rm -f "$GLOBAL_INSTALL_LOCK"/.pid.*
            rmdir "$GLOBAL_INSTALL_LOCK" 2>/dev/null || true
        fi
    fi
}
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The engine and sudoers entry are machine-global. Take this lock before the
# per-user operation lock so two accounts can never race to become the owner.
ensure_root_dir "$STATE_ROOT"
if ! mkdir -m 700 "$GLOBAL_INSTALL_LOCK" 2>/dev/null; then
    safe_root_dir "$GLOBAL_INSTALL_LOCK" || {
        echo "Unsafe VPNonly global install lock" >&2; exit 1
    }
    if safe_root_file "$GLOBAL_INSTALL_LOCK/pid" 0 32; then
        GLOBAL_LOCK_PID=$(cat "$GLOBAL_INSTALL_LOCK/pid") || exit 1
        valid_pid "$GLOBAL_LOCK_PID" || {
            echo "Unsafe VPNonly global install lock state" >&2; exit 1
        }
        if kill -0 "$GLOBAL_LOCK_PID" 2>/dev/null; then
            echo "BUSY: another VPNonly install is running" >&2
            exit 9
        fi
    elif [ -e "$GLOBAL_INSTALL_LOCK/pid" ] || [ -L "$GLOBAL_INSTALL_LOCK/pid" ]; then
        echo "Unsafe VPNonly global install lock state" >&2
        exit 1
    else
        GLOBAL_LOCK_MTIME=$(stat -f '%m' "$GLOBAL_INSTALL_LOCK" 2>/dev/null) || {
            echo "Unsafe VPNonly global install lock state" >&2; exit 1
        }
        NOW=$(date +%s) || exit 1
        case "$GLOBAL_LOCK_MTIME:$NOW" in
            *[!0-9:]*) echo "Unsafe VPNonly global install lock state" >&2; exit 1 ;;
        esac
        if [ $((NOW - GLOBAL_LOCK_MTIME)) -lt 30 ]; then
            echo "BUSY: another VPNonly install is starting" >&2
            exit 9
        fi
    fi
    rm -f "$GLOBAL_INSTALL_LOCK/pid" "$GLOBAL_INSTALL_LOCK"/.pid.*
    rmdir "$GLOBAL_INSTALL_LOCK" 2>/dev/null || {
        echo "BUSY: another VPNonly install is running" >&2; exit 9
    }
    mkdir -m 700 "$GLOBAL_INSTALL_LOCK" 2>/dev/null || {
        echo "BUSY: another VPNonly install is running" >&2; exit 9
    }
fi
GLOBAL_INSTALL_LOCK_HELD=1
chown root:wheel "$GLOBAL_INSTALL_LOCK"
chmod 700 "$GLOBAL_INSTALL_LOCK"
safe_root_dir "$GLOBAL_INSTALL_LOCK" || {
    echo "Could not create a safe VPNonly global install lock" >&2; exit 1
}
GLOBAL_LOCK_PID_TMP=$(mktemp "$GLOBAL_INSTALL_LOCK/.pid.XXXXXX")
printf '%s\n' "$$" > "$GLOBAL_LOCK_PID_TMP"
chmod 600 "$GLOBAL_LOCK_PID_TMP"
chown root:wheel "$GLOBAL_LOCK_PID_TMP"
mv -f "$GLOBAL_LOCK_PID_TMP" "$GLOBAL_INSTALL_LOCK/pid"
GLOBAL_LOCK_PID_TMP=""

# Serialize the migration with this user's up.sh, down.sh, and route.sh. In
# particular, no route declaration can be overwritten by the v10 handoff after
# the app has already moved on to a newer tunnel state.
if ! mkdir -m 700 "$INSTALL_LOCK" 2>/dev/null; then
    safe_root_dir "$INSTALL_LOCK" || { echo "Unsafe VPNonly operation lock" >&2; exit 1; }
    if safe_root_file "$INSTALL_LOCK/pid" 0 32; then
        LOCK_PID=$(cat "$INSTALL_LOCK/pid") || exit 1
        valid_pid "$LOCK_PID" || { echo "Unsafe VPNonly operation lock" >&2; exit 1; }
        if kill -0 "$LOCK_PID" 2>/dev/null; then
            echo "BUSY: another VPNonly operation is running" >&2
            exit 9
        fi
    elif [ -e "$INSTALL_LOCK/pid" ] || [ -L "$INSTALL_LOCK/pid" ]; then
        echo "Unsafe VPNonly operation lock state" >&2
        exit 1
    else
        LOCK_MTIME=$(stat -f '%m' "$INSTALL_LOCK" 2>/dev/null) || {
            echo "Unsafe VPNonly operation lock state" >&2; exit 1
        }
        NOW=$(date +%s) || exit 1
        case "$LOCK_MTIME:$NOW" in
            *[!0-9:]*) echo "Unsafe VPNonly operation lock state" >&2; exit 1 ;;
        esac
        if [ $((NOW - LOCK_MTIME)) -lt 30 ]; then
            echo "BUSY: another VPNonly operation is starting" >&2
            exit 9
        fi
    fi
    rm -f "$INSTALL_LOCK/pid" "$INSTALL_LOCK"/.pid.*
    rmdir "$INSTALL_LOCK" 2>/dev/null || { echo "BUSY: another VPNonly operation is running" >&2; exit 9; }
    mkdir -m 700 "$INSTALL_LOCK" 2>/dev/null || { echo "BUSY: another VPNonly operation is running" >&2; exit 9; }
fi
INSTALL_LOCK_HELD=1
chown root:wheel "$INSTALL_LOCK"
chmod 700 "$INSTALL_LOCK"
LOCK_PID_TMP=$(mktemp "$INSTALL_LOCK/.pid.XXXXXX")
printf '%s\n' "$$" > "$LOCK_PID_TMP"
chmod 600 "$LOCK_PID_TMP"
chown root:wheel "$LOCK_PID_TMP"
mv -f "$LOCK_PID_TMP" "$INSTALL_LOCK/pid"
LOCK_PID_TMP=""

# Resolve the one machine owner only after both locks are published. VERSION
# 10 did not have OWNER, so its root-owned sudoers grantee is the migration
# identity. New installs record OWNER early enough for a partial retry to be
# attributable without trusting the invoking account.
INSTALL_ROOT="/Library/Application Support/VPNonly"
OWNER_FILE="$DEST/OWNER"
VERSION_FILE="$DEST/VERSION"
SUDOERS_FILE=/etc/sudoers.d/vpnonly
DEST_PRESENT=0
SUDOERS_PRESENT=0
RECORDED_OWNER=""
SUDOERS_OWNER=""
INSTALLED_VERSION=""

if [ -e "$INSTALL_ROOT" ] || [ -L "$INSTALL_ROOT" ]; then
    safe_root_owned_dir "$INSTALL_ROOT" || {
        echo "Existing VPNonly install directory is unsafe." >&2
        exit 1
    }
fi
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    safe_root_owned_dir "$DEST" || {
        echo "Existing VPNonly engine directory is unsafe." >&2
        exit 1
    }
    DEST_PRESENT=1

    if [ -e "$OWNER_FILE" ] || [ -L "$OWNER_FILE" ]; then
        safe_root_file "$OWNER_FILE" 0 1024 &&
        [ "$(stat -f '%g' "$OWNER_FILE" 2>/dev/null)" = 0 ] || {
            echo "Existing VPNonly owner record is unsafe." >&2
            exit 1
        }
        RECORDED_OWNER=$(cat "$OWNER_FILE") || exit 1
        case "$RECORDED_OWNER" in
            ""|root|*[!A-Za-z0-9._-]*)
                echo "Existing VPNonly owner record is invalid." >&2
                exit 1
                ;;
        esac
    fi

    if [ -e "$VERSION_FILE" ] || [ -L "$VERSION_FILE" ]; then
        safe_root_file "$VERSION_FILE" 1 32 &&
        [ "$(stat -f '%g' "$VERSION_FILE" 2>/dev/null)" = 0 ] || {
            echo "Existing VPNonly version record is unsafe." >&2
            exit 1
        }
        INSTALLED_VERSION=$(cat "$VERSION_FILE") || exit 1
        case "$INSTALLED_VERSION" in
            ""|10|11) ;;
            *)
                echo "Existing VPNonly engine version is not supported by this installer." >&2
                exit 1
                ;;
        esac
    fi
fi

# The sudoers file is ownership evidence even if a prior install crashed before
# VERSION or OWNER was published. Accept only VPNonly's two-line shape with one
# named grantee; extra aliases/specs are ambiguity, not evidence.
if [ -e "$SUDOERS_FILE" ] || [ -L "$SUDOERS_FILE" ]; then
    safe_root_file "$SUDOERS_FILE" 0 65536 &&
    [ "$(stat -f '%u:%g:%Lp' "$SUDOERS_FILE" 2>/dev/null)" = "0:0:440" ] || {
        echo "Existing VPNonly sudoers entry is unsafe." >&2
        exit 1
    }
    /usr/sbin/visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1 || {
        echo "Existing VPNonly sudoers entry is invalid." >&2
        exit 1
    }
    SUDOERS_OWNER=$(read_vpnonly_sudoers_owner "$SUDOERS_FILE") || {
        echo "Existing VPNonly sudoers entry has no single recoverable owner." >&2
        exit 1
    }
    SUDOERS_PRESENT=1
fi

if RESOLVED_OWNER=$(resolve_install_owner_values "$RECORDED_OWNER" "$SUDOERS_OWNER" \
                    "$DEST_PRESENT" "$SUDOERS_PRESENT" "$INSTALL_USER"); then
    :
else
    OWNER_RESULT=$?
    case "$OWNER_RESULT" in
    2)
        echo "VPNonly owner records conflict; setup did not change the installation." >&2
        ;;
    3)
        EXISTING_OWNER="$RECORDED_OWNER"
        [ -n "$EXISTING_OWNER" ] || EXISTING_OWNER="$SUDOERS_OWNER"
        echo "VPNonly is already owned by '$EXISTING_OWNER', not '$INSTALL_USER'." >&2
        ;;
    4)
        echo "A partial VPNonly installation has no recoverable owner; setup stopped." >&2
        ;;
    *)
        echo "VPNonly ownership could not be resolved safely." >&2
        ;;
    esac
    exit 1
fi
if [ -n "$RESOLVED_OWNER" ]; then
    [ "$RESOLVED_OWNER" = "$INSTALL_USER" ] || {
        echo "VPNonly is already owned by '$RESOLVED_OWNER', not '$INSTALL_USER'." >&2
        exit 1
    }
fi

# A v10 route.sh did not know about this lock. Wait for any already-running
# root copy to leave before replacing the script or snapshotting main PF. Once
# the copy below lands, every new invocation observes the lock and exits busy.
legacy_route_running() {
    /bin/ps -axo pid=,uid=,command= 2>/dev/null | /usr/bin/awk -v self="$$" '
        $1 != self && $2 == 0 && $3 == "/bin/bash" &&
        index($0, "/Library/Application Support/VPNonly/engine/route.sh") { found=1 }
        END { exit(found ? 0 : 1) }'
}
wait_for_legacy_route() {
    local tries=0
    while legacy_route_running && [ "$tries" -lt 50 ]; do
        /bin/sleep 0.1
        tries=$((tries + 1))
    done
    if legacy_route_running; then
        echo "An older VPNonly firewall update is still running; setup can be retried." >&2
        exit 1
    fi
    return 0
}
wait_for_legacy_route

mkdir -p "$DEST/bin"
chown -R root:wheel "$INSTALL_ROOT"
chmod 755 "$INSTALL_ROOT" "$DEST" "$DEST/bin"
safe_root_owned_dir "$INSTALL_ROOT" && safe_root_owned_dir "$DEST" || {
    echo "Could not create a safe VPNonly engine directory." >&2
    exit 1
}

# Publish ownership before the bulk copy. If a later step is interrupted, the
# next globally serialized installer can attribute and safely retry the partial
# tree instead of adopting it for whichever account happens to run next.
OWNER_TMP=$(mktemp "$DEST/.OWNER.XXXXXX")
printf '%s\n' "$INSTALL_USER" > "$OWNER_TMP"
chown root:wheel "$OWNER_TMP"
chmod 0644 "$OWNER_TMP"
mv -f "$OWNER_TMP" "$OWNER_FILE"
OWNER_TMP=""
safe_root_file "$OWNER_FILE" 0 1024 &&
[ "$(stat -f '%g' "$OWNER_FILE" 2>/dev/null)" = 0 ] &&
[ "$(cat "$OWNER_FILE")" = "$INSTALL_USER" ] || {
    echo "Could not verify VPNonly's owner record." >&2
    exit 1
}

cp "$SRC/up.sh" "$SRC/down.sh" "$SRC/run.sh" "$SRC/route.sh" "$SRC/group.sh" "$SRC/status.sh" "$SRC/uninstall.sh" "$DEST/"
cp "$SRC/THIRD-PARTY-NOTICES.txt" "$SRC/wireguard-tools-GPLv2.txt" "$SRC/wireguard-go-MIT.txt" "$DEST/" 2>/dev/null || true
cp "$SRC/vpnrun" "$DEST/vpnrun"
cp "$SRC/bin/wg" "$SRC/bin/wireguard-go" "$SRC/bin/vpnparse" "$DEST/bin/"
chown -R root:wheel "$INSTALL_ROOT"
chmod 755 "$INSTALL_ROOT" "$DEST" "$DEST/bin" "$DEST"/*.sh "$DEST/vpnrun" "$DEST/bin/"*
wait_for_legacy_route

TMP=$(mktemp)
cat > "$TMP" <<EOF
Cmnd_Alias VPNONLY = /Library/Application\\ Support/VPNonly/engine/up.sh *, /Library/Application\\ Support/VPNonly/engine/down.sh, /Library/Application\\ Support/VPNonly/engine/down.sh *, /Library/Application\\ Support/VPNonly/engine/run.sh *, /Library/Application\\ Support/VPNonly/engine/route.sh *, /Library/Application\\ Support/VPNonly/engine/group.sh *, /Library/Application\\ Support/VPNonly/engine/status.sh ""
$INSTALL_USER ALL=(root) NOPASSWD: VPNONLY
EOF
visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/vpnonly
rm -f "$TMP"
TMP=""

# VERSION 10 placed its generated policy directly in PF's main ruleset. This
# migration is deliberately self-contained instead of calling route.sh while
# holding the shared operation lock. It builds fail-closed child policy from
# every trustworthy source, prepares a direct-main rollback, and transfers the
# PF enable reference only after the child has survived the main handoff.
RHOME=$(dscl . -read "/Users/$INSTALL_USER" NFSHomeDirectory | awk '{print $2}')
case "$RHOME" in /*) ;; *) echo "Could not safely resolve this account's home directory." >&2; exit 1 ;; esac
INSTALL_UID=$(id -u "$INSTALL_USER")
LEGACY_CONF="$RHOME/.config/vpnonly"
PF_STATE="$STATE_ROOT/.pf-$INSTALL_USER"
ANCHOR=com.apple/vpnonly

ACTIVE_RULES=$(mktemp /var/run/vpnonly-install-active.XXXXXX)
chmod 600 "$ACTIVE_RULES"
/sbin/pfctl -s rules > "$ACTIVE_RULES" 2>/dev/null || {
    echo "Could not inspect the active PF rules before setup." >&2
    exit 1
}
ACTIVE_NAT=$(mktemp /var/run/vpnonly-install-nat.XXXXXX)
chmod 600 "$ACTIVE_NAT"
/sbin/pfctl -s nat > "$ACTIVE_NAT" 2>/dev/null || {
    echo "Could not inspect the active PF translation rules before setup." >&2
    exit 1
}
ACTIVE_CHILD_RULES=$(mktemp /var/run/vpnonly-install-child-rules.XXXXXX)
ACTIVE_CHILD_NAT=$(mktemp /var/run/vpnonly-install-child-nat.XXXXXX)
chmod 600 "$ACTIVE_CHILD_RULES" "$ACTIVE_CHILD_NAT"
/sbin/pfctl -a "$ANCHOR" -s rules > "$ACTIVE_CHILD_RULES" 2>/dev/null || {
    echo "Could not inspect VPNonly's existing PF child rules before setup." >&2
    exit 1
}
/sbin/pfctl -a "$ANCHOR" -s nat > "$ACTIVE_CHILD_NAT" 2>/dev/null || {
    echo "Could not inspect VPNonly's existing PF child translations before setup." >&2
    exit 1
}

# The fixed utun9 all-traffic NAT shape is distinctive to v10. It is not enough
# by itself to authorize a main-ruleset reload, but it is too dangerous to
# silently leave behind. A matching trusted generated snapshot below either
# proves ownership or makes setup stop and ask for a reboot.
ACTIVE_V10_NAT_IPS=$(/usr/bin/awk '
    $1 == "nat" && $2 == "on" && $3 == "utun9" && $4 == "inet" &&
    ((NF == 7 && $5 == "all" && $6 == "->") ||
     (NF == 10 && $5 == "from" && $6 == "any" && $7 == "to" &&
      $8 == "any" && $9 == "->")) &&
    $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $NF }' "$ACTIVE_NAT")
ACTIVE_V10_NAT_COUNT=$(printf '%s\n' "$ACTIVE_V10_NAT_IPS" |
    /usr/bin/awk 'NF { count++ } END { print count + 0 }')

LEGACY_HINT=0
LEGACY_PATH_HINT=0
for legacy_file in pf-merged.conf pf-token routed-groups; do
    if [ -e "$LEGACY_CONF/$legacy_file" ] || [ -L "$LEGACY_CONF/$legacy_file" ]; then
        LEGACY_HINT=1
        LEGACY_PATH_HINT=1
    fi
done
if [ -e "$PF_STATE/routed-groups" ] || [ -L "$PF_STATE/routed-groups" ] ||
   [ -e "$PF_STATE/pf-token" ] || [ -L "$PF_STATE/pf-token" ] ||
   [ -e "$PF_STATE/pf-token.pending" ] || [ -L "$PF_STATE/pf-token.pending" ]; then
    LEGACY_HINT=1
fi
for token_stage in "$PF_STATE"/.pf-token.*; do
    if [ -e "$token_stage" ] || [ -L "$token_stage" ]; then
        LEGACY_HINT=1
        break
    fi
done
[ "$ACTIVE_V10_NAT_COUNT" -gt 0 ] && LEGACY_HINT=1
[ -s "$ACTIVE_CHILD_RULES" ] && LEGACY_HINT=1
[ -s "$ACTIVE_CHILD_NAT" ] && LEGACY_HINT=1
/usr/bin/awk '
    { for (i=1; i<NF; i++) if ($i == "group") {
        value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
        if ((value ~ /^[0-9]+$/ && value >= 7100 && value < 7900) || value ~ /^vpn_/) print value
    } }' \
    "$ACTIVE_RULES" | /usr/bin/grep -q . && LEGACY_HINT=1 || true

if [ "$LEGACY_HINT" -eq 1 ]; then
    echo "Migrating VPNonly's older firewall policy…"

    LEGACY_DIR_ID=""
    if [ "$LEGACY_PATH_HINT" -eq 1 ]; then
        [ -d "$LEGACY_CONF" ] && [ ! -L "$LEGACY_CONF" ] || {
            echo "Legacy VPNonly state is behind an unsafe directory link." >&2
            exit 1
        }
        HOME_REAL=$(cd -P "$RHOME" 2>/dev/null && pwd) || {
            echo "Could not safely resolve this account's home directory." >&2
            exit 1
        }
        LEGACY_REAL=$(cd -P "$LEGACY_CONF" 2>/dev/null && pwd) || {
            echo "Could not safely resolve legacy VPNonly state." >&2
            exit 1
        }
        [ "$LEGACY_REAL" = "$HOME_REAL/.config/vpnonly" ] || {
            echo "Legacy VPNonly state is outside the account's physical config directory." >&2
            exit 1
        }
        LEGACY_DIR_UID=$(stat -f '%u' "$LEGACY_CONF" 2>/dev/null) || exit 1
        [ "$LEGACY_DIR_UID" = "$INSTALL_UID" ] || [ "$LEGACY_DIR_UID" = 0 ] || {
            echo "Legacy VPNonly state has an unexpected owner." >&2
            exit 1
        }
        LEGACY_DIR_MODE=$(stat -f '%Lp' "$LEGACY_CONF" 2>/dev/null) || exit 1
        case "$LEGACY_DIR_MODE" in ""|*[!0-7]*) echo "Legacy VPNonly state has an invalid mode." >&2; exit 1 ;; esac
        [ $((8#$LEGACY_DIR_MODE & 022)) -eq 0 ] || {
            echo "Legacy VPNonly state is writable by another account." >&2
            exit 1
        }
        LEGACY_DIR_ID=$(stat -f '%d:%i:%u:%g:%Lp' "$LEGACY_CONF" 2>/dev/null) || exit 1
    fi

    DEFAULT_IF=$(/sbin/route -n get default 2>/dev/null |
        /usr/bin/awk '/interface:/{print $2; exit}' || true)
    case "$DEFAULT_IF" in
        utun*|ppp*|ipsec*)
            echo "Disconnect the other full-device VPN before VPNonly upgrades its older firewall policy." >&2
            echo "Setup stopped before changing PF." >&2
            exit 1
            ;;
    esac

    # Snapshot root-owned legacy files into root-only runtime storage. The
    # containing config directory was user-writable in v10, so compare the
    # source inode before and after copying to catch a rename/symlink race.
    snapshot_root_file() {
        local source="$1" destination="$2" max_size="$3" before after
        safe_root_file "$source" 1 "$max_size" || return 1
        before=$(stat -f '%d:%i:%u:%g:%Lp:%z' "$source" 2>/dev/null) || return 1
        /bin/cp -p "$source" "$destination" || return 1
        after=$(stat -f '%d:%i:%u:%g:%Lp:%z' "$source" 2>/dev/null) || return 1
        [ "$before" = "$after" ] || return 1
        chown root:wheel "$destination" && chmod 600 "$destination"
    }
    snapshot_legacy() {
        local source="$1" destination="$2" max_size="$3"
        [ -n "$LEGACY_DIR_ID" ] &&
        [ "$(stat -f '%d:%i:%u:%g:%Lp' "$LEGACY_CONF" 2>/dev/null)" = "$LEGACY_DIR_ID" ] || return 1
        snapshot_root_file "$source" "$destination" "$max_size" || return 1
        [ "$(stat -f '%d:%i:%u:%g:%Lp' "$LEGACY_CONF" 2>/dev/null)" = "$LEGACY_DIR_ID" ]
    }

    if [ -e "$LEGACY_CONF/routed-groups" ] || [ -L "$LEGACY_CONF/routed-groups" ]; then
        ROUTED_SNAPSHOT=$(mktemp /var/run/vpnonly-legacy-groups.XXXXXX)
        snapshot_legacy "$LEGACY_CONF/routed-groups" "$ROUTED_SNAPSHOT" 32768 || {
            echo "Legacy VPNonly routing state is unsafe; setup stopped before changing PF." >&2
            exit 1
        }
    fi
    if [ -e "$LEGACY_CONF/pf-token" ] || [ -L "$LEGACY_CONF/pf-token" ]; then
        TOKEN_SNAPSHOT=$(mktemp /var/run/vpnonly-legacy-token.XXXXXX)
        snapshot_legacy "$LEGACY_CONF/pf-token" "$TOKEN_SNAPSHOT" 128 || {
            echo "Legacy VPNonly PF reference is unsafe; setup stopped before changing PF." >&2
            exit 1
        }
    fi
    if [ -e "$LEGACY_CONF/pf-merged.conf" ] || [ -L "$LEGACY_CONF/pf-merged.conf" ]; then
        MERGED_SNAPSHOT=$(mktemp /var/run/vpnonly-legacy-main.XXXXXX)
        snapshot_legacy "$LEGACY_CONF/pf-merged.conf" "$MERGED_SNAPSHOT" 1048576 || {
            echo "Legacy VPNonly main rules are unsafe; setup stopped before changing PF." >&2
            exit 1
        }
    fi
    if [ -e "$PF_STATE" ] || [ -L "$PF_STATE" ]; then
        safe_root_dir "$PF_STATE" || {
            echo "VPNonly's root retry state is unsafe; setup stopped before changing PF." >&2
            exit 1
        }
        if [ -e "$PF_STATE/routed-groups" ] || [ -L "$PF_STATE/routed-groups" ]; then
            ROOT_GROUPS_SNAPSHOT=$(mktemp /var/run/vpnonly-root-groups.XXXXXX)
            snapshot_root_file "$PF_STATE/routed-groups" "$ROOT_GROUPS_SNAPSHOT" 32768 || {
                echo "VPNonly's root routing retry state is unsafe; setup stopped before changing PF." >&2
                exit 1
            }
        fi
        STAGED_TOKEN_FILE=""
        STAGED_TOKEN_COUNT=0
        for token_stage in "$PF_STATE"/.pf-token.*; do
            [ -e "$token_stage" ] || [ -L "$token_stage" ] || continue
            safe_root_file "$token_stage" 0 128 || {
                echo "VPNonly has an incomplete PF reference; restart this Mac before retrying setup." >&2
                exit 1
            }
            STAGED_TOKEN_COUNT=$((STAGED_TOKEN_COUNT + 1))
            STAGED_TOKEN_FILE="$token_stage"
        done
        [ "$STAGED_TOKEN_COUNT" -le 1 ] || {
            echo "VPNonly has ambiguous staged PF references; restart this Mac before retrying setup." >&2
            exit 1
        }
        if [ "$STAGED_TOKEN_COUNT" -eq 1 ]; then
            if [ -e "$PF_STATE/pf-token.pending" ] || [ -L "$PF_STATE/pf-token.pending" ]; then
                echo "VPNonly has more than one pending PF reference; restart before retrying setup." >&2
                exit 1
            fi
            mv -f "$STAGED_TOKEN_FILE" "$PF_STATE/pf-token.pending" || {
                echo "Could not preserve VPNonly's staged PF reference." >&2
                exit 1
            }
        fi
    fi

    LEGACY_VPNG=()
    ACTIVE_VPNG=()
    LEGACY_COUNT=0
    ACTIVE_COUNT=0
    valid_group_name() {
        case "$1" in
            vpn_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;;
            *) return 1 ;;
        esac
    }
    add_group() {
        local candidate="$1" gid existing
        valid_group_name "$candidate" || {
            echo "Legacy VPNonly group '$candidate' is invalid; setup stopped before changing PF." >&2
            exit 1
        }
        gid=$(dscl . -read "/Groups/$candidate" PrimaryGroupID 2>/dev/null | awk '{print $2}') || {
            echo "Legacy VPNonly group '$candidate' no longer exists; setup stopped before changing PF." >&2
            exit 1
        }
        case "$gid" in ""|*[!0-9]*) echo "Legacy VPNonly group id is invalid." >&2; exit 1 ;; esac
        [ "$gid" -ge 7100 ] && [ "$gid" -lt 7900 ] || {
            echo "Legacy VPNonly group '$candidate' is outside the private gid range." >&2
            exit 1
        }
        for existing in "${LEGACY_VPNG[@]-}"; do [ "$existing" = "$candidate" ] && return 0; done
        LEGACY_VPNG[$LEGACY_COUNT]="$candidate"
        LEGACY_COUNT=$((LEGACY_COUNT + 1))
    }
    add_active_group() {
        local candidate="$1" existing
        add_group "$candidate"
        for existing in "${ACTIVE_VPNG[@]-}"; do [ "$existing" = "$candidate" ] && return 0; done
        ACTIVE_VPNG[$ACTIVE_COUNT]="$candidate"
        ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    }

    ACTIVE_GROUPS_FILE=$(mktemp /var/run/vpnonly-active-groups.XXXXXX)
    ACTIVE_CHILD_GROUPS_FILE=$(mktemp /var/run/vpnonly-active-child-groups.XXXXXX)
    LEGACY_GROUPS_FILE=$(mktemp /var/run/vpnonly-all-groups.XXXXXX)
    GROUP_DIRECTORY=$(mktemp /var/run/vpnonly-group-directory.XXXXXX)
    chmod 600 "$ACTIVE_GROUPS_FILE" "$ACTIVE_CHILD_GROUPS_FILE" \
        "$LEGACY_GROUPS_FILE" "$GROUP_DIRECTORY"
    dscl . -list /Groups PrimaryGroupID > "$GROUP_DIRECTORY" 2>/dev/null || {
        echo "Could not inspect local groups; setup stopped before changing PF." >&2
        exit 1
    }
    /usr/bin/awk '
        { for (i=1; i<NF; i++) if ($i == "group") {
            value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
            if ((value ~ /^[0-9]+$/ && value >= 7100 && value < 7900) || value ~ /^vpn_/) print value
        } }' \
        "$ACTIVE_RULES" > "$ACTIVE_GROUPS_FILE"
    while IFS= read -r active_value; do
        [ -n "$active_value" ] || continue
        case "$active_value" in
            *[!0-9]*) group="$active_value" ;;
            *)
                group=$(/usr/bin/awk -v wanted="$active_value" '$NF == wanted { print $1 }' "$GROUP_DIRECTORY")
                GROUP_MATCHES=$(printf '%s\n' "$group" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
                [ "$GROUP_MATCHES" -eq 1 ] || {
                    echo "Active VPNonly gid $active_value does not map to one trusted local group." >&2
                    echo "Setup stopped before changing PF." >&2
                    exit 1
                }
                ;;
        esac
        add_active_group "$group"
    done < "$ACTIVE_GROUPS_FILE"

    # A prior v11 route can have committed its child rules and PF token before
    # failing to publish routed-groups. Recover that kernel policy rather than
    # replacing it with an empty anchor and releasing its only enable reference.
    /usr/bin/awk '
        { for (i=1; i<NF; i++) if ($i == "group") {
            value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
            print value
        } }' "$ACTIVE_CHILD_RULES" > "$ACTIVE_CHILD_GROUPS_FILE"
    CHILD_GROUP_COUNT=$(/usr/bin/awk 'NF { count++ } END { print count + 0 }' \
        "$ACTIVE_CHILD_GROUPS_FILE")
    if { [ -s "$ACTIVE_CHILD_RULES" ] || [ -s "$ACTIVE_CHILD_NAT" ]; } &&
       [ "$CHILD_GROUP_COUNT" -eq 0 ]; then
        echo "VPNonly's existing PF child policy could not be recovered safely." >&2
        echo "Restart this Mac, then open VPNonly again." >&2
        exit 1
    fi
    while IFS= read -r child_value; do
        [ -n "$child_value" ] || continue
        case "$child_value" in
            *[!0-9]*) group="$child_value" ;;
            *)
                group=$(/usr/bin/awk -v wanted="$child_value" '$NF == wanted { print $1 }' "$GROUP_DIRECTORY")
                GROUP_MATCHES=$(printf '%s\n' "$group" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')
                [ "$GROUP_MATCHES" -eq 1 ] || {
                    echo "VPNonly child gid $child_value does not map to one trusted local group." >&2
                    echo "Setup stopped before changing PF." >&2
                    exit 1
                }
                ;;
        esac
        add_group "$group"
    done < "$ACTIVE_CHILD_GROUPS_FILE"

    if [ -n "$MERGED_SNAPSHOT" ]; then
        /usr/bin/awk '{ for (i=1; i<NF; i++) if ($i == "group" && $(i+1) ~ /^vpn_/) print $(i+1) }' \
            "$MERGED_SNAPSHOT" >> "$LEGACY_GROUPS_FILE"
    fi
    if [ -n "$ROUTED_SNAPSHOT" ]; then
        /usr/bin/awk '{ for (i=1; i<=NF; i++) print $i }' "$ROUTED_SNAPSHOT" >> "$LEGACY_GROUPS_FILE"
    fi
    if [ -n "$ROOT_GROUPS_SNAPSHOT" ]; then
        /usr/bin/awk '{ for (i=1; i<=NF; i++) print $i }' "$ROOT_GROUPS_SNAPSHOT" >> "$LEGACY_GROUPS_FILE"
    fi
    while IFS= read -r group; do [ -n "$group" ] && add_group "$group"; done < "$LEGACY_GROUPS_FILE"

    ACTIVE_LEGACY=0
    [ "$ACTIVE_COUNT" -gt 0 ] && ACTIVE_LEGACY=1
    # v10 also put a direct NAT rule in main whenever utun9 was up, even with
    # no routed groups. Only an exact IP match in the trusted generated file
    # proves it is ours. A suspicious orphan is left untouched and setup aborts
    # so reboot can clear runtime PF without claiming a successful migration.
    if [ "$ACTIVE_V10_NAT_COUNT" -gt 0 ]; then
        MERGED_V10_NAT_IPS=""
        if [ -n "$MERGED_SNAPSHOT" ]; then
            MERGED_V10_NAT_IPS=$(/usr/bin/awk '
                $1 == "nat" && $2 == "on" && $3 == "utun9" && $4 == "inet" &&
                NF == 10 && $5 == "from" && $6 == "any" && $7 == "to" &&
                $8 == "any" && $9 == "->" &&
                $10 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $10 }' \
                "$MERGED_SNAPSHOT")
        fi
        MERGED_V10_NAT_COUNT=$(printf '%s\n' "$MERGED_V10_NAT_IPS" |
            /usr/bin/awk 'NF { count++ } END { print count + 0 }')
        if [ "$ACTIVE_V10_NAT_COUNT" -ne 1 ] ||
           [ "$MERGED_V10_NAT_COUNT" -ne 1 ] ||
           [ "$ACTIVE_V10_NAT_IPS" != "$MERGED_V10_NAT_IPS" ]; then
            echo "A fixed-interface PF translation is active, but VPNonly cannot prove safe ownership." >&2
            echo "Restart this Mac, then open VPNonly again." >&2
            exit 1
        fi
        ACTIVE_LEGACY=1
    fi
    NVPNG=$LEGACY_COUNT

    if [ "$NVPNG" -gt 0 ]; then
        /usr/bin/grep -Eq '^[[:space:]]*anchor "com\.apple/\*" all[[:space:]]*$' "$ACTIVE_RULES" || {
            echo "The active PF rules do not expose the exact stock com.apple filter hook." >&2
            echo "Setup stopped before changing PF." >&2
            exit 1
        }
    fi

    # A live v10 main policy must have a trusted, parseable direct-main file
    # ready before it can be retired. If that rollback material is missing, a
    # reboot safely clears runtime PF policy and lets setup retry without it.
    if [ "$ACTIVE_LEGACY" -eq 1 ]; then
        [ -n "$MERGED_SNAPSHOT" ] || {
            echo "Active legacy VPNonly PF rules were found, but safe rollback material is missing." >&2
            echo "Restart this Mac, then open VPNonly again." >&2
            exit 1
        }
        ROLLBACK_CONF=$(mktemp /var/run/vpnonly-rollback.XXXXXX)
        /bin/cp "$MERGED_SNAPSHOT" "$ROLLBACK_CONF"
        chown root:wheel "$ROLLBACK_CONF"
        chmod 600 "$ROLLBACK_CONF"
        /sbin/pfctl -n -f "$ROLLBACK_CONF" >/dev/null 2>&1 || {
            echo "Legacy VPNonly rollback rules are invalid; setup stopped before changing PF." >&2
            exit 1
        }
        if [ "$ACTIVE_COUNT" -gt 0 ]; then
            for group in "${ACTIVE_VPNG[@]}"; do
                /usr/bin/grep -Fqx "block return out proto { tcp udp } from any to any group $group" "$ROLLBACK_CONF" || {
                    echo "Legacy VPNonly rollback rules do not protect every active group." >&2
                    echo "Setup stopped before changing PF." >&2
                    exit 1
                }
            done
        fi

        /sbin/pfctl -n -f /etc/pf.conf >/dev/null 2>&1 || {
            echo "Your saved PF configuration is invalid; legacy VPNonly policy was left in place." >&2
            exit 1
        }
        /usr/bin/grep -Eq '^[[:space:]]*anchor[[:space:]]+"com\.apple/\*"[[:space:]]*(all[[:space:]]*)?([#].*)?$' /etc/pf.conf &&
        /usr/bin/grep -Eq '^[[:space:]]*nat-anchor[[:space:]]+"com\.apple/\*"[[:space:]]*(all[[:space:]]*)?([#].*)?$' /etc/pf.conf || {
            echo "Your saved PF configuration does not contain VPNonly's exact stock anchor hooks." >&2
            echo "Legacy VPNonly policy was left in place." >&2
            exit 1
        }
    fi

    BLOCK_CONF=$(mktemp /var/run/vpnonly-migrate-block.XXXXXX)
    chmod 600 "$BLOCK_CONF"
    chown root:wheel "$BLOCK_CONF"
    if [ "$NVPNG" -gt 0 ]; then
        for group in "${LEGACY_VPNG[@]}"; do
            printf 'block drop out quick on ! lo0 from any to any group %s\n' "$group" >> "$BLOCK_CONF"
        done
    fi
    /sbin/pfctl -n -a "$ANCHOR" -f "$BLOCK_CONF" >/dev/null 2>&1 || {
        echo "VPNonly's migration block rules failed validation." >&2
        exit 1
    }

    ensure_root_dir "$PF_STATE"
    ROOT_TOKEN_FILE="$PF_STATE/pf-token"
    PENDING_TOKEN_FILE="$PF_STATE/pf-token.pending"
    HAS_ROOT_TOKEN=0
    ROOT_TOKEN=""
    EXTRA_TOKEN=""
    EXTRA_TOKEN_ACTIVE=0
    REFERENCES=$(/sbin/pfctl -s References 2>/dev/null) || {
        echo "Could not inspect PF enable references." >&2
        exit 1
    }
    PF_INFO=$(/sbin/pfctl -s info 2>/dev/null) || {
        echo "Could not inspect PF status." >&2
        exit 1
    }
    reference_is_active() {
        local token="$1"
        printf '%s\n' "$REFERENCES" | /usr/bin/awk -v wanted="$token" '
            {
                pid=substr($0, 1, 8); value=substr($0, 39, 24)
                gsub(/^[[:space:]]+/, "", pid); gsub(/[[:space:]]+$/, "", pid)
                gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                if (pid ~ /^[0-9]+$/ && value == wanted) found=1
            }
            END { exit(found ? 0 : 1) }'
    }
    if [ -e "$ROOT_TOKEN_FILE" ] || [ -L "$ROOT_TOKEN_FILE" ]; then
        safe_root_file "$ROOT_TOKEN_FILE" 0 128 || { echo "Unsafe VPNonly PF reference." >&2; exit 1; }
        ROOT_TOKEN=$(cat "$ROOT_TOKEN_FILE")
        case "$ROOT_TOKEN" in ""|*[!0-9]*) echo "Invalid VPNonly PF reference." >&2; exit 1 ;; esac
        if reference_is_active "$ROOT_TOKEN"; then
            printf '%s\n' "$PF_INFO" | grep -Eq '^Status:[[:space:]]+Enabled' || {
                echo "PF has a VPNonly reference but is disabled; setup stopped before changing PF." >&2
                exit 1
            }
            HAS_ROOT_TOKEN=1
        else
            rm -f "$ROOT_TOKEN_FILE"
            ROOT_TOKEN=""
        fi
    fi

    # A failed token-file publish leaves this fixed root-only recovery name.
    # Adopt a still-live reference, or retain a second one until the primary
    # reference and child blocks have both been revalidated below.
    if [ -e "$PENDING_TOKEN_FILE" ] || [ -L "$PENDING_TOKEN_FILE" ]; then
        safe_root_file "$PENDING_TOKEN_FILE" 0 128 || {
            echo "Unsafe pending VPNonly PF reference; restart this Mac before retrying setup." >&2
            exit 1
        }
        PENDING_TOKEN=$(cat "$PENDING_TOKEN_FILE")
        case "$PENDING_TOKEN" in ""|*[!0-9]*)
            echo "Invalid pending VPNonly PF reference; restart this Mac before retrying setup." >&2
            exit 1
            ;;
        esac
        if reference_is_active "$PENDING_TOKEN"; then
            printf '%s\n' "$PF_INFO" | grep -Eq '^Status:[[:space:]]+Enabled' || {
                echo "PF has a pending VPNonly reference but is disabled." >&2
                exit 1
            }
            if [ "$HAS_ROOT_TOKEN" -eq 0 ]; then
                mv -f "$PENDING_TOKEN_FILE" "$ROOT_TOKEN_FILE" || {
                    echo "Could not adopt VPNonly's pending PF reference." >&2
                    exit 1
                }
                ROOT_TOKEN="$PENDING_TOKEN"
                HAS_ROOT_TOKEN=1
            elif [ "$ROOT_TOKEN" = "$PENDING_TOKEN" ]; then
                rm -f "$PENDING_TOKEN_FILE"
            else
                EXTRA_TOKEN="$PENDING_TOKEN"
                EXTRA_TOKEN_ACTIVE=1
            fi
        else
            rm -f "$PENDING_TOKEN_FILE"
        fi
    fi

    LEGACY_TOKEN=""
    LEGACY_TOKEN_ACTIVE=0
    if [ -n "$TOKEN_SNAPSHOT" ]; then
        LEGACY_TOKEN=$(cat "$TOKEN_SNAPSHOT")
        case "$LEGACY_TOKEN" in ""|*[!0-9]*) echo "Legacy VPNonly PF reference is invalid." >&2; exit 1 ;; esac
        reference_is_active "$LEGACY_TOKEN" && LEGACY_TOKEN_ACTIVE=1 || true
    fi

    # A partially migrated machine should have distinct old and new references.
    # If both state files name the same still-live token, acquire a fresh root
    # reference before releasing the legacy one rather than disabling our own.
    if [ "$HAS_ROOT_TOKEN" -eq 1 ] && [ "$LEGACY_TOKEN_ACTIVE" -eq 1 ] &&
       [ "$ROOT_TOKEN" = "$LEGACY_TOKEN" ]; then
        rm -f "$ROOT_TOKEN_FILE"
        if [ "$EXTRA_TOKEN_ACTIVE" -eq 1 ]; then
            mv -f "$PENDING_TOKEN_FILE" "$ROOT_TOKEN_FILE" || {
                echo "Could not promote VPNonly's distinct pending PF reference." >&2
                exit 1
            }
            ROOT_TOKEN="$EXTRA_TOKEN"
            HAS_ROOT_TOKEN=1
            EXTRA_TOKEN=""
            EXTRA_TOKEN_ACTIVE=0
        else
            ROOT_TOKEN=""
            HAS_ROOT_TOKEN=0
        fi
    fi

    /sbin/pfctl -q -a "$ANCHOR" -f "$BLOCK_CONF" || {
        echo "Could not install VPNonly's fail-closed migration anchor." >&2
        exit 1
    }

    publish_pending_token() {
        local token="$1"
        case "$token" in ""|*[!0-9]*) return 1 ;; esac
        TOKEN_PUBLISH_TMP=$(mktemp "$PF_STATE/.pf-token.XXXXXX") || return 1
        chown root:wheel "$TOKEN_PUBLISH_TMP" || return 1
        chmod 600 "$TOKEN_PUBLISH_TMP" || return 1
        printf '%s\n' "$token" > "$TOKEN_PUBLISH_TMP" || return 1
        safe_root_file "$TOKEN_PUBLISH_TMP" 0 128 || return 1
        [ "$(cat "$TOKEN_PUBLISH_TMP" 2>/dev/null)" = "$token" ] || return 1
        mv -f "$TOKEN_PUBLISH_TMP" "$PENDING_TOKEN_FILE" || return 1
        TOKEN_PUBLISH_TMP=""
        ROOT_TOKEN_TMP="$PENDING_TOKEN_FILE"
    }

    release_or_retain_new_token() {
        local token="$1"
        if /sbin/pfctl -X "$token" >/dev/null 2>&1; then
            [ -n "$ROOT_TOKEN_TMP" ] && rm -f "$ROOT_TOKEN_TMP"
            [ -n "$TOKEN_PUBLISH_TMP" ] && rm -f "$TOKEN_PUBLISH_TMP"
            ROOT_TOKEN_TMP=""
            TOKEN_PUBLISH_TMP=""
            PF_ENABLE_STARTED=0
            return 0
        fi
        # Never overwrite the empty recovery sentinel in place: a short write
        # containing only a numeric prefix could look valid on retry while the
        # real active token was different. Publish a verified complete sibling
        # with one rename, or preserve the ambiguous files for reboot recovery.
        if publish_pending_token "$token"; then
            ROOT_TOKEN_TMP=""
            echo "VPNonly retained the active PF reference for a safe retry." >&2
            return 0
        fi
        # Leaving the empty sentinel and any root-only staging inode is safer
        # than deleting the last evidence of an untracked active reference.
        echo "CRITICAL: an active PF reference requires a restart before retrying setup" >&2
        ROOT_TOKEN_TMP=""
        TOKEN_PUBLISH_TMP=""
    }

    if [ "$NVPNG" -gt 0 ] && [ "$HAS_ROOT_TOKEN" -eq 0 ]; then
        # Create durable storage before incrementing PF's reference count. If
        # publication later fails and -X also fails, this file is retained under
        # the fixed pending name so the next install/uninstall can recover it.
        ROOT_TOKEN_TMP=$(mktemp "$PF_STATE/.pf-token.XXXXXX") || {
            echo "Could not prepare storage for VPNonly's PF enable reference." >&2
            exit 1
        }
        chmod 600 "$ROOT_TOKEN_TMP"
        chown root:wheel "$ROOT_TOKEN_TMP"
        mv -f "$ROOT_TOKEN_TMP" "$PENDING_TOKEN_FILE" || {
            echo "Could not prepare durable PF reference recovery state." >&2
            exit 1
        }
        ROOT_TOKEN_TMP="$PENDING_TOKEN_FILE"
        REFS_BEFORE_FILE=$(mktemp /var/run/vpnonly-refs-before.XXXXXX)
        REFS_AFTER_FILE=$(mktemp /var/run/vpnonly-refs-after.XXXXXX)
        ENABLE_CAPTURE=$(mktemp /var/run/vpnonly-enable-output.XXXXXX)
        chmod 600 "$REFS_BEFORE_FILE" "$REFS_AFTER_FILE" "$ENABLE_CAPTURE"
        /sbin/pfctl -s References > "$REFS_BEFORE_FILE" 2>/dev/null || {
            echo "Could not snapshot PF references before enabling." >&2
            exit 1
        }
        PF_ENABLE_STARTED=1
        /sbin/pfctl -E > "$ENABLE_CAPTURE" 2>&1 &
        ENABLE_PID=$!
        if ! wait "$ENABLE_PID"; then
            PF_ENABLE_STARTED=0
            rm -f "$ROOT_TOKEN_TMP"
            ROOT_TOKEN_TMP=""
            echo "Could not acquire VPNonly's PF enable reference." >&2
            exit 1
        fi
        ROOT_TOKEN=$(awk '/Token[[:space:]]*:/ {print $NF; exit}' "$ENABLE_CAPTURE")
        /sbin/pfctl -s References > "$REFS_AFTER_FILE" 2>/dev/null || {
            case "$ROOT_TOKEN" in
                ""|*[!0-9]*) ROOT_TOKEN_TMP="" ;;
                *) release_or_retain_new_token "$ROOT_TOKEN" ;;
            esac
            echo "PF enabled, but its new reference could not be inspected; restart before retrying." >&2
            exit 1
        }
        case "$ROOT_TOKEN" in ""|*[!0-9]*)
            # Defensive fallback for an OS output-format change: derive the one
            # reference added by this call. The PID-specific row disambiguates a
            # concurrent third-party PF enable when the table has the stock form.
            ROOT_TOKEN=$(/usr/bin/awk -v pid="$ENABLE_PID" '
                {
                    rowpid=substr($0, 1, 8); name=substr($0, 10, 28); value=substr($0, 39, 24)
                    gsub(/^[[:space:]]+/, "", rowpid); gsub(/[[:space:]]+$/, "", rowpid)
                    gsub(/^[[:space:]]+/, "", name); gsub(/[[:space:]]+$/, "", name)
                    gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                    if (rowpid == pid && name == "pfctl" && value ~ /^[0-9]+$/) print value
                }' \
                "$REFS_AFTER_FILE")
            CANDIDATE_COUNT=$(printf '%s\n' "$ROOT_TOKEN" |
                /usr/bin/awk 'NF { count++ } END { print count + 0 }')
            if [ "$CANDIDATE_COUNT" -ne 1 ]; then
                ROOT_TOKEN=$(/usr/bin/awk '
                    NR == FNR {
                        pid=substr($0, 1, 8); value=substr($0, 39, 24)
                        gsub(/^[[:space:]]+/, "", pid); gsub(/[[:space:]]+$/, "", pid)
                        gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                        if (pid ~ /^[0-9]+$/ && value ~ /^[0-9]+$/) old[value]=1
                        next
                    }
                    {
                        pid=substr($0, 1, 8); value=substr($0, 39, 24)
                        gsub(/^[[:space:]]+/, "", pid); gsub(/[[:space:]]+$/, "", pid)
                        gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                        if (pid ~ /^[0-9]+$/ && value ~ /^[0-9]+$/ && !old[value]) print value
                    }
                ' "$REFS_BEFORE_FILE" "$REFS_AFTER_FILE")
                CANDIDATE_COUNT=$(printf '%s\n' "$ROOT_TOKEN" |
                    /usr/bin/awk 'NF { count++ } END { print count + 0 }')
            fi
            [ "$CANDIDATE_COUNT" -eq 1 ] || {
                # The fixed empty pending file forces a conservative reboot on
                # retry instead of silently acquiring and stranding more refs.
                ROOT_TOKEN_TMP=""
                echo "PF enabled without one identifiable reference; restart before retrying setup." >&2
                exit 1
            }
            ;;
        esac
        /usr/bin/awk -v wanted="$ROOT_TOKEN" '
            {
                pid=substr($0, 1, 8); value=substr($0, 39, 24)
                gsub(/^[[:space:]]+/, "", pid); gsub(/[[:space:]]+$/, "", pid)
                gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                if (pid ~ /^[0-9]+$/ && value == wanted) found=1
            }
            END { exit(found ? 0 : 1) }' "$REFS_AFTER_FILE" || {
            release_or_retain_new_token "$ROOT_TOKEN"
            echo "PF did not retain VPNonly's newly acquired reference." >&2
            exit 1
        }
        if ! publish_pending_token "$ROOT_TOKEN"; then
            release_or_retain_new_token "$ROOT_TOKEN"
            echo "Could not store VPNonly's PF enable reference." >&2
            exit 1
        fi
        mv -f "$PENDING_TOKEN_FILE" "$ROOT_TOKEN_FILE" || {
            ROOT_TOKEN_TMP=""
            echo "Could not publish VPNonly's PF enable reference; restart before retrying." >&2
            exit 1
        }
        ROOT_TOKEN_TMP=""
        PF_ENABLE_STARTED=0
        HAS_ROOT_TOKEN=1
    fi

    verify_child_blocks() {
        local output group gid
        output=$(/sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null) || return 1
        for group in "${LEGACY_VPNG[@]}"; do
            gid=$(dscl . -read "/Groups/$group" PrimaryGroupID 2>/dev/null | awk '{print $2}') || return 1
            printf '%s\n' "$output" |
                /usr/bin/awk -v wanted="$gid" '
                    $1 == "block" { for (i=1; i<NF; i++) if ($i == "group") {
                        value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
                        if (value == wanted) found=1
                    } }
                    END { exit(found ? 0 : 1) }' || return 1
        done
    }
    if [ "$NVPNG" -gt 0 ]; then
        verify_child_blocks || { echo "VPNonly's fail-closed child rules were not active." >&2; exit 1; }
    fi

    rollback_after_commit() {
        echo "VPNonly could not verify the scoped policy after retiring v10; restoring its validated legacy main rules." >&2
        if /sbin/pfctl -q -f "$ROLLBACK_CONF"; then
            /sbin/pfctl -q -a "$ANCHOR" -f "$BLOCK_CONF" >/dev/null 2>&1 || true
            echo "Legacy VPNonly policy was restored; setup can be retried." >&2
        else
            echo "CRITICAL: VPNonly could not restore its validated legacy PF rules." >&2
        fi
        exit 1
    }

    if [ "$ACTIVE_LEGACY" -eq 1 ]; then
        wait_for_legacy_route
        PRECOMMIT_RULES=$(mktemp /var/run/vpnonly-precommit-main.XXXXXX) || exit 1
        PRECOMMIT_NAT=$(mktemp /var/run/vpnonly-precommit-nat.XXXXXX) || exit 1
        /sbin/pfctl -s rules > "$PRECOMMIT_RULES" 2>/dev/null || {
            echo "PF changed while VPNonly was preparing its migration; setup can be retried." >&2
            exit 1
        }
        /sbin/pfctl -s nat > "$PRECOMMIT_NAT" 2>/dev/null || {
            echo "PF changed while VPNonly was preparing its migration; setup can be retried." >&2
            exit 1
        }
        /usr/bin/cmp -s "$ACTIVE_RULES" "$PRECOMMIT_RULES" &&
        /usr/bin/cmp -s "$ACTIVE_NAT" "$PRECOMMIT_NAT" || {
            echo "PF changed while VPNonly was preparing its migration; setup stopped before reloading main." >&2
            exit 1
        }
        wait_for_legacy_route
        /sbin/pfctl -q -f /etc/pf.conf || {
            echo "Could not retire VPNonly's legacy main firewall policy; its original policy remains active." >&2
            exit 1
        }
        /sbin/pfctl -q -a "$ANCHOR" -f "$BLOCK_CONF" || rollback_after_commit

        POST_RULES=$(mktemp /var/run/vpnonly-post-main.XXXXXX) || rollback_after_commit
        /sbin/pfctl -s rules > "$POST_RULES" 2>/dev/null || rollback_after_commit
        /usr/bin/grep -Eq '^[[:space:]]*anchor "com\.apple/\*" all[[:space:]]*$' "$POST_RULES" || rollback_after_commit
        POST_NAT=$(mktemp /var/run/vpnonly-post-nat.XXXXXX) || rollback_after_commit
        /sbin/pfctl -s nat > "$POST_NAT" 2>/dev/null || rollback_after_commit
        /usr/bin/grep -Eq '^[[:space:]]*nat-anchor "com\.apple/\*" all[[:space:]]*$' "$POST_NAT" || rollback_after_commit
        if /usr/bin/grep -Eq '^[[:space:]]*nat on utun9 inet (all|from any to any) -> [0-9]+(\.[0-9]+){3}[[:space:]]*$' "$POST_NAT"; then
            rollback_after_commit
        fi
        if /usr/bin/awk '
            { for (i=1; i<NF; i++) if ($i == "group") {
                value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
                if ((value ~ /^[0-9]+$/ && value >= 7100 && value < 7900) || value ~ /^vpn_/) found=1
            } }
            END { exit(found ? 0 : 1) }' "$POST_RULES"; then
            rm -f "$POST_RULES"
            rollback_after_commit
        fi
        rm -f "$POST_RULES"
        POST_RULES=""
        rm -f "$POST_NAT"
        POST_NAT=""
        if [ "$NVPNG" -gt 0 ]; then verify_child_blocks || rollback_after_commit; fi
    fi

    GROUPS_TMP=$(mktemp "$PF_STATE/.routed-groups.XXXXXX") || {
        echo "Fail-closed policy is active, but its retry state could not be recorded." >&2
        exit 1
    }
    if [ "$NVPNG" -gt 0 ]; then
        for group in "${LEGACY_VPNG[@]}"; do printf '%s\n' "$group" >> "$GROUPS_TMP"; done
    fi
    chmod 600 "$GROUPS_TMP"
    chown root:wheel "$GROUPS_TMP"
    mv -f "$GROUPS_TMP" "$PF_STATE/routed-groups" || {
        rm -f "$GROUPS_TMP"
        echo "Fail-closed policy is active, but its retry state could not be recorded." >&2
        exit 1
    }
    GROUPS_TMP=""

    # Revalidate the child and the new reference immediately before releasing
    # either an old v10 token or a recovered extra token. This is the actual
    # handoff point: an earlier successful check is not enough authorization.
    REFERENCES=$(/sbin/pfctl -s References 2>/dev/null) || {
        echo "Could not revalidate PF references before handoff." >&2
        exit 1
    }
    PF_INFO=$(/sbin/pfctl -s info 2>/dev/null) || {
        echo "Could not revalidate PF status before handoff." >&2
        exit 1
    }
    if [ "$NVPNG" -gt 0 ]; then
        [ "$HAS_ROOT_TOKEN" -eq 1 ] && reference_is_active "$ROOT_TOKEN" &&
        printf '%s\n' "$PF_INFO" | grep -Eq '^Status:[[:space:]]+Enabled' &&
        verify_child_blocks || {
            echo "VPNonly's replacement PF protection was not durable; old references were retained." >&2
            exit 1
        }
    fi
    if [ "$LEGACY_TOKEN_ACTIVE" -eq 1 ] && ! reference_is_active "$LEGACY_TOKEN"; then
        LEGACY_TOKEN_ACTIVE=0
    fi
    if [ "$EXTRA_TOKEN_ACTIVE" -eq 1 ] && ! reference_is_active "$EXTRA_TOKEN"; then
        EXTRA_TOKEN_ACTIVE=0
        rm -f "$PENDING_TOKEN_FILE"
    fi

    # The new root token is acquired and recorded before the old reference is
    # released. Any failure below leaves the legacy files in place for a retry.
    if [ "$LEGACY_TOKEN_ACTIVE" -eq 1 ]; then
        /sbin/pfctl -X "$LEGACY_TOKEN" >/dev/null 2>&1 || {
            echo "Could not release VPNonly's legacy PF reference; fail-closed policy remains active." >&2
            exit 1
        }
        if [ "$EXTRA_TOKEN_ACTIVE" -eq 1 ] && [ "$EXTRA_TOKEN" = "$LEGACY_TOKEN" ]; then
            EXTRA_TOKEN_ACTIVE=0
            rm -f "$PENDING_TOKEN_FILE"
        fi
    fi
    if [ "$EXTRA_TOKEN_ACTIVE" -eq 1 ]; then
        /sbin/pfctl -X "$EXTRA_TOKEN" >/dev/null 2>&1 || {
            echo "Could not release VPNonly's recovered extra PF reference; cleanup can be retried." >&2
            exit 1
        }
        rm -f "$PENDING_TOKEN_FILE"
    fi
    if [ "$NVPNG" -eq 0 ]; then
        if [ "$HAS_ROOT_TOKEN" -eq 1 ]; then
            /sbin/pfctl -X "$ROOT_TOKEN" >/dev/null 2>&1 || {
                echo "Could not release VPNonly's empty PF reference; cleanup can be retried." >&2
                exit 1
            }
            rm -f "$ROOT_TOKEN_FILE"
        fi
        rm -f "$PF_STATE/routed-groups"
        rmdir "$PF_STATE" 2>/dev/null || true
    fi

    # The v10 directory belongs to the customer and can be renamed or replaced
    # while this privileged installer runs. Unlink through the customer uid so
    # a swapped symlink can never delete the new root-only retry/token files.
    /usr/bin/sudo -u "$INSTALL_USER" /bin/rm -f \
        "$LEGACY_CONF/pf-merged.conf" "$LEGACY_CONF/pf-token" \
        "$LEGACY_CONF/routed-groups" "$LEGACY_CONF/tunnel-ip" || {
        echo "Migration is complete; some inert legacy files could not be removed safely." >&2
    }
fi

# VERSION is the commit marker. Write it only after every script, ownership
# record, and sudo permission are installed, so a partial setup is retried.
install -m 0644 -o root -g wheel "$SRC/VERSION" "$DEST/VERSION"
echo "INSTALLED"
