//! The panel's window on the Mac: a popover the shadow's margin bigger than
//! the panel, never resized (a window resized as it searched shook:
//! AppKit's new frame and Metal's next drawable don't land together);
//! only the system's vibrancy under the panel follows its height. A menu
//! bar app: no Dock icon.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const chrome = @import("chrome.zig");
const after = @import("after.zig");
const ime_level = @import("ime_level.zig");
const Preview = @import("preview.zig").Preview;

/// The system's glass under the panel, which the window's views keep.
var glass: ?objc.Object = null;
/// What moves with the next frame shown: the height the glass and the page
/// go to, whether the page comes (true) or goes, and the page.
var wanted: ?f32 = null;
var page_to: ?bool = null;
var page: ?*Preview = null;

/// Before the app: nothing on the Mac.
pub fn prepare() void {}

/// The window, from the panel's size: a shadow's margin bigger, as tall as
/// the panel can be.
pub fn adjust(o: *nanoui.WindowOptions) void {
    o.width = chrome.width + 2 * chrome.shadow_margin;
    o.height = chrome.max_height + 2 * chrome.shadow_margin;
    o.title_bar = .popover;
}

/// The glass goes to the panel's height at the first `resize`. The panel
/// keeps a shadow's margin, and lets the window fade it in (`shown`).
pub fn setup(w: *nanoui.Window, radius: f32) chrome.Fit {
    // A menu bar app: no Dock icon, no menu bar of its own.
    const app = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    _ = objc.msg(objc.BOOL, app, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
    // The panel's own shadow, not the system's: a shadowed window in dark
    // mode gets a hard black outline round its pixels.
    objc.msg(void, w.nswindow, "setHasShadow:", .{objc.NO});
    glass = backdrop(w, radius);
    // Pinyin's candidates over the panel, not behind it (#39).
    if (w.surface) |surface| {
        _ = ime_level.answerWindowLevel(surface.nsview);
        surface.after_frame = afterFrame;
    }
    return .{ .margin = chrome.shadow_margin, .window_fades = true };
}

/// A fifth of the way down the main screen, centered.
pub fn place(w: *nanoui.Window) void {
    const screen = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return;
    const f = objc.msg(objc.CGRect, screen, "frame", .{});
    const screens = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const primary = objc.msg(objc.Object, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const ph = objc.msg(objc.CGRect, primary, "frame", .{}).size.height;
    const top = ph - (f.origin.y + f.size.height);
    // The panel there; the window is the shadow's margin bigger.
    w.setPosition(
        f.origin.x + (f.size.width - chrome.width) / 2 - chrome.shadow_margin,
        top + f.size.height * 0.2 - chrome.shadow_margin,
    );
    // Unseen as it orders in: it still holds the frame it hid with, until
    // the next one is drawn (issue #9). `shown` fades it in.
    objc.msg(void, w.nswindow, "setAlphaValue:", .{@as(f64, 0)});
}

/// The glass and the page to the panel's height, in the frame that shows
/// it: a key's frame only builds the panel, and its pixels come with the
/// display's next refresh. Moved sooner, the glass stood a frame or two
/// without the panel, or the panel's rows hung off the glass.
pub fn resize(_: *nanoui.Window, h: f32, p: *anyopaque) void {
    wanted = h;
    page = @ptrCast(@alignCast(p));
}

/// The page, loading now and seen with the frame that makes room for it:
/// shown sooner, it stood over the rows.
pub fn showPage(p: *anyopaque, w: *nanoui.Window, url: []const u8, h: f32) void {
    const preview: *Preview = @ptrCast(@alignCast(p));
    page = preview;
    preview.load(w, url, h);
    page_to = true;
    requestFrame(w);
}

/// The page, gone with the frame that replaces it: gone sooner, the last
/// frame under it ("Searching Google...") showed for a refresh.
pub fn hidePage(p: *anyopaque, w: *nanoui.Window) void {
    page = @ptrCast(@alignCast(p));
    page_to = false;
    requestFrame(w);
}

/// Not while hidden: a showing draws everything anyway.
fn requestFrame(w: *nanoui.Window) void {
    if (w.isVisible()) if (w.surface) |surface| surface.requestFrame();
}

const Step = enum { wait, ask, move };

/// What a built frame does about a height still wanted: a frame with a
/// drawable is shown now, so everything moves with it; a visible one
/// without asks for one; a hidden window waits, drawing nothing, to show.
fn stepFor(has_drawable: bool, visible: bool) Step {
    if (has_drawable) return .move;
    return if (visible) .ask else .wait;
}

/// True when native views moved: nanoui then presents this frame in the
/// same transaction as they move.
fn afterFrame(_: ?*anyopaque, s: *nanoui.Surface) bool {
    if (wanted == null and page_to == null) return false;
    switch (stepFor(s.renderer.given_drawable != null, s.visible())) {
        .wait => return false,
        .ask => {
            s.requestFrame();
            return false;
        },
        .move => {},
    }
    // The glass's own layers would otherwise ease to their new size.
    objc.msg(void, objc.class("CATransaction"), "setDisableActions:", .{objc.YES});
    if (wanted) |h| {
        if (glass) |g| objc.msg(void, g, "setFrame:", .{glassFrame(h)});
        if (page) |p| p.fit(h);
    }
    if (page) |p| if (page_to) |on| if (on) p.uncover() else p.hide();
    wanted = null;
    page_to = null;
    return true;
}

/// The glass's corners to the theme's, as the panel's follow it.
pub fn corners(radius: f32) void {
    const g = glass orelse return;
    const layer = objc.msg(?objc.Object, g, "layer", .{}) orelse return;
    objc.msg(void, layer, "setCornerRadius:", .{@as(f64, radius)});
}

pub fn showing(w: *nanoui.Window) bool {
    return w.isVisible() and w.isFocused();
}

/// The panel lost the keys: the popover hides itself.
pub fn lostKeys(_: *nanoui.Window) void {}

/// After `show`: the window fades in, the system's glass and the panel
/// together. The panel's entrance couldn't be drawn over that glass (it
/// is the system's, at full strength at once), so the window has it; the
/// fade also hides the frame left from the last showing while the panel
/// draws its new one.
pub fn shown(w: *nanoui.Window) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.class("NSAnimationContext");
    objc.msg(void, cls, "beginGrouping", .{});
    objc.msg(void, objc.msg(objc.Object, cls, "currentContext", .{}), "setDuration:", .{fade_s});
    objc.msg(
        void,
        objc.msg(objc.Object, w.nswindow, "animator", .{}),
        "setAlphaValue:",
        .{@as(f64, 1)},
    );
    objc.msg(void, cls, "endGrouping", .{});
    after.oneShot(fade_settle_ms, w, settle);
}

const fade_s: f64 = 0.12;
/// Whole once the fade is over, whatever became of it (AppKit's animation
/// may not finish): a launcher left see-through would be worse than one
/// that didn't fade. A little after the fade, so as not to cut it short.
const fade_settle_ms: u64 = @as(u64, @intFromFloat(fade_s * 1000)) + 80;

fn settle(w: *nanoui.Window) void {
    if (w.isVisible()) objc.msg(void, w.nswindow, "setAlphaValue:", .{@as(f64, 1)});
}

/// Puts the system's vibrancy under the panel (NSVisualEffectView, as
/// launchers use), the shadow's margin in. Not NSGlassEffectView: on
/// macOS 27 it draws an opaque 1-pixel black line just outside its sides,
/// which read as black edges round the panel.
fn backdrop(w: *nanoui.Window, radius: f64) ?objc.Object {
    const surface = w.surface orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const b = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
    const v = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{b});
    // Popover: light or dark with the system, as the panel's colors are.
    objc.msg(void, v, "setMaterial:", .{@as(objc.NSInteger, 6)});
    objc.msg(void, v, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, v, "setState:", .{@as(objc.NSInteger, 1)}); // always active
    objc.msg(void, v, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, v, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{radius});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }
    surface.attachBackdrop(v);
    objc.release(v);
    // In a flipped host view, from the top; the window never resizes.
    objc.msg(void, v, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
    // No height until a frame shows the panel over it (`afterFrame`):
    // `attachBackdrop` sized it to the window, which then stood empty
    // while the first showing drew its first frame.
    objc.msg(void, v, "setFrame:", .{glassFrame(0)});
    return v;
}

/// Where the glass goes: under the panel, the shadow's margin in.
fn glassFrame(h: f32) objc.CGRect {
    const m = chrome.shadow_margin;
    return .{ .origin = .{ .x = m, .y = m }, .size = .{ .width = chrome.width, .height = h } };
}

test "the glass moves only with a frame that is being shown" {
    try std.testing.expectEqual(Step.move, stepFor(true, true));
    try std.testing.expectEqual(Step.ask, stepFor(false, true));
    // Hidden, nothing asks for frames: an idle Nanolight stays idle.
    try std.testing.expectEqual(Step.wait, stepFor(false, false));
}
