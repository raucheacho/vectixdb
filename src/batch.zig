//! A batch of writes, applied atomically, and its encoding in the log.

const std = @import("std");
const Allocator = std.mem.Allocator;
const codec = @import("codec.zig");
const schema = @import("schema.zig");

const Schema = schema.Schema;
const Doc = schema.Doc;
const Value = schema.Value;

pub const Op = union(enum) {
    create: struct { name: []const u8, schema: Schema },
    drop: []const u8,
    put: struct { collection: []const u8, doc: Doc },
    delete: struct { collection: []const u8, id: []const u8 },
};

pub const max_ops = 1 << 20;

pub fn encode(w: *codec.Writer, ops: []const Op) !void {
    try w.int(u32, @intCast(ops.len));
    for (ops) |op| {
        try w.int(u8, @intFromEnum(std.meta.activeTag(op)));
        switch (op) {
            .create => |c| {
                try w.blob(c.name);
                try c.schema.serialize(w);
            },
            .drop => |name| try w.blob(name),
            .put => |p| {
                try w.blob(p.collection);
                try encodeDoc(w, p.doc);
            },
            .delete => |d| {
                try w.blob(d.collection);
                try w.blob(d.id);
            },
        }
    }
}

fn encodeDoc(w: *codec.Writer, d: Doc) !void {
    try w.blob(d.id);
    if (d.vector) |v| {
        try w.varint(v.len);
        try w.f32s(v);
    } else try w.varint(0);
    if (d.payload) |p| {
        try w.int(u8, 1);
        try w.blob(p);
    } else try w.int(u8, 0);
    try w.varint(d.fields.len);
    for (d.fields) |fv| {
        try w.blob(fv.field);
        try w.int(u8, @intFromEnum(std.meta.activeTag(fv.value)));
        switch (fv.value) {
            .text, .keyword => |s| try w.blob(s),
            .keywords => |ks| {
                try w.varint(ks.len);
                for (ks) |k| try w.blob(k);
            },
            .int, .time => |x| try w.int(i64, x),
            .float => |x| try w.int(u64, @bitCast(x)),
            .bool => |x| try w.int(u8, @intFromBool(x)),
        }
    }
}

/// Decodes a batch. Strings borrow from `data`; everything else (op list,
/// vectors, field lists) is allocated in `arena`.
pub fn decode(arena: Allocator, data: []const u8) ![]Op {
    var r: codec.Reader = .{ .data = data };
    const n = try r.int(u32);
    if (n > max_ops or n > data.len) return error.Corrupt;
    const ops = try arena.alloc(Op, n);
    for (ops) |*op| {
        const tag = try r.int(u8);
        op.* = switch (tag) {
            0 => .{ .create = .{ .name = try r.blob(), .schema = try Schema.deserialize(arena, &r) } },
            1 => .{ .drop = try r.blob() },
            2 => .{ .put = .{ .collection = try r.blob(), .doc = try decodeDoc(arena, &r) } },
            3 => .{ .delete = .{ .collection = try r.blob(), .id = try r.blob() } },
            else => return error.Corrupt,
        };
    }
    if (!r.done()) return error.Corrupt;
    return ops;
}

fn decodeDoc(arena: Allocator, r: *codec.Reader) !Doc {
    var d: Doc = .{ .id = try r.blob() };
    const dim = try r.varint();
    if (dim > schema.limits.max_dim) return error.Corrupt;
    if (dim > 0) {
        const v = try arena.alloc(f32, @intCast(dim));
        for (v) |*x| x.* = try r.float();
        d.vector = v;
    }
    const has_payload = try r.int(u8);
    if (has_payload > 1) return error.Corrupt;
    if (has_payload == 1) d.payload = try r.blob();
    const nf = try r.varint();
    if (nf > schema.limits.max_fields) return error.Corrupt;
    const fields = try arena.alloc(schema.FieldValue, @intCast(nf));
    for (fields) |*fv| {
        const name = try r.blob();
        const t = try r.int(u8);
        const value: Value = switch (t) {
            0 => .{ .text = try r.blob() },
            1 => .{ .keyword = try r.blob() },
            2 => blk: {
                const m = try r.varint();
                if (m > schema.limits.max_keywords) return error.Corrupt;
                const ks = try arena.alloc([]const u8, @intCast(m));
                for (ks) |*k| k.* = try r.blob();
                break :blk .{ .keywords = ks };
            },
            3 => .{ .int = try r.int(i64) },
            4 => .{ .float = @bitCast(try r.int(u64)) },
            5 => .{ .bool = switch (try r.int(u8)) {
                0 => false,
                1 => true,
                else => return error.Corrupt,
            } },
            6 => .{ .time = try r.int(i64) },
            else => return error.Corrupt,
        };
        fv.* = .{ .field = name, .value = value };
    }
    d.fields = fields;
    return d;
}

test "encode / decode round trip" {
    const gpa = std.testing.allocator;
    const s: Schema = .{ .vector = .{ .dim = 2 }, .fields = &.{.{ .name = "t", .type = .keywords }} };
    const ops = [_]Op{
        .{ .create = .{ .name = "c", .schema = s } },
        .{ .put = .{ .collection = "c", .doc = .{
            .id = "x",
            .vector = &.{ 1, 2 },
            .payload = "p",
            .fields = &.{
                .{ .field = "t", .value = .{ .keywords = &.{ "a", "b" } } },
                .{ .field = "n", .value = .{ .float = -0.5 } },
                .{ .field = "b", .value = .{ .bool = true } },
            },
        } } },
        .{ .delete = .{ .collection = "c", .id = "y" } },
        .{ .drop = "old" },
    };
    var w = codec.Writer.init(gpa);
    defer w.deinit();
    try encode(&w, &ops);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const back = try decode(arena.allocator(), w.buf.items);
    try std.testing.expectEqual(@as(usize, 4), back.len);
    try std.testing.expect(back[0].create.schema.eql(s));
    const d = back[1].put.doc;
    try std.testing.expectEqualStrings("x", d.id);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, d.vector.?);
    try std.testing.expectEqualStrings("p", d.payload.?);
    try std.testing.expectEqualStrings("b", d.fields[0].value.keywords[1]);
    try std.testing.expectEqual(@as(f64, -0.5), d.fields[1].value.float);
    try std.testing.expectEqualStrings("y", back[2].delete.id);
    try std.testing.expectEqualStrings("old", back[3].drop);

    // Truncations never crash.
    for (0..w.buf.items.len) |cut| {
        if (decode(arena.allocator(), w.buf.items[0..cut])) |_| {} else |_| {}
    }
}
