/// ara-eyes — Zig HTTP server for WGC screen capture
///
/// Usage: eyes [config.json]
///
const std = @import("std");
const config_mod = @import("config.zig");
const Api = @import("api.zig").Api;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config_path = if (args.len > 1) args[1] else "config.json";
    const config = try config_mod.load(allocator, config_path);

    var api = try Api.init(allocator, config);
    defer api.deinit();

    api.run();
}
