//! Camera math in web-mercator [0,1] space (the charttable scene's world
//! space). The camera is NEVER baked into vertex data; every frame we
//! rebuild a single MVP from the camera state and hand it to the vertex shader.
//! Geometry is stored camera-relative to a fixed `origin` so f32 precision holds
//! even when zoomed into a harbor.
//!
//! Zoom follows the MapLibre style-spec convention: at zoom z the world is
//! 512 * 2^z px wide. (lookout counts against a 256 px world tile; its shell
//! converts at the ABI edge — one conversion, one place.)
const std = @import("std");

pub const Vec2 = struct { x: f64, y: f64 };

/// Wrap a world x into [0,1) — longitude is cyclic (the antimeridian).
pub fn wrapX(x: f64) f64 {
    return x - std.math.floor(x);
}

/// The SHORT-WAY difference a - b of two world x's, in [-0.5, 0.5): the delta
/// that crosses the antimeridian when that is nearer.
pub fn wrapDx(a: f64, b: f64) f64 {
    const d = a - b;
    return d - std.math.round(d);
}

/// Where a tile's left edge sits in a frame whose origin is `origin_x`,
/// choosing the world copy nearest that origin.
///
/// Longitude is cyclic, so every tile has a copy each 1.0 world units and the
/// renderer has to pick one, for the tile as a whole. Nearest is measured at
/// the tile's CENTRE: judged by its left edge, a tile a whole span wide counts
/// as near when only its far corner is, and the body of it lands a world away
/// from what the view is looking at.
pub fn placeTileX(x0: f64, span: f64, origin_x: f64) f64 {
    return wrapDx(x0 + span * 0.5, origin_x) - span * 0.5;
}

/// The other world copy of a tile that a view can also see, as the offset to
/// add to its placement (`-1` or `+1`), or null when one copy is enough.
///
/// `dx` is the placement placeTileX chose and `span` the tile's width, both in
/// world units in a frame centred on the view; `half_w` is the view's own half
/// width there. Longitude is cyclic, so a tile recurs every 1.0 world units:
/// once the view is wider than the gap between two copies -- which happens
/// from about z1 down, where a tile is a large fraction of the world -- the
/// same tile is visible on both sides and has to be DRAWN on both sides. One
/// placement per tile leaves a wedge of empty ocean instead.
///
/// At most one copy can qualify: a tile is at most one world wide, so its
/// copies are at least that far apart.
pub fn wrappedCopy(dx: f64, span: f64, half_w: f64) ?f64 {
    for ([2]f64{ -1, 1 }) |k| {
        if (dx + k < half_w and dx + k + span > -half_w) return k;
    }
    return null;
}

/// lon/lat (degrees) -> normalized web-mercator [0,1], y down.
pub fn lonLatToWorld(lon: f64, lat: f64) Vec2 {
    const x = wrapX((lon + 180.0) / 360.0);
    const s = std.math.sin(lat * std.math.pi / 180.0);
    const y = 0.5 - std.math.log(f64, std.math.e, (1.0 + s) / (1.0 - s)) / (4.0 * std.math.pi);
    return .{ .x = x, .y = y };
}

/// normalized world [0,1] -> lon/lat degrees ([-180, 180)).
pub fn worldToLonLat(w: Vec2) Vec2 {
    const lon = wrapX(w.x) * 360.0 - 180.0;
    const n = std.math.pi - 2.0 * std.math.pi * w.y;
    const lat = (180.0 / std.math.pi) * std.math.atan(0.5 * (std.math.exp(n) - std.math.exp(-n)));
    return .{ .x = lon, .y = lat };
}

pub const Camera = struct {
    origin: Vec2, // fixed reference point (build view center) in world [0,1]
    center: Vec2, // current view center in world [0,1]
    zoom: f64, // fractional web-mercator zoom
    rotation: f64 = 0, // view rotation, radians CW (course-up); 0 = north-up
    vw: f32, // viewport width px
    vh: f32, // viewport height px
    min_zoom: f64 = 0, // clamp range (the chart's own zoom band)
    max_zoom: f64 = 24,

    // ---- animation state (advanced by tick each frame) ----
    /// The zoom `zoom` eases toward; wheel/pinch set this, not `zoom` directly, so
    /// a small scroll animates instead of snapping. Keep in sync with `zoom` when
    /// the view is set programmatically (setTarget).
    target_zoom: f64 = 0,
    zfocus: Vec2 = .{ .x = 0, .y = 0 }, // world point kept under the cursor while zooming
    zfx: f32 = 0, // cursor px the zoom pivots about
    zfy: f32 = 0,
    vel_x: f64 = 0, // fling velocity, logical px/sec (decays each tick)
    vel_y: f64 = 0,

    /// px-per-world-unit at the current zoom (512 px world tile at z0,
    /// the style-spec convention).
    pub fn worldToPx(self: Camera) f64 {
        return 512.0 * std.math.pow(f64, 2.0, self.zoom);
    }

    /// Keep the viewport on the map vertically: y clamps so the view can't
    /// scroll past the mercator top/bottom (x, by contrast, wraps). When the
    /// whole world is shorter than the viewport, center it.
    pub fn clampY(self: *Camera) void {
        const hh = @as(f64, self.vh) * 0.5 / self.worldToPx();
        self.center.y = if (hh >= 0.5) 0.5 else std.math.clamp(self.center.y, hh, 1.0 - hh);
    }

    /// Column-major mat4 mapping camera-relative world (world - origin, as f32)
    /// to Vulkan clip space: translate to center, rotate (course-up), scale to
    /// clip, flip y. Small (world-origin) values keep f32 exact.
    pub fn mvp(self: Camera) [16]f32 {
        return self.mvpOrigin(self.origin);
    }

    /// Like mvp() but for geometry stored relative to an arbitrary `origin`
    /// (each cached tile stores its verts relative to its own NW corner, so f32
    /// stays exact anywhere on earth).
    pub fn mvpOrigin(self: Camera, origin: Vec2) [16]f32 {
        const s = self.worldToPx();
        const a: f64 = 2.0 * s / @as(f64, self.vw);
        const b: f64 = 2.0 * s / @as(f64, self.vh);
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        // SHORT WAY in x: the camera and a scene origin are both world x in
        // [0,1), so a camera that has crossed the antimeridian since the
        // scene was built is a whole world away by subtraction and next door
        // by longitude. Wrapping here turns the whole scene at once, which is
        // the only place the turn can happen without splitting geometry: a
        // per-vertex wrap tears any primitive lying across the seam.
        const dx = wrapDx(origin.x, self.center.x); // added before rotate/scale
        const dy = origin.y - self.center.y;
        var m = [_]f32{0} ** 16;
        m[0] = @floatCast(a * c);
        m[1] = @floatCast(-b * sn);
        m[4] = @floatCast(-a * sn);
        m[5] = @floatCast(-b * c);
        m[10] = 0.0;
        m[12] = @floatCast(a * (c * dx - sn * dy));
        m[13] = @floatCast(-b * (sn * dx + c * dy));
        m[14] = 0.5; // clip z = 0.5 (inside Vulkan [0,1])
        m[15] = 1.0;
        return m;
    }

    /// reference-px -> clip-space delta (for constant-screen-size marks).
    pub fn pxToClip(self: Camera) [2]f32 {
        return .{ 2.0 / self.vw, -2.0 / self.vh };
    }
    /// (sin, cos) of the view rotation, for MAP-aligned marks in the shader.
    pub fn rotSinCos(self: Camera) [2]f32 {
        return .{ @floatCast(std.math.sin(self.rotation)), @floatCast(std.math.cos(self.rotation)) };
    }

    /// screen px (y down, origin top-left) -> world (x wrapped to [0,1)),
    /// rotation-aware.
    pub fn screenToWorld(self: Camera, px: f32, py: f32) Vec2 {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        const ex = (@as(f64, px) - @as(f64, self.vw) * 0.5);
        const ey = (@as(f64, py) - @as(f64, self.vh) * 0.5);
        // inverse rotation R(-theta)
        const wx = (c * ex + sn * ey) / s;
        const wy = (-sn * ex + c * ey) / s;
        return .{ .x = wrapX(self.center.x + wx), .y = self.center.y + wy };
    }

    /// world [0,1] -> screen px (rotation-aware). The x delta takes the SHORT
    /// way around the antimeridian, so a feature just across the seam maps to
    /// the near instance instead of a world-width away.
    pub fn worldToScreen(self: Camera, w: Vec2) Vec2 {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        const rx = wrapDx(w.x, self.center.x) * s;
        const ry = (w.y - self.center.y) * s;
        return .{
            .x = (c * rx - sn * ry) + @as(f64, self.vw) * 0.5,
            .y = (sn * rx + c * ry) + @as(f64, self.vh) * 0.5,
        };
    }

    /// Zoom by dz keeping the world point under (px,py) fixed on screen.
    pub fn zoomAbout(self: *Camera, dz: f64, px: f32, py: f32) void {
        const before = self.screenToWorld(px, py);
        self.zoom = std.math.clamp(self.zoom + dz, self.min_zoom, self.max_zoom);
        const after = self.screenToWorld(px, py);
        self.center.x = wrapX(self.center.x + wrapDx(before.x, after.x));
        self.center.y += before.y - after.y;
        self.clampY();
        // This is the INSTANT zoom, so the target moves with it. Left behind,
        // `animating()` is `|target_zoom - zoom| > 1e-4` forever after the
        // first zoom, `busy()` reports it, and the map never goes idle again
        // for the life of the session.
        self.setTarget();
    }

    /// Move the centre so world point `w` sits at screen (px,py). Rotation-aware;
    /// x takes the short way around the antimeridian. clampY still applies, so a
    /// point cannot be placed past the mercator top or bottom.
    pub fn placeAt(self: *Camera, w: Vec2, px: f32, py: f32) void {
        const at = self.screenToWorld(px, py);
        self.center.x = wrapX(self.center.x + wrapDx(w.x, at.x));
        self.center.y += w.y - at.y;
        self.clampY();
    }

    // Animation time constants (seconds).
    const ZOOM_TAU = 0.085; // zoom ease — small enough to feel immediate, smooth
    const FLING_TAU = 0.32; // fling decay
    const FLING_MIN = 12.0; // px/s: below this the fling stops

    /// Pin `target_zoom` to `zoom` — call after a programmatic view set so the
    /// next scroll eases from the actual zoom, not a stale target.
    pub fn setTarget(self: *Camera) void {
        self.target_zoom = self.zoom;
        self.vel_x = 0;
        self.vel_y = 0;
    }

    /// Request a zoom of `dz` about (px,py): eases there over the next frames,
    /// keeping the world point under the cursor fixed the whole way.
    pub fn zoomToward(self: *Camera, dz: f64, px: f32, py: f32) void {
        self.target_zoom = std.math.clamp(self.target_zoom + dz, self.min_zoom, self.max_zoom);
        self.zfocus = self.screenToWorld(px, py);
        self.zfx = px;
        self.zfy = py;
    }

    /// Begin a fling with the given logical-px/sec velocity (0,0 stops one).
    pub fn flingStart(self: *Camera, vx: f64, vy: f64) void {
        self.vel_x = vx;
        self.vel_y = vy;
    }

    /// True while a zoom ease or fling is still in progress.
    pub fn animating(self: Camera) bool {
        return @abs(self.target_zoom - self.zoom) > 1e-4 or
            @abs(self.vel_x) > FLING_MIN or @abs(self.vel_y) > FLING_MIN;
    }

    /// Advance the zoom ease and fling by `dt` seconds.
    ///
    /// `dt` is CLAMPED to about two frames' worth. The ease runs on
    /// wall-clock time, and a hitched frame — a heavy scene rebuild landing,
    /// a style's tiles decoding — otherwise advances the zoom by the whole
    /// hitch in one visible step: the chart lurches, resumes, lurches at the
    /// next hitch, which a mariner reads as the map shaking whenever the
    /// renderer breathes. Clamped, the same hitch is a barely-late ease.
    /// The fling takes the same clamp: velocity times a hitch is a teleport.
    pub fn tick(self: *Camera, dt_raw: f64) void {
        const dt = @min(dt_raw, 0.033);
        if (@abs(self.target_zoom - self.zoom) > 1e-4) {
            const k = 1.0 - @exp(-dt / ZOOM_TAU);
            self.zoom += (self.target_zoom - self.zoom) * k;
            if (@abs(self.target_zoom - self.zoom) < 1e-4) self.zoom = self.target_zoom;
            // Keep the pivot world point under its cursor px as the zoom changes.
            const after = self.screenToWorld(self.zfx, self.zfy);
            self.center.x = wrapX(self.center.x + wrapDx(self.zfocus.x, after.x));
            self.center.y += self.zfocus.y - after.y;
            self.clampY();
        }
        if (@abs(self.vel_x) > FLING_MIN or @abs(self.vel_y) > FLING_MIN) {
            self.panPx(@floatCast(self.vel_x * dt), @floatCast(self.vel_y * dt));
            const decay = @exp(-dt / FLING_TAU);
            self.vel_x *= decay;
            self.vel_y *= decay;
        } else {
            self.vel_x = 0;
            self.vel_y = 0;
        }
    }

    /// Pan by a screen-px delta (rotation-aware). x wraps at the antimeridian.
    pub fn panPx(self: *Camera, dx: f32, dy: f32) void {
        const s = self.worldToPx();
        const c = std.math.cos(self.rotation);
        const sn = std.math.sin(self.rotation);
        // move the world opposite the drag, un-rotating the screen delta
        self.center.x = wrapX(self.center.x - (c * @as(f64, dx) + sn * @as(f64, dy)) / s);
        self.center.y -= (-sn * @as(f64, dx) + c * @as(f64, dy)) / s;
        self.clampY();
    }

    /// Viewport half-extents in world units at the current zoom. The extents
    /// are those of the AXIS-ALIGNED box that holds the rotated viewport: a
    /// turned view reaches past its own width and height, and a scene built to
    /// the width and height alone leaves the corners empty.
    pub fn halfExtents(self: Camera) Vec2 {
        const wp = self.worldToPx();
        const ext = rotatedExtent(@as(f64, self.vw), @as(f64, self.vh), self.rotation);
        return .{ .x = ext[0] * 0.5 / wp, .y = ext[1] * 0.5 / wp };
    }

    /// The display-scale denominator (1:N) for the current view — the number
    /// minimum-scale gates (e.g. S-52 SCAMIN) compare against. Standard
    /// web-mercator scale at 96dpi, latitude adjusted.
    pub fn displayScale(self: Camera) f32 {
        return displayScaleAt(self.zoom, worldToLonLat(self.center).y);
    }
};

/// The width and height of the axis-aligned box that holds a `w` x `h`
/// viewport turned by `rotation` radians. At 45 degrees a square viewport needs
/// a box 1.41 times its side.
pub fn rotatedExtent(w: f64, h: f64, rotation: f64) [2]f64 {
    const c = @abs(std.math.cos(rotation));
    const s = @abs(std.math.sin(rotation));
    return .{ c * w + s * h, s * w + c * h };
}

/// Display-scale denominator (1:N) for a zoom + latitude (degrees).
pub fn displayScaleAt(zoom: f64, lat_deg: f64) f32 {
    // OSM scale denom at z0, equator, 96dpi is 559082264.029 for a 256 px
    // world tile; our z0 world is 512 px, so the denominator halves.
    const C: f64 = 279541132.0145;
    return @floatCast(C * std.math.cos(lat_deg * std.math.pi / 180.0) / std.math.pow(f64, 2.0, zoom));
}

// Zoom-to-cursor: the world point under a screen point stays under it across a
// zoom. This is the anchor math both platforms share (macOS wheel/pinch, iOS
// pinch/double-tap all funnel through zoomAbout) — so it verifies "zoom to
// cursor" deterministically, no UI or GPU.
test "zoomAbout keeps the point under the cursor fixed" {
    const std_testing = std.testing;
    const origin = lonLatToWorld(-76.48, 38.98);
    inline for (.{ .{ 300.0, 200.0, 2.0 }, .{ 1180.0, 60.0, 1.3 }, .{ 20.0, 860.0, -1.7 } }) |cfg| {
        const px: f32 = cfg[0];
        const py: f32 = cfg[1];
        const dz: f64 = cfg[2];
        var cam = Camera{ .origin = origin, .center = origin, .zoom = 12, .target_zoom = 12, .vw = 1200, .vh = 900, .min_zoom = 2, .max_zoom = 22 };
        const w_before = cam.screenToWorld(px, py);
        cam.zoomAbout(dz, px, py);
        const w_after = cam.screenToWorld(px, py);
        // Same world point under the same screen point, to sub-pixel world units.
        try std_testing.expectApproxEqAbs(w_before.x, w_after.x, 1e-9);
        try std_testing.expectApproxEqAbs(w_before.y, w_after.y, 1e-9);
    }
}

// Follow mode's anchor math: the fix must land on the horizontal centre, three
// quarters down the view, at any zoom and any view rotation.
test "placeAt puts a fix on the follow anchor" {
    const std_testing = std.testing;
    const origin = lonLatToWorld(-76.4767, 38.9763);
    const vw: f32 = 1264;
    const vh: f32 = 730;
    const ax = vw * 0.5;
    const ay = vh * 0.75;
    inline for (.{ .{ 15.0, 0.0 }, .{ 12.3, 37.0 }, .{ 18.0, 215.0 }, .{ 9.0, 90.0 } }) |cfg| {
        var cam = Camera{
            .origin = origin,
            .center = origin,
            .zoom = cfg[0],
            .target_zoom = cfg[0],
            .rotation = cfg[1] * std.math.pi / 180.0,
            .vw = vw,
            .vh = vh,
            .min_zoom = 2,
            .max_zoom = 22,
        };
        // A fix a little north-east of the opening centre.
        const fix = lonLatToWorld(-76.4700, 38.9800);
        cam.placeAt(fix, ax, ay);
        const s = cam.worldToScreen(fix);
        try std_testing.expectApproxEqAbs(@as(f64, ax), s.x, 1e-6);
        try std_testing.expectApproxEqAbs(@as(f64, ay), s.y, 1e-6);
    }
}

// A rotated view reaches past its own width and height. The scene is built
// axis-aligned in world space, so the corners of a turned viewport fell outside
// the build and drew as empty wedges.
test "halfExtents holds the corners of a rotated viewport" {
    const std_testing = std.testing;
    const origin = lonLatToWorld(-76.48, 38.98);
    const vw: f32 = 1264;
    const vh: f32 = 730;
    inline for (.{ 0.0, 30.0, 45.0, 90.0, 137.0, 215.0 }) |deg| {
        var cam = Camera{
            .origin = origin,
            .center = origin,
            .zoom = 13.7,
            .target_zoom = 13.7,
            .rotation = deg * std.math.pi / 180.0,
            .vw = vw,
            .vh = vh,
            .min_zoom = 2,
            .max_zoom = 22,
        };
        const he = cam.halfExtents();
        inline for (.{ .{ 0.0, 0.0 }, .{ 1264.0, 0.0 }, .{ 0.0, 730.0 }, .{ 1264.0, 730.0 } }) |corner| {
            const px: f32 = corner[0];
            const py: f32 = corner[1];
            const w = cam.screenToWorld(px, py);
            try std_testing.expect(@abs(w.x - cam.center.x) <= he.x + 1e-9);
            try std_testing.expect(@abs(w.y - cam.center.y) <= he.y + 1e-9);
        }
    }
}

// The seamap style over a wide view came out as horizontal bands stretched
// across the map: the vertex stages chose a world copy PER VERTEX, so a
// triangle lying across the half-world seam had corners a whole world apart.
// The choice is the host's now, and these are the two halves of it.
test "placeTileX puts a whole tile on its nearest copy" {
    const std_testing = std.testing;
    // z2: four columns, a quarter of the world each.
    const span = 0.25;
    inline for (.{ 0.0, 0.1234, 0.2361, 0.5, 0.75, 0.9999 }) |origin_x| {
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            const x0 = @as(f64, @floatFromInt(col)) * span;
            const dx = placeTileX(x0, span, origin_x);
            // Still the same geography: a whole number of worlds from where
            // the tile actually is.
            const worlds = dx - (x0 - origin_x);
            try std_testing.expectApproxEqAbs(@round(worlds), worlds, 1e-12);
            // And the nearest copy of it, measured where the tile IS rather
            // than at its left edge -- which is what keeps the body of a tile
            // on the near side instead of a corner of it.
            try std_testing.expect(@abs(dx + span * 0.5) <= 0.5);
        }
    }
}

test "wrappedCopy asks for the second copy only when the view can see it" {
    const std_testing = std.testing;
    // z1: two columns, half the world each, and a view of the whole world.
    // The column placed off to the west is visible in the east as well, and
    // has to be drawn there too or that side is empty ocean.
    try std_testing.expectEqual(@as(?f64, 1), wrappedCopy(-0.7361, 0.5, 0.5));
    // The same tile under a view half that wide is off screen on both sides.
    try std_testing.expect(wrappedCopy(-0.7361, 0.5, 0.25) == null);
    // A tile under the camera never needs a second copy: its other copies are
    // a world away, and no view is that wide.
    try std_testing.expect(wrappedCopy(-0.1, 0.25, 0.5) == null);
}

// mvpOrigin's x delta takes the short way round. Without that a camera that
// crossed the antimeridian since the scene was built is a whole world from
// its origin by subtraction, and the scene is translated off screen.
test "mvpOrigin turns the whole scene at the antimeridian" {
    const std_testing = std.testing;
    const cam = Camera{
        .origin = .{ .x = 0.99, .y = 0.5 },
        .center = .{ .x = 0.01, .y = 0.5 },
        .zoom = 4,
        .vw = 1024,
        .vh = 768,
    };
    const near = cam.mvpOrigin(cam.origin);
    // 0.99 is 0.02 WEST of 0.01, not 0.98 east: the translation is the small
    // one, and of the sign that puts the origin left of centre.
    const a = 2.0 * cam.worldToPx() / @as(f64, cam.vw);
    try std_testing.expectApproxEqAbs(@as(f32, @floatCast(a * -0.02)), near[12], 1e-3);
}
