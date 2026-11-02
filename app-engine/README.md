# VPNonly privileged engine

This directory is the exact source snapshot for VPNonly's privileged helper.
It is generated from the private application repository by the release command;
`SOURCE-MANIFEST.sha256` makes accidental drift visible.

The engine:

- asks macOS to allocate a free `utunN` interface instead of claiming a fixed one;
- records and validates VPNonly's exact root process, interface and socket;
- changes only the dedicated `com.apple/vpnonly` PF anchor during normal use;
- routes or blocks private per-app groups without changing the Mac's default route;
- with the app's Allow Local Network setting on (the default), lets those
  groups reach the private networks, /16 or narrower, that the Mac is on over
  Wi-Fi, Ethernet or a bridge, from its own address there, plus link-local
  addresses from its own link-local address and link-local multicast
  (224.0.0.0/24). Each network's router is reachable only on ports 53, 80 and
  443, which on most routers keeps its port-mapping services (UPnP, NAT-PMP,
  PCP) out of reach, and ports 1900 and 5351 are blocked on every local
  address. Every other destination still goes through the tunnel, and the
  engine leaves local access out while a system proxy is set or the proxy
  settings can't be read;
- tears down only a tunnel that its root-owned state proves VPNonly created.

The command-line version at the repository root (`vpnonly`, installed with
Homebrew) is a separate, smaller implementation of the same idea, and it is
supported. It is not this engine: it loads its own `com.apple/vpnonly-cli` PF
anchor and keeps its own state. It does share one file with this engine: the
inner-source patch (`wireguard-go-nat.patch`), which its Homebrew formula
builds into `wireguard-go` so the CLI, like the Mac app, works with any
WireGuard provider.

VPNonly's own source in this directory is MIT licensed. The bundled WireGuard
programs retain their upstream licences; see `licenses/` and
`THIRD-PARTY-NOTICES.txt`.
