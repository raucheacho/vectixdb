# Go binding

Package `github.com/raucheacho/vectixdb/bindings/go` (import it as `vectixdb`). It is a thin cgo wrapper over the C API: the same calls, Go types, no logic of its own.

## The static library is not in the module

The package links `bindings/go/lib/<os>_<arch>/lib/libvectixdb.a`. The library is built with Zig and is not committed (it is in `.gitignore`). So `go get` alone is not enough: the consuming project needs a checkout of this repository and the library built for each target platform.

```sh
./scripts/go-libs.sh                              # host platform
./scripts/go-libs.sh linux_amd64 linux_arm64      # cross-compiled with Zig, from any OS
```

Supported: `darwin_arm64`, `darwin_amd64` (macOS 13+), `linux_amd64`, `linux_arm64` (glibc). Windows is not supported yet.

## Using it from a project

Keep the checkout next to the project and point the module at it:

```
// go.mod of the application
require github.com/raucheacho/vectixdb/bindings/go v0.0.0
replace github.com/raucheacho/vectixdb/bindings/go => ../vectixdb/bindings/go
```

Lorag works this way, with a `Makefile` rule that builds the library when it is missing:

```make
VECTIXDB ?= ../vectixdb
ENGINE_LIB = $(VECTIXDB)/bindings/go/lib/$(shell go env GOOS)_$(shell go env GOARCH)/lib/libvectixdb.a
$(ENGINE_LIB):
	$(VECTIXDB)/scripts/go-libs.sh
build: $(ENGINE_LIB)
	CGO_ENABLED=1 go build ./...
```

While the repository is private, CI jobs check it out with a token (see [CI](#ci)).

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

The tests run against the library of the host platform: build it first with `scripts/go-libs.sh`.

## Cross-compiling an application

cgo needs a C toolchain for the target. Zig provides one for every platform, which avoids installing cross compilers:

```sh
./scripts/go-libs.sh linux_amd64
CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="zig cc -target x86_64-linux-gnu" go build ./cmd/app
```

Use the same target as the library: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos`, `x86_64-macos`.

## Docker

The library links against glibc: use a Debian or Ubuntu based image, not Alpine (musl). Pass the checkout as a named build context:

```dockerfile
FROM golang:1.24-bookworm AS build
ARG ZIG_VERSION=0.16.0
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-$(uname -m)-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt \
 && ln -s "/opt/zig-$(uname -m)-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
COPY --from=vectixdb . /src/vectixdb
RUN cd /src/vectixdb && rm -rf zig-out .zig-cache bindings/go/lib && ./scripts/go-libs.sh
WORKDIR /src/app
COPY . .
RUN CGO_ENABLED=1 go build -o /out/app ./cmd/app

FROM debian:bookworm-slim
COPY --from=build /out/app /usr/local/bin/app
```

```sh
docker build --build-context vectixdb=../vectixdb -t app .
```

Lorag's [Dockerfile](https://github.com/raucheacho/lorag/blob/main/Dockerfile) is a complete example.

## CI

A job that builds an application against this repository:

```yaml
- uses: actions/checkout@v4
  with: { path: app }
- uses: actions/checkout@v4
  with:
    repository: raucheacho/vectixdb
    token: ${{ secrets.VECTIXDB_TOKEN }}   # needed while the repository is private
    path: vectixdb
- uses: mlugg/setup-zig@v2
  with: { version: 0.16.0 }
- uses: actions/setup-go@v5
  with: { go-version-file: app/go.mod }
- run: ./vectixdb/scripts/go-libs.sh
- run: go test -race ./...
  working-directory: app
```
