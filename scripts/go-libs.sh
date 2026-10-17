#!/bin/sh
# Builds the static library of the Go binding into
# bindings/go/lib/<goos_goarch>/libvectixdb.a, for the host or for the
# platforms given as arguments (e.g. linux_amd64 darwin_arm64; "all" for
# every supported one). STRIP=1 drops debug info, as releases do.
set -eu
cd "$(dirname "$0")/.."
. scripts/platform.sh

[ $# -eq 0 ] && set -- "$(go env GOOS)_$(go env GOARCH)"
[ "$1" = all ] && set -- $ALL_PLATFORMS

strip=
[ "${STRIP:-}" = 1 ] && strip=-Dstrip

for platform in "$@"; do
    tmp=$(mktemp -d)
    build_platform "$platform" "$tmp" $strip
    cp "$tmp/lib/libvectixdb.a" "bindings/go/lib/$platform/libvectixdb.a"
    rm -rf "$tmp"
    echo "built bindings/go/lib/$platform/libvectixdb.a"
done
