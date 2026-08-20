//! Renderer backend selector. Every backend implements the same `Gpu` API
//! behind this file, so the rest of the library imports `gpu` and never names
//! a backend:
//!   * Apple (macOS / iOS / visionOS) -> gpu_metal.zig (direct Metal)
//!   * Windows                        -> gpu_d3d12.zig (Direct3D 12)
//!   * Linux / Android                -> gpu_vk.zig (raw Vulkan)
//!   * freestanding / wasi            -> gpu_none.zig (stub)
//! The target OS decides, except on Windows, where `-Dgpu=vk` selects the
//! Vulkan backend instead (it carries a win32 surface path). All backends
//! expose: Gpu (+ its Scene/SceneData), Uniforms, Options, NativeKind, Color.
const builtin = @import("builtin");
const ct_build = @import("ct_build");

const impl = if (builtin.os.tag == .windows and ct_build.gpu_d3d12)
    @import("gpu_d3d12.zig")
else switch (builtin.os.tag) {
    .macos, .ios, .visionos => @import("gpu_metal.zig"),
    // gpu_none.zig stays for a target with neither (a pure wasm or freestanding
    // build); everything with a window system draws with Vulkan.
    .freestanding, .wasi => @import("gpu_none.zig"),
    else => @import("gpu_vk.zig"),
};

pub const Gpu = impl.Gpu;
pub const Uniforms = impl.Uniforms;
pub const Options = impl.Options;
pub const NativeKind = impl.NativeKind;
pub const Color = impl.Color;
/// Whether the selected backend draws at all. False only for gpu_none.zig.
pub const renders = impl.renders;

test {
    _ = impl;
}
