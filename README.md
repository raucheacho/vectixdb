# VectixDB

An embedded hybrid search engine written in Zig. One library combines:
- vectors (HNSW, f32 or int8);
- full text (BM25);
- exact substring search;
- typed metadata filters.

It runs inside your process, with crash-safe storage and a stable C API. There is no server and no dependency.

```
your app ──(C API, Go binding)──▶ libvectixdb.a ──▶ one directory on disk
                                   WAL + snapshots + manifest
```

## Status

**0.1.0, pre-alpha.** The engine is complete for phase 1 and tested hard. The on-disk format and the C API may still change until 1.0; after that, every change goes through a version number.

| Area | State |
| --- | --- |
| Storage: WAL, snapshots, manifest, checkpoint, recovery | done; crash-tested at every I/O operation |
| Vector search: HNSW f32/int8, filtered, brute force when the filter is selective | done |
| Full text: BM25 with a Unicode analyzer (Latin, Greek, Cyrillic, Arabic folding, identifiers) | done |
| Exact substring route, typed filters, hybrid fusion (RRF or weighted) | done |
| C API, Go binding, `vectix` CLI | done |
| Benchmarks against Zvec | [docs/BENCH.md](docs/BENCH.md) |
| mmap snapshots, group commit, sparse vectors, Python binding | planned, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#roadmap) |

Used by Lorag (a local memory for AI agents) through the Go binding.

## Guarantees

- **Durable writes.** In the default `sync` mode, an acknowledged write survives a process crash and a power loss: the call returns after `fsync`, which is `F_FULLFSYNC` on macOS.
- **Atomic writes.** A batch is applied entirely or not at all, across collections.
- **Safe recovery.** It never deletes data it has not proven obsolete. A damaged manifest makes the open fail; it never triggers a cleanup.
- **Failed `fsync`.** It poisons the handle instead of being retried; reopen to recover.
- **Read-only opens.** They write no byte.
- **One writer.** One process opens a database for writing, enforced with a lock on `<dir>/LOCK`. Read-only opens share the lock with each other, but not with a writer: while a writer has the database open, they fail with `VTX_E_LOCKED`.

## Installing

Releases need no Zig. Platforms: macOS 13+ (arm64, x86-64), Linux with glibc 2.28+ (arm64, x86-64).

- **Go:** `go get github.com/raucheacho/vectixdb/bindings/go@v0.1.0`. The module carries the prebuilt static libraries ([docs/GO.md](docs/GO.md)).
- **C, C++ or FFI:** one archive per platform on the [releases page](https://github.com/raucheacho/vectixdb/releases), `vectixdb-<version>-<os>-<arch>.tar.gz`:
  - the header, `include/vectixdb.h`;
  - the static library `lib/libvectixdb.a` (recommended);
  - the shared library, for FFI;
  - `lib/pkgconfig/vectixdb.pc`;
  - the `vectix` tool.

  See [docs/INTEGRATION.md](docs/INTEGRATION.md#building-and-shipping).

While the repository is private, download with `gh release download v0.1.0 -R raucheacho/vectixdb`, and give Go access as described in [docs/GO.md](docs/GO.md#installing).

## Building from source

Requirements: [Zig 0.16](https://ziglang.org/download/).

```sh
zig build test -Drelease      # unit, crash-recovery and C API tests
zig build -Drelease           # zig-out/lib/libvectixdb.a, zig-out/include/vectixdb.h, zig-out/bin/vectix
zig build c-test              # builds and runs tests/c/smoke.c against the header
./scripts/go-libs.sh          # static library of the Go binding, for the host
```

### From Go

```go
import vectixdb "github.com/raucheacho/vectixdb/bindings/go"

db, err := vectixdb.Open("data", nil)
if err != nil { ... }
defer db.Close()

db.CreateCollection("notes", vectixdb.Schema{
    Vector: &vectixdb.VectorSpec{Dim: 384, Metric: vectixdb.Cosine, Tag: "multilingual-e5-small"},
    Fields: []vectixdb.Field{
        {Name: "body", Type: vectixdb.TypeText},
        {Name: "lang", Type: vectixdb.TypeKeyword},
    },
})
db.PutDocs("notes", vectixdb.Doc{ID: "n1", Vector: v, Fields: map[string]vectixdb.Value{
    "body": vectixdb.Text("clear the metro cache"),
    "lang": vectixdb.Keyword("en"),
}})
hits, err := db.Search("notes", vectixdb.Query{
    Vector: q, Text: "metro cache", K: 10,
    Filter: vectixdb.Eq("lang", vectixdb.Keyword("en")),
})
for _, h := range hits {
    fmt.Println(h.ID, h.Score, h.VectorRank, h.TextRank)
}
```

### From C

```c
#include "vectixdb.h"

vtx_db *db;
if (vtx_open("data", NULL, &db) != VTX_OK) { fprintf(stderr, "%s\n", vtx_last_error()); return 1; }

vtx_schema *s = vtx_schema_new();
vtx_schema_vector(s, 384, VTX_COSINE, 0, 0, 0, "e5-small");
vtx_schema_field(s, "body", VTX_TEXT);
vtx_create_collection(db, "notes", s);
vtx_schema_free(s);

vtx_batch *b = vtx_batch_new();
vtx_batch_put(b, "notes", "n1", 2);
vtx_batch_vector(b, vec, 384);
vtx_batch_text(b, "body", "clear the metro cache", 21);
vtx_write(db, b, NULL);
vtx_batch_free(b);

vtx_query *q = vtx_query_new("notes", 10);
vtx_query_vector(q, qvec, 384);
vtx_query_text(q, "metro cache", 11);
vtx_results *r;
vtx_search(db, q, &r);
for (size_t i = 0; i < vtx_results_len(r); i++) {
    size_t n; const char *id = vtx_result_id(r, i, &n);
    printf("%.*s %f\n", (int)n, id, vtx_result_score(r, i));
}
vtx_results_free(r);
vtx_query_free(q);
vtx_close(db);
```

Error handling is left out above. Every `int` function returns `VTX_OK` or a negative `VTX_E_*` code; see [docs/C-API.md](docs/C-API.md).

## Command line

```sh
vectix info   <dir>                                  # collections, documents, log state
vectix verify <dir>                                  # load everything, check every index
vectix search <dir> <collection> --text "metro cache" [--exact S] [--k N] [--field F]...
vectix get    <dir> <collection> <id>
vectix bench  [--n 100000] [--dim 384] [--f32] [--vectors FILE --qvectors FILE]
```

Every command but `bench` opens the database read-only, so it fails with `VTX_E_LOCKED` while an application has the database open for writing.

## Documentation

| Document | For |
| --- | --- |
| [docs/INTEGRATION.md](docs/INTEGRATION.md) | Using VectixDB in a project: schema design, writes, durability, queries, operations |
| [docs/C-API.md](docs/C-API.md) | The C API, function by function, with ownership rules |
| [docs/GO.md](docs/GO.md) | The Go binding: building the library, module setup, cross-compiling, Docker |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Working on the engine: source tour, invariants, tests, release, roadmap |
| [docs/FORMAT.md](docs/FORMAT.md) | On-disk format, recovery and checkpoints |
| [docs/BENCH.md](docs/BENCH.md) | Benchmarks and comparison with Zvec (in French) |
| [CHANGELOG.md](CHANGELOG.md) | Changes by version |

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
