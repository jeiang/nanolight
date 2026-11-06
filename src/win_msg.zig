//! Windows: Nanolight's message-only window, where the system sends the
//! hot key (WM_HOTKEY, hotkey_win.zig) and a second copy sends its command
//! (`nanolight --toggle`, a newer copy asking this one to quit: single.zig).
//! nanoui's message loop dispatches to it like to any window of the thread.
//! Made once, by `single_win.claim`, after it looked for another copy's.
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

/// Where the window's messages go.
pub const Handlers = struct {
    hotkey: *const fn () void,
    command: *const fn (cmd: single.Command) void,
};

var hwnd: ?HWND = null;
/// Set with `hwnd` (a window procedure has no context of its own).
var handlers: Handlers = undefined;

fn proc(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    if (msg == wm_hotkey) {
        handlers.hotkey();
    } else if (single.Command.fromMessage(msg)) |cmd| {
        handlers.command(cmd);
    } else return DefWindowProcW(h, msg, wp, lp);
    return 0;
}

/// Makes ours, once, after `other` (else ours would be found as the other
/// copy's).
pub fn create(on: Handlers) ?HWND {
    std.debug.assert(hwnd == null);
    handlers = on;
    const inst = GetModuleHandleW(null);
    _ = RegisterClassExW(
        &.{ .lpfnWndProc = &proc, .hInstance = inst, .lpszClassName = class_name },
    );
    hwnd = CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, message_parent, null, inst, null);
    return hwnd;
}

/// Ours, once `create` made it.
pub fn window() ?HWND {
    return hwnd;
}

/// Another running copy's window.
pub fn other() ?HWND {
    return FindWindowExW(message_parent, null, class_name, null);
}

pub fn post(to: HWND, cmd: single.Command) bool {
    return PostMessageW(to, cmd.message(), 0, 0) != 0;
}
