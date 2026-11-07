//! What the panel opens by name: the apps (apps.zig) and the script commands
//! (script_commands.zig), two lists taken side by side in one name order,
//! and how often each was opened (launch_counts.zig), which lifts it in the
//! ranking and lists it for an empty query.
const std = @import("std");
const nanoui = @import("nanoui");
const apps = @import("apps.zig");
const sc = @import("script_commands.zig");
const launch_counts = @import("launch_counts.zig");
const prefs = @import("prefs.zig");
const search = @import("search.zig");
const Counts = launch_counts.Counts;
const Launch = @import("settings.zig").Launch;

/// An app (its place in `apps.Index`) or a script command (in `sc.List`).
pub const Item = union(enum) {
    app: u32,
    script: u32,

    pub fn eql(a: Item, b: Item) bool {
        return std.meta.eql(a, b);
    }
};

pub const Launchers = struct {
    apps: *const apps.Index,
    scripts: []const sc.Script = &.{},
    counts: *const Counts,

    pub fn name(l: Launchers, it: Item) []const u8 {
        return switch (it) {
            .app => |i| l.apps.apps.items[i].name,
            .script => |i| l.scripts[i].title,
        };
    }

    /// What its count is kept under: an app's path, a script's `key`.
    pub fn key(l: Launchers, it: Item) []const u8 {
        return switch (it) {
            .app => |i| l.apps.apps.items[i].path,
            .script => |i| l.scripts[i].key,
        };
    }

    pub fn count(l: Launchers, it: Item) u16 {
        return l.counts.of(l.key(it));
    }

    /// Every app and script, alphabetically as the two lists are sorted.
    pub fn iterator(l: Launchers) Iterator {
        return .{ .l = l };
    }

    pub const Iterator = struct {
        l: Launchers,
        app: u32 = 0,
        script: u32 = 0,

        pub fn next(it: *Iterator) ?Item {
            const list = it.l.apps.apps.items;
            const more_apps = it.app < list.len;
            const more_scripts = it.script < it.l.scripts.len;
            if (more_apps and (!more_scripts or !std.ascii.lessThanIgnoreCase(
                it.l.scripts[it.script].title,
                list[it.app].name,
            ))) {
                it.app += 1;
                return .{ .app = it.app - 1 };
            }
            if (!more_scripts) return null;
            it.script += 1;
            return .{ .script = it.script - 1 };
        }
    };

    /// The one whose key is `path`, else (older rows, other machines' records)
    /// the one named `name`, case-insensitively.
    pub fn find(l: Launchers, path: []const u8, item_name: []const u8) ?Item {
        if (path.len > 0) if (l.findKey(path)) |x| return x;
        return l.findName(item_name);
    }

    pub fn findKey(l: Launchers, key_: []const u8) ?Item {
        if (l.apps.findPath(key_)) |i| return .{ .app = i };
        for (l.scripts, 0..) |s, i| {
            if (std.mem.eql(u8, s.key, key_)) return .{ .script = @intCast(i) };
        }
        return null;
    }

    pub fn findName(l: Launchers, item_name: []const u8) ?Item {
        if (l.apps.find(item_name)) |i| return .{ .app = i };
        for (l.scripts, 0..) |s, i| {
            if (std.ascii.eqlIgnoreCase(s.title, item_name)) return .{ .script = @intCast(i) };
        }
        return null;
    }

    /// Where `ranked` from `rank` points.
    pub fn at(l: Launchers, ranked: search.Ranked) Item {
        const n: u32 = @intCast(l.apps.apps.items.len);
        return if (ranked.index < n) .{ .app = ranked.index } else .{ .script = ranked.index - n };
    }

    fn flat(l: Launchers, it: Item) u32 {
        return switch (it) {
            .app => |i| i,
            .script => |i| @as(u32, @intCast(l.apps.apps.items.len)) + i,
        };
    }

    /// The best `out.len` for `query`, best first (name order among equals):
    /// by name (an app's pinyin too), lifted by how often each was opened.
    /// `at` says which each is.
    pub fn rank(l: Launchers, query: []const u8, out: []search.Ranked) usize {
        var top: search.Top = .init(out);
        var it = l.iterator();
        while (it.next()) |x| {
            var scored = switch (x) {
                .app => |i| apps.score(query, l.apps.apps.items[i]),
                .script => |i| search.score(query, l.scripts[i].title),
            } orelse continue;
            const boost = @as(i32, l.count(x)) * search.launch_boost;
            scored.score += @min(boost, search.max_launch_boost);
            top.offer(.{ .index = l.flat(x), .match = scored });
        }
        return top.n;
    }

    /// Up to `out.len` for an empty query: the most opened, else the
    /// starters there are.
    pub fn suggestions(l: Launchers, out: []Item) usize {
        var n: usize = 0;
        // Most opened first: a few passes from the highest count down.
        var best: u16 = std.math.maxInt(u16);
        while (n < out.len) {
            var next: u16 = 0;
            var it = l.iterator();
            while (it.next()) |x| {
                const c = l.count(x);
                if (c < best and c > next) next = c;
            }
            if (next == 0) break;
            it = l.iterator();
            while (it.next()) |x| if (l.count(x) == next and n < out.len) {
                out[n] = x;
                n += 1;
            };
            best = next;
        }
        for (apps.starters) |s| {
            if (n == out.len) break;
            const x = l.findName(s) orelse continue;
            for (out[0..n]) |o| {
                if (o.eql(x)) break;
            } else {
                out[n] = x;
                n += 1;
            }
        }
        return n;
    }

    /// Every one opened, as a synced record lists them, in name order.
    pub fn launches(l: Launchers, arena: std.mem.Allocator) []const Launch {
        var list: std.ArrayList(Launch) = .empty;
        var it = l.iterator();
        while (it.next()) |x| {
            const c = l.count(x);
            if (c == 0) continue;
            // best effort: out of memory, the record lists those so far.
            list.append(arena, .{ .name = l.name(x), .path = l.key(x), .count = c }) catch break;
        }
        return list.items;
    }
};

/// This machine's counts and where they are kept: the one writer of
/// `nanolight.launches`.
pub const Tally = struct {
    counts: Counts = .{},
    /// Null in tests: the counts last the run.
    kv: ?nanoui.kv.Store = null,

    pub fn deinit(t: *Tally, gpa: std.mem.Allocator) void {
        t.counts.deinit(gpa);
        t.* = undefined;
    }

    /// The counts kept, into an empty table.
    pub fn load(t: *Tally, gpa: std.mem.Allocator) void {
        const kv = t.kv orelse return;
        const text = prefs.text(kv, gpa, .launches) orelse return;
        defer gpa.free(text);
        t.counts.parse(gpa, text);
    }

    /// Counts an opening of `key`, and keeps it.
    pub fn bump(t: *Tally, gpa: std.mem.Allocator, key: []const u8) void {
        t.counts.bump(gpa, key);
        t.save(gpa);
    }

    /// `key`'s count, at least `count` (another machine's); kept by `save`.
    pub fn raise(t: *Tally, gpa: std.mem.Allocator, key: []const u8, count: u16) void {
        t.counts.raise(gpa, key, count);
    }

    /// Every count kept, the `launch_counts.max` most opened. A failure is
    /// logged; the counts in memory stand for this run.
    pub fn save(t: *const Tally, gpa: std.mem.Allocator) void {
        const kv = t.kv orelse return;
        const text = t.counts.encode(gpa) orelse return;
        defer gpa.free(text);
        prefs.keepText(kv, .launches, text);
    }

    /// Older rows kept an app's count by its name: its key keeps it now.
    pub fn adopt(t: *Tally, gpa: std.mem.Allocator, l: Launchers) void {
        const Old = struct { name: []const u8, key: []const u8 };
        // Found first: a rename changes the table.
        var old: std.ArrayList(Old) = .empty;
        defer old.deinit(gpa);
        for (t.counts.map.keys()) |k| {
            if (l.findKey(k) != null) continue;
            const x = l.findName(k) orelse continue;
            // best effort: out of memory, the older rows wait for the next scan.
            old.append(gpa, .{ .name = k, .key = l.key(x) }) catch break;
        }
        for (old.items) |o| t.counts.rename(gpa, o.name, o.key);
    }
};

fn testIndex(a: std.mem.Allocator, names: []const []const u8) !apps.Index {
    var ix: apps.Index = .init(a);
    for (names) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    ix.sort();
    return ix;
}

test "apps and scripts take turns by name, and opening one suggests it" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "Calculator", "Notes" });
    defer ix.deinit();
    var list: sc.List = .init(t.allocator);
    defer list.deinit();
    list.add(ix.apps.items, "Greet", "Mine", "/s/greet.sh");
    list.add(ix.apps.items, "Script Commands Folder", "Raycast", null);
    list.finish();
    var counts: Counts = .{};
    defer counts.deinit(t.allocator);
    const l: Launchers = .{ .apps = &ix, .scripts = list.items.items, .counts = &counts };
    var names: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = l.iterator();
    while (it.next()) |x| : (n += 1) names[n] = l.name(x);
    try t.expectEqual(@as(usize, 5), n);
    try t.expectEqualStrings("Greet", names[1]);
    try t.expectEqualStrings("Script Commands Folder", names[4]);
    // Nothing opened yet: the starters there are.
    var out: [3]Item = undefined;
    try t.expectEqual(@as(usize, 2), l.suggestions(&out));
    try t.expectEqualStrings("Safari", l.name(out[0]));
    // Opened, a script comes first; ties go by name.
    counts.bump(t.allocator, list.items.items[0].key);
    counts.bump(t.allocator, list.items.items[0].key);
    counts.bump(t.allocator, ix.apps.items[0].path);
    try t.expectEqual(@as(usize, 3), l.suggestions(&out));
    try t.expect(out[0].eql(.{ .script = 0 }));
    try t.expectEqualStrings("Calculator", l.name(out[1]));
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const record = l.launches(arena.allocator());
    try t.expectEqual(@as(usize, 2), record.len);
    try t.expectEqualStrings("script:/s/greet.sh", record[1].path);
    try t.expect(l.find("script:/s/greet.sh", "").?.eql(.{ .script = 0 }));
    try t.expect(l.find("/elsewhere/greet.sh", "GREET").?.eql(.{ .script = 0 }));
}

test "rank keeps the best, best first, and opening often lifts a name" {
    const t = std.testing;
    var ix: apps.Index = .init(t.allocator);
    defer ix.deinit();
    for ([_][]const u8{ "Notes Helper", "Notes", "Numbers", "Keynote" }) |name| {
        try ix.add(name, name);
    }
    var counts: Counts = .{};
    defer counts.deinit(t.allocator);
    const l: Launchers = .{ .apps = &ix, .counts = &counts };
    var out: [3]search.Ranked = undefined;
    try t.expectEqual(@as(usize, 3), l.rank("no", &out));
    try t.expectEqual(@as(u32, 1), out[0].index);
    try t.expectEqual(@as(u32, 3), out[2].index);
    // The helper, opened once, climbs past Notes.
    counts.bump(t.allocator, "Notes Helper");
    try t.expectEqual(@as(usize, 3), l.rank("no", &out));
    try t.expectEqual(@as(u32, 0), out[0].index);
    const none: Counts = .{};
    const fresh: Launchers = .{ .apps = &ix, .counts = &none };
    var two: [2]search.Ranked = undefined;
    try t.expectEqual(@as(usize, 2), fresh.rank("no", &two));
    try t.expectEqual(@as(u32, 0), two[1].index);
}

test "counts outlive a scan that missed their app, and follow its path" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    var tally: Tally = .{ .kv = mem.store() };
    defer tally.deinit(t.allocator);
    tally.bump(t.allocator, "/Volumes/Studio/Logic.app");
    tally.bump(t.allocator, "/Volumes/Studio/Logic.app");
    tally.bump(t.allocator, "C:\\Windows\\explorer.exe");
    // The volume is not mounted, and the app has another name now: both keep theirs.
    var again: Tally = .{ .kv = mem.store() };
    defer again.deinit(t.allocator);
    again.load(t.allocator);
    var ix: apps.Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("微信", "C:\\Windows\\explorer.exe");
    again.adopt(t.allocator, .{ .apps = &ix, .counts = &again.counts });
    const l: Launchers = .{ .apps = &ix, .counts = &again.counts };
    try t.expectEqual(@as(u16, 1), l.count(.{ .app = 0 }));
    try t.expectEqual(@as(u16, 2), again.counts.of("/Volumes/Studio/Logic.app"));
    // An older row by the app's name, in any case, is its path's from now on.
    var old: Tally = .{};
    defer old.deinit(t.allocator);
    old.counts.parse(t.allocator, "safari\t4\n");
    var named = try testIndex(t.allocator, &.{"Safari"});
    defer named.deinit();
    old.adopt(t.allocator, .{ .apps = &named, .counts = &old.counts });
    try t.expectEqual(@as(u16, 4), old.counts.of("/Applications/Safari.app"));
    // Without a store, an opening is counted for the run only.
    old.bump(t.allocator, "/Applications/Safari.app");
    try t.expectEqual(@as(u16, 5), old.counts.of("/Applications/Safari.app"));
}
