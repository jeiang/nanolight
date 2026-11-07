//! The apps Nanolight finds, each OS's as its backend finds them (the Mac's
//! bundles, apps_mac.zig; Linux's desktop entries, apps_linux.zig; the
//! Windows Start menu's shortcuts, apps_win.zig). Sorted and without
//! duplicates. Icons are asked of the system only for the rows on screen,
//! and kept. How often each was opened is launchers.zig's.
const std = @import("std");
const builtin = @import("builtin");
const app_scan = @import("app_scan.zig");
const search = @import("search.zig");
const App = app_scan.App;
const Env = std.process.Environ.Map;

/// This OS's apps: what `app_scan.conforms` lists.
const backend = switch (builtin.os.tag) {
    .macos => @import("apps_mac.zig"),
    .windows => @import("apps_win.zig"),
    else => @import("apps_linux.zig"),
};
comptime {
    app_scan.conforms(backend);
}

/// Listed with an empty query before anything was opened: names the
/// backend's scan lists. Tests list the Mac's on every OS, as their apps
/// are named after them.
pub const starters: []const []const u8 = if (builtin.is_test)
    &.{ "Safari", "Notes", "Calendar", "System Settings", "Finder" }
else
    backend.starters;

/// Finds this machine's apps, and those in the folders config.toml names,
/// found as this OS finds its own. `Index.finish` comes after the last scan.
pub fn scan(ix: *Index, io: std.Io, env: *const Env, extra_dirs: []const []const u8) void {
    ix.io = io;
    ix.env = env;
    backend.scan(ix.sink(), io, env);
    for (extra_dirs) |d| backend.scanDir(ix.sink(), io, d, 1);
}

/// Opens an app `scan` found (or a file, a folder).
pub fn launch(io: std.Io, path: []const u8) bool {
    return backend.launch(io, path);
}

/// The icon kept in `slot`, asked of the system for `path` (as PNG, `gpa`
/// owning it) the first time; none asked without an `io`.
pub fn cachedIcon(
    slot: *app_scan.Icon,
    gpa: std.mem.Allocator,
    io: ?std.Io,
    env: ?*const Env,
    path: []const u8,
) ?[]const u8 {
    switch (slot.*) {
        .png => |png| return png,
        .none => return null,
        .unloaded => {},
    }
    const png = backend.icon(gpa, io orelse return null, env, path);
    slot.* = if (png) |p| .{ .png = p } else .none;
    return png;
}

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    /// Apps a scan found but memory left out (`finish` says so).
    lost: u32 = 0,
    /// The Io and environment the apps were found with, for their icons.
    io: ?std.Io = null,
    env: ?*const Env = null,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        for (ix.apps.items) |a| switch (a.icon) {
            .png => |png| ix.gpa.free(png),
            .unloaded, .none => {},
        };
        ix.apps.deinit(ix.gpa);
        ix.arena.deinit();
    }

    /// Where a scan adds its apps. The index must stay put while it is used.
    pub fn sink(ix: *Index) app_scan.Sink {
        return .{
            .gpa = ix.gpa,
            .arena = ix.arena.allocator(),
            .apps = &ix.apps,
            .lost = &ix.lost,
        };
    }

    /// Adds an app unless one of its name is there already, its folder
    /// the one it is in.
    pub fn add(ix: *Index, name: []const u8, path: []const u8) !void {
        return ix.addIn(name, path, app_scan.folderOf(path));
    }

    /// Adds an app, its row saying `folder` ("Applications", "Start").
    pub fn addIn(ix: *Index, name: []const u8, path: []const u8, folder: []const u8) !void {
        return ix.sink().put(name, path, folder);
    }

    /// After the scans: the apps sorted, and those memory left out logged.
    pub fn finish(ix: *Index) void {
        if (ix.lost > 0) std.log.warn("nanolight: {d} apps not listed: out of memory", .{ix.lost});
        ix.sort();
    }

    /// Alphabetical, case-insensitive; each app's icon goes with it.
    pub fn sort(ix: *Index) void {
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: App, b: App) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        std.sort.pdq(App, ix.apps.items, Ctx{}, Ctx.lessThan);
    }

    /// Whether `other` lists the same apps, at the same paths: a rescan that
    /// found nothing new (script_live.zig `refresh`).
    pub fn same(ix: *const Index, other: *const Index) bool {
        if (ix.apps.items.len != other.apps.items.len) return false;
        for (ix.apps.items, other.apps.items) |a, b| {
            if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.name, b.name)) return false;
        }
        return true;
    }

    pub fn find(ix: *const Index, name: []const u8) ?u32 {
        return app_scan.findName(ix.apps.items, name);
    }

    pub fn findPath(ix: *const Index, path: []const u8) ?u32 {
        for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, path)) return @intCast(i);
        return null;
    }

    /// The app's icon as PNG, made the first time it is asked for.
    pub fn icon(ix: *Index, i: u32) ?[]const u8 {
        const app = &ix.apps.items[i];
        return cachedIcon(&app.icon, ix.gpa, ix.io, ix.env, app.path);
    }
};

/// A match through an app's pinyin scores this much under its name's.
const pinyin_cost = 70;

/// How well `query` names `app`: by its name, or by its pinyin.
pub fn score(query: []const u8, app: App) ?search.Match {
    var m = search.score(query, app.name);
    if (app.pinyin.len > 0) if (search.scoreAscii(query, app.pinyin)) |mp| {
        var via = mp;
        via.score -= pinyin_cost;
        via.n = 0;
        if (m == null or via.score > m.?.score) m = via;
    };
    return m;
}

test "names are kept once and sorted" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("notes", "/System/Applications/Notes.app");
    try ix.add("Notes", "/Applications/Notes.app");
    try ix.add("Calculator", "/System/Applications/Calculator.app");
    ix.sort();
    try t.expectEqual(@as(usize, 3), ix.apps.items.len);
    try t.expectEqualStrings("Calculator", ix.apps.items[0].name);
    try t.expectEqualStrings("Applications", ix.apps.items[0].folder);
    try t.expectEqual(@as(?u32, 2), ix.findPath("/Applications/Safari.app"));
}

test "an icon stays with its app through a sort" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Mail", "/Applications/Mail.app");
    try ix.add("Zed", "/Applications/Zed.app");
    const zed_was = ix.find("Zed").?;
    ix.apps.items[zed_was].icon = .{ .png = try t.allocator.dupe(u8, "zed") };
    // A name read later (localize) sorts again: Mail moves.
    ix.apps.items[ix.find("Mail").?].name = "Ångström";
    ix.sort();
    const zed = ix.findPath("/Applications/Zed.app").?;
    try t.expect(zed != zed_was);
    try t.expectEqualStrings("zed", ix.icon(zed).?);
    const mail = ix.findPath("/Applications/Mail.app").?;
    try t.expect(ix.apps.items[mail].icon == .unloaded);
}

test "a second look tells an app installed since from no change (#15)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Applications/Alpha.app");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try @import("test_tmp.zig").path(&buf, &tmp);
    var env: Env = .init(t.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    scan(&ix, t.io, &env, &.{});
    ix.finish();
    var again: Index = .init(t.allocator);
    defer again.deinit();
    scan(&again, t.io, &env, &.{});
    again.finish();
    try t.expect(ix.same(&again));
    // DOSBox-X, installed while Nanolight ran.
    try tmp.dir.createDirPath(t.io, "Applications/DOSBox-X.app");
    var later: Index = .init(t.allocator);
    defer later.deinit();
    scan(&later, t.io, &env, &.{});
    later.finish();
    try t.expect(!ix.same(&later));
    try t.expect(later.find("DOSBox-X") != null);
}

test "pinyin keys find CJK display names" {
    const t = std.testing;
    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const a = ix.arena.allocator();
    ix.apps.items[0].name = try a.dupe(u8, "微信");
    ix.apps.items[0].pinyin = try a.dupe(u8, "weixin");
    try t.expect(score("weixin", ix.apps.items[0]) != null);
    try t.expectEqual(@as(u8, 0), score("weixin", ix.apps.items[0]).?.n);
    try t.expect(score("weixin", .{ .name = "WeChat", .path = "", .folder = "" }) == null);
}
