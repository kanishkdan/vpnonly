# VPNonly

Route **only the apps you choose** through a WireGuard VPN on macOS. Everything
else on the Mac keeps its normal connection.

Most VPNs are all or nothing: you connect, and your browser, video calls and
banking all move to another country. This does the opposite. Nothing is
tunneled unless you ask for it.

Around 350 lines of shell and one small C file. No kernel extension, no
Network Extension entitlement, and your default route is never touched.

## Setup

```sh
brew install wireguard-go wireguard-tools
git clone https://github.com/kanishkdan/vpnonly && cd vpnonly
```

You also need Xcode Command Line Tools, for `cc` to build the 30-line launcher.
macOS offers to install them the first time it's needed.

Then pick your provider.

**NordVPN.** There's no config file to download, so fetch a key once. Generate
an access token at
[my.nordaccount.com → Manual configuration → Access token](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/),
then:

```sh
./fetch-creds.sh          # paste the token, once
```

**Anything else that speaks WireGuard** (Mullvad, Proton, IVPN, AirVPN, your
own server): download a `.conf` from them. Nothing to copy by hand.

## Using it

```sh
sudo ./up.sh                                  # NordVPN, Singapore by default
sudo COUNTRY=us ./up.sh                       # or pick a country
sudo ./up.sh ~/Downloads/mullvad-sg.conf      # or any provider's config

sudo ./run.sh                                 # pick an app from a list
sudo ./status.sh                              # what's routed, and both exit IPs
sudo ./down.sh                                # everything back to normal
```

`up.sh` brings up the tunnel but routes nothing. `run.sh` is what puts an app
inside it, and with no arguments it just asks:

```
$ sudo ./run.sh
Apps on this Mac:
   1  Android Studio
   2  CapCut
   3  ChatGPT
   ...
Pick a number (or q to quit): 2

launched through the tunnel (pid 40317): CapCut
check it with: sudo ./status.sh
```

Or name it directly, if you'd rather not scroll:

```sh
sudo ./run.sh CapCut                          # by name
sudo ./run.sh /Applications/CapCut.app        # by path
sudo ./run.sh /usr/bin/curl https://api.ipify.org   # any binary, with arguments
```

Safari is left out of the list on purpose. See the limitations below.

Bringing it up looks like this:

```
server: sg668.nordvpn.com (103.75.11.42:51820)
interface: utun7
exit IP via tunnel: 187.15.100.99
your normal IP:     223.181.33.133
Tunnel up. Launch an app inside it:  sudo ./run.sh /Applications/YourApp.app
```

Two different addresses is the whole proof. `status.sh` shows the same
comparison at any time, plus which processes are currently in the group.

## How it works

macOS's built-in PF firewall can't match packets by *application*, but it can
match by *unix group*. That's the entire trick.

1. **`up.sh`** starts a userspace WireGuard interface, asking the kernel for a
   free `utunN` rather than claiming a fixed name, and brings it up **without
   installing a default route** so nothing uses it by default. It creates a
   group called `vpnonly` and loads three rules into VPNonly's own PF anchor:

   ```
   nat on utun7 inet from any to any -> 10.5.0.2
   pass out quick on ! lo0 route-to (utun7 10.5.0.2) inet proto { tcp udp } \
       from any to any group vpnonly keep state
   block return out quick on ! lo0 from any to any group vpnonly
   ```

   The `block` rule is the kill switch. If the tunnel goes down, group traffic
   is refused rather than leaking to your ISP, and `return` means the app fails
   immediately instead of hanging until it times out.

2. **`vpnrun`** (30 lines of C, run via sudo) launches your app with its group
   set to `vpnonly`, then drops privileges back to you. Every helper process
   the app spawns inherits the group, so Chromium-style multi-process apps work.

Group membership is fixed when a process starts and can't be changed
afterwards, which is why an app has to be launched through `run.sh` rather than
switched over while it's already open.

**`/etc/pf.conf` is never read, modified or reloaded.** Rules live in a
dedicated anchor under `com.apple/`, which macOS already evaluates, so other
firewall tools keep their rules and VPNonly keeps its own. `down.sh` clears
just that anchor and stops just the process it started.

## Limitations

- Apple Silicon and Intel both work here; the compiled launcher is built on
  your machine.
- **Safari and other WebKit apps can't be routed.** WebKit hands its
  connections to separate system processes that macOS starts on its own, so
  they never carry the group and PF has nothing to match. Proton VPN's macOS
  split tunneling documents the same limitation. Chrome, Firefox, Arc and Brave
  are fine.
- **DNS queries are not tunneled.** Apps resolve via the system resolver, which
  runs outside the group, so lookups still exit over your normal connection
  even though the connections themselves are tunneled. If your threat model is
  "hide which hosts I talk to from my ISP", this matters. If it's "give one app
  a different exit IP", it mostly doesn't.
- IPv6 is blocked for grouped apps rather than tunneled. No leak, but no v6.
- No automatic reconnect if the server drops. `down.sh` then `up.sh`.
- Don't run your provider's own app *connected* at the same time. `up.sh`
  checks for this and refuses, because a tunnel inside another tunnel usually
  breaks on MTU.

## Verifying

```sh
curl -s https://api.ipify.org                          # your normal IP
sudo ./run.sh /usr/bin/curl -s https://api.ipify.org   # the VPN exit IP
```

## Roadmap

The architecturally "right" version is a Network Extension
(`NETransparentProxyProvider`) matching flows by signing identifier, which is
how Mullvad's client does split tunneling on macOS. This repo is the
zero-dependency, auditable version.

## Security notes

- Your WireGuard private key lives in `~/.config/vpnonly/` with mode 600 and
  never leaves the machine. Revoke the Nord access token after use; it's only
  needed once to fetch the key.
- Everything that runs as root is in this repo and short enough to read in five
  minutes: `up.sh`, `down.sh`, `run.sh`, `status.sh`, `vpnrun.c`.

## The Mac app

There's also a menu bar app that does this with a list of every app on your
Mac, a country picker, per-app switches you can toggle without relaunching, and
automatic updates. It's $19 once for two Macs:
[vpnonly.app](https://vpnonly.app). Two-minute demo of the app:
[youtu.be/C9L9OaURekc](https://youtu.be/C9L9OaURekc).

The privileged engine it installs is published in
[`app-engine/`](app-engine/) with a checksum manifest generated by the same
command that builds each release, so you can read exactly what runs as root
before trusting it. The scripts above are the same idea without the interface.

## Licence

MIT for everything that runs as root: the scripts at the repository root and
everything under [`app-engine/`](app-engine/). Read it, audit it, reuse it.

The compiled app (the `VPNonly-*.zip` releases) and the website under `docs/`
are not MIT. The app is a paid product and redistributing it isn't permitted;
its terms are at [vpnonly.app/terms](https://vpnonly.app/terms.html).
[`LICENSE`](LICENSE) sets out the split in full.

Bundled WireGuard and Sparkle components retain their upstream licences. See
[`app-engine/THIRD-PARTY-NOTICES.txt`](app-engine/THIRD-PARTY-NOTICES.txt).
