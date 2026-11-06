//! The running app's side of sync (account.zig): this machine's settings
//! as the account gets them, the account's merged in, the status line (in
//! the menu and in Settings), and the quicklinks listed, the config's or the
//! account's.
const std = @import("std");
const nanoui = @import("nanoui");
const account = @import("account.zig");
const config = @import("config.zig");
const settings = @import("settings.zig");
const Settings = settings.Settings;
const keys = @import("keys.zig");
const prefs = @import("prefs.zig");
const suggest_live = @import("suggest_live.zig");
const App = @import("app.zig").App;

/// Pinned once started: the account's hooks point here.
pub const Sync = struct {
    core: *App,
    /// Null in headless runs.
    acct: ?account.Account = null,
    label: [192]u8 = undefined,
    /// The quicklinks from the config or sync, empty for the built-in ones
    /// (`setQuicklinks`), and the arena they live in.
    quicklinks: []const settings.Quicklink = &.{},
    arena: ?*std.heap.ArenaAllocator = null,

    pub fn deinit(sy: *Sync) void {
        const old = sy.arena orelse return;
        old.deinit();
        sy.core.app.gpa.destroy(old);
    }

    /// `[sync]` names a server: synced now.
    pub fn start(sy: *Sync, cfg: config.Sync) void {
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

    /// "Sync: host, last synced 3 min ago", "Sync: error ...", or `account.off_text`.
    pub fn status(sy: *Sync) []const u8 {
        return if (sy.acct) |*a| a.status(&sy.label) else account.off_text;
    }

    /// The menu bar's sync row: the status, as text. Nothing to click.
    pub fn menuItem(sy: *Sync) nanoui.menu.MenuItem {
        return .{ .label = sy.status(), .disabled = true };
    }

    /// Lists `list` (those `settings.quicklinkProblem` lets through) in the panel,
    /// or the built-in quicklinks when none. False when nothing changed, or the list
    /// could not be copied (logged; the old one stays).
    pub fn setQuicklinks(sy: *Sync, list: []const settings.Quicklink) bool {
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
        s.quicklinks = if (keep.len > 0) keep else &settings.default_quicklinks;
        s.built = 1;
        return true;
    }
};

fn from(ctx: *anyopaque) *Sync {
    return @ptrCast(@alignCast(ctx));
}

/// The quicklinks of `list` that can be listed, copied into `arena`.
fn copyQuicklinks(
    arena: std.mem.Allocator,
    list: []const settings.Quicklink,
) ![]const settings.Quicklink {
    var keep: std.ArrayList(settings.Quicklink) = .empty;
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
    const sy = from(ctx);
    const core = sy.core;
    const ix = core.s.index;
    var list: std.ArrayList(settings.Launch) = .empty;
    for (ix.apps.items) |a| if (a.launches > 0) {
        const one: settings.Launch = .{
            .name = a.name,
            .path = a.path,
            .count = a.launches,
        };
        list.append(arena, one) catch break;
    };
    const at = prefs.int(core.kv, arena, .sync_at);
    var out: Settings = .{ .hotkey = "cmd_space", .suggest = core.s.suggest_on, .at = at };
    out.launches = list.items;
    out.quicklinks = sy.quicklinks;
    const name = arena.create([keys.name_max]u8) catch return out;
    out.hotkey = core.choice.name(name);
    return out;
}

/// The account's settings, merged: the key, the suggestions, the quicklinks, the counts.
fn applySynced(ctx: *anyopaque, st: Settings) void {
    const sy = from(ctx);
    const core = sy.core;
    // A failure is logged; the next sync sends this machine's older time.
    _ = prefs.setInt(core.kv, .sync_at, st.at);
    if (keys.Choice.parse(st.hotkey)) |c| if (!c.eql(core.choice)) {
        _ = prefs.setHotkey(core.kv, c);
        core.useKey(c);
    };
    suggest_live.set(core, st.suggest, .synced);
    if (sy.setQuicklinks(st.quicklinks)) prefs.setQuicklinks(core.kv, core.app.gpa, sy.quicklinks);
    const ix = core.s.index;
    for (st.launches) |la| if (ix.resolve(la.path, la.name)) |i| {
        ix.apps.items[i].launches = @max(ix.apps.items[i].launches, la.count);
    };
    ix.save(core.kv);
    core.s.built = 1;
    core.menuChanged();
    core.redraw();
}

/// The sync status changed: the menu shows it.
fn changed(ctx: *anyopaque) void {
    from(ctx).core.menuChanged();
}
