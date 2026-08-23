//! A nesting-depth check that runs BEFORE std.json sees the text.
//!
//! Why this exists: `std.json.parseFromSliceLeaky(std.json.Value, ...)`
//! builds the value tree by recursion, and Zig 0.16 puts no depth limit on
//! it. A document of ten thousand `[` characters therefore overflows the
//! stack inside std.json — the process dies before any charttable code runs,
//! so no limit inside the expression parser or the evaluator can catch it.
//!
//! The check is a single pass over the bytes. It counts bracket nesting
//! outside of string literals; it does not validate the document, because
//! std.json does that immediately afterwards. A false accept is harmless
//! (std.json rejects it); the only job here is to refuse the depths that
//! would crash the parse.

const std = @import("std");

/// Deepest nesting any caller accepts by default.
///
/// A hand-written style reaches maybe ten levels, and a generated one with
/// long `case`/`match` chains reaches perhaps thirty. 128 leaves that room
/// untouched. It is also far below the depth that costs a stack: the parse
/// is one recursive pass, and the later passes over the same tree (expression
/// parse, typecheck, evaluate) each recurse to the same depth separately, not
/// on top of one another.
pub const default_max: u32 = 128;

/// True when no array or object in `text` nests deeper than `max`.
pub fn withinDepth(text: []const u8, max: u32) bool {
    var depth: u32 = 0;
    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                if (depth > max) return false;
            },
            // Saturating: an unbalanced closer is std.json's error to report,
            // not a reason to wrap the counter here.
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return true;
}

/// `withinDepth` at `default_max`.
pub fn ok(text: []const u8) bool {
    return withinDepth(text, default_max);
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "flat and shallow documents pass" {
    try testing.expect(ok("{}"));
    try testing.expect(ok("[]"));
    try testing.expect(ok("{\"a\": [1, 2, {\"b\": 3}]}"));
    try testing.expect(ok("null"));
    try testing.expect(ok(""));
}

test "depth is counted to the limit and no further" {
    var buf: [512]u8 = undefined;
    // Exactly at the limit passes; one more level does not.
    for (buf[0..8]) |*c| c.* = '[';
    try testing.expect(withinDepth(buf[0..8], 8));
    try testing.expect(!withinDepth(buf[0..8], 7));
}

test "brackets inside strings do not count" {
    try testing.expect(withinDepth("{\"k\": \"[[[[[[[[[[\"}", 2));
    // An escaped quote keeps the scanner inside the string.
    try testing.expect(withinDepth("{\"k\": \"a\\\"[[[[[[[[\"}", 2));
    // A trailing backslash before the closing quote must not swallow it.
    try testing.expect(withinDepth("{\"k\": \"a\\\\\"}", 2));
}

test "a deep document is rejected" {
    const a = testing.allocator;
    const deep = try a.alloc(u8, 10_000);
    defer a.free(deep);
    @memset(deep, '[');
    try testing.expect(!ok(deep));
}

test "siblings are not cumulative" {
    // Ten thousand adjacent pairs are depth 1, not depth 10000.
    const a = testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    for (0..10_000) |_| try list.appendSlice(a, "[]");
    try testing.expect(ok(list.items));
}

test "the guard agrees with what std.json survives" {
    const a = testing.allocator;
    // A document just inside the limit must still parse.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    for (0..default_max) |_| try list.append(a, '[');
    for (0..default_max) |_| try list.append(a, ']');
    try testing.expect(ok(list.items));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), list.items, .{});
}
