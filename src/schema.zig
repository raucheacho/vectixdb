//! Collection schema, document values and their validation.

const std = @import("std");
const codec = @import("codec.zig");
const distance = @import("distance.zig");
const bm25 = @import("bm25.zig");

pub const Metric = distance.Metric;

pub const limits = struct {
    pub const max_fields = 64;
    pub const max_name_len = 64;
    pub const max_id_len = 512;
    pub const max_dim = 4096;
    pub const max_text_len = 16 << 20;
    pub const max_payload_len = 16 << 20;
    pub const max_keywords = 1024;
    pub const max_keyword_len = 1024;
    pub const max_tag_len = 256;
};

pub const FieldType = enum(u8) {
    /// Full text: indexed with BM25 and searchable by exact substring.
    text,
    /// One exact string, filterable with eq / in.
    keyword,
    /// A list of exact strings; eq / in match if any element matches.
    keywords,
    int,
    float,
    bool,
    /// Milliseconds since the Unix epoch.
    time,
};

pub const Field = struct {
    name: []const u8,
    type: FieldType,
};

pub const VectorSpec = struct {
    dim: u32,
    metric: Metric = .cosine,
    quantized: bool = false,
    m: u32 = 16,
    ef_construction: u32 = 200,
    /// Free label, e.g. the embedding model that produced the vectors.
    tag: []const u8 = "",
};

pub const Error = error{ InvalidSchema, InvalidDocument, OutOfMemory };

pub const Schema = struct {
    vector: ?VectorSpec = null,
    fields: []const Field = &.{},
    bm25: bm25.Params = .{},

    pub fn validate(s: Schema) Error!void {
        if (s.vector) |v| {
            if (v.dim == 0 or v.dim > limits.max_dim) return error.InvalidSchema;
            if (v.m < 2 or v.m > 256 or v.ef_construction == 0 or v.ef_construction > 4096) return error.InvalidSchema;
            if (v.quantized and v.metric != .cosine) return error.InvalidSchema;
            if (v.tag.len > limits.max_tag_len) return error.InvalidSchema;
        }
        if (s.fields.len > limits.max_fields) return error.InvalidSchema;
        for (s.fields, 0..) |f, i| {
            if (!validName(f.name)) return error.InvalidSchema;
            for (s.fields[0..i]) |g| if (std.mem.eql(u8, f.name, g.name)) return error.InvalidSchema;
        }
        if (!(s.bm25.k1 >= 0 and s.bm25.k1 <= 10 and s.bm25.b >= 0 and s.bm25.b <= 1)) return error.InvalidSchema;
    }

    pub fn fieldIndex(s: Schema, name: []const u8) ?u16 {
        for (s.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, name)) return @intCast(i);
        return null;
    }

    /// Deep copy owned by `gpa`; free with `deinit`.
    pub fn clone(s: Schema, gpa: std.mem.Allocator) Error!Schema {
        var out: Schema = .{ .bm25 = s.bm25 };
        errdefer out.deinit(gpa);
        if (s.vector) |v| {
            var vc = v;
            vc.tag = try gpa.dupe(u8, v.tag);
            out.vector = vc;
        }
        const fields = try gpa.alloc(Field, s.fields.len);
        for (fields) |*f| f.* = .{ .name = "", .type = .text };
        out.fields = fields;
        for (s.fields, fields) |src, *dst| dst.* = .{ .name = try gpa.dupe(u8, src.name), .type = src.type };
        return out;
    }

    pub fn deinit(s: *Schema, gpa: std.mem.Allocator) void {
        if (s.vector) |v| gpa.free(v.tag);
        for (s.fields) |f| gpa.free(f.name);
        gpa.free(s.fields);
        s.* = undefined;
    }

    pub fn eql(a: Schema, b: Schema) bool {
        if ((a.vector == null) != (b.vector == null)) return false;
        if (a.vector) |va| {
            const vb = b.vector.?;
            if (va.dim != vb.dim or va.metric != vb.metric or va.quantized != vb.quantized or va.m != vb.m or
                va.ef_construction != vb.ef_construction or !std.mem.eql(u8, va.tag, vb.tag)) return false;
        }
        if (a.fields.len != b.fields.len) return false;
        for (a.fields, b.fields) |x, y| if (x.type != y.type or !std.mem.eql(u8, x.name, y.name)) return false;
        return a.bm25.k1 == b.bm25.k1 and a.bm25.b == b.bm25.b;
    }

    pub fn serialize(s: Schema, w: *codec.Writer) !void {
        if (s.vector) |v| {
            try w.int(u8, 1);
            try w.int(u32, v.dim);
            try w.int(u8, @intCast(@intFromEnum(v.metric)));
            try w.int(u8, @intFromBool(v.quantized));
            try w.int(u32, v.m);
            try w.int(u32, v.ef_construction);
            try w.blob(v.tag);
        } else try w.int(u8, 0);
        try w.int(u16, @intCast(s.fields.len));
        for (s.fields) |f| {
            try w.blob(f.name);
            try w.int(u8, @intFromEnum(f.type));
        }
        try w.float(s.bm25.k1);
        try w.float(s.bm25.b);
    }

    /// Reads a schema; slices borrow from the reader's buffer except
    /// `fields`, allocated with `gpa` (free with `gpa.free(s.fields)`), unless
    /// cloned.
    pub fn deserialize(gpa: std.mem.Allocator, r: *codec.Reader) !Schema {
        var s: Schema = .{};
        const has_vector = try r.int(u8);
        if (has_vector > 1) return error.Corrupt;
        if (has_vector == 1) {
            const dim = try r.int(u32);
            const metric = try r.int(u8);
            if (metric > 2) return error.Corrupt;
            const quantized = try r.int(u8);
            s.vector = .{
                .dim = dim,
                .metric = @enumFromInt(metric),
                .quantized = quantized != 0,
                .m = try r.int(u32),
                .ef_construction = try r.int(u32),
                .tag = try r.blob(),
            };
        }
        const n = try r.int(u16);
        if (n > limits.max_fields) return error.Corrupt;
        const fields = try gpa.alloc(Field, n);
        errdefer gpa.free(fields);
        for (fields) |*f| {
            const name = try r.blob();
            const t = try r.int(u8);
            if (t > @intFromEnum(FieldType.time)) return error.Corrupt;
            f.* = .{ .name = name, .type = @enumFromInt(t) };
        }
        s.fields = fields;
        s.bm25 = .{ .k1 = try r.float(), .b = try r.float() };
        s.validate() catch return error.Corrupt;
        return s;
    }
};

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > limits.max_name_len) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return false;
    return true;
}

pub const Value = union(FieldType) {
    text: []const u8,
    keyword: []const u8,
    keywords: []const []const u8,
    int: i64,
    float: f64,
    bool: bool,
    time: i64,
};

pub const FieldValue = struct {
    field: []const u8,
    value: Value,
};

pub const Doc = struct {
    id: []const u8,
    vector: ?[]const f32 = null,
    fields: []const FieldValue = &.{},
    payload: ?[]const u8 = null,

    /// Checks the document against the schema without changing anything.
    pub fn validate(d: Doc, s: Schema) Error!void {
        if (d.id.len == 0 or d.id.len > limits.max_id_len) return error.InvalidDocument;
        if (d.vector) |v| {
            const spec = s.vector orelse return error.InvalidDocument;
            if (v.len != spec.dim) return error.InvalidDocument;
            var norm: f32 = 0;
            for (v) |x| {
                if (!std.math.isFinite(x)) return error.InvalidDocument;
                norm += x * x;
            }
            if (spec.metric == .cosine and norm == 0) return error.InvalidDocument;
        }
        if (d.payload) |p| if (p.len > limits.max_payload_len) return error.InvalidDocument;
        for (d.fields, 0..) |fv, i| {
            const idx = s.fieldIndex(fv.field) orelse return error.InvalidDocument;
            for (d.fields[0..i]) |prev| if (std.mem.eql(u8, prev.field, fv.field)) return error.InvalidDocument;
            if (std.meta.activeTag(fv.value) != s.fields[idx].type) return error.InvalidDocument;
            switch (fv.value) {
                .text => |t| if (t.len > limits.max_text_len) return error.InvalidDocument,
                .keyword => |k| if (k.len > limits.max_keyword_len) return error.InvalidDocument,
                .keywords => |ks| {
                    if (ks.len > limits.max_keywords) return error.InvalidDocument;
                    for (ks) |k| if (k.len > limits.max_keyword_len) return error.InvalidDocument;
                },
                .float => |f| if (!std.math.isFinite(f)) return error.InvalidDocument,
                .int, .bool, .time => {},
            }
        }
    }
};

test "schema validation and round trip" {
    const gpa = std.testing.allocator;
    const s: Schema = .{
        .vector = .{ .dim = 4, .tag = "e5-small" },
        .fields = &.{ .{ .name = "body", .type = .text }, .{ .name = "lang", .type = .keyword } },
    };
    try s.validate();
    try std.testing.expectError(error.InvalidSchema, (Schema{ .fields = &.{ .{ .name = "a", .type = .int }, .{ .name = "a", .type = .int } } }).validate());
    try std.testing.expectError(error.InvalidSchema, (Schema{ .fields = &.{.{ .name = "a b", .type = .int }} }).validate());
    try std.testing.expectError(error.InvalidSchema, (Schema{ .vector = .{ .dim = 4, .metric = .l2, .quantized = true } }).validate());

    var w = codec.Writer.init(gpa);
    defer w.deinit();
    try s.serialize(&w);
    var r: codec.Reader = .{ .data = w.buf.items };
    const back = try Schema.deserialize(gpa, &r);
    defer gpa.free(back.fields);
    try std.testing.expect(s.eql(back));

    var owned = try back.clone(gpa);
    defer owned.deinit(gpa);
    try std.testing.expect(s.eql(owned));
}

test "document validation" {
    const s: Schema = .{
        .vector = .{ .dim = 2 },
        .fields = &.{ .{ .name = "n", .type = .float }, .{ .name = "tags", .type = .keywords } },
    };
    try (Doc{ .id = "a", .vector = &.{ 1, 0 }, .fields = &.{.{ .field = "n", .value = .{ .float = 1.5 } }} }).validate(s);
    try (Doc{ .id = "no-vector" }).validate(s);
    const bad = [_]Doc{
        .{ .id = "" },
        .{ .id = "a", .vector = &.{1} },
        .{ .id = "a", .vector = &.{ 0, 0 } },
        .{ .id = "a", .vector = &.{ std.math.nan(f32), 0 } },
        .{ .id = "a", .fields = &.{.{ .field = "n", .value = .{ .int = 1 } }} },
        .{ .id = "a", .fields = &.{.{ .field = "n", .value = .{ .float = std.math.inf(f64) } }} },
        .{ .id = "a", .fields = &.{.{ .field = "missing", .value = .{ .int = 1 } }} },
        .{ .id = "a", .fields = &.{ .{ .field = "n", .value = .{ .float = 1 } }, .{ .field = "n", .value = .{ .float = 2 } } } },
    };
    for (bad) |d| try std.testing.expectError(error.InvalidDocument, d.validate(s));
}
