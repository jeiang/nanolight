//! The panel's window on the Mac: a popover the shadow's margin bigger than
//! the panel, never resized (a window resized as it searched shook:
//! AppKit's new frame and Metal's next drawable don't land together);
//! only the system's vibrancy under the panel follows its height. A menu
//! bar app: no Dock icon.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const view = @import("view.zig");

/// The system's glass under the panel, which the window's views keep.
var glass: ?objc.Object = null;

pub fn adjust(o: *nanoui.WindowOptions, hidden: bool, h: f32) void {
    o.width = if (hidden) view.width else view.width + 2 * view.shadow_margin;
    o.height = if (hidden) h else view.max_height + 2 * view.shadow_margin;
    o.title_bar = .popover;
}

pub fn setup(app: *nanoui.App, w: *nanoui.Window, s: *view.Nanolight, h: f32) void {
    // A menu bar app: no Dock icon, no menu bar of its own.
    _ = objc.msg(objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(objc.NSInteger, 1)});
    // The panel's own shadow, not the system's: a shadowed window in dark
    // mode gets a hard black outline round its pixels.
    s.margin = view.shadow_margin;
    s.window_fades = true;
    objc.msg(void, w.nswindow, "setHasShadow:", .{objc.NO});
    glass = backdrop(w, 18, h);
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
    w.setPosition(f.origin.x + (f.size.width - view.width) / 2 - view.shadow_margin, top + f.size.height * 0.2 - view.shadow_margin);
    // Unseen as it orders in: it still holds the frame it hid with, until
    // the next one is drawn (issue #9). `shown` fades it in.
    objc.msg(void, w.nswindow, "setAlphaValue:", .{@as(f64, 0)});
}

/// The glass to the panel's height, in the frame that draws it (a view's
/// frame, not the window's: nothing is laid out again).
pub fn resize(_: *nanoui.Window, h: f32) void {
    const g = glass orelse return;
    objc.msg(void, g, "setFrame:", .{glassFrame(h)});
}

/// Whether the panel has the keys.
pub fn focused(w: *nanoui.Window) bool {
    return w.isFocused();
}

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
    objc.msg(void, objc.msg(objc.Object, w.nswindow, "animator", .{}), "setAlphaValue:", .{@as(f64, 1)});
    objc.msg(void, cls, "endGrouping", .{});
    // Whole once the fade is over, whatever became of it: a launcher
    // left see-through would be worse than one that didn't fade.
    nanoui.App.after(@intFromFloat(fade_s * 1000 + 80), w, struct {
        fn f(ctx: ?*anyopaque) callconv(.c) void {
            const win: *nanoui.Window = @ptrCast(@alignCast(ctx.?));
            if (win.isVisible()) objc.msg(void, win.nswindow, "setAlphaValue:", .{@as(f64, 1)});
        }
    }.f);
}

const fade_s: f64 = 0.12;

/// Puts the system's vibrancy under the panel (NSVisualEffectView, as
/// launchers use), `height` tall, the shadow's margin in. Not
/// NSGlassEffectView: on macOS 27 it draws an opaque 1-pixel black line
/// just outside its sides, which read as black edges round the panel.
fn backdrop(w: *nanoui.Window, radius: f64, height: f32) ?objc.Object {
    const surface = w.surface orelse return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const b = objc.msg(objc.CGRect, surface.nsview, "bounds", .{});
    const v = objc.msg(objc.Object, objc.alloc("NSVisualEffectView"), "initWithFrame:", .{b});
    // Popover: light or dark with the system, as the panel's colors are.
    objc.msg(void, v, "setMaterial:", .{@as(objc.NSInteger, 6)});
    objc.msg(void, v, "setBlendingMode:", .{@as(objc.NSInteger, 0)}); // behind the window
    objc.msg(void, v, "setState:", .{@as(objc.NSInteger, 1)}); // always active
    // Rounded as the panel is.
    objc.msg(void, v, "setWantsLayer:", .{objc.YES});
    if (objc.msg(?objc.Object, v, "layer", .{})) |layer| {
        objc.msg(void, layer, "setCornerRadius:", .{radius});
        objc.msg(void, layer, "setMasksToBounds:", .{objc.YES});
    }
    surface.attachBackdrop(v);
    objc.release(v);
    // In a flipped host view, from the top; the window never resizes.
    objc.msg(void, v, "setAutoresizingMask:", .{@as(objc.NSUInteger, 0)});
    objc.msg(void, v, "setFrame:", .{glassFrame(height)});
    return v;
}

/// Where the glass goes: under the panel, the shadow's margin in.
fn glassFrame(h: f32) objc.CGRect {
    const m = view.shadow_margin;
    return .{ .origin = .{ .x = m, .y = m }, .size = .{ .width = view.width, .height = h } };
}
