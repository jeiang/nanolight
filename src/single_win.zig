//! Windows: single.zig's copies and commands, by Nanolight's message
//! window (win_msg.zig): a second copy finds the first one's and posts to it.
const std = @import("std");
const single = @import("single.zig");
const msg = @import("win_msg.zig");

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

var listener: ?single.Listener = null;

fn command(_: *anyopaque, m: u32) void {
    const l = listener orelse return;
    l.func(l.ctx, if (m == msg.wm_quit) .quit else .toggle);
}

pub fn claim(on: single.Listener) usize {
    var n: usize = 0;
    if (msg.other()) |h| {
        _ = msg.post(h, msg.wm_quit);
        n = 1;
        // Gone within two seconds, or left to run beside this one.
        var i: usize = 0;
        while (i < 40 and msg.other() != null) : (i += 1) Sleep(50);
    }
    listener = on;
    const h = msg.window() orelse return n;
    msg.on_command = .{ .ctx = h, .func = command };
    return n;
}

/// Never: opening Nanolight's own row starts a new copy, which takes
/// over (`claim`).
pub fn isSelf(_: []const u8) bool {
    return false;
}

pub fn send(cmd: single.Command) bool {
    const h = msg.other() orelse return false;
    return msg.post(h, if (cmd == .quit) msg.wm_quit else msg.wm_toggle);
}
