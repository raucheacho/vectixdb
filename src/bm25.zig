//! Inverted index with Okapi BM25 ranking, one per text field.
//!
//! Documents are identified by their collection slot. Postings are kept per
//! term in insertion order. Removal fixes corpus statistics (document
//! frequency, average length) at once; dead postings are skipped at query time
//! and dropped by `compact`.

const std = @import("std");
const codec = @import("codec.zig");
const topk = @import("topk.zig");
const Analyzer = @import("analyzer.zig").Analyzer;

/// `SlotReused`: a slot can hold one document between two compactions;
/// replacing a document means indexing it under a new slot.
pub const Error = error{ OutOfMemory, Corrupt, SlotReused };
pub const Filter = std.DynamicBitSetUnmanaged;
/// `dist` carries the BM25 score (higher is better), `slot` the document.
pub const Hit = topk.Item;

const Posting = struct {
    slot: u32,
    tf: u32,
};

pub const Params = struct {
    k1: f32 = 1.2,
    b: f32 = 0.75,
};

pub const Stats = struct {
    docs: u32,
    terms: u32,
    postings: u64,
    avg_doc_len: f32,
};

pub const Index = struct {
    gpa: std.mem.Allocator,
    params: Params,

    terms: std.StringHashMapUnmanaged(u32) = .empty,
    term_strs: std.ArrayList([]u8) = .empty,
    postings: std.ArrayList(std.ArrayList(Posting)) = .empty,
    df: std.ArrayList(u32) = .empty,

    /// Per slot: whether the slot holds an indexed document, its length in
    /// tokens and its distinct terms. Slots beyond the end are absent.
    present: std.ArrayList(bool) = .empty,
    /// Slots that held a document since the last compaction. Their postings
    /// may still be in the lists, so they cannot be reused.
    used: std.ArrayList(bool) = .empty,
    doc_len: std.ArrayList(u32) = .empty,
    doc_terms: std.ArrayList([]u32) = .empty,

    live: u32 = 0,
    total_len: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, params: Params) Index {
        return .{ .gpa = gpa, .params = params };
    }

    pub fn deinit(self: *Index) void {
        const gpa = self.gpa;
        for (self.term_strs.items) |t| gpa.free(t);
        for (self.postings.items) |*p| p.deinit(gpa);
        for (self.doc_terms.items) |d| gpa.free(d);
        self.terms.deinit(gpa);
        self.term_strs.deinit(gpa);
        self.postings.deinit(gpa);
        self.df.deinit(gpa);
        self.present.deinit(gpa);
        self.used.deinit(gpa);
        self.doc_len.deinit(gpa);
        self.doc_terms.deinit(gpa);
        self.* = undefined;
    }

    pub fn contains(self: *const Index, slot: u32) bool {
        return slot < self.present.items.len and self.present.items[slot];
    }

    fn termId(self: *Index, term: []const u8) Error!u32 {
        if (self.terms.get(term)) |id| return id;
        const gpa = self.gpa;
        const owned = try gpa.dupe(u8, term);
        errdefer gpa.free(owned);
        const id: u32 = @intCast(self.term_strs.items.len);
        try self.term_strs.ensureUnusedCapacity(gpa, 1);
        try self.postings.ensureUnusedCapacity(gpa, 1);
        try self.df.ensureUnusedCapacity(gpa, 1);
        try self.terms.put(gpa, owned, id);
        self.term_strs.appendAssumeCapacity(owned);
        self.postings.appendAssumeCapacity(.empty);
        self.df.appendAssumeCapacity(0);
        return id;
    }

    fn growTo(self: *Index, n: usize) Error!void {
        const gpa = self.gpa;
        if (n <= self.present.items.len) return;
        const extra = n - self.present.items.len;
        try self.present.ensureUnusedCapacity(gpa, extra);
        try self.used.ensureUnusedCapacity(gpa, extra);
        try self.doc_len.ensureUnusedCapacity(gpa, extra);
        try self.doc_terms.ensureUnusedCapacity(gpa, extra);
        self.present.appendNTimesAssumeCapacity(false, extra);
        self.used.appendNTimesAssumeCapacity(false, extra);
        self.doc_len.appendNTimesAssumeCapacity(0, extra);
        self.doc_terms.appendNTimesAssumeCapacity(&.{}, extra);
    }

    /// Indexes `text` under `slot`, which must not have been used since the
    /// last compaction.
    pub fn add(self: *Index, slot: u32, text: []const u8) Error!void {
        const gpa = self.gpa;
        if (slot < self.used.items.len and self.used.items[slot]) return error.SlotReused;

        var tf: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
        defer tf.deinit(gpa);
        var length: u32 = 0;
        var an = Analyzer.init(text);
        while (an.next()) |t| {
            const tid = try self.termId(t);
            const gop = try tf.getOrPut(gpa, tid);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            length +|= 1;
        }

        try self.growTo(@as(usize, slot) + 1);
        const uniq = try gpa.dupe(u32, tf.keys());
        errdefer gpa.free(uniq);
        for (tf.keys()) |tid| try self.postings.items[tid].ensureUnusedCapacity(gpa, 1);

        var it = tf.iterator();
        while (it.next()) |e| {
            self.postings.items[e.key_ptr.*].appendAssumeCapacity(.{ .slot = slot, .tf = e.value_ptr.* });
            self.df.items[e.key_ptr.*] += 1;
        }
        self.present.items[slot] = true;
        self.used.items[slot] = true;
        self.doc_len.items[slot] = length;
        self.doc_terms.items[slot] = uniq;
        self.live += 1;
        self.total_len += length;
    }

    /// Removes the document in `slot`, if any.
    pub fn remove(self: *Index, slot: u32) void {
        if (!self.contains(slot)) return;
        self.present.items[slot] = false;
        for (self.doc_terms.items[slot]) |tid| self.df.items[tid] -= 1;
        self.gpa.free(self.doc_terms.items[slot]);
        self.doc_terms.items[slot] = &.{};
        self.live -= 1;
        self.total_len -= self.doc_len.items[slot];
        self.doc_len.items[slot] = 0;
    }

    /// Top-k documents accepted by `filter`, best first.
    pub fn search(self: *const Index, gpa: std.mem.Allocator, query: []const u8, k: usize, filter: ?*const Filter, out: []Hit) Error!usize {
        if (self.live == 0 or k == 0) return 0;
        const n: f32 = @floatFromInt(self.live);
        const avgdl: f32 = @as(f32, @floatFromInt(self.total_len)) / n;

        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(gpa);
        // Dense accumulator over slots, plus the list of touched slots so that
        // selection only walks actual matches.
        const scores = try gpa.alloc(f32, self.present.items.len);
        defer gpa.free(scores);
        @memset(scores, 0);
        var touched: std.ArrayList(u32) = .empty;
        defer touched.deinit(gpa);

        const k1 = self.params.k1;
        const b = self.params.b;
        const len_norm = b / @max(avgdl, 1e-6);
        var an = Analyzer.init(query);
        while (an.next()) |t| {
            const tid = self.terms.get(t) orelse continue;
            if ((try seen.getOrPut(gpa, tid)).found_existing) continue;
            const df: f32 = @floatFromInt(self.df.items[tid]);
            if (df == 0) continue;
            const idf = @log(1.0 + (n - df + 0.5) / (df + 0.5));
            for (self.postings.items[tid].items) |p| {
                if (!self.present.items[p.slot]) continue;
                if (filter) |f| if (p.slot >= f.bit_length or !f.isSet(p.slot)) continue;
                const f: f32 = @floatFromInt(p.tf);
                const dl: f32 = @floatFromInt(self.doc_len.items[p.slot]);
                const norm = k1 * (1.0 - b + dl * len_norm);
                if (scores[p.slot] == 0) try touched.append(gpa, p.slot);
                scores[p.slot] += idf * f * (k1 + 1.0) / (f + norm);
            }
        }

        var best: topk.MinHeap = .{};
        defer best.deinit(gpa);
        for (touched.items) |slot| {
            const item = Hit{ .slot = slot, .dist = scores[slot] };
            if (best.len() < k) {
                try best.push(gpa, item);
            } else if (topk.descending({}, item, best.peek().?)) {
                _ = best.pop();
                try best.push(gpa, item);
            }
        }
        const res = best.items.items;
        std.mem.sort(Hit, res, {}, topk.descending);
        const m = @min(res.len, out.len);
        @memcpy(out[0..m], res[0..m]);
        return m;
    }

    pub fn stats(self: *const Index) Stats {
        var postings: u64 = 0;
        var terms: u32 = 0;
        for (self.postings.items, self.df.items) |p, df| {
            postings += p.items.len;
            if (df > 0) terms += 1;
        }
        return .{
            .docs = self.live,
            .terms = terms,
            .postings = postings,
            .avg_doc_len = if (self.live == 0) 0 else @as(f32, @floatFromInt(self.total_len)) / @as(f32, @floatFromInt(self.live)),
        };
    }

    /// Writes live documents and terms only, with slots renumbered through
    /// `remap` (identity when null). Postings are delta + varint encoded.
    pub fn serialize(self: *const Index, w: *codec.Writer, remap: ?[]const u32) Error!void {
        const gpa = w.gpa;
        try w.float(self.params.k1);
        try w.float(self.params.b);
        try w.int(u32, self.live);
        for (self.present.items, self.doc_len.items, 0..) |p, len, slot| {
            if (!p) continue;
            try w.varint(mapSlot(remap, @intCast(slot)));
            try w.varint(len);
        }
        var live_terms: u32 = 0;
        for (self.df.items) |df| {
            if (df > 0) live_terms += 1;
        }
        try w.int(u32, live_terms);
        var slots: std.ArrayList(Posting) = .empty;
        defer slots.deinit(gpa);
        for (self.term_strs.items, self.postings.items, self.df.items) |term, plist, df| {
            if (df == 0) continue;
            try w.blob(term);
            try w.varint(df);
            slots.items.len = 0;
            for (plist.items) |p| {
                if (!self.present.items[p.slot]) continue;
                try slots.append(gpa, .{ .slot = mapSlot(remap, p.slot), .tf = p.tf });
            }
            std.mem.sort(Posting, slots.items, {}, postingLess);
            var prev: u32 = 0;
            for (slots.items) |p| {
                try w.varint(p.slot - prev);
                try w.varint(p.tf);
                prev = p.slot;
            }
        }
    }

    pub fn deserialize(gpa: std.mem.Allocator, r: *codec.Reader) Error!Index {
        const k1 = try r.float();
        const b = try r.float();
        if (!std.math.isFinite(k1) or !std.math.isFinite(b)) return error.Corrupt;
        var self = Index.init(gpa, .{ .k1 = k1, .b = b });
        errdefer self.deinit();

        const ndocs = try r.int(u32);
        for (0..ndocs) |_| {
            const slot = try r.varint();
            if (slot >= std.math.maxInt(u32)) return error.Corrupt;
            const len = try r.varint();
            if (len > std.math.maxInt(u32)) return error.Corrupt;
            const s: u32 = @intCast(slot);
            try self.growTo(@as(usize, s) + 1);
            if (self.present.items[s]) return error.Corrupt;
            self.present.items[s] = true;
            self.used.items[s] = true;
            self.doc_len.items[s] = @intCast(len);
            self.total_len += len;
        }
        self.live = ndocs;

        // Postings first; the distinct terms of each document are rebuilt
        // after, from per-slot counts (no per-document growth).
        const counts = try gpa.alloc(u32, self.present.items.len);
        defer gpa.free(counts);
        @memset(counts, 0);
        const nterms = try r.int(u32);
        for (0..nterms) |_| {
            const term = try r.blob();
            if (self.terms.contains(term)) return error.Corrupt;
            const tid = try self.termId(term);
            const df = try r.varint();
            if (df == 0 or df > ndocs) return error.Corrupt;
            const plist = &self.postings.items[tid];
            try plist.ensureTotalCapacity(gpa, @intCast(df));
            var slot: u64 = 0;
            for (0..@intCast(df)) |j| {
                const delta = try r.varint();
                if (j > 0 and delta == 0) return error.Corrupt;
                slot += delta;
                if (slot >= self.present.items.len or !self.present.items[@intCast(slot)]) return error.Corrupt;
                const tf = try r.varint();
                if (tf == 0 or tf > std.math.maxInt(u32)) return error.Corrupt;
                plist.appendAssumeCapacity(.{ .slot = @intCast(slot), .tf = @intCast(tf) });
                counts[@intCast(slot)] += 1;
            }
            self.df.items[tid] = @intCast(df);
        }
        for (counts, 0..) |c, slot| {
            if (c > 0) self.doc_terms.items[slot] = try gpa.alloc(u32, c);
        }
        @memset(counts, 0);
        for (self.postings.items, 0..) |plist, tid| {
            for (plist.items) |p| {
                self.doc_terms.items[p.slot][counts[p.slot]] = @intCast(tid);
                counts[p.slot] += 1;
            }
        }
        return self;
    }

    /// Drops dead postings and terms, and renumbers slots through `remap`.
    pub fn compact(self: *Index, remap: ?[]const u32) Error!void {
        var w = codec.Writer.init(self.gpa);
        defer w.deinit();
        try self.serialize(&w, remap);
        var r: codec.Reader = .{ .data = w.buf.items };
        var fresh = try Index.deserialize(self.gpa, &r);
        std.mem.swap(Index, self, &fresh);
        fresh.deinit();
    }
};

fn mapSlot(remap: ?[]const u32, slot: u32) u32 {
    return if (remap) |r| r[slot] else slot;
}

fn postingLess(_: void, a: Posting, b: Posting) bool {
    return a.slot < b.slot;
}

const testing = std.testing;

test "ranks the more relevant document first" {
    var idx = Index.init(testing.allocator, .{});
    defer idx.deinit();
    try idx.add(0, "the quick brown fox jumps over the lazy dog");
    try idx.add(1, "vector search with hnsw graphs and bm25 ranking");
    try idx.add(2, "bm25 bm25 ranking function for keyword search");
    try idx.add(5, "un moteur de recherche local écrit en Zig");

    var out: [4]Hit = undefined;
    const n = try idx.search(testing.allocator, "BM25 ranking", 4, null, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 2), out[0].slot);
    try testing.expectEqual(@as(u32, 1), out[1].slot);
    try testing.expect(out[0].dist > out[1].dist);

    const m = try idx.search(testing.allocator, "ecrit en zig", 4, null, &out);
    try testing.expectEqual(@as(usize, 1), m);
    try testing.expectEqual(@as(u32, 5), out[0].slot);
    try testing.expect(!idx.contains(3));
}

test "filter, remove and replace" {
    var idx = Index.init(testing.allocator, .{});
    defer idx.deinit();
    try idx.add(0, "alpha beta");
    try idx.add(1, "alpha gamma");
    try idx.add(2, "alpha delta");

    var filter = try Filter.initEmpty(testing.allocator, 3);
    defer filter.deinit(testing.allocator);
    filter.set(2);
    var out: [3]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(testing.allocator, "alpha", 3, &filter, &out));
    try testing.expectEqual(@as(u32, 2), out[0].slot);

    idx.remove(0);
    try testing.expectEqual(@as(u32, 2), idx.df.items[idx.terms.get("alpha").?]);
    try testing.expectEqual(@as(usize, 2), try idx.search(testing.allocator, "alpha", 3, null, &out));

    try testing.expectError(error.SlotReused, idx.add(0, "epsilon"));
    idx.remove(1);
    try idx.add(3, "epsilon");
    try testing.expectEqual(@as(usize, 1), try idx.search(testing.allocator, "alpha", 3, null, &out));
    try testing.expectEqual(@as(usize, 1), try idx.search(testing.allocator, "epsilon", 3, null, &out));
}

test "compact with remap and serialize round trip" {
    const gpa = testing.allocator;
    var idx = Index.init(gpa, .{ .k1 = 1.5 });
    defer idx.deinit();
    var buf: [64]u8 = undefined;
    for (0..200) |i| {
        const text = try std.fmt.bufPrint(&buf, "doc {d} term{d} shared common{d}", .{ i, i % 13, i % 3 });
        try idx.add(@intCast(i), text);
    }
    idx.remove(4);

    var before: [10]Hit = undefined;
    const nb = try idx.search(gpa, "term4 common1", 10, null, &before);

    // Close the gap left by slot 4.
    var remap: [200]u32 = undefined;
    for (&remap, 0..) |*r, i| r.* = if (i > 4) @intCast(i - 1) else @intCast(i);
    try idx.compact(&remap);
    try testing.expectEqual(@as(u32, 199), idx.live);
    try testing.expectEqual(@as(usize, 199), idx.present.items.len);

    var after: [10]Hit = undefined;
    const na = try idx.search(gpa, "term4 common1", 10, null, &after);
    try testing.expectEqual(nb, na);
    for (before[0..nb], after[0..na]) |x, y| {
        try testing.expectEqual(remap[x.slot], y.slot);
        try testing.expectApproxEqAbs(x.dist, y.dist, 1e-5);
    }

    var w = codec.Writer.init(gpa);
    defer w.deinit();
    try idx.serialize(&w, null);
    var r: codec.Reader = .{ .data = w.buf.items };
    var back = try Index.deserialize(gpa, &r);
    defer back.deinit();
    try testing.expect(r.done());
    try testing.expectEqual(idx.total_len, back.total_len);
}
