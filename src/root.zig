//! charttable: a native map renderer that implements the MapLibre style spec.
//! One Zig library with a C ABI. Style JSON + vector tiles in; Metal / Vulkan /
//! D3D12 / SDL frames out. See DESIGN.md for the architecture and the
//! conformance tiers; THIRD-PARTY-NOTICES.md for provenance.
//!
//! This file is the public Zig surface and the test collector. Every module
//! must be referenced from here or its tests go dead in a test build.

pub const camera = @import("camera.zig");
pub const map = @import("map.zig");
pub const map_object = @import("map_object.zig");
pub const capi = @import("capi.zig");
pub const symbol_layout = @import("layout/symbol.zig");
pub const scene = @import("scene/types.zig");
pub const batch = @import("scene/batch.zig");
pub const value = @import("style/value.zig");
pub const color = @import("style/color.zig");
pub const expr = @import("style/expr.zig");
pub const eval = @import("style/eval.zig");
pub const properties = @import("style/properties.zig");
pub const style = @import("style/style.zig");
pub const compile = @import("style/compile.zig");
pub const coord = @import("source/coord.zig");
pub const mvt = @import("source/mvt.zig");
pub const mlt = @import("source/mlt.zig");
pub const pmtiles = @import("source/pmtiles.zig");
pub const cache = @import("source/cache.zig");
pub const provider = @import("source/provider.zig");
pub const fill = @import("layout/fill.zig");
pub const line = @import("layout/line.zig");
pub const dem = @import("layout/dem.zig");
pub const earcut = @import("layout/earcut.zig");
pub const sprite = @import("symbol/sprite.zig");
pub const glyphs = @import("symbol/glyphs.zig");
pub const gpu = @import("gpu/gpu.zig");
pub const png = @import("util/png.zig");
pub const webp = @import("util/webp.zig");
pub const lock = @import("util/lock.zig");
pub const clock = @import("util/clock.zig");

comptime {
    // Force the C ABI's `export fn`s to be analyzed and emitted. Zig is lazy:
    // an imported file nothing references contributes no symbols, and
    // libcharttable.a comes out with zero charttable_* exports in it.
    _ = capi;
}

test {
    _ = camera;
    _ = map;
    _ = map_object;
    _ = capi;
    _ = symbol_layout;
    _ = scene;
    _ = batch;
    _ = value;
    _ = color;
    _ = expr;
    _ = eval;
    _ = properties;
    _ = style;
    _ = compile;
    _ = coord;
    _ = mvt;
    _ = mlt;
    _ = pmtiles;
    _ = cache;
    _ = provider;
    _ = fill;
    _ = line;
    _ = dem;
    _ = earcut;
    _ = sprite;
    _ = glyphs;
    _ = gpu;
    _ = png;
    _ = webp;
    _ = lock;
    _ = clock;
}
