//! Raycast Script Commands (github.com/raycast/script-commands, MIT), run
//! by Nanolight itself: no JavaScript. A script command is any script
//! (bash, Python, Ruby, PowerShell…) whose comments say what it is:
//!
//!     # @raycast.schemaVersion 1
//!     # @raycast.title Generate UUID
//!     # @raycast.mode silent
//!     # @raycast.packageName Developer Utilities
//!     # @raycast.icon 💻
//!     # @raycast.argument1 { "type": "text", "placeholder": "Name" }
//!
//! Scripts dropped in `<data dir>/script-commands` (a folder down too) are
//! rows among the apps (`List`), their folder the package's name.
//! script_run.zig runs one and shows what it prints.
const std = @import("std");
const nanoui = @import("nanoui");
const app_scan = @import("app_scan.zig");
const model = @import("raycast_model.zig");
const paths = @import("paths.zig");
const cachedIcon = @import("apps.zig").cachedIcon;
const windows = @import("os.zig").windows;
const test_apps = @import("test_apps.zig");

pub const Mode = enum { silent, compact, full_output, inline_ };

pub const Argument = struct {
    /// "text", "password" or "dropdown" (`kind`).
    type: []const u8 = "text",
    placeholder: []const u8 = "",
    optional: bool = false,
    percentEncoded: bool = false,
    data: []const struct { title: []const u8 = "", value: []const u8 = "" } = &.{},

    /// Its type; one not known is text.
    pub fn kind(a: Argument) model.Field.Kind {
        return std.meta.stringToEnum(model.Field.Kind, a.type) orelse .text;
    }
};

pub const Meta = struct {
    title: []const u8 = "",
    mode: Mode = .full_output,
    package: []const u8 = "",
    icon: []const u8 = "",
    description: []const u8 = "",
    cwd: []const u8 = "",
    confirm: bool = false,
    args: [model.max_args]?Argument = @splat(null),
    schema: bool = false,

    pub fn argCount(m: *const Meta) usize {
        var n: usize = 0;
        for (m.args) |a| if (a != null) {
            n += 1;
        };
        return n;
    }

    fn set(m: *Meta, key: HeaderKey, value: []const u8) void {
        switch (key) {
            .schemaVersion => m.schema = true,
            .title => m.title = value,
            .packageName => m.package = value,
            .icon => m.icon = value,
            .description => m.description = value,
            .currentDirectoryPath => m.cwd = value,
            .needsConfirmation => m.confirm = std.mem.eql(u8, value, "true"),
            .mode => m.mode = parseMode(value),
        }
    }
};

/// The `@raycast.` keys read, besides `argument1` to `argument3`.
const HeaderKey = enum {
    schemaVersion,
    title,
    packageName,
    icon,
    description,
    currentDirectoryPath,
    needsConfirmation,
    mode,
};
const key_marker = "@raycast.";
const comment_starts = [_][]const u8{ "#", "//", "--", ";" };
/// Header lines read at most: the header sits at the top.
const header_lines_max = 200;

/// The `@raycast.` keys in a script's comments (`#`, `//`, `--`), values
/// pointing into `bytes`; arguments parsed into `arena`. Null when it isn't
/// a script command (no schemaVersion or no title).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ?Meta {
    var m: Meta = .{};
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var seen: usize = 0;
    while (lines.next()) |raw| {
        seen += 1;
        if (seen > header_lines_max) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        const body = for (comment_starts) |c| {
            if (std.mem.startsWith(u8, line, c)) {
                break std.mem.trimStart(u8, line[c.len..], " \t#/-;");
            }
        } else continue;
        const key_at = std.mem.indexOf(u8, body, key_marker) orelse continue;
        const kv = body[key_at + key_marker.len ..];
        const sp = std.mem.indexOfAny(u8, kv, " \t") orelse kv.len;
        const key = kv[0..sp];
        const value = std.mem.trim(u8, kv[sp..], " \t");
        if (std.meta.stringToEnum(HeaderKey, key)) |known| {
            m.set(known, value);
        } else if (argumentSlot(key)) |slot| {
            const options: std.json.ParseOptions = .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            };
            m.args[slot] = std.json.parseFromSliceLeaky(Argument, arena, value, options) catch null;
        }
    }
    if (!m.schema or m.title.len == 0) return null;
    return m;
}

/// `argumentN`'s slot in `Meta.args`: N from 1 to `max_args`.
fn argumentSlot(key: []const u8) ?usize {
    // One digit names every slot.
    comptime std.debug.assert(model.max_args <= 9);
    const argument = "argument";
    if (!std.mem.startsWith(u8, key, argument)) return null;
    const digits = key[argument.len..];
    if (digits.len != 1) return null;
    const n = std.fmt.charToDigit(digits[0], 10) catch return null;
    if (n < 1) return null;
    if (n > model.max_args) return null;
    return n - 1;
}

fn parseMode(value: []const u8) Mode {
    if (std.mem.eql(u8, value, "silent")) return .silent;
    if (std.mem.eql(u8, value, "compact")) return .compact;
    if (std.mem.eql(u8, value, "inline")) return .inline_;
    return .full_output;
}

/// `<data dir>/script-commands`, made if missing. Caller frees it.
pub fn dir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    return paths.subdir(gpa, io, "script-commands", .default_dir);
}

/// A script command found, or the row that opens their folder: listed among
/// the apps (launchers.zig), its own row kind.
pub const Script = struct {
    title: []const u8,
    /// Its package's name, as its row shows it; "Raycast" for the folder's row.
    package: []const u8,
    /// Its file; null for the row that opens the folder.
    file: ?[]const u8,
    /// What its launches are counted under (launch_counts.zig), as they
    /// always have been: `script:<file>`, or `script-folder:`.
    key: []const u8,
    icon: app_scan.Icon = .unloaded,
};

const key_prefix = "script:";
const folder_key = "script-folder:";

/// The script commands found, sorted by title as the apps are. A title an
/// app or an earlier script has is not listed again.
pub const List = struct {
    gpa: std.mem.Allocator,
    /// Owns each script's strings.
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Script) = .empty,
    /// Scripts found but left out: memory ran out.
    lost: u32 = 0,
    /// The Io and environment the apps were found with, for the icons.
    io: std.Io,
    env: *const std.process.Environ.Map,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) List {
        return .{ .gpa = gpa, .arena = .init(gpa), .io = io, .env = env };
    }

    pub fn deinit(l: *List) void {
        for (l.items.items) |s| switch (s.icon) {
            .png => |png| l.gpa.free(png),
            .unloaded, .none => {},
        };
        l.items.deinit(l.gpa);
        l.arena.deinit();
    }

    /// Lists a script (or, with no `file`, the folder's row) unless an app
    /// in `apps` or a script already listed has its title; one memory
    /// leaves out is counted in `lost`.
    pub fn add(
        l: *List,
        apps: []const app_scan.App,
        title: []const u8,
        package: []const u8,
        file: ?[]const u8,
    ) void {
        if (app_scan.findName(apps, title) != null or l.find(title) != null) return;
        l.put(title, package, file) catch {
            l.lost += 1;
        };
    }

    fn put(l: *List, title: []const u8, package: []const u8, file: ?[]const u8) !void {
        const a = l.arena.allocator();
        const own: ?[]const u8 = if (file) |f| try a.dupe(u8, f) else null;
        const key = if (own) |f|
            try std.fmt.allocPrint(a, key_prefix ++ "{s}", .{f})
        else
            folder_key;
        try l.items.append(l.gpa, .{
            .title = try a.dupe(u8, title),
            .package = try a.dupe(u8, package),
            .file = own,
            .key = key,
        });
    }

    /// After the scans: sorted by title, and those memory left out logged.
    pub fn finish(l: *List) void {
        if (l.lost > 0) std.log.warn(
            "nanolight: {d} script commands not listed: out of memory",
            .{l.lost},
        );
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: Script, b: Script) bool {
                return std.ascii.lessThanIgnoreCase(a.title, b.title);
            }
        };
        std.sort.pdq(Script, l.items.items, Ctx{}, Ctx.lessThan);
    }

    pub fn find(l: *const List, title: []const u8) ?u32 {
        for (l.items.items, 0..) |s, i| {
            if (std.ascii.eqlIgnoreCase(s.title, title)) return @intCast(i);
        }
        return null;
    }

    /// Whether `other` lists the same scripts, from the same files.
    pub fn same(l: *const List, other: *const List) bool {
        if (l.items.items.len != other.items.items.len) return false;
        for (l.items.items, other.items.items) |a, b| {
            if (!std.mem.eql(u8, a.key, b.key) or !std.mem.eql(u8, a.title, b.title)) return false;
        }
        return true;
    }

    /// Script `i`'s icon, made the first time it is asked for: the system's
    /// for its key, which names no file (the Mac's blank document).
    pub fn icon(l: *List, i: u32) ?[]const u8 {
        const s = &l.items.items[i];
        return cachedIcon(&s.icon, l.gpa, l.io, l.env, s.key);
    }
};

/// Lists the row that opens the folder, then each script command in the
/// folder and in `extra` (a folder down too), past the titles `apps` has.
pub fn scan(l: *List, apps: []const app_scan.App, extra: []const []const u8) void {
    const io = l.io;
    l.add(apps, "Script Commands Folder", "Raycast", null);
    if (dir(l.gpa, io)) |root| {
        defer l.gpa.free(root);
        scanDir(l, io, apps, root);
    } else |err| std.log.warn("nanolight: no script commands folder: {t}", .{err});
    for (extra) |d| scanDir(l, io, apps, d);
}

/// The script commands in `root` and in the folders in it, no deeper.
fn scanDir(l: *List, io: std.Io, apps: []const app_scan.App, root: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(l.gpa);
    defer arena.deinit();
    const Scan = struct {
        list: *List,
        io: std.Io,
        apps: []const app_scan.App,
        arena: std.mem.Allocator,

        fn visit(s: @This(), f: app_scan.Found) app_scan.Step {
            const name = f.entry.name;
            if (name.len == 0 or name[0] == '.') return .next;
            if (f.entry.kind == .directory) return .descend;
            addScript(s, f);
            return .next;
        }

        /// Lists `f` if its header says it is a script command.
        fn addScript(s: @This(), f: app_scan.Found) void {
            // The header is in the first lines: the file's first 8 KB.
            var buf: [8192]u8 = undefined;
            const head = f.dir.readFile(s.io, f.entry.name, &buf) catch |err| {
                std.log.warn("nanolight: {s} could not be read: {t}", .{ f.full, err });
                return;
            };
            const m = parse(s.arena, head) orelse return;
            const package = if (m.package.len > 0) m.package else "Script Command";
            s.list.add(s.apps, m.title, package, f.full);
        }
    };
    const ctx: Scan = .{ .list = l, .io = io, .apps = apps, .arena = arena.allocator() };
    app_scan.walk(io, root, 1, ctx, Scan.visit);
}

/// How to run `file`: its shebang's interpreter (`#!/usr/bin/env python3`),
/// else by its extension on Windows, else `sh`. Written into `out`.
pub fn command(bytes: []const u8, file: []const u8, out: *[8][]const u8) [][]const u8 {
    var n: usize = 0;
    const ext = std.fs.path.extension(file);
    if (windows) {
        const by_ext: ?[]const []const u8 = if (std.ascii.eqlIgnoreCase(ext, ".ps1"))
            &.{ "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" }
        else if (std.ascii.eqlIgnoreCase(ext, ".bat") or std.ascii.eqlIgnoreCase(ext, ".cmd"))
            &.{ "cmd", "/c" }
        else if (std.ascii.eqlIgnoreCase(ext, ".py"))
            &.{"python"}
        else if (std.ascii.eqlIgnoreCase(ext, ".js"))
            &.{"node"}
        else
            null;
        if (by_ext) |parts| {
            for (parts) |p| {
                out[n] = p;
                n += 1;
            }
            out[n] = file;
            return out[0 .. n + 1];
        }
    }
    if (std.mem.startsWith(u8, bytes, "#!")) {
        const nl = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
        var words = std.mem.tokenizeAny(u8, std.mem.trim(u8, bytes[2..nl], " \t\r"), " \t");
        while (words.next()) |w| if (n < out.len - 1) {
            // On Windows "/usr/bin/env bash" is "bash" from the PATH (Git's).
            out[n] = if (windows) std.fs.path.basename(w) else w;
            n += 1;
        };
        if (n > 1 and std.mem.eql(u8, std.fs.path.basename(out[0]), "env")) {
            // env's own name goes on Windows; elsewhere it finds the rest.
            if (windows) {
                std.mem.copyForwards([]const u8, out[0 .. n - 1], out[1..n]);
                n -= 1;
            }
        }
    }
    if (n == 0) {
        out[0] = if (windows) "sh" else "/bin/sh";
        n = 1;
    }
    out[n] = file;
    return out[0 .. n + 1];
}

test "a script command's header" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\#!/usr/bin/env bash
        \\# Required parameters:
        \\# @raycast.schemaVersion 1
        \\# @raycast.title Search Wikipedia
        \\# @raycast.mode silent
        \\# @raycast.packageName Web Searches
        \\# @raycast.icon 📖
        \\# @raycast.argument1 { "type": "text", "placeholder": "Query", "percentEncoded": true }
        \\# @raycast.argument2 { "type": "dropdown", "placeholder": "Lang", "data": [{"title":
    ++
        \\ "English", "value": "en"}] }
        \\open "https://$2.wikipedia.org/w/index.php?search=$1"
    ;
    const m = parse(arena.allocator(), src).?;
    try std.testing.expectEqualStrings("Search Wikipedia", m.title);
    try std.testing.expectEqual(Mode.silent, m.mode);
    try std.testing.expectEqualStrings("Web Searches", m.package);
    try std.testing.expectEqual(@as(usize, 2), m.argCount());
    try std.testing.expect(m.args[0].?.percentEncoded);
    try std.testing.expectEqualStrings("en", m.args[1].?.data[0].value);
    try std.testing.expectEqual(model.Field.Kind.text, m.args[0].?.kind());
    try std.testing.expectEqual(model.Field.Kind.dropdown, m.args[1].?.kind());
    const secret: Argument = .{ .type = "password" };
    try std.testing.expectEqual(model.Field.Kind.password, secret.kind());
    const other: Argument = .{ .type = "number" };
    try std.testing.expectEqual(model.Field.Kind.text, other.kind());
    try std.testing.expect(parse(arena.allocator(), "#!/bin/sh\necho hi\n") == null);
    // AppleScript's and JavaScript's comments too.
    try std.testing.expectEqualStrings(
        "A",
        parse(arena.allocator(), "-- @raycast.schemaVersion 1\n-- @raycast.title A\n").?.title,
    );
    try std.testing.expectEqualStrings(
        "B",
        parse(arena.allocator(), "// @raycast.schemaVersion 1\n// @raycast.title B\n").?.title,
    );

    var out: [8][]const u8 = undefined;
    const argv = command(src, "/s/wiki.sh", &out);
    try std.testing.expectEqualStrings("/s/wiki.sh", argv[argv.len - 1]);
    if (!windows) try std.testing.expectEqualStrings("/usr/bin/env", argv[0]);
    try std.testing.expectEqualStrings(
        if (windows) "sh" else "/bin/sh",
        command("echo", "x", &out)[0],
    );
}

test "a folder named in config.toml is scanned for script commands, a folder down too" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(
        t.io,
        .{
            .sub_path = "hello.sh",
            .data = "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Say Hello\n# " ++
                "@raycast.mode silent\necho hi\n",
        },
    );
    try tmp.dir.writeFile(t.io, .{ .sub_path = "plain.sh", .data = "#!/bin/sh\necho no header\n" });
    const header = "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title ";
    try tmp.dir.createDirPath(t.io, "sub/old");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/near.sh", .data = header ++ "One Down\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "sub/old/far.sh", .data = header ++ "Two Down\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try @import("test_tmp.zig").path(&buf, &tmp);
    var l: List = .init(t.allocator, t.io, &test_apps.no_env);
    defer l.deinit();
    scanDir(&l, t.io, &.{}, path);
    try t.expectEqual(@as(usize, 2), l.items.items.len);
    try t.expect(l.find("Say Hello") != null and l.find("Two Down") == null);
    const near = l.items.items[l.find("One Down").?];
    try t.expect(std.mem.endsWith(u8, near.file.?, "near.sh"));
    // Counted as they always were, by their file.
    try t.expect(std.mem.startsWith(u8, near.key, "script:"));
    try t.expect(std.mem.endsWith(u8, near.key, near.file.?));
}

test "a script whose title an app or another script has is not listed again" {
    const t = std.testing;
    const apps = [_]app_scan.App{.{ .name = "Safari", .path = "/A/Safari.app", .folder = "A" }};
    var l: List = .init(t.allocator, t.io, &test_apps.no_env);
    defer l.deinit();
    l.add(&apps, "safari", "Mine", "/s/safari.sh");
    l.add(&apps, "Script Commands Folder", "Raycast", null);
    l.add(&apps, "Hello", "Mine", "/s/hello.sh");
    l.add(&apps, "hello", "Mine", "/s/hello2.sh");
    l.finish();
    try t.expectEqual(@as(usize, 2), l.items.items.len);
    try t.expectEqualStrings("Hello", l.items.items[0].title);
    try t.expectEqualStrings("script-folder:", l.items.items[1].key);
    try t.expect(l.items.items[1].file == null);
}
