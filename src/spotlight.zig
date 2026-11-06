//! File search by name through Spotlight's index (the Mac's alone,
//! platform.zig's `files`): `mdfind` asked in tiers, exact names first,
//! under one deadline, into one ranked list (files.zig). Only paths and
//! names are read.
const std = @import("std");
const files = @import("files.zig");
const paths = @import("paths.zig");
const search = @import("search.zig");
const List = files.List;
const max_path = files.max_path;
const max_rows = files.max_rows;

/// A query worth asking Spotlight: a name, not a path, no control bytes.
pub fn eligible(q: []const u8) bool {
    if (q.len < 2 or q.len > 256 or paths.isPath(q)) return false;
    for (q) |c| if (c < 0x20 or c == 0x7f) return false;
    return true;
}

/// Folders left out of every search, wherever they are: dependencies,
/// repositories, build output and caches, the Trash.
const excluded_folders = [_][]const u8{
    "node_modules",
    ".git",
    "Library/Caches",
    ".cache",
    ".Trash",
    ".zig-cache",
    "zig-cache",
    "zig-out",
};

/// Whether `path` is left out: in ~/Library, in one of `excluded_folders`,
/// or in one the user listed in `extra` (lines: a path, or a folder name).
pub fn excluded(path: []const u8, extra: []const u8) bool {
    var library_buf: [max_path]u8 = undefined;
    const h = paths.home();
    if (h.len > 0) {
        const library = std.fmt.bufPrint(&library_buf, "{s}/Library", .{h}) catch return true;
        if (paths.within(path, library)) return true;
    }
    for (excluded_folders) |part| {
        if (paths.hasComponent(path, part)) return true;
    }
    var lines = std.mem.tokenizeScalar(u8, extra, '\n');
    var buf: [max_path]u8 = undefined;
    while (lines.next()) |line| {
        const p = paths.expand(&buf, std.mem.trim(u8, line, " \r\t")) orelse continue;
        if (p.len == 0) continue;
        if (p[0] == '/') {
            if (paths.within(path, std.mem.trimEnd(u8, p, "/"))) return true;
        } else if (paths.hasComponent(path, p)) return true;
    }
    return false;
}

pub const Tier = enum { exact, prefix, word, subsequence };

/// Literal, case/diacritic-insensitive queries, never shell text.
pub fn predicate(buf: []u8, query: []const u8, tier: Tier) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("kMDItemFSName == \"") catch return null;
    w.writeAll(switch (tier) {
        .exact, .prefix => "",
        .word => "* ",
        .subsequence => "*",
    }) catch return null;
    var i: usize = 0;
    while (i < query.len) {
        const len = std.unicode.utf8ByteSequenceLength(query[i]) catch return null;
        if (i + len > query.len) return null;
        if (len == 1 and (query[i] == '"' or query[i] == '*' or query[i] == '\\' or
            query[i] == '?')) w.writeByte('\\') catch return null;
        w.writeAll(query[i..][0..len]) catch return null;
        if (tier == .subsequence) w.writeByte('*') catch return null;
        i += len;
    }
    if (tier == .prefix or tier == .word) w.writeByte('*') catch return null;
    w.writeAll("\"cd") catch return null;
    return w.buffered();
}

/// Bounded tiers share one two-second deadline and one ranked, deduplicated list.
pub fn find(
    io: std.Io,
    query: []const u8,
    locations: []const u8,
    extra: []const u8,
    out: *List,
) bool {
    out.deinit();
    if (!eligible(query)) return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(a, "/usr/bin/mdfind") catch return false;
    var lines = std.mem.tokenizeScalar(
        u8,
        if (std.mem.trim(u8, locations, " \r\n\t").len == 0) paths.home() else locations,
        '\n',
    );
    while (lines.next()) |line| {
        var buf: [max_path]u8 = undefined;
        const path = paths.expand(&buf, std.mem.trim(u8, line, " \r\t")) orelse continue;
        if (path.len == 0 or path[0] != '/') continue;
        const owned = a.dupe(u8, path) catch return false;
        argv.appendSlice(a, &.{ "-onlyin", owned }) catch return false;
    }
    if (argv.items.len == 1) return false;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + 2000;
    argv.append(a, "") catch return false;
    var ok = false;
    for ([_]Tier{ .exact, .prefix, .word, .subsequence }) |tier| {
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) break;
        var pred_buf: [2048]u8 = undefined;
        argv.items[argv.items.len - 1] = predicate(&pred_buf, query, tier) orelse return false;
        ok = collect(io, argv.items, query, extra, out, @min(deadline, now + 500)) or ok;
    }
    return ok;
}

fn collect(
    io: std.Io,
    argv: []const []const u8,
    query: []const u8,
    extra: []const u8,
    out: *List,
    deadline: i64,
) bool {
    var child = std.process.spawn(
        io,
        .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore },
    ) catch return false;
    defer child.kill(io);
    var read_buf: [8192]u8 = undefined;
    var path_buf: [max_path]u8 = undefined;
    var used: usize = 0;
    var count: usize = 0;
    var total: usize = 0;
    var oversized = false;
    // A wall-clock deadline also bounds a process that keeps producing output.
    while (count < 256 and total < 256 * max_path) {
        const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) break;
        var fds = [_]std.posix.pollfd{
            .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        if ((std.posix.poll(&fds, @intCast(@min(remaining, 20))) catch return false) == 0) continue;
        const n = std.c.read(child.stdout.?.handle, &read_buf, read_buf.len);
        if (n < 0) return false;
        if (n == 0) {
            if (used > 0 and !oversized) candidate(io, out, query, path_buf[0..used], extra);
            return true;
        }
        total += @intCast(n);
        for (read_buf[0..@intCast(n)]) |c| {
            if (c == '\n') {
                if (std.Io.Clock.awake.now(io).toMilliseconds() >= deadline) return count > 0;
                count += 1;
                if (!oversized) candidate(io, out, query, path_buf[0..used], extra);
                used = 0;
                oversized = false;
                if (count == 256) return true;
            } else if (used < path_buf.len) {
                path_buf[used] = c;
                used += 1;
            } else oversized = true;
        }
    }
    return count > 0;
}

fn candidate(io: std.Io, out: *List, query: []const u8, path: []const u8, extra: []const u8) void {
    if (path.len == 0 or path[0] != '/' or excluded(path, extra)) return;
    for (out.entries[0..out.n]) |*e| if (std.mem.eql(u8, e.path(), path)) return;
    // Spotlight also folds diacritics, which the ASCII matcher does not.
    // Keep those matches below the tiers it can score and highlight.
    const m = search.score(query, std.fs.path.basename(path)) orelse search.Match{ .score = 0 };
    if (out.n == max_rows and m.score <= out.entries[out.n - 1].match.score) return;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    out.add(path, st.kind == .directory, m);
}
