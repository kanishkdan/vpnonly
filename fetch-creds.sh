#!/bin/bash
# NordVPN adapter: fetch your NordLynx (WireGuard) private key and store it
# locally with 600 perms. Needs a NordVPN access token:
#   https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/
#   -> Access token tab -> Generate new token
# Run as your normal user (NOT sudo).
#
# Using a different provider? Skip this script and drop your WireGuard private
# key into ~/.config/vpnonly/wg.key instead (see README, "Other providers").
set -euo pipefail

CONF="$HOME/.config/vpnonly"
mkdir -p "$CONF" && chmod 700 "$CONF"

if [ -t 0 ]; then
    read -rsp "Paste your NordVPN access token: " TOKEN; echo
else
    TOKEN="${1:?usage: fetch-creds.sh <token> (or run interactively)}"
fi

RESP=$(curl -sf -u "token:${TOKEN}" https://api.nordvpn.com/v1/users/services/credentials) || {
    echo "ERROR: NordVPN API rejected the token (or network issue)." >&2; exit 1; }

KEY=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nordlynx_private_key"])') || {
    echo "ERROR: no nordlynx_private_key in response — is your subscription active?" >&2; exit 1; }

umask 077
printf '%s\n' "$KEY" > "$CONF/wg.key"
echo "OK: WireGuard private key saved to $CONF/wg.key (mode 600)."
echo "You can revoke the access token anytime from your Nord account dashboard."
