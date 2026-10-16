//! C API. See include/vectixdb.h for the contract.
//!
//! Every function returns `VTX_OK` (0) or a negative code, and stores a
//! message for `vtx_last_error` (per thread). Objects built by the caller
//! (schema, batch, filter, query) are plain values until passed to the
//! database; filters given to `vtx_filter_and/or/not` and `vtx_query_filter`
//! are owned by their new parent.

const std = @import("std");
const builtin = @import("builtin");
const fsmod = @import("fs.zig");
const dbmod = @import("db.zig");
const schema = @import("schema.zig");
const filter_mod = @import("filter.zig");
const coll_mod = @import("collection.zig");
const root = @import("root.zig");

const Filter = filter_mod.Filter;
const Allocator = std.mem.Allocator;

const gpa: Allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

/// The library's own I/O instance: no signal handlers, no thread pool, so
/// it coexists with any host runtime (Go, Python).
var threaded: std.Io.Threaded = .init_single_threaded;

pub const OK: c_int = 0;
pub const E_NOMEM: c_int = -1;
pub const E_IO: c_int = -2;
pub const E_CORRUPT: c_int = -3;
pub const E_LOCKED: c_int = -4;
pub const E_READONLY: c_int = -5;
pub const E_POISONED: c_int = -6;
pub const E_NOT_FOUND: c_int = -7;
pub const E_EXISTS: c_int = -8;
pub const E_INVALID: c_int = -9;
pub const E_NOSPACE: c_int = -10;
pub const E_TOO_LARGE: c_int = -11;

threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn fail(code: c_int, comptime fmt: []const u8, args: anytype) c_int {
    const msg = std.fmt.bufPrint(last_error_buf[0 .. last_error_buf.len - 1], fmt, args) catch last_error_buf[0 .. last_error_buf.len - 1];
    last_error_len = msg.len;
    last_error_buf[msg.len] = 0;
    return code;
}

fn failErr(e: anyerror, what: []const u8) c_int {
    const code: c_int = switch (e) {
        error.OutOfMemory => E_NOMEM,
        error.Corrupt => E_CORRUPT,
        error.Locked => E_LOCKED,
        error.ReadOnly => E_READONLY,
        error.Poisoned => E_POISONED,
        error.NotFound => E_NOT_FOUND,
        error.AlreadyExists => E_EXISTS,
        error.InvalidSchema, error.InvalidDocument, error.InvalidQuery, error.InvalidFilter, error.InvalidArgument => E_INVALID,
        error.NoSpace => E_NOSPACE,
        error.RecordTooLarge => E_TOO_LARGE,
        else => E_IO,
    };
    return fail(code, "{s}: {t}", .{ what, e });
}

fn ok() c_int {
    last_error_len = 0;
    last_error_buf[0] = 0;
    return OK;
}

fn span(p: ?[*:0]const u8) ?[]const u8 {
    return if (p) |s| std.mem.span(s) else null;
}

fn bytes(p: ?[*]const u8, len: usize) []const u8 {
    if (len == 0) return "";
    return (p orelse return "")[0..len];
}

export fn vtx_version() [*:0]const u8 {
    return root.version;
}

export fn vtx_last_error() [*:0]const u8 {
    if (last_error_len == 0) return "";
    return @ptrCast(&last_error_buf);
}

// ---------------------------------------------------------------------------
// Database

pub const Options = extern struct {
    /// sizeof(vtx_options), for forward compatibility.
    struct_size: u32,
    read_only: c_int,
    /// 0: sync (default), 1: none.
    durability: c_int,
    /// Bytes of log before an automatic checkpoint; 0 keeps the default.
    checkpoint_after: u64,
    repair: c_int,
};

const Handle = struct {
    real: fsmod.Real,
    db: *dbmod.Db,
};

export fn vtx_open(path: ?[*:0]const u8, opt: ?*const Options, out: ?*?*Handle) c_int {
    const out_ptr = out orelse return fail(E_INVALID, "vtx_open: out is NULL", .{});
    out_ptr.* = null;
    const p = span(path) orelse return fail(E_INVALID, "vtx_open: path is NULL", .{});
    var opts: dbmod.Options = .{};
    if (opt) |o| {
        if (o.struct_size < @sizeOf(Options)) return fail(E_INVALID, "vtx_open: unsupported vtx_options size", .{});
        opts.read_only = o.read_only != 0;
        opts.durability = if (o.durability == 1) .none else .sync;
        if (o.checkpoint_after > 0) opts.checkpoint_after = o.checkpoint_after;
        opts.repair = o.repair != 0;
    }
    const h = gpa.create(Handle) catch return fail(E_NOMEM, "vtx_open: out of memory", .{});
    const io = threaded.io();
    h.real = fsmod.Real.open(io, p, if (opts.read_only) .shared else .exclusive) catch |e| {
        gpa.destroy(h);
        return failErr(e, "vtx_open");
    };
    h.db = dbmod.Db.open(gpa, io, h.real.fs(), opts) catch |e| {
        h.real.deinit();
        gpa.destroy(h);
        return failErr(e, "vtx_open");
    };
    out_ptr.* = h;
    return ok();
}

export fn vtx_close(h: ?*Handle) c_int {
    const handle = h orelse return ok();
    const result = handle.db.close();
    handle.real.deinit();
    gpa.destroy(handle);
    result catch |e| return failErr(e, "vtx_close");
    return ok();
}

export fn vtx_sync(h: *Handle) c_int {
    h.db.sync() catch |e| return failErr(e, "vtx_sync");
    return ok();
}

export fn vtx_checkpoint(h: *Handle) c_int {
    h.db.checkpoint() catch |e| return failErr(e, "vtx_checkpoint");
    return ok();
}

export fn vtx_compact(h: *Handle, coll: ?[*:0]const u8) c_int {
    const name = span(coll) orelse return fail(E_INVALID, "vtx_compact: collection is NULL", .{});
    h.db.compact(name) catch |e| return failErr(e, "vtx_compact");
    return ok();
}

pub const Stats = extern struct {
    collections: u32,
    documents: u64,
    last_seq: u64,
    checkpoint_seq: u64,
    generation: u64,
    wal_bytes: u64,
};

export fn vtx_stats(h: *Handle, out: *Stats) void {
    const s = h.db.stats();
    out.* = .{
        .collections = s.collections,
        .documents = s.documents,
        .last_seq = s.last_seq,
        .checkpoint_seq = s.checkpoint_seq,
        .generation = s.generation,
        .wal_bytes = s.wal_bytes,
    };
}

export fn vtx_count(h: *Handle, coll: ?[*:0]const u8, out: *u32) c_int {
    const name = span(coll) orelse return fail(E_INVALID, "vtx_count: collection is NULL", .{});
    out.* = h.db.count(name) catch |e| return failErr(e, "vtx_count");
    return ok();
}

const Names = struct { items: [][]u8, z: [][:0]u8 };

export fn vtx_collections(h: *Handle, out: *?*Names) c_int {
    out.* = null;
    const names = h.db.collectionNames(gpa) catch |e| return failErr(e, "vtx_collections");
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }
    const n = gpa.create(Names) catch return fail(E_NOMEM, "vtx_collections: out of memory", .{});
    n.* = .{ .items = &.{}, .z = gpa.alloc([:0]u8, names.len) catch {
        gpa.destroy(n);
        return fail(E_NOMEM, "vtx_collections: out of memory", .{});
    } };
    for (names, 0..) |name, i| {
        n.z[i] = gpa.dupeZ(u8, name) catch {
            for (n.z[0..i]) |z| gpa.free(z);
            gpa.free(n.z);
            gpa.destroy(n);
            return fail(E_NOMEM, "vtx_collections: out of memory", .{});
        };
    }
    out.* = n;
    return ok();
}

export fn vtx_names_len(n: *const Names) usize {
    return n.z.len;
}

export fn vtx_names_get(n: *const Names, i: usize) [*:0]const u8 {
    return n.z[i].ptr;
}

export fn vtx_names_free(n: ?*Names) void {
    const names = n orelse return;
    for (names.z) |z| gpa.free(z);
    gpa.free(names.z);
    gpa.destroy(names);
}

// ---------------------------------------------------------------------------
// Schema and collections

const SchemaBuilder = struct {
    arena: std.heap.ArenaAllocator,
    schema: schema.Schema = .{},
    fields: std.ArrayList(schema.Field) = .empty,

    fn build(b: *SchemaBuilder) schema.Schema {
        var s = b.schema;
        s.fields = b.fields.items;
        return s;
    }
};

export fn vtx_schema_new() ?*SchemaBuilder {
    const b = gpa.create(SchemaBuilder) catch return null;
    b.* = .{ .arena = .init(gpa) };
    return b;
}

export fn vtx_schema_free(b: ?*SchemaBuilder) void {
    const builder = b orelse return;
    builder.arena.deinit();
    gpa.destroy(builder);
}

export fn vtx_schema_vector(b: *SchemaBuilder, dim: u32, metric: c_int, quantized: c_int, m: u32, ef_construction: u32, tag: ?[*:0]const u8) c_int {
    if (metric < 0 or metric > 2) return fail(E_INVALID, "vtx_schema_vector: unknown metric {d}", .{metric});
    const a = b.arena.allocator();
    b.schema.vector = .{
        .dim = dim,
        .metric = @enumFromInt(@as(u32, @intCast(metric))),
        .quantized = quantized != 0,
        .m = if (m == 0) 16 else m,
        .ef_construction = if (ef_construction == 0) 200 else ef_construction,
        .tag = a.dupe(u8, span(tag) orelse "") catch return fail(E_NOMEM, "out of memory", .{}),
    };
    return ok();
}

export fn vtx_schema_field(b: *SchemaBuilder, name: ?[*:0]const u8, field_type: c_int) c_int {
    const n = span(name) orelse return fail(E_INVALID, "vtx_schema_field: name is NULL", .{});
    if (field_type < 0 or field_type > @intFromEnum(schema.FieldType.time)) return fail(E_INVALID, "vtx_schema_field: unknown type {d}", .{field_type});
    const a = b.arena.allocator();
    const owned = a.dupe(u8, n) catch return fail(E_NOMEM, "out of memory", .{});
    b.fields.append(a, .{ .name = owned, .type = @enumFromInt(@as(u8, @intCast(field_type))) }) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_schema_bm25(b: *SchemaBuilder, k1: f32, bb: f32) c_int {
    b.schema.bm25 = .{ .k1 = k1, .b = bb };
    return ok();
}

export fn vtx_create_collection(h: *Handle, name: ?[*:0]const u8, b: *SchemaBuilder) c_int {
    const n = span(name) orelse return fail(E_INVALID, "vtx_create_collection: name is NULL", .{});
    _ = h.db.createCollection(n, b.build()) catch |e| return failErr(e, "vtx_create_collection");
    return ok();
}

export fn vtx_drop_collection(h: *Handle, name: ?[*:0]const u8) c_int {
    const n = span(name) orelse return fail(E_INVALID, "vtx_drop_collection: name is NULL", .{});
    _ = h.db.dropCollection(n) catch |e| return failErr(e, "vtx_drop_collection");
    return ok();
}

// ---------------------------------------------------------------------------
// Batches

const Batch = struct {
    arena: std.heap.ArenaAllocator,
    ops: std.ArrayList(dbmod.Op) = .empty,
    /// Document being built by the last vtx_batch_put.
    doc: ?struct {
        collection: []const u8,
        doc: schema.Doc,
        fields: std.ArrayList(schema.FieldValue),
    } = null,

    fn finish(b: *Batch) !void {
        const d = b.doc orelse return;
        var doc = d.doc;
        doc.fields = d.fields.items;
        try b.ops.append(b.arena.allocator(), .{ .put = .{ .collection = d.collection, .doc = doc } });
        b.doc = null;
    }

    fn setField(b: *Batch, field: ?[*:0]const u8, value: schema.Value) c_int {
        const d = &(b.doc orelse return fail(E_INVALID, "no document: call vtx_batch_put first", .{}));
        const name = span(field) orelse return fail(E_INVALID, "field name is NULL", .{});
        const a = b.arena.allocator();
        const owned = a.dupe(u8, name) catch return fail(E_NOMEM, "out of memory", .{});
        d.fields.append(a, .{ .field = owned, .value = value }) catch return fail(E_NOMEM, "out of memory", .{});
        return ok();
    }

    fn dupe(b: *Batch, p: ?[*]const u8, len: usize) ?[]const u8 {
        return b.arena.allocator().dupe(u8, bytes(p, len)) catch null;
    }
};

export fn vtx_batch_new() ?*Batch {
    const b = gpa.create(Batch) catch return null;
    b.* = .{ .arena = .init(gpa) };
    return b;
}

export fn vtx_batch_free(b: ?*Batch) void {
    const batch = b orelse return;
    batch.arena.deinit();
    gpa.destroy(batch);
}

export fn vtx_batch_reset(b: *Batch) void {
    _ = b.arena.reset(.retain_capacity);
    b.ops = .empty;
    b.doc = null;
}

export fn vtx_batch_put(b: *Batch, coll: ?[*:0]const u8, id: ?[*]const u8, id_len: usize) c_int {
    b.finish() catch return fail(E_NOMEM, "out of memory", .{});
    const c = span(coll) orelse return fail(E_INVALID, "vtx_batch_put: collection is NULL", .{});
    const a = b.arena.allocator();
    const cc = a.dupe(u8, c) catch return fail(E_NOMEM, "out of memory", .{});
    const ii = b.dupe(id, id_len) orelse return fail(E_NOMEM, "out of memory", .{});
    b.doc = .{ .collection = cc, .doc = .{ .id = ii }, .fields = .empty };
    return ok();
}

export fn vtx_batch_vector(b: *Batch, v: ?[*]const f32, dim: usize) c_int {
    const d = &(b.doc orelse return fail(E_INVALID, "no document: call vtx_batch_put first", .{}));
    const src = v orelse return fail(E_INVALID, "vtx_batch_vector: vector is NULL", .{});
    d.doc.vector = b.arena.allocator().dupe(f32, src[0..dim]) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_batch_payload(b: *Batch, p: ?[*]const u8, len: usize) c_int {
    const d = &(b.doc orelse return fail(E_INVALID, "no document: call vtx_batch_put first", .{}));
    d.doc.payload = b.dupe(p, len) orelse return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_batch_text(b: *Batch, field: ?[*:0]const u8, s: ?[*]const u8, len: usize) c_int {
    const v = b.dupe(s, len) orelse return fail(E_NOMEM, "out of memory", .{});
    return b.setField(field, .{ .text = v });
}

export fn vtx_batch_keyword(b: *Batch, field: ?[*:0]const u8, s: ?[*]const u8, len: usize) c_int {
    const v = b.dupe(s, len) orelse return fail(E_NOMEM, "out of memory", .{});
    return b.setField(field, .{ .keyword = v });
}

/// Sets a keywords field from `n` strings.
export fn vtx_batch_keywords(b: *Batch, field: ?[*:0]const u8, strs: ?[*]const [*]const u8, lens: ?[*]const usize, n: usize) c_int {
    const a = b.arena.allocator();
    const list = a.alloc([]const u8, n) catch return fail(E_NOMEM, "out of memory", .{});
    if (n > 0) {
        const ss = strs orelse return fail(E_INVALID, "vtx_batch_keywords: strings are NULL", .{});
        const ls = lens orelse return fail(E_INVALID, "vtx_batch_keywords: lengths are NULL", .{});
        for (list, 0..) |*x, i| x.* = b.dupe(ss[i], ls[i]) orelse return fail(E_NOMEM, "out of memory", .{});
    }
    return b.setField(field, .{ .keywords = list });
}

export fn vtx_batch_int(b: *Batch, field: ?[*:0]const u8, v: i64) c_int {
    return b.setField(field, .{ .int = v });
}

export fn vtx_batch_float(b: *Batch, field: ?[*:0]const u8, v: f64) c_int {
    return b.setField(field, .{ .float = v });
}

export fn vtx_batch_bool(b: *Batch, field: ?[*:0]const u8, v: c_int) c_int {
    return b.setField(field, .{ .bool = v != 0 });
}

export fn vtx_batch_time(b: *Batch, field: ?[*:0]const u8, ms: i64) c_int {
    return b.setField(field, .{ .time = ms });
}

export fn vtx_batch_delete(b: *Batch, coll: ?[*:0]const u8, id: ?[*]const u8, id_len: usize) c_int {
    b.finish() catch return fail(E_NOMEM, "out of memory", .{});
    const c = span(coll) orelse return fail(E_INVALID, "vtx_batch_delete: collection is NULL", .{});
    const a = b.arena.allocator();
    const cc = a.dupe(u8, c) catch return fail(E_NOMEM, "out of memory", .{});
    const ii = b.dupe(id, id_len) orelse return fail(E_NOMEM, "out of memory", .{});
    b.ops.append(a, .{ .delete = .{ .collection = cc, .id = ii } }) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

/// Applies the batch atomically. The batch is left unchanged (reset it to
/// reuse it).
export fn vtx_write(h: *Handle, b: *Batch, seq_out: ?*u64) c_int {
    b.finish() catch return fail(E_NOMEM, "out of memory", .{});
    const seq = h.db.write(b.ops.items) catch |e| return failErr(e, "vtx_write");
    if (seq_out) |s| s.* = seq;
    return ok();
}

// ---------------------------------------------------------------------------
// Filters

const CFilter = struct {
    node: Filter,
    arena: std.heap.ArenaAllocator,
    children: [2]?*CFilter = .{ null, null },
};

/// Allocates a leaf filter on `field`; `make` builds the node from the
/// owned field name.
fn leaf(field: ?[*:0]const u8, ctx: anytype, comptime make: fn (@TypeOf(ctx), []const u8, Allocator) anyerror!Filter) ?*CFilter {
    const name = span(field) orelse return null;
    const f = gpa.create(CFilter) catch return null;
    f.* = .{ .node = undefined, .arena = .init(gpa) };
    const a = f.arena.allocator();
    const owned = a.dupe(u8, name) catch {
        vtx_filter_free(f);
        return null;
    };
    f.node = make(ctx, owned, a) catch {
        vtx_filter_free(f);
        return null;
    };
    return f;
}

export fn vtx_filter_free(f: ?*CFilter) void {
    const node = f orelse return;
    for (node.children) |c| vtx_filter_free(c);
    node.arena.deinit();
    gpa.destroy(node);
}

export fn vtx_filter_eq_keyword(field: ?[*:0]const u8, s: ?[*]const u8, len: usize) ?*CFilter {
    return leaf(field, bytes(s, len), struct {
        fn make(v: []const u8, name: []const u8, a: Allocator) !Filter {
            return .{ .eq = .{ .field = name, .value = .{ .keyword = try a.dupe(u8, v) } } };
        }
    }.make);
}

fn scalarFilter(field: ?[*:0]const u8, value: schema.Value) ?*CFilter {
    return leaf(field, value, struct {
        fn make(v: schema.Value, name: []const u8, _: Allocator) !Filter {
            return .{ .eq = .{ .field = name, .value = v } };
        }
    }.make);
}

export fn vtx_filter_eq_int(field: ?[*:0]const u8, v: i64) ?*CFilter {
    return scalarFilter(field, .{ .int = v });
}
export fn vtx_filter_eq_float(field: ?[*:0]const u8, v: f64) ?*CFilter {
    return scalarFilter(field, .{ .float = v });
}
export fn vtx_filter_eq_bool(field: ?[*:0]const u8, v: c_int) ?*CFilter {
    return scalarFilter(field, .{ .bool = v != 0 });
}
export fn vtx_filter_eq_time(field: ?[*:0]const u8, v: i64) ?*CFilter {
    return scalarFilter(field, .{ .time = v });
}

const Bounds = struct { lo: ?filter_mod.Bound, hi: ?filter_mod.Bound };

/// Flags for range bounds.
const has_lo: c_int = 1;
const lo_inclusive: c_int = 2;
const has_hi: c_int = 4;
const hi_inclusive: c_int = 8;

fn rangeFilter(field: ?[*:0]const u8, flags: c_int, lo: schema.Value, hi: schema.Value) ?*CFilter {
    const b: Bounds = .{
        .lo = if (flags & has_lo != 0) .{ .value = lo, .inclusive = flags & lo_inclusive != 0 } else null,
        .hi = if (flags & has_hi != 0) .{ .value = hi, .inclusive = flags & hi_inclusive != 0 } else null,
    };
    return leaf(field, b, struct {
        fn make(bb: Bounds, name: []const u8, _: Allocator) !Filter {
            return .{ .range = .{ .field = name, .lo = bb.lo, .hi = bb.hi } };
        }
    }.make);
}

export fn vtx_filter_range_int(field: ?[*:0]const u8, lo: i64, hi: i64, flags: c_int) ?*CFilter {
    return rangeFilter(field, flags, .{ .int = lo }, .{ .int = hi });
}
export fn vtx_filter_range_float(field: ?[*:0]const u8, lo: f64, hi: f64, flags: c_int) ?*CFilter {
    return rangeFilter(field, flags, .{ .float = lo }, .{ .float = hi });
}
export fn vtx_filter_range_time(field: ?[*:0]const u8, lo: i64, hi: i64, flags: c_int) ?*CFilter {
    return rangeFilter(field, flags, .{ .time = lo }, .{ .time = hi });
}

export fn vtx_filter_exists(field: ?[*:0]const u8) ?*CFilter {
    return leaf(field, {}, struct {
        fn make(_: void, name: []const u8, _: Allocator) !Filter {
            return .{ .exists = name };
        }
    }.make);
}

fn combine(a: ?*CFilter, b: ?*CFilter, any: bool) ?*CFilter {
    const x = a orelse {
        vtx_filter_free(b);
        return null;
    };
    const y = b orelse {
        vtx_filter_free(x);
        return null;
    };
    const f = gpa.create(CFilter) catch {
        vtx_filter_free(x);
        vtx_filter_free(y);
        return null;
    };
    f.* = .{ .node = undefined, .arena = .init(gpa), .children = .{ x, y } };
    const list = f.arena.allocator().alloc(Filter, 2) catch {
        vtx_filter_free(f);
        return null;
    };
    list[0] = x.node;
    list[1] = y.node;
    f.node = if (any) .{ .any = list } else .{ .all = list };
    return f;
}

/// Takes ownership of `a` and `b` (also on failure).
export fn vtx_filter_and(a: ?*CFilter, b: ?*CFilter) ?*CFilter {
    return combine(a, b, false);
}

export fn vtx_filter_or(a: ?*CFilter, b: ?*CFilter) ?*CFilter {
    return combine(a, b, true);
}

export fn vtx_filter_not(a: ?*CFilter) ?*CFilter {
    const x = a orelse return null;
    const f = gpa.create(CFilter) catch {
        vtx_filter_free(x);
        return null;
    };
    f.* = .{ .node = .{ .not = &x.node }, .arena = .init(gpa), .children = .{ x, null } };
    return f;
}

// ---------------------------------------------------------------------------
// Queries and results

const CQuery = struct {
    arena: std.heap.ArenaAllocator,
    collection: []const u8,
    query: coll_mod.Query,
    text_fields: std.ArrayList([]const u8) = .empty,
    out_fields: std.ArrayList([]const u8) = .empty,
    payload: bool = true,
    filter: ?*CFilter = null,
};

export fn vtx_query_new(coll: ?[*:0]const u8, k: u32) ?*CQuery {
    const c = span(coll) orelse return null;
    const q = gpa.create(CQuery) catch return null;
    q.* = .{ .arena = .init(gpa), .collection = "", .query = .{ .k = k } };
    q.collection = q.arena.allocator().dupe(u8, c) catch {
        vtx_query_free(q);
        return null;
    };
    return q;
}

export fn vtx_query_free(q: ?*CQuery) void {
    const query = q orelse return;
    vtx_filter_free(query.filter);
    query.arena.deinit();
    gpa.destroy(query);
}

export fn vtx_query_vector(q: *CQuery, v: ?[*]const f32, dim: usize) c_int {
    const src = v orelse return fail(E_INVALID, "vtx_query_vector: vector is NULL", .{});
    q.query.vector = q.arena.allocator().dupe(f32, src[0..dim]) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_query_text(q: *CQuery, s: ?[*]const u8, len: usize) c_int {
    q.query.text = q.arena.allocator().dupe(u8, bytes(s, len)) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_query_exact(q: *CQuery, s: ?[*]const u8, len: usize) c_int {
    q.query.exact = q.arena.allocator().dupe(u8, bytes(s, len)) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

/// Restricts `text` and `exact` to this text field (call once per field).
export fn vtx_query_text_field(q: *CQuery, name: ?[*:0]const u8) c_int {
    const n = span(name) orelse return fail(E_INVALID, "vtx_query_text_field: name is NULL", .{});
    const a = q.arena.allocator();
    q.text_fields.append(a, a.dupe(u8, n) catch return fail(E_NOMEM, "out of memory", .{})) catch return fail(E_NOMEM, "out of memory", .{});
    q.query.text_fields = q.text_fields.items;
    return ok();
}

/// Takes ownership of `f`, replacing any previous filter.
export fn vtx_query_filter(q: *CQuery, f: ?*CFilter) c_int {
    vtx_filter_free(q.filter);
    q.filter = f;
    q.query.filter = if (f) |x| &x.node else null;
    return ok();
}

export fn vtx_query_ef(q: *CQuery, ef: u32) c_int {
    q.query.ef = ef;
    return ok();
}

export fn vtx_query_candidates(q: *CQuery, n: u32) c_int {
    q.query.candidates = n;
    return ok();
}

export fn vtx_query_rrf(q: *CQuery, k: f32) c_int {
    if (!(k > 0)) return fail(E_INVALID, "vtx_query_rrf: k must be > 0", .{});
    q.query.fusion = .{ .rrf = k };
    return ok();
}

export fn vtx_query_weighted(q: *CQuery, vector: f32, text: f32) c_int {
    q.query.fusion = .{ .weighted = .{ .vector = vector, .text = text } };
    return ok();
}

/// Adds a field to copy into each result.
export fn vtx_query_return_field(q: *CQuery, name: ?[*:0]const u8) c_int {
    const n = span(name) orelse return fail(E_INVALID, "vtx_query_return_field: name is NULL", .{});
    const a = q.arena.allocator();
    q.out_fields.append(a, a.dupe(u8, n) catch return fail(E_NOMEM, "out of memory", .{})) catch return fail(E_NOMEM, "out of memory", .{});
    return ok();
}

export fn vtx_query_payload(q: *CQuery, include: c_int) c_int {
    q.payload = include != 0;
    return ok();
}

const CResults = struct {
    inner: dbmod.Results,
};

export fn vtx_search(h: *Handle, q: *const CQuery, out: *?*CResults) c_int {
    out.* = null;
    const r = h.db.search(q.collection, q.query, .{ .fields = q.out_fields.items, .payload = q.payload }) catch |e| return failErr(e, "vtx_search");
    const res = gpa.create(CResults) catch {
        var rr = r;
        rr.deinit();
        return fail(E_NOMEM, "out of memory", .{});
    };
    res.* = .{ .inner = r };
    out.* = res;
    return ok();
}

/// Fetches one document by id. `*out` holds zero or one result.
export fn vtx_get(h: *Handle, coll: ?[*:0]const u8, id: ?[*]const u8, id_len: usize, out: *?*CResults) c_int {
    out.* = null;
    const c = span(coll) orelse return fail(E_INVALID, "vtx_get: collection is NULL", .{});
    const found = h.db.get(c, bytes(id, id_len)) catch |e| return failErr(e, "vtx_get");
    const r: dbmod.Results = found orelse .{ .arena = .init(gpa), .items = &.{} };
    const res = gpa.create(CResults) catch {
        var rr = r;
        rr.deinit();
        return fail(E_NOMEM, "out of memory", .{});
    };
    res.* = .{ .inner = r };
    out.* = res;
    return ok();
}

export fn vtx_results_free(r: ?*CResults) void {
    const res = r orelse return;
    res.inner.deinit();
    gpa.destroy(res);
}

export fn vtx_results_len(r: *const CResults) usize {
    return r.inner.items.len;
}

export fn vtx_result_id(r: *const CResults, i: usize, len: *usize) [*]const u8 {
    const id = r.inner.items[i].id;
    len.* = id.len;
    return id.ptr;
}

export fn vtx_result_score(r: *const CResults, i: usize) f32 {
    return r.inner.items[i].score;
}

pub const Explain = extern struct {
    vector_rank: u32,
    vector_distance: f32,
    text_rank: u32,
    text_score: f32,
};

export fn vtx_result_explain(r: *const CResults, i: usize, out: *Explain) void {
    const it = r.inner.items[i];
    out.* = .{ .vector_rank = it.vector_rank, .vector_distance = it.vector_distance, .text_rank = it.text_rank, .text_score = it.text_score };
}

/// NULL when the document has no payload.
export fn vtx_result_payload(r: *const CResults, i: usize, len: *usize) ?[*]const u8 {
    const p = r.inner.items[i].payload orelse {
        len.* = 0;
        return null;
    };
    len.* = p.len;
    return p.ptr;
}

export fn vtx_result_fields(r: *const CResults, i: usize) usize {
    return r.inner.items[i].fields.len;
}

export fn vtx_result_field_name(r: *const CResults, i: usize, j: usize, len: *usize) [*]const u8 {
    const n = r.inner.items[i].fields[j].field;
    len.* = n.len;
    return n.ptr;
}

export fn vtx_result_field_type(r: *const CResults, i: usize, j: usize) c_int {
    return @intFromEnum(std.meta.activeTag(r.inner.items[i].fields[j].value));
}

/// text and keyword fields.
export fn vtx_result_field_str(r: *const CResults, i: usize, j: usize, len: *usize) ?[*]const u8 {
    const s = switch (r.inner.items[i].fields[j].value) {
        .text, .keyword => |s| s,
        else => {
            len.* = 0;
            return null;
        },
    };
    len.* = s.len;
    return s.ptr;
}

/// Number of strings of a keywords field.
export fn vtx_result_field_count(r: *const CResults, i: usize, j: usize) usize {
    return switch (r.inner.items[i].fields[j].value) {
        .keywords => |ks| ks.len,
        else => 0,
    };
}

export fn vtx_result_field_item(r: *const CResults, i: usize, j: usize, k: usize, len: *usize) ?[*]const u8 {
    const ks = switch (r.inner.items[i].fields[j].value) {
        .keywords => |ks| ks,
        else => {
            len.* = 0;
            return null;
        },
    };
    len.* = ks[k].len;
    return ks[k].ptr;
}

/// int and time fields.
export fn vtx_result_field_int(r: *const CResults, i: usize, j: usize) i64 {
    return switch (r.inner.items[i].fields[j].value) {
        .int, .time => |x| x,
        else => 0,
    };
}

export fn vtx_result_field_float(r: *const CResults, i: usize, j: usize) f64 {
    return switch (r.inner.items[i].fields[j].value) {
        .float => |x| x,
        else => 0,
    };
}

export fn vtx_result_field_bool(r: *const CResults, i: usize, j: usize) c_int {
    return switch (r.inner.items[i].fields[j].value) {
        .bool => |x| @intFromBool(x),
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Tests: drive the API the way a C caller would.

const testing = std.testing;

test "C API end to end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = path_buf[0..try tmp.dir.realPath(threaded.io(), &path_buf)];
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/db", .{base}, 0);
    defer gpa.free(path);

    var h: ?*Handle = null;
    try testing.expectEqual(OK, vtx_open(path, null, &h));
    var second: ?*Handle = null;
    try testing.expectEqual(E_LOCKED, vtx_open(path, null, &second));
    try testing.expect(std.mem.indexOf(u8, std.mem.span(vtx_last_error()), "Locked") != null);

    const s = vtx_schema_new().?;
    defer vtx_schema_free(s);
    try testing.expectEqual(OK, vtx_schema_vector(s, 2, 0, 0, 0, 0, "test-model"));
    try testing.expectEqual(OK, vtx_schema_field(s, "body", 0));
    try testing.expectEqual(OK, vtx_schema_field(s, "tags", 2));
    try testing.expectEqual(OK, vtx_schema_field(s, "v", 3));
    try testing.expectEqual(OK, vtx_create_collection(h.?, "mem", s));
    try testing.expectEqual(E_EXISTS, vtx_create_collection(h.?, "mem", s));

    const b = vtx_batch_new().?;
    defer vtx_batch_free(b);
    const docs = [_]struct { id: []const u8, body: []const u8, tag: []const u8, v: i64, vec: [2]f32 }{
        .{ .id = "e1", .body = "metro cannot resolve module", .tag = "expo", .v = 52, .vec = .{ 1, 0 } },
        .{ .id = "e2", .body = "zig build fails on macos", .tag = "zig", .v = 15, .vec = .{ 0, 1 } },
    };
    for (docs) |d| {
        try testing.expectEqual(OK, vtx_batch_put(b, "mem", d.id.ptr, d.id.len));
        try testing.expectEqual(OK, vtx_batch_vector(b, &d.vec, 2));
        try testing.expectEqual(OK, vtx_batch_text(b, "body", d.body.ptr, d.body.len));
        const strs = [_][*]const u8{d.tag.ptr};
        const lens = [_]usize{d.tag.len};
        try testing.expectEqual(OK, vtx_batch_keywords(b, "tags", &strs, &lens, 1));
        try testing.expectEqual(OK, vtx_batch_int(b, "v", d.v));
        try testing.expectEqual(OK, vtx_batch_payload(b, d.body.ptr, d.body.len));
    }
    var seq: u64 = 0;
    try testing.expectEqual(OK, vtx_write(h.?, b, &seq));
    try testing.expectEqual(@as(u64, 2), seq);

    vtx_batch_reset(b);
    try testing.expectEqual(OK, vtx_batch_put(b, "mem", "bad", 3));
    try testing.expectEqual(OK, vtx_batch_vector(b, &[_]f32{ 1, 2, 3 }, 3));
    try testing.expectEqual(E_INVALID, vtx_write(h.?, b, null));

    const q = vtx_query_new("mem", 5).?;
    defer vtx_query_free(q);
    try testing.expectEqual(OK, vtx_query_vector(q, &[_]f32{ 0.9, 0.1 }, 2));
    try testing.expectEqual(OK, vtx_query_text(q, "metro module", 12));
    const f = vtx_filter_and(
        vtx_filter_eq_keyword("tags", "expo", 4),
        vtx_filter_range_int("v", 50, 0, has_lo | lo_inclusive),
    );
    try testing.expectEqual(OK, vtx_query_filter(q, f));
    try testing.expectEqual(OK, vtx_query_return_field(q, "v"));
    var res: ?*CResults = null;
    try testing.expectEqual(OK, vtx_search(h.?, q, &res));
    defer vtx_results_free(res);
    try testing.expectEqual(@as(usize, 1), vtx_results_len(res.?));
    var len: usize = 0;
    try testing.expectEqualStrings("e1", vtx_result_id(res.?, 0, &len)[0..len]);
    var ex: Explain = undefined;
    vtx_result_explain(res.?, 0, &ex);
    try testing.expectEqual(@as(u32, 1), ex.vector_rank);
    try testing.expectEqual(@as(u32, 1), ex.text_rank);
    try testing.expectEqual(@as(i64, 52), vtx_result_field_int(res.?, 0, 0));
    try testing.expect(vtx_result_payload(res.?, 0, &len) != null);

    var got: ?*CResults = null;
    try testing.expectEqual(OK, vtx_get(h.?, "mem", "e2", 2, &got));
    defer vtx_results_free(got);
    try testing.expectEqual(@as(usize, 3), vtx_result_fields(got.?, 0));
    try testing.expectEqual(@as(usize, 1), vtx_result_field_count(got.?, 0, 1));

    var count: u32 = 0;
    try testing.expectEqual(OK, vtx_count(h.?, "mem", &count));
    try testing.expectEqual(@as(u32, 2), count);
    var names: ?*Names = null;
    try testing.expectEqual(OK, vtx_collections(h.?, &names));
    try testing.expectEqualStrings("mem", std.mem.span(vtx_names_get(names.?, 0)));
    vtx_names_free(names);

    try testing.expectEqual(OK, vtx_close(h));
    try testing.expectEqual(OK, vtx_open(path, null, &h));
    try testing.expectEqual(OK, vtx_count(h.?, "mem", &count));
    try testing.expectEqual(@as(u32, 2), count);
    var st: Stats = undefined;
    vtx_stats(h.?, &st);
    try testing.expectEqual(@as(u64, 2), st.documents);
    try testing.expectEqual(OK, vtx_close(h));
}
