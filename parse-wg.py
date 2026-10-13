#!/usr/bin/env python3
"""Turn a provider's WireGuard config into something `wg setconf` accepts.

Providers hand out wg-quick configs, which carry Address/DNS/MTU/PostUp lines
that plain `wg setconf` rejects outright. This keeps the session fields, drops
the rest, and reports the tunnel's IPv4 address separately (the firewall needs
it for NAT: Nord uses 10.5.0.2, Mullvad hands out 10.64.x.x, self-hosted is
anything at all).

usage: parse-wg.py <provider.conf> <out.conf>
prints: "<ipv4> <endpoint>" on success, message on stderr + exit 1 on failure.

Deliberately hand-rolled rather than configparser: these files show up with
BOMs, CRLFs, comments mid-section, duplicate keys and stray lines before the
first section, and configparser rejects several of those.
"""
import re
import sys
import base64
import ipaddress
import json
import os
import tempfile


def parse(text):
    section = None
    iface, peer = {}, {}
    for raw in text.splitlines():
        line = raw.strip().lstrip("﻿")
        if not line or line[0] in "#;":
            continue
        if line.startswith("["):
            name = line.strip("[]").strip().lower()
            section = name if name in ("interface", "peer") else None
            continue
        if "=" not in line or section is None:
            continue
        # split once only: base64 keys end in '='
        key, _, value = line.partition("=")
        key = key.strip().lower()
        value = value.strip()
        # strip trailing comments, but never inside a key/endpoint value
        if key in ("address", "dns", "allowedips") and "#" in value:
            value = value.split("#", 1)[0].strip()
        target = iface if section == "interface" else peer
        target.setdefault(key, value)      # first occurrence wins
    return iface, peer


def nord_config(host, data, private_key):
    host = host.strip().lower()
    if "." not in host:
        host += ".nordvpn.com"
    def key_ok(value):
        try:
            return len(value) == 44 and len(base64.b64decode(value, validate=True)) == 32
        except (ValueError, TypeError):
            return False
    if not re.fullmatch(r"[a-z]{2}[0-9]+\.nordvpn\.com", host) or not key_ok(private_key):
        raise ValueError("invalid NordVPN hostname or saved key")
    if not isinstance(data, list) or not all(isinstance(x, dict) for x in data):
        raise ValueError("invalid NordVPN server list")
    matches = [x for x in data if x.get("hostname") == host]
    if len(matches) != 1:
        raise ValueError("NordVPN did not return exactly the requested server")
    server = matches[0]
    tech = next((x for x in server.get("technologies", []) if x.get("identifier") == "wireguard_udp"), {})
    key = next((x.get("value") for x in tech.get("metadata", []) if x.get("name") == "public_key"), None)
    if server.get("status") != "online" or tech.get("pivot", {}).get("status") != "online" or not key_ok(key):
        raise ValueError("that server has no usable online WireGuard peer")
    station = server.get("station")
    if not isinstance(station, str):
        raise ValueError("invalid NordVPN station")
    station = str(ipaddress.IPv4Address(station))
    return (f"# NordVPN server: {host}\n[Interface]\nPrivateKey = {private_key}\n"
            f"Address = 10.5.0.2/32\n\n[Peer]\nPublicKey = {key}\n"
            f"Endpoint = {station}:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n")


def write_private_config(output, config):
    # Atomic replacement also tightens permissions on older session files and
    # replaces an output symlink instead of following it with a private key.
    fd, temp = tempfile.mkstemp(prefix=".wg-config-", dir=os.path.dirname(os.path.abspath(output)))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(config)
        os.replace(temp, output)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def pin_from_stdin(host, key_path, output):
    # Run as the invoking user. Only public metadata arrives over stdin.
    try:
        with open(key_path) as f:
            private_key = f.read().strip()
        data = sys.stdin.read(64 * 1024 * 1024 + 1)
        if len(data) > 64 * 1024 * 1024:
            raise ValueError("server list is too large")
        config = nord_config(host, json.loads(data), private_key)
        write_private_config(output, config)
        print("Pinned " + config.splitlines()[0].split(": ", 1)[1])
        return 0
    except (OSError, ValueError, TypeError, AttributeError):
        # Never echo provider data or key material in a failure.
        print("Could not pin the requested NordVPN server; saved selection is unchanged.", file=sys.stderr)
        return 1


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--nord-config":
        return pin_from_stdin(sys.argv[2], sys.argv[3], sys.argv[4])
    if len(sys.argv) != 3:
        print("usage: parse-wg.py <in.conf> <out.conf>", file=sys.stderr)
        return 1
    try:
        with open(sys.argv[1], "rb") as fh:
            text = fh.read().decode("utf-8", "replace")
    except OSError as exc:
        print("cannot read config: %s" % exc, file=sys.stderr)
        return 1

    iface, peer = parse(text)
    priv = iface.get("privatekey")
    addr = iface.get("address")
    pub = peer.get("publickey")
    endpoint = peer.get("endpoint")
    psk = peer.get("presharedkey")
    allowed = peer.get("allowedips") or "0.0.0.0/0"

    missing = [n for n, v in (("PrivateKey", priv), ("Address", addr),
                              ("PublicKey", pub), ("Endpoint", endpoint)) if not v]
    if missing:
        print("config is missing: %s" % ", ".join(missing), file=sys.stderr)
        return 1

    ip4 = None
    for part in addr.replace(";", ",").split(","):
        candidate = part.strip().split("/")[0]
        if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", candidate):
            ip4 = candidate
            break
    if not ip4:
        print("config has no IPv4 Address — IPv6-only tunnels aren't supported yet",
              file=sys.stderr)
        return 1

    # we only route IPv4, so drop v6 entries rather than let wg claim them
    allowed4 = ",".join(a.strip() for a in allowed.split(",")
                        if a.strip() and ":" not in a) or "0.0.0.0/0"

    if not re.match(r"^[^\s:]+:\d+$", endpoint) and not re.match(r"^\[.+\]:\d+$", endpoint):
        print("endpoint doesn't look like host:port — got %r" % endpoint, file=sys.stderr)
        return 1

    out = ["[Interface]", "PrivateKey = %s" % priv, "", "[Peer]",
           "PublicKey = %s" % pub]
    if psk:
        out.append("PresharedKey = %s" % psk)
    out += ["Endpoint = %s" % endpoint,
            "AllowedIPs = %s" % allowed4,
            "PersistentKeepalive = 25", ""]
    try:
        write_private_config(sys.argv[2], "\n".join(out))
    except OSError as exc:
        print("cannot write: %s" % exc, file=sys.stderr)
        return 1

    print("%s %s" % (ip4, endpoint))
    return 0


if __name__ == "__main__":
    sys.exit(main())
