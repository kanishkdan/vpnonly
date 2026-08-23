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

/usr/bin/curl -fL --retry 2 \
    "https://git.zx2c4.com/wireguard-go/snapshot/wireguard-go-$VERSION.tar.xz" \
    -o "$ARCHIVE"
ACTUAL=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')
[ "$ACTUAL" = "$SHA256" ] || {
    echo "wireguard-go source checksum mismatch" >&2
    exit 1
}

/usr/bin/tar -xf "$ARCHIVE" -C "$BUILD_DIR"
SOURCE="$BUILD_DIR/wireguard-go-$VERSION"
/bin/mkdir -p "$BUILD_DIR/gocache" "$BUILD_DIR/gomodcache" "$DIR0/bin"

env GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 GOTOOLCHAIN=local \
    GOCACHE="$BUILD_DIR/gocache" GOMODCACHE="$BUILD_DIR/gomodcache" \
    MACOSX_DEPLOYMENT_TARGET=13.0 \
    "$GO_BIN" -C "$SOURCE" build -buildvcs=false -trimpath \
    -ldflags='-s -w -buildid=' -o "$BUILD_DIR/wireguard-go" .

"$BUILD_DIR/wireguard-go" --version 2>&1 | \
    /usr/bin/grep -Fq "wireguard-go v$VERSION" || {
        echo "wireguard-go reported an unexpected version" >&2
        exit 1
    }
/usr/bin/install -m 0755 "$BUILD_DIR/wireguard-go" "$DIR0/bin/wireguard-go"
echo "Built wireguard-go $VERSION for macOS 13"
