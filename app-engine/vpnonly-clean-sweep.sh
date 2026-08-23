#!/bin/bash
# Removes every trace of VPNonly from this Mac, including the bits the normal
# uninstaller deliberately keeps. Use this when something is wrong and you want
# to start from nothing.
#
#   chmod +x vpnonly-clean-sweep.sh
#   ./vpnonly-clean-sweep.sh
#
# It will ask for your admin password once: the engine it installs is owned by
# root, so removing it needs root. Nothing here touches your VPN provider
# account or any file outside VPNonly's own.
set -uo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL
case "${USER:-}" in
    ""|root|*[!A-Za-z0-9._-]*)
        echo "This cleanup needs a normal macOS account name." >&2
        exit 1
        ;;
esac
id "$USER" >/dev/null 2>&1 || { echo "No such account: $USER" >&2; exit 1; }
CURRENT_USER=$(/usr/bin/id -un) || exit 1
[ "$USER" = "$CURRENT_USER" ] || {
    echo "This cleanup must be run by the account it is removing ($CURRENT_USER)." >&2
    exit 1
}
ACCOUNT_HOME=$(/usr/bin/dscl . -read "/Users/$USER" NFSHomeDirectory 2>/dev/null |
    /usr/bin/awk '{ print $2; exit }') || {
    echo "Could not resolve the home folder for $USER." >&2
    exit 1
}
case "$ACCOUNT_HOME" in
    /*) ;;
    *) echo "The home folder for $USER is invalid." >&2; exit 1 ;;
esac
ENGINE_ROOT="/Library/Application Support/VPNonly"
ENGINE="$ENGINE_ROOT/engine"
STATE_ROOT="/var/run/vpnonly"
TUNNEL_STATE="$STATE_ROOT/$USER"
OP_LOCK="$STATE_ROOT/.lock-$USER"
PF_STATE="$STATE_ROOT/.pf-$USER"
ANCHOR="com.apple/vpnonly"

root_path_exists() {
    sudo /bin/test -e "$1" 2>/dev/null || sudo /bin/test -L "$1" 2>/dev/null
}

contains_rules() {
    /usr/bin/awk 'NF { found=1 } END { exit !found }'
}

list_vpn_groups() {
    /usr/bin/dscl . -list /Groups PrimaryGroupID 2>/dev/null |
        /usr/bin/awk '$1 ~ /^vpn_[0-9a-f]{12}$/ && $2 >= 7100 && $2 < 7900 { print $1 }'
}

safe_installed_dir() {
    local path="$1" meta owner mode
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    meta=$(/usr/bin/stat -f '%u:%Lp' "$path" 2>/dev/null) || return 1
    owner=${meta%%:*}
    mode=${meta#*:}
    [ "$owner" = 0 ] || return 1
    case "$mode" in ""|*[!0-7]*) return 1 ;; esac
    [ $((8#$mode & 022)) -eq 0 ]
}

find_vpnonly_tunnel_pids() {
    sudo /bin/ps -axo pid=,uid=,command= 2>/dev/null |
        /usr/bin/awk -v modern="$ENGINE/bin/wireguard-go -f utun" \
                         -v legacy="$ENGINE/bin/wireguard-go utun9" '
            {
                command=$3
                for (i=4; i<=NF; i++) command=command " " $i
                if ($2 == 0 && (command == modern || command == legacy)) print $1
            }'
}

find_ambiguous_legacy_tunnel_pids() {
    sudo /bin/ps -axo pid=,uid=,command= 2>/dev/null |
        /usr/bin/awk '
            {
                command=$3
                for (i=4; i<=NF; i++) command=command " " $i
                if ($2 == 0 && (command == "wireguard-go utun9" ||
                    command ~ /\/wireguard-go utun9$/)) print $1
            }'
}

release_root_pf_token() {
    local token_file="$1" token_meta token_size token_value references
    root_path_exists "$token_file" || return 0
    sudo /bin/test -f "$token_file" && ! sudo /bin/test -L "$token_file" || return 1
    token_meta=$(sudo /usr/bin/stat -f '%u:%g:%Lp:%z' "$token_file" 2>/dev/null) || return 1
    case "$token_meta" in 0:0:600:*) ;; *) return 1 ;; esac
    token_size=${token_meta##*:}
    [ "$token_size" -le 128 ] 2>/dev/null || return 1
    token_value=$(sudo /bin/cat "$token_file" 2>/dev/null) || return 1
    case "$token_value" in ""|*[!0-9]*) return 1 ;; esac

    references=$(sudo /sbin/pfctl -s References 2>/dev/null) || return 1
    if printf '%s\n' "$references" |
       /usr/bin/grep -Eq "(^|[[:space:]])$token_value([[:space:]]|$)"; then
        sudo /sbin/pfctl -X "$token_value" >/dev/null 2>&1 || return 1
        references=$(sudo /sbin/pfctl -s References 2>/dev/null) || return 1
        if printf '%s\n' "$references" |
           /usr/bin/grep -Eq "(^|[[:space:]])$token_value([[:space:]]|$)"; then
            return 1
        fi
    fi
    sudo /bin/rm -f "$token_file"
}

cleanup_root_pf_token_temp() {
    local token_file="$1" token_meta token_size token_mtime
    token_meta=$(sudo /usr/bin/stat -f '%u:%g:%Lp:%z' "$token_file" 2>/dev/null) || return 1
    case "$token_meta" in 0:0:600:*) ;; *) return 1 ;; esac
    token_size=${token_meta##*:}
    case "$token_size" in ""|*[!0-9]*) return 1 ;; esac
    if [ "$token_size" -gt 0 ]; then
        release_root_pf_token "$token_file"
        return
    fi

    # The installer creates this file before pfctl -E. An empty file from the
    # current boot is ambiguous: a hard crash may have acquired a reference
    # before recording its value. Across a restart every such reference is
    # gone, so an older empty staging inode is then safe to remove.
    token_mtime=$(sudo /usr/bin/stat -f '%m' "$token_file" 2>/dev/null) || return 1
    case "$token_mtime" in ""|*[!0-9]*) return 1 ;; esac
    [ "$token_mtime" -lt "$BOOT_EPOCH" ] || return 1
    sudo /bin/rm -f "$token_file"
}

echo "==> stopping anything that's running"
pkill -9 -f "VPNonly.app/Contents/MacOS/VPNonly" 2>/dev/null && echo "    stopped a running copy" || echo "    nothing was running"
sleep 1

echo "==> removing VPNonly's firewall policy and root-owned engine"
RAN_DOWN=0
if [ -e "$ENGINE_ROOT" ] || [ -L "$ENGINE_ROOT" ]; then
    safe_installed_dir "$ENGINE_ROOT" || {
        echo "    the installed engine path is unsafe; nothing root-owned was removed" >&2
        exit 1
    }
    if [ -e "$ENGINE" ] || [ -L "$ENGINE" ]; then
        safe_installed_dir "$ENGINE" || {
            echo "    the installed engine directory is unsafe; nothing root-owned was removed" >&2
            exit 1
        }
        INSTALLED_VERSION=$(/usr/bin/sed -n '1p' "$ENGINE/VERSION" 2>/dev/null || true)
        case "$INSTALLED_VERSION" in
        11) ;;
        "")
            echo "    the engine is partial and has no trustworthy version; no helper was executed"
            ;;
        *)
            echo "    the installed engine is an older unsafe version; it was not executed" >&2
            echo "    open the current VPNonly app and use Uninstall so it can migrate safely first" >&2
            exit 1
            ;;
        esac
    else
        INSTALLED_VERSION=""
        echo "    the engine directory is missing; checking retained state directly"
    fi

    if [ "$INSTALLED_VERSION" = 11 ] &&
       [ -x "$ENGINE/uninstall.sh" ] && [ -x "$ENGINE/down.sh" ] && [ -x "$ENGINE/route.sh" ]; then
        if sudo "$ENGINE/uninstall.sh" "$USER"; then
            RAN_DOWN=1
        else
            echo "    the verified uninstaller stopped early; checking retained state without guessing ownership" >&2
        fi
    elif [ "$INSTALLED_VERSION" = 11 ]; then
        echo "    the v11 engine is partial; using only the verified helpers that remain"
        if [ -x "$ENGINE/down.sh" ] && [ -x "$ENGINE/bin/wg" ] &&
           [ -x "$ENGINE/bin/wireguard-go" ]; then
            sudo "$ENGINE/down.sh" "$USER" || {
                echo "    the partial engine could not verify and stop its tunnel" >&2
                exit 1
            }
            RAN_DOWN=1
        elif [ -x "$ENGINE/down.sh" ]; then
            echo "    tunnel helper dependencies are partial; ownership will be checked without executing it"
        fi
        if [ -x "$ENGINE/route.sh" ]; then
            sudo "$ENGINE/route.sh" "$USER" || {
                echo "    the partial engine could not clear its scoped firewall policy" >&2
                exit 1
            }
        fi
    else
        echo "    no installed helper was trusted; using read-only ownership checks"
    fi
fi

# Close the passwordless entry before fallback cleanup. If an app or stale
# helper races this sweep, the checks below see its lock/process and stop
# instead of deleting the ownership evidence from underneath it.
sudo /bin/rm -f /etc/sudoers.d/vpnonly || {
    echo "    VPNonly's sudoers rule could not be removed" >&2
    exit 1
}
if root_path_exists /etc/sudoers.d/vpnonly; then
    echo "    VPNonly's sudoers rule is still present" >&2
    exit 1
fi

if root_path_exists "$STATE_ROOT"; then
    sudo /bin/test -d "$STATE_ROOT" && ! sudo /bin/test -L "$STATE_ROOT" &&
    [ "$(sudo /usr/bin/stat -f '%u:%g:%Lp' "$STATE_ROOT" 2>/dev/null || true)" = "0:0:700" ] || {
        echo "    VPNonly's runtime directory is unsafe; refusing to follow it" >&2
        exit 1
    }
fi

if root_path_exists "$OP_LOCK"; then
    echo "    a VPNonly root operation is still active or could not be verified" >&2
    echo "    restart this Mac, then run the cleanup again" >&2
    exit 1
fi
if ! VPNONLY_TUNNEL_PIDS=$(find_vpnonly_tunnel_pids); then
    echo "    VPNonly's tunnel processes could not be inspected" >&2
    exit 1
fi
if [ -n "$VPNONLY_TUNNEL_PIDS" ]; then
    echo "    VPNonly's exact tunnel process is still running (pid $VPNONLY_TUNNEL_PIDS)" >&2
    if [ "$RAN_DOWN" -eq 0 ]; then
        echo "    reinstall the current app so its verified teardown can run, or restart this Mac" >&2
    fi
    exit 1
fi

LEGACY_STATE_HINT=0
for legacy_path in "$ACCOUNT_HOME/.config/vpnonly/pf-merged.conf" \
                   "$ACCOUNT_HOME/.config/vpnonly/pf-token" \
                   "$ACCOUNT_HOME/.config/vpnonly/tunnel-ip" \
                   "$ACCOUNT_HOME/.config/vpnonly/routed-groups"; do
    if [ -e "$legacy_path" ] || [ -L "$legacy_path" ]; then
        LEGACY_STATE_HINT=1
    fi
done
if [ "$LEGACY_STATE_HINT" -eq 1 ]; then
    if ! AMBIGUOUS_TUNNEL_PIDS=$(find_ambiguous_legacy_tunnel_pids); then
        echo "    older tunnel processes could not be inspected" >&2
        exit 1
    fi
    if [ -n "$AMBIGUOUS_TUNNEL_PIDS" ]; then
        echo "    a root wireguard-go utun9 process may belong to old VPNonly or another VPN" >&2
        echo "    it was not touched; close other VPN apps or restart this Mac, then retry" >&2
        exit 1
    fi
fi

# A missing/partially removed v10 engine can still leave its direct group rules
# in PF's main ruleset. There is no safe scoped command that can delete those;
# a restart reloads /etc/pf.conf without guessing at another product's rules.
MAIN_RULES=$(sudo /sbin/pfctl -s rules 2>/dev/null) || {
    echo "    the active PF rules could not be inspected; nothing else was removed" >&2
    exit 1
}
MAIN_NAT=$(sudo /sbin/pfctl -s nat 2>/dev/null) || {
    echo "    the active PF translations could not be inspected; nothing else was removed" >&2
    exit 1
}
if printf '%s\n' "$MAIN_RULES" | /usr/bin/awk '
     { for (i=1; i<=NF; i++) if ($i == "group") {
           value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
           if ((value ~ /^[0-9]+$/ && value >= 7100 && value < 7900) ||
               value ~ /^vpn_[0-9a-f]{12}$/) found=1
       } }
     END { exit !found }'; then
    echo "    older VPNonly rules are still in PF's main ruleset" >&2
    echo "    restart the Mac, then run this cleanup again" >&2
    exit 1
fi

# v10 could also leave a direct NAT rule when no app groups were selected. A
# surviving generated-policy file is enough to make that rule ambiguous; do
# not mistake NordVPN's own utun9 policy for ours and rewrite the main ruleset.
if [ "$LEGACY_STATE_HINT" -eq 1 ] &&
   printf '%s\n' "$MAIN_NAT" |
       /usr/bin/grep -Eq '^[[:space:]]*nat on utun9 inet (all|from any to any) -> [0-9]+(\.[0-9]+){3}[[:space:]]*$'; then
    echo "    an older VPNonly-style NAT rule may still be in PF's main ruleset" >&2
    echo "    restart the Mac, then run this cleanup again" >&2
    exit 1
fi

# Never consume an old token from the user-writable v10 directory: it could
# name another PF client's reference. If its recorded value is still active,
# a restart safely retires it; once stale, the settings cleanup can remove it.
LEGACY_TOKEN="$ACCOUNT_HOME/.config/vpnonly/pf-token"
if [ -e "$LEGACY_TOKEN" ] || [ -L "$LEGACY_TOKEN" ]; then
    [ -f "$LEGACY_TOKEN" ] && [ ! -L "$LEGACY_TOKEN" ] || {
        echo "    the older VPNonly PF reference file is unsafe" >&2
        echo "    open the current app so it can migrate it safely" >&2
        exit 1
    }
    LEGACY_TOKEN_META=$(/usr/bin/stat -f '%u:%Lp:%z' "$LEGACY_TOKEN" 2>/dev/null || true)
    LEGACY_TOKEN_OWNER=${LEGACY_TOKEN_META%%:*}
    LEGACY_TOKEN_REST=${LEGACY_TOKEN_META#*:}
    LEGACY_TOKEN_MODE=${LEGACY_TOKEN_REST%%:*}
    LEGACY_TOKEN_SIZE=${LEGACY_TOKEN_META##*:}
    case "$LEGACY_TOKEN_MODE" in
        ""|*[!0-7]*)
            echo "    the older VPNonly PF reference is not trustworthy" >&2
            echo "    open the current app so it can migrate it safely" >&2
            exit 1
            ;;
    esac
    case "$LEGACY_TOKEN_SIZE" in
        ""|*[!0-9]*)
            echo "    the older VPNonly PF reference is not trustworthy" >&2
            echo "    open the current app so it can migrate it safely" >&2
            exit 1
            ;;
    esac
    if [ "$LEGACY_TOKEN_OWNER" != 0 ] ||
       [ $((8#$LEGACY_TOKEN_MODE & 022)) -ne 0 ] ||
       [ "$LEGACY_TOKEN_SIZE" -gt 128 ]; then
        echo "    the older VPNonly PF reference is not trustworthy" >&2
        echo "    open the current app so it can migrate it safely" >&2
        exit 1
    fi
    LEGACY_TOKEN_VALUE=$(/bin/cat "$LEGACY_TOKEN" 2>/dev/null || true)
    case "$LEGACY_TOKEN_VALUE" in
        ""|*[!0-9]*)
            echo "    the older VPNonly PF reference is invalid" >&2
            echo "    open the current app so it can migrate it safely" >&2
            exit 1
            ;;
    esac
    PF_REFERENCES=$(sudo /sbin/pfctl -s References 2>/dev/null) || {
        echo "    PF enable references could not be inspected" >&2
        exit 1
    }
    if printf '%s\n' "$PF_REFERENCES" |
       /usr/bin/grep -Eq "(^|[[:space:]])$LEGACY_TOKEN_VALUE([[:space:]]|$)"; then
        echo "    an older VPNonly PF reference is still active" >&2
        echo "    restart the Mac, then run this cleanup again" >&2
        exit 1
    fi
fi

# Never kill by interface name or reload PF's main ruleset here: either could
# belong to another VPN. An empty scoped load removes only a stranded VPNonly
# ruleset, including both its NAT and filter sections.
sudo /sbin/pfctl -q -a "$ANCHOR" -f /dev/null 2>/dev/null || {
    echo "    VPNonly's scoped firewall policy could not be cleared; nothing else was removed" >&2
    exit 1
}
ANCHOR_RULES=$(sudo /sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null) || {
    echo "    VPNonly's scoped firewall rules could not be verified" >&2
    exit 1
}
ANCHOR_NAT=$(sudo /sbin/pfctl -a "$ANCHOR" -s nat 2>/dev/null) || {
    echo "    VPNonly's scoped firewall translations could not be verified" >&2
    exit 1
}
if printf '%s\n%s\n' "$ANCHOR_RULES" "$ANCHOR_NAT" | contains_rules; then
    echo "    VPNonly's scoped firewall policy is not empty" >&2
    exit 1
fi

if root_path_exists "$PF_STATE"; then
    sudo /bin/test -d "$PF_STATE" && ! sudo /bin/test -L "$PF_STATE" &&
    [ "$(sudo /usr/bin/stat -f '%u:%g:%Lp' "$PF_STATE" 2>/dev/null || true)" = "0:0:700" ] || {
        echo "    unsafe VPNonly PF retry directory; refusing to follow it" >&2
        exit 1
    }
fi
BOOT_EPOCH=$(sudo /usr/sbin/sysctl -n kern.boottime 2>/dev/null |
    /usr/bin/awk '{ value=$4; gsub(/,/, "", value); print value }') || {
    echo "    this Mac's boot time could not be inspected" >&2
    exit 1
}
case "$BOOT_EPOCH" in ""|*[!0-9]*)
    echo "    this Mac's boot time could not be verified" >&2
    exit 1
    ;;
esac
for token_file in "$PF_STATE/pf-token" "$PF_STATE/pf-token.pending"; do
    root_path_exists "$token_file" || continue
    cleanup_root_pf_token_temp "$token_file" || {
        echo "    a VPNonly PF reference is unsafe or could not be released" >&2
        echo "    cleanup stopped with its retry state intact; restart this Mac, then retry" >&2
        exit 1
    }
done

PF_TOKEN_TEMPS=""
if root_path_exists "$PF_STATE"; then
    PF_TOKEN_TEMPS=$(sudo /usr/bin/find "$PF_STATE" -mindepth 1 -maxdepth 1 \
        -type f -name '.pf-token.*' -print 2>/dev/null) || {
        echo "    VPNonly's PF staging files could not be inspected" >&2
        exit 1
    }
fi
for token_file in $PF_TOKEN_TEMPS; do
    cleanup_root_pf_token_temp "$token_file" || {
        echo "    an ambiguous PF reference staging file was retained" >&2
        echo "    restart this Mac, then run the cleanup again" >&2
        exit 1
    }
done

if root_path_exists "$PF_STATE"; then
    sudo /bin/rm -f "$PF_STATE/routed-groups" || {
        echo "    VPNonly's routed-group retry state could not be removed" >&2
        exit 1
    }
    ROUTED_TEMPS=$(sudo /usr/bin/find "$PF_STATE" -mindepth 1 -maxdepth 1 \
        -type f -name '.routed-groups.*' -print 2>/dev/null) || {
        echo "    VPNonly's routed-group staging files could not be inspected" >&2
        exit 1
    }
    for routed_temp in $ROUTED_TEMPS; do
        sudo /bin/rm -f "$routed_temp" || {
            echo "    VPNonly's routed-group staging file could not be removed" >&2
            exit 1
        }
    done
    PF_LEFTOVERS=$(sudo /usr/bin/find "$PF_STATE" -mindepth 1 -maxdepth 1 -print 2>/dev/null) || {
        echo "    VPNonly's PF retry directory could not be verified" >&2
        exit 1
    }
    [ -z "$PF_LEFTOVERS" ] || {
        echo "    unknown files remain in VPNonly's PF retry directory" >&2
        exit 1
    }
    sudo /bin/rmdir "$PF_STATE" || {
        echo "    VPNonly's PF retry directory could not be removed" >&2
        exit 1
    }
fi

sudo /bin/rm -rf "$TUNNEL_STATE" || {
    echo "    VPNonly's root-owned runtime state could not be completely removed" >&2
    exit 1
}
for root_path in "$TUNNEL_STATE" "$PF_STATE" /etc/sudoers.d/vpnonly; do
    if root_path_exists "$root_path"; then
        echo "    root-owned VPNonly path remains: $root_path" >&2
        exit 1
    fi
done

echo "==> removing the per-app groups"
if ! VPN_GROUPS=$(list_vpn_groups); then
    echo "    the local group directory could not be read; the engine was kept" >&2
    exit 1
fi
for g in $VPN_GROUPS; do
    sudo /usr/sbin/dseditgroup -o delete "$g" >/dev/null 2>&1 || {
        echo "    could not remove VPNonly group $g; the engine was kept" >&2
        exit 1
    }
    echo "    removed $g"
done
if ! REMAINING_GROUPS=$(list_vpn_groups); then
    echo "    VPNonly's group cleanup could not be verified; the engine was kept" >&2
    exit 1
fi
[ -z "$REMAINING_GROUPS" ] || {
    echo "    VPNonly groups remain; the engine was kept" >&2
    exit 1
}

sudo /bin/rm -rf "$ENGINE_ROOT" || {
    echo "    VPNonly's engine could not be completely removed" >&2
    exit 1
}
if root_path_exists "$ENGINE_ROOT"; then
    echo "    VPNonly's engine is still installed" >&2
    exit 1
fi

echo "==> removing the app itself, wherever it is"
CLEANUP_FAILED=0
if root_path_exists /Applications/VPNonly.app; then
    if sudo /bin/rm -rf /Applications/VPNonly.app &&
       ! root_path_exists /Applications/VPNonly.app; then
        echo "    removed /Applications/VPNonly.app"
    else
        echo "    could not remove /Applications/VPNonly.app" >&2
        CLEANUP_FAILED=1
    fi
fi
for p in "$ACCOUNT_HOME/Applications/VPNonly.app" "$ACCOUNT_HOME/Downloads/VPNonly.app" \
         "$ACCOUNT_HOME/Desktop/VPNonly.app" "$ACCOUNT_HOME/.Trash/VPNonly.app"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        if /bin/rm -rf "$p" && [ ! -e "$p" ] && [ ! -L "$p" ]; then
            echo "    removed $p"
        else
            echo "    could not remove $p" >&2
            CLEANUP_FAILED=1
        fi
    fi
done
/bin/rm -f "$ACCOUNT_HOME/Downloads/VPNonly-"*.zip 2>/dev/null || CLEANUP_FAILED=1

echo "==> removing your settings, licence and cached data"
for p in "$ACCOUNT_HOME/.config/vpnonly" \
         "$ACCOUNT_HOME/Library/Application Support/VPNonly" \
         "$ACCOUNT_HOME/Library/Caches/in.armoury.vpnonly" \
         "$ACCOUNT_HOME/Library/HTTPStorages/in.armoury.vpnonly" \
         "$ACCOUNT_HOME/Library/HTTPStorages/in.armoury.vpnonly.binarycookies" \
         "$ACCOUNT_HOME/Library/Saved Application State/in.armoury.vpnonly.savedState"; do
    /bin/rm -rf "$p" 2>/dev/null || CLEANUP_FAILED=1
    if [ -e "$p" ] || [ -L "$p" ]; then
        echo "    could not remove $p" >&2
        CLEANUP_FAILED=1
    fi
done
/usr/bin/defaults delete in.armoury.vpnonly 2>/dev/null || true
/bin/rm -f "$ACCOUNT_HOME/Library/Preferences/in.armoury.vpnonly.plist" 2>/dev/null || CLEANUP_FAILED=1

echo "==> clearing macOS's record of the app"
# A stale LaunchServices entry can make a fresh copy refuse to open.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true

echo
echo "Checking nothing is left:"
if /usr/bin/pgrep -f "VPNonly.app/Contents/MacOS" >/dev/null; then
    echo "  ! app process is still running"
    CLEANUP_FAILED=1
else
    echo "  running:   nothing"
fi
if ! VPNONLY_TUNNEL_PIDS=$(find_vpnonly_tunnel_pids); then
    echo "  ! tunnel processes could not be verified"
    CLEANUP_FAILED=1
elif [ -n "$VPNONLY_TUNNEL_PIDS" ]; then
    echo "  ! tunnel process remains: $VPNONLY_TUNNEL_PIDS"
    CLEANUP_FAILED=1
fi
if root_path_exists /Applications/VPNonly.app; then
    echo "  ! app still in Applications"
    CLEANUP_FAILED=1
else
    echo "  app:       gone"
fi
if root_path_exists "$ENGINE_ROOT"; then
    echo "  ! engine still installed"
    CLEANUP_FAILED=1
else
    echo "  engine:    gone"
fi
if [ -e "$ACCOUNT_HOME/.config/vpnonly" ] || [ -L "$ACCOUNT_HOME/.config/vpnonly" ]; then
    echo "  ! settings still present"
    CLEANUP_FAILED=1
else
    echo "  settings:  gone"
fi
if /usr/bin/defaults read in.armoury.vpnonly >/dev/null 2>&1; then
    echo "  ! preferences still present"
    CLEANUP_FAILED=1
else
    echo "  prefs:     gone"
fi
if ! REMAINING_GROUPS=$(list_vpn_groups); then
    echo "  ! groups could not be verified"
    CLEANUP_FAILED=1
elif [ -n "$REMAINING_GROUPS" ]; then
    echo "  ! VPNonly groups remain"
    CLEANUP_FAILED=1
else
    echo "  groups:    none"
fi
echo "  internet:  $(/usr/bin/curl -s --max-time 5 -o /dev/null -w '%{http_code}' https://example.com) via $(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/{print $2}')"
echo
if [ "$CLEANUP_FAILED" -ne 0 ]; then
    echo "Cleanup is incomplete. The lines marked ! must be fixed before reinstalling." >&2
    exit 1
fi
echo "Done. Empty the Trash, restart the Mac, then download a fresh copy from"
echo "https://vpnonly.app/download.html"
