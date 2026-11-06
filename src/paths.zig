//! Paths as typed in the panel and shown in its rows: one starts with `/`
//! or `~`, and `~` is the home folder.
const std = @import("std");

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
