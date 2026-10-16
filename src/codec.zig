//! Little-endian binary encoding used by the on-disk index formats.
//!
//! Every file is `magic(4) | version(u32) | body | crc32c(body)`. Writers grow
//! an in-memory buffer; readers work on a borrowed slice and fail with
//! `error.Corrupt` instead of reading out of bounds.

const std = @import("std");

pub const Error = error{ Corrupt, OutOfMemory };

const native_le = @import("builtin").cpu.arch.endian() == .little;

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.gpa);
    }

    pub fn bytes(w: *Writer, b: []const u8) !void {
        try w.buf.appendSlice(w.gpa, b);
    }

    pub fn int(w: *Writer, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try w.bytes(&tmp);
    }

    pub fn float(w: *Writer, v: f32) !void {
        try w.int(u32, @bitCast(v));
    }

    pub fn varint(w: *Writer, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) {
            try w.buf.append(w.gpa, @as(u8, @truncate(x)) | 0x80);
        }
        try w.buf.append(w.gpa, @truncate(x));
    }

    pub fn blob(w: *Writer, b: []const u8) !void {
        try w.varint(b.len);
        try w.bytes(b);
    }

    pub fn f32s(w: *Writer, v: []const f32) !void {
        if (native_le) return w.bytes(std.mem.sliceAsBytes(v));
        for (v) |x| try w.float(x);
    }

    /// Appends the CRC32 of everything after the 8-byte header.
    pub fn finish(w: *Writer) !void {
        const crc = @import("crc32c.zig").hash(w.buf.items[8..]);
        try w.int(u32, crc);
    }
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    /// Validates magic, version and checksum, and positions the reader on the body.
    pub fn open(data: []const u8, magic: *const [4]u8, version: u32) Error!Reader {
        if (data.len < 12) return error.Corrupt;
        if (!std.mem.eql(u8, data[0..4], magic)) return error.Corrupt;
        if (std.mem.readInt(u32, data[4..8], .little) != version) return error.Corrupt;
        const body = data[8 .. data.len - 4];
        const want = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        if (@import("crc32c.zig").hash(body) != want) return error.Corrupt;
        return .{ .data = data[0 .. data.len - 4], .pos = 8 };
    }

    pub fn take(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.data.len - r.pos) return error.Corrupt;
        const s = r.data[r.pos..][0..n];
        r.pos += n;
        return s;
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const s = try r.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    pub fn float(r: *Reader) Error!f32 {
        return @bitCast(try r.int(u32));
    }

    /// Reads `out.len` floats.
    pub fn f32s(r: *Reader, out: []f32) Error!void {
        const bytes = try r.take(out.len * 4);
        if (native_le) {
            @memcpy(std.mem.sliceAsBytes(out), bytes);
            return;
        }
        for (out, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
    }

    pub fn varint(r: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = (try r.take(1))[0];
            if (shift >= 64) return error.Corrupt;
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return result;
            shift += 7;
        }
    }

    pub fn blob(r: *Reader) Error![]const u8 {
        const n = try r.varint();
        if (n > r.data.len - r.pos) return error.Corrupt;
        return r.take(@intCast(n));
    }

    pub fn done(r: *const Reader) bool {
        return r.pos == r.data.len;
    }
};

pub fn header(w: *Writer, magic: *const [4]u8, version: u32) !void {
    try w.bytes(magic);
    try w.int(u32, version);
}

test "round trip with checksum" {
    const gpa = std.testing.allocator;
    var w = Writer.init(gpa);
    defer w.deinit();
    try header(&w, "TEST", 3);
    try w.varint(300);
    try w.blob("hello");
    try w.float(1.5);
    try w.finish();

    var r = try Reader.open(w.buf.items, "TEST", 3);
    try std.testing.expectEqual(@as(u64, 300), try r.varint());
    try std.testing.expectEqualStrings("hello", try r.blob());
    try std.testing.expectEqual(@as(f32, 1.5), try r.float());
    try std.testing.expect(r.done());

    w.buf.items[9] ^= 0xff;
    try std.testing.expectError(error.Corrupt, Reader.open(w.buf.items, "TEST", 3));
}
