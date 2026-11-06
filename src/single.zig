//! One Nanolight at a time, and commands from a second copy. A copy that
//! starts while an older one runs asks it to quit (`claim`): the newest
//! launch is the newest code (an update, a reinstall). `nanolight --toggle`
//! asks the running one to show or hide its panel (`send`), for Wayland,
//! where the desktop's shortcut settings must run it.
//!
//! Mac: NSRunningApplication (single_mac.zig); there the panel also knows
//! its own row (`isSelf`). Windows: a message window (win_msg.zig). Linux:
//! a socket in $XDG_RUNTIME_DIR (single_unix.zig).
const builtin = @import("builtin");

pub const Command = enum { toggle, quit };
pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, cmd: Command) void,
};

const impl = switch (builtin.os.tag) {
    .macos => @import("single_mac.zig"),
    .windows => @import("single_win.zig"),
    else => @import("single_unix.zig"),
};

/// Whether the app at `path` is Nanolight (any copy of it).
pub fn isSelf(path: []const u8) bool {
    return if (@hasDecl(impl, "isSelf")) impl.isSelf(path) else false;
}

/// Asks older copies to quit and listens for commands. Returns how many
/// copies were asked.
pub fn claim(on: Listener) usize {
    return impl.claim(on);
}

/// Sends `cmd` to the running copy; false when none answered.
pub fn send(cmd: Command) bool {
    return impl.send(cmd);
}
