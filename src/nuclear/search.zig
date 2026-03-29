//! SIMD Image/Pixel Search - Pure Zig
//!
//! AVX2-accelerated search using Zig's @Vector.
//! Target: match C++ ParallelSearch.cpp performance (0.05ms on 4K).

const std = @import("std");
const root = @import("root.zig");
const cache = @import("cache.zig");

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

// ═══════════════════════════════════════════════════════════════
//  SIMD Types
// ═══════════════════════════════════════════════════════════════

// 256-bit vectors for AVX2
const Vec32u8 = @Vector(32, u8);
const Vec8u32 = @Vector(8, u32);

// ═══════════════════════════════════════════════════════════════
//  Pixel Search
// ═══════════════════════════════════════════════════════════════

pub fn findPixel(
    data: [*]const u8,
    width: u32,
    height: u32,
    stride: u32,
    target_color: u32, // 0xRRGGBB
    tolerance: u8,
    roi: ?Rect,
) root.SearchResult {
    const region = roi orelse Rect{ .x = 0, .y = 0, .width = width, .height = height };

    // Extract target RGB
    const target_r: u8 = @truncate((target_color >> 16) & 0xFF);
    const target_g: u8 = @truncate((target_color >> 8) & 0xFF);
    const target_b: u8 = @truncate(target_color & 0xFF);

    // TODO: SIMD implementation
    // For now, scalar fallback
    var y: u32 = region.y;
    while (y < region.y + region.height) : (y += 1) {
        var x: u32 = region.x;
        while (x < region.x + region.width) : (x += 1) {
            const offset = y * stride + x * 4; // BGRA
            const b = data[offset];
            const g = data[offset + 1];
            const r = data[offset + 2];

            const dr = if (r > target_r) r - target_r else target_r - r;
            const dg = if (g > target_g) g - target_g else target_g - g;
            const db = if (b > target_b) b - target_b else target_b - b;

            if (dr <= tolerance and dg <= tolerance and db <= tolerance) {
                return .{ .found = true, .x = @truncate(x), .y = @truncate(y) };
            }
        }
    }

    return .{ .found = false };
}

// ═══════════════════════════════════════════════════════════════
//  Image Search
// ═══════════════════════════════════════════════════════════════

pub fn findImage(
    haystack: [*]const u8,
    hay_width: u32,
    hay_height: u32,
    hay_stride: u32,
    needle: *const cache.CachedImage,
    tolerance: u8,
    roi: ?Rect,
) root.SearchResult {
    _ = haystack;
    _ = hay_width;
    _ = hay_height;
    _ = hay_stride;
    _ = needle;
    _ = tolerance;
    _ = roi;

    // TODO: SIMD image search
    // Algorithm:
    // 1. For each candidate position in haystack (ROI)
    // 2. Compare needle pixels using AVX2 (32 bytes at a time)
    // 3. Skip transparent pixels (trans_color match)
    // 4. Early exit on mismatch beyond tolerance

    return .{ .found = false };
}

// ═══════════════════════════════════════════════════════════════
//  SIMD Helpers (TODO)
// ═══════════════════════════════════════════════════════════════

/// Compare 32 bytes with tolerance, return match mask
fn simdCompareWithTolerance(a: Vec32u8, b: Vec32u8, tol: u8) u32 {
    // Compute |a - b| <= tolerance for each byte
    const diff_ab = a -| b; // saturating sub
    const diff_ba = b -| a;
    const diff = @max(diff_ab, diff_ba);
    const tol_vec: Vec32u8 = @splat(tol);
    const mask = diff <= tol_vec;
    return @bitCast(mask);
}
