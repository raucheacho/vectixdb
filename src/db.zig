//! The database: a directory of collections, a write-ahead log, collection
//! snapshots and a manifest that names the current snapshots.
//!
//!   MANIFEST-<gen>             "VTXM": gen, checkpoint_seq, (collection, snapshot file)*
//!   snap-<gen>-<collection>.vtx "VTXC": one collection, written at checkpoint <gen>
//!   wal-<first_seq>.log        batches after the checkpoint
//!
//! Writes: validate, append to the log, sync (durability `sync`), apply in
//! memory. A failure while applying (out of memory) poisons the handle; the
//! log still holds the batch, so reopening recovers it.
//!
//! Checkpoint: write snapshots of modified collections (temporary file, sync,
//! rename), sync the directory, write the manifest atomically, and only then
//! delete the log files and snapshots it makes obsolete. Opening uses the
//! newest valid manifest; files are deleted at open only when that manifest is
//! the newest one present, so a damaged manifest never leads to deleting data.
//!
//! Thread safe: one writer at a time, readers in parallel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fsmod = @import("fs.zig");
const Fs = fsmod.Fs;
const codec = @import("codec.zig");
const wal_mod = @import("wal.zig");
const batch = @import("batch.zig");
const schema = @import("schema.zig");
const coll_mod = @import("collection.zig");

pub const Collection = coll_mod.Collection;
pub const Query = coll_mod.Query;
pub const Op = batch.Op;
pub const Schema = schema.Schema;
pub const Doc = schema.Doc;
pub const Value = schema.Value;

const manifest_magic = "VTXM";
const snapshot_magic = "VTXC";
const format_version: u32 = 1;

pub const Error = error{
    NotFound,
    AlreadyExists,
    NoSpace,
    AccessDenied,
    Locked,
    Crashed,
    InputOutput,
    OutOfMemory,
    Corrupt,
    Poisoned,
    ReadOnly,
    RecordTooLarge,
    InvalidSchema,
    InvalidDocument,
    InvalidQuery,
    InvalidFilter,
    InvalidArgument,
};

pub const Durability = enum {
    /// A write is durable when it returns.
    sync,
    /// A write is durable after `sync`, a checkpoint or `close`; a crash may
    /// lose the last writes, never corrupt the database.
    none,
};

pub const Options = struct {
    read_only: bool = false,
    durability: Durability = .sync,
    wal_segment_size: u64 = 64 << 20,
    /// Checkpoint automatically once this many log bytes were written since
    /// the last one (0: only explicit checkpoints).
    checkpoint_after: u64 = 64 << 20,
    /// Drop corrupted log records instead of refusing to open.
    repair: bool = false,
    /// Threads used to insert the vectors of a batch (0: number of CPUs, at
    /// most 8). With 1 the vector graph is deterministic.
    build_threads: u32 = 0,
};

const Entry = struct {
    coll: *Collection,
    /// Snapshot file holding the collection at the last checkpoint.
    snapshot: ?[]u8 = null,
    dirty: bool = true,
};

/// One search result, owned by `Results`.
pub const Result = struct {
    id: []const u8,
    score: f32,
    vector_rank: u32,
    vector_distance: f32,
    text_rank: u32,
    text_score: f32,
    payload: ?[]const u8,
    fields: []const schema.FieldValue,
};

pub const Results = struct {
    arena: std.heap.ArenaAllocator,
    items: []Result,

    pub fn deinit(r: *Results) void {
        r.arena.deinit();
    }
};

pub const Stats = struct {
    collections: u32,
    documents: u64,
    last_seq: u64,
    checkpoint_seq: u64,
    generation: u64,
    wal_bytes: u64,
};

pub const Db = struct {
    gpa: Allocator,
    io: std.Io,
    fs: Fs,
    opts: Options,
    lock: std.Io.RwLock = .init,

    collections: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Snapshot files to delete once the next manifest is durable.
    obsolete: std.ArrayList([]u8) = .empty,
    wal: wal_mod.Wal,
    gen: u64 = 0,
    checkpoint_seq: u64 = 0,
    wal_bytes: u64 = 0,
    poisoned: bool = false,

    pub fn open(gpa: Allocator, io: std.Io, fs: Fs, opts: Options) Error!*Db {
        const self = try gpa.create(Db);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .fs = fs, .opts = opts, .wal = undefined };
        if (self.opts.build_threads == 0) {
            self.opts.build_threads = @intCast(@min(std.Thread.getCpuCount() catch 1, 8));
        }
        errdefer self.freeState();

        const names = try fs.list(gpa);
        defer fsmod.freeList(gpa, names);

        // Newest valid manifest whose snapshots all load.
        var manifests: std.ArrayList(u64) = .empty;
        defer manifests.deinit(gpa);
        for (names) |name| if (parseManifestName(name)) |g| try manifests.append(gpa, g);
        std.mem.sort(u64, manifests.items, {}, std.sort.desc(u64));
        var newest_used = true;
        var loaded = false;
        for (manifests.items) |g| {
            if (self.loadManifest(g)) {
                loaded = true;
                break;
            } else |e| switch (e) {
                error.OutOfMemory, error.Crashed => return e,
                else => {
                    self.clearCollections();
                    newest_used = false;
                },
            }
        }
        if (manifests.items.len > 0 and !loaded) return error.Corrupt;

        var replay: Replay = .{ .db = self };
        self.wal = wal_mod.Wal.open(gpa, fs, .{
            .writable = !opts.read_only,
            .segment_size = opts.wal_segment_size,
            .repair = opts.repair,
        }, self.checkpoint_seq, &replay) catch |e| return mapErr(e);
        errdefer self.wal.deinit();
        if (replay.err) |e| return e;

        if (!opts.read_only and newest_used) try self.removeOrphans(names);
        return self;
    }

    /// Releases everything. Pending writes are made durable first (and a
    /// checkpoint is attempted) unless the handle is read-only or poisoned.
    pub fn close(self: *Db) Error!void {
        // A poisoned handle may have acknowledged nothing durable since the
        // failure: say so.
        var result: Error!void = if (self.poisoned) error.Poisoned else {};
        if (!self.opts.read_only and !self.poisoned) {
            if (self.wal_bytes > 0) {
                result = self.checkpointLocked();
                if (result) |_| {} else |_| result = self.wal.sync() catch |e| mapErr(e);
            } else {
                result = self.wal.sync() catch |e| mapErr(e);
            }
        }
        self.wal.deinit();
        self.freeState();
        self.gpa.destroy(self);
        return result;
    }

    fn freeState(self: *Db) void {
        self.clearCollections();
        self.collections.deinit(self.gpa);
        for (self.obsolete.items) |n| self.gpa.free(n);
        self.obsolete.deinit(self.gpa);
    }

    fn clearCollections(self: *Db) void {
        for (self.collections.values()) |e| {
            if (e.snapshot) |s| self.gpa.free(s);
            e.coll.deinit();
        }
        self.collections.clearRetainingCapacity();
        self.gen = 0;
        self.checkpoint_seq = 0;
    }

    // ---- writes --------------------------------------------------------

    /// Applies a batch atomically and returns its sequence number.
    pub fn write(self: *Db, ops: []const Op) Error!u64 {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.opts.read_only) return error.ReadOnly;
        if (self.poisoned) return error.Poisoned;
        if (ops.len == 0 or ops.len > batch.max_ops) return error.InvalidArgument;
        try self.validate(ops);

        var w = codec.Writer.init(self.gpa);
        defer w.deinit();
        try batch.encode(&w, ops);
        const seq = self.wal.append(w.buf.items) catch |e| return self.walErr(e);
        if (self.opts.durability == .sync) self.wal.sync() catch |e| return self.walErr(e);
        self.wal_bytes += w.buf.items.len;

        self.apply(ops) catch |e| {
            self.poisoned = true;
            return e;
        };
        if (self.opts.checkpoint_after > 0 and self.wal_bytes >= self.opts.checkpoint_after) {
            // The batch is already safe in the log; a failed checkpoint is
            // retried after the next write.
            self.checkpointLocked() catch {};
        }
        return seq;
    }

    pub fn put(self: *Db, collection: []const u8, doc: Doc) Error!u64 {
        return self.write(&.{.{ .put = .{ .collection = collection, .doc = doc } }});
    }

    pub fn delete(self: *Db, collection: []const u8, id: []const u8) Error!u64 {
        return self.write(&.{.{ .delete = .{ .collection = collection, .id = id } }});
    }

    pub fn createCollection(self: *Db, name: []const u8, s: Schema) Error!u64 {
        return self.write(&.{.{ .create = .{ .name = name, .schema = s } }});
    }

    pub fn dropCollection(self: *Db, name: []const u8) Error!u64 {
        return self.write(&.{.{ .drop = name }});
    }

    /// Makes every write durable (for durability `none`).
    pub fn sync(self: *Db) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.poisoned) return error.Poisoned;
        if (self.opts.read_only) return;
        self.wal.sync() catch |e| return self.walErr(e);
    }

    fn walErr(self: *Db, e: anyerror) Error {
        if (self.wal.poisoned) self.poisoned = true;
        return mapErr(e);
    }

    /// Checks a batch against the current collections and the earlier
    /// operations of the same batch, without changing anything.
    fn validate(self: *Db, ops: []const Op) Error!void {
        var overlay: std.StringHashMapUnmanaged(?Schema) = .empty;
        defer overlay.deinit(self.gpa);
        for (ops) |op| switch (op) {
            .create => |c| {
                if (!schema.validName(c.name)) return error.InvalidSchema;
                try c.schema.validate();
                if (self.lookupSchema(&overlay, c.name) != null) return error.AlreadyExists;
                try overlay.put(self.gpa, c.name, c.schema);
            },
            .drop => |name| {
                if (self.lookupSchema(&overlay, name) == null) return error.NotFound;
                try overlay.put(self.gpa, name, null);
            },
            .put => |p| {
                const s = self.lookupSchema(&overlay, p.collection) orelse return error.NotFound;
                try p.doc.validate(s);
            },
            .delete => |d| {
                if (self.lookupSchema(&overlay, d.collection) == null) return error.NotFound;
                if (d.id.len == 0 or d.id.len > schema.limits.max_id_len) return error.InvalidDocument;
            },
        };
    }

    fn lookupSchema(self: *Db, overlay: *std.StringHashMapUnmanaged(?Schema), name: []const u8) ?Schema {
        if (overlay.get(name)) |s| return s;
        const e = self.collections.get(name) orelse return null;
        return e.coll.schema;
    }

    fn apply(self: *Db, ops: []const Op) Error!void {
        // Vectors are queued per collection and inserted at the end, in
        // parallel; a drop discards its collection's queue with it.
        defer for (self.collections.values()) |e| {
            e.coll.pending_slots.clearRetainingCapacity();
            e.coll.pending_vectors.clearRetainingCapacity();
        };
        try self.applyOps(ops);
        for (self.collections.values()) |e| e.coll.flushVectors(self.opts.build_threads) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Corrupt,
        };
    }

    fn applyOps(self: *Db, ops: []const Op) Error!void {
        for (ops) |op| switch (op) {
            .create => |c| {
                try self.collections.ensureUnusedCapacity(self.gpa, 1);
                const coll = Collection.init(self.gpa, c.name, c.schema) catch |e| return switch (e) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Corrupt,
                };
                self.collections.putAssumeCapacity(coll.name, .{ .coll = coll });
            },
            .drop => |name| {
                const kv = self.collections.fetchOrderedRemove(name).?;
                if (kv.value.snapshot) |s| {
                    self.obsolete.append(self.gpa, s) catch self.gpa.free(s);
                }
                kv.value.coll.deinit();
            },
            .put => |p| {
                const e = self.collections.getPtr(p.collection).?;
                e.dirty = true;
                e.coll.putDeferred(p.doc) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Corrupt,
                };
            },
            .delete => |d| {
                const e = self.collections.getPtr(d.collection).?;
                if (e.coll.delete(d.id)) e.dirty = true;
            },
        };
    }

    const Replay = struct {
        db: *Db,
        err: ?Error = null,

        pub fn apply(r: *Replay, seq: u64, payload: []const u8) !void {
            _ = seq;
            var arena: std.heap.ArenaAllocator = .init(r.db.gpa);
            defer arena.deinit();
            const ops = batch.decode(arena.allocator(), payload) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Corrupt,
            };
            r.db.validate(ops) catch return error.Corrupt;
            try r.db.apply(ops);
            r.db.wal_bytes += payload.len;
        }
    };

    // ---- reads ---------------------------------------------------------

    pub const SearchOptions = struct {
        /// Fields copied into each result.
        fields: []const []const u8 = &.{},
        payload: bool = true,
    };

    pub fn search(self: *Db, collection: []const u8, q: Query, out: SearchOptions) Error!Results {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        const e = self.collections.get(collection) orelse return error.NotFound;
        const coll = e.coll;
        const field_idx = try self.gpa.alloc(u16, out.fields.len);
        defer self.gpa.free(field_idx);
        for (out.fields, field_idx) |name, *idx| idx.* = coll.schema.fieldIndex(name) orelse return error.InvalidQuery;

        const hits = coll.search(self.gpa, q) catch |err| return mapErr(err);
        defer self.gpa.free(hits);

        var results: Results = .{ .arena = .init(self.gpa), .items = &.{} };
        errdefer results.deinit();
        const a = results.arena.allocator();
        const items = try a.alloc(Result, hits.len);
        for (hits, items) |h, *r| {
            r.* = .{
                .id = try a.dupe(u8, coll.idOf(h.slot)),
                .score = h.score,
                .vector_rank = h.vector_rank,
                .vector_distance = h.vector_distance,
                .text_rank = h.text_rank,
                .text_score = h.text_score,
                .payload = if (out.payload) if (coll.payloadOf(h.slot)) |p| try a.dupe(u8, p) else null else null,
                .fields = try copyFields(a, coll, h.slot, field_idx),
            };
        }
        results.items = items;
        return results;
    }

    /// The document with this id, with every field and its payload.
    pub fn get(self: *Db, collection: []const u8, id: []const u8) Error!?Results {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        const e = self.collections.get(collection) orelse return error.NotFound;
        const coll = e.coll;
        const slot = coll.slotOf(id) orelse return null;

        var results: Results = .{ .arena = .init(self.gpa), .items = &.{} };
        errdefer results.deinit();
        const a = results.arena.allocator();
        const all = try a.alloc(u16, coll.schema.fields.len);
        for (all, 0..) |*x, i| x.* = @intCast(i);
        const items = try a.alloc(Result, 1);
        items[0] = .{
            .id = try a.dupe(u8, id),
            .score = 0,
            .vector_rank = 0,
            .vector_distance = 0,
            .text_rank = 0,
            .text_score = 0,
            .payload = if (coll.payloadOf(slot)) |p| try a.dupe(u8, p) else null,
            .fields = try copyFields(a, coll, slot, all),
        };
        results.items = items;
        return results;
    }

    fn copyFields(a: Allocator, coll: *const Collection, slot: u32, idx: []const u16) ![]schema.FieldValue {
        var out: std.ArrayList(schema.FieldValue) = .empty;
        for (idx) |i| {
            const ref = coll.fieldOf(slot, i) orelse continue;
            const value: Value = switch (ref) {
                .text => |s| .{ .text = try a.dupe(u8, s) },
                .keyword => |s| .{ .keyword = try a.dupe(u8, s) },
                .keywords => |k| blk: {
                    const ks = try a.alloc([]const u8, k.len());
                    for (ks, 0..) |*x, j| x.* = try a.dupe(u8, k.get(j));
                    break :blk .{ .keywords = ks };
                },
                .int => |x| .{ .int = x },
                .float => |x| .{ .float = x },
                .bool => |x| .{ .bool = x },
                .time => |x| .{ .time = x },
            };
            try out.append(a, .{ .field = coll.schema.fields[i].name, .value = value });
        }
        return out.toOwnedSlice(a);
    }

    pub fn count(self: *Db, collection: []const u8) Error!u32 {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        const e = self.collections.get(collection) orelse return error.NotFound;
        return e.coll.len();
    }

    /// Names of the collections, allocated with `gpa`.
    pub fn collectionNames(self: *Db, gpa: Allocator) Error![][]u8 {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        const out = try gpa.alloc([]u8, self.collections.count());
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |n| gpa.free(n);
            gpa.free(out);
        }
        for (self.collections.keys(), out) |k, *o| {
            o.* = try gpa.dupe(u8, k);
            done += 1;
        }
        return out;
    }

    pub fn stats(self: *Db) Stats {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        var docs: u64 = 0;
        for (self.collections.values()) |e| docs += e.coll.len();
        return .{
            .collections = @intCast(self.collections.count()),
            .documents = docs,
            .last_seq = self.wal.lastSeq(),
            .checkpoint_seq = self.checkpoint_seq,
            .generation = self.gen,
            .wal_bytes = self.wal_bytes,
        };
    }

    /// Checks the internal consistency of every collection.
    pub fn verify(self: *Db) Error!void {
        self.lock.lockSharedUncancelable(self.io);
        defer self.lock.unlockShared(self.io);
        for (self.collections.values()) |e| try e.coll.check();
    }

    // ---- maintenance -----------------------------------------------------

    pub fn checkpoint(self: *Db) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        return self.checkpointLocked();
    }

    /// Rebuilds a collection without its tombstones.
    pub fn compact(self: *Db, collection: []const u8) Error!void {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.opts.read_only) return error.ReadOnly;
        if (self.poisoned) return error.Poisoned;
        const e = self.collections.getPtr(collection) orelse return error.NotFound;
        // Compaction renumbers slots but changes no document: the log needs
        // no record, and a crash before the next checkpoint simply replays
        // onto the previous snapshot.
        e.coll.compact() catch |err| return mapErr(err);
        e.dirty = true;
    }

    fn checkpointLocked(self: *Db) Error!void {
        if (self.opts.read_only) return error.ReadOnly;
        if (self.poisoned) return error.Poisoned;
        const gpa = self.gpa;
        const gen = self.gen + 1;
        const seq = self.wal.lastSeq();

        // 1. Snapshots of modified collections.
        var written: std.ArrayList([]u8) = .empty;
        defer {
            for (written.items) |n| gpa.free(n);
            written.deinit(gpa);
        }
        var new_files = try gpa.alloc(?[]u8, self.collections.count());
        defer gpa.free(new_files);
        @memset(new_files, null);
        for (self.collections.values(), 0..) |e, i| {
            if (!e.dirty and e.snapshot != null) continue;
            const name = try snapshotName(gpa, gen, e.coll.name);
            written.append(gpa, name) catch |err| {
                gpa.free(name);
                return err;
            };
            try self.writeSnapshot(name, e.coll);
            new_files[i] = name;
        }
        try self.fsCall(self.fs.syncDir());

        // 2. The manifest makes the checkpoint durable.
        var w = codec.Writer.init(gpa);
        defer w.deinit();
        try codec.header(&w, manifest_magic, format_version);
        try w.int(u64, gen);
        try w.int(u64, seq);
        try w.int(u32, @intCast(self.collections.count()));
        for (self.collections.values(), new_files) |e, nf| {
            try w.blob(e.coll.name);
            try w.blob(nf orelse e.snapshot.?);
        }
        try w.finish();
        var mname_buf: [40]u8 = undefined;
        try self.fsCall(self.fs.writeAtomic(manifestName(&mname_buf, gen), w.buf.items));

        // 3. Switch to the new state, then delete what it made obsolete.
        var old_manifest_buf: [40]u8 = undefined;
        const old_manifest = if (self.gen > 0) manifestName(&old_manifest_buf, self.gen) else null;
        for (self.collections.values(), new_files) |*e, nf| {
            const file = nf orelse continue;
            if (e.snapshot) |old| self.obsolete.append(gpa, old) catch gpa.free(old);
            e.snapshot = file;
            e.dirty = false;
            for (written.items, 0..) |n, j| if (n.ptr == file.ptr) {
                _ = written.swapRemove(j);
                break;
            };
        }
        self.gen = gen;
        self.checkpoint_seq = seq;
        self.wal_bytes = 0;

        self.wal.rotate() catch |err| return self.walErr(err);
        self.wal.removeUpTo(seq) catch {};
        for (self.obsolete.items) |n| {
            self.fs.remove(n) catch {};
            gpa.free(n);
        }
        self.obsolete.clearRetainingCapacity();
        if (old_manifest) |m| self.fs.remove(m) catch {};
    }

    fn fsCall(self: *Db, r: anytype) Error!@typeInfo(@TypeOf(r)).error_union.payload {
        return r catch |e| {
            if (e == error.Crashed) self.poisoned = true;
            return mapErr(e);
        };
    }

    fn writeSnapshot(self: *Db, name: []const u8, coll: *const Collection) Error!void {
        var w = codec.Writer.init(self.gpa);
        defer w.deinit();
        try codec.header(&w, snapshot_magic, format_version);
        coll.serialize(&w, false) catch |e| return mapErr(e);
        try w.finish();
        var tmp_buf: [std.fs.max_name_bytes]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.InvalidArgument;
        const h = try self.fsCall(self.fs.create(tmp));
        {
            errdefer self.fs.close(h);
            try self.fsCall(self.fs.write(h, w.buf.items, 0));
            try self.fsCall(self.fs.sync(h));
        }
        self.fs.close(h);
        try self.fsCall(self.fs.rename(tmp, name));
    }

    fn loadManifest(self: *Db, gen: u64) !void {
        const gpa = self.gpa;
        var name_buf: [40]u8 = undefined;
        const data = try self.fs.readAll(gpa, manifestName(&name_buf, gen));
        defer gpa.free(data);
        var r = try codec.Reader.open(data, manifest_magic, format_version);
        if (try r.int(u64) != gen) return error.Corrupt;
        const seq = try r.int(u64);
        const n = try r.int(u32);
        for (0..n) |_| {
            const cname = try r.blob();
            const file = try r.blob();
            const snap = try self.fs.readAll(gpa, file);
            defer gpa.free(snap);
            var sr = try codec.Reader.open(snap, snapshot_magic, format_version);
            const coll = try Collection.deserialize(gpa, &sr);
            errdefer coll.deinit();
            if (!sr.done() or !std.mem.eql(u8, coll.name, cname)) return error.Corrupt;
            const owned = try gpa.dupe(u8, file);
            errdefer gpa.free(owned);
            const gop = try self.collections.getOrPut(gpa, coll.name);
            if (gop.found_existing) return error.Corrupt;
            gop.value_ptr.* = .{ .coll = coll, .snapshot = owned, .dirty = false };
        }
        if (!r.done()) return error.Corrupt;
        self.gen = gen;
        self.checkpoint_seq = seq;
    }

    /// Deletes files left by interrupted checkpoints and older generations.
    /// Only called when the newest manifest present was the one loaded.
    fn removeOrphans(self: *Db, names: []const []u8) Error!void {
        var removed = false;
        for (names) |name| {
            const orphan = blk: {
                if (std.mem.endsWith(u8, name, ".tmp") and !std.mem.startsWith(u8, name, "wal-")) break :blk true;
                if (parseManifestName(name)) |g| break :blk g != self.gen;
                if (std.mem.startsWith(u8, name, "snap-") and std.mem.endsWith(u8, name, ".vtx")) {
                    for (self.collections.values()) |e| {
                        if (e.snapshot) |s| if (std.mem.eql(u8, s, name)) break :blk false;
                    }
                    break :blk true;
                }
                break :blk false;
            };
            if (orphan) {
                try self.fsCall(self.fs.remove(name));
                removed = true;
            }
        }
        if (removed) try self.fsCall(self.fs.syncDir());
        self.wal.removeUpTo(self.checkpoint_seq) catch |e| return mapErr(e);
    }
};

fn manifestName(buf: *[40]u8, gen: u64) []const u8 {
    return std.fmt.bufPrint(buf, "MANIFEST-{d:0>20}", .{gen}) catch unreachable;
}

fn parseManifestName(name: []const u8) ?u64 {
    if (name.len != 29 or !std.mem.startsWith(u8, name, "MANIFEST-")) return null;
    return std.fmt.parseInt(u64, name[9..], 10) catch null;
}

fn snapshotName(gpa: Allocator, gen: u64, coll: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "snap-{d:0>20}-{s}.vtx", .{ gen, coll });
}

pub fn mapErr(e: anyerror) Error {
    inline for (@typeInfo(Error).error_set.?) |err| {
        if (e == @field(anyerror, err.name)) return @field(Error, err.name);
    }
    return switch (e) {
        error.SlotReused, error.DimensionMismatch, error.InvalidConfig => error.Corrupt,
        else => error.InputOutput,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Filter = coll_mod.Filter;

// Field storage for the ops built by `note`.
var f1: [2]schema.FieldValue = undefined;
var f2: [2]schema.FieldValue = undefined;
var f3: [2]schema.FieldValue = undefined;
var f4: [2]schema.FieldValue = undefined;
var f5: [2]schema.FieldValue = undefined;
var f6: [2]schema.FieldValue = undefined;
var f7: [2]schema.FieldValue = undefined;
var f8: [2]schema.FieldValue = undefined;
var f9: [2]schema.FieldValue = undefined;
var f10: [2]schema.FieldValue = undefined;
var f11: [2]schema.FieldValue = undefined;
var f12: [2]schema.FieldValue = undefined;
var f13: [2]schema.FieldValue = undefined;

var test_threaded: std.Io.Threaded = .init_single_threaded;

fn testIo() std.Io {
    return test_threaded.io();
}

const notes_schema: Schema = .{
    .vector = .{ .dim = 3 },
    .fields = &.{
        .{ .name = "body", .type = .text },
        .{ .name = "n", .type = .int },
    },
};

/// Builds a put; `fields` holds the field list and must outlive the op.
fn note(fields: *[2]schema.FieldValue, id: []const u8, n: i64, body: []const u8, v: []const f32) Op {
    fields.* = .{
        .{ .field = "body", .value = .{ .text = body } },
        .{ .field = "n", .value = .{ .int = n } },
    };
    return .{ .put = .{ .collection = "notes", .doc = .{ .id = id, .vector = v, .payload = body, .fields = fields } } };
}

test "create, write, search, reopen" {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, 1);
    defer sim.deinit();
    {
        const db = try Db.open(gpa, testIo(), sim.fs(), .{});
        _ = try db.createCollection("notes", notes_schema);
        _ = try db.write(&.{
            note(&f1, "a", 1, "metro bundler cache", &.{ 1, 0, 0 }),
            note(&f2, "b", 2, "zig build system", &.{ 0, 1, 0 }),
        });
        try testing.expectError(error.AlreadyExists, db.createCollection("notes", notes_schema));
        try testing.expectError(error.NotFound, db.put("missing", .{ .id = "x" }));
        try testing.expectError(error.InvalidDocument, db.put("notes", .{ .id = "x", .vector = &.{1} }));
        // A failing batch changes nothing, even its valid operations.
        try testing.expectError(error.InvalidDocument, db.write(&.{ note(&f3, "c", 3, "ok", &.{ 0, 0, 1 }), .{ .put = .{ .collection = "notes", .doc = .{ .id = "" } } } }));
        try testing.expectEqual(@as(u32, 2), try db.count("notes"));
        try db.close();
    }
    const db = try Db.open(gpa, testIo(), sim.fs(), .{});
    defer db.close() catch {};
    try testing.expectEqual(@as(u32, 2), try db.count("notes"));
    var res = try db.search("notes", .{ .vector = &.{ 1, 0.1, 0 }, .text = "metro", .k = 1 }, .{ .fields = &.{"n"} });
    defer res.deinit();
    try testing.expectEqualStrings("a", res.items[0].id);
    try testing.expectEqualStrings("metro bundler cache", res.items[0].payload.?);
    try testing.expectEqual(@as(i64, 1), res.items[0].fields[0].value.int);

    var got = (try db.get("notes", "b")).?;
    defer got.deinit();
    try testing.expectEqualStrings("zig build system", got.items[0].fields[0].value.text);
    try testing.expect(try db.get("notes", "zz") == null);
}

test "checkpoint, drop, compact, reopen" {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, 2);
    defer sim.deinit();
    {
        const db = try Db.open(gpa, testIo(), sim.fs(), .{});
        _ = try db.createCollection("notes", notes_schema);
        _ = try db.createCollection("tmp", .{});
        _ = try db.write(&.{ note(&f4, "a", 1, "one", &.{ 1, 0, 0 }), note(&f5, "b", 2, "two", &.{ 0, 1, 0 }) });
        try db.checkpoint();
        try testing.expectEqual(@as(u64, 1), db.gen);
        _ = try db.delete("notes", "a");
        _ = try db.dropCollection("tmp");
        try db.compact("notes");
        try db.checkpoint();
        _ = try db.put("notes", (note(&f6, "c", 3, "three", &.{ 0, 0, 1 })).put.doc);
        try db.close(); // checkpoints again
    }
    const names = try sim.fs().list(gpa);
    defer fsmod.freeList(gpa, names);
    var manifests: usize = 0;
    var snaps: usize = 0;
    for (names) |n| {
        if (parseManifestName(n) != null) manifests += 1;
        if (std.mem.startsWith(u8, n, "snap-")) snaps += 1;
    }
    try testing.expectEqual(@as(usize, 1), manifests);
    try testing.expectEqual(@as(usize, 1), snaps);

    const db = try Db.open(gpa, testIo(), sim.fs(), .{});
    defer db.close() catch {};
    try testing.expectEqual(@as(u32, 2), try db.count("notes"));
    try testing.expectError(error.NotFound, db.count("tmp"));
    try testing.expect(try db.get("notes", "a") == null);
}

test "damaged newest manifest: open fails and deletes nothing" {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, 3);
    defer sim.deinit();
    const fs = sim.fs();
    {
        const db = try Db.open(gpa, testIo(), fs, .{});
        _ = try db.createCollection("notes", notes_schema);
        _ = try db.write(&.{note(&f7, "a", 1, "one", &.{ 1, 0, 0 })});
        try db.checkpoint();
        _ = try db.write(&.{note(&f8, "b", 2, "two", &.{ 0, 1, 0 })});
        try db.checkpoint();
        try db.close();
    }
    var name_buf: [40]u8 = undefined;
    const h = try fs.open(manifestName(&name_buf, 2), true);
    try fs.write(h, "XX", 12);
    fs.close(h);

    const before = try fs.list(gpa);
    defer fsmod.freeList(gpa, before);
    // Generation 1 is gone (its log was removed by the second checkpoint):
    // the gap is detected instead of silently losing "b".
    try testing.expectError(error.Corrupt, Db.open(gpa, testIo(), fs, .{}));
    const after = try fs.list(gpa);
    defer fsmod.freeList(gpa, after);
    try testing.expectEqual(before.len, after.len);
}

test "read-only open writes nothing" {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, 4);
    defer sim.deinit();
    {
        const db = try Db.open(gpa, testIo(), sim.fs(), .{ .checkpoint_after = 0 });
        _ = try db.createCollection("notes", notes_schema);
        _ = try db.write(&.{note(&f9, "a", 1, "one", &.{ 1, 0, 0 })});
        try db.checkpoint();
        _ = try db.write(&.{note(&f10, "b", 2, "two", &.{ 0, 1, 0 })});
        db.wal.deinit(); // simulate a crash: no close, no checkpoint
        db.freeState();
        gpa.destroy(db);
    }
    const ops = sim.ops;
    const db = try Db.open(gpa, testIo(), sim.fs(), .{ .read_only = true });
    try testing.expectEqual(@as(u32, 2), try db.count("notes"));
    try testing.expectError(error.ReadOnly, db.delete("notes", "a"));
    var res = try db.search("notes", .{ .text = "two" }, .{});
    res.deinit();
    try db.close();
    try testing.expectEqual(ops, sim.ops);
}

test "failed log sync poisons the handle; reopening recovers" {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, 5);
    defer sim.deinit();
    {
        const db = try Db.open(gpa, testIo(), sim.fs(), .{});
        _ = try db.createCollection("notes", notes_schema);
        sim.sync_fail_at = sim.ops + 1; // the sync after the next append
        try testing.expectError(error.InputOutput, db.write(&.{note(&f11, "a", 1, "one", &.{ 1, 0, 0 })}));
        try testing.expectError(error.Poisoned, db.write(&.{note(&f12, "b", 2, "two", &.{ 0, 1, 0 })}));
        try testing.expectError(error.Poisoned, db.close());
    }
    try sim.crash();
    const db = try Db.open(gpa, testIo(), sim.fs(), .{});
    defer db.close() catch {};
    try testing.expectEqual(@as(u32, 0), try db.count("notes"));
}

/// Workload for the crash tests: batch i (1-based, after the create) puts
/// document "d<i mod 7>" with n = i, and every fifth batch deletes one.
fn workloadBatch(i: usize, fields: *[2]schema.FieldValue, id_buf: []u8, body_buf: []u8, v: *[3]f32) Op {
    const id = std.fmt.bufPrint(id_buf, "d{d}", .{i % 7}) catch unreachable;
    if (i % 5 == 0) return .{ .delete = .{ .collection = "notes", .id = id } };
    const body = std.fmt.bufPrint(body_buf, "note number {d} about topic{d}", .{ i, i % 3 }) catch unreachable;
    v.* = .{ @floatFromInt(i % 3 + 1), @floatFromInt(i % 5), 1 };
    return note(fields, id, @intCast(i), body, v);
}

/// Expected value of `n` for each id after the first `m` batches.
fn model(m: usize) [7]?i64 {
    var out: [7]?i64 = @splat(null);
    for (1..m + 1) |i| out[i % 7] = if (i % 5 == 0) null else @intCast(i);
    return out;
}

/// Random outcomes tried per crash point (each picks what survives).
const crash_seeds = 4;

fn crashRun(seed: u64, crash_at: u64, recovery_crash: ?u64) !void {
    const gpa = testing.allocator;
    var sim: fsmod.Sim = .init(gpa, seed);
    defer sim.deinit();
    const opts: Options = .{ .checkpoint_after = 600, .wal_segment_size = 300 };
    const total = 25;

    var acked: usize = 0;
    var created = false;
    {
        const db = try Db.open(gpa, testIo(), sim.fs(), opts);
        sim.crash_at = crash_at;
        run: {
            _ = db.createCollection("notes", notes_schema) catch break :run;
            created = true;
            var id_buf: [8]u8 = undefined;
            var body_buf: [64]u8 = undefined;
            var v: [3]f32 = undefined;
            for (1..total + 1) |i| {
                var fields: [2]schema.FieldValue = undefined;
                _ = db.write(&.{workloadBatch(i, &fields, &id_buf, &body_buf, &v)}) catch break :run;
                acked = i;
            }
        }
        db.close() catch {};
    }
    try sim.crash();

    if (recovery_crash) |at| {
        sim.crash_at = sim.ops + at;
        if (Db.open(gpa, testIo(), sim.fs(), opts)) |db| {
            db.close() catch {};
        } else |e| try testing.expectEqual(error.Crashed, e);
        try sim.crash();
    }

    const db = try Db.open(gpa, testIo(), sim.fs(), opts);
    defer db.close() catch {};
    const last = db.wal.lastSeq();
    if (last == 0) {
        try testing.expect(!created);
        try testing.expectEqual(@as(usize, 0), db.collections.count());
        return;
    }
    const m: usize = @intCast(last - 1); // seq 1 is the create
    try testing.expect(m >= acked and m <= total);
    const want = model(m);
    var live: u32 = 0;
    for (want, 0..) |w, i| {
        var id_buf: [8]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "d{d}", .{i});
        const got = try db.get("notes", id);
        if (w) |n| {
            var r = got orelse return error.TestUnexpectedResult;
            defer r.deinit();
            try testing.expectEqual(n, r.items[0].fields[1].value.int);
            live += 1;
        } else {
            if (got) |r| {
                var rr = r;
                rr.deinit();
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqual(live, try db.count("notes"));
    try db.verify();
    // Indexes agree with the documents.
    var res = try db.search("notes", .{ .text = "note", .k = 50 }, .{});
    defer res.deinit();
    try testing.expectEqual(@as(usize, live), res.items.len);
    // The database accepts writes after recovery.
    _ = try db.delete("notes", "d0");
}

test "crash at every operation of a workload with checkpoints" {
    var at: u64 = 0;
    while (at < 260) : (at += 1) {
        for (0..crash_seeds) |s| {
            try crashRun(at * 31 + s, at, null);
            try crashRun(at * 31 + s + 7777, at, (at + s) % 9);
        }
    }
}
