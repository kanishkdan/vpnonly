#!/bin/bash
# Rebuild the bundled wg from pinned upstream source for macOS 13.
# Homebrew bottles inherit the OS of the bottle builder; copying one made a
# nominally macOS-13 app contain a command that required macOS 26.
set -euo pipefail
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

DIR0="$(cd "$(dirname "$0")" && pwd)"
VERSION=1.0.20260223
SHA256=af459827b80bfd31b83b08077f4b5843acb7d18ad9a33a2ef532d3090f291fbf
BUILD_DIR=$(/usr/bin/mktemp -d /tmp/vpnonly-wg-build.XXXXXX)
ARCHIVE="$BUILD_DIR/wireguard-tools.tar.xz"

cleanup() {
    case "$BUILD_DIR" in /tmp/vpnonly-wg-build.*)
        /bin/rm -rf "$BUILD_DIR"
        ;;
    esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/curl -fL --retry 2 \
    "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$VERSION.tar.xz" \
    -o "$ARCHIVE"
ACTUAL=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')
[ "$ACTUAL" = "$SHA256" ] || {
    echo "wireguard-tools source checksum mismatch" >&2
    exit 1
}

/usr/bin/tar -xf "$ARCHIVE" -C "$BUILD_DIR"
env MACOSX_DEPLOYMENT_TARGET=13.0 CFLAGS="-O2 -mmacosx-version-min=13.0" \
    /usr/bin/make -C "$BUILD_DIR/wireguard-tools-$VERSION/src" wg
/usr/bin/install -m 0755 "$BUILD_DIR/wireguard-tools-$VERSION/src/wg" "$DIR0/bin/wg"
echo "Built wireguard-tools $VERSION for macOS 13"
