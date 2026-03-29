/// ScreenMaster DLL bindings + Win32 window enumeration
const std = @import("std");
const windows = std.os.windows;

const HWND = windows.HWND;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const LPARAM = windows.LPARAM;

// ═══════════════════════════════════════════════════════════════
//  ScreenMaster DLL Bindings
// ═══════════════════════════════════════════════════════════════

pub const ImageFormat = enum(c_int) {
    png = 0,
    jpeg = 1,
};

var dll_handle: ?windows.HMODULE = null;
var fn_start_capture: ?*const fn (HWND) callconv(.winapi) c_int = null;
var fn_save_frame: ?*const fn (HWND, [*:0]const u16, c_int) callconv(.winapi) c_int = null;

pub fn loadDll(path: []const u8) !void {
    // Convert path to wide string
    var wide_path: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_path, path) catch return error.InvalidPath;
    wide_path[len] = 0;

    dll_handle = windows.kernel32.LoadLibraryW(@ptrCast(&wide_path));
    if (dll_handle == null) return error.DllLoadFailed;

    fn_start_capture = @ptrCast(windows.kernel32.GetProcAddress(dll_handle.?, "StartCapture") orelse return error.FunctionNotFound);
    fn_save_frame = @ptrCast(windows.kernel32.GetProcAddress(dll_handle.?, "SaveFrameToFile") orelse return error.FunctionNotFound);
}

pub fn unloadDll() void {
    if (dll_handle) |h| {
        _ = windows.kernel32.FreeLibrary(h);
        dll_handle = null;
    }
}

pub fn startCapture(hwnd: usize) !void {
    const f = fn_start_capture orelse return error.DllNotLoaded;
    const result = f(@ptrFromInt(hwnd));
    if (result != 1) return error.CaptureSessionFailed;
}

pub fn saveFrame(hwnd: usize, path: []const u8, format: ImageFormat) !void {
    const f = fn_save_frame orelse return error.DllNotLoaded;
    
    // Convert path to wide string
    var wide_path: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide_path, path) catch return error.InvalidPath;
    wide_path[len] = 0;

    const result = f(@ptrFromInt(hwnd), @ptrCast(&wide_path), @intFromEnum(format));
    if (result != 1) return error.SaveFrameFailed;
}

// ═══════════════════════════════════════════════════════════════
//  Win32 Window Enumeration
// ═══════════════════════════════════════════════════════════════

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
    list: std.ArrayList(WindowInfo),
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
            // Extract filename from path
            if (std.mem.lastIndexOf(u8, full_path, "\\")) |idx| {
                process_name = full_path[idx + 1 ..];
            } else {
                process_name = full_path;
            }
        }
    }

    ctx.list.append(.{
        .hwnd = @intFromPtr(hwnd),
        .title = title,
        .process = process_name,
    }) catch return 1;

    return 1;
}

pub fn listWindows(allocator: std.mem.Allocator) !WindowList {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var ctx = EnumContext{
        .list = std.ArrayList(WindowInfo).init(arena.allocator()),
        .arena = &arena,
    };

    _ = user32.EnumWindows(&enumCallback, @bitCast(@intFromPtr(&ctx)));

    const fg = user32.GetForegroundWindow();
    const fg_hwnd: usize = if (fg) |h| @intFromPtr(h) else 0;

    return .{
        .windows = try ctx.list.toOwnedSlice(),
        .foreground_hwnd = fg_hwnd,
        .arena = arena,
    };
}

pub fn getForegroundWindow() usize {
    const fg = user32.GetForegroundWindow();
    return if (fg) |h| @intFromPtr(h) else 0;
}
