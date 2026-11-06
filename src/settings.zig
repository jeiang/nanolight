//! What Nanolight syncs between a person's machines, as one record: the key
//! that opens it, whether Google's suggestions are on, the quicklinks, and
//! how often each app was opened (what an empty panel suggests). JSON, so
//! nanolight-server (server.zig) keeps it as it came.
//!
//! Two machines merge, never overwrite: the key, the suggestions and the
//! quicklinks go with whichever changed them last (`at`), and each app keeps
//! the higher count of the two, so what you open most anywhere comes up first.
const std = @import("std");

pub const Launch = struct {
    name: []const u8,
    /// Stable across locales; empty in older synced records.
    path: []const u8 = "",
    count: u16,
};

pub const Quicklink = struct {
    name: []const u8,
    /// `{argument}` is where the typed words go, escaped.
    url: []const u8,
    keyword: []const u8 = "",
};

/// What Nanolight searches with when no quicklinks are set; the first is
/// the search for what was typed, and Google's suggestions go with Google.
pub const default_quicklinks = [_]Quicklink{
    .{ .name = "Google", .url = "https://www.google.com/search?q={argument}" },
    .{ .name = "DuckDuckGo", .url = "https://duckduckgo.com/?q={argument}", .keyword = "ddg" },
    .{ .name = "Claude", .url = "https://claude.ai/new?q={argument}" },
    .{ .name = "Grok", .url = "https://grok.com/?q={argument}" },
    .{ .name = "X", .url = "https://x.com/search?f=live&q={argument}" },
};

/// A quicklink opens in a browser or the panel: http and https only.
pub fn webUrl(url: []const u8) bool {
    inline for (.{ "http://", "https://" }) |scheme| {
        if (url.len > scheme.len and std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) return true;
    }
    return false;
}

const max_quicklinks = 64;
const max_quicklink_field = 512;
/// A record keeps at most this many launch counts: the most opened.
pub const max_launches = 512;

pub const Settings = struct {
    /// 2 added `quicklinks`; a record of 1 still decodes.
    v: u8 = 2,
    /// shortcut.Choice's name: "cmd_space", or a recorded "key:7:2048:120".
    hotkey: []const u8,
    suggest: bool,
    /// When `hotkey`, `suggest` or `quicklinks` last changed, on whichever machine (unix seconds).
    at: i64,
    launches: []const Launch = &.{},
    /// Empty: the built-in ones.
    quicklinks: []const Quicklink = &.{},
};

pub fn encode(gpa: std.mem.Allocator, s: Settings) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, s, .{});
}

/// The longest key name a record carries (shortcut.zig's `Choice.name`).
pub const hotkey_max = 32;

/// A record's body, or null when it isn't one of ours. Past `max_launches`,
/// the least opened apps are left out.
pub fn decode(arena: std.mem.Allocator, body: []const u8) ?Settings {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    var s = std.json.parseFromSliceLeaky(Settings, arena, body, options) catch return null;
    if (s.v < 1 or s.v > 2 or s.hotkey.len == 0 or s.hotkey.len > hotkey_max) return null;
    s.launches = mostOpened(arena, s.launches) catch return null;
    if (s.quicklinks.len > max_quicklinks) return null;
    for (s.quicklinks) |q| {
        if (q.name.len == 0 or q.url.len == 0) return null;
        if (q.name.len > max_quicklink_field or q.url.len > max_quicklink_field or q.keyword.len > max_quicklink_field) return null;
    }
    return s;
}

/// The two, merged. `prefer_remote`: this Mac's first sync, where the
/// account's key and choices win over what a fresh install picked.
pub fn merge(arena: std.mem.Allocator, local: Settings, remote: Settings, prefer_remote: bool) !Settings {
    const theirs = prefer_remote or remote.at > local.at;
    var out: Settings = if (theirs)
        .{ .hotkey = remote.hotkey, .suggest = remote.suggest, .at = remote.at, .quicklinks = remote.quicklinks }
    else
        .{ .hotkey = local.hotkey, .suggest = local.suggest, .at = local.at, .quicklinks = local.quicklinks };
    var list: std.ArrayList(Launch) = .empty;
    for ([_][]const Launch{ local.launches, remote.launches }) |side| for (side) |l| {
        if (l.name.len == 0 or l.name.len > 255) continue;
        if (l.path.len > 512) continue;
        for (list.items) |*have| {
            if (launchSame(have.*, l)) {
                have.count = @max(have.count, l.count);
                if (have.path.len == 0 and l.path.len > 0) have.path = l.path;
                break;
            }
        } else try list.append(arena, l);
    };
    sortByKey(list.items);
    out.launches = try mostOpened(arena, list.items);
    return out;
}

/// A steady order, so the same counts encode the same.
fn sortByKey(launches: []Launch) void {
    std.sort.pdq(Launch, launches, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            return std.mem.lessThan(u8, launchSortKey(a), launchSortKey(b));
        }
    }.f);
}

/// Most opened first, the same on every run (of equals, the earlier key).
fn sortByCount(launches: []Launch) void {
    std.sort.pdq(Launch, launches, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, launchSortKey(a), launchSortKey(b));
        }
    }.f);
}

/// `launches`, or past `max_launches` the most opened of them, in key order.
fn mostOpened(arena: std.mem.Allocator, launches: []const Launch) ![]const Launch {
    if (launches.len <= max_launches) return launches;
    const ranked = try arena.dupe(Launch, launches);
    sortByCount(ranked);
    const kept = ranked[0..max_launches];
    sortByKey(kept);
    return kept;
}

/// `s` encoded in at most `limit` bytes, or null when even without launches
/// it is not. Too many launches drop the least opened, the same ones on every
/// run (ties go to the later key).
pub fn encodeWithin(arena: std.mem.Allocator, s: Settings, limit: usize) !?[]u8 {
    var out = s;
    const ranked = try arena.dupe(Launch, s.launches);
    sortByCount(ranked);
    var keep = ranked.len;
    while (true) {
        const body = try encode(arena, out);
        if (body.len <= limit) return body;
        if (keep == 0) return null;
        keep /= 2;
        out.launches = try arena.dupe(Launch, ranked[0..keep]);
        sortByKey(@constCast(out.launches));
    }
}

/// Whether the two say the same.
pub fn same(a: Settings, b: Settings) bool {
    if (!std.mem.eql(u8, a.hotkey, b.hotkey) or a.suggest != b.suggest or a.at != b.at or a.launches.len != b.launches.len) return false;
    for (a.launches, b.launches) |x, y| if (x.count != y.count or !launchSame(x, y)) return false;
    return sameQuicklinks(a.quicklinks, b.quicklinks);
}

pub fn sameQuicklinks(a: []const Quicklink, b: []const Quicklink) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.name, y.name) or !std.mem.eql(u8, x.url, y.url) or !std.mem.eql(u8, x.keyword, y.keyword)) return false;
    }
    return true;
}

fn launchSame(a: Launch, b: Launch) bool {
    if (a.path.len > 0 and b.path.len > 0) return std.mem.eql(u8, a.path, b.path);
    return std.mem.eql(u8, a.name, b.name);
}

fn launchSortKey(l: Launch) []const u8 {
    if (l.path.len > 0) return l.path;
    return l.name;
}

test "two Macs merge: the later choice wins, and each app keeps its higher count" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const here: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 100, .launches = &.{ .{ .name = "Safari", .count = 5 }, .{ .name = "Notes", .count = 1 } } };
    const there: Settings = .{ .hotkey = "opt_space", .suggest = false, .at = 200, .launches = &.{ .{ .name = "Notes", .count = 4 }, .{ .name = "Mail", .count = 2 } } };
    const m = try merge(a, here, there, false);
    try std.testing.expectEqualStrings("opt_space", m.hotkey);
    try std.testing.expect(!m.suggest);
    try std.testing.expectEqual(@as(usize, 3), m.launches.len);
    try std.testing.expectEqualStrings("Mail", m.launches[0].name);
    try std.testing.expectEqual(@as(u16, 4), m.launches[1].count);
    try std.testing.expectEqual(@as(u16, 5), m.launches[2].count);
    // Merged either way round, the same.
    try std.testing.expect(same(m, try merge(a, there, here, false)));
    // This Mac changed its key last: it stays.
    const later: Settings = .{ .hotkey = "ctrl_space", .suggest = true, .at = 300 };
    try std.testing.expectEqualStrings("ctrl_space", (try merge(a, later, there, false)).hotkey);
    // But a first sync takes the account's, whatever this Mac picked.
    try std.testing.expectEqualStrings("opt_space", (try merge(a, later, there, true)).hotkey);
}

test "a record round-trips, and what isn't one isn't taken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 1793600000, .launches = &.{.{ .name = "Visual \"Studio\" Code", .count = 3 }}, .quicklinks = &.{.{ .name = "DuckDuckGo", .url = "https://duckduckgo.com/?q={argument}", .keyword = "ddg" }} };
    const body = try encode(a, s);
    const back = decode(a, body).?;
    try std.testing.expect(same(s, back));
    try std.testing.expect(decode(a, "{\"v\":3,\"hotkey\":\"x\",\"suggest\":true,\"at\":1}") == null);
    try std.testing.expect(decode(a, "{\"v\":2,\"hotkey\":\"x\",\"suggest\":true,\"at\":1,\"quicklinks\":[{\"name\":\"\",\"url\":\"u\"}]}") == null);
    try std.testing.expect(decode(a, "not json") == null);
    // Fields a later version adds are passed over.
    try std.testing.expect(decode(a, "{\"v\":2,\"hotkey\":\"cmd_space\",\"suggest\":false,\"at\":5,\"theme\":\"dark\"}") != null);
}

test "a v1 record decodes with no quicklinks, and the quicklinks go with the later choice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const old = decode(a, "{\"v\":1,\"hotkey\":\"cmd_space\",\"suggest\":true,\"at\":5}").?;
    try std.testing.expectEqual(@as(usize, 0), old.quicklinks.len);
    const ql: []const Quicklink = &.{.{ .name = "Claude", .url = "https://claude.ai/new?q={argument}" }};
    const newer: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 9, .quicklinks = ql };
    try std.testing.expectEqual(@as(usize, 1), (try merge(a, old, newer, false)).quicklinks.len);
    try std.testing.expectEqual(@as(usize, 1), (try merge(a, newer, old, false)).quicklinks.len);
    try std.testing.expect(!same(old, newer));
    try std.testing.expectEqual(@as(u8, 2), (try merge(a, old, old, false)).v);
}

test "only http and https quicklinks are web addresses" {
    try std.testing.expect(webUrl("https://x.com/?q={argument}"));
    try std.testing.expect(webUrl("HTTP://a/b"));
    try std.testing.expect(!webUrl("file:///etc/passwd"));
    try std.testing.expect(!webUrl("javascript:alert(1)"));
    try std.testing.expect(!webUrl("https://"));
    for (default_quicklinks) |q| try std.testing.expect(webUrl(q.url));
}

test "a record too big for the limit sheds its least opened apps" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const launches = try a.alloc(Launch, 100);
    for (launches, 0..) |*l, i| {
        l.* = .{ .name = "App", .path = try std.fmt.allocPrint(a, "/Applications/{d:0>3}", .{i}), .count = @intCast(i) };
    }
    const s: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 1, .launches = launches };
    const whole = try encode(a, s);
    const body = (try encodeWithin(a, s, whole.len - 1)).?;
    try std.testing.expect(body.len < whole.len);
    const got = decode(a, body).?;
    try std.testing.expect(got.launches.len > 0 and got.launches.len < 100);
    for (got.launches) |l| try std.testing.expect(l.count >= 100 - got.launches.len);
    try std.testing.expect((try encodeWithin(a, s, 10)) == null);
    try std.testing.expectEqualStrings(whole, (try encodeWithin(a, s, whole.len)).?);
}

test "a record keeps the most opened apps, at most max_launches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const launches = try a.alloc(Launch, max_launches + 50);
    for (launches, 0..) |*l, i| {
        const path = try std.fmt.allocPrint(a, "/Applications/{d:0>4}", .{i});
        l.* = .{ .name = "App", .path = path, .count = @intCast(i + 1) };
    }
    const s: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 1, .launches = launches };
    const got = decode(a, try encode(a, s)).?;
    try std.testing.expectEqual(@as(usize, max_launches), got.launches.len);
    for (got.launches) |l| try std.testing.expect(l.count > 50);
    // Merged with itself, no more than the cap either.
    try std.testing.expectEqual(@as(usize, max_launches), (try merge(a, s, s, false)).launches.len);
}
