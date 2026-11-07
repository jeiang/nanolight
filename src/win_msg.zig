//! Windows: Nanolight's message-only window, where the system sends the
//! hot key (WM_HOTKEY, hotkey_win.zig) and a second copy sends its command
//! (`nanolight --toggle`, a newer copy asking this one to quit: single.zig).
//! nanoui's message loop dispatches to it like to any window of the thread.
//! Made on first use (`ensure`), by `single_win.claim` or
//! `hotkey_win.register`, whichever runs first.
const std = @import("std");
const single = @import("single.zig");

pub const HWND = *opaque {};
const HINSTANCE = ?*anyopaque;
const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: HINSTANCE = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    ex: u32,
    class: [*:0]const u16,
    name: ?[*:0]const u16,
    style: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    parent: ?HWND,
    menu: ?*anyopaque,
    inst: HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn FindWindowExW(
    parent: ?HWND,
    after: ?HWND,
    class: [*:0]const u16,
    name: ?[*:0]const u16,
) callconv(.winapi) ?HWND;
extern "user32" fn PostMessageW(?HWND, u32, usize, isize) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) HINSTANCE;

const wm_hotkey: u32 = 0x0312;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("NanolightMessages");
/// HWND_MESSAGE: the parent of message-only windows.
const message_parent: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

/// What the window's messages call, each set by its owner.
pub const Handlers = struct {
    hotkey: ?*const fn () void = null,
    command: ?*const fn (cmd: single.Command) void = null,
};

var hwnd: ?HWND = null;
/// A window procedure has no context of its own.
var handlers: Handlers = .{};

fn proc(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    if (msg == wm_hotkey) {
        if (handlers.hotkey) |f| f();
    } else if (single.Command.fromMessage(msg)) |cmd| {
        if (handlers.command) |f| f(cmd);
    } else return DefWindowProcW(h, msg, wp, lp);
    return 0;
}

/// Ours, made on the first call; `on`'s handlers are kept (those it leaves
/// null stay as they were). Null when it can't be made.
pub fn ensure(on: Handlers) ?HWND {
    if (on.hotkey) |f| handlers.hotkey = f;
    if (on.command) |f| handlers.command = f;
    if (hwnd) |h| return h;
    const inst = GetModuleHandleW(null);
    _ = RegisterClassExW(
        &.{ .lpfnWndProc = &proc, .hInstance = inst, .lpszClassName = class_name },
    );
    hwnd = CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, message_parent, null, inst, null);
    return hwnd;
}

/// Ours, once `ensure` made it.
pub fn window() ?HWND {
    return hwnd;
}

/// Another running copy's window: ours, whenever it was made, is skipped.
pub fn other() ?HWND {
    const first = FindWindowExW(message_parent, null, class_name, null);
    if (first == null or first != hwnd) return first;
    return FindWindowExW(message_parent, hwnd, class_name, null);
}

pub fn post(to: HWND, cmd: single.Command) bool {
    return PostMessageW(to, cmd.message(), 0, 0) != 0;
}
