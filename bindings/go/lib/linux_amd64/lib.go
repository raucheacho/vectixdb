//go:build linux && amd64

// Package lib links the VectixDB static library built for linux/amd64.
// The binding imports it on that platform; it has no API of its own.
//
// libvectixdb.a is built by scripts/go-libs.sh and committed only in
// release tags, so that "go get" works without Zig.
package lib

// #cgo LDFLAGS: ${SRCDIR}/libvectixdb.a -lm
import "C"
