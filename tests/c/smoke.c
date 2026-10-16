/* Uses the public header exactly as a C program would. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "vectixdb.h"

#define CHECK(call)                                                        \
    do {                                                                   \
        int rc_ = (call);                                                  \
        if (rc_ != VTX_OK) {                                               \
            fprintf(stderr, "%s:%d: %s -> %d (%s)\n", __FILE__, __LINE__,  \
                    #call, rc_, vtx_last_error());                         \
            return 1;                                                      \
        }                                                                  \
    } while (0)

static int remove_tree(const char *path) {
    char cmd[4096];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", path);
    return system(cmd);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "c-smoke-db";
    remove_tree(path);
    printf("vectixdb %s\n", vtx_version());

    vtx_db *db = NULL;
    CHECK(vtx_open(path, NULL, &db));

    vtx_schema *s = vtx_schema_new();
    CHECK(vtx_schema_vector(s, 3, VTX_COSINE, 1, 0, 0, "demo"));
    CHECK(vtx_schema_field(s, "body", VTX_TEXT));
    CHECK(vtx_schema_field(s, "lang", VTX_KEYWORD));
    CHECK(vtx_create_collection(db, "notes", s));
    vtx_schema_free(s);

    vtx_batch *b = vtx_batch_new();
    const char *bodies[] = {"clear the metro cache", "zig build on macos", "metro et expo"};
    const char *langs[] = {"en", "en", "fr"};
    const float vecs[3][3] = {{1, 0, 0}, {0, 1, 0}, {0.8f, 0.2f, 0}};
    for (int i = 0; i < 3; i++) {
        char id[8];
        snprintf(id, sizeof id, "n%d", i);
        CHECK(vtx_batch_put(b, "notes", id, strlen(id)));
        CHECK(vtx_batch_vector(b, vecs[i], 3));
        CHECK(vtx_batch_text(b, "body", bodies[i], strlen(bodies[i])));
        CHECK(vtx_batch_keyword(b, "lang", langs[i], strlen(langs[i])));
    }
    uint64_t seq = 0;
    CHECK(vtx_write(db, b, &seq));
    vtx_batch_free(b);

    vtx_query *q = vtx_query_new("notes", 2);
    const float qv[3] = {1, 0.1f, 0};
    CHECK(vtx_query_vector(q, qv, 3));
    CHECK(vtx_query_text(q, "metro", 5));
    CHECK(vtx_query_filter(q, vtx_filter_eq_keyword("lang", "en", 2)));
    vtx_results *r = NULL;
    CHECK(vtx_search(db, q, &r));
    vtx_query_free(q);

    size_t len = 0;
    if (vtx_results_len(r) < 1) return 1;
    const char *id = vtx_result_id(r, 0, &len);
    printf("top: %.*s score %.4f\n", (int)len, id, vtx_result_score(r, 0));
    if (len != 2 || memcmp(id, "n0", 2) != 0) return 1;
    vtx_results_free(r);

    vtx_stats_t st;
    vtx_stats(db, &st);
    printf("documents: %llu, last seq: %llu\n", (unsigned long long)st.documents, (unsigned long long)st.last_seq);
    CHECK(vtx_close(db));
    remove_tree(path);
    puts("ok");
    return 0;
}
