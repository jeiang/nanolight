//! Clipboard history: what was copied (text, images, files), kept on disk
//! for a while, searchable. This file is the model and the store, with no
//! window and no OS in it; each OS's watcher and paste are its own file
//! (clipboard_mac.zig, clipboard_win.zig, clipboard_linux.zig), picked at
//! compile time as `Watcher`.
//!
//! On disk, in one directory: `index.json` (the entries, newest first) and
//! `blobs/<hash>.png` (an image) or `blobs/<hash>.txt` (a text too long for
//! the index). Everything stays on this computer: sync never carries it.
//! Items from excluded apps, and items the source marked concealed or
//! transient (password managers), are never stored, and nothing is stored
//! while `enabled` is false.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const search = @import("search.zig");

pub const Kind = enum { text, image, file };

/// Silent under test: the build fails a test run that writes to stderr.
fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.warn(fmt, args);
}

pub const max_text: usize = 10 << 20;
pub const max_image: usize = 20 << 20;
/// A copied list of files, as paths one a line.
pub const max_files: usize = 256 << 10;
/// What the index keeps of a text longer than `Store.inline_max`.
pub const preview_max = 512;
/// How much of a text is matched against a search.
const match_max = 160;
/// A match below this is letters scattered in order: too loose for a text
/// that may be long (the scores are search.zig's).
const min_score = 450;

/// One thing that was copied.
pub const Entry = struct {
    /// Of its kind and content: what makes a second copy the same entry.
    hash: u64,
    kind: Kind,
    /// Text: the text, or its first `preview_max` bytes when the rest is in
    /// a blob. File: the paths, one a line. Image: empty.
    text: []const u8,
    /// The whole content's bytes: the text, the PNG, the paths.
    size: u64,
    width: u32 = 0,
    height: u32 = 0,
    /// Bundle ID, exe name or app ID of where it came from; empty if unknown.
    source: []const u8 = "",
    /// When it was last copied (Unix seconds).
    at: i64,
    /// How many times it was copied.
    count: u32 = 1,
};

/// What a watcher saw on the clipboard. Slices are the watcher's own: the
/// store copies what it keeps.
pub const Item = struct {
    kind: Kind,
    /// A text, or a file list's paths one a line.
    text: []const u8 = "",
    png: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    source: []const u8 = "",
    /// Marked concealed or transient by the app that copied it.
    concealed: bool = false,
};

pub const Result = enum { added, bumped, disabled, excluded, concealed, empty, too_big, failed };

pub const Config = struct {
    enabled: bool = true,
    /// 0: no age limit.
    retention_days: u32 = 7,
    /// 0: no limit.
    max_entries: u32 = 1000,
    /// Compared with an item's source, any case. Borrowed.
    exclude_apps: []const []const u8 = &.{},
};

pub fn hash(kind: Kind, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(@backingInt(kind) + 1, bytes);
}

fn blobName(buf: []u8, h: u64, ext: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "blobs/{x:0>16}.{s}", .{ h, ext }) catch unreachable;
}

/// `s` cut to at most `max` bytes, on a character boundary.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Where it keeps its files; null keeps everything in memory (tests).
    dir: ?Io.Dir,
    cfg: Config,
    /// Newest first.
    entries: std.ArrayList(Entry) = .empty,
    /// A text longer than this goes to a blob (all of it stays here without a dir).
    inline_max: usize = 4096,
    /// Counts every change, so a screen knows its list is stale.
    gen: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, dir: ?Io.Dir, cfg: Config) Store {
        return .{ .gpa = gpa, .io = io, .dir = dir, .cfg = cfg };
    }

    pub fn deinit(s: *Store) void {
        for (s.entries.items) |e| s.free(e);
        s.entries.deinit(s.gpa);
    }

    fn free(s: *Store, e: Entry) void {
        s.gpa.free(e.text);
        s.gpa.free(e.source);
    }

    // ----- what is kept -----

    /// Whether `source` is one of the excluded apps.
    pub fn excluded(s: *const Store, source: []const u8) bool {
        if (source.len == 0) return false;
        for (s.cfg.exclude_apps) |x| if (std.ascii.eqlIgnoreCase(x, source)) return true;
        return false;
    }

    /// Keeps `item` copied at `now`, or says why not. A copy of what is
    /// already kept makes it newest and counts it.
    pub fn add(s: *Store, item: Item, now: i64) Result {
        if (!s.cfg.enabled) return .disabled;
        if (item.concealed) return .concealed;
        if (s.excluded(item.source)) return .excluded;
        const content = if (item.kind == .image) item.png else item.text;
        if (content.len == 0 or (item.kind != .image and std.mem.trim(u8, content, " \t\r\n").len == 0)) return .empty;
        const cap = switch (item.kind) {
            .text => max_text,
            .image => max_image,
            .file => max_files,
        };
        if (content.len > cap) {
            std.log.info("nanolight: clipboard: a {s} of {d} bytes is over the {d} byte limit; not kept", .{ @tagName(item.kind), content.len, cap });
            return .too_big;
        }
        const h = hash(item.kind, content);
        for (s.entries.items, 0..) |*e, i| if (e.hash == h and e.kind == item.kind) {
            e.count +|= 1;
            e.at = now;
            if (item.source.len > 0) if (s.gpa.dupe(u8, item.source)) |src| {
                s.gpa.free(e.source);
                e.source = src;
            } else |_| {};
            std.mem.rotate(Entry, s.entries.items[0 .. i + 1], i);
            s.changed();
            return .bumped;
        };
        const e = s.make(item, h, content, now) orelse return .failed;
        s.entries.insert(s.gpa, 0, e) catch {
            s.dropBlob(e);
            s.free(e);
            return .failed;
        };
        _ = s.enforce();
        s.changed();
        return .added;
    }

    /// The entry for `item`, its blob written.
    fn make(s: *Store, item: Item, h: u64, content: []const u8, now: i64) ?Entry {
        const spill = item.kind == .text and s.dir != null and content.len > s.inline_max;
        const body = s.gpa.dupe(u8, if (item.kind == .image) "" else if (spill) clip(content, @min(preview_max, s.inline_max)) else content) catch return null;
        const source = s.gpa.dupe(u8, item.source) catch {
            s.gpa.free(body);
            return null;
        };
        const e: Entry = .{ .hash = h, .kind = item.kind, .text = body, .size = content.len, .width = item.width, .height = item.height, .source = source, .at = now };
        if (item.kind == .image or spill) s.writeBlob(e, content) catch |err| {
            warn("nanolight: clipboard: could not write a blob: {t}", .{err});
            s.free(e);
            return null;
        };
        return e;
    }

    fn blobFor(e: Entry, buf: []u8) ?[]const u8 {
        return switch (e.kind) {
            .image => blobName(buf, e.hash, "png"),
            .text => if (e.text.len < e.size) blobName(buf, e.hash, "txt") else null,
            .file => null,
        };
    }

    fn writeBlob(s: *Store, e: Entry, bytes: []const u8) !void {
        const dir = s.dir orelse return;
        var buf: [48]u8 = undefined;
        try dir.createDirPath(s.io, "blobs");
        try writeAtomic(s.io, dir, blobFor(e, &buf).?, bytes);
    }

    fn dropBlob(s: *Store, e: Entry) void {
        const dir = s.dir orelse return;
        var buf: [48]u8 = undefined;
        if (blobFor(e, &buf)) |name| dir.deleteFile(s.io, name) catch {};
    }

    fn changed(s: *Store) void {
        s.gen +%= 1;
        s.save();
    }

    /// The text of `e`, all of it. Caller frees.
    pub fn fullText(s: *Store, gpa: std.mem.Allocator, e: Entry) ![]u8 {
        var buf: [48]u8 = undefined;
        const name = blobFor(e, &buf) orelse return gpa.dupe(u8, e.text);
        const dir = s.dir orelse return error.NoDirectory;
        return dir.readFileAlloc(s.io, name, gpa, .limited(max_text));
    }

    /// The PNG of an image entry, or null if its file is gone. Caller frees.
    pub fn png(s: *Store, gpa: std.mem.Allocator, e: Entry) ?[]u8 {
        if (e.kind != .image) return null;
        const dir = s.dir orelse return null;
        var buf: [48]u8 = undefined;
        return dir.readFileAlloc(s.io, blobName(&buf, e.hash, "png"), gpa, .limited(max_image)) catch null;
    }

    pub fn get(s: *const Store, h: u64) ?*const Entry {
        for (s.entries.items) |*e| if (e.hash == h) return e;
        return null;
    }

    pub fn remove(s: *Store, h: u64) bool {
        for (s.entries.items, 0..) |e, i| if (e.hash == h) {
            _ = s.entries.orderedRemove(i);
            s.dropBlob(e);
            s.free(e);
            s.changed();
            return true;
        };
        return false;
    }

    /// Forgets everything, blobs included.
    pub fn clear(s: *Store) void {
        for (s.entries.items) |e| {
            s.dropBlob(e);
            s.free(e);
        }
        s.entries.clearRetainingCapacity();
        s.changed();
    }

    /// Drops what is older than `retention_days` and what is past `max_entries`.
    /// Returns how many went.
    pub fn prune(s: *Store, now: i64) usize {
        var gone: usize = 0;
        if (s.cfg.retention_days > 0) {
            const cutoff = now -| @as(i64, s.cfg.retention_days) * std.time.s_per_day;
            var i = s.entries.items.len;
            while (i > 0) {
                i -= 1;
                if (s.entries.items[i].at >= cutoff) continue;
                const e = s.entries.orderedRemove(i);
                s.dropBlob(e);
                s.free(e);
                gone += 1;
            }
        }
        gone += s.enforce();
        if (gone > 0) s.changed();
        return gone;
    }

    /// The oldest entries past `max_entries` go.
    fn enforce(s: *Store) usize {
        const max = s.cfg.max_entries;
        if (max == 0) return 0;
        var gone: usize = 0;
        while (s.entries.items.len > max) {
            const e = s.entries.pop().?;
            s.dropBlob(e);
            s.free(e);
            gone += 1;
        }
        return gone;
    }

    // ----- search -----

    /// The entries `query` finds, best first (newest first among equals),
    /// as places in `entries`: how many went into `out`. No query lists the
    /// newest. It matches the text's start, a file's name and the source app.
    pub fn find(s: *const Store, query: []const u8, out: []u32) usize {
        const q = std.mem.trim(u8, query, " ");
        if (q.len == 0) {
            const n = @min(s.entries.items.len, out.len);
            for (out[0..n], 0..) |*o, i| o.* = @intCast(i);
            return n;
        }
        var scores: [64]i32 = undefined;
        const room = @min(out.len, scores.len);
        var n: usize = 0;
        for (s.entries.items, 0..) |e, i| {
            const sc = s.score(q, e) orelse continue;
            var at = n;
            while (at > 0 and scores[at - 1] < sc) at -= 1;
            if (at >= room) continue;
            if (n < room) n += 1;
            var j = n - 1;
            while (j > at) : (j -= 1) {
                out[j] = out[j - 1];
                scores[j] = scores[j - 1];
            }
            out[at] = @intCast(i);
            scores[at] = sc;
        }
        return n;
    }

    fn score(_: *const Store, q: []const u8, e: Entry) ?i32 {
        var best: ?i32 = null;
        switch (e.kind) {
            .text => best = better(best, q, clip(e.text, match_max), 0),
            .file => {
                var lines = std.mem.splitScalar(u8, e.text, '\n');
                while (lines.next()) |path| best = better(best, q, std.fs.path.basename(path), 0);
            },
            .image => {},
        }
        return better(best, q, e.source, 100);
    }

    fn better(best: ?i32, q: []const u8, name: []const u8, penalty: i32) ?i32 {
        const m = search.score(q, name) orelse return best;
        const sc = m.score - penalty;
        if (m.score < min_score) return best;
        return if (best == null or sc > best.?) sc else best;
    }

    // ----- the files -----

    /// Reads `index.json`. A missing one is an empty history; one that does
    /// not parse is set aside as `index.json.corrupt` and the history starts
    /// empty, its blobs left alone (the sweep at the next start frees them).
    pub fn load(s: *Store, now: i64) void {
        const dir = s.dir orelse return;
        const bytes = dir.readFileAlloc(s.io, "index.json", s.gpa, .limited(256 << 20)) catch |e| {
            if (e != error.FileNotFound) warn("nanolight: clipboard: index.json: {t}; starting empty", .{e});
            return;
        };
        defer s.gpa.free(bytes);
        const parsed = std.json.parseFromSlice(Disk, s.gpa, bytes, .{ .ignore_unknown_fields = true }) catch {
            warn("nanolight: clipboard: index.json is damaged; moved to index.json.corrupt, starting empty", .{});
            dir.rename("index.json", dir, "index.json.corrupt", s.io) catch {};
            return;
        };
        defer parsed.deinit();
        for (parsed.value.entries) |d| {
            const h = std.fmt.parseInt(u64, d.hash, 16) catch continue;
            const body = s.gpa.dupe(u8, d.text) catch continue;
            const source = s.gpa.dupe(u8, d.source) catch {
                s.gpa.free(body);
                continue;
            };
            s.entries.append(s.gpa, .{ .hash = h, .kind = d.kind, .text = body, .size = d.size, .width = d.w, .height = d.h, .source = source, .at = d.at, .count = @max(d.count, 1) }) catch {
                s.gpa.free(body);
                s.gpa.free(source);
            };
        }
        std.mem.sort(Entry, s.entries.items, {}, newer);
        _ = s.prune(now);
        s.sweep();
        s.gen +%= 1;
    }

    fn newer(_: void, a: Entry, b: Entry) bool {
        return a.at > b.at;
    }

    /// Deletes the blobs no entry names.
    fn sweep(s: *Store) void {
        const dir = s.dir orelse return;
        var blobs = dir.openDir(s.io, "blobs", .{ .iterate = true }) catch return;
        defer blobs.close(s.io);
        var it = blobs.iterate();
        while (it.next(s.io) catch null) |f| {
            const stem = std.fs.path.stem(f.name);
            const h = std.fmt.parseInt(u64, stem, 16) catch continue;
            const keep = for (s.entries.items) |e| {
                var buf: [48]u8 = undefined;
                const name = blobFor(e, &buf) orelse continue;
                if (e.hash == h and std.mem.eql(u8, name["blobs/".len..], f.name)) break true;
            } else false;
            if (!keep) blobs.deleteFile(s.io, f.name) catch {};
        }
    }

    fn save(s: *Store) void {
        const dir = s.dir orelse return;
        const list = s.gpa.alloc(DiskEntry, s.entries.items.len) catch return;
        defer s.gpa.free(list);
        const names = s.gpa.alloc([16]u8, list.len) catch return;
        defer s.gpa.free(names);
        for (s.entries.items, list, names) |e, *d, *name| {
            _ = std.fmt.bufPrint(name, "{x:0>16}", .{e.hash}) catch unreachable;
            d.* = .{ .hash = name, .kind = e.kind, .text = e.text, .size = e.size, .w = e.width, .h = e.height, .source = e.source, .at = e.at, .count = e.count };
        }
        const json = std.json.Stringify.valueAlloc(s.gpa, Disk{ .entries = list }, .{}) catch return;
        defer s.gpa.free(json);
        writeAtomic(s.io, dir, "index.json", json) catch |e| warn("nanolight: clipboard: could not write index.json: {t}", .{e});
    }
};

const DiskEntry = struct {
    hash: []const u8,
    kind: Kind,
    text: []const u8 = "",
    size: u64 = 0,
    w: u32 = 0,
    h: u32 = 0,
    source: []const u8 = "",
    at: i64 = 0,
    count: u32 = 1,
};

const Disk = struct {
    v: u8 = 1,
    entries: []const DiskEntry = &.{},
};

/// Written to a temp file, fsynced, then renamed: a crash leaves the old
/// file or the new one.
fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{name});
    errdefer dir.deleteFile(io, tmp) catch {};
    const f = try dir.createFile(io, tmp, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.sync(io);
    try dir.rename(tmp, dir, name, io);
}

// ----- how an entry reads -----

/// "Safari" of "com.apple.Safari", "chrome" of "chrome.exe"; an app ID that
/// is not a dotted name stays as it is.
pub fn appName(source: []const u8) []const u8 {
    const s = if (std.ascii.endsWithIgnoreCase(source, ".exe")) source[0 .. source.len - 4] else source;
    if (s.len != source.len) return s;
    if (std.mem.count(u8, s, ".") >= 2) if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| if (i + 1 < s.len) return s[i + 1 ..];
    return s;
}

/// "now", "5 min ago", "3 h ago", "2 d ago".
pub fn relative(buf: []u8, now: i64, at: i64) []const u8 {
    const d = @max(now - at, 0);
    const r = if (d < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (d < std.time.s_per_hour)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(d, 60)})
    else if (d < std.time.s_per_day)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(d, std.time.s_per_hour)})
    else
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(d, std.time.s_per_day)});
    return r catch "";
}

/// "12 bytes", "34 KB", "1.5 MB".
pub fn sizeText(buf: []u8, n: u64) []const u8 {
    const r = if (n < 1024)
        std.fmt.bufPrint(buf, "{d} bytes", .{n})
    else if (n < 1 << 20)
        std.fmt.bufPrint(buf, "{d} KB", .{n >> 10})
    else
        std.fmt.bufPrint(buf, "{d}.{d} MB", .{ n >> 20, (n & ((1 << 20) - 1)) * 10 >> 20 });
    return r catch "";
}

pub fn kindLabel(k: Kind) []const u8 {
    return switch (k) {
        .text => "Text",
        .image => "Image",
        .file => "File",
    };
}

/// One line for a list: a text's first line, an image's size, a file's name
/// (and how many more).
pub fn title(buf: []u8, e: Entry) []const u8 {
    switch (e.kind) {
        .text => {
            var lines = std.mem.splitScalar(u8, e.text, '\n');
            while (lines.next()) |l| {
                const t = std.mem.trim(u8, l, " \t\r");
                if (t.len > 0) return clip(t, 200);
            }
            return "";
        },
        .image => return std.fmt.bufPrint(buf, "Image {d} × {d}", .{ e.width, e.height }) catch "Image",
        .file => {
            const n = std.mem.count(u8, e.text, "\n") + 1;
            const first = e.text[0 .. std.mem.indexOfScalar(u8, e.text, '\n') orelse e.text.len];
            const name = std.fs.path.basename(first);
            if (n == 1) return name;
            return std.fmt.bufPrint(buf, "{s} and {d} more", .{ name, n - 1 }) catch name;
        },
    }
}

/// The width and height a PNG's header gives, or null if it is not one.
pub fn pngSize(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{ std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big) };
}

// ----- the OS's side -----

/// What a paste or a copy writes to the clipboard: the full text (a file
/// list's paths one a line) or the PNG.
pub const Content = struct {
    kind: Kind,
    text: []const u8 = "",
    png: []const u8 = "",
};

pub const PasteResult = enum {
    /// Written, and the keystroke sent to the app that had the keys.
    pasted,
    /// Written only: the OS has not allowed this app to send keys.
    copied_no_permission,
    /// Written only: pasting is not done on this system (yet).
    copied_unsupported,
    failed,
};

/// What a watcher tells the app.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Something was copied.
    observe: *const fn (ctx: *anyopaque, item: Item) void,
    /// Whether this source is excluded: asked before the content is read.
    excluded: *const fn (ctx: *anyopaque, source: []const u8) bool,
};

/// Called to hide the panel, before the app that had the keys is woken.
pub const Hide = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

/// This OS's watcher. Each one has:
///
///   `pub const available: bool` and `unavailable_reason: []const u8`
///   `start(w, sink) !void` and `stop(w)`: watching, on the main thread
///   `noteFrontmost(w)`: called as the panel opens, to remember where to paste
///   `paste(w, content, hide) PasteResult`
///   `copy(w, content) bool`: writes it, no paste
pub const Watcher = switch (builtin.os.tag) {
    .macos => @import("clipboard_mac.zig").Watcher,
    .windows => @import("clipboard_win.zig").Watcher,
    else => @import("clipboard_linux.zig").Watcher,
};

/// The text for a footer after a paste that only copied, or null.
pub fn pasteNote(r: PasteResult) ?[]const u8 {
    return switch (r) {
        .pasted => null,
        .copied_no_permission => "Copied. Allow Nanolight in Privacy & Security > Accessibility to paste.",
        .copied_unsupported => "Copied. Pasting is not supported on this system yet.",
        .failed => "Could not write the clipboard.",
    };
}

// ----- tests -----

const testing = std.testing;

fn textItem(t: []const u8, source: []const u8) Item {
    return .{ .kind = .text, .text = t, .source = source };
}

fn memory(cfg: Config) Store {
    return .init(testing.allocator, testing.io, null, cfg);
}

test "a copy is kept, newest first, and the same copy again bumps it" {
    var s = memory(.{});
    defer s.deinit();
    try testing.expectEqual(Result.added, s.add(textItem("one", "a"), 100));
    try testing.expectEqual(Result.added, s.add(textItem("two", "b"), 200));
    try testing.expectEqualStrings("two", s.entries.items[0].text);
    try testing.expectEqual(Result.bumped, s.add(textItem("one", "c"), 300));
    try testing.expectEqual(@as(usize, 2), s.entries.items.len);
    const e = s.entries.items[0];
    try testing.expectEqualStrings("one", e.text);
    try testing.expectEqual(@as(u32, 2), e.count);
    try testing.expectEqual(@as(i64, 300), e.at);
    try testing.expectEqualStrings("c", e.source);
    // A bump with no source keeps the old one; another kind with the same bytes is another entry.
    try testing.expectEqual(Result.bumped, s.add(textItem("one", ""), 400));
    try testing.expectEqualStrings("c", s.entries.items[0].source);
    try testing.expectEqual(Result.added, s.add(.{ .kind = .file, .text = "one" }, 500));
    try testing.expectEqual(@as(usize, 3), s.entries.items.len);
}

test "nothing is stored when disabled, excluded, concealed, empty or too big" {
    var s = memory(.{ .enabled = false });
    defer s.deinit();
    try testing.expectEqual(Result.disabled, s.add(textItem("x", ""), 1));
    s.cfg = .{ .exclude_apps = &.{ "com.bitwarden.desktop", "KeePassXC.exe" } };
    try testing.expectEqual(Result.excluded, s.add(textItem("x", "com.Bitwarden.Desktop"), 1));
    try testing.expectEqual(Result.excluded, s.add(textItem("x", "keepassxc.exe"), 1));
    try testing.expectEqual(Result.concealed, s.add(.{ .kind = .text, .text = "hunter2", .concealed = true }, 1));
    try testing.expectEqual(Result.empty, s.add(textItem("", ""), 1));
    try testing.expectEqual(Result.empty, s.add(textItem(" \n\t", ""), 1));
    try testing.expectEqual(Result.empty, s.add(.{ .kind = .image }, 1));
    const big = try testing.allocator.alloc(u8, max_image + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectEqual(Result.too_big, s.add(.{ .kind = .text, .text = big[0 .. max_text + 1] }, 1));
    try testing.expectEqual(Result.too_big, s.add(.{ .kind = .image, .png = big }, 1));
    try testing.expectEqual(@as(usize, 0), s.entries.items.len);
    try testing.expectEqual(@as(u32, 0), s.gen);
    // An unknown source is never excluded.
    try testing.expectEqual(Result.added, s.add(textItem("x", ""), 1));
}

test "pruning by age and by count" {
    const day = std.time.s_per_day;
    const now: i64 = 100 * day;
    var s = memory(.{ .retention_days = 7, .max_entries = 3 });
    defer s.deinit();
    for ([_][]const u8{ "old", "edge", "a", "b", "c" }, [_]i64{ -8 * day, -6 * day, -3, -2, -1 }) |t, d| _ = s.add(textItem(t, ""), now + d);
    // Adding past the limit drops the oldest at once.
    try testing.expectEqual(@as(usize, 3), s.entries.items.len);
    try testing.expectEqualStrings("c", s.entries.items[0].text);
    try testing.expectEqualStrings("a", s.entries.items[2].text);

    var t = memory(.{ .retention_days = 7, .max_entries = 0 });
    defer t.deinit();
    for ([_][]const u8{ "old", "edge", "a" }, [_]i64{ -8 * day, -6 * day, -3 }) |w, d| _ = t.add(textItem(w, ""), now + d);
    try testing.expectEqual(@as(usize, 1), t.prune(now));
    try testing.expectEqual(@as(usize, 0), t.prune(now));
    try testing.expectEqual(@as(usize, 1), t.prune(now + 2 * day));
    try testing.expectEqualStrings("a", t.entries.items[0].text);
    // 0 days keeps everything.
    t.cfg.retention_days = 0;
    try testing.expectEqual(@as(usize, 0), t.prune(now + 1000 * day));
}

test "search matches text, file names and the source app, best first" {
    var s = memory(.{});
    defer s.deinit();
    _ = s.add(textItem("remember the milk", "com.apple.Notes"), 1);
    _ = s.add(textItem("milkshake recipe", "com.apple.Safari"), 2);
    _ = s.add(.{ .kind = .file, .text = "/Users/me/Documents/budget.xlsx\n/Users/me/a.txt", .source = "com.apple.finder" }, 3);
    _ = s.add(.{ .kind = .image, .png = "x", .width = 4, .height = 4, .source = "com.apple.Preview" }, 4);
    var out: [8]u32 = undefined;
    // No query: all, newest first.
    try testing.expectEqual(@as(usize, 4), s.find("", &out));
    try testing.expectEqual(@as(u32, 0), out[0]);
    // A prefix beats a match inside.
    try testing.expectEqual(@as(usize, 2), s.find("milk", &out));
    try testing.expectEqualStrings("milkshake recipe", s.entries.items[out[0]].text);
    try testing.expectEqualStrings("remember the milk", s.entries.items[out[1]].text);
    // A file's name, not its directory prefix path alone.
    try testing.expectEqual(@as(usize, 1), s.find("budget", &out));
    try testing.expectEqual(Kind.file, s.entries.items[out[0]].kind);
    // The source app, for every kind.
    try testing.expectEqual(@as(usize, 1), s.find("preview", &out));
    try testing.expectEqual(Kind.image, s.entries.items[out[0]].kind);
    try testing.expectEqual(@as(usize, 0), s.find("zzzzqq", &out));
    // Room for only some.
    var one: [1]u32 = undefined;
    try testing.expectEqual(@as(usize, 1), s.find("", &one));
}

test "a long text goes to a blob and comes back whole; an image keeps its PNG" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.inline_max = 16;
    const long = "0123456789abcdef0123456789abcdef";
    try testing.expectEqual(Result.added, s.add(textItem(long, ""), 1));
    try testing.expectEqual(Result.added, s.add(.{ .kind = .image, .png = "\x89PNGdata", .width = 2, .height = 3 }, 2));
    // The index holds the start only, the blob the rest.
    const e = s.get(hash(.text, long)).?.*;
    try testing.expectEqual(@as(u64, long.len), e.size);
    const whole = try s.fullText(testing.allocator, e);
    defer testing.allocator.free(whole);
    try testing.expectEqualStrings(long, whole);
    const img = s.get(hash(.image, "\x89PNGdata")).?.*;
    const bytes = s.png(testing.allocator, img).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("\x89PNGdata", bytes);
    try testing.expectEqual(@as(u32, 3), img.height);
    // Removing an entry removes its blob.
    try testing.expect(s.remove(img.hash));
    try testing.expect(!s.remove(img.hash));
    var names: usize = 0;
    var blobs = try tmp.dir.openDir(testing.io, "blobs", .{ .iterate = true });
    defer blobs.close(testing.io);
    var it = blobs.iterate();
    while (try it.next(testing.io)) |f| {
        names += 1;
        try testing.expect(std.mem.endsWith(u8, f.name, ".txt"));
    }
    try testing.expectEqual(@as(usize, 1), names);
}

test "the history survives a restart, newest first, and blobs nobody names are swept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
        defer s.deinit();
        _ = s.add(textItem("first", "a.b.App"), 10);
        _ = s.add(.{ .kind = .image, .png = "png1", .width = 1, .height = 1 }, 20);
        _ = s.add(textItem("first", ""), 30);
    }
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blobs/00000000000000ff.png", .data = "orphan" });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.load(40);
    try testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try testing.expectEqualStrings("first", s.entries.items[0].text);
    try testing.expectEqual(@as(u32, 2), s.entries.items[0].count);
    try testing.expectEqualStrings("a.b.App", s.entries.items[0].source);
    try testing.expectEqual(Kind.image, s.entries.items[1].kind);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "blobs/00000000000000ff.png", .{}));
    const bytes = s.png(testing.allocator, s.entries.items[1]).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("png1", bytes);
}

test "a corrupt index starts empty, is set aside, and its blobs are left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.json", .data = "{\"entries\": [oops" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "blobs/0000000000000001.png", .data = "keep" });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.load(1);
    try testing.expectEqual(@as(usize, 0), s.entries.items.len);
    try tmp.dir.access(testing.io, "index.json.corrupt", .{});
    try tmp.dir.access(testing.io, "blobs/0000000000000001.png", .{});
    // And it works from there.
    try testing.expectEqual(Result.added, s.add(textItem("fresh", ""), 2));
    try tmp.dir.access(testing.io, "index.json", .{});
}

test "an entry with a bad hash in the index is skipped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.json", .data = "{\"v\":1,\"entries\":[{\"hash\":\"zz\",\"kind\":\"text\",\"text\":\"x\"},{\"hash\":\"0a\",\"kind\":\"text\",\"text\":\"y\",\"at\":5,\"size\":1}]}" });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{ .retention_days = 0 });
    defer s.deinit();
    s.load(10);
    try testing.expectEqual(@as(usize, 1), s.entries.items.len);
    try testing.expectEqualStrings("y", s.entries.items[0].text);
}

test "clear forgets everything, blobs too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    _ = s.add(textItem("a", ""), 1);
    _ = s.add(.{ .kind = .image, .png = "p", .width = 1, .height = 1 }, 2);
    s.clear();
    try testing.expectEqual(@as(usize, 0), s.entries.items.len);
    var blobs = try tmp.dir.openDir(testing.io, "blobs", .{ .iterate = true });
    defer blobs.close(testing.io);
    var it = blobs.iterate();
    try testing.expect((try it.next(testing.io)) == null);
    var again: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer again.deinit();
    again.load(3);
    try testing.expectEqual(@as(usize, 0), again.entries.items.len);
}

test "how entries read" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Safari", appName("com.apple.Safari"));
    try testing.expectEqualStrings("chrome", appName("chrome.exe"));
    try testing.expectEqualStrings("firefox", appName("firefox"));
    try testing.expectEqualStrings("org.gnome", appName("org.gnome"));
    try testing.expectEqualStrings("just now", relative(&buf, 100, 90));
    try testing.expectEqualStrings("5 min ago", relative(&buf, 1000, 700));
    try testing.expectEqualStrings("3 h ago", relative(&buf, 20000, 9000));
    try testing.expectEqualStrings("2 d ago", relative(&buf, 200000, 20000));
    const t: Entry = .{ .hash = 1, .kind = .text, .text = "\n  hello\nworld", .size = 14, .at = 0 };
    try testing.expectEqualStrings("hello", title(&buf, t));
    const im: Entry = .{ .hash = 2, .kind = .image, .text = "", .size = 1, .width = 800, .height = 600, .at = 0 };
    try testing.expectEqualStrings("Image 800 × 600", title(&buf, im));
    const f: Entry = .{ .hash = 3, .kind = .file, .text = "/a/b/c.txt\n/a/d.txt", .size = 1, .at = 0 };
    try testing.expectEqualStrings("c.txt and 1 more", title(&buf, f));
    try testing.expectEqualStrings("é", clip("éé", 3));
    try testing.expectEqualStrings("12 bytes", sizeText(&buf, 12));
    try testing.expectEqualStrings("34 KB", sizeText(&buf, 34 * 1024 + 5));
    try testing.expectEqualStrings("1.5 MB", sizeText(&buf, 3 << 19));
    const hdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x03\x20\x00\x00\x02\x58";
    try testing.expectEqual([2]u32{ 800, 600 }, pngSize(hdr).?);
    try testing.expect(pngSize("not a png at all, really not") == null);
}

test "every OS's watcher has the same surface" {
    inline for (.{ "available", "unavailable_reason", "start", "stop", "noteFrontmost", "paste", "copy" }) |name| {
        try testing.expect(@hasDecl(Watcher, name));
    }
}
