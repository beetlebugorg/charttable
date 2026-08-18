//! Renderer backend selector. Every backend implements the same `Gpu` API
//! behind this file, so the rest of the library imports `gpu` and never names
//! a backend (ported from lookout-marine src/gpu.zig):
//!   * Apple (macOS / iOS / visionOS) -> gpu_metal.zig (direct Metal)
//!   * Linux / Windows / Android        -> gpu_vk.zig (raw Vulkan)
//!   * freestanding / wasi              -> gpu_none.zig (stub)
//! lookout selects via -Dbackend build options; charttable has one real
//! backend so far, so the target OS decides. All backends expose: Gpu (+ its
//! Scene/SceneData), Uniforms, Options, NativeKind, Color.
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
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

test {
    _ = impl;
}
