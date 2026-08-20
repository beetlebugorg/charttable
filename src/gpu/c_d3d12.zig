//! Direct3D 12 and DXGI: the COM vtables, structs and enum values gpu_d3d12.zig
//! uses, declared here rather than taken from a header. The Windows SDK's
//! d3d12.h is C++-first and its C path (`CINTERFACE`) needs an SDK installed
//! on the build machine; declaring the ABI keeps the build self-contained.
//!
//! d3d12.dll, dxgi.dll and d3dcompiler_47.dll are loaded at open through
//! LoadLibrary/GetProcAddress (Api.load), not linked. A machine without the
//! D3D12 runtime fails with a name at open, and the build needs no import
//! libraries for either the MSVC or the MinGW ABI.
//!
//! Two ABI rules a wrong declaration breaks silently:
//!
//!  1. Every vtable slot is declared, in order, including the uncalled ones —
//!     an omitted slot shifts every later method. Uncalled slots are typed
//!     `*const anyopaque`, so calling one does not compile.
//!  2. `GetCPUDescriptorHandleForHeapStart` and its GPU twin return a one-field
//!     struct by value, and the shipped runtime returns it through a HIDDEN
//!     POINTER: `this` in the first argument slot, the address to write in the
//!     second. Declared as returning the value in a register instead, the
//!     runtime writes eight bytes through whatever the second slot happened to
//!     hold — measured landing in this binary's own code section. Both are
//!     declared here with the out pointer explicit.

const std = @import("std");

pub const HRESULT = i32;
pub const HMODULE = *anyopaque;
pub const HANDLE = *anyopaque;
pub const HWND = *anyopaque;
pub const BOOL = i32;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const S_OK: HRESULT = 0;

pub inline fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

/// `{aaaaaaaa-bbbb-cccc-dd dd-dddddddddddd}` in the order the registry prints
/// it, so a GUID here can be eyeballed against the SDK header.
fn guid(a: u32, b: u16, c: u16, d: [8]u8) GUID {
    return .{ .a = a, .b = b, .c = c, .d = d };
}

pub const IID_IDXGIFactory4 = guid(0x1bc6ea02, 0xef36, 0x464f, .{ 0xbf, 0x0c, 0x21, 0xca, 0x39, 0xe5, 0x16, 0x8a });
pub const IID_IDXGISwapChain3 = guid(0x94d99bdb, 0xf1f8, 0x4ab0, .{ 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1 });
pub const IID_ID3D12Device = guid(0x189819f1, 0x1db6, 0x4b57, .{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 });
pub const IID_ID3D12CommandQueue = guid(0x0ec870a6, 0x5d7e, 0x4c22, .{ 0x8c, 0xfc, 0x5b, 0xaa, 0xe0, 0x76, 0x16, 0xed });
pub const IID_ID3D12CommandAllocator = guid(0x6102dee4, 0xaf59, 0x4b09, .{ 0xb9, 0x99, 0xb4, 0x4d, 0x73, 0xf0, 0x9b, 0x24 });
pub const IID_ID3D12GraphicsCommandList = guid(0x5b160d0f, 0xac1b, 0x4185, .{ 0x8b, 0xa8, 0xb3, 0xae, 0x42, 0xa5, 0xa4, 0x55 });
pub const IID_ID3D12Resource = guid(0x696442be, 0xa72e, 0x4059, .{ 0xbc, 0x79, 0x5b, 0x5c, 0x98, 0x04, 0x0f, 0xad });
pub const IID_ID3D12DescriptorHeap = guid(0x8efb471d, 0x616c, 0x4f49, .{ 0x90, 0xf7, 0x12, 0x7b, 0xb7, 0x63, 0xfa, 0x51 });
pub const IID_ID3D12Fence = guid(0x0a753dcf, 0xc4d8, 0x4b91, .{ 0xad, 0xf6, 0xbe, 0x5a, 0x60, 0xd9, 0x5a, 0x76 });
pub const IID_ID3D12RootSignature = guid(0xc54a6b66, 0x72df, 0x4ee8, .{ 0x8b, 0xe5, 0xa9, 0x46, 0xa1, 0x42, 0x92, 0x14 });
pub const IID_ID3D12PipelineState = guid(0x765a30f3, 0xf624, 0x4c6f, .{ 0xa8, 0x28, 0xac, 0xe9, 0x48, 0x62, 0x24, 0x45 });
pub const IID_ID3D12Debug = guid(0x344488b7, 0x6846, 0x474b, .{ 0xb9, 0x89, 0xf0, 0x27, 0x44, 0x82, 0x45, 0xe0 });

// ---- kernel32 ---------------------------------------------------------------
pub extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(mod: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn CreateEventA(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u8) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub const INFINITE: u32 = 0xFFFF_FFFF;

// ---- DXGI enums / structs ---------------------------------------------------
pub const DXGI_FORMAT_UNKNOWN: u32 = 0;
pub const DXGI_FORMAT_R32G32B32A32_FLOAT: u32 = 2;
pub const DXGI_FORMAT_R32G32_FLOAT: u32 = 16;
pub const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: u32 = 29;
pub const DXGI_FORMAT_D32_FLOAT: u32 = 40;
pub const DXGI_FORMAT_R32_FLOAT: u32 = 41;
pub const DXGI_FORMAT_R32_UINT: u32 = 42;
pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: u32 = 91;

pub const DXGI_USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;
pub const DXGI_SCALING_STRETCH: u32 = 0;
pub const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;
pub const DXGI_ALPHA_MODE_PREMULTIPLIED: u32 = 2;
pub const DXGI_ALPHA_MODE_IGNORE: u32 = 3;
pub const DXGI_CREATE_FACTORY_DEBUG: u32 = 1;
pub const DXGI_MWA_NO_ALT_ENTER: u32 = 2;
pub const DXGI_ADAPTER_FLAG_SOFTWARE: u32 = 2;
pub const DXGI_ERROR_DEVICE_REMOVED: HRESULT = @bitCast(@as(u32, 0x887A0005));
pub const DXGI_ERROR_DEVICE_RESET: HRESULT = @bitCast(@as(u32, 0x887A0007));

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const DXGI_SWAP_CHAIN_DESC1 = extern struct {
    Width: u32 = 0,
    Height: u32 = 0,
    Format: u32 = DXGI_FORMAT_R8G8B8A8_UNORM,
    Stereo: BOOL = FALSE,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    BufferUsage: u32 = DXGI_USAGE_RENDER_TARGET_OUTPUT,
    BufferCount: u32 = 2,
    Scaling: u32 = DXGI_SCALING_STRETCH,
    SwapEffect: u32 = DXGI_SWAP_EFFECT_FLIP_DISCARD,
    AlphaMode: u32 = DXGI_ALPHA_MODE_IGNORE,
    Flags: u32 = 0,
};

pub const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: extern struct { LowPart: u32, HighPart: i32 },
    Flags: u32,
};

// ---- D3D12 enums ------------------------------------------------------------
pub const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;
pub const D3D_ROOT_SIGNATURE_VERSION_1: u32 = 1;
pub const D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST: u32 = 4;

pub const D3D12_COMMAND_LIST_TYPE_DIRECT: u32 = 0;

pub const D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV: u32 = 0;
pub const D3D12_DESCRIPTOR_HEAP_TYPE_RTV: u32 = 2;
pub const D3D12_DESCRIPTOR_HEAP_TYPE_DSV: u32 = 3;
pub const D3D12_DESCRIPTOR_HEAP_FLAG_NONE: u32 = 0;
pub const D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE: u32 = 1;

pub const D3D12_HEAP_TYPE_DEFAULT: u32 = 1;
pub const D3D12_HEAP_TYPE_UPLOAD: u32 = 2;
pub const D3D12_HEAP_TYPE_READBACK: u32 = 3;
pub const D3D12_HEAP_FLAG_NONE: u32 = 0;
pub const D3D12_CPU_PAGE_PROPERTY_UNKNOWN: u32 = 0;
pub const D3D12_MEMORY_POOL_UNKNOWN: u32 = 0;

pub const D3D12_RESOURCE_DIMENSION_BUFFER: u32 = 1;
pub const D3D12_RESOURCE_DIMENSION_TEXTURE2D: u32 = 3;
pub const D3D12_TEXTURE_LAYOUT_UNKNOWN: u32 = 0;
pub const D3D12_TEXTURE_LAYOUT_ROW_MAJOR: u32 = 1;
pub const D3D12_RESOURCE_FLAG_NONE: u32 = 0;
pub const D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET: u32 = 1;
pub const D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL: u32 = 2;

pub const D3D12_RESOURCE_STATE_COMMON: u32 = 0;
pub const D3D12_RESOURCE_STATE_PRESENT: u32 = 0;
pub const D3D12_RESOURCE_STATE_RENDER_TARGET: u32 = 0x4;
pub const D3D12_RESOURCE_STATE_DEPTH_WRITE: u32 = 0x10;
pub const D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE: u32 = 0x80;
pub const D3D12_RESOURCE_STATE_COPY_DEST: u32 = 0x400;
pub const D3D12_RESOURCE_STATE_COPY_SOURCE: u32 = 0x800;
pub const D3D12_RESOURCE_STATE_RESOLVE_DEST: u32 = 0x1000;
pub const D3D12_RESOURCE_STATE_RESOLVE_SOURCE: u32 = 0x2000;
pub const D3D12_RESOURCE_STATE_GENERIC_READ: u32 = 0xAC3;

pub const D3D12_RESOURCE_BARRIER_TYPE_TRANSITION: u32 = 0;
pub const D3D12_RESOURCE_BARRIER_FLAG_NONE: u32 = 0;
pub const D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES: u32 = 0xFFFF_FFFF;

pub const D3D12_FILL_MODE_SOLID: u32 = 3;
pub const D3D12_CULL_MODE_NONE: u32 = 1;
pub const D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF: u32 = 0;

pub const D3D12_COMPARISON_FUNC_LESS: u32 = 2;
pub const D3D12_COMPARISON_FUNC_ALWAYS: u32 = 8;
pub const D3D12_DEPTH_WRITE_MASK_ZERO: u32 = 0;
pub const D3D12_DEPTH_WRITE_MASK_ALL: u32 = 1;
pub const D3D12_STENCIL_OP_KEEP: u32 = 1;

pub const D3D12_BLEND_ZERO: u32 = 1;
pub const D3D12_BLEND_ONE: u32 = 2;
pub const D3D12_BLEND_SRC_ALPHA: u32 = 5;
pub const D3D12_BLEND_INV_SRC_ALPHA: u32 = 6;
pub const D3D12_BLEND_OP_ADD: u32 = 1;
pub const D3D12_LOGIC_OP_NOOP: u32 = 5;
pub const D3D12_COLOR_WRITE_ENABLE_ALL: u8 = 15;

pub const D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA: u32 = 0;
pub const D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE: u32 = 3;
pub const D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED: u32 = 0;
pub const D3D12_PIPELINE_STATE_FLAG_NONE: u32 = 0;

pub const D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT: u32 = 1;
pub const D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE: u32 = 0;
pub const D3D12_ROOT_PARAMETER_TYPE_CBV: u32 = 2;
pub const D3D12_DESCRIPTOR_RANGE_TYPE_SRV: u32 = 0;
pub const D3D12_SHADER_VISIBILITY_ALL: u32 = 0;
pub const D3D12_SHADER_VISIBILITY_VERTEX: u32 = 1;
pub const D3D12_SHADER_VISIBILITY_PIXEL: u32 = 5;

pub const D3D12_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
pub const D3D12_TEXTURE_ADDRESS_MODE_CLAMP: u32 = 3;
pub const D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK: u32 = 0;

pub const D3D12_SRV_DIMENSION_TEXTURE2D: u32 = 4;
/// D3D12_ENCODE_SHADER_4_COMPONENT_MAPPING(0,1,2,3) — the identity swizzle.
pub const D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING: u32 = 0x1688;

pub const D3D12_CLEAR_FLAG_DEPTH: u32 = 1;
pub const D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX: u32 = 0;
pub const D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT: u32 = 1;

pub const D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS: u32 = 4;

/// A texture row inside a buffer starts on a 256-byte boundary, and the
/// buffer's own placement on 512. Both the sprite upload and the snapshot
/// readback pad their rows to the first of these.
pub const D3D12_TEXTURE_DATA_PITCH_ALIGNMENT: u32 = 256;
/// A root CBV's address must be 256-byte aligned, which is also the uniform
/// ring's stride.
pub const D3D12_CONSTANT_BUFFER_DATA_PLACEMENT_ALIGNMENT: u32 = 256;

pub const D3DCOMPILE_OPTIMIZATION_LEVEL3: u32 = 1 << 15;

// ---- D3D12 structs ----------------------------------------------------------
pub const D3D12_COMMAND_QUEUE_DESC = extern struct {
    Type: u32 = D3D12_COMMAND_LIST_TYPE_DIRECT,
    Priority: i32 = 0,
    Flags: u32 = 0,
    NodeMask: u32 = 0,
};

pub const D3D12_DESCRIPTOR_HEAP_DESC = extern struct {
    Type: u32,
    NumDescriptors: u32,
    Flags: u32 = D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
    NodeMask: u32 = 0,
};

pub const D3D12_HEAP_PROPERTIES = extern struct {
    Type: u32,
    CPUPageProperty: u32 = D3D12_CPU_PAGE_PROPERTY_UNKNOWN,
    MemoryPoolPreference: u32 = D3D12_MEMORY_POOL_UNKNOWN,
    CreationNodeMask: u32 = 1,
    VisibleNodeMask: u32 = 1,
};

pub const D3D12_RESOURCE_DESC = extern struct {
    Dimension: u32,
    Alignment: u64 = 0,
    Width: u64,
    Height: u32 = 1,
    DepthOrArraySize: u16 = 1,
    MipLevels: u16 = 1,
    Format: u32 = DXGI_FORMAT_UNKNOWN,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    Layout: u32 = D3D12_TEXTURE_LAYOUT_UNKNOWN,
    Flags: u32 = D3D12_RESOURCE_FLAG_NONE,
};

pub const D3D12_DEPTH_STENCIL_VALUE = extern struct { Depth: f32, Stencil: u8 };
pub const D3D12_CLEAR_VALUE = extern struct {
    Format: u32,
    u: extern union {
        Color: [4]f32,
        DepthStencil: D3D12_DEPTH_STENCIL_VALUE,
    },
};

pub const D3D12_RANGE = extern struct { Begin: usize, End: usize };

pub const D3D12_RESOURCE_TRANSITION_BARRIER = extern struct {
    pResource: ?*ID3D12Resource,
    Subresource: u32,
    StateBefore: u32,
    StateAfter: u32,
};
pub const D3D12_RESOURCE_BARRIER = extern struct {
    Type: u32 = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,
    Flags: u32 = D3D12_RESOURCE_BARRIER_FLAG_NONE,
    u: extern union {
        Transition: D3D12_RESOURCE_TRANSITION_BARRIER,
    },
};

pub const D3D12_VIEWPORT = extern struct {
    TopLeftX: f32,
    TopLeftY: f32,
    Width: f32,
    Height: f32,
    MinDepth: f32 = 0,
    MaxDepth: f32 = 1,
};
pub const D3D12_RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const D3D12_BOX = extern struct {
    left: u32,
    top: u32,
    front: u32,
    right: u32,
    bottom: u32,
    back: u32,
};

pub const D3D12_VERTEX_BUFFER_VIEW = extern struct {
    BufferLocation: u64,
    SizeInBytes: u32,
    StrideInBytes: u32,
};
pub const D3D12_INDEX_BUFFER_VIEW = extern struct {
    BufferLocation: u64,
    SizeInBytes: u32,
    Format: u32,
};

pub const D3D12_INPUT_ELEMENT_DESC = extern struct {
    SemanticName: [*:0]const u8,
    SemanticIndex: u32,
    Format: u32,
    InputSlot: u32,
    AlignedByteOffset: u32,
    InputSlotClass: u32 = D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,
    InstanceDataStepRate: u32 = 0,
};
pub const D3D12_INPUT_LAYOUT_DESC = extern struct {
    pInputElementDescs: ?[*]const D3D12_INPUT_ELEMENT_DESC = null,
    NumElements: u32 = 0,
};

pub const D3D12_SHADER_BYTECODE = extern struct {
    pShaderBytecode: ?*const anyopaque = null,
    BytecodeLength: usize = 0,
};

pub const D3D12_SO_DECLARATION_ENTRY = extern struct {
    Stream: u32,
    SemanticName: ?[*:0]const u8,
    SemanticIndex: u32,
    StartComponent: u8,
    ComponentCount: u8,
    OutputSlot: u8,
};
pub const D3D12_STREAM_OUTPUT_DESC = extern struct {
    pSODeclaration: ?[*]const D3D12_SO_DECLARATION_ENTRY = null,
    NumEntries: u32 = 0,
    pBufferStrides: ?[*]const u32 = null,
    NumStrides: u32 = 0,
    RasterizedStream: u32 = 0,
};

pub const D3D12_RENDER_TARGET_BLEND_DESC = extern struct {
    BlendEnable: BOOL = FALSE,
    LogicOpEnable: BOOL = FALSE,
    SrcBlend: u32 = D3D12_BLEND_ONE,
    DestBlend: u32 = D3D12_BLEND_ZERO,
    BlendOp: u32 = D3D12_BLEND_OP_ADD,
    SrcBlendAlpha: u32 = D3D12_BLEND_ONE,
    DestBlendAlpha: u32 = D3D12_BLEND_ZERO,
    BlendOpAlpha: u32 = D3D12_BLEND_OP_ADD,
    LogicOp: u32 = D3D12_LOGIC_OP_NOOP,
    RenderTargetWriteMask: u8 = D3D12_COLOR_WRITE_ENABLE_ALL,
};
pub const D3D12_BLEND_DESC = extern struct {
    AlphaToCoverageEnable: BOOL = FALSE,
    IndependentBlendEnable: BOOL = FALSE,
    RenderTarget: [8]D3D12_RENDER_TARGET_BLEND_DESC = @splat(.{}),
};

pub const D3D12_RASTERIZER_DESC = extern struct {
    FillMode: u32 = D3D12_FILL_MODE_SOLID,
    CullMode: u32 = D3D12_CULL_MODE_NONE,
    FrontCounterClockwise: BOOL = FALSE,
    DepthBias: i32 = 0,
    DepthBiasClamp: f32 = 0,
    SlopeScaledDepthBias: f32 = 0,
    DepthClipEnable: BOOL = TRUE,
    MultisampleEnable: BOOL = FALSE,
    AntialiasedLineEnable: BOOL = FALSE,
    ForcedSampleCount: u32 = 0,
    ConservativeRaster: u32 = D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF,
};

pub const D3D12_DEPTH_STENCILOP_DESC = extern struct {
    StencilFailOp: u32 = D3D12_STENCIL_OP_KEEP,
    StencilDepthFailOp: u32 = D3D12_STENCIL_OP_KEEP,
    StencilPassOp: u32 = D3D12_STENCIL_OP_KEEP,
    StencilFunc: u32 = D3D12_COMPARISON_FUNC_ALWAYS,
};
pub const D3D12_DEPTH_STENCIL_DESC = extern struct {
    DepthEnable: BOOL = TRUE,
    DepthWriteMask: u32 = D3D12_DEPTH_WRITE_MASK_ALL,
    DepthFunc: u32 = D3D12_COMPARISON_FUNC_LESS,
    StencilEnable: BOOL = FALSE,
    StencilReadMask: u8 = 0xFF,
    StencilWriteMask: u8 = 0xFF,
    FrontFace: D3D12_DEPTH_STENCILOP_DESC = .{},
    BackFace: D3D12_DEPTH_STENCILOP_DESC = .{},
};

pub const D3D12_CACHED_PIPELINE_STATE = extern struct {
    pCachedBlob: ?*const anyopaque = null,
    CachedBlobSizeInBytes: usize = 0,
};

pub const D3D12_GRAPHICS_PIPELINE_STATE_DESC = extern struct {
    pRootSignature: ?*ID3D12RootSignature = null,
    VS: D3D12_SHADER_BYTECODE = .{},
    PS: D3D12_SHADER_BYTECODE = .{},
    DS: D3D12_SHADER_BYTECODE = .{},
    HS: D3D12_SHADER_BYTECODE = .{},
    GS: D3D12_SHADER_BYTECODE = .{},
    StreamOutput: D3D12_STREAM_OUTPUT_DESC = .{},
    BlendState: D3D12_BLEND_DESC = .{},
    SampleMask: u32 = 0xFFFF_FFFF,
    RasterizerState: D3D12_RASTERIZER_DESC = .{},
    DepthStencilState: D3D12_DEPTH_STENCIL_DESC = .{},
    InputLayout: D3D12_INPUT_LAYOUT_DESC = .{},
    IBStripCutValue: u32 = D3D12_INDEX_BUFFER_STRIP_CUT_VALUE_DISABLED,
    PrimitiveTopologyType: u32 = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE,
    NumRenderTargets: u32 = 1,
    RTVFormats: [8]u32 = @splat(DXGI_FORMAT_UNKNOWN),
    DSVFormat: u32 = DXGI_FORMAT_UNKNOWN,
    SampleDesc: DXGI_SAMPLE_DESC = .{},
    NodeMask: u32 = 0,
    CachedPSO: D3D12_CACHED_PIPELINE_STATE = .{},
    Flags: u32 = D3D12_PIPELINE_STATE_FLAG_NONE,
};

pub const D3D12_DESCRIPTOR_RANGE = extern struct {
    RangeType: u32,
    NumDescriptors: u32,
    BaseShaderRegister: u32,
    RegisterSpace: u32 = 0,
    OffsetInDescriptorsFromTableStart: u32 = 0,
};
pub const D3D12_ROOT_DESCRIPTOR_TABLE = extern struct {
    NumDescriptorRanges: u32,
    pDescriptorRanges: [*]const D3D12_DESCRIPTOR_RANGE,
};
pub const D3D12_ROOT_CONSTANTS = extern struct {
    ShaderRegister: u32,
    RegisterSpace: u32,
    Num32BitValues: u32,
};
pub const D3D12_ROOT_DESCRIPTOR = extern struct {
    ShaderRegister: u32,
    RegisterSpace: u32 = 0,
};
pub const D3D12_ROOT_PARAMETER = extern struct {
    ParameterType: u32,
    u: extern union {
        DescriptorTable: D3D12_ROOT_DESCRIPTOR_TABLE,
        Constants: D3D12_ROOT_CONSTANTS,
        Descriptor: D3D12_ROOT_DESCRIPTOR,
    },
    ShaderVisibility: u32,
};
pub const D3D12_STATIC_SAMPLER_DESC = extern struct {
    Filter: u32,
    AddressU: u32,
    AddressV: u32,
    AddressW: u32,
    MipLODBias: f32 = 0,
    MaxAnisotropy: u32 = 0,
    ComparisonFunc: u32 = D3D12_COMPARISON_FUNC_ALWAYS,
    BorderColor: u32 = D3D12_STATIC_BORDER_COLOR_TRANSPARENT_BLACK,
    MinLOD: f32 = 0,
    MaxLOD: f32 = 3.402823466e38,
    ShaderRegister: u32,
    RegisterSpace: u32 = 0,
    ShaderVisibility: u32,
};
pub const D3D12_ROOT_SIGNATURE_DESC = extern struct {
    NumParameters: u32 = 0,
    pParameters: ?[*]const D3D12_ROOT_PARAMETER = null,
    NumStaticSamplers: u32 = 0,
    pStaticSamplers: ?[*]const D3D12_STATIC_SAMPLER_DESC = null,
    Flags: u32 = 0,
};

pub const D3D12_TEX2D_SRV = extern struct {
    MostDetailedMip: u32 = 0,
    MipLevels: u32 = 1,
    PlaneSlice: u32 = 0,
    ResourceMinLODClamp: f32 = 0,
};
pub const D3D12_BUFFER_SRV = extern struct {
    FirstElement: u64,
    NumElements: u32,
    StructureByteStride: u32,
    Flags: u32,
};
pub const D3D12_SHADER_RESOURCE_VIEW_DESC = extern struct {
    Format: u32,
    ViewDimension: u32,
    Shader4ComponentMapping: u32 = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
    u: extern union {
        // Buffer is the widest member (its FirstElement is 64-bit), so it sets
        // the union's size and alignment even though we only ever write
        // Texture2D.
        Buffer: D3D12_BUFFER_SRV,
        Texture2D: D3D12_TEX2D_SRV,
    },
};

pub const D3D12_SUBRESOURCE_FOOTPRINT = extern struct {
    Format: u32,
    Width: u32,
    Height: u32,
    Depth: u32 = 1,
    RowPitch: u32,
};
pub const D3D12_PLACED_SUBRESOURCE_FOOTPRINT = extern struct {
    Offset: u64 = 0,
    Footprint: D3D12_SUBRESOURCE_FOOTPRINT,
};
pub const D3D12_TEXTURE_COPY_LOCATION = extern struct {
    pResource: ?*ID3D12Resource,
    Type: u32,
    u: extern union {
        PlacedFootprint: D3D12_PLACED_SUBRESOURCE_FOOTPRINT,
        SubresourceIndex: u32,
    },
};

pub const D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS = extern struct {
    Format: u32,
    SampleCount: u32,
    Flags: u32 = 0,
    NumQualityLevels: u32 = 0,
};

// ---- COM interfaces ---------------------------------------------------------
//
// Layout rule: every struct here is `{ v: *const VTable }`, and each VTable
// repeats its bases' slots in order before adding its own. `This` is typed
// `*anyopaque` throughout so the vtables need no forward declarations.

const Unused = *const anyopaque;

/// The three IUnknown slots every vtable opens with.
const UnknownSlots = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

pub const IUnknown = extern struct {
    v: *const VTable,
    pub const VTable = UnknownSlots;
    pub inline fn Release(self: *IUnknown) u32 {
        return self.v.Release(self);
    }
};

pub const ID3DBlob = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        GetBufferPointer: *const fn (*anyopaque) callconv(.winapi) ?[*]u8,
        GetBufferSize: *const fn (*anyopaque) callconv(.winapi) usize,
    };
    pub inline fn Release(self: *ID3DBlob) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn bytes(self: *ID3DBlob) []const u8 {
        const p = self.v.GetBufferPointer(self) orelse return &.{};
        return p[0..self.v.GetBufferSize(self)];
    }
};

pub const IDXGIAdapter1 = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        // IDXGIObject
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        // IDXGIAdapter
        EnumOutputs: Unused,
        GetDesc: Unused,
        CheckInterfaceSupport: Unused,
        // IDXGIAdapter1
        GetDesc1: *const fn (*anyopaque, *DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT,
    };
    pub inline fn Release(self: *IDXGIAdapter1) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn GetDesc1(self: *IDXGIAdapter1, d: *DXGI_ADAPTER_DESC1) HRESULT {
        return self.v.GetDesc1(self, d);
    }
};

pub const IDXGIFactory4 = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        // IDXGIObject
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        // IDXGIFactory
        EnumAdapters: Unused,
        MakeWindowAssociation: *const fn (*anyopaque, HWND, u32) callconv(.winapi) HRESULT,
        GetWindowAssociation: Unused,
        CreateSwapChain: Unused,
        CreateSoftwareAdapter: Unused,
        // IDXGIFactory1
        EnumAdapters1: *const fn (*anyopaque, u32, *?*IDXGIAdapter1) callconv(.winapi) HRESULT,
        IsCurrent: Unused,
        // IDXGIFactory2
        IsWindowedStereoEnabled: Unused,
        CreateSwapChainForHwnd: *const fn (
            *anyopaque,
            *anyopaque, // the command queue, as IUnknown*
            HWND,
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*const anyopaque, // pFullscreenDesc
            ?*anyopaque, // pRestrictToOutput
            *?*IDXGISwapChain3,
        ) callconv(.winapi) HRESULT,
        CreateSwapChainForCoreWindow: Unused,
        GetSharedResourceAdapterLuid: Unused,
        RegisterStereoStatusWindow: Unused,
        RegisterStereoStatusEvent: Unused,
        UnregisterStereoStatus: Unused,
        RegisterOcclusionStatusWindow: Unused,
        RegisterOcclusionStatusEvent: Unused,
        UnregisterOcclusionStatus: Unused,
        CreateSwapChainForComposition: *const fn (
            *anyopaque,
            *anyopaque, // the command queue, as IUnknown*
            *const DXGI_SWAP_CHAIN_DESC1,
            ?*anyopaque, // pRestrictToOutput
            *?*IDXGISwapChain3,
        ) callconv(.winapi) HRESULT,
        // IDXGIFactory3
        GetCreationFlags: Unused,
        // IDXGIFactory4
        EnumAdapterByLuid: Unused,
        EnumWarpAdapter: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    };
    pub inline fn Release(self: *IDXGIFactory4) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn EnumAdapters1(self: *IDXGIFactory4, i: u32, out: *?*IDXGIAdapter1) HRESULT {
        return self.v.EnumAdapters1(self, i, out);
    }
    pub inline fn MakeWindowAssociation(self: *IDXGIFactory4, hwnd: HWND, flags: u32) HRESULT {
        return self.v.MakeWindowAssociation(self, hwnd, flags);
    }
    pub inline fn CreateSwapChainForHwnd(
        self: *IDXGIFactory4,
        queue: *ID3D12CommandQueue,
        hwnd: HWND,
        desc: *const DXGI_SWAP_CHAIN_DESC1,
        out: *?*IDXGISwapChain3,
    ) HRESULT {
        return self.v.CreateSwapChainForHwnd(self, queue, hwnd, desc, null, null, out);
    }
    /// A swapchain with no window, for a host that composes it into its own
    /// visual tree (a XAML SwapChainPanel, a DirectComposition visual).
    pub inline fn CreateSwapChainForComposition(
        self: *IDXGIFactory4,
        queue: *ID3D12CommandQueue,
        desc: *const DXGI_SWAP_CHAIN_DESC1,
        out: *?*IDXGISwapChain3,
    ) HRESULT {
        return self.v.CreateSwapChainForComposition(self, queue, desc, null, out);
    }
};

pub const IDXGISwapChain3 = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        // IDXGIObject
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        GetPrivateData: Unused,
        GetParent: Unused,
        // IDXGIDeviceSubObject
        GetDevice: Unused,
        // IDXGISwapChain
        Present: *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: Unused,
        GetFullscreenState: Unused,
        GetDesc: Unused,
        ResizeBuffers: *const fn (*anyopaque, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT,
        ResizeTarget: Unused,
        GetContainingOutput: Unused,
        GetFrameStatistics: Unused,
        GetLastPresentCount: Unused,
        // IDXGISwapChain1
        GetDesc1: *const fn (*anyopaque, *DXGI_SWAP_CHAIN_DESC1) callconv(.winapi) HRESULT,
        GetFullscreenDesc: Unused,
        GetHwnd: Unused,
        GetCoreWindow: Unused,
        Present1: Unused,
        IsTemporaryMonoSupported: Unused,
        GetRestrictToOutput: Unused,
        SetBackgroundColor: Unused,
        GetBackgroundColor: Unused,
        SetRotation: Unused,
        GetRotation: Unused,
        // IDXGISwapChain2
        SetSourceSize: Unused,
        GetSourceSize: Unused,
        SetMaximumFrameLatency: Unused,
        GetMaximumFrameLatency: Unused,
        GetFrameLatencyWaitableObject: Unused,
        SetMatrixTransform: Unused,
        GetMatrixTransform: Unused,
        // IDXGISwapChain3
        GetCurrentBackBufferIndex: *const fn (*anyopaque) callconv(.winapi) u32,
        CheckColorSpaceSupport: Unused,
        SetColorSpace1: Unused,
        ResizeBuffers1: Unused,
    };
    pub inline fn Release(self: *IDXGISwapChain3) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn Present(self: *IDXGISwapChain3, sync_interval: u32, flags: u32) HRESULT {
        return self.v.Present(self, sync_interval, flags);
    }
    pub inline fn GetBuffer(self: *IDXGISwapChain3, i: u32, out: *?*ID3D12Resource) HRESULT {
        return self.v.GetBuffer(self, i, &IID_ID3D12Resource, @ptrCast(out));
    }
    pub inline fn ResizeBuffers(self: *IDXGISwapChain3, count: u32, w: u32, h: u32, fmt: u32, flags: u32) HRESULT {
        return self.v.ResizeBuffers(self, count, w, h, fmt, flags);
    }
    pub inline fn GetDesc1(self: *IDXGISwapChain3, d: *DXGI_SWAP_CHAIN_DESC1) HRESULT {
        return self.v.GetDesc1(self, d);
    }
    pub inline fn GetCurrentBackBufferIndex(self: *IDXGISwapChain3) u32 {
        return self.v.GetCurrentBackBufferIndex(self);
    }
};

pub const ID3D12Debug = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        EnableDebugLayer: *const fn (*anyopaque) callconv(.winapi) void,
    };
    pub inline fn Release(self: *ID3D12Debug) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn EnableDebugLayer(self: *ID3D12Debug) void {
        self.v.EnableDebugLayer(self);
    }
};

/// IUnknown + ID3D12Object + ID3D12DeviceChild, the eight slots every D3D12
/// object below ID3D12Device opens with.
const DeviceChildSlots = extern struct {
    base: UnknownSlots,
    GetPrivateData: Unused,
    SetPrivateData: Unused,
    SetPrivateDataInterface: Unused,
    SetName: Unused,
    GetDevice: Unused,
};

pub const ID3D12RootSignature = extern struct {
    v: *const VTable,
    pub const VTable = extern struct { base: DeviceChildSlots };
    pub inline fn Release(self: *ID3D12RootSignature) u32 {
        return self.v.base.base.Release(self);
    }
};

pub const ID3D12PipelineState = extern struct {
    v: *const VTable,
    pub const VTable = extern struct { base: DeviceChildSlots };
    pub inline fn Release(self: *ID3D12PipelineState) u32 {
        return self.v.base.base.Release(self);
    }
};

pub const ID3D12Resource = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        Map: *const fn (*anyopaque, u32, ?*const D3D12_RANGE, *?*anyopaque) callconv(.winapi) HRESULT,
        Unmap: *const fn (*anyopaque, u32, ?*const D3D12_RANGE) callconv(.winapi) void,
        GetDesc: Unused, // returns D3D12_RESOURCE_DESC by value (hidden sret)
        GetGPUVirtualAddress: *const fn (*anyopaque) callconv(.winapi) u64,
        WriteToSubresource: Unused,
        ReadFromSubresource: Unused,
        GetHeapProperties: Unused,
    };
    pub inline fn Release(self: *ID3D12Resource) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn Map(self: *ID3D12Resource, sub: u32, read: ?*const D3D12_RANGE, out: *?*anyopaque) HRESULT {
        return self.v.Map(self, sub, read, out);
    }
    pub inline fn Unmap(self: *ID3D12Resource, sub: u32, written: ?*const D3D12_RANGE) void {
        self.v.Unmap(self, sub, written);
    }
    pub inline fn GetGPUVirtualAddress(self: *ID3D12Resource) u64 {
        return self.v.GetGPUVirtualAddress(self);
    }
};

pub const ID3D12DescriptorHeap = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        GetDesc: Unused, // returns D3D12_DESCRIPTOR_HEAP_DESC by value
        // The hidden return pointer is the second argument; see the ABI note
        // at the top of this file.
        GetCPUDescriptorHandleForHeapStart: *const fn (*anyopaque, *usize) callconv(.winapi) usize,
        GetGPUDescriptorHandleForHeapStart: *const fn (*anyopaque, *u64) callconv(.winapi) u64,
    };
    pub inline fn Release(self: *ID3D12DescriptorHeap) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn cpuStart(self: *ID3D12DescriptorHeap) usize {
        var out: usize = 0;
        _ = self.v.GetCPUDescriptorHandleForHeapStart(self, &out);
        return out;
    }
    pub inline fn gpuStart(self: *ID3D12DescriptorHeap) u64 {
        var out: u64 = 0;
        _ = self.v.GetGPUDescriptorHandleForHeapStart(self, &out);
        return out;
    }
};

pub const ID3D12Fence = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        GetCompletedValue: *const fn (*anyopaque) callconv(.winapi) u64,
        SetEventOnCompletion: *const fn (*anyopaque, u64, HANDLE) callconv(.winapi) HRESULT,
        Signal: *const fn (*anyopaque, u64) callconv(.winapi) HRESULT,
    };
    pub inline fn Release(self: *ID3D12Fence) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn GetCompletedValue(self: *ID3D12Fence) u64 {
        return self.v.GetCompletedValue(self);
    }
    pub inline fn SetEventOnCompletion(self: *ID3D12Fence, value: u64, ev: HANDLE) HRESULT {
        return self.v.SetEventOnCompletion(self, value, ev);
    }
};

pub const ID3D12CommandAllocator = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        Reset: *const fn (*anyopaque) callconv(.winapi) HRESULT,
    };
    pub inline fn Release(self: *ID3D12CommandAllocator) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn Reset(self: *ID3D12CommandAllocator) HRESULT {
        return self.v.Reset(self);
    }
};

pub const ID3D12CommandQueue = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        UpdateTileMappings: Unused,
        CopyTileMappings: Unused,
        ExecuteCommandLists: *const fn (*anyopaque, u32, [*]const *ID3D12GraphicsCommandList) callconv(.winapi) void,
        SetMarker: Unused,
        BeginEvent: Unused,
        EndEvent: Unused,
        Signal: *const fn (*anyopaque, *ID3D12Fence, u64) callconv(.winapi) HRESULT,
        Wait: Unused,
        GetTimestampFrequency: Unused,
        GetClockCalibration: Unused,
        GetDesc: Unused, // returns D3D12_COMMAND_QUEUE_DESC by value
    };
    pub inline fn Release(self: *ID3D12CommandQueue) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn ExecuteCommandLists(self: *ID3D12CommandQueue, n: u32, lists: [*]const *ID3D12GraphicsCommandList) void {
        self.v.ExecuteCommandLists(self, n, lists);
    }
    pub inline fn Signal(self: *ID3D12CommandQueue, fence: *ID3D12Fence, value: u64) HRESULT {
        return self.v.Signal(self, fence, value);
    }
};

pub const ID3D12GraphicsCommandList = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: DeviceChildSlots,
        // ID3D12CommandList
        GetType: Unused,
        // ID3D12GraphicsCommandList
        Close: *const fn (*anyopaque) callconv(.winapi) HRESULT,
        Reset: *const fn (*anyopaque, *ID3D12CommandAllocator, ?*ID3D12PipelineState) callconv(.winapi) HRESULT,
        ClearState: Unused,
        DrawInstanced: *const fn (*anyopaque, u32, u32, u32, u32) callconv(.winapi) void,
        DrawIndexedInstanced: *const fn (*anyopaque, u32, u32, u32, i32, u32) callconv(.winapi) void,
        Dispatch: Unused,
        CopyBufferRegion: Unused,
        CopyTextureRegion: *const fn (
            *anyopaque,
            *const D3D12_TEXTURE_COPY_LOCATION,
            u32,
            u32,
            u32,
            *const D3D12_TEXTURE_COPY_LOCATION,
            ?*const D3D12_BOX,
        ) callconv(.winapi) void,
        CopyResource: Unused,
        CopyTiles: Unused,
        ResolveSubresource: *const fn (*anyopaque, *ID3D12Resource, u32, *ID3D12Resource, u32, u32) callconv(.winapi) void,
        IASetPrimitiveTopology: *const fn (*anyopaque, u32) callconv(.winapi) void,
        RSSetViewports: *const fn (*anyopaque, u32, [*]const D3D12_VIEWPORT) callconv(.winapi) void,
        RSSetScissorRects: *const fn (*anyopaque, u32, [*]const D3D12_RECT) callconv(.winapi) void,
        OMSetBlendFactor: Unused,
        OMSetStencilRef: Unused,
        SetPipelineState: *const fn (*anyopaque, *ID3D12PipelineState) callconv(.winapi) void,
        ResourceBarrier: *const fn (*anyopaque, u32, [*]const D3D12_RESOURCE_BARRIER) callconv(.winapi) void,
        ExecuteBundle: Unused,
        SetDescriptorHeaps: *const fn (*anyopaque, u32, [*]const *ID3D12DescriptorHeap) callconv(.winapi) void,
        SetComputeRootSignature: Unused,
        SetGraphicsRootSignature: *const fn (*anyopaque, *ID3D12RootSignature) callconv(.winapi) void,
        SetComputeRootDescriptorTable: Unused,
        SetGraphicsRootDescriptorTable: *const fn (*anyopaque, u32, u64) callconv(.winapi) void,
        SetComputeRoot32BitConstant: Unused,
        SetGraphicsRoot32BitConstant: Unused,
        SetComputeRoot32BitConstants: Unused,
        SetGraphicsRoot32BitConstants: Unused,
        SetComputeRootConstantBufferView: Unused,
        SetGraphicsRootConstantBufferView: *const fn (*anyopaque, u32, u64) callconv(.winapi) void,
        SetComputeRootShaderResourceView: Unused,
        SetGraphicsRootShaderResourceView: Unused,
        SetComputeRootUnorderedAccessView: Unused,
        SetGraphicsRootUnorderedAccessView: Unused,
        IASetIndexBuffer: *const fn (*anyopaque, ?*const D3D12_INDEX_BUFFER_VIEW) callconv(.winapi) void,
        IASetVertexBuffers: *const fn (*anyopaque, u32, u32, ?[*]const D3D12_VERTEX_BUFFER_VIEW) callconv(.winapi) void,
        SOSetTargets: Unused,
        OMSetRenderTargets: *const fn (*anyopaque, u32, ?[*]const usize, BOOL, ?*const usize) callconv(.winapi) void,
        ClearDepthStencilView: *const fn (*anyopaque, usize, u32, f32, u8, u32, ?[*]const D3D12_RECT) callconv(.winapi) void,
        ClearRenderTargetView: *const fn (*anyopaque, usize, *const [4]f32, u32, ?[*]const D3D12_RECT) callconv(.winapi) void,
        ClearUnorderedAccessViewUint: Unused,
        ClearUnorderedAccessViewFloat: Unused,
        DiscardResource: Unused,
        BeginQuery: Unused,
        EndQuery: Unused,
        ResolveQueryData: Unused,
        SetPredication: Unused,
        SetMarker: Unused,
        BeginEvent: Unused,
        EndEvent: Unused,
        ExecuteIndirect: Unused,
    };

    pub inline fn Release(self: *ID3D12GraphicsCommandList) u32 {
        return self.v.base.base.Release(self);
    }
    pub inline fn Close(self: *ID3D12GraphicsCommandList) HRESULT {
        return self.v.Close(self);
    }
    pub inline fn Reset(self: *ID3D12GraphicsCommandList, alloc: *ID3D12CommandAllocator, pso: ?*ID3D12PipelineState) HRESULT {
        return self.v.Reset(self, alloc, pso);
    }
    pub inline fn DrawInstanced(self: *ID3D12GraphicsCommandList, verts: u32, instances: u32, first_vert: u32, first_instance: u32) void {
        self.v.DrawInstanced(self, verts, instances, first_vert, first_instance);
    }
    pub inline fn DrawIndexedInstanced(self: *ID3D12GraphicsCommandList, idx: u32, instances: u32, first_idx: u32, base_vertex: i32, first_instance: u32) void {
        self.v.DrawIndexedInstanced(self, idx, instances, first_idx, base_vertex, first_instance);
    }
    pub inline fn CopyTextureRegion(
        self: *ID3D12GraphicsCommandList,
        dst: *const D3D12_TEXTURE_COPY_LOCATION,
        x: u32,
        y: u32,
        z: u32,
        src: *const D3D12_TEXTURE_COPY_LOCATION,
        box: ?*const D3D12_BOX,
    ) void {
        self.v.CopyTextureRegion(self, dst, x, y, z, src, box);
    }
    pub inline fn ResolveSubresource(self: *ID3D12GraphicsCommandList, dst: *ID3D12Resource, dst_sub: u32, src: *ID3D12Resource, src_sub: u32, fmt: u32) void {
        self.v.ResolveSubresource(self, dst, dst_sub, src, src_sub, fmt);
    }
    pub inline fn IASetPrimitiveTopology(self: *ID3D12GraphicsCommandList, topo: u32) void {
        self.v.IASetPrimitiveTopology(self, topo);
    }
    pub inline fn RSSetViewports(self: *ID3D12GraphicsCommandList, n: u32, vps: [*]const D3D12_VIEWPORT) void {
        self.v.RSSetViewports(self, n, vps);
    }
    pub inline fn RSSetScissorRects(self: *ID3D12GraphicsCommandList, n: u32, rects: [*]const D3D12_RECT) void {
        self.v.RSSetScissorRects(self, n, rects);
    }
    pub inline fn SetPipelineState(self: *ID3D12GraphicsCommandList, pso: *ID3D12PipelineState) void {
        self.v.SetPipelineState(self, pso);
    }
    pub inline fn ResourceBarrier(self: *ID3D12GraphicsCommandList, n: u32, bars: [*]const D3D12_RESOURCE_BARRIER) void {
        self.v.ResourceBarrier(self, n, bars);
    }
    pub inline fn SetDescriptorHeaps(self: *ID3D12GraphicsCommandList, n: u32, heaps: [*]const *ID3D12DescriptorHeap) void {
        self.v.SetDescriptorHeaps(self, n, heaps);
    }
    pub inline fn SetGraphicsRootSignature(self: *ID3D12GraphicsCommandList, rs: *ID3D12RootSignature) void {
        self.v.SetGraphicsRootSignature(self, rs);
    }
    pub inline fn SetGraphicsRootDescriptorTable(self: *ID3D12GraphicsCommandList, slot: u32, handle: u64) void {
        self.v.SetGraphicsRootDescriptorTable(self, slot, handle);
    }
    pub inline fn SetGraphicsRootConstantBufferView(self: *ID3D12GraphicsCommandList, slot: u32, addr: u64) void {
        self.v.SetGraphicsRootConstantBufferView(self, slot, addr);
    }
    pub inline fn IASetIndexBuffer(self: *ID3D12GraphicsCommandList, view: ?*const D3D12_INDEX_BUFFER_VIEW) void {
        self.v.IASetIndexBuffer(self, view);
    }
    pub inline fn IASetVertexBuffers(self: *ID3D12GraphicsCommandList, start: u32, n: u32, views: ?[*]const D3D12_VERTEX_BUFFER_VIEW) void {
        self.v.IASetVertexBuffers(self, start, n, views);
    }
    pub inline fn OMSetRenderTargets(self: *ID3D12GraphicsCommandList, n: u32, rtvs: ?[*]const usize, single_range: BOOL, dsv: ?*const usize) void {
        self.v.OMSetRenderTargets(self, n, rtvs, single_range, dsv);
    }
    pub inline fn ClearDepthStencilView(self: *ID3D12GraphicsCommandList, dsv: usize, flags: u32, depth: f32, stencil: u8) void {
        self.v.ClearDepthStencilView(self, dsv, flags, depth, stencil, 0, null);
    }
    pub inline fn ClearRenderTargetView(self: *ID3D12GraphicsCommandList, rtv: usize, color: *const [4]f32) void {
        self.v.ClearRenderTargetView(self, rtv, color, 0, null);
    }
};

pub const ID3D12Device = extern struct {
    v: *const VTable,
    pub const VTable = extern struct {
        base: UnknownSlots,
        // ID3D12Object
        GetPrivateData: Unused,
        SetPrivateData: Unused,
        SetPrivateDataInterface: Unused,
        SetName: Unused,
        // ID3D12Device
        GetNodeCount: Unused,
        CreateCommandQueue: *const fn (*anyopaque, *const D3D12_COMMAND_QUEUE_DESC, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateCommandAllocator: *const fn (*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateGraphicsPipelineState: *const fn (*anyopaque, *const D3D12_GRAPHICS_PIPELINE_STATE_DESC, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateComputePipelineState: Unused,
        CreateCommandList: *const fn (*anyopaque, u32, u32, *ID3D12CommandAllocator, ?*ID3D12PipelineState, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        CheckFeatureSupport: *const fn (*anyopaque, u32, *anyopaque, u32) callconv(.winapi) HRESULT,
        CreateDescriptorHeap: *const fn (*anyopaque, *const D3D12_DESCRIPTOR_HEAP_DESC, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        GetDescriptorHandleIncrementSize: *const fn (*anyopaque, u32) callconv(.winapi) u32,
        CreateRootSignature: *const fn (*anyopaque, u32, *const anyopaque, usize, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        CreateConstantBufferView: Unused,
        CreateShaderResourceView: *const fn (*anyopaque, ?*ID3D12Resource, ?*const D3D12_SHADER_RESOURCE_VIEW_DESC, usize) callconv(.winapi) void,
        CreateUnorderedAccessView: Unused,
        CreateRenderTargetView: *const fn (*anyopaque, ?*ID3D12Resource, ?*const anyopaque, usize) callconv(.winapi) void,
        CreateDepthStencilView: *const fn (*anyopaque, ?*ID3D12Resource, ?*const anyopaque, usize) callconv(.winapi) void,
        CreateSampler: Unused,
        CopyDescriptors: Unused,
        CopyDescriptorsSimple: Unused,
        GetResourceAllocationInfo: Unused, // returns a 16-byte struct (sret)
        GetCustomHeapProperties: Unused, // ditto
        CreateCommittedResource: *const fn (
            *anyopaque,
            *const D3D12_HEAP_PROPERTIES,
            u32,
            *const D3D12_RESOURCE_DESC,
            u32,
            ?*const D3D12_CLEAR_VALUE,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        CreateHeap: Unused,
        CreatePlacedResource: Unused,
        CreateReservedResource: Unused,
        CreateSharedHandle: Unused,
        OpenSharedHandle: Unused,
        OpenSharedHandleByName: Unused,
        MakeResident: Unused,
        Evict: Unused,
        CreateFence: *const fn (*anyopaque, u64, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        GetDeviceRemovedReason: *const fn (*anyopaque) callconv(.winapi) HRESULT,
        GetCopyableFootprints: Unused,
        CreateQueryHeap: Unused,
        SetStablePowerState: Unused,
        CreateCommandSignature: Unused,
        GetResourceTiling: Unused,
        GetAdapterLuid: Unused, // returns LUID by value
    };

    pub inline fn Release(self: *ID3D12Device) u32 {
        return self.v.base.Release(self);
    }
    pub inline fn CreateCommandQueue(self: *ID3D12Device, desc: *const D3D12_COMMAND_QUEUE_DESC, out: *?*ID3D12CommandQueue) HRESULT {
        return self.v.CreateCommandQueue(self, desc, &IID_ID3D12CommandQueue, @ptrCast(out));
    }
    pub inline fn CreateCommandAllocator(self: *ID3D12Device, kind: u32, out: *?*ID3D12CommandAllocator) HRESULT {
        return self.v.CreateCommandAllocator(self, kind, &IID_ID3D12CommandAllocator, @ptrCast(out));
    }
    pub inline fn CreateGraphicsPipelineState(self: *ID3D12Device, desc: *const D3D12_GRAPHICS_PIPELINE_STATE_DESC, out: *?*ID3D12PipelineState) HRESULT {
        return self.v.CreateGraphicsPipelineState(self, desc, &IID_ID3D12PipelineState, @ptrCast(out));
    }
    pub inline fn CreateCommandList(self: *ID3D12Device, mask: u32, kind: u32, alloc: *ID3D12CommandAllocator, pso: ?*ID3D12PipelineState, out: *?*ID3D12GraphicsCommandList) HRESULT {
        return self.v.CreateCommandList(self, mask, kind, alloc, pso, &IID_ID3D12GraphicsCommandList, @ptrCast(out));
    }
    pub inline fn CheckFeatureSupport(self: *ID3D12Device, feature: u32, data: *anyopaque, size: u32) HRESULT {
        return self.v.CheckFeatureSupport(self, feature, data, size);
    }
    pub inline fn CreateDescriptorHeap(self: *ID3D12Device, desc: *const D3D12_DESCRIPTOR_HEAP_DESC, out: *?*ID3D12DescriptorHeap) HRESULT {
        return self.v.CreateDescriptorHeap(self, desc, &IID_ID3D12DescriptorHeap, @ptrCast(out));
    }
    pub inline fn GetDescriptorHandleIncrementSize(self: *ID3D12Device, kind: u32) u32 {
        return self.v.GetDescriptorHandleIncrementSize(self, kind);
    }
    pub inline fn CreateRootSignature(self: *ID3D12Device, blob: []const u8, out: *?*ID3D12RootSignature) HRESULT {
        return self.v.CreateRootSignature(self, 0, blob.ptr, blob.len, &IID_ID3D12RootSignature, @ptrCast(out));
    }
    pub inline fn CreateShaderResourceView(self: *ID3D12Device, res: ?*ID3D12Resource, desc: ?*const D3D12_SHADER_RESOURCE_VIEW_DESC, dst: usize) void {
        self.v.CreateShaderResourceView(self, res, desc, dst);
    }
    pub inline fn CreateRenderTargetView(self: *ID3D12Device, res: ?*ID3D12Resource, dst: usize) void {
        self.v.CreateRenderTargetView(self, res, null, dst);
    }
    pub inline fn CreateDepthStencilView(self: *ID3D12Device, res: ?*ID3D12Resource, dst: usize) void {
        self.v.CreateDepthStencilView(self, res, null, dst);
    }
    pub inline fn CreateCommittedResource(
        self: *ID3D12Device,
        heap: *const D3D12_HEAP_PROPERTIES,
        desc: *const D3D12_RESOURCE_DESC,
        state: u32,
        clear: ?*const D3D12_CLEAR_VALUE,
        out: *?*ID3D12Resource,
    ) HRESULT {
        return self.v.CreateCommittedResource(self, heap, D3D12_HEAP_FLAG_NONE, desc, state, clear, &IID_ID3D12Resource, @ptrCast(out));
    }
    pub inline fn CreateFence(self: *ID3D12Device, initial: u64, out: *?*ID3D12Fence) HRESULT {
        return self.v.CreateFence(self, initial, 0, &IID_ID3D12Fence, @ptrCast(out));
    }
    pub inline fn GetDeviceRemovedReason(self: *ID3D12Device) HRESULT {
        return self.v.GetDeviceRemovedReason(self);
    }
};

// ---- the DLL entry points ---------------------------------------------------

pub const Api = struct {
    D3D12CreateDevice: *const fn (?*anyopaque, u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    D3D12SerializeRootSignature: *const fn (*const D3D12_ROOT_SIGNATURE_DESC, u32, *?*ID3DBlob, *?*ID3DBlob) callconv(.winapi) HRESULT,
    D3D12GetDebugInterface: ?*const fn (*const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    CreateDXGIFactory2: *const fn (u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    D3DCompile: *const fn (
        *const anyopaque, // pSrcData
        usize, // SrcDataSize
        ?[*:0]const u8, // pSourceName
        ?*const anyopaque, // pDefines
        ?*anyopaque, // pInclude
        [*:0]const u8, // pEntrypoint
        [*:0]const u8, // pTarget
        u32, // Flags1
        u32, // Flags2
        *?*ID3DBlob, // ppCode
        *?*ID3DBlob, // ppErrorMsgs
    ) callconv(.winapi) HRESULT,

    /// GetProcAddress hands back a `void*`, which carries alignment 1. A
    /// function pointer is more aligned than that on some targets (4 on
    /// aarch64), so the cast has to assert the alignment as well as the type.
    fn sym(comptime T: type, mod: HMODULE, comptime name: [*:0]const u8) ?T {
        const p = GetProcAddress(mod, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }
    fn Fn(comptime field: []const u8) type {
        const T = @FieldType(Api, field);
        return switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
    }

    /// Load the three DLLs and resolve the entry points the backend calls.
    /// error.Unsupported means the machine has no D3D12 runtime.
    pub fn load() error{Unsupported}!Api {
        const d3d12 = LoadLibraryA("d3d12.dll") orelse return error.Unsupported;
        const dxgi = LoadLibraryA("dxgi.dll") orelse return error.Unsupported;
        // Shipped in System32 since Windows 8.1. The shader programs are
        // compiled from HLSL at open.
        const dxc = LoadLibraryA("d3dcompiler_47.dll") orelse return error.Unsupported;
        return .{
            .D3D12CreateDevice = sym(Fn("D3D12CreateDevice"), d3d12, "D3D12CreateDevice") orelse return error.Unsupported,
            .D3D12SerializeRootSignature = sym(Fn("D3D12SerializeRootSignature"), d3d12, "D3D12SerializeRootSignature") orelse return error.Unsupported,
            .D3D12GetDebugInterface = sym(Fn("D3D12GetDebugInterface"), d3d12, "D3D12GetDebugInterface"),
            .CreateDXGIFactory2 = sym(Fn("CreateDXGIFactory2"), dxgi, "CreateDXGIFactory2") orelse return error.Unsupported,
            .D3DCompile = sym(Fn("D3DCompile"), dxc, "D3DCompile") orelse return error.Unsupported,
        };
    }
};

// The sizes the D3D12 runtime assumes for the structs declared above. A field
// of the wrong width or in the wrong place fails here rather than at the call.
comptime {
    std.debug.assert(@sizeOf(D3D12_RESOURCE_DESC) == 56);
    std.debug.assert(@sizeOf(D3D12_CLEAR_VALUE) == 20);
    std.debug.assert(@sizeOf(D3D12_RESOURCE_BARRIER) == 32);
    std.debug.assert(@sizeOf(D3D12_RENDER_TARGET_BLEND_DESC) == 40);
    std.debug.assert(@sizeOf(D3D12_BLEND_DESC) == 328);
    std.debug.assert(@sizeOf(D3D12_RASTERIZER_DESC) == 44);
    std.debug.assert(@sizeOf(D3D12_DEPTH_STENCIL_DESC) == 52);
    std.debug.assert(@sizeOf(D3D12_STREAM_OUTPUT_DESC) == 32);
    std.debug.assert(@sizeOf(D3D12_GRAPHICS_PIPELINE_STATE_DESC) == 656);
    std.debug.assert(@sizeOf(D3D12_ROOT_PARAMETER) == 32);
    std.debug.assert(@sizeOf(D3D12_STATIC_SAMPLER_DESC) == 52);
    std.debug.assert(@sizeOf(D3D12_ROOT_SIGNATURE_DESC) == 40);
    std.debug.assert(@sizeOf(D3D12_SHADER_RESOURCE_VIEW_DESC) == 40);
    std.debug.assert(@sizeOf(D3D12_TEXTURE_COPY_LOCATION) == 48);
    std.debug.assert(@sizeOf(D3D12_PLACED_SUBRESOURCE_FOOTPRINT) == 32);
    std.debug.assert(@sizeOf(DXGI_SWAP_CHAIN_DESC1) == 48);
    std.debug.assert(@sizeOf(DXGI_ADAPTER_DESC1) == 312);
}
