//! Linux: the panel's key, from any app, on X11: a passive grab of Space
//! with the choice's modifiers on the root window, over an Xlib connection
//! of Nanolight's own (x11.zig), whose socket nanoui's loop watches.
//! Wayland has no such grab for apps: there the desktop's keyboard settings
//! run `nanolight --toggle` (display.zig says which session this is).
const std = @import("std");
const nanoui = @import("nanoui");
const keys = @import("keys.zig");
const display = @import("display.zig");
const x11 = @import("x11.zig");
const Choice = keys.Choice;

/// XKeyEvent's `time`, after type, serial, send_event, display, window,
/// root and subwindow.
const time_offset = 7 * @sizeOf(c_long);

const shift_mask: c_uint = 1;
const lock_mask: c_uint = 2;
const control_mask: c_uint = 4;
const mod1_mask: c_uint = 8; // Alt
const mod2_mask: c_uint = 16; // Num Lock
const key_press: c_int = 2;
const xk_space: c_ulong = 0x20;
/// Caps Lock and Num Lock are modifiers too: the key is grabbed with each.
const locks = [_]c_uint{ 0, lock_mask, mod2_mask, lock_mask | mod2_mask };

var dpy: ?*x11.Display = null;
var watch: ?nanoui.fdwatch.Watch = null;
var pressed: ?keys.Pressed = null;
var grabbed: ?c_uint = null;
var failed = false;

fn onError(_: *x11.Display, _: *anyopaque) callconv(.c) c_int {
    failed = true;
    return 0;
}

fn readable(_: ?*anyopaque) callconv(.c) void {
    const xl = x11.load() orelse return;
    const d = dpy orelse return;
    while (xl.XPending(d) > 0) {
        var ev: x11.Event = .{ .pad = @splat(0) };
        _ = xl.XNextEvent(d, &ev);
        if (ev.type != key_press) continue;
        const bytes = std.mem.asBytes(&ev);
        x11.last_press = @truncate(
            std.mem.readInt(c_ulong, bytes[time_offset..][0..@sizeOf(c_ulong)], .little),
        );
        if (pressed) |p| p.func(p.ctx);
    }
}

/// Nanolight's own connection, opened once, its socket watched: a key
/// grabbed on a connection nobody reads would never fire.
fn open(xl: x11.Lib) !*x11.Display {
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
    switch (display.session()) {
        .x11 => {},
        .wayland => return error.Wayland,
        .none => return error.NoDisplay,
    }
    const xl = x11.load() orelse return error.NoX11;
    const d = try open(xl);
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    unregister();
    const m = modifiers(choice);
    // Another client holding the key answers BadAccess, asynchronously:
    // caught here, with GDK's handler put back after.
    failed = false;
    const before = xl.XSetErrorHandler(&onError);
    for (locks) |e| _ = xl.XGrabKey(d, code, m | e, root, 0, 1, 1);
    _ = xl.XSync(d, 0);
    _ = xl.XSetErrorHandler(before);
    if (failed) {
        for (locks) |e| _ = xl.XUngrabKey(d, code, m | e, root);
        _ = xl.XSync(d, 0);
        return error.HotKeyTaken;
    }
    grabbed = m;
}

/// Gives the key back (while another is recorded); `register` takes one again.
pub fn unregister() void {
    const m = grabbed orelse return;
    grabbed = null;
    const xl = x11.load() orelse return;
    const d = dpy orelse return;
    const root = xl.XDefaultRootWindow(d);
    const code: c_int = xl.XKeysymToKeycode(d, xk_space);
    for (locks) |e| _ = xl.XUngrabKey(d, code, m | e, root);
    _ = xl.XSync(d, 0);
}

/// Whether another client (the window manager: Alt Space is its window
/// menu on many desktops) holds `choice`: grabbed and let go again.
pub fn taken(choice: Choice) bool {
    if (display.session() != .x11) return false;
    const m = modifiers(choice);
    if (grabbed == m) return false;
    const xl = x11.load() orelse return false;
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
