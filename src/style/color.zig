//! CSS color parsing for style properties and `to-color`: #hex (3/4/6/8),
//! rgb()/rgba(), hsl()/hsla(), and named colors. Grammar per the published
//! CSS Color specification (the style spec defers to CSS for color syntax).

const std = @import("std");
const Color = @import("value.zig").Color;

fn hexNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

fn hexByte(hi: u8, lo: u8) ?f32 {
    const h = hexNibble(hi) orelse return null;
    const l = hexNibble(lo) orelse return null;
    return @as(f32, @floatFromInt(@as(u8, h) * 16 + l)) / 255.0;
}

fn parseHex(s: []const u8) ?Color {
    switch (s.len) {
        3, 4 => {
            var c: [4]f32 = .{ 0, 0, 0, 1 };
            for (s, 0..) |ch, i| {
                const n = hexNibble(ch) orelse return null;
                c[i] = @as(f32, @floatFromInt(@as(u8, n) * 17)) / 255.0;
            }
            return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
        },
        6, 8 => {
            var c: [4]f32 = .{ 0, 0, 0, 1 };
            var i: usize = 0;
            while (i * 2 < s.len) : (i += 1) {
                c[i] = hexByte(s[i * 2], s[i * 2 + 1]) orelse return null;
            }
            return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
        },
        else => return null,
    }
}

/// Split "a, b, c" (or space-separated) into up to 4 trimmed args.
fn splitArgs(body: []const u8, out: *[4][]const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, body, ',');
    // Modern space-separated syntax ("rgb(1 2 3 / .5)") is normalized first.
    if (std.mem.indexOfScalar(u8, body, ',') == null) {
        var buf: [4][]const u8 = undefined;
        var m: usize = 0;
        var wit = std.mem.tokenizeAny(u8, body, " \t/");
        while (wit.next()) |tok| {
            if (m >= 4) return null;
            buf[m] = tok;
            m += 1;
        }
        out.* = buf;
        return m;
    }
    while (it.next()) |part| {
        if (n >= 4) return null;
        out[n] = std.mem.trim(u8, part, " \t");
        if (out[n].len == 0) return null;
        n += 1;
    }
    return n;
}

/// A number, or a percentage scaled so 100% = `pct_base`.
fn parseComponent(s: []const u8, pct_base: f32) ?f32 {
    if (s.len == 0) return null;
    if (s[s.len - 1] == '%') {
        const p = std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch return null;
        return p / 100.0 * pct_base;
    }
    return std.fmt.parseFloat(f32, s) catch return null;
}

fn parseRgbFunc(body: []const u8) ?Color {
    var args: [4][]const u8 = undefined;
    const n = splitArgs(body, &args) orelse return null;
    if (n < 3) return null;
    const r = parseComponent(args[0], 255.0) orelse return null;
    const g = parseComponent(args[1], 255.0) orelse return null;
    const b = parseComponent(args[2], 255.0) orelse return null;
    const a: f32 = if (n == 4) parseComponent(args[3], 1.0) orelse return null else 1.0;
    return .{
        .r = std.math.clamp(r / 255.0, 0, 1),
        .g = std.math.clamp(g / 255.0, 0, 1),
        .b = std.math.clamp(b / 255.0, 0, 1),
        .a = std.math.clamp(a, 0, 1),
    };
}

fn hueToRgb(p: f32, q: f32, t0: f32) f32 {
    var t = t0;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

fn parseHslFunc(body: []const u8) ?Color {
    var args: [4][]const u8 = undefined;
    const n = splitArgs(body, &args) orelse return null;
    if (n < 3) return null;
    var h = parseComponent(std.mem.trimEnd(u8, args[0], "deg"), 360.0) orelse return null;
    h = @mod(h / 360.0, 1.0);
    const s = std.math.clamp((parseComponent(args[1], 100.0) orelse return null) / 100.0, 0, 1);
    const l = std.math.clamp((parseComponent(args[2], 100.0) orelse return null) / 100.0, 0, 1);
    const a: f32 = if (n == 4) std.math.clamp(parseComponent(args[3], 1.0) orelse return null, 0, 1) else 1.0;
    if (s == 0) return .{ .r = l, .g = l, .b = l, .a = a };
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    return .{
        .r = hueToRgb(p, q, h + 1.0 / 3.0),
        .g = hueToRgb(p, q, h),
        .b = hueToRgb(p, q, h - 1.0 / 3.0),
        .a = a,
    };
}

const Named = struct { name: []const u8, rgb: u32 };
// The CSS named colors styles actually use. NOT the full CSS4 list yet —
// extend against the published W3C table when a style needs one missing here
// (parse returns null, the expression falls back to the property default,
// and the diagnostics channel names the color).
const named_colors = [_]Named{
    .{ .name = "aliceblue", .rgb = 0xf0f8ff },
    .{ .name = "aqua", .rgb = 0x00ffff },
    .{ .name = "beige", .rgb = 0xf5f5dc },
    .{ .name = "black", .rgb = 0x000000 },
    .{ .name = "blue", .rgb = 0x0000ff },
    .{ .name = "brown", .rgb = 0xa52a2a },
    .{ .name = "coral", .rgb = 0xff7f50 },
    .{ .name = "crimson", .rgb = 0xdc143c },
    .{ .name = "cyan", .rgb = 0x00ffff },
    .{ .name = "darkblue", .rgb = 0x00008b },
    .{ .name = "darkgray", .rgb = 0xa9a9a9 },
    .{ .name = "darkgreen", .rgb = 0x006400 },
    .{ .name = "darkgrey", .rgb = 0xa9a9a9 },
    .{ .name = "darkred", .rgb = 0x8b0000 },
    .{ .name = "dimgray", .rgb = 0x696969 },
    .{ .name = "dimgrey", .rgb = 0x696969 },
    .{ .name = "fuchsia", .rgb = 0xff00ff },
    .{ .name = "gainsboro", .rgb = 0xdcdcdc },
    .{ .name = "gold", .rgb = 0xffd700 },
    .{ .name = "gray", .rgb = 0x808080 },
    .{ .name = "green", .rgb = 0x008000 },
    .{ .name = "grey", .rgb = 0x808080 },
    .{ .name = "hotpink", .rgb = 0xff69b4 },
    .{ .name = "indigo", .rgb = 0x4b0082 },
    .{ .name = "ivory", .rgb = 0xfffff0 },
    .{ .name = "khaki", .rgb = 0xf0e68c },
    .{ .name = "lavender", .rgb = 0xe6e6fa },
    .{ .name = "lightblue", .rgb = 0xadd8e6 },
    .{ .name = "lightgray", .rgb = 0xd3d3d3 },
    .{ .name = "lightgreen", .rgb = 0x90ee90 },
    .{ .name = "lightgrey", .rgb = 0xd3d3d3 },
    .{ .name = "lime", .rgb = 0x00ff00 },
    .{ .name = "magenta", .rgb = 0xff00ff },
    .{ .name = "maroon", .rgb = 0x800000 },
    .{ .name = "navy", .rgb = 0x000080 },
    .{ .name = "olive", .rgb = 0x808000 },
    .{ .name = "orange", .rgb = 0xffa500 },
    .{ .name = "orangered", .rgb = 0xff4500 },
    .{ .name = "pink", .rgb = 0xffc0cb },
    .{ .name = "purple", .rgb = 0x800080 },
    .{ .name = "red", .rgb = 0xff0000 },
    .{ .name = "salmon", .rgb = 0xfa8072 },
    .{ .name = "silver", .rgb = 0xc0c0c0 },
    .{ .name = "skyblue", .rgb = 0x87ceeb },
    .{ .name = "slategray", .rgb = 0x708090 },
    .{ .name = "steelblue", .rgb = 0x4682b4 },
    .{ .name = "tan", .rgb = 0xd2b48c },
    .{ .name = "teal", .rgb = 0x008080 },
    .{ .name = "tomato", .rgb = 0xff6347 },
    .{ .name = "violet", .rgb = 0xee82ee },
    .{ .name = "wheat", .rgb = 0xf5deb3 },
    .{ .name = "white", .rgb = 0xffffff },
    .{ .name = "whitesmoke", .rgb = 0xf5f5f5 },
    .{ .name = "yellow", .rgb = 0xffff00 },
};

fn parseNamed(s: []const u8) ?Color {
    var buf: [24]u8 = undefined;
    if (s.len > buf.len) return null;
    const lower = std.ascii.lowerString(&buf, s);
    if (std.mem.eql(u8, lower, "transparent")) return Color.transparent;
    for (named_colors) |nc| {
        if (std.mem.eql(u8, nc.name, lower)) {
            return .{
                .r = @as(f32, @floatFromInt((nc.rgb >> 16) & 0xff)) / 255.0,
                .g = @as(f32, @floatFromInt((nc.rgb >> 8) & 0xff)) / 255.0,
                .b = @as(f32, @floatFromInt(nc.rgb & 0xff)) / 255.0,
                .a = 1,
            };
        }
    }
    return null;
}

fn funcBody(s: []const u8, name: []const u8) ?[]const u8 {
    if (s.len < name.len + 2) return null;
    if (!std.ascii.startsWithIgnoreCase(s, name)) return null;
    const rest = std.mem.trim(u8, s[name.len..], " \t");
    if (rest.len < 2 or rest[0] != '(' or rest[rest.len - 1] != ')') return null;
    return std.mem.trim(u8, rest[1 .. rest.len - 1], " \t");
}

/// Parse a CSS color string. Null on anything unrecognized — the caller
/// decides whether that is a diagnostics-and-default or a hard error.
pub fn parse(s0: []const u8) ?Color {
    const s = std.mem.trim(u8, s0, " \t\r\n");
    if (s.len == 0) return null;
    if (s[0] == '#') return parseHex(s[1..]);
    if (funcBody(s, "rgba")) |b| return parseRgbFunc(b);
    if (funcBody(s, "rgb")) |b| return parseRgbFunc(b);
    if (funcBody(s, "hsla")) |b| return parseHslFunc(b);
    if (funcBody(s, "hsl")) |b| return parseHslFunc(b);
    return parseNamed(s);
}

// ---- tests -----------------------------------------------------------------

fn expectColor(s: []const u8, r: f32, g: f32, b: f32, a: f32) !void {
    const c = parse(s) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(r, c.r, 1e-3);
    try std.testing.expectApproxEqAbs(g, c.g, 1e-3);
    try std.testing.expectApproxEqAbs(b, c.b, 1e-3);
    try std.testing.expectApproxEqAbs(a, c.a, 1e-3);
}

test "hex forms" {
    try expectColor("#ff00ff", 1, 0, 1, 1);
    try expectColor("#f0f", 1, 0, 1, 1);
    try expectColor("#ff00ff80", 1, 0, 1, 0x80.0 / 255.0);
    try expectColor("#f0f8", 1, 0, 1, 0x88.0 / 255.0);
    try std.testing.expectEqual(@as(?Color, null), parse("#ggg"));
    try std.testing.expectEqual(@as(?Color, null), parse("#ff00f"));
}

test "rgb() and rgba(), comma and modern syntax" {
    try expectColor("rgb(255, 0, 255)", 1, 0, 1, 1);
    try expectColor("rgba(255,0,255,0.5)", 1, 0, 1, 0.5);
    try expectColor("rgba(255, 255, 255, 0.9)", 1, 1, 1, 0.9);
    try expectColor("rgb(100%, 0%, 50%)", 1, 0, 0.5, 1);
    try expectColor("rgb(255 0 255 / 0.5)", 1, 0, 1, 0.5);
}

test "hsl()" {
    try expectColor("hsl(0, 100%, 50%)", 1, 0, 0, 1);
    try expectColor("hsl(120, 100%, 50%)", 0, 1, 0, 1);
    try expectColor("hsl(240, 100%, 25%)", 0, 0, 0.5, 1);
    try expectColor("hsla(0, 0%, 100%, 0.25)", 1, 1, 1, 0.25);
}

test "named colors and transparent" {
    try expectColor("black", 0, 0, 0, 1);
    try expectColor("White", 1, 1, 1, 1);
    try expectColor("MAGENTA", 1, 0, 1, 1);
    try expectColor("transparent", 0, 0, 0, 0);
    try std.testing.expectEqual(@as(?Color, null), parse("notacolor"));
}
