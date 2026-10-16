//! VectixDB: embedded hybrid search engine (vectors, full text, exact match,
//! metadata filters). See docs/SPEC.md.

pub const version = "0.1.0";

pub const fs = @import("fs.zig");
pub const wal = @import("wal.zig");
pub const distance = @import("distance.zig");
pub const crc32c = @import("crc32c.zig");
pub const codec = @import("codec.zig");
pub const topk = @import("topk.zig");
pub const hnsw = @import("hnsw.zig");
pub const analyzer = @import("analyzer.zig");
pub const bm25 = @import("bm25.zig");
pub const schema = @import("schema.zig");
pub const filter = @import("filter.zig");
pub const collection = @import("collection.zig");
pub const batch = @import("batch.zig");
pub const db = @import("db.zig");
pub const c_api = @import("c_api.zig");

comptime {
    _ = c_api; // export the C symbols
}

test {
    @import("std").testing.refAllDecls(@This());
}
