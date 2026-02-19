/// Zig HTTP Server Template — Entry Point
///
/// Copy this project, add your routes in api.zig, customize config.zig.
///
const std = @import("std");
const Config = @import("config").Config;
const Api = @import("api").Api;

const log = std.log.scoped(.main);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load config
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const config_path = if (args.len > 1) args[1] else "config.json";

    var config = try Config.loadFromFile(allocator, config_path);
    defer config.deinit();

    log.info("listening on {s}:{d}", .{ config.host, config.port });

    // Init API server
    var api = try Api.init(allocator, &config);
    defer api.deinit();

    api.installSignalHandlers();

    log.info("ready", .{});

    // Run (blocks until shutdown signal)
    api.run();

    log.info("shutdown complete", .{});
}
