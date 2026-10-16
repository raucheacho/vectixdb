# VectixDB

Embedded hybrid search engine written in Zig: vectors (HNSW, int8), full text (BM25), exact substring and typed metadata filters in one in-process library, with crash-safe storage and a stable C API. No server, no dependencies.

Status: pre-alpha. Design and on-disk format: [docs/SPEC.md](docs/SPEC.md).

## Build

```sh
zig build test -Drelease   # Zig 0.16: unit, crash and C API tests
zig build c-test           # a C program against include/vectixdb.h
zig build -Drelease        # zig-out/lib/libvectixdb.a + zig-out/include/vectixdb.h
```

## Command line

```sh
zig build -Drelease                       # zig-out/bin/vectix
vectix info   <dir>                       # collections, documents, log state
vectix verify <dir>                       # load everything, check every index
vectix search <dir> <collection> --text "metro cache" --field lang
vectix get    <dir> <collection> <id>
vectix bench  --n 100000 --dim 384        # ingestion, latency per route, recall@10
```

Every command but `bench` opens the database read-only (shared lock). Benchmark results and the comparison with Zvec: [docs/BENCH.md](docs/BENCH.md).

## Go

```sh
./scripts/go-libs.sh                  # static library for the host (or: linux_amd64 darwin_arm64 ...)
cd bindings/go && go test -race ./...
```

```go
db, _ := vectixdb.Open("data", nil)
defer db.Close()
db.CreateCollection("notes", vectixdb.Schema{
    Vector: &vectixdb.VectorSpec{Dim: 384, Quantized: true, Tag: "multilingual-e5-small"},
    Fields: []vectixdb.Field{{Name: "body", Type: vectixdb.TypeText}, {Name: "lang", Type: vectixdb.TypeKeyword}},
})
db.PutDocs("notes", vectixdb.Doc{ID: "n1", Vector: v, Fields: map[string]vectixdb.Value{
    "body": vectixdb.Text("clear the metro cache"), "lang": vectixdb.Keyword("en"),
}})
hits, _ := db.Search("notes", vectixdb.Query{Vector: q, Text: "metro cache", Filter: vectixdb.Eq("lang", vectixdb.Keyword("en"))})
```

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
