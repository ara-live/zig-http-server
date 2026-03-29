/// Nuclear GPU capture pipeline - sub-ms window capture to JPEG
///
/// Wraps the ScreenMaster Zig modules for use as the eyes backend.
/// Zero CPU pixel processing - everything happens on GPU.
///
const std = @import("std");
const log = std.log.scoped(.nuclear);

// Nuclear modules from ScreenMaster
const d3d11 = @import("nuclear/d3d11.zig");
const wgc = @import("nuclear/wgc.zig");
const cuda = @import("nuclear/cuda.zig");
const nvjpeg = @import("nuclear/nvjpeg.zig");
const kernel = @import("nuclear/kernel.zig");

// ═══════════════════════════════════════════════════════════════
//  Global Pipeline State
// ═══════════════════════════════════════════════════════════════

const MAX_SESSIONS = 64;

/// Per-window capture session
const WindowSession = struct {
    hwnd: usize,
    pool: *wgc.IDirect3D11CaptureFramePool,
    session: *wgc.IGraphicsCaptureSession,
    item: *wgc.IGraphicsCaptureItem,
    d3d_device: *anyopaque, // IDirect3DDevice from WinRT
    shared_texture: *d3d11.ID3D11Texture2D,
    cuda_resource: cuda.CUgraphicsResource,
    src_width: u32,
    src_height: u32,
    last_used: i64,
    active: bool,

    fn deinit(self: *WindowSession, pipeline: *Pipeline) void {
        _ = self.session.release();
        _ = self.pool.release();
        _ = self.item.release();
        // Release the IDirect3DDevice (IUnknown)
        const dev_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(self.d3d_device));
        _ = dev_unk.*.Release(self.d3d_device);
        pipeline.cuda_ctx.unregisterResource(self.cuda_resource);
        _ = self.shared_texture.release();
        self.active = false;
    }
};

/// Global capture pipeline state
pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    
    // D3D11 + CUDA
    device: d3d11.Device,
    cuda_ctx: cuda.CudaContext,
    resize_kernel: kernel.ResizeKernel,
    encoder: nvjpeg.JpegEncoder,
    
    // Target output size (Anthropic limit)
    target_width: u32 = 1568,
    target_height: u32 = 882,
    
    // Output buffer (allocated once, reused)
    rgb_mem: usize, // CUdeviceptr is just usize
    rgb_pitch: usize,
    rgb_size: usize,
    
    // Per-window sessions
    sessions: [MAX_SESSIONS]WindowSession = undefined,
    session_count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    
    // Factory (cached)
    factory: *wgc.IDirect3D11CaptureFramePoolStatics,
    
    pub fn init(allocator: std.mem.Allocator, target_width: u32, target_height: u32) !*Pipeline {
        var self = try allocator.create(Pipeline);
        errdefer allocator.destroy(self);
        
        self.* = .{
            .allocator = allocator,
            .device = undefined,
            .cuda_ctx = undefined,
            .resize_kernel = undefined,
            .encoder = undefined,
            .target_width = target_width,
            .target_height = target_height,
            .rgb_mem = undefined,
            .rgb_pitch = undefined,
            .rgb_size = undefined,
            .factory = undefined,
        };
        
        // D3D11 device
        self.device = try d3d11.Device.create();
        errdefer self.device.deinit();
        
        // CUDA context with D3D11 interop
        self.cuda_ctx = try cuda.CudaContext.initWithD3D11(self.device.d3d_device);
        errdefer self.cuda_ctx.deinit();
        
        // Resize kernel (PTX embedded)
        self.resize_kernel = try kernel.ResizeKernel.init(&self.cuda_ctx);
        errdefer self.resize_kernel.deinit();
        
        // nvJPEG encoder
        self.encoder = try nvjpeg.JpegEncoder.init(self.cuda_ctx.stream);
        errdefer self.encoder.deinit();
        
        // Allocate output RGB buffer
        self.rgb_pitch = target_width * 3;
        self.rgb_size = self.rgb_pitch * target_height;
        self.rgb_mem = try self.cuda_ctx.alloc(self.rgb_size);
        errdefer self.cuda_ctx.free(self.rgb_mem);
        
        // WGC factory
        self.factory = try wgc.getFramePoolFactory();
        
        log.info("Nuclear pipeline initialized: target {}x{}, {}KB RGB buffer", .{
            target_width, target_height, self.rgb_size / 1024
        });
        
        return self;
    }
    
    pub fn deinit(self: *Pipeline) void {
        // Clean up sessions
        for (0..self.session_count) |i| {
            if (self.sessions[i].active) {
                self.sessions[i].deinit(self);
            }
        }
        
        _ = self.factory.release();
        self.cuda_ctx.free(self.rgb_mem);
        self.encoder.deinit();
        self.resize_kernel.deinit();
        self.cuda_ctx.deinit();
        self.device.deinit();
        self.allocator.destroy(self);
    }
    
    /// Get or create a capture session for a window
    fn getSession(self: *Pipeline, hwnd: usize) !*WindowSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check for existing session
        for (self.sessions[0..self.session_count]) |*session| {
            if (session.hwnd == hwnd and session.active) {
                session.last_used = std.time.timestamp();
                return session;
            }
        }
        
        // Create new session
        const slot = blk: {
            // Find inactive slot or expand
            for (self.sessions[0..self.session_count]) |*session| {
                if (!session.active) break :blk session;
            }
            if (self.session_count < MAX_SESSIONS) {
                self.session_count += 1;
                break :blk &self.sessions[self.session_count - 1];
            }
            // Evict oldest
            var oldest: *WindowSession = &self.sessions[0];
            for (self.sessions[1..self.session_count]) |*session| {
                if (session.last_used < oldest.last_used) {
                    oldest = session;
                }
            }
            oldest.deinit(self);
            break :blk oldest;
        };
        
        // WGC setup
        const item = try wgc.createCaptureItemForWindow(@ptrFromInt(hwnd));
        errdefer _ = item.release();
        
        const size = try item.getSize();
        const src_width: u32 = @intCast(size.Width);
        const src_height: u32 = @intCast(size.Height);
        
        const d3d_device = try wgc.createDirect3DDevice(self.device.dxgi_device.?);
        errdefer {
            const dev_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(d3d_device));
            _ = dev_unk.*.Release(d3d_device);
        }
        
        const pool = try self.factory.create(d3d_device, .B8G8R8A8UIntNormalized, 1, size);
        errdefer _ = pool.release();
        
        const session = try pool.createCaptureSession(item);
        errdefer _ = session.release();
        
        // Shared texture for CUDA interop
        const shared_texture = try self.device.createSharedTexture(src_width, src_height, .B8G8R8A8_UNORM);
        errdefer _ = shared_texture.release();
        
        const cuda_resource = try self.cuda_ctx.registerD3D11Texture(shared_texture);
        errdefer self.cuda_ctx.unregisterResource(cuda_resource);
        
        // Start capture
        try session.startCapture();
        
        slot.* = .{
            .hwnd = hwnd,
            .pool = pool,
            .session = session,
            .item = item,
            .d3d_device = d3d_device,
            .shared_texture = shared_texture,
            .cuda_resource = cuda_resource,
            .src_width = src_width,
            .src_height = src_height,
            .last_used = std.time.timestamp(),
            .active = true,
        };
        
        log.info("Created session for hwnd {} ({}x{})", .{ hwnd, src_width, src_height });
        return slot;
    }
    
    /// Capture a window and encode to JPEG
    /// Returns allocated JPEG bytes (caller must free)
    pub fn capture(self: *Pipeline, hwnd: usize) ![]u8 {
        const session = try self.getSession(hwnd);
        
        // Try to get a frame (WGC delivers asynchronously)
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            if (session.pool.tryGetNextFrame()) |frame| {
                defer _ = frame.release();
                return self.processFrame(session, frame);
            }
            std.Thread.sleep(5 * std.time.ns_per_ms);
        }
        
        return error.NoFrameAvailable;
    }
    
    fn processFrame(self: *Pipeline, session: *WindowSession, frame: *wgc.IDirect3D11CaptureFrame) ![]u8 {
        // Copy WGC → shared texture
        const surface = try frame.getSurface();
        const wgc_texture = try wgc.getTextureFromSurface(surface);
        defer {
            const tex_unk: *const *const d3d11.IUnknownVtbl = @ptrCast(@alignCast(wgc_texture));
            _ = tex_unk.*.Release(wgc_texture);
        }
        self.device.copyTexture(session.shared_texture, wgc_texture);
        
        // Map for CUDA
        var resource = session.cuda_resource;
        try self.cuda_ctx.mapResource(&resource);
        defer self.cuda_ctx.unmapResource(&resource);
        
        const cuda_array = try self.cuda_ctx.getMappedArray(session.cuda_resource);
        
        // Create texture object with hardware bilinear filtering
        const tex_obj = try self.resize_kernel.createTextureFromArray(cuda_array);
        defer self.resize_kernel.destroyTexture(tex_obj);
        
        // Launch fused resize+BGRA→RGB kernel
        try self.resize_kernel.launch(
            tex_obj,
            self.rgb_mem,
            self.target_width,
            self.target_height,
            self.rgb_pitch,
            session.src_width,
            session.src_height,
        );
        self.cuda_ctx.synchronize();
        
        // nvJPEG encode
        const jpeg_data = try self.encoder.encode(
            self.allocator,
            self.rgb_mem,
            self.target_width,
            self.target_height,
            self.rgb_pitch,
        );
        
        return jpeg_data;
    }
    
    /// Warm up a session without capturing
    pub fn warmSession(self: *Pipeline, hwnd: usize) !void {
        _ = try self.getSession(hwnd);
    }
};

// ═══════════════════════════════════════════════════════════════
//  Global Instance
// ═══════════════════════════════════════════════════════════════

var global_pipeline: ?*Pipeline = null;

pub fn init(allocator: std.mem.Allocator, target_width: u32, target_height: u32) !void {
    if (global_pipeline != null) return; // Already initialized
    global_pipeline = try Pipeline.init(allocator, target_width, target_height);
}

pub fn deinit() void {
    if (global_pipeline) |p| {
        p.deinit();
        global_pipeline = null;
    }
}

/// Capture a window and return JPEG bytes
pub fn capture(allocator: std.mem.Allocator, hwnd: usize) ![]u8 {
    const pipeline = global_pipeline orelse return error.PipelineNotInitialized;
    _ = allocator; // Pipeline uses its own allocator
    return pipeline.capture(hwnd);
}

/// Warm a session without capturing
pub fn warmSession(hwnd: usize) !void {
    const pipeline = global_pipeline orelse return error.PipelineNotInitialized;
    try pipeline.warmSession(hwnd);
}

pub fn isInitialized() bool {
    return global_pipeline != null;
}
