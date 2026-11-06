//! One Nanolight at a time, and commands from a second copy. A copy that
//! starts while an older one runs asks it to quit (`claim`): the newest
//! launch is the newest code (an update, a reinstall). `nanolight --toggle`
//! asks the running one to show or hide its panel (`send`), for Wayland,
//! where the desktop's shortcut settings must run it. `isSelf` says
//! whether an app is Nanolight.
//!
//! Each OS's (platform.zig's `Single`): Mac: NSRunningApplication
//! (single_mac.zig). Windows: a message window (single_win.zig). Linux: a
//! socket in $XDG_RUNTIME_DIR (single_unix.zig).
const std = @import("std");

pub const Command = enum {
    toggle,
    quit,

    /// The line a second copy writes to the Linux socket.
    pub fn line(c: Command) []const u8 {
        return wire.get(c).line;
    }

    /// The message a second copy posts to the Windows message window.
    pub fn message(c: Command) u32 {
        return wire.get(c).message;
    }

    pub fn fromLine(l: []const u8) ?Command {
        for (std.enums.values(Command)) |c| if (std.mem.eql(u8, l, c.line())) return c;
        return null;
    }

    pub fn fromMessage(m: u32) ?Command {
        for (std.enums.values(Command)) |c| if (m == c.message()) return c;
        return null;
    }
};

/// WM_APP: the first message number free for an app's own.
const wm_app: u32 = 0x8000;
/// Each command as the two wires spell it.
const wire: std.enums.EnumArray(Command, struct { line: []const u8, message: u32 }) = .init(.{
    .toggle = .{ .line = "toggle", .message = wm_app + 1 },
    .quit = .{ .line = "quit", .message = wm_app + 2 },
});

pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, cmd: Command) void,
};

/// How long a newer copy waits at startup for the older one it asked to
/// quit: it needs time to exit. Asked every `quit_poll_ms` whether it has.
pub const quit_wait_ms = 2000;
const quit_poll_ms = 50;

/// What became of an older copy: none ran; it was asked to quit (and,
/// where that can be seen, went); it was asked and didn't go.
pub const Older = enum { none, quit, stayed };

/// Asks the older copy, if `Wire.send(.quit)` reaches one, to quit, and
/// waits up to `quit_wait_ms` until `Wire.running()` says it has gone.
pub fn quitOlder(io: std.Io, comptime Wire: type) Older {
    if (!Wire.send(.quit)) return .none;
    var waited: u32 = 0;
    while (Wire.running()) : (waited += quit_poll_ms) {
        if (waited >= quit_wait_ms) return .stayed;
        // Canceled: shutting down anyway; say it stayed.
        io.sleep(.fromMilliseconds(quit_poll_ms), .awake) catch return .stayed;
    }
    return .quit;
}

test "each command's wire spellings read back as it" {
    for (std.enums.values(Command)) |c| {
        try std.testing.expectEqual(c, Command.fromLine(c.line()).?);
        try std.testing.expectEqual(c, Command.fromMessage(c.message()).?);
    }
    try std.testing.expectEqual(null, Command.fromLine("show"));
    try std.testing.expectEqual(null, Command.fromMessage(wm_app));
    try std.testing.expectEqualStrings("quit", Command.quit.line());
    try std.testing.expectEqual(0x8001, Command.toggle.message());
}
