//! File system layer. Everything the engine persists goes through `Fs`, a
//! flat directory of files. Two implementations:
//!
//! - `Real`: the operating system, through `std.Io`. `sync` is a full flush
//!   (`F_FULLFSYNC` on Apple platforms, where `fsync` does not reach the disk).
//! - `Sim`: an in-memory file system for tests that models what survives a
//!   crash. Writes, truncations and directory changes made since the last
//!   `sync`/`syncDir` are pending; on `crash()` either a prefix of them or an
//!   arbitrary subset is kept (real file systems reorder unsynced changes),
//!   and kept writes may be torn. A rename is atomic. Faults (crash at the
//!   n-th operation, disk full, failing fsync) are injected by operation
//!   count.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotFound,
    AlreadyExists,
    NoSpace,
    AccessDenied,
    Locked,
    /// Simulated process death: every operation fails until `Sim.crash()`.
    Crashed,
    InputOutput,
    OutOfMemory,
};

pub const Handle = u64;

pub const Fs = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, []const u8) Error!Handle,
        open: *const fn (*anyopaque, []const u8, bool) Error!Handle,
        close: *const fn (*anyopaque, Handle) void,
        read: *const fn (*anyopaque, Handle, []u8, u64) Error!usize,
        write: *const fn (*anyopaque, Handle, []const u8, u64) Error!void,
        len: *const fn (*anyopaque, Handle) Error!u64,
        truncate: *const fn (*anyopaque, Handle, u64) Error!void,
        sync: *const fn (*anyopaque, Handle) Error!void,
        rename: *const fn (*anyopaque, []const u8, []const u8) Error!void,
        remove: *const fn (*anyopaque, []const u8) Error!void,
        syncDir: *const fn (*anyopaque) Error!void,
        list: *const fn (*anyopaque, Allocator) Error![][]u8,
    };

    /// Creates (or truncates) a file opened for reading and writing.
    pub fn create(fs: Fs, name: []const u8) Error!Handle {
        return fs.vtable.create(fs.ptr, name);
    }
    pub fn open(fs: Fs, name: []const u8, writable: bool) Error!Handle {
        return fs.vtable.open(fs.ptr, name, writable);
    }
    pub fn close(fs: Fs, h: Handle) void {
        fs.vtable.close(fs.ptr, h);
    }
    /// Reads up to `buf.len` bytes at `offset`; returns fewer only at EOF.
    pub fn read(fs: Fs, h: Handle, buf: []u8, offset: u64) Error!usize {
        return fs.vtable.read(fs.ptr, h, buf, offset);
    }
    pub fn write(fs: Fs, h: Handle, data: []const u8, offset: u64) Error!void {
        return fs.vtable.write(fs.ptr, h, data, offset);
    }
    pub fn len(fs: Fs, h: Handle) Error!u64 {
        return fs.vtable.len(fs.ptr, h);
    }
    pub fn truncate(fs: Fs, h: Handle, size: u64) Error!void {
        return fs.vtable.truncate(fs.ptr, h, size);
    }
    pub fn sync(fs: Fs, h: Handle) Error!void {
        return fs.vtable.sync(fs.ptr, h);
    }
    /// Atomically replaces `new` with `old`. Durable after `syncDir`.
    pub fn rename(fs: Fs, old: []const u8, new: []const u8) Error!void {
        return fs.vtable.rename(fs.ptr, old, new);
    }
    pub fn remove(fs: Fs, name: []const u8) Error!void {
        return fs.vtable.remove(fs.ptr, name);
    }
    /// Makes file creations, renames and removals durable.
    pub fn syncDir(fs: Fs) Error!void {
        return fs.vtable.syncDir(fs.ptr);
    }
    /// Names of the files in the directory, sorted. Free with `freeList`.
    pub fn list(fs: Fs, gpa: Allocator) Error![][]u8 {
        const names = try fs.vtable.list(fs.ptr, gpa);
        std.mem.sort([]u8, names, {}, lessThan);
        return names;
    }

    /// Reads a whole file.
    pub fn readAll(fs: Fs, gpa: Allocator, name: []const u8) Error![]u8 {
        const h = try fs.open(name, false);
        defer fs.close(h);
        const size = try fs.len(h);
        const buf = try gpa.alloc(u8, @intCast(size));
        errdefer gpa.free(buf);
        if (try fs.read(h, buf, 0) != buf.len) return error.InputOutput;
        return buf;
    }

    /// Writes `data` to `name` so that after a crash the file holds either its
    /// previous contents or `data`, never a mix: temporary file, sync, rename,
    /// directory sync.
    pub fn writeAtomic(fs: Fs, name: []const u8, data: []const u8) Error!void {
        var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.InputOutput;
        const h = try fs.create(tmp);
        {
            errdefer fs.close(h);
            try fs.write(h, data, 0);
            try fs.sync(h);
        }
        fs.close(h);
        try fs.rename(tmp, name);
        try fs.syncDir();
    }

    pub fn exists(fs: Fs, name: []const u8) Error!bool {
        const h = fs.open(name, false) catch |e| switch (e) {
            error.NotFound => return false,
            else => return e,
        };
        fs.close(h);
        return true;
    }
};

pub fn freeList(gpa: Allocator, names: [][]u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// Real file system

pub const Real = struct {
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: ?std.Io.File = null,

    pub const lock_name = "LOCK";

    pub const LockMode = enum { none, shared, exclusive };

    /// Opens (creating it if needed) the directory at `path` and takes a
    /// non-blocking lock on its LOCK file: one exclusive holder (a writer) or
    /// any number of shared ones (readers); a conflict gives `error.Locked`.
    pub fn open(io: std.Io, path: []const u8, mode: LockMode) Error!Real {
        // Only a writer creates anything: a reader never writes a byte.
        if (mode == .exclusive) std.Io.Dir.cwd().createDirPath(io, path) catch |e| return mapErr(e);
        const dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| return mapErr(e);
        var self: Real = .{ .io = io, .dir = dir };
        errdefer dir.close(io);
        switch (mode) {
            .none => {},
            .exclusive => self.lock_file = dir.createFile(io, lock_name, .{
                .truncate = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |e| return switch (e) {
                error.WouldBlock => error.Locked,
                else => mapErr(e),
            },
            // No LOCK file: no writer ever opened the directory.
            .shared => self.lock_file = dir.openFile(io, lock_name, .{
                .lock = .shared,
                .lock_nonblocking = true,
            }) catch |e| switch (e) {
                error.WouldBlock => return error.Locked,
                error.FileNotFound => null,
                else => return mapErr(e),
            },
        }
        return self;
    }

    pub fn deinit(self: *Real) void {
        if (self.lock_file) |f| f.close(self.io);
        self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn fs(self: *Real) Fs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Fs.VTable = .{
        .create = create,
        .open = openFile,
        .close = close,
        .read = read,
        .write = write,
        .len = len,
        .truncate = truncate,
        .sync = sync,
        .rename = rename,
        .remove = remove,
        .syncDir = syncDir,
        .list = list,
    };

    fn get(p: *anyopaque) *Real {
        return @ptrCast(@alignCast(p));
    }
    fn file(h: Handle) std.Io.File {
        return .{ .handle = @intCast(h), .flags = .{ .nonblocking = false } };
    }
    fn handle(f: std.Io.File) Handle {
        return @intCast(f.handle);
    }

    fn create(p: *anyopaque, name: []const u8) Error!Handle {
        const self = get(p);
        const f = self.dir.createFile(self.io, name, .{ .read = true, .truncate = true }) catch |e| return mapErr(e);
        return handle(f);
    }
    fn openFile(p: *anyopaque, name: []const u8, writable: bool) Error!Handle {
        const self = get(p);
        const f = self.dir.openFile(self.io, name, .{ .mode = if (writable) .read_write else .read_only }) catch |e| return mapErr(e);
        return handle(f);
    }
    fn close(p: *anyopaque, h: Handle) void {
        file(h).close(get(p).io);
    }
    fn read(p: *anyopaque, h: Handle, buf: []u8, offset: u64) Error!usize {
        return file(h).readPositionalAll(get(p).io, buf, offset) catch |e| mapErr(e);
    }
    fn write(p: *anyopaque, h: Handle, data: []const u8, offset: u64) Error!void {
        file(h).writePositionalAll(get(p).io, data, offset) catch |e| return mapErr(e);
    }
    fn len(p: *anyopaque, h: Handle) Error!u64 {
        return file(h).length(get(p).io) catch |e| mapErr(e);
    }
    fn truncate(p: *anyopaque, h: Handle, size: u64) Error!void {
        file(h).setLength(get(p).io, size) catch |e| return mapErr(e);
    }
    fn sync(p: *anyopaque, h: Handle) Error!void {
        return fullSync(get(p).io, file(h));
    }
    fn rename(p: *anyopaque, old: []const u8, new: []const u8) Error!void {
        const self = get(p);
        std.Io.Dir.rename(self.dir, old, self.dir, new, self.io) catch |e| return mapErr(e);
    }
    fn remove(p: *anyopaque, name: []const u8) Error!void {
        const self = get(p);
        self.dir.deleteFile(self.io, name) catch |e| return mapErr(e);
    }
    fn syncDir(p: *anyopaque) Error!void {
        const self = get(p);
        if (builtin.os.tag == .windows) return; // NTFS journals metadata
        if (std.c.fsync(self.dir.handle) != 0) return error.InputOutput;
    }
    fn list(p: *anyopaque, gpa: Allocator) Error![][]u8 {
        const self = get(p);
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = self.dir.iterate();
        while (it.next(self.io) catch |e| return mapErr(e)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.eql(u8, entry.name, lock_name)) continue;
            const name = try gpa.dupe(u8, entry.name);
            names.append(gpa, name) catch |e| {
                gpa.free(name);
                return e;
            };
        }
        return names.toOwnedSlice(gpa);
    }

    fn fullSync(io: std.Io, f: std.Io.File) Error!void {
        if (comptime builtin.os.tag.isDarwin()) {
            // fsync on Apple platforms only reaches the drive cache.
            if (std.c.fcntl(f.handle, std.c.F.FULLFSYNC) == 0) return;
            // Some file systems (network, FAT) reject F_FULLFSYNC.
        }
        f.sync(io) catch |e| return mapErr(e);
    }

    fn mapErr(e: anyerror) Error {
        return switch (e) {
            error.FileNotFound => error.NotFound,
            error.PathAlreadyExists => error.AlreadyExists,
            error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => error.NoSpace,
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.AccessDenied,
            error.OutOfMemory => error.OutOfMemory,
            else => error.InputOutput,
        };
    }
};

// ---------------------------------------------------------------------------
// Simulated file system

pub const Sim = struct {
    gpa: Allocator,
    rng: std.Random.DefaultPrng,
    inodes: std.ArrayList(?*Inode) = .empty,
    /// What a running process sees.
    dir: std.StringHashMapUnmanaged(u32) = .empty,
    /// What survives a crash, plus `dir_pending` applied in order.
    durable_dir: std.StringHashMapUnmanaged(u32) = .empty,
    dir_pending: std.ArrayList(DirOp) = .empty,
    handles: std.ArrayList(?u32) = .empty,

    /// Number of mutating operations performed so far.
    ops: u64 = 0,
    /// The mutating operation with this index fails with `error.Crashed`, as
    /// do all later ones.
    crash_at: ?u64 = null,
    /// The write with this operation index stores a random prefix and fails
    /// with `error.NoSpace`.
    nospace_at: ?u64 = null,
    /// The sync with this operation index fails and loses the file's pending
    /// writes (they stay visible until the next crash, as with a real fsync
    /// failure).
    sync_fail_at: ?u64 = null,
    crashed: bool = false,

    const Inode = struct {
        data: std.ArrayList(u8) = .empty,
        durable: std.ArrayList(u8) = .empty,
        pending: std.ArrayList(DataOp) = .empty,

        fn deinit(n: *Inode, gpa: Allocator) void {
            for (n.pending.items) |op| op.deinit(gpa);
            n.pending.deinit(gpa);
            n.data.deinit(gpa);
            n.durable.deinit(gpa);
        }
    };

    const DataOp = union(enum) {
        write: struct { offset: u64, bytes: []u8 },
        truncate: u64,

        fn deinit(op: DataOp, gpa: Allocator) void {
            if (op == .write) gpa.free(op.write.bytes);
        }
    };

    const DirOp = union(enum) {
        link: struct { name: []u8, inode: u32 },
        unlink: []u8,
        rename: struct { old: []u8, new: []u8 },

        fn deinit(op: DirOp, gpa: Allocator) void {
            switch (op) {
                .link => |l| gpa.free(l.name),
                .unlink => |n| gpa.free(n),
                .rename => |r| {
                    gpa.free(r.old);
                    gpa.free(r.new);
                },
            }
        }
    };

    pub fn init(gpa: Allocator, seed: u64) Sim {
        return .{ .gpa = gpa, .rng = .init(seed) };
    }

    pub fn deinit(self: *Sim) void {
        const gpa = self.gpa;
        for (self.inodes.items) |maybe| if (maybe) |n| {
            n.deinit(gpa);
            gpa.destroy(n);
        };
        self.inodes.deinit(gpa);
        freeKeys(gpa, &self.dir);
        freeKeys(gpa, &self.durable_dir);
        for (self.dir_pending.items) |op| op.deinit(gpa);
        self.dir_pending.deinit(gpa);
        self.handles.deinit(gpa);
        self.* = undefined;
    }

    pub fn fs(self: *Sim) Fs {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Simulates a power loss followed by a restart: open handles are
    /// dropped, and each file and the directory keep their durable state plus
    /// some of their pending changes: a prefix (the last one possibly torn)
    /// or an arbitrary subset (each kept write possibly torn).
    pub fn crash(self: *Sim) Allocator.Error!void {
        const gpa = self.gpa;
        const random = self.rng.random();
        const subset = random.boolean();

        // Directory: durable entries plus some pending operations, in order.
        const keep_dir = random.uintAtMost(usize, self.dir_pending.items.len);
        for (self.dir_pending.items, 0..) |op, i| {
            const keep = if (subset) random.boolean() else i < keep_dir;
            if (keep) try applyDirOp(gpa, &self.durable_dir, op);
        }
        for (self.dir_pending.items) |op| op.deinit(gpa);
        self.dir_pending.clearRetainingCapacity();
        freeKeys(gpa, &self.dir);
        self.dir = try cloneDir(gpa, &self.durable_dir);

        // Files: durable bytes plus some pending operations, in order.
        for (self.inodes.items) |maybe| if (maybe) |n| {
            const keep = random.uintAtMost(usize, n.pending.items.len);
            for (n.pending.items, 0..) |op, i| {
                const kept = if (subset) random.boolean() else i < keep;
                if (!kept) continue;
                const torn = (subset or i + 1 == keep) and random.boolean();
                try applyDataOp(gpa, &n.durable, op, if (torn) random else null);
            }
            for (n.pending.items) |op| op.deinit(gpa);
            n.pending.clearRetainingCapacity();
            n.data.clearRetainingCapacity();
            try n.data.appendSlice(gpa, n.durable.items);
        };

        // Free inodes no longer linked.
        for (self.inodes.items, 0..) |maybe, i| if (maybe) |n| {
            if (!isLinked(&self.dir, @intCast(i))) {
                n.deinit(gpa);
                gpa.destroy(n);
                self.inodes.items[i] = null;
            }
        };

        self.handles.clearRetainingCapacity();
        self.crashed = false;
        self.crash_at = null;
        self.nospace_at = null;
        self.sync_fail_at = null;
    }

    /// Makes every pending change durable (a clean shutdown).
    pub fn flushAll(self: *Sim) Allocator.Error!void {
        for (self.inodes.items) |maybe| if (maybe) |n| try commitInode(self.gpa, n);
        try self.commitDir();
    }

    const vtable: Fs.VTable = .{
        .create = create,
        .open = open,
        .close = close,
        .read = read,
        .write = write,
        .len = len,
        .truncate = truncate,
        .sync = sync,
        .rename = rename,
        .remove = remove,
        .syncDir = syncDir,
        .list = list,
    };

    fn get(p: *anyopaque) *Sim {
        return @ptrCast(@alignCast(p));
    }

    /// Counts a mutating operation and decides whether it crashes.
    fn step(self: *Sim) Error!u64 {
        if (self.crashed) return error.Crashed;
        const n = self.ops;
        self.ops += 1;
        if (self.crash_at) |at| if (n >= at) {
            self.crashed = true;
            return error.Crashed;
        };
        return n;
    }

    fn inodeOf(self: *Sim, h: Handle) Error!*Inode {
        if (self.crashed) return error.Crashed;
        if (h >= self.handles.items.len) return error.InputOutput;
        const idx = self.handles.items[@intCast(h)] orelse return error.InputOutput;
        return self.inodes.items[idx].?;
    }

    fn newHandle(self: *Sim, inode: u32) Error!Handle {
        for (self.handles.items, 0..) |slot, i| if (slot == null) {
            self.handles.items[i] = inode;
            return i;
        };
        try self.handles.append(self.gpa, inode);
        return self.handles.items.len - 1;
    }

    fn create(p: *anyopaque, name: []const u8) Error!Handle {
        const self = get(p);
        _ = try self.step();
        if (self.dir.get(name)) |idx| {
            const n = self.inodes.items[idx].?;
            try n.pending.append(self.gpa, .{ .truncate = 0 });
            n.data.clearRetainingCapacity();
            return self.newHandle(idx);
        }
        const n = try self.gpa.create(Inode);
        n.* = .{};
        errdefer self.gpa.destroy(n);
        const idx: u32 = @intCast(self.inodes.items.len);
        try self.inodes.append(self.gpa, n);
        try self.link(name, idx);
        return self.newHandle(idx);
    }

    fn open(p: *anyopaque, name: []const u8, writable: bool) Error!Handle {
        _ = writable;
        const self = get(p);
        if (self.crashed) return error.Crashed;
        const idx = self.dir.get(name) orelse return error.NotFound;
        return self.newHandle(idx);
    }

    fn close(p: *anyopaque, h: Handle) void {
        const self = get(p);
        if (h < self.handles.items.len) self.handles.items[@intCast(h)] = null;
    }

    fn read(p: *anyopaque, h: Handle, buf: []u8, offset: u64) Error!usize {
        const n = try get(p).inodeOf(h);
        if (offset >= n.data.items.len) return 0;
        const avail = n.data.items[@intCast(offset)..];
        const count = @min(avail.len, buf.len);
        @memcpy(buf[0..count], avail[0..count]);
        return count;
    }

    fn write(p: *anyopaque, h: Handle, data: []const u8, offset: u64) Error!void {
        const self = get(p);
        const n = try self.inodeOf(h);
        const op_index = try self.step();
        var bytes = data;
        var nospace = false;
        if (self.nospace_at == op_index) {
            bytes = data[0..self.rng.random().uintLessThan(usize, data.len + 1)];
            nospace = true;
        }
        {
            const copy = try self.gpa.dupe(u8, bytes);
            errdefer self.gpa.free(copy);
            const op: DataOp = .{ .write = .{ .offset = offset, .bytes = copy } };
            try applyDataOp(self.gpa, &n.data, op, null);
            try n.pending.append(self.gpa, op);
        }
        if (nospace) return error.NoSpace;
    }

    fn len(p: *anyopaque, h: Handle) Error!u64 {
        return (try get(p).inodeOf(h)).data.items.len;
    }

    fn truncate(p: *anyopaque, h: Handle, size: u64) Error!void {
        const self = get(p);
        const n = try self.inodeOf(h);
        _ = try self.step();
        const op: DataOp = .{ .truncate = size };
        try applyDataOp(self.gpa, &n.data, op, null);
        try n.pending.append(self.gpa, op);
    }

    fn sync(p: *anyopaque, h: Handle) Error!void {
        const self = get(p);
        const n = try self.inodeOf(h);
        const op_index = try self.step();
        if (self.sync_fail_at == op_index) {
            for (n.pending.items) |op| op.deinit(self.gpa);
            n.pending.clearRetainingCapacity();
            return error.InputOutput;
        }
        try commitInode(self.gpa, n);
    }

    fn rename(p: *anyopaque, old: []const u8, new: []const u8) Error!void {
        const self = get(p);
        _ = try self.step();
        if (!self.dir.contains(old)) return error.NotFound;
        const op: DirOp = .{ .rename = .{ .old = try self.gpa.dupe(u8, old), .new = undefined } };
        const new_copy = self.gpa.dupe(u8, new) catch |e| {
            self.gpa.free(op.rename.old);
            return e;
        };
        var full = op;
        full.rename.new = new_copy;
        errdefer full.deinit(self.gpa);
        try applyDirOp(self.gpa, &self.dir, full);
        try self.dir_pending.append(self.gpa, full);
    }

    fn remove(p: *anyopaque, name: []const u8) Error!void {
        const self = get(p);
        _ = try self.step();
        if (!self.dir.contains(name)) return error.NotFound;
        try self.unlink(name);
    }

    fn syncDir(p: *anyopaque) Error!void {
        const self = get(p);
        _ = try self.step();
        try self.commitDir();
    }

    fn list(p: *anyopaque, gpa: Allocator) Error![][]u8 {
        const self = get(p);
        if (self.crashed) return error.Crashed;
        var names: std.ArrayList([]u8) = .empty;
        errdefer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = self.dir.keyIterator();
        while (it.next()) |k| {
            const name = try gpa.dupe(u8, k.*);
            names.append(gpa, name) catch |e| {
                gpa.free(name);
                return e;
            };
        }
        return names.toOwnedSlice(gpa);
    }

    fn link(self: *Sim, name: []const u8, idx: u32) Allocator.Error!void {
        const op: DirOp = .{ .link = .{ .name = try self.gpa.dupe(u8, name), .inode = idx } };
        errdefer op.deinit(self.gpa);
        try applyDirOp(self.gpa, &self.dir, op);
        try self.dir_pending.append(self.gpa, op);
    }

    fn unlink(self: *Sim, name: []const u8) Allocator.Error!void {
        const op: DirOp = .{ .unlink = try self.gpa.dupe(u8, name) };
        errdefer op.deinit(self.gpa);
        try applyDirOp(self.gpa, &self.dir, op);
        try self.dir_pending.append(self.gpa, op);
    }

    fn commitDir(self: *Sim) Allocator.Error!void {
        for (self.dir_pending.items) |op| {
            try applyDirOp(self.gpa, &self.durable_dir, op);
            op.deinit(self.gpa);
        }
        self.dir_pending.clearRetainingCapacity();
    }

    fn commitInode(gpa: Allocator, n: *Inode) Allocator.Error!void {
        n.durable.clearRetainingCapacity();
        try n.durable.appendSlice(gpa, n.data.items);
        for (n.pending.items) |op| op.deinit(gpa);
        n.pending.clearRetainingCapacity();
    }

    fn applyDataOp(gpa: Allocator, buf: *std.ArrayList(u8), op: DataOp, tear: ?std.Random) Allocator.Error!void {
        switch (op) {
            .truncate => |size| {
                const s: usize = @intCast(size);
                if (s <= buf.items.len) {
                    buf.shrinkRetainingCapacity(s);
                } else {
                    try buf.appendNTimes(gpa, 0, s - buf.items.len);
                }
            },
            .write => |w| {
                var bytes = w.bytes;
                if (tear) |r| bytes = bytes[0..r.uintLessThan(usize, bytes.len + 1)];
                const off: usize = @intCast(w.offset);
                const end = off + bytes.len;
                if (end > buf.items.len) try buf.appendNTimes(gpa, 0, end - buf.items.len);
                @memcpy(buf.items[off..end], bytes);
            },
        }
    }

    fn applyDirOp(gpa: Allocator, dir: *std.StringHashMapUnmanaged(u32), op: DirOp) Allocator.Error!void {
        switch (op) {
            .link => |l| {
                if (dir.getPtr(l.name)) |v| {
                    v.* = l.inode;
                } else {
                    const key = try gpa.dupe(u8, l.name);
                    errdefer gpa.free(key);
                    try dir.put(gpa, key, l.inode);
                }
            },
            .unlink => |name| {
                if (dir.fetchRemove(name)) |kv| gpa.free(kv.key);
            },
            .rename => |r| {
                // Skipped when the source did not survive (subset crashes).
                const kv = dir.fetchRemove(r.old) orelse return;
                gpa.free(kv.key);
                try applyDirOp(gpa, dir, .{ .link = .{ .name = r.new, .inode = kv.value } });
            },
        }
    }

    fn cloneDir(gpa: Allocator, src: *const std.StringHashMapUnmanaged(u32)) Allocator.Error!std.StringHashMapUnmanaged(u32) {
        var out: std.StringHashMapUnmanaged(u32) = .empty;
        errdefer freeKeys(gpa, &out);
        var it = src.iterator();
        while (it.next()) |kv| {
            const key = try gpa.dupe(u8, kv.key_ptr.*);
            errdefer gpa.free(key);
            try out.put(gpa, key, kv.value_ptr.*);
        }
        return out;
    }

    fn isLinked(dir: *const std.StringHashMapUnmanaged(u32), idx: u32) bool {
        var it = dir.valueIterator();
        while (it.next()) |v| if (v.* == idx) return true;
        return false;
    }

    fn freeKeys(gpa: Allocator, map: *std.StringHashMapUnmanaged(u32)) void {
        var it = map.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        map.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "sim: synced data and directory survive a crash" {
    var sim: Sim = .init(testing.allocator, 1);
    defer sim.deinit();
    const fs = sim.fs();

    const h = try fs.create("a");
    try fs.write(h, "hello", 0);
    try fs.sync(h);
    fs.close(h);
    try fs.syncDir();

    try sim.crash();
    const data = try fs.readAll(testing.allocator, "a");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hello", data);
}

test "sim: unsynced changes keep a prefix, possibly torn" {
    var saw_full = false;
    var saw_partial = false;
    var saw_missing = false;
    var seed: u64 = 0;
    while (seed < 200) : (seed += 1) {
        var sim: Sim = .init(testing.allocator, seed);
        defer sim.deinit();
        const fs = sim.fs();
        const h = try fs.create("a");
        try fs.write(h, "0123456789", 0);
        fs.close(h);
        try sim.crash();
        const data = fs.readAll(testing.allocator, "a") catch |e| switch (e) {
            error.NotFound => {
                saw_missing = true;
                continue;
            },
            else => return e,
        };
        defer testing.allocator.free(data);
        try testing.expect(std.mem.startsWith(u8, "0123456789", data));
        if (data.len == 10) saw_full = true else saw_partial = true;
    }
    try testing.expect(saw_full and saw_partial and saw_missing);
}

test "sim: writeAtomic yields old or new contents, never a mix" {
    var at: u64 = 0;
    while (at < 12) : (at += 1) {
        var sim: Sim = .init(testing.allocator, at);
        defer sim.deinit();
        const fs = sim.fs();
        try fs.writeAtomic("m", "old-contents");
        sim.crash_at = sim.ops + at;
        fs.writeAtomic("m", "new") catch |e| try testing.expectEqual(error.Crashed, e);
        try sim.crash();
        const data = try fs.readAll(testing.allocator, "m");
        defer testing.allocator.free(data);
        try testing.expect(std.mem.eql(u8, data, "old-contents") or std.mem.eql(u8, data, "new"));
    }
}

test "sim: failed sync loses pending writes after a crash" {
    var sim: Sim = .init(testing.allocator, 7);
    defer sim.deinit();
    const fs = sim.fs();
    const h = try fs.create("a");
    try fs.sync(h);
    try fs.syncDir();
    try fs.write(h, "lost", 0);
    sim.sync_fail_at = sim.ops;
    try testing.expectError(error.InputOutput, fs.sync(h));
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try fs.read(h, &buf, 0)); // still visible
    try sim.crash();
    const data = try fs.readAll(testing.allocator, "a");
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 0), data.len);
}

test "sim: disk full stores a prefix and reports NoSpace" {
    var sim: Sim = .init(testing.allocator, 3);
    defer sim.deinit();
    const fs = sim.fs();
    const h = try fs.create("a");
    defer fs.close(h);
    sim.nospace_at = sim.ops;
    try testing.expectError(error.NoSpace, fs.write(h, "abcdef", 0));
    try testing.expect(try fs.len(h) <= 6);
}

test "real: write, sync, rename, list, lock" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path_buf[0..base_len]});
    defer testing.allocator.free(path);

    var real = try Real.open(io, path, .exclusive);
    defer real.deinit();
    const fs = real.fs();
    try fs.writeAtomic("x", "data");
    try fs.rename("x", "y");
    try fs.syncDir();
    try testing.expect(!try fs.exists("x"));
    const data = try fs.readAll(testing.allocator, "y");
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("data", data);

    const names = try fs.list(testing.allocator);
    defer freeList(testing.allocator, names);
    try testing.expectEqual(@as(usize, 1), names.len);

    try testing.expectError(error.Locked, Real.open(io, path, .exclusive));
    try testing.expectError(error.Locked, Real.open(io, path, .shared));

    // A reader never creates the directory.
    const missing = try std.fmt.allocPrint(testing.allocator, "{s}/missing", .{path_buf[0..base_len]});
    defer testing.allocator.free(missing);
    try testing.expectError(error.NotFound, Real.open(io, missing, .shared));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, missing, .{}));
}
