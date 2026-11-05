//! config.toml: what a person (or a Nix module) says Nanolight should
//! start with. The file seeds the app's own settings and in-app changes
//! win: each key's last-applied file value is kept in the kv store, and
//! only a file value that differs from it is applied again (`seed`).
//! A missing file is the defaults, unless one was applied before (then
//! nothing is recorded or pruned until it is found); a broken one is
//! logged and the defaults are used.
const std = @import("std");
const nanoui = @import("nanoui");
const toml = @import("toml.zig");
const shortcut = @import("shortcut.zig");

const settings = @import("settings.zig");
pub const Quicklink = settings.Quicklink;

pub const Clipboard = struct {
    enabled: bool = true,
    retention_days: u32 = 7,
    max_entries: u32 = 1000,
    paste_plain_text: bool = true,
    /// Mac bundle IDs, Windows exe names, Linux app IDs.
    exclude_apps: []const []const u8 = &.{ "com.bitwarden.desktop", "com.yubico.yubioath" },
};

pub const Sync = struct {
    /// Empty: syncing is off.
    url: []const u8 = "",
    /// The file that holds the bearer token.
    token_file: []const u8 = "",
};

/// A key left out of the file is null: the app's own value stands.
pub const Config = struct {
    /// Read from a file; false for the defaults of a missing one, which seed nothing.
    from_file: bool = false,
    hotkey: ?[]const u8 = null,
    suggestions: ?bool = null,
    open_searches_in_browser: ?bool = null,
    show_in_menu_bar: ?bool = null,
    pop_to_root_seconds: u32 = 90,
    extra_app_dirs: []const []const u8 = &.{},
    script_command_dirs: []const []const u8 = &.{},
    /// Empty: the built-in ones.
    quicklinks: []const Quicklink = &.{},
    clipboard: Clipboard = .{},
    sync: Sync = .{},
};

/// Where and why a config failed to load; `line` is 0 for a wrong value.
pub const Problem = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

/// Silent under test: the build fails a test run that writes to stderr.
fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) std.log.warn(fmt, args);
}

/// The kv keys the settings live under (main.zig reads and writes them too).
pub const suggest_key = "nanolight.suggest";
/// "1": Return opens searches in the browser (issue #10).
pub const searches_out_key = "nanolight.searches_out";
/// "0": no menu bar icon (issue #8).
pub const menu_bar_key = "nanolight.menu_bar";
/// The quicklinks in use, as JSON: the config's, or what sync last brought.
pub const quicklinks_key = "nanolight.quicklinks";
/// "0": clipboard history is off (the app's own switch; the config's `[clipboard] enabled` seeds it).
pub const clipboard_key = "nanolight.clipboard.enabled";
/// When this machine last changed its key or suggestions (settings.zig's `at`).
pub const sync_at_key = "nanolight.sync.at";

const applied_prefix = "nanolight.config.";

/// Set once a config file has been applied; a later launch that finds none must not fall back to defaults.
const seen_key = "nanolight.config.seen";

/// Reads the first config file `candidates` finds. Strings live as long as `arena`.
/// No file is the defaults (`from_file` false). A file that cannot be read or is invalid is null,
/// and so is no file on a machine where one was applied before: the caller seeds only a file it
/// read, and treats null as "retention and exclude list unknown".
pub fn load(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, kv: nanoui.kv.Store) ?Config {
    const data = nanoui.path(arena, .data, "Nanolight") catch null;
    return loadFrom(arena, io, candidates(arena, env, data) catch return null, kv);
}

/// Where a config may live, first match wins: `NANOLIGHT_CONFIG`, the data dir, the XDG config dir
/// (home-manager's `xdg.configFile`), then `/etc/nanolight` (the NixOS and nix-darwin modules).
fn candidates(arena: std.mem.Allocator, env: *const std.process.Environ.Map, data_dir: ?[]const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (env.get("NANOLIGHT_CONFIG")) |p| try out.append(arena, p);
    if (data_dir) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, "config.toml" }));
    const xdg: ?[]const u8 = if (env.get("XDG_CONFIG_HOME")) |x| (if (x.len > 0) x else null) else null;
    if (xdg orelse (if (env.get("HOME")) |h| try std.fs.path.join(arena, &.{ h, ".config" }) else null)) |c|
        try out.append(arena, try std.fs.path.join(arena, &.{ c, "nanolight", "config.toml" }));
    try out.append(arena, "/etc/nanolight/config.toml");
    return out.items;
}

/// A script runs with its folder as the working directory, so a relative
/// `[script_commands] dirs` entry is taken relative to the config file.
fn absoluteScriptDirs(arena: std.mem.Allocator, io: std.Io, c: *Config, config_path: []const u8) !Config {
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, std.fs.path.dirname(config_path) orelse ".", arena);
    const dirs = try arena.alloc([]const u8, c.script_command_dirs.len);
    for (c.script_command_dirs, dirs) |d, *out|
        out.* = if (std.fs.path.isAbsolute(d)) d else try std.fs.path.join(arena, &.{ base, d });
    c.script_command_dirs = dirs;
    return c.*;
}

fn loadFrom(arena: std.mem.Allocator, io: std.Io, paths: []const []const u8, kv: nanoui.kv.Store) ?Config {
    for (paths) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |e| {
            if (e == error.FileNotFound) continue;
            std.log.warn("nanolight: {s}: {t}; using the defaults", .{ path, e });
            return null;
        };
        var problem: Problem = .{};
        var c = parse(arena, text, &problem) catch |e| {
            if (e == error.OutOfMemory) return null;
            if (problem.line > 0)
                std.log.warn("nanolight: {s}:{d}: {s}; using the defaults", .{ path, problem.line, problem.msg })
            else
                std.log.warn("nanolight: {s}: {s}; using the defaults", .{ path, problem.msg });
            return null;
        };
        return absoluteScriptDirs(arena, io, &c, path) catch null;
    }
    if (kv.get(arena, seen_key) catch null) |_| {
        warn("nanolight: no config.toml found, but one was applied before; clipboard history is paused until it is found", .{});
        return null;
    }
    return .{};
}

pub fn parse(arena: std.mem.Allocator, text: []const u8, problem: *Problem) Error!Config {
    var d: toml.Diag = .{};
    const root = toml.parse(arena, text, &d) catch |e| switch (e) {
        error.Syntax => {
            problem.* = .{ .line = d.line, .msg = d.msg };
            return error.Invalid;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    var r: Reader = .{ .a = arena, .problem = problem };
    var c: Config = .{ .from_file = true };
    c.hotkey = try r.get([]const u8, root, "", "hotkey");
    c.suggestions = try r.get(bool, root, "", "suggestions");
    c.open_searches_in_browser = try r.get(bool, root, "", "open_searches_in_browser");
    c.show_in_menu_bar = try r.get(bool, root, "", "show_in_menu_bar");
    if (try r.get(u32, root, "", "pop_to_root_seconds")) |v| c.pop_to_root_seconds = v;
    r.unknown(root, "", &.{ "hotkey", "suggestions", "open_searches_in_browser", "show_in_menu_bar", "pop_to_root_seconds", "apps", "script_commands", "quicklinks", "clipboard", "sync" });

    if (try r.table(root, "apps")) |t| {
        if (try r.get([]const []const u8, t, "apps.", "extra_dirs")) |v| c.extra_app_dirs = v;
        r.unknown(t, "apps.", &.{"extra_dirs"});
    }
    if (try r.table(root, "script_commands")) |t| {
        if (try r.get([]const []const u8, t, "script_commands.", "dirs")) |v| c.script_command_dirs = v;
        r.unknown(t, "script_commands.", &.{"dirs"});
    }
    if (root.get("quicklinks")) |v| c.quicklinks = try r.quicklinks(v);
    if (try r.table(root, "clipboard")) |t| {
        const s = "clipboard.";
        if (try r.get(bool, t, s, "enabled")) |x| c.clipboard.enabled = x;
        if (try r.get(u32, t, s, "retention_days")) |x| c.clipboard.retention_days = x;
        if (try r.get(u32, t, s, "max_entries")) |x| c.clipboard.max_entries = x;
        if (try r.get(bool, t, s, "paste_plain_text")) |x| c.clipboard.paste_plain_text = x;
        if (try r.get([]const []const u8, t, s, "exclude_apps")) |x| c.clipboard.exclude_apps = x;
        r.unknown(t, s, &.{ "enabled", "retention_days", "max_entries", "paste_plain_text", "exclude_apps" });
    }
    if (try r.table(root, "sync")) |t| {
        if (try r.get([]const u8, t, "sync.", "url")) |x| c.sync.url = x;
        if (try r.get([]const u8, t, "sync.", "token_file")) |x| c.sync.token_file = x;
        r.unknown(t, "sync.", &.{ "url", "token_file" });
    }
    return c;
}

const Reader = struct {
    a: std.mem.Allocator,
    problem: *Problem,

    fn bad(r: *Reader, scope: []const u8, key: []const u8, what: []const u8) Error {
        r.problem.* = .{ .msg = std.fmt.allocPrint(r.a, "{s}{s} must be {s}", .{ scope, key, what }) catch "a value has the wrong type" };
        return error.Invalid;
    }

    fn get(r: *Reader, comptime T: type, t: *const toml.Table, scope: []const u8, key: []const u8) Error!?T {
        const v = t.get(key) orelse return null;
        switch (T) {
            bool => return if (v == .boolean) v.boolean else r.bad(scope, key, "true or false"),
            []const u8 => return if (v == .string) v.string else r.bad(scope, key, "a string"),
            u32 => {
                if (v == .int) if (std.math.cast(u32, v.int)) |n| return n;
                return r.bad(scope, key, "a whole number, 0 or more");
            },
            []const []const u8 => {
                if (v != .array) return r.bad(scope, key, "a list of strings");
                const out = try r.a.alloc([]const u8, v.items().len);
                for (v.items(), out) |item, *o| {
                    if (item != .string) return r.bad(scope, key, "a list of strings");
                    o.* = item.string;
                }
                return out;
            },
            else => @compileError("no reader for " ++ @typeName(T)),
        }
    }

    fn table(r: *Reader, t: *const toml.Table, key: []const u8) Error!?*const toml.Table {
        const v = t.get(key) orelse return null;
        return if (v == .table) v.table else r.bad("", key, "a table");
    }

    fn quicklinks(r: *Reader, v: toml.Value) Error![]const Quicklink {
        if (v != .array) return r.bad("", "quicklinks", "a list of tables ([[quicklinks]])");
        var out: std.ArrayList(Quicklink) = .empty;
        for (v.items()) |item| {
            if (item != .table) return r.bad("", "quicklinks", "a list of tables ([[quicklinks]])");
            const t = item.table;
            const name = try r.get([]const u8, t, "quicklinks.", "name") orelse return r.bad("quicklinks.", "name", "set, as a string");
            const url = try r.get([]const u8, t, "quicklinks.", "url") orelse return r.bad("quicklinks.", "url", "set, as a string");
            if (name.len == 0 or url.len == 0) return r.bad("quicklinks.", "name and url", "not empty");
            r.unknown(t, "quicklinks.", &.{ "name", "url", "keyword" });
            if (!settings.webUrl(url)) {
                warn("nanolight: config: quicklink \"{s}\": only http and https addresses work; ignored", .{name});
                continue;
            }
            try out.append(r.a, .{ .name = name, .url = url, .keyword = try r.get([]const u8, t, "quicklinks.", "keyword") orelse "" });
        }
        return out.items;
    }

    /// A key nothing reads is most often a typo: say so.
    fn unknown(r: *Reader, t: *const toml.Table, scope: []const u8, known: []const []const u8) void {
        _ = r;
        outer: for (t.map.keys()) |k| {
            for (known) |name| if (std.mem.eql(u8, k, name)) continue :outer;
            warn("nanolight: config: unknown key {s}{s} is ignored", .{ scope, k });
        }
    }
};

// ----- the file seeds, the app's own changes win -----

/// Whether the file's `value` for `key` is new since it was last applied.
/// A new one is recorded, so the next start sees it as applied.
pub fn fresh(store: nanoui.kv.Store, gpa: std.mem.Allocator, key: []const u8, value: []const u8) bool {
    var buf: [96]u8 = undefined;
    const k = std.fmt.bufPrint(&buf, "{s}{s}", .{ applied_prefix, key }) catch return false;
    if (store.get(gpa, k) catch null) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, value)) return false;
    }
    store.set(k, value) catch {};
    return true;
}

/// A key left out of the file is forgotten, so putting its old value back
/// applies it again.
fn forget(store: nanoui.kv.Store, key: []const u8) void {
    var buf: [96]u8 = undefined;
    const k = std.fmt.bufPrint(&buf, "{s}{s}", .{ applied_prefix, key }) catch return;
    store.remove(k);
}

fn seedBool(store: nanoui.kv.Store, gpa: std.mem.Allocator, key: []const u8, kv_key: []const u8, value: ?bool) bool {
    const v = value orelse {
        forget(store, key);
        return false;
    };
    if (!fresh(store, gpa, key, if (v) "1" else "0")) return false;
    store.set(kv_key, if (v) "1" else "0") catch {};
    return true;
}

fn seedQuicklinks(store: nanoui.kv.Store, gpa: std.mem.Allocator, list: []const Quicklink, synced: *bool) void {
    if (list.len == 0) return forget(store, "quicklinks");
    const json = std.json.Stringify.valueAlloc(gpa, list, .{}) catch return;
    defer gpa.free(json);
    if (!fresh(store, gpa, "quicklinks", json)) return;
    store.set(quicklinks_key, json) catch {};
    synced.* = true;
}

/// Whether clipboard history records: the app's own switch, else the config's value.
pub fn clipboardEnabled(store: nanoui.kv.Store, gpa: std.mem.Allocator, from_file: bool) bool {
    const v = (store.get(gpa, clipboard_key) catch null) orelse return from_file;
    defer gpa.free(v);
    return !std.mem.eql(u8, v, "0");
}

/// The quicklinks kept by the file or by sync; empty means the built-in ones.
pub fn loadQuicklinks(arena: std.mem.Allocator, store: nanoui.kv.Store) []const Quicklink {
    const text = (store.get(arena, quicklinks_key) catch return &.{}) orelse return &.{};
    return std.json.parseFromSliceLeaky([]const Quicklink, arena, text, .{ .ignore_unknown_fields = true }) catch &.{};
}

/// Keeps `list` as the quicklinks in use; empty goes back to the built-in ones.
pub fn saveQuicklinks(store: nanoui.kv.Store, gpa: std.mem.Allocator, list: []const Quicklink) void {
    if (list.len == 0) return store.remove(quicklinks_key);
    const json = std.json.Stringify.valueAlloc(gpa, list, .{}) catch return;
    defer gpa.free(json);
    store.set(quicklinks_key, json) catch {};
}

/// Applies the file's values that changed since they were last applied.
/// A changed hotkey, suggestions or quicklinks list counts as a local change at `now`, so
/// it syncs.
pub fn seed(store: nanoui.kv.Store, gpa: std.mem.Allocator, c: Config, now: i64) void {
    var synced = false;
    store.set(seen_key, "1") catch {};
    if (c.hotkey) |h| {
        if (shortcut.Choice.parse(h)) |choice| {
            if (fresh(store, gpa, "hotkey", h)) {
                shortcut.save(store, choice);
                synced = true;
            }
        } else warn("nanolight: config: hotkey \"{s}\" is not a shortcut this system can use; ignored", .{h});
    } else forget(store, "hotkey");
    seedQuicklinks(store, gpa, c.quicklinks, &synced);
    if (seedBool(store, gpa, "suggestions", suggest_key, c.suggestions)) synced = true;
    _ = seedBool(store, gpa, "open_searches_in_browser", searches_out_key, c.open_searches_in_browser);
    _ = seedBool(store, gpa, "show_in_menu_bar", menu_bar_key, c.show_in_menu_bar);
    _ = seedBool(store, gpa, "clipboard.enabled", clipboard_key, c.clipboard.enabled);
    if (synced) {
        var buf: [24]u8 = undefined;
        store.set(sync_at_key, std.fmt.bufPrint(&buf, "{d}", .{now}) catch "0") catch {};
    }
}

// ----- tests -----

const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, text: []const u8) !Config {
    var p: Problem = .{};
    return parse(arena, text, &p) catch |e| {
        std.debug.print("config problem: line {d}: {s}\n", .{ p.line, p.msg });
        return e;
    };
}

test "an empty file is the defaults" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(), "# nothing\n");
    try testing.expect(c.hotkey == null and c.suggestions == null and c.show_in_menu_bar == null);
    try testing.expectEqual(@as(u32, 90), c.pop_to_root_seconds);
    try testing.expectEqual(@as(usize, 0), c.quicklinks.len);
    try testing.expect(c.clipboard.enabled and c.clipboard.paste_plain_text);
    try testing.expectEqual(@as(u32, 7), c.clipboard.retention_days);
    try testing.expectEqual(@as(usize, 2), c.clipboard.exclude_apps.len);
    try testing.expectEqualStrings("", c.sync.url);
}

test "the whole example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(),
        \\hotkey = "ctrl_space"
        \\suggestions = false
        \\open_searches_in_browser = true
        \\show_in_menu_bar = false
        \\pop_to_root_seconds = 0
        \\
        \\[apps]
        \\extra_dirs = ["/Applications/Nix Apps"]
        \\
        \\[script_commands]
        \\dirs = ["/etc/nanolight/scripts", "/home/me/s"]
        \\
        \\[[quicklinks]]
        \\name = "DuckDuckGo"
        \\url = "https://duckduckgo.com/?q={argument}"
        \\keyword = "ddg"
        \\
        \\[[quicklinks]]
        \\name = "Google"
        \\url = "https://www.google.com/search?q={argument}"
        \\
        \\[clipboard]
        \\enabled = false
        \\retention_days = 30
        \\max_entries = 50
        \\paste_plain_text = false
        \\exclude_apps = ["org.keepassxc.keepassxc"]
        \\
        \\[sync]
        \\url = "http://100.64.0.1:8890"
        \\token_file = "/run/secrets/token"
    );
    try testing.expectEqualStrings("ctrl_space", c.hotkey.?);
    try testing.expectEqual(false, c.suggestions.?);
    try testing.expectEqual(true, c.open_searches_in_browser.?);
    try testing.expectEqual(false, c.show_in_menu_bar.?);
    try testing.expectEqual(@as(u32, 0), c.pop_to_root_seconds);
    try testing.expectEqualStrings("/Applications/Nix Apps", c.extra_app_dirs[0]);
    try testing.expectEqual(@as(usize, 2), c.script_command_dirs.len);
    try testing.expectEqual(@as(usize, 2), c.quicklinks.len);
    try testing.expectEqualStrings("ddg", c.quicklinks[0].keyword);
    try testing.expectEqualStrings("", c.quicklinks[1].keyword);
    try testing.expect(!c.clipboard.enabled and !c.clipboard.paste_plain_text);
    try testing.expectEqual(@as(u32, 30), c.clipboard.retention_days);
    try testing.expectEqual(@as(u32, 50), c.clipboard.max_entries);
    try testing.expectEqualStrings("org.keepassxc.keepassxc", c.clipboard.exclude_apps[0]);
    try testing.expectEqualStrings("http://100.64.0.1:8890", c.sync.url);
    try testing.expectEqualStrings("/run/secrets/token", c.sync.token_file);
}

test "bad files say what and where" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    try testing.expectError(error.Invalid, parse(arena.allocator(), "suggestions = true\nhotkey = \n", &p));
    try testing.expectEqual(@as(usize, 2), p.line);
    for ([_][]const u8{
        "suggestions = \"yes\"\n",
        "pop_to_root_seconds = -1\n",
        "pop_to_root_seconds = 1.5\n",
        "apps = 3\n",
        "[apps]\nextra_dirs = [1]\n",
        "[apps]\nextra_dirs = \"/x\"\n",
        "quicklinks = [1]\n",
        "[[quicklinks]]\nname = \"x\"\n",
        "[[quicklinks]]\nname = \"\"\nurl = \"u\"\n",
        "[clipboard]\nretention_days = \"7\"\n",
    }) |text| {
        p = .{};
        try testing.expectError(error.Invalid, parse(arena.allocator(), text, &p));
        try testing.expectEqual(@as(usize, 0), p.line);
        try testing.expect(p.msg.len > 0);
    }
    // An unknown key is ignored, the rest read.
    const c = try parseOk(arena.allocator(), "colour = 1\nsuggestions = false\n");
    try testing.expectEqual(false, c.suggestions.?);
}

test "quicklinks as an inline array read the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(), "quicklinks = [{ name = \"A\", url = \"http://a/{argument}\", keyword = \"a\" }]\n");
    try testing.expectEqual(@as(usize, 1), c.quicklinks.len);
    try testing.expectEqualStrings("a", c.quicklinks[0].keyword);
}

fn kvGet(store: nanoui.kv.Store, key: []const u8) !?[]u8 {
    return store.get(testing.allocator, key);
}

fn expectKv(store: nanoui.kv.Store, key: []const u8, want: ?[]const u8) !void {
    const v = try kvGet(store, key);
    defer if (v) |x| testing.allocator.free(x);
    if (want) |w| try testing.expectEqualStrings(w, v orelse return error.TestExpectedEqual) else try testing.expect(v == null);
}

test "the file seeds once, then the app's own change wins" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    const file: Config = .{ .hotkey = "ctrl_space", .suggestions = false, .open_searches_in_browser = true, .show_in_menu_bar = false };

    // First start: everything is new.
    seed(store, testing.allocator, file, 1000);
    try testing.expect(shortcut.load(store, testing.allocator).eql(.ctrl_space));
    try expectKv(store, suggest_key, "0");
    try expectKv(store, searches_out_key, "1");
    try expectKv(store, menu_bar_key, "0");
    try expectKv(store, sync_at_key, "1000");

    // The person changes things in the app.
    shortcut.save(store, .opt_space);
    try store.set(suggest_key, "1");
    try store.set(menu_bar_key, "1");
    try store.set(sync_at_key, "1500");

    // The same file on the next start leaves all of it alone.
    seed(store, testing.allocator, file, 2000);
    try testing.expect(shortcut.load(store, testing.allocator).eql(.opt_space));
    try expectKv(store, suggest_key, "1");
    try expectKv(store, menu_bar_key, "1");
    try expectKv(store, sync_at_key, "1500");

    // A key that changes in the file is applied, and counts as a change now.
    var edited = file;
    edited.suggestions = true;
    edited.hotkey = "cmd_space";
    seed(store, testing.allocator, edited, 3000);
    try testing.expect(shortcut.load(store, testing.allocator).eql(.cmd_space));
    try expectKv(store, suggest_key, "1");
    try expectKv(store, sync_at_key, "3000");
    // The ones it did not touch are still the app's.
    try expectKv(store, menu_bar_key, "1");
}

test "an unsynced key changing does not move the sync time" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    seed(store, testing.allocator, .{ .show_in_menu_bar = true }, 10);
    try expectKv(store, sync_at_key, null);
    seed(store, testing.allocator, .{ .show_in_menu_bar = false }, 20);
    try expectKv(store, menu_bar_key, "0");
    try expectKv(store, sync_at_key, null);
}

test "a key removed from the file applies again when it comes back" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    seed(store, testing.allocator, .{ .suggestions = false }, 1);
    try store.set(suggest_key, "1");
    seed(store, testing.allocator, .{}, 2);
    try expectKv(store, suggest_key, "1");
    seed(store, testing.allocator, .{ .suggestions = false }, 3);
    try expectKv(store, suggest_key, "0");
    try expectKv(store, sync_at_key, "3");
}

test "clipboard history's switch: the file seeds it, the app's choice wins, and it never syncs" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    try testing.expect(clipboardEnabled(store, testing.allocator, true));
    try testing.expect(!clipboardEnabled(store, testing.allocator, false));
    seed(store, testing.allocator, .{ .clipboard = .{ .enabled = false } }, 7);
    try expectKv(store, clipboard_key, "0");
    try testing.expect(!clipboardEnabled(store, testing.allocator, true));
    try expectKv(store, sync_at_key, null);
    // Turned on in the app; the same file leaves it on.
    try store.set(clipboard_key, "1");
    seed(store, testing.allocator, .{ .clipboard = .{ .enabled = false } }, 8);
    try testing.expect(clipboardEnabled(store, testing.allocator, false));
    // The file changes its mind: that applies.
    seed(store, testing.allocator, .{ .clipboard = .{ .enabled = true } }, 9);
    try expectKv(store, clipboard_key, "1");
    seed(store, testing.allocator, .{ .clipboard = .{ .enabled = false } }, 10);
    try expectKv(store, clipboard_key, "0");
}

test "a hotkey this system cannot use is ignored, and not recorded" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    seed(store, testing.allocator, .{ .hotkey = "hyper_banana" }, 5);
    try testing.expect(!store.has("nanolight.hotkey"));
    try expectKv(store, sync_at_key, null);
    try expectKv(store, applied_prefix ++ "hotkey", null);
}

test "quicklinks: a changed list is a local change now, an unchanged one leaves the app's alone" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ddg: []const Quicklink = &.{.{ .name = "DDG", .url = "https://duckduckgo.com/?q={argument}", .keyword = "ddg" }};
    seed(store, testing.allocator, .{ .quicklinks = ddg }, 100);
    try testing.expectEqualStrings("ddg", loadQuicklinks(a, store)[0].keyword);
    try expectKv(store, sync_at_key, "100");

    // Sync brought another list; the same file leaves it, and the time, alone.
    const synced: []const Quicklink = &.{.{ .name = "Kagi", .url = "https://kagi.com/search?q={argument}" }};
    saveQuicklinks(store, testing.allocator, synced);
    try store.set(sync_at_key, "150");
    seed(store, testing.allocator, .{ .quicklinks = ddg }, 200);
    try testing.expectEqualStrings("Kagi", loadQuicklinks(a, store)[0].name);
    try expectKv(store, sync_at_key, "150");

    // An edited file wins again, as a change now.
    const edited: []const Quicklink = &.{.{ .name = "Bing", .url = "https://bing.com/search?q={argument}" }};
    seed(store, testing.allocator, .{ .quicklinks = edited }, 300);
    try testing.expectEqualStrings("Bing", loadQuicklinks(a, store)[0].name);
    try expectKv(store, sync_at_key, "300");

    // No list in the file touches nothing; an empty saved list is the defaults.
    seed(store, testing.allocator, .{}, 400);
    try testing.expectEqual(@as(usize, 1), loadQuicklinks(a, store).len);
    saveQuicklinks(store, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), loadQuicklinks(a, store).len);
}

test "a quicklink that is not http or https is dropped, the rest stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(arena.allocator(),
        \\[[quicklinks]]
        \\name = "Local"
        \\url = "file:///etc/passwd?{argument}"
        \\[[quicklinks]]
        \\name = "Ok"
        \\url = "https://a.example/?q={argument}"
        \\
    );
    try testing.expectEqual(@as(usize, 1), c.quicklinks.len);
    try testing.expectEqualStrings("Ok", c.quicklinks[0].name);
}

test "a missing file is the defaults and is not from a file" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = loadFrom(arena.allocator(), testing.io, &.{"/nonexistent/nanolight/config.toml"}, m.store()).?;
    try testing.expect(!c.from_file);
    try testing.expect((try parseOk(arena.allocator(), "")).from_file);
}

test "lookup order: env, data dir, XDG, /etc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NANOLIGHT_CONFIG", "/n/c.toml");
    try env.put("XDG_CONFIG_HOME", "/x");
    var got = try candidates(a, &env, "/d");
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("/n/c.toml", got[0]);
    try testing.expectEqualStrings("/d/config.toml", got[1]);
    try testing.expectEqualStrings("/x/nanolight/config.toml", got[2]);
    try testing.expectEqualStrings("/etc/nanolight/config.toml", got[3]);
    var home: std.process.Environ.Map = .init(testing.allocator);
    defer home.deinit();
    try home.put("HOME", "/h");
    got = try candidates(a, &home, "/d");
    try testing.expectEqualStrings("/d/config.toml", got[0]);
    try testing.expectEqualStrings("/h/.config/nanolight/config.toml", got[1]);
}

test "the first file that exists wins" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.toml", .data = "suggestions = false\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.toml", .data = "suggestions = true\n" });
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const paths = [_][]const u8{
        try std.fs.path.join(a, &.{ dir, "a.toml" }),
        try std.fs.path.join(a, &.{ dir, "b.toml" }),
        try std.fs.path.join(a, &.{ dir, "c.toml" }),
    };
    const c = loadFrom(a, testing.io, &paths, m.store()).?;
    try testing.expectEqual(false, c.suggestions.?);
}

test "a relative script command dir is relative to the config file" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.toml", .data = "[script_commands]\ndirs = [\"scripts\", \"/abs\"]\n" });
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const paths = [_][]const u8{try std.fs.path.join(a, &.{ dir, "a.toml" })};
    const c = loadFrom(a, testing.io, &paths, m.store()).?;
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ dir, "scripts" }), c.script_command_dirs[0]);
    try testing.expectEqualStrings("/abs", c.script_command_dirs[1]);
}

test "a relative config path still gives absolute script command dirs" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.toml", .data = "[script_commands]\ndirs = [\"scripts\"]\n" });
    const a = arena.allocator();
    const paths = [_][]const u8{try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "a.toml" })};
    const c = loadFrom(a, testing.io, &paths, m.store()).?;
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ dir, "scripts" }), c.script_command_dirs[0]);
}

test "no file after one was applied is a failed load, not the defaults" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none = [_][]const u8{"/nonexistent/nanolight/config.toml"};
    try testing.expect(loadFrom(arena.allocator(), testing.io, &none, m.store()) != null);
    seed(m.store(), testing.allocator, .{ .from_file = true }, 1);
    try testing.expect(loadFrom(arena.allocator(), testing.io, &none, m.store()) == null);
}
