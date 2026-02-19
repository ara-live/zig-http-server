const std = @import("std");
const log = std.log.scoped(.config);

pub const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3001,
    auth_token: ?[]const u8 = null,
    max_body_size: usize = 65_536, // 64KB
    socket_timeout_ms: u32 = 30_000, // 30s recv/send timeout per connection
    max_connections: u32 = 64, // max concurrent connections (thread limit)

    // Add your config fields here:
    // my_setting: []const u8 = "default",

    // Internal — owns the parsed JSON for string lifetime
    _parsed: ?std.json.Parsed(std.json.Value) = null,
    _allocator: ?std.mem.Allocator = null,

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            log.warn("config file not found ({s}), using defaults", .{path});
            if (err == error.FileNotFound) return Config{};
            return err;
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 1_048_576);
        defer allocator.free(data);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        const obj = parsed.value.object;

        var config = Config{
            ._parsed = parsed,
            ._allocator = allocator,
        };

        if (obj.get("host")) |v| {
            if (v == .string) config.host = v.string;
        }
        if (obj.get("port")) |v| {
            if (v == .integer) config.port = @intCast(v.integer);
        }
        if (obj.get("authToken")) |v| {
            if (v == .string) config.auth_token = v.string;
        }
        if (obj.get("maxBodySize")) |v| {
            if (v == .integer) config.max_body_size = @intCast(v.integer);
        }
        if (obj.get("socketTimeoutMs")) |v| {
            if (v == .integer) config.socket_timeout_ms = @intCast(v.integer);
        }
        if (obj.get("maxConnections")) |v| {
            if (v == .integer) config.max_connections = @intCast(v.integer);
        }

        // Parse your custom fields here:
        // if (obj.get("mySetting")) |v| {
        //     if (v == .string) config.my_setting = v.string;
        // }

        return config;
    }

    pub fn deinit(self: *Config) void {
        if (self._parsed) |*p| {
            p.deinit();
            self._parsed = null;
        }
    }
};
