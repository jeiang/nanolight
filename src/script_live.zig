//! The running app's side of script commands (script_run.zig): the apps
//! and script rows found again, and a command opened from its row, the
//! panel staying up.
const std = @import("std");
const nanoui = @import("nanoui");
const sc = @import("script_commands.zig");
const apps = @import("apps.zig");
const config = @import("config.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;
const Opens = @import("app.zig").Opens;

/// Pinned once initialized: the runner and the panel point at its screen.
pub const Scripts = struct {
    core: *App,
    env: *const std.process.Environ.Map,
    /// Where apps and script commands are looked for, besides the usual places.
    cfg: *const config.Config,
    /// The script command running in the panel (raycast_view.zig).
    screen: @import("raycast_view.zig").Ext,
    /// Raycast script commands, run by Nanolight itself (script_run.zig).
    runner: @import("script_run.zig").Runner,

    pub fn init(
        sx: *Scripts,
        core: *App,
        env: *const std.process.Environ.Map,
        cfg: *const config.Config,
    ) void {
        const gpa = core.app.gpa;
        sx.core = core;
        sx.env = env;
        sx.cfg = cfg;
        sx.screen = .{ .gpa = gpa, .back = &core.s.query };
        sx.runner = .{
            .gpa = gpa,
            .io = core.app.io,
            .screen = sx.screen.asScreen(),
            .hooks = .{ .ctx = sx, .hide = hide, .redraw = redraw, .copy = copy, .footer = footer },
        };
        core.s.ext = &sx.screen;
    }

    pub fn deinit(sx: *Scripts) void {
        sx.runner.deinit();
        sx.screen.deinit();
    }

    /// The core's `opens`: a command's row runs it in the panel.
    pub fn opensHook(sx: *Scripts) Opens {
        return .{ .ctx = sx, .func = open };
    }

    /// The core's `rescan`: apps installed or removed since are found.
    pub fn rescanHook(sx: *Scripts) Hook {
        return .{ .ctx = sx, .func = refresh };
    }

    /// The core's `popped`: the command running in the panel ends.
    pub fn poppedHook(sx: *Scripts) Hook {
        return .{ .ctx = sx, .func = pop };
    }

    /// A command's row was chosen: it runs in the panel, which stays up while
    /// its screen is open (view.zig `go`).
    fn start(sx: *Scripts, target: []const u8) void {
        const gpa = sx.core.app.gpa;
        if (std.mem.eql(u8, target, sc.folder_path)) {
            const d = sc.dir(gpa) catch return;
            defer gpa.free(d);
            _ = nanoui.shell.openPath(d);
            return;
        }
        const ix = sx.core.s.index;
        var title: []const u8 = "Script";
        var png: ?[]const u8 = null;
        for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, target)) {
            title = a.name;
            png = ix.icon(@intCast(i));
            break;
        };
        sx.core.s.query.clear();
        sx.runner.start(.{ .path = target, .title = title, .icon = png });
    }

    /// The apps and script commands found again, their counts kept.
    pub fn rescan(sx: *Scripts) void {
        const ix = sx.core.s.index;
        ix.deinit();
        ix.* = .init(sx.core.app.gpa);
        sx.fill(ix);
        sx.changed();
    }

    fn fill(sx: *Scripts, ix: *apps.Index) void {
        apps.scan(ix, sx.core.app.io, sx.env, sx.cfg.apps.extra_dirs);
        sc.scan(ix.sink(), sx.core.app.gpa, sx.cfg.script_commands.dirs);
        ix.finish();
        ix.load(sx.core.kv);
    }

    /// The rows again at once: theirs are places in the old index.
    fn changed(sx: *Scripts) void {
        const s = sx.core.s;
        s.built = 1;
        s.rebuild();
        sx.core.redraw();
    }
};

fn from(ctx: *anyopaque) *Scripts {
    return @ptrCast(@alignCast(ctx));
}

fn open(ctx: *anyopaque, target: []const u8) bool {
    const command = std.mem.startsWith(u8, target, sc.prefix) or
        std.mem.eql(u8, target, sc.folder_path);
    if (command) from(ctx).start(target);
    return command;
}

/// As the panel opens: an app installed or removed since Nanolight started
/// is found (#15; after omerdikyol's #4). A look at a few folders; when it
/// finds what the index has, the index stays, its icons with it.
fn refresh(ctx: *anyopaque) void {
    const sx = from(ctx);
    const s = sx.core.s;
    var fresh: apps.Index = .init(sx.core.app.gpa);
    sx.fill(&fresh);
    if (s.index.same(&fresh)) return fresh.deinit();
    s.index.deinit();
    s.index.* = fresh;
    sx.changed();
}

fn pop(ctx: *anyopaque) void {
    from(ctx).runner.pop();
}

fn footer(ctx: *anyopaque, text: []const u8) void {
    App.footer(from(ctx).core, text);
}

fn copy(_: *anyopaque, text: []const u8) void {
    nanoui.clipboard.writeText(text);
}

fn hide(ctx: *anyopaque) void {
    if (from(ctx).core.window) |w| w.hide();
}

fn redraw(ctx: *anyopaque) void {
    from(ctx).core.redraw();
}
