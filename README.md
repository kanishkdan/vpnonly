# vpnonly

**[Website](https://kanishkdan.github.io/vpnonly/)** · Prefer a menu bar app over the CLI? [VPNonly Pro — $19](https://dodo.pe/vpnonly)

**Per-app VPN split tunneling for macOS.** Route *only the apps you choose*
through a WireGuard VPN while everything else on your Mac uses your normal
connection. ~300 lines of shell + C. No kernel extensions, no changes to your
default route, fully reversible with one command (or a reboot).

Born out of a concrete itch: NordVPN (like most commercial VPN apps) has no
split tunneling on macOS, and I wanted exactly one app inside the VPN.

```sh
./fetch-creds.sh                              # once (NordVPN; see below for others)
sudo ./up.sh                                  # tunnel up — nothing routed yet
sudo ./run.sh /Applications/CapCut.app        # this app, and only this app, is in the VPN
sudo ./down.sh                                # everything back to stock
```

## How it works

macOS's built-in PF firewall can't match packets by *application*, but it can
match by *unix group*. That's the whole trick:

1. **`up.sh`** starts a userspace WireGuard interface (`wireguard-go` →
   `utun9`) to your VPN server — **without installing a default route**, so
   nothing uses it by default. It creates a dedicated group `vpnonly` and
   loads two PF rules on top of the stock ruleset:

   ```
   pass out quick route-to (utun9 10.5.0.2) inet proto { tcp udp } \
       from any to any group vpnonly keep state
   block return out proto { tcp udp } from any to any group vpnonly
   ```

   plus a NAT rule so packets exiting the tunnel carry the tunnel address.
   The `block` rule is the kill switch: if the tunnel is down, group traffic
   is refused — never leaked to your ISP.

2. **`vpnrun`** (30 lines of C, runs via sudo) launches your app with its
   group set to `vpnonly`, then drops privileges back to you. Every helper
   process the app spawns inherits the group, so Chromium-style multi-process
   apps work.

`/etc/pf.conf` is never modified on disk. `down.sh` reloads the stock ruleset
and kills the tunnel; a reboot does the same. The worst-case failure mode is
"the app has no internet," never "my Mac has no internet."

## Install

```sh
brew install wireguard-go wireguard-tools
git clone https://github.com/kanishkdan/vpnonly && cd vpnonly
```

Requires Xcode Command Line Tools (for `cc`, to build the tiny launcher —
happens automatically on first `up.sh`).

## Providers

**NordVPN** (built-in adapter): generate an access token at
[my.nordaccount.com → Manual configuration → Access token](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/),
then `./fetch-creds.sh` and paste it. Exit country: `sudo COUNTRY=us ./up.sh`
(default `sg`).

**Anything else that speaks WireGuard** (Mullvad, Proton, IVPN, a WireGuard
server on your own VPS): put your private key in `~/.config/vpnonly/wg.key`
(mode 600) and pass the server details directly:

```sh
sudo ENDPOINT=<server-ip:port> PEER_KEY=<server-pubkey> CLIENT_IP=<your-assigned-ip> ./up.sh
```

## Verifying

`up.sh` prints the tunnel exit IP next to your normal IP. You can also check
any time:

```sh
curl -s https://api.ipify.org                          # your normal IP
sudo ./run.sh /usr/bin/curl -s https://api.ipify.org   # the VPN exit IP
```

## Known limitations (v0 — honest list)

- **DNS queries are not tunneled yet.** Apps resolve via the system resolver
  (`mDNSResponder`), which runs outside the group, so DNS *queries* still exit
  via your normal connection (the connections themselves are tunneled). If
  your threat model is "hide which hosts I talk to from my ISP," this matters;
  if it's "give one app a different exit IP," it mostly doesn't. Planned fix:
  per-flow steering of the resolver, or a scoped resolver inside the tunnel.
- IPv6 for grouped apps is blocked outright — no leak, but no v6 either.
- No auto-reconnect if the VPN server dies (`down.sh` + `up.sh` to bounce).
- Assumes the stock `/etc/pf.conf`. If you run a custom PF config, read
  `up.sh` first — it inserts one NAT line after your `rdr-anchor` line.
- The Nord credentials endpoint is semi-official. If it breaks, use the
  generic WireGuard path with OpenVPN-style service credentials instead.
- Don't run your VPN provider's own app connected at the same time — its
  firewall/routing rules will fight these.

## Roadmap

The architecturally "right" version of this is a Network Extension
(`NETransparentProxyProvider`) matching flows by app signing identifier — no
group trick, no PF, per-app rules in a UI. That's how Mullvad's open-source
client does split tunneling on macOS. This repo is the zero-dependency,
auditable version; the NE app is the plan if there's interest.

## Security notes

- Your WireGuard private key lives in `~/.config/vpnonly/` with mode 600 and
  never leaves the machine. Revoke the Nord access token after use; it's only
  needed once to fetch the key.
- Everything that runs as root is in this repo and short enough to read in
  five minutes: `up.sh`, `down.sh`, `run.sh`, `vpnrun.c`.

## License

MIT
