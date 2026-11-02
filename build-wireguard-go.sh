#!/bin/bash
# Build the wireguard-go the CLI runs: pinned upstream source plus VPNonly's
# inner-source rewrite, the same patch the Mac app ships
# (app-engine/wireguard-go-nat.patch, tests included).
#
# Stock wireguard-go sends packets into the tunnel with your LAN address as
# their source. NordVPN's servers accept that; providers that enforce
# cryptokey routing (Mullvad, Proton, most self-hosted servers) silently drop
# every one, so the tunnel comes up and nothing gets through. up.sh turns the
# rewrite on by passing the tunnel address in WG_NAT_SOURCE.
#
#   ./build-wireguard-go.sh          builds ./wireguard-go, where up.sh looks
#   ./build-wireguard-go.sh <path>   builds it there instead (the formula)
#
# Needs Go and a network connection for the source and its Go modules. Run it
# as yourself: nothing here needs root.
set -euo pipefail
umask 022

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$DIR/wireguard-go}"
VERSION=0.0.20250522
SHA256=c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c
TREE_SHA256=d02a8fa9fd9e2b06dcdc3757e876e60235a0ebb2990bcc593a6e1f8398eb4853

# The release tarball carries the patch next to this script; a git checkout
# has it in the published engine directory. Either way it is the app's patch.
PATCH="$DIR/wireguard-go-nat.patch"
[ -f "$PATCH" ] || PATCH="$DIR/app-engine/wireguard-go-nat.patch"
[ -f "$PATCH" ] || { echo "wireguard-go-nat.patch not found" >&2; exit 1; }

command -v go >/dev/null 2>&1 || {
    echo "Go is required to build wireguard-go:  brew install go" >&2
    exit 1
}

BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpnonly-wireguard-go.XXXXXX")
cleanup() {
    case "$BUILD_DIR" in */vpnonly-wireguard-go.*)
        # The Go module cache is read-only, so rm needs write access first.
        chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
        rm -rf "$BUILD_DIR"
        ;;
    esac
}
trap cleanup EXIT

# Content hash of the extracted source: sha256 over every file's sha256 and
# path, sorted. It survives repackaging, which the archive hash does not:
# cgit regenerates snapshots and their bytes drift, and GitHub's mirror
# packages the same tree differently again.
treehash() {
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z |
        xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')
}

# Primary is the WireGuard project's own server, the fallback its official
# GitHub mirror. Whichever answers, the build goes ahead only if the extracted
# tree matches the pinned content hash.
SOURCE="$BUILD_DIR/wireguard-go-$VERSION"
ARCHIVE="$BUILD_DIR/wireguard-go.tar"
if curl -fsSL --retry 2 -o "$ARCHIVE" \
    "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-$VERSION.tar.xz"; then
    [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" = "$SHA256" ] ||
        echo "note: upstream repackaged the snapshot; relying on the content hash" >&2
else
    echo "note: git.zx2c4.com unreachable, using the GitHub mirror" >&2
    curl -fsSL --retry 2 -o "$ARCHIVE" \
        "https://github.com/WireGuard/wireguard-go/archive/refs/tags/$VERSION.tar.gz" || {
        echo "could not download wireguard-go $VERSION" >&2
        exit 1
    }
fi
tar -xf "$ARCHIVE" -C "$BUILD_DIR"
[ -d "$SOURCE" ] && [ "$(treehash "$SOURCE")" = "$TREE_SHA256" ] || {
    echo "wireguard-go source does not match the pinned content hash" >&2
    exit 1
}

patch -d "$SOURCE" -p1 --forward -s < "$PATCH" || {
    echo "wireguard-go NAT patch failed to apply" >&2
    exit 1
}

export GOCACHE="$BUILD_DIR/gocache" GOMODCACHE="$BUILD_DIR/gomodcache"
# The rewrite's own tests run before anything is built. A failure here means
# packets would be corrupted, so nothing is installed.
go -C "$SOURCE" test . >/dev/null || {
    echo "wireguard-go NAT tests failed" >&2
    exit 1
}
go -C "$SOURCE" build -buildvcs=false -trimpath -ldflags='-s -w' \
    -o "$BUILD_DIR/wireguard-go" .

"$BUILD_DIR/wireguard-go" --version 2>&1 | grep -Fq "wireguard-go v$VERSION" || {
    echo "the built wireguard-go reported an unexpected version" >&2
    exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 0755 "$BUILD_DIR/wireguard-go" "$OUT"
echo "Built wireguard-go $VERSION with VPNonly's source rewrite: $OUT"
