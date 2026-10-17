module github.com/raucheacho/vectixdb/bindings/go

go 1.24.0

// The static library of each platform is its own module (bindings/go/lib),
// committed only in release tags. Release tags pin these versions; the
// replace directives serve development in this repository and are ignored
// by the projects that depend on the binding.
require (
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_amd64 v0.1.0
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_arm64 v0.1.0
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_amd64 v0.1.0
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_arm64 v0.1.0
)

replace (
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_amd64 => ./lib/darwin_amd64
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_arm64 => ./lib/darwin_arm64
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_amd64 => ./lib/linux_amd64
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_arm64 => ./lib/linux_arm64
)
