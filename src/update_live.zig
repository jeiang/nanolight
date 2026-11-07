//! Updates from GitHub's releases: a release build checks them (one run
//! from zig-out can't replace itself, and a Nix build never updates
//! itself), the menu and Settings offer the one that is ready, and the
//! panel says "Updated to x" the next time it opens after one.
//!
//! A launcher almost never quits, so installing at quit would mean never:
//! it restarts into an update once the panel has been away `idle_ms`,
//! unseen, and comes back as it was. On the Mac that is nanoui's
//! `autoRestart`, whose updater also says the copy was updated
//! (`updatedFrom`). On Windows and Linux it is `away` here (nanoui's
//! portable updater swaps the program and starts the new one), and the new
//! copy learns it was updated from prefs' `.updated`.
const std = @import("std");
const nanoui = @import("nanoui");
const prefs = @import("prefs.zig");
const platform = @import("platform.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;
const after = @import("after.zig");
const build = @import("build_options");
const app_facts = @import("app_facts.zig");

const idle_ms = app_facts.restart_idle_ms;

pub const Update = struct {
    core: *App,
    /// The updater as started, ended at quit.
    started: ?*nanoui.Updater = null,
    /// The same once it can update this copy; null when it can't.
    updater: ?*nanoui.Updater = null,
    label: [64]u8 = undefined,
    /// The panel's absences still being waited out (only the last one acts).
    away_wait: after.Debounce = .{},

    /// The updater, unless this build never updates itself.
    pub fn start(u: *Update, init: std.process.Init) void {
        if (build.nix_managed) return;
        const updater = nanoui.Updater.start(init, .{
            .repo = build.repo,
            .asset = build.asset,
            .version = build.version,
            .name = app_facts.app_name,
            .changed = .{ .ctx = u, .func = changed },
        }) catch return;
        u.started = updater;
        if (updater.phase.load(.acquire) == .off) return;
        u.updater = updater;
        updater.autoRestart(u.core.app, .{ .idle_ms = idle_ms });
    }

    pub fn deinit(u: *Update) void {
        if (u.started) |updater| updater.deinit();
    }

    pub fn awayHook(u: *Update) Hook {
        return .{ .ctx = u, .func = away };
    }

    /// Restarts into the update that is ready, if one is.
    pub fn restart(u: *Update) void {
        const updater = u.updater orelse return;
        const v = updater.ready() orelse return;
        const note = !platform.native_autorestart;
        const kv = u.core.kv;
        // A failure is logged; without the note the new copy only skips "Updated to".
        if (note) _ = prefs.setText(kv, .updated, v);
        if (updater.restart()) u.core.app.quit() else if (note) prefs.remove(kv, .updated);
    }

    pub fn check(u: *Update) void {
        if (u.updater) |updater| updater.checkNow();
    }

    /// The updater's version, else the build's.
    pub fn version(u: *const Update) []const u8 {
        const updater = u.updater orelse return build.version;
        return if (updater.current.len > 0) updater.current else build.version;
    }

    pub fn ready(u: *const Update) ?[]const u8 {
        const updater = u.updater orelse return null;
        return updater.ready();
    }

    /// The menu's item: the update that is ready, else a check.
    pub fn menuItem(u: *Update) nanoui.menu.MenuItem {
        const label = if (u.ready()) |v|
            std.fmt.bufPrint(&u.label, "Restart to Update to {s}", .{v}) catch "Restart to Update"
        else
            "Check for Updates";
        return .{ .label = label, .disabled = u.updater == null, .click = .of(u, clicked) };
    }

    fn clicked(u: *Update, _: *nanoui.menu.Item) void {
        const updater = u.updater orelse return;
        if (updater.ready() != null) u.restart() else updater.checkNow();
    }

    /// Restarted by an automatic update: what the panel says the next time
    /// it opens (in `buf`), else null.
    pub fn greeting(u: *Update, buf: *[64]u8) ?[]const u8 {
        const kv = u.core.kv;
        const gpa = u.core.app.gpa;
        const old = prefs.text(kv, gpa, .updated);
        defer if (old) |v| gpa.free(v);
        if (old != null) prefs.remove(kv, .updated);
        const restarted = if (u.updater) |updater| updater.updatedFrom() != null else false;
        if (!restarted and old == null) return null;
        const now = if (u.updater) |updater| updater.current else old.?;
        return std.fmt.bufPrint(buf, "Updated to {s}", .{now}) catch "Updated";
    }
};

/// An update became ready, or the updater's state moved: the menu follows.
fn changed(ctx: *anyopaque) void {
    const u = after.cast(*Update, ctx);
    u.core.menuChanged();
    away(u);
}

/// Off the Mac: the panel went away, or an update became ready; once the
/// panel has been away `idle_ms`, it restarts into the update.
fn away(ctx: *anyopaque) void {
    if (platform.native_autorestart) return;
    const u = after.cast(*Update, ctx);
    const updater = u.updater orelse return;
    if (updater.ready() == null) return;
    u.away_wait.poke(idle_ms, Update, "away_wait", restartUnseen);
}

fn restartUnseen(u: *Update) void {
    // In use: going away asks again.
    if (u.core.window) |w| if (w.isVisible()) return;
    u.restart();
}
