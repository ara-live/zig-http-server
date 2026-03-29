//! D3D11 Device Creation for WGC
//!
//! Creates D3D11 device with BGRA support required for Windows Graphics Capture.

const std = @import("std");
const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;

// ═══════════════════════════════════════════════════════════════
//  COM Interface Definitions
// ═══════════════════════════════════════════════════════════════

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

pub const IID_ID3D11Device = GUID{
    .Data1 = 0xdb6f6ddb,
    .Data2 = 0xac77,
    .Data3 = 0x4e88,
    .Data4 = .{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 },
};

pub const IID_IDXGIDevice = GUID{
    .Data1 = 0x54ec77fa,
    .Data2 = 0x1377,
    .Data3 = 0x44e6,
    .Data4 = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c },
};

// IUnknown vtable
pub const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
};

// ID3D11Device (partial - just what we need)
pub const ID3D11DeviceVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // ID3D11Device methods - must match vtable order!
    CreateBuffer: *const anyopaque,
    CreateTexture1D: *const anyopaque,
    CreateTexture2D: *const fn (*anyopaque, *const D3D11_TEXTURE2D_DESC, ?*const D3D11_SUBRESOURCE_DATA, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    CreateTexture3D: *const anyopaque,
    CreateShaderResourceView: *const anyopaque,
    CreateUnorderedAccessView: *const anyopaque,
    CreateRenderTargetView: *const anyopaque,
    CreateDepthStencilView: *const anyopaque,
    CreateInputLayout: *const anyopaque,
    CreateVertexShader: *const anyopaque,
    CreateGeometryShader: *const anyopaque,
    CreateGeometryShaderWithStreamOutput: *const anyopaque,
    CreatePixelShader: *const anyopaque,
    CreateHullShader: *const anyopaque,
    CreateDomainShader: *const anyopaque,
    CreateComputeShader: *const anyopaque,
    CreateClassLinkage: *const anyopaque,
    CreateBlendState: *const anyopaque,
    CreateDepthStencilState: *const anyopaque,
    CreateRasterizerState: *const anyopaque,
    CreateSamplerState: *const anyopaque,
    CreateQuery: *const anyopaque,
    CreatePredicate: *const anyopaque,
    CreateCounter: *const anyopaque,
    CreateDeferredContext: *const anyopaque,
    OpenSharedResource: *const anyopaque,
    CheckFormatSupport: *const anyopaque,
    CheckMultisampleQualityLevels: *const anyopaque,
    CheckCounterInfo: *const anyopaque,
    CheckCounter: *const anyopaque,
    CheckFeatureSupport: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    GetFeatureLevel: *const anyopaque,
    GetCreationFlags: *const anyopaque,
    GetDeviceRemovedReason: *const anyopaque,
    GetImmediateContext: *const fn (*anyopaque, *?*ID3D11DeviceContext) callconv(WINAPI) void,
};

pub const ID3D11Device = extern struct {
    lpVtbl: *const ID3D11DeviceVtbl,

    pub fn queryInterface(self: *ID3D11Device, riid: *const GUID, ppvObject: *?*anyopaque) windows.HRESULT {
        return self.lpVtbl.QueryInterface(self, riid, ppvObject);
    }

    pub fn createTexture2D(self: *ID3D11Device, desc: *const D3D11_TEXTURE2D_DESC) !*ID3D11Texture2D {
        var texture: ?*anyopaque = null;
        const hr = self.lpVtbl.CreateTexture2D(self, desc, null, &texture);
        if (hr < 0) {
            std.log.err("CreateTexture2D failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CreateTextureFailed;
        }
        return @ptrCast(@alignCast(texture.?));
    }

    pub fn getImmediateContext(self: *ID3D11Device) *ID3D11DeviceContext {
        var ctx: ?*ID3D11DeviceContext = null;
        self.lpVtbl.GetImmediateContext(self, &ctx);
        return ctx.?;
    }

    pub fn release(self: *ID3D11Device) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ID3D11DeviceContext
pub const ID3D11DeviceContextVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // ID3D11DeviceChild
    GetDevice: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    // ID3D11DeviceContext - lots of methods, we just need a few
    VSSetConstantBuffers: *const anyopaque,
    PSSetShaderResources: *const anyopaque,
    PSSetShader: *const anyopaque,
    PSSetSamplers: *const anyopaque,
    VSSetShader: *const anyopaque,
    DrawIndexed: *const anyopaque,
    Draw: *const anyopaque,
    Map: *const anyopaque,
    Unmap: *const anyopaque,
    PSSetConstantBuffers: *const anyopaque,
    IASetInputLayout: *const anyopaque,
    IASetVertexBuffers: *const anyopaque,
    IASetIndexBuffer: *const anyopaque,
    DrawIndexedInstanced: *const anyopaque,
    DrawInstanced: *const anyopaque,
    GSSetConstantBuffers: *const anyopaque,
    GSSetShader: *const anyopaque,
    IASetPrimitiveTopology: *const anyopaque,
    VSSetShaderResources: *const anyopaque,
    VSSetSamplers: *const anyopaque,
    Begin: *const anyopaque,
    End: *const anyopaque,
    GetData: *const anyopaque,
    SetPredication: *const anyopaque,
    GSSetShaderResources: *const anyopaque,
    GSSetSamplers: *const anyopaque,
    OMSetRenderTargets: *const anyopaque,
    OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
    OMSetBlendState: *const anyopaque,
    OMSetDepthStencilState: *const anyopaque,
    SOSetTargets: *const anyopaque,
    DrawAuto: *const anyopaque,
    DrawIndexedInstancedIndirect: *const anyopaque,
    DrawInstancedIndirect: *const anyopaque,
    Dispatch: *const anyopaque,
    DispatchIndirect: *const anyopaque,
    RSSetState: *const anyopaque,
    RSSetViewports: *const anyopaque,
    RSSetScissorRects: *const anyopaque,
    CopySubresourceRegion: *const anyopaque,
    CopyResource: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(WINAPI) void,
    UpdateSubresource: *const anyopaque,
    CopyStructureCount: *const anyopaque,
    ClearRenderTargetView: *const anyopaque,
    ClearUnorderedAccessViewUint: *const anyopaque,
    ClearUnorderedAccessViewFloat: *const anyopaque,
    ClearDepthStencilView: *const anyopaque,
    GenerateMips: *const anyopaque,
    SetResourceMinLOD: *const anyopaque,
    GetResourceMinLOD: *const anyopaque,
    ResolveSubresource: *const anyopaque,
    ExecuteCommandList: *const anyopaque,
    HSSetShaderResources: *const anyopaque,
    HSSetShader: *const anyopaque,
    HSSetSamplers: *const anyopaque,
    HSSetConstantBuffers: *const anyopaque,
    DSSetShaderResources: *const anyopaque,
    DSSetShader: *const anyopaque,
    DSSetSamplers: *const anyopaque,
    DSSetConstantBuffers: *const anyopaque,
    CSSetShaderResources: *const anyopaque,
    CSSetUnorderedAccessViews: *const anyopaque,
    CSSetShader: *const anyopaque,
    CSSetSamplers: *const anyopaque,
    CSSetConstantBuffers: *const anyopaque,
    VSGetConstantBuffers: *const anyopaque,
    PSGetShaderResources: *const anyopaque,
    PSGetShader: *const anyopaque,
    PSGetSamplers: *const anyopaque,
    VSGetShader: *const anyopaque,
    PSGetConstantBuffers: *const anyopaque,
    IAGetInputLayout: *const anyopaque,
    IAGetVertexBuffers: *const anyopaque,
    IAGetIndexBuffer: *const anyopaque,
    GSGetConstantBuffers: *const anyopaque,
    GSGetShader: *const anyopaque,
    IAGetPrimitiveTopology: *const anyopaque,
    VSGetShaderResources: *const anyopaque,
    VSGetSamplers: *const anyopaque,
    GetPredication: *const anyopaque,
    GSGetShaderResources: *const anyopaque,
    GSGetSamplers: *const anyopaque,
    OMGetRenderTargets: *const anyopaque,
    OMGetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
    OMGetBlendState: *const anyopaque,
    OMGetDepthStencilState: *const anyopaque,
    SOGetTargets: *const anyopaque,
    RSGetState: *const anyopaque,
    RSGetViewports: *const anyopaque,
    RSGetScissorRects: *const anyopaque,
    HSGetShaderResources: *const anyopaque,
    HSGetShader: *const anyopaque,
    HSGetSamplers: *const anyopaque,
    HSGetConstantBuffers: *const anyopaque,
    DSGetShaderResources: *const anyopaque,
    DSGetShader: *const anyopaque,
    DSGetSamplers: *const anyopaque,
    DSGetConstantBuffers: *const anyopaque,
    CSGetShaderResources: *const anyopaque,
    CSGetUnorderedAccessViews: *const anyopaque,
    CSGetShader: *const anyopaque,
    CSGetSamplers: *const anyopaque,
    CSGetConstantBuffers: *const anyopaque,
    ClearState: *const anyopaque,
    Flush: *const fn (*anyopaque) callconv(WINAPI) void,
};

pub const ID3D11DeviceContext = extern struct {
    lpVtbl: *const ID3D11DeviceContextVtbl,

    pub fn copyResource(self: *ID3D11DeviceContext, dst: *anyopaque, src: *anyopaque) void {
        self.lpVtbl.CopyResource(self, dst, src);
    }

    pub fn flush(self: *ID3D11DeviceContext) void {
        self.lpVtbl.Flush(self);
    }

    pub fn release(self: *ID3D11DeviceContext) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ID3D11Texture2D
pub const ID3D11Texture2DVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // ID3D11DeviceChild
    GetDevice: *const anyopaque,
    GetPrivateData: *const anyopaque,
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    // ID3D11Resource
    GetType: *const anyopaque,
    SetEvictionPriority: *const anyopaque,
    GetEvictionPriority: *const anyopaque,
    // ID3D11Texture2D
    GetDesc: *const fn (*anyopaque, *D3D11_TEXTURE2D_DESC) callconv(WINAPI) void,
};

pub const ID3D11Texture2D = extern struct {
    lpVtbl: *const ID3D11Texture2DVtbl,

    pub fn getDesc(self: *ID3D11Texture2D) D3D11_TEXTURE2D_DESC {
        var desc: D3D11_TEXTURE2D_DESC = undefined;
        self.lpVtbl.GetDesc(self, &desc);
        return desc;
    }

    pub fn release(self: *ID3D11Texture2D) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  D3D11 Enums and Structs
// ═══════════════════════════════════════════════════════════════

pub const D3D_DRIVER_TYPE = enum(c_int) {
    UNKNOWN = 0,
    HARDWARE = 1,
    REFERENCE = 2,
    NULL = 3,
    SOFTWARE = 4,
    WARP = 5,
};

pub const D3D_FEATURE_LEVEL = enum(c_int) {
    _9_1 = 0x9100,
    _9_2 = 0x9200,
    _9_3 = 0x9300,
    _10_0 = 0xa000,
    _10_1 = 0xa100,
    _11_0 = 0xb000,
    _11_1 = 0xb100,
    _12_0 = 0xc000,
    _12_1 = 0xc100,
};

pub const D3D11_CREATE_DEVICE_FLAG = packed struct(u32) {
    SINGLETHREADED: bool = false,
    DEBUG: bool = false,
    SWITCH_TO_REF: bool = false,
    PREVENT_INTERNAL_THREADING_OPTIMIZATIONS: bool = false,
    BGRA_SUPPORT: bool = false,
    DEBUGGABLE: bool = false,
    PREVENT_ALTERING_LAYER_SETTINGS_FROM_REGISTRY: bool = false,
    DISABLE_GPU_TIMEOUT: bool = false,
    VIDEO_SUPPORT: bool = false,
    _padding: u23 = 0,
};

pub const D3D11_TEXTURE2D_DESC = extern struct {
    Width: u32,
    Height: u32,
    MipLevels: u32,
    ArraySize: u32,
    Format: DXGI_FORMAT,
    SampleDesc: DXGI_SAMPLE_DESC,
    Usage: D3D11_USAGE,
    BindFlags: u32,
    CPUAccessFlags: u32,
    MiscFlags: u32,
};

pub const D3D11_SUBRESOURCE_DATA = extern struct {
    pSysMem: *const anyopaque,
    SysMemPitch: u32,
    SysMemSlicePitch: u32,
};

pub const D3D11_USAGE = enum(c_int) {
    DEFAULT = 0,
    IMMUTABLE = 1,
    DYNAMIC = 2,
    STAGING = 3,
};

pub const DXGI_FORMAT = enum(c_int) {
    UNKNOWN = 0,
    B8G8R8A8_UNORM = 87,
    B8G8R8A8_TYPELESS = 90,
    B8G8R8A8_UNORM_SRGB = 91,
    // Add more as needed
};

pub const DXGI_SAMPLE_DESC = extern struct {
    Count: u32 = 1,
    Quality: u32 = 0,
};

pub const D3D11_CPU_ACCESS_FLAG = struct {
    pub const READ: u32 = 0x20000;
    pub const WRITE: u32 = 0x10000;
};

pub const D3D11_RESOURCE_MISC_FLAG = struct {
    pub const SHARED: u32 = 0x2;
    pub const SHARED_KEYEDMUTEX: u32 = 0x10;
    pub const SHARED_NTHANDLE: u32 = 0x800;
};

pub const D3D11_BIND_FLAG = struct {
    pub const SHADER_RESOURCE: u32 = 0x8;
    pub const RENDER_TARGET: u32 = 0x20;
    pub const UNORDERED_ACCESS: u32 = 0x80;
};

// ═══════════════════════════════════════════════════════════════
//  External Functions
// ═══════════════════════════════════════════════════════════════

extern "d3d11" fn D3D11CreateDevice(
    pAdapter: ?*anyopaque,
    DriverType: D3D_DRIVER_TYPE,
    Software: ?windows.HMODULE,
    Flags: D3D11_CREATE_DEVICE_FLAG,
    pFeatureLevels: ?[*]const D3D_FEATURE_LEVEL,
    FeatureLevels: u32,
    SDKVersion: u32,
    ppDevice: *?*ID3D11Device,
    pFeatureLevel: ?*D3D_FEATURE_LEVEL,
    ppImmediateContext: *?*anyopaque,
) callconv(WINAPI) windows.HRESULT;

extern "dxgi" fn CreateDXGIFactory1(
    riid: *const GUID,
    ppFactory: *?*anyopaque,
) callconv(WINAPI) windows.HRESULT;

const D3D11_SDK_VERSION: u32 = 7;

// DXGI Factory interface
const IID_IDXGIFactory1 = GUID{
    .Data1 = 0x770aae78,
    .Data2 = 0xf26f,
    .Data3 = 0x4dba,
    .Data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 },
};

const IDXGIFactory1Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IDXGIObject
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    GetPrivateData: *const anyopaque,
    GetParent: *const anyopaque,
    // IDXGIFactory
    EnumAdapters: *const fn (*anyopaque, u32, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    MakeWindowAssociation: *const anyopaque,
    GetWindowAssociation: *const anyopaque,
    CreateSwapChain: *const anyopaque,
    CreateSoftwareAdapter: *const anyopaque,
    // IDXGIFactory1
    EnumAdapters1: *const fn (*anyopaque, u32, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    IsCurrent: *const anyopaque,
};

const DXGI_ADAPTER_DESC1 = extern struct {
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

const IDXGIAdapter1Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IDXGIObject
    SetPrivateData: *const anyopaque,
    SetPrivateDataInterface: *const anyopaque,
    GetPrivateData: *const anyopaque,
    GetParent: *const anyopaque,
    // IDXGIAdapter
    EnumOutputs: *const anyopaque,
    GetDesc: *const anyopaque,
    CheckInterfaceSupport: *const anyopaque,
    // IDXGIAdapter1
    GetDesc1: *const fn (*anyopaque, *DXGI_ADAPTER_DESC1) callconv(WINAPI) windows.HRESULT,
};

const NVIDIA_VENDOR_ID: u32 = 0x10DE;

// ═══════════════════════════════════════════════════════════════
//  Public API
// ═══════════════════════════════════════════════════════════════

pub const Device = struct {
    d3d_device: *ID3D11Device,
    d3d_context: *ID3D11DeviceContext,
    dxgi_device: ?*anyopaque = null,

    pub fn create() !Device {
        const feature_levels = [_]D3D_FEATURE_LEVEL{
            ._11_1,
            ._11_0,
            ._10_1,
            ._10_0,
        };

        const flags = D3D11_CREATE_DEVICE_FLAG{
            .BGRA_SUPPORT = true, // Required for WGC
        };

        // Find NVIDIA adapter for CUDA interop
        var nvidia_adapter: ?*anyopaque = null;
        {
            var factory: ?*anyopaque = null;
            var hr = CreateDXGIFactory1(&IID_IDXGIFactory1, &factory);
            if (hr >= 0 and factory != null) {
                defer {
                    const fac_unk: *const *const IUnknownVtbl = @ptrCast(@alignCast(factory.?));
                    _ = fac_unk.*.Release(factory.?);
                }
                
                const fac_vtbl: *const *const IDXGIFactory1Vtbl = @ptrCast(@alignCast(factory.?));
                var adapter_idx: u32 = 0;
                while (true) : (adapter_idx += 1) {
                    var adapter: ?*anyopaque = null;
                    hr = fac_vtbl.*.EnumAdapters1(factory.?, adapter_idx, &adapter);
                    if (hr < 0) break; // No more adapters
                    
                    const adp_vtbl: *const *const IDXGIAdapter1Vtbl = @ptrCast(@alignCast(adapter.?));
                    var desc: DXGI_ADAPTER_DESC1 = undefined;
                    _ = adp_vtbl.*.GetDesc1(adapter.?, &desc);
                    
                    // Log adapter info
                    var name_buf: [128]u8 = undefined;
                    const name_len = std.unicode.utf16LeToUtf8(&name_buf, &desc.Description) catch 0;
                    std.log.info("Adapter {}: {s} (VendorId: 0x{X:0>4}, VRAM: {}MB)", .{
                        adapter_idx,
                        name_buf[0..name_len],
                        desc.VendorId,
                        desc.DedicatedVideoMemory / (1024 * 1024),
                    });
                    
                    if (desc.VendorId == NVIDIA_VENDOR_ID) {
                        nvidia_adapter = adapter;
                        std.log.info("Selected NVIDIA adapter for CUDA interop", .{});
                        break;
                    } else {
                        // Release non-NVIDIA adapter
                        const adp_unk: *const *const IUnknownVtbl = @ptrCast(@alignCast(adapter.?));
                        _ = adp_unk.*.Release(adapter.?);
                    }
                }
            }
        }
        defer if (nvidia_adapter) |adp| {
            const adp_unk: *const *const IUnknownVtbl = @ptrCast(@alignCast(adp));
            _ = adp_unk.*.Release(adp);
        };

        var device: ?*ID3D11Device = null;
        var context: ?*anyopaque = null;
        var feature_level: D3D_FEATURE_LEVEL = undefined;

        // Use NVIDIA adapter if found, otherwise default
        const driver_type: D3D_DRIVER_TYPE = if (nvidia_adapter != null) .UNKNOWN else .HARDWARE;
        
        const hr = D3D11CreateDevice(
            nvidia_adapter, // Use NVIDIA adapter for CUDA interop
            driver_type,
            null,
            flags,
            &feature_levels,
            feature_levels.len,
            D3D11_SDK_VERSION,
            &device,
            &feature_level,
            &context,
        );

        if (hr < 0) {
            std.log.err("D3D11CreateDevice failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.D3D11CreateDeviceFailed;
        }

        std.log.info("D3D11 device created, feature level: 0x{X}", .{@intFromEnum(feature_level)});

        // Query IDXGIDevice
        var dxgi_device: ?*anyopaque = null;
        const qhr = device.?.queryInterface(&IID_IDXGIDevice, &dxgi_device);
        if (qhr < 0) {
            std.log.warn("Failed to query IDXGIDevice: 0x{X:0>8}", .{@as(u32, @bitCast(qhr))});
        }

        return Device{
            .d3d_device = device.?,
            .d3d_context = @ptrCast(@alignCast(context.?)),
            .dxgi_device = dxgi_device,
        };
    }

    pub fn deinit(self: *Device) void {
        if (self.dxgi_device) |dxgi| {
            const obj: *const *const IUnknownVtbl = @ptrCast(@alignCast(dxgi));
            _ = obj.*.Release(dxgi);
        }
        _ = self.d3d_device.release();
        _ = self.d3d_context.release();
    }

    /// Create a texture suitable for CUDA interop (SHARED flag)
    pub fn createSharedTexture(self: *Device, width: u32, height: u32, format: DXGI_FORMAT) !*ID3D11Texture2D {
        const desc = D3D11_TEXTURE2D_DESC{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = D3D11_BIND_FLAG.SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = D3D11_RESOURCE_MISC_FLAG.SHARED,
        };
        return self.d3d_device.createTexture2D(&desc);
    }

    /// Copy one texture to another
    pub fn copyTexture(self: *Device, dst: *ID3D11Texture2D, src: *anyopaque) void {
        self.d3d_context.copyResource(dst, src);
        self.d3d_context.flush();
    }
};

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

test "create D3D11 device" {
    var device = try Device.create();
    defer device.deinit();

    try std.testing.expect(device.dxgi_device != null);
}
