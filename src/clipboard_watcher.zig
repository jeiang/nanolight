//! This OS's clipboard watcher and paste, picked at compile time: each OS's
//! is its own file (clipboard_mac.zig, clipboard_win.zig, clipboard_linux.zig).
const builtin = @import("builtin");
const types = @import("clipboard_types.zig");
const Sink = types.Sink;
const StartError = types.StartError;
const Content = types.Content;
const Hide = types.Hide;
const PasteResult = types.PasteResult;

/// This OS's watcher. Every one has, all on the main thread:
///
///   `start(w, sink) StartError!void` and `stop(w)`: watching
///   `status(w) ?[]const u8`: why it is not watching, once a start failed
///   `noteFrontmost(w)`: called as the panel opens, to remember where to paste
///   `paste(w, content, hide) PasteResult` (never `.copied` or `.unreadable`)
///   `copy(w, content) bool`: writes it, no paste
///
/// and keeps to these rules:
///
///   - Nothing over its kind's `cap` is read or converted: it is logged and dropped.
///   - An item its source marked concealed or transient is observed with
///     `concealed` set and nothing of it read.
///   - What its own `copy` and `paste` write is not observed: a poll watcher
///     (clipboard_poll.zig) keeps the change count it wrote; a Linux one offers
///     `own_mime` and skips an offer that has it (clipboard_offer.zig).
///   - `Item.source` is what the OS names: the frontmost app's bundle ID when the
///     change is seen (Mac), the owner's exe (Windows), the owner window's
///     WM_CLASS (X11). Wayland names no source, so `exclude_apps` cannot apply there.
pub const Watcher = switch (builtin.os.tag) {
    .macos => @import("clipboard_mac.zig").Watcher,
    .windows => @import("clipboard_win.zig").Watcher,
    else => @import("clipboard_linux.zig").Watcher,
};

comptime {
    conforms(Watcher);
}

/// Fails the build unless `W` has the surface `Watcher` documents.
fn conforms(comptime W: type) void {
    const surface = .{
        .{ "start", fn (*W, Sink) StartError!void },
        .{ "stop", fn (*W) void },
        .{ "status", fn (*const W) ?[]const u8 },
        .{ "noteFrontmost", fn (*W) void },
        .{ "paste", fn (*W, Content, Hide) PasteResult },
        .{ "copy", fn (*W, Content) bool },
    };
    inline for (surface) |d| {
        if (!@hasDecl(W, d[0])) @compileError(@typeName(W) ++ " has no " ++ d[0]);
        if (@TypeOf(@field(W, d[0])) != d[1])
            @compileError(@typeName(W) ++ "." ++ d[0] ++ " is not " ++ @typeName(d[1]));
    }
}

test "every OS's watcher has the same surface" {
    comptime {
        conforms(@import("clipboard_mac.zig").Watcher);
        conforms(@import("clipboard_win.zig").Watcher);
        conforms(@import("clipboard_linux.zig").Watcher);
    }
}
