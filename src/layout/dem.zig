//! Terrain from RGB-encoded elevation tiles: hillshade and color relief.
//!
//! A raster-dem tile is an ordinary PNG whose channels are a number, not a
//! color. Two encodings are in use and they disagree about everything except
//! that the answer is metres:
//!
//!   mapbox:    -10000 + (R*65536 + G*256 + B) * 0.1
//!   terrarium: (R*256 + G + B/256) - 32768
//!
//! Both layer types produce an RGBA image per tile, which the scene draws
//! through the raster path — a quad with a texture, exactly like an aerial
//! photo. Nothing here touches the GPU, so the whole thing runs on the build
//! thread with the rest of layout.
//!
//! Provenance: the encodings are published formats (Mapbox Terrain-RGB,
//! Mapzen/AWS Terrarium). The shading is the standard Horn slope/aspect
//! kernel from the GIS literature (Horn 1981), which is what every
//! hillshade implementation uses; no renderer's source was consulted.

const std = @import("std");

pub const Encoding = enum {
    mapbox,
    terrarium,

    pub fn parse(s: ?[]const u8) Encoding {
        const name = s orelse return .mapbox;
        if (std.mem.eql(u8, name, "terrarium")) return .terrarium;
        return .mapbox;
    }
};

/// Metres above sea level for one encoded pixel.
pub fn elevation(enc: Encoding, r: u8, g: u8, b: u8) f32 {
    const rf: f32 = @floatFromInt(r);
    const gf: f32 = @floatFromInt(g);
    const bf: f32 = @floatFromInt(b);
    return switch (enc) {
        .mapbox => -10000.0 + (rf * 65536.0 + gf * 256.0 + bf) * 0.1,
        .terrarium => (rf * 256.0 + gf + bf / 256.0) - 32768.0,
    };
}

/// An elevation grid decoded from one tile's pixels.
pub const Grid = struct {
    w: u32,
    h: u32,
    z: []f32,

    pub fn at(self: Grid, x: i64, y: i64) f32 {
        // Clamp at the edges: a tile has no neighbours here, and clamping
        // makes the border slope flat rather than inventing a cliff.
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, self.w) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, self.h) - 1));
        return self.z[cy * self.w + cx];
    }
};

pub fn decode(arena: std.mem.Allocator, enc: Encoding, rgba: []const u8, w: u32, h: u32) !Grid {
    const n = @as(usize, w) * h;
    if (rgba.len < n * 4) return error.ShortImage;
    const z = try arena.alloc(f32, n);
    for (0..n) |i| z[i] = elevation(enc, rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]);
    return .{ .w = w, .h = h, .z = z };
}

pub const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };

pub const HillshadeOpts = struct {
    /// Degrees clockwise from north, the direction the light comes FROM.
    illumination_direction: f32 = 335,
    exaggeration: f32 = 0.5,
    shadow: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    highlight: Rgba = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    accent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
    /// Metres per pixel, so a slope means the same thing at every zoom.
    /// A wrong value only makes the terrain look flatter or harsher.
    meters_per_px: f32 = 30,
};

/// Shade a tile: slope and aspect by the Horn kernel, lit from one
/// direction, written out as a transparency-carrying overlay. The result is
/// straight alpha and is meant to be drawn OVER whatever is beneath it.
pub fn hillshade(
    arena: std.mem.Allocator,
    grid: Grid,
    opts: HillshadeOpts,
    out: []u8,
) !void {
    const n = @as(usize, grid.w) * grid.h;
    if (out.len < n * 4) return error.ShortImage;
    _ = arena;

    // The light's azimuth is measured clockwise from north; the maths below
    // wants it counter-clockwise from +x.
    const az = (90.0 - opts.illumination_direction) * std.math.pi / 180.0;
    const altitude = 45.0 * std.math.pi / 180.0; // the spec's fixed sun height
    const sin_alt = @sin(altitude);
    const cos_alt = @cos(altitude);
    const scale = 1.0 / (8.0 * @max(opts.meters_per_px, 0.0001)) * opts.exaggeration * 4.0;

    var y: i64 = 0;
    while (y < grid.h) : (y += 1) {
        var x: i64 = 0;
        while (x < grid.w) : (x += 1) {
            const a = grid.at(x - 1, y - 1);
            const b = grid.at(x, y - 1);
            const c = grid.at(x + 1, y - 1);
            const d = grid.at(x - 1, y);
            const f = grid.at(x + 1, y);
            const g = grid.at(x - 1, y + 1);
            const h = grid.at(x, y + 1);
            const i = grid.at(x + 1, y + 1);

            // Horn's 3x3: the weighted differences across the cell.
            const dzdx = ((c + 2 * f + i) - (a + 2 * d + g)) * scale;
            const dzdy = ((g + 2 * h + i) - (a + 2 * b + c)) * scale;

            const slope = std.math.atan(@sqrt(dzdx * dzdx + dzdy * dzdy));
            // Aspect: the compass direction the slope faces.
            const aspect = std.math.atan2(dzdy, -dzdx);

            const lum = std.math.clamp(
                sin_alt * @cos(slope) + cos_alt * @sin(slope) * @cos(az - aspect),
                0,
                1,
            );

            // This is an OVERLAY, so what matters is the departure from flat
            // ground, not the absolute luminance. Flat ground lit from 45°
            // has lum == sin_alt; scoring that as "half shaded" would lay a
            // grey wash over every flat area, which is what the test caught.
            // Darker than flat draws the shadow color, lighter draws the
            // highlight, and equal draws nothing at all.
            const steep = std.math.clamp(@sin(slope), 0, 1);
            const c_out = if (lum < sin_alt) opts.shadow else opts.highlight;
            const away: f32 = if (lum < sin_alt)
                (sin_alt - lum) / sin_alt
            else
                (lum - sin_alt) / @max(1.0 - sin_alt, 0.0001);

            // The accent color rides raw steepness, which picks out ridges
            // whichever way they face.
            const with_accent = mix(c_out, opts.accent, steep * 0.35);
            const alpha = std.math.clamp(with_accent.a * away, 0, 1);
            const o = (@as(usize, @intCast(y)) * grid.w + @as(usize, @intCast(x))) * 4;
            out[o + 0] = q8(with_accent.r);
            out[o + 1] = q8(with_accent.g);
            out[o + 2] = q8(with_accent.b);
            out[o + 3] = q8(alpha);
        }
    }
}

/// A color ramp sampled over a fixed elevation window, so a per-pixel color
/// is a table lookup rather than an expression evaluation 65 000 times.
pub const Ramp = struct {
    lo: f32,
    hi: f32,
    /// RGBA8, `steps` entries.
    lut: []const u8,

    pub const steps: usize = 256;

    pub fn sample(self: Ramp, z: f32) [4]u8 {
        if (self.hi <= self.lo) return self.lut[0..4].*;
        const t = std.math.clamp((z - self.lo) / (self.hi - self.lo), 0, 1);
        const i: usize = @intFromFloat(t * @as(f32, @floatFromInt(steps - 1)) + 0.5);
        return self.lut[i * 4 ..][0..4].*;
    }
};

/// Paint every pixel by its elevation.
pub fn colorRelief(grid: Grid, ramp: Ramp, opacity: f32, out: []u8) !void {
    const n = @as(usize, grid.w) * grid.h;
    if (out.len < n * 4) return error.ShortImage;
    for (0..n) |i| {
        const c = ramp.sample(grid.z[i]);
        out[i * 4 + 0] = c[0];
        out[i * 4 + 1] = c[1];
        out[i * 4 + 2] = c[2];
        out[i * 4 + 3] = q8(@as(f32, @floatFromInt(c[3])) / 255.0 * std.math.clamp(opacity, 0, 1));
    }
}

fn mix(a: Rgba, b: Rgba, t: f32) Rgba {
    const k = std.math.clamp(t, 0, 1);
    return .{
        .r = a.r + (b.r - a.r) * k,
        .g = a.g + (b.g - a.g) * k,
        .b = a.b + (b.b - a.b) * k,
        .a = a.a + (b.a - a.a) * k,
    };
}

fn q8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 1) * 255.0 + 0.5);
}

/// Metres per pixel at a tile's latitude and zoom, for a 256-px tile.
/// Slope is a ratio of height to DISTANCE, so without this the same terrain
/// shades differently at every zoom.
pub fn metersPerPixel(z: u8, tile_y: u32, tile_size: u32) f32 {
    const n = @as(f64, @floatFromInt(@as(u64, 1) << @intCast(z)));
    // Latitude at the tile's centre, from the Web Mercator inverse.
    const yc = (@as(f64, @floatFromInt(tile_y)) + 0.5) / n;
    const lat = std.math.atan(std.math.sinh(std.math.pi * (1.0 - 2.0 * yc)));
    const equator = 40075016.686;
    const size: f64 = @floatFromInt(@max(tile_size, 1));
    return @floatCast(equator * @cos(lat) / (n * size));
}

// ---- tests -----------------------------------------------------------------

const testing = std.testing;

test "the two published encodings decode to metres" {
    // Mapbox: 0 is -10000 m, and one blue step is 0.1 m.
    try testing.expectApproxEqAbs(@as(f32, -10000), elevation(.mapbox, 0, 0, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -9999.9), elevation(.mapbox, 0, 0, 1), 0.001);
    // Terrarium: 32768 in the red channel is sea level.
    try testing.expectApproxEqAbs(@as(f32, 0), elevation(.terrarium, 128, 0, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), elevation(.terrarium, 128, 1, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -32768), elevation(.terrarium, 0, 0, 0), 0.001);
    try testing.expectEqual(Encoding.terrarium, Encoding.parse("terrarium"));
    try testing.expectEqual(Encoding.mapbox, Encoding.parse(null));
    try testing.expectEqual(Encoding.mapbox, Encoding.parse("mapbox"));
}

test "flat ground casts no shade; a slope does" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w: u32 = 8;
    const h: u32 = 8;
    const flat = Grid{ .w = w, .h = h, .z = try a.alloc(f32, w * h) };
    @memset(flat.z, 100);
    const out = try a.alloc(u8, w * h * 4);
    try hillshade(a, flat, .{}, out);
    // Flat ground is lit head-on: nothing to shade, so nothing to draw.
    for (0..w * h) |i| try testing.expectEqual(@as(u8, 0), out[i * 4 + 3]);

    // A ramp rising to the east: shaded, and the alpha is not uniform noise.
    const slope = Grid{ .w = w, .h = h, .z = try a.alloc(f32, w * h) };
    for (0..h) |y| for (0..w) |x| {
        slope.z[y * w + x] = @as(f32, @floatFromInt(x)) * 40.0;
    };
    try hillshade(a, slope, .{}, out);
    var shaded: usize = 0;
    for (0..w * h) |i| if (out[i * 4 + 3] > 0) {
        shaded += 1;
    };
    try testing.expect(shaded > w * h / 2);
}

test "a color ramp maps elevation through its window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Black at the bottom, white at the top.
    const lut = try a.alloc(u8, Ramp.steps * 4);
    for (0..Ramp.steps) |i| {
        const v: u8 = @intCast(i * 255 / (Ramp.steps - 1));
        lut[i * 4 ..][0..4].* = .{ v, v, v, 255 };
    }
    const ramp = Ramp{ .lo = 0, .hi = 100, .lut = lut };
    try testing.expectEqual(@as(u8, 0), ramp.sample(0)[0]);
    try testing.expectEqual(@as(u8, 255), ramp.sample(100)[0]);
    try testing.expectEqual(@as(u8, 255), ramp.sample(1000)[0]); // clamped
    try testing.expectEqual(@as(u8, 0), ramp.sample(-50)[0]); // clamped
    try testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(ramp.sample(50)[0])), 2);

    const grid = Grid{ .w = 2, .h = 1, .z = try a.alloc(f32, 2) };
    grid.z[0] = 0;
    grid.z[1] = 100;
    const out = try a.alloc(u8, 2 * 4);
    try colorRelief(grid, ramp, 0.5, out);
    try testing.expectEqual(@as(u8, 0), out[0]);
    try testing.expectEqual(@as(u8, 255), out[4]);
    try testing.expectEqual(@as(u8, 128), out[3]); // opacity applied
}

test "metres per pixel shrinks with zoom and with latitude" {
    // z0 is one tile centred on the equator: the classic 156 km/px figure.
    try testing.expectApproxEqAbs(@as(f32, 156543.0), metersPerPixel(0, 0, 256), 1.0);

    // Zooming in always shrinks it. (Row 0 also walks toward the pole as
    // zoom rises, and that shrinks it too -- both pull the same way, which
    // is why this is a monotonic check and not an exact halving. There is
    // no equator-centred tile above z0 to halve against.)
    var prev = metersPerPixel(0, 0, 256);
    for (1..6) |z| {
        const now = metersPerPixel(@intCast(z), 0, 256);
        try testing.expect(now < prev);
        prev = now;
    }

    // At one zoom, a tile near the pole covers less ground per pixel than
    // one at the equator.
    try testing.expect(metersPerPixel(4, 0, 256) < metersPerPixel(4, 8, 256));

    // A 512-px tile spans the same ground in twice the pixels.
    try testing.expectApproxEqAbs(
        metersPerPixel(3, 4, 256) / 2.0,
        metersPerPixel(3, 4, 512),
        0.001,
    );
}
