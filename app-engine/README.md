# VPNonly privileged engine

This directory is the exact source snapshot for VPNonly's privileged helper.
It is generated from the private application repository by the release command;
`SOURCE-MANIFEST.sha256` makes accidental drift visible.

The engine:

- asks macOS to allocate a free `utunN` interface instead of claiming a fixed one;
- records and validates VPNonly's exact root process, interface and socket;
- changes only the dedicated `com.apple/vpnonly` PF anchor during normal use;
- routes or blocks private per-app groups without changing the Mac's default route;
- tears down only a tunnel that its root-owned state proves VPNonly created.

The historical command-line prototype remains at the repository root for
reference. It is not the engine shipped in the current Mac app and is not a
supported installation path on current macOS.

VPNonly's own source in this directory is MIT licensed. The bundled WireGuard
programs retain their upstream licences; see `licenses/` and
`THIRD-PARTY-NOTICES.txt`.
