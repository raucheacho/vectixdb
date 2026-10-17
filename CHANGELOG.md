# Changelog

## 0.1.0 (unreleased)

First version: phase 1 of the specification.

- Storage:
  - write-ahead log with `synced` markers;
  - snapshots and a checksummed manifest;
  - checkpoints, compaction;
  - recovery that never deletes unproven data;
  - exclusive and shared locks.
- Durability modes `sync` (default, `F_FULLFSYNC` on macOS) and `none`; a failed `fsync` poisons the handle.
- Collections:
  - one optional vector field (cosine, L2, dot; f32 or int8);
  - typed fields `text`, `keyword`, `keywords`, `int`, `float`, `bool`, `time`;
  - an opaque payload.
- Search:
  - vector (HNSW with parallel batch insert, brute force under selective filters), BM25 text, exact substring;
  - typed filters;
  - RRF or weighted fusion, with per-route ranks in every result.
- Unicode analyzer: Latin, Greek and Cyrillic folding, Arabic normalization, identifier splitting.
- Hardware CRC-32C on ARMv8 and x86-64-v2.
- C API (`include/vectixdb.h`, API 0.1), Go binding, `vectix` command line tool.
- Static libraries for macOS (arm64, x86-64) and Linux glibc (arm64, x86-64) with the compiler runtime bundled where needed (on x86-64 macOS, repacked so Apple's linker reads it).
- Build options `-Dstrip` (no debug info) and `-Dshared` (shared library).
- Distribution without Zig:
  - release archives per platform: header, static and shared libraries, pkg-config file, `vectix`;
  - the Go module carries its header and, in release tags, the prebuilt static library of each platform in its own module (`bindings/go/lib/<platform>`).

Formats: WAL version 1, manifest version 1, collection snapshot version 1.
