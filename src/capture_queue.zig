/// Capture Queue — routes WGC calls through a dedicated COM-initialized thread
///
/// HTTP workers enqueue requests, capture thread processes them.
/// Solves COM apartment threading issues with WGC from worker threads.
///
const std = @import("std");
const nuclear = @import("nuclear_capture.zig");

const windows = std.os.windows;
const WINAPI = std.builtin.CallingConvention.winapi;

// Windows event handle
const HANDLE = windows.HANDLE;
extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*anyopaque,
    bManualReset: i32,
    bInitialState: i32,
    lpName: ?[*:0]const u16,
) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(WINAPI) i32;
extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(WINAPI) i32;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(WINAPI) u32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(WINAPI) i32;

const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;
const INFINITE: u32 = 0xFFFFFFFF;

const MAX_QUEUE = 32;

pub const CaptureRequest = struct {
    hwnd: usize,
    result: ?[]u8 = null,
    err: ?anyerror = null,
    done_event: HANDLE,
    allocator: std.mem.Allocator,
};

pub const CaptureQueue = struct {
    queue: [MAX_QUEUE]*CaptureRequest,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    work_event: ?HANDLE = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !CaptureQueue {
        const work_event = CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
        
        return CaptureQueue{
            .queue = undefined,
            .work_event = work_event,
            .allocator = allocator,
            .thread = null, // Thread started after global assignment
        };
    }
    
    pub fn startThread(self: *CaptureQueue) !void {
        self.thread = try std.Thread.spawn(.{}, captureThread, .{self});
    }

    pub fn deinit(self: *CaptureQueue) void {
        // Signal shutdown
        self.shutdown.store(true, .release);
        if (self.work_event) |ev| {
            _ = SetEvent(ev);
        }
        
        // Wait for thread
        if (self.thread) |t| {
            t.join();
        }
        
        // Close event
        if (self.work_event) |ev| {
            _ = CloseHandle(ev);
        }
    }

    /// Enqueue a capture request and wait for completion
    /// Returns JPEG data (caller must free) or error
    pub fn capture(self: *CaptureQueue, allocator: std.mem.Allocator, hwnd: usize) ![]u8 {
        // Create completion event for this request
        const done_event = CreateEventW(null, 1, 0, null) orelse return error.CreateEventFailed;
        defer _ = CloseHandle(done_event);

        var request = CaptureRequest{
            .hwnd = hwnd,
            .done_event = done_event,
            .allocator = allocator,
        };

        // Enqueue
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count >= MAX_QUEUE) {
                return error.QueueFull;
            }

            self.queue[self.tail] = &request;
            self.tail = (self.tail + 1) % MAX_QUEUE;
            self.count += 1;
            std.log.info("Enqueued request, count={}", .{self.count});
        }

        // Signal worker
        if (self.work_event) |ev| {
            std.log.info("Signaling work event", .{});
            _ = SetEvent(ev);
        }

        // Wait for completion (5 second timeout)
        const wait_result = WaitForSingleObject(done_event, 5000);
        if (wait_result == WAIT_TIMEOUT) {
            return error.CaptureTimeout;
        }

        // Check result
        if (request.err) |e| {
            return e;
        }

        return request.result orelse error.NoResult;
    }

    fn captureThread(self: *CaptureQueue) void {
        std.log.info("Capture queue thread started", .{});
        
        // Initialize COM on this thread (required for WGC)
        const wgc = @import("nuclear/wgc.zig");
        wgc.init() catch |err| {
            std.log.err("Capture thread COM init failed: {}", .{err});
            return;
        };
        std.log.info("Capture queue thread COM initialized", .{});
        
        // Initialize nuclear pipeline ON THIS THREAD (D3D11 + WGC must be same thread)
        nuclear.init(self.allocator, 1568, 882) catch |err| {
            std.log.err("Nuclear pipeline init on capture thread failed: {}", .{err});
            return;
        };
        std.log.info("Nuclear pipeline initialized on capture thread", .{});
        
        while (!self.shutdown.load(.acquire)) {
            // Wait for work
            if (self.work_event) |ev| {
                _ = WaitForSingleObject(ev, 100); // 100ms timeout for shutdown check
            }

            // Process all pending requests
            while (true) {
                const request = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    if (self.count == 0) break :blk null;

                    const req = self.queue[self.head];
                    self.head = (self.head + 1) % MAX_QUEUE;
                    self.count -= 1;
                    break :blk req;
                };

                if (request == null) break;
                const req = request.?;

                std.log.info("Queue thread processing hwnd {}", .{req.hwnd});
                
                // Do the actual capture (on this COM-initialized thread)
                const result = nuclear.capture(req.allocator, req.hwnd);
                if (result) |data| {
                    std.log.info("Queue thread capture SUCCESS: {} bytes", .{data.len});
                    req.result = data;
                } else |err| {
                    std.log.err("Queue thread capture FAILED: {}", .{err});
                    req.err = err;
                }

                // Signal completion
                _ = SetEvent(req.done_event);
            }
        }

        std.log.info("Capture queue thread exiting", .{});
    }
};

// Global capture queue instance
pub var g_queue: ?CaptureQueue = null;

pub fn initQueue(allocator: std.mem.Allocator) !void {
    if (g_queue != null) return;
    g_queue = try CaptureQueue.init(allocator);
    // Start thread AFTER g_queue is set (thread uses pointer to g_queue)
    try g_queue.?.startThread();
}

pub fn deinitQueue() void {
    if (g_queue) |*q| {
        q.deinit();
        g_queue = null;
    }
}

/// Thread-safe capture via queue
pub fn queuedCapture(allocator: std.mem.Allocator, hwnd: usize) ![]u8 {
    std.log.info("queuedCapture called for hwnd {}", .{hwnd});
    if (g_queue) |*q| {
        std.log.info("Queue exists, calling capture", .{});
        return q.capture(allocator, hwnd);
    }
    std.log.err("Queue not initialized!", .{});
    return error.QueueNotInitialized;
}
