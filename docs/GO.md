# Go binding

Package `github.com/raucheacho/vectixdb/bindings/go` (import it as `vectixdb`). It is a thin cgo wrapper over the C API: the same calls, Go types, no logic of its own.

## Installing

```sh
go get github.com/raucheacho/vectixdb/bindings/go@v0.1.0
```

Releases carry the prebuilt static library of every supported platform, so a build needs a C compiler for cgo but not Zig. Supported: `darwin_arm64`, `darwin_amd64` (macOS 13+), `linux_amd64`, `linux_arm64` (glibc). Windows is not supported yet.

### How the module is laid out

- **The header** is in the module (`bindings/go/include/vectixdb.h`), a copy of `include/vectixdb.h` that CI keeps identical.
- **The libraries** are one module per platform, `bindings/go/lib/<goos>_<goarch>`, which the binding imports on that platform only. Their `libvectixdb.a` is never on a branch: `scripts/release-go.sh` adds the four libraries in a release commit and tags it `bindings/go/v<version>` and `bindings/go/lib/<platform>/v<version>`. `go get` downloads the four (about 4.5 MB in all).
- **`go mod vendor`** drops the `.a` files (they are not Go files); do not vendor the binding.

### Working from a checkout

To use unreleased changes, or to change the engine, point the application at a checkout. Every module needs a `replace`, since those of the binding's own `go.mod` do not apply to the application:

```
// go.mod of the application
require github.com/raucheacho/vectixdb/bindings/go v0.0.0

replace (
	github.com/raucheacho/vectixdb/bindings/go => ../vectixdb/bindings/go
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_amd64 => ../vectixdb/bindings/go/lib/darwin_amd64
	github.com/raucheacho/vectixdb/bindings/go/lib/darwin_arm64 => ../vectixdb/bindings/go/lib/darwin_arm64
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_amd64 => ../vectixdb/bindings/go/lib/linux_amd64
	github.com/raucheacho/vectixdb/bindings/go/lib/linux_arm64 => ../vectixdb/bindings/go/lib/linux_arm64
)
```

Then build the library with Zig 0.16:

```sh
./scripts/go-libs.sh                              # host platform
./scripts/go-libs.sh linux_amd64 linux_arm64      # cross-compiled, from any OS
./scripts/go-libs.sh all                          # every platform; STRIP=1 drops debug info, as releases do
```

Lorag works this way, with a `Makefile` rule that builds the library when it is missing:

```make
VECTIXDB ?= ../vectixdb
ENGINE_LIB = $(VECTIXDB)/bindings/go/lib/$(shell go env GOOS)_$(shell go env GOARCH)/libvectixdb.a
$(ENGINE_LIB):
	$(VECTIXDB)/scripts/go-libs.sh
build: $(ENGINE_LIB)
	CGO_ENABLED=1 go build ./...
```

## API

| Go | C | Notes |
| --- | --- | --- |
| `Open(path, *Options)` | `vtx_open` | `Options{ReadOnly, Durability, CheckpointAfter, Repair}`; `nil` for defaults |
| `(*DB).Close()` | `vtx_close` | safe to call twice |
| `Sync`, `Checkpoint`, `Compact(coll)` | | |
| `Stats()`, `Count(coll)`, `Collections()` | | |
| `CreateCollection(name, Schema)`, `DropCollection(name)` | | `Schema{Vector *VectorSpec, Fields []Field, BM25K1, BM25B}` |
| `Write(ops ...Op)` | `vtx_write` | ops from `Put(coll, Doc)` and `Delete(coll, id)`; returns the sequence |
| `PutDocs(coll, docs...)` | | `Write` with one put per document |
| `Search(coll, Query)` | `vtx_search` | `[]Result` |
| `Get(coll, id)` | `vtx_get` | `*Result`, `nil` when absent |
| `Eq`, `In`, `Range`, `Gt`, `Gte`, `Lt`, `Lte`, `Exists`, `And`, `Or`, `Not` | `vtx_filter_*` | `In` is an `Or` of `Eq` |
| `Version()` | `vtx_version` | |

### Values

Field values are typed: `Text`, `Keyword`, `Keywords`, `Int`, `Float`, `Bool`, `Time` (a `time.Time`, stored in milliseconds). A `Result.Fields` map holds the same types; use a type switch:

```go
switch v := r.Fields["page"].(type) {
case vectixdb.Int:
    page = int(v)
}
```

### Errors

Every error is a `*vectixdb.Error` with a `Code` and a message from the engine. Compare with `errors.Is`:

```go
if errors.Is(err, vectixdb.ErrLocked) { … }
```

The sentinels are `ErrNoMemory`, `ErrIO`, `ErrCorrupt`, `ErrLocked`, `ErrReadOnly`, `ErrPoisoned`, `ErrNotFound`, `ErrExists`, `ErrInvalid`, `ErrNoSpace`, `ErrTooLarge`, and `ErrClosed` (Go only: the handle was closed). What to do with each: [INTEGRATION.md](INTEGRATION.md#errors-you-must-handle).

### Concurrency

- A `*DB` is safe for concurrent use; share one per process.
- Searches run in parallel and writes are serialized by the engine.
- `Close` waits for calls in flight.
- Each call locks the goroutine to its OS thread for its duration, so the engine's thread-local error message is read on the right thread.

## Testing

```sh
cd bindings/go
go test -race ./...
go test -bench . -run ^$ ./...        # BenchmarkHybridSearch
```

In a checkout, the tests run against the library of the host platform: build it first with `scripts/go-libs.sh`.

## Cross-compiling an application

cgo needs a C toolchain for the target:
- **Linux** from any OS: Zig provides one, `CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="zig cc -target x86_64-linux-gnu.2.28" go build ./cmd/app` (glibc 2.28: Debian 10, Ubuntu 20.04, RHEL 8 and later). Use `aarch64-linux-gnu.2.28` for arm64.
- **macOS** on macOS only, with Apple's clang (`CC="clang -arch x86_64"` for Intel from Apple silicon): the Go runtime links Apple frameworks, which Zig does not provide.

## Docker

The library links against glibc: use a Debian or Ubuntu based image, not Alpine (musl). With a released version, the image needs nothing more than Go and a C compiler:

```dockerfile
FROM golang:1.24-bookworm AS build
WORKDIR /src/app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=1 go build -o /out/app ./cmd/app

FROM debian:bookworm-slim
COPY --from=build /out/app /usr/local/bin/app
```

To build from a checkout instead, pass it as a named build context (`docker build --build-context vectixdb=../vectixdb`) and build the library in the image with Zig (`scripts/go-libs.sh`).

## CI

With a released version, a CI job needs Go only:

```yaml
- uses: actions/checkout@v4
- uses: actions/setup-go@v5
  with: { go-version-file: go.mod }
- run: go test -race ./...
```

From a checkout, check out both repositories side by side, install Zig (`mlugg/setup-zig@v2`, version 0.16.0) and run `./vectixdb/scripts/go-libs.sh` before the tests.
