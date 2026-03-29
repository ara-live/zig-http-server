/// ara-eyes HTTP server — Zig edition
///
/// Multi-threaded HTTP server with the Warm-One pattern.
/// Routes: /capture, /windows, /status
///
const std = @import("std");
const mem = std.mem;
const net = std.net;
const http = std.http;
const builtin = @import("builtin");
const log = std.log.scoped(.api);
const Config = @import("config.zig").Config;
const capture = @import("capture.zig");

const kernel32 = if (builtin.os.tag == .windows) std.os.windows.kernel32 else struct {};
const HANDLE_FLAG_INHERIT: u32 = 0x00000001;

const Status = http.Status;
const Request = http.Server.Request;

const header_buf_size: usize = 8192;
const write_buf_size: usize = 16_384;
const response_buf_size: usize = 524_288; // 512KB for image data

// ═══════════════════════════════════════════════════════════════
//  Session Management (WGC warmup)
// ═══════════════════════════════════════════════════════════════

const MAX_SESSIONS = 8;

const SessionManager = struct {
    sessions: [MAX_SESSIONS]usize = [_]usize{0} ** MAX_SESSIONS,
    timestamps: [MAX_SESSIONS]i64 = [_]i64{0} ** MAX_SESSIONS,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    tmp_dir: []const u8,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !SessionManager {
        // Create temp directory
        std.fs.cwd().makeDir("tmp") catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        return .{
            .tmp_dir = "tmp",
            .allocator = allocator,
        };
    }

    fn ensureSession(self: *SessionManager, hwnd: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already tracked
        for (self.sessions[0..self.count]) |s| {
            if (s == hwnd) return false; // Not new
        }

        // Start WGC capture session
        capture.startCapture(hwnd) catch return false;

        // Track it
        if (self.count < MAX_SESSIONS) {
            self.sessions[self.count] = hwnd;
            self.timestamps[self.count] = std.time.timestamp();
            self.count += 1;
        } else {
            // Evict oldest
            var oldest_idx: usize = 0;
            var oldest_time = self.timestamps[0];
            for (self.timestamps[1..], 1..) |t, i| {
                if (t < oldest_time) {
                    oldest_time = t;
                    oldest_idx = i;
                }
            }
            self.sessions[oldest_idx] = hwnd;
            self.timestamps[oldest_idx] = std.time.timestamp();
        }

        return true; // Is new session
    }

    fn tmpPath(self: *SessionManager, hwnd: usize, ext: []const u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/capture_{d}.{s}", .{ self.tmp_dir, hwnd, ext }) catch "tmp/capture.png";
    }
};

// ═══════════════════════════════════════════════════════════════
//  Warm-One State
// ═══════════════════════════════════════════════════════════════

const Warm = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    block: ?[]u8 = null,
    pending_conn: ?net.Server.Connection = null,
    pending_block: ?[]u8 = null,
    thread_ready: bool = false,
    stopping: bool = false,
};

// ═══════════════════════════════════════════════════════════════
//  Api — shared server state
// ═══════════════════════════════════════════════════════════════

pub const Api = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    listener: net.Server,
    shutdown: std.atomic.Value(bool),
    active_connections: std.atomic.Value(u32),
    start_time: i64,
    warm: Warm,
    sessions: SessionManager,

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Api {
        // Load ScreenMaster DLL
        capture.loadDll(config.dll_path) catch |err| {
            log.err("failed to load ScreenMaster.dll: {}", .{err});
            return err;
        };

        const address = try net.Address.resolveIp(config.host, config.port);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        if (comptime builtin.os.tag == .windows) {
            _ = kernel32.SetHandleInformation(listener.stream.handle, HANDLE_FLAG_INHERIT, 0);
        }

        return .{
            .allocator = allocator,
            .config = config,
            .listener = listener,
            .shutdown = std.atomic.Value(bool).init(false),
            .active_connections = std.atomic.Value(u32).init(0),
            .start_time = std.time.timestamp(),
            .warm = .{},
            .sessions = try SessionManager.init(allocator),
        };
    }

    pub fn deinit(self: *Api) void {
        self.warm.mutex.lock();
        if (self.warm.block) |b| self.allocator.free(b);
        self.warm.block = null;
        self.warm.mutex.unlock();
        self.listener.deinit();
        capture.unloadDll();
    }

    pub fn run(self: *Api) void {
        log.info("ara-eyes listening on {s}:{d}", .{ self.config.host, self.config.port });
        self.replenish();

        while (!self.shutdown.load(.acquire)) {
            const conn = self.listener.accept() catch |err| {
                if (self.shutdown.load(.acquire)) break;
                log.err("accept: {}", .{err});
                continue;
            };
            self.prepareSocket(conn);

            const active = self.active_connections.load(.acquire);
            if (active >= self.config.max_connections) {
                log.warn("connection limit ({d}), rejecting", .{active});
                conn.stream.close();
                continue;
            }
            self.dispatch(conn);
        }
    }

    fn prepareSocket(self: *Api, conn: net.Server.Connection) void {
        _ = self;
        if (comptime builtin.os.tag == .windows) {
            _ = kernel32.SetHandleInformation(conn.stream.handle, HANDLE_FLAG_INHERIT, 0);
        }
        // Timeouts handled by std.http.Server internally
    }

    fn blockSize(self: *Api) usize {
        return header_buf_size + write_buf_size + self.config.max_body_size + response_buf_size;
    }

    fn allocBlock(self: *Api) ?[]u8 {
        return self.allocator.alloc(u8, self.blockSize()) catch null;
    }

    fn dispatch(self: *Api, conn: net.Server.Connection) void {
        self.warm.mutex.lock();
        if (self.warm.thread_ready and self.warm.block != null) {
            self.warm.pending_conn = conn;
            self.warm.pending_block = self.warm.block;
            self.warm.block = null;
            self.warm.thread_ready = false;
            self.warm.cond.signal();
            self.warm.mutex.unlock();
            self.replenish();
            return;
        }
        self.warm.mutex.unlock();

        const block = self.allocBlock() orelse {
            log.warn("block alloc failed, rejecting", .{});
            conn.stream.close();
            return;
        };
        _ = std.Thread.spawn(.{}, directHandler, .{ self, conn, block }) catch {
            self.allocator.free(block);
            conn.stream.close();
        };
    }

    fn replenish(self: *Api) void {
        self.warm.mutex.lock();
        if (self.warm.block == null) {
            self.warm.block = self.allocBlock();
        }
        self.warm.mutex.unlock();

        _ = std.Thread.spawn(.{}, warmThread, .{self}) catch {};
    }

    pub fn requestShutdown(self: *Api) void {
        self.shutdown.store(true, .release);
        self.warm.mutex.lock();
        self.warm.stopping = true;
        self.warm.cond.signal();
        self.warm.mutex.unlock();
    }
};

fn warmThread(api: *Api) void {
    api.warm.mutex.lock();
    api.warm.thread_ready = true;
    while (true) {
        api.warm.cond.wait(&api.warm.mutex);
        if (api.warm.stopping) {
            api.warm.mutex.unlock();
            return;
        }
        if (api.warm.pending_conn) |conn| {
            const block = api.warm.pending_block.?;
            api.warm.pending_conn = null;
            api.warm.pending_block = null;
            api.warm.mutex.unlock();
            handleRequests(api, conn, block);
            return;
        }
    }
}

fn directHandler(api: *Api, conn: net.Server.Connection, block: []u8) void {
    handleRequests(api, conn, block);
}

fn handleRequests(api: *Api, conn: net.Server.Connection, block: []u8) void {
    _ = api.active_connections.fetchAdd(1, .monotonic);
    defer _ = api.active_connections.fetchSub(1, .monotonic);
    defer conn.stream.close();
    defer api.allocator.free(block);

    var ctx = Connection.initFromBlock(api, block);
    var read_io = conn.stream.reader(ctx.header_buf);
    var write_io = conn.stream.writer(ctx.write_buf);
    var server = http.Server.init(read_io.interface(), &write_io.interface);

    while (true) {
        if (api.shutdown.load(.acquire)) break;
        var request = server.receiveHead() catch break;

        const start_ns = std.time.nanoTimestamp();
        const status = ctx.route(&request);
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        log.info("{s} {s} -> {d} ({d}ms)", .{
            @tagName(request.head.method),
            request.head.target,
            @intFromEnum(status),
            @divFloor(elapsed_ns, 1_000_000),
        });
    }
}

// ═══════════════════════════════════════════════════════════════
//  Connection — per-connection state
// ═══════════════════════════════════════════════════════════════

const Connection = struct {
    api: *Api,
    header_buf: []u8,
    write_buf: []u8,
    body_buf: []u8,
    response_buf: []u8,

    fn initFromBlock(api: *Api, block: []u8) Connection {
        var off: usize = 0;
        const hdr = block[off..][0..header_buf_size];
        off += header_buf_size;
        const wrt = block[off..][0..write_buf_size];
        off += write_buf_size;
        const bdy_size = api.config.max_body_size;
        const bdy = block[off..][0..bdy_size];
        off += bdy_size;
        const rsp = block[off..][0..response_buf_size];
        return .{ .api = api, .header_buf = hdr, .write_buf = wrt, .body_buf = bdy, .response_buf = rsp };
    }

    fn route(self: *Connection, request: *Request) Status {
        const target = request.head.target;
        const method = request.head.method;

        // Parse path and query
        var path = target;
        var query: ?[]const u8 = null;
        if (mem.indexOf(u8, target, "?")) |idx| {
            path = target[0..idx];
            query = target[idx + 1 ..];
        }

        if (mem.eql(u8, path, "/capture") and method == .GET) return self.handleCapture(request, query);
        if (mem.eql(u8, path, "/windows") and method == .GET) return self.handleWindows(request);
        if (mem.eql(u8, path, "/status") and method == .GET) return self.handleStatus(request);
        if (mem.eql(u8, path, "/health") and method == .GET) return self.handleStatus(request);

        return sendNotFound(request);
    }

    fn handleCapture(self: *Connection, request: *Request, query: ?[]const u8) Status {
        // Parse query params
        var hwnd: usize = 0;
        var format = capture.ImageFormat.jpeg;

        if (query) |q| {
            var params = mem.splitScalar(u8, q, '&');
            while (params.next()) |param| {
                if (mem.startsWith(u8, param, "hwnd=")) {
                    hwnd = std.fmt.parseInt(usize, param[5..], 10) catch 0;
                } else if (mem.startsWith(u8, param, "format=")) {
                    const fmt = param[7..];
                    if (mem.eql(u8, fmt, "png")) format = .png;
                }
            }
        }

        // Default to foreground window
        if (hwnd == 0) {
            hwnd = capture.getForegroundWindow();
            if (hwnd == 0) return sendError(request, .internal_server_error, "no foreground window");
        }

        // Ensure WGC session (with warmup for new sessions)
        const is_new = self.api.sessions.ensureSession(hwnd);
        if (is_new) {
            std.Thread.sleep(100_000_000); // 100ms warmup
        }

        // Save frame to temp file
        const ext = if (format == .png) "png" else "jpg";
        var path_buf: [128]u8 = undefined;
        const path = self.api.sessions.tmpPath(hwnd, ext, &path_buf);

        capture.saveFrame(hwnd, path, format) catch |err| {
            // Retry once for new sessions
            if (is_new) {
                std.Thread.sleep(150_000_000); // 150ms more
                capture.saveFrame(hwnd, path, format) catch {
                    return sendError(request, .internal_server_error, "capture failed");
                };
            } else {
                log.err("saveFrame: {}", .{err});
                return sendError(request, .internal_server_error, "capture failed");
            }
        };

        // Read file and send
        const file = std.fs.cwd().openFile(path, .{}) catch {
            return sendError(request, .internal_server_error, "failed to read capture");
        };
        defer file.close();
        defer std.fs.cwd().deleteFile(path) catch {};

        const stat = file.stat() catch {
            return sendError(request, .internal_server_error, "failed to stat capture");
        };
        const size = stat.size;
        if (size > response_buf_size) {
            return sendError(request, .internal_server_error, "capture too large");
        }

        const data = file.readAll(self.response_buf) catch {
            return sendError(request, .internal_server_error, "failed to read capture");
        };

        const content_type = if (format == .png) "image/png" else "image/jpeg";
        sendBinary(request, self.response_buf[0..data], content_type, .ok);
        return .ok;
    }

    fn handleWindows(self: *Connection, request: *Request) Status {
        var list = capture.listWindows(self.api.allocator) catch {
            return sendError(request, .internal_server_error, "failed to enumerate windows");
        };
        defer list.deinit();

        var stream = std.io.fixedBufferStream(self.response_buf);
        const w = stream.writer();

        w.writeAll("{\"foreground\":") catch return sendError(request, .internal_server_error, "json error");

        // Write foreground
        var found_fg = false;
        for (list.windows) |win| {
            if (win.hwnd == list.foreground_hwnd) {
                writeWindowJson(w, win) catch return sendError(request, .internal_server_error, "json error");
                found_fg = true;
                break;
            }
        }
        if (!found_fg) w.writeAll("null") catch {};

        w.writeAll(",\"windows\":[") catch return sendError(request, .internal_server_error, "json error");

        var first = true;
        for (list.windows) |win| {
            if (!first) w.writeByte(',') catch {};
            first = false;
            writeWindowJson(w, win) catch return sendError(request, .internal_server_error, "json error");
        }

        w.writeAll("]}") catch return sendError(request, .internal_server_error, "json error");

        sendJson(request, stream.getWritten(), .ok);
        return .ok;
    }

    fn handleStatus(self: *Connection, request: *Request) Status {
        const uptime = std.time.timestamp() - self.api.start_time;
        const active = self.api.active_connections.load(.acquire);
        const json = std.fmt.bufPrint(
            self.response_buf,
            "{{\"status\":\"ok\",\"version\":\"2.0.0\",\"uptime\":{d},\"active_connections\":{d}}}",
            .{ uptime, active },
        ) catch return sendError(request, .internal_server_error, "format error");
        sendJson(request, json, .ok);
        return .ok;
    }
};

fn writeWindowJson(w: anytype, win: capture.WindowInfo) !void {
    try w.print("{{\"hwnd\":{d},\"title\":\"", .{win.hwnd});
    try writeJsonEscaped(w, win.title);
    try w.writeAll("\",\"process\":\"");
    try writeJsonEscaped(w, win.process);
    try w.writeAll("\"}");
}

// ═══════════════════════════════════════════════════════════════
//  Response Helpers
// ═══════════════════════════════════════════════════════════════

fn sendJson(request: *Request, json: []const u8, status: Status) void {
    request.respond(json, .{ .status = status }) catch {};
}

fn sendBinary(request: *Request, data: []const u8, content_type: []const u8, status: Status) void {
    _ = content_type; // TODO: set content-type header
    request.respond(data, .{ .status = status }) catch {};
}

fn sendError(request: *Request, status: Status, msg: []const u8) Status {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"unknown\"}";
    request.respond(json, .{ .status = status }) catch {};
    return status;
}

fn sendNotFound(request: *Request) Status {
    return sendError(request, .not_found, "not found");
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try std.fmt.format(writer, "\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
