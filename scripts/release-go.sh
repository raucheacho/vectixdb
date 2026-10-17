#!/bin/sh
# Makes the Go module of a release installable with "go get", without Zig:
#   scripts/release-go.sh 0.1.0
#
# On top of the current commit, it creates a release commit that adds the
# prebuilt static libraries (bindings/go/lib/<platform>/libvectixdb.a, which
# branches never contain) and pins the platform modules to this version, then
# tags it:
#   bindings/go/v<version>
#   bindings/go/lib/<platform>/v<version>, one per platform
# The commit is on no branch; the tags keep it. Nothing is pushed: the release
# workflow pushes the tags (git push origin <tags>).
set -eu
cd "$(dirname "$0")/.."
. scripts/platform.sh

[ $# -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
version=${1#v}
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "the working tree has changes" >&2; exit 1; }
cmp -s include/vectixdb.h bindings/go/include/vectixdb.h || { echo "bindings/go/include/vectixdb.h differs from include/vectixdb.h" >&2; exit 1; }

STRIP=1 ./scripts/go-libs.sh all

start=$(git symbolic-ref -q --short HEAD || git rev-parse HEAD)
git checkout -q --detach
sed -i.bak "s#^\(	github.com/raucheacho/vectixdb/bindings/go/lib/[a-z0-9_]*\) v0.0.0#\1 v$version#" bindings/go/go.mod
rm -f bindings/go/go.mod.bak
git add bindings/go/go.mod
for platform in $ALL_PLATFORMS; do
    git add -f "bindings/go/lib/$platform/libvectixdb.a"
done
git commit -q -m "go module v$version: prebuilt libraries"

tags="bindings/go/v$version"
for platform in $ALL_PLATFORMS; do
    tags="$tags bindings/go/lib/$platform/v$version"
done
for t in $tags; do
    git tag -a "$t" -m "VectixDB $version" HEAD
done
git checkout -q "$start"
echo "release commit $(git rev-parse --short "bindings/go/v$version^{commit}"), tags:"
for t in $tags; do echo "  $t"; done
