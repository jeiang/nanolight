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

const max_quicklinks = 64;
const max_quicklink_field = 512;

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

/// A record's body, or null when it isn't one of ours.
pub fn decode(arena: std.mem.Allocator, body: []const u8) ?Settings {
    const s = std.json.parseFromSliceLeaky(Settings, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
    if (s.v < 1 or s.v > 2 or s.hotkey.len == 0 or s.hotkey.len > 32) return null;
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
    // A steady order, so the same counts encode the same.
    std.sort.pdq(Launch, list.items, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            const ak = launchSortKey(a);
            const bk = launchSortKey(b);
            return std.mem.lessThan(u8, ak, bk);
        }
    }.f);
    out.launches = list.items;
    return out;
}

/// Whether the two say the same.
pub fn same(a: Settings, b: Settings) bool {
    if (!std.mem.eql(u8, a.hotkey, b.hotkey) or a.suggest != b.suggest or a.at != b.at or a.launches.len != b.launches.len) return false;
    for (a.launches, b.launches) |x, y| if (x.count != y.count or !launchSame(x, y)) return false;
    if (a.quicklinks.len != b.quicklinks.len) return false;
    for (a.quicklinks, b.quicklinks) |x, y| {
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
