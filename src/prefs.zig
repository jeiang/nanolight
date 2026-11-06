//! The app's own settings in the kv store: every key Nanolight keeps, its
//! type and its default. A value that cannot be read is logged and its
//! default stands; a write that fails is logged and returns false.
const std = @import("std");
const nanoui = @import("nanoui");
const Quicklink = @import("settings.zig").Quicklink;
const Theme = @import("palette.zig").Theme;

const Store = nanoui.kv.Store;

pub const Key = enum {
    /// Google's completions.
    suggest,
    /// Return opens searches in the browser (issue #10).
    searches_out,
    /// The menu bar icon (issue #8).
    menu_bar,
    /// Local file search, on this Mac only.
    files,
    /// Clipboard history records; the config's `[clipboard] enabled` seeds it.
    clipboard,
    /// The welcome was done.
    onboarded,
    /// The key that opens the panel: shortcut.Choice's name.
    hotkey,
    /// The panel's tint: a `Theme`'s name.
    theme,
    /// The quicklinks in use, as JSON: the config's, or what sync last brought.
    quicklinks,
    /// When this machine last changed a synced setting (settings.zig's `at`).
    sync_at,
    /// The server this machine last synced with: a different one is a first sync again.
    account_synced,
    /// Each app's launch count: "<path>\t<count>" lines (apps.zig).
    launches,
    /// Where file search looks, and what it leaves out (files.zig).
    files_locations,
    files_exclusions,
    /// When the currency rates were last fetched (convert.zig).
    rates_at,
    /// Left by a restart into an update off the Mac, and by 0.1.6 and before
    /// on the Mac: the version it was.
    updated,
    /// Set once a config file was applied; a later launch that finds none
    /// must not fall back to the defaults (config.zig).
    config_seen,

    pub fn name(k: Key) []const u8 {
        return spec(k).name;
    }
};

const Kind = union(enum) {
    /// "1" is on and "0" off; nothing kept (or anything else) is `unset`.
    /// A value that cannot be read is `unreadable`, else `unset`.
    flag: struct { unset: bool, unreadable: ?bool = null },
    /// Decimal; 0 when unset.
    int,
    text,
};

const Spec = struct { name: []const u8, kind: Kind };

fn spec(k: Key) Spec {
    return switch (k) {
        .suggest => .{ .name = "nanolight.suggest", .kind = .{ .flag = .{ .unset = true } } },
        .searches_out => .{
            .name = "nanolight.searches_out",
            .kind = .{ .flag = .{ .unset = false } },
        },
        .menu_bar => .{ .name = "nanolight.menu_bar", .kind = .{ .flag = .{ .unset = true } } },
        .files => .{ .name = "nanolight.files", .kind = .{ .flag = .{ .unset = false } } },
        // A switch that cannot be read is off: history never records against a choice.
        .clipboard => .{
            .name = "nanolight.clipboard.enabled",
            .kind = .{ .flag = .{ .unset = true, .unreadable = false } },
        },
        .onboarded => .{ .name = "nanolight.onboarded", .kind = .{ .flag = .{ .unset = false } } },
        .hotkey => .{ .name = "nanolight.hotkey", .kind = .text },
        .theme => .{ .name = "nanolight.theme", .kind = .text },
        .quicklinks => .{ .name = "nanolight.quicklinks", .kind = .text },
        .sync_at => .{ .name = "nanolight.sync.at", .kind = .int },
        .account_synced => .{ .name = "nanolight.account.synced", .kind = .text },
        .launches => .{ .name = "nanolight.launches", .kind = .text },
        .files_locations => .{ .name = "nanolight.files.locations", .kind = .text },
        .files_exclusions => .{ .name = "nanolight.files.exclusions", .kind = .text },
        .rates_at => .{ .name = "nanolight.rates.at", .kind = .int },
        .updated => .{ .name = "nanolight.updated", .kind = .text },
        .config_seen => .{ .name = applied_prefix ++ "seen", .kind = .text },
    };
}

/// Where config.zig keeps the file's last-applied value for each of its keys.
pub const applied_prefix = "nanolight.config.";
pub const applied_key_max = 96;

/// The record of the file's last-applied value for its key `file_key`.
pub fn appliedKey(buf: *[applied_key_max]u8, file_key: []const u8) []const u8 {
    std.debug.assert(applied_prefix.len + file_key.len <= applied_key_max);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ applied_prefix, file_key }) catch unreachable;
}

/// Silent under test: the build fails a test run that writes to stderr.
fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) std.log.warn(fmt, args);
}

/// Writes `value` at `key`; false, and logged, when it could not be kept.
pub fn put(kv: Store, key: []const u8, value: []const u8) bool {
    kv.set(key, value) catch |e| {
        warn("nanolight: could not save {s}: {t}", .{ key, e });
        return false;
    };
    return true;
}

/// What is kept at `k`, or null (also when it cannot be read: logged). Caller frees it.
pub fn text(kv: Store, gpa: std.mem.Allocator, comptime k: Key) ?[]u8 {
    comptime std.debug.assert(spec(k).kind == .text);
    return kv.get(gpa, k.name()) catch |e| {
        warn("nanolight: could not read {s}: {t}", .{ k.name(), e });
        return null;
    };
}

pub fn setText(kv: Store, comptime k: Key, value: []const u8) bool {
    comptime std.debug.assert(spec(k).kind == .text);
    return put(kv, k.name(), value);
}

/// The switch at `k`, or its default when none is kept.
pub fn flag(kv: Store, gpa: std.mem.Allocator, comptime k: Key) bool {
    return flagOr(kv, gpa, k, spec(k).kind.flag.unset);
}

/// The switch at `k`, or `unset` when none is kept.
pub fn flagOr(kv: Store, gpa: std.mem.Allocator, comptime k: Key, unset: bool) bool {
    const f = comptime spec(k).kind.flag;
    const v = kv.get(gpa, k.name()) catch |e| {
        const fallback = f.unreadable orelse unset;
        warn("nanolight: could not read {s}: {t}; taken as {}", .{ k.name(), e, fallback });
        return fallback;
    } orelse return unset;
    defer gpa.free(v);
    if (std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "0")) return false;
    return unset;
}

pub fn setFlag(kv: Store, comptime k: Key, on: bool) bool {
    comptime std.debug.assert(spec(k).kind == .flag);
    return put(kv, k.name(), if (on) "1" else "0");
}

/// The number at `k`; 0 when none is kept, or it cannot be read (logged).
pub fn int(kv: Store, gpa: std.mem.Allocator, comptime k: Key) i64 {
    comptime std.debug.assert(spec(k).kind == .int);
    const v = kv.get(gpa, k.name()) catch |e| {
        warn("nanolight: could not read {s}: {t}", .{ k.name(), e });
        return 0;
    } orelse return 0;
    defer gpa.free(v);
    return std.fmt.parseInt(i64, v, 10) catch {
        warn("nanolight: {s} is not a number: \"{s}\"", .{ k.name(), v });
        return 0;
    };
}

pub fn setInt(kv: Store, comptime k: Key, value: i64) bool {
    comptime std.debug.assert(spec(k).kind == .int);
    var buf: [24]u8 = undefined;
    return put(kv, k.name(), std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable);
}

pub fn has(kv: Store, comptime k: Key) bool {
    return kv.has(k.name());
}

pub fn remove(kv: Store, comptime k: Key) void {
    kv.remove(k.name());
}

/// The theme kept on this machine; `.system` when none is.
pub fn theme(kv: Store, gpa: std.mem.Allocator) Theme {
    const v = text(kv, gpa, .theme) orelse return .system;
    defer gpa.free(v);
    return std.meta.stringToEnum(Theme, v) orelse .system;
}

pub fn setTheme(kv: Store, t: Theme) bool {
    return setText(kv, .theme, @tagName(t));
}

/// `list` as it is kept; null, and logged, out of memory.
pub fn quicklinksJson(gpa: std.mem.Allocator, list: []const Quicklink) ?[]u8 {
    return std.json.Stringify.valueAlloc(gpa, list, .{}) catch |e| {
        warn("nanolight: could not keep the quicklinks: {t}", .{e});
        return null;
    };
}

/// The quicklinks kept by the file or by sync; empty means the built-in ones,
/// as does a list that cannot be read (logged).
pub fn quicklinks(arena: std.mem.Allocator, kv: Store) []const Quicklink {
    const json = text(kv, arena, .quicklinks) orelse return &.{};
    return std.json.parseFromSliceLeaky(
        []const Quicklink,
        arena,
        json,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        warn("nanolight: {s} is not a quicklink list ({t}); using the built-in ones", .{
            Key.quicklinks.name(),
            e,
        });
        return &.{};
    };
}

/// Keeps `list` as the quicklinks in use; empty goes back to the built-in ones.
/// A failure is logged; the list in memory stands for this run.
pub fn setQuicklinks(kv: Store, gpa: std.mem.Allocator, list: []const Quicklink) void {
    if (list.len == 0) return remove(kv, .quicklinks);
    const json = quicklinksJson(gpa, list) orelse return;
    defer gpa.free(json);
    _ = setText(kv, .quicklinks, json);
}

/// Nanolight's data folder (config.toml, the clipboard, script commands, the rates).
/// Caller frees it.
pub fn dataDir(gpa: std.mem.Allocator) ![]u8 {
    return nanoui.path(gpa, .data, "Nanolight");
}

// ----- tests -----

const testing = std.testing;

test "a switch is on at \"1\", off at \"0\", and its default otherwise" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const kv = m.store();
    try testing.expect(flag(kv, testing.allocator, .suggest));
    try testing.expect(!flag(kv, testing.allocator, .searches_out));
    try testing.expect(setFlag(kv, .suggest, false));
    try testing.expect(!flag(kv, testing.allocator, .suggest));
    try kv.set(Key.suggest.name(), "yes");
    try testing.expect(flag(kv, testing.allocator, .suggest));
    try testing.expect(setFlag(kv, .searches_out, true));
    try testing.expect(flag(kv, testing.allocator, .searches_out));
    try testing.expect(!flagOr(kv, testing.allocator, .clipboard, false));
}

test "a switch that cannot be read is its default, or off for clipboard history" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const kv = m.store();
    try kv.set(Key.clipboard.name(), "1");
    try kv.set(Key.menu_bar.name(), "0");
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expect(!flagOr(kv, failing.allocator(), .clipboard, true));
    try testing.expect(flag(kv, failing.allocator(), .menu_bar));
}

test "a number is kept as decimal text" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const kv = m.store();
    try testing.expectEqual(@as(i64, 0), int(kv, testing.allocator, .sync_at));
    try testing.expect(setInt(kv, .sync_at, 1500));
    const v = (try kv.get(testing.allocator, "nanolight.sync.at")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1500", v);
    try testing.expectEqual(@as(i64, 1500), int(kv, testing.allocator, .sync_at));
    try kv.set(Key.sync_at.name(), "soon");
    try testing.expectEqual(@as(i64, 0), int(kv, testing.allocator, .sync_at));
}

test "the theme is kept by name" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const kv = m.store();
    try testing.expectEqual(Theme.system, theme(kv, testing.allocator));
    try testing.expect(setTheme(kv, .forest));
    try testing.expectEqual(Theme.forest, theme(kv, testing.allocator));
    try kv.set(Key.theme.name(), "plaid");
    try testing.expectEqual(Theme.system, theme(kv, testing.allocator));
}

test "a quicklink list that is not JSON is the built-in ones" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const kv = m.store();
    try kv.set(Key.quicklinks.name(), "[{");
    try testing.expectEqual(@as(usize, 0), quicklinks(arena.allocator(), kv).len);
}
