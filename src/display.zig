//! Linux: which display server this session is, one rule for every backend.
//!
//! XDG_SESSION_TYPE, when it says "wayland" or "x11"; else Wayland when
//! WAYLAND_DISPLAY is set; else X11 when DISPLAY is; else none. An empty
//! variable counts as unset. Each backend acts on it:
//! - Wayland: clipboard history watches Wayland (data-control), or X11 over
//!   XWayland when the compositor has no data-control and DISPLAY is set
//!   (clipboard_linux.zig). The hot key reports that it can't be grabbed:
//!   the desktop's keyboard settings run `nanolight --toggle`
//!   (hotkey_x11.zig). GTK draws the panel over Wayland, so X11's active
//!   window says nothing about it: GTK's focus is the panel's (panel_pc.zig).
//! - X11: all three use X11.
//! - None: clipboard history says why it is off; there is no hot key.
const std = @import("std");

pub const Session = enum { wayland, x11, none };

var cached: ?Session = null;

/// The session, worked out (and logged) once: the environment it comes
/// from doesn't change while Nanolight runs.
pub fn session() Session {
    if (cached) |s| return s;
    const s, const by = pick();
    std.log.info("nanolight: display session: {t} (by {s})", .{ s, by });
    cached = s;
    return s;
}

fn pick() struct { Session, []const u8 } {
    const kind = env("XDG_SESSION_TYPE") orelse "";
    if (std.mem.eql(u8, kind, "wayland")) return .{ .wayland, "XDG_SESSION_TYPE" };
    if (std.mem.eql(u8, kind, "x11")) return .{ .x11, "XDG_SESSION_TYPE" };
    if (env("WAYLAND_DISPLAY") != null) return .{ .wayland, "WAYLAND_DISPLAY" };
    if (env("DISPLAY") != null) return .{ .x11, "DISPLAY" };
    return .{ .none, "neither WAYLAND_DISPLAY nor DISPLAY" };
}

/// An environment variable; null when unset or empty.
pub fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.mem.span(std.c.getenv(name) orelse return null);
    return if (v.len == 0) null else v;
}
