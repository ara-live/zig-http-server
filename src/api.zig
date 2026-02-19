/// Zig HTTP Server Template — api.zig
///
/// Multi-threaded HTTP server with the Warm-One pattern:
/// - One thread + one buffer block always pre-created, ready for the next connection
/// - When taken, replacements are spawned/allocated immediately
/// - Zero allocation and zero thread creation on the connection hot path
/// - HTTP/1.1 keep-alive (client-controlled)
/// - Non-inheritable sockets (prevents child process handle leaks on Windows)
/// - Per-connection contiguous buffer (single alloc, perfect cache locality)
/// - Comptime route dispatch
/// - Request logging with timing
/// - Optional Bearer auth
/// - Connection limit with atomic counter
/// - Graceful shutdown via signal handlers
///
/// To add routes: add handler fn + entry in Connection.routes.
/// To add config: edit config.zig.
///
const std = @import("std");
const mem = std.mem;
const net = std.net;
const http = std.http;
const builtin = @import("builtin");
const log = std.log.scoped(.api);
const Config = @import("config").Config;

const kernel32 = if (builtin.os.tag == .windows) std.os.windows.kernel32 else struct {};
const ws2 = if (builtin.os.tag == .windows) std.os.windows.ws2_32 else struct {};
const SOL_SOCKET: u32 = if (builtin.os.tag == .windows) 0xFFFF else 0;
const HANDLE_FLAG_INHERIT: u32 = 0x00000001;

const Status = http.Status;
const Request = http.Server.Request;

// Per-connection buffer sizes — tune for your use case
const header_buf_size: usize = 8192; // HTTP header parsing
const write_buf_size: usize = 16_384; // Buffered socket writes
const response_buf_size: usize = 262_144; // 256KB — JSON response formatting

// ═══════════════════════════════════════════════════════════════
//  Warm-One State
//
//  Always one thread + one block pre-created. When taken,
//  replacements are spawned/allocated immediately. The hot path
//  (accept → first byte read) does zero allocation and zero
//  thread creation.
// ═══════════════════════════════════════════════════════════════

const Warm = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    /// Pre-allocated contiguous buffer block (null = being replenished)
    block: ?[]u8 = null,

    /// Handoff slot: accept thread stores connection here for warm thread
    pending_conn: ?net.Server.Connection = null,
    pending_block: ?[]u8 = null,

    /// A warm thread is blocked on cond, ready for work
    thread_ready: bool = false,

    /// Shutdown signal for warm thread
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

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Api {
        const address = try net.Address.resolveIp(config.host, config.port);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();

        // Prevent child processes from inheriting the listener socket.
        // Standard practice — see libuv, Go net, Rust std::net.
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
        };
    }

    pub fn deinit(self: *Api) void {
        // Free warm block if still held
        self.warm.mutex.lock();
        if (self.warm.block) |b| self.allocator.free(b);
        self.warm.block = null;
        self.warm.mutex.unlock();

        self.listener.deinit();
    }

    // ── Accept Loop ─────────────────────────────────────────────

    pub fn run(self: *Api) void {
        log.info("accepting connections", .{});

        // Pre-warm: first block + first thread
        self.replenish();

        while (!self.shutdown.load(.acquire)) {
            const conn = self.listener.accept() catch |err| {
                if (self.shutdown.load(.acquire)) break;
                log.err("accept: {}", .{err});
                continue;
            };

            self.prepareSocket(conn);

            // Connection limit
            const active = self.active_connections.load(.acquire);
            if (active >= self.config.max_connections) {
                log.warn("connection limit reached ({d}), rejecting", .{active});
                conn.stream.close();
                continue;
            }

            self.dispatch(conn);
        }

        // Shutdown: wake warm thread if waiting
        self.warm.mutex.lock();
        self.warm.stopping = true;
        self.warm.cond.signal();
        self.warm.mutex.unlock();
    }

    fn dispatch(self: *Api, conn: net.Server.Connection) void {
        self.warm.mutex.lock();

        if (self.warm.thread_ready and self.warm.block != null) {
            // ── Fast path: hand to pre-spawned worker ──
            self.warm.pending_conn = conn;
            self.warm.pending_block = self.warm.block;
            self.warm.block = null;
            self.warm.thread_ready = false;
            self.warm.cond.signal();
            self.warm.mutex.unlock();
        } else {
            // ── Fallback: no warm thread ready, spawn directly ──
            const block = self.warm.block;
            self.warm.block = null;
            self.warm.mutex.unlock();

            const actual_block = block orelse self.allocBlock() catch {
                log.err("block alloc failed, rejecting connection", .{});
                conn.stream.close();
                return;
            };

            const thread = std.Thread.spawn(.{}, directHandler, .{ self, conn, actual_block }) catch |err| {
                log.err("thread spawn failed: {}", .{err});
                self.allocator.free(actual_block);
                conn.stream.close();
                return;
            };
            thread.detach();
        }

        // Replenish for next connection (off hot path — races with next accept)
        self.replenish();
    }

    /// Ensure a warm block and warm thread are ready for the next connection.
    /// Called from the accept thread only — no concurrent access.
    fn replenish(self: *Api) void {
        // Replenish block
        self.warm.mutex.lock();
        const need_block = (self.warm.block == null);
        const need_thread = !self.warm.thread_ready and !self.warm.stopping;
        self.warm.mutex.unlock();

        if (need_block) {
            if (self.allocBlock()) |new_block| {
                self.warm.mutex.lock();
                self.warm.block = new_block;
                self.warm.mutex.unlock();
            } else |_| {
                log.warn("warm block pre-alloc failed (will retry next cycle)", .{});
            }
        }

        if (need_thread) {
            const thread = std.Thread.spawn(.{}, warmWorker, .{self}) catch {
                log.warn("warm thread pre-spawn failed (will retry next cycle)", .{});
                return;
            };
            thread.detach();
        }
    }

    // ── Socket Setup ────────────────────────────────────────────

    fn prepareSocket(self: *Api, conn: net.Server.Connection) void {
        // Non-inheritable: child processes must not inherit connection sockets
        if (comptime builtin.os.tag == .windows) {
            _ = kernel32.SetHandleInformation(conn.stream.handle, HANDLE_FLAG_INHERIT, 0);
        }

        const timeout_ms = self.config.socket_timeout_ms;
        if (comptime builtin.os.tag == .windows) {
            _ = ws2.setsockopt(conn.stream.handle, SOL_SOCKET, ws2.SO.RCVTIMEO, mem.asBytes(&timeout_ms), @sizeOf(u32));
            _ = ws2.setsockopt(conn.stream.handle, SOL_SOCKET, ws2.SO.SNDTIMEO, mem.asBytes(&timeout_ms), @sizeOf(u32));
        } else {
            const timeout_s = timeout_ms / 1000;
            const timeout_us = (timeout_ms % 1000) * 1000;
            const tv = std.posix.timeval{ .sec = @intCast(timeout_s), .usec = @intCast(timeout_us) };
            std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, mem.asBytes(&tv)) catch {};
            std.posix.setsockopt(conn.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, mem.asBytes(&tv)) catch {};
        }
    }

    // ── Block Allocation ────────────────────────────────────────

    /// Allocate a single contiguous block for all per-connection buffers.
    /// One alloc, one free, perfect cache locality.
    fn allocBlock(self: *Api) ![]u8 {
        const total = header_buf_size + write_buf_size + self.config.max_body_size + response_buf_size;
        return self.allocator.alloc(u8, total);
    }

    // ── Signal Handling ─────────────────────────────────────────

    var global_api_ptr: ?*Api = null;

    pub fn installSignalHandlers(self: *Api) void {
        global_api_ptr = self;
        if (comptime builtin.os.tag == .windows) {
            _ = kernel32.SetConsoleCtrlHandler(&windowsCtrlHandler, 1);
        } else {
            const act = std.posix.Sigaction{
                .handler = .{ .handler = posixSignalHandler },
                .mask = mem.zeroes(std.posix.sigset_t),
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
            std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
        }
    }

    fn posixSignalHandler(_: c_int) callconv(.c) void {
        if (global_api_ptr) |api| api.shutdown.store(true, .release);
    }

    fn windowsCtrlHandler(ctrl_type: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
        if (ctrl_type <= 2) { // CTRL_C, CTRL_BREAK, CTRL_CLOSE
            if (global_api_ptr) |api| api.shutdown.store(true, .release);
            return 1;
        }
        return 0;
    }
};

// ═══════════════════════════════════════════════════════════════
//  Thread Entry Points
// ═══════════════════════════════════════════════════════════════

/// Pre-spawned warm worker — blocks until a connection is handed off.
fn warmWorker(api: *Api) void {
    api.warm.mutex.lock();
    api.warm.thread_ready = true;

    // Block until accept thread hands us a connection (or shutdown)
    while (api.warm.pending_conn == null and !api.warm.stopping) {
        api.warm.cond.wait(&api.warm.mutex);
    }

    if (api.warm.stopping) {
        api.warm.thread_ready = false;
        api.warm.mutex.unlock();
        return;
    }

    // Take handoff
    const conn = api.warm.pending_conn.?;
    const block = api.warm.pending_block.?;
    api.warm.pending_conn = null;
    api.warm.pending_block = null;
    api.warm.mutex.unlock();

    // Handle the connection
    handleRequests(api, conn, block);
}

/// Direct handler — spawned as fallback when no warm thread is ready.
fn directHandler(api: *Api, conn: net.Server.Connection, block: []u8) void {
    handleRequests(api, conn, block);
}

// ═══════════════════════════════════════════════════════════════
//  Connection Handler (shared by warm and direct paths)
// ═══════════════════════════════════════════════════════════════

fn handleRequests(api: *Api, conn: net.Server.Connection, block: []u8) void {
    _ = api.active_connections.fetchAdd(1, .monotonic);
    defer _ = api.active_connections.fetchSub(1, .monotonic);
    defer conn.stream.close();
    defer api.allocator.free(block);

    var ctx = Connection.initFromBlock(api, block);

    var read_io = conn.stream.reader(ctx.header_buf);
    var write_io = conn.stream.writer(ctx.write_buf);
    var server = http.Server.init(read_io.interface(), &write_io.interface);

    // Keep-alive loop: handle multiple requests per connection.
    // std.http.Server respects the client's Connection header —
    // receiveHead returns HttpConnectionClosing when done.
    while (true) {
        if (api.shutdown.load(.acquire)) break;

        var request = server.receiveHead() catch |err| {
            switch (err) {
                error.HttpConnectionClosing,
                error.HttpHeadersOversize,
                error.HttpRequestTruncated,
                => {},
                else => log.err("receiveHead: {}", .{err}),
            }
            break;
        };

        // Auth check (if configured)
        if (api.config.auth_token) |token| {
            if (!checkAuth(&request, token)) {
                _ = sendError(&request, .unauthorized, "unauthorized");
                continue;
            }
        }

        const start_ns = std.time.nanoTimestamp();
        const status = ctx.route(&request);
        const elapsed_ns = std.time.nanoTimestamp() - start_ns;
        logRequest(request.head.method, request.head.target, status, elapsed_ns);
    }
}

// ═══════════════════════════════════════════════════════════════
//  Connection — per-connection state (from contiguous block)
// ═══════════════════════════════════════════════════════════════

const Connection = struct {
    api: *Api,
    header_buf: []u8,
    write_buf: []u8,
    body_buf: []u8,
    response_buf: []u8,

    /// Slice a contiguous block into typed buffers. Zero allocation.
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
        return .{
            .api = api,
            .header_buf = hdr,
            .write_buf = wrt,
            .body_buf = bdy,
            .response_buf = rsp,
        };
    }

    // ── Routing ─────────────────────────────────────────────

    const Route = struct {
        method: http.Method,
        path: []const u8,
        handler: *const fn (*Connection, *Request) Status,
    };

    // ┌──────────────────────────────────────────────────────────┐
    // │  ROUTE TABLE — add one line per endpoint                 │
    // │  Comptime dispatch, perfect inlining, zero runtime cost  │
    // └──────────────────────────────────────────────────────────┘
    const routes = [_]Route{
        .{ .method = .GET, .path = "/health", .handler = &handleHealth },
        .{ .method = .POST, .path = "/echo", .handler = &handleEcho }, // example — delete
    };

    fn route(self: *Connection, request: *Request) Status {
        const target = request.head.target;
        const method = request.head.method;

        var path_matched = false;
        inline for (routes) |r| {
            if (mem.eql(u8, target, r.path)) {
                path_matched = true;
                if (method == r.method) {
                    return r.handler(self, request);
                }
            }
        }
        if (path_matched) return sendMethodNotAllowed(request);

        // Prefix-match routes (path params) go here:
        // if (mem.startsWith(u8, target, "/item/")) {
        //     if (method == .GET) return self.handleGetItem(request, target[6..]);
        //     return sendMethodNotAllowed(request);
        // }

        return sendNotFound(request);
    }

    // ── Handlers ────────────────────────────────────────────

    fn handleHealth(self: *Connection, request: *Request) Status {
        const uptime = std.time.timestamp() - self.api.start_time;
        const json = std.fmt.bufPrint(
            self.response_buf,
            "{{\"status\":\"ok\",\"version\":\"0.1.0\",\"uptime\":{d}}}",
            .{uptime},
        ) catch return sendInternalError(request);
        sendJson(request, json, .ok);
        return .ok;
    }

    /// Example handler — echoes back the request body. Delete when adding real routes.
    fn handleEcho(self: *Connection, request: *Request) Status {
        const body = self.readBody(request) catch |err| {
            return switch (err) {
                error.PayloadTooLarge => sendPayloadTooLarge(request),
                else => sendInternalError(request),
            };
        };
        if (body == null) return sendBadRequest(request, "request body required");

        var parsed = std.json.parseFromSlice(std.json.Value, self.api.allocator, body.?, .{}) catch {
            return sendBadRequest(request, "invalid JSON");
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return sendBadRequest(request, "expected JSON object");
        const msg_val = root.object.get("message") orelse
            return sendBadRequest(request, "missing field: message");
        if (msg_val != .string) return sendBadRequest(request, "message must be a string");

        var stream = std.io.fixedBufferStream(self.response_buf);
        const w = stream.writer();
        w.writeAll("{\"echo\":\"") catch return sendInternalError(request);
        writeJsonEscaped(w, msg_val.string) catch return sendInternalError(request);
        w.writeAll("\"}") catch return sendInternalError(request);

        sendJson(request, stream.getWritten(), .ok);
        return .ok;
    }

    // ── Body Reading ────────────────────────────────────────

    /// Read request body into per-connection buffer.
    /// Returns null if no body. Returns error.PayloadTooLarge if oversized.
    fn readBody(self: *Connection, request: *Request) !?[]const u8 {
        const content_length = request.head.content_length orelse return null;
        if (content_length == 0) return null;
        if (content_length > self.api.config.max_body_size) return error.PayloadTooLarge;

        const len: usize = @intCast(content_length);
        var body_reader = request.readerExpectContinue(self.body_buf[len..]) catch
            return error.ReadFailed;
        var dest: [1][]u8 = .{self.body_buf[0..len]};
        body_reader.readVecAll(&dest) catch return error.ReadFailed;
        return self.body_buf[0..len];
    }
};

// ═══════════════════════════════════════════════════════════════
//  Stateless helpers
// ═══════════════════════════════════════════════════════════════

// ── Auth ────────────────────────────────────────────────────────

fn checkAuth(request: *Request, token: []const u8) bool {
    var lines = mem.splitSequence(u8, request.head_buffer, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(line, "authorization:")) {
            const value = mem.trimLeft(u8, line["authorization:".len..], " \t");
            if (mem.startsWith(u8, value, "Bearer ")) {
                return mem.eql(u8, value["Bearer ".len..], token);
            }
        }
    }
    return false;
}

// ── Response Helpers ────────────────────────────────────────────

fn sendJson(request: *Request, json: []const u8, status: Status) void {
    request.respond(json, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    }) catch {};
}

fn sendError(request: *Request, status: Status, message: []const u8) Status {
    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch
        "{\"error\":\"internal error\"}";
    sendJson(request, json, status);
    return status;
}

fn sendNotFound(request: *Request) Status {
    return sendError(request, .not_found, "not found");
}

fn sendMethodNotAllowed(request: *Request) Status {
    return sendError(request, .method_not_allowed, "method not allowed");
}

fn sendInternalError(request: *Request) Status {
    return sendError(request, .internal_server_error, "internal error");
}

fn sendPayloadTooLarge(request: *Request) Status {
    return sendError(request, .payload_too_large, "request body too large");
}

fn sendBadRequest(request: *Request, message: []const u8) Status {
    return sendError(request, .bad_request, message);
}

// ── Logging ─────────────────────────────────────────────────────

fn logRequest(method: http.Method, target: []const u8, status: Status, elapsed_ns: i128) void {
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const method_str = switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .OPTIONS => "OPTIONS",
        .HEAD => "HEAD",
        else => "???",
    };
    log.info("{s} {s} {d} {d:.2}ms", .{
        method_str,
        target,
        @intFromEnum(status),
        elapsed_ms,
    });
}

// ── JSON String Escaping ────────────────────────────────────────

/// Escape a string for inclusion in a JSON value (between quotes).
pub fn writeJsonEscaped(writer: anytype, data: []const u8) !void {
    for (data) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
