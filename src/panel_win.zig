//! The panel's window on Windows: borderless, over other windows, out of
//! the taskbar, exactly the panel's size (it follows the panel's height).
//! nanoui draws the panel on it; there is no system vibrancy under it, so
//! the panel paints its own fill. The window is transparent (nanoui's
//! `transparent`): only the rounded panel shows, nothing square behind its
//! corners. The window manager tells nothing more: the panel is the active
//! window while it shows (panel_x11.zig follows it on X11).
const nanoui = @import("nanoui");
const chrome = @import("chrome.zig");

/// Nothing to do before the app: no GTK to put in place.
pub fn prepare() void {}

/// The window, from the panel's size.
pub fn adjust(o: *nanoui.WindowOptions) void {
    o.decorations = false;
    o.skip_taskbar = true;
    o.always_on_top = true;
    o.transparent = true;
}

/// The panel fills the window: no margin, and an entrance of its own.
pub fn setup(_: *nanoui.Window) chrome.Fit {
    return .{};
}

/// Whether the panel shows and has the keys.
pub fn showing(w: *nanoui.Window) bool {
    return w.isVisible() and w.isFocused();
}

/// The panel lost the keys: it goes.
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
}

pub fn resize(w: *nanoui.Window, h: f32, _: *anyopaque) void {
    w.setSize(chrome.width, @ceil(h));
}

/// After `show`: nothing to tell the window manager.
pub fn shown(_: *nanoui.Window) void {}

/// A PC has no search page (`platform.preview`): nothing to show.
pub fn showPage(_: *anyopaque, _: *nanoui.Window, _: []const u8, _: f32) void {}

pub fn hidePage(_: *anyopaque, _: *nanoui.Window) void {}
