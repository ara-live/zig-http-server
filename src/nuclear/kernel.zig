//! CUDA Kernel Management - PTX loading and launching
//!
//! Embeds the bgra_to_rgb_resize kernel as PTX and provides launch interface.

const std = @import("std");
const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;
const cuda = @import("cuda.zig");

// ═══════════════════════════════════════════════════════════════
//  Embedded PTX
// ═══════════════════════════════════════════════════════════════

const bgra_to_rgb_resize_ptx = @embedFile("kernels/bgra_to_rgb_resize.ptx");

// ═══════════════════════════════════════════════════════════════
//  CUDA Module/Function Types
// ═══════════════════════════════════════════════════════════════

pub const CUmodule = *opaque {};
pub const CUfunction = *opaque {};
pub const CUtexObject = u64;

// Texture descriptor structures
pub const CUDA_RESOURCE_DESC = extern struct {
    resType: c_uint, // CU_RESOURCE_TYPE_*
    res: extern union {
        array: extern struct {
            hArray: cuda.CUarray,
        },
        linear: extern struct {
            devPtr: usize,
            format: c_uint,
            numChannels: c_uint,
            sizeInBytes: usize,
        },
        pitch2D: extern struct {
            devPtr: usize,
            format: c_uint,
            numChannels: c_uint,
            width: usize,
            height: usize,
            pitchInBytes: usize,
        },
    },
    flags: c_uint,
};

pub const CUDA_TEXTURE_DESC = extern struct {
    addressMode: [3]c_uint, // CU_TR_ADDRESS_MODE_*
    filterMode: c_uint, // CU_TR_FILTER_MODE_*
    flags: c_uint,
    maxAnisotropy: c_uint,
    mipmapFilterMode: c_uint,
    mipmapLevelBias: f32,
    minMipmapLevelClamp: f32,
    maxMipmapLevelClamp: f32,
    borderColor: [4]f32,
    reserved: [12]c_int,
};

pub const CU_RESOURCE_TYPE_ARRAY: c_uint = 0;
pub const CU_RESOURCE_TYPE_LINEAR: c_uint = 2;
pub const CU_RESOURCE_TYPE_PITCH2D: c_uint = 3;

pub const CU_TR_ADDRESS_MODE_CLAMP: c_uint = 1;
pub const CU_TR_FILTER_MODE_POINT: c_uint = 0;
pub const CU_TR_FILTER_MODE_LINEAR: c_uint = 1;

pub const CU_AD_FORMAT_UNSIGNED_INT8: c_uint = 0x01;
pub const CU_AD_FORMAT_FLOAT: c_uint = 0x20;

// ═══════════════════════════════════════════════════════════════
//  Additional CUDA API Functions
// ═══════════════════════════════════════════════════════════════

const CuModuleLoadDataFn = *const fn (*CUmodule, [*]const u8) callconv(WINAPI) cuda.CUresult;
const CuModuleUnloadFn = *const fn (CUmodule) callconv(WINAPI) cuda.CUresult;
const CuModuleGetFunctionFn = *const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(WINAPI) cuda.CUresult;

const CuLaunchKernelFn = *const fn (
    CUfunction,
    c_uint, c_uint, c_uint, // grid dim
    c_uint, c_uint, c_uint, // block dim
    c_uint, // shared mem
    cuda.CUstream,
    ?[*]?*anyopaque, // kernel params
    ?[*]?*anyopaque, // extra
) callconv(WINAPI) cuda.CUresult;

const CuTexObjectCreateFn = *const fn (
    *CUtexObject,
    *const CUDA_RESOURCE_DESC,
    *const CUDA_TEXTURE_DESC,
    ?*const anyopaque, // resource view (null)
) callconv(WINAPI) cuda.CUresult;

const CuTexObjectDestroyFn = *const fn (CUtexObject) callconv(WINAPI) cuda.CUresult;

// ═══════════════════════════════════════════════════════════════
//  Kernel API
// ═══════════════════════════════════════════════════════════════

pub const KernelApi = struct {
    cuModuleLoadData: CuModuleLoadDataFn,
    cuModuleUnload: CuModuleUnloadFn,
    cuModuleGetFunction: CuModuleGetFunctionFn,
    cuLaunchKernel: CuLaunchKernelFn,
    cuTexObjectCreate: CuTexObjectCreateFn,
    cuTexObjectDestroy: CuTexObjectDestroyFn,

    pub fn load(cuda_module: windows.HMODULE) !KernelApi {
        return KernelApi{
            .cuModuleLoadData = getProc(cuda_module, CuModuleLoadDataFn, "cuModuleLoadData") orelse return error.MissingSymbol,
            .cuModuleUnload = getProc(cuda_module, CuModuleUnloadFn, "cuModuleUnload") orelse return error.MissingSymbol,
            .cuModuleGetFunction = getProc(cuda_module, CuModuleGetFunctionFn, "cuModuleGetFunction") orelse return error.MissingSymbol,
            .cuLaunchKernel = getProc(cuda_module, CuLaunchKernelFn, "cuLaunchKernel") orelse return error.MissingSymbol,
            .cuTexObjectCreate = getProc(cuda_module, CuTexObjectCreateFn, "cuTexObjectCreate") orelse return error.MissingSymbol,
            .cuTexObjectDestroy = getProc(cuda_module, CuTexObjectDestroyFn, "cuTexObjectDestroy") orelse return error.MissingSymbol,
        };
    }
};

fn getProc(module: windows.HMODULE, comptime T: type, name: [*:0]const u8) ?T {
    const ptr = windows.kernel32.GetProcAddress(module, name) orelse return null;
    return @ptrCast(ptr);
}

// ═══════════════════════════════════════════════════════════════
//  Resize Kernel Wrapper
// ═══════════════════════════════════════════════════════════════

pub const ResizeKernel = struct {
    api: KernelApi,
    module: CUmodule,
    function: CUfunction,
    stream: cuda.CUstream,

    pub fn init(cuda_ctx: *cuda.CudaContext) !ResizeKernel {
        var api = try KernelApi.load(cuda_ctx.api.module);

        // Load PTX module
        var module: CUmodule = undefined;
        var result = api.cuModuleLoadData(&module, bgra_to_rgb_resize_ptx.ptr);
        if (result != cuda.CUDA_SUCCESS) {
            std.log.err("cuModuleLoadData failed: {}", .{result});
            return error.ModuleLoadFailed;
        }
        errdefer _ = api.cuModuleUnload(module);

        // Get kernel function
        var function: CUfunction = undefined;
        result = api.cuModuleGetFunction(&function, module, "bgra_to_rgb_resize");
        if (result != cuda.CUDA_SUCCESS) {
            std.log.err("cuModuleGetFunction failed: {}", .{result});
            return error.GetFunctionFailed;
        }

        std.log.info("Resize kernel loaded from PTX", .{});

        return ResizeKernel{
            .api = api,
            .module = module,
            .function = function,
            .stream = cuda_ctx.stream,
        };
    }

    pub fn deinit(self: *ResizeKernel) void {
        _ = self.api.cuModuleUnload(self.module);
    }

    /// Create a texture object for the source CUDA array
    pub fn createTextureFromArray(self: *ResizeKernel, array: cuda.CUarray) !CUtexObject {
        var res_desc = std.mem.zeroes(CUDA_RESOURCE_DESC);
        res_desc.resType = CU_RESOURCE_TYPE_ARRAY;
        res_desc.res.array.hArray = array;

        var tex_desc = std.mem.zeroes(CUDA_TEXTURE_DESC);
        tex_desc.addressMode = .{ CU_TR_ADDRESS_MODE_CLAMP, CU_TR_ADDRESS_MODE_CLAMP, CU_TR_ADDRESS_MODE_CLAMP };
        tex_desc.filterMode = CU_TR_FILTER_MODE_LINEAR; // Hardware bilinear!
        tex_desc.flags = 0; // Use unnormalized (pixel) coordinates

        var tex_obj: CUtexObject = 0;
        const result = self.api.cuTexObjectCreate(&tex_obj, &res_desc, &tex_desc, null);
        if (result != cuda.CUDA_SUCCESS) {
            std.log.err("cuTexObjectCreate failed: {}", .{result});
            return error.TextureCreateFailed;
        }

        return tex_obj;
    }

    pub fn destroyTexture(self: *ResizeKernel, tex_obj: CUtexObject) void {
        _ = self.api.cuTexObjectDestroy(tex_obj);
    }

    /// Launch the fused resize + BGRA→RGB kernel
    pub fn launch(
        self: *ResizeKernel,
        tex_obj: CUtexObject,
        dst: usize,
        dst_width: u32,
        dst_height: u32,
        dst_pitch: usize,
        src_width: u32,
        src_height: u32,
    ) !void {
        // Calculate scale factors
        const scale_x: f32 = @as(f32, @floatFromInt(src_width)) / @as(f32, @floatFromInt(dst_width));
        const scale_y: f32 = @as(f32, @floatFromInt(src_height)) / @as(f32, @floatFromInt(dst_height));

        // Kernel arguments (must be pointers to values)
        var arg_tex = tex_obj;
        var arg_dst = dst;
        var arg_width: c_int = @intCast(dst_width);
        var arg_height: c_int = @intCast(dst_height);
        var arg_pitch = dst_pitch;
        var arg_scale_x = scale_x;
        var arg_scale_y = scale_y;

        var args = [_]?*anyopaque{
            @ptrCast(&arg_tex),
            @ptrCast(&arg_dst),
            @ptrCast(&arg_width),
            @ptrCast(&arg_height),
            @ptrCast(&arg_pitch),
            @ptrCast(&arg_scale_x),
            @ptrCast(&arg_scale_y),
        };

        // Grid/block dimensions
        const block_x: c_uint = 16;
        const block_y: c_uint = 16;
        const grid_x: c_uint = (dst_width + block_x - 1) / block_x;
        const grid_y: c_uint = (dst_height + block_y - 1) / block_y;

        const result = self.api.cuLaunchKernel(
            self.function,
            grid_x, grid_y, 1,
            block_x, block_y, 1,
            0, // shared mem
            self.stream,
            &args,
            null,
        );

        if (result != cuda.CUDA_SUCCESS) {
            std.log.err("cuLaunchKernel failed: {}", .{result});
            return error.LaunchFailed;
        }
    }
};

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

test "load resize kernel" {
    var ctx = cuda.CudaContext.init() catch |err| {
        std.debug.print("CUDA not available: {}\n", .{err});
        return;
    };
    defer ctx.deinit();

    var kernel = ResizeKernel.init(&ctx) catch |err| {
        std.debug.print("Kernel load failed: {}\n", .{err});
        return;
    };
    defer kernel.deinit();

    std.debug.print("Resize kernel loaded successfully!\n", .{});
}
