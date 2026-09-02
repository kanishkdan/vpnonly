#!/bin/bash
# Rebuild the bundled wireguard-go from pinned upstream source. The binary is
# ignored by git, so a release must never silently reuse whichever local copy
# happens to be present on the release Mac.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/go/bin
export PATH

DIR0="$(cd "$(dirname "$0")" && pwd)"
VERSION=0.0.20250522
SHA256=c7eeffb13e5eb43b93e54a21d78dd71414771af9e07112da5275690493695c9c
TREE_SHA256=d02a8fa9fd9e2b06dcdc3757e876e60235a0ebb2990bcc593a6e1f8398eb4853
BUILD_DIR=$(/usr/bin/mktemp -d /tmp/vpnonly-wireguard-go-build.XXXXXX)
ARCHIVE="$BUILD_DIR/wireguard-go.tar.xz"

cleanup() {
    case "$BUILD_DIR" in /tmp/vpnonly-wireguard-go-build.*)
        /bin/chmod -R u+w "$BUILD_DIR" 2>/dev/null || true
        /bin/rm -rf "$BUILD_DIR"
        ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

GO_BIN=$(command -v go 2>/dev/null || true)
[ -x "$GO_BIN" ] || {
    echo "Go is required to build wireguard-go" >&2
    exit 1
}

# Content hash of the extracted source: sha256 over every file's sha256 and
# path, sorted. Independent of how the archive was packaged, which is the
# point — cgit regenerates snapshots and their bytes drift between cgit
# versions (three different archive checksums exist today for this one
# source), and GitHub's mirror packages it differently again.
treehash() {
    (cd "$1" && /usr/bin/find . -type f -print0 | LC_ALL=C /usr/bin/sort -z |
        /usr/bin/xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 |
        /usr/bin/awk '{print $1}')
}

# Primary is the WireGuard project's own server; the fallback is the
# project's official GitHub mirror, used when the primary is down or has
# repackaged the snapshot. Whatever the source, the build proceeds only if
# the extracted tree matches the pinned content hash.
fetch_source() {
    local override="$1" primary="$2" mirror="$3"
    if [ -n "$override" ]; then
        /bin/cp "$override" "$ARCHIVE"
    elif /usr/bin/curl -fsSL --retry 2 "$primary" -o "$ARCHIVE"; then
        local actual
        actual=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')
        [ "$actual" = "$SHA256" ] ||
            echo "note: upstream repackaged the snapshot; relying on the content hash" >&2
    else
        echo "note: primary source unreachable, using the GitHub mirror" >&2
        /usr/bin/curl -fsSL --retry 2 "$mirror" -o "$ARCHIVE" || {
            echo "could not fetch source from upstream or its mirror" >&2
            exit 1
        }
    fi
    /usr/bin/tar -xf "$ARCHIVE" -C "$BUILD_DIR"
    local got
    got=$(treehash "$SOURCE")
    [ "$got" = "$TREE_SHA256" ] || {
        echo "source content hash mismatch: $got" >&2
        exit 1
    }
}

SOURCE="$BUILD_DIR/wireguard-go-$VERSION"
fetch_source "${WIREGUARD_GO_ARCHIVE:-}" \
    "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-$VERSION.tar.xz" \
    "https://github.com/WireGuard/wireguard-go/archive/refs/tags/$VERSION.tar.gz"

# VPNonly's inner-source rewrite (see the comment atop source_nat.go in the
# patch). Applied to the checksum-verified upstream source, never vendored,
# so the whole local change is this one reviewable file.
/usr/bin/patch -d "$SOURCE" -p1 --forward -s < "$DIR0/wireguard-go-nat.patch" || {
    echo "wireguard-go NAT patch failed to apply" >&2
    exit 1
}
/bin/mkdir -p "$BUILD_DIR/gocache" "$BUILD_DIR/gomodcache" "$DIR0/bin"

env GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local \
    GOCACHE="$BUILD_DIR/gocache" GOMODCACHE="$BUILD_DIR/gomodcache" \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    "$GO_BIN" -C "$SOURCE" build -buildvcs=false -trimpath \
    -ldflags='-s -w -buildid=' -o "$BUILD_DIR/wireguard-go" .

env GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local \
    GOCACHE="$BUILD_DIR/gocache" GOMODCACHE="$BUILD_DIR/gomodcache" \
    "$GO_BIN" -C "$SOURCE" test -run \
    'TestTCPEgressAndReply|TestUDPZeroChecksumStaysZero|TestFragmentRewritesIPOnly|TestICMPEcho|TestPassthroughs|TestSweep' \
    . >/dev/null || {
    echo "wireguard-go NAT tests failed" >&2
    exit 1
}

"$BUILD_DIR/wireguard-go" --version 2>&1 | \
    /usr/bin/grep -Fq "wireguard-go v$VERSION" || {
        echo "wireguard-go reported an unexpected version" >&2
        exit 1
    }
/usr/bin/install -m 0755 "$BUILD_DIR/wireguard-go" "$DIR0/bin/wireguard-go"
echo "Built wireguard-go $VERSION for macOS 13"
