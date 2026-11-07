//! Linux: the panel's key, from any app, on X11: a passive grab of Space
//! with the choice's modifiers on the root window, over an Xlib connection
//! of Nanolight's own (libX11, opened with dlopen), whose socket nanoui's
//! loop watches. Wayland has no such grab for apps: there the desktop's
//! keyboard settings run `nanolight --toggle`.
const std = @import("std");
const nanoui = @import("nanoui");
const keys = @import("keys.zig");
const Choice = keys.Choice;

const Display = opaque {};
const Window = c_ulong;
/// XEvent: a union 24 longs long; `type` first.
const XEvent = extern struct { type: c_int, pad: [188]u8 = undefined };
/// XKeyEvent's `time`, after type, serial, send_event, display, window,
/// root and subwindow.
const time_offset = 7 * @sizeOf(c_long);
const ErrorHandler = *const fn (*Display, *anyopaque) callconv(.c) c_int;

const X = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) Window,
    XKeysymToKeycode: *const fn (*Display, c_ulong) callconv(.c) u8,
    XGrabKey: *const fn (*Display, c_int, c_uint, Window, c_int, c_int, c_int) callconv(.c) c_int,
    XUngrabKey: *const fn (*Display, c_int, c_uint, Window) callconv(.c) c_int,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (?ErrorHandler) callconv(.c) ?ErrorHandler,
};

const shift_mask: c_uint = 1;
const lock_mask: c_uint = 2;
const control_mask: c_uint = 4;
const mod1_mask: c_uint = 8; // Alt
const mod2_mask: c_uint = 16; // Num Lock
const key_press: c_int = 2;
const xk_space: c_ulong = 0x20;

var x: ?X = null;
var dpy: ?*Display = null;
var watch: ?nanoui.fdwatch.Watch = null;
var pressed: ?keys.Pressed = null;
var grabbed: ?c_uint = null;
var failed = false;
/// The X server's time of the last press (`lastPress`).
var last_time: u32 = 0;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

pub fn onX11() bool {
    return !std.mem.eql(u8, env("XDG_SESSION_TYPE") orelse "", "wayland") and
        env("DISPLAY") != null;
}

/// The X server's time of the last press of the key, 0 before one: window
/// managers refuse focus to a window shown without a recent one.
pub fn lastPress() u32 {
    return last_time;
}

fn load() ?X {
    if (x) |v| return v;
    const lib = std.c.dlopen("libX11.so.6", .{ .NOW = true }) orelse return null;
    var v: X = undefined;
    inline for (@typeInfo(X).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse return null;
        @field(v, name) = @ptrCast(@alignCast(sym));
    }
    x = v;
    return v;
}

fn onError(_: *Display, _: *anyopaque) callconv(.c) c_int {
    failed = true;
    return 0;
}

fn readable(_: ?*anyopaque) callconv(.c) void {
    const xl = x orelse return;
    const d = dpy orelse return;
    while (xl.XPending(d) > 0) {
        var ev: XEvent = .{ .type = 0 };
        _ = xl.XNextEvent(d, &ev);
        if (ev.type != key_press) continue;
        const bytes = std.mem.asBytes(&ev);
        last_time = @truncate(
            std.mem.readInt(c_ulong, bytes[time_offset..][0..@sizeOf(c_ulong)], .little),
        );
        if (pressed) |p| p.func(p.ctx);
    }
}

/// Nanolight's own connection, opened once, its socket watched: a key
/// grabbed on a connection nobody reads would never fire.
fn open(xl: X) !*Display {
    if (dpy) |d| return d;
    const d = xl.XOpenDisplay(null) orelse return error.NoDisplay;
    watch = nanoui.fdwatch.readable(xl.XConnectionNumber(d), null, readable) catch |e| {
        _ = xl.XCloseDisplay(d);
        return e;
    };
    dpy = d;
    return d;
}

/// The modifiers to grab Space with: a PC offers no other key (`keys.any_key`).
fn modifiers(choice: Choice) c_uint {
    std.debug.assert(choice.available());
    const p = choice.pc();
    var m: c_uint = 0;
    if (p.ctrl) m |= control_mask;
    if (p.alt) m |= mod1_mask;
    if (p.shift) m |= shift_mask;
    return m;
}

pub fn register(choice: Choice, on: keys.Pressed) !void {
    pressed = on;
    if (!onX11()) return error.Wayland;
    const xl = load() orelse return error.NoX11;
    const d = try open(xl);
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    // Caps Lock and Num Lock are modifiers too: grab with each.
    const extra = [_]c_uint{ 0, lock_mask, mod2_mask, lock_mask | mod2_mask };
    if (grabbed) |m| for (extra) |e| {
        _ = xl.XUngrabKey(d, code, m | e, root);
    };
    grabbed = null;
    const m = modifiers(choice);
    // Another client holding the key answers BadAccess, asynchronously:
    // caught here, with GDK's handler put back after.
    failed = false;
    const before = xl.XSetErrorHandler(&onError);
    for (extra) |e| _ = xl.XGrabKey(d, code, m | e, root, 0, 1, 1);
    _ = xl.XSync(d, 0);
    _ = xl.XSetErrorHandler(before);
    if (failed) {
        for (extra) |e| _ = xl.XUngrabKey(d, code, m | e, root);
        _ = xl.XSync(d, 0);
        return error.HotKeyTaken;
    }
    grabbed = m;
}

/// Whether another client (the window manager: Alt Space is its window
/// menu on many desktops) holds `choice`: grabbed and let go again.
pub fn taken(choice: Choice) bool {
    if (!onX11()) return false;
    const m = modifiers(choice);
    if (grabbed == m) return false;
    const xl = load() orelse return false;
    // No connection, no grab to test: `register` says why.
    const d = open(xl) catch return false;
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    failed = false;
    const before = xl.XSetErrorHandler(&onError);
    _ = xl.XGrabKey(d, code, m, root, 0, 1, 1);
    _ = xl.XSync(d, 0);
    _ = xl.XSetErrorHandler(before);
    const held = failed;
    if (!held) _ = xl.XUngrabKey(d, code, m, root);
    _ = xl.XSync(d, 0);
    return held;
}
