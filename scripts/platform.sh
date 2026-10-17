# Sourced by the build scripts: Zig build of the library for one platform.
#
# build_platform <goos_goarch> <prefix> [zig build options...]
# installs lib/, include/ and bin/ under <prefix>. It sets platform, prefix,
# target and cpu; its own temporary names start with an underscore.

build_platform() {
    platform=$1 prefix=$2
    shift 2
    # x86-64-v2 (2009 onwards) has SSE4.2, hence the hardware CRC32C.
    # glibc 2.28: Debian 10, Ubuntu 20.04, RHEL 8 and later.
    cpu=baseline
    case "$platform" in
        darwin_arm64) target=aarch64-macos.13.0 ;;
        darwin_amd64) target=x86_64-macos.13.0 cpu=x86_64_v2 ;;
        linux_amd64) target=x86_64-linux-gnu.2.28 cpu=x86_64_v2 ;;
        linux_arm64) target=aarch64-linux-gnu.2.28 ;;
        *) echo "unsupported platform: $platform" >&2; return 1 ;;
    esac
    zig build -Drelease -Dtarget="$target" -Dcpu="$cpu" --prefix "$prefix" "$@"
    if [ "$platform" = darwin_amd64 ]; then
        # The archive carries compiler_rt (__zig_probe_stack) but Zig leaves
        # its members misaligned, and Apple's linker then skips them all.
        # Repack it in the Darwin format.
        _lib=$(cd "$prefix/lib" && pwd)/libvectixdb.a
        _repack=$(mktemp -d)
        (cd "$_repack" && zig ar x "$_lib" && chmod 644 ./*.o && rm -f "$_lib" && zig ar rcs --format=darwin "$_lib" ./*.o)
        rm -rf "$_repack"
    fi
}

ALL_PLATFORMS="darwin_arm64 darwin_amd64 linux_amd64 linux_arm64"
