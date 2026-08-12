//! Range → draw-call batching. Ranges arrive in paint order; the host still
//! has to decide, per range, which pipeline draws it, which atlas it
//! samples, what the uniform block should say, and whether it folds into the
//! previous draw. That classification is the engine's, so it lives here —
//! the backend keeps its pipeline objects, textures, encoder, and any extra
//! pass structure (the opaque front-to-back pre-pass) of its own.
//!
//! Allocates nothing and touches no GPU. `ranges.len` is always a safe
//! output capacity: draws only ever merge, never split.

const std = @import("std");
const t = @import("types.zig");

fn classify(r: t.Range) t.Pipeline {
    return switch (r.prim) {
        .triangles => if (r.pattern != t.NO_PATTERN) .pattern else .fill,
        .quads => switch (r.atlas) {
            .sprite => .sprite,
            .glyph, .glyph_bold, .glyph_italic => .sdf,
            .none => .sprite, // untextured quads ride the sprite pipeline
        },
    };
}

/// Apply the missing-tier fallback: bold/italic fall back to the regular
/// glyph atlas; a range whose atlas (after fallback) never uploaded returns
/// null and must be dropped — only the host knows what uploaded.
fn resolveAtlas(r: t.Range, have: u8) ?t.Atlas {
    if (r.prim != .quads or r.atlas == .none) return .none;
    var a = r.atlas;
    if ((have & t.AtlasBit.bit(a)) == 0 and (a == .glyph_bold or a == .glyph_italic))
        a = .glyph;
    if ((have & t.AtlasBit.bit(a)) == 0) return null;
    return a;
}

/// Batch `ranges` into `out`. Returns how many draws the batch HAS: a return
/// greater than out.len means the buffer was too small and NOTHING should be
/// drawn from it (a truncated batch is missing content silently). Pass an
/// empty `out` to ask for the count alone.
pub fn batch(ranges: []const t.Range, opts: t.BatchOpts, out: []t.Draw) usize {
    var n: usize = 0;
    var last: ?*t.Draw = null;
    for (ranges) |r| {
        if (r.count == 0) continue;
        if (opts.exclude_opaque_tris and r.prim == .triangles and
            (r.flags & t.Range.FLAG_OPAQUE) != 0) continue;
        const atlas = resolveAtlas(r, opts.atlas_have) orelse continue;
        const pipe = classify(r);
        // An SDF draw carries the halo colour: the range's own when the style
        // set text-halo-color, else the scene's effective background.
        const color: [4]f32 = if (pipe != .sdf) .{ 0, 0, 0, 0 } else if ((r.flags & t.Range.FLAG_HALO) != 0) .{
            @as(f32, @floatFromInt(r.halo[0])) / 255.0,
            @as(f32, @floatFromInt(r.halo[1])) / 255.0,
            @as(f32, @floatFromInt(r.halo[2])) / 255.0,
            @as(f32, @floatFromInt(r.halo[3])) / 255.0,
        } else opts.halo;

        if (last) |d| {
            if (d.prim == r.prim and d.pipeline == pipe and d.atlas == atlas and
                d.pattern == r.pattern and std.mem.eql(f32, &d.color, &color) and
                d.first + d.count == r.first)
            {
                d.count += r.count;
                continue;
            }
        }
        if (n < out.len) {
            out[n] = .{
                .first = r.first,
                .count = r.count,
                .prim = r.prim,
                .pipeline = pipe,
                .atlas = atlas,
                .pattern = r.pattern,
                .color = color,
            };
            last = &out[n];
        } else {
            last = null; // counting past capacity: no merge target, count conservatively
        }
        n += 1;
    }
    return n;
}

// ---- tests -----------------------------------------------------------------

const expectEqual = std.testing.expectEqual;

fn tri(first: u32, count: u32, opaq: bool) t.Range {
    return .{ .first = first, .count = count, .paint_key = 0, .kind = .area, .prim = .triangles, .flags = if (opaq) t.Range.FLAG_OPAQUE else 0 };
}

fn quad(first: u32, count: u32, atlas: t.Atlas) t.Range {
    return .{ .first = first, .count = count, .paint_key = 0, .kind = .symbol, .prim = .quads, .atlas = atlas };
}

const all_atlases: u8 = 0b11111;
const halo = [4]f32{ 0.5, 0.5, 0.5, 1 };

test "contiguous same-pipeline ranges merge into one draw" {
    const ranges = [_]t.Range{ tri(0, 30, false), tri(30, 12, false), tri(42, 9, false) };
    var out: [3]t.Draw = undefined;
    const n = batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out);
    try expectEqual(@as(usize, 1), n);
    try expectEqual(@as(u32, 0), out[0].first);
    try expectEqual(@as(u32, 51), out[0].count);
    try expectEqual(t.Pipeline.fill, out[0].pipeline);
}

test "a gap breaks the merge" {
    const ranges = [_]t.Range{ tri(0, 30, false), tri(60, 12, false) };
    var out: [2]t.Draw = undefined;
    try expectEqual(@as(usize, 2), batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out));
}

test "pipeline change breaks the merge and picks the right pipeline" {
    const ranges = [_]t.Range{ tri(0, 30, false), quad(0, 6, .sprite), quad(6, 6, .glyph) };
    var out: [3]t.Draw = undefined;
    const n = batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out);
    try expectEqual(@as(usize, 3), n);
    try expectEqual(t.Pipeline.fill, out[0].pipeline);
    try expectEqual(t.Pipeline.sprite, out[1].pipeline);
    try expectEqual(t.Pipeline.sdf, out[2].pipeline);
    try expectEqual(halo, out[2].color);
}

test "bold falls back to regular glyph atlas; missing sprite atlas drops" {
    const have: u8 = t.AtlasBit.bit(.glyph); // only the regular glyph atlas uploaded
    const ranges = [_]t.Range{ quad(0, 6, .glyph_bold), quad(6, 6, .sprite) };
    var out: [2]t.Draw = undefined;
    const n = batch(&ranges, .{ .atlas_have = have, .halo = halo }, &out);
    try expectEqual(@as(usize, 1), n);
    try expectEqual(t.Atlas.glyph, out[0].atlas);
}

test "exclude_opaque_tris skips only opaque triangle ranges" {
    const ranges = [_]t.Range{ tri(0, 30, true), tri(30, 12, false), quad(0, 6, .sprite) };
    var out: [3]t.Draw = undefined;
    const n = batch(&ranges, .{ .exclude_opaque_tris = true, .atlas_have = all_atlases, .halo = halo }, &out);
    try expectEqual(@as(usize, 2), n);
    try expectEqual(@as(u32, 30), out[0].first);
}

test "overflow returns the true count and draws nothing from a short buffer" {
    const ranges = [_]t.Range{ tri(0, 3, false), quad(0, 6, .sprite), tri(9, 3, false) };
    var out0: [0]t.Draw = .{};
    try expectEqual(@as(usize, 3), batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out0));
    var out1: [1]t.Draw = undefined;
    try expectEqual(@as(usize, 3), batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out1));
}

test "pattern ranges classify to the pattern pipeline and split on cell change" {
    var a = tri(0, 12, false);
    a.pattern = 0;
    var b = tri(12, 12, false);
    b.pattern = 1;
    const ranges = [_]t.Range{ a, b };
    var out: [2]t.Draw = undefined;
    const n = batch(&ranges, .{ .atlas_have = all_atlases, .halo = halo }, &out);
    try expectEqual(@as(usize, 2), n);
    try expectEqual(t.Pipeline.pattern, out[0].pipeline);
    try expectEqual(@as(u32, 0), out[0].pattern);
    try expectEqual(@as(u32, 1), out[1].pattern);
}
