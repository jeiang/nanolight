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
//! rows among the apps: `script:<file>`, their folder the package's name.
//! script_run.zig runs one and shows what it prints.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const Index = @import("apps.zig").Index;
const model = @import("raycast_model.zig");
const windows = builtin.os.tag == .windows;

pub const prefix = "script:";
/// The row that opens the scripts' folder.
pub const folder_path = "script-folder:";

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

    /// A known header key's value.
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

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `<data dir>/script-commands`, made if missing. Caller frees it.
pub fn dir(gpa: std.mem.Allocator) ![]u8 {
    const data = try @import("prefs.zig").dataDir(gpa);
    defer gpa.free(data);
    const d = try std.fs.path.join(gpa, &.{ data, "script-commands" });
    // best effort: a folder that can't be made just lists no scripts.
    std.Io.Dir.cwd().createDirPath(io(), d) catch {};
    return d;
}

/// Adds each script command in the folder and in `extra` (a folder down
/// too) to `ix`, and the row that opens the folder.
pub fn scan(ix: *Index, gpa: std.mem.Allocator, extra: []const []const u8) void {
    // best effort: only memory can fail here, and the scripts still list.
    ix.addIn("Script Commands Folder", folder_path, "Raycast") catch {};
    if (dir(gpa)) |root| {
        defer gpa.free(root);
        scanDir(ix, gpa, root);
    } else |_| {}
    for (extra) |d| scanDir(ix, gpa, d);
}

/// The script commands in `root` and in the folders in it, no deeper: one
/// loop for the folder, one inside it for a folder down.
fn scanDir(ix: *Index, gpa: std.mem.Allocator, root: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var top = std.Io.Dir.cwd().openDir(io(), root, .{ .iterate = true }) catch return;
    defer top.close(io());
    var it = top.iterate();
    while (it.next(io()) catch null) |e| {
        if (hidden(e.name)) continue;
        if (e.kind != .directory) {
            addScript(ix, a, .{ .dir = top, .folder = root, .name = e.name });
            continue;
        }
        const folder = std.fs.path.join(a, &.{ root, e.name }) catch continue;
        var sub = top.openDir(io(), e.name, .{ .iterate = true }) catch continue;
        defer sub.close(io());
        var sub_it = sub.iterate();
        while (sub_it.next(io()) catch null) |f| {
            if (hidden(f.name) or f.kind == .directory) continue;
            addScript(ix, a, .{ .dir = sub, .folder = folder, .name = f.name });
        }
    }
}

fn hidden(name: []const u8) bool {
    return name.len == 0 or name[0] == '.';
}

/// A file in a folder being scanned.
const Entry = struct {
    /// The folder, open.
    dir: std.Io.Dir,
    /// The folder's path.
    folder: []const u8,
    name: []const u8,
};

/// Lists `entry` if its header says it is a script command.
fn addScript(ix: *Index, a: std.mem.Allocator, entry: Entry) void {
    // The header is in the first lines: the file's first 8 KB.
    var buf: [8192]u8 = undefined;
    const head = entry.dir.readFile(io(), entry.name, &buf) catch return;
    const m = parse(a, head) orelse return;
    const full = std.fs.path.join(a, &.{ entry.folder, entry.name }) catch return;
    const row = std.fmt.allocPrint(a, "{s}{s}", .{ prefix, full }) catch return;
    const package = if (m.package.len > 0) m.package else "Script Command";
    // best effort: out of memory leaves the script unlisted
    ix.addIn(m.title, row, package) catch {};
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
    // A type not known is text.
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
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    scanDir(&ix, t.allocator, path);
    try t.expectEqual(@as(usize, 2), ix.apps.items.len);
    try t.expect(ix.find("Say Hello") != null and ix.find("Two Down") == null);
    const near = ix.apps.items[ix.find("One Down").?];
    try t.expect(std.mem.startsWith(u8, near.path, prefix));
    try t.expect(std.mem.endsWith(u8, near.path, "near.sh"));
}
