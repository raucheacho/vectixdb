# Developing VectixDB

How the engine is built, what must stay true, how to test a change and what comes next. The on-disk format and the recovery rules are in [FORMAT.md](FORMAT.md).

## Toolchain

- **Zig 0.16.0 exactly.** Zig is not at 1.0 and breaks its standard library between versions.
- **Go 1.24 or newer**, only for the binding.
- **Docker**, only to run the ThreadSanitizer tests and the Linux link checks from macOS.

| Command | |
| --- | --- |
| `zig build test -Drelease` | All tests, optimized (the crash tests are slow in Debug) |
| `zig build test -Dtest-filter=wal` | Tests whose name contains `wal` |
| `zig build test -Dtsan` | Under ThreadSanitizer (Linux only, see below) |
| `zig build c-test` | Builds and runs `tests/c/smoke.c` with `-Werror` |
| `zig build -Drelease` | Library, header and `vectix` into `zig-out/` |
| `zig build run -- info <dir>` | Runs the CLI |
| `./scripts/go-libs.sh [platforms]` | Static libraries for the Go binding |

The build uses `preferred_optimize_mode = ReleaseSafe`, so the option is `-Drelease`; `-Doptimize=` is rejected.

### Zig 0.16 notes

These cost time once:
- **I/O.** It goes through `std.Io`. The library creates its own `std.Io.Threaded.init_single_threaded` instance, which installs no signal handler: the Go runtime owns signals.
- **Inline assembly.** Operand modifiers are written `%[name:w]`, not `%w[name]` (see `crc32c.zig`).
- **Standard output in tools.** Use `file.writerStreaming(...)`. `File.writer` is positional and overwrites.
- **Static library for foreign linkers.** It sets `bundle_compiler_rt = true` except on arm64 macOS. On x86-64, Zig code calls `__zig_probe_stack`, which gcc and clang do not provide. On arm64 macOS nothing from compiler_rt is needed. On x86-64 macOS, Zig leaves the archive members misaligned and Apple's linker skips them all, so `scripts/go-libs.sh` repacks that archive with `zig ar --format=darwin`.
- **Stripping.** `-Dstrip` drops debug info from the library and the CLI (the macOS arm64 static library goes from 4.8 MB to 0.7 MB). `-Dshared` also builds the shared library, versioned from `build.zig.zon`.

## Source tour

```
src/
  root.zig        module root: exports every file, runs every test
  fs.zig          Fs interface: Real (std.Io, F_FULLFSYNC on macOS, flock) and Sim (crash simulator)
  wal.zig         write-ahead log: segments, records with `synced`, recovery rules
  crc32c.zig      hardware CRC-32C (ARMv8 CRC, SSE4.2), std fallback
  codec.zig       little-endian encoder/decoder for snapshots and the manifest
  batch.zig       batch operations (create, drop, put, delete) and their log encoding
  schema.zig      field types, vector spec, values, validation, limits
  filter.zig      typed filter AST and its validation against a schema
  analyzer.zig    Unicode tokenizer and folding (Latin, Greek, Cyrillic, Arabic, identifiers)
  distance.zig    SIMD kernels: dot, l2, int8 dot, quantize
  topk.zig        heaps for graph search and top-k
  hnsw.zig        HNSW graph indexed by slot labels; parallel batch insert; filtered search
  bm25.zig        inverted index per text field, by slot
  collection.zig  documents, slots, columns, filters, the search planner and fusion
  db.zig          the database: open/recovery, write path, checkpoint, compaction, orphans
  c_api.zig       the exported C functions (contract: include/vectixdb.h)
  cli.zig         the `vectix` tool
bindings/go/      cgo wrapper (vectixdb.go, filter.go) and its tests
tests/c/smoke.c   C program against the header
bench/            zvec_bench.py: runs Zvec on the same data as `vectix bench`
scripts/          go-libs.sh: per-platform static libraries
```

### The write path (`db.zig`)

1. **`Db.write(batch)`** validates every operation against the schemas and the effect of earlier operations in the batch. Nothing is written if one fails.
2. The batch is encoded (`batch.zig`) and appended to the log with its sequence number (`wal.append`).
3. In `sync` mode, `wal.sync` runs: `F_FULLFSYNC` on macOS. A failure here **poisons** the handle, and the sync is never retried.
4. **`apply`** changes the collections in memory. Vectors are queued and inserted together by `flushVectors(build_threads)`. Running out of memory here also poisons the handle: the batch is in the log and a reopen replays it.
5. Once the log has passed `checkpoint_after` bytes, a checkpoint runs inside the call.

### Recovery (`Db.open`)

1. **Pick a manifest.** It is the newest `MANIFEST-<gen>` whose CRC is valid and whose snapshots all load; failing that, the one before.
2. **Replay the log.** Records with `seq > checkpoint_seq` are replayed. A torn tail (a record whose `seq` no later record declared durable) is truncated. Damage in the middle is `Corrupt`, unless `repair` is set.
3. **Clean up.** Only when the newest manifest was loaded, orphans are deleted: temporary files, unreferenced snapshots, older manifests, log files covered by the checkpoint.

### Checkpoint

1. Write each changed collection to `snap-<gen>-<name>.vtx.tmp`, `fsync` it, rename it, then `fsync` the directory.
2. Write the manifest the same way.
3. Only then delete what the new manifest made obsolete.

A crash at any point leaves either the old state or the new one.

### Collections and search (`collection.zig`)

- **Slots.** Every document has a `u32` slot. HNSW labels, BM25 postings, keyword postings and numeric columns are all indexed by slot. A replace or delete kills the slot (tombstone) and never reuses it before `compact`.
- **The planner.**
  - The filter is evaluated to a bitset; the exact route narrows it further.
  - The vector route uses brute force when the bitset holds fewer than `max(1000, total/50)` slots, else filtered HNSW.
  - The text route runs BM25 over the requested fields.
  - The results are fused with RRF or weights.
- **Explanations.** Each hit keeps its rank and score per route, so callers can explain a ranking.

## Invariants

A change that breaks one of these is a bug, whatever the benchmark says.

1. An acknowledged write in `sync` mode survives a crash and a power loss.
2. Recovery deletes only what a newer, checksum-valid manifest made obsolete. A damaged manifest never leads to a deletion.
3. An operation that fails leaves no partial state: prepare everything, then commit in a step that cannot fail.
4. A failed `fsync` poisons the handle; it is never retried.
5. A read-only open writes no byte, and takes a shared lock.
6. The same limits are checked when writing and when reading back.
7. Every file is versioned and checksummed (CRC-32C).
8. Filter values keep their type end to end.
9. The engine stays generic: it knows nothing of agents, problems or memory. Applications build those on fields.

## Testing

### Unit and crash tests

52 tests, all run by `zig build test -Drelease`.

The crash tests (`db.zig`, at the end) replay a workload on the simulated file system `fs.Sim`:
- the workload creates collections, puts, deletes and checkpoints;
- it crashes at every I/O operation, with 4 random outcomes per point (`crash_seeds`);
- on a crash, the simulator keeps either a prefix or an arbitrary subset of unsynced writes, tears the last write, and applies renames atomically;
- some runs crash a second time during recovery;
- each recovered state must be exactly a prefix of the batches containing every acknowledged one, and must pass `db.verify()` (all indexes consistent).

`fs.Sim` also injects a full disk (`nospace_at`) and failing syncs (`sync_fail_at`), which drop pending data like Linux does.

### Mutation testing (by hand, before touching durability code)

A durability test that cannot fail proves nothing. After changing `wal.zig` or the checkpoint code, check that the crash tests still catch these four mutations:

| Mutation | Where |
| --- | --- |
| Remove the WAL `sync` in the write path | `Db.write` |
| Remove the snapshot `sync` | checkpoint |
| Remove the directory `syncDir` before writing the manifest | checkpoint |
| Delete covered log files before the manifest is durable | checkpoint |

Apply one mutation, run `zig build test -Drelease -Dtest-filter=crash`, expect a failure, revert. All four were verified on 2026-10-16.

### Concurrency (ThreadSanitizer)

ThreadSanitizer does not build with Zig 0.16 on recent macOS. Run it in a Linux container:

```sh
docker run --rm -v "$PWD":/src:ro -w /work golang:1.24-bookworm sh -c '
  apt-get -qq update && apt-get -qq install -y xz-utils >/dev/null
  curl -fsSL https://ziglang.org/download/0.16.0/zig-$(uname -m)-linux-0.16.0.tar.xz | tar -xJ -C /opt
  cp -r /src/. /work && rm -rf .zig-cache zig-out
  /opt/zig-$(uname -m)-linux-0.16.0/zig build test -Dtsan --summary all'
```

It takes about 7 minutes; the CI runs it on every push.

### Go binding and link checks

```sh
./scripts/go-libs.sh && (cd bindings/go && go test -race ./...)
./scripts/go-libs.sh linux_arm64 linux_amd64
docker run --rm -v "$PWD":/src -w /src/bindings/go golang:1.24-bookworm go test -race ./...
docker run --rm --platform linux/amd64 -v "$PWD":/src -w /src/bindings/go golang:1.24-bookworm go test ./...
```

The last two catch link problems that only show with gcc (the missing compiler runtime was found this way).

### Benchmarks

```sh
zig build -Drelease
zig-out/bin/vectix bench --n 100000 --dim 384             # int8
zig-out/bin/vectix bench --n 100000 --dim 384 --f32
python bench/zvec_bench.py gen cmp 100000 384 300           # same data for Zvec
python bench/zvec_bench.py run cmp int8
zig-out/bin/vectix bench --vectors cmp/vecs.f32 --qvectors cmp/queries.f32
```

Report any performance claim in [BENCH.md](BENCH.md) with the machine, the versions and the commands.

## Common changes

### Adding a field type

1. `schema.zig`: the `FieldType` enum (append; the numeric value is on disk), `Value`, validation, encoding.
2. `collection.zig`: a column type, put/delete, `fieldOf`, the filter evaluation, snapshot (de)serialization, `check`.
3. `filter.zig`: which operators accept it.
4. `batch.zig`: log encoding.
5. `c_api.zig` + `include/vectixdb.h`: a `VTX_*` constant, a `vtx_batch_*` setter, a `vtx_filter_*` constructor, result accessors.
6. `bindings/go`: the value type, `setField`, `readValue`, filter builders.
7. **Bump the snapshot and log format versions** if old files cannot be read the same way, and add a test reading the previous version.

### Adding a C function

1. Declare it in `include/vectixdb.h` with its ownership rule.
2. Implement it in `c_api.zig`, storing a message for `vtx_last_error` on every failure path.
3. Use it in `tests/c/smoke.c`.
4. Wrap it in the Go binding.
5. Document it in [C-API.md](C-API.md).

### Changing the on-disk format

Every file starts with a magic and a `u32` version. Until 1.0, a new version may refuse older files with a clear error. From 1.0, the engine must read the previous format version, and the change is noted in [CHANGELOG.md](../CHANGELOG.md).

## CI

[.github/workflows/ci.yml](../.github/workflows/ci.yml):
- tests, C test and Go binding on Linux x86-64, Linux arm64 and macOS;
- ThreadSanitizer on Linux;
- the static libraries for every Go platform.

## Release checklist

1. `zig build test -Drelease`, `zig build c-test` and the Go tests pass. CI is green, ThreadSanitizer included.
2. After durability changes, the mutation table above was re-checked.
3. Bump the version in `build.zig.zon` and in `vtx_version`.
4. Add a CHANGELOG entry: format versions, API changes, migration notes.
5. Tag `vX.Y.Z`.
6. Attach the per-platform libraries (`scripts/go-libs.sh` for all platforms) to the release, so applications do not need Zig.

## Roadmap

In rough order of value:

| Item | Why | Notes |
| --- | --- | --- |
| Section-aligned snapshots and mmap | Memory: vectors and payloads read from the page cache instead of copied | Will not speed up opening much: the checksum reads every byte (measured, see BENCH.md) |
| Group commit | Throughput of many small `sync` writes from several threads | Batches arriving during an `fsync` share the next one |
| Query primitives | Score modulation by a numeric field (`score × (1 + w·log1p(field))`) or by time decay with a half-life, MMR diversity with λ, a budget (best set whose sum of an int field ≤ N), validity ranges (`v_min ≤ x ≤ v_max` over two fields) | Generic, knowing only fields; Lorag builds its agent memory on them |
| Sparse vectors | Learned sparse retrieval (SPLADE-like) next to dense vectors | v1.1 |
| Several vector fields per collection | Multi-model collections | |
| Python binding | | Same C API |
| Fuzzing the decoders | WAL, manifest and snapshot decoders must only ever return `Corrupt` | Not done yet |
| Stemming as an option | `manger` and `mange` do not match today | Per field, off by default for predictability |
| Read snapshots while writing | Readers without blocking the writer | v2 |
| Windows | Does not compile: `src/fs.zig` assumes integer file handles, the CLI uses `getrusage` | The fix is small; the work is validating crash safety (atomic replace, directory sync, the lock) on a Windows CI runner |
| Published release artifacts | Applications without Zig | See release checklist |
