//! Direct3D 12 backend: the device, the pipelines, the scene's buffers, and a
//! frame rendered either into a Win32 window's swapchain or offscreen for a
//! snapshot. Selected by gpu.zig on Windows.
//!
//! What the API leaves to the caller, and how it is answered here:
//!   * per-draw uniforms: one upload-heap ring, 256 B a slot, addressed by a
//!     root CBV. A draw costs one address write; nothing is allocated per
//!     frame. Root parameter 0 is the vertex block (b0), 2 the fragment block
//!     (b1), 1 a one-SRV descriptor table for the atlas or pattern cell.
//!   * vertex, index and quad buffers: upload-heap, persistently mapped and
//!     written straight through, so makeScene never touches the queue and can
//!     run on the build worker.
//!   * textures: staged through an upload buffer with rows padded to
//!     D3D12_TEXTURE_DATA_PITCH_ALIGNMENT, copied on a one-shot command list,
//!     fence-waited.
//!
//! Triangles are drawn INDEXED: scene.Range.first/count index the index
//! buffer. Single frame in flight — the chart redraws on demand, not at a
//! locked rate.
//!
//! The swapchain's pixel size is the host's declared viewport in points times
//! the pixel density, because this backend chooses that size rather than
//! adopting one from a surface. resize() means POINTS on every path, offscreen
//! included.
const std = @import("std");
const builtin = @import("builtin");
const d3d = @import("c_d3d12.zig");
const scene = @import("../scene/types.zig");
const batch = @import("../scene/batch.zig");
const png = @import("../util/png.zig");

const hlsl = struct {
    const fill_vert = @embedFile("d3d12_fill_vert");
    const fill_frag = @embedFile("d3d12_fill_frag");
    const pattern_vert = @embedFile("d3d12_pattern_vert");
    const pattern_frag = @embedFile("d3d12_pattern_frag");
    const sprite_vert = @embedFile("d3d12_sprite_vert");
    const sprite_frag = @embedFile("d3d12_sprite_frag");
    const sdf_frag = @embedFile("d3d12_sdf_frag");
    const overlay_vert = @embedFile("d3d12_overlay_vert");
    const overlay_frag = @embedFile("d3d12_overlay_frag");
};

/// Vertex/fragment uniform block (128 bytes), byte-identical to `cbuffer U` in
/// shaders/d3d12/*. THE ENGINE OWNS THIS LAYOUT (scene/types.zig); the ABI gate
/// in root.zig catches a skew at open.
pub const Uniforms = scene.Uniforms;

/// RGBA colour 0..1.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// This backend draws. A test that renders gates on this rather than on a list
/// of operating systems; whether a device is actually there stays Gpu.init's
/// answer to give.
pub const renders = true;

// Monotonic clock: the backends' shared timing ABI. The MSVC CRT has no
// clock_gettime, so this is QueryPerformanceCounter.
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;

pub fn ticksUs() i64 {
    var ctr: i64 = 0;
    var freq: i64 = 0;
    _ = QueryPerformanceCounter(&ctr);
    _ = QueryPerformanceFrequency(&freq);
    if (freq == 0) return 0;
    // Split the divide so a large counter x 1e6 cannot overflow i64.
    return @divTrunc(ctr, freq) * 1_000_000 + @divTrunc(@rem(ctr, freq) * 1_000_000, freq);
}
pub fn ticksMs() i64 {
    return @divTrunc(ticksUs(), 1000);
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("d3d12: " ++ fmt ++ "\n", args);
}
fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("d3d12: " ++ fmt ++ "\n", args);
}

fn check(hr: d3d.HRESULT, comptime what: []const u8) !void {
    if (!d3d.ok(hr)) {
        logErr(what ++ " failed (hr=0x{x:0>8})", .{@as(u32, @bitCast(hr))});
        return error.D3D12Failure;
    }
}

/// How to interpret Options.native_handle. Superset across backends so
/// root/capi share one ABI; this backend accepts win32_hwnd and d3d12_panel.
pub const NativeKind = enum(c_int) {
    none = 0,
    metal_layer = 1,
    cocoa_window = 2,
    cocoa_view = 3,
    win32_hwnd = 4, // *const Win32Window
    x11_window = 5,
    uikit_windowscene = 6,
    android_window = 7,
    wayland_surface = 8,
    /// No handle at all: the backend makes a COMPOSITION swapchain and the
    /// host composes it into its own visual tree — a XAML SwapChainPanel via
    /// ISwapChainPanelNative::SetSwapChain, or a DirectComposition visual.
    /// The host fetches the swapchain with Gpu.swapchainPtr.
    d3d12_panel = 10,
};

/// A host's Win32 window. `hinstance` is unused here and may be null; the
/// swapchain is created from the HWND alone.
pub const Win32Window = extern struct { hinstance: ?*anyopaque, hwnd: ?*anyopaque };

pub const Options = struct {
    width: u32,
    height: u32,
    want_msaa: bool = false,
    native_handle: ?*anyopaque = null,
    native_kind: NativeKind = .none,

    /// A swapchain is wanted when a handle was given, and for the panel kind,
    /// which has no handle to give: the backend creates the swapchain and the
    /// host composes it.
    pub fn wantWindow(self: Options) bool {
        if (self.native_kind == .d3d12_panel) return true;
        return self.native_handle != null and self.native_kind != .none;
    }
};

/// 256 B a slot: the alignment a root CBV address must satisfy, and >= the
/// 128 B block, so one slot holds one draw's uniforms.
const UNIFORM_STRIDE: u32 = d3d.D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT;
const RING_BYTES: u32 = 1 << 20; // ~4096 draws/frame at 256 B a slot
const MAX_SRV: u32 = 512; // atlases + pattern cells
const MAX_SC: u32 = 4; // swapchain buffers we are willing to hold
/// RTV heap layout: swapchain buffers first, then the two targets that are not
/// swapchain buffers.
const RTV_MSAA: u32 = MAX_SC;
const RTV_OFFSCREEN: u32 = MAX_SC + 1;
const RTV_COUNT: u32 = MAX_SC + 2;

/// The colour format for every render target and for the readback. Fixed
/// rather than negotiated: this backend creates the swapchain, so it picks,
/// and it picks the UNORM form. An _SRGB target would encode the palette a
/// second time on write — the chart's colours are already sRGB — and every
/// colour would come out pale.
const COLOR_FORMAT: u32 = d3d.DXGI_FORMAT_R8G8B8A8_UNORM;
const DEPTH_FORMAT: u32 = d3d.DXGI_FORMAT_D32_FLOAT;

const Buffer = struct {
    res: ?*d3d.ID3D12Resource = null,
    mapped: ?[*]u8 = null,
    gpu: u64 = 0,
    size: u64 = 0,
};

const Tex = struct {
    res: ?*d3d.ID3D12Resource = null,
    srv: u32 = 0, // slot in the shader-visible heap
    gpu: u64 = 0, // that slot's GPU descriptor handle
};

const PatternTex = struct { tex: ?Tex = null, w: f32 = 1, h: f32 = 1 };

const SEM: [*:0]const u8 = "TEXCOORD";

fn ie(index: u32, format: u32, slot: u32, offset: u32) d3d.D3D12_INPUT_ELEMENT_DESC {
    return .{
        .SemanticName = SEM,
        .SemanticIndex = index,
        .Format = format,
        .InputSlot = slot,
        .AlignedByteOffset = offset,
    };
}

// Slot 0 is geometry; slots 1 and 2 are evaluated paint, one entry per slot-0
// vertex, on two parallel buffers so a scene with no zoom-interpolated paint
// carries no extra bytes.

// fill: scene.Vertex, stride 28.
const tri_elems = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    ie(0, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 0), // a_pos
    ie(1, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 8), // a_off
    ie(2, d3d.DXGI_FORMAT_R32_UINT, 0, 16), // a_zwin
    ie(3, d3d.DXGI_FORMAT_R32_UINT, 0, 20), // a_flags
    ie(4, d3d.DXGI_FORMAT_R32_FLOAT, 0, 24), // a_depth
    ie(5, d3d.DXGI_FORMAT_R8G8B8A8_UNORM, 1, 0), // a_color
    ie(6, d3d.DXGI_FORMAT_R8G8B8A8_UNORM, 2, 0), // a_color_hi
};
// pattern: the same geometry, no paint — the cell texture IS the colour.
const pattern_elems = tri_elems[0..5].*;

// sprite + SDF: scene.Quad, stride 40.
const quad_elems = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    ie(0, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 0), // a_pos
    ie(1, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 8), // a_off
    ie(2, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 16), // a_uv
    ie(3, d3d.DXGI_FORMAT_R32_FLOAT, 0, 24), // a_weight
    ie(4, d3d.DXGI_FORMAT_R32_UINT, 0, 28), // a_zwin
    ie(5, d3d.DXGI_FORMAT_R32_UINT, 0, 32), // a_pack
    ie(6, d3d.DXGI_FORMAT_R32_FLOAT, 0, 36), // a_depth
    ie(7, d3d.DXGI_FORMAT_R8G8B8A8_UNORM, 1, 0), // a_color
    ie(8, d3d.DXGI_FORMAT_R8G8B8A8_UNORM, 2, 0), // a_color_hi
};

// overlay: scene.OverlayVertex, stride 24 — world f2@0, colour f4@8.
const overlay_elems = [_]d3d.D3D12_INPUT_ELEMENT_DESC{
    ie(0, d3d.DXGI_FORMAT_R32G32_FLOAT, 0, 0),
    ie(1, d3d.DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 8),
};

fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

fn barrier(cmd: *d3d.ID3D12GraphicsCommandList, res: *d3d.ID3D12Resource, before: u32, after: u32) void {
    if (before == after) return;
    const bars = [_]d3d.D3D12_RESOURCE_BARRIER{.{ .u = .{ .Transition = .{
        .pResource = res,
        .Subresource = d3d.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
        .StateBefore = before,
        .StateAfter = after,
    } } }};
    cmd.ResourceBarrier(1, &bars);
}

pub const Gpu = struct {
    api: d3d.Api,
    factory: *d3d.IDXGIFactory4,
    device: *d3d.ID3D12Device,
    queue: *d3d.ID3D12CommandQueue,

    swapchain: ?*d3d.IDXGISwapChain3 = null, // null => offscreen-only (snapshot)
    hwnd: ?d3d.HWND = null,
    /// Composition mode: no window, the host composes the swapchain itself.
    panel: bool = false,
    sc_bufs: [MAX_SC]?*d3d.ID3D12Resource = @splat(null),
    sc_count: u32 = 0,

    rtv_heap: *d3d.ID3D12DescriptorHeap,
    rtv_size: u32,
    dsv_heap: *d3d.ID3D12DescriptorHeap,
    srv_heap: *d3d.ID3D12DescriptorHeap,
    srv_size: u32,
    srv_cpu0: usize,
    srv_gpu0: u64,
    /// Free slots in srv_heap, as a stack. A pattern cell takes one for as long
    /// as its scene lives, so slots have to come back.
    srv_free: [MAX_SRV]u16 = undefined,
    srv_free_n: u32 = 0,

    root_sig: *d3d.ID3D12RootSignature,
    pso_fill: ?*d3d.ID3D12PipelineState = null,
    pso_pattern: ?*d3d.ID3D12PipelineState = null,
    pso_sprite: ?*d3d.ID3D12PipelineState = null,
    pso_sdf: ?*d3d.ID3D12PipelineState = null,
    pso_overlay: ?*d3d.ID3D12PipelineState = null,

    cmd_alloc: *d3d.ID3D12CommandAllocator,
    cmd: *d3d.ID3D12GraphicsCommandList,
    up_alloc: *d3d.ID3D12CommandAllocator,
    up_cmd: *d3d.ID3D12GraphicsCommandList,
    fence: *d3d.ID3D12Fence,
    fence_event: d3d.HANDLE,
    fence_value: u64 = 0,
    /// The value signalled after the last submitted frame. The next frame waits
    /// on it before resetting the allocator it is still reading.
    frame_fence_value: u64 = 0,

    ring: Buffer = .{},
    ring_off: u32 = 0,

    /// The depth target. It exists for ONE job: a range drawn with depth write
    /// puts its plane in front of the chart's opaque area fills, so those fills
    /// fail the depth test exactly where it covers them and pass everywhere
    /// else — per pixel, with no scene rebuild. Written and tested within one
    /// frame and never read afterwards.
    depth_res: ?*d3d.ID3D12Resource = null,
    msaa_res: ?*d3d.ID3D12Resource = null,
    off_res: ?*d3d.ID3D12Resource = null,
    download: Buffer = .{},
    /// The readback buffer's padded row stride; rows land on a 256 B boundary,
    /// so the snapshot has to be unpadded on the way out.
    download_pitch: u32 = 0,

    /// Host geometry (scene.OverlayVertex): one triangle stream in world space,
    /// coloured per vertex, drawn after everything else. Re-uploaded when the
    /// store's generation moves — a host batch or a zoom step, not a frame.
    overlay_buf: Buffer = .{},
    overlay_count: u32 = 0,
    overlay_gen: u64 = 0, // 0 = nothing uploaded yet (a built store is >= 1)
    /// The overlay pass's own frame uniform: the chart's, with the MVP and wrap
    /// rebuilt for the overlay's origin. setOverlay writes it, and it is the
    /// only thing that fills overlay_buf, so a buffer to draw always has a
    /// uniform to draw it with.
    overlay_u: Uniforms = std.mem.zeroes(Uniforms),

    msaa_used: bool,
    width: u32,
    height: u32,
    external_window: bool = false,
    host_pt_w: f32 = 0,
    host_pt_h: f32 = 0,
    size_changed_ms: i64 = -100000,
    pixel_density: f32 = 1.0,
    host_density: f32 = 0,
    pattern_scale: f32 = 1,

    clear: Color = .{ .r = 0.576, .g = 0.682, .b = 0.733, .a = 1.0 },
    scene: ?Scene = null,

    sprite_tex: ?Tex = null,
    /// The sprite atlas's size, so a row update can refuse one that does not
    /// belong to the texture it would write into.
    sprite_w: u32 = 0,
    sprite_h: u32 = 0,
    glyph_tex: ?Tex = null,
    glyph_bold_tex: ?Tex = null,
    glyph_italic_tex: ?Tex = null,

    /// GPU-resident whole-view scene.
    pub const SceneData = struct {
        vertices: []const scene.Vertex = &.{},
        paint: []const scene.PaintVertex = &.{},
        paint_hi: []const scene.PaintVertex = &.{},
        indices: []const u32 = &.{},
        quads: []const scene.Quad = &.{},
        quad_paint: []const scene.PaintVertex = &.{},
        ranges: []const scene.Range = &.{},
        patterns: []const scene.PatternCell = &.{},
    };

    pub const Scene = struct {
        vbuf: Buffer = .{}, // scene.Vertex, indexed
        ibuf: Buffer = .{}, // u32 indices
        pbuf: Buffer = .{}, // scene.PaintVertex, one per vertex
        phbuf: Buffer = .{}, // the zoom pair's upper half
        qbuf: Buffer = .{}, // scene.Quad, six per quad, non-indexed
        qpbuf: Buffer = .{}, // paint, one per quad vertex
        ranges: []scene.Range = &.{},
        patterns: []PatternTex = &.{},
        /// Scratch for the batch. Sized to the range count, which is the
        /// ceiling — draws only ever merge, never split — so a frame never
        /// allocates and a batch never truncates.
        draws: []scene.Draw = &.{},
        alloc: std.mem.Allocator,
    };

    // ---- open ---------------------------------------------------------------
    pub fn init(opts: Options) !Gpu {
        const api = try d3d.Api.load();

        var factory_flags: u32 = 0;
        if (std.c.getenv("CHARTTABLE_D3D12_DEBUG") != null) {
            if (api.D3D12GetDebugInterface) |get| {
                var dbg: ?*anyopaque = null;
                if (d3d.ok(get(&d3d.IID_ID3D12Debug, &dbg))) {
                    const d: *d3d.ID3D12Debug = @ptrCast(@alignCast(dbg.?));
                    d.EnableDebugLayer();
                    _ = d.Release();
                    factory_flags |= d3d.DXGI_CREATE_FACTORY_DEBUG;
                    logInfo("debug layer on", .{});
                }
            }
        }

        var factory_raw: ?*anyopaque = null;
        try check(api.CreateDXGIFactory2(factory_flags, &d3d.IID_IDXGIFactory4, &factory_raw), "CreateDXGIFactory2");
        const factory: *d3d.IDXGIFactory4 = @ptrCast(@alignCast(factory_raw.?));
        errdefer _ = factory.Release();

        const device = try pickDevice(api, factory);
        errdefer _ = device.Release();

        var qdesc = d3d.D3D12_COMMAND_QUEUE_DESC{};
        var queue_opt: ?*d3d.ID3D12CommandQueue = null;
        try check(device.CreateCommandQueue(&qdesc, &queue_opt), "CreateCommandQueue");
        const queue = queue_opt.?;
        errdefer _ = queue.Release();

        var msaa = false;
        if (opts.want_msaa and std.c.getenv("CHARTTABLE_NO_MSAA") == null) {
            var q = d3d.D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS{ .Format = COLOR_FORMAT, .SampleCount = 4 };
            if (d3d.ok(device.CheckFeatureSupport(d3d.D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS, &q, @sizeOf(@TypeOf(q)))))
                msaa = q.NumQualityLevels > 0;
        }

        const rtv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_RTV, RTV_COUNT, false);
        errdefer _ = rtv_heap.Release();
        const dsv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, false);
        errdefer _ = dsv_heap.Release();
        const srv_heap = try makeHeap(device, d3d.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, MAX_SRV, true);
        errdefer _ = srv_heap.Release();

        var alloc_opt: ?*d3d.ID3D12CommandAllocator = null;
        try check(device.CreateCommandAllocator(d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, &alloc_opt), "CreateCommandAllocator");
        const cmd_alloc = alloc_opt.?;
        errdefer _ = cmd_alloc.Release();
        var up_alloc_opt: ?*d3d.ID3D12CommandAllocator = null;
        try check(device.CreateCommandAllocator(d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, &up_alloc_opt), "CreateCommandAllocator upload");
        const up_alloc = up_alloc_opt.?;
        errdefer _ = up_alloc.Release();

        // A command list is created open; close both so the first Reset is legal.
        var cmd_opt: ?*d3d.ID3D12GraphicsCommandList = null;
        try check(device.CreateCommandList(0, d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, cmd_alloc, null, &cmd_opt), "CreateCommandList");
        const cmd = cmd_opt.?;
        errdefer _ = cmd.Release();
        _ = cmd.Close();
        var up_cmd_opt: ?*d3d.ID3D12GraphicsCommandList = null;
        try check(device.CreateCommandList(0, d3d.D3D12_COMMAND_LIST_TYPE_DIRECT, up_alloc, null, &up_cmd_opt), "CreateCommandList upload");
        const up_cmd = up_cmd_opt.?;
        errdefer _ = up_cmd.Release();
        _ = up_cmd.Close();

        var fence_opt: ?*d3d.ID3D12Fence = null;
        try check(device.CreateFence(0, &fence_opt), "CreateFence");
        const fence = fence_opt.?;
        errdefer _ = fence.Release();
        const fence_event = d3d.CreateEventA(null, d3d.FALSE, d3d.FALSE, null) orelse return error.D3D12Failure;
        errdefer _ = d3d.CloseHandle(fence_event);

        var g = Gpu{
            .api = api,
            .factory = factory,
            .device = device,
            .queue = queue,
            .rtv_heap = rtv_heap,
            .rtv_size = device.GetDescriptorHandleIncrementSize(d3d.D3D12_DESCRIPTOR_HEAP_TYPE_RTV),
            .dsv_heap = dsv_heap,
            .srv_heap = srv_heap,
            .srv_size = device.GetDescriptorHandleIncrementSize(d3d.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),
            .srv_cpu0 = srv_heap.cpuStart(),
            .srv_gpu0 = srv_heap.gpuStart(),
            .root_sig = undefined,
            .cmd_alloc = cmd_alloc,
            .cmd = cmd,
            .up_alloc = up_alloc,
            .up_cmd = up_cmd,
            .fence = fence,
            .fence_event = fence_event,
            .msaa_used = msaa,
            .width = opts.width,
            .height = opts.height,
            .external_window = opts.wantWindow(),
        };
        // Hand out the descriptor slots from the top so the first texture takes
        // slot 0 and a debug capture reads in creation order.
        var i: u32 = 0;
        while (i < MAX_SRV) : (i += 1) g.srv_free[i] = @intCast(MAX_SRV - 1 - i);
        g.srv_free_n = MAX_SRV;

        g.root_sig = try g.createRootSignature();
        errdefer _ = g.root_sig.Release();
        try g.createPipelines();
        errdefer g.releasePipelines();
        g.ring = try g.createBuffer(RING_BYTES, .upload);
        errdefer g.destroyBuffer(&g.ring);

        if (opts.wantWindow()) {
            switch (opts.native_kind) {
                .d3d12_panel => g.panel = true,
                .win32_hwnd => {
                    const w: *const Win32Window = @ptrCast(@alignCast(opts.native_handle orelse return error.Unsupported));
                    g.hwnd = w.hwnd orelse return error.Unsupported;
                },
                else => {
                    logErr("native_kind {t} is neither a Win32 window nor a composition panel", .{opts.native_kind});
                    return error.Unsupported;
                },
            }
            try g.createSwapchain();
        } else {
            try g.ensureOffscreenTargets();
        }
        logInfo("ready {d}x{d} (msaa={}, buffers={d})", .{ g.width, g.height, g.msaa_used, g.sc_count });
        return g;
    }

    /// The adapter with the most dedicated video memory that can actually make
    /// an 11_0 device, skipping the software rasterizer. A machine with a
    /// discrete GPU and an integrated one should draw the chart on the discrete
    /// one; a machine with only WARP still opens, because a snapshot is worth
    /// producing slowly.
    fn pickDevice(api: d3d.Api, factory: *d3d.IDXGIFactory4) !*d3d.ID3D12Device {
        var best: ?*d3d.ID3D12Device = null;
        var best_vram: usize = 0;
        var best_name: [128]u16 = @splat(0);
        var i: u32 = 0;
        while (i < 16) : (i += 1) {
            var ad: ?*d3d.IDXGIAdapter1 = null;
            if (!d3d.ok(factory.EnumAdapters1(i, &ad)) or ad == null) break;
            defer _ = ad.?.Release();
            var desc: d3d.DXGI_ADAPTER_DESC1 = undefined;
            if (!d3d.ok(ad.?.GetDesc1(&desc))) continue;
            if (desc.Flags & d3d.DXGI_ADAPTER_FLAG_SOFTWARE != 0) continue;
            var dev: ?*anyopaque = null;
            if (!d3d.ok(api.D3D12CreateDevice(ad.?, d3d.D3D_FEATURE_LEVEL_11_0, &d3d.IID_ID3D12Device, &dev))) continue;
            const cand: *d3d.ID3D12Device = @ptrCast(@alignCast(dev.?));
            if (best == null or desc.DedicatedVideoMemory > best_vram) {
                if (best) |b| _ = b.Release();
                best = cand;
                best_vram = desc.DedicatedVideoMemory;
                best_name = desc.Description;
            } else _ = cand.Release();
        }
        if (best) |b| {
            var name: [128]u8 = @splat(0);
            for (best_name, 0..) |wc, k| name[k] = if (wc >= 32 and wc < 127) @intCast(wc) else 0;
            logInfo("device up ({s}), {d} MiB dedicated", .{ std.mem.sliceTo(&name, 0), best_vram >> 20 });
            return b;
        }
        // No hardware adapter took an 11_0 device. Ask for the software one by
        // name rather than reporting no GPU at all.
        var warp: ?*anyopaque = null;
        if (d3d.ok(factory.v.EnumWarpAdapter(factory, &d3d.IID_IDXGIFactory4, &warp))) {
            defer _ = @as(*d3d.IUnknown, @ptrCast(@alignCast(warp.?))).Release();
            var dev: ?*anyopaque = null;
            if (d3d.ok(api.D3D12CreateDevice(warp.?, d3d.D3D_FEATURE_LEVEL_11_0, &d3d.IID_ID3D12Device, &dev))) {
                logInfo("no hardware adapter took a device; running on WARP", .{});
                return @ptrCast(@alignCast(dev.?));
            }
        }
        logErr("no adapter supports feature level 11_0", .{});
        return error.D3D12Failure;
    }

    fn makeHeap(device: *d3d.ID3D12Device, kind: u32, n: u32, shader_visible: bool) !*d3d.ID3D12DescriptorHeap {
        var desc = d3d.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = kind,
            .NumDescriptors = n,
            .Flags = if (shader_visible) d3d.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE else d3d.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
        };
        var out: ?*d3d.ID3D12DescriptorHeap = null;
        try check(device.CreateDescriptorHeap(&desc, &out), "CreateDescriptorHeap");
        return out.?;
    }

    fn rtvHandle(self: *const Gpu, index: u32) usize {
        return self.rtv_heap.cpuStart() + index * self.rtv_size;
    }
    fn dsvHandle(self: *const Gpu) usize {
        return self.dsv_heap.cpuStart();
    }

    // ---- buffers ------------------------------------------------------------
    const HeapKind = enum { upload, readback, default };

    fn createBuffer(self: *Gpu, size: u64, kind: HeapKind) !Buffer {
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = switch (kind) {
            .upload => d3d.D3D12_HEAP_TYPE_UPLOAD,
            .readback => d3d.D3D12_HEAP_TYPE_READBACK,
            .default => d3d.D3D12_HEAP_TYPE_DEFAULT,
        } };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_BUFFER,
            .Width = @max(size, 1),
            .Layout = d3d.D3D12_TEXTURE_LAYOUT_ROW_MAJOR,
        };
        // An upload-heap resource is created (and stays) GENERIC_READ; a
        // readback one COPY_DEST. Neither is ever transitioned.
        const state: u32 = switch (kind) {
            .upload => d3d.D3D12_RESOURCE_STATE_GENERIC_READ,
            .readback => d3d.D3D12_RESOURCE_STATE_COPY_DEST,
            .default => d3d.D3D12_RESOURCE_STATE_COMMON,
        };
        var out = Buffer{ .size = size };
        var res: ?*d3d.ID3D12Resource = null;
        try check(self.device.CreateCommittedResource(&heap, &desc, state, null, &res), "CreateCommittedResource buffer");
        out.res = res.?;
        out.gpu = res.?.GetGPUVirtualAddress();
        if (kind == .upload) {
            // Nothing here is ever read back through the mapping, so the read
            // range is empty and the mapping is kept for the buffer's life.
            var p: ?*anyopaque = null;
            const nothing = d3d.D3D12_RANGE{ .Begin = 0, .End = 0 };
            if (!d3d.ok(res.?.Map(0, &nothing, &p))) {
                _ = res.?.Release();
                out.res = null;
                return error.D3D12Failure;
            }
            out.mapped = @ptrCast(p);
        }
        return out;
    }

    fn destroyBuffer(self: *Gpu, b: *Buffer) void {
        _ = self;
        if (b.res) |r| {
            if (b.mapped != null) r.Unmap(0, null);
            _ = r.Release();
        }
        b.* = .{};
    }

    fn upload(self: *Gpu, bytes: []const u8) !Buffer {
        var b = try self.createBuffer(bytes.len, .upload);
        @memcpy(b.mapped.?[0..bytes.len], bytes);
        return b;
    }

    // ---- root signature + pipelines -----------------------------------------
    fn createRootSignature(self: *Gpu) !*d3d.ID3D12RootSignature {
        const range = [_]d3d.D3D12_DESCRIPTOR_RANGE{.{
            .RangeType = d3d.D3D12_DESCRIPTOR_RANGE_TYPE_SRV,
            .NumDescriptors = 1,
            .BaseShaderRegister = 0,
        }};
        const params = [_]d3d.D3D12_ROOT_PARAMETER{
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_CBV,
                .u = .{ .Descriptor = .{ .ShaderRegister = 0 } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_ALL,
            },
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE,
                .u = .{ .DescriptorTable = .{ .NumDescriptorRanges = 1, .pDescriptorRanges = &range } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_PIXEL,
            },
            .{
                .ParameterType = d3d.D3D12_ROOT_PARAMETER_TYPE_CBV,
                .u = .{ .Descriptor = .{ .ShaderRegister = 1 } },
                .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_PIXEL,
            },
        };
        const samplers = [_]d3d.D3D12_STATIC_SAMPLER_DESC{.{
            .Filter = d3d.D3D12_FILTER_MIN_MAG_MIP_LINEAR,
            .AddressU = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressV = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .AddressW = d3d.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
            .ShaderRegister = 0,
            .ShaderVisibility = d3d.D3D12_SHADER_VISIBILITY_PIXEL,
        }};
        const desc = d3d.D3D12_ROOT_SIGNATURE_DESC{
            .NumParameters = params.len,
            .pParameters = &params,
            .NumStaticSamplers = samplers.len,
            .pStaticSamplers = &samplers,
            .Flags = d3d.D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT,
        };
        var blob: ?*d3d.ID3DBlob = null;
        var errs: ?*d3d.ID3DBlob = null;
        const hr = self.api.D3D12SerializeRootSignature(&desc, d3d.D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errs);
        if (errs) |e| {
            logErr("root signature: {s}", .{e.bytes()});
            _ = e.Release();
        }
        try check(hr, "D3D12SerializeRootSignature");
        defer _ = blob.?.Release();
        var out: ?*d3d.ID3D12RootSignature = null;
        try check(self.device.CreateRootSignature(blob.?.bytes(), &out), "CreateRootSignature");
        return out.?;
    }

    fn compile(self: *Gpu, src: []const u8, comptime target: [*:0]const u8, comptime name: [:0]const u8) !*d3d.ID3DBlob {
        var code: ?*d3d.ID3DBlob = null;
        var errs: ?*d3d.ID3DBlob = null;
        const hr = self.api.D3DCompile(
            src.ptr,
            src.len,
            name.ptr,
            null,
            null,
            "main",
            target,
            d3d.D3DCOMPILE_OPTIMIZATION_LEVEL3,
            0,
            &code,
            &errs,
        );
        if (errs) |e| {
            logErr("{s}: {s}", .{ name, e.bytes() });
            _ = e.Release();
        }
        try check(hr, "D3DCompile " ++ name);
        return code orelse error.D3D12Failure;
    }

    /// `depth_write` is for a range that must occlude the fills behind it.
    /// Everything else TESTS depth and never writes it, which is what leaves
    /// the chart in painter's order among its own ranges.
    fn buildPipeline(
        self: *Gpu,
        vs: *d3d.ID3DBlob,
        ps: *d3d.ID3DBlob,
        elems: []const d3d.D3D12_INPUT_ELEMENT_DESC,
        depth_write: bool,
    ) !*d3d.ID3D12PipelineState {
        const vsb = vs.bytes();
        const psb = ps.bytes();
        var desc = d3d.D3D12_GRAPHICS_PIPELINE_STATE_DESC{
            .pRootSignature = self.root_sig,
            .VS = .{ .pShaderBytecode = vsb.ptr, .BytecodeLength = vsb.len },
            .PS = .{ .pShaderBytecode = psb.ptr, .BytecodeLength = psb.len },
            .InputLayout = .{ .pInputElementDescs = elems.ptr, .NumElements = @intCast(elems.len) },
            .NumRenderTargets = 1,
            .DSVFormat = DEPTH_FORMAT,
            .SampleDesc = .{ .Count = if (self.msaa_used) 4 else 1 },
        };
        desc.RTVFormats[0] = COLOR_FORMAT;
        desc.RasterizerState.MultisampleEnable = if (self.msaa_used) d3d.TRUE else d3d.FALSE;
        desc.BlendState.RenderTarget[0] = .{
            .BlendEnable = d3d.TRUE,
            .SrcBlend = d3d.D3D12_BLEND_SRC_ALPHA,
            .DestBlend = d3d.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOp = d3d.D3D12_BLEND_OP_ADD,
            .SrcBlendAlpha = d3d.D3D12_BLEND_ONE,
            .DestBlendAlpha = d3d.D3D12_BLEND_INV_SRC_ALPHA,
            .BlendOpAlpha = d3d.D3D12_BLEND_OP_ADD,
        };
        // LESS: the engine gives a nearer range a SMALLER depth, so a fill
        // behind a written plane fails.
        desc.DepthStencilState.DepthFunc = d3d.D3D12_COMPARISON_FUNC_LESS;
        desc.DepthStencilState.DepthWriteMask = if (depth_write)
            d3d.D3D12_DEPTH_WRITE_MASK_ALL
        else
            d3d.D3D12_DEPTH_WRITE_MASK_ZERO;
        var out: ?*d3d.ID3D12PipelineState = null;
        try check(self.device.CreateGraphicsPipelineState(&desc, &out), "CreateGraphicsPipelineState");
        return out.?;
    }

    fn createPipelines(self: *Gpu) !void {
        const fill_vs = try self.compile(hlsl.fill_vert, "vs_5_0", "fill.vert");
        defer _ = fill_vs.Release();
        const fill_ps = try self.compile(hlsl.fill_frag, "ps_5_0", "fill.frag");
        defer _ = fill_ps.Release();
        const pat_vs = try self.compile(hlsl.pattern_vert, "vs_5_0", "pattern.vert");
        defer _ = pat_vs.Release();
        const pat_ps = try self.compile(hlsl.pattern_frag, "ps_5_0", "pattern.frag");
        defer _ = pat_ps.Release();
        const spr_vs = try self.compile(hlsl.sprite_vert, "vs_5_0", "sprite.vert");
        defer _ = spr_vs.Release();
        const spr_ps = try self.compile(hlsl.sprite_frag, "ps_5_0", "sprite.frag");
        defer _ = spr_ps.Release();
        const sdf_ps = try self.compile(hlsl.sdf_frag, "ps_5_0", "sdf.frag");
        defer _ = sdf_ps.Release();
        const ov_vs = try self.compile(hlsl.overlay_vert, "vs_5_0", "overlay.vert");
        defer _ = ov_vs.Release();
        const ov_ps = try self.compile(hlsl.overlay_frag, "ps_5_0", "overlay.frag");
        defer _ = ov_ps.Release();

        self.pso_fill = try self.buildPipeline(fill_vs, fill_ps, &tri_elems, false);
        self.pso_pattern = try self.buildPipeline(pat_vs, pat_ps, &pattern_elems, false);
        self.pso_sprite = try self.buildPipeline(spr_vs, spr_ps, &quad_elems, false);
        self.pso_sdf = try self.buildPipeline(spr_vs, sdf_ps, &quad_elems, false);
        // The overlay tests depth like the chart and writes none. Its shader
        // emits z = 0, the near plane, so the chart cannot hide host content.
        self.pso_overlay = try self.buildPipeline(ov_vs, ov_ps, &overlay_elems, false);
    }

    fn releasePipelines(self: *Gpu) void {
        for ([_]?*d3d.ID3D12PipelineState{
            self.pso_fill, self.pso_pattern, self.pso_sprite, self.pso_sdf, self.pso_overlay,
        }) |p| if (p) |q| {
            _ = q.Release();
        };
        self.pso_fill = null;
        self.pso_pattern = null;
        self.pso_sprite = null;
        self.pso_sdf = null;
        self.pso_overlay = null;
    }

    // ---- fences -------------------------------------------------------------
    fn waitFence(self: *Gpu, value: u64) void {
        if (value == 0 or self.fence.GetCompletedValue() >= value) return;
        if (!d3d.ok(self.fence.SetEventOnCompletion(value, self.fence_event))) return;
        _ = d3d.WaitForSingleObject(self.fence_event, d3d.INFINITE);
    }

    /// Signal past everything submitted so far and block until the GPU reaches
    /// it. The render thread's call: a resource about to be released may still
    /// be referenced by the frame in flight.
    fn waitForGpu(self: *Gpu) void {
        self.fence_value += 1;
        const v = self.fence_value;
        if (!d3d.ok(self.queue.Signal(self.fence, v))) return;
        self.waitFence(v);
    }

    fn signalFrame(self: *Gpu) void {
        self.fence_value += 1;
        if (d3d.ok(self.queue.Signal(self.fence, self.fence_value)))
            self.frame_fence_value = self.fence_value;
    }

    /// One-shot upload commands: record via the callback, submit, fence-wait.
    /// Render-thread only.
    fn oneShot(self: *Gpu, ctx: anytype, comptime record: fn (@TypeOf(ctx), *d3d.ID3D12GraphicsCommandList) void) !void {
        self.waitFence(self.frame_fence_value);
        try check(self.up_alloc.Reset(), "reset upload allocator");
        try check(self.up_cmd.Reset(self.up_alloc, null), "reset upload command list");
        record(ctx, self.up_cmd);
        try check(self.up_cmd.Close(), "close upload command list");
        const lists = [_]*d3d.ID3D12GraphicsCommandList{self.up_cmd};
        self.queue.ExecuteCommandLists(1, &lists);
        self.waitForGpu();
    }

    // ---- swapchain + targets ------------------------------------------------
    fn createSwapchain(self: *Gpu) !void {
        if (self.hwnd == null and !self.panel) return;
        if (self.width == 0 or self.height == 0) return; // minimized; retry later
        var desc = d3d.DXGI_SWAP_CHAIN_DESC1{
            .Width = self.width,
            .Height = self.height,
            .Format = COLOR_FORMAT,
            // MSAA never lands on the swapchain: the flip model forbids a
            // multisampled back buffer, so the samples live on a target of
            // their own and resolve into it.
            .SampleDesc = .{ .Count = 1 },
            .BufferCount = 2,
        };
        var sc: ?*d3d.IDXGISwapChain3 = null;
        if (self.panel) {
            // A composition swapchain has no window: the host sets it on its
            // own visual. The chart is opaque, so IGNORE is the honest alpha
            // mode; a composition surface that refuses it takes PREMULTIPLIED,
            // which is identical for the alpha 1 this always writes.
            desc.AlphaMode = d3d.DXGI_ALPHA_MODE_IGNORE;
            var hr = self.factory.CreateSwapChainForComposition(self.queue, &desc, &sc);
            if (!d3d.ok(hr)) {
                desc.AlphaMode = d3d.DXGI_ALPHA_MODE_PREMULTIPLIED;
                hr = self.factory.CreateSwapChainForComposition(self.queue, &desc, &sc);
            }
            try check(hr, "CreateSwapChainForComposition");
            self.swapchain = sc.?;
        } else {
            const hwnd = self.hwnd.?;
            try check(self.factory.CreateSwapChainForHwnd(self.queue, hwnd, &desc, &sc), "CreateSwapChainForHwnd");
            self.swapchain = sc.?;
            // The chart owns its window's presentation; a stray alt-enter
            // putting it into exclusive fullscreen would resize the swapchain
            // behind us.
            _ = self.factory.MakeWindowAssociation(hwnd, d3d.DXGI_MWA_NO_ALT_ENTER);
        }
        try self.adoptBackBuffers();
        try self.ensureDepth();
        try self.ensureMsaa();
        self.size_changed_ms = ticksMs();
    }

    fn adoptBackBuffers(self: *Gpu) !void {
        const sc = self.swapchain orelse return;
        var d: d3d.DXGI_SWAP_CHAIN_DESC1 = undefined;
        try check(sc.GetDesc1(&d), "GetDesc1");
        self.width = d.Width;
        self.height = d.Height;
        self.sc_count = @min(d.BufferCount, MAX_SC);
        var i: u32 = 0;
        while (i < self.sc_count) : (i += 1) {
            var buf: ?*d3d.ID3D12Resource = null;
            try check(sc.GetBuffer(i, &buf), "GetBuffer");
            self.sc_bufs[i] = buf.?;
            self.device.CreateRenderTargetView(buf.?, self.rtvHandle(i));
        }
    }

    fn releaseBackBuffers(self: *Gpu) void {
        var i: u32 = 0;
        while (i < self.sc_count) : (i += 1) {
            if (self.sc_bufs[i]) |b| _ = b.Release();
            self.sc_bufs[i] = null;
        }
        self.sc_count = 0;
    }

    /// True when the swapchain no longer matches the host's declared viewport:
    /// host points x density is the pixel extent it should have.
    fn extentStale(self: *const Gpu) bool {
        if (self.host_pt_w <= 0 or self.host_pt_h <= 0 or self.pixel_density <= 0) return false;
        const w: u32 = @intFromFloat(@round(self.host_pt_w * self.pixel_density));
        const h: u32 = @intFromFloat(@round(self.host_pt_h * self.pixel_density));
        const dw = if (w > self.width) w - self.width else self.width - w;
        const dh = if (h > self.height) h - self.height else self.height - h;
        return dw > 2 or dh > 2; // slack for the points->pixels rounding
    }

    fn resizeSwapchain(self: *Gpu, w: u32, h: u32) void {
        const sc = self.swapchain orelse return;
        if (w == 0 or h == 0) return;
        self.waitForGpu();
        self.releaseBackBuffers();
        self.releaseDepth();
        self.releaseMsaa();
        if (!d3d.ok(sc.ResizeBuffers(0, w, h, d3d.DXGI_FORMAT_UNKNOWN, 0))) {
            logErr("ResizeBuffers {d}x{d} failed", .{ w, h });
            // The buffers are gone either way; take them back at whatever size
            // the swapchain still reports rather than presenting into nothing.
        }
        self.adoptBackBuffers() catch |e| {
            logErr("re-adopting back buffers failed: {t}", .{e});
            return;
        };
        self.ensureDepth() catch |e| {
            logErr("depth target: {t}", .{e});
            return;
        };
        self.ensureMsaa() catch |e| {
            logErr("msaa target: {t}", .{e});
            return;
        };
        self.size_changed_ms = ticksMs();
        logInfo("swapchain now {d}x{d} (host pts {d}x{d})", .{ self.width, self.height, self.host_pt_w, self.host_pt_h });
    }

    fn createTarget(self: *Gpu, w: u32, h: u32, format: u32, samples: u32, flags: u32, state: u32, clear: ?*const d3d.D3D12_CLEAR_VALUE) !*d3d.ID3D12Resource {
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = d3d.D3D12_HEAP_TYPE_DEFAULT };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Width = w,
            .Height = h,
            .Format = format,
            .SampleDesc = .{ .Count = samples },
            .Flags = flags,
        };
        var out: ?*d3d.ID3D12Resource = null;
        try check(self.device.CreateCommittedResource(&heap, &desc, state, clear, &out), "CreateCommittedResource target");
        return out.?;
    }

    fn ensureDepth(self: *Gpu) !void {
        if (self.depth_res != null) return;
        if (self.width == 0 or self.height == 0) return;
        const clear = d3d.D3D12_CLEAR_VALUE{
            .Format = DEPTH_FORMAT,
            .u = .{ .DepthStencil = .{ .Depth = 1.0, .Stencil = 0 } },
        };
        self.depth_res = try self.createTarget(
            self.width,
            self.height,
            DEPTH_FORMAT,
            if (self.msaa_used) 4 else 1,
            d3d.D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
            d3d.D3D12_RESOURCE_STATE_DEPTH_WRITE,
            &clear,
        );
        self.device.CreateDepthStencilView(self.depth_res, self.dsvHandle());
    }

    fn releaseDepth(self: *Gpu) void {
        if (self.depth_res) |r| _ = r.Release();
        self.depth_res = null;
    }

    fn ensureMsaa(self: *Gpu) !void {
        if (!self.msaa_used or self.msaa_res != null) return;
        if (self.width == 0 or self.height == 0) return;
        self.msaa_res = try self.createTarget(
            self.width,
            self.height,
            COLOR_FORMAT,
            4,
            d3d.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
            d3d.D3D12_RESOURCE_STATE_RENDER_TARGET,
            null,
        );
        self.device.CreateRenderTargetView(self.msaa_res, self.rtvHandle(RTV_MSAA));
    }

    fn releaseMsaa(self: *Gpu) void {
        if (self.msaa_res) |r| _ = r.Release();
        self.msaa_res = null;
    }

    fn ensureOffscreenTargets(self: *Gpu) !void {
        try self.ensureDepth();
        try self.ensureMsaa();
        if (self.off_res == null) {
            self.off_res = try self.createTarget(
                self.width,
                self.height,
                COLOR_FORMAT,
                1,
                d3d.D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
                d3d.D3D12_RESOURCE_STATE_RENDER_TARGET,
                null,
            );
            self.device.CreateRenderTargetView(self.off_res, self.rtvHandle(RTV_OFFSCREEN));
        }
        if (self.download.res == null) {
            self.download_pitch = alignUp(self.width * 4, d3d.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
            self.download = try self.createBuffer(@as(u64, self.download_pitch) * self.height, .readback);
        }
    }

    fn releaseOffscreen(self: *Gpu) void {
        if (self.off_res) |r| _ = r.Release();
        self.off_res = null;
        self.destroyBuffer(&self.download);
        self.download_pitch = 0;
    }

    /// Resize the render surface. width/height are logical POINTS from the
    /// host; the pixel size is those times the pixel density.
    pub fn resize(self: *Gpu, width_pts: u32, height_pts: u32) void {
        self.host_pt_w = @floatFromInt(width_pts);
        self.host_pt_h = @floatFromInt(height_pts);
        const d = if (self.pixel_density > 0) self.pixel_density else 1.0;
        const w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(width_pts)) * d));
        const h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(height_pts)) * d));

        if (self.swapchain != null) {
            if (self.extentStale()) self.resizeSwapchain(w, h);
            return;
        }
        if (self.hwnd != null or self.panel) {
            // Opened before there was any size to make a swapchain against.
            // This is the first one it has had.
            if (w == 0 or h == 0) return;
            self.width = w;
            self.height = h;
            self.createSwapchain() catch |e| logErr("swapchain at {d}x{d}: {t}", .{ w, h, e });
            return;
        }
        // `external_window` separates the two ways swapchain can be null: a
        // snapshot-only Gpu, which needs offscreen targets at the new size, and
        // a host window that has gone away, which needs nothing until one comes
        // back. Sizing offscreen targets for the second would allocate a
        // full-screen image per resize for a view nobody can see.
        if (self.external_window) return;
        if (w == self.width and h == self.height) return;
        if (w == 0 or h == 0) return;
        self.waitForGpu();
        self.releaseOffscreen();
        self.releaseDepth();
        self.releaseMsaa();
        self.width = w;
        self.height = h;
        self.ensureOffscreenTargets() catch |e| logErr("resize to {d}x{d}: {t}", .{ w, h, e });
    }

    /// The swapchain this backend owns, for a host that composes it itself
    /// (NativeKind.d3d12_panel — ISwapChainPanelNative::SetSwapChain). Null on
    /// every other kind. Ownership stays here: resize rebuilds its buffers and
    /// deinit releases it, so the host must drop its reference first.
    pub fn swapchainPtr(self: *Gpu) ?*anyopaque {
        if (!self.panel) return null;
        return self.swapchain;
    }

    /// The host's own scale factor. Set once at open; the pixel size of every
    /// target follows from it and the declared point viewport.
    pub fn setPixelDensity(self: *Gpu, d: f32) void {
        if (d <= 0.2 or d >= 8.0 or d == self.pixel_density) return;
        self.host_density = d;
        self.pixel_density = d;
        if (self.host_pt_w > 0 and self.host_pt_h > 0)
            self.resize(@intFromFloat(self.host_pt_w), @intFromFloat(self.host_pt_h));
    }

    // ---- descriptors + textures ---------------------------------------------
    fn takeSrvSlot(self: *Gpu) !u32 {
        if (self.srv_free_n == 0) return error.D3D12Failure;
        self.srv_free_n -= 1;
        return self.srv_free[self.srv_free_n];
    }

    fn giveSrvSlot(self: *Gpu, slot: u32) void {
        if (self.srv_free_n >= MAX_SRV) return;
        self.srv_free[self.srv_free_n] = @intCast(slot);
        self.srv_free_n += 1;
    }

    fn makeTexture(self: *Gpu, rgba: []const u8, w: u32, h: u32) !Tex {
        if (w == 0 or h == 0) return error.D3D12Failure;
        var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = d3d.D3D12_HEAP_TYPE_DEFAULT };
        var desc = d3d.D3D12_RESOURCE_DESC{
            .Dimension = d3d.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
            .Width = w,
            .Height = h,
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
        };
        var res: ?*d3d.ID3D12Resource = null;
        try check(self.device.CreateCommittedResource(&heap, &desc, d3d.D3D12_RESOURCE_STATE_COPY_DEST, null, &res), "CreateCommittedResource texture");
        errdefer _ = res.?.Release();

        try self.copyRowsIntoTexture(res.?, rgba, w, h, 0, h, d3d.D3D12_RESOURCE_STATE_COPY_DEST);

        const slot = try self.takeSrvSlot();
        errdefer self.giveSrvSlot(slot);
        var srv = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{
            .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            .ViewDimension = d3d.D3D12_SRV_DIMENSION_TEXTURE2D,
            .u = .{ .Texture2D = .{ .MipLevels = 1 } },
        };
        self.device.CreateShaderResourceView(res.?, &srv, self.srv_cpu0 + slot * self.srv_size);
        return .{ .res = res.?, .srv = slot, .gpu = self.srv_gpu0 + @as(u64, slot) * self.srv_size };
    }

    /// Copy `rows` rows of `rgba` (which is a full w x h image; the band starts
    /// at row y0) into the texture, leaving it PIXEL_SHADER_RESOURCE. `from` is
    /// the state the texture is in on the way in.
    fn copyRowsIntoTexture(self: *Gpu, res: *d3d.ID3D12Resource, rgba: []const u8, w: u32, h: u32, y0: u32, rows: u32, from: u32) !void {
        _ = h;
        const src_pitch = w * 4;
        const dst_pitch = alignUp(src_pitch, d3d.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        var staging = try self.createBuffer(@as(u64, dst_pitch) * rows, .upload);
        defer self.destroyBuffer(&staging);
        const dst = staging.mapped.?;
        var r: u32 = 0;
        while (r < rows) : (r += 1) {
            const s = (@as(usize, y0) + r) * src_pitch;
            @memcpy(dst[r * dst_pitch ..][0..src_pitch], rgba[s .. s + src_pitch]);
        }

        const Ctx = struct {
            res: *d3d.ID3D12Resource,
            buf: *d3d.ID3D12Resource,
            w: u32,
            y0: u32,
            rows: u32,
            pitch: u32,
            from: u32,
        };
        try self.oneShot(Ctx{
            .res = res,
            .buf = staging.res.?,
            .w = w,
            .y0 = y0,
            .rows = rows,
            .pitch = dst_pitch,
            .from = from,
        }, struct {
            fn rec(ctx: Ctx, cmd: *d3d.ID3D12GraphicsCommandList) void {
                barrier(cmd, ctx.res, ctx.from, d3d.D3D12_RESOURCE_STATE_COPY_DEST);
                const dst_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
                    .pResource = ctx.res,
                    .Type = d3d.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
                    .u = .{ .SubresourceIndex = 0 },
                };
                const src_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
                    .pResource = ctx.buf,
                    .Type = d3d.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
                    .u = .{ .PlacedFootprint = .{ .Footprint = .{
                        .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
                        .Width = ctx.w,
                        .Height = ctx.rows,
                        .RowPitch = ctx.pitch,
                    } } },
                };
                cmd.CopyTextureRegion(&dst_loc, 0, ctx.y0, 0, &src_loc, null);
                barrier(cmd, ctx.res, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            }
        }.rec);
    }

    fn destroyTexture(self: *Gpu, t: *Tex) void {
        if (t.res) |r| {
            self.waitForGpu();
            _ = r.Release();
            self.giveSrvSlot(t.srv);
        }
        t.* = .{};
    }

    pub fn uploadSpriteAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        const t = try self.makeTexture(rgba, w, h);
        if (self.sprite_tex) |*old| self.destroyTexture(old);
        self.sprite_tex = t;
        self.sprite_w = w;
        self.sprite_h = h;
    }

    /// Replace a horizontal band of the sprite atlas in place. The symbol atlas
    /// grows a row at a time as new symbols bake, and re-uploading the whole
    /// sheet for each one showed up as a stall on the interactive path. False
    /// means the caller should upload the atlas whole instead.
    pub fn updateSpriteAtlasRows(self: *Gpu, rgba: []const u8, w: u32, h: u32, y0: u32, rows: u32) bool {
        const t = self.sprite_tex orelse return false;
        const res = t.res orelse return false;
        if (w != self.sprite_w or h != self.sprite_h) return false;
        if (rows == 0 or y0 + rows > h) return false;
        if (rgba.len < (@as(usize, y0) + rows) * w * 4) return false;
        self.copyRowsIntoTexture(res, rgba, w, h, y0, rows, d3d.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE) catch return false;
        return true;
    }

    pub fn uploadGlyphAtlas(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        const t = try self.makeTexture(rgba, w, h);
        if (self.glyph_tex) |*old| self.destroyTexture(old);
        self.glyph_tex = t;
    }
    pub fn uploadGlyphAtlasBold(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        const t = try self.makeTexture(rgba, w, h);
        if (self.glyph_bold_tex) |*old| self.destroyTexture(old);
        self.glyph_bold_tex = t;
    }
    pub fn uploadGlyphAtlasItalic(self: *Gpu, rgba: []const u8, w: u32, h: u32) !void {
        const t = try self.makeTexture(rgba, w, h);
        if (self.glyph_italic_tex) |*old| self.destroyTexture(old);
        self.glyph_italic_tex = t;
    }

    // ---- the scene ----------------------------------------------------------
    /// Which atlases were actually uploaded, as the bitmask the batcher wants.
    /// A missing bold/italic tier falls back to the regular glyph atlas there.
    fn atlasHave(self: *const Gpu) u8 {
        var m: u8 = 0;
        if (self.sprite_tex != null) m |= scene.AtlasBit.bit(.sprite);
        if (self.glyph_tex != null) m |= scene.AtlasBit.bit(.glyph);
        if (self.glyph_bold_tex != null) m |= scene.AtlasBit.bit(.glyph_bold);
        if (self.glyph_italic_tex != null) m |= scene.AtlasBit.bit(.glyph_italic);
        return m;
    }

    fn atlasTexture(self: *const Gpu, atlas: scene.Atlas) ?Tex {
        return switch (atlas) {
            .glyph => self.glyph_tex,
            .glyph_bold => self.glyph_bold_tex,
            .glyph_italic => self.glyph_italic_tex,
            else => self.sprite_tex,
        };
    }

    /// Which draws this scene needs. An empty slice if the batch somehow
    /// exceeded its buffer, since a truncated batch is missing chart rather
    /// than merely slow.
    fn batchScene(self: *const Gpu, s: *const Scene) []const scene.Draw {
        if (s.ranges.len == 0 or s.draws.len == 0) return &.{};
        const opts = scene.BatchOpts{
            .exclude_opaque_tris = false,
            .atlas_have = self.atlasHave(),
            .halo = .{ self.clear.r, self.clear.g, self.clear.b, 1 },
        };
        const n = batch.batch(s.ranges, opts, s.draws);
        return if (n > s.draws.len) &.{} else s.draws[0..n];
    }

    /// Stage a scene's buffers. Upload-heap and persistently mapped, written
    /// straight through, so this never touches the queue and may run on the
    /// build worker while a frame is in flight — unless the scene carries
    /// pattern cells, whose textures go through the queue like any other.
    pub fn makeScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) !Scene {
        var out = Scene{ .alloc = alloc };
        errdefer self.freeSceneValue(&out);

        if (data.vertices.len > 0 and data.indices.len > 0) {
            out.vbuf = try self.upload(std.mem.sliceAsBytes(data.vertices));
            out.ibuf = try self.upload(std.mem.sliceAsBytes(data.indices));
            if (data.paint.len > 0)
                out.pbuf = try self.upload(std.mem.sliceAsBytes(data.paint));
            // A scene with no zoom-interpolated paint carries no second stream;
            // binding the first twice makes the shader's mix a no-op.
            if (data.paint_hi.len > 0)
                out.phbuf = try self.upload(std.mem.sliceAsBytes(data.paint_hi));
        }
        if (data.quads.len > 0) {
            out.qbuf = try self.upload(std.mem.sliceAsBytes(data.quads));
            if (data.quad_paint.len > 0)
                out.qpbuf = try self.upload(std.mem.sliceAsBytes(data.quad_paint));
        }
        if (data.ranges.len > 0) {
            out.ranges = try alloc.dupe(scene.Range, data.ranges);
            out.draws = try alloc.alloc(scene.Draw, data.ranges.len);
        }
        if (data.patterns.len > 0) {
            out.patterns = try alloc.alloc(PatternTex, data.patterns.len);
            @memset(out.patterns, .{});
            try self.makePatternTextures(alloc, data.patterns, out.patterns);
        }
        return out;
    }

    /// All of a scene's pattern-cell textures in ONE submission and ONE wait.
    /// A raster view carries dozens of tile textures per rebuild, and a full
    /// GPU round-trip each (makeTexture/oneShot) costs seconds per rebuild on
    /// a software device — the map then never looks idle.
    fn makePatternTextures(self: *Gpu, alloc: std.mem.Allocator, cells: []const scene.PatternCell, out: []PatternTex) !void {
        const Job = struct { res: *d3d.ID3D12Resource, buf: Buffer, w: u32, rows: u32, pitch: u32, cell: usize };
        var jobs: std.ArrayList(Job) = .empty;
        defer jobs.deinit(alloc);
        // On any failure the unconsumed jobs go; entries already landed in
        // `out` are the caller's errdefer (freeSceneValue). destroyBuffer
        // zeroes the buffer, so revisiting a consumed job's buf is harmless.
        var done: usize = 0;
        errdefer for (jobs.items[done..]) |*j| {
            self.destroyBuffer(&j.buf);
            _ = j.res.Release();
        };

        for (cells, 0..) |cell, i| {
            if (cell.w == 0 or cell.h == 0 or cell.rgba.len == 0) continue;
            var heap = d3d.D3D12_HEAP_PROPERTIES{ .Type = d3d.D3D12_HEAP_TYPE_DEFAULT };
            var desc = d3d.D3D12_RESOURCE_DESC{
                .Dimension = d3d.D3D12_RESOURCE_DIMENSION_TEXTURE2D,
                .Width = cell.w,
                .Height = cell.h,
                .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
            };
            var res: ?*d3d.ID3D12Resource = null;
            try check(self.device.CreateCommittedResource(&heap, &desc, d3d.D3D12_RESOURCE_STATE_COPY_DEST, null, &res), "CreateCommittedResource texture");
            errdefer _ = res.?.Release();

            const src_pitch = cell.w * 4;
            const dst_pitch = alignUp(src_pitch, d3d.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
            var staging = try self.createBuffer(@as(u64, dst_pitch) * cell.h, .upload);
            errdefer self.destroyBuffer(&staging);
            const dst = staging.mapped.?;
            var r: u32 = 0;
            while (r < cell.h) : (r += 1) {
                const s = @as(usize, r) * src_pitch;
                @memcpy(dst[r * dst_pitch ..][0..src_pitch], cell.rgba[s .. s + src_pitch]);
            }
            try jobs.append(alloc, .{ .res = res.?, .buf = staging, .w = cell.w, .rows = cell.h, .pitch = dst_pitch, .cell = i });
        }
        if (jobs.items.len == 0) return;

        self.waitFence(self.frame_fence_value);
        try check(self.up_alloc.Reset(), "reset upload allocator");
        try check(self.up_cmd.Reset(self.up_alloc, null), "reset upload command list");
        for (jobs.items) |j| {
            const dst_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
                .pResource = j.res,
                .Type = d3d.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
                .u = .{ .SubresourceIndex = 0 },
            };
            const src_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
                .pResource = j.buf.res.?,
                .Type = d3d.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
                .u = .{ .PlacedFootprint = .{ .Footprint = .{
                    .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
                    .Width = j.w,
                    .Height = j.rows,
                    .Depth = 1,
                    .RowPitch = j.pitch,
                } } },
            };
            self.up_cmd.CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, null);
            barrier(self.up_cmd, j.res, d3d.D3D12_RESOURCE_STATE_COPY_DEST, d3d.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        }
        try check(self.up_cmd.Close(), "close upload command list");
        const lists = [_]*d3d.ID3D12GraphicsCommandList{self.up_cmd};
        self.queue.ExecuteCommandLists(1, &lists);
        self.waitForGpu();

        for (jobs.items) |*j| {
            self.destroyBuffer(&j.buf);
            const slot = try self.takeSrvSlot();
            var srv = d3d.D3D12_SHADER_RESOURCE_VIEW_DESC{
                .Format = d3d.DXGI_FORMAT_R8G8B8A8_UNORM,
                .ViewDimension = d3d.D3D12_SRV_DIMENSION_TEXTURE2D,
                .u = .{ .Texture2D = .{ .MipLevels = 1 } },
            };
            self.device.CreateShaderResourceView(j.res, &srv, self.srv_cpu0 + slot * self.srv_size);
            out[j.cell] = .{
                .tex = .{ .res = j.res, .srv = slot, .gpu = self.srv_gpu0 + @as(u64, slot) * self.srv_size },
                .w = @floatFromInt(j.w),
                .h = @floatFromInt(j.rows),
            };
            done += 1;
        }
    }

    pub fn adoptScene(self: *Gpu, sc: Scene) void {
        self.freeScene();
        self.scene = sc;
    }

    pub fn uploadScene(self: *Gpu, alloc: std.mem.Allocator, data: SceneData) !void {
        self.adoptScene(try self.makeScene(alloc, data));
    }

    /// Repaint without rebuilding geometry: the paint stream alone changes when
    /// only the palette moved.
    pub fn updatePaint(self: *Gpu, paint: []const scene.PaintVertex) !void {
        const s = if (self.scene) |*sc| sc else return;
        if (s.pbuf.mapped == null or paint.len == 0) return;
        // The frame in flight is reading this buffer.
        self.waitFence(self.frame_fence_value);
        const bytes = std.mem.sliceAsBytes(paint);
        const n = @min(bytes.len, s.pbuf.size);
        @memcpy(s.pbuf.mapped.?[0..n], bytes[0..n]);
    }

    /// The quad half of the same contract: a raster cross-fade rewrites the
    /// quad paint stream's alphas frame by frame, and nothing else moves.
    pub fn updateQuadPaint(self: *Gpu, quad_paint: []const scene.PaintVertex) !void {
        const s = if (self.scene) |*sc| sc else return;
        if (s.qpbuf.mapped == null or quad_paint.len == 0) return;
        // The frame in flight is reading this buffer.
        self.waitFence(self.frame_fence_value);
        const bytes = std.mem.sliceAsBytes(quad_paint);
        const n = @min(bytes.len, s.qpbuf.size);
        @memcpy(s.qpbuf.mapped.?[0..n], bytes[0..n]);
    }

    pub fn freeStagedScene(self: *Gpu, sc: *Scene) void {
        self.freeSceneValue(sc);
    }

    fn freeSceneValue(self: *Gpu, s: *Scene) void {
        self.destroyBuffer(&s.vbuf);
        self.destroyBuffer(&s.ibuf);
        self.destroyBuffer(&s.pbuf);
        self.destroyBuffer(&s.phbuf);
        self.destroyBuffer(&s.qbuf);
        self.destroyBuffer(&s.qpbuf);
        // ONE wait for the lot: destroyTexture waits per texture, and a
        // raster view's scene holds dozens.
        for (s.patterns) |*pt| {
            if (pt.tex == null) continue;
            self.waitForGpu();
            break;
        }
        for (s.patterns) |*pt| if (pt.tex) |*t| {
            _ = t.res.?.Release();
            self.giveSrvSlot(t.srv);
            t.* = .{};
        };
        if (s.patterns.len > 0) s.alloc.free(s.patterns);
        if (s.ranges.len > 0) s.alloc.free(s.ranges);
        if (s.draws.len > 0) s.alloc.free(s.draws);
        s.patterns = &.{};
        s.ranges = &.{};
        s.draws = &.{};
    }

    pub fn freeScene(self: *Gpu) void {
        if (self.scene) |*s| {
            // The frame in flight may still be reading these buffers.
            self.waitFence(self.frame_fence_value);
            self.freeSceneValue(s);
            self.scene = null;
        }
    }

    // ---- the overlay --------------------------------------------------------
    /// The host's own geometry, drawn after the scene in the same command list
    /// so the two cannot tear apart. `generation` only moves when the vertices
    /// changed, so a still overlay re-uploads nothing.
    pub fn setOverlay(self: *Gpu, verts: []const scene.OverlayVertex, generation: u64, u: Uniforms) !void {
        self.overlay_u = u;
        if (generation == self.overlay_gen) return;
        self.overlay_gen = generation;
        self.freeOverlayBuf();
        if (verts.len == 0) return;
        self.overlay_buf = try self.upload(std.mem.sliceAsBytes(verts));
        self.overlay_count = @intCast(verts.len);
    }

    pub fn clearOverlay(self: *Gpu) void {
        self.freeOverlayBuf();
        self.overlay_gen = 0;
    }

    fn freeOverlayBuf(self: *Gpu) void {
        if (self.overlay_buf.res != null) {
            self.waitFence(self.frame_fence_value);
            self.destroyBuffer(&self.overlay_buf);
        }
        self.overlay_count = 0;
    }

    // ---- the frame ----------------------------------------------------------
    /// Copy a Uniforms into the ring; returns the GPU address of its slot.
    fn pushUniform(self: *Gpu, u: *const Uniforms) ?u64 {
        if (self.ring_off + UNIFORM_STRIDE > RING_BYTES) return null; // ring full: skip draw
        const off = self.ring_off;
        @memcpy(self.ring.mapped.?[off .. off + @sizeOf(Uniforms)], std.mem.asBytes(u));
        self.ring_off = off + UNIFORM_STRIDE;
        return self.ring.gpu + off;
    }

    fn recordDraws(self: *Gpu, cmd: *d3d.ID3D12GraphicsCommandList, rtv: usize, u: Uniforms) void {
        self.ring_off = 0;
        const dsv = self.dsvHandle();
        const rtvs = [_]usize{rtv};
        cmd.OMSetRenderTargets(1, &rtvs, d3d.FALSE, &dsv);
        const clear = [4]f32{ self.clear.r, self.clear.g, self.clear.b, self.clear.a };
        cmd.ClearRenderTargetView(rtv, &clear);
        // The depth clear is FARTHEST (1.0), so every range passes until
        // something puts a plane in front of the fills.
        cmd.ClearDepthStencilView(dsv, d3d.D3D12_CLEAR_FLAG_DEPTH, 1.0, 0);

        // D3D12 clip space is Y-up with a [0,1] depth range, which is what the
        // shared MVP and the paint-order depths already assume, so this is the
        // plain viewport.
        const vps = [_]d3d.D3D12_VIEWPORT{.{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.width),
            .Height = @floatFromInt(self.height),
        }};
        cmd.RSSetViewports(1, &vps);
        const rects = [_]d3d.D3D12_RECT{.{
            .left = 0,
            .top = 0,
            .right = @intCast(self.width),
            .bottom = @intCast(self.height),
        }};
        cmd.RSSetScissorRects(1, &rects);

        cmd.SetGraphicsRootSignature(self.root_sig);
        const heaps = [_]*d3d.ID3D12DescriptorHeap{self.srv_heap};
        cmd.SetDescriptorHeaps(1, &heaps);
        cmd.IASetPrimitiveTopology(d3d.D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        self.recordScene(cmd, u);
        // The overlay runs even when there is no scene — an own-ship symbol
        // must not vanish because the chart is still loading.
        self.recordOverlay(cmd);
    }

    /// The chart itself, in paint order.
    fn recordScene(self: *Gpu, cmd: *d3d.ID3D12GraphicsCommandList, u: Uniforms) void {
        const s = if (self.scene) |*sc| sc else return; // no scene: clear only
        var bound_pso: ?*d3d.ID3D12PipelineState = null;
        var bound_tex: u64 = 0;
        var bound_prim: ?scene.Prim = null;

        // The batcher folds contiguous ranges sharing a spec into one call.
        // That matters: a coastal view carries thousands of ranges, and binding
        // each one separately dominated the frame. This loop binds and draws
        // what it is handed, and nothing else.
        for (self.batchScene(s)) |dr| {
            const tri = dr.prim == .triangles;
            var uu = u;
            var pso: ?*d3d.ID3D12PipelineState = null;
            var tex_gpu: u64 = 0;
            const halo = dr.pipeline == .sdf;

            if (tri) {
                if (s.vbuf.res == null or s.ibuf.res == null) continue;
                pso = self.pso_fill;
                if (dr.pipeline == .pattern) {
                    // Whether a cell rasterized is ours to know; without one
                    // the fill under it already drew, so this draws nothing.
                    if (dr.pattern >= s.patterns.len) continue;
                    const pt = s.patterns[dr.pattern];
                    const t = pt.tex orelse continue;
                    // Scale the cell with the zoom so it tracks the geometry the
                    // MVP scales, instead of swimming during a zoom animation.
                    const cs = self.pixel_density * self.pattern_scale;
                    uu.cell_px = .{ pt.w * cs, pt.h * cs };
                    pso = self.pso_pattern;
                    tex_gpu = t.gpu;
                }
            } else {
                if (s.qbuf.res == null) continue;
                // A raster range samples the image the scene carries for it,
                // not an atlas — but it still rides the sprite pipeline: a
                // raster tile IS a textured world-space quad with the
                // antimeridian wrap and paint-order depth the sprite shader
                // already does.
                const tex = if (dr.pipeline == .raster) blk: {
                    if (dr.pattern >= s.patterns.len) continue;
                    break :blk s.patterns[dr.pattern].tex orelse continue;
                } else self.atlasTexture(dr.atlas) orelse continue;
                pso = if (halo) self.pso_sdf else self.pso_sprite;
                tex_gpu = tex.gpu;
            }
            const p = pso orelse continue;

            if (p != bound_pso) {
                cmd.SetPipelineState(p);
                bound_pso = p;
            }
            // The vertex streams change with the primitive, not with every draw.
            if (bound_prim == null or bound_prim.? != dr.prim) {
                if (tri) {
                    // The paint streams ride parallel buffers; a scene with no
                    // zoom-interpolated paint binds the first one twice, and the
                    // shader's mix collapses to a no-op. With no paint at all,
                    // the geometry buffer stands in at the paint stride, which
                    // is what the fill shader's colour then reads.
                    const pb = if (s.pbuf.res != null) s.pbuf else s.vbuf;
                    const ph = if (s.phbuf.res != null) s.phbuf else pb;
                    const views = [3]d3d.D3D12_VERTEX_BUFFER_VIEW{
                        vbv(s.vbuf, @sizeOf(scene.Vertex)),
                        vbv(pb, @sizeOf(scene.PaintVertex)),
                        vbv(ph, @sizeOf(scene.PaintVertex)),
                    };
                    cmd.IASetVertexBuffers(0, 3, &views);
                    const ib = d3d.D3D12_INDEX_BUFFER_VIEW{
                        .BufferLocation = s.ibuf.gpu,
                        .SizeInBytes = @intCast(s.ibuf.size),
                        .Format = d3d.DXGI_FORMAT_R32_UINT,
                    };
                    cmd.IASetIndexBuffer(&ib);
                } else {
                    const qp = if (s.qpbuf.res != null) s.qpbuf else s.qbuf;
                    const views = [3]d3d.D3D12_VERTEX_BUFFER_VIEW{
                        vbv(s.qbuf, @sizeOf(scene.Quad)),
                        vbv(qp, @sizeOf(scene.PaintVertex)),
                        vbv(qp, @sizeOf(scene.PaintVertex)),
                    };
                    cmd.IASetVertexBuffers(0, 3, &views);
                }
                bound_prim = dr.prim;
            }
            if (tex_gpu != 0 and tex_gpu != bound_tex) {
                cmd.SetGraphicsRootDescriptorTable(1, tex_gpu);
                bound_tex = tex_gpu;
            }
            const vaddr = self.pushUniform(&uu) orelse continue;
            cmd.SetGraphicsRootConstantBufferView(0, vaddr);
            if (halo) {
                // The halo renders in the scene's background colour (sdf.frag,
                // b1): a hardcoded white halo glared at night.
                uu.color = dr.color;
                const faddr = self.pushUniform(&uu) orelse continue;
                cmd.SetGraphicsRootConstantBufferView(2, faddr);
            }
            if (tri) {
                cmd.DrawIndexedInstanced(dr.count, 1, dr.first, 0, 0);
            } else {
                cmd.DrawInstanced(dr.count, 1, dr.first, 0);
            }
        }
    }

    fn vbv(b: Buffer, stride: u32) d3d.D3D12_VERTEX_BUFFER_VIEW {
        return .{ .BufferLocation = b.gpu, .SizeInBytes = @intCast(b.size), .StrideInBytes = stride };
    }

    /// Draw the overlay LAST — after the whole chart, in the same command list.
    /// The overlay carries its OWN uniform (setOverlay): the shader reads mvp
    /// and wrap_x, and both are built for the overlay's origin, not the
    /// chart's. It goes in the ring like every other draw's.
    fn recordOverlay(self: *Gpu, cmd: *d3d.ID3D12GraphicsCommandList) void {
        if (self.overlay_count == 0 or self.overlay_buf.res == null) return;
        const pso = self.pso_overlay orelse return;
        cmd.SetPipelineState(pso);
        const views = [_]d3d.D3D12_VERTEX_BUFFER_VIEW{vbv(self.overlay_buf, @sizeOf(scene.OverlayVertex))};
        cmd.IASetVertexBuffers(0, 1, &views);
        const vaddr = self.pushUniform(&self.overlay_u) orelse return;
        cmd.SetGraphicsRootConstantBufferView(0, vaddr);
        cmd.DrawInstanced(self.overlay_count, 1, 0, 0);
    }

    /// Render one frame to the window and present. Returns false if no window.
    pub fn renderWindow(self: *Gpu, u: Uniforms) bool {
        return self.renderWindowFallible(u) catch |e| {
            logErr("frame failed: {t}", .{e});
            return false;
        };
    }

    fn renderWindowFallible(self: *Gpu, u: Uniforms) !bool {
        const sc = self.swapchain orelse return false;
        if (self.sc_count == 0) return true; // minimized; nothing to draw into
        if (self.extentStale()) {
            self.resizeSwapchain(
                @intFromFloat(@round(self.host_pt_w * self.pixel_density)),
                @intFromFloat(@round(self.host_pt_h * self.pixel_density)),
            );
            if (self.sc_count == 0) return true;
        }
        self.waitFence(self.frame_fence_value);
        const index = sc.GetCurrentBackBufferIndex();
        if (index >= self.sc_count) return true;
        const back = self.sc_bufs[index] orelse return true;

        try check(self.cmd_alloc.Reset(), "reset frame allocator");
        try check(self.cmd.Reset(self.cmd_alloc, null), "reset frame command list");
        const cmd = self.cmd;

        if (self.msaa_res) |ms| {
            barrier(cmd, back, d3d.D3D12_RESOURCE_STATE_PRESENT, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST);
            self.recordDraws(cmd, self.rtvHandle(RTV_MSAA), u);
            barrier(cmd, ms, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            cmd.ResolveSubresource(back, 0, ms, 0, COLOR_FORMAT);
            barrier(cmd, ms, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            barrier(cmd, back, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST, d3d.D3D12_RESOURCE_STATE_PRESENT);
        } else {
            barrier(cmd, back, d3d.D3D12_RESOURCE_STATE_PRESENT, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            self.recordDraws(cmd, self.rtvHandle(index), u);
            barrier(cmd, back, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_PRESENT);
        }
        try check(cmd.Close(), "close frame command list");
        const lists = [_]*d3d.ID3D12GraphicsCommandList{cmd};
        self.queue.ExecuteCommandLists(1, &lists);

        const pr = sc.Present(1, 0); // vsync
        if (pr == d3d.DXGI_ERROR_DEVICE_REMOVED or pr == d3d.DXGI_ERROR_DEVICE_RESET) {
            logErr("device removed at present (reason 0x{x:0>8})", .{@as(u32, @bitCast(self.device.GetDeviceRemovedReason()))});
            return error.D3D12Failure;
        }
        self.signalFrame();
        return true;
    }

    /// Render one frame offscreen and read the pixels back (RGBA8, top-down).
    pub fn renderOffscreen(self: *Gpu, alloc: std.mem.Allocator, u: Uniforms) ![]u8 {
        try self.ensureOffscreenTargets();
        const off = self.off_res orelse return error.D3D12Failure;
        const dl = self.download.res orelse return error.D3D12Failure;
        self.waitFence(self.frame_fence_value);
        try check(self.cmd_alloc.Reset(), "reset frame allocator");
        try check(self.cmd.Reset(self.cmd_alloc, null), "reset frame command list");
        const cmd = self.cmd;

        if (self.msaa_res) |ms| {
            self.recordDraws(cmd, self.rtvHandle(RTV_MSAA), u);
            barrier(cmd, ms, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            barrier(cmd, off, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST);
            cmd.ResolveSubresource(off, 0, ms, 0, COLOR_FORMAT);
            barrier(cmd, ms, d3d.D3D12_RESOURCE_STATE_RESOLVE_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
            barrier(cmd, off, d3d.D3D12_RESOURCE_STATE_RESOLVE_DEST, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        } else {
            self.recordDraws(cmd, self.rtvHandle(RTV_OFFSCREEN), u);
            barrier(cmd, off, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE);
        }
        const dst_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = dl,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT,
            .u = .{ .PlacedFootprint = .{ .Footprint = .{
                .Format = COLOR_FORMAT,
                .Width = self.width,
                .Height = self.height,
                .RowPitch = self.download_pitch,
            } } },
        };
        const src_loc = d3d.D3D12_TEXTURE_COPY_LOCATION{
            .pResource = off,
            .Type = d3d.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,
            .u = .{ .SubresourceIndex = 0 },
        };
        cmd.CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, null);
        barrier(cmd, off, d3d.D3D12_RESOURCE_STATE_COPY_SOURCE, d3d.D3D12_RESOURCE_STATE_RENDER_TARGET);
        try check(cmd.Close(), "close frame command list");
        const lists = [_]*d3d.ID3D12GraphicsCommandList{cmd};
        self.queue.ExecuteCommandLists(1, &lists);
        self.waitForGpu();

        // Rows landed on a 256 B boundary in the readback buffer; the caller
        // wants them packed.
        const row = self.width * 4;
        const outb = try alloc.alloc(u8, @as(usize, row) * self.height);
        errdefer alloc.free(outb);
        var p: ?*anyopaque = null;
        const read = d3d.D3D12_RANGE{ .Begin = 0, .End = @as(usize, self.download_pitch) * self.height };
        try check(dl.Map(0, &read, &p), "map readback");
        const src: [*]const u8 = @ptrCast(p.?);
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            @memcpy(outb[y * row ..][0..row], src[y * self.download_pitch ..][0..row]);
        }
        const wrote_nothing = d3d.D3D12_RANGE{ .Begin = 0, .End = 0 };
        dl.Unmap(0, &wrote_nothing);
        return outb;
    }

    pub fn savePng(self: *Gpu, alloc: std.mem.Allocator, path: []const u8, u: Uniforms) !void {
        const pixels = try self.renderOffscreen(alloc, u);
        defer alloc.free(pixels);
        try png.write(alloc, path, pixels, self.width, self.height);
    }

    pub fn deinit(self: *Gpu) void {
        self.waitForGpu();
        self.clearOverlay();
        self.freeScene();
        if (self.sprite_tex) |*t| self.destroyTexture(t);
        if (self.glyph_tex) |*t| self.destroyTexture(t);
        if (self.glyph_bold_tex) |*t| self.destroyTexture(t);
        if (self.glyph_italic_tex) |*t| self.destroyTexture(t);
        self.releaseOffscreen();
        self.releaseBackBuffers();
        self.releaseDepth();
        self.releaseMsaa();
        self.destroyBuffer(&self.ring);
        if (self.swapchain) |sc| _ = sc.Release();
        self.swapchain = null;
        self.releasePipelines();
        _ = self.root_sig.Release();
        _ = self.cmd.Release();
        _ = self.up_cmd.Release();
        _ = self.cmd_alloc.Release();
        _ = self.up_alloc.Release();
        _ = self.fence.Release();
        _ = d3d.CloseHandle(self.fence_event);
        _ = self.srv_heap.Release();
        _ = self.dsv_heap.Release();
        _ = self.rtv_heap.Release();
        _ = self.queue.Release();
        _ = self.device.Release();
        _ = self.factory.Release();
    }
};

test "the uniform ring slot holds a whole block" {
    try std.testing.expect(UNIFORM_STRIDE >= @sizeOf(Uniforms));
    try std.testing.expectEqual(@as(u32, 0), RING_BYTES % UNIFORM_STRIDE);
}

test "the vertex layouts match the scene contract" {
    // The input elements are declared by hand against scene/types.zig, and a
    // drifted offset shades wrong rather than failing.
    try std.testing.expectEqual(@as(u32, @offsetOf(scene.Vertex, "depth")), tri_elems[4].AlignedByteOffset);
    try std.testing.expectEqual(@as(u32, @offsetOf(scene.Quad, "depth")), quad_elems[6].AlignedByteOffset);
    try std.testing.expectEqual(@as(u32, @offsetOf(scene.Quad, "flags")), quad_elems[5].AlignedByteOffset);
    try std.testing.expectEqual(@as(usize, 5), pattern_elems.len);
    try std.testing.expectEqual(@as(u32, 8), overlay_elems[1].AlignedByteOffset);
}

test "an unsupported native kind does not open a device" {
    var w = Win32Window{ .hinstance = null, .hwnd = null };
    const opts = Options{ .width = 16, .height = 16, .native_handle = &w, .native_kind = .x11_window };
    try std.testing.expect(opts.wantWindow());
    if (Gpu.init(opts)) |g| {
        var open = g;
        open.deinit();
        return error.TestUnexpectedResult;
    } else |e| {
        // A machine with no D3D12 runtime fails earlier; both are a refusal.
        try std.testing.expect(e == error.Unsupported or e == error.D3D12Failure);
    }
}

// The swapchain path needs a real HWND, so it gets one. This covers what the
// offscreen tests cannot: CreateSwapChainForHwnd, the back-buffer barriers,
// Present, and the rebuild a resize forces. Skips on a machine that will not
// give out a window or a device.
test "a window gets a swapchain, presents, and survives a resize" {
    const user32 = struct {
        const WndClassExA = extern struct {
            cbSize: u32,
            style: u32,
            lpfnWndProc: *const fn (d3d.HWND, u32, usize, isize) callconv(.winapi) isize,
            cbClsExtra: i32,
            cbWndExtra: i32,
            hInstance: ?*anyopaque,
            hIcon: ?*anyopaque,
            hCursor: ?*anyopaque,
            hbrBackground: ?*anyopaque,
            lpszMenuName: ?[*:0]const u8,
            lpszClassName: [*:0]const u8,
            hIconSm: ?*anyopaque,
        };
        extern "user32" fn RegisterClassExA(*const WndClassExA) callconv(.winapi) u16;
        extern "user32" fn DefWindowProcA(d3d.HWND, u32, usize, isize) callconv(.winapi) isize;
        extern "user32" fn CreateWindowExA(u32, [*:0]const u8, [*:0]const u8, u32, i32, i32, i32, i32, ?d3d.HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?d3d.HWND;
        extern "user32" fn DestroyWindow(d3d.HWND) callconv(.winapi) d3d.BOOL;
        extern "kernel32" fn GetModuleHandleA(?[*:0]const u8) callconv(.winapi) ?*anyopaque;
        const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
    };

    const hinstance = user32.GetModuleHandleA(null);
    const cls = user32.WndClassExA{
        .cbSize = @sizeOf(user32.WndClassExA),
        .style = 0,
        .lpfnWndProc = &user32.DefWindowProcA,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = "charttable_d3d12_test",
        .hIconSm = null,
    };
    if (user32.RegisterClassExA(&cls) == 0) return error.SkipZigTest;
    const hwnd = user32.CreateWindowExA(
        0,
        "charttable_d3d12_test",
        "charttable",
        user32.WS_OVERLAPPEDWINDOW,
        0,
        0,
        320,
        240,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.SkipZigTest;
    defer _ = user32.DestroyWindow(hwnd);

    var win = Win32Window{ .hinstance = hinstance, .hwnd = hwnd };
    var g = Gpu.init(.{
        .width = 320,
        .height = 240,
        .native_handle = &win,
        .native_kind = .win32_hwnd,
    }) catch return error.SkipZigTest;
    defer g.deinit();

    try std.testing.expect(g.swapchain != null);
    try std.testing.expect(g.sc_count >= 2);
    try std.testing.expectEqual(@as(u32, 320), g.width);
    try std.testing.expectEqual(@as(u32, 240), g.height);

    // No scene: the frame is a clear and a present, which is the whole
    // acquire/barrier/resolve/present path all the same.
    var u = std.mem.zeroes(Uniforms);
    u.mvp = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    u.zoom_t = 0;
    u.rot_cos = 1;
    try std.testing.expect(g.renderWindow(u));
    try std.testing.expect(g.renderWindow(u));

    // A resize in POINTS at density 1 is a resize in pixels, and the back
    // buffers have to come back at the new size.
    g.resize(200, 150);
    try std.testing.expectEqual(@as(u32, 200), g.width);
    try std.testing.expectEqual(@as(u32, 150), g.height);
    try std.testing.expect(g.sc_count >= 2);
    try std.testing.expect(g.renderWindow(u));
}

comptime {
    if (builtin.os.tag != .windows) @compileError("gpu_d3d12.zig is a Windows backend");
}
