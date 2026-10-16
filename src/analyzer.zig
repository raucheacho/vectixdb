//! Text analyzer shared by indexing and querying.
//!
//! - Words are runs of letters and digits in any script. `_`, `-` and `.`
//!   between two word characters join a compound: the compound is emitted
//!   first, then each part (`ERR_MODULE_NOT_FOUND` gives
//!   `err_module_not_found`, `err`, `module`, `not`, `found`).
//! - Folding: lowercase (Latin, Greek, Cyrillic); Latin diacritics removed
//!   (`Été` -> `ete`, `Œ` -> `oe`, `ß` -> `ss`); combining marks dropped.
//! - Arabic: harakat and tatweel removed; alef variants -> ا, ى -> ي,
//!   ة -> ه; Arabic-Indic digits -> ASCII digits.
//! - No stemming, so results stay predictable.
//! - Scripts without spaces (Chinese, Japanese) yield one token per run.

const std = @import("std");

pub const max_token_len = 64;
const max_compound_len = 256;
const max_parts = 32;

pub const Analyzer = struct {
    text: []const u8,
    pos: usize = 0,

    norm: [max_compound_len]u8 = undefined,
    norm_len: usize = 0,
    /// Part boundaries in `norm`: part i is norm[starts[i]..ends[i]].
    starts: [max_parts]u16 = undefined,
    ends: [max_parts]u16 = undefined,
    parts: usize = 0,
    /// Next thing to emit: 0 = the compound, i + 1 = part i.
    cursor: usize = 0,

    pub fn init(text: []const u8) Analyzer {
        return .{ .text = text };
    }

    /// Returns the next token. The slice is valid until the next call.
    pub fn next(a: *Analyzer) ?[]const u8 {
        while (true) {
            if (a.parts > 0) {
                if (a.cursor == 0) {
                    a.cursor = 1;
                    if (a.parts > 1) return truncate(a.norm[0..a.norm_len]);
                }
                if (a.cursor <= a.parts) {
                    const i = a.cursor - 1;
                    a.cursor += 1;
                    return truncate(a.norm[a.starts[i]..a.ends[i]]);
                }
                a.parts = 0;
            }
            if (!a.loadCompound()) return null;
        }
    }

    /// Scans the next compound and normalizes it into `norm`.
    fn loadCompound(a: *Analyzer) bool {
        const s = a.text;
        // Skip to the first word character.
        while (a.pos < s.len) {
            const cp = decode(s, a.pos);
            if (classify(cp.value) == .word) break;
            a.pos += cp.len;
        }
        if (a.pos >= s.len) return false;

        a.norm_len = 0;
        a.parts = 0;
        a.cursor = 0;
        var part_start: usize = 0;
        var in_part = false;
        while (a.pos < s.len) {
            const cp = decode(s, a.pos);
            switch (classify(cp.value)) {
                .word => {
                    if (!in_part) {
                        part_start = a.norm_len;
                        in_part = true;
                    }
                    a.pushFolded(cp.value);
                    a.pos += cp.len;
                },
                .mark => a.pos += cp.len, // dropped, does not break the word
                .joiner => {
                    // A joiner continues the compound only between word characters.
                    if (a.pos + cp.len >= s.len) break;
                    const nxt = decode(s, a.pos + cp.len);
                    if (classify(nxt.value) != .word) break;
                    a.endPart(part_start, &in_part);
                    if (a.norm_len < max_compound_len) {
                        a.norm[a.norm_len] = @intCast(cp.value);
                        a.norm_len += 1;
                    }
                    a.pos += cp.len;
                },
                .separator => break,
            }
        }
        a.endPart(part_start, &in_part);
        if (a.parts == 0) return a.loadCompound(); // only marks: skip
        return true;
    }

    fn endPart(a: *Analyzer, start: usize, in_part: *bool) void {
        if (!in_part.*) return;
        in_part.* = false;
        if (a.norm_len == start) return;
        if (a.parts == max_parts) {
            a.ends[max_parts - 1] = @intCast(a.norm_len); // merge the rest into the last part
            return;
        }
        a.starts[a.parts] = @intCast(start);
        a.ends[a.parts] = @intCast(a.norm_len);
        a.parts += 1;
    }

    fn pushFolded(a: *Analyzer, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const out = fold(cp, &tmp);
        if (a.norm_len + out.len > max_compound_len) return;
        @memcpy(a.norm[a.norm_len..][0..out.len], out);
        a.norm_len += out.len;
    }
};

/// Cuts a token to `max_token_len` bytes without splitting a UTF-8 sequence.
fn truncate(t: []const u8) []const u8 {
    if (t.len <= max_token_len) return t;
    var end: usize = max_token_len;
    while (end > 0 and t[end] & 0xC0 == 0x80) end -= 1;
    return t[0..end];
}

const Decoded = struct { value: u21, len: usize };

/// Decodes one code point; invalid bytes decode as U+FFFD (a separator).
fn decode(s: []const u8, pos: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(s[pos]) catch return .{ .value = 0xFFFD, .len = 1 };
    if (pos + len > s.len) return .{ .value = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(s[pos..][0..len]) catch return .{ .value = 0xFFFD, .len = 1 };
    return .{ .value = cp, .len = len };
}

const Class = enum { word, mark, joiner, separator };

fn classify(cp: u21) Class {
    if (cp < 0x80) {
        if (std.ascii.isAlphanumeric(@intCast(cp))) return .word;
        return switch (cp) {
            '_', '-', '.' => .joiner,
            else => .separator,
        };
    }
    return switch (cp) {
        0x80...0xBF, 0xD7, 0xF7 => .separator, // Latin-1 punctuation and symbols
        0x0300...0x036F => .mark, // combining diacritics
        0x060C, 0x061B, 0x061F, 0x066A...0x066D, 0x06D4 => .separator, // Arabic punctuation
        0x0640, 0x064B...0x065F, 0x0670 => .mark, // tatweel, harakat, superscript alef
        0x2000...0x2BFF => .separator, // punctuation, symbols, arrows, math
        0x3000...0x303F => .separator, // CJK punctuation
        0xFE30...0xFE4F, 0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFEFF, 0xFFFD => .separator,
        0x1F000...0x1FAFF => .separator, // emoji and pictographs
        else => .word,
    };
}

/// Latin Extended-A (U+0100..U+017F) to ASCII base letters; '*' marks the
/// two-letter ligatures handled separately.
const latin_ext_a = "aaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiii**jjkkkllllllllllnnnnnnnnnoooooo**rrrrrrssssssssttttttuuuuuuuuuuuuwwyyyzzzzzzs";

comptime {
    std.debug.assert(latin_ext_a.len == 0x80);
}

fn fold(cp: u21, buf: *[4]u8) []const u8 {
    const mapped: u21 = switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xFF => return foldLatin1(cp, buf),
        0x0100...0x017F => {
            if (cp == 0x0132 or cp == 0x0133) return "ij";
            if (cp == 0x0152 or cp == 0x0153) return "oe";
            buf[0] = latin_ext_a[cp - 0x0100];
            return buf[0..1];
        },
        0x0391...0x03A9 => cp + 0x20, // Greek capitals
        0x03C2 => 0x03C3, // final sigma
        0x0400...0x040F => cp + 0x50, // Cyrillic Ѐ..Џ
        0x0410...0x042F => cp + 0x20, // Cyrillic А..Я
        0x0622, 0x0623, 0x0625, 0x0671 => 0x0627, // alef variants -> alef
        0x0649 => 0x064A, // alef maksura -> yeh
        0x0629 => 0x0647, // teh marbuta -> heh
        0x0660...0x0669 => cp - 0x0660 + '0', // Arabic-Indic digits
        0x06F0...0x06F9 => cp - 0x06F0 + '0', // Extended Arabic-Indic digits
        else => cp,
    };
    const n = std.unicode.utf8Encode(mapped, buf) catch return "";
    return buf[0..n];
}

fn foldLatin1(cp: u21, buf: *[4]u8) []const u8 {
    // Upper and lower case share the same layout, 0x20 apart.
    const lower: u21 = if (cp >= 0xC0 and cp <= 0xDE and cp != 0xD7) cp + 0x20 else cp;
    const s: []const u8 = switch (lower) {
        0xE0...0xE5 => "a",
        0xE6 => "ae",
        0xE7 => "c",
        0xE8...0xEB => "e",
        0xEC...0xEF => "i",
        0xF0 => "d",
        0xF1 => "n",
        0xF2...0xF6, 0xF8 => "o",
        0xF9...0xFC => "u",
        0xFD, 0xFF => "y",
        0xFE => "th",
        0xDF => "ss",
        else => {
            const n = std.unicode.utf8Encode(lower, buf) catch return "";
            return buf[0..n];
        },
    };
    return s;
}

// ---------------------------------------------------------------------------
// Tests

fn expectTokens(text: []const u8, want: []const []const u8) !void {
    var a = Analyzer.init(text);
    for (want) |w| {
        const got = a.next() orelse {
            std.debug.print("missing token {s}\n", .{w});
            return error.TestExpectedEqual;
        };
        try std.testing.expectEqualStrings(w, got);
    }
    if (a.next()) |extra| {
        std.debug.print("unexpected token {s}\n", .{extra});
        return error.TestExpectedEqual;
    }
}

test "latin folding" {
    try expectTokens("L'Été déjà: Œuvre, Straße & Ångström Łódź", &.{ "l", "ete", "deja", "oeuvre", "strasse", "angstrom", "lodz" });
}

test "compounds emit the whole and the parts" {
    try expectTokens("ERR_MODULE_NOT_FOUND at foo.bar-baz.", &.{
        "err_module_not_found", "err", "module", "not", "found", "at", "foo.bar-baz", "foo", "bar", "baz",
    });
    try expectTokens("__init__ --flag v1.2 end.", &.{ "init", "flag", "v1.2", "v1", "2", "end" });
    try expectTokens("café-crème", &.{ "cafe-creme", "cafe", "creme" });
}

test "arabic normalization" {
    // أحمد with harakat and tatweel, إسلام, مدرسة, على, ١٢٣
    try expectTokens("أَحْمَـــد إسلام مدرسة على ١٢٣", &.{ "احمد", "اسلام", "مدرسه", "علي", "123" });
}

test "greek and cyrillic lowercase, combining marks dropped" {
    try expectTokens("ΑΘΗΝΑ Москва e\u{0301}te\u{0301}", &.{ "αθηνα", "москва", "ete" });
}

test "separators, emoji, invalid bytes, long tokens" {
    try expectTokens("a\u{00A0}b — c 🚀 d\xFFe 日本語", &.{ "a", "b", "c", "d", "e", "日本語" });
    var a = Analyzer.init("x" ** 100);
    try std.testing.expectEqual(@as(usize, max_token_len), a.next().?.len);
    try std.testing.expect(a.next() == null);
    var b = Analyzer.init("é" ** 40); // 80 bytes of 2-byte sequences, folded to 40 bytes
    try std.testing.expectEqual(@as(usize, 40), b.next().?.len);
    var c = Analyzer.init("日" ** 30); // 90 bytes, cut on a code point boundary
    const t = c.next().?;
    try std.testing.expect(t.len <= max_token_len and t.len % 3 == 0);
}
