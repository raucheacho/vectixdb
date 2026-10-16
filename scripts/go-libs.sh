#!/bin/sh
# Builds the static library for the Go binding, for the host or for the
# platforms given as GOOS_GOARCH arguments (e.g. linux_amd64 darwin_arm64).
set -eu
cd "$(dirname "$0")/.."

host="$(go env GOOS)_$(go env GOARCH)"
[ $# -eq 0 ] && set -- "$host"

for platform in "$@"; do
    # x86-64-v2 (2009 onwards) has SSE4.2, hence the hardware CRC32C.
    cpu=baseline
    case "$platform" in
        darwin_arm64) target=aarch64-macos.13.0 ;;
        darwin_amd64) target=x86_64-macos.13.0 cpu=x86_64_v2 ;;
        linux_amd64) target=x86_64-linux-gnu cpu=x86_64_v2 ;;
        linux_arm64) target=aarch64-linux-gnu ;;
        windows_amd64) target=x86_64-windows-gnu cpu=x86_64_v2 ;;
        *) echo "unsupported platform: $platform" >&2; exit 1 ;;
    esac
    zig build -Drelease -Dtarget="$target" -Dcpu="$cpu" --prefix "bindings/go/lib/$platform"
    rm -rf "bindings/go/lib/$platform/include"
    echo "built bindings/go/lib/$platform"
done
