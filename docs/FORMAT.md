# On-disk format

What a database directory holds and how it stays consistent through crashes. The source of truth is the code (`src/wal.zig`, `src/db.zig`, `src/codec.zig`, `Collection.serialize`); this page is the map. Format version 1 everywhere.

## Files

```
<dir>/
  LOCK                           exclusive lock, held while the database is open
  MANIFEST-<gen>                 the current manifest (only one is kept after a checkpoint)
  wal-<first seq>.log            write-ahead log, sequence number on 20 digits
  snap-<gen>-<collection>.vtx    snapshot of one collection, written at checkpoint <gen>
  *.tmp                          files being written; never read, removed at open
```

Everything lives in one directory, so a single directory sync makes every create, rename and delete durable.

Integers are little-endian. Checksums are CRC32C, computed with the CPU instructions (ARMv8 CRC, SSE4.2) when the target has them.

## Write-ahead log

```
file header (24 B): "VTXW" | version u16 | 0 u16 | first_seq u64 | crc32c u32 | 0 u32
record:             len u32 | seq u64 | synced u64 | crc32c u32 | payload (len bytes)
```

- **Records.** The CRC covers the first 20 bytes of the record header and the payload. The payload is one batch (`batch.encode`: op count, then each create, drop, put or delete).
- **`synced`.** The last sequence number known durable (its fsync returned) when the record was written.
- **Continuity.** Sequence numbers are contiguous across files.
- **New files.** A file is created under a `.tmp` name and renamed once its header is durable, so a crash never leaves a log without a header.

### Recovery

Replay starts after the manifest's `checkpoint_seq`. Batches at or below it are skipped, so replay is idempotent. Files entirely covered by the checkpoint are ignored, since their neighbours may already be deleted, then removed.

Replay stops at the first invalid record, of sequence number s:
- **If no valid record after it claims `synced >= s`,** then s was never acknowledged as durable. It and everything after it are an unsynced tail, possibly persisted out of order by the file system. The tail is cut off before the log is appended to again.
- **Otherwise durable data was damaged,** and opening fails with `VTX_E_CORRUPT`, unless `repair` is set: then everything from s on is dropped.

**Known limit.** The last records synced as a group are only vouched for by the next write. If those exact bytes were damaged between a crash and the reopening, the damage would be taken for an unsynced tail.

## Framed files: manifest and snapshots

```
magic (4 B) | version u32 | body | crc32c(body) u32
```

Readers check the CRC before decoding, and fail with `Corrupt` instead of reading out of bounds.

- **Manifest** (`"VTXM"`). Body: `gen u64 | checkpoint_seq u64 | n u32 | (collection name, snapshot file name) × n`, names as length-prefixed blobs.
- **Collection snapshot** (`"VTXC"`), immutable. The body holds, in order:
  - the name and the schema;
  - the live documents, renumbered densely (id, payload);
  - the columns field by field (text with its BM25 index, keywords, numbers with a presence flag);
  - the HNSW graph. Deleted nodes stay in it for routing until compaction.

  The file is read whole into memory.

## Checkpoint

1. For each modified collection, write `snap-<n>-<name>.vtx.tmp`, sync it and rename it. Then sync the directory.
2. Write `MANIFEST-<n>` the same way: temporary file, sync, rename, directory sync.
3. Only then rotate the log, and delete:
   - log files covered by `checkpoint_seq`;
   - snapshots that were replaced or belong to dropped collections;
   - the previous manifest.

A crash at any step leaves either the complete old state or the complete new one. A checkpoint runs when the log passes `checkpoint_after` (64 MiB by default), on request, and on close.

## Opening

1. **Pick a manifest.** Take the highest `<gen>` whose CRC is valid and whose snapshots all load; failing that, the one before. If the log no longer covers the gap from an older manifest, replay sees a hole in the sequence numbers and opening fails, without losing or deleting anything.
2. **Replay the log** (above).
3. **Remove orphans:** temporary files, unreferenced snapshots and older manifests. This happens only when the loaded manifest is the newest one present, so a damaged manifest never leads to a deletion.

**Compaction** renumbers a collection's slots without changing any document. It is not logged: after a crash before the next checkpoint, replay simply runs on the previous snapshot.

## Changing the format

Every file starts with a magic and a version. The policy (refuse older files before 1.0, read the previous version from 1.0) and the steps are in [DEVELOPMENT.md](DEVELOPMENT.md#changing-the-on-disk-format).
