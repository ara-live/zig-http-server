/// ara-eyes configuration
const std = @import("std");

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 7071,  // 7070 is v1 Python, 7071 is v2 Zig
    dll_path: []const u8 = "ScreenMaster.dll",
    max_body_size: usize = 65536,
    socket_timeout_ms: u32 = 30000,
    max_connections: u32 = 32,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !*Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("config: {s} not found, using defaults", .{path});
            const cfg = try allocator.create(Config);
            cfg.* = .{};
            return cfg;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const cfg = try allocator.create(Config);
    cfg.* = .{};

    if (parsed.value == .object) {
        const obj = parsed.value.object;
        if (obj.get("host")) |v| if (v == .string) {
            cfg.host = try allocator.dupe(u8, v.string);
        };
        if (obj.get("port")) |v| if (v == .integer) {
            cfg.port = @intCast(v.integer);
        };
        if (obj.get("dllPath")) |v| if (v == .string) {
            cfg.dll_path = try allocator.dupe(u8, v.string);
        };
        if (obj.get("maxBodySize")) |v| if (v == .integer) {
            cfg.max_body_size = @intCast(v.integer);
        };
        if (obj.get("socketTimeoutMs")) |v| if (v == .integer) {
            cfg.socket_timeout_ms = @intCast(v.integer);
        };
        if (obj.get("maxConnections")) |v| if (v == .integer) {
            cfg.max_connections = @intCast(v.integer);
        };
    }

    return cfg;
}
