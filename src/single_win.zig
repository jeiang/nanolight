//! Windows: single.zig's copies and commands, by Nanolight's message
//! window (win_msg.zig): a second copy finds the first one's and posts to it.
const std = @import("std");
const single = @import("single.zig");
const msg = @import("win_msg.zig");
const log = @import("log.zig");

var listener: ?single.Listener = null;

fn heard(cmd: single.Command) void {
    const l = listener orelse return;
    l.func(l.ctx, cmd);
}

/// An older copy left running keeps its window; this one has its own
/// beside it all the same (the hot key may have made it already).
pub fn claim(io: std.Io, on: single.Listener) single.Older {
    const older = single.quitOlder(io, @This());
    listener = on;
    if (msg.ensure(.{ .command = heard }) == null)
        log.warn("nanolight: no message window; `--toggle` can't reach this copy", .{});
    return older;
}

/// Whether a copy's window is there.
pub fn running() bool {
    return msg.other() != null;
}

/// Never: opening Nanolight's own row starts a new copy, which takes
/// over (`claim`).
pub fn isSelf(_: []const u8) bool {
    return false;
}

pub fn send(cmd: single.Command) bool {
    const h = msg.other() orelse return false;
    return msg.post(h, cmd);
}
