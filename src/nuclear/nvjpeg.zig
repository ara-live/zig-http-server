//! nvJPEG Bindings - GPU JPEG Encoding
//!
//! Dynamically loads nvjpeg64_*.dll from NVIDIA driver
//! Provides GPU-accelerated JPEG encoding from CUDA arrays

const std = @import("std");
const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;
const cuda = @import("cuda.zig");

// ═══════════════════════════════════════════════════════════════
//  nvJPEG Types
// ═══════════════════════════════════════════════════════════════

pub const nvjpegStatus = c_int;
pub const NVJPEG_STATUS_SUCCESS: nvjpegStatus = 0;

pub const nvjpegHandle = *opaque {};
pub const nvjpegEncoderState = *opaque {};
pub const nvjpegEncoderParams = *opaque {};

pub const nvjpegBackend = enum(c_int) {
    DEFAULT = 0,
    HYBRID = 1, // CPU + GPU hybrid
    GPU_HYBRID = 2, // GPU-focused hybrid
    HARDWARE = 3, // Hardware encoder (if available)
};

pub const nvjpegChromaSubsampling = enum(c_int) {
    CSS_444 = 0,
    CSS_422 = 1,
    CSS_420 = 2, // Most common for photos
    CSS_440 = 3,
    CSS_411 = 4,
    CSS_410 = 5,
    CSS_GRAY = 6,
    CSS_UNKNOWN = -1,
};

pub const nvjpegInputFormat = enum(c_int) {
    RGB = 3,
    BGR = 4,
    RGBI = 5, // Interleaved RGB
    BGRI = 6, // Interleaved BGR (matches BGRA after stripping alpha)
};

pub const nvjpegImage = extern struct {
    channel: [4]usize, // CUDA device pointers (NOT host pointers!)
    pitch: [4]usize,
};

// ═══════════════════════════════════════════════════════════════
//  nvJPEG Function Signatures
// ═══════════════════════════════════════════════════════════════

// Library management
const NvjpegGetPropertyFn = *const fn (c_int, *c_int) callconv(WINAPI) nvjpegStatus;
const NvjpegCreateFn = *const fn (nvjpegBackend, ?*anyopaque, *nvjpegHandle) callconv(WINAPI) nvjpegStatus;
const NvjpegDestroyFn = *const fn (nvjpegHandle) callconv(WINAPI) nvjpegStatus;

// Encoder state
const NvjpegEncoderStateCreateFn = *const fn (nvjpegHandle, *nvjpegEncoderState, cuda.CUstream) callconv(WINAPI) nvjpegStatus;
const NvjpegEncoderStateDestroyFn = *const fn (nvjpegEncoderState) callconv(WINAPI) nvjpegStatus;

// Encoder params
const NvjpegEncoderParamsCreateFn = *const fn (nvjpegHandle, *nvjpegEncoderParams, cuda.CUstream) callconv(WINAPI) nvjpegStatus;
const NvjpegEncoderParamsDestroyFn = *const fn (nvjpegEncoderParams) callconv(WINAPI) nvjpegStatus;
const NvjpegEncoderParamsSetQualityFn = *const fn (nvjpegEncoderParams, c_int, cuda.CUstream) callconv(WINAPI) nvjpegStatus;
const NvjpegEncoderParamsSetSamplingFactorsFn = *const fn (nvjpegEncoderParams, nvjpegChromaSubsampling, cuda.CUstream) callconv(WINAPI) nvjpegStatus;

// Encoding
const NvjpegEncodeImageFn = *const fn (
    nvjpegHandle,
    nvjpegEncoderState,
    nvjpegEncoderParams,
    *const nvjpegImage,
    nvjpegInputFormat,
    c_int, // width
    c_int, // height
    cuda.CUstream,
) callconv(WINAPI) nvjpegStatus;

const NvjpegEncodeRetrieveBitstreamFn = *const fn (
    nvjpegHandle,
    nvjpegEncoderState,
    ?[*]u8, // output buffer (null to query size)
    *usize, // size
    cuda.CUstream,
) callconv(WINAPI) nvjpegStatus;

// ═══════════════════════════════════════════════════════════════
//  Dynamic Loading
// ═══════════════════════════════════════════════════════════════

pub const NvjpegApi = struct {
    module: windows.HMODULE,

    // Library
    nvjpegGetProperty: NvjpegGetPropertyFn,
    nvjpegCreate: NvjpegCreateFn,
    nvjpegDestroy: NvjpegDestroyFn,

    // Encoder state
    nvjpegEncoderStateCreate: NvjpegEncoderStateCreateFn,
    nvjpegEncoderStateDestroy: NvjpegEncoderStateDestroyFn,

    // Encoder params
    nvjpegEncoderParamsCreate: NvjpegEncoderParamsCreateFn,
    nvjpegEncoderParamsDestroy: NvjpegEncoderParamsDestroyFn,
    nvjpegEncoderParamsSetQuality: NvjpegEncoderParamsSetQualityFn,
    nvjpegEncoderParamsSetSamplingFactors: NvjpegEncoderParamsSetSamplingFactorsFn,

    // Encoding
    nvjpegEncodeImage: NvjpegEncodeImageFn,
    nvjpegEncodeRetrieveBitstream: NvjpegEncodeRetrieveBitstreamFn,

    pub fn load() !NvjpegApi {
        // Try different nvJPEG DLL versions (driver ships one)
        const dll_names = [_][*:0]const u16{
            std.unicode.utf8ToUtf16LeStringLiteral("nvjpeg64_12.dll"),
            std.unicode.utf8ToUtf16LeStringLiteral("nvjpeg64_11.dll"),
            std.unicode.utf8ToUtf16LeStringLiteral("nvjpeg.dll"),
        };

        var module: ?windows.HMODULE = null;
        for (dll_names) |name| {
            module = windows.kernel32.LoadLibraryW(name);
            if (module != null) break;
        }

        if (module == null) {
            std.log.err("Failed to load nvJPEG DLL - not in driver?", .{});
            return error.NvjpegNotAvailable;
        }

        const mod = module.?;

        return NvjpegApi{
            .module = mod,
            .nvjpegGetProperty = getProc(mod, NvjpegGetPropertyFn, "nvjpegGetProperty") orelse return error.MissingSymbol,
            .nvjpegCreate = getProc(mod, NvjpegCreateFn, "nvjpegCreate") orelse return error.MissingSymbol,
            .nvjpegDestroy = getProc(mod, NvjpegDestroyFn, "nvjpegDestroy") orelse return error.MissingSymbol,
            .nvjpegEncoderStateCreate = getProc(mod, NvjpegEncoderStateCreateFn, "nvjpegEncoderStateCreate") orelse return error.MissingSymbol,
            .nvjpegEncoderStateDestroy = getProc(mod, NvjpegEncoderStateDestroyFn, "nvjpegEncoderStateDestroy") orelse return error.MissingSymbol,
            .nvjpegEncoderParamsCreate = getProc(mod, NvjpegEncoderParamsCreateFn, "nvjpegEncoderParamsCreate") orelse return error.MissingSymbol,
            .nvjpegEncoderParamsDestroy = getProc(mod, NvjpegEncoderParamsDestroyFn, "nvjpegEncoderParamsDestroy") orelse return error.MissingSymbol,
            .nvjpegEncoderParamsSetQuality = getProc(mod, NvjpegEncoderParamsSetQualityFn, "nvjpegEncoderParamsSetQuality") orelse return error.MissingSymbol,
            .nvjpegEncoderParamsSetSamplingFactors = getProc(mod, NvjpegEncoderParamsSetSamplingFactorsFn, "nvjpegEncoderParamsSetSamplingFactors") orelse return error.MissingSymbol,
            .nvjpegEncodeImage = getProc(mod, NvjpegEncodeImageFn, "nvjpegEncodeImage") orelse return error.MissingSymbol,
            .nvjpegEncodeRetrieveBitstream = getProc(mod, NvjpegEncodeRetrieveBitstreamFn, "nvjpegEncodeRetrieveBitstream") orelse return error.MissingSymbol,
        };
    }

    pub fn deinit(self: *NvjpegApi) void {
        _ = windows.kernel32.FreeLibrary(self.module);
    }
};

fn getProc(module: windows.HMODULE, comptime T: type, name: [*:0]const u8) ?T {
    const ptr = windows.kernel32.GetProcAddress(module, name) orelse return null;
    return @ptrCast(ptr);
}

// ═══════════════════════════════════════════════════════════════
//  High-Level Encoder
// ═══════════════════════════════════════════════════════════════

pub const JpegEncoder = struct {
    api: NvjpegApi,
    handle: nvjpegHandle,
    state: nvjpegEncoderState,
    params: nvjpegEncoderParams,
    stream: cuda.CUstream,

    pub fn init(cuda_stream: cuda.CUstream) !JpegEncoder {
        var api = try NvjpegApi.load();
        errdefer api.deinit();

        // Create nvJPEG handle
        var handle: nvjpegHandle = undefined;
        var status = api.nvjpegCreate(.GPU_HYBRID, null, &handle);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegCreate failed: {}", .{status});
            return error.CreateFailed;
        }
        errdefer _ = api.nvjpegDestroy(handle);

        // Create encoder state
        var state: nvjpegEncoderState = undefined;
        status = api.nvjpegEncoderStateCreate(handle, &state, cuda_stream);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegEncoderStateCreate failed: {}", .{status});
            return error.StateCreateFailed;
        }
        errdefer _ = api.nvjpegEncoderStateDestroy(state);

        // Create encoder params
        var params: nvjpegEncoderParams = undefined;
        status = api.nvjpegEncoderParamsCreate(handle, &params, cuda_stream);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegEncoderParamsCreate failed: {}", .{status});
            return error.ParamsCreateFailed;
        }
        errdefer _ = api.nvjpegEncoderParamsDestroy(params);

        // Set default quality (85)
        status = api.nvjpegEncoderParamsSetQuality(params, 85, cuda_stream);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.warn("nvjpegEncoderParamsSetQuality failed: {}", .{status});
        }

        // Set chroma subsampling (4:2:0 for good compression)
        status = api.nvjpegEncoderParamsSetSamplingFactors(params, .CSS_420, cuda_stream);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.warn("nvjpegEncoderParamsSetSamplingFactors failed: {}", .{status});
        }

        std.log.info("nvJPEG encoder initialized", .{});

        return JpegEncoder{
            .api = api,
            .handle = handle,
            .state = state,
            .params = params,
            .stream = cuda_stream,
        };
    }

    pub fn deinit(self: *JpegEncoder) void {
        _ = self.api.nvjpegEncoderParamsDestroy(self.params);
        _ = self.api.nvjpegEncoderStateDestroy(self.state);
        _ = self.api.nvjpegDestroy(self.handle);
        self.api.deinit();
    }

    pub fn setQuality(self: *JpegEncoder, quality: u8) void {
        _ = self.api.nvjpegEncoderParamsSetQuality(self.params, @intCast(quality), self.stream);
    }

    /// Encode image from GPU memory to JPEG
    /// gpu_ptr is a CUDA device pointer (NOT a host pointer)
    /// Returns allocated buffer with JPEG data (caller must free)
    pub fn encode(
        self: *JpegEncoder,
        allocator: std.mem.Allocator,
        gpu_ptr: usize, // CUDA device pointer
        width: u32,
        height: u32,
        pitch: usize,
    ) ![]u8 {
        // Set up nvjpegImage pointing to GPU memory
        // Using BGRI format (interleaved BGR) - closest to our BGRA
        var image = nvjpegImage{
            .channel = .{ gpu_ptr, 0, 0, 0 },
            .pitch = .{ pitch, 0, 0, 0 },
        };

        std.debug.print("nvjpegEncodeImage: ptr=0x{x} {}x{} pitch={}\n", .{ gpu_ptr, width, height, pitch });

        // Encode
        var status = self.api.nvjpegEncodeImage(
            self.handle,
            self.state,
            self.params,
            &image,
            .BGRI, // Interleaved BGR - expects 3 bytes per pixel!
            @intCast(width),
            @intCast(height),
            self.stream,
        );
        std.debug.print("nvjpegEncodeImage returned: {}\n", .{status});
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegEncodeImage failed: {}", .{status});
            return error.EncodeFailed;
        }

        // Sync stream before retrieving
        // Note: We need cuStreamSynchronize here, but we don't have the CUDA API in this module
        // The caller should sync before calling encode, or we need to add sync to JpegEncoder

        // Query output size - pass null to get size only
        var size: usize = 0;
        status = self.api.nvjpegEncodeRetrieveBitstream(self.handle, self.state, null, &size, self.stream);
        std.debug.print("nvjpegEncodeRetrieveBitstream (query): status={} size={}\n", .{ status, size });
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegEncodeRetrieveBitstream (query) failed: {}", .{status});
            return error.RetrieveFailed;
        }

        // Allocate and retrieve
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        status = self.api.nvjpegEncodeRetrieveBitstream(self.handle, self.state, buffer.ptr, &size, self.stream);
        if (status != NVJPEG_STATUS_SUCCESS) {
            std.log.err("nvjpegEncodeRetrieveBitstream failed: {}", .{status});
            return error.RetrieveFailed;
        }

        return buffer[0..size];
    }
};

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

test "load nvJPEG API" {
    var api = NvjpegApi.load() catch |err| {
        std.debug.print("nvJPEG not available: {}\n", .{err});
        return; // Skip if not available
    };
    defer api.deinit();

    // Query version
    var major: c_int = 0;
    var minor: c_int = 0;
    _ = api.nvjpegGetProperty(0, &major); // MAJOR_VERSION = 0
    _ = api.nvjpegGetProperty(1, &minor); // MINOR_VERSION = 1

    std.debug.print("nvJPEG version: {}.{}\n", .{ major, minor });
}

test "create encoder" {
    // Need CUDA context first
    var cuda_ctx = cuda.CudaContext.init() catch |err| {
        std.debug.print("CUDA not available: {}\n", .{err});
        return;
    };
    defer cuda_ctx.deinit();

    var encoder = JpegEncoder.init(cuda_ctx.stream) catch |err| {
        std.debug.print("nvJPEG encoder init failed: {}\n", .{err});
        return;
    };
    defer encoder.deinit();

    std.debug.print("nvJPEG encoder created successfully\n", .{});
}
