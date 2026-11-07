//! File search by name through Spotlight's index (the Mac's alone,
//! platform.zig's `files`): `mdfind` asked in tiers, exact names first,
//! under one deadline, into one ranked list (files.zig). Only paths and
//! names are read.
const std = @import("std");
const assert = std.debug.assert;
const files = @import("files.zig");
const paths = @import("paths.zig");
const search = @import("search.zig");
const log = @import("log.zig");
const List = files.List;
const max_path = files.max_path;
const max_rows = files.max_rows;

/// The longest query Spotlight is asked.
const query_max = 256;
/// All tiers together, and each tier, answer within these.
const deadline_ms = 2000;
const tier_ms = 500;
/// How long one wait for mdfind's output lasts, so a deadline is noticed.
const poll_ms = 20;
/// The most lines, and bytes, read from one tier.
const lines_max = 256;
const bytes_max = lines_max * max_path;

/// A query worth asking Spotlight: a name, not a path, UTF-8, no control bytes.
pub fn eligible(q: []const u8) bool {
    if (q.len < 2 or q.len > query_max or paths.isPath(q)) return false;
    for (q) |c| if (c < 0x20 or c == 0x7f) return false;
    return std.unicode.utf8ValidateSlice(q);
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

/// The room `predicate` takes: the framing, and at most three bytes for
/// each query byte (an escape, the byte, a subsequence's `*`).
pub const predicate_len = "kMDItemFSName == \"* ".len + 3 * query_max + "*\"cd".len;

/// Literal, case/diacritic-insensitive queries, never shell text. The
/// query is `eligible`'s.
pub fn predicate(buf: *[predicate_len]u8, query: []const u8, tier: Tier) []const u8 {
    assert(query.len <= query_max);
    var w: std.Io.Writer = .fixed(buf);
    // `predicate_len` holds the longest, so no write fails.
    w.writeAll("kMDItemFSName == \"") catch unreachable;
    w.writeAll(switch (tier) {
        .exact, .prefix => "",
        .word => "* ",
        .subsequence => "*",
    }) catch unreachable;
    var i: usize = 0;
    while (i < query.len) {
        const len = std.unicode.utf8ByteSequenceLength(query[i]) catch unreachable;
        assert(i + len <= query.len);
        if (len == 1 and (query[i] == '"' or query[i] == '*' or query[i] == '\\' or
            query[i] == '?')) w.writeByte('\\') catch unreachable;
        w.writeAll(query[i..][0..len]) catch unreachable;
        if (tier == .subsequence) w.writeByte('*') catch unreachable;
        i += len;
    }
    if (tier == .prefix or tier == .word) w.writeByte('*') catch unreachable;
    w.writeAll("\"cd") catch unreachable;
    return w.buffered();
}

/// Bounded tiers share one deadline and one ranked, deduplicated list.
/// False when nothing was asked or no tier answered in time; an error when
/// mdfind failed (the cause is logged) and no tier answered.
pub fn find(
    io: std.Io,
    query: []const u8,
    locations: []const u8,
    extra: []const u8,
    out: *List,
) error{ Unavailable, OutOfMemory }!bool {
    out.deinit();
    if (!eligible(query)) return false;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "/usr/bin/mdfind");
    var lines = std.mem.tokenizeScalar(
        u8,
        if (std.mem.trim(u8, locations, " \r\n\t").len == 0) paths.home() else locations,
        '\n',
    );
    while (lines.next()) |line| {
        var buf: [max_path]u8 = undefined;
        const path = paths.expand(&buf, std.mem.trim(u8, line, " \r\t")) orelse continue;
        if (path.len == 0 or path[0] != '/') continue;
        try argv.appendSlice(a, &.{ "-onlyin", try a.dupe(u8, path) });
    }
    if (argv.items.len == 1) return false;
    const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + deadline_ms;
    try argv.append(a, "");
    var ok = false;
    var unavailable = false;
    for ([_]Tier{ .exact, .prefix, .word, .subsequence }) |tier| {
        const now = std.Io.Clock.awake.now(io).toMilliseconds();
        if (now >= deadline) break;
        var pred_buf: [predicate_len]u8 = undefined;
        argv.items[argv.items.len - 1] = predicate(&pred_buf, query, tier);
        const until = @min(deadline, now + tier_ms);
        const answered = collect(io, argv.items, query, extra, out, until) catch {
            unavailable = true;
            continue;
        };
        ok = answered or ok;
    }
    if (!ok and unavailable) return error.Unavailable;
    return ok;
}

fn collect(
    io: std.Io,
    argv: []const []const u8,
    query: []const u8,
    extra: []const u8,
    out: *List,
    deadline: i64,
) error{Unavailable}!bool {
    var child = std.process.spawn(
        io,
        .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore },
    ) catch |e| {
        log.warn("file search: mdfind didn't start: {t}", .{e});
        return error.Unavailable;
    };
    defer child.kill(io);
    var read_buf: [8192]u8 = undefined;
    var path_buf: [max_path]u8 = undefined;
    var used: usize = 0;
    var count: usize = 0;
    var total: usize = 0;
    var oversized = false;
    // A wall-clock deadline also bounds a process that keeps producing output.
    while (count < lines_max and total < bytes_max) {
        const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
        if (remaining <= 0) break;
        var fds = [_]std.posix.pollfd{
            .{ .fd = child.stdout.?.handle, .events = std.posix.POLL.IN, .revents = 0 },
        };
        const ready = std.posix.poll(&fds, @intCast(@min(remaining, poll_ms))) catch |e| {
            log.warn("file search: waiting on mdfind failed: {t}", .{e});
            return error.Unavailable;
        };
        if (ready == 0) continue;
        const n = std.c.read(child.stdout.?.handle, &read_buf, read_buf.len);
        if (n < 0) {
            log.warn("file search: reading mdfind failed: {t}", .{std.posix.errno(n)});
            return error.Unavailable;
        }
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
                if (count == lines_max) return true;
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
