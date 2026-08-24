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
BUNDLED_VERSION=$(cat "$SRC/VERSION") || exit 1
case "$BUNDLED_VERSION" in
    0|0*|*[!0-9]*) echo "Bundled VPNonly engine version is invalid." >&2; exit 1 ;;
esac
[ "${#BUNDLED_VERSION}" -le 9 ] || {
    echo "Bundled VPNonly engine version is invalid." >&2
    exit 1
}
# Version 11 was the first to keep its rules in VPNonly's own PF anchor and to
# ask macOS for a free tunnel interface. Anything at or above it upgrades by
# replacing scripts. Versions 9 and 10 wrote into PF's main ruleset and pinned
# utun9, and the code that migrated them in place was the largest and least
# testable part of this installer: it had to reason about states that only
# exist on machines nobody can reproduce. Refusing and asking for a clean
# removal is a promise we can actually keep. uninstall.sh already knows how to
# clear v10 policy, so the path exists and is one command.
MIN_ANCHOR_VERSION=11

validate_installed_version() {
    local installed="$1"
    case "$installed" in
        "") return 0 ;;
        0|0*|*[!0-9]*)
            echo "Existing VPNonly engine version is invalid." >&2
            return 1
            ;;
    esac
    [ "${#installed}" -le 9 ] || {
        echo "Existing VPNonly engine version is invalid." >&2
        return 1
    }
    if [ "$installed" -gt "$BUNDLED_VERSION" ]; then
        echo "NEWER_ENGINE: installed=$installed bundled=$BUNDLED_VERSION" >&2
        return 12
    fi
    if [ "$installed" -lt "$MIN_ANCHOR_VERSION" ]; then
        echo "LEGACY_ENGINE: installed=$installed needs removal before setup" >&2
        return 13
    fi
}

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
ROOT_TOKEN_TMP=""
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
    for file in "$TMP" "$OWNER_TMP"; do
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
        validate_installed_version "$INSTALLED_VERSION"
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
TMP=$(mktemp)
cat > "$TMP" <<EOF
Cmnd_Alias VPNONLY = /Library/Application\\ Support/VPNonly/engine/up.sh *, /Library/Application\\ Support/VPNonly/engine/down.sh, /Library/Application\\ Support/VPNonly/engine/down.sh *, /Library/Application\\ Support/VPNonly/engine/run.sh *, /Library/Application\\ Support/VPNonly/engine/route.sh *, /Library/Application\\ Support/VPNonly/engine/group.sh *, /Library/Application\\ Support/VPNonly/engine/status.sh ""
$INSTALL_USER ALL=(root) NOPASSWD: VPNONLY
EOF
visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/vpnonly
rm -f "$TMP"
TMP=""

# VERSION is the commit marker. Write it only after every script, ownership
# record, and sudo permission are installed, so a partial setup is retried.
install -m 0644 -o root -g wheel "$SRC/VERSION" "$DEST/VERSION"
echo "INSTALLED"
