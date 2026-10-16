//! SIMD distance kernels.
//!
//! All kernels work on any length: the bulk is processed in `lanes`-wide
//! vectors and the tail with a scalar loop.

const std = @import("std");

pub const Metric = enum(u32) {
    cosine = 0,
    l2 = 1,
    dot = 2,
};

const lanes = std.simd.suggestVectorLength(f32) orelse 8;
const F32xN = @Vector(lanes, f32);

const i8_lanes = 16;
const I8xN = @Vector(i8_lanes, i8);
const I32xN = @Vector(i8_lanes, i32);

pub fn dot(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var acc: F32xN = @splat(0);
    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: F32xN = a[i..][0..lanes].*;
        const vb: F32xN = b[i..][0..lanes].*;
        acc += va * vb;
    }
    var sum = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) sum += a[i] * b[i];
    return sum;
}

pub fn l2sq(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var acc: F32xN = @splat(0);
    var i: usize = 0;
    while (i + lanes <= a.len) : (i += lanes) {
        const va: F32xN = a[i..][0..lanes].*;
        const vb: F32xN = b[i..][0..lanes].*;
        const d = va - vb;
        acc += d * d;
    }
    var sum = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) {
        const d = a[i] - b[i];
        sum += d * d;
    }
    return sum;
}

/// Integer dot product with 32-bit accumulation.
pub fn dotI8(a: []const i8, b: []const i8) i32 {
    std.debug.assert(a.len == b.len);
    var acc: I32xN = @splat(0);
    var i: usize = 0;
    while (i + i8_lanes <= a.len) : (i += i8_lanes) {
        const va: I8xN = a[i..][0..i8_lanes].*;
        const vb: I8xN = b[i..][0..i8_lanes].*;
        acc += @as(I32xN, va) * @as(I32xN, vb);
    }
    var sum = @reduce(.Add, acc);
    while (i < a.len) : (i += 1) sum += @as(i32, a[i]) * @as(i32, b[i]);
    return sum;
}

/// Scales `v` to unit length in place. Zero vectors are left untouched.
pub fn normalize(v: []f32) void {
    const n = @sqrt(dot(v, v));
    if (n == 0) return;
    const inv = 1.0 / n;
    for (v) |*x| x.* *= inv;
}

/// Symmetric scalar quantization with a per-vector scale.
/// Returns the factor that maps codes back to floats (x ≈ code * factor).
pub fn quantize(src: []const f32, dst: []i8) f32 {
    std.debug.assert(src.len == dst.len);
    var max_abs: f32 = 0;
    for (src) |x| max_abs = @max(max_abs, @abs(x));
    if (max_abs == 0) {
        @memset(dst, 0);
        return 0;
    }
    const scale = 127.0 / max_abs;
    for (src, dst) |x, *q| {
        const r = @round(x * scale);
        q.* = @intFromFloat(std.math.clamp(r, -127.0, 127.0));
    }
    return max_abs / 127.0;
}

pub fn dequantize(src: []const i8, factor: f32, dst: []f32) void {
    for (src, dst) |q, *x| x.* = @as(f32, @floatFromInt(q)) * factor;
}

test "dot and l2 match scalar reference" {
    var a: [37]f32 = undefined;
    var b: [37]f32 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        const f: f32 = @floatFromInt(i);
        x.* = @sin(f);
        y.* = @cos(f * 0.5);
    }
    var ref_dot: f32 = 0;
    var ref_l2: f32 = 0;
    for (a, b) |x, y| {
        ref_dot += x * y;
        ref_l2 += (x - y) * (x - y);
    }
    try std.testing.expectApproxEqAbs(ref_dot, dot(&a, &b), 1e-4);
    try std.testing.expectApproxEqAbs(ref_l2, l2sq(&a, &b), 1e-4);
}

test "int8 dot handles tail" {
    var a: [21]i8 = undefined;
    var b: [21]i8 = undefined;
    var ref: i32 = 0;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @intCast(@as(i32, @intCast(i)) - 10);
        y.* = @intCast(@as(i32, @intCast(i * 3 % 17)) - 8);
        ref += @as(i32, x.*) * @as(i32, y.*);
    }
    try std.testing.expectEqual(ref, dotI8(&a, &b));
}

test "quantize round trip" {
    var v = [_]f32{ 0.5, -0.25, 0.125, -1.0, 0.0 };
    var q: [5]i8 = undefined;
    const f = quantize(&v, &q);
    var back: [5]f32 = undefined;
    dequantize(&q, f, &back);
    for (v, back) |x, y| try std.testing.expectApproxEqAbs(x, y, 0.01);
}
