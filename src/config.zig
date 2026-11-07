//! config.toml: what a person (or a Nix module) says Nanolight should
//! start with. The file seeds the app's own settings and in-app changes
//! win: each key's last-applied file value is kept in the kv store, and
//! only a file value that differs from it is applied again (`seed`).
//! A missing file is the defaults, unless one was applied before (then
//! nothing is recorded or pruned until it is found); a broken one is
//! logged and the defaults are used (`Loaded`).
const std = @import("std");
const nanoui = @import("nanoui");
const toml = @import("toml.zig");
const keys = @import("keys.zig");
const clipboard = @import("clipboard.zig");
const account = @import("account.zig");
const prefs = @import("prefs.zig");
const settings = @import("settings.zig");
const Quicklink = @import("web.zig").Quicklink;
const log = @import("log.zig");

pub const max_bytes = 1 << 20;

/// The file's keys: each field is the key of its name, a struct a table of
/// its own (`parse`). A key left out of the file is null, the app's own
/// value standing, or else the default.
pub const Config = struct {
    hotkey: ?[]const u8 = null,
    suggestions: ?bool = null,
    open_searches_in_browser: ?bool = null,
    show_in_menu_bar: ?bool = null,
    pop_to_root_seconds: u32 = 90,
    apps: Apps = .{},
    script_commands: ScriptCommands = .{},
    /// Empty: the built-in ones.
    quicklinks: []const Quicklink = &.{},
    clipboard: clipboard.Config = .{},
    sync: account.Config = .{},
};

pub const Apps = struct {
    /// Scanned like /Applications (depth 1).
    extra_dirs: []const []const u8 = &.{},
};

pub const ScriptCommands = struct {
    /// Besides `<data dir>/script-commands`; absolute once loaded (`absoluteScriptDirs`).
    dirs: []const []const u8 = &.{},
};

/// What a file key seeds in the app's own settings (prefs.zig), in this
/// order, and the synced field it sets, if any. `key` is its path in `Config`
/// ("table.key") and names its applied record.
const Seed = struct {
    key: []const u8,
    rule: Rule,
    setting: ?settings.Field = null,

    /// Whether a change to it is a local change that syncs: it sets one of the `choices`.
    fn syncs(s: Seed) bool {
        return if (s.setting) |f| settings.isChoice(f) else false;
    }
};
const Rule = union(enum) { hotkey, quicklinks, flag: prefs.Key };
const seeds = [_]Seed{
    .{ .key = "hotkey", .rule = .hotkey, .setting = .hotkey },
    .{ .key = "quicklinks", .rule = .quicklinks, .setting = .quicklinks },
    .{ .key = "suggestions", .rule = .{ .flag = .suggest }, .setting = .suggest },
    .{ .key = "open_searches_in_browser", .rule = .{ .flag = .searches_out } },
    .{ .key = "show_in_menu_bar", .rule = .{ .flag = .menu_bar } },
    .{ .key = "clipboard.enabled", .rule = .{ .flag = .clipboard } },
};

pub const Loaded = union(enum) {
    /// No file, and none was applied before: the defaults, which seed nothing.
    defaults,
    /// Read from a file: it seeds.
    file: Config,
    /// A file that cannot be read or is invalid, no file where one was applied before,
    /// or a headless run: the retention and the exclude list are unknown, so clipboard
    /// history records and prunes nothing, and nothing is seeded.
    unusable,

    /// The values in use: the file's, else the defaults.
    pub fn config(l: Loaded) Config {
        return switch (l) {
            .file => |c| c,
            .defaults, .unusable => .{},
        };
    }

    /// The clipboard's values in use. An unusable load knows no retention or
    /// count limit: only the store's fixed size budget prunes.
    pub fn clipboardConfig(l: Loaded) clipboard.Config {
        var c = l.config().clipboard;
        if (l == .unusable) {
            c.retention_days = 0;
            c.max_entries = 0;
        }
        return c;
    }
};

/// Where and why a config failed to load; `line` is 0 for a wrong value.
/// `ignored` lists what a file that loads has that the app leaves out
/// (an unknown key, a dropped quicklink, a hotkey this system can't use).
pub const Problem = struct {
    line: usize = 0,
    msg: []const u8 = "",
    ignored: std.ArrayList([]const u8) = .empty,
};

pub const Error = error{ Invalid, OutOfMemory };

/// Reads the first config file `candidates` finds. Strings live as long as `arena`.
pub fn load(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    kv: nanoui.kv.Store,
) Loaded {
    const data = prefs.dataDir(arena) catch null;
    return loadFrom(arena, io, candidates(arena, env, data) catch return .unusable, kv);
}

/// Where a config may live, first match wins: `NANOLIGHT_CONFIG`, the data dir, the XDG config dir
/// (home-manager's `xdg.configFile`), then `/etc/nanolight` (the NixOS and nix-darwin modules).
fn candidates(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    data_dir: ?[]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (env.get("NANOLIGHT_CONFIG")) |p| try out.append(arena, p);
    if (data_dir) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, "config.toml" }));
    const xdg: ?[]const u8 = if (env.get("XDG_CONFIG_HOME")) |x|
        (if (x.len > 0) x else null)
    else
        null;
    if (xdg orelse (if (env.get("HOME")) |h|
        try std.fs.path.join(arena, &.{ h, ".config" })
    else
        null)) |c|
        try out.append(arena, try std.fs.path.join(arena, &.{ c, "nanolight", "config.toml" }));
    try out.append(arena, "/etc/nanolight/config.toml");
    return out.items;
}

/// A script runs with its folder as the working directory, so a relative
/// `[script_commands] dirs` entry is taken relative to the config file.
fn absoluteScriptDirs(
    arena: std.mem.Allocator,
    io: std.Io,
    c: *Config,
    config_path: []const u8,
) !Config {
    const base = try std.Io.Dir.cwd()
        .realPathFileAlloc(io, std.fs.path.dirname(config_path) orelse ".", arena);
    const dirs = try arena.alloc([]const u8, c.script_commands.dirs.len);
    for (c.script_commands.dirs, dirs) |d, *out|
        out.* = if (std.fs.path.isAbsolute(d)) d else try std.fs.path.join(arena, &.{ base, d });
    c.script_commands.dirs = dirs;
    return c.*;
}

fn loadFrom(
    arena: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    kv: nanoui.kv.Store,
) Loaded {
    for (paths) |path| {
        const cwd = std.Io.Dir.cwd();
        const text = cwd.readFileAlloc(io, path, arena, .limited(max_bytes)) catch |e| {
            if (e == error.FileNotFound) continue;
            log.warn("nanolight: {s}: {t}; using the defaults", .{ path, e });
            return .unusable;
        };
        var problem: Problem = .{};
        var c = parse(arena, text, &problem) catch |e| {
            if (e == error.OutOfMemory) return .unusable;
            if (problem.line > 0)
                log.warn(
                    "nanolight: {s}:{d}: {s}; using the defaults",
                    .{ path, problem.line, problem.msg },
                )
            else
                log.warn("nanolight: {s}: {s}; using the defaults", .{ path, problem.msg });
            return .unusable;
        };
        for (problem.ignored.items) |what|
            log.warn("nanolight: {s}: {s}; ignored", .{ path, what });
        return .{ .file = absoluteScriptDirs(arena, io, &c, path) catch return .unusable };
    }
    // Unreadable counts as applied before: the defaults must not stand in for a lost file.
    const seen = kv.get(arena, prefs.Key.config_seen.name()) catch |e| {
        log.warn(
            "nanolight: could not read {s}: {t}; clipboard history is paused",
            .{ prefs.Key.config_seen.name(), e },
        );
        return .unusable;
    };
    if (seen != null) {
        log.warn("nanolight: no config.toml found, but one was applied before; " ++
            "clipboard history is paused until it is found", .{});
        return .unusable;
    }
    return .defaults;
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
    var c = try r.table(Config, root, "");
    if (c.hotkey) |h| if (keys.Choice.parse(h) == null) {
        try r.ignore("hotkey \"{s}\" is not a shortcut this system can use", .{h});
        c.hotkey = null;
    };
    return c;
}

const Reader = struct {
    a: std.mem.Allocator,
    problem: *Problem,

    fn bad(r: *Reader, scope: []const u8, key: []const u8, what: []const u8) Error {
        r.problem.line = 0;
        r.problem.msg = std.fmt.allocPrint(
            r.a,
            "{s}{s} must be {s}",
            .{ scope, key, what },
        ) catch "a value has the wrong type";
        return error.Invalid;
    }

    fn ignore(r: *Reader, comptime fmt: []const u8, args: anytype) Error!void {
        try r.problem.ignored.append(r.a, try std.fmt.allocPrint(r.a, fmt, args));
    }

    /// `T` read from `t`, the table at `scope` ("" or "name."): each field
    /// its key, a struct field a table, and any other key ignored.
    fn table(
        r: *Reader,
        comptime T: type,
        t: *const toml.Table,
        comptime scope: []const u8,
    ) Error!T {
        var out: T = .{};
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            const dest = &@field(out, name);
            if (F == []const Quicklink) {
                if (t.get(name)) |v| dest.* = try r.quicklinks(v);
            } else if (@typeInfo(F) == .@"struct") {
                if (t.get(name)) |v| {
                    if (v != .table) return r.bad(scope, name, "a table");
                    dest.* = try r.table(F, v.table, scope ++ name ++ ".");
                }
            } else if (@typeInfo(F) == .optional) {
                dest.* = try r.get(@typeInfo(F).optional.child, t, scope, name);
            } else if (try r.get(F, t, scope, name)) |v| dest.* = v;
        }
        try r.unknown(t, scope, comptime std.meta.fieldNames(T));
        return out;
    }

    fn get(
        r: *Reader,
        comptime T: type,
        t: *const toml.Table,
        scope: []const u8,
        key: []const u8,
    ) Error!?T {
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

    fn quicklinks(r: *Reader, v: toml.Value) Error![]const Quicklink {
        if (v != .array) return r.bad("", "quicklinks", "a list of tables ([[quicklinks]])");
        var out: std.ArrayList(Quicklink) = .empty;
        for (v.items(), 0..) |item, i| {
            if (item != .table) return r.bad("", "quicklinks", "a list of tables ([[quicklinks]])");
            const t = item.table;
            const name = try r.get([]const u8, t, "quicklinks.", "name") orelse
                return r.bad("quicklinks.", "name", "set, as a string");
            const url = try r.get([]const u8, t, "quicklinks.", "url") orelse
                return r.bad("quicklinks.", "url", "set, as a string");
            if (name.len == 0 or
                url.len == 0) return r.bad("quicklinks.", "name and url", "not empty");
            try r.unknown(t, "quicklinks.", comptime std.meta.fieldNames(Quicklink));
            const q: Quicklink = .{
                .name = name,
                .url = url,
                .keyword = try r.get([]const u8, t, "quicklinks.", "keyword") orelse "",
            };
            if (settings.quicklinkProblem(i, q)) |why| {
                try r.ignore("quicklink \"{s}\": {s}", .{ name, why });
                continue;
            }
            try out.append(r.a, q);
        }
        return out.items;
    }

    /// A key nothing reads is most often a typo: say so.
    fn unknown(
        r: *Reader,
        t: *const toml.Table,
        scope: []const u8,
        known: []const [:0]const u8,
    ) Error!void {
        outer: for (t.map.keys()) |k| {
            for (known) |name| if (std.mem.eql(u8, k, name)) continue :outer;
            try r.ignore("unknown key {s}{s}", .{ scope, k });
        }
    }
};

// ----- the file seeds, the app's own changes win -----

/// Whether the file's `value` for `key` is new since it was last applied. A record that
/// cannot be read counts as applied: the app's own value stands.
fn fresh(store: nanoui.kv.Store, gpa: std.mem.Allocator, key: []const u8, value: []const u8) bool {
    var buf: [prefs.applied_key_max]u8 = undefined;
    const k = prefs.appliedKey(&buf, key);
    const old = store.get(gpa, k) catch |e| {
        log.warn(
            "nanolight: could not read {s}: {t}; the config's value is not applied",
            .{ k, e },
        );
        return false;
    } orelse return true;
    defer gpa.free(old);
    return !std.mem.eql(u8, old, value);
}

/// Records `value` as applied for `key`; only after the value itself was kept, so a
/// failed write is tried again at the next start rather than lost.
fn record(store: nanoui.kv.Store, key: []const u8, value: []const u8) void {
    var buf: [prefs.applied_key_max]u8 = undefined;
    // Unkept, the next start applies the same value again.
    prefs.keep(store, prefs.appliedKey(&buf, key), value);
}

/// A key left out of the file is forgotten, so putting its old value back
/// applies it again.
fn forget(store: nanoui.kv.Store, key: []const u8) void {
    var buf: [prefs.applied_key_max]u8 = undefined;
    store.remove(prefs.appliedKey(&buf, key));
}

/// Seeds from what `load` found. Only a file does: a missing one would forget what the
/// app applied, and an unusable one (a headless run among them) says nothing reliable.
pub fn apply(store: nanoui.kv.Store, gpa: std.mem.Allocator, loaded: Loaded, now: i64) void {
    switch (loaded) {
        .file => |c| seed(store, gpa, c, now),
        .defaults, .unusable => {},
    }
}

/// The type of `Config`'s field at `path`: "key", or "table.key".
fn Field(comptime path: []const u8) type {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return @FieldType(Config, path);
    std.debug.assert(std.mem.indexOfScalarPos(u8, path, dot + 1, '.') == null);
    return @FieldType(@FieldType(Config, path[0..dot]), path[dot + 1 ..]);
}

fn field(c: Config, comptime path: []const u8) Field(path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |d| return @field(@field(c, path[0..d]), path[d + 1 ..]);
    return @field(c, path);
}

/// Applies the file's values that changed since they were last applied, each value
/// before its applied record. A changed key that syncs counts as a local change at
/// `now`, so it syncs.
fn seed(store: nanoui.kv.Store, gpa: std.mem.Allocator, c: Config, now: i64) void {
    // Unkept, the next start with no file uses the defaults.
    prefs.keepText(store, .config_seen, "1");
    var synced = false;
    inline for (seeds) |s| {
        if (seedOne(store, gpa, s, field(c, s.key)) and comptime s.syncs()) synced = true;
    }
    // Unkept, the change still syncs at the next one.
    if (synced) prefs.keepInt(store, .sync_at, now);
}

/// Applies the file's `value` for `s` if it is new: whether it was. Left out
/// of the file, its record is forgotten.
fn seedOne(store: nanoui.kv.Store, gpa: std.mem.Allocator, comptime s: Seed, value: anytype) bool {
    switch (s.rule) {
        .flag => |k| {
            const on = value orelse {
                forget(store, s.key);
                return false;
            };
            const text = if (on) "1" else "0";
            if (!fresh(store, gpa, s.key, text)) return false;
            if (!prefs.setFlag(store, k, on)) return false;
            record(store, s.key, text);
        },
        .hotkey => {
            const name = value orelse {
                forget(store, s.key);
                return false;
            };
            // `parse` lets through only a hotkey this system can use.
            const choice = keys.Choice.parse(name) orelse unreachable;
            if (!fresh(store, gpa, s.key, name)) return false;
            if (!prefs.setHotkey(store, choice)) return false;
            record(store, s.key, name);
        },
        .quicklinks => {
            if (value.len == 0) {
                forget(store, s.key);
                return false;
            }
            const json = prefs.quicklinksJson(gpa, value) orelse return false;
            defer gpa.free(json);
            if (!fresh(store, gpa, s.key, json)) return false;
            if (!prefs.setText(store, .quicklinks, json)) return false;
            record(store, s.key, json);
        },
    }
    return true;
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
    try testing.expect(c.clipboard.enabled == null and c.clipboard.paste_plain_text);
    try testing.expectEqual(@as(u32, 7), c.clipboard.retention_days);
    try testing.expectEqual(@as(usize, 2), c.clipboard.exclude_apps.len);
    try testing.expectEqualStrings("", c.sync.url);
}

test "the whole example" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    const c = try parse(arena.allocator(),
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
    , &p);
    try testing.expectEqual(@as(usize, 0), p.ignored.items.len);
    try testing.expectEqualStrings("ctrl_space", c.hotkey.?);
    try testing.expectEqual(false, c.suggestions.?);
    try testing.expectEqual(true, c.open_searches_in_browser.?);
    try testing.expectEqual(false, c.show_in_menu_bar.?);
    try testing.expectEqual(@as(u32, 0), c.pop_to_root_seconds);
    try testing.expectEqualStrings("/Applications/Nix Apps", c.apps.extra_dirs[0]);
    try testing.expectEqual(@as(usize, 2), c.script_commands.dirs.len);
    try testing.expectEqual(@as(usize, 2), c.quicklinks.len);
    try testing.expectEqualStrings("ddg", c.quicklinks[0].keyword);
    try testing.expectEqualStrings("", c.quicklinks[1].keyword);
    try testing.expect(!c.clipboard.enabled.? and !c.clipboard.paste_plain_text);
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
    try testing.expectError(
        error.Invalid,
        parse(arena.allocator(), "suggestions = true\nhotkey = \n", &p),
    );
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
    p = .{};
    const c = try parse(arena.allocator(), "colour = 1\nsuggestions = false\n", &p);
    try testing.expectEqual(false, c.suggestions.?);
    try testing.expectEqual(@as(usize, 1), p.ignored.items.len);
    try testing.expectEqualStrings("unknown key colour", p.ignored.items[0]);
}

test "an unknown key in a table is named with its table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    _ = try parse(arena.allocator(), "[clipboard]\nretention = 3\n[[quicklinks]]\n" ++
        "name = \"a\"\nurl = \"https://a/{argument}\"\nicon = \"x\"\n", &p);
    try testing.expectEqual(@as(usize, 2), p.ignored.items.len);
    // In the order of `Config`'s fields.
    try testing.expectEqualStrings("unknown key quicklinks.icon", p.ignored.items[0]);
    try testing.expectEqualStrings("unknown key clipboard.retention", p.ignored.items[1]);
}

test "a hotkey this system cannot use is ignored, the rest read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    const c = try parse(arena.allocator(), "hotkey = \"hyper_banana\"\nsuggestions = false\n", &p);
    try testing.expect(c.hotkey == null);
    try testing.expectEqual(false, c.suggestions.?);
    try testing.expectEqual(@as(usize, 1), p.ignored.items.len);
    try testing.expect(std.mem.indexOf(u8, p.ignored.items[0], "hyper_banana") != null);
}

test "quicklinks as an inline array read the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try parseOk(
        arena.allocator(),
        "quicklinks = [{ name = \"A\", url = \"http://a/{argument}\", keyword = \"a\" }]\n",
    );
    try testing.expectEqual(@as(usize, 1), c.quicklinks.len);
    try testing.expectEqualStrings("a", c.quicklinks[0].keyword);
}

fn kvGet(store: nanoui.kv.Store, key: []const u8) !?[]u8 {
    return store.get(testing.allocator, key);
}

fn expectKv(store: nanoui.kv.Store, key: []const u8, want: ?[]const u8) !void {
    const v = try kvGet(store, key);
    defer if (v) |x| testing.allocator.free(x);
    if (want) |w| try testing.expectEqualStrings(
        w,
        v orelse return error.TestExpectedEqual,
    ) else try testing.expect(v == null);
}

const suggest_key = prefs.Key.suggest.name();
const searches_out_key = prefs.Key.searches_out.name();
const menu_bar_key = prefs.Key.menu_bar.name();
const clipboard_key = prefs.Key.clipboard.name();
const sync_at_key = prefs.Key.sync_at.name();
const seen_key = prefs.Key.config_seen.name();
const applied_prefix = prefs.applied_prefix;

test "the file seeds once, then the app's own change wins" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    const file: Config = .{
        .hotkey = "ctrl_space",
        .suggestions = false,
        .open_searches_in_browser = true,
        .show_in_menu_bar = false,
    };

    seed(store, testing.allocator, file, 1000);
    try testing.expect(prefs.hotkey(store, testing.allocator).eql(.ctrl_space));
    try expectKv(store, suggest_key, "0");
    try expectKv(store, searches_out_key, "1");
    try expectKv(store, menu_bar_key, "0");
    try expectKv(store, sync_at_key, "1000");

    // The person changes things in the app.
    try testing.expect(prefs.setHotkey(store, .opt_space));
    try store.set(suggest_key, "1");
    try store.set(menu_bar_key, "1");
    try store.set(sync_at_key, "1500");

    seed(store, testing.allocator, file, 2000);
    try testing.expect(prefs.hotkey(store, testing.allocator).eql(.opt_space));
    try expectKv(store, suggest_key, "1");
    try expectKv(store, menu_bar_key, "1");
    try expectKv(store, sync_at_key, "1500");

    var edited = file;
    edited.suggestions = true;
    edited.hotkey = "cmd_space";
    seed(store, testing.allocator, edited, 3000);
    try testing.expect(prefs.hotkey(store, testing.allocator).eql(.cmd_space));
    try expectKv(store, suggest_key, "1");
    try expectKv(store, sync_at_key, "3000");
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
    const a = testing.allocator;
    try testing.expect(prefs.flagOr(store, a, .clipboard, true));
    try testing.expect(!prefs.flagOr(store, a, .clipboard, false));
    seed(store, a, .{ .clipboard = .{ .enabled = false } }, 7);
    try expectKv(store, clipboard_key, "0");
    try testing.expect(!prefs.flagOr(store, a, .clipboard, true));
    try expectKv(store, sync_at_key, null);
    // Turned on in the app; the same file leaves it on.
    try store.set(clipboard_key, "1");
    seed(store, a, .{ .clipboard = .{ .enabled = false } }, 8);
    try testing.expect(prefs.flagOr(store, a, .clipboard, false));
    seed(store, a, .{ .clipboard = .{ .enabled = true } }, 9);
    try expectKv(store, clipboard_key, "1");
    seed(store, a, .{ .clipboard = .{ .enabled = false } }, 10);
    try expectKv(store, clipboard_key, "0");
}

test "a file that leaves clipboard history out never turns it back on" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    // Off in the app, then a first config file with no [clipboard] table.
    try store.set(clipboard_key, "0");
    seed(store, testing.allocator, .{}, 1);
    try expectKv(store, clipboard_key, "0");
    try expectKv(store, applied_prefix ++ "clipboard.enabled", null);
    // A file whose [clipboard] table has no `enabled`.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const keyless = try parseOk(arena.allocator(), "[clipboard]\nmax_entries = 5\n");
    seed(store, testing.allocator, keyless, 2);
    try expectKv(store, clipboard_key, "0");
    // `enabled = false`, then the line removed: still off, the record forgotten.
    try store.set(clipboard_key, "1");
    seed(store, testing.allocator, .{ .clipboard = .{ .enabled = false } }, 3);
    try expectKv(store, clipboard_key, "0");
    seed(store, testing.allocator, .{}, 4);
    try expectKv(store, clipboard_key, "0");
    try expectKv(store, applied_prefix ++ "clipboard.enabled", null);
}

test "a value that cannot be written is not recorded as applied, and applies next start" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    m.gpa = failing.allocator();
    seed(store, testing.allocator, .{ .suggestions = false, .hotkey = "ctrl_space" }, 1);
    m.gpa = testing.allocator;
    try expectKv(store, suggest_key, null);
    try expectKv(store, applied_prefix ++ "suggestions", null);
    try expectKv(store, applied_prefix ++ "hotkey", null);
    seed(store, testing.allocator, .{ .suggestions = false, .hotkey = "ctrl_space" }, 2);
    try expectKv(store, suggest_key, "0");
    try expectKv(store, applied_prefix ++ "suggestions", "0");
    try testing.expect(prefs.hotkey(store, testing.allocator).eql(.ctrl_space));
}

test "a headless or unusable load seeds nothing and records nothing" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    apply(store, testing.allocator, .unusable, 1);
    apply(store, testing.allocator, .defaults, 1);
    try testing.expect(!store.has(seen_key) and !store.has(suggest_key));
    try testing.expect(!store.has(clipboard_key));
    const unusable = (Loaded{ .unusable = {} }).clipboardConfig();
    try testing.expectEqual(@as(u32, 0), unusable.retention_days);
    try testing.expectEqual(@as(u32, 0), unusable.max_entries);
    const defaults = (Loaded{ .defaults = {} }).clipboardConfig();
    try testing.expectEqual(@as(u32, 7), defaults.retention_days);
    apply(store, testing.allocator, .{ .file = .{ .suggestions = false } }, 1);
    try testing.expect(store.has(seen_key));
    try expectKv(store, suggest_key, "0");
}

test "a hotkey this system cannot use is not recorded" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    const store = m.store();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    const c = try parse(arena.allocator(), "hotkey = \"hyper_banana\"\n", &p);
    seed(store, testing.allocator, c, 5);
    try testing.expect(!prefs.has(store, .hotkey));
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
    const ddg: []const Quicklink = &.{
        .{ .name = "DDG", .url = "https://duckduckgo.com/?q={argument}", .keyword = "ddg" },
    };
    seed(store, testing.allocator, .{ .quicklinks = ddg }, 100);
    try testing.expectEqualStrings("ddg", prefs.quicklinks(a, store)[0].keyword);
    try expectKv(store, sync_at_key, "100");

    // Sync brought another list; the same file leaves it, and the time, alone.
    const synced: []const Quicklink = &.{
        .{ .name = "Kagi", .url = "https://kagi.com/search?q={argument}" },
    };
    prefs.setQuicklinks(store, testing.allocator, synced);
    try store.set(sync_at_key, "150");
    seed(store, testing.allocator, .{ .quicklinks = ddg }, 200);
    try testing.expectEqualStrings("Kagi", prefs.quicklinks(a, store)[0].name);
    try expectKv(store, sync_at_key, "150");

    const edited: []const Quicklink = &.{
        .{ .name = "Bing", .url = "https://bing.com/search?q={argument}" },
    };
    seed(store, testing.allocator, .{ .quicklinks = edited }, 300);
    try testing.expectEqualStrings("Bing", prefs.quicklinks(a, store)[0].name);
    try expectKv(store, sync_at_key, "300");

    // No list in the file touches nothing; an empty saved list is the defaults.
    seed(store, testing.allocator, .{}, 400);
    try testing.expectEqual(@as(usize, 1), prefs.quicklinks(a, store).len);
    prefs.setQuicklinks(store, testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), prefs.quicklinks(a, store).len);
}

test "a quicklink that is not http or https is dropped, the rest stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var p: Problem = .{};
    const c = try parse(arena.allocator(),
        \\[[quicklinks]]
        \\name = "Local"
        \\url = "file:///etc/passwd?{argument}"
        \\[[quicklinks]]
        \\name = "Ok"
        \\url = "https://a.example/?q={argument}"
        \\
    , &p);
    try testing.expectEqual(@as(usize, 1), c.quicklinks.len);
    try testing.expectEqualStrings("Ok", c.quicklinks[0].name);
    try testing.expectEqual(@as(usize, 1), p.ignored.items.len);
}

test "a missing file is the defaults" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none = [_][]const u8{"/nonexistent/nanolight/config.toml"};
    try testing.expect(loadFrom(arena.allocator(), testing.io, &none, m.store()) == .defaults);
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
    const c = loadFrom(a, testing.io, &paths, m.store()).file;
    try testing.expectEqual(false, c.suggestions.?);
}

test "a relative script command dir is relative to the config file" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "a.toml", .data = "[script_commands]\ndirs = [\"scripts\", \"/abs\"]\n" },
    );
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const paths = [_][]const u8{try std.fs.path.join(a, &.{ dir, "a.toml" })};
    const c = loadFrom(a, testing.io, &paths, m.store()).file;
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ dir, "scripts" }),
        c.script_commands.dirs[0],
    );
    try testing.expectEqualStrings("/abs", c.script_commands.dirs[1]);
}

test "a relative config path still gives absolute script command dirs" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "a.toml", .data = "[script_commands]\ndirs = [\"scripts\"]\n" },
    );
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, ".", a);
    const relative = try std.fs.path.relativeAlloc(a, cwd, null, cwd, dir);
    const paths = [_][]const u8{try std.fs.path.join(a, &.{ relative, "a.toml" })};
    try testing.expect(!std.fs.path.isAbsolute(paths[0]));
    const c = loadFrom(a, testing.io, &paths, m.store()).file;
    try testing.expectEqualStrings(
        try std.fs.path.join(a, &.{ dir, "scripts" }),
        c.script_commands.dirs[0],
    );
}

test "no file after one was applied is a failed load, not the defaults" {
    var m: nanoui.kv.Memory = .{ .gpa = testing.allocator };
    defer m.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const none = [_][]const u8{"/nonexistent/nanolight/config.toml"};
    try testing.expect(loadFrom(arena.allocator(), testing.io, &none, m.store()) == .defaults);
    seed(m.store(), testing.allocator, .{}, 1);
    try testing.expect(loadFrom(arena.allocator(), testing.io, &none, m.store()) == .unusable);
}
