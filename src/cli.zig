//! vectix: command line tool for VectixDB databases.
//!
//!   vectix info   <dir>
//!   vectix verify <dir>
//!   vectix search <dir> <collection> [--text Q] [--exact S] [--k N] [--field F]...
//!   vectix get    <dir> <collection> <id>
//!   vectix bench  [--n N] [--dim D] [--queries Q] [--k K] [--ef E] [--f32] [--dir PATH] [--keep]
//!                 [--vectors FILE --qvectors FILE]
//!
//! Every command except bench opens the database read-only (shared lock).

const std = @import("std");
const vx = @import("vectixdb");

const Db = vx.db.Db;
const Io = std.Io;

const usage =
    \\usage:
    \\  vectix info   <dir>                          collections, documents, log state
    \\  vectix verify <dir>                          load everything and check every index
    \\  vectix search <dir> <collection> [--text Q] [--exact S] [--k N] [--field F]...
    \\  vectix get    <dir> <collection> <id>
    \\  vectix bench  [--n 100000] [--dim 384] [--queries 300] [--k 10] [--ef 64] [--f32] [--dir PATH] [--keep]
    \\               [--vectors FILE --qvectors FILE]   raw f32 rows instead of generated data
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [8192]u8 = undefined;
    var out_file = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }
    const cmd = args[1];
    const rest = args[2..];
    const result = if (std.mem.eql(u8, cmd, "info"))
        info(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "verify"))
        verify(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "search"))
        search(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "get"))
        get(gpa, io, out, rest)
    else if (std.mem.eql(u8, cmd, "bench"))
        bench(gpa, io, out, rest)
    else {
        try out.writeAll(usage);
        std.process.exit(2);
    };
    result catch |e| {
        out.flush() catch {};
        var err_buf: [256]u8 = undefined;
        var err_file = Io.File.stderr().writerStreaming(io, &err_buf);
        err_file.interface.print("vectix {s}: {t}\n", .{ cmd, e }) catch {};
        err_file.interface.flush() catch {};
        std.process.exit(1);
    };
}

const Opened = struct {
    real: vx.fs.Real,
    db: *Db,

    fn close(o: *Opened) void {
        o.db.close() catch {};
        o.real.deinit();
    }
};

fn openReadOnly(gpa: std.mem.Allocator, io: Io, path: []const u8) !Opened {
    var o: Opened = .{ .real = try vx.fs.Real.open(io, path, .shared), .db = undefined };
    errdefer o.real.deinit();
    o.db = try Db.open(gpa, io, o.real.fs(), .{ .read_only = true });
    return o;
}

fn info(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.InvalidArgument;
    var o = try openReadOnly(gpa, io, args[0]);
    defer o.close();
    const s = o.db.stats();
    try out.print("vectixdb {s}\n", .{vx.version});
    try out.print("generation {d}, last seq {d}, checkpoint seq {d}, log {d} bytes since checkpoint\n", .{ s.generation, s.last_seq, s.checkpoint_seq, s.wal_bytes });
    try out.print("{d} collections, {d} documents\n", .{ s.collections, s.documents });
    for (o.db.collections.values()) |e| {
        const c = e.coll;
        try out.print("\n{s}: {d} documents ({d} slots)\n", .{ c.name, c.len(), c.slots() });
        if (c.schema.vector) |v| {
            const st = c.vectors.?.stats();
            try out.print("  vector  dim {d}, {t}, {s}, m {d}, ef_construction {d}, tag \"{s}\"\n", .{ v.dim, v.metric, if (v.quantized) "int8" else "f32", v.m, v.ef_construction, v.tag });
            try out.print("          {d} nodes ({d} live), max level {d}, {d} edges, {d} KiB\n", .{ st.nodes, st.live, st.max_level, st.edges, st.memory_bytes / 1024 });
        }
        for (c.schema.fields, c.columns) |f, *col| {
            try out.print("  {s: <8}{t}", .{ f.name, f.type });
            if (col.* == .text) {
                const bs = col.text.index.stats();
                try out.print(", {d} docs, {d} terms, avg length {d:.1}", .{ bs.docs, bs.terms, bs.avg_doc_len });
            }
            try out.writeAll("\n");
        }
    }
}

fn verify(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len != 1) return error.InvalidArgument;
    const start = Io.Timestamp.now(io, .awake);
    var o = try openReadOnly(gpa, io, args[0]);
    defer o.close();
    try o.db.verify();
    const s = o.db.stats();
    try out.print("ok: {d} collections, {d} documents, log replayed to seq {d} ({d} ms)\n", .{ s.collections, s.documents, s.last_seq, ms(start.untilNow(io, .awake)) });
}

fn search(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 2) return error.InvalidArgument;
    var q: vx.collection.Query = .{};
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(gpa);
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArgument;
        const opt = args[i];
        const val = args[i + 1];
        if (std.mem.eql(u8, opt, "--text")) {
            q.text = val;
        } else if (std.mem.eql(u8, opt, "--exact")) {
            q.exact = val;
        } else if (std.mem.eql(u8, opt, "--k")) {
            q.k = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, opt, "--field")) {
            try fields.append(gpa, val);
        } else return error.InvalidArgument;
    }
    var o = try openReadOnly(gpa, io, args[0]);
    defer o.close();
    const start = Io.Timestamp.now(io, .awake);
    var res = try o.db.search(args[1], q, .{ .fields = fields.items, .payload = false });
    defer res.deinit();
    const elapsed = start.untilNow(io, .awake);
    for (res.items, 1..) |r, rank| {
        try out.print("{d: >3}. {s}  score {d:.4}", .{ rank, r.id, r.score });
        if (r.text_rank > 0) try out.print("  text #{d} ({d:.3})", .{ r.text_rank, r.text_score });
        try out.writeAll("\n");
        for (r.fields) |f| try printField(out, f);
    }
    try out.print("{d} results in {d:.2} ms\n", .{ res.items.len, @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1e6 });
}

fn get(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    if (args.len != 3) return error.InvalidArgument;
    var o = try openReadOnly(gpa, io, args[0]);
    defer o.close();
    var res = (try o.db.get(args[1], args[2])) orelse return error.NotFound;
    defer res.deinit();
    const r = res.items[0];
    try out.print("{s}\n", .{r.id});
    for (r.fields) |f| try printField(out, f);
    if (r.payload) |p| try out.print("  payload: {d} bytes\n", .{p.len});
}

fn printField(out: *Io.Writer, f: vx.schema.FieldValue) !void {
    try out.print("     {s}: ", .{f.field});
    switch (f.value) {
        .text => |s| try out.print("{s}", .{s[0..@min(s.len, 160)]}),
        .keyword => |s| try out.print("{s}", .{s}),
        .keywords => |ks| for (ks, 0..) |k, j| try out.print("{s}{s}", .{ if (j > 0) ", " else "", k }),
        .int, .time => |x| try out.print("{d}", .{x}),
        .float => |x| try out.print("{d}", .{x}),
        .bool => |x| try out.print("{}", .{x}),
    }
    try out.writeAll("\n");
}

fn ms(d: Io.Duration) i64 {
    return @intCast(@divTrunc(d.toNanoseconds(), std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// Benchmark

const BenchOpts = struct {
    n: usize = 100_000,
    dim: u32 = 384,
    queries: usize = 300,
    k: u32 = 10,
    ef: u32 = 64,
    quantized: bool = true,
    dir: []const u8 = "vectix-bench-db",
    /// Keep the database after the run (for info, verify, search).
    keep: bool = false,
    /// Raw little-endian f32 files (rows of `dim` values) to use instead of
    /// generated vectors, e.g. to compare engines on identical data.
    vectors: ?[]const u8 = null,
    qvectors: ?[]const u8 = null,
};

/// Synthetic corpus: vectors drawn around 200 cluster centers (closer to
/// real embeddings than uniform noise), Zipf-distributed words, an int
/// field with 100 values (1 % selectivity) and a keyword with 5 (20 %).
const Corpus = struct {
    dim: u32,
    centers: []f32,
    words: [][]u8,
    zipf: []f64,

    const ncenters = 200;
    const nwords = 5000;
    const langs = [_][]const u8{ "en", "fr", "ar", "de", "es" };

    fn init(gpa: std.mem.Allocator, dim: u32, rnd: std.Random) !Corpus {
        const centers = try gpa.alloc(f32, ncenters * dim);
        for (centers) |*x| x.* = rnd.floatNorm(f32);
        const words = try gpa.alloc([]u8, nwords);
        for (words, 0..) |*w, i| w.* = try std.fmt.allocPrint(gpa, "w{d}", .{i});
        const zipf = try gpa.alloc(f64, nwords);
        var total: f64 = 0;
        for (zipf, 1..) |*z, i| {
            total += 1.0 / @as(f64, @floatFromInt(i));
            z.* = total;
        }
        for (zipf) |*z| z.* /= total;
        return .{ .dim = dim, .centers = centers, .words = words, .zipf = zipf };
    }

    fn deinit(c: *Corpus, gpa: std.mem.Allocator) void {
        gpa.free(c.centers);
        for (c.words) |w| gpa.free(w);
        gpa.free(c.words);
        gpa.free(c.zipf);
    }

    fn vector(c: *const Corpus, rnd: std.Random, out: []f32) void {
        const center = c.centers[rnd.uintLessThan(usize, ncenters) * c.dim ..][0..c.dim];
        for (out, center) |*x, m| x.* = m + 0.35 * rnd.floatNorm(f32);
    }

    fn word(c: *const Corpus, rnd: std.Random) []const u8 {
        const u = rnd.float(f64);
        const i = std.sort.lowerBound(f64, c.zipf, u, struct {
            fn order(a: f64, b: f64) std.math.Order {
                return std.math.order(a, b);
            }
        }.order);
        return c.words[@min(i, c.words.len - 1)];
    }

    fn text(c: *const Corpus, rnd: std.Random, buf: *std.ArrayList(u8), gpa: std.mem.Allocator, words: usize) !void {
        buf.clearRetainingCapacity();
        for (0..words) |i| {
            if (i > 0) try buf.append(gpa, ' ');
            try buf.appendSlice(gpa, c.word(rnd));
        }
    }
};

const Latency = struct {
    samples: std.ArrayList(u64) = .empty,

    fn add(l: *Latency, gpa: std.mem.Allocator, ns: i96) !void {
        try l.samples.append(gpa, @intCast(ns));
    }

    fn pct(l: *Latency, p: f64) f64 {
        std.mem.sort(u64, l.samples.items, {}, std.sort.asc(u64));
        const idx: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(l.samples.items.len - 1))));
        return @as(f64, @floatFromInt(l.samples.items[idx])) / 1e6;
    }
};

fn bench(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, args: []const [:0]const u8) !void {
    var o: BenchOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = args[i];
        if (std.mem.eql(u8, opt, "--f32")) {
            o.quantized = false;
            continue;
        }
        if (std.mem.eql(u8, opt, "--keep")) {
            o.keep = true;
            continue;
        }
        if (i + 1 >= args.len) return error.InvalidArgument;
        const val = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, opt, "--n")) o.n = try std.fmt.parseInt(usize, val, 10) else if (std.mem.eql(u8, opt, "--dim")) o.dim = try std.fmt.parseInt(u32, val, 10) else if (std.mem.eql(u8, opt, "--queries")) o.queries = try std.fmt.parseInt(usize, val, 10) else if (std.mem.eql(u8, opt, "--k")) o.k = try std.fmt.parseInt(u32, val, 10) else if (std.mem.eql(u8, opt, "--ef")) o.ef = try std.fmt.parseInt(u32, val, 10) else if (std.mem.eql(u8, opt, "--dir")) o.dir = val else if (std.mem.eql(u8, opt, "--vectors")) o.vectors = val else if (std.mem.eql(u8, opt, "--qvectors")) o.qvectors = val else return error.InvalidArgument;
    }

    Io.Dir.cwd().deleteTree(io, o.dir) catch {};
    defer if (!o.keep) Io.Dir.cwd().deleteTree(io, o.dir) catch {};

    var prng = std.Random.DefaultPrng.init(0xbe7c4);
    const rnd = prng.random();
    var corpus = try Corpus.init(gpa, o.dim, rnd);
    defer corpus.deinit(gpa);
    const loaded = if (o.vectors) |path| try loadF32(gpa, io, path, o.dim) else null;
    defer if (loaded) |l| gpa.free(l);
    if (loaded) |l| o.n = l.len / o.dim;
    const loaded_q = if (o.qvectors) |path| try loadF32(gpa, io, path, o.dim) else null;
    defer if (loaded_q) |l| gpa.free(l);
    if (loaded_q) |l| o.queries = l.len / o.dim;

    try out.print("vectixdb {s} bench: {d} documents, dim {d} {s}, k {d}, ef {d}\n", .{ vx.version, o.n, o.dim, if (o.quantized) "int8" else "f32", o.k, o.ef });
    try out.flush();

    var real = try vx.fs.Real.open(io, o.dir, .exclusive);
    var db = try Db.open(gpa, io, real.fs(), .{ .durability = .none, .checkpoint_after = 0 });
    _ = try db.createCollection("bench", .{
        .vector = .{ .dim = o.dim, .quantized = o.quantized },
        .fields = &.{
            .{ .name = "body", .type = .text },
            .{ .name = "group", .type = .int },
            .{ .name = "lang", .type = .keyword },
        },
    });

    // ---- ingestion
    const batch_size = 1000;
    const vecs = try gpa.alloc(f32, batch_size * o.dim);
    defer gpa.free(vecs);
    const texts = try gpa.alloc(std.ArrayList(u8), batch_size);
    defer {
        for (texts) |*t| t.deinit(gpa);
        gpa.free(texts);
    }
    for (texts) |*t| t.* = .empty;
    const ids = try gpa.alloc([16]u8, batch_size);
    defer gpa.free(ids);
    const fields = try gpa.alloc([3]vx.schema.FieldValue, batch_size);
    defer gpa.free(fields);
    const ops = try gpa.alloc(vx.batch.Op, batch_size);
    defer gpa.free(ops);

    // Original f32 vectors, for the exact ground truth.
    const all_vecs = try gpa.alloc(f32, o.n * o.dim);
    defer gpa.free(all_vecs);

    const ingest_start = Io.Timestamp.now(io, .awake);
    var done: usize = 0;
    while (done < o.n) {
        const m = @min(batch_size, o.n - done);
        for (0..m) |j| {
            const doc_i = done + j;
            const v = vecs[j * o.dim ..][0..o.dim];
            if (loaded) |l| @memcpy(v, l[doc_i * o.dim ..][0..o.dim]) else corpus.vector(rnd, v);
            @memcpy(all_vecs[doc_i * o.dim ..][0..o.dim], v);
            try corpus.text(rnd, &texts[j], gpa, 30);
            const id = try std.fmt.bufPrint(&ids[j], "d{d}", .{doc_i});
            fields[j] = .{
                .{ .field = "body", .value = .{ .text = texts[j].items } },
                .{ .field = "group", .value = .{ .int = @intCast(doc_i % 100) } },
                .{ .field = "lang", .value = .{ .keyword = Corpus.langs[doc_i % Corpus.langs.len] } },
            };
            ops[j] = .{ .put = .{ .collection = "bench", .doc = .{ .id = id, .vector = v, .fields = &fields[j] } } };
        }
        _ = try db.write(ops[0..m]);
        done += m;
        if (done % 20_000 == 0 or done == o.n) {
            try out.print("  ingested {d}\r", .{done});
            try out.flush();
        }
    }
    try db.sync();
    const ingest = start_elapsed(io, ingest_start);
    try out.print("ingest      {d} docs in {d:.1} s  ({d:.0} docs/s)\n", .{ o.n, ingest, @as(f64, @floatFromInt(o.n)) / ingest });

    const ck_start = Io.Timestamp.now(io, .awake);
    try db.checkpoint();
    try out.print("checkpoint  {d:.2} s, disk {d:.1} MiB\n", .{ start_elapsed(io, ck_start), @as(f64, @floatFromInt(try dirSize(io, o.dir))) / (1 << 20) });
    try db.close();
    real.deinit();

    const open_start = Io.Timestamp.now(io, .awake);
    real = try vx.fs.Real.open(io, o.dir, .exclusive);
    defer real.deinit();
    db = try Db.open(gpa, io, real.fs(), .{});
    defer db.close() catch {};
    try out.print("reopen      {d:.2} s\n", .{start_elapsed(io, open_start)});

    // ---- queries
    const qvecs = try gpa.alloc(f32, o.queries * o.dim);
    defer gpa.free(qvecs);
    const qtexts = try gpa.alloc(std.ArrayList(u8), o.queries);
    defer {
        for (qtexts) |*t| t.deinit(gpa);
        gpa.free(qtexts);
    }
    for (0..o.queries) |qi| {
        if (loaded_q) |l| @memcpy(qvecs[qi * o.dim ..][0..o.dim], l[qi * o.dim ..][0..o.dim]) else corpus.vector(rnd, qvecs[qi * o.dim ..][0..o.dim]);
        qtexts[qi] = .empty;
        try corpus.text(rnd, &qtexts[qi], gpa, 3);
    }

    const selective: vx.filter.Filter = .{ .eq = .{ .field = "group", .value = .{ .int = 7 } } };
    const broad: vx.filter.Filter = .{ .eq = .{ .field = "lang", .value = .{ .keyword = "en" } } };
    const Route = struct { name: []const u8, vector: bool, text: bool, filter: ?*const vx.filter.Filter, exact: bool = false };
    const routes = [_]Route{
        .{ .name = "vector", .vector = true, .text = false, .filter = null },
        .{ .name = "text", .vector = false, .text = true, .filter = null },
        .{ .name = "hybrid", .vector = true, .text = true, .filter = null },
        .{ .name = "vector 20%", .vector = true, .text = false, .filter = &broad },
        .{ .name = "vector 1%", .vector = true, .text = false, .filter = &selective },
        .{ .name = "hybrid 20%", .vector = true, .text = true, .filter = &broad },
        .{ .name = "exact 1%", .vector = false, .text = false, .filter = &selective, .exact = true },
    };

    try out.print("\n{s: <12}{s: >9}{s: >9}{s: >9}{s: >11}\n", .{ "route", "p50 ms", "p95 ms", "p99 ms", "recall@k" });
    for (routes) |route| {
        var lat: Latency = .{};
        defer lat.samples.deinit(gpa);
        var hits_total: usize = 0;
        var truth_total: usize = 0;
        for (0..o.queries) |qi| {
            const qv = qvecs[qi * o.dim ..][0..o.dim];
            const q: vx.collection.Query = .{
                .vector = if (route.vector) qv else null,
                .text = if (route.text) qtexts[qi].items else null,
                .exact = if (route.exact) corpus.words[qi % 50] else null,
                .filter = route.filter,
                .k = o.k,
                .ef = o.ef,
            };
            const t0 = Io.Timestamp.now(io, .awake);
            var res = try db.search("bench", q, .{ .payload = false });
            try lat.add(gpa, t0.untilNow(io, .awake).toNanoseconds());
            defer res.deinit();

            if (route.vector and !route.text) {
                const truth = try exactTopK(gpa, all_vecs, o.dim, qv, route.filter == &selective, route.filter == &broad, o.k);
                defer gpa.free(truth);
                for (res.items) |r| {
                    const doc = try std.fmt.parseInt(u32, r.id[1..], 10);
                    if (std.mem.indexOfScalar(u32, truth, doc) != null) hits_total += 1;
                }
                truth_total += truth.len;
            }
        }
        try out.print("{s: <12}{d: >9.3}{d: >9.3}{d: >9.3}", .{ route.name, lat.pct(0.5), lat.pct(0.95), lat.pct(0.99) });
        if (truth_total > 0) {
            try out.print("{d: >11.3}\n", .{@as(f64, @floatFromInt(hits_total)) / @as(f64, @floatFromInt(truth_total))});
        } else try out.print("{s: >11}\n", .{"-"});
        try out.flush();
    }
    const ru = std.posix.getrusage(std.posix.rusage.SELF);
    const rss_mib = @as(f64, @floatFromInt(ru.maxrss)) / if (@import("builtin").os.tag.isDarwin()) @as(f64, 1 << 20) else 1024;
    try out.print("\npeak memory {d:.0} MiB\n", .{rss_mib});
}

/// True k nearest documents by exhaustive cosine on the original f32
/// vectors, with the bench filters applied (group 7, or lang "en").
fn exactTopK(gpa: std.mem.Allocator, vecs: []const f32, dim: u32, q: []const f32, group7: bool, en: bool, k: u32) ![]u32 {
    const Item = vx.topk.Item;
    var best: vx.topk.MaxHeap = .{};
    defer best.deinit(gpa);
    const qn = @sqrt(vx.distance.dot(q, q));
    const n = vecs.len / dim;
    for (0..n) |i| {
        if (group7 and i % 100 != 7) continue;
        if (en and i % Corpus.langs.len != 0) continue;
        const v = vecs[i * dim ..][0..dim];
        const d = 1 - vx.distance.dot(q, v) / (qn * @sqrt(vx.distance.dot(v, v)));
        const item = Item{ .slot = @intCast(i), .dist = d };
        if (best.len() < k) {
            try best.push(gpa, item);
        } else if (d < best.peek().?.dist) {
            _ = best.pop();
            try best.push(gpa, item);
        }
    }
    const out = try gpa.alloc(u32, best.len());
    for (best.items.items, out) |it, *s| s.* = it.slot;
    return out;
}

fn loadF32(gpa: std.mem.Allocator, io: Io, path: []const u8, dim: u32) ![]f32 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    if (bytes.len % (4 * dim) != 0) return error.InvalidArgument;
    const out = try gpa.alloc(f32, bytes.len / 4);
    for (out, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    return out;
}

fn start_elapsed(io: Io, t: Io.Timestamp) f64 {
    return @as(f64, @floatFromInt(t.untilNow(io, .awake).toNanoseconds())) / 1e9;
}

fn dirSize(io: Io, path: []const u8) !u64 {
    var dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const st = try dir.statFile(io, e.name, .{});
        total += st.size;
    }
    return total;
}
