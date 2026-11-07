//! The running app's side of script commands (script_run.zig): the apps
//! and script rows found again, and a command opened from its row, the
//! panel staying up.
const std = @import("std");
const nanoui = @import("nanoui");
const sc = @import("script_commands.zig");
const apps = @import("apps.zig");
const config = @import("config.zig");
const ScriptTarget = @import("host.zig").ScriptTarget;
const pipeline = @import("pipeline.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;
const Opens = @import("app.zig").Opens;
const Runner = @import("script_run.zig").Runner;

/// Pinned once its hooks are taken and its list is the panel's (main.zig).
pub const Scripts = struct {
    core: *App,
    env: *const std.process.Environ.Map,
    /// Where apps and script commands are looked for, besides the usual places.
    cfg: *const config.Config,
    /// Raycast script commands, run by Nanolight itself (script_run.zig), on
    /// the panel's script screen (nanolight.zig `Nanolight.scriptScreen`).
    runner: Runner,
    /// The script commands found, listed among the apps (the panel's `scripts`).
    list: sc.List,

    /// The script commands among the apps already found (main.zig scans
    /// them once), and their runner.
    pub fn init(
        core: *App,
        env: *const std.process.Environ.Map,
        cfg: *const config.Config,
    ) Scripts {
        const gpa = core.app.gpa;
        const ix = core.s.index;
        var list: sc.List = .init(gpa);
        sc.scan(&list, core.app.io, ix.apps.items, ix.env, cfg.script_commands.dirs);
        list.finish();
        return .{
            .core = core,
            .env = env,
            .cfg = cfg,
            .runner = .{
                .gpa = gpa,
                .io = core.app.io,
                .screen = core.s.scriptScreen(),
                .hooks = .{
                    .ctx = core,
                    // A silent script runs on without its screen: the
                    // panel goes, and its going is noted.
                    .hide = App.hide,
                    .redraw = redraw,
                    .copy = copy,
                    .footer = App.footer,
                },
            },
            .list = list,
        };
    }

    pub fn deinit(sx: *Scripts) void {
        sx.runner.deinit();
        sx.core.s.scripts = null;
        sx.list.deinit();
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

    /// A command's row was chosen: it runs in the panel, which stays up
    /// (host.zig `Target.opensScreen`).
    fn start(sx: *Scripts, target: ScriptTarget) void {
        const gpa = sx.core.app.gpa;
        switch (target) {
            .folder => {
                const d = sc.dir(gpa, sx.core.app.io) catch return;
                defer gpa.free(d);
                _ = nanoui.shell.openPath(d);
            },
            .command => |i| {
                const x = sx.list.items.items[i];
                sx.runner.start(.{ .file = x.file.?, .title = x.title, .icon = sx.list.icon(i) });
            },
        }
    }

    /// The apps first: a script whose title an app has is not listed.
    fn fill(sx: *Scripts, ix: *apps.Index, list: *sc.List) void {
        const io = sx.core.app.io;
        apps.scan(ix, io, sx.env, sx.cfg.apps.extra_dirs);
        ix.finish();
        sc.scan(list, io, ix.apps.items, ix.env, sx.cfg.script_commands.dirs);
        list.finish();
    }

    /// The rows again at once: theirs are places in the old lists. Older
    /// counts kept by name are their app's or script's from now on.
    fn changed(sx: *Scripts) void {
        const s = sx.core.s;
        s.tally.adopt(s.index.gpa, s.launchable());
        s.query.invalidate();
        pipeline.rebuild(s);
        sx.core.redraw();
    }
};

fn from(ctx: *anyopaque) *Scripts {
    return @ptrCast(@alignCast(ctx));
}

fn open(ctx: *anyopaque, target: ScriptTarget) void {
    from(ctx).start(target);
}

/// As the panel opens: an app installed or removed since Nanolight started
/// is found (#15; after omerdikyol's #4). A look at a few folders; when it
/// finds what the lists have, they stay, their icons with them.
fn refresh(ctx: *anyopaque) void {
    const sx = from(ctx);
    const s = sx.core.s;
    const gpa = sx.core.app.gpa;
    var fresh: apps.Index = .init(gpa);
    var list: sc.List = .init(gpa);
    sx.fill(&fresh, &list);
    if (s.index.same(&fresh) and sx.list.same(&list)) {
        fresh.deinit();
        list.deinit();
        return;
    }
    s.index.deinit();
    s.index.* = fresh;
    sx.list.deinit();
    sx.list = list;
    sx.changed();
}

fn pop(ctx: *anyopaque) void {
    from(ctx).runner.pop();
}

fn copy(_: *anyopaque, text: []const u8) void {
    nanoui.clipboard.writeText(text);
}

fn redraw(ctx: *anyopaque) void {
    App.from(ctx).redraw();
}
