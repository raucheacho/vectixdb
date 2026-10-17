#!/bin/sh
# Builds the release archives of the C library and the CLI, from any host:
#   scripts/dist.sh 0.1.0 [platforms...]      (default: every platform)
# writes dist/vectixdb-<version>-<goos>-<goarch>.tar.gz and dist/SHA256SUMS.
#
#   include/vectixdb.h
#   lib/libvectixdb.a                static, recommended
#   lib/libvectixdb.{so,dylib}...    shared, for FFI (Python, Node, ...)
#   lib/pkgconfig/vectixdb.pc
#   bin/vectix                       command line tool
#   LICENSE NOTICE README.md CHANGELOG.md
set -eu
cd "$(dirname "$0")/.."
. scripts/platform.sh

[ $# -ge 1 ] || { echo "usage: $0 <version> [platforms...]" >&2; exit 2; }
version=${1#v}
shift
[ $# -eq 0 ] && set -- $ALL_PLATFORMS

zon=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
[ "$version" = "$zon" ] || { echo "version $version does not match build.zig.zon ($zon)" >&2; exit 1; }
api=$(sed -n 's/^pub const version = "\(.*\)";/\1/p' src/root.zig)
[ "$version" = "$api" ] || { echo "version $version does not match vtx_version in src/root.zig ($api)" >&2; exit 1; }

mkdir -p dist
for platform in "$@"; do
    name="vectixdb-$version-$(echo "$platform" | tr _ -)"
    out="dist/$name"
    rm -rf "$out"
    echo "building $name"
    build_platform "$platform" "$out" -Dstrip -Dshared

    libs_private=
    case "$platform" in linux_*) libs_private="-lpthread -lm" ;; esac
    mkdir -p "$out/lib/pkgconfig"
    cat >"$out/lib/pkgconfig/vectixdb.pc" <<EOF
prefix=\${pcfiledir}/../..
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: vectixdb
Description: Embedded hybrid search engine: vectors, BM25, exact substring, typed filters
URL: https://github.com/raucheacho/vectixdb
Version: $version
Cflags: -I\${includedir}
Libs: -L\${libdir} -lvectixdb
Libs.private: $libs_private
EOF
    cp LICENSE NOTICE README.md CHANGELOG.md "$out/"

    xattrs=
    [ "$(uname -s)" = Darwin ] && xattrs=--no-xattrs
    COPYFILE_DISABLE=1 tar $xattrs -czf "$out.tar.gz" -C dist "$name"
    rm -rf "$out"
done

(cd dist && shasum -a 256 vectixdb-*.tar.gz >SHA256SUMS)
echo "archives and SHA256SUMS in dist/"
