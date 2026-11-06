//! The apps Nanolight finds, each OS's as its backend finds them (the Mac's
//! bundles, apps_mac.zig; Linux's desktop entries, apps_linux.zig; the
//! Windows Start menu's shortcuts, apps_win.zig). Sorted and without
//! duplicates. How often each was opened is kept in the app's defaults
//! and lifts it in the ranking. Icons are asked of the system only for the
//! rows on screen, and kept.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const app_scan = @import("app_scan.zig");
const counts = @import("launch_counts.zig");
const prefs = @import("prefs.zig");
const search = @import("search.zig");
const assert = std.debug.assert;
const App = app_scan.App;
const Launch = counts.Launch;
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
const starters: []const []const u8 = if (builtin.is_test)
    &.{ "Safari", "Notes", "Calendar", "System Settings", "Finder" }
else
    backend.starters;

/// Finds this machine's apps, and those in the folders config.toml names,
/// found as this OS finds its own. `Index.finish` comes after the last scan.
pub fn scan(ix: *Index, io: std.Io, env: *const Env, extra_dirs: []const []const u8) void {
    ix.env = env;
    backend.scan(ix.sink(), io, env);
    for (extra_dirs) |d| backend.scanDir(ix.sink(), io, d, 1);
}

/// An address for the browser or the system (a pane of System Settings),
/// not a file to open.
pub fn isUrl(target: []const u8) bool {
    for ([_][]const u8{
        "https://",
        "http://",
        @import("settings_panes.zig").url_prefix,
    }) |p| if (std.mem.startsWith(u8, target, p)) return true;
    return false;
}

/// Opens an app `scan` found (or a file, a folder).
pub fn launch(io: std.Io, path: []const u8) bool {
    return backend.launch(io, path);
}

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    /// Counts in the store for apps this scan did not find (a volume not
    /// mounted, say): written back with the rest, so they are not lost.
    missed: std.ArrayList(Launch) = .empty,
    /// Apps a scan found but memory left out (`finish` says so).
    lost: u32 = 0,
    /// The environment the apps were found in, for their icons.
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
        ix.missed.deinit(ix.gpa);
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

    /// Alphabetical, case-insensitive; each app's count and icon go with it.
    pub fn sort(ix: *Index) void {
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: App, b: App) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        std.sort.pdq(App, ix.apps.items, Ctx{}, Ctx.lessThan);
    }

    /// Whether `other` lists the same apps and commands, at the same
    /// paths: a rescan that found nothing new (script_live.zig `refresh`).
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

    /// The app a launch count is for: by its path, else (older rows, older
    /// synced records) by its name.
    pub fn resolve(ix: *const Index, path: []const u8, name: []const u8) ?u32 {
        if (path.len > 0) if (ix.findPath(path)) |i| return i;
        return ix.find(name);
    }

    /// Up to `out.len` apps for an empty query: the most opened, else the
    /// starters there are.
    pub fn suggestions(ix: *const Index, out: []u32) usize {
        var n: usize = 0;
        // Most opened first: a few passes from the highest count down.
        var best: u16 = std.math.maxInt(u16);
        while (n < out.len) {
            var next: u16 = 0;
            for (ix.apps.items) |a| if (a.launches < best and a.launches > next) {
                next = a.launches;
            };
            if (next == 0) break;
            for (ix.apps.items, 0..) |a, i| if (a.launches == next and n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            };
            best = next;
        }
        for (starters) |s| {
            if (n == out.len) break;
            const i = ix.find(s) orelse continue;
            if (std.mem.indexOfScalar(u32, out[0..n], i) == null) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// Counts an opening, and keeps the counts in `store`.
    pub fn opened(ix: *Index, i: u32, store: ?nanoui.kv.Store) void {
        ix.apps.items[i].launches +|= 1;
        if (store) |kv| ix.save(kv);
    }

    /// Keeps every count in `kv` (as `opened` does, and a sync after it):
    /// the apps' and those `missed`, the `counts.max` most opened.
    pub fn save(ix: *Index, kv: nanoui.kv.Store) void {
        var list: std.ArrayList(Launch) = .empty;
        defer list.deinit(ix.gpa);
        // best effort: out of memory leaves the stored counts as they were.
        list.ensureTotalCapacity(ix.gpa, ix.apps.items.len + ix.missed.items.len) catch return;
        for (ix.apps.items) |a| if (a.launches > 0) {
            list.appendAssumeCapacity(.{ .key = a.path, .count = a.launches });
        };
        list.appendSliceAssumeCapacity(ix.missed.items);
        const kept = counts.mostOpened(list.items);
        var aw: std.Io.Writer.Allocating = .init(ix.gpa);
        defer aw.deinit();
        // best effort: out of memory leaves the stored counts as they were.
        for (kept) |l| aw.writer.print("{s}\t{d}\n", .{ l.key, l.count }) catch return;
        // A failure is logged; the counts in memory stand for this run.
        _ = prefs.setText(kv, .launches, aw.written());
    }

    /// The counts `opened` kept. Keys are app paths; older rows used
    /// display names and are still read once. Rows for apps not found
    /// are kept in `missed`, at most `counts.max` of them.
    pub fn load(ix: *Index, store: nanoui.kv.Store) void {
        ix.missed.clearRetainingCapacity();
        const v = prefs.text(store, ix.gpa, .launches) orelse return;
        defer ix.gpa.free(v);
        var lines = std.mem.splitScalar(u8, v, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const key = line[0..tab];
            const count = std.fmt.parseInt(u16, line[tab + 1 ..], 10) catch |err| {
                std.log.warn("nanolight: launch count of {s} not read: {t}", .{ key, err });
                continue;
            };
            if (ix.resolve(key, key)) |i| {
                ix.apps.items[i].launches = count;
                continue;
            }
            if (count > 0) ix.keepMissed(key, count);
        }
        assert(ix.missed.items.len <= counts.max);
    }

    /// Keeps a stored count no app here has; once `counts.max` are kept,
    /// only in place of the least opened, if it beats it.
    fn keepMissed(ix: *Index, key: []const u8, count: u16) void {
        var slot: ?usize = null;
        if (ix.missed.items.len == counts.max) {
            var least: usize = 0;
            for (ix.missed.items, 0..) |l, i| if (l.count < ix.missed.items[least].count) {
                least = i;
            };
            if (ix.missed.items[least].count >= count) return;
            slot = least;
        }
        // best effort: a count not kept now is one fewer remembered.
        const owned = ix.arena.allocator().dupe(u8, key) catch return;
        if (slot) |i| {
            ix.missed.items[i] = .{ .key = owned, .count = count };
        } else {
            // best effort: as above.
            ix.missed.append(ix.gpa, .{ .key = owned, .count = count }) catch return;
        }
    }

    /// The app's icon as PNG, made the first time it is asked for.
    pub fn icon(ix: *Index, i: u32) ?[]const u8 {
        const app = &ix.apps.items[i];
        switch (app.icon) {
            .png => |png| return png,
            .none => return null,
            .unloaded => {},
        }
        const io = std.Io.Threaded.global_single_threaded.io();
        const png = backend.icon(ix.gpa, io, ix.env, app.path);
        app.icon = if (png) |p| .{ .png = p } else .none;
        return png;
    }
};

/// A match through an app's pinyin scores this much under its name's.
const pinyin_cost = 70;
/// Each time an app was opened lifts it this much, up to `max_launch_boost`.
const launch_boost = 25;
const max_launch_boost = 250;

/// The best `out.len` apps for `query`, best first: by name or pinyin,
/// lifted by how often each was opened.
pub fn rankApps(query: []const u8, ix: *const Index, out: []search.Ranked) usize {
    var top: search.Top = .init(out);
    for (ix.apps.items, 0..) |app, i| {
        var m = search.score(query, app.name);
        if (app.pinyin.len > 0) if (search.scoreAscii(query, app.pinyin)) |mp| {
            var via = mp;
            via.score -= pinyin_cost;
            via.n = 0;
            if (m == null or via.score > m.?.score) m = via;
        };
        var scored = m orelse continue;
        scored.score += @min(@as(i32, app.launches) * launch_boost, max_launch_boost);
        top.offer(.{ .index = @intCast(i), .match = scored });
    }
    return top.n;
}

test "names are kept once, sorted, and opening one suggests it" {
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
    var out: [3]u32 = undefined;
    // Nothing opened yet: the starters there are.
    try t.expectEqual(@as(usize, 2), ix.suggestions(&out));
    try t.expectEqualStrings("Safari", ix.apps.items[out[0]].name);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.opened(0, mem.store());
    ix.opened(0, mem.store());
    try t.expectEqual(@as(usize, 3), ix.suggestions(&out));
    try t.expectEqualStrings("Calculator", ix.apps.items[out[0]].name);
    // Kept, and read back.
    ix.apps.items[0].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[0].launches);
}

test "a count and an icon stay with their app through a sort" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Mail", "/Applications/Mail.app");
    try ix.add("Zed", "/Applications/Zed.app");
    const zed_was = ix.find("Zed").?;
    ix.opened(zed_was, null);
    ix.apps.items[zed_was].icon = .{ .png = try t.allocator.dupe(u8, "zed") };
    // A name read later (localize) sorts again, after the count: Mail moves.
    ix.apps.items[ix.find("Mail").?].name = "Ångström";
    ix.sort();
    const zed = ix.findPath("/Applications/Zed.app").?;
    try t.expect(zed != zed_was);
    try t.expectEqual(@as(u16, 1), ix.apps.items[zed].launches);
    try t.expectEqualStrings("zed", ix.icon(zed).?);
    const mail = ix.findPath("/Applications/Mail.app").?;
    try t.expectEqual(@as(u16, 0), ix.apps.items[mail].launches);
    try t.expect(ix.apps.items[mail].icon == .unloaded);
}

test "counts outlive a scan that missed their app" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    {
        var ix: Index = .init(t.allocator);
        defer ix.deinit();
        try ix.add("Safari", "/Applications/Safari.app");
        try ix.add("Logic", "/Volumes/Studio/Logic.app");
        ix.opened(ix.find("Logic").?, null);
        ix.opened(ix.find("Logic").?, null);
        ix.opened(ix.find("Safari").?, mem.store());
    }
    {
        // The volume is not mounted: Safari opened again keeps Logic's count.
        var ix: Index = .init(t.allocator);
        defer ix.deinit();
        try ix.add("Safari", "/Applications/Safari.app");
        ix.load(mem.store());
        ix.opened(ix.find("Safari").?, mem.store());
    }
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("Logic", "/Volumes/Studio/Logic.app");
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[ix.find("Logic").?].launches);
    try t.expectEqual(@as(u16, 2), ix.apps.items[ix.find("Safari").?].launches);
    try t.expectEqual(@as(usize, 0), ix.missed.items.len);
}

test "past the cap, the least opened counts are dropped" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    // More stored than kept, least opened first (an order `save` never writes).
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    for (0..counts.max + 10) |i| try aw.writer.print("/gone/{d}.app\t{d}\n", .{ i, i + 1 });
    try mem.store().set(prefs.Key.launches.name(), aw.written());
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    ix.load(mem.store());
    try t.expectEqual(@as(usize, counts.max), ix.missed.items.len);
    for (ix.missed.items) |l| try t.expect(l.count > 10);
    // Safari, opened once, is the least opened of all: it is the one left out.
    ix.opened(0, mem.store());
    const v = (try mem.store().get(t.allocator, prefs.Key.launches.name())).?;
    defer t.allocator.free(v);
    try t.expectEqual(@as(usize, counts.max), std.mem.count(u8, v, "\n"));
    try t.expect(std.mem.indexOf(u8, v, "Safari") == null);
    try t.expect(std.mem.startsWith(u8, v, "/gone/521.app\t522\n"));
}

test "a second look tells an app installed since from no change (#15)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Applications/Alpha.app");
    var buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
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

test "launch counts resolve stored paths on Windows-style keys" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Explorer", "C:\\Windows\\explorer.exe");
    const i = ix.findPath("C:\\Windows\\explorer.exe").?;
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.apps.items[i].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 1), ix.apps.items[i].launches);
}

test "launch counts follow the app path when the display name changes" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const i = ix.findPath("/Applications/WeChat.app").?;
    ix.opened(i, null);
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.apps.items[i].name = "微信";
    ix.apps.items[i].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[i].launches);
}

test "pinyin keys find CJK display names" {
    const t = std.testing;
    var ix = Index.init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const a = ix.arena.allocator();
    ix.apps.items[0].name = try a.dupe(u8, "微信");
    ix.apps.items[0].pinyin = try a.dupe(u8, "weixin");
    var out: [1]search.Ranked = undefined;
    try t.expectEqual(@as(usize, 1), rankApps("weixin", &ix, &out));
    try t.expectEqual(@as(u32, 0), out[0].index);
}

test "rank keeps the best, best first, and opening often lifts a name" {
    const t = std.testing;
    var ix = Index.init(t.allocator);
    defer ix.deinit();
    for ([_][]const u8{ "Notes Helper", "Notes", "Numbers", "Keynote" }) |name| {
        try ix.add(name, name);
    }
    var out: [3]search.Ranked = undefined;
    try t.expectEqual(@as(usize, 3), rankApps("no", &ix, &out));
    try t.expectEqual(@as(u32, 1), out[0].index);
    try t.expectEqual(@as(u32, 3), out[2].index);
    // The helper, opened once, climbs past Notes.
    ix.apps.items[0].launches = 1;
    try t.expectEqual(@as(usize, 3), rankApps("no", &ix, &out));
    try t.expectEqual(@as(u32, 0), out[0].index);
    // Only as many as there's room for: the worst one is the one dropped.
    ix.apps.items[0].launches = 0;
    var two: [2]search.Ranked = undefined;
    try t.expectEqual(@as(usize, 2), rankApps("no", &ix, &two));
    try t.expectEqual(@as(u32, 0), two[1].index);
}
