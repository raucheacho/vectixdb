//! Binary heaps over (slot, distance) pairs, used by graph search and top-k selection.

const std = @import("std");

pub const Item = extern struct {
    slot: u32,
    dist: f32,
};

/// `min = true` pops the smallest distance first, `min = false` the largest.
pub fn Heap(comptime min: bool) type {
    return struct {
        const Self = @This();

        items: std.ArrayList(Item) = .empty,

        // Ties are broken on slot so that results are deterministic.
        inline fn before(a: Item, b: Item) bool {
            if (a.dist == b.dist) return a.slot > b.slot;
            return if (min) a.dist < b.dist else a.dist > b.dist;
        }

        pub fn deinit(h: *Self, gpa: std.mem.Allocator) void {
            h.items.deinit(gpa);
        }

        pub fn len(h: *const Self) usize {
            return h.items.items.len;
        }

        pub fn peek(h: *const Self) ?Item {
            return if (h.items.items.len == 0) null else h.items.items[0];
        }

        pub fn push(h: *Self, gpa: std.mem.Allocator, item: Item) !void {
            try h.items.append(gpa, item);
            const xs = h.items.items;
            var i = xs.len - 1;
            while (i > 0) {
                const p = (i - 1) / 2;
                if (!before(xs[i], xs[p])) break;
                std.mem.swap(Item, &xs[i], &xs[p]);
                i = p;
            }
        }

        pub fn pop(h: *Self) ?Item {
            const xs = h.items.items;
            if (xs.len == 0) return null;
            const top = xs[0];
            xs[0] = xs[xs.len - 1];
            h.items.items.len -= 1;
            const n = h.items.items.len;
            var i: usize = 0;
            while (true) {
                const l = 2 * i + 1;
                if (l >= n) break;
                var c = l;
                if (l + 1 < n and before(xs[l + 1], xs[l])) c = l + 1;
                if (!before(xs[c], xs[i])) break;
                std.mem.swap(Item, &xs[i], &xs[c]);
                i = c;
            }
            return top;
        }
    };
}

pub const MinHeap = Heap(true);
pub const MaxHeap = Heap(false);

pub fn ascending(_: void, a: Item, b: Item) bool {
    if (a.dist == b.dist) return a.slot < b.slot;
    return a.dist < b.dist;
}

pub fn descending(_: void, a: Item, b: Item) bool {
    if (a.dist == b.dist) return a.slot < b.slot;
    return a.dist > b.dist;
}

test "heaps order" {
    const gpa = std.testing.allocator;
    var mn: MinHeap = .{};
    defer mn.deinit(gpa);
    var mx: MaxHeap = .{};
    defer mx.deinit(gpa);
    const ds = [_]f32{ 5, 1, 4, 2, 3 };
    for (ds, 0..) |d, i| {
        try mn.push(gpa, .{ .slot = @intCast(i), .dist = d });
        try mx.push(gpa, .{ .slot = @intCast(i), .dist = d });
    }
    var prev: f32 = -1;
    while (mn.pop()) |it| {
        try std.testing.expect(it.dist >= prev);
        prev = it.dist;
    }
    try std.testing.expectEqual(@as(f32, 5), mx.pop().?.dist);
}
