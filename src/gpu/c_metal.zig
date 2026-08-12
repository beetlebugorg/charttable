//! Metal-backend C interop: the ObjC Metal shim behind a C face
//! (metal_shim.h). Apple-only; used solely by gpu_metal.zig.
//! Ported from lookout-marine src/c_metal.zig.
pub const c = @cImport({
    @cInclude("metal_shim.h");
});
