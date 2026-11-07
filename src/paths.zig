//! Paths: as typed in the panel and shown in its rows (one starts with `/`
//! or `~`, and `~` is the home folder), and where Nanolight keeps its files.
const std = @import("std");
const nanoui = @import("nanoui");
const app_facts = @import("app_facts.zig");
const display = @import("display.zig");

pub fn isPath(q: []const u8) bool {
    return q.len > 0 and (q[0] == '/' or q[0] == '~');
}

/// The home folder, or "" when unknown. Read from the process environment:
/// the panel's rows draw paths with no environment at hand.
pub fn home() []const u8 {
    return if (std.c.getenv("HOME")) |p| std.mem.span(p) else "";
}

/// `path` with a leading `~` spelled out; null for `~user` or no home.
pub fn expand(buf: []u8, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~")) return path;
    if (path.len > 1 and path[1] != '/') return null;
    const h = home();
    if (h.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ h, path[1..] }) catch null;
}

/// The folder `path` is in, with `~` for the home folder.
pub fn parent(buf: []u8, path: []const u8) []const u8 {
    const p = std.fs.path.dirname(path) orelse "/";
    const h = home();
    if (h.len > 0 and within(p, h)) return std.fmt.bufPrint(buf, "~{s}", .{p[h.len..]}) catch p;
    return p;
}

/// Whether `path` is `root` or inside it.
pub fn within(path: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, path, root) or (std.mem.startsWith(u8, path, root) and
        (std.mem.endsWith(u8, root, "/") or (path.len > root.len and path[root.len] == '/')));
}

/// Whether one of `path`'s folders (or its name) is `component`, which may
/// itself span folders ("Library/Caches").
pub fn hasComponent(path: []const u8, component: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, component)) |i| {
        const end = i + component.len;
        if ((i == 0 or path[i - 1] == '/') and (end == path.len or path[end] == '/')) return true;
        from = i + 1;
    }
    return false;
}

// ----- where Nanolight keeps its files -----

/// Nanolight's data folder (config.toml, the clipboard, script commands, the rates).
/// Caller frees it.
pub fn dataDir(gpa: std.mem.Allocator) ![]u8 {
    return nanoui.path(gpa, .data, app_facts.app_name);
}

/// `<data dir>/<name>`, a folder, made with `perms` if missing. Caller frees it.
pub fn subdir(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    perms: std.Io.Dir.Permissions,
) ![]u8 {
    const data = try dataDir(gpa);
    defer gpa.free(data);
    const d = try std.fs.path.join(gpa, &.{ data, name });
    errdefer gpa.free(d);
    _ = try std.Io.Dir.cwd().createDirPathStatus(io, d, perms);
    return d;
}

/// `<data dir>/<name>`, a file, the data folder made if missing. Caller frees it.
pub fn dataFile(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const data = try dataDir(gpa);
    defer gpa.free(data);
    // best effort: without the folder the file's read fails, and its write says why.
    std.Io.Dir.cwd().createDirPath(io, data) catch {};
    return std.fs.path.join(gpa, &.{ data, name });
}

/// Where a config may live, first match wins: `NANOLIGHT_CONFIG`, the data dir, the XDG config dir
/// (home-manager's `xdg.configFile`), then `/etc/nanolight` (the NixOS and nix-darwin modules).
pub fn configCandidates(
    arena: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    data_dir: ?[]const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (env.get("NANOLIGHT_CONFIG")) |p| try out.append(arena, p);
    if (data_dir) |d| try out.append(arena, try std.fs.path.join(arena, &.{ d, "config.toml" }));
    if (try xdgConfigHome(arena, env)) |c|
        try out.append(arena, try std.fs.path.join(arena, &.{ c, "nanolight", "config.toml" }));
    try out.append(arena, "/etc/nanolight/config.toml");
    return out.items;
}

/// Linux's autostart entry in the XDG config dir, written into `buf`; null
/// without a home folder.
pub fn autostartEntry(buf: []u8) ?[]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const a = fba.allocator();
    const config = (xdgConfigHome(a, ProcessEnv{}) catch return null) orelse return null;
    return std.fs.path.join(a, &.{ config, "autostart", "nanolight.desktop" }) catch null;
}

/// The process environment, looked up like an `Environ.Map`.
const ProcessEnv = struct {
    fn get(_: ProcessEnv, name: [:0]const u8) ?[]const u8 {
        return display.env(name);
    }
};

/// `XDG_CONFIG_HOME`, else `$HOME/.config`; null without either. An empty
/// `XDG_CONFIG_HOME` counts as unset (the XDG spec). The result may be
/// `env`'s own string: use an arena.
fn xdgConfigHome(arena: std.mem.Allocator, env: anytype) std.mem.Allocator.Error!?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) return x;
    const h = env.get("HOME") orelse return null;
    return try std.fs.path.join(arena, &.{ h, ".config" });
}

const testing = std.testing;

test "config lookup order: env, data dir, XDG, /etc" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("NANOLIGHT_CONFIG", "/n/c.toml");
    try env.put("XDG_CONFIG_HOME", "/x");
    var got = try configCandidates(a, &env, "/d");
    try testing.expectEqual(@as(usize, 4), got.len);
    try testing.expectEqualStrings("/n/c.toml", got[0]);
    try testing.expectEqualStrings("/d/config.toml", got[1]);
    try testing.expectEqualStrings("/x/nanolight/config.toml", got[2]);
    try testing.expectEqualStrings("/etc/nanolight/config.toml", got[3]);
    var home_only: std.process.Environ.Map = .init(testing.allocator);
    defer home_only.deinit();
    try home_only.put("HOME", "/h");
    got = try configCandidates(a, &home_only, "/d");
    try testing.expectEqualStrings("/d/config.toml", got[0]);
    try testing.expectEqualStrings("/h/.config/nanolight/config.toml", got[1]);
}

test "an empty XDG_CONFIG_HOME counts as unset, for config and autostart alike" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", "");
    try testing.expect(try xdgConfigHome(a, &env) == null);
    try env.put("HOME", "/h");
    try testing.expectEqualStrings("/h/.config", (try xdgConfigHome(a, &env)).?);
    const got = try configCandidates(a, &env, null);
    try testing.expectEqualStrings("/h/.config/nanolight/config.toml", got[0]);
}
