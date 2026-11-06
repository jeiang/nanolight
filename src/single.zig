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

pub const Command = enum { toggle, quit };
pub const Listener = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, cmd: Command) void,
};
