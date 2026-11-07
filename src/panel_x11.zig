//! The panel's window on X11: borderless, over other windows,
//! out of the taskbar, exactly the panel's size (it follows the panel's
//! height). nanoui draws the panel on it; there is no system vibrancy
//! under it, so the panel paints its own fill. The window is transparent
//! (nanoui's `transparent`): only the rounded panel shows, nothing square
//! behind its corners.
//!
//! X11 (display.zig's session): the window manager says which window is
//! active (GTK can't while the hot key's grab holds the keyboard), over an
//! Xlib connection of the panel's own whose socket nanoui's loop watches;
//! when another window becomes it, the panel goes, as the Mac's popover does.
const std = @import("std");
const nanoui = @import("nanoui");
const chrome = @import("chrome.zig");
const dl = @import("dl.zig");
const display = @import("display.zig");
const x11 = @import("x11.zig");
const log = @import("log.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Before the app: GTK 3, where a window can be put somewhere (GTK 4 lets
/// only the compositor place one), unless the user asked for another.
pub fn prepare() void {
    if (std.c.getenv("NANOUI_GTK") == null) _ = setenv("NANOUI_GTK", "3", 0);
}

/// The window, from the panel's size.
pub fn adjust(o: *nanoui.WindowOptions) void {
    // A theme.json's colors and font, or dark on a dark desktop.
    o.theme = @import("linux_theme.zig").windowTheme();
    o.decorations = false;
    o.skip_taskbar = true;
    o.always_on_top = true;
    o.transparent = true;
}

/// The panel fills the window: no margin, and an entrance of its own.
pub fn setup(w: *nanoui.Window, _: f32) chrome.Fit {
    // A Wayland session: nothing to follow here (the compositor says).
    if (display.session() == .x11) {
        window = w;
        follow();
    }
    return .{};
}

/// The panel draws its own corners here: nothing under it to round.
pub fn corners(_: f32) void {}

/// Whether the panel shows and has the keys: on X11 by the window
/// manager's word.
pub fn showing(w: *nanoui.Window) bool {
    if (!w.isVisible()) return false;
    if (panelActive()) |active| return active;
    return w.isFocused();
}

/// The panel lost the keys: it goes, as another window took them. The hot
/// key's press time goes with it: the next open (a click, the menu) is not
/// the hot key's, and the window manager would be told a time it never saw.
pub fn lostKeys(w: *nanoui.Window) void {
    x11.last_press = 0;
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
    // The panel's user time is the hot key's, set before it maps, so a
    // window manager that prevents focus stealing (Xfce, KDE) lets it take
    // the keys from the window that had them.
    const t = x11.last_press;
    if (t == 0) return;
    const g = gtk orelse return;
    const gw = gdkWindow(g, w) orelse return;
    g.gdk_x11_window_set_user_time(gw, t);
}

pub fn resize(w: *nanoui.Window, h: f32, _: *anyopaque) void {
    const height = @ceil(h);
    // GTK 3 under Wayland can keep a borderless window at its old size
    // after `gtk_window_resize`, and the bottom of the panel is cut off. A
    // size request of the new height makes it take it.
    w.setMinSize(chrome.width, height);
    w.setSize(chrome.width, height);
}

/// After `show`: on X11 the window manager is given the hot key's time, or
/// it may refuse the panel the focus (focus stealing prevention).
/// A PC has no search page (`platform.preview`): nothing to show.
pub fn showPage(_: *anyopaque, _: *nanoui.Window, _: []const u8, _: f32) void {}

pub fn hidePage(_: *anyopaque, _: *nanoui.Window) void {}

pub fn shown(w: *nanoui.Window) void {
    const t = x11.last_press;
    if (t == 0) return;
    const g = gtk orelse return;
    const win = w.gtkwindow orelse return;
    g.gtk_window_present_with_time(@ptrCast(win), t);
}

const atom_offset = x11.atom_offset;
const xa_window = x11.xa_window;

/// GTK's and GDK's functions the panel uses on X11, looked up once from the
/// libraries GTK 3 has loaded.
const Gtk = struct {
    gtk_widget_get_window: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gtk_window_present_with_time: *const fn (*anyopaque, u32) callconv(.c) void,
    gdk_x11_window_get_xid: *const fn (*anyopaque) callconv(.c) x11.Window,
    gdk_x11_window_set_user_time: *const fn (*anyopaque, u32) callconv(.c) void,
};

/// GTK's functions, once the panel follows the focus.
var gtk: ?Gtk = null;
var window: ?*nanoui.Window = null;
var dpy: ?*x11.Display = null;
var watch: ?nanoui.fdwatch.Watch = null;
var net_active: x11.Atom = 0;

const no_follow = "the panel won't follow the focus";

/// The panel's own connection: the root window's property changes (the
/// active window) delivered to it, its socket watched. Without GTK 3
/// (`NANOUI_GTK` asked for 4) or libX11 it doesn't follow (logged).
fn follow() void {
    const xl = x11.load() orelse return;
    const g = dl.table(Gtk, &.{
        .{ .name = "libgtk-3.so.0", .loaded = true },
        .{ .name = "libgdk-3.so.0", .loaded = true },
    }, no_follow) orelse return;
    gtk = g;
    const d = xl.XOpenDisplay(null) orelse {
        log.warn("nanolight: no X display: " ++ no_follow, .{});
        return;
    };
    watch = nanoui.fdwatch.readable(xl.XConnectionNumber(d), null, readable) catch |e| {
        log.warn("nanolight: X can't be watched ({s}): " ++ no_follow, .{@errorName(e)});
        _ = xl.XCloseDisplay(d);
        return;
    };
    dpy = d;
    net_active = xl.XInternAtom(d, "_NET_ACTIVE_WINDOW", 0);
    _ = xl.XSelectInput(d, xl.XDefaultRootWindow(d), x11.property_change_mask);
}

fn readable(_: ?*anyopaque) callconv(.c) void {
    const xl = x11.load() orelse return;
    const d = dpy orelse return;
    while (xl.XPending(d) > 0) {
        var ev: x11.Event = .{ .pad = @splat(0) };
        _ = xl.XNextEvent(d, &ev);
        if (ev.type != x11.property_notify) continue;
        const bytes = std.mem.asBytes(&ev);
        const atom = std.mem.readInt(c_ulong, bytes[atom_offset..][0..@sizeOf(c_ulong)], .little);
        if (atom == net_active and panelActive() == false) if (window) |w| lostKeys(w);
    }
}

fn gdkWindow(g: Gtk, w: *nanoui.Window) ?*anyopaque {
    const win = w.gtkwindow orelse return null;
    return g.gtk_widget_get_window(@ptrCast(win));
}

/// Whether the window manager has the panel as its active window; null
/// when that can't be known (no X, the panel not yet shown, a window
/// manager without _NET_ACTIVE_WINDOW).
fn panelActive() ?bool {
    const g = gtk orelse return null;
    const xl = x11.load() orelse return null;
    const d = dpy orelse return null;
    const w = window orelse return null;
    const ours = g.gdk_x11_window_get_xid(gdkWindow(g, w) orelse return null);
    if (ours == 0) return null;
    var kind: x11.Atom = 0;
    var format: c_int = 0;
    var n: c_ulong = 0;
    var left: c_ulong = 0;
    var data: ?[*]u8 = null;
    if (xl.XGetWindowProperty(
        d,
        xl.XDefaultRootWindow(d),
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
    defer _ = xl.XFree(data);
    const bytes = data orelse return null;
    if (n == 0 or format != 32) return null;
    const active = std.mem.readInt(c_ulong, bytes[0..@sizeOf(c_ulong)], .little);
    return active == ours;
}
