//! CRC-32C (Castagnoli), the checksum of every file. Uses the CPU's CRC
//! instructions when the target has them (ARMv8 CRC, x86 SSE4.2), about ten
//! times faster than the table-driven `std.hash.crc.Crc32Iscsi`, which is the
//! fallback and the reference in tests.

const std = @import("std");
const builtin = @import("builtin");

const arch = builtin.cpu.arch;
const has_arm_crc = arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
const has_sse42 = arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);

pub const accelerated = has_arm_crc or has_sse42;

pub fn hash(data: []const u8) u32 {
    var c = Crc.init();
    c.update(data);
    return c.final();
}

pub const Crc = struct {
    state: u32,

    pub fn init() Crc {
        return .{ .state = 0xFFFF_FFFF };
    }

    pub fn update(c: *Crc, data: []const u8) void {
        if (!accelerated) {
            // Same polynomial, reflection and init: continue the std state.
            var s: std.hash.crc.Crc32Iscsi = .{ .crc = c.state };
            s.update(data);
            c.state = s.crc;
            return;
        }
        var crc = c.state;
        var i: usize = 0;
        while (i + 8 <= data.len) : (i += 8) crc = step64(crc, std.mem.readInt(u64, data[i..][0..8], .little));
        while (i < data.len) : (i += 1) crc = step8(crc, data[i]);
        c.state = crc;
    }

    pub fn final(c: Crc) u32 {
        return ~c.state;
    }
};

inline fn step64(crc: u32, v: u64) u32 {
    if (has_arm_crc) {
        return asm ("crc32cx %[out:w], %[crc:w], %[v]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [v] "r" (v),
        );
    }
    var c: u64 = crc;
    asm ("crc32q %[v], %[c]"
        : [c] "+r" (c),
        : [v] "r" (v),
    );
    return @truncate(c);
}

inline fn step8(crc: u32, v: u8) u32 {
    if (has_arm_crc) {
        return asm ("crc32cb %[out:w], %[crc:w], %[v:w]"
            : [out] "=r" (-> u32),
            : [crc] "r" (crc),
              [v] "r" (@as(u32, v)),
        );
    }
    var c: u32 = crc;
    asm ("crc32b %[v], %[c]"
        : [c] "+r" (c),
        : [v] "r" (v),
    );
    return c;
}

test "matches the reference on every length and split" {
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [300]u8 = undefined;
    prng.random().bytes(&buf);
    for (0..buf.len) |n| {
        const want = std.hash.crc.Crc32Iscsi.hash(buf[0..n]);
        try std.testing.expectEqual(want, hash(buf[0..n]));
        // Incremental updates give the same result.
        const cut = n / 3;
        var c = Crc.init();
        c.update(buf[0..cut]);
        c.update(buf[cut..n]);
        try std.testing.expectEqual(want, c.final());
    }
    try std.testing.expectEqual(@as(u32, 0xE3069283), hash("123456789"));
}
