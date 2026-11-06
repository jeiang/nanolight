//! Windows and Linux: restarting into an update unseen. nanoui's
//! `autoRestart` is the Mac's for now; here, once an update is ready and
//! the panel has been away 10 s, Nanolight restarts into it (nanoui's
//! portable updater swaps the program and starts the new one). The new
//! copy finds prefs' `.updated` and starts quietly, the panel saying
//! "Updated to x" the next time it opens.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const main = @import("main.zig");

const after_ms = 10 * 1000;
var waits: u32 = 0;

/// The panel went away, or an update became ready: ask again in 10 s.
pub fn away(l: *main.Live) void {
    if (builtin.os.tag == .macos) return;
    const u = l.updater orelse return;
    if (u.ready() == null) return;
    waits += 1;
    nanoui.App.after(after_ms, l, struct {
        fn f(c: ?*anyopaque) callconv(.c) void {
            waits -= 1;
            if (waits == 0) check(@ptrCast(@alignCast(c.?)));
        }
    }.f);
}

fn check(l: *main.Live) void {
    // In use: going away asks again.
    if (l.window) |w| if (w.isVisible()) return;
    l.restartForUpdate();
}
