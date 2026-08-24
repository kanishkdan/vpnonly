#!/bin/bash
# usage: route.sh <user> [--blocks-only] [group ...]
#
# Replaces VPNonly's private PF anchor with the complete desired state. The
# macOS main ruleset already evaluates com.apple/* anchors; keeping every
# VPNonly rule in one child anchor lets us update NAT and filtering together
# without reloading (and thereby disturbing) the main ruleset.
set -euo pipefail
umask 077
LC_ALL=C
export LC_ALL

PFCTL=/sbin/pfctl
IFCONFIG=/sbin/ifconfig
PS=/bin/ps
STAT=/usr/bin/stat
GREP=/usr/bin/grep
AWK=/usr/bin/awk
DSCL=/usr/bin/dscl
ANCHOR="com.apple/vpnonly"
ENGINE="/Library/Application Support/VPNonly/engine"
WG="$ENGINE/bin/wg"
WG_GO="$ENGINE/bin/wireguard-go"
STATE_ROOT=/var/run/vpnonly

die() { echo "ROUTE_ERROR: $*" >&2; exit 6; }

[ "$(/usr/bin/id -u)" = 0 ] || die "must run as root"
RUSER="${1:?usage: route.sh <user> [--blocks-only] [group ...]}"; shift || true
case "$RUSER" in
    ""|root|*[!A-Za-z0-9._-]*) die "invalid user" ;;
esac
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && [ "$RUSER" != "$SUDO_USER" ]; then
    die "asked to act for a different user"
fi

BLOCKS_ONLY=0
if [ "${1:-}" = "--blocks-only" ]; then
    BLOCKS_ONLY=1
    shift
fi

# These directories hold only root-owned runtime state. Never put PF files,
# process IDs, or enable tokens in the user's writable config directory.
ensure_root_dir() {
    local path="$1"
    [ ! -L "$path" ] || die "unsafe state-directory symlink: $path"
    if [ ! -e "$path" ]; then
        /bin/mkdir -m 700 "$path" || die "cannot create state directory"
    fi
    [ -d "$path" ] && [ ! -L "$path" ] || die "unsafe state directory: $path"
    [ "$($STAT -f '%u' "$path" 2>/dev/null)" = 0 ] || die "state directory is not root-owned"
    /usr/sbin/chown root:wheel "$path" || die "cannot secure state-directory ownership"
    /bin/chmod 700 "$path" || die "cannot secure state directory"
}

ensure_root_dir "$STATE_ROOT"
STATE="$STATE_ROOT/$RUSER"
TUNNEL_STATE_PRESENT=0
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    ensure_root_dir "$STATE"
    TUNNEL_STATE_PRESENT=1
fi
# Keep PF bookkeeping out of the tunnel-state directory. up.sh removes and
# recreates that directory between tunnels; leaving a token there would make
# its safe rmdir/mkdir lifecycle fail on every reconnect.
PF_STATE="$STATE_ROOT/.pf-$RUSER"
ensure_root_dir "$PF_STATE"

# Only exact app-group names in the private gid range may enter a PF rule.
# Reject the whole declaration on one bad argument: silently omitting a group
# would let a tagged process use the normal connection.
ROUTE_GROUPS=()
for group in "$@"; do
    case "$group" in
        vpn_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) die "invalid VPN group" ;;
    esac
    gid=$($DSCL . -read "/Groups/$group" PrimaryGroupID 2>/dev/null | $AWK '{print $2}') || die "unknown VPN group"
    case "$gid" in ""|*[!0-9]*) die "invalid VPN group id" ;; esac
    [ "$gid" -ge 7100 ] && [ "$gid" -lt 7900 ] || die "VPN group id outside private range"
    ROUTE_GROUPS[${#ROUTE_GROUPS[@]}]="$group"
done
NVPNG=${#ROUTE_GROUPS[@]}

safe_root_file() {
    local path="$1" allow_empty="${2:-0}" max_size="${3:-128}" mode size
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ "$($STAT -f '%u' "$path" 2>/dev/null)" = 0 ] || return 1
    mode=$($STAT -f '%Lp' "$path" 2>/dev/null) || return 1
    case "$mode" in ""|*[!0-7]*) return 1 ;; esac
    [ $((8#$mode & 022)) -eq 0 ] || return 1
    size=$($STAT -f '%z' "$path" 2>/dev/null) || return 1
    [ "$size" -le "$max_size" ] || return 1
    [ "$allow_empty" -eq 1 ] || [ "$size" -gt 0 ] || return 1
}

valid_ipv4() {
    local ip="$1" a b c d extra octet
    case "$ip" in ""|.*|*.|*..*|*[!0-9.]*) return 1 ;; esac
    IFS=. read -r a b c d extra <<< "$ip"
    [ -z "$extra" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        case "$octet" in ""|*[!0-9]*) return 1 ;; esac
        [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
    done
}

# One root-owned operation lock serializes route, up, and down. A timer, second
# app instance, or direct sudo invocation can otherwise interleave the global
# PF anchor/token with tunnel state and make each command report a success that
# was already overwritten by another.
OP_LOCK="$STATE_ROOT/.lock-$RUSER"
LOCK_HELD=0
LOCK_PID_TMP=""
PFCONF=""
PREVIOUS_PFCONF=""
ANCHOR_COMMITTED=0
POLICY_COMPLETE=0
ENABLE_CAPTURE=""
REFS_BEFORE_FILE=""
REFS_AFTER_FILE=""
cleanup() {
    set +e
    if [ "$ANCHOR_COMMITTED" -eq 1 ] && [ "$POLICY_COMPLETE" -eq 0 ] &&
       [ -n "$PREVIOUS_PFCONF" ] && [ -f "$PREVIOUS_PFCONF" ] &&
       [ ! -L "$PREVIOUS_PFCONF" ]; then
        if $PFCTL -n -a "$ANCHOR" -f "$PREVIOUS_PFCONF" >/dev/null 2>&1 &&
           $PFCTL -q -a "$ANCHOR" -f "$PREVIOUS_PFCONF"; then
            echo "ROUTE_WARNING: restored the previous VPNonly policy after an incomplete update" >&2
        else
            echo "ROUTE_CRITICAL: could not restore the previous VPNonly policy" >&2
        fi
    fi
    if [ -n "$PFCONF" ]; then /bin/rm -f "$PFCONF"; fi
    [ -n "$PREVIOUS_PFCONF" ] && /bin/rm -f "$PREVIOUS_PFCONF"
    [ -n "$ENABLE_CAPTURE" ] && /bin/rm -f "$ENABLE_CAPTURE"
    [ -n "$REFS_BEFORE_FILE" ] && /bin/rm -f "$REFS_BEFORE_FILE"
    [ -n "$REFS_AFTER_FILE" ] && /bin/rm -f "$REFS_AFTER_FILE"
    [ -n "$LOCK_PID_TMP" ] && /bin/rm -f "$LOCK_PID_TMP"
    if [ "$LOCK_HELD" -eq 1 ] && [ -d "$OP_LOCK" ] && [ ! -L "$OP_LOCK" ] &&
       [ "$($STAT -f '%u:%g:%Lp' "$OP_LOCK" 2>/dev/null)" = "0:0:700" ]; then
        if safe_root_file "$OP_LOCK/pid" 0 32 &&
           [ "$(/bin/cat "$OP_LOCK/pid" 2>/dev/null)" = "$$" ]; then
            /bin/rm -f "$OP_LOCK/pid"
            /bin/rmdir "$OP_LOCK" 2>/dev/null || true
        elif [ ! -e "$OP_LOCK/pid" ] && [ ! -L "$OP_LOCK/pid" ]; then
            /bin/rm -f "$OP_LOCK"/.pid.*
            /bin/rmdir "$OP_LOCK" 2>/dev/null || true
        fi
    fi
    /bin/rmdir "$PF_STATE" 2>/dev/null || true
}
trap cleanup EXIT

if ! /bin/mkdir -m 700 "$OP_LOCK" 2>/dev/null; then
    [ -d "$OP_LOCK" ] && [ ! -L "$OP_LOCK" ] &&
        [ "$($STAT -f '%u:%g:%Lp' "$OP_LOCK" 2>/dev/null)" = "0:0:700" ] ||
        die "unsafe VPNonly operation lock"
    if safe_root_file "$OP_LOCK/pid" 0 32; then
        lock_pid=$(/bin/cat "$OP_LOCK/pid")
        case "$lock_pid" in ""|*[!0-9]*) die "unsafe VPNonly operation lock" ;; esac
        /bin/kill -0 "$lock_pid" 2>/dev/null &&
            die "another VPNonly operation is running"
    elif [ -e "$OP_LOCK/pid" ] || [ -L "$OP_LOCK/pid" ]; then
        die "unsafe VPNonly operation lock"
    else
        lock_mtime=$($STAT -f '%m' "$OP_LOCK" 2>/dev/null || echo 0)
        now=$(/bin/date +%s)
        if [ "$lock_mtime" -gt 0 ] 2>/dev/null &&
           [ $((now - lock_mtime)) -lt 30 ] 2>/dev/null; then
            die "another VPNonly operation is starting"
        fi
    fi
    /bin/rm -f "$OP_LOCK/pid" "$OP_LOCK"/.pid.*
    /bin/rmdir "$OP_LOCK" 2>/dev/null || die "another VPNonly operation is running"
    /bin/mkdir -m 700 "$OP_LOCK" 2>/dev/null || die "another VPNonly operation is running"
fi
LOCK_HELD=1
/usr/sbin/chown root:wheel "$OP_LOCK"
/bin/chmod 700 "$OP_LOCK"
LOCK_PID_TMP=$(/usr/bin/mktemp "$OP_LOCK/.pid.XXXXXX") || die "cannot record operation lock"
printf '%s\n' "$$" > "$LOCK_PID_TMP" || die "cannot record operation lock"
/usr/sbin/chown root:wheel "$LOCK_PID_TMP" || die "cannot secure operation lock"
/bin/chmod 600 "$LOCK_PID_TMP" || die "cannot secure operation lock"
/bin/mv -f "$LOCK_PID_TMP" "$OP_LOCK/pid" || die "cannot publish operation lock"
LOCK_PID_TMP=""

# The interface name alone is not ownership. Accept an up tunnel only when all
# root state agrees with a live root process running our exact installed binary,
# and when both the WireGuard socket and wg query are usable.
OWNED_TUNNEL=0
IFACE=""
TUNNEL_PID=""
CLIENT_IP=""
if [ "$TUNNEL_STATE_PRESENT" -eq 1 ] &&
   safe_root_file "$STATE/interface" &&
   safe_root_file "$STATE/pid" &&
   safe_root_file "$STATE/client-ip"; then
    IFACE=$(/bin/cat "$STATE/interface")
    TUNNEL_PID=$(/bin/cat "$STATE/pid")
    CLIENT_IP=$(/bin/cat "$STATE/client-ip")

    case "$IFACE" in
        utun*) suffix=${IFACE#utun}; case "$suffix" in ""|*[!0-9]*) IFACE="" ;; esac ;;
        *) IFACE="" ;;
    esac
    case "$TUNNEL_PID" in ""|*[!0-9]*) TUNNEL_PID="" ;; esac

    if [ -n "$IFACE" ] && [ -n "$TUNNEL_PID" ] && [ "${#TUNNEL_PID}" -le 10 ] &&
       [ "$TUNNEL_PID" -gt 1 ] 2>/dev/null && valid_ipv4 "$CLIENT_IP" &&
       [ -x "$WG" ] && [ -x "$WG_GO" ] &&
       $IFCONFIG "$IFACE" >/dev/null 2>&1; then
        socket="/var/run/wireguard/$IFACE.sock"
        proc_uid=$($PS -p "$TUNNEL_PID" -o uid= 2>/dev/null | /usr/bin/tr -d '[:space:]')
        proc_command=$($PS -p "$TUNNEL_PID" -o command= 2>/dev/null || true)
        while [ "${proc_command# }" != "$proc_command" ]; do proc_command=${proc_command# }; done
        if [ "$proc_uid" = 0 ] &&
           [ "$proc_command" = "$WG_GO -f utun" ] &&
           [ -S "$socket" ] && [ ! -L "$socket" ] &&
           [ "$($STAT -f '%u' "$socket" 2>/dev/null)" = 0 ] &&
           "$WG" show "$IFACE" >/dev/null 2>&1; then
            OWNED_TUNNEL=1
        fi
    fi
fi

ROUTE_THROUGH=0
if [ "$BLOCKS_ONLY" -eq 0 ] && [ "$OWNED_TUNNEL" -eq 1 ] && [ "$NVPNG" -gt 0 ]; then
    ROUTE_THROUGH=1
fi

# A wildcard hook must be present in the active main ruleset. Loading a named
# anchor that nothing evaluates succeeds but enforces nothing, which would be
# a dangerous false success. NAT is required only for a route-through load;
# block-only reconciliation can still protect apps when a custom main ruleset
# omitted the stock NAT hook.
if [ "$NVPNG" -gt 0 ]; then
    main_filter=$($PFCTL -s rules 2>/dev/null) || die "cannot inspect active PF filter rules"
    printf '%s\n' "$main_filter" |
        $GREP -Eq '^[[:space:]]*anchor "com\.apple/\*" all[[:space:]]*$' ||
        die "active PF filter hook is missing or customized"
    if [ "$ROUTE_THROUGH" -eq 1 ]; then
        main_nat=$($PFCTL -s nat 2>/dev/null) || die "cannot inspect active PF NAT rules"
        printf '%s\n' "$main_nat" |
            $GREP -Eq '^[[:space:]]*nat-anchor "com\.apple/\*" all[[:space:]]*$' ||
            die "active PF NAT hook is missing or customized"
    fi
fi

PFCONF=$(/usr/bin/mktemp /var/run/vpnonly-pf.XXXXXX) || die "cannot create PF rules file"

if [ "$ROUTE_THROUGH" -eq 1 ]; then
    printf 'nat on %s inet from any to any -> %s\n' "$IFACE" "$CLIENT_IP" >> "$PFCONF"
fi
if [ "$NVPNG" -gt 0 ]; then
    for group in "${ROUTE_GROUPS[@]}"; do
        if [ "$ROUTE_THROUGH" -eq 1 ]; then
            # The pass must precede the quick fallback block. Both match the group;
            # a valid owned tunnel takes the route-to rule, while every block-only
            # declaration contains only the final fail-closed rule.
            printf 'pass out quick on ! lo0 route-to (%s %s) inet proto { tcp udp } from any to any group %s keep state\n' \
                "$IFACE" "$CLIENT_IP" "$group" >> "$PFCONF"
        fi
        # Anything this IPv4-only tunnel cannot deliberately route stays
        # fail-closed too (IPv6, ICMP, and uncommon protocols included).
        #
        # `return`, not `drop`: a silent drop leaves the app waiting for a
        # timeout, so a blocked app looks hung rather than offline. `return`
        # sends a TCP RST and an ICMP unreachable for UDP, so the app fails at
        # once and says so. Every other protocol is still dropped silently,
        # which is what `return` already does for them.
        printf 'block return out quick on ! lo0 from any to any group %s\n' \
            "$group" >> "$PFCONF"
    done
fi

# A scoped full-ruleset load replaces both translation and filter rules in this
# one anchor. In particular, loading the empty file clears stale NAT too;
# -F rules alone would clear only filters, while -F all risks global state.
$PFCTL -n -a "$ANCHOR" -f "$PFCONF" >/dev/null 2>&1 || die "generated anchor failed validation"

# Keep a parseable copy of the active child before replacing it. Every error
# after the scoped commit rolls this exact policy back, so a caller restoring
# its in-memory group set can never leave a still-tagged app without a rule.
PREVIOUS_PFCONF=$(/usr/bin/mktemp /var/run/vpnonly-pf-previous.XXXXXX) ||
    die "cannot snapshot the existing VPNonly policy"
$PFCTL -a "$ANCHOR" -s nat > "$PREVIOUS_PFCONF" 2>/dev/null ||
    die "cannot snapshot the existing VPNonly translations"
$PFCTL -a "$ANCHOR" -s rules >> "$PREVIOUS_PFCONF" 2>/dev/null ||
    die "cannot snapshot the existing VPNonly rules"
$PFCTL -n -a "$ANCHOR" -f "$PREVIOUS_PFCONF" >/dev/null 2>&1 ||
    die "the existing VPNonly policy could not be preserved"

# Read the previous declaration before changing the kernel so an unsafe state
# file can never turn into a post-commit surprise.
PREV="$PF_STATE/routed-groups"
REMOVED=0
if [ -e "$PREV" ] || [ -L "$PREV" ]; then
    safe_root_file "$PREV" 1 32768 || die "unsafe routed-groups state"
    while IFS= read -r was || [ -n "$was" ]; do
        [ -n "$was" ] || continue
        still=0
        if [ "$NVPNG" -gt 0 ]; then
            for group in "${ROUTE_GROUPS[@]}"; do [ "$was" = "$group" ] && still=1; done
        fi
        [ "$still" -eq 1 ] || REMOVED=1
    done < "$PREV"
fi

TOKEN="$PF_STATE/pf-token"
PENDING_TOKEN="$PF_STATE/pf-token.pending"
HAS_TOKEN=0
EXTRA_TOKEN_ACTIVE=0

references=$($PFCTL -s References 2>/dev/null) || die "cannot inspect PF enable references"
info=$($PFCTL -s info 2>/dev/null) || die "cannot inspect PF status"
reference_is_active() {
    local wanted="$1"
    printf '%s\n' "$references" | $AWK -v wanted="$wanted" '
        {
            pid=substr($0, 1, 8); value=substr($0, 39, 24)
            gsub(/^[[:space:]]+/, "", pid); gsub(/[[:space:]]+$/, "", pid)
            gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
            if (pid ~ /^[0-9]+$/ && value == wanted) found=1
        }
        END { exit(found ? 0 : 1) }'
}
pf_is_enabled() {
    printf '%s\n' "$info" | $GREP -Eq '^Status:[[:space:]]+Enabled'
}
read_token_file() {
    local path="$1"
    safe_root_file "$path" 0 128 || die "unsafe PF enable token"
    /bin/cat "$path"
}

# A crash can leave the pre-publish mktemp inode behind. Recover one numeric
# root-owned stage into the fixed pending name; an empty stage means pfctl may
# have enabled PF without returning a token, so only a reboot can prove that
# unknown reference is gone.
staged_token=""
staged_count=0
for candidate in "$PF_STATE"/.pf-token.*; do
    [ -e "$candidate" ] || [ -L "$candidate" ] || continue
    [ "$candidate" = "$PENDING_TOKEN" ] && continue
    safe_root_file "$candidate" 1 128 || die "unsafe staged PF enable token"
    staged_count=$((staged_count + 1))
    staged_token="$candidate"
done
[ "$staged_count" -le 1 ] || die "ambiguous staged PF enable tokens; restart this Mac"
if [ "$staged_count" -eq 1 ]; then
    [ ! -e "$PENDING_TOKEN" ] && [ ! -L "$PENDING_TOKEN" ] ||
        die "more than one pending PF enable token; restart this Mac"
    [ -s "$staged_token" ] || die "incomplete PF enable token; restart this Mac"
    staged_value=$(/bin/cat "$staged_token")
    case "$staged_value" in ""|*[!0-9]*) die "invalid staged PF enable token; restart this Mac" ;; esac
    reference_is_active "$staged_value" && pf_is_enabled ||
        die "unverifiable staged PF enable token; restart this Mac"
    /bin/mv -f "$staged_token" "$PENDING_TOKEN" || die "cannot preserve staged PF enable token"
fi

token_value=""
if [ -e "$TOKEN" ] || [ -L "$TOKEN" ]; then
    token_value=$(read_token_file "$TOKEN")
    case "$token_value" in ""|*[!0-9]*) die "invalid PF enable token" ;; esac
    if reference_is_active "$token_value"; then
        pf_is_enabled || die "PF has VPNonly's reference but is disabled"
        HAS_TOKEN=1
    else
        # /var/run normally prevents this across reboot, but manual PF resets
        # can invalidate a recorded reference. Reacquire rather than claiming
        # protection while PF is actually off.
        /bin/rm -f "$TOKEN"
        token_value=""
    fi
fi

pending_value=""
if [ -e "$PENDING_TOKEN" ] || [ -L "$PENDING_TOKEN" ]; then
    safe_root_file "$PENDING_TOKEN" 1 128 || die "unsafe pending PF enable token"
    [ -s "$PENDING_TOKEN" ] || die "incomplete PF enable token; restart this Mac"
    pending_value=$(/bin/cat "$PENDING_TOKEN")
    case "$pending_value" in ""|*[!0-9]*) die "invalid pending PF enable token" ;; esac
    if reference_is_active "$pending_value"; then
        pf_is_enabled || die "PF has VPNonly's pending reference but is disabled"
        if [ "$HAS_TOKEN" -eq 0 ]; then
            /bin/mv -f "$PENDING_TOKEN" "$TOKEN" || die "cannot adopt pending PF enable token"
            token_value="$pending_value"
            HAS_TOKEN=1
        elif [ "$pending_value" = "$token_value" ]; then
            /bin/rm -f "$PENDING_TOKEN"
            pending_value=""
        else
            EXTRA_TOKEN_ACTIVE=1
        fi
    else
        # Pending is recovery state written around pfctl -E. An inactive-looking
        # numeric prefix may be a torn write of a different live token; preserve
        # it and require reboot rather than guessing and leaking that reference.
        die "unverifiable pending PF enable token; restart this Mac"
    fi
fi

if ! $PFCTL -q -a "$ANCHOR" -f "$PFCONF"; then
    die "could not load VPNonly PF anchor"
fi
ANCHOR_COMMITTED=1

# Install protection before acquiring our PF enable reference. On the first
# ever route, the opposite order creates a small enabled-but-empty interval.
# Existing PF users see the scoped anchor swap immediately; a disabled PF sees
# the already-complete anchor as soon as -E succeeds.
if [ "$NVPNG" -gt 0 ] && [ "$HAS_TOKEN" -eq 0 ]; then
    REFS_BEFORE_FILE=$(/usr/bin/mktemp /var/run/vpnonly-route-refs-before.XXXXXX) ||
        die "cannot prepare PF reference snapshot"
    REFS_AFTER_FILE=$(/usr/bin/mktemp /var/run/vpnonly-route-refs-after.XXXXXX) ||
        die "cannot prepare PF reference snapshot"
    ENABLE_CAPTURE=$(/usr/bin/mktemp /var/run/vpnonly-route-enable.XXXXXX) ||
        die "cannot prepare PF enable output"
    /bin/chmod 600 "$REFS_BEFORE_FILE" "$REFS_AFTER_FILE" "$ENABLE_CAPTURE"
    printf '%s\n' "$references" > "$REFS_BEFORE_FILE" ||
        die "cannot record the PF reference snapshot"

    # Publish an empty, fixed recovery inode before incrementing PF's reference
    # count. If the command succeeds but its output cannot be attributed, the
    # empty file forces a reboot instead of silently acquiring more references.
    token_stage=$(/usr/bin/mktemp "$PF_STATE/.pf-token.XXXXXX") || die "cannot prepare PF reference storage"
    /usr/sbin/chown root:wheel "$token_stage" || die "cannot secure PF reference storage"
    /bin/chmod 600 "$token_stage" || die "cannot secure PF reference storage"
    /bin/mv -f "$token_stage" "$PENDING_TOKEN" || die "cannot publish PF reference recovery state"

    $PFCTL -E > "$ENABLE_CAPTURE" 2>&1 &
    enable_pid=$!
    if ! wait "$enable_pid"; then
        /bin/rm -f "$PENDING_TOKEN"
        die "cannot enable PF"
    fi
    token_value=$($AWK '/Token[[:space:]]*:/ {print $NF; exit}' "$ENABLE_CAPTURE")
    publish_pending_token() {
        local value="$1" complete
        case "$value" in ""|*[!0-9]*) return 1 ;; esac
        complete=$(/usr/bin/mktemp "$PF_STATE/.pf-token.XXXXXX") || return 1
        /usr/sbin/chown root:wheel "$complete" || return 1
        /bin/chmod 600 "$complete" || return 1
        printf '%s\n' "$value" > "$complete" || return 1
        safe_root_file "$complete" 0 128 || return 1
        [ "$(/bin/cat "$complete" 2>/dev/null)" = "$value" ] || return 1
        /bin/mv -f "$complete" "$PENDING_TOKEN"
    }
    if ! $PFCTL -s References > "$REFS_AFTER_FILE" 2>/dev/null; then
        case "$token_value" in
            ""|*[!0-9]*) ;;
            *) publish_pending_token "$token_value" || true ;;
        esac
        die "PF enabled but its reference could not be inspected; restart this Mac"
    fi
    case "$token_value" in
        ""|*[!0-9]*)
            token_value=$($AWK -v pid="$enable_pid" '
                {
                    rowpid=substr($0, 1, 8); name=substr($0, 10, 28); value=substr($0, 39, 24)
                    gsub(/^[[:space:]]+/, "", rowpid); gsub(/[[:space:]]+$/, "", rowpid)
                    gsub(/^[[:space:]]+/, "", name); gsub(/[[:space:]]+$/, "", name)
                    gsub(/^[[:space:]]+/, "", value); gsub(/[[:space:]]+$/, "", value)
                    if (rowpid == pid && name == "pfctl" && value ~ /^[0-9]+$/) print value
                }' "$REFS_AFTER_FILE")
            candidate_count=$(printf '%s\n' "$token_value" |
                $AWK 'NF { count++ } END { print count + 0 }')
            if [ "$candidate_count" -ne 1 ]; then
                token_value=$($AWK '
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
                    }' "$REFS_BEFORE_FILE" "$REFS_AFTER_FILE")
                candidate_count=$(printf '%s\n' "$token_value" |
                    $AWK 'NF { count++ } END { print count + 0 }')
            fi
            [ "$candidate_count" -eq 1 ] ||
                die "PF enabled without one identifiable reference; restart this Mac"
            ;;
    esac
    references=$(/bin/cat "$REFS_AFTER_FILE")
    reference_is_active "$token_value" || {
        publish_pending_token "$token_value" || true
        die "PF did not retain VPNonly's new reference"
    }
    publish_pending_token "$token_value" ||
        die "cannot record PF reference atomically; restart this Mac"
    /bin/mv -f "$PENDING_TOKEN" "$TOKEN" || die "cannot publish PF reference; restart this Mac"
    HAS_TOKEN=1
fi

if [ "$BLOCKS_ONLY" -eq 1 ] && [ "$NVPNG" -gt 0 ] && [ "$OWNED_TUNNEL" -eq 1 ]; then
    # This is part of the privacy transition, not housekeeping: old keep-state
    # entries must not outlive the swap to block-only before tunnel teardown.
    $PFCTL -i "$IFACE" -F states >/dev/null 2>&1 ||
        die "could not close existing routed connections"
elif [ "$REMOVED" -eq 1 ] && [ "$OWNED_TUNNEL" -eq 1 ]; then
    $PFCTL -i "$IFACE" -F states >/dev/null 2>&1 ||
        echo "ROUTE_WARNING: old connections may take a moment to close" >&2
fi

if groups_tmp=$(/usr/bin/mktemp "$PF_STATE/.routed-groups.XXXXXX"); then
    if [ "$NVPNG" -gt 0 ]; then
        for group in "${ROUTE_GROUPS[@]}"; do printf '%s\n' "$group" >> "$groups_tmp"; done
    fi
    /bin/chmod 600 "$groups_tmp"
    /bin/mv -f "$groups_tmp" "$PREV" || {
        /bin/rm -f "$groups_tmp"
        echo "ROUTE_WARNING: active policy could not be recorded" >&2
    }
else
    echo "ROUTE_WARNING: active policy could not be recorded" >&2
fi

if [ "$NVPNG" -eq 0 ]; then
    # Keep the durable PF reference while VPNonly is installed. Releasing the
    # last reference is not atomic with returning success: a TERM/KILL in that
    # few-instruction window could make Swift restore its old model around an
    # inactive old anchor. The anchor is empty, so retaining the reference adds
    # no VPNonly filtering; uninstall/clean-sweep release it after teardown.
    :
elif [ "$EXTRA_TOKEN_ACTIVE" -eq 1 ]; then
    # A crash can leave both the durable token and a second pending reference.
    # Re-read immediately before handoff. A cross-user or external PF reset must
    # never make us release the last reference on the strength of an old table.
    references=$($PFCTL -s References 2>/dev/null) ||
        die "cannot revalidate PF references before handoff"
    info=$($PFCTL -s info 2>/dev/null) ||
        die "cannot revalidate PF status before handoff"
    if ! reference_is_active "$token_value" || ! pf_is_enabled; then
        echo "ROUTE_WARNING: retained the recovery PF reference after an external PF change" >&2
    elif $PFCTL -X "$pending_value" >/dev/null 2>&1; then
        /bin/rm -f "$PENDING_TOKEN"
    else
        echo "ROUTE_WARNING: an extra PF reference will be retried later" >&2
    fi
fi

if [ "$NVPNG" -eq 0 ]; then
    /bin/rm -f "$PREV" ||
        echo "ROUTE_WARNING: empty policy installed but old bookkeeping remains" >&2
    /bin/rmdir "$PF_STATE" 2>/dev/null || true
fi

# From this point every privacy-relevant operation succeeded. Bookkeeping and
# human-readable output below must never turn a committed policy into a caller-
# visible failure that makes Swift restore a different in-memory declaration.
POLICY_COMPLETE=1

mode=full
[ "$BLOCKS_ONLY" -eq 1 ] && mode=blocks-only
{
    if [ "$NVPNG" -eq 0 ]; then
        echo "ROUTES none tunnel=$OWNED_TUNNEL mode=$mode"
    else
        printf 'ROUTES'
        for group in "${ROUTE_GROUPS[@]}"; do printf ' %s' "$group"; done
        echo " tunnel=$OWNED_TUNNEL mode=$mode"
    fi
} || true
exit 0
