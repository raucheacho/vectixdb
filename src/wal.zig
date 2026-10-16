//! Write-ahead log: the source of truth for every write since the last
//! checkpoint. A sequence of files `wal-<first_seq>.log`, each with a header,
//! then records:
//!
//!   file header (24 B): "VTXW" | version u16 | 0 u16 | first_seq u64 | crc32c u32 | 0 u32
//!   record           : len u32 | seq u64 | synced u64 | crc32c(header, payload) u32 | payload
//!
//! `synced` is the last sequence number known durable (fsync returned) when
//! the record was written. Sequence numbers are contiguous across files.
//! Recovery replays records after the checkpoint and stops at the first
//! invalid one, at sequence number s:
//! - if no valid record after it claims `synced >= s`, record s was never
//!   acknowledged as durable: it and everything after it are an unsynced
//!   tail (possibly persisted out of order), cut off before the log is
//!   appended to again;
//! - otherwise durable data was damaged and opening fails with
//!   `error.Corrupt` (unless `repair` is set, which drops everything from
//!   that point on).
//! A file is created under a temporary name and renamed once its header is
//! durable, so a crash never leaves a log without a header.

const std = @import("std");
const fsmod = @import("fs.zig");
const Fs = fsmod.Fs;
const Handle = fsmod.Handle;
const Allocator = std.mem.Allocator;
const Crc = @import("crc32c.zig").Crc;
const crcHash = @import("crc32c.zig").hash;

pub const magic = "VTXW";
pub const format_version: u16 = 1;
pub const file_header_len = 24;
pub const record_header_len = 24;

pub const Error = fsmod.Error || error{ Corrupt, Poisoned, ReadOnly, RecordTooLarge };

pub const Options = struct {
    writable: bool = true,
    /// Start a new file once the current one reaches this size.
    segment_size: u64 = 64 << 20,
    /// Largest payload accepted, checked on append and on replay.
    max_record: u32 = 64 << 20,
    /// Drop corrupted records and everything after them instead of failing.
    repair: bool = false,
};

pub const Wal = struct {
    gpa: Allocator,
    fs: Fs,
    opts: Options,
    /// First sequence number of each file, ascending.
    files: std.ArrayList(u64) = .empty,
    /// Open handle on the last file, if appending to it is allowed.
    handle: ?Handle = null,
    offset: u64 = 0,
    next_seq: u64,
    /// Last sequence number known durable.
    synced_seq: u64 = 0,
    /// Set after a failed sync or an unrecoverable write error: the state of
    /// the file is unknown, so every later write is refused.
    poisoned: bool = false,
    scratch: std.ArrayList(u8) = .empty,

    /// Opens the log and calls `ctx.apply(seq: u64, payload: []const u8)` for
    /// every record with `seq > after_seq`, in order.
    pub fn open(gpa: Allocator, fs: Fs, opts: Options, after_seq: u64, ctx: anytype) !Wal {
        var self: Wal = .{ .gpa = gpa, .fs = fs, .opts = opts, .next_seq = after_seq + 1 };
        errdefer self.deinit();

        const names = try fs.list(gpa);
        defer fsmod.freeList(gpa, names);
        for (names) |name| {
            if (parseName(name)) |first| {
                try self.files.append(gpa, first);
            } else if (opts.writable and isTempName(name)) {
                try fs.remove(name); // never referenced
            }
        }
        std.mem.sort(u64, self.files.items, {}, std.sort.asc(u64));

        var expected: ?u64 = null;
        var tail_end: u64 = 0;
        var i: usize = 0;
        while (i < self.files.items.len) : (i += 1) {
            const first = self.files.items[i];
            const last = i + 1 == self.files.items.len;
            // A file followed by one that starts within the checkpoint holds
            // only checkpointed records: not needed, and its neighbors may
            // already be deleted (removals are not ordered before a crash).
            // It stays listed so that `removeUpTo` deletes it.
            if (!last and self.files.items[i + 1] <= after_seq + 1) continue;
            var name_buf: [32]u8 = undefined;
            const name = fileName(&name_buf, first);
            const data = try fs.readAll(gpa, name);
            defer gpa.free(data);

            if (expected) |e| {
                if (first != e) return error.Corrupt; // gap or overlap between files
            } else if (first > after_seq + 1) {
                return error.Corrupt; // records between the checkpoint and the log are missing
            }

            if (!validHeader(data, first)) {
                if (last and data.len < file_header_len) {
                    // Defensive: files are renamed into place with a durable
                    // header, but an empty file holds no record either way.
                    if (opts.writable) {
                        try fs.remove(name);
                        try fs.syncDir();
                    }
                    _ = self.files.pop();
                    break;
                }
                if (!opts.repair) return error.Corrupt;
                try self.dropFrom(i);
                break;
            }

            var seq = first;
            var off: usize = file_header_len;
            while (off < data.len) {
                const rec = parseRecord(data[off..], seq, opts.max_record) orelse break;
                if (seq > after_seq) try ctx.apply(seq, rec.payload);
                seq += 1;
                off += record_header_len + rec.payload.len;
            }
            expected = seq;

            if (off < data.len) {
                const torn = last and !durableAfter(data, off, seq, opts.max_record);
                if (!torn and !opts.repair) return error.Corrupt;
                if (!last) try self.dropFrom(i + 1);
                tail_end = off;
                if (opts.writable) try self.cutFile(name, off);
                break;
            }
            tail_end = off;
        }

        if (expected) |e| {
            if (e > after_seq + 1) self.next_seq = e;
        }
        // Keep appending to the last file only if its sequence continues.
        if (opts.writable and self.files.items.len > 0 and expected != null and expected.? == self.next_seq) {
            var name_buf: [32]u8 = undefined;
            const name = fileName(&name_buf, self.files.items[self.files.items.len - 1]);
            self.handle = try fs.open(name, true);
            self.offset = tail_end;
            // What a crashed process wrote may still be only in the page
            // cache: make it durable before claiming it is.
            try fs.sync(self.handle.?);
        }
        self.synced_seq = self.next_seq - 1;
        return self;
    }

    pub fn deinit(self: *Wal) void {
        if (self.handle) |h| self.fs.close(h);
        self.files.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.* = undefined;
    }

    /// Sequence number of the last record appended or replayed (0 if none).
    pub fn lastSeq(self: *const Wal) u64 {
        return self.next_seq - 1;
    }

    /// Appends a record and returns its sequence number. The record is not
    /// durable until `sync` returns.
    pub fn append(self: *Wal, payload: []const u8) Error!u64 {
        if (self.poisoned) return error.Poisoned;
        if (!self.opts.writable) return error.ReadOnly;
        if (payload.len > self.opts.max_record) return error.RecordTooLarge;
        if (self.handle == null or self.offset >= self.opts.segment_size) try self.startFile();

        const seq = self.next_seq;
        const total = record_header_len + payload.len;
        self.scratch.clearRetainingCapacity();
        try self.scratch.ensureTotalCapacity(self.gpa, total);
        const buf = self.scratch.addManyAsSliceAssumeCapacity(total);
        std.mem.writeInt(u32, buf[0..4], @intCast(payload.len), .little);
        std.mem.writeInt(u64, buf[4..12], seq, .little);
        std.mem.writeInt(u64, buf[12..20], self.synced_seq, .little);
        @memcpy(buf[record_header_len..], payload);
        std.mem.writeInt(u32, buf[20..24], recordCrc(buf[0..20], payload), .little);

        self.fs.write(self.handle.?, buf, self.offset) catch |e| {
            // Undo a partial write so that the next record starts on a
            // record boundary; if that is impossible, stop writing.
            if (e == error.Crashed) {
                self.poisoned = true;
            } else {
                self.fs.truncate(self.handle.?, self.offset) catch {
                    self.poisoned = true;
                };
            }
            return e;
        };
        self.offset += total;
        self.next_seq += 1;
        return seq;
    }

    /// Makes every appended record durable.
    pub fn sync(self: *Wal) Error!void {
        if (self.poisoned) return error.Poisoned;
        const h = self.handle orelse return;
        self.fs.sync(h) catch |e| {
            self.poisoned = true;
            return e;
        };
        self.synced_seq = self.next_seq - 1;
    }

    /// Closes the current file after making it durable; the next append
    /// starts a new one. Used at checkpoints so that older files can go.
    pub fn rotate(self: *Wal) Error!void {
        if (self.poisoned) return error.Poisoned;
        const h = self.handle orelse return;
        self.fs.sync(h) catch |e| {
            self.poisoned = true;
            return e;
        };
        self.synced_seq = self.next_seq - 1;
        self.fs.close(h);
        self.handle = null;
    }

    /// Deletes the files whose records all have `seq <= upto` (they are
    /// covered by a durable checkpoint). The file being appended to is kept.
    pub fn removeUpTo(self: *Wal, upto: u64) Error!void {
        if (!self.opts.writable) return error.ReadOnly;
        var removed: usize = 0;
        while (removed < self.files.items.len) : (removed += 1) {
            const is_last = removed + 1 == self.files.items.len;
            const covered = if (is_last)
                self.handle == null and self.next_seq - 1 <= upto
            else
                self.files.items[removed + 1] <= upto + 1;
            if (!covered) break;
            var name_buf: [32]u8 = undefined;
            try self.fs.remove(fileName(&name_buf, self.files.items[removed]));
        }
        if (removed == 0) return;
        try self.fs.syncDir();
        self.files.replaceRangeAssumeCapacity(0, removed, &.{});
    }

    fn startFile(self: *Wal) Error!void {
        if (self.handle) |h| {
            // Files before the last one must be complete.
            self.fs.sync(h) catch |e| {
                self.poisoned = true;
                return e;
            };
            self.synced_seq = self.next_seq - 1;
            self.fs.close(h);
            self.handle = null;
        }
        const first = self.next_seq;
        var name_buf: [32]u8 = undefined;
        const name = fileName(&name_buf, first);
        var tmp_buf: [40]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch unreachable;

        var header: [file_header_len]u8 = @splat(0);
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u16, header[4..6], format_version, .little);
        std.mem.writeInt(u64, header[8..16], first, .little);
        std.mem.writeInt(u32, header[16..20], crcHash(header[0..16]), .little);

        try self.files.ensureUnusedCapacity(self.gpa, 1);
        const h = try self.fs.create(tmp);
        errdefer self.fs.close(h);
        try self.fs.write(h, &header, 0);
        try self.fs.sync(h);
        try self.fs.rename(tmp, name);
        try self.fs.syncDir();
        self.files.appendAssumeCapacity(first);
        self.handle = h;
        self.offset = file_header_len;
    }

    /// Removes the files from index `from` on (repair).
    fn dropFrom(self: *Wal, from: usize) Error!void {
        if (self.opts.writable) {
            for (self.files.items[from..]) |first| {
                var name_buf: [32]u8 = undefined;
                try self.fs.remove(fileName(&name_buf, first));
            }
            try self.fs.syncDir();
        }
        self.files.shrinkRetainingCapacity(from);
    }

    fn cutFile(self: *Wal, name: []const u8, size: u64) Error!void {
        const h = try self.fs.open(name, true);
        defer self.fs.close(h);
        try self.fs.truncate(h, size);
        try self.fs.sync(h);
    }
};

pub fn fileName(buf: *[32]u8, first_seq: u64) []const u8 {
    return std.fmt.bufPrint(buf, "wal-{d:0>20}.log", .{first_seq}) catch unreachable;
}

fn parseName(name: []const u8) ?u64 {
    if (name.len != 28 or !std.mem.startsWith(u8, name, "wal-") or !std.mem.endsWith(u8, name, ".log")) return null;
    return std.fmt.parseInt(u64, name[4..24], 10) catch null;
}

fn isTempName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "wal-") and std.mem.endsWith(u8, name, ".log.tmp");
}

fn validHeader(data: []const u8, first: u64) bool {
    if (data.len < file_header_len) return false;
    if (!std.mem.eql(u8, data[0..4], magic)) return false;
    if (std.mem.readInt(u16, data[4..6], .little) != format_version) return false;
    if (std.mem.readInt(u64, data[8..16], .little) != first) return false;
    return std.mem.readInt(u32, data[16..20], .little) == crcHash(data[0..16]);
}

fn recordCrc(head: *const [20]u8, payload: []const u8) u32 {
    var crc = Crc.init();
    crc.update(head);
    crc.update(payload);
    return crc.final();
}

const Record = struct { payload: []const u8, synced: u64 };

/// Returns the record at the start of `data` if it is complete, has sequence
/// number `seq` and a valid checksum.
fn parseRecord(data: []const u8, seq: u64, max_record: u32) ?Record {
    if (data.len < record_header_len) return null;
    const len = std.mem.readInt(u32, data[0..4], .little);
    if (len > max_record or len > data.len - record_header_len) return null;
    if (std.mem.readInt(u64, data[4..12], .little) != seq) return null;
    const synced = std.mem.readInt(u64, data[12..20], .little);
    if (synced >= seq) return null;
    const payload = data[record_header_len..][0..len];
    if (std.mem.readInt(u32, data[20..24], .little) != recordCrc(data[0..20], payload)) return null;
    return .{ .payload = payload, .synced = synced };
}

/// Whether a valid record after `from` says that sequence number `seq` had
/// been made durable: if so, the bad bytes at `from` are damaged durable
/// data, not an unsynced tail.
fn durableAfter(data: []const u8, from: usize, seq: u64, max_record: u32) bool {
    var off = from + 1;
    while (off + record_header_len <= data.len) : (off += 1) {
        const s = std.mem.readInt(u64, data[off + 4 ..][0..8], .little);
        if (s <= seq or s > seq + (1 << 32)) continue;
        const rec = parseRecord(data[off..], s, max_record) orelse continue;
        if (rec.synced >= seq) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const Collect = struct {
    gpa: Allocator,
    seqs: std.ArrayList(u64) = .empty,
    payloads: std.ArrayList([]u8) = .empty,

    fn apply(c: *Collect, seq: u64, payload: []const u8) !void {
        try c.seqs.append(c.gpa, seq);
        const copy = try c.gpa.dupe(u8, payload);
        errdefer c.gpa.free(copy);
        try c.payloads.append(c.gpa, copy);
    }

    fn deinit(c: *Collect) void {
        for (c.payloads.items) |p| c.gpa.free(p);
        c.payloads.deinit(c.gpa);
        c.seqs.deinit(c.gpa);
    }
};

fn payloadFor(buf: []u8, i: usize) []u8 {
    const n = 10 + (i * 37) % 90;
    for (buf[0..n], 0..) |*b, j| b.* = @truncate(i *% 31 +% j *% 7);
    return buf[0..n];
}

fn reopen(gpa: Allocator, fs: Fs, opts: Options, after: u64, c: *Collect) !Wal {
    return Wal.open(gpa, fs, opts, after, c);
}

test "append, reopen, replay" {
    var sim: fsmod.Sim = .init(testing.allocator, 1);
    defer sim.deinit();
    const fs = sim.fs();
    var buf: [128]u8 = undefined;
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        try testing.expectEqual(@as(usize, 0), c.seqs.items.len);
        for (0..50) |i| try testing.expectEqual(@as(u64, i + 1), try w.append(payloadFor(&buf, i)));
        try w.sync();
    }
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, .{}, 20, &c);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 30), c.seqs.items.len);
    try testing.expectEqual(@as(u64, 21), c.seqs.items[0]);
    try testing.expectEqualSlices(u8, payloadFor(&buf, 20), c.payloads.items[0]);
    try testing.expectEqual(@as(u64, 51), try w.append("next"));
}

test "rotation and removal of covered files" {
    var sim: fsmod.Sim = .init(testing.allocator, 2);
    defer sim.deinit();
    const fs = sim.fs();
    var buf: [128]u8 = undefined;
    const opts: Options = .{ .segment_size = 300 };
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, opts, 0, &c);
        defer w.deinit();
        for (0..40) |i| _ = try w.append(payloadFor(&buf, i));
        try w.sync();
        try testing.expect(w.files.items.len > 3);
        try w.removeUpTo(25);
        try testing.expect(w.files.items[0] <= 26);
        if (w.files.items.len > 1) try testing.expect(w.files.items[1] > 26);
    }
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, opts, 25, &c);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 15), c.seqs.items.len);
    try testing.expectEqual(@as(u64, 26), c.seqs.items[0]);
}

test "torn tail is cut before appending again" {
    var sim: fsmod.Sim = .init(testing.allocator, 3);
    defer sim.deinit();
    const fs = sim.fs();
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        _ = try w.append("one");
        _ = try w.append("two");
        try w.sync();
    }
    // Simulate a torn third record: garbage after the last valid one.
    var name_buf: [32]u8 = undefined;
    const h = try fs.open(fileName(&name_buf, 1), true);
    const end = try fs.len(h);
    try fs.write(h, &[_]u8{ 9, 0, 0, 0, 3, 0, 0 }, end);
    try fs.sync(h);
    fs.close(h);
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        try testing.expectEqual(@as(usize, 2), c.seqs.items.len);
        try testing.expectEqual(@as(u64, 3), try w.append("three"));
        try w.sync();
    }
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, .{}, 0, &c);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 3), c.seqs.items.len);
    try testing.expectEqualStrings("three", c.payloads.items[2]);
}

test "corruption before valid records fails unless repair" {
    var sim: fsmod.Sim = .init(testing.allocator, 4);
    defer sim.deinit();
    const fs = sim.fs();
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        for (0..5) |_| _ = try w.append("payload-bytes");
        try w.sync();
        // The next record records that the first five are durable.
        _ = try w.append("payload-bytes");
        try w.sync();
    }
    // Flip a byte inside the second record's payload.
    var name_buf: [32]u8 = undefined;
    const h = try fs.open(fileName(&name_buf, 1), true);
    try fs.write(h, "X", file_header_len + (record_header_len + 13) + record_header_len + 2);
    try fs.sync(h);
    fs.close(h);

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    try testing.expectError(error.Corrupt, reopen(testing.allocator, fs, .{}, 0, &c));

    var c2: Collect = .{ .gpa = testing.allocator };
    defer c2.deinit();
    var w = try reopen(testing.allocator, fs, .{ .repair = true }, 0, &c2);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), c2.seqs.items.len);
    try testing.expectEqual(@as(u64, 2), try w.append("after repair"));
}

test "unsynced records lost out of order are a tail, not corruption" {
    var sim: fsmod.Sim = .init(testing.allocator, 8);
    defer sim.deinit();
    const fs = sim.fs();
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        _ = try w.append("durable");
        try w.sync();
        for (0..4) |_| _ = try w.append("not-synced"); // seqs 2..5, synced = 1
    }
    // Record 3 never reached the disk, records 4 and 5 did.
    var name_buf: [32]u8 = undefined;
    const h = try fs.open(fileName(&name_buf, 1), true);
    const rec = record_header_len + 10;
    try fs.write(h, &([_]u8{0} ** rec), file_header_len + (record_header_len + 7) + rec);
    fs.close(h);

    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, .{}, 0, &c);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 2), c.seqs.items.len);
    try testing.expectEqual(@as(u64, 3), try w.append("next"));
}

test "oversized records are refused on append" {
    var sim: fsmod.Sim = .init(testing.allocator, 5);
    defer sim.deinit();
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, sim.fs(), .{ .max_record = 8 }, 0, &c);
    defer w.deinit();
    try testing.expectError(error.RecordTooLarge, w.append("123456789"));
    try testing.expectEqual(@as(u64, 1), try w.append("12345678"));
}

test "disk full leaves the log usable; failed sync poisons it" {
    var sim: fsmod.Sim = .init(testing.allocator, 6);
    defer sim.deinit();
    const fs = sim.fs();
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, .{}, 0, &c);
    defer w.deinit();
    _ = try w.append("first");
    sim.nospace_at = sim.ops;
    try testing.expectError(error.NoSpace, w.append("this one does not fit"));
    try testing.expectEqual(@as(u64, 2), try w.append("second"));
    sim.sync_fail_at = sim.ops;
    try testing.expectError(error.InputOutput, w.sync());
    try testing.expectError(error.Poisoned, w.append("third"));
}

test "read-only open never writes" {
    var sim: fsmod.Sim = .init(testing.allocator, 7);
    defer sim.deinit();
    const fs = sim.fs();
    {
        var c: Collect = .{ .gpa = testing.allocator };
        defer c.deinit();
        var w = try reopen(testing.allocator, fs, .{}, 0, &c);
        defer w.deinit();
        _ = try w.append("a");
        try w.sync();
    }
    var name_buf: [32]u8 = undefined;
    const h = try fs.open(fileName(&name_buf, 1), true);
    try fs.write(h, "torn", try fs.len(h));
    fs.close(h);
    const ops = sim.ops;
    var c: Collect = .{ .gpa = testing.allocator };
    defer c.deinit();
    var w = try reopen(testing.allocator, fs, .{ .writable = false }, 0, &c);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), c.seqs.items.len);
    try testing.expectError(error.ReadOnly, w.append("x"));
    try testing.expectEqual(ops, sim.ops);
}

/// Crashes at every mutating operation of a workload (including during the
/// recovery that follows) and checks that recovery returns a prefix of what
/// was appended that contains every acknowledged record.
fn crashWorkload(seed: u64, crash_at: u64, sync_each: bool, recovery_crash: ?u64) !void {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, seed);
    defer sim.deinit();
    const fs = sim.fs();
    const opts: Options = .{ .segment_size = 400 };
    var buf: [128]u8 = undefined;
    const total = 30;

    var acked: usize = 0;
    {
        var c: Collect = .{ .gpa = gpa };
        defer c.deinit();
        var w = try reopen(gpa, fs, opts, 0, &c);
        defer w.deinit();
        sim.crash_at = crash_at;
        for (0..total) |i| {
            _ = w.append(payloadFor(&buf, i)) catch break;
            if (sync_each) {
                w.sync() catch break;
                acked = i + 1;
            }
        }
    }
    try sim.crash();

    if (recovery_crash) |at| {
        var c: Collect = .{ .gpa = gpa };
        defer c.deinit();
        sim.crash_at = sim.ops + at;
        if (reopen(gpa, fs, opts, 0, &c)) |w| {
            var ww = w;
            ww.deinit();
        } else |e| try testing.expectEqual(error.Crashed, e);
        try sim.crash();
    }

    var count: usize = 0;
    {
        var c: Collect = .{ .gpa = gpa };
        defer c.deinit();
        var w = try reopen(gpa, fs, opts, 0, &c);
        defer w.deinit();
        count = c.seqs.items.len;
        try testing.expect(count >= acked);
        try testing.expect(count <= total);
        for (c.seqs.items, c.payloads.items, 0..) |seq, p, i| {
            try testing.expectEqual(@as(u64, i + 1), seq);
            try testing.expectEqualSlices(u8, payloadFor(&buf, i), p);
        }
        // The log accepts new records after recovery.
        try testing.expectEqual(@as(u64, count + 1), try w.append("after"));
        try w.sync();
    }
    try sim.crash();
    var c: Collect = .{ .gpa = gpa };
    defer c.deinit();
    var w = try reopen(gpa, fs, opts, 0, &c);
    defer w.deinit();
    try testing.expectEqual(count + 1, c.seqs.items.len);
    try testing.expectEqualStrings("after", c.payloads.items[count]);
}

test "crash at every operation" {
    var at: u64 = 0;
    while (at < 120) : (at += 1) {
        for (0..3) |seed| {
            try crashWorkload(seed * 1000 + at, at, true, null);
            try crashWorkload(seed * 1000 + at, at, false, null);
            try crashWorkload(seed * 1000 + at, at, true, at % 7);
        }
    }
}
