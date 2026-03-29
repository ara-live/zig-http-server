//! Image Cache - Pure Zig
//!
//! Stores loaded needle images for fast repeated searches.

const std = @import("std");

pub const CachedImage = struct {
    data: []const u8, // BGRA pixels
    width: u32,
    height: u32,
    trans_color: ?u32, // Pixels matching this color are skipped during search

    pub fn deinit(self: *CachedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

// Global cache (thread-safe)
var cache_mutex: std.Thread.Mutex = .{};
var cache_map: ?std.StringHashMap(CachedImage) = null;
var cache_allocator: ?std.mem.Allocator = null;

pub fn init(allocator: std.mem.Allocator) void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cache_map == null) {
        cache_map = std.StringHashMap(CachedImage).init(allocator);
        cache_allocator = allocator;
    }
}

pub fn deinit() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cache_map) |*map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            if (cache_allocator) |alloc| {
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
        }
        map.deinit();
        cache_map = null;
    }
}

pub fn load(name: []const u8, path: []const u8, trans_color: ?u32) !void {
    _ = name;
    _ = path;
    _ = trans_color;

    // TODO: Load image from path using WIC or stb_image
    // Convert to BGRA, store in cache

    return error.NotImplemented;
}

pub fn get(name: []const u8) ?*const CachedImage {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cache_map) |*map| {
        return map.getPtr(name);
    }
    return null;
}

pub fn clear() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cache_map) |*map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            if (cache_allocator) |alloc| {
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
        }
        map.clearRetainingCapacity();
    }
}
