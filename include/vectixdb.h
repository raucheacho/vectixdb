/*
 * VectixDB: embedded hybrid search engine (vectors, full text, exact match,
 * typed metadata filters). C API, version 0.1.
 *
 * Conventions
 * - Functions returning int return VTX_OK (0) or a negative VTX_E_* code;
 *   vtx_last_error() then describes the failure (per thread, valid until
 *   the next call on that thread).
 * - Strings are (pointer, length) pairs unless typed `const char *`, which
 *   are NUL-terminated. Ids, text and payloads may hold any bytes.
 * - Objects built by the caller (schema, batch, filter, query) are freed by
 *   their *_free function. Filters passed to vtx_filter_and/or/not and to
 *   vtx_query_filter belong to their new parent, also on failure.
 * - Results are owned by the vtx_results object; pointers into it stay valid
 *   until vtx_results_free.
 * - A vtx_db is thread safe: one writer at a time, readers in parallel.
 */
#ifndef VECTIXDB_H
#define VECTIXDB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VTX_OK 0
#define VTX_E_NOMEM -1
#define VTX_E_IO -2
#define VTX_E_CORRUPT -3
#define VTX_E_LOCKED -4    /* another process has the database open */
#define VTX_E_READONLY -5
#define VTX_E_POISONED -6  /* a write failed in a way that left its durability unknown: reopen */
#define VTX_E_NOT_FOUND -7
#define VTX_E_EXISTS -8
#define VTX_E_INVALID -9   /* invalid schema, document, filter, query or argument */
#define VTX_E_NOSPACE -10
#define VTX_E_TOO_LARGE -11

/* Metrics */
#define VTX_COSINE 0
#define VTX_L2 1
#define VTX_DOT 2

/* Field types */
#define VTX_TEXT 0     /* full text: BM25 and exact substring */
#define VTX_KEYWORD 1  /* one exact string */
#define VTX_KEYWORDS 2 /* list of exact strings */
#define VTX_INT 3
#define VTX_FLOAT 4
#define VTX_BOOL 5
#define VTX_TIME 6     /* milliseconds since the Unix epoch */

/* Range filter flags */
#define VTX_HAS_LO 1
#define VTX_LO_INCLUSIVE 2
#define VTX_HAS_HI 4
#define VTX_HI_INCLUSIVE 8

typedef struct vtx_db vtx_db;
typedef struct vtx_schema vtx_schema;
typedef struct vtx_batch vtx_batch;
typedef struct vtx_filter vtx_filter;
typedef struct vtx_query vtx_query;
typedef struct vtx_results vtx_results;
typedef struct vtx_names vtx_names;

const char *vtx_version(void);
const char *vtx_last_error(void);

/* ---- database ---------------------------------------------------------- */

typedef struct {
    uint32_t struct_size;      /* sizeof(vtx_options) */
    int read_only;
    int durability;            /* 0: every write is durable when it returns (default)
                                  1: durable after vtx_sync, a checkpoint or vtx_close */
    uint64_t checkpoint_after; /* log bytes before an automatic checkpoint, 0: default (64 MiB) */
    int repair;                /* drop corrupted log records instead of failing */
} vtx_options;

/* Opens or creates the database directory. `opt` may be NULL. */
int vtx_open(const char *path, const vtx_options *opt, vtx_db **out);
/* Makes pending writes durable, checkpoints, and frees the handle (always). */
int vtx_close(vtx_db *db);
int vtx_sync(vtx_db *db);
int vtx_checkpoint(vtx_db *db);
/* Rebuilds a collection without deleted documents. */
int vtx_compact(vtx_db *db, const char *collection);

typedef struct {
    uint32_t collections;
    uint64_t documents;
    uint64_t last_seq;
    uint64_t checkpoint_seq;
    uint64_t generation;
    uint64_t wal_bytes;
} vtx_stats_t;
void vtx_stats(vtx_db *db, vtx_stats_t *out);

int vtx_count(vtx_db *db, const char *collection, uint32_t *out);
int vtx_collections(vtx_db *db, vtx_names **out);
size_t vtx_names_len(const vtx_names *n);
const char *vtx_names_get(const vtx_names *n, size_t i);
void vtx_names_free(vtx_names *n);

/* ---- schema and collections -------------------------------------------- */

vtx_schema *vtx_schema_new(void);
void vtx_schema_free(vtx_schema *s);
/* m and ef_construction: 0 for defaults (16, 200). int8 quantization requires cosine. */
int vtx_schema_vector(vtx_schema *s, uint32_t dim, int metric, int quantized,
                      uint32_t m, uint32_t ef_construction, const char *tag);
int vtx_schema_field(vtx_schema *s, const char *name, int type);
int vtx_schema_bm25(vtx_schema *s, float k1, float b);

int vtx_create_collection(vtx_db *db, const char *name, const vtx_schema *s);
int vtx_drop_collection(vtx_db *db, const char *name);

/* ---- writes ------------------------------------------------------------- */

vtx_batch *vtx_batch_new(void);
void vtx_batch_free(vtx_batch *b);
void vtx_batch_reset(vtx_batch *b);

/* Starts a document (insert or replace); the setters below apply to it. */
int vtx_batch_put(vtx_batch *b, const char *collection, const char *id, size_t id_len);
int vtx_batch_vector(vtx_batch *b, const float *v, size_t dim);
int vtx_batch_payload(vtx_batch *b, const void *p, size_t len);
int vtx_batch_text(vtx_batch *b, const char *field, const char *s, size_t len);
int vtx_batch_keyword(vtx_batch *b, const char *field, const char *s, size_t len);
int vtx_batch_keywords(vtx_batch *b, const char *field, const char *const *strs, const size_t *lens, size_t n);
int vtx_batch_int(vtx_batch *b, const char *field, int64_t v);
int vtx_batch_float(vtx_batch *b, const char *field, double v);
int vtx_batch_bool(vtx_batch *b, const char *field, int v);
int vtx_batch_time(vtx_batch *b, const char *field, int64_t ms);
int vtx_batch_delete(vtx_batch *b, const char *collection, const char *id, size_t id_len);

/* Applies the whole batch or nothing; `seq` (may be NULL) receives its sequence number. */
int vtx_write(vtx_db *db, vtx_batch *b, uint64_t *seq);

/* ---- filters (NULL on allocation failure or NULL field) ----------------- */

vtx_filter *vtx_filter_eq_keyword(const char *field, const char *s, size_t len); /* keywords: contains */
vtx_filter *vtx_filter_eq_int(const char *field, int64_t v);
vtx_filter *vtx_filter_eq_float(const char *field, double v);
vtx_filter *vtx_filter_eq_bool(const char *field, int v);
vtx_filter *vtx_filter_eq_time(const char *field, int64_t ms);
vtx_filter *vtx_filter_range_int(const char *field, int64_t lo, int64_t hi, int flags);
vtx_filter *vtx_filter_range_float(const char *field, double lo, double hi, int flags);
vtx_filter *vtx_filter_range_time(const char *field, int64_t lo, int64_t hi, int flags);
vtx_filter *vtx_filter_exists(const char *field);
vtx_filter *vtx_filter_and(vtx_filter *a, vtx_filter *b);
vtx_filter *vtx_filter_or(vtx_filter *a, vtx_filter *b);
vtx_filter *vtx_filter_not(vtx_filter *a);   /* includes documents without the field */
void vtx_filter_free(vtx_filter *f);

/* ---- queries ------------------------------------------------------------ */

vtx_query *vtx_query_new(const char *collection, uint32_t k);
void vtx_query_free(vtx_query *q);
int vtx_query_vector(vtx_query *q, const float *v, size_t dim);
int vtx_query_text(vtx_query *q, const char *s, size_t len);   /* BM25 */
int vtx_query_exact(vtx_query *q, const char *s, size_t len);  /* literal substring, exhaustive */
int vtx_query_text_field(vtx_query *q, const char *name);      /* restrict text/exact (repeatable) */
int vtx_query_filter(vtx_query *q, vtx_filter *f);
int vtx_query_ef(vtx_query *q, uint32_t ef);
int vtx_query_candidates(vtx_query *q, uint32_t n);            /* per route before fusion */
int vtx_query_rrf(vtx_query *q, float k);                      /* default fusion, k = 60 */
int vtx_query_weighted(vtx_query *q, float vector, float text);
int vtx_query_return_field(vtx_query *q, const char *name);    /* repeatable */
int vtx_query_payload(vtx_query *q, int include);              /* default 1 */

/* Without vector or text, returns matching documents in insertion order. */
int vtx_search(vtx_db *db, const vtx_query *q, vtx_results **out);
/* Zero or one result, with every field. */
int vtx_get(vtx_db *db, const char *collection, const char *id, size_t id_len, vtx_results **out);

/* ---- results ------------------------------------------------------------ */

typedef struct {
    uint32_t vector_rank;   /* 1-based, 0 when the vector route did not return it */
    float vector_distance;
    uint32_t text_rank;
    float text_score;
} vtx_explain;

size_t vtx_results_len(const vtx_results *r);
const char *vtx_result_id(const vtx_results *r, size_t i, size_t *len);
float vtx_result_score(const vtx_results *r, size_t i);
void vtx_result_explain(const vtx_results *r, size_t i, vtx_explain *out);
const void *vtx_result_payload(const vtx_results *r, size_t i, size_t *len); /* NULL if none */
size_t vtx_result_fields(const vtx_results *r, size_t i);
const char *vtx_result_field_name(const vtx_results *r, size_t i, size_t j, size_t *len);
int vtx_result_field_type(const vtx_results *r, size_t i, size_t j);
const char *vtx_result_field_str(const vtx_results *r, size_t i, size_t j, size_t *len);
size_t vtx_result_field_count(const vtx_results *r, size_t i, size_t j);
const char *vtx_result_field_item(const vtx_results *r, size_t i, size_t j, size_t k, size_t *len);
int64_t vtx_result_field_int(const vtx_results *r, size_t i, size_t j);
double vtx_result_field_float(const vtx_results *r, size_t i, size_t j);
int vtx_result_field_bool(const vtx_results *r, size_t i, size_t j);
void vtx_results_free(vtx_results *r);

#ifdef __cplusplus
}
#endif

#endif /* VECTIXDB_H */
