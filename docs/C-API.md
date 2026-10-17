# C API reference

Header: [`include/vectixdb.h`](../include/vectixdb.h), API version 0.1. Library: `libvectixdb.a` (static), built with `zig build -Drelease`.

The API is the contract of the engine. The Go binding and future bindings (Python) wrap it without logic of their own.

## Conventions

- **Return codes.** Functions returning `int` return `VTX_OK` (0) or a negative `VTX_E_*` code. `vtx_last_error()` then returns a message for the calling thread, valid until that thread's next call. Bindings must read it on the same OS thread (the Go binding locks the goroutine to its thread for each call).
- **Strings.**
  - `(pointer, length)` pairs may contain any bytes, including NUL: ids, text, keywords, payloads.
  - `const char *` parameters are NUL-terminated: paths, collection and field names.
- **Ownership.**
  - Objects you create (schema, batch, filter, query) are freed with their `*_free` function.
  - A filter passed to `vtx_filter_and`, `vtx_filter_or`, `vtx_filter_not` or `vtx_query_filter` belongs to its new parent from then on, even when the call fails: do not free it.
  - Results belong to their `vtx_results`. Every pointer read from it stays valid until `vtx_results_free`.
- **Threads.** A `vtx_db` may be used from several threads: searches run in parallel, writes are serialized. Schemas, batches, filters, queries and results are not thread-safe: use one per thread or lock them yourself.
- **ABI.** Options are passed through `vtx_options`, whose first field is `struct_size`; every other object is opaque and built through functions, so the ABI can grow without breaking callers.

## Error codes

| Code | Value | Meaning |
| --- | --- | --- |
| `VTX_OK` | 0 | success |
| `VTX_E_NOMEM` | -1 | out of memory |
| `VTX_E_IO` | -2 | input/output error |
| `VTX_E_CORRUPT` | -3 | damaged data found (open without `repair`, or a damaged snapshot) |
| `VTX_E_LOCKED` | -4 | another process holds the database |
| `VTX_E_READONLY` | -5 | write on a read-only handle |
| `VTX_E_POISONED` | -6 | a sync or an apply failed; close and reopen |
| `VTX_E_NOT_FOUND` | -7 | no such collection |
| `VTX_E_EXISTS` | -8 | collection already exists |
| `VTX_E_INVALID` | -9 | invalid schema, document, filter, query or argument |
| `VTX_E_NOSPACE` | -10 | disk full |
| `VTX_E_TOO_LARGE` | -11 | over a size limit |

## Database

```c
typedef struct {
    uint32_t struct_size;      /* sizeof(vtx_options) */
    int read_only;             /* shared lock, writes nothing */
    int durability;            /* 0: durable when a write returns (default); 1: after vtx_sync, a checkpoint or vtx_close */
    uint64_t checkpoint_after; /* log bytes before an automatic checkpoint; 0: 64 MiB */
    int repair;                /* drop damaged log records instead of failing to open */
} vtx_options;
```

| Function | |
| --- | --- |
| `int vtx_open(const char *path, const vtx_options *opt, vtx_db **out)` | Opens or creates the directory; `opt` may be `NULL` |
| `int vtx_close(vtx_db *db)` | Syncs, checkpoints if the log holds writes, releases the lock. Frees the handle even on error (`VTX_E_POISONED` if it was poisoned) |
| `int vtx_sync(vtx_db *db)` | Makes every write durable (for durability 1) |
| `int vtx_checkpoint(vtx_db *db)` | Writes snapshots of changed collections, then trims the log |
| `int vtx_compact(vtx_db *db, const char *collection)` | Rewrites a collection without deleted documents |
| `void vtx_stats(vtx_db *db, vtx_stats_t *out)` | `collections`, `documents`, `last_seq`, `checkpoint_seq`, `generation`, `wal_bytes` |
| `int vtx_count(vtx_db *db, const char *collection, uint32_t *out)` | Live documents of a collection |
| `int vtx_collections(vtx_db *db, vtx_names **out)` | Collection names; read with `vtx_names_len`, `vtx_names_get`; free with `vtx_names_free` |
| `const char *vtx_version(void)` | Library version, e.g. `"0.1.0"` |

## Schema and collections

| Function | |
| --- | --- |
| `vtx_schema *vtx_schema_new(void)` / `void vtx_schema_free(vtx_schema *)` | |
| `int vtx_schema_vector(s, dim, metric, quantized, m, ef_construction, tag)` | One vector field. `metric`: `VTX_COSINE`, `VTX_L2`, `VTX_DOT`. `quantized` requires cosine. `m`, `ef_construction`: 0 for 16 and 200. `tag`: free label, may be `NULL` |
| `int vtx_schema_field(s, name, type)` | `VTX_TEXT`, `VTX_KEYWORD`, `VTX_KEYWORDS`, `VTX_INT`, `VTX_FLOAT`, `VTX_BOOL`, `VTX_TIME` (ms since the epoch) |
| `int vtx_schema_bm25(s, k1, b)` | BM25 parameters (defaults 1.2 and 0.75) |
| `int vtx_create_collection(db, name, s)` | The schema is copied; free yours afterwards |
| `int vtx_drop_collection(db, name)` | Logged like a write |

## Writes

A batch is a list of operations applied atomically by `vtx_write`. `vtx_batch_put` starts a document; the setters that follow fill it.

| Function | |
| --- | --- |
| `vtx_batch *vtx_batch_new(void)` / `vtx_batch_free` / `vtx_batch_reset` | `reset` empties a batch for reuse |
| `int vtx_batch_put(b, collection, id, id_len)` | Insert or replace |
| `int vtx_batch_vector(b, v, dim)` | |
| `int vtx_batch_payload(b, p, len)` | Opaque bytes |
| `int vtx_batch_text / _keyword(b, field, s, len)` | |
| `int vtx_batch_keywords(b, field, strs, lens, n)` | |
| `int vtx_batch_int / _float / _bool / _time(b, field, v)` | |
| `int vtx_batch_delete(b, collection, id, id_len)` | No error if the id does not exist |
| `int vtx_write(db, b, &seq)` | Validates everything, logs, syncs (durability 0), applies. `seq` may be `NULL`. The batch is not consumed: free or reset it |

Validation covers the effect of earlier operations in the same batch: putting into a collection created by the same batch is fine.

## Filters

Each constructor returns `NULL` when allocation fails or the field name is `NULL`.

| Function | Matches |
| --- | --- |
| `vtx_filter_eq_keyword(field, s, len)` | keyword equal; for `keywords`, contains |
| `vtx_filter_eq_int / _float / _bool / _time(field, v)` | equal |
| `vtx_filter_range_int / _float / _time(field, lo, hi, flags)` | `flags`: `VTX_HAS_LO`, `VTX_LO_INCLUSIVE`, `VTX_HAS_HI`, `VTX_HI_INCLUSIVE` |
| `vtx_filter_exists(field)` | documents with a value for the field |
| `vtx_filter_and(a, b)`, `vtx_filter_or(a, b)` | takes ownership of `a` and `b` |
| `vtx_filter_not(a)` | takes ownership; also keeps documents without the field |
| `vtx_filter_free(f)` | only for a filter you still own |

A filter is type-checked against the schema when the query runs: a range on a keyword field is `VTX_E_INVALID`.

## Queries

| Function | |
| --- | --- |
| `vtx_query *vtx_query_new(collection, k)` / `vtx_query_free` | `k` from 1 to 10,000 |
| `vtx_query_vector(q, v, dim)` | vector route |
| `vtx_query_text(q, s, len)` | BM25 route |
| `vtx_query_exact(q, s, len)` | keeps documents containing the bytes (case-sensitive), exhaustive |
| `vtx_query_text_field(q, name)` | restricts text and exact to this field; repeatable |
| `vtx_query_filter(q, f)` | takes ownership of `f` |
| `vtx_query_ef(q, ef)` | HNSW list size, default 64 |
| `vtx_query_candidates(q, n)` | results taken from each route before fusion |
| `vtx_query_rrf(q, k)` | reciprocal rank fusion, the default with `k` = 60 |
| `vtx_query_weighted(q, w_vector, w_text)` | weighted fusion of similarity and normalized BM25 |
| `vtx_query_return_field(q, name)` | copy this field into results; repeatable |
| `vtx_query_payload(q, include)` | default 1 |
| `int vtx_search(db, q, &results)` | With neither vector nor text: matching documents in insertion order |
| `int vtx_get(db, collection, id, id_len, &results)` | Zero or one result, with every field and the payload |

## Results

| Function | |
| --- | --- |
| `size_t vtx_results_len(r)` | |
| `const char *vtx_result_id(r, i, &len)` | |
| `float vtx_result_score(r, i)` | see the score table in [INTEGRATION.md](INTEGRATION.md#scores-and-explanations) |
| `void vtx_result_explain(r, i, &explain)` | `vector_rank`, `vector_distance`, `text_rank`, `text_score`; ranks are 1-based, 0 when the route missed |
| `const void *vtx_result_payload(r, i, &len)` | `NULL` if none |
| `size_t vtx_result_fields(r, i)` | number of returned fields |
| `vtx_result_field_name(r, i, j, &len)`, `vtx_result_field_type(r, i, j)` | |
| `vtx_result_field_str(r, i, j, &len)` | text and keyword |
| `vtx_result_field_count(r, i, j)`, `vtx_result_field_item(r, i, j, k, &len)` | keywords |
| `vtx_result_field_int / _float / _bool(r, i, j)` | time is read with `_int` |
| `void vtx_results_free(r)` | |

## A complete lifecycle

```c
vtx_options o = { .struct_size = sizeof o, .durability = 0 };
vtx_db *db;
if (vtx_open("data", &o, &db)) die();

vtx_query *q = vtx_query_new("notes", 5);
vtx_query_text(q, "metro cache", 11);
vtx_query_filter(q, vtx_filter_and(
    vtx_filter_eq_keyword("lang", "en", 2),
    vtx_filter_range_time("updated", since_ms, 0, VTX_HAS_LO | VTX_LO_INCLUSIVE)));   /* both filters now belong to q */
vtx_query_return_field(q, "body");

vtx_results *r;
if (vtx_search(db, q, &r) == VTX_OK) {
    for (size_t i = 0; i < vtx_results_len(r); i++) {
        vtx_explain e; vtx_result_explain(r, i, &e);
        size_t n; const char *body = vtx_result_field_str(r, i, 0, &n);
        printf("#%u %.*s\n", e.text_rank, (int)n, body);
    }
    vtx_results_free(r);
} else {
    fprintf(stderr, "search: %s\n", vtx_last_error());
}
vtx_query_free(q);   /* frees the filters too */
vtx_close(db);
```

[`tests/c/smoke.c`](../tests/c/smoke.c) exercises the whole API and compiles with `-std=c99 -Wall -Wextra -Werror`.
