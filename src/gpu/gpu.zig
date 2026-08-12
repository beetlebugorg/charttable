//! Renderer backend selector. Every backend implements the same `Gpu` API
//! behind this file, so the rest of the library imports `gpu` and never names
//! a backend (ported from lookout-marine src/gpu.zig):
//!   * Apple (macOS / iOS) -> gpu_metal.zig (direct Metal)
//!   * everything else     -> gpu_none.zig (stub; Vulkan / D3D12 / SDL ports
//!                            land here per DESIGN.md's module map)
//! lookout selects via -Dbackend build options; charttable has one real
//! backend so far, so the target OS decides. All backends expose: Gpu (+ its
//! Scene/SceneData), Uniforms, Options, NativeKind, Color.
const builtin = @import("builtin");

const impl = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
    @import("gpu_metal.zig")
else
    @import("gpu_none.zig");

pub const Gpu = impl.Gpu;
pub const Uniforms = impl.Uniforms;
pub const Options = impl.Options;
pub const NativeKind = impl.NativeKind;
pub const Color = impl.Color;

test {
    _ = impl;
}
