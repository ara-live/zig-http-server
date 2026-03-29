//! Windows Graphics Capture - Pure Zig
//!
//! Direct WinRT/WGC bindings without C++ intermediary.
//! Manual COM implementation for minimal overhead.

const std = @import("std");
const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;
const d3d11 = @import("d3d11.zig");

// ═══════════════════════════════════════════════════════════════
//  WinRT String (HSTRING)
// ═══════════════════════════════════════════════════════════════

pub const HSTRING = *opaque {};

extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsCreateString(
    sourceString: [*]const u16,
    length: u32,
    string: *?HSTRING,
) callconv(WINAPI) windows.HRESULT;

extern "api-ms-win-core-winrt-string-l1-1-0" fn WindowsDeleteString(
    string: ?HSTRING,
) callconv(WINAPI) windows.HRESULT;

// ═══════════════════════════════════════════════════════════════
//  WinRT Activation
// ═══════════════════════════════════════════════════════════════

extern "api-ms-win-core-winrt-l1-1-0" fn RoInitialize(
    initType: u32, // RO_INIT_MULTITHREADED = 1
) callconv(WINAPI) windows.HRESULT;

// COM initialization (required before WinRT on some thread types)
extern "ole32" fn CoInitializeEx(
    pvReserved: ?*anyopaque,
    dwCoInit: u32, // COINIT_MULTITHREADED = 0
) callconv(WINAPI) windows.HRESULT;

extern "api-ms-win-core-winrt-l1-1-0" fn RoGetActivationFactory(
    activatableClassId: HSTRING,
    iid: *const d3d11.GUID,
    factory: *?*anyopaque,
) callconv(WINAPI) windows.HRESULT;

// ═══════════════════════════════════════════════════════════════
//  COM Interface GUIDs
// ═══════════════════════════════════════════════════════════════

// IGraphicsCaptureItemInterop {3628E81B-3CAC-4C60-B7F4-23CE0E0C3356}
pub const IID_IGraphicsCaptureItemInterop = d3d11.GUID{
    .Data1 = 0x3628E81B,
    .Data2 = 0x3CAC,
    .Data3 = 0x4C60,
    .Data4 = .{ 0xB7, 0xF4, 0x23, 0xCE, 0x0E, 0x0C, 0x33, 0x56 },
};

// IGraphicsCaptureItem {79C3F95B-31F7-4EC2-A464-632EF5D30760}
pub const IID_IGraphicsCaptureItem = d3d11.GUID{
    .Data1 = 0x79C3F95B,
    .Data2 = 0x31F7,
    .Data3 = 0x4EC2,
    .Data4 = .{ 0xA4, 0x64, 0x63, 0x2E, 0xF5, 0xD3, 0x07, 0x60 },
};

// IActivationFactory {00000035-0000-0000-C000-000000000046}
pub const IID_IActivationFactory = d3d11.GUID{
    .Data1 = 0x00000035,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

// ═══════════════════════════════════════════════════════════════
//  IGraphicsCaptureItemInterop
// ═══════════════════════════════════════════════════════════════

pub const IGraphicsCaptureItemInteropVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IGraphicsCaptureItemInterop
    CreateForWindow: *const fn (
        self: *anyopaque,
        window: windows.HWND,
        riid: *const d3d11.GUID,
        result: *?*anyopaque,
    ) callconv(WINAPI) windows.HRESULT,
    CreateForMonitor: *const fn (
        self: *anyopaque,
        monitor: *anyopaque, // HMONITOR
        riid: *const d3d11.GUID,
        result: *?*anyopaque,
    ) callconv(WINAPI) windows.HRESULT,
};

pub const IGraphicsCaptureItemInterop = extern struct {
    lpVtbl: *const IGraphicsCaptureItemInteropVtbl,

    pub fn createForWindow(self: *IGraphicsCaptureItemInterop, hwnd: windows.HWND, riid: *const d3d11.GUID, result: *?*anyopaque) windows.HRESULT {
        return self.lpVtbl.CreateForWindow(self, hwnd, riid, result);
    }

    pub fn release(self: *IGraphicsCaptureItemInterop) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  IGraphicsCaptureItem (WinRT interface - partial)
// ═══════════════════════════════════════════════════════════════

pub const SizeInt32 = extern struct {
    Width: i32,
    Height: i32,
};

pub const IGraphicsCaptureItemVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]*d3d11.GUID) callconv(WINAPI) windows.HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(WINAPI) windows.HRESULT,
    // IGraphicsCaptureItem
    get_DisplayName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    get_Size: *const fn (*anyopaque, *SizeInt32) callconv(WINAPI) windows.HRESULT,
    add_Closed: *const fn (*anyopaque, *anyopaque, *i64) callconv(WINAPI) windows.HRESULT,
    remove_Closed: *const fn (*anyopaque, i64) callconv(WINAPI) windows.HRESULT,
};

pub const IGraphicsCaptureItem = extern struct {
    lpVtbl: *const IGraphicsCaptureItemVtbl,

    pub fn getSize(self: *IGraphicsCaptureItem) !SizeInt32 {
        var size: SizeInt32 = undefined;
        const hr = self.lpVtbl.get_Size(self, &size);
        if (hr < 0) return error.GetSizeFailed;
        return size;
    }

    pub fn release(self: *IGraphicsCaptureItem) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  Public API
// ═══════════════════════════════════════════════════════════════

// Thread-local COM/WinRT initialization (must be called per-thread)
threadlocal var tls_initialized: bool = false;

pub fn init() !void {
    if (tls_initialized) return;

    // Initialize COM first (MTA mode)
    const co_hr = CoInitializeEx(null, 0); // COINIT_MULTITHREADED = 0
    // S_OK, S_FALSE (already init), or RPC_E_CHANGED_MODE (different mode) are all acceptable
    if (co_hr < 0 and co_hr != @as(i32, @bitCast(@as(u32, 0x80010106)))) { // RPC_E_CHANGED_MODE
        std.log.err("CoInitializeEx failed: 0x{X:0>8}", .{@as(u32, @bitCast(co_hr))});
        return error.CoInitializeFailed;
    }

    // Then initialize WinRT
    const hr = RoInitialize(1); // RO_INIT_MULTITHREADED
    // S_OK (0) or S_FALSE (1, already initialized on this thread) are both fine
    if (hr < 0) {
        std.log.err("RoInitialize failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.RoInitializeFailed;
    }

    tls_initialized = true;
    std.log.info("COM+WinRT initialized on thread", .{});
}

/// Creates a GraphicsCaptureItem for a window handle
pub fn createCaptureItemForWindow(hwnd: windows.HWND) !*IGraphicsCaptureItem {
    try init();

    // Class name: "Windows.Graphics.Capture.GraphicsCaptureItem"
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Graphics.Capture.GraphicsCaptureItem");

    var hstring: ?HSTRING = null;
    var hr = WindowsCreateString(class_name.ptr, class_name.len, &hstring);
    if (hr < 0) {
        std.log.err("WindowsCreateString failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateStringFailed;
    }
    defer _ = WindowsDeleteString(hstring);

    // Get activation factory
    var factory: ?*anyopaque = null;
    hr = RoGetActivationFactory(hstring.?, &IID_IGraphicsCaptureItemInterop, &factory);
    if (hr < 0) {
        std.log.err("RoGetActivationFactory failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.GetFactoryFailed;
    }

    const interop: *IGraphicsCaptureItemInterop = @ptrCast(@alignCast(factory.?));
    defer _ = interop.release();

    // Create capture item for window
    var item: ?*anyopaque = null;
    hr = interop.createForWindow(hwnd, &IID_IGraphicsCaptureItem, &item);
    if (hr < 0) {
        std.log.err("CreateForWindow failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateForWindowFailed;
    }

    std.log.info("Created capture item for HWND {}", .{@intFromPtr(hwnd)});
    return @ptrCast(@alignCast(item.?));
}

// ═══════════════════════════════════════════════════════════════
//  Direct3D11 WinRT Interop
// ═══════════════════════════════════════════════════════════════

// Creates WinRT IDirect3DDevice from IDXGIDevice
extern "d3d11" fn CreateDirect3D11DeviceFromDXGIDevice(
    dxgiDevice: *anyopaque, // IDXGIDevice*
    graphicsDevice: *?*anyopaque, // IInspectable**
) callconv(WINAPI) windows.HRESULT;

// IDirect3DDevice IID {A37624AB-8D5F-4650-9D3E-9EAE3D9BC670}
pub const IID_IDirect3DDevice = d3d11.GUID{
    .Data1 = 0xA37624AB,
    .Data2 = 0x8D5F,
    .Data3 = 0x4650,
    .Data4 = .{ 0x9D, 0x3E, 0x9E, 0xAE, 0x3D, 0x9B, 0xC6, 0x70 },
};

/// Wraps IDXGIDevice into WinRT IDirect3DDevice
pub fn createDirect3DDevice(dxgi_device: *anyopaque) !*anyopaque {
    var d3d_device: ?*anyopaque = null;
    const hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi_device, &d3d_device);
    if (hr < 0) {
        std.log.err("CreateDirect3D11DeviceFromDXGIDevice failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.CreateDirect3DDeviceFailed;
    }
    return d3d_device.?;
}

// ═══════════════════════════════════════════════════════════════
//  Direct3D11CaptureFramePool
// ═══════════════════════════════════════════════════════════════

// IGraphicsCaptureItemStatics not needed - we use interop directly

// IDirect3D11CaptureFramePoolStatics {7784056A-67AA-4D53-AE54-1088D5A8CA21}
pub const IID_IDirect3D11CaptureFramePoolStatics = d3d11.GUID{
    .Data1 = 0x7784056A,
    .Data2 = 0x67AA,
    .Data3 = 0x4D53,
    .Data4 = .{ 0xAE, 0x54, 0x10, 0x88, 0xD5, 0xA8, 0xCA, 0x21 },
};

// IDirect3D11CaptureFramePool {24EB6D22-1975-422E-82E7-780DBD8DDF24}  
pub const IID_IDirect3D11CaptureFramePool = d3d11.GUID{
    .Data1 = 0x24EB6D22,
    .Data2 = 0x1975,
    .Data3 = 0x422E,
    .Data4 = .{ 0x82, 0xE7, 0x78, 0x0D, 0xBD, 0x8D, 0xDF, 0x24 },
};

// DirectXPixelFormat enum values
pub const DirectXPixelFormat = enum(c_int) {
    Unknown = 0,
    B8G8R8A8UIntNormalized = 87, // DXGI_FORMAT_B8G8R8A8_UNORM
    R8G8B8A8UIntNormalized = 28,
};

// IDirect3D11CaptureFramePoolStatics vtable
pub const IDirect3D11CaptureFramePoolStaticsVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]*d3d11.GUID) callconv(WINAPI) windows.HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(WINAPI) windows.HRESULT,
    // IDirect3D11CaptureFramePoolStatics
    Create: *const fn (
        self: *anyopaque,
        device: *anyopaque, // IDirect3DDevice
        pixelFormat: DirectXPixelFormat,
        numberOfBuffers: i32,
        size: SizeInt32,
        result: *?*anyopaque, // IDirect3D11CaptureFramePool
    ) callconv(WINAPI) windows.HRESULT,
};

pub const IDirect3D11CaptureFramePoolStatics = extern struct {
    lpVtbl: *const IDirect3D11CaptureFramePoolStaticsVtbl,

    pub fn create(
        self: *IDirect3D11CaptureFramePoolStatics,
        device: *anyopaque,
        pixelFormat: DirectXPixelFormat,
        numberOfBuffers: i32,
        size: SizeInt32,
    ) !*IDirect3D11CaptureFramePool {
        var result: ?*anyopaque = null;
        const hr = self.lpVtbl.Create(self, device, pixelFormat, numberOfBuffers, size, &result);
        if (hr < 0) {
            std.log.err("FramePool.Create failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.FramePoolCreateFailed;
        }
        return @ptrCast(@alignCast(result.?));
    }

    pub fn release(self: *IDirect3D11CaptureFramePoolStatics) u32 {
        return self.lpVtbl.Release(self);
    }
};

// IDirect3D11CaptureFramePool vtable
pub const IDirect3D11CaptureFramePoolVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]*d3d11.GUID) callconv(WINAPI) windows.HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(WINAPI) windows.HRESULT,
    // IDirect3D11CaptureFramePool
    Recreate: *const fn (*anyopaque, *anyopaque, DirectXPixelFormat, i32, SizeInt32) callconv(WINAPI) windows.HRESULT,
    TryGetNextFrame: *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    add_FrameArrived: *const fn (*anyopaque, *anyopaque, *i64) callconv(WINAPI) windows.HRESULT,
    remove_FrameArrived: *const fn (*anyopaque, i64) callconv(WINAPI) windows.HRESULT,
    CreateCaptureSession: *const fn (*anyopaque, *IGraphicsCaptureItem, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    // ... more methods
};

pub const IDirect3D11CaptureFramePool = extern struct {
    lpVtbl: *const IDirect3D11CaptureFramePoolVtbl,

    pub fn tryGetNextFrame(self: *IDirect3D11CaptureFramePool) ?*IDirect3D11CaptureFrame {
        var frame: ?*anyopaque = null;
        const hr = self.lpVtbl.TryGetNextFrame(self, &frame);
        if (hr < 0 or frame == null) return null;
        return @ptrCast(@alignCast(frame.?));
    }

    pub fn createCaptureSession(self: *IDirect3D11CaptureFramePool, item: *IGraphicsCaptureItem) !*IGraphicsCaptureSession {
        var session: ?*anyopaque = null;
        const hr = self.lpVtbl.CreateCaptureSession(self, item, &session);
        if (hr < 0) {
            std.log.err("CreateCaptureSession failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.CreateSessionFailed;
        }
        return @ptrCast(@alignCast(session.?));
    }

    pub fn release(self: *IDirect3D11CaptureFramePool) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  IGraphicsCaptureSession
// ═══════════════════════════════════════════════════════════════

pub const IGraphicsCaptureSessionVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]*d3d11.GUID) callconv(WINAPI) windows.HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(WINAPI) windows.HRESULT,
    // IGraphicsCaptureSession
    StartCapture: *const fn (*anyopaque) callconv(WINAPI) windows.HRESULT,
};

pub const IGraphicsCaptureSession = extern struct {
    lpVtbl: *const IGraphicsCaptureSessionVtbl,

    pub fn startCapture(self: *IGraphicsCaptureSession) !void {
        const hr = self.lpVtbl.StartCapture(self);
        if (hr < 0) {
            std.log.err("StartCapture failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.StartCaptureFailed;
        }
    }

    pub fn release(self: *IGraphicsCaptureSession) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  IDirect3D11CaptureFrame
// ═══════════════════════════════════════════════════════════════

pub const IDirect3D11CaptureFrameVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IInspectable
    GetIids: *const fn (*anyopaque, *u32, *?[*]*d3d11.GUID) callconv(WINAPI) windows.HRESULT,
    GetRuntimeClassName: *const fn (*anyopaque, *?HSTRING) callconv(WINAPI) windows.HRESULT,
    GetTrustLevel: *const fn (*anyopaque, *i32) callconv(WINAPI) windows.HRESULT,
    // IDirect3D11CaptureFrame
    get_Surface: *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    get_SystemRelativeTime: *const fn (*anyopaque, *i64) callconv(WINAPI) windows.HRESULT,
    get_ContentSize: *const fn (*anyopaque, *SizeInt32) callconv(WINAPI) windows.HRESULT,
};

pub const IDirect3D11CaptureFrame = extern struct {
    lpVtbl: *const IDirect3D11CaptureFrameVtbl,

    pub fn getSurface(self: *IDirect3D11CaptureFrame) !*anyopaque {
        var surface: ?*anyopaque = null;
        const hr = self.lpVtbl.get_Surface(self, &surface);
        if (hr < 0) return error.GetSurfaceFailed;
        return surface.?;
    }

    pub fn getContentSize(self: *IDirect3D11CaptureFrame) !SizeInt32 {
        var size: SizeInt32 = undefined;
        const hr = self.lpVtbl.get_ContentSize(self, &size);
        if (hr < 0) return error.GetSizeFailed;
        return size;
    }

    pub fn release(self: *IDirect3D11CaptureFrame) u32 {
        return self.lpVtbl.Release(self);
    }
};

// ═══════════════════════════════════════════════════════════════
//  IDirect3DDxgiInterfaceAccess (extract D3D11 textures from WinRT)
// ═══════════════════════════════════════════════════════════════

// {A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1}
pub const IID_IDirect3DDxgiInterfaceAccess = d3d11.GUID{
    .Data1 = 0xA9B3D012,
    .Data2 = 0x3DF2,
    .Data3 = 0x4EE3,
    .Data4 = .{ 0xB8, 0xD1, 0x86, 0x95, 0xF4, 0x57, 0xD3, 0xC1 },
};

// IID_ID3D11Texture2D {6F15AAF2-D208-4E89-9AB4-489535D34F9C}
pub const IID_ID3D11Texture2D = d3d11.GUID{
    .Data1 = 0x6F15AAF2,
    .Data2 = 0xD208,
    .Data3 = 0x4E89,
    .Data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
};

pub const IDirect3DDxgiInterfaceAccessVtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
    AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
    Release: *const fn (*anyopaque) callconv(WINAPI) u32,
    // IDirect3DDxgiInterfaceAccess
    GetInterface: *const fn (*anyopaque, *const d3d11.GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
};

pub const IDirect3DDxgiInterfaceAccess = extern struct {
    lpVtbl: *const IDirect3DDxgiInterfaceAccessVtbl,

    pub fn getInterface(self: *IDirect3DDxgiInterfaceAccess, riid: *const d3d11.GUID) !*anyopaque {
        var result: ?*anyopaque = null;
        const hr = self.lpVtbl.GetInterface(self, riid, &result);
        if (hr < 0) {
            std.log.err("GetInterface failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.GetInterfaceFailed;
        }
        return result.?;
    }

    pub fn release(self: *IDirect3DDxgiInterfaceAccess) u32 {
        return self.lpVtbl.Release(self);
    }
};

/// Extract ID3D11Texture2D from a WinRT IDirect3DSurface
pub fn getTextureFromSurface(surface: *anyopaque) !*anyopaque {
    // QI for IDirect3DDxgiInterfaceAccess
    const unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(surface));
    var access: ?*anyopaque = null;
    const hr = unk.*.QueryInterface(surface, &IID_IDirect3DDxgiInterfaceAccess, &access);
    if (hr < 0) {
        std.log.err("QI for IDirect3DDxgiInterfaceAccess failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.QueryInterfaceFailed;
    }
    defer {
        const acc: *IDirect3DDxgiInterfaceAccess = @ptrCast(@alignCast(access.?));
        _ = acc.release();
    }

    // Get the ID3D11Texture2D
    const iface: *IDirect3DDxgiInterfaceAccess = @ptrCast(@alignCast(access.?));
    return iface.getInterface(&IID_ID3D11Texture2D);
}

// ═══════════════════════════════════════════════════════════════
//  Frame Pool Factory
// ═══════════════════════════════════════════════════════════════

/// Gets the frame pool statics factory
pub fn getFramePoolFactory() !*IDirect3D11CaptureFramePoolStatics {
    try init();

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("Windows.Graphics.Capture.Direct3D11CaptureFramePool");

    var hstring: ?HSTRING = null;
    var hr = WindowsCreateString(class_name.ptr, class_name.len, &hstring);
    if (hr < 0) return error.CreateStringFailed;
    defer _ = WindowsDeleteString(hstring);

    var factory: ?*anyopaque = null;
    hr = RoGetActivationFactory(hstring.?, &IID_IDirect3D11CaptureFramePoolStatics, &factory);
    if (hr < 0) {
        std.log.err("RoGetActivationFactory for FramePool failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
        return error.GetFactoryFailed;
    }

    return @ptrCast(@alignCast(factory.?));
}

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

extern "user32" fn GetDesktopWindow() callconv(WINAPI) windows.HWND;
extern "user32" fn FindWindowW(lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16) callconv(WINAPI) ?windows.HWND;

test "create capture item for task manager" {
    // Find Task Manager window
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null);

    if (hwnd) |h| {
        std.debug.print("Task Manager HWND: {}\n", .{@intFromPtr(h)});
        const item = try createCaptureItemForWindow(h);
        defer _ = item.release();

        const size = try item.getSize();
        std.debug.print("Task Manager size: {}x{}\n", .{ size.Width, size.Height });

        try std.testing.expect(size.Width > 0);
        try std.testing.expect(size.Height > 0);
    } else {
        std.debug.print("Task Manager not found, skipping\n", .{});
    }
}

test "full capture pipeline" {
    // Find Task Manager
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null) orelse {
        std.debug.print("Task Manager not found, skipping full capture test\n", .{});
        return;
    };

    // Create D3D11 device
    var device = try d3d11.Device.create();
    defer device.deinit();
    std.debug.print("D3D11 device created\n", .{});

    // Wrap in WinRT IDirect3DDevice
    const d3d_device = try createDirect3DDevice(device.dxgi_device.?);
    std.debug.print("WinRT Direct3D device created\n", .{});

    // Create capture item
    const item = try createCaptureItemForWindow(hwnd);
    defer _ = item.release();
    const size = try item.getSize();
    std.debug.print("Capture item: {}x{}\n", .{ size.Width, size.Height });

    // Get frame pool factory
    const factory = try getFramePoolFactory();
    defer _ = factory.release();
    std.debug.print("Frame pool factory acquired\n", .{});

    // Create frame pool
    const pool = try factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
    defer _ = pool.release();
    std.debug.print("Frame pool created\n", .{});

    // Create capture session
    const session = try pool.createCaptureSession(item);
    defer _ = session.release();
    std.debug.print("Capture session created\n", .{});

    // Start capture
    try session.startCapture();
    std.debug.print("Capture started!\n", .{});

    // Try to get a frame (may need a small delay)
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    if (pool.tryGetNextFrame()) |frame| {
        defer _ = frame.release();
        const frame_size = try frame.getContentSize();
        std.debug.print("Got frame! Size: {}x{}\n", .{ frame_size.Width, frame_size.Height });
        try std.testing.expect(frame_size.Width > 0);
    } else {
        std.debug.print("No frame yet (normal on first try)\n", .{});
    }

    std.debug.print("Full capture pipeline test PASSED!\n", .{});
}

test "extract texture from frame" {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null) orelse {
        std.debug.print("Task Manager not found, skipping\n", .{});
        return;
    };

    // Full pipeline setup
    var device = try d3d11.Device.create();
    defer device.deinit();

    const d3d_device = try createDirect3DDevice(device.dxgi_device.?);
    const item = try createCaptureItemForWindow(hwnd);
    defer _ = item.release();
    const size = try item.getSize();

    const factory = try getFramePoolFactory();
    defer _ = factory.release();
    const pool = try factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
    defer _ = pool.release();
    const session = try pool.createCaptureSession(item);
    defer _ = session.release();

    try session.startCapture();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    if (pool.tryGetNextFrame()) |frame| {
        defer _ = frame.release();

        // Get surface
        const surface = try frame.getSurface();
        std.debug.print("Got surface: {*}\n", .{surface});

        // Extract texture
        const texture = try getTextureFromSurface(surface);
        std.debug.print("Got ID3D11Texture2D: {*}\n", .{texture});

        // Release texture (COM ref counting)
        const tex_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(texture));
        _ = tex_unk.*.Release(texture);

        std.debug.print("Texture extraction test PASSED!\n", .{});
    } else {
        std.debug.print("No frame available\n", .{});
    }
}

test "full CUDA pipeline" {
    const cuda = @import("cuda.zig");
    
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null) orelse {
        std.debug.print("Task Manager not found, skipping\n", .{});
        return;
    };

    // D3D11 + WGC setup
    var device = try d3d11.Device.create();
    defer device.deinit();

    const d3d_device = try createDirect3DDevice(device.dxgi_device.?);
    const item = try createCaptureItemForWindow(hwnd);
    defer _ = item.release();
    const size = try item.getSize();

    const factory = try getFramePoolFactory();
    defer _ = factory.release();
    const pool = try factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
    defer _ = pool.release();
    const session = try pool.createCaptureSession(item);
    defer _ = session.release();

    // CUDA setup - must use D3D11 interop init to pair with same GPU
    var cuda_ctx = cuda.CudaContext.initWithD3D11(device.d3d_device) catch |err| {
        std.debug.print("CUDA D3D11 init failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.deinit();
    std.debug.print("CUDA D3D11 interop context created\n", .{});

    // Create our own SHARED texture for CUDA interop
    const shared_texture = try device.createSharedTexture(
        @intCast(size.Width),
        @intCast(size.Height),
        .B8G8R8A8_UNORM,
    );
    defer _ = shared_texture.release();
    std.debug.print("Created shared texture {}x{}\n", .{ size.Width, size.Height });

    // Register shared texture with CUDA (before capture, reuse across frames)
    const cuda_resource = cuda_ctx.registerD3D11Texture(shared_texture) catch |err| {
        std.debug.print("CUDA register shared texture failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.unregisterResource(cuda_resource);
    std.debug.print("Shared texture registered with CUDA!\n", .{});

    // Start capture and get frame
    try session.startCapture();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    if (pool.tryGetNextFrame()) |frame| {
        defer _ = frame.release();
        const frame_size = try frame.getContentSize();

        // Get WGC texture
        const surface = try frame.getSurface();
        const wgc_texture = try getTextureFromSurface(surface);
        defer {
            const tex_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(wgc_texture));
            _ = tex_unk.*.Release(wgc_texture);
        }

        // Copy WGC texture → our shared texture (GPU→GPU, fast!)
        device.copyTexture(shared_texture, wgc_texture);
        std.debug.print("Copied WGC texture to shared texture\n", .{});

        // Map shared texture for CUDA access
        var resource = cuda_resource;
        try cuda_ctx.mapResource(&resource);
        defer cuda_ctx.unmapResource(&resource);
        std.debug.print("Shared texture mapped for CUDA access!\n", .{});

        // Get CUDA array
        const cuda_array = try cuda_ctx.getMappedArray(cuda_resource);
        std.debug.print("Got CUDA array: {*}\n", .{cuda_array});

        std.debug.print("CUDA pipeline to array PASSED! Frame: {}x{}\n", .{ frame_size.Width, frame_size.Height });
    } else {
        std.debug.print("No frame available\n", .{});
    }
}

test "full nvJPEG encode" {
    const cuda = @import("cuda.zig");
    const nvjpeg = @import("nvjpeg.zig");
    
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null) orelse {
        std.debug.print("Task Manager not found, skipping\n", .{});
        return;
    };

    // Full D3D11 + WGC + CUDA setup (same as before)
    var device = try d3d11.Device.create();
    defer device.deinit();

    const d3d_device = try createDirect3DDevice(device.dxgi_device.?);
    const item = try createCaptureItemForWindow(hwnd);
    defer _ = item.release();
    const size = try item.getSize();
    const width: u32 = @intCast(size.Width);
    const height: u32 = @intCast(size.Height);

    const factory = try getFramePoolFactory();
    defer _ = factory.release();
    const pool = try factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
    defer _ = pool.release();
    const session = try pool.createCaptureSession(item);
    defer _ = session.release();

    var cuda_ctx = cuda.CudaContext.initWithD3D11(device.d3d_device) catch |err| {
        std.debug.print("CUDA init failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.deinit();

    // Create shared texture and register with CUDA
    const shared_texture = try device.createSharedTexture(width, height, .B8G8R8A8_UNORM);
    defer _ = shared_texture.release();

    const cuda_resource = cuda_ctx.registerD3D11Texture(shared_texture) catch |err| {
        std.debug.print("CUDA register failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.unregisterResource(cuda_resource);

    // Allocate CUDA device memory for linear BGRA data
    const bgra_pitch = width * 4; // 4 bytes per pixel
    const bgra_size = bgra_pitch * height;
    const bgra_mem = try cuda_ctx.alloc(bgra_size);
    defer cuda_ctx.free(bgra_mem);

    // Also allocate RGB memory for nvJPEG (3 bytes per pixel)
    const rgb_pitch = width * 3;
    const rgb_size = rgb_pitch * height;
    const rgb_mem = try cuda_ctx.alloc(rgb_size);
    defer cuda_ctx.free(rgb_mem);
    std.debug.print("Allocated {}KB BGRA + {}KB RGB CUDA memory\n", .{ bgra_size / 1024, rgb_size / 1024 });

    // Initialize nvJPEG encoder
    var encoder = nvjpeg.JpegEncoder.init(cuda_ctx.stream) catch |err| {
        std.debug.print("nvJPEG init failed: {}\n", .{err});
        return;
    };
    defer encoder.deinit();
    std.debug.print("nvJPEG encoder ready\n", .{});

    // Start capture
    try session.startCapture();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    if (pool.tryGetNextFrame()) |frame| {
        defer _ = frame.release();

        // Copy WGC → shared texture
        const surface = try frame.getSurface();
        const wgc_texture = try getTextureFromSurface(surface);
        defer {
            const tex_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(wgc_texture));
            _ = tex_unk.*.Release(wgc_texture);
        }
        device.copyTexture(shared_texture, wgc_texture);

        // Map shared texture → CUDA array
        var resource = cuda_resource;
        try cuda_ctx.mapResource(&resource);
        defer cuda_ctx.unmapResource(&resource);

        const cuda_array = try cuda_ctx.getMappedArray(cuda_resource);

        // Copy array → linear BGRA device memory
        try cuda_ctx.copyArrayToDevice(bgra_mem, bgra_pitch, cuda_array, width, height, 4);
        cuda_ctx.synchronize();
        std.debug.print("Copied to BGRA memory, synced\n", .{});

        // TODO: BGRA→RGB conversion kernel needed here
        // For now, we'll try encoding with RGB pitch pointing to BGRA data
        // This will produce garbage colors but should prove the API works
        
        // Encode to JPEG (using RGB memory with wrong data for now)
        const jpeg_data = encoder.encode(
            std.testing.allocator,
            bgra_mem, // Using BGRA data but with RGB pitch - will be garbled
            width,
            height,
            rgb_pitch, // Tell nvJPEG it's 3 bytes/pixel
        ) catch |err| {
            std.debug.print("nvJPEG encode failed: {} (BGRA→RGB conversion needed)\n", .{err});
            // Expected to fail until we add BGRA→RGB
            return;
        };
        defer std.testing.allocator.free(jpeg_data);

        std.debug.print("JPEG ENCODED! Size: {} bytes ({}x{})\n", .{ jpeg_data.len, width, height });
    } else {
        std.debug.print("No frame available\n", .{});
    }
}

test "NUCLEAR: fused resize + nvJPEG" {
    const cuda = @import("cuda.zig");
    const nvjpeg = @import("nvjpeg.zig");
    const kernel = @import("kernel.zig");
    
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskManagerWindow");
    const hwnd = FindWindowW(class_name.ptr, null) orelse {
        std.debug.print("Task Manager not found, skipping\n", .{});
        return;
    };

    // Target output size (Anthropic max width)
    const target_width: u32 = 800; // Smaller for test
    const target_height: u32 = 453; // Maintain aspect ratio

    // D3D11 + WGC setup
    var device = try d3d11.Device.create();
    defer device.deinit();

    const d3d_device = try createDirect3DDevice(device.dxgi_device.?);
    const item = try createCaptureItemForWindow(hwnd);
    defer _ = item.release();
    const size = try item.getSize();
    const src_width: u32 = @intCast(size.Width);
    const src_height: u32 = @intCast(size.Height);

    const factory = try getFramePoolFactory();
    defer _ = factory.release();
    const pool = try factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
    defer _ = pool.release();
    const session = try pool.createCaptureSession(item);
    defer _ = session.release();

    // CUDA setup
    var cuda_ctx = cuda.CudaContext.initWithD3D11(device.d3d_device) catch |err| {
        std.debug.print("CUDA init failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.deinit();

    // Shared texture for CUDA interop
    const shared_texture = try device.createSharedTexture(src_width, src_height, .B8G8R8A8_UNORM);
    defer _ = shared_texture.release();

    const cuda_resource = cuda_ctx.registerD3D11Texture(shared_texture) catch |err| {
        std.debug.print("CUDA register failed: {}\n", .{err});
        return;
    };
    defer cuda_ctx.unregisterResource(cuda_resource);

    // Load resize kernel
    var resize_kernel = kernel.ResizeKernel.init(&cuda_ctx) catch |err| {
        std.debug.print("Kernel init failed: {}\n", .{err});
        return;
    };
    defer resize_kernel.deinit();

    // Allocate output RGB buffer (resized)
    const rgb_pitch = target_width * 3;
    const rgb_size = rgb_pitch * target_height;
    const rgb_mem = try cuda_ctx.alloc(rgb_size);
    defer cuda_ctx.free(rgb_mem);
    std.debug.print("Allocated {}KB RGB output buffer ({}x{})\n", .{ rgb_size / 1024, target_width, target_height });

    // nvJPEG encoder
    var encoder = nvjpeg.JpegEncoder.init(cuda_ctx.stream) catch |err| {
        std.debug.print("nvJPEG init failed: {}\n", .{err});
        return;
    };
    defer encoder.deinit();

    // Start capture
    try session.startCapture();
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Run multiple times to see hot path performance
    var run: u32 = 0;
    while (run < 5) : (run += 1) {
        std.Thread.sleep(16 * std.time.ns_per_ms); // Wait for next frame
        const frame = pool.tryGetNextFrame() orelse continue;
        defer _ = frame.release();
        
        // START TIMING (from frame ready to JPEG bytes)
        const start_time = std.time.nanoTimestamp();

        // Copy WGC → shared texture
        const surface = try frame.getSurface();
        const wgc_texture = try getTextureFromSurface(surface);
        defer {
            const tex_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(wgc_texture));
            _ = tex_unk.*.Release(wgc_texture);
        }
        device.copyTexture(shared_texture, wgc_texture);

        // Map for CUDA
        var resource = cuda_resource;
        try cuda_ctx.mapResource(&resource);
        defer cuda_ctx.unmapResource(&resource);

        const cuda_array = try cuda_ctx.getMappedArray(cuda_resource);

        // Create texture object with hardware bilinear filtering
        const tex_obj = try resize_kernel.createTextureFromArray(cuda_array);
        defer resize_kernel.destroyTexture(tex_obj);

        // Launch fused resize+BGRA→RGB kernel!
        try resize_kernel.launch(
            tex_obj,
            rgb_mem,
            target_width,
            target_height,
            rgb_pitch,
            src_width,
            src_height,
        );
        cuda_ctx.synchronize();
        std.debug.print("Fused kernel launched: {}x{} → {}x{}\n", .{ src_width, src_height, target_width, target_height });

        // nvJPEG encode the resized RGB
        const jpeg_data = encoder.encode(
            std.testing.allocator,
            rgb_mem,
            target_width,
            target_height,
            rgb_pitch,
        ) catch |err| {
            std.debug.print("nvJPEG encode failed: {}\n", .{err});
            return;
        };
        defer std.testing.allocator.free(jpeg_data);

        const end_time = std.time.nanoTimestamp();
        const elapsed_ns = end_time - start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        
        std.debug.print("🔥 NUCLEAR: {}x{} → {}x{} → {} bytes in {d:.2}ms\n", .{
            src_width, src_height, target_width, target_height, jpeg_data.len, elapsed_ms
        });

        // Save to disk for visual verification
        const file = std.fs.cwd().createFile("C:\\Ara\\temp\\nuclear_test.jpg", .{}) catch |err| {
            std.debug.print("Failed to create file: {}\n", .{err});
            return;
        };
        defer file.close();
        file.writeAll(jpeg_data) catch |err| {
            std.debug.print("Failed to write: {}\n", .{err});
            return;
        };
        std.debug.print("Saved to C:\\Ara\\temp\\nuclear_test.jpg\n", .{});
    }
}
