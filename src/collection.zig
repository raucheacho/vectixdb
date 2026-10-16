//! A collection: documents with an optional vector, typed fields and a
//! payload, all sharing one space of `u32` slots.
//!
//! Slots are assigned in insertion order and never reused before `compact`:
//! replacing a document deletes its slot and takes a new one. Every index
//! (HNSW, BM25, keyword postings, numeric columns) is addressed by slot, and
//! dead slots are masked by the `live` bitset.
//!
//! Not thread safe: the database serializes writers and excludes them from
//! readers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const hnsw = @import("hnsw.zig");
const bm25 = @import("bm25.zig");
const topk = @import("topk.zig");
const schema = @import("schema.zig");
const filter_mod = @import("filter.zig");

const Schema = schema.Schema;
const Doc = schema.Doc;
const Value = schema.Value;
const FieldType = schema.FieldType;
pub const Filter = filter_mod.Filter;
pub const Bitset = std.DynamicBitSetUnmanaged;

const none: u32 = std.math.maxInt(u32);

pub const Error = error{ OutOfMemory, InvalidDocument, InvalidQuery, InvalidFilter, Corrupt };

// ---------------------------------------------------------------------------
// Columns

/// Interned strings with postings, for keyword and keywords fields.
const TagColumn = struct {
    dict: std.StringHashMapUnmanaged(u32) = .empty,
    strs: std.ArrayList([]u8) = .empty,
    postings: std.ArrayList(std.ArrayList(u32)) = .empty,
    /// Term ids per slot; empty when the slot has no value.
    per_slot: std.ArrayList([]u32) = .empty,

    fn deinit(c: *TagColumn, gpa: Allocator) void {
        for (c.strs.items) |s| gpa.free(s);
        for (c.postings.items) |*p| p.deinit(gpa);
        for (c.per_slot.items) |ids| if (ids.len > 0) gpa.free(ids);
        c.dict.deinit(gpa);
        c.strs.deinit(gpa);
        c.postings.deinit(gpa);
        c.per_slot.deinit(gpa);
    }

    fn intern(c: *TagColumn, gpa: Allocator, s: []const u8) !u32 {
        if (c.dict.get(s)) |id| return id;
        const owned = try gpa.dupe(u8, s);
        errdefer gpa.free(owned);
        try c.strs.ensureUnusedCapacity(gpa, 1);
        try c.postings.ensureUnusedCapacity(gpa, 1);
        const id: u32 = @intCast(c.strs.items.len);
        try c.dict.put(gpa, owned, id);
        c.strs.appendAssumeCapacity(owned);
        c.postings.appendAssumeCapacity(.empty);
        return id;
    }

    /// Sets the values of the last slot (appended with `appendSlot`).
    fn set(c: *TagColumn, gpa: Allocator, slot: u32, values: []const []const u8) !void {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(gpa);
        for (values) |v| {
            const id = try c.intern(gpa, v);
            if (std.mem.indexOfScalar(u32, ids.items, id) == null) try ids.append(gpa, id);
        }
        for (ids.items) |id| try c.postings.items[id].ensureUnusedCapacity(gpa, 1);
        const owned = try ids.toOwnedSlice(gpa);
        for (owned) |id| c.postings.items[id].appendAssumeCapacity(slot);
        c.per_slot.items[slot] = owned;
    }

    fn clear(c: *TagColumn, gpa: Allocator, slot: u32) void {
        const ids = c.per_slot.items[slot];
        if (ids.len > 0) gpa.free(ids);
        c.per_slot.items[slot] = &.{};
    }

    fn markEq(c: *const TagColumn, s: []const u8, out: *Bitset) void {
        const id = c.dict.get(s) orelse return;
        for (c.postings.items[id].items) |slot| out.set(slot);
    }
};

fn NumColumn(comptime T: type) type {
    return struct {
        values: std.ArrayList(T) = .empty,
        present: std.ArrayList(bool) = .empty,

        fn deinit(c: *@This(), gpa: Allocator) void {
            c.values.deinit(gpa);
            c.present.deinit(gpa);
        }
    };
}

const TextColumn = struct {
    values: std.ArrayList([]u8) = .empty,
    present: std.ArrayList(bool) = .empty,
    index: bm25.Index,

    fn deinit(c: *TextColumn, gpa: Allocator) void {
        for (c.values.items) |v| if (v.len > 0) gpa.free(v);
        c.values.deinit(gpa);
        c.present.deinit(gpa);
        c.index.deinit();
    }
};

const Column = union(FieldType) {
    text: TextColumn,
    keyword: TagColumn,
    keywords: TagColumn,
    int: NumColumn(i64),
    float: NumColumn(f64),
    bool: NumColumn(bool),
    time: NumColumn(i64),

    fn init(gpa: Allocator, t: FieldType, params: bm25.Params) Column {
        return switch (t) {
            .text => .{ .text = .{ .index = bm25.Index.init(gpa, params) } },
            .keyword => .{ .keyword = .{} },
            .keywords => .{ .keywords = .{} },
            .int => .{ .int = .{} },
            .float => .{ .float = .{} },
            .bool => .{ .bool = .{} },
            .time => .{ .time = .{} },
        };
    }

    fn deinit(c: *Column, gpa: Allocator) void {
        switch (c.*) {
            inline else => |*col| col.deinit(gpa),
        }
    }

    /// Appends an empty entry for a new slot.
    fn appendSlot(c: *Column, gpa: Allocator) !void {
        switch (c.*) {
            .text => |*t| {
                try t.values.ensureUnusedCapacity(gpa, 1);
                try t.present.append(gpa, false);
                t.values.appendAssumeCapacity(&.{});
            },
            .keyword, .keywords => |*t| try t.per_slot.append(gpa, &.{}),
            inline .int, .float, .bool, .time => |*n| {
                try n.values.ensureUnusedCapacity(gpa, 1);
                try n.present.append(gpa, false);
                n.values.appendAssumeCapacity(undefinedValue(@TypeOf(n.values.items[0])));
            },
        }
    }

    fn present(c: *const Column, slot: u32) bool {
        return switch (c.*) {
            .text => |t| t.present.items[slot],
            .keyword, .keywords => |t| t.per_slot.items[slot].len > 0,
            inline .int, .float, .bool, .time => |n| n.present.items[slot],
        };
    }
};

fn undefinedValue(comptime T: type) T {
    return switch (T) {
        bool => false,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Queries

pub const Fusion = union(enum) {
    /// Reciprocal rank fusion: score = sum of 1 / (k + rank).
    rrf: f32,
    /// Weighted sum of the vector similarity and the BM25 score normalized
    /// by the best one.
    weighted: struct { vector: f32 = 0.5, text: f32 = 0.5 },
};

pub const Query = struct {
    vector: ?[]const f32 = null,
    text: ?[]const u8 = null,
    /// Text fields searched by `text` and `exact` (all text fields if null).
    text_fields: ?[]const []const u8 = null,
    /// Literal substring that must appear in one of the text fields.
    exact: ?[]const u8 = null,
    filter: ?*const Filter = null,
    k: u32 = 10,
    ef: u32 = 64,
    /// Candidates taken from each route before fusion (default: max(4k, 50)).
    candidates: u32 = 0,
    fusion: Fusion = .{ .rrf = 60 },
};

pub const Hit = struct {
    slot: u32,
    /// Higher is better. Vector only: similarity (cosine, dot) or
    /// 1 / (1 + distance) for L2. Text only: BM25. Both: fused score.
    score: f32,
    /// 1-based rank in each route, 0 when the route did not return it.
    vector_rank: u32 = 0,
    vector_distance: f32 = 0,
    text_rank: u32 = 0,
    text_score: f32 = 0,
};

/// Below this many candidates, a filtered vector search is exact.
pub fn bruteForceThreshold(total: usize) usize {
    return @max(1000, total / 50);
}

// ---------------------------------------------------------------------------
// Collection

pub const Collection = struct {
    gpa: Allocator,
    name: []u8,
    schema: Schema,

    ids: std.ArrayList([]u8) = .empty,
    by_id: std.StringHashMapUnmanaged(u32) = .empty,
    live: Bitset = .{},
    live_count: u32 = 0,
    payloads: std.ArrayList(?[]u8) = .empty,
    columns: []Column,
    vectors: ?*hnsw.Index = null,
    node_of_slot: std.ArrayList(u32) = .empty,
    /// Vectors of documents put with `putDeferred`, inserted by
    /// `flushVectors` (back to back, one per entry of `pending_slots`).
    pending_slots: std.ArrayList(u32) = .empty,
    pending_vectors: std.ArrayList(f32) = .empty,

    pub fn init(gpa: Allocator, name: []const u8, s: Schema) !*Collection {
        try s.validate();
        if (!schema.validName(name)) return error.InvalidSchema;
        const self = try gpa.create(Collection);
        errdefer gpa.destroy(self);
        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);
        var owned = try s.clone(gpa);
        errdefer owned.deinit(gpa);
        const columns = try gpa.alloc(Column, s.fields.len);
        for (columns, s.fields) |*c, f| c.* = Column.init(gpa, f.type, s.bm25);
        self.* = .{ .gpa = gpa, .name = owned_name, .schema = owned, .columns = columns };
        if (s.vector) |v| {
            self.vectors = hnsw.Index.init(gpa, .{
                .dim = v.dim,
                .metric = v.metric,
                .quantized = v.quantized,
                .m = v.m,
                .ef_construction = v.ef_construction,
            }) catch |e| {
                self.deinit();
                return e;
            };
        }
        return self;
    }

    pub fn deinit(self: *Collection) void {
        const gpa = self.gpa;
        for (self.ids.items) |id| if (id.len > 0) gpa.free(id);
        self.ids.deinit(gpa);
        self.by_id.deinit(gpa);
        self.live.deinit(gpa);
        for (self.payloads.items) |p| if (p) |b| gpa.free(b);
        self.payloads.deinit(gpa);
        for (self.columns) |*c| c.deinit(gpa);
        gpa.free(self.columns);
        if (self.vectors) |v| v.deinit();
        self.node_of_slot.deinit(gpa);
        self.pending_slots.deinit(gpa);
        self.pending_vectors.deinit(gpa);
        self.schema.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    pub fn len(self: *const Collection) u32 {
        return self.live_count;
    }

    pub fn slots(self: *const Collection) u32 {
        return @intCast(self.ids.items.len);
    }

    pub fn slotOf(self: *const Collection, id: []const u8) ?u32 {
        return self.by_id.get(id);
    }

    pub fn idOf(self: *const Collection, slot: u32) []const u8 {
        return self.ids.items[slot];
    }

    pub fn payloadOf(self: *const Collection, slot: u32) ?[]const u8 {
        return self.payloads.items[slot];
    }

    pub fn isLive(self: *const Collection, slot: u32) bool {
        return slot < self.live.bit_length and self.live.isSet(slot);
    }

    // ---- writes --------------------------------------------------------

    /// Inserts or replaces a document. The document must have passed
    /// `doc.validate(collection.schema)`. On `OutOfMemory` the collection may
    /// be left inconsistent: the caller must discard it and recover from the
    /// log.
    pub fn put(self: *Collection, doc: Doc) Error!void {
        try self.putDeferred(doc);
        try self.flushVectors(1);
    }

    /// Like `put`, but the vector is only queued: call `flushVectors` before
    /// any read. Lets a batch insert its vectors in parallel.
    pub fn putDeferred(self: *Collection, doc: Doc) Error!void {
        const gpa = self.gpa;
        if (self.by_id.get(doc.id)) |old| self.deleteSlot(old);
        if (self.ids.items.len >= none - 1) return error.OutOfMemory;
        const slot: u32 = @intCast(self.ids.items.len);

        // Grow every per-slot array first.
        const id = try gpa.dupe(u8, doc.id);
        errdefer gpa.free(id);
        try self.ids.ensureUnusedCapacity(gpa, 1);
        try self.payloads.ensureUnusedCapacity(gpa, 1);
        try self.node_of_slot.ensureUnusedCapacity(gpa, 1);
        try self.by_id.ensureUnusedCapacity(gpa, 1);
        try self.live.resize(gpa, slot + 1, false);
        for (self.columns) |*c| try c.appendSlot(gpa);
        const payload: ?[]u8 = if (doc.payload) |p| try gpa.dupe(u8, p) else null;

        self.ids.appendAssumeCapacity(id);
        self.payloads.appendAssumeCapacity(payload);
        self.node_of_slot.appendAssumeCapacity(none);
        self.by_id.putAssumeCapacity(id, slot);
        self.live.set(slot);
        self.live_count += 1;

        for (doc.fields) |fv| {
            const idx = self.schema.fieldIndex(fv.field).?;
            try self.setValue(&self.columns[idx], slot, fv.value);
        }
        if (doc.vector) |v| {
            if (v.len != self.schema.vector.?.dim) return error.InvalidDocument;
            try self.pending_slots.append(gpa, slot);
            try self.pending_vectors.appendSlice(gpa, v);
        }
    }

    /// Inserts the queued vectors of documents still live, on `threads`
    /// threads.
    pub fn flushVectors(self: *Collection, threads: usize) Error!void {
        if (self.pending_slots.items.len == 0) return;
        const gpa = self.gpa;
        const index = self.vectors.?;
        const dim = index.cfg.dim;
        defer {
            self.pending_slots.clearRetainingCapacity();
            self.pending_vectors.clearRetainingCapacity();
        }
        // Drop documents deleted or replaced later in the same batch.
        var kept: usize = 0;
        for (self.pending_slots.items, 0..) |slot, i| {
            if (!self.live.isSet(slot)) continue;
            self.pending_slots.items[kept] = slot;
            if (kept != i) @memmove(self.pending_vectors.items[kept * dim ..][0..dim], self.pending_vectors.items[i * dim ..][0..dim]);
            kept += 1;
        }
        const slots_ = self.pending_slots.items[0..kept];
        const nodes = try gpa.alloc(u32, kept);
        defer gpa.free(nodes);
        index.insertBatch(slots_, self.pending_vectors.items[0 .. kept * dim], threads, nodes) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidDocument,
        };
        for (slots_, nodes) |slot, node| self.node_of_slot.items[slot] = node;
    }

    fn setValue(self: *Collection, col: *Column, slot: u32, v: Value) Error!void {
        const gpa = self.gpa;
        switch (col.*) {
            .text => |*t| {
                const owned = try gpa.dupe(u8, v.text);
                t.values.items[slot] = owned;
                t.present.items[slot] = true;
                t.index.add(slot, v.text) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Corrupt,
                };
            },
            .keyword => |*t| try t.set(gpa, slot, &.{v.keyword}),
            .keywords => |*t| try t.set(gpa, slot, v.keywords),
            .int => |*n| setNum(i64, n, slot, v.int),
            .float => |*n| setNum(f64, n, slot, v.float),
            .bool => |*n| setNum(bool, n, slot, v.bool),
            .time => |*n| setNum(i64, n, slot, v.time),
        }
    }

    fn setNum(comptime T: type, n: *NumColumn(T), slot: u32, v: T) void {
        n.values.items[slot] = v;
        n.present.items[slot] = true;
    }

    /// Deletes a document; returns whether it existed.
    pub fn delete(self: *Collection, id: []const u8) bool {
        const slot = self.by_id.get(id) orelse return false;
        self.deleteSlot(slot);
        return true;
    }

    fn deleteSlot(self: *Collection, slot: u32) void {
        const gpa = self.gpa;
        _ = self.by_id.remove(self.ids.items[slot]);
        gpa.free(self.ids.items[slot]);
        self.ids.items[slot] = &.{};
        self.live.unset(slot);
        self.live_count -= 1;
        if (self.payloads.items[slot]) |p| gpa.free(p);
        self.payloads.items[slot] = null;
        for (self.columns) |*c| switch (c.*) {
            .text => |*t| {
                if (t.present.items[slot]) gpa.free(t.values.items[slot]);
                t.values.items[slot] = &.{};
                t.present.items[slot] = false;
                t.index.remove(slot);
            },
            .keyword, .keywords => |*t| t.clear(gpa, slot),
            inline .int, .float, .bool, .time => |*n| n.present.items[slot] = false,
        };
        const node = self.node_of_slot.items[slot];
        if (node != none) {
            self.vectors.?.remove(node);
            self.node_of_slot.items[slot] = none;
        }
    }

    // ---- reads ---------------------------------------------------------

    pub const FieldRef = union(FieldType) {
        text: []const u8,
        keyword: []const u8,
        keywords: struct {
            col: *const TagColumn,
            ids: []const u32,

            pub fn len(k: @This()) usize {
                return k.ids.len;
            }
            pub fn get(k: @This(), i: usize) []const u8 {
                return k.col.strs.items[k.ids[i]];
            }
        },
        int: i64,
        float: f64,
        bool: bool,
        time: i64,
    };

    /// Value of a field for a live slot, or null if absent.
    pub fn fieldOf(self: *const Collection, slot: u32, field: u16) ?FieldRef {
        const col = &self.columns[field];
        if (!col.present(slot)) return null;
        return switch (col.*) {
            .text => |*t| .{ .text = t.values.items[slot] },
            .keyword => |*t| .{ .keyword = t.strs.items[t.per_slot.items[slot][0]] },
            .keywords => |*t| .{ .keywords = .{ .col = t, .ids = t.per_slot.items[slot] } },
            .int => |*n| .{ .int = n.values.items[slot] },
            .float => |*n| .{ .float = n.values.items[slot] },
            .bool => |*n| .{ .bool = n.values.items[slot] },
            .time => |*n| .{ .time = n.values.items[slot] },
        };
    }

    /// Bitset of live slots matching `f` (already validated). Caller owns it.
    pub fn evalFilter(self: *const Collection, gpa: Allocator, f: *const Filter) Error!Bitset {
        var out = try self.evalNode(gpa, f);
        out.setIntersection(self.live);
        return out;
    }

    fn evalNode(self: *const Collection, gpa: Allocator, f: *const Filter) Error!Bitset {
        const n = self.ids.items.len;
        switch (f.*) {
            .eq => |e| {
                var out = try Bitset.initEmpty(gpa, n);
                self.markEq(e.field, e.value, &out);
                return out;
            },
            .in => |e| {
                var out = try Bitset.initEmpty(gpa, n);
                for (e.values) |v| self.markEq(e.field, v, &out);
                return out;
            },
            .range => |r| {
                var out = try Bitset.initEmpty(gpa, n);
                const col = &self.columns[self.schema.fieldIndex(r.field).?];
                switch (col.*) {
                    .int, .time => |*c| markRange(i64, c, r.lo, r.hi, &out),
                    .float => |*c| markRange(f64, c, r.lo, r.hi, &out),
                    else => return error.InvalidFilter,
                }
                return out;
            },
            .exists => |name| {
                var out = try Bitset.initEmpty(gpa, n);
                const col = &self.columns[self.schema.fieldIndex(name).?];
                for (0..n) |i| if (col.present(@intCast(i))) out.set(i);
                return out;
            },
            .all => |subs| {
                var out = try Bitset.initFull(gpa, n);
                errdefer out.deinit(gpa);
                for (subs) |*sub| {
                    var b = try self.evalNode(gpa, sub);
                    defer b.deinit(gpa);
                    out.setIntersection(b);
                }
                return out;
            },
            .any => |subs| {
                var out = try Bitset.initEmpty(gpa, n);
                errdefer out.deinit(gpa);
                for (subs) |*sub| {
                    var b = try self.evalNode(gpa, sub);
                    defer b.deinit(gpa);
                    out.setUnion(b);
                }
                return out;
            },
            .not => |sub| {
                var out = try self.evalNode(gpa, sub);
                out.toggleAll();
                return out;
            },
        }
    }

    fn markEq(self: *const Collection, field: []const u8, v: Value, out: *Bitset) void {
        const col = &self.columns[self.schema.fieldIndex(field).?];
        switch (col.*) {
            .keyword, .keywords => |*t| t.markEq(v.keyword, out),
            .int, .time => |*c| {
                const want = if (v == .int) v.int else v.time;
                for (c.values.items, c.present.items, 0..) |x, p, i| if (p and x == want) out.set(i);
            },
            .float => |*c| for (c.values.items, c.present.items, 0..) |x, p, i| {
                if (p and x == v.float) out.set(i);
            },
            .bool => |*c| for (c.values.items, c.present.items, 0..) |x, p, i| {
                if (p and x == v.bool) out.set(i);
            },
            .text => {},
        }
    }

    fn markRange(comptime T: type, c: *const NumColumn(T), lo: ?filter_mod.Bound, hi: ?filter_mod.Bound, out: *Bitset) void {
        const lo_v: ?T = if (lo) |b| boundValue(T, b.value) else null;
        const hi_v: ?T = if (hi) |b| boundValue(T, b.value) else null;
        const lo_inc = if (lo) |b| b.inclusive else true;
        const hi_inc = if (hi) |b| b.inclusive else true;
        for (c.values.items, c.present.items, 0..) |x, p, i| {
            if (!p) continue;
            if (lo_v) |l| if (x < l or (x == l and !lo_inc)) continue;
            if (hi_v) |h| if (x > h or (x == h and !hi_inc)) continue;
            out.set(i);
        }
    }

    fn boundValue(comptime T: type, v: Value) T {
        return switch (T) {
            f64 => v.float,
            else => if (v == .int) v.int else v.time,
        };
    }

    fn textFieldIndices(self: *const Collection, gpa: Allocator, names: ?[]const []const u8) Error![]u16 {
        var out: std.ArrayList(u16) = .empty;
        errdefer out.deinit(gpa);
        if (names) |ns| {
            for (ns) |name| {
                const idx = self.schema.fieldIndex(name) orelse return error.InvalidQuery;
                if (self.schema.fields[idx].type != .text) return error.InvalidQuery;
                try out.append(gpa, idx);
            }
        } else {
            for (self.schema.fields, 0..) |f, i| if (f.type == .text) try out.append(gpa, @intCast(i));
        }
        return out.toOwnedSlice(gpa);
    }

    /// Runs a query. The caller frees the returned slice.
    pub fn search(self: *const Collection, gpa: Allocator, q: Query) Error![]Hit {
        if (q.k == 0 or q.k > 10_000 or q.ef > 10_000 or q.candidates > 100_000) return error.InvalidQuery;
        if (q.vector) |v| {
            const spec = self.schema.vector orelse return error.InvalidQuery;
            if (v.len != spec.dim) return error.InvalidQuery;
            for (v) |x| if (!std.math.isFinite(x)) return error.InvalidQuery;
        }
        if (q.filter) |f| try f.validate(self.schema);
        const text_fields = try self.textFieldIndices(gpa, q.text_fields);
        defer gpa.free(text_fields);
        if ((q.text != null or q.exact != null) and text_fields.len == 0) return error.InvalidQuery;

        // Candidate set from the filter and the exact route.
        var allowed: ?Bitset = null;
        defer if (allowed) |*a| a.deinit(gpa);
        if (q.filter) |f| allowed = try self.evalFilter(gpa, f);
        if (q.exact) |needle| {
            if (needle.len == 0) return error.InvalidQuery;
            if (allowed == null) allowed = try self.live.clone(gpa);
            self.keepExact(&allowed.?, needle, text_fields);
        }

        const want_vector = q.vector != null;
        const want_text = q.text != null;
        if (!want_vector and !want_text) return self.listSlots(gpa, if (allowed) |*a| a else &self.live, q.k);

        const both = want_vector and want_text;
        const cand: usize = if (q.candidates > 0) q.candidates else if (both) @max(q.k * 4, 50) else q.k;

        var vec_hits: []topk.Item = &.{};
        defer gpa.free(vec_hits);
        if (q.vector) |v| vec_hits = try self.vectorRoute(gpa, v, cand, q.ef, if (allowed) |*a| a else null);

        var text_hits: []topk.Item = &.{};
        defer gpa.free(text_hits);
        if (q.text) |t| text_hits = try self.textRoute(gpa, t, cand, text_fields, if (allowed) |*a| a else null);

        return self.fuse(gpa, q, vec_hits, text_hits);
    }

    fn listSlots(self: *const Collection, gpa: Allocator, set: *const Bitset, k: u32) Error![]Hit {
        _ = self;
        var out: std.ArrayList(Hit) = .empty;
        errdefer out.deinit(gpa);
        var it = set.iterator(.{});
        while (it.next()) |slot| {
            if (out.items.len == k) break;
            try out.append(gpa, .{ .slot = @intCast(slot), .score = 0 });
        }
        return out.toOwnedSlice(gpa);
    }

    fn keepExact(self: *const Collection, set: *Bitset, needle: []const u8, fields: []const u16) void {
        var it = set.iterator(.{});
        while (it.next()) |slot| {
            var found = false;
            for (fields) |fi| {
                const t = &self.columns[fi].text;
                if (t.present.items[slot] and std.mem.indexOf(u8, t.values.items[slot], needle) != null) {
                    found = true;
                    break;
                }
            }
            if (!found) set.unset(slot);
        }
    }

    fn vectorRoute(self: *const Collection, gpa: Allocator, v: []const f32, cand: usize, ef: u32, allowed: ?*const Bitset) Error![]topk.Item {
        const index = self.vectors orelse return error.InvalidQuery;
        const out = try gpa.alloc(topk.Item, cand);
        errdefer gpa.free(out);
        var n: usize = 0;
        if (allowed) |a| {
            if (a.count() <= bruteForceThreshold(index.live)) {
                var nodes: std.ArrayList(u32) = .empty;
                defer nodes.deinit(gpa);
                var it = a.iterator(.{});
                while (it.next()) |slot| {
                    const node = self.node_of_slot.items[slot];
                    if (node != none) try nodes.append(gpa, node);
                }
                n = index.searchExact(gpa, v, nodes.items, cand, out) catch |e| return mapIndexErr(e);
            } else {
                n = index.search(gpa, v, cand, @max(ef, cand), a, out) catch |e| return mapIndexErr(e);
            }
        } else {
            n = index.search(gpa, v, cand, @max(ef, cand), null, out) catch |e| return mapIndexErr(e);
        }
        return gpa.realloc(out, n);
    }

    fn textRoute(self: *const Collection, gpa: Allocator, text: []const u8, cand: usize, fields: []const u16, allowed: ?*const Bitset) Error![]topk.Item {
        const buf = try gpa.alloc(topk.Item, cand);
        defer gpa.free(buf);
        if (fields.len == 1) {
            const n = try searchField(&self.columns[fields[0]].text.index, gpa, text, cand, allowed, buf);
            return gpa.dupe(topk.Item, buf[0..n]);
        }
        // Several fields: sum the scores per document.
        var acc: std.AutoArrayHashMapUnmanaged(u32, f32) = .empty;
        defer acc.deinit(gpa);
        for (fields) |fi| {
            const n = try searchField(&self.columns[fi].text.index, gpa, text, cand, allowed, buf);
            for (buf[0..n]) |h| {
                const gop = try acc.getOrPut(gpa, h.slot);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += h.dist;
            }
        }
        const all = try gpa.alloc(topk.Item, acc.count());
        defer gpa.free(all);
        for (acc.keys(), acc.values(), all) |slot, score, *o| o.* = .{ .slot = slot, .dist = score };
        std.mem.sort(topk.Item, all, {}, topk.descending);
        return gpa.dupe(topk.Item, all[0..@min(cand, all.len)]);
    }

    fn searchField(index: *const bm25.Index, gpa: Allocator, text: []const u8, cand: usize, allowed: ?*const Bitset, out: []topk.Item) Error!usize {
        return index.search(gpa, text, cand, allowed, out) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
    }

    fn similarity(self: *const Collection, dist: f32) f32 {
        return switch (self.schema.vector.?.metric) {
            .cosine, .dot => 1.0 - dist,
            .l2 => 1.0 / (1.0 + dist),
        };
    }

    fn fuse(self: *const Collection, gpa: Allocator, q: Query, vec_hits: []const topk.Item, text_hits: []const topk.Item) Error![]Hit {
        var by_slot: std.AutoArrayHashMapUnmanaged(u32, Hit) = .empty;
        defer by_slot.deinit(gpa);
        const both = q.vector != null and q.text != null;
        const max_text = if (text_hits.len > 0) text_hits[0].dist else 1;

        for (vec_hits, 1..) |h, rank| {
            const gop = try by_slot.getOrPut(gpa, h.slot);
            gop.value_ptr.* = .{ .slot = h.slot, .score = 0, .vector_rank = @intCast(rank), .vector_distance = h.dist };
        }
        for (text_hits, 1..) |h, rank| {
            const gop = try by_slot.getOrPut(gpa, h.slot);
            if (!gop.found_existing) gop.value_ptr.* = .{ .slot = h.slot, .score = 0 };
            gop.value_ptr.text_rank = @intCast(rank);
            gop.value_ptr.text_score = h.dist;
        }

        const hits = try gpa.alloc(Hit, by_slot.count());
        errdefer gpa.free(hits);
        for (by_slot.values(), hits) |h, *o| {
            o.* = h;
            if (!both) {
                o.score = if (h.vector_rank > 0) self.similarity(h.vector_distance) else h.text_score;
                continue;
            }
            switch (q.fusion) {
                .rrf => |k| {
                    if (h.vector_rank > 0) o.score += 1.0 / (k + @as(f32, @floatFromInt(h.vector_rank)));
                    if (h.text_rank > 0) o.score += 1.0 / (k + @as(f32, @floatFromInt(h.text_rank)));
                },
                .weighted => |w| {
                    if (h.vector_rank > 0) o.score += w.vector * self.similarity(h.vector_distance);
                    if (h.text_rank > 0) o.score += w.text * h.text_score / @max(max_text, 1e-9);
                },
            }
        }
        std.mem.sort(Hit, hits, {}, hitLess);
        return gpa.realloc(hits, @min(hits.len, q.k));
    }

    fn hitLess(_: void, a: Hit, b: Hit) bool {
        if (a.score == b.score) return a.slot < b.slot;
        return a.score > b.score;
    }

    // ---- consistency -----------------------------------------------------

    /// Checks that every structure agrees with the others: id table, live
    /// set, columns, BM25 and vector indexes. Returns `error.Corrupt` with
    /// nothing changed if not.
    pub fn check(self: *const Collection) Error!void {
        const n = self.ids.items.len;
        if (self.live.bit_length != n or self.payloads.items.len != n or self.node_of_slot.items.len != n) return error.Corrupt;
        if (self.live.count() != self.live_count or self.by_id.count() != self.live_count) return error.Corrupt;
        var it = self.by_id.iterator();
        while (it.next()) |kv| {
            const slot = kv.value_ptr.*;
            if (slot >= n or !self.live.isSet(slot) or !std.mem.eql(u8, self.ids.items[slot], kv.key_ptr.*)) return error.Corrupt;
        }
        for (0..n) |slot| {
            if (self.live.isSet(slot)) continue;
            if (self.ids.items[slot].len != 0 or self.payloads.items[slot] != null or self.node_of_slot.items[slot] != none) return error.Corrupt;
        }
        for (self.columns) |*col| switch (col.*) {
            .text => |*t| {
                if (t.values.items.len != n or t.present.items.len != n) return error.Corrupt;
                var with_text: u32 = 0;
                for (t.present.items, 0..) |p, slot| {
                    if (p and !self.live.isSet(slot)) return error.Corrupt;
                    if (p != t.index.contains(@intCast(slot))) return error.Corrupt;
                    if (p) with_text += 1;
                }
                if (t.index.live != with_text) return error.Corrupt;
            },
            .keyword, .keywords => |*t| {
                if (t.per_slot.items.len != n) return error.Corrupt;
                for (t.per_slot.items, 0..) |ids, slot| {
                    if (ids.len > 0 and !self.live.isSet(slot)) return error.Corrupt;
                    for (ids) |id| {
                        if (id >= t.strs.items.len) return error.Corrupt;
                        if (std.mem.indexOfScalar(u32, t.postings.items[id].items, @intCast(slot)) == null) return error.Corrupt;
                    }
                }
            },
            inline .int, .float, .bool, .time => |*c| {
                if (c.values.items.len != n or c.present.items.len != n) return error.Corrupt;
                for (c.present.items, 0..) |p, slot| if (p and !self.live.isSet(slot)) return error.Corrupt;
            },
        };
        if (self.vectors) |v| {
            var with_vector: u32 = 0;
            for (self.node_of_slot.items, 0..) |node, slot| {
                if (node == none) continue;
                if (node >= v.count or v.deleted.items[node] or v.labels.items[node] != slot) return error.Corrupt;
                with_vector += 1;
            }
            if (v.live != with_vector) return error.Corrupt;
        } else {
            for (self.node_of_slot.items) |node| if (node != none) return error.Corrupt;
        }
    }

    // ---- maintenance -----------------------------------------------------

    /// Renumbers live documents densely and rebuilds every index without
    /// tombstones. Search results are unchanged, slots are not.
    pub fn compact(self: *Collection) Error!void {
        var w = codec.Writer.init(self.gpa);
        defer w.deinit();
        try self.serialize(&w, true);
        var r: codec.Reader = .{ .data = w.buf.items };
        const fresh = try Collection.deserialize(self.gpa, &r);
        std.mem.swap(Collection, self, fresh);
        // Keep the original name allocation: callers may hold it (the
        // database uses it as a map key).
        std.mem.swap([]u8, &self.name, &fresh.name);
        fresh.deinit();
    }

    /// Writes live documents, renumbered densely. The vector graph keeps its
    /// tombstones (they still route searches) unless `compact_vectors`.
    pub fn serialize(self: *const Collection, w: *codec.Writer, compact_vectors: bool) Error!void {
        const gpa = self.gpa;
        const n = self.ids.items.len;
        const remap = try gpa.alloc(u32, n);
        defer gpa.free(remap);
        var next: u32 = 0;
        for (remap, 0..) |*r, i| {
            if (self.live.isSet(i)) {
                r.* = next;
                next += 1;
            } else r.* = none;
        }

        try w.blob(self.name);
        try self.schema.serialize(w);
        try w.int(u32, self.live_count);
        var it = self.live.iterator(.{});
        while (it.next()) |slot| {
            try w.blob(self.ids.items[slot]);
            if (self.payloads.items[slot]) |p| {
                try w.int(u8, 1);
                try w.blob(p);
            } else try w.int(u8, 0);
        }
        for (self.columns) |*col| {
            it = self.live.iterator(.{});
            switch (col.*) {
                .text => |*t| {
                    while (it.next()) |slot| {
                        try w.int(u8, @intFromBool(t.present.items[slot]));
                        if (t.present.items[slot]) try w.blob(t.values.items[slot]);
                    }
                    t.index.serialize(w, remap) catch |e| return mapIndexErr(e);
                },
                .keyword, .keywords => |*t| while (it.next()) |slot| {
                    const ids = t.per_slot.items[slot];
                    try w.varint(ids.len);
                    for (ids) |id| try w.blob(t.strs.items[id]);
                },
                .int, .time => |*c| while (it.next()) |slot| {
                    try w.int(u8, @intFromBool(c.present.items[slot]));
                    if (c.present.items[slot]) try w.int(i64, c.values.items[slot]);
                },
                .float => |*c| while (it.next()) |slot| {
                    try w.int(u8, @intFromBool(c.present.items[slot]));
                    if (c.present.items[slot]) try w.int(u64, @bitCast(c.values.items[slot]));
                },
                .bool => |*c| while (it.next()) |slot| {
                    const v: u8 = if (!c.present.items[slot]) 0 else if (c.values.items[slot]) 2 else 1;
                    try w.int(u8, v);
                },
            }
        }
        if (self.vectors) |v| {
            if (compact_vectors and v.live != v.count) {
                // Serialize a compacted copy without touching `self`.
                var tmp = codec.Writer.init(gpa);
                defer tmp.deinit();
                v.serialize(&tmp, null) catch |e| return mapIndexErr(e);
                var r: codec.Reader = .{ .data = tmp.buf.items };
                const copy = hnsw.Index.deserialize(gpa, &r) catch |e| return mapIndexErr(e);
                defer copy.deinit();
                copy.compact(remap) catch |e| return mapIndexErr(e);
                copy.serialize(w, null) catch |e| return mapIndexErr(e);
            } else {
                v.serialize(w, remap) catch |e| return mapIndexErr(e);
            }
        }
    }

    pub fn deserialize(gpa: Allocator, r: *codec.Reader) Error!*Collection {
        const name = try r.blob();
        const s = Schema.deserialize(gpa, r) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
        defer gpa.free(s.fields);
        const self = Collection.init(gpa, name, s) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
        errdefer self.deinit();

        const count = try r.int(u32);
        if (count > r.data.len) return error.Corrupt; // every document takes at least a byte
        try self.ids.ensureTotalCapacity(gpa, count);
        try self.payloads.ensureTotalCapacity(gpa, count);
        try self.node_of_slot.appendNTimes(gpa, none, count);
        try self.live.resize(gpa, count, true);
        try self.by_id.ensureTotalCapacity(gpa, count);
        for (0..count) |_| {
            const id = try r.blob();
            if (id.len == 0 or id.len > schema.limits.max_id_len) return error.Corrupt;
            const owned = try gpa.dupe(u8, id);
            self.ids.appendAssumeCapacity(owned);
            const gop = self.by_id.getOrPutAssumeCapacity(owned);
            if (gop.found_existing) return error.Corrupt;
            gop.value_ptr.* = @intCast(self.ids.items.len - 1);
            const has_payload = try r.int(u8);
            if (has_payload > 1) return error.Corrupt;
            self.payloads.appendAssumeCapacity(if (has_payload == 1) try gpa.dupe(u8, try r.blob()) else null);
        }
        self.live_count = count;

        for (self.columns) |*col| {
            for (0..count) |_| try col.appendSlot(gpa);
            switch (col.*) {
                .text => |*t| {
                    for (0..count) |slot| {
                        const p = try r.int(u8);
                        if (p > 1) return error.Corrupt;
                        if (p == 1) {
                            t.values.items[slot] = try gpa.dupe(u8, try r.blob());
                            t.present.items[slot] = true;
                        }
                    }
                    var index = bm25.Index.deserialize(gpa, r) catch |e| return mapIndexErr(e);
                    for (index.present.items, 0..) |p, slot| {
                        if (p and (slot >= count or !t.present.items[slot])) {
                            index.deinit();
                            return error.Corrupt;
                        }
                    }
                    t.index.deinit();
                    t.index = index;
                },
                .keyword, .keywords => |*t| {
                    const single = col.* == .keyword;
                    var strs: std.ArrayList([]const u8) = .empty;
                    defer strs.deinit(gpa);
                    for (0..count) |slot| {
                        const m = try r.varint();
                        if (m > schema.limits.max_keywords or (single and m > 1)) return error.Corrupt;
                        strs.items.len = 0;
                        for (0..@intCast(m)) |_| try strs.append(gpa, try r.blob());
                        if (m > 0) try t.set(gpa, @intCast(slot), strs.items);
                    }
                },
                .int, .time => |*c| for (0..count) |slot| {
                    const p = try r.int(u8);
                    if (p > 1) return error.Corrupt;
                    if (p == 1) setNum(i64, c, @intCast(slot), try r.int(i64));
                },
                .float => |*c| for (0..count) |slot| {
                    const p = try r.int(u8);
                    if (p > 1) return error.Corrupt;
                    if (p == 1) {
                        const x: f64 = @bitCast(try r.int(u64));
                        if (!std.math.isFinite(x)) return error.Corrupt;
                        setNum(f64, c, @intCast(slot), x);
                    }
                },
                .bool => |*c| for (0..count) |slot| {
                    const v = try r.int(u8);
                    if (v > 2) return error.Corrupt;
                    if (v > 0) setNum(bool, c, @intCast(slot), v == 2);
                },
            }
        }

        if (self.vectors) |old| {
            const index = hnsw.Index.deserialize(gpa, r) catch |e| return mapIndexErr(e);
            const spec = self.schema.vector.?;
            if (index.cfg.dim != spec.dim or index.cfg.metric != spec.metric or index.cfg.quantized != spec.quantized) {
                index.deinit();
                return error.Corrupt;
            }
            old.deinit();
            self.vectors = index;
            for (index.labels.items, index.deleted.items, 0..) |label, dead, node| {
                if (dead) continue;
                if (label >= count or self.node_of_slot.items[label] != none) return error.Corrupt;
                self.node_of_slot.items[label] = @intCast(node);
            }
        }
        return self;
    }
};

fn mapIndexErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const test_schema: Schema = .{
    .vector = .{ .dim = 4 },
    .fields = &.{
        .{ .name = "title", .type = .text },
        .{ .name = "body", .type = .text },
        .{ .name = "lang", .type = .keyword },
        .{ .name = "tags", .type = .keywords },
        .{ .name = "version", .type = .int },
        .{ .name = "score", .type = .float },
        .{ .name = "ok", .type = .bool },
        .{ .name = "at", .type = .time },
    },
};

fn sample(c: *Collection) !void {
    const docs = [_]Doc{
        .{ .id = "a", .vector = &.{ 1, 0, 0, 0 }, .payload = "pa", .fields = &.{
            .{ .field = "title", .value = .{ .text = "Expo metro resolve error" } },
            .{ .field = "body", .value = .{ .text = "clear the cache with npx expo start -c" } },
            .{ .field = "lang", .value = .{ .keyword = "en" } },
            .{ .field = "tags", .value = .{ .keywords = &.{ "expo", "metro" } } },
            .{ .field = "version", .value = .{ .int = 52 } },
            .{ .field = "score", .value = .{ .float = 0.5 } },
            .{ .field = "ok", .value = .{ .bool = true } },
            .{ .field = "at", .value = .{ .time = 1000 } },
        } },
        .{ .id = "b", .vector = &.{ 0.9, 0.1, 0, 0 }, .fields = &.{
            .{ .field = "title", .value = .{ .text = "Erreur de résolution Metro" } },
            .{ .field = "lang", .value = .{ .keyword = "fr" } },
            .{ .field = "tags", .value = .{ .keywords = &.{"metro"} } },
            .{ .field = "version", .value = .{ .int = 51 } },
            .{ .field = "score", .value = .{ .float = 1.0000001 } },
        } },
        .{ .id = "c", .vector = &.{ 0, 1, 0, 0 }, .fields = &.{
            .{ .field = "title", .value = .{ .text = "Zig build system" } },
            .{ .field = "lang", .value = .{ .keyword = "en" } },
            .{ .field = "score", .value = .{ .float = 1.0 } },
        } },
        .{ .id = "d", .fields = &.{
            .{ .field = "title", .value = .{ .text = "No vector here: ERR_MODULE_NOT_FOUND" } },
        } },
    };
    for (docs) |d| {
        try d.validate(c.schema);
        try c.put(d);
    }
}

fn hitIds(c: *const Collection, hits: []const Hit, buf: *[8][]const u8) []const []const u8 {
    for (hits, 0..) |h, i| buf[i] = c.idOf(h.slot);
    return buf[0..hits.len];
}

fn expectIds(c: *const Collection, hits: []const Hit, want: []const []const u8) !void {
    var buf: [8][]const u8 = undefined;
    const got = hitIds(c, hits, &buf);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "put, get, replace, delete" {
    const c = try Collection.init(testing.allocator, "docs", test_schema);
    defer c.deinit();
    try sample(c);
    try testing.expectEqual(@as(u32, 4), c.len());

    const a = c.slotOf("a").?;
    try testing.expectEqualStrings("pa", c.payloadOf(a).?);
    try testing.expectEqual(@as(i64, 52), c.fieldOf(a, 4).?.int);
    const tags = c.fieldOf(a, 3).?.keywords;
    try testing.expectEqual(@as(usize, 2), tags.len());
    try testing.expectEqualStrings("metro", tags.get(1));
    try testing.expect(c.fieldOf(c.slotOf("d").?, 4) == null);

    // Replace "a": new slot, old values gone.
    try c.check();
    try c.put(.{ .id = "a", .fields = &.{.{ .field = "title", .value = .{ .text = "replaced" } }} });
    try testing.expectEqual(@as(u32, 4), c.len());
    try testing.expect(c.slotOf("a").? != a);
    try testing.expect(c.payloadOf(c.slotOf("a").?) == null);

    try testing.expect(c.delete("b"));
    try testing.expect(!c.delete("b"));
    try testing.expectEqual(@as(u32, 3), c.len());
    try c.check();
}

test "filters" {
    const gpa = testing.allocator;
    const c = try Collection.init(gpa, "docs", test_schema);
    defer c.deinit();
    try sample(c);

    const cases = [_]struct { f: Filter, want: []const []const u8 }{
        .{ .f = .{ .eq = .{ .field = "lang", .value = .{ .keyword = "en" } } }, .want = &.{ "a", "c" } },
        .{ .f = .{ .eq = .{ .field = "tags", .value = .{ .keyword = "metro" } } }, .want = &.{ "a", "b" } },
        .{ .f = .{ .in = .{ .field = "version", .values = &.{ .{ .int = 51 }, .{ .int = 60 } } } }, .want = &.{"b"} },
        .{ .f = .{ .range = .{ .field = "version", .lo = .{ .value = .{ .int = 51 }, .inclusive = false } } }, .want = &.{"a"} },
        // Exclusive bound just above 1.0: only the 1.0000001 document (Zvec #817).
        .{ .f = .{ .range = .{ .field = "score", .lo = .{ .value = .{ .float = 1.00000005 }, .inclusive = false } } }, .want = &.{"b"} },
        .{ .f = .{ .range = .{ .field = "score", .hi = .{ .value = .{ .float = 1.0 } } } }, .want = &.{ "a", "c" } },
        .{ .f = .{ .exists = "version" }, .want = &.{ "a", "b" } },
        .{ .f = .{ .not = &.{ .exists = "version" } }, .want = &.{ "c", "d" } },
        .{ .f = .{ .eq = .{ .field = "ok", .value = .{ .bool = true } } }, .want = &.{"a"} },
        .{ .f = .{ .range = .{ .field = "at", .lo = .{ .value = .{ .time = 1000 } }, .hi = .{ .value = .{ .time = 1000 } } } }, .want = &.{"a"} },
        .{ .f = .{ .all = &.{
            .{ .eq = .{ .field = "lang", .value = .{ .keyword = "en" } } },
            .{ .any = &.{ .{ .exists = "tags" }, .{ .eq = .{ .field = "score", .value = .{ .float = 1.0 } } } } },
        } }, .want = &.{ "a", "c" } },
    };
    for (cases) |tc| {
        const hits = try c.search(gpa, .{ .filter = &tc.f, .k = 10 });
        defer gpa.free(hits);
        try expectIds(c, hits, tc.want);
    }

    // Deleted documents never match.
    _ = c.delete("a");
    const f: Filter = .{ .eq = .{ .field = "lang", .value = .{ .keyword = "en" } } };
    const hits = try c.search(gpa, .{ .filter = &f });
    defer gpa.free(hits);
    try expectIds(c, hits, &.{"c"});

    const bad: Filter = .{ .eq = .{ .field = "version", .value = .{ .float = 52 } } };
    try testing.expectError(error.InvalidFilter, c.search(gpa, .{ .filter = &bad }));
}

test "routes: vector, text, exact, hybrid" {
    const gpa = testing.allocator;
    const c = try Collection.init(gpa, "docs", test_schema);
    defer c.deinit();
    try sample(c);

    {
        const hits = try c.search(gpa, .{ .vector = &.{ 1, 0, 0, 0 }, .k = 2 });
        defer gpa.free(hits);
        try expectIds(c, hits, &.{ "a", "b" });
        try testing.expectApproxEqAbs(@as(f32, 1), hits[0].score, 1e-5);
        try testing.expectEqual(@as(u32, 1), hits[0].vector_rank);
    }
    {
        const f: Filter = .{ .eq = .{ .field = "lang", .value = .{ .keyword = "en" } } };
        const hits = try c.search(gpa, .{ .vector = &.{ 0.9, 0.1, 0, 0 }, .filter = &f, .k = 3 });
        defer gpa.free(hits);
        try expectIds(c, hits, &.{ "a", "c" });
    }
    {
        // Accent-insensitive, both text fields.
        const hits = try c.search(gpa, .{ .text = "resolution metro" });
        defer gpa.free(hits);
        try testing.expectEqualStrings("b", c.idOf(hits[0].slot));
        try testing.expectEqual(@as(usize, 2), hits.len);
    }
    {
        const hits = try c.search(gpa, .{ .text = "err_module_not_found" });
        defer gpa.free(hits);
        try expectIds(c, hits, &.{"d"});
    }
    {
        const hits = try c.search(gpa, .{ .exact = "npx expo start -c" });
        defer gpa.free(hits);
        try expectIds(c, hits, &.{"a"});
        const none_hits = try c.search(gpa, .{ .exact = "NPX EXPO" });
        defer gpa.free(none_hits);
        try testing.expectEqual(@as(usize, 0), none_hits.len);
    }
    {
        const hits = try c.search(gpa, .{ .vector = &.{ 0, 1, 0, 0 }, .text = "metro", .k = 3 });
        defer gpa.free(hits);
        try testing.expectEqual(@as(usize, 3), hits.len);
        for (hits) |h| try testing.expect(h.vector_rank > 0 or h.text_rank > 0);
        // "a" and "b" are found by both routes and come before "c".
        try testing.expectEqualStrings("c", c.idOf(hits[2].slot));
    }
    try testing.expectError(error.InvalidQuery, c.search(gpa, .{ .vector = &.{ 1, 0 } }));
    try testing.expectError(error.InvalidQuery, c.search(gpa, .{ .text = "x", .text_fields = &.{"lang"} }));
}

test "serialize and compact keep results" {
    const gpa = testing.allocator;
    const c = try Collection.init(gpa, "docs", test_schema);
    defer c.deinit();
    try sample(c);
    _ = c.delete("b");

    var w = codec.Writer.init(gpa);
    defer w.deinit();
    try c.serialize(&w, false);
    var r: codec.Reader = .{ .data = w.buf.items };
    const back = try Collection.deserialize(gpa, &r);
    defer back.deinit();
    try testing.expect(r.done());
    try testing.expectEqual(@as(u32, 3), back.len());
    try testing.expectEqual(@as(u32, 3), back.slots());

    try c.compact();
    try testing.expectEqual(@as(u32, 3), c.slots());
    try testing.expectEqual(c.vectors.?.count, c.vectors.?.live);

    for ([_]*Collection{ c, back }) |coll| {
        try coll.check();
        const hits = try coll.search(gpa, .{ .vector = &.{ 1, 0, 0, 0 }, .text = "metro", .k = 3 });
        defer gpa.free(hits);
        try testing.expectEqualStrings("a", coll.idOf(hits[0].slot));
        const f: Filter = .{ .eq = .{ .field = "tags", .value = .{ .keyword = "metro" } } };
        const fh = try coll.search(gpa, .{ .filter = &f });
        defer gpa.free(fh);
        try expectIds(coll, fh, &.{"a"});
        try testing.expectEqualStrings("pa", coll.payloadOf(coll.slotOf("a").?).?);
    }
}

test "filtered vector search switches to exact below the threshold" {
    const gpa = testing.allocator;
    const c = try Collection.init(gpa, "big", .{
        .vector = .{ .dim = 8 },
        .fields = &.{.{ .name = "group", .type = .int }},
    });
    defer c.deinit();
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var idbuf: [16]u8 = undefined;
    var v: [8]f32 = undefined;
    for (0..3000) |i| {
        for (&v) |*x| x.* = rnd.floatNorm(f32);
        const doc: Doc = .{
            .id = try std.fmt.bufPrint(&idbuf, "d{d}", .{i}),
            .vector = &v,
            .fields = &.{.{ .field = "group", .value = .{ .int = @intCast(i % 100) } }},
        };
        try c.put(doc);
    }
    // 30 documents match: exact search, so the 5 results are the true nearest.
    const f: Filter = .{ .eq = .{ .field = "group", .value = .{ .int = 7 } } };
    for (&v) |*x| x.* = rnd.floatNorm(f32);
    const hits = try c.search(gpa, .{ .vector = &v, .filter = &f, .k = 5 });
    defer gpa.free(hits);
    try testing.expectEqual(@as(usize, 5), hits.len);
    for (hits) |h| try testing.expectEqual(@as(i64, 7), c.fieldOf(h.slot, 0).?.int);
    for (hits[1..], hits[0 .. hits.len - 1]) |b, a| try testing.expect(a.score >= b.score);
}
