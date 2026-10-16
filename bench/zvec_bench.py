"""Compares Zvec with `vectix bench` on identical data.

python zvec_bench.py gen  OUT_DIR [N] [DIM] [QUERIES]   writes vecs.f32 and queries.f32
python zvec_bench.py run  OUT_DIR [int8|f32]            benchmarks zvec on those files

Same protocol as `vectix bench`: HNSW m=16, ef_construction=200, ef=64, k=10,
cosine; fields group = i % 100 (1 % filter) and lang = langs[i % 5] (20 %);
recall@10 against exact cosine on the original f32 vectors.
"""
import os
import shutil
import sys
import time

import numpy as np
import zvec

LANGS = ["en", "fr", "ar", "de", "es"]


def gen(out, n=100_000, dim=384, queries=300):
    rng = np.random.default_rng(0xBE7C4)
    centers = rng.standard_normal((200, dim), dtype=np.float32)
    def draw(m):
        return centers[rng.integers(0, 200, m)] + 0.35 * rng.standard_normal((m, dim), dtype=np.float32)
    os.makedirs(out, exist_ok=True)
    draw(n).astype("<f4").tofile(os.path.join(out, "vecs.f32"))
    draw(queries).astype("<f4").tofile(os.path.join(out, "queries.f32"))
    print(f"wrote {n} vectors and {queries} queries of dim {dim} to {out}")


def truth(vecs, q, mask, k):
    vn = vecs / np.linalg.norm(vecs, axis=1, keepdims=True)
    qn = q / np.linalg.norm(q)
    sims = vn @ qn
    if mask is not None:
        sims = np.where(mask, sims, -np.inf)
    top = np.argpartition(-sims, k)[:k]
    return set(top[np.isfinite(sims[top])].tolist())


def pct(xs, p):
    xs = sorted(xs)
    return xs[int(p * (len(xs) - 1))] * 1000


def run(out, mode="int8", dim=384, k=10, ef=64):
    vecs = np.fromfile(os.path.join(out, "vecs.f32"), dtype="<f4").reshape(-1, dim)
    queries = np.fromfile(os.path.join(out, "queries.f32"), dtype="<f4").reshape(-1, dim)
    n = len(vecs)
    path = os.path.join(out, f"zvec-{mode}")
    shutil.rmtree(path, ignore_errors=True)

    quant = zvec.QuantizeType.INT8 if mode == "int8" else zvec.QuantizeType.UNDEFINED
    schema = zvec.CollectionSchema(
        name="bench",
        vectors=zvec.VectorSchema("v", zvec.DataType.VECTOR_FP32, dim,
                                  index_param=zvec.HnswIndexParam(metric_type=zvec.MetricType.COSINE, m=16,
                                                                  ef_construction=200, quantize_type=quant)),
        fields=[
            zvec.FieldSchema("group", zvec.DataType.INT64, index_param=zvec.InvertIndexParam()),
            zvec.FieldSchema("lang", zvec.DataType.STRING, index_param=zvec.InvertIndexParam()),
        ],
    )
    col = zvec.create_and_open(path=path, schema=schema)
    print(f"zvec {zvec.__version__} bench: {n} documents, dim {dim} {mode}, k {k}, ef {ef}")

    t0 = time.perf_counter()
    for start in range(0, n, 1000):
        docs = [zvec.Doc(id=f"d{i}", vectors={"v": vecs[i].tolist()},
                         fields={"group": i % 100, "lang": LANGS[i % 5]})
                for i in range(start, min(start + 1000, n))]
        col.insert(docs)
    t_insert = time.perf_counter() - t0
    t1 = time.perf_counter()
    col.optimize()
    col.flush()
    t_opt = time.perf_counter() - t1
    total = t_insert + t_opt
    print(f"ingest      {n} docs in {total:.1f} s  ({n / total:.0f} docs/s; insert {t_insert:.1f} s + optimize {t_opt:.1f} s)")
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(path) for f in fs)
    print(f"disk        {size / 2**20:.1f} MiB")
    col.close() if hasattr(col, "close") else None
    t2 = time.perf_counter()
    col = zvec.open(path=path)
    print(f"reopen      {time.perf_counter() - t2:.2f} s")

    idx = np.arange(n)
    routes = [
        ("vector", None, None),
        ("vector 20%", "lang = 'en'", idx % 5 == 0),
        ("vector 1%", "group = 7", idx % 100 == 7),
    ]
    print(f"\n{'route':<12}{'p50 ms':>9}{'p95 ms':>9}{'p99 ms':>9}{'recall@k':>11}")
    for name, flt, mask in routes:
        lat, hits, tot = [], 0, 0
        for q in queries:
            t = time.perf_counter()
            res = col.query(zvec.Query(field_name="v", vector=q.tolist(), param=zvec.HnswQueryParam(ef=ef)),
                            topk=k, filter=flt)
            lat.append(time.perf_counter() - t)
            want = truth(vecs, q, mask, k)
            got = {int(d.id[1:]) for d in res}
            hits += len(got & want)
            tot += len(want)
        print(f"{name:<12}{pct(lat, .5):>9.3f}{pct(lat, .95):>9.3f}{pct(lat, .99):>9.3f}{hits / tot:>11.3f}")
    import resource
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    print(f"\npeak memory {rss / (2**20 if sys.platform == 'darwin' else 1024):.0f} MiB (includes numpy data)")


if __name__ == "__main__":
    cmd, out = sys.argv[1], sys.argv[2]
    if cmd == "gen":
        gen(out, *[int(x) for x in sys.argv[3:]])
    else:
        run(out, sys.argv[3] if len(sys.argv) > 3 else "int8")
