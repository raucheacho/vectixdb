//! Hierarchical Navigable Small World graph (Malkov & Yashunin, 2016).
//!
//! Layout is flat and cache friendly: vectors live in one contiguous array,
//! layer-0 adjacency in another (`count | neighbors...` per node), and only the
//! rare upper layers get a per-node allocation. Each node carries a `u32`
//! label, the slot of its document in the owning collection: results report
//! labels, and filters are bitsets over labels.
//!
//! Deletion is a tombstone: the node keeps routing traffic but never appears in
//! results. `compact` rebuilds the graph from live nodes only.
//!
//! Writes are not thread safe, except `insertBatch`, which links the nodes of
//! a batch on several threads (per-node spin locks guard the adjacency lists,
//! a global one the entry point). Concurrent `search` calls are safe as long
//! as no write runs at the same time. With one thread the graph is
//! deterministic; with several it depends on scheduling (results stay
//! equally good, not identical).

const std = @import("std");
const distance = @import("distance.zig");
const codec = @import("codec.zig");
const topk = @import("topk.zig");

pub const Metric = distance.Metric;
pub const Item = topk.Item;
/// Set of accepted labels.
pub const Filter = std.DynamicBitSetUnmanaged;

pub const magic = "VTXH";
/// Largest adjacency list: 2 * max m.
const max_links = 512;

fn spinLock(l: *std.atomic.Value(u8)) void {
    while (l.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub const format_version: u32 = 1;
const max_level_cap: u8 = 16;

pub const Config = struct {
    dim: u32,
    metric: Metric = .cosine,
    /// Store int8 codes instead of f32 (4x less memory). Cosine only.
    quantized: bool = false,
    m: u32 = 16,
    ef_construction: u32 = 200,
    seed: u64 = 0x10ea9,
};

pub const Error = error{ OutOfMemory, DimensionMismatch, InvalidConfig, Corrupt };

pub const Stats = struct {
    nodes: u32,
    live: u32,
    max_level: i32,
    edges: u64,
    memory_bytes: u64,
};

/// A vector prepared for distance computations against stored nodes.
pub const Query = struct {
    f: []f32 = &.{},
    codes: []i8 = &.{},
    factor: f32 = 0,

    pub fn deinit(q: *Query, gpa: std.mem.Allocator) void {
        if (q.f.len > 0) gpa.free(q.f);
        if (q.codes.len > 0) gpa.free(q.codes);
    }
};

/// Per-call scratch space, so that searches never touch shared state.
const Scratch = struct {
    visited: []u64,
    candidates: topk.MinHeap = .{},
    results: topk.MaxHeap = .{},

    fn init(gpa: std.mem.Allocator, nodes: usize) !Scratch {
        const words = (nodes + 63) / 64;
        const v = try gpa.alloc(u64, @max(words, 1));
        @memset(v, 0);
        return .{ .visited = v };
    }

    fn deinit(s: *Scratch, gpa: std.mem.Allocator) void {
        gpa.free(s.visited);
        s.candidates.deinit(gpa);
        s.results.deinit(gpa);
    }

    fn reset(s: *Scratch) void {
        @memset(s.visited, 0);
        s.candidates.items.items.len = 0;
        s.results.items.items.len = 0;
    }

    inline fn visit(s: *Scratch, node: u32) bool {
        const w = node >> 6;
        const bit = @as(u64, 1) << @intCast(node & 63);
        const seen = s.visited[w] & bit != 0;
        s.visited[w] |= bit;
        return seen;
    }
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    m0: u32,
    ml: f64,
    rng: std.Random.DefaultPrng,

    count: u32 = 0,
    live: u32 = 0,
    entry: u32 = 0,
    max_level: i32 = -1,

    vectors: std.ArrayList(f32) = .empty,
    codes: std.ArrayList(i8) = .empty,
    factors: std.ArrayList(f32) = .empty,
    levels: std.ArrayList(u8) = .empty,
    deleted: std.ArrayList(bool) = .empty,
    labels: std.ArrayList(u32) = .empty,
    links0: std.ArrayList(u32) = .empty,
    upper: std.ArrayList(?[]u32) = .empty,

    /// Per-node locks, used only while `concurrent` (parallel batch insert).
    node_locks: std.ArrayList(std.atomic.Value(u8)) = .empty,
    entry_lock: std.atomic.Value(u8) = .init(0),
    concurrent: bool = false,

    pub fn init(gpa: std.mem.Allocator, cfg: Config) Error!*Index {
        if (cfg.dim == 0 or cfg.dim > 65536) return error.InvalidConfig;
        if (cfg.m < 2 or cfg.m > 256) return error.InvalidConfig;
        if (cfg.quantized and cfg.metric != .cosine) return error.InvalidConfig;
        const self = try gpa.create(Index);
        self.* = .{
            .gpa = gpa,
            .cfg = cfg,
            .m0 = cfg.m * 2,
            .ml = 1.0 / @log(@as(f64, @floatFromInt(cfg.m))),
            .rng = std.Random.DefaultPrng.init(cfg.seed),
        };
        self.cfg.ef_construction = @max(cfg.ef_construction, cfg.m);
        return self;
    }

    pub fn deinit(self: *Index) void {
        const gpa = self.gpa;
        for (self.upper.items) |u| if (u) |s| gpa.free(s);
        self.vectors.deinit(gpa);
        self.codes.deinit(gpa);
        self.factors.deinit(gpa);
        self.levels.deinit(gpa);
        self.deleted.deinit(gpa);
        self.labels.deinit(gpa);
        self.links0.deinit(gpa);
        self.upper.deinit(gpa);
        self.node_locks.deinit(gpa);
        gpa.destroy(self);
    }

    // ---- vector access -------------------------------------------------

    pub fn prepare(self: *const Index, gpa: std.mem.Allocator, v: []const f32) Error!Query {
        const dim = self.cfg.dim;
        if (v.len != dim) return error.DimensionMismatch;
        const f = try gpa.dupe(f32, v);
        if (self.cfg.metric == .cosine) distance.normalize(f);
        if (!self.cfg.quantized) return .{ .f = f };
        defer gpa.free(f);
        const codes = try gpa.alloc(i8, dim);
        const factor = distance.quantize(f, codes);
        return .{ .codes = codes, .factor = factor };
    }

    inline fn vec(self: *const Index, node: u32) []const f32 {
        const d = self.cfg.dim;
        return self.vectors.items[@as(usize, node) * d ..][0..d];
    }

    inline fn code(self: *const Index, node: u32) []const i8 {
        const d = self.cfg.dim;
        return self.codes.items[@as(usize, node) * d ..][0..d];
    }

    /// Internal distance: smaller is closer; squared for L2.
    pub inline fn distQ(self: *const Index, q: *const Query, node: u32) f32 {
        if (self.cfg.quantized) {
            const ip: f32 = @floatFromInt(distance.dotI8(q.codes, self.code(node)));
            return 1.0 - ip * q.factor * self.factors.items[node];
        }
        return switch (self.cfg.metric) {
            .cosine, .dot => 1.0 - distance.dot(q.f, self.vec(node)),
            .l2 => distance.l2sq(q.f, self.vec(node)),
        };
    }

    /// Converts an internal distance into the reported one.
    pub inline fn reportDist(self: *const Index, d: f32) f32 {
        return if (self.cfg.metric == .l2) @sqrt(@max(d, 0)) else d;
    }

    inline fn distNodes(self: *const Index, a: u32, b: u32) f32 {
        if (self.cfg.quantized) {
            const ip: f32 = @floatFromInt(distance.dotI8(self.code(a), self.code(b)));
            return 1.0 - ip * self.factors.items[a] * self.factors.items[b];
        }
        return switch (self.cfg.metric) {
            .cosine, .dot => 1.0 - distance.dot(self.vec(a), self.vec(b)),
            .l2 => distance.l2sq(self.vec(a), self.vec(b)),
        };
    }

    // ---- adjacency -----------------------------------------------------

    inline fn maxLinks(self: *const Index, level: usize) u32 {
        return if (level == 0) self.m0 else self.cfg.m;
    }

    fn block(self: *const Index, node: u32, level: usize) []u32 {
        if (level == 0) {
            const stride = self.m0 + 1;
            return self.links0.items[@as(usize, node) * stride ..][0..stride];
        }
        const stride = self.cfg.m + 1;
        return self.upper.items[node].?[(level - 1) * stride ..][0..stride];
    }

    pub fn neighbors(self: *const Index, node: u32, level: usize) []const u32 {
        const b = self.block(node, level);
        return b[1..][0..b[0]];
    }

    /// The neighbors of `node`, copied under its lock during a parallel
    /// insert (another thread may be rewriting the list).
    fn readNeighbors(self: *const Index, node: u32, level: usize, buf: *[max_links]u32) []const u32 {
        if (!self.concurrent) return self.neighbors(node, level);
        const s = @constCast(self);
        s.lockNode(node);
        defer s.unlockNode(node);
        const ns = self.neighbors(node, level);
        @memcpy(buf[0..ns.len], ns);
        return buf[0..ns.len];
    }

    fn lockNode(self: *Index, node: u32) void {
        if (!self.concurrent) return;
        spinLock(&self.node_locks.items[node]);
    }

    fn unlockNode(self: *Index, node: u32) void {
        if (!self.concurrent) return;
        self.node_locks.items[node].store(0, .release);
    }

    fn setNeighbors(self: *Index, node: u32, level: usize, ns: []const Item) void {
        const b = self.block(node, level);
        b[0] = @intCast(ns.len);
        for (ns, 0..) |n, i| b[1 + i] = n.slot;
    }

    // ---- search primitives --------------------------------------------

    fn greedy(self: *const Index, q: *const Query, start: u32, level: usize) Item {
        var cur = Item{ .slot = start, .dist = self.distQ(q, start) };
        var changed = true;
        var buf: [max_links]u32 = undefined;
        while (changed) {
            changed = false;
            for (self.readNeighbors(cur.slot, level, &buf)) |n| {
                const d = self.distQ(q, n);
                if (d < cur.dist) {
                    cur = .{ .slot = n, .dist = d };
                    changed = true;
                }
            }
        }
        return cur;
    }

    inline fn admit(self: *const Index, node: u32, filter: ?*const Filter) bool {
        if (self.deleted.items[node]) return false;
        const f = filter orelse return true;
        const label = self.labels.items[node];
        return label < f.bit_length and f.isSet(label);
    }

    /// Beam search on one layer. Leaves up to `ef` results in `s.results`
    /// (node ids). With `results_only_admitted`, only live nodes accepted by
    /// `filter` enter the results; every node still routes the search.
    fn searchLayer(
        self: *const Index,
        gpa: std.mem.Allocator,
        s: *Scratch,
        q: *const Query,
        entry: Item,
        ef: usize,
        level: usize,
        results_only_admitted: bool,
        filter: ?*const Filter,
    ) !void {
        s.reset();
        _ = s.visit(entry.slot);
        try s.candidates.push(gpa, entry);
        if (!results_only_admitted or self.admit(entry.slot, filter)) try s.results.push(gpa, entry);

        var buf: [max_links]u32 = undefined;
        while (s.candidates.pop()) |c| {
            const bound = if (s.results.peek()) |r| r.dist else std.math.inf(f32);
            if (c.dist > bound and s.results.len() >= ef) break;
            for (self.readNeighbors(c.slot, level, &buf)) |n| {
                if (s.visit(n)) continue;
                const d = self.distQ(q, n);
                const worst = if (s.results.peek()) |r| r.dist else std.math.inf(f32);
                if (s.results.len() < ef or d < worst) {
                    try s.candidates.push(gpa, .{ .slot = n, .dist = d });
                    if (!results_only_admitted or self.admit(n, filter)) {
                        try s.results.push(gpa, .{ .slot = n, .dist = d });
                        if (s.results.len() > ef) _ = s.results.pop();
                    }
                }
            }
        }
    }

    /// Diversity heuristic (algorithm 4 of the paper): keep a candidate only if
    /// it is closer to the base node than to every neighbor already kept.
    fn selectNeighbors(self: *const Index, sorted: []const Item, max: usize, out: *std.ArrayList(Item), gpa: std.mem.Allocator) !void {
        out.items.len = 0;
        for (sorted) |c| {
            if (out.items.len >= max) break;
            var good = true;
            for (out.items) |kept| {
                if (self.distNodes(c.slot, kept.slot) < c.dist) {
                    good = false;
                    break;
                }
            }
            if (good) try out.append(gpa, c);
        }
    }

    // ---- writes --------------------------------------------------------

    fn randomLevel(self: *Index) u8 {
        const u = 1.0 - self.rng.random().float(f64);
        const l = @floor(-@log(u) * self.ml);
        return @intFromFloat(@min(l, @as(f64, max_level_cap)));
    }

    /// Adds a vector under `label` and returns its node id.
    pub fn insert(self: *Index, label: u32, v: []const f32) Error!u32 {
        var q = try self.prepare(self.gpa, v);
        defer q.deinit(self.gpa);
        return self.insertPrepared(label, &q, null);
    }

    fn insertPrepared(self: *Index, label: u32, q: *const Query, forced_level: ?u8) Error!u32 {
        const gpa = self.gpa;
        if (self.count == std.math.maxInt(u32)) return error.OutOfMemory;

        const node = self.count;
        const level = forced_level orelse self.randomLevel();

        // Reserve everything first so a failure leaves the index unchanged.
        try self.labels.ensureUnusedCapacity(gpa, 1);
        try self.levels.ensureUnusedCapacity(gpa, 1);
        try self.deleted.ensureUnusedCapacity(gpa, 1);
        try self.upper.ensureUnusedCapacity(gpa, 1);
        try self.links0.ensureUnusedCapacity(gpa, self.m0 + 1);
        try self.node_locks.ensureUnusedCapacity(gpa, 1);
        if (self.cfg.quantized) {
            try self.codes.ensureUnusedCapacity(gpa, self.cfg.dim);
            try self.factors.ensureUnusedCapacity(gpa, 1);
        } else {
            try self.vectors.ensureUnusedCapacity(gpa, self.cfg.dim);
        }
        var up: ?[]u32 = null;
        if (level > 0) {
            const u = try gpa.alloc(u32, @as(usize, level) * (self.cfg.m + 1));
            @memset(u, 0);
            up = u;
        }

        if (self.cfg.quantized) {
            self.codes.appendSliceAssumeCapacity(q.codes);
            self.factors.appendAssumeCapacity(q.factor);
        } else {
            self.vectors.appendSliceAssumeCapacity(q.f);
        }
        self.labels.appendAssumeCapacity(label);
        self.levels.appendAssumeCapacity(level);
        self.deleted.appendAssumeCapacity(false);
        self.upper.appendAssumeCapacity(up);
        self.links0.appendNTimesAssumeCapacity(0, self.m0 + 1);
        self.node_locks.appendAssumeCapacity(.init(0));
        self.count += 1;
        self.live += 1;

        if (self.max_level < 0) {
            self.entry = node;
            self.max_level = level;
            return node;
        }

        try self.connect(node, q, level, self.entry, self.max_level);

        if (level > self.max_level) {
            self.entry = node;
            self.max_level = level;
        }
        return node;
    }

    /// Links `node` into the graph, searching from `entry` at level `top`.
    fn connect(self: *Index, node: u32, q: *const Query, level: u8, entry: u32, top: i32) Error!void {
        const gpa = self.gpa;
        var scratch = try Scratch.init(gpa, self.count);
        defer scratch.deinit(gpa);
        var sorted: std.ArrayList(Item) = .empty;
        defer sorted.deinit(gpa);
        var chosen: std.ArrayList(Item) = .empty;
        defer chosen.deinit(gpa);
        var pool: std.ArrayList(Item) = .empty;
        defer pool.deinit(gpa);
        var kept: std.ArrayList(Item) = .empty;
        defer kept.deinit(gpa);

        var ep = Item{ .slot = entry, .dist = self.distQ(q, entry) };
        var lc: i32 = top;
        while (lc > level) : (lc -= 1) ep = self.greedy(q, ep.slot, @intCast(lc));

        lc = @min(@as(i32, level), top);
        while (lc >= 0) : (lc -= 1) {
            const l: usize = @intCast(lc);
            try self.searchLayer(gpa, &scratch, q, ep, self.cfg.ef_construction, l, false, null);
            sorted.items.len = 0;
            for (scratch.results.items.items) |r| if (r.slot != node) try sorted.append(gpa, r);
            std.mem.sort(Item, sorted.items, {}, topk.ascending);

            try self.selectNeighbors(sorted.items, self.cfg.m, &chosen, gpa);
            {
                // Other threads may already have linked themselves to this
                // node: keep their links.
                self.lockNode(node);
                defer self.unlockNode(node);
                const existing = self.neighbors(node, l);
                if (existing.len == 0) {
                    self.setNeighbors(node, l, chosen.items);
                } else {
                    pool.items.len = 0;
                    try pool.appendSlice(gpa, chosen.items);
                    for (existing) |e| {
                        if (!containsSlot(chosen.items, e)) try pool.append(gpa, .{ .slot = e, .dist = self.distNodes(node, e) });
                    }
                    std.mem.sort(Item, pool.items, {}, topk.ascending);
                    try self.selectNeighbors(pool.items, self.maxLinks(l), &kept, gpa);
                    self.setNeighbors(node, l, kept.items);
                }
            }

            const cap = self.maxLinks(l);
            for (chosen.items) |n| {
                self.lockNode(n.slot);
                defer self.unlockNode(n.slot);
                const b = self.block(n.slot, l);
                if (std.mem.indexOfScalar(u32, b[1..][0..b[0]], node) != null) continue;
                if (b[0] < cap) {
                    b[1 + b[0]] = node;
                    b[0] += 1;
                    continue;
                }
                // Full: re-select among existing neighbors plus the new node.
                pool.items.len = 0;
                for (b[1..][0..b[0]]) |e| {
                    try pool.append(gpa, .{ .slot = e, .dist = self.distNodes(n.slot, e) });
                }
                try pool.append(gpa, .{ .slot = node, .dist = n.dist });
                std.mem.sort(Item, pool.items, {}, topk.ascending);
                try self.selectNeighbors(pool.items, cap, &kept, gpa);
                self.setNeighbors(n.slot, l, kept.items);
            }
            if (sorted.items.len > 0) ep = sorted.items[0];
        }
    }

    fn containsSlot(items: []const Item, slot: u32) bool {
        for (items) |it| if (it.slot == slot) return true;
        return false;
    }

    /// Inserts `labels.len` vectors (`vectors` holds them back to back) and
    /// returns their node ids in `nodes_out`. With `threads > 1`, nodes are
    /// linked in parallel. On error the index must be discarded.
    pub fn insertBatch(self: *Index, labels: []const u32, vectors: []const f32, threads: usize, nodes_out: []u32) Error!void {
        const gpa = self.gpa;
        const dim = self.cfg.dim;
        const n = labels.len;
        if (vectors.len != n * dim or nodes_out.len != n) return error.DimensionMismatch;
        if (n == 0) return;

        var start: usize = 0;
        if (self.max_level < 0 or threads <= 1 or n < 64) {
            // Sequential: first node of an empty graph, or a small batch.
            const seq_end = if (threads <= 1 or n < 64) n else 1;
            while (start < seq_end) : (start += 1) {
                nodes_out[start] = try self.insert(labels[start], vectors[start * dim ..][0..dim]);
            }
            if (start == n) return;
        }

        // Prepare the remaining vectors and reserve every per-node array, so
        // that nothing reallocates while threads read.
        const m = n - start;
        const queries = try gpa.alloc(Query, m);
        var prepared: usize = 0;
        defer {
            for (queries[0..prepared]) |*q| q.deinit(gpa);
            gpa.free(queries);
        }
        for (queries, 0..) |*q, i| {
            q.* = try self.prepare(gpa, vectors[(start + i) * dim ..][0..dim]);
            prepared += 1;
        }
        const levels = try gpa.alloc(u8, m);
        defer gpa.free(levels);
        for (levels) |*l| l.* = self.randomLevel();

        try self.labels.ensureUnusedCapacity(gpa, m);
        try self.levels.ensureUnusedCapacity(gpa, m);
        try self.deleted.ensureUnusedCapacity(gpa, m);
        try self.upper.ensureUnusedCapacity(gpa, m);
        try self.node_locks.ensureUnusedCapacity(gpa, m);
        try self.links0.ensureUnusedCapacity(gpa, m * (self.m0 + 1));
        if (self.cfg.quantized) {
            try self.codes.ensureUnusedCapacity(gpa, m * dim);
            try self.factors.ensureUnusedCapacity(gpa, m);
        } else {
            try self.vectors.ensureUnusedCapacity(gpa, m * dim);
        }
        const first: u32 = self.count;
        for (queries, levels, 0..) |*q, level, i| {
            var up: ?[]u32 = null;
            if (level > 0) {
                const u = try gpa.alloc(u32, @as(usize, level) * (self.cfg.m + 1));
                @memset(u, 0);
                up = u;
            }
            if (self.cfg.quantized) {
                self.codes.appendSliceAssumeCapacity(q.codes);
                self.factors.appendAssumeCapacity(q.factor);
            } else {
                self.vectors.appendSliceAssumeCapacity(q.f);
            }
            self.labels.appendAssumeCapacity(labels[start + i]);
            self.levels.appendAssumeCapacity(level);
            self.deleted.appendAssumeCapacity(false);
            self.upper.appendAssumeCapacity(up);
            self.links0.appendNTimesAssumeCapacity(0, self.m0 + 1);
            self.node_locks.appendAssumeCapacity(.init(0));
            self.count += 1;
            self.live += 1;
            nodes_out[start + i] = first + @as(u32, @intCast(i));
        }

        const Shared = struct {
            index: *Index,
            first: u32,
            queries: []const Query,
            levels: []const u8,
            next: std.atomic.Value(usize) = .init(0),
            failed: std.atomic.Value(bool) = .init(false),

            fn work(sh: *@This()) void {
                while (!sh.failed.load(.monotonic)) {
                    const i = sh.next.fetchAdd(1, .monotonic);
                    if (i >= sh.queries.len) return;
                    sh.index.connectConcurrent(sh.first + @as(u32, @intCast(i)), &sh.queries[i], sh.levels[i]) catch {
                        sh.failed.store(true, .monotonic);
                    };
                }
            }
        };
        var shared: Shared = .{ .index = self, .first = first, .queries = queries, .levels = levels };
        self.concurrent = true;
        defer self.concurrent = false;
        const workers = try gpa.alloc(?std.Thread, @min(threads, m) - 1);
        defer gpa.free(workers);
        for (workers) |*w| w.* = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch null;
        Shared.work(&shared);
        for (workers) |w| if (w) |t| t.join();
        if (shared.failed.load(.monotonic)) return error.OutOfMemory;
    }

    fn connectConcurrent(self: *Index, node: u32, q: *const Query, level: u8) Error!void {
        spinLock(&self.entry_lock);
        const entry = self.entry;
        const top = self.max_level;
        // A node that raises the top level keeps the entry lock until it is
        // linked, so that no search starts from a half-linked entry point.
        const raises = level > top;
        if (!raises) self.entry_lock.store(0, .release);
        defer if (raises) self.entry_lock.store(0, .release);
        try self.connect(node, q, level, entry, top);
        if (raises) {
            self.entry = node;
            self.max_level = level;
        }
    }

    /// Hides a node from results. Idempotent.
    pub fn remove(self: *Index, node: u32) void {
        if (node >= self.count or self.deleted.items[node]) return;
        self.deleted.items[node] = true;
        self.live -= 1;
    }

    // ---- reads ---------------------------------------------------------

    /// Writes up to `k` nearest live nodes accepted by `filter` into `out`,
    /// closest first. `Item.slot` holds the label.
    pub fn search(self: *const Index, gpa: std.mem.Allocator, v: []const f32, k: usize, ef_search: usize, filter: ?*const Filter, out: []Item) Error!usize {
        if (self.max_level < 0 or self.live == 0 or k == 0) return 0;
        var q = try self.prepare(gpa, v);
        defer q.deinit(gpa);

        var ep = Item{ .slot = self.entry, .dist = self.distQ(&q, self.entry) };
        var lc: i32 = self.max_level;
        while (lc > 0) : (lc -= 1) ep = self.greedy(&q, ep.slot, @intCast(lc));

        var scratch = try Scratch.init(gpa, self.count);
        defer scratch.deinit(gpa);
        try self.searchLayer(gpa, &scratch, &q, ep, @max(ef_search, k), 0, true, filter);

        const res = scratch.results.items.items;
        for (res) |*r| r.slot = self.labels.items[r.slot];
        std.mem.sort(Item, res, {}, topk.ascending);
        const n = @min(@min(k, res.len), out.len);
        for (res[0..n], out[0..n]) |r, *o| o.* = .{ .slot = r.slot, .dist = self.reportDist(r.dist) };
        return n;
    }

    /// Exact search over the given nodes (used when a filter keeps few
    /// documents). `Item.slot` holds the label.
    pub fn searchExact(self: *const Index, gpa: std.mem.Allocator, v: []const f32, nodes: []const u32, k: usize, out: []Item) Error!usize {
        if (k == 0) return 0;
        var q = try self.prepare(gpa, v);
        defer q.deinit(gpa);
        var best: topk.MaxHeap = .{};
        defer best.deinit(gpa);
        for (nodes) |node| {
            if (self.deleted.items[node]) continue;
            const item = Item{ .slot = self.labels.items[node], .dist = self.distQ(&q, node) };
            if (best.len() < k) {
                try best.push(gpa, item);
            } else if (topk.ascending({}, item, best.peek().?)) {
                _ = best.pop();
                try best.push(gpa, item);
            }
        }
        const res = best.items.items;
        std.mem.sort(Item, res, {}, topk.ascending);
        const n = @min(res.len, out.len);
        for (res[0..n], out[0..n]) |r, *o| o.* = .{ .slot = r.slot, .dist = self.reportDist(r.dist) };
        return n;
    }

    pub fn stats(self: *const Index) Stats {
        var edges: u64 = 0;
        for (0..self.count) |i| {
            const s: u32 = @intCast(i);
            for (0..@as(usize, self.levels.items[i]) + 1) |l| edges += self.neighbors(s, l).len;
        }
        var bytes: u64 = self.vectors.capacity * 4 + self.codes.capacity + self.factors.capacity * 4;
        bytes += self.links0.capacity * 4 + self.levels.capacity + self.deleted.capacity + self.labels.capacity * 4;
        for (self.upper.items) |u| if (u) |s| {
            bytes += s.len * 4;
        };
        return .{
            .nodes = self.count,
            .live = self.live,
            .max_level = self.max_level,
            .edges = edges,
            .memory_bytes = bytes,
        };
    }

    // ---- maintenance ---------------------------------------------------

    /// Rebuilds the graph from live nodes, dropping tombstones, and relabels
    /// them with `remap[old_label]`. Levels are preserved so the hierarchy
    /// keeps its shape. Nodes keep their relative order.
    pub fn compact(self: *Index, remap: ?[]const u32) Error!void {
        if (self.live == self.count and remap == null) return;
        const fresh = try Index.init(self.gpa, self.cfg);
        errdefer fresh.deinit();
        fresh.rng = self.rng;
        for (0..self.count) |i| {
            const s: u32 = @intCast(i);
            if (self.deleted.items[s]) continue;
            var q: Query = .{};
            if (self.cfg.quantized) {
                q.codes = @constCast(self.code(s));
                q.factor = self.factors.items[s];
            } else {
                q.f = @constCast(self.vec(s));
            }
            const label = if (remap) |r| r[self.labels.items[s]] else self.labels.items[s];
            _ = try fresh.insertPrepared(label, &q, self.levels.items[s]);
        }
        // Swap contents, then free the old ones through `fresh`.
        std.mem.swap(Index, self, fresh);
        fresh.deinit();
    }

    /// Writes the graph; labels of live nodes go through `remap` (identity
    /// when null), tombstoned nodes keep routing with label `maxInt(u32)`.
    pub fn serialize(self: *const Index, w: *codec.Writer, remap: ?[]const u32) Error!void {
        try w.int(u32, self.cfg.dim);
        try w.int(u32, @intFromEnum(self.cfg.metric));
        try w.int(u8, @intFromBool(self.cfg.quantized));
        try w.int(u32, self.cfg.m);
        try w.int(u32, self.cfg.ef_construction);
        try w.int(u64, self.cfg.seed);
        try w.int(u32, self.count);
        try w.int(u32, self.entry);
        try w.int(i32, self.max_level);
        for (0..self.count) |i| {
            const s: u32 = @intCast(i);
            const label = self.labels.items[s];
            const dead = self.deleted.items[s];
            try w.int(u32, if (dead) std.math.maxInt(u32) else if (remap) |r| r[label] else label);
            try w.int(u8, @intFromBool(dead));
            try w.int(u8, self.levels.items[s]);
            if (self.cfg.quantized) {
                try w.float(self.factors.items[s]);
                try w.bytes(@ptrCast(self.code(s)));
            } else {
                try w.f32s(self.vec(s));
            }
            for (0..@as(usize, self.levels.items[s]) + 1) |l| {
                const ns = self.neighbors(s, l);
                try w.varint(ns.len);
                for (ns) |n| try w.varint(n);
            }
        }
    }

    pub fn deserialize(gpa: std.mem.Allocator, r: *codec.Reader) Error!*Index {
        var cfg: Config = .{ .dim = try r.int(u32) };
        const metric = try r.int(u32);
        if (metric > 2) return error.Corrupt;
        cfg.metric = @enumFromInt(metric);
        cfg.quantized = (try r.int(u8)) != 0;
        cfg.m = try r.int(u32);
        cfg.ef_construction = try r.int(u32);
        cfg.seed = try r.int(u64);
        const self = Index.init(gpa, cfg) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
        errdefer self.deinit();

        const count = try r.int(u32);
        const entry = try r.int(u32);
        const max_level = try r.int(i32);
        if (count > 0 and entry >= count) return error.Corrupt;
        if (max_level > max_level_cap or (count == 0) != (max_level < 0)) return error.Corrupt;

        const dim = cfg.dim;
        if (count > r.data.len) return error.Corrupt; // each node takes several bytes
        try self.labels.ensureTotalCapacity(gpa, count);
        try self.deleted.ensureTotalCapacity(gpa, count);
        try self.levels.ensureTotalCapacity(gpa, count);
        try self.node_locks.ensureTotalCapacity(gpa, count);
        try self.upper.ensureTotalCapacity(gpa, count);
        try self.links0.ensureTotalCapacity(gpa, @as(usize, count) * (self.m0 + 1));
        if (cfg.quantized) {
            try self.factors.ensureTotalCapacity(gpa, count);
            try self.codes.ensureTotalCapacity(gpa, @as(usize, count) * dim);
        } else {
            try self.vectors.ensureTotalCapacity(gpa, @as(usize, count) * dim);
        }
        for (0..count) |i| {
            const s: u32 = @intCast(i);
            self.labels.appendAssumeCapacity(try r.int(u32));
            const del = (try r.int(u8)) != 0;
            const level = try r.int(u8);
            if (level > max_level_cap) return error.Corrupt;
            self.deleted.appendAssumeCapacity(del);
            self.levels.appendAssumeCapacity(level);
            if (cfg.quantized) {
                self.factors.appendAssumeCapacity(try r.float());
                self.codes.appendSliceAssumeCapacity(@ptrCast(try r.take(dim)));
            } else {
                try r.f32s(self.vectors.addManyAsSliceAssumeCapacity(dim));
            }
            self.links0.appendNTimesAssumeCapacity(0, self.m0 + 1);
            self.node_locks.appendAssumeCapacity(.init(0));
            var up: ?[]u32 = null;
            if (level > 0) {
                const u = try gpa.alloc(u32, @as(usize, level) * (cfg.m + 1));
                @memset(u, 0);
                up = u;
            }
            self.upper.appendAssumeCapacity(up);
            self.count += 1;
            for (0..@as(usize, level) + 1) |l| {
                const n = try r.varint();
                if (n > self.maxLinks(l)) return error.Corrupt;
                const b = self.block(s, l);
                b[0] = @intCast(n);
                for (0..@intCast(n)) |j| {
                    const t = try r.varint();
                    if (t >= count) return error.Corrupt;
                    b[1 + j] = @intCast(t);
                }
            }
            if (!del) self.live += 1;
        }
        if (count > 0 and self.levels.items[entry] != @as(u8, @intCast(max_level))) return error.Corrupt;
        self.entry = entry;
        self.max_level = max_level;
        // Advance the generator so new levels differ from the ones already drawn.
        for (0..count) |_| _ = self.rng.next();
        return self;
    }
};

// ---- tests -------------------------------------------------------------

const testing = std.testing;

fn randomVectors(gpa: std.mem.Allocator, n: usize, dim: usize, seed: u64) ![]f32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const out = try gpa.alloc(f32, n * dim);
    for (out) |*x| x.* = r.floatNorm(f32);
    return out;
}

fn build(gpa: std.mem.Allocator, cfg: Config, data: []const f32) !*Index {
    const idx = try Index.init(gpa, cfg);
    errdefer idx.deinit();
    const n = data.len / cfg.dim;
    for (0..n) |i| _ = try idx.insert(@intCast(i), data[i * cfg.dim ..][0..cfg.dim]);
    return idx;
}

fn allNodes(gpa: std.mem.Allocator, idx: *const Index) ![]u32 {
    const nodes = try gpa.alloc(u32, idx.count);
    for (nodes, 0..) |*n, i| n.* = @intCast(i);
    return nodes;
}

fn recallAt10(idx: *const Index, data: []const f32, queries: usize, ef: usize, filter: ?*const Filter) !f64 {
    const gpa = testing.allocator;
    const dim = idx.cfg.dim;
    var candidates: std.ArrayList(u32) = .empty;
    defer candidates.deinit(gpa);
    for (0..idx.count) |i| {
        if (filter) |f| if (!f.isSet(idx.labels.items[i])) continue;
        try candidates.append(gpa, @intCast(i));
    }
    var truth: [10]Item = undefined;
    var res: [10]Item = undefined;
    var hits: usize = 0;
    var total: usize = 0;
    for (0..queries) |qi| {
        const q = data[qi * dim ..][0..dim];
        const nt = try idx.searchExact(gpa, q, candidates.items, 10, &truth);
        const n = try idx.search(gpa, q, 10, ef, filter, &res);
        for (res[0..n]) |r| {
            for (truth[0..nt]) |t| {
                if (t.slot == r.slot) {
                    hits += 1;
                    break;
                }
            }
        }
        total += nt;
    }
    return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
}

test "recall@10 above 0.95 on random data" {
    const gpa = testing.allocator;
    const data = try randomVectors(gpa, 2000, 32, 7);
    defer gpa.free(data);
    const idx = try build(gpa, .{ .dim = 32, .m = 16, .ef_construction = 200 }, data);
    defer idx.deinit();
    try testing.expect(try recallAt10(idx, data, 100, 64, null) > 0.95);
}

test "filtered search keeps recall and only returns accepted labels" {
    const gpa = testing.allocator;
    const n = 2000;
    const data = try randomVectors(gpa, n, 32, 9);
    defer gpa.free(data);
    const idx = try build(gpa, .{ .dim = 32 }, data);
    defer idx.deinit();
    var filter = try Filter.initEmpty(gpa, n);
    defer filter.deinit(gpa);
    for (0..n) |i| if (i % 5 == 0) filter.set(i); // 20 % of the documents
    try testing.expect(try recallAt10(idx, data, 100, 64, &filter) > 0.9);
    var res: [10]Item = undefined;
    const got = try idx.search(gpa, data[0..32], 10, 64, &filter, &res);
    try testing.expectEqual(@as(usize, 10), got);
    for (res[0..got]) |r| try testing.expect(r.slot % 5 == 0);
}

test "quantized index keeps good recall" {
    const gpa = testing.allocator;
    const data = try randomVectors(gpa, 1500, 64, 11);
    defer gpa.free(data);
    const idx = try build(gpa, .{ .dim = 64, .quantized = true }, data);
    defer idx.deinit();
    try testing.expect(try recallAt10(idx, data, 100, 64, null) > 0.9);
    try testing.expectEqual(@as(usize, 0), idx.vectors.items.len);
    try testing.expectEqual(@as(usize, 1500 * 64), idx.codes.items.len);
}

test "remove and compact with relabeling" {
    const gpa = testing.allocator;
    const dim = 8;
    const data = try randomVectors(gpa, 300, dim, 3);
    defer gpa.free(data);
    const idx = try build(gpa, .{ .dim = dim, .metric = .l2 }, data);
    defer idx.deinit();

    idx.remove(5);
    idx.remove(5);
    try testing.expectEqual(@as(u32, 299), idx.live);
    var res: [5]Item = undefined;
    const n = try idx.search(gpa, data[5 * dim ..][0..dim], 5, 50, null, &res);
    for (res[0..n]) |r| try testing.expect(r.slot != 5);

    // Shift every label above 5 down by one.
    var remap: [300]u32 = undefined;
    for (&remap, 0..) |*r, i| r.* = if (i > 5) @intCast(i - 1) else @intCast(i);
    try idx.compact(&remap);
    try testing.expectEqual(idx.live, idx.count);
    const n2 = try idx.search(gpa, data[9 * dim ..][0..dim], 1, 50, null, &res);
    try testing.expectEqual(@as(usize, 1), n2);
    try testing.expectEqual(@as(u32, 8), res[0].slot);
    try testing.expectApproxEqAbs(@as(f32, 0), res[0].dist, 1e-5);
}

test "serialize round trip preserves results" {
    const gpa = testing.allocator;
    const dim = 16;
    const data = try randomVectors(gpa, 500, dim, 5);
    defer gpa.free(data);
    const idx = try build(gpa, .{ .dim = dim }, data);
    defer idx.deinit();
    idx.remove(1);

    var w = codec.Writer.init(gpa);
    defer w.deinit();
    try codec.header(&w, magic, format_version);
    try idx.serialize(&w, null);
    try w.finish();
    var r = try codec.Reader.open(w.buf.items, magic, format_version);
    const back = try Index.deserialize(gpa, &r);
    defer back.deinit();
    try testing.expect(r.done());
    try testing.expectEqual(idx.live, back.live);

    var a: [10]Item = undefined;
    var b: [10]Item = undefined;
    const q = data[42 * dim ..][0..dim];
    const na = try idx.search(gpa, q, 10, 40, null, &a);
    const nb = try back.search(gpa, q, 10, 40, null, &b);
    try testing.expectEqual(na, nb);
    for (a[0..na], b[0..nb]) |x, y| try testing.expectEqual(x.slot, y.slot);
}

test "parallel batch insert keeps recall" {
    const gpa = testing.allocator;
    const n = 4000;
    const dim = 32;
    const data = try randomVectors(gpa, n, dim, 21);
    defer gpa.free(data);
    for ([_]usize{ 2, 3, 16 }) |threads| for ([_]bool{ false, true }) |quantized| {
        const idx = try Index.init(gpa, .{ .dim = dim, .quantized = quantized });
        defer idx.deinit();
        const labels = try gpa.alloc(u32, n);
        defer gpa.free(labels);
        for (labels, 0..) |*l, i| l.* = @intCast(i);
        const nodes = try gpa.alloc(u32, n);
        defer gpa.free(nodes);
        // Two batches: one into an empty graph, one into a populated graph.
        try idx.insertBatch(labels[0..1000], data[0 .. 1000 * dim], threads, nodes[0..1000]);
        try idx.insertBatch(labels[1000..], data[1000 * dim ..], threads, nodes[1000..]);
        try testing.expectEqual(@as(u32, n), idx.live);
        for (nodes, 0..) |node, i| try testing.expectEqual(@as(u32, @intCast(i)), idx.labels.items[node]);
        // Every list is valid: no self loop, no duplicate, within bounds.
        for (0..idx.count) |i| {
            const node: u32 = @intCast(i);
            for (0..@as(usize, idx.levels.items[i]) + 1) |l| {
                const ns = idx.neighbors(node, l);
                try testing.expect(ns.len <= idx.maxLinks(l));
                for (ns, 0..) |x, j| {
                    try testing.expect(x != node and x < idx.count);
                    try testing.expect(std.mem.indexOfScalar(u32, ns[j + 1 ..], x) == null);
                }
            }
        }
        const recall = try recallAt10(idx, data, 100, 64, null);
        try testing.expect(recall > @as(f64, if (quantized) 0.9 else 0.95));
    };
}

test "rejects bad input" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidConfig, Index.init(gpa, .{ .dim = 4, .metric = .l2, .quantized = true }));
    const idx = try Index.init(gpa, .{ .dim = 4 });
    defer idx.deinit();
    try testing.expectError(error.DimensionMismatch, idx.insert(0, &[_]f32{ 1, 2 }));
    var out: [1]Item = undefined;
    try testing.expectEqual(@as(usize, 0), try idx.search(gpa, &[_]f32{ 1, 0, 0, 0 }, 1, 10, null, &out));
    const nodes = try allNodes(gpa, idx);
    defer gpa.free(nodes);
    try testing.expectEqual(@as(usize, 0), try idx.searchExact(gpa, &[_]f32{ 1, 0, 0, 0 }, nodes, 1, &out));
}
