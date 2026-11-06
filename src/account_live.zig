//! The running app's side of sync (account.zig): this machine's settings
//! as the account gets them, the account's merged in, the status line (in
//! the menu and in Settings), and the quicklinks listed, the config's or the
//! account's.
const std = @import("std");
const nanoui = @import("nanoui");
const account = @import("account.zig");
const settings = @import("settings.zig");
const Settings = settings.Settings;
const web = @import("web.zig");
const Quicklink = web.Quicklink;
const keys = @import("keys.zig");
const prefs = @import("prefs.zig");
const launchers = @import("launchers.zig");
const suggest_live = @import("suggest_live.zig");
const App = @import("app.zig").App;

pub const off_text = "Sync: off (set [sync] in config.toml)";

/// Pinned once started: the account's hooks point here.
pub const Sync = struct {
    core: *App,
    /// Null in headless runs.
    acct: ?account.Account = null,
    label: [192]u8 = undefined,
    /// The quicklinks from the config or sync, empty for the built-in ones
    /// (`setQuicklinks`), and the arena they live in.
    quicklinks: []const Quicklink = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(sy: *Sync) void {
        const old = sy.arena orelse return;
        old.deinit();
        sy.core.app.gpa.destroy(old);
    }

    /// `[sync]` names a server: synced now.
    pub fn start(sy: *Sync, cfg: account.Config) void {
        sy.acct = .{
            .gpa = sy.core.app.gpa,
            .io = sy.core.app.io,
            .kv = sy.core.kv,
            .hooks = .{ .ctx = sy, .snapshot = snapshot, .apply = applySynced, .changed = changed },
            .cfg = cfg,
        };
        const a = &sy.acct.?;
        sy.core.acct = a;
        a.load();
    }

    /// "Sync: host, last synced 3 min ago", "Sync: error ...", or `off_text`.
    pub fn status(sy: *Sync) []const u8 {
        const a = if (sy.acct) |*x| x else return off_text;
        return a.status(&sy.label) orelse off_text;
    }

    /// The menu bar's sync row: the status, as text. Nothing to click.
    pub fn menuItem(sy: *Sync) nanoui.menu.MenuItem {
        return .{ .label = sy.status(), .disabled = true };
    }

    /// Lists `list` (those `settings.quicklinkProblem` lets through) in the panel,
    /// or the built-in quicklinks when none. False when nothing changed, or the list
    /// could not be copied (logged; the old one stays).
    pub fn setQuicklinks(sy: *Sync, list: []const Quicklink) bool {
        const gpa = sy.core.app.gpa;
        const arena = gpa.create(std.heap.ArenaAllocator) catch return false;
        arena.* = .init(gpa);
        const keep = copyQuicklinks(arena.allocator(), list) catch |e| {
            std.log.warn("nanolight: the quicklinks could not be listed: {t}", .{e});
            arena.deinit();
            gpa.destroy(arena);
            return false;
        };
        if (settings.sameQuicklinks(keep, sy.quicklinks)) {
            arena.deinit();
            gpa.destroy(arena);
            return false;
        }
        if (sy.arena) |old| {
            old.deinit();
            gpa.destroy(old);
        }
        sy.arena = arena;
        sy.quicklinks = keep;
        const s = sy.core.s;
        s.quicklinks = if (keep.len > 0) keep else &web.default_quicklinks;
        s.query.invalidate();
        return true;
    }
};

fn from(ctx: *anyopaque) *Sync {
    return @ptrCast(@alignCast(ctx));
}

/// The quicklinks of `list` that can be listed, copied into `arena`.
fn copyQuicklinks(
    arena: std.mem.Allocator,
    list: []const Quicklink,
) ![]const Quicklink {
    var keep: std.ArrayList(Quicklink) = .empty;
    for (list, 0..) |q, i| {
        if (settings.quicklinkProblem(i, q)) |why| {
            std.log.warn("nanolight: quicklink \"{s}\": {s}; ignored", .{ q.name, why });
            continue;
        }
        try keep.append(arena, .{
            .name = try arena.dupe(u8, q.name),
            .url = try arena.dupe(u8, q.url),
            .keyword = try arena.dupe(u8, q.keyword),
        });
    }
    return keep.items;
}

fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator) Settings {
    var here: Here = .{ .sy = from(ctx) };
    return settings.snapshot(&here, arena);
}

/// This machine's synced fields, one method each (`settings.snapshot`).
const Here = struct {
    sy: *Sync,

    pub fn hotkey(h: *Here, arena: std.mem.Allocator) []const u8 {
        const name = arena.create([keys.name_max]u8) catch return "cmd_space";
        return h.sy.core.choice.name(name);
    }

    pub fn suggest(h: *Here, _: std.mem.Allocator) bool {
        return h.sy.core.s.suggest_on;
    }

    pub fn at(h: *Here, arena: std.mem.Allocator) i64 {
        return prefs.int(h.sy.core.kv, arena, .sync_at);
    }

    pub fn launches(h: *Here, arena: std.mem.Allocator) []const settings.Launch {
        return h.sy.core.s.launchable().launches(arena);
    }

    pub fn quicklinks(h: *Here, _: std.mem.Allocator) []const Quicklink {
        return h.sy.quicklinks;
    }
};

/// The account's settings, merged: the key, the suggestions, the quicklinks, the counts.
fn applySynced(ctx: *anyopaque, st: Settings) void {
    const sy = from(ctx);
    const core = sy.core;
    var take: Take = .{ .sy = sy };
    settings.apply(st, &take);
    launchers.save(&core.s.counts, core.s.index.gpa, core.kv);
    core.s.query.invalidate();
    core.menuChanged();
    core.redraw();
}

/// The account's synced fields taken here, one method each (`settings.apply`).
const Take = struct {
    sy: *Sync,

    pub fn hotkey(t: *Take, name: []const u8) void {
        const core = t.sy.core;
        const c = keys.Choice.parse(name) orelse return;
        if (c.eql(core.choice)) return;
        _ = prefs.setHotkey(core.kv, c);
        core.useKey(c);
    }

    pub fn suggest(t: *Take, on: bool) void {
        suggest_live.set(t.sy.core, on, .synced);
    }

    pub fn at(t: *Take, when: i64) void {
        // A failure is logged; the next sync sends this machine's older time.
        _ = prefs.setInt(t.sy.core.kv, .sync_at, when);
    }

    pub fn launches(t: *Take, list: []const settings.Launch) void {
        const s = t.sy.core.s;
        const here = s.launchable();
        for (list) |la| {
            const x = here.find(la.path, la.name) orelse continue;
            s.counts.raise(s.index.gpa, here.key(x), la.count);
        }
    }

    pub fn quicklinks(t: *Take, list: []const Quicklink) void {
        const sy = t.sy;
        if (sy.setQuicklinks(list)) prefs.setQuicklinks(sy.core.kv, sy.core.app.gpa, sy.quicklinks);
    }
};

fn changed(ctx: *anyopaque) void {
    from(ctx).core.menuChanged();
}
