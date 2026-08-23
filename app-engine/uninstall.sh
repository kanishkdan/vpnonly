#!/bin/bash
# Removes everything VPNonly ever put on this machine, root-owned bits included.
# Run with administrator privileges. Safe to run twice.
#
#   sudo "/Library/Application Support/VPNonly/engine/uninstall.sh" [username]
#
# Deleting the app alone would leave a root-owned engine and a sudoers entry
# behind, so this exists and is documented. Nothing here touches your VPN
# provider account or your own config files in ~/.config/vpnonly.
set -uo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL

[ "$(id -u)" = 0 ] || { echo "must run as root (use sudo)"; exit 1; }
RUSER="${1:-${SUDO_USER:-}}"
[ -n "$RUSER" ] || { echo "usage: uninstall.sh <username>"; exit 1; }
case "$RUSER" in *[!A-Za-z0-9._-]*) echo "refusing odd username: $RUSER"; exit 1 ;; esac
[ "$RUSER" != "root" ] || { echo "refusing to uninstall for root"; exit 1; }
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && [ "$RUSER" != "$SUDO_USER" ]; then
    echo "refusing: asked to uninstall for '$RUSER' but invoked by '$SUDO_USER'" >&2
    exit 1
fi
/usr/bin/id "$RUSER" >/dev/null 2>&1 || { echo "no such user: $RUSER"; exit 1; }
DIR0="$(cd "$(dirname "$0")" && pwd)"
STATE="/var/run/vpnonly/$RUSER"
PF_STATE="/var/run/vpnonly/.pf-$RUSER"
ANCHOR="com.apple/vpnonly"

list_vpn_groups() {
    /usr/bin/dscl . -list /Groups PrimaryGroupID 2>/dev/null |
        /usr/bin/awk '$1 ~ /^vpn_[0-9a-f]{12}$/ && $2 >= 7100 && $2 < 7900 { print $1 }'
}

contains_rules() {
    /usr/bin/awk 'NF { found=1 } END { exit !found }'
}

find_vpnonly_tunnel_pids() {
    /bin/ps -axo pid=,uid=,command= 2>/dev/null |
        /usr/bin/awk -v modern="$DIR0/bin/wireguard-go -f utun" \
                         -v legacy="$DIR0/bin/wireguard-go utun9" '
            {
                command=$3
                for (i=4; i<=NF; i++) command=command " " $i
                if ($2 == 0 && (command == modern || command == legacy)) print $1
            }'
}

release_pf_token_file() {
    local token_file="$1" token_meta token_value references
    [ -e "$token_file" ] || [ -L "$token_file" ] || return 0
    [ -f "$token_file" ] && [ ! -L "$token_file" ] || return 1
    token_meta=$(/usr/bin/stat -f '%u:%g:%Lp:%z' "$token_file" 2>/dev/null) || return 1
    case "$token_meta" in 0:0:600:*) ;; *) return 1 ;; esac
    [ "${token_meta##*:}" -le 128 ] 2>/dev/null || return 1
    token_value=$(/bin/cat "$token_file") || return 1
    case "$token_value" in ""|*[!0-9]*) return 1 ;; esac

    references=$(/sbin/pfctl -s References 2>/dev/null) || return 1
    if printf '%s\n' "$references" |
       /usr/bin/grep -Eq "(^|[[:space:]])$token_value([[:space:]]|$)"; then
        /sbin/pfctl -X "$token_value" >/dev/null 2>&1 || return 1
        references=$(/sbin/pfctl -s References 2>/dev/null) || return 1
        if printf '%s\n' "$references" |
           /usr/bin/grep -Eq "(^|[[:space:]])$token_value([[:space:]]|$)"; then
            return 1
        fi
    fi
    /bin/rm -f "$token_file"
}

LEGACY_WAS_RUNNING=0
if /usr/bin/pgrep -U 0 -f -x "$DIR0/bin/wireguard-go utun9" >/dev/null 2>&1; then
    LEGACY_WAS_RUNNING=1
fi

echo "Closing the tunnel…"
"$DIR0/down.sh" "$RUSER" || {
    echo "The owned tunnel could not be verified and stopped; the engine was kept." >&2
    exit 1
}
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    echo "VPNonly's tunnel state remained after teardown; the engine was kept." >&2
    exit 1
fi
if ! TUNNEL_PIDS=$(find_vpnonly_tunnel_pids); then
    echo "VPNonly's tunnel processes could not be verified; the engine was kept." >&2
    exit 1
fi
if [ -n "$TUNNEL_PIDS" ]; then
    echo "A VPNonly tunnel process remains (pid $TUNNEL_PIDS); the engine was kept." >&2
    exit 1
fi

echo "Removing VPNonly's firewall rules…"
"$DIR0/route.sh" "$RUSER" || {
    echo "VPNonly's firewall anchor could not be cleared; the engine was kept." >&2
    exit 1
}
for token_file in "$PF_STATE/pf-token" "$PF_STATE/pf-token.pending" \
                  "$PF_STATE"/.pf-token.*; do
    [ -e "$token_file" ] || [ -L "$token_file" ] || continue
    release_pf_token_file "$token_file" || {
        echo "VPNonly's PF reference could not be released; the engine was kept so cleanup can be retried." >&2
        exit 1
    }
done

# A successful scoped load is not enough: explicitly prove that neither half
# of the private anchor retained rules before deleting the retry machinery.
ANCHOR_RULES=$(/sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null) || {
    echo "VPNonly's firewall rules could not be verified; the engine was kept." >&2
    exit 1
}
ANCHOR_NAT=$(/sbin/pfctl -a "$ANCHOR" -s nat 2>/dev/null) || {
    echo "VPNonly's firewall translations could not be verified; the engine was kept." >&2
    exit 1
}
if printf '%s\n%s\n' "$ANCHOR_RULES" "$ANCHOR_NAT" | contains_rules; then
    echo "VPNonly's firewall anchor is not empty; the engine was kept." >&2
    exit 1
fi

# VERSION 10 wrote group rules into PF's main ruleset. Deleting their groups
# while those numeric rules are live can make a later gid reuse hit stale VPN
# policy. Only a restart (or the v11 installer migration) may retire them.
MAIN_RULES=$(/sbin/pfctl -s rules 2>/dev/null) || {
    echo "The active PF rules could not be inspected; the engine was kept." >&2
    exit 1
}
if printf '%s\n' "$MAIN_RULES" | /usr/bin/awk '
    { for (i=1; i<=NF; i++) if ($i == "group") {
        value=$(i+1); if (value == "=" && i+2 <= NF) value=$(i+2)
        if ((value ~ /^[0-9]+$/ && value >= 7100 && value < 7900) ||
            value ~ /^vpn_[0-9a-f]{12}$/) found=1
    } }
    END { exit !found }'; then
    echo "Older VPNonly rules remain in PF's main ruleset." >&2
    echo "Restart this Mac, then run Uninstall again; the engine and groups were kept." >&2
    exit 1
fi
if [ "$LEGACY_WAS_RUNNING" -eq 1 ]; then
    MAIN_NAT=$(/sbin/pfctl -s nat 2>/dev/null) || {
        echo "The active PF translations could not be inspected; the engine was kept." >&2
        exit 1
    }
    if printf '%s\n' "$MAIN_NAT" |
       /usr/bin/grep -Eq '^[[:space:]]*nat on utun9 inet (all|from any to any) -> [0-9]+(\.[0-9]+){3}[[:space:]]*$'; then
        echo "An older VPNonly NAT rule remains in PF's main ruleset." >&2
        echo "Restart this Mac, then run Uninstall again; the engine was kept." >&2
        exit 1
    fi
fi

if [ -e "$PF_STATE" ] || [ -L "$PF_STATE" ]; then
    [ -d "$PF_STATE" ] && [ ! -L "$PF_STATE" ] || {
        echo "VPNonly's PF retry state is unsafe; the engine was kept." >&2
        exit 1
    }
    /bin/rmdir "$PF_STATE" 2>/dev/null || {
        echo "VPNonly's PF retry state is not empty; the engine was kept." >&2
        exit 1
    }
fi

echo "Removing the per-app groups…"
if ! VPN_GROUPS=$(list_vpn_groups); then
    echo "The local group directory could not be read; the engine was kept." >&2
    exit 1
fi
for g in $VPN_GROUPS; do
    /usr/sbin/dseditgroup -o delete "$g" >/dev/null 2>&1 || {
        echo "Could not remove VPNonly group $g; the engine was kept." >&2
        exit 1
    }
    echo "  removed $g"
done
if ! REMAINING_GROUPS=$(list_vpn_groups); then
    echo "The group cleanup could not be verified; the engine was kept." >&2
    exit 1
fi
[ -z "$REMAINING_GROUPS" ] || {
    echo "VPNonly groups remain; the engine was kept." >&2
    exit 1
}

echo "Removing the passwordless rule…"
/bin/rm -f /etc/sudoers.d/vpnonly || {
    echo "Could not remove VPNonly's sudoers rule; the engine was kept." >&2
    exit 1
}
[ ! -e /etc/sudoers.d/vpnonly ] && [ ! -L /etc/sudoers.d/vpnonly ] || {
    echo "VPNonly's sudoers rule is still present; the engine was kept." >&2
    exit 1
}

echo "Removing the engine…"
/bin/rm -rf "/Library/Application Support/VPNonly" || {
    echo "Could not completely remove VPNonly's engine." >&2
    exit 1
}
if [ -e "/Library/Application Support/VPNonly" ] ||
   [ -L "/Library/Application Support/VPNonly" ]; then
    echo "VPNonly's engine is still present." >&2
    exit 1
fi

echo
echo "Done. VPNonly is off this machine."
echo "Your own files (WireGuard keys, imported configs, licence) are still in"
echo "~/.config/vpnonly and ~/Library/Application Support/VPNonly — delete those"
echo "yourself if you want them gone. Drag VPNonly.app to the Trash to finish."
