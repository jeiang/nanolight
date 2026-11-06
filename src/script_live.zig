//! The running app's side of script commands (script_run.zig): the apps
//! and script rows found again, and a command opened from its row, the
//! panel staying up.
const std = @import("std");
const nanoui = @import("nanoui");
const main = @import("main.zig");
const sc = @import("script_commands.zig");
const apps = @import("apps.zig");
const Live = main.Live;

pub fn isCommand(target: []const u8) bool {
    return std.mem.startsWith(u8, target, sc.prefix) or std.mem.eql(u8, target, sc.folder_path);
}

/// Sets up the script runner and the panel's command screen.
pub fn init(l: *Live, env: *const std.process.Environ.Map) void {
    const gpa = l.app.gpa;
    l.ext_ui = .{ .gpa = gpa, .back = &l.s.query };
    l.scripts = .{
        .gpa = gpa,
        .io = l.app.io,
        .screen = l.ext_ui.asScreen(),
        .hooks = .{ .ctx = l, .hide = hide, .redraw = redraw, .copy = copy, .footer = footer },
    };
    l.s.ext = &l.ext_ui;
    l.env = env;
}

fn footer(ctx: *anyopaque, text: []const u8) void {
    const l = live(ctx);
    l.s.note = text;
    redraw(l);
}

pub fn deinit(l: *Live) void {
    l.scripts.deinit();
    l.ext_ui.deinit();
}

/// A command's row was chosen: it runs in the panel, which stays up while
/// its screen is open (view.zig `go`).
pub fn start(l: *Live, target: []const u8) void {
    if (std.mem.eql(u8, target, sc.folder_path)) {
        const d = sc.dir(l.app.gpa) catch return;
        defer l.app.gpa.free(d);
        _ = nanoui.shell.openPath(d);
        return;
    }
    const ix = l.s.index;
    var title: []const u8 = "Script";
    var png: ?[]const u8 = null;
    for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, target)) {
        title = a.name;
        png = ix.icon(@intCast(i));
        break;
    };
    l.s.query.clear();
    l.scripts.start(.{ .path = target, .title = title, .icon = png });
}

fn live(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn copy(_: *anyopaque, text: []const u8) void {
    nanoui.clipboard.writeText(text);
}

fn hide(ctx: *anyopaque) void {
    const l = live(ctx);
    if (l.window) |w| w.hide();
}

fn redraw(ctx: *anyopaque) void {
    const l = live(ctx);
    if (l.window) |w| w.redraw();
}

/// The apps and script commands found again, their counts kept.
pub fn rescan(ctx: *anyopaque) void {
    const l = live(ctx);
    const env = l.env orelse return;
    const ix = l.s.index;
    ix.deinit();
    ix.* = .init(l.app.gpa);
    fill(l, ix, env);
    changed(l);
}

/// As the panel opens: an app installed or removed since Nanolight started
/// is found (#15; after omerdikyol's #4). A look at a few folders; when it
/// finds what the index has, the index stays, its icons with it.
pub fn refresh(ctx: *anyopaque) void {
    const l = live(ctx);
    const env = l.env orelse return;
    var fresh: apps.Index = .init(l.app.gpa);
    fill(l, &fresh, env);
    if (l.s.index.same(&fresh)) return fresh.deinit();
    l.s.index.deinit();
    l.s.index.* = fresh;
    changed(l);
}

fn fill(l: *Live, ix: *apps.Index, env: *const std.process.Environ.Map) void {
    apps.scan(ix, l.app.io, env, l.cfg.apps.extra_dirs);
    sc.scan(ix.sink(), l.app.gpa, l.cfg.script_commands.dirs);
    ix.finish();
    ix.load(l.kv);
}

/// The rows again at once: theirs are places in the old index.
fn changed(l: *Live) void {
    l.s.built = 1;
    l.s.rebuild();
    redraw(l);
}
