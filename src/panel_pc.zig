//! The panel's window on Windows and Linux: borderless, over other windows,
//! out of the taskbar, exactly the panel's size (it follows the panel's
//! height). nanoui draws the panel on it; there is no system vibrancy
//! under it, so the panel paints its own fill. The window is transparent
//! (nanoui's `transparent`): only the rounded panel shows, nothing square
//! behind its corners.
//!
//! X11: the window manager says which window is active (GTK can't while
//! the hot key's grab holds the keyboard), over an Xlib connection of the
//! panel's own whose socket nanoui's loop watches; when another window
//! becomes it, the panel goes, as the Mac's popover does.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const chrome = @import("chrome.zig");
const x11 = @import("hotkey_x11.zig");
const windows = builtin.os.tag == .windows;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Before the app: on Linux GTK 3, where a window can be put somewhere
/// (GTK 4 lets only the compositor place one), unless the user asked for
/// another.
pub fn prepare() void {
    if (!windows and std.c.getenv("NANOUI_GTK") == null) _ = setenv("NANOUI_GTK", "3", 0);
}

/// The window, from the panel's size.
pub fn adjust(o: *nanoui.WindowOptions) void {
    o.decorations = false;
    o.skip_taskbar = true;
    o.always_on_top = true;
    o.transparent = true;
}

/// The panel fills the window: no margin, and an entrance of its own.
pub fn setup(w: *nanoui.Window) chrome.Fit {
    if (!windows and x11.onX11()) {
        window = w;
        follow();
    }
    return .{};
}

/// Whether the panel shows and has the keys: on X11 by the window
/// manager's word.
pub fn showing(w: *nanoui.Window) bool {
    if (!w.isVisible()) return false;
    if (!windows) if (panelActive()) |active| return active;
    return w.isFocused();
}

/// The panel lost the keys: it goes, as another window took them.
pub fn lostKeys(w: *nanoui.Window) void {
    if (w.isVisible()) w.hide();
}

/// A fifth of the way down the screen, centered.
pub fn place(w: *nanoui.Window) void {
    const m = w.monitorSize();
    // A fifth of the way down, but high enough that the panel at its
    // tallest (a command's screen) stays on a small screen.
    w.setPosition(
        @max(0, (m[0] - chrome.width) / 2),
        @max(0, @min(m[1] * 0.2, m[1] - chrome.max_height - 16)),
    );
    // X11: the panel's user time is the hot key's, set before it maps, so a
    // window manager that prevents focus stealing (Xfce, KDE) lets it take
    // the keys from the window that had them.
    if (windows) return;
    const t = x11.lastPress();
    if (t == 0) return;
    const l = lib orelse return;
    const gw = gdkWindow(l, w) orelse return;
    l.gdk_x11_window_set_user_time(gw, t);
}

pub fn resize(w: *nanoui.Window, h: f32) void {
    const height = @ceil(h);
    // Linux: GTK 3 under Wayland can keep a borderless window at its old
    // size after `gtk_window_resize`, and the bottom of the panel is cut
    // off. A size request of the new height makes it take it.
    if (!windows) w.setMinSize(chrome.width, height);
    w.setSize(chrome.width, height);
}

/// After `show`: on X11 the window manager is given the hot key's time, or
/// it may refuse the panel the focus (focus stealing prevention).
pub fn shown(w: *nanoui.Window) void {
    if (windows) return;
    const t = x11.lastPress();
    if (t == 0) return;
    const l = lib orelse return;
    const win = w.gtkwindow orelse return;
    l.gtk_window_present_with_time(@ptrCast(win), t);
}

const Display = opaque {};
const XWindow = c_ulong;
/// XEvent: a union 24 longs long; `type` first.
const XEvent = extern struct { type: c_int, pad: [188]u8 = undefined };
const property_notify: c_int = 28;
const property_change_mask: c_long = 1 << 22;
/// XPropertyEvent's `atom`, after type, serial, send_event, display and window.
const atom_offset = 5 * @sizeOf(c_long);
/// XA_WINDOW.
const xa_window: c_ulong = 33;

/// GTK's, GDK's and Xlib's functions the panel uses on X11, looked up once
/// from the libraries GTK 3 has loaded (and libX11).
const Lib = struct {
    gtk_widget_get_window: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gtk_window_present_with_time: *const fn (*anyopaque, u32) callconv(.c) void,
    gdk_x11_window_get_xid: *const fn (*anyopaque) callconv(.c) XWindow,
    gdk_x11_window_set_user_time: *const fn (*anyopaque, u32) callconv(.c) void,
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) XWindow,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XSelectInput: *const fn (*Display, XWindow, c_long) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) c_ulong,
    XGetWindowProperty: *const fn (
        *Display,
        XWindow,
        c_ulong,
        c_long,
        c_long,
        c_int,
        c_ulong,
        *c_ulong,
        *c_int,
        *c_ulong,
        *c_ulong,
        *?[*]u8,
    ) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
};

var lib: ?Lib = null;
var window: ?*nanoui.Window = null;
var dpy: ?*Display = null;
var watch: ?nanoui.fdwatch.Watch = null;
var net_active: c_ulong = 0;

/// The functions, or null (logged) when a library or one of them is
/// missing: GTK 4 asked for (`NANOUI_GTK`), or no libX11.
fn load() ?Lib {
    const gtk = std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .NOLOAD = true });
    const gdk = std.c.dlopen("libgdk-3.so.0", .{ .NOW = true, .NOLOAD = true });
    const xlib = std.c.dlopen("libX11.so.6", .{ .NOW = true });
    var v: Lib = undefined;
    inline for (@typeInfo(Lib).@"struct".field_names) |name| {
        const from = if (std.mem.startsWith(u8, name, "gtk_"))
            gtk
        else if (std.mem.startsWith(u8, name, "gdk_")) gdk else xlib;
        const sym = std.c.dlsym(from orelse return missing(name), name) orelse return missing(name);
        @field(v, name) = @ptrCast(@alignCast(sym));
    }
    return v;
}

fn missing(name: []const u8) ?Lib {
    std.log.warn("nanolight: no {s} (GTK 3 on X11): the panel won't follow the focus", .{name});
    return null;
}

/// The panel's own connection: the root window's property changes (the
/// active window) delivered to it, its socket watched.
fn follow() void {
    const l = load() orelse return;
    lib = l;
    const d = l.XOpenDisplay(null) orelse {
        std.log.warn("nanolight: no X display: the panel won't follow the focus", .{});
        return;
    };
    watch = nanoui.fdwatch.readable(l.XConnectionNumber(d), null, readable) catch |e| {
        std.log.warn("nanolight: X can't be watched ({s}): the panel won't follow the focus", .{
            @errorName(e),
        });
        _ = l.XCloseDisplay(d);
        return;
    };
    dpy = d;
    net_active = l.XInternAtom(d, "_NET_ACTIVE_WINDOW", 0);
    _ = l.XSelectInput(d, l.XDefaultRootWindow(d), property_change_mask);
}

fn readable(_: ?*anyopaque) callconv(.c) void {
    const l = lib orelse return;
    const d = dpy orelse return;
    while (l.XPending(d) > 0) {
        var ev: XEvent = .{ .type = 0 };
        _ = l.XNextEvent(d, &ev);
        if (ev.type != property_notify) continue;
        const bytes = std.mem.asBytes(&ev);
        const atom = std.mem.readInt(c_ulong, bytes[atom_offset..][0..@sizeOf(c_ulong)], .little);
        if (atom == net_active and panelActive() == false) if (window) |w| lostKeys(w);
    }
}

fn gdkWindow(l: Lib, w: *nanoui.Window) ?*anyopaque {
    const win = w.gtkwindow orelse return null;
    return l.gtk_widget_get_window(@ptrCast(win));
}

/// Whether the window manager has the panel as its active window; null
/// when that can't be known (no X, the panel not yet shown, a window
/// manager without _NET_ACTIVE_WINDOW).
fn panelActive() ?bool {
    const l = lib orelse return null;
    const d = dpy orelse return null;
    const w = window orelse return null;
    const ours = l.gdk_x11_window_get_xid(gdkWindow(l, w) orelse return null);
    if (ours == 0) return null;
    var kind: c_ulong = 0;
    var format: c_int = 0;
    var n: c_ulong = 0;
    var left: c_ulong = 0;
    var data: ?[*]u8 = null;
    if (l.XGetWindowProperty(
        d,
        l.XDefaultRootWindow(d),
        net_active,
        0,
        1,
        0,
        xa_window,
        &kind,
        &format,
        &n,
        &left,
        &data,
    ) != 0) return null;
    defer _ = l.XFree(data);
    const bytes = data orelse return null;
    if (n == 0 or format != 32) return null;
    const active = std.mem.readInt(c_ulong, bytes[0..@sizeOf(c_ulong)], .little);
    return active == ours;
}
