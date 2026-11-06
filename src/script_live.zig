//! The running app's side of script commands (script_run.zig): the apps
//! and script rows found again, and a command opened from its row, the
//! panel staying up.
const std = @import("std");
const nanoui = @import("nanoui");
const sc = @import("script_commands.zig");
const apps = @import("apps.zig");
const launchers = @import("launchers.zig");
const config = @import("config.zig");
const Target = @import("results.zig").Target;
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
    /// The script commands found, listed among the apps (the panel's `scripts`).
    list: sc.List,

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
        sx.list = .init(gpa);
        core.s.ext = &sx.screen;
        core.s.scripts = &sx.list;
    }

    pub fn deinit(sx: *Scripts) void {
        sx.runner.deinit();
        sx.screen.deinit();
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

    /// A command's row was chosen: it runs in the panel, which stays up while
    /// its screen is open (view.zig `go`).
    fn start(sx: *Scripts, target: Target) void {
        const gpa = sx.core.app.gpa;
        switch (target) {
            .folder => {
                const d = sc.dir(gpa) catch return;
                defer gpa.free(d);
                _ = nanoui.shell.openPath(d);
            },
            .script => |i| {
                const x = sx.list.items.items[i];
                sx.core.s.query.clear();
                sx.runner.start(.{ .file = x.file.?, .title = x.title, .icon = sx.list.icon(i) });
            },
            .app, .url, .pane => unreachable, // The core opens these itself.
        }
    }

    /// The apps and script commands found again, their counts kept.
    pub fn rescan(sx: *Scripts) void {
        const gpa = sx.core.app.gpa;
        const ix = sx.core.s.index;
        ix.deinit();
        ix.* = .init(gpa);
        sx.list.deinit();
        sx.list = .init(gpa);
        sx.fill(ix, &sx.list);
        sx.changed();
    }

    /// The apps first: a script whose title an app has is not listed.
    fn fill(sx: *Scripts, ix: *apps.Index, list: *sc.List) void {
        apps.scan(ix, sx.core.app.io, sx.env, sx.cfg.apps.extra_dirs);
        ix.finish();
        sc.scan(list, ix.apps.items, ix.env, sx.cfg.script_commands.dirs);
        list.finish();
    }

    /// The rows again at once: theirs are places in the old lists. Older
    /// counts kept by name are their app's or script's from now on.
    fn changed(sx: *Scripts) void {
        const s = sx.core.s;
        launchers.adopt(&s.counts, s.index.gpa, s.launchable());
        s.built = 1;
        s.rebuild();
        sx.core.redraw();
    }
};

fn from(ctx: *anyopaque) *Scripts {
    return @ptrCast(@alignCast(ctx));
}

fn open(ctx: *anyopaque, target: Target) void {
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
