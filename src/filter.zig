//! Typed metadata filters. Values keep their type from the caller to the
//! engine (no text round trip), so bounds compare exactly.

const std = @import("std");
const schema = @import("schema.zig");
const Value = schema.Value;
const Schema = schema.Schema;

pub const max_depth = 32;
pub const max_nodes = 1024;

pub const Bound = struct {
    value: Value,
    inclusive: bool = true,
};

pub const Filter = union(enum) {
    /// keyword: equal; keywords: contains; int, float, bool, time: equal.
    eq: struct { field: []const u8, value: Value },
    /// Like `eq` with any of the values.
    in: struct { field: []const u8, values: []const Value },
    /// int, float, time. A missing bound is open.
    range: struct { field: []const u8, lo: ?Bound = null, hi: ?Bound = null },
    /// The document has a value for the field.
    exists: []const u8,
    /// Every sub-filter matches (an empty list matches everything).
    all: []const Filter,
    /// At least one sub-filter matches (an empty list matches nothing).
    any: []const Filter,
    /// Complement among live documents, including those without the field.
    not: *const Filter,

    pub const Error = error{InvalidFilter};

    pub fn validate(f: Filter, s: Schema) Error!void {
        var nodes: usize = 0;
        try f.check(s, 0, &nodes);
    }

    fn check(f: Filter, s: Schema, depth: usize, nodes: *usize) Error!void {
        nodes.* += 1;
        if (depth > max_depth or nodes.* > max_nodes) return error.InvalidFilter;
        switch (f) {
            .eq => |e| try checkValue(s, e.field, e.value),
            .in => |e| {
                if (e.values.len == 0 or e.values.len > max_nodes) return error.InvalidFilter;
                for (e.values) |v| try checkValue(s, e.field, v);
            },
            .range => |r| {
                const t = try fieldType(s, r.field);
                if (t != .int and t != .float and t != .time) return error.InvalidFilter;
                if (r.lo == null and r.hi == null) return error.InvalidFilter;
                if (r.lo) |b| try checkBound(t, b.value);
                if (r.hi) |b| try checkBound(t, b.value);
            },
            .exists => |name| _ = try fieldType(s, name),
            .all, .any => |subs| for (subs) |sub| try sub.check(s, depth + 1, nodes),
            .not => |sub| try sub.check(s, depth + 1, nodes),
        }
    }
};

fn fieldType(s: Schema, name: []const u8) Filter.Error!schema.FieldType {
    const idx = s.fieldIndex(name) orelse return error.InvalidFilter;
    return s.fields[idx].type;
}

fn checkValue(s: Schema, name: []const u8, v: Value) Filter.Error!void {
    const t = try fieldType(s, name);
    const ok = switch (t) {
        .text => false, // use the exact route
        .keyword, .keywords => v == .keyword,
        .int => v == .int,
        .float => v == .float and std.math.isFinite(v.float),
        .bool => v == .bool,
        .time => v == .time,
    };
    if (!ok) return error.InvalidFilter;
}

fn checkBound(t: schema.FieldType, v: Value) Filter.Error!void {
    const ok = switch (t) {
        .int => v == .int,
        .time => v == .time,
        .float => v == .float and !std.math.isNan(v.float),
        else => false,
    };
    if (!ok) return error.InvalidFilter;
}

test "validation" {
    const s: Schema = .{ .fields = &.{
        .{ .name = "lang", .type = .keyword },
        .{ .name = "n", .type = .int },
        .{ .name = "x", .type = .float },
        .{ .name = "body", .type = .text },
    } };
    const ok = Filter{ .all = &.{
        .{ .eq = .{ .field = "lang", .value = .{ .keyword = "fr" } } },
        .{ .range = .{ .field = "n", .lo = .{ .value = .{ .int = 1 }, .inclusive = false } } },
        .{ .not = &.{ .exists = "x" } },
    } };
    try ok.validate(s);
    const bad = [_]Filter{
        .{ .eq = .{ .field = "missing", .value = .{ .int = 1 } } },
        .{ .eq = .{ .field = "n", .value = .{ .float = 1 } } }, // no silent conversion
        .{ .eq = .{ .field = "body", .value = .{ .keyword = "x" } } },
        .{ .range = .{ .field = "lang", .lo = .{ .value = .{ .int = 1 } } } },
        .{ .range = .{ .field = "x" } },
        .{ .in = .{ .field = "n", .values = &.{} } },
    };
    for (bad) |f| try std.testing.expectError(error.InvalidFilter, f.validate(s));
}
