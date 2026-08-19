# vpnonly

**[Website](https://vpnonly.app/)** · Prefer a menu bar app over the CLI? [VPNonly for Mac — $19](https://dodo.pe/vpnonly-github)

**Per-app VPN split tunneling for macOS.** Route *only the apps you choose*
through a WireGuard VPN while everything else on your Mac uses your normal
connection. ~300 lines of shell + C. No kernel extensions, no changes to your
default route, fully reversible with one command (or a reboot).

Born out of a concrete itch: NordVPN has no split tunneling on macOS at all,
and I wanted exactly one app inside the VPN. Some providers do offer it now
(ExpressVPN, Surfshark, Mullvad, Windscribe, and Proton experimentally) but
each only works with its own service, and all of them work the other way
round — your whole Mac joins the VPN and you exclude apps from it. Here,
nothing is tunneled unless you ask for it.
[Comparison, with sources.](https://vpnonly.app/guides/mac-vpn-split-tunneling.html)

```sh
sudo ./up.sh mullvad-sg.conf                  # any provider: hand it their .conf
sudo ./run.sh /Applications/CapCut.app        # this app, and only this app, is in the VPN
sudo ./status.sh                              # what's routed, and both exit IPs
sudo ./down.sh                                # everything back to stock
```

On NordVPN there's no config file to download, so fetch a key once instead:

```sh
./fetch-creds.sh                              # paste an access token, once
sudo ./up.sh                                  # Singapore by default
sudo COUNTRY=us ./up.sh                       # or pick a country
```

## Demo

<!-- VIDEO: drag the .mp4 into a GitHub issue comment, copy the
     user-images.githubusercontent.com URL it gives you, and paste it below as
     <video src="..."></video>. GitHub renders that inline with a play button.
     An external link (YouTube, vpnonly.app) will not embed — it just links. -->

See it working: **[vpnonly.app](https://vpnonly.app/)** — one app on a Singapore
IP while the browser next to it stays home.

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

Works on Intel and Apple Silicon: the launcher is compiled on your machine, so
there's no prebuilt binary to match. (The paid menu bar app is Apple Silicon
only for now — the scripts aren't.)

## Providers

**NordVPN** (built-in adapter): generate an access token at
[my.nordaccount.com → Manual configuration → Access token](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/),
then `./fetch-creds.sh` and paste it. Exit country: `sudo COUNTRY=us ./up.sh`
(default `sg`).

**Anything else that speaks WireGuard** (Mullvad, Proton, IVPN, AirVPN, a
server on your own VPS): download a `.conf` from them and point `up.sh` at it.
The key, the endpoint and the tunnel address all come out of the file, so
there's nothing to copy by hand:

```sh
sudo ./up.sh ~/Downloads/mullvad-sg.conf
```

Providers hand out *wg-quick* configs, which carry `Address`, `DNS` and
sometimes `MTU` lines that plain `wg setconf` rejects. `parse-wg.py` strips
those and reports the tunnel address separately, which is what the NAT rule
needs — Nord uses 10.5.0.2, Mullvad hands out 10.64.x.x, your own server is
whatever you chose.

If you'd rather pass the pieces yourself:

```sh
sudo ENDPOINT=<server-ip:port> PEER_KEY=<server-pubkey> CLIENT_IP=<your-assigned-ip> ./up.sh
```

## Set it up with Claude Code, Codex or Cursor

Everything here is shell scripts and one small C file, which is exactly the
sort of thing a coding agent can drive. Paste this into Claude Code, Codex or
Cursor and let it walk you through it:

```text
Set up vpnonly on my Mac. It routes individual apps through a WireGuard VPN
while the rest of the machine stays on my normal connection.

Repo: https://github.com/kanishkdan/vpnonly

Do this with me, one step at a time, and explain anything that needs sudo
before you run it:

1. brew install wireguard-go wireguard-tools
2. Clone the repo and cd into it.
3. Ask me which VPN I use.
   - NordVPN: have me generate an access token at my.nordaccount.com >
     Manual configuration > Access token, then run ./fetch-creds.sh
   - Anything else (Mullvad, Proton, IVPN, AirVPN, my own server): ask me for
     the path to the .conf file they gave me.
4. Bring the tunnel up. Nothing is routed yet at this point:
     sudo ./up.sh                    (NordVPN, add COUNTRY=us to pick a country)
     sudo ./up.sh /path/to/my.conf   (any other provider)
5. Ask which app I want on the VPN, then:
     sudo ./run.sh /Applications/<App>.app
6. Prove it worked by showing me both IPs side by side:
     curl -s https://api.ipify.org
     sudo ./run.sh /usr/bin/curl -s https://api.ipify.org
   They should differ. If they don't, stop and tell me why.
7. Show me how to undo everything: sudo ./down.sh

Two things to know: don't try to route Safari, because WebKit connections
can't be matched by the firewall, and don't run my VPN provider's own app at
the same time, because its rules will fight these.
```

If you'd rather not hand an agent sudo, the same steps are above and they're
short enough to read first.

## Verifying

`status.sh` answers the only question that matters — is this app's traffic
actually going somewhere different?

```sh
$ sudo ./status.sh
tunnel:   up on utun9 (10.5.0.2)
received: 314665312 bytes
in vpn:
  4821  CapCut
your ip:  182.69.179.136
vpn ip:   103.75.11.42
```

Two different addresses means it's working. Under the hood it's just:

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
- **Safari can't be routed, and neither can other WebKit apps.** WebKit hands
  its connections to separate system processes that macOS starts on its own, so
  they never carry the group and PF has nothing to match. Proton VPN's macOS
  split tunneling documents the same limitation. Chrome, Firefox, Arc and Brave
  are all fine.
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
