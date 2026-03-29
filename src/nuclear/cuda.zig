//! CUDA Runtime Bindings for D3D11 Interop + nvJPEG
//!
//! Dynamically loads nvcuda.dll and nvjpeg64_*.dll
//! No CUDA toolkit required — uses driver API + shipped DLLs

const std = @import("std");
const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;

// ═══════════════════════════════════════════════════════════════
//  CUDA Types
// ═══════════════════════════════════════════════════════════════

pub const CUresult = c_int;
pub const CUdevice = c_int;
pub const CUcontext = *opaque {};
pub const CUstream = ?*opaque {};
pub const CUgraphicsResource = *opaque {};
pub const CUarray = *opaque {};

pub const CUDA_SUCCESS: CUresult = 0;

// D3D11 interop flags
pub const CU_GRAPHICS_REGISTER_FLAGS_NONE: c_uint = 0;
pub const CU_GRAPHICS_REGISTER_FLAGS_READ_ONLY: c_uint = 1;
pub const CU_GRAPHICS_REGISTER_FLAGS_SURFACE_LDST: c_uint = 4;
pub const CU_GRAPHICS_MAP_RESOURCE_FLAGS_NONE: c_uint = 0;

// ═══════════════════════════════════════════════════════════════
//  CUDA Driver API Function Signatures
// ═══════════════════════════════════════════════════════════════

const CuInitFn = *const fn (c_uint) callconv(WINAPI) CUresult;
const CuDeviceGetFn = *const fn (*CUdevice, c_int) callconv(WINAPI) CUresult;
const CuCtxCreateFn = *const fn (*CUcontext, c_uint, CUdevice) callconv(WINAPI) CUresult;
const CuCtxDestroyFn = *const fn (CUcontext) callconv(WINAPI) CUresult;
const CuCtxSetCurrentFn = *const fn (CUcontext) callconv(WINAPI) CUresult;
const CuStreamCreateFn = *const fn (*CUstream, c_uint) callconv(WINAPI) CUresult;
const CuStreamDestroyFn = *const fn (CUstream) callconv(WINAPI) CUresult;
const CuStreamSynchronizeFn = *const fn (CUstream) callconv(WINAPI) CUresult;
const CuMemAllocFn = *const fn (*usize, usize) callconv(WINAPI) CUresult;
const CuMemFreeFn = *const fn (usize) callconv(WINAPI) CUresult;
const CuMemcpyDtoHFn = *const fn (*anyopaque, usize, usize) callconv(WINAPI) CUresult;

// Copy from array to device memory
pub const CUDA_MEMCPY2D = extern struct {
    srcXInBytes: usize,
    srcY: usize,
    srcMemoryType: c_uint, // CU_MEMORYTYPE_*
    srcHost: ?*const anyopaque,
    srcDevice: usize,
    srcArray: ?CUarray,
    srcPitch: usize,
    dstXInBytes: usize,
    dstY: usize,
    dstMemoryType: c_uint,
    dstHost: ?*anyopaque,
    dstDevice: usize,
    dstArray: ?CUarray,
    dstPitch: usize,
    WidthInBytes: usize,
    Height: usize,
};

pub const CU_MEMORYTYPE_HOST: c_uint = 1;
pub const CU_MEMORYTYPE_DEVICE: c_uint = 2;
pub const CU_MEMORYTYPE_ARRAY: c_uint = 3;

const CuMemcpy2DFn = *const fn (*const CUDA_MEMCPY2D) callconv(WINAPI) CUresult;

// D3D11 Interop
const CuGraphicsD3D11RegisterResourceFn = *const fn (
    *CUgraphicsResource,
    *anyopaque, // ID3D11Resource*
    c_uint, // flags
) callconv(WINAPI) CUresult;

const CuGraphicsUnregisterResourceFn = *const fn (CUgraphicsResource) callconv(WINAPI) CUresult;

const CuGraphicsMapResourcesFn = *const fn (
    c_uint, // count
    *CUgraphicsResource,
    CUstream,
) callconv(WINAPI) CUresult;

const CuGraphicsUnmapResourcesFn = *const fn (
    c_uint,
    *CUgraphicsResource,
    CUstream,
) callconv(WINAPI) CUresult;

const CuGraphicsSubResourceGetMappedArrayFn = *const fn (
    *CUarray,
    CUgraphicsResource,
    c_uint, // arrayIndex
    c_uint, // mipLevel
) callconv(WINAPI) CUresult;

// Get CUDA device for a D3D11 device
const CuD3D11GetDeviceFn = *const fn (
    *CUdevice,
    *anyopaque, // IDXGIAdapter*
) callconv(WINAPI) CUresult;

// Create context for D3D11 interop
const CuD3D11CtxCreateFn = *const fn (
    *CUcontext,
    *CUdevice,
    c_uint, // flags
    *anyopaque, // ID3D11Device*
) callconv(WINAPI) CUresult;

// ═══════════════════════════════════════════════════════════════
//  Dynamic Loading
// ═══════════════════════════════════════════════════════════════

pub const CudaApi = struct {
    module: windows.HMODULE,
    
    // Core
    cuInit: CuInitFn,
    cuDeviceGet: CuDeviceGetFn,
    cuCtxCreate: CuCtxCreateFn,
    cuCtxDestroy: CuCtxDestroyFn,
    cuCtxSetCurrent: CuCtxSetCurrentFn,
    cuStreamCreate: CuStreamCreateFn,
    cuStreamDestroy: CuStreamDestroyFn,
    cuStreamSynchronize: CuStreamSynchronizeFn,
    cuMemAlloc: CuMemAllocFn,
    cuMemFree: CuMemFreeFn,
    cuMemcpyDtoH: CuMemcpyDtoHFn,
    cuMemcpy2D: CuMemcpy2DFn,
    
    // D3D11 Interop
    cuGraphicsD3D11RegisterResource: CuGraphicsD3D11RegisterResourceFn,
    cuGraphicsUnregisterResource: CuGraphicsUnregisterResourceFn,
    cuGraphicsMapResources: CuGraphicsMapResourcesFn,
    cuGraphicsUnmapResources: CuGraphicsUnmapResourcesFn,
    cuGraphicsSubResourceGetMappedArray: CuGraphicsSubResourceGetMappedArrayFn,
    cuD3D11GetDevice: CuD3D11GetDeviceFn,
    cuD3D11CtxCreate: ?CuD3D11CtxCreateFn, // Optional - may not exist in older drivers

    pub fn load() !CudaApi {
        const module = windows.kernel32.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("nvcuda.dll")) orelse {
            std.log.err("Failed to load nvcuda.dll - is NVIDIA driver installed?", .{});
            return error.CudaNotAvailable;
        };

        return CudaApi{
            .module = module,
            .cuInit = getProc(module, CuInitFn, "cuInit") orelse return error.MissingSymbol,
            .cuDeviceGet = getProc(module, CuDeviceGetFn, "cuDeviceGet") orelse return error.MissingSymbol,
            .cuCtxCreate = getProc(module, CuCtxCreateFn, "cuCtxCreate_v2") orelse return error.MissingSymbol,
            .cuCtxDestroy = getProc(module, CuCtxDestroyFn, "cuCtxDestroy_v2") orelse return error.MissingSymbol,
            .cuCtxSetCurrent = getProc(module, CuCtxSetCurrentFn, "cuCtxSetCurrent") orelse return error.MissingSymbol,
            .cuStreamCreate = getProc(module, CuStreamCreateFn, "cuStreamCreate") orelse return error.MissingSymbol,
            .cuStreamDestroy = getProc(module, CuStreamDestroyFn, "cuStreamDestroy_v2") orelse return error.MissingSymbol,
            .cuStreamSynchronize = getProc(module, CuStreamSynchronizeFn, "cuStreamSynchronize") orelse return error.MissingSymbol,
            .cuMemAlloc = getProc(module, CuMemAllocFn, "cuMemAlloc_v2") orelse return error.MissingSymbol,
            .cuMemFree = getProc(module, CuMemFreeFn, "cuMemFree_v2") orelse return error.MissingSymbol,
            .cuMemcpyDtoH = getProc(module, CuMemcpyDtoHFn, "cuMemcpyDtoH_v2") orelse return error.MissingSymbol,
            .cuMemcpy2D = getProc(module, CuMemcpy2DFn, "cuMemcpy2D_v2") orelse return error.MissingSymbol,
            .cuGraphicsD3D11RegisterResource = getProc(module, CuGraphicsD3D11RegisterResourceFn, "cuGraphicsD3D11RegisterResource") orelse return error.MissingSymbol,
            .cuGraphicsUnregisterResource = getProc(module, CuGraphicsUnregisterResourceFn, "cuGraphicsUnregisterResource") orelse return error.MissingSymbol,
            .cuGraphicsMapResources = getProc(module, CuGraphicsMapResourcesFn, "cuGraphicsMapResources") orelse return error.MissingSymbol,
            .cuGraphicsUnmapResources = getProc(module, CuGraphicsUnmapResourcesFn, "cuGraphicsUnmapResources") orelse return error.MissingSymbol,
            .cuGraphicsSubResourceGetMappedArray = getProc(module, CuGraphicsSubResourceGetMappedArrayFn, "cuGraphicsSubResourceGetMappedArray") orelse return error.MissingSymbol,
            .cuD3D11GetDevice = getProc(module, CuD3D11GetDeviceFn, "cuD3D11GetDevice") orelse return error.MissingSymbol,
            .cuD3D11CtxCreate = getProc(module, CuD3D11CtxCreateFn, "cuD3D11CtxCreate"), // Optional
        };
    }

    pub fn deinit(self: *CudaApi) void {
        _ = windows.kernel32.FreeLibrary(self.module);
    }
};

fn getProc(module: windows.HMODULE, comptime T: type, name: [*:0]const u8) ?T {
    const ptr = windows.kernel32.GetProcAddress(module, name) orelse return null;
    return @ptrCast(ptr);
}

// ═══════════════════════════════════════════════════════════════
//  High-Level Wrapper
// ═══════════════════════════════════════════════════════════════

pub const CudaContext = struct {
    api: CudaApi,
    device: CUdevice,
    context: CUcontext,
    stream: CUstream,

    /// Initialize CUDA with D3D11 device interop
    /// This ensures CUDA uses the same GPU as the D3D11 device
    pub fn initWithD3D11(d3d_device: *anyopaque) !CudaContext {
        var api = try CudaApi.load();
        errdefer api.deinit();

        // Initialize CUDA
        var result = api.cuInit(0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuInit failed: {}", .{result});
            return error.CudaInitFailed;
        }

        // Get the DXGI adapter from D3D11 device
        // First QI for IDXGIDevice
        const IID_IDXGIDevice = @import("d3d11.zig").IID_IDXGIDevice;
        const unk: *const *const @import("d3d11.zig").IUnknownVtbl = @ptrCast(@alignCast(d3d_device));
        var dxgi_device: ?*anyopaque = null;
        var hr = unk.*.QueryInterface(d3d_device, &IID_IDXGIDevice, &dxgi_device);
        if (hr < 0) {
            std.log.err("QI for IDXGIDevice failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.QueryInterfaceFailed;
        }

        // Get adapter from DXGI device
        // IDXGIDevice::GetAdapter is vtable index 7 (after IUnknown + 4 DXGI methods)
        const IDXGIDeviceVtbl = extern struct {
            QueryInterface: *const fn (*anyopaque, *const @import("d3d11.zig").GUID, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
            AddRef: *const fn (*anyopaque) callconv(WINAPI) u32,
            Release: *const fn (*anyopaque) callconv(WINAPI) u32,
            GetParent: *const anyopaque,
            GetPrivateData: *const anyopaque,
            SetPrivateData: *const anyopaque,
            SetPrivateDataInterface: *const anyopaque,
            GetAdapter: *const fn (*anyopaque, *?*anyopaque) callconv(WINAPI) windows.HRESULT,
        };
        const dxgi_vtbl: *const *const IDXGIDeviceVtbl = @ptrCast(@alignCast(dxgi_device.?));
        var adapter: ?*anyopaque = null;
        hr = dxgi_vtbl.*.GetAdapter(dxgi_device.?, &adapter);

        // Release DXGI device ref
        const dxgi_unk: *const *const @import("d3d11.zig").IUnknownVtbl = @ptrCast(@alignCast(dxgi_device.?));
        _ = dxgi_unk.*.Release(dxgi_device.?);

        if (hr < 0) {
            std.log.err("GetAdapter failed: 0x{X:0>8}", .{@as(u32, @bitCast(hr))});
            return error.GetAdapterFailed;
        }
        defer {
            const adp_unk: *const *const @import("d3d11.zig").IUnknownVtbl = @ptrCast(@alignCast(adapter.?));
            _ = adp_unk.*.Release(adapter.?);
        }

        // Try cuD3D11GetDevice first
        var device: CUdevice = undefined;
        result = api.cuD3D11GetDevice(&device, adapter.?);
        if (result != CUDA_SUCCESS) {
            // Blackwell/sm_120 may have D3D11 interop issues - fall back to device 0
            std.log.warn("cuD3D11GetDevice failed: {}, trying device 0 directly", .{result});
            result = api.cuDeviceGet(&device, 0);
            if (result != CUDA_SUCCESS) {
                std.log.err("cuDeviceGet(0) also failed: {}", .{result});
                return error.CudaDeviceNotFound;
            }
        }
        std.log.info("CUDA device for D3D11 adapter: {}", .{device});

        // Create context on this device
        var context: CUcontext = undefined;
        result = api.cuCtxCreate(&context, 0, device);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuCtxCreate failed: {}", .{result});
            return error.CudaContextFailed;
        }
        errdefer _ = api.cuCtxDestroy(context);

        // Create stream
        var stream: CUstream = null;
        result = api.cuStreamCreate(&stream, 0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuStreamCreate failed: {}", .{result});
            return error.CudaStreamFailed;
        }

        std.log.info("CUDA D3D11 interop initialized: device={}", .{device});

        return CudaContext{
            .api = api,
            .device = device,
            .context = context,
            .stream = stream,
        };
    }

    pub fn init() !CudaContext {
        var api = try CudaApi.load();
        errdefer api.deinit();

        // Initialize CUDA
        var result = api.cuInit(0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuInit failed: {}", .{result});
            return error.CudaInitFailed;
        }

        // Get device 0
        var device: CUdevice = undefined;
        result = api.cuDeviceGet(&device, 0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuDeviceGet failed: {}", .{result});
            return error.CudaDeviceNotFound;
        }

        // Create context
        var context: CUcontext = undefined;
        result = api.cuCtxCreate(&context, 0, device);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuCtxCreate failed: {}", .{result});
            return error.CudaContextFailed;
        }
        errdefer _ = api.cuCtxDestroy(context);

        // Create stream
        var stream: CUstream = null;
        result = api.cuStreamCreate(&stream, 0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuStreamCreate failed: {}", .{result});
            return error.CudaStreamFailed;
        }

        std.log.info("CUDA initialized: device={}", .{device});

        return CudaContext{
            .api = api,
            .device = device,
            .context = context,
            .stream = stream,
        };
    }

    pub fn deinit(self: *CudaContext) void {
        if (self.stream) |s| {
            _ = self.api.cuStreamDestroy(s);
        }
        _ = self.api.cuCtxDestroy(self.context);
        self.api.deinit();
    }

    /// Register a D3D11 texture for CUDA access
    pub fn registerD3D11Texture(self: *CudaContext, texture: *anyopaque) !CUgraphicsResource {
        return self.registerD3D11TextureWithFlags(texture, CU_GRAPHICS_REGISTER_FLAGS_NONE);
    }

    /// Register a D3D11 texture with specific flags
    pub fn registerD3D11TextureWithFlags(self: *CudaContext, texture: *anyopaque, flags: c_uint) !CUgraphicsResource {
        var resource: CUgraphicsResource = undefined;
        const result = self.api.cuGraphicsD3D11RegisterResource(
            &resource,
            texture,
            flags,
        );
        if (result != CUDA_SUCCESS) {
            std.log.err("cuGraphicsD3D11RegisterResource failed: {} (flags={})", .{ result, flags });
            return error.RegisterFailed;
        }
        return resource;
    }

    pub fn unregisterResource(self: *CudaContext, resource: CUgraphicsResource) void {
        _ = self.api.cuGraphicsUnregisterResource(resource);
    }

    /// Map a registered resource for CUDA access
    pub fn mapResource(self: *CudaContext, resource: *CUgraphicsResource) !void {
        const result = self.api.cuGraphicsMapResources(1, resource, self.stream);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuGraphicsMapResources failed: {}", .{result});
            return error.MapFailed;
        }
    }

    pub fn unmapResource(self: *CudaContext, resource: *CUgraphicsResource) void {
        _ = self.api.cuGraphicsUnmapResources(1, resource, self.stream);
    }

    /// Get the CUDA array from a mapped resource
    pub fn getMappedArray(self: *CudaContext, resource: CUgraphicsResource) !CUarray {
        var array: CUarray = undefined;
        const result = self.api.cuGraphicsSubResourceGetMappedArray(&array, resource, 0, 0);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuGraphicsSubResourceGetMappedArray failed: {}", .{result});
            return error.GetArrayFailed;
        }
        return array;
    }

    pub fn synchronize(self: *CudaContext) void {
        if (self.stream) |s| {
            _ = self.api.cuStreamSynchronize(s);
        }
    }

    /// Allocate device memory
    pub fn alloc(self: *CudaContext, size: usize) !usize {
        var ptr: usize = 0;
        const result = self.api.cuMemAlloc(&ptr, size);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuMemAlloc failed: {}", .{result});
            return error.AllocFailed;
        }
        return ptr;
    }

    /// Free device memory
    pub fn free(self: *CudaContext, ptr: usize) void {
        _ = self.api.cuMemFree(ptr);
    }

    /// Copy from CUDA array to device memory (for nvJPEG)
    pub fn copyArrayToDevice(self: *CudaContext, dst: usize, dst_pitch: usize, src: CUarray, width: u32, height: u32, bytes_per_pixel: u32) !void {
        const copy_params = CUDA_MEMCPY2D{
            .srcXInBytes = 0,
            .srcY = 0,
            .srcMemoryType = CU_MEMORYTYPE_ARRAY,
            .srcHost = null,
            .srcDevice = 0,
            .srcArray = src,
            .srcPitch = 0, // Not used for array source
            .dstXInBytes = 0,
            .dstY = 0,
            .dstMemoryType = CU_MEMORYTYPE_DEVICE,
            .dstHost = null,
            .dstDevice = dst,
            .dstArray = null,
            .dstPitch = dst_pitch,
            .WidthInBytes = width * bytes_per_pixel,
            .Height = height,
        };

        const result = self.api.cuMemcpy2D(&copy_params);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuMemcpy2D failed: {}", .{result});
            return error.CopyFailed;
        }
    }

    /// Copy device memory to host
    pub fn copyToHost(self: *CudaContext, dst: *anyopaque, src: usize, size: usize) !void {
        const result = self.api.cuMemcpyDtoH(dst, src, size);
        if (result != CUDA_SUCCESS) {
            std.log.err("cuMemcpyDtoH failed: {}", .{result});
            return error.CopyFailed;
        }
    }
};

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

test "load CUDA API" {
    var ctx = CudaContext.init() catch |err| {
        std.debug.print("CUDA not available: {}\n", .{err});
        return; // Skip test if no CUDA
    };
    defer ctx.deinit();

    std.debug.print("CUDA device: {}\n", .{ctx.device});
}
