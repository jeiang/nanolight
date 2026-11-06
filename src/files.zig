//! The files and folders file search lists (spotlight.zig finds them by
//! name), and a typed path's: the path itself, then its folder's entries
//! that start with what follows the last `/`.
const std = @import("std");
const paths = @import("paths.zig");
const search = @import("search.zig");

pub const max_rows = 5;
pub const max_path = 4096;

pub const Entry = struct {
    bytes: [max_path]u8 = undefined,
    len: usize = 0,
    folder: bool = false,
    match: search.Match = .{ .score = 0 },
    png: []u8 = &.{},

    pub fn path(e: *const Entry) []const u8 {
        return e.bytes[0..e.len];
    }

    pub fn name(e: *const Entry) []const u8 {
        const p = e.path();
        return if (std.mem.eql(u8, p, "/")) p else std.fs.path.basename(p);
    }
};

pub const List = struct {
    /// Owns every entry icon; a list must be moved, never copied.
    allocator: std.mem.Allocator = std.heap.page_allocator,
    entries: [max_rows]Entry = undefined,
    n: usize = 0,
    exact: bool = false,

    pub fn deinit(l: *List) void {
        for (l.entries[0..l.n]) |e| l.allocator.free(e.png);
        l.n = 0;
        l.exact = false;
    }

    /// Transfer ownership, leaving the source safe to destroy on the main thread.
    pub fn replace(l: *List, source: *List) void {
        std.debug.assert(l != source);
        l.deinit();
        l.* = source.*;
        source.n = 0;
        source.exact = false;
    }

    pub fn add(l: *List, path: []const u8, folder: bool, m: search.Match) void {
        if (path.len == 0 or path.len >= max_path) return;
        for (l.entries[0..l.n]) |*e| if (std.mem.eql(u8, e.path(), path)) return;
        var at: usize = 0;
        while (at < l.n and l.entries[at].match.score >= m.score) : (at += 1) {}
        if (at == max_rows) return;
        if (l.n == max_rows) l.allocator.free(l.entries[max_rows - 1].png);
        var i = @min(l.n, max_rows - 1);
        while (i > at) : (i -= 1) l.entries[i] = l.entries[i - 1];
        l.entries[at] = .{ .len = path.len, .folder = folder, .match = m };
        @memcpy(l.entries[at].bytes[0..path.len], path);
        l.n = @min(l.n + 1, max_rows);
    }

    /// Keep the last answer's matching rows while a new answer is on its way.
    pub fn filter(l: *List, query: []const u8) void {
        var expanded: [max_path]u8 = undefined;
        const typed_path = paths.isPath(query);
        const path = if (typed_path) paths.expand(&expanded, query) else null;
        const clean = if (path) |p| (if (p.len > 1) std.mem.trimEnd(u8, p, "/") else p) else "";
        const old_n = l.n;
        var n: usize = 0;
        l.exact = false;
        for (0..old_n) |i| {
            const e = &l.entries[i];
            var keep = false;
            defer if (!keep) l.allocator.free(e.png);
            const m = if (path) |p| blk: {
                if (std.mem.eql(u8, e.path(), clean)) {
                    l.exact = true;
                    break :blk search.Match{ .score = search.exact_path };
                }
                const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse continue;
                const dir = if (slash == 0) "/" else p[0..slash];
                if (!std.mem.eql(u8, std.fs.path.dirname(e.path()) orelse "/", dir)) continue;
                const prefix = p[slash + 1 ..];
                if (!std.ascii.startsWithIgnoreCase(e.name(), prefix)) continue;
                if (e.name()[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue;
                break :blk search.score(prefix, e.name()) orelse search.Match{ .score = 1 };
            } else if (typed_path) continue else search.score(query, e.name()) orelse continue;
            keep = true;
            l.entries[n] = e.*;
            l.entries[n].match = m;
            n += 1;
        }
        l.n = n;
        std.sort.insertion(Entry, l.entries[0..n], {}, struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                return a.match.score > b.match.score;
            }
        }.before);
    }

    /// Finder icons are prepared off the UI thread along with the answer
    /// (file search is the Mac's alone, platform.zig's `files`).
    pub fn icons(l: *List) void {
        for (l.entries[0..l.n]) |*e| {
            const png = @import("icon_mac.zig").png(l.allocator, e.path()) orelse continue;
            l.allocator.free(e.png);
            e.png = png;
        }
    }
};

/// Existing paths lead; partial paths list a handful of matching siblings.
pub fn complete(io: std.Io, query: []const u8, out: *List) void {
    out.deinit();
    if (!paths.isPath(query)) return;
    var expanded: [max_path]u8 = undefined;
    const path = paths.expand(&expanded, query) orelse return;
    const clean = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    if (std.Io.Dir.cwd().statFile(io, clean, .{})) |st| {
        out.add(clean, st.kind == .directory, .{ .score = search.exact_path });
        out.exact = true;
        if (!std.mem.endsWith(u8, path, "/")) return;
    } else |_| {}
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    const dir_path = if (slash == 0) "/" else path[0..slash];
    const prefix = path[slash + 1 ..];
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    var buf: [max_path]u8 = undefined;
    // Bound work even in very large directories. No recursive crawl.
    var seen: usize = 0;
    while (seen < 2048) : (seen += 1) {
        const e = (it.next(io) catch null) orelse break;
        if (e.name.len == 0 or (e.name[0] == '.' and (prefix.len == 0 or
            prefix[0] != '.'))) continue;
        if (!std.ascii.startsWithIgnoreCase(e.name, prefix)) continue;
        const full = std.fmt.bufPrint(
            &buf,
            "{s}{s}{s}",
            .{ dir_path, if (slash == 0) "" else "/", e.name },
        ) catch continue;
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
        out.add(full, st.kind == .directory, search.score(prefix, e.name) orelse .{ .score = 1 });
        if (out.n == max_rows) break;
    }
}
