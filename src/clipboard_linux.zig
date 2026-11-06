//! Clipboard history on Linux. Wayland first: a compositor that offers
//! data-control (clipboard_wl.zig); else the X11 selections
//! (clipboard_x11.zig); else history is unavailable and says why. This file
//! is the choice between them; what both share is clipboard_offer.zig.
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const offer = @import("clipboard_offer.zig");
const x11 = @import("clipboard_x11.zig");
const wl = @import("clipboard_wl.zig");

pub const Watcher = struct {
    /// Why history cannot run in this session, once `start` failed.
    why: ?[]const u8 = null,
    backend: union(enum) { none, x11: x11.X11, wl: wl.Wl } = .none,

    pub fn start(w: *Watcher, sink: clipboard.Sink) clipboard.StartError!void {
        if (w.backend == .none) try w.pick();
        switch (w.backend) {
            inline .x11, .wl => |*b| b.sink = sink,
            .none => unreachable,
        }
    }

    pub fn status(w: *const Watcher) ?[]const u8 {
        return w.why;
    }

    /// Opens the Wayland connection if there is data-control, else X11.
    fn pick(w: *Watcher) clipboard.StartError!void {
        w.why = "Clipboard history needs a display: neither WAYLAND_DISPLAY nor DISPLAY is set.";
        if (offer.env("WAYLAND_DISPLAY") != null) {
            w.backend = .{ .wl = .{} };
            if (w.backend.wl.open()) |_| return w.opened("Wayland") else |e| {
                w.backend.wl.close();
                w.backend = .none;
                clipboard.log(.warn, "nanolight: clipboard: Wayland: {t}", .{e});
                w.why = switch (e) {
                    error.NoDataControl => "This Wayland compositor has no data-control " ++
                        "protocol (GNOME has none), so clipboard history cannot watch it.",
                    else => "Could not connect to the Wayland display " ++
                        "(libwayland-client missing?).",
                };
            }
        }
        if (offer.env("DISPLAY") != null) {
            w.backend = .{ .x11 = .{} };
            if (w.backend.x11.open()) |_| return w.opened("X11") else |e| {
                w.backend.x11.close();
                w.backend = .none;
                clipboard.log(.warn, "nanolight: clipboard: X11: {t}", .{e});
                w.why = "Could not open the X11 display with libX11 and libXfixes.";
            }
        }
        return error.Unavailable;
    }

    fn opened(w: *Watcher, transport: []const u8) void {
        w.why = null;
        clipboard.log(.info, "nanolight: clipboard: watching over {s}", .{transport});
    }

    pub fn stop(w: *Watcher) void {
        switch (w.backend) {
            inline .x11, .wl => |*b| b.sink = null,
            .none => {},
        }
    }

    /// Nothing to note: a window manager gives the keys back to the previous
    /// window, and a Wayland compositor does the same.
    pub fn noteFrontmost(_: *Watcher) void {}

    pub fn paste(w: *Watcher, c: clipboard.Content, hide: clipboard.Hide) clipboard.PasteResult {
        return switch (w.backend) {
            inline .x11, .wl => |*b| b.paste(c, hide),
            .none => if (w.copy(c)) .copied_unsupported else .failed,
        };
    }

    /// With no transport nothing watches, so what this writes needs no
    /// `own_mime` to be told apart.
    pub fn copy(w: *Watcher, c: clipboard.Content) bool {
        return switch (w.backend) {
            inline .x11, .wl => |*b| b.copy(c),
            .none => blk: {
                if (c.kind == .image) break :blk false;
                nanoui.clipboard.writeText(c.text);
                break :blk true;
            },
        };
    }
};
