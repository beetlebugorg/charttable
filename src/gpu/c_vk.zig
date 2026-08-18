//! Vulkan headers for gpu_vk.zig. Android takes the NDK sysroot headers, its
//! loader and its window type; every other target takes the vendored Khronos
//! headers with no VK_USE_PLATFORM_* defined, since those drag in the X11,
//! Wayland and Windows SDKs. All gpu_vk.zig needs from them are the WSI
//! create-info structs, which it declares itself and reaches through
//! vkGetInstanceProcAddr.
const builtin = @import("builtin");

/// True when building for Android — its own headers, surface extension and
/// window handle.
pub const android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

pub const c = if (android) @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("android/native_window.h");
}) else @cImport({
    @cInclude("vulkan/vulkan.h");
});
