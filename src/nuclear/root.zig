//! ScreenMaster - Pure Zig Implementation
//!
//! Native Windows screen capture and SIMD image search.
//! No C dependencies - direct Win32/WGC/AVX2 via Zig.
//!
//! Performance target: match or beat C++ DLL (0.05ms search on 4K).

const std = @import("std");
pub const d3d11 = @import("d3d11.zig");
pub const wgc = @import("wgc.zig");
pub const cuda = @import("cuda.zig");
pub const nvjpeg = @import("nvjpeg.zig");
pub const kernel = @import("kernel.zig");
pub const search = @import("search.zig");
pub const cache = @import("cache.zig");

// ═══════════════════════════════════════════════════════════════
//  Public API
// ═══════════════════════════════════════════════════════════════

pub const ImageFormat = enum {
    png,
    jpeg,
};

pub const CaptureSession = struct {
    hwnd: usize,
    wgc_session: ?*wgc.Session = null,

    pub fn init(hwnd: usize) !CaptureSession {
        var session = CaptureSession{ .hwnd = hwnd };
        session.wgc_session = try wgc.Session.create(hwnd);
        return session;
    }

    pub fn deinit(self: *CaptureSession) void {
        if (self.wgc_session) |s| s.destroy();
    }

    pub fn captureFrame(self: *CaptureSession) !wgc.Frame {
        const session = self.wgc_session orelse return error.NoSession;
        return session.getFrame();
    }

    pub fn saveFrame(self: *CaptureSession, path: []const u8, format: ImageFormat) !void {
        const frame = try self.captureFrame();
        defer frame.release();
        try frame.saveToFile(path, format);
    }
};

pub const SearchResult = struct {
    found: bool,
    x: u16 = 0,
    y: u16 = 0,
};

/// Search for a pixel color in a captured frame
pub fn pixelSearch(
    frame: *const wgc.Frame,
    color: u32, // 0xRRGGBB
    tolerance: u8,
    roi: ?search.Rect,
) SearchResult {
    return search.findPixel(frame.data, frame.width, frame.height, frame.stride, color, tolerance, roi);
}

/// Search for a cached needle image in a captured frame
pub fn imageSearch(
    frame: *const wgc.Frame,
    needle_name: []const u8,
    tolerance: u8,
    roi: ?search.Rect,
) !SearchResult {
    const needle = cache.get(needle_name) orelse return error.NeedleNotCached;
    return search.findImage(frame.data, frame.width, frame.height, frame.stride, needle, tolerance, roi);
}

// ═══════════════════════════════════════════════════════════════
//  Cache Management
// ═══════════════════════════════════════════════════════════════

pub fn loadImageToCache(name: []const u8, path: []const u8, trans_color: ?u32) !void {
    try cache.load(name, path, trans_color);
}

pub fn clearCache() void {
    cache.clear();
}

// ═══════════════════════════════════════════════════════════════
//  Window Enumeration (shared with bindings)
// ═══════════════════════════════════════════════════════════════

pub const windows = @import("windows.zig");
pub const WindowInfo = windows.WindowInfo;
pub const listWindows = windows.listWindows;
pub const getForegroundWindow = windows.getForegroundWindow;

// ═══════════════════════════════════════════════════════════════
//  Tests
// ═══════════════════════════════════════════════════════════════

test "module compiles" {
    // Basic smoke test
    _ = d3d11;
    _ = wgc;
    _ = search;
    _ = cache;
}

test {
    // Reference all tests in submodules
    _ = @import("d3d11.zig");
    _ = @import("wgc.zig");
    _ = @import("cuda.zig");
    _ = @import("nvjpeg.zig");
    _ = @import("kernel.zig");
}
