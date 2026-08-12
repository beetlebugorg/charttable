//! charttable: a native map renderer that implements the MapLibre style spec.
//! One Zig library with a C ABI. Style JSON + vector tiles in; Metal / Vulkan /
//! D3D12 / SDL frames out. See DESIGN.md for the architecture and the
//! conformance tiers; THIRD-PARTY-NOTICES.md for provenance.
//!
//! This file is the public Zig surface and the test collector. Every module
//! must be referenced from here or its tests go dead in a test build.

pub const camera = @import("camera.zig");
pub const map = @import("map.zig");
pub const scene = @import("scene/types.zig");
pub const batch = @import("scene/batch.zig");
pub const value = @import("style/value.zig");
pub const color = @import("style/color.zig");
pub const expr = @import("style/expr.zig");
pub const eval = @import("style/eval.zig");
pub const properties = @import("style/properties.zig");
pub const style = @import("style/style.zig");
pub const coord = @import("source/coord.zig");
pub const mvt = @import("source/mvt.zig");
pub const mlt = @import("source/mlt.zig");
pub const pmtiles = @import("source/pmtiles.zig");
pub const fill = @import("layout/fill.zig");
pub const line = @import("layout/line.zig");
pub const sprite = @import("symbol/sprite.zig");
pub const glyphs = @import("symbol/glyphs.zig");
pub const gpu = @import("gpu/gpu.zig");
pub const png = @import("util/png.zig");
pub const lock = @import("util/lock.zig");
pub const clock = @import("util/clock.zig");

test {
    _ = camera;
    _ = map;
    _ = scene;
    _ = batch;
    _ = value;
    _ = color;
    _ = expr;
    _ = eval;
    _ = properties;
    _ = style;
    _ = coord;
    _ = mvt;
    _ = mlt;
    _ = pmtiles;
    _ = fill;
    _ = line;
    _ = sprite;
    _ = glyphs;
    _ = gpu;
    _ = png;
    _ = lock;
    _ = clock;
}
