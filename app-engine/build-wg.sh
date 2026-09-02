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
TREE_SHA256=cb77b0f08753fe7bd5c321b73bce221bef8466b666ed55cd0c63b12f95bfed8b
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

SOURCE="$BUILD_DIR/wireguard-tools-$VERSION"
fetch_source "${WIREGUARD_TOOLS_ARCHIVE:-}" \
    "https://git.zx2c4.com/wireguard-tools/snapshot/wireguard-tools-$VERSION.tar.xz" \
    "https://github.com/WireGuard/wireguard-tools/archive/refs/tags/v$VERSION.tar.gz"
env MACOSX_DEPLOYMENT_TARGET=13.0 CFLAGS="-O2 -mmacosx-version-min=13.0" \
    /usr/bin/make -C "$BUILD_DIR/wireguard-tools-$VERSION/src" wg
/usr/bin/install -m 0755 "$BUILD_DIR/wireguard-tools-$VERSION/src/wg" "$DIR0/bin/wg"
echo "Built wireguard-tools $VERSION for macOS 13"
