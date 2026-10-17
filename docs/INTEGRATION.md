# Integrating VectixDB

This guide is for developers embedding VectixDB in an application. Examples use the Go binding; every call maps one-to-one to the C API ([C-API.md](C-API.md)).

## Concepts

| Concept | What it is |
| --- | --- |
| **Database** | A directory. One process opens it for writing (exclusive lock on `<dir>/LOCK`). It holds every collection, one write-ahead log, snapshots and a manifest. |
| **Collection** | A named set of documents with a fixed schema. Up to one vector field, any number of typed fields. |
| **Document** | An id (1 to 512 bytes, any bytes), an optional vector, typed field values, an optional opaque payload (up to 16 MiB). |
| **Batch** | Puts and deletes, on one or several collections, applied atomically and numbered with a sequence (`seq`). |
| **Checkpoint** | Writes a snapshot of each changed collection, then trims the log. Speeds up the next open; it does not change durability. |

Names of collections and fields: 1 to 64 characters among ASCII letters, digits, `_` and `-`.

## Designing a schema

```go
db.CreateCollection("chunks", vectixdb.Schema{
    Vector: &vectixdb.VectorSpec{
        Dim: 768, Metric: vectixdb.Cosine, Quantized: false,
        M: 16, EfConstruction: 200,        // 0 = these defaults
        Tag: "nomic-embed-text",           // free label, e.g. the embedding model
    },
    Fields: []vectixdb.Field{
        {Name: "content", Type: vectixdb.TypeText},       // BM25 + exact substring
        {Name: "path", Type: vectixdb.TypeKeyword},       // exact match filters
        {Name: "tags", Type: vectixdb.TypeKeywords},      // list; Eq means "contains"
        {Name: "page", Type: vectixdb.TypeInt},
        {Name: "updated", Type: vectixdb.TypeTime},       // ms since the epoch
    },
    BM25K1: 1.2, BM25B: 0.75,                             // 0 = these defaults
})
```

### Choosing field types

| Type | Use for | Filters |
| --- | --- | --- |
| `TypeText` | Prose and code to search by words | none: searched by the text and exact routes |
| `TypeKeyword` | One exact value: path, status, language, owner | `Eq`, `In`, `Not`, `Exists` |
| `TypeKeywords` | A set of values: tags, versions | `Eq` (contains one), `In` |
| `TypeInt`, `TypeFloat`, `TypeTime` | Numbers and dates | `Eq`, `Range`, `Gt`, `Gte`, `Lt`, `Lte` |
| `TypeBool` | Flags | `Eq` |

### Vector rules

- **Quantization.** `Quantized: true` stores int8 codes: about 3.5 times less disk and memory, recall@10 about 0.93 instead of 0.99 (see [BENCH.md](BENCH.md)). It requires `Cosine`.
- **One embedding space per collection.** Vectors from two models never share a collection. To change models, see [Changing the embedding model](#changing-the-embedding-model-or-the-schema).
- **Dimension.** It is fixed at creation, from 1 to 4,096.

### What the schema cannot do (yet)

- **No schema change.** Fields cannot be added or removed after creation: create a new collection.
- **One vector field.** A collection has at most one; sparse vectors are planned.
- **No partial update.** A put replaces the whole document: send every field again.

## Writing

```go
seq, err := db.Write(
    vectixdb.Put("chunks", vectixdb.Doc{ID: "c1", Vector: v1, Fields: map[string]vectixdb.Value{"content": vectixdb.Text("…")}}),
    vectixdb.Put("chunks", vectixdb.Doc{ID: "c2", Vector: v2, Fields: …}),
    vectixdb.Delete("chunks", "old-c7"),
)
```

- **One batch per logical change.** A batch is atomic: a search sees all of it or none of it. To replace a document's chunks, put the new ones and delete the old ones in the same batch.
- **Batch for throughput.** In `sync` mode every batch costs one `fsync` (a few milliseconds on a laptop SSD). Group writes, for instance 256 to 1,024 documents, when loading data. The vectors of a batch are inserted in parallel (`build_threads`: 8 at most by default).
- **Put means insert or replace.** A put on an existing id replaces the document.
- **Deletes are tombstones** until `Compact`.
- **Validation happens first.** Dimensions, types and limits are checked before anything is written: an invalid batch fails with `ErrInvalid` and leaves the database untouched.

### Durability modes

| Mode | When a write returns | Use for |
| --- | --- | --- |
| `DurabilitySync` (default) | It is on disk: survives a crash and a power loss | Anything the user cannot easily redo |
| `DurabilityNone` | It is in the log, not yet synced | Bulk loads you can restart; call `Sync()` at the end |

With `DurabilityNone`, a crash may lose the last writes, never corrupt the database.

### Errors you must handle

| Error | Meaning | What to do |
| --- | --- | --- |
| `ErrInvalid` | Bad schema, document, filter or query | Fix the input; nothing was written |
| `ErrNotFound`, `ErrExists` | Collection missing or already there | |
| `ErrLocked` | Another process has the database open for writing | Run one writer; open read-only only when it is closed |
| `ErrNoSpace` | Disk full | The log is truncated back; the database stays usable once space is freed |
| `ErrPoisoned` | An `fsync` or an in-memory apply failed: the durability of recent writes is unknown | Close and reopen; recovery replays the log |
| `ErrCorrupt` | Damaged data found at open | Do not delete files. Open with `Repair: true` only if losing the damaged log records is acceptable |
| `ErrTooLarge` | A record over the limits (64 MiB log record, 16 MiB text or payload) | Split the batch or the value |

## Searching

A query targets one collection and combines up to three routes:

| Route | Set | Returns | Exhaustive |
| --- | --- | --- | --- |
| Vector | `Vector` | nearest neighbors (HNSW) | no, except under a selective filter (exact brute force) |
| Text | `Text` | BM25 ranking on text fields | yes, among documents containing a query term |
| Exact | `Exact` | documents whose text contains the literal bytes (case-sensitive) | yes |

```go
res, err := db.Search("chunks", vectixdb.Query{
    Vector:     qvec,                       // vector route
    Text:       "metro cache",              // BM25 route
    Exact:      "ERR_MODULE_NOT_FOUND",     // keeps only documents containing it
    TextFields: []string{"content"},        // restrict Text and Exact (default: all text fields)
    Filter:     vectixdb.And(vectixdb.Eq("path", vectixdb.Keyword("/notes/a.md")), vectixdb.Gte("page", vectixdb.Int(3))),
    K:          10,                         // default 10, max 10,000
    Ef:         64,                         // HNSW search list (default 64, raise for recall)
    Candidates: 50,                         // per route before fusion (default max(4K, 50) in hybrid)
    Fusion:     vectixdb.Fusion{RRFK: 60},  // or {VectorWeight: 0.7, TextWeight: 0.3}
    ReturnFields: []string{"content", "path", "page"},
    NoPayload:  true,
})
```

### Scores and explanations

Each `Result` carries its final `Score` and the contribution of each route: `VectorRank`, `VectorDistance`, `TextRank` (1-based, 0 when the route missed it) and `TextScore`.

| Query | `Score` |
| --- | --- |
| Vector only | similarity: `1 − distance` for cosine and dot, `1 / (1 + distance)` for L2 |
| Text only | BM25 score |
| Vector + text, RRF | `Σ 1/(k + rank)` over the routes that returned it |
| Vector + text, weighted | `w_v × similarity + w_t × bm25 / best_bm25` |
| Filter or exact only | 0; documents come in insertion order |

To show a score in [0, 1] for RRF, divide by `2/(k+1)`, the score of a document ranked first by both routes.

### Filters

```go
vectixdb.Eq("status", vectixdb.Keyword("valid"))
vectixdb.In("space", vectixdb.Keyword("global"), vectixdb.Keyword("shop"))
vectixdb.Range("updated", vectixdb.Time(from), true, vectixdb.Time(to), false)
vectixdb.Not(vectixdb.Eq("status", vectixdb.Keyword("obsolete")))   // also keeps documents without the field
vectixdb.Exists("page")
vectixdb.And(a, b, c); vectixdb.Or(a, b)
```

Filters are typed end to end: a float stays a float, and comparing a field with the wrong type is `ErrInvalid`, never a silent conversion.

When a filter keeps fewer than `max(1000, 2 % of the collection)` documents, the vector route computes exact distances on those documents instead of walking the graph, so filtered results do not lose recall.

### Text analysis

The text route lowercases and folds accents (Latin, Greek, Cyrillic), normalizes Arabic, and splits identifiers. `ERR_MODULE_NOT_FOUND` is indexed as itself and as `err`, `module`, `not`, `found`.

There is no stemming: `manger` does not match `mange`. Hybrid queries cover that through the vector route.

### Get and list

- `db.Get(collection, id)` returns one document with every field, or `nil`.
- A query with neither `Vector` nor `Text` lists the matching documents in insertion order, up to `K` (10,000 at most). Use it to scan a filtered subset.

## Concurrency

- **One handle per process.** A handle is thread-safe: concurrent searches run in parallel and writes are serialized. Share one handle for the whole process.
- **Go binding.** It locks the calling goroutine to its OS thread only for the duration of a call, to read the thread-local error message; nothing else is required.
- **No background threads** except the short-lived ones inserting a batch's vectors. Checkpoints and compactions run when you call them, plus an automatic checkpoint inside `Write` once the log passes `CheckpointAfter` (64 MiB by default).

## Operations

| Task | How |
| --- | --- |
| Faster startup | `Checkpoint()` after bulk loads; `Close()` also checkpoints when needed |
| Reclaim deleted documents | `Compact(collection)` when many were deleted (rewrites the collection's slots) |
| Inspect | `vectix info <dir>`, `vectix verify <dir>` (read-only; stop the writer first) |
| Monitor | `Stats()`: documents, last sequence, checkpoint sequence, log bytes |
| Back up | Close the writer (or `Checkpoint()` and pause writes), then copy the whole directory |
| Disk usage | Roughly: vectors (`dim × 4` bytes, or `dim + 4` in int8) + HNSW links (about `M × 8` bytes per document) + text and fields, plus the log until the next checkpoint |

## Changing the embedding model or the schema

A collection cannot change its vector space or its fields. Use generations of collections and a pointer document; this is what Lorag does in production.

1. Keep a small collection, for example `meta`, with one document per subsystem: `{active: "chunks_3", config: "<fingerprint>"}`. The fingerprint lists everything baked into the collection: model name, dimension, metric, quantization, HNSW parameters, field layout version.
2. At startup, compare the stored fingerprint with the current configuration. If it differs, create `chunks_4`.
3. Fill the new generation from your source of truth, in batches, while searches keep using `chunks_3`. Writes during the rebuild go to both collections, in the same batch.
4. Switch: one `Write` puts the new pointer document.
5. Drop `chunks_3`. At startup, drop any `chunks_*` that is not active (a rebuild interrupted by a crash).

Include the **model name** in the fingerprint, not only the dimension: two models with the same dimension produce incompatible vectors.

## Building and shipping

| Target | Library |
| --- | --- |
| macOS arm64, macOS x86-64 (13+) | `libvectixdb.a`; on x86-64, compiler runtime bundled (build with `scripts/go-libs.sh`, which repacks the archive for Apple's linker) |
| Linux arm64, Linux x86-64 (glibc) | `libvectixdb.a`, compiler runtime bundled; link with `-lm` |
| Windows x86-64 | not supported yet: the engine does not compile for Windows |

- **x86-64 CPUs.** The libraries target x86-64-v2 (CPUs from 2009 onwards) for the hardware CRC32C.
- **Release builds** use `-Drelease` (ReleaseSafe: safety checks stay on).
- **Go applications:** see [GO.md](GO.md) for the module setup, cross-compiling and a Docker build.

## Limits

| Limit | Value |
| --- | --- |
| Vector dimension | 4,096 |
| Fields per collection | 64 |
| Name length | 64 bytes |
| Id length | 512 bytes |
| Text value, payload | 16 MiB each |
| Encoded batch | 64 MiB |
| Keywords per value | 1,024, each up to 1,024 bytes |
| Results per query | 10,000 |
| `ef`, `candidates` | 10,000 and 100,000 |
