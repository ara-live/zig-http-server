//! Win32 Window Enumeration - Pure Zig
//!
//! List visible windows with their handles, titles, and process names.

const std = @import("std");
const windows = std.os.windows;

const HWND = windows.HWND;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const LPARAM = windows.LPARAM;

const user32 = struct {
    extern "user32" fn EnumWindows(lpEnumFunc: *const fn (HWND, LPARAM) callconv(.winapi) BOOL, lParam: LPARAM) callconv(.winapi) BOOL;
    extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
    extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;
    extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) c_int;
    extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(.winapi) DWORD;
    extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
};

const kernel32_ext = struct {
    extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
};

const psapi = struct {
    extern "psapi" fn GetModuleFileNameExW(hProcess: HANDLE, hModule: ?HANDLE, lpFilename: [*]u16, nSize: DWORD) callconv(.winapi) DWORD;
};

const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

pub const WindowInfo = struct {
    hwnd: usize,
    title: []const u8,
    process: []const u8,
};

pub const WindowList = struct {
    windows: []WindowInfo,
    foreground_hwnd: usize,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *WindowList) void {
        self.arena.deinit();
    }
};

const EnumContext = struct {
    list: *std.ArrayList(WindowInfo),
    arena: *std.heap.ArenaAllocator,
};

fn enumCallback(hwnd: HWND, lparam: LPARAM) callconv(.winapi) BOOL {
    const ctx: *EnumContext = @ptrFromInt(@as(usize, @bitCast(lparam)));

    if (user32.IsWindowVisible(hwnd) == 0) return 1;

    const title_len = user32.GetWindowTextLengthW(hwnd);
    if (title_len == 0) return 1;

    // Get title
    var title_buf: [256]u16 = undefined;
    const actual_len = user32.GetWindowTextW(hwnd, &title_buf, 256);
    if (actual_len == 0) return 1;

    const title = std.unicode.utf16LeToUtf8Alloc(ctx.arena.allocator(), title_buf[0..@intCast(actual_len)]) catch return 1;

    // Get process name
    var pid: DWORD = 0;
    _ = user32.GetWindowThreadProcessId(hwnd, &pid);

    var process_name: []const u8 = "";
    if (kernel32_ext.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)) |handle| {
        defer _ = kernel32_ext.CloseHandle(handle);
        var exe_buf: [260]u16 = undefined;
        const exe_len = psapi.GetModuleFileNameExW(handle, null, &exe_buf, 260);
        if (exe_len > 0) {
            const full_path = std.unicode.utf16LeToUtf8Alloc(ctx.arena.allocator(), exe_buf[0..exe_len]) catch "";
            if (std.mem.lastIndexOf(u8, full_path, "\\")) |idx| {
                process_name = full_path[idx + 1 ..];
            } else {
                process_name = full_path;
            }
        }
    }

    ctx.list.append(ctx.arena.allocator(), .{
        .hwnd = @intFromPtr(hwnd),
        .title = title,
        .process = process_name,
    }) catch return 1;

    return 1;
}

pub fn listWindows(allocator: std.mem.Allocator) !WindowList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var list = std.ArrayList(WindowInfo).initCapacity(arena.allocator(), 32) catch return error.OutOfMemory;
    var ctx = EnumContext{
        .list = &list,
        .arena = &arena,
    };

    _ = user32.EnumWindows(&enumCallback, @bitCast(@intFromPtr(&ctx)));

    const fg = user32.GetForegroundWindow();
    const fg_hwnd: usize = if (fg) |h| @intFromPtr(h) else 0;

    return .{
        .windows = try ctx.list.toOwnedSlice(arena.allocator()),
        .foreground_hwnd = fg_hwnd,
        .arena = arena,
    };
}

pub fn getForegroundWindow() usize {
    const fg = user32.GetForegroundWindow();
    return if (fg) |h| @intFromPtr(h) else 0;
}
