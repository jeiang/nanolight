//! Clipboard history: what was copied (text, images, files), kept on disk
//! for a while, searchable. This file is the model, the store and the
//! watcher contract, with no window and no OS in it; each OS's watcher and
//! paste are their own file (clipboard_mac.zig, clipboard_win.zig,
//! clipboard_linux.zig), picked at compile time as `Watcher`. How an entry
//! reads on screen is clipboard_view.zig's.
//!
//! On disk, in one directory: `index.json` (the entries, newest first) and
//! `blobs/<hash>.png` (an image) or `blobs/<hash>.txt` (a text too long for
//! the index). Everything stays on this computer: sync never carries it.
//! Items from excluded apps, and items the source marked concealed or
//! transient (password managers), are never stored, and nothing is stored
//! while `Store.on` is false.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const search = @import("search.zig");

/// The feature's name, as its row and its screen say it.
pub const title = "Clipboard History";

pub const Kind = enum {
    text,
    image,
    file,

    /// What a kind's content is and where it is kept.
    pub const Info = struct {
        /// The most of it kept; a watcher reads (and converts) nothing larger.
        cap: usize,
        /// Its content is the PNG (`Item.png`), not text.
        png: bool,
        /// Its blob's extension, and when the content goes there.
        ext: *const [blob_ext_len]u8,
        blob: enum { always, when_long, never },
    };

    pub fn info(k: Kind) Info {
        return switch (k) {
            .text => .{ .cap = 10 << 20, .png = false, .ext = "txt", .blob = .when_long },
            .image => .{ .cap = 20 << 20, .png = true, .ext = "png", .blob = .always },
            // A copied list of files, as paths one a line.
            .file => .{ .cap = 256 << 10, .png = false, .ext = "txt", .blob = .never },
        };
    }

    pub fn cap(k: Kind) usize {
        return k.info().cap;
    }
};

/// User-only (0600 / 0700); Windows has no mode and keeps its profile's ACL.
const Perm = Io.File.Permissions;
pub const private_file: Perm = if (@hasDecl(Perm, "fromMode")) .fromMode(0o600) else .default_file;
pub const private_dir: Perm = if (@hasDecl(Perm, "fromMode")) .fromMode(0o700) else .default_dir;

/// The clipboard modules' log: silent under test, where the build fails a run that writes
/// to stderr.
pub fn log(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    switch (level) {
        .err => std.log.err(fmt, args),
        .warn => std.log.warn(fmt, args),
        .info => std.log.info(fmt, args),
        .debug => std.log.debug(fmt, args),
    }
}

/// The most the history keeps of all its entries' content together (their `size`),
/// whatever `max_entries` says (0 there limits only the count): past it, the oldest go first.
pub const max_store_bytes: u64 = 256 << 20;
comptime {
    // The newest entry always fits on its own.
    for (std.enums.values(Kind)) |k| std.debug.assert(k.cap() <= max_store_bytes);
}
/// A text longer than this goes to a blob (all of it stays in memory without a dir).
const inline_max = 4096;
/// What the index keeps of a text that went to a blob.
pub const preview_max = 512;
comptime {
    std.debug.assert(preview_max < inline_max);
}
/// How much of a text is matched against a search.
const match_max = 160;
/// The app a thing was copied from matches this much under the thing.
const source_cost = 100;

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
    /// Any kind when `concealed`: nothing of it was read.
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

/// config.toml's `[clipboard]` table.
pub const Config = struct {
    /// Seeds the app's own switch (prefs.zig's `.clipboard`); null leaves it be.
    enabled: ?bool = null,
    /// 0: no age limit.
    retention_days: u32 = 7,
    /// 0: no limit on the count (`max_store_bytes` still applies).
    max_entries: u32 = 1000,
    /// Return pastes text without its formatting; false copies the entry instead.
    paste_plain_text: bool = true,
    /// Compared with an item's source, any case. Borrowed.
    exclude_apps: []const []const u8 = &.{ "com.bitwarden.desktop", "com.yubico.yubioath" },
};

pub fn hash(kind: Kind, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(@backingInt(kind) + 1, bytes);
}

// ----- the format on disk -----

/// The version `index.json` is written in, and the one `load` reads.
const format_version = 1;
/// The largest `index.json` read; past it, the file is not this app's.
const max_index_bytes = 256 << 20;
const blob_dir = "blobs";
/// "blobs/<16 hex digits>.<ext>".
const blob_ext_len = 3;
const blob_name_len = blob_dir.len + "/".len + 16 + ".".len + blob_ext_len;

/// The file that holds `e`'s content, in `buf`; null when the index holds it all.
fn blobName(e: Entry, buf: *[blob_name_len]u8) ?[]const u8 {
    const i = e.kind.info();
    switch (i.blob) {
        .always => {},
        .when_long => if (e.text.len >= e.size) return null,
        .never => return null,
    }
    return std.fmt.bufPrint(buf, blob_dir ++ "/{x:0>16}.{s}", .{ e.hash, i.ext }) catch unreachable;
}

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
    v: u32 = format_version,
    entries: []const DiskEntry = &.{},
};

/// `index.json` as `load` reads it: the entries one by one, so a bad one is skipped alone.
const DiskIn = struct {
    v: u32 = format_version,
    entries: []const std.json.Value = &.{},
};

/// Deletes `name` in `dir`; true when it is gone, a missing file included. A failure is
/// logged: on these paths it means content may outlive a delete the person asked for.
fn deleteIfThere(io: Io, dir: Io.Dir, name: []const u8) bool {
    dir.deleteFile(io, name) catch |e| {
        if (e == error.FileNotFound) return true;
        log(.warn, "nanolight: clipboard: could not delete {s}: {t}", .{ name, e });
        return false;
    };
    return true;
}

/// An entry's content as the OS writes it; `owned` is the caller's to free.
pub const Loaded = struct { content: Content, owned: ?[]u8 = null };

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Where it keeps its files; null keeps everything in memory (tests).
    dir: ?Io.Dir,
    cfg: Config,
    /// The app's switch (prefs.zig's `.clipboard`): nothing records while it is off.
    on: bool = true,
    /// False when the config file failed to load: nothing records, whatever `on` says.
    config_ok: bool = true,
    /// Newest first. Read it through `len`, `at` and `find`.
    entries: std.ArrayList(Entry) = .empty,
    /// Counts every change, so a screen knows its list is stale.
    gen: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, io: Io, dir: ?Io.Dir, cfg: Config) Store {
        return .{ .gpa = gpa, .io = io, .dir = dir, .cfg = cfg };
    }

    /// Settings' switch turned to `on`, `kept` saying whether that was saved. Off holds at
    /// once even when it was not (logged): recording stops now. On holds only once kept, so
    /// a failed write never leaves history recording against what the next launch reads.
    pub fn turn(s: *Store, on: bool, kept: bool) void {
        if (kept or !on) s.on = on;
        if (!kept and !on)
            log(.warn, "nanolight: clipboard history is off until Nanolight quits; " ++
                "that could not be saved", .{});
    }

    pub fn deinit(s: *Store) void {
        for (s.entries.items) |e| s.free(e);
        s.entries.deinit(s.gpa);
    }

    fn free(s: *Store, e: Entry) void {
        s.gpa.free(e.text);
        s.gpa.free(e.source);
    }

    // ----- the list -----

    pub fn len(s: *const Store) usize {
        return s.entries.items.len;
    }

    /// The `i`th entry, newest first; valid until the next change.
    pub fn at(s: *const Store, i: usize) Entry {
        return s.entries.items[i];
    }

    pub fn get(s: *const Store, h: u64) ?*const Entry {
        for (s.entries.items) |*e| if (e.hash == h) return e;
        return null;
    }

    // ----- what is kept -----

    /// Whether `source` is one of the excluded apps.
    pub fn excluded(s: *const Store, source: []const u8) bool {
        if (source.len == 0) return false;
        for (s.cfg.exclude_apps) |x| if (std.ascii.eqlIgnoreCase(x, source)) return true;
        return false;
    }

    /// Keeps `item` copied at `now`; whether the history changed. A copy of
    /// what is already kept makes it newest and counts it.
    pub fn add(s: *Store, item: Item, now: i64) bool {
        if (!s.on or !s.config_ok) return false;
        if (item.concealed) return false;
        if (s.excluded(item.source)) return false;
        const content = if (item.kind.info().png) item.png else item.text;
        if (content.len == 0 or (!item.kind.info().png and
            std.mem.trim(u8, content, " \t\r\n").len == 0)) return false;
        if (content.len > item.kind.cap()) {
            log(
                .info,
                "nanolight: clipboard: a {t} of {d} bytes is over the {d} byte limit; not kept",
                .{ item.kind, content.len, item.kind.cap() },
            );
            return false;
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
            s.changedOrWarn();
            return true;
        };
        const e = s.make(item, h, content, now) orelse return false;
        s.entries.insert(s.gpa, 0, e) catch {
            s.dropBlob(e);
            s.free(e);
            return false;
        };
        _ = s.enforce();
        s.changedOrWarn();
        return true;
    }

    /// The entry for `item`, its blob written.
    fn make(s: *Store, item: Item, h: u64, content: []const u8, now: i64) ?Entry {
        const spill = item.kind.info().blob == .when_long and s.dir != null and
            content.len > inline_max;
        const shown = if (item.kind.info().png)
            ""
        else if (spill) search.clip(content, preview_max) else content;
        const body = s.gpa.dupe(u8, shown) catch return null;
        const source = s.gpa.dupe(u8, item.source) catch {
            s.gpa.free(body);
            return null;
        };
        const e: Entry = .{
            .hash = h,
            .kind = item.kind,
            .text = body,
            .size = content.len,
            .width = item.width,
            .height = item.height,
            .source = source,
            .at = now,
        };
        s.writeBlob(e, content) catch |err| {
            log(.warn, "nanolight: clipboard: could not write a blob: {t}", .{err});
            s.free(e);
            return null;
        };
        return e;
    }

    fn writeBlob(s: *Store, e: Entry, bytes: []const u8) !void {
        const dir = s.dir orelse return;
        var buf: [blob_name_len]u8 = undefined;
        const name = blobName(e, &buf) orelse return;
        _ = try dir.createDirPathStatus(s.io, blob_dir, private_dir);
        try writeAtomic(s.io, dir, name, bytes);
    }

    /// A failure is logged; the next `load` sweeps the file.
    fn dropBlob(s: *Store, e: Entry) void {
        const dir = s.dir orelse return;
        var buf: [blob_name_len]u8 = undefined;
        if (blobName(e, &buf)) |name| _ = deleteIfThere(s.io, dir, name);
    }

    /// After a change in memory: counted, and the index written.
    fn changed(s: *Store) !void {
        s.gen +%= 1;
        try s.save();
    }

    /// `changed` where the caller cannot act on a failure: it is logged, and the next
    /// change writes the whole index again.
    fn changedOrWarn(s: *Store) void {
        s.changed() catch |e| indexNotWritten(e);
    }

    fn indexNotWritten(e: anyerror) void {
        log(.warn, "nanolight: clipboard: could not write index.json: {t}", .{e});
    }

    /// All of `e`'s content, from its blob when it has one: a missing or
    /// unreadable blob is an error.
    pub fn read(s: *Store, gpa: std.mem.Allocator, e: Entry) !Loaded {
        const png = e.kind.info().png;
        var buf: [blob_name_len]u8 = undefined;
        const name = blobName(e, &buf) orelse
            return .{ .content = .{ .kind = e.kind, .text = e.text } };
        const dir = s.dir orelse return error.NoDirectory;
        const bytes = try dir.readFileAlloc(s.io, name, gpa, .limited(e.kind.cap()));
        return .{
            .content = .{
                .kind = e.kind,
                .text = if (png) "" else bytes,
                .png = if (png) bytes else "",
            },
            .owned = bytes,
        };
    }

    pub fn remove(s: *Store, h: u64) bool {
        for (s.entries.items, 0..) |e, i| if (e.hash == h) {
            _ = s.entries.orderedRemove(i);
            s.dropBlob(e);
            s.free(e);
            s.changedOrWarn();
            return true;
        };
        return false;
    }

    pub const ClearError = error{Incomplete};

    /// Forgets everything, blobs included. `error.Incomplete`: something may still be on
    /// disk (each failure is logged); memory is empty either way.
    pub fn clear(s: *Store) ClearError!void {
        for (s.entries.items) |e| s.free(e);
        s.entries.clearRetainingCapacity();
        // With no entries, the sweep deletes every blob.
        var gone = s.sweep();
        if (s.dir) |dir| gone = deleteIfThere(s.io, dir, "index.json.corrupt") and gone;
        s.changed() catch |e| {
            // The old index still names what was copied: it must not stay.
            log(.warn, "nanolight: clipboard: could not write index.json: {t}; deleting it", .{e});
            if (s.dir) |dir| gone = deleteIfThere(s.io, dir, "index.json") and gone;
        };
        if (!gone) return error.Incomplete;
    }

    /// Drops what is older than `retention_days`, then the oldest past `max_entries` or
    /// `max_store_bytes`. Returns how many went; an error means the index on disk still
    /// lists them (the next change or launch writes it again).
    pub fn prune(s: *Store, now: i64) !usize {
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
        if (gone > 0) try s.changed();
        return gone;
    }

    /// `prune` where the caller cannot act on a failure: it is logged.
    pub fn pruneOrWarn(s: *Store, now: i64) void {
        _ = s.prune(now) catch |e| indexNotWritten(e);
    }

    /// The oldest entries past `keepCount` go.
    fn enforce(s: *Store) usize {
        const keep = keepCount(s.entries.items, max_store_bytes, s.cfg.max_entries);
        const gone = s.entries.items.len - keep;
        for (s.entries.items[keep..]) |e| {
            s.dropBlob(e);
            s.free(e);
        }
        s.entries.shrinkRetainingCapacity(keep);
        return gone;
    }

    // ----- search -----

    /// The entries that match `query`, best first (newest first among equals),
    /// into `out`: how many. No query lists the newest. It matches the text's
    /// start, a file's name and the source app.
    pub fn find(s: *const Store, query: []const u8, out: []search.Ranked) usize {
        const q = std.mem.trim(u8, query, " ");
        if (q.len == 0) {
            const n = @min(s.entries.items.len, out.len);
            for (out[0..n], 0..) |*o, i| o.* = .{ .index = @intCast(i), .match = .{ .score = 0 } };
            return n;
        }
        var top: search.Top = .init(out);
        for (s.entries.items, 0..) |e, i| {
            const m = match(q, e) orelse continue;
            top.offer(.{ .index = @intCast(i), .match = m });
        }
        return top.n;
    }

    fn match(q: []const u8, e: Entry) ?search.Match {
        const min = search.min_loose_long;
        var best: ?search.Match = null;
        switch (e.kind) {
            .text => best = search.scoreNamed(q, search.clip(e.text, match_max), &.{}, min),
            .file => {
                var lines = std.mem.splitScalar(u8, e.text, '\n');
                while (lines.next()) |path| {
                    keepBetter(&best, search.scoreNamed(q, std.fs.path.basename(path), &.{}, min));
                }
            },
            .image => {},
        }
        var via = search.scoreNamed(q, e.source, &.{}, min) orelse return best;
        via.score -= source_cost;
        keepBetter(&best, via);
        return best;
    }

    fn keepBetter(best: *?search.Match, m: ?search.Match) void {
        const new = m orelse return;
        if (best.* == null or new.score > best.*.?.score) best.* = new;
    }

    // ----- the files -----

    /// Reads `index.json`. A missing one is an empty history. An entry that
    /// does not read is skipped (and its blob swept). An index of another
    /// version starts the history empty and is left as it is until the
    /// next change writes this version; one that is not an index at all is
    /// deleted (its text must not outlive Clear History). Either way its
    /// blobs are left alone.
    pub fn load(s: *Store, now: i64) void {
        const dir = s.dir orelse return;
        const limit: std.Io.Limit = .limited(max_index_bytes);
        const bytes = dir.readFileAlloc(s.io, "index.json", s.gpa, limit) catch |e| {
            if (e != error.FileNotFound) log(
                .warn,
                "nanolight: clipboard: index.json: {t}; starting empty",
                .{e},
            );
            return;
        };
        defer s.gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const disk = std.json.parseFromSliceLeaky(
            DiskIn,
            a,
            bytes,
            .{ .ignore_unknown_fields = true },
        ) catch {
            log(
                .warn,
                "nanolight: clipboard: index.json is damaged; deleting it, starting empty",
                .{},
            );
            _ = deleteIfThere(s.io, dir, "index.json");
            return;
        };
        if (disk.v != format_version) {
            log(
                .warn,
                "nanolight: clipboard: index.json is version {d}, not {d}; starting empty",
                .{ disk.v, format_version },
            );
            return;
        }
        var skipped: usize = 0;
        for (disk.entries) |v| {
            const d = std.json.parseFromValueLeaky(
                DiskEntry,
                a,
                v,
                .{ .ignore_unknown_fields = true },
            ) catch {
                skipped += 1;
                continue;
            };
            s.append(d) catch {
                skipped += 1;
                continue;
            };
        }
        if (skipped > 0) log(
            .warn,
            "nanolight: clipboard: index.json: skipped {d} entries that did not read",
            .{skipped},
        );
        std.mem.sort(Entry, s.entries.items, {}, newer);
        s.pruneOrWarn(now);
        // A blob it could not delete is logged; the next launch sweeps again.
        _ = s.sweep();
        s.gen +%= 1;
    }

    fn append(s: *Store, d: DiskEntry) !void {
        const h = try std.fmt.parseInt(u64, d.hash, 16);
        const body = try s.gpa.dupe(u8, d.text);
        errdefer s.gpa.free(body);
        const source = try s.gpa.dupe(u8, d.source);
        errdefer s.gpa.free(source);
        try s.entries.append(s.gpa, .{
            .hash = h,
            .kind = d.kind,
            .text = body,
            .size = d.size,
            .width = d.w,
            .height = d.h,
            .source = source,
            .at = d.at,
            .count = @max(d.count, 1),
        });
    }

    fn newer(_: void, a: Entry, b: Entry) bool {
        return a.at > b.at;
    }

    /// Deletes the blobs no entry names, and any other file in `blobs/`
    /// (a leftover `.tmp`). False when one may be left (logged).
    fn sweep(s: *Store) bool {
        const dir = s.dir orelse return true;
        var blobs = dir.openDir(s.io, blob_dir, .{ .iterate = true }) catch |e| {
            if (e == error.FileNotFound) return true;
            return sweepFailed(e);
        };
        defer blobs.close(s.io);
        var gone = true;
        var it = blobs.iterate();
        while (it.next(s.io) catch |e| return sweepFailed(e)) |f| {
            const keep = for (s.entries.items) |e| {
                var buf: [blob_name_len]u8 = undefined;
                const name = blobName(e, &buf) orelse continue;
                if (std.mem.eql(u8, std.fs.path.basename(name), f.name)) break true;
            } else false;
            if (!keep) gone = deleteIfThere(s.io, blobs, f.name) and gone;
        }
        return gone;
    }

    fn sweepFailed(e: anyerror) bool {
        log(.warn, "nanolight: clipboard: could not list blobs: {t}", .{e});
        return false;
    }

    fn save(s: *Store) !void {
        const dir = s.dir orelse return;
        const list = try s.gpa.alloc(DiskEntry, s.entries.items.len);
        defer s.gpa.free(list);
        const names = try s.gpa.alloc([16]u8, list.len);
        defer s.gpa.free(names);
        for (s.entries.items, list, names) |e, *d, *name| {
            _ = std.fmt.bufPrint(name, "{x:0>16}", .{e.hash}) catch unreachable;
            d.* = .{
                .hash = name,
                .kind = e.kind,
                .text = e.text,
                .size = e.size,
                .w = e.width,
                .h = e.height,
                .source = e.source,
                .at = e.at,
                .count = e.count,
            };
        }
        const json = try std.json.Stringify.valueAlloc(s.gpa, Disk{ .entries = list }, .{});
        defer s.gpa.free(json);
        try writeAtomic(s.io, dir, "index.json", json);
    }
};

/// How many of `entries` (newest first) stay: the newest while there are at most
/// `max_entries` (0: any number) and their content is within `budget`.
fn keepCount(entries: []const Entry, budget: u64, max_entries: u32) usize {
    var total: u64 = 0;
    for (entries) |e| total +|= e.size;
    var n = entries.len;
    while (n > 0 and (total > budget or (max_entries > 0 and n > max_entries))) {
        n -= 1;
        total -|= entries[n].size;
    }
    return n;
}

/// Written to a temp file, fsynced, then renamed: a crash leaves the old
/// file or the new one.
fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var buf: [80]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{name});
    // best effort: the write already failed; a left temp file is overwritten next time.
    errdefer dir.deleteFile(io, tmp) catch {};
    const f = try dir.createFile(io, tmp, .{ .truncate = true, .permissions = private_file });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.sync(io);
    try dir.rename(tmp, dir, name, io);
}

/// The width and height a PNG's header gives, or null if it is not one.
pub fn pngSize(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or
        !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        std.mem.readInt(u32, bytes[16..20], .big),
        std.mem.readInt(u32, bytes[20..24], .big),
    };
}

// ----- the OS's side -----

/// What a paste or a copy writes to the clipboard: the full text (a file
/// list's paths one a line) or the PNG.
pub const Content = struct {
    kind: Kind,
    text: []const u8 = "",
    png: []const u8 = "",
};

/// How a paste or a copy of an entry went.
pub const PasteResult = enum {
    /// Written, and the keystroke sent to the app that had the keys.
    pasted,
    /// Written, as asked: no paste.
    copied,
    /// Written only: the OS has not allowed this app to send keys.
    copied_no_permission,
    /// Written only: pasting is not done on this system (yet).
    copied_unsupported,
    /// The clipboard could not be written.
    failed,
    /// The entry's content could not be read (its blob is gone or damaged).
    unreadable,
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

pub const StartError = error{Unavailable};

/// This OS's watcher. Every one has, all on the main thread:
///
///   `start(w, sink) StartError!void` and `stop(w)`: watching
///   `status(w) ?[]const u8`: why it is not watching, once a start failed
///   `noteFrontmost(w)`: called as the panel opens, to remember where to paste
///   `paste(w, content, hide) PasteResult` (never `.copied` or `.unreadable`)
///   `copy(w, content) bool`: writes it, no paste
///
/// and keeps to these rules:
///
///   - Nothing over its kind's `cap` is read or converted: it is logged and dropped.
///   - An item its source marked concealed or transient is observed with
///     `concealed` set and nothing of it read.
///   - What its own `copy` and `paste` write is not observed: a poll watcher
///     (clipboard_poll.zig) keeps the change count it wrote; a Linux one offers
///     `own_mime` and skips an offer that has it (clipboard_offer.zig).
///   - `Item.source` is what the OS names: the frontmost app's bundle ID when the
///     change is seen (Mac), the owner's exe (Windows), the owner window's
///     WM_CLASS (X11). Wayland names no source, so `exclude_apps` cannot apply there.
pub const Watcher = switch (builtin.os.tag) {
    .macos => @import("clipboard_mac.zig").Watcher,
    .windows => @import("clipboard_win.zig").Watcher,
    else => @import("clipboard_linux.zig").Watcher,
};

comptime {
    conforms(Watcher);
}

/// Fails the build unless `W` has the surface `Watcher` documents.
pub fn conforms(comptime W: type) void {
    const surface = .{
        .{ "start", fn (*W, Sink) StartError!void },
        .{ "stop", fn (*W) void },
        .{ "status", fn (*const W) ?[]const u8 },
        .{ "noteFrontmost", fn (*W) void },
        .{ "paste", fn (*W, Content, Hide) PasteResult },
        .{ "copy", fn (*W, Content) bool },
    };
    inline for (surface) |d| {
        if (!@hasDecl(W, d[0])) @compileError(@typeName(W) ++ " has no " ++ d[0]);
        if (@TypeOf(@field(W, d[0])) != d[1])
            @compileError(@typeName(W) ++ "." ++ d[0] ++ " is not " ++ @typeName(d[1]));
    }
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
    try testing.expect(s.add(textItem("one", "a"), 100));
    try testing.expect(s.add(textItem("two", "b"), 200));
    try testing.expectEqualStrings("two", s.at(0).text);
    try testing.expect(s.add(textItem("one", "c"), 300));
    try testing.expectEqual(@as(usize, 2), s.len());
    const e = s.at(0);
    try testing.expectEqualStrings("one", e.text);
    try testing.expectEqual(@as(u32, 2), e.count);
    try testing.expectEqual(@as(i64, 300), e.at);
    try testing.expectEqualStrings("c", e.source);
    // A bump with no source keeps the old one; another kind with the same bytes is another entry.
    try testing.expect(s.add(textItem("one", ""), 400));
    try testing.expectEqualStrings("c", s.at(0).source);
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expect(s.add(.{ .kind = .file, .text = "one" }, 500));
    try testing.expectEqual(@as(usize, 3), s.len());
}

test "the switch: on holds only once kept, off holds even when it is not" {
    var s = memory(.{});
    defer s.deinit();
    s.on = false;
    s.turn(true, false);
    try testing.expect(!s.on);
    s.turn(true, true);
    try testing.expect(s.on);
    s.turn(false, false);
    try testing.expect(!s.on);
    s.on = true;
    s.turn(false, true);
    try testing.expect(!s.on);
}

test "nothing is stored when disabled, excluded, concealed, empty or too big" {
    var s = memory(.{});
    defer s.deinit();
    s.on = false;
    try testing.expect(!s.add(textItem("x", ""), 1));
    s.on = true;
    s.config_ok = false;
    try testing.expect(!s.add(textItem("x", ""), 1));
    s.config_ok = true;
    s.cfg = .{ .exclude_apps = &.{ "com.bitwarden.desktop", "KeePassXC.exe" } };
    try testing.expect(!s.add(textItem("x", "com.Bitwarden.Desktop"), 1));
    try testing.expect(!s.add(textItem("x", "keepassxc.exe"), 1));
    try testing.expect(!s.add(.{ .kind = .text, .text = "hunter2", .concealed = true }, 1));
    try testing.expect(!s.add(textItem("", ""), 1));
    try testing.expect(!s.add(textItem(" \n\t", ""), 1));
    try testing.expect(!s.add(.{ .kind = .image }, 1));
    const big = try testing.allocator.alloc(u8, Kind.image.cap() + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expect(!s.add(.{ .kind = .text, .text = big[0 .. Kind.text.cap() + 1] }, 1));
    try testing.expect(!s.add(.{ .kind = .image, .png = big }, 1));
    try testing.expectEqual(@as(usize, 0), s.len());
    try testing.expectEqual(@as(u32, 0), s.gen);
    // An unknown source is never excluded.
    try testing.expect(s.add(textItem("x", ""), 1));
}

test "pruning by age and by count" {
    const day = std.time.s_per_day;
    const now: i64 = 100 * day;
    var s = memory(.{ .retention_days = 7, .max_entries = 3 });
    defer s.deinit();
    for ([_][]const u8{ "old", "edge", "a", "b", "c" }, [_]i64{
        -8 * day,
        -6 * day,
        -3,
        -2,
        -1,
    }) |t, d| _ = s.add(textItem(t, ""), now + d);
    // Adding past the limit drops the oldest at once.
    try testing.expectEqual(@as(usize, 3), s.len());
    try testing.expectEqualStrings("c", s.at(0).text);
    try testing.expectEqualStrings("a", s.at(2).text);

    var t = memory(.{ .retention_days = 7, .max_entries = 0 });
    defer t.deinit();
    for ([_][]const u8{ "old", "edge", "a" }, [_]i64{
        -8 * day,
        -6 * day,
        -3,
    }) |w, d| _ = t.add(textItem(w, ""), now + d);
    try testing.expectEqual(@as(usize, 1), try t.prune(now));
    try testing.expectEqual(@as(usize, 0), try t.prune(now));
    try testing.expectEqual(@as(usize, 1), try t.prune(now + 2 * day));
    try testing.expectEqualStrings("a", t.at(0).text);
    // 0 days keeps everything.
    t.cfg.retention_days = 0;
    try testing.expectEqual(@as(usize, 0), try t.prune(now + 1000 * day));
}

test "the size budget keeps the newest, up to its boundary" {
    const sized = struct {
        fn of(comptime sizes: []const u64) [sizes.len]Entry {
            var out: [sizes.len]Entry = undefined;
            for (&out, sizes) |*e, n|
                e.* = .{ .hash = n, .kind = .text, .text = "", .size = n, .at = 0 };
            return out;
        }
    };
    // Newest first: 1, 2, 4, 4 bytes.
    const list = sized.of(&.{ 1, 2, 4, 4 });
    // Exactly the budget: all stay.
    try testing.expectEqual(@as(usize, 4), keepCount(&list, 11, 0));
    // One byte under: the oldest goes, the newest stays.
    try testing.expectEqual(@as(usize, 3), keepCount(&list, 10, 0));
    try testing.expectEqual(@as(usize, 2), keepCount(&list, 3, 0));
    // The count limit too, whichever cuts more.
    try testing.expectEqual(@as(usize, 1), keepCount(&list, 100, 1));
    try testing.expectEqual(@as(usize, 0), keepCount(&list, 0, 0));
    try testing.expectEqual(@as(usize, 0), keepCount(&.{}, 0, 0));
}

test "search matches text, file names and the source app, best first" {
    var s = memory(.{});
    defer s.deinit();
    _ = s.add(textItem("remember the milk", "com.apple.Notes"), 1);
    _ = s.add(textItem("milkshake recipe", "com.apple.Safari"), 2);
    _ = s.add(
        .{
            .kind = .file,
            .text = "/Users/me/Documents/budget.xlsx\n/Users/me/a.txt",
            .source = "com.apple.finder",
        },
        3,
    );
    _ = s.add(
        .{ .kind = .image, .png = "x", .width = 4, .height = 4, .source = "com.apple.Preview" },
        4,
    );
    var out: [8]search.Ranked = undefined;
    // No query: all, newest first.
    try testing.expectEqual(@as(usize, 4), s.find("", &out));
    try testing.expectEqual(@as(u32, 0), out[0].index);
    // A prefix beats a match inside.
    try testing.expectEqual(@as(usize, 2), s.find("milk", &out));
    try testing.expectEqualStrings("milkshake recipe", s.at(out[0].index).text);
    try testing.expectEqualStrings("remember the milk", s.at(out[1].index).text);
    // A file's name, not its directory prefix path alone.
    try testing.expectEqual(@as(usize, 1), s.find("budget", &out));
    try testing.expectEqual(Kind.file, s.at(out[0].index).kind);
    // The source app, for every kind.
    try testing.expectEqual(@as(usize, 1), s.find("preview", &out));
    try testing.expectEqual(Kind.image, s.at(out[0].index).kind);
    try testing.expectEqual(@as(usize, 0), s.find("zzzzqq", &out));
    // Room for only some.
    var one: [1]search.Ranked = undefined;
    try testing.expectEqual(@as(usize, 1), s.find("", &one));
}

test "a long text goes to a blob and comes back whole; an image keeps its PNG" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    var long: [inline_max + 1]u8 = undefined;
    for (&long, 0..) |*c, i| c.* = "0123456789abcdef"[i % 16];
    try testing.expect(s.add(textItem(&long, ""), 1));
    const png = "\x89PNGdata";
    try testing.expect(s.add(.{ .kind = .image, .png = png, .width = 2, .height = 3 }, 2));
    // The index holds the start only, the blob the rest.
    const e = s.get(hash(.text, &long)).?.*;
    try testing.expectEqual(@as(u64, long.len), e.size);
    try testing.expectEqual(@as(usize, preview_max), e.text.len);
    const whole = try s.read(testing.allocator, e);
    defer testing.allocator.free(whole.owned.?);
    try testing.expectEqualStrings(&long, whole.content.text);
    const img = s.get(hash(.image, "\x89PNGdata")).?.*;
    const bytes = try s.read(testing.allocator, img);
    defer testing.allocator.free(bytes.owned.?);
    try testing.expectEqualStrings("\x89PNGdata", bytes.content.png);
    try testing.expectEqual(@as(u32, 3), img.height);
    // A short text and a file list are all in the index.
    _ = s.add(.{ .kind = .file, .text = "/a/b" }, 3);
    const files = try s.read(testing.allocator, s.at(0));
    try testing.expect(files.owned == null);
    try testing.expectEqualStrings("/a/b", files.content.text);
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
    // A blob that is gone is an error, not an empty entry.
    try tmp.dir.deleteTree(testing.io, "blobs");
    try testing.expectError(error.FileNotFound, s.read(testing.allocator, e));
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
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/00000000000000ff.png", .data = "orphan" },
    );
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.load(40);
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expectEqualStrings("first", s.at(0).text);
    try testing.expectEqual(@as(u32, 2), s.at(0).count);
    try testing.expectEqualStrings("a.b.App", s.at(0).source);
    try testing.expectEqual(Kind.image, s.at(1).kind);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "blobs/00000000000000ff.png", .{}),
    );
    const bytes = try s.read(testing.allocator, s.at(1));
    defer testing.allocator.free(bytes.owned.?);
    try testing.expectEqualStrings("png1", bytes.content.png);
}

test "an index too big for the budget is cut on load, oldest first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Three entries of 100 MiB each (their size, not their bytes): the budget keeps two.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "index.json",
        .data =
        \\{"v":1,"entries":[
        \\{"hash":"01","kind":"file","text":"/old","size":104857600,"at":1},
        \\{"hash":"02","kind":"file","text":"/mid","size":104857600,"at":2},
        \\{"hash":"03","kind":"file","text":"/new","size":104857600,"at":3}]}
        ,
    });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{ .retention_days = 0 });
    defer s.deinit();
    s.load(10);
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expectEqualStrings("/mid", s.at(1).text);
}

test "an index the old version wrote still loads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/00000000000000bb.png", .data = "png bytes" },
    );
    // Written by the store before the format was versioned on read: every field, v 1.
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "index.json",
        .data =
        \\{"v":1,"entries":[{"hash":"00000000000000aa","kind":"text","text":"hello",
        \\"size":5,"w":0,"h":0,"source":"com.apple.Notes","at":300,"count":2},
        \\{"hash":"00000000000000bb","kind":"image","text":"","size":9,"w":800,"h":600,
        \\"source":"","at":200,"count":1},{"hash":"00000000000000cc","kind":"file",
        \\"text":"/Users/me/a.txt","size":15,"w":0,"h":0,"source":"com.apple.finder",
        \\"at":100,"count":1}]}
        ,
    });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{ .retention_days = 0 });
    defer s.deinit();
    s.load(400);
    try testing.expectEqual(@as(usize, 3), s.len());
    try testing.expectEqualStrings("hello", s.at(0).text);
    try testing.expectEqual(@as(u32, 2), s.at(0).count);
    try testing.expectEqualStrings("com.apple.Notes", s.at(0).source);
    try testing.expectEqual(Kind.image, s.at(1).kind);
    try testing.expectEqual(@as(u32, 600), s.at(1).height);
    const img = try s.read(testing.allocator, s.at(1));
    defer testing.allocator.free(img.owned.?);
    try testing.expectEqualStrings("png bytes", img.content.png);
    try testing.expectEqualStrings("/Users/me/a.txt", s.at(2).text);
}

test "an entry that does not read is skipped, and the rest are kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/000000000000000b.png", .data = "only the bad entry's" },
    );
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "index.json",
        .data =
        \\{"v":1,"entries":[{"hash":"zz","kind":"text","text":"bad hash"},
        \\{"hash":"0b","kind":"sound","size":3,"at":7},
        \\{"hash":"0c","kind":"text","text":7},
        \\"not an entry",
        \\{"hash":"0a","kind":"text","text":"y","at":5,"size":1},
        \\{"hash":"0d","kind":"file","text":"/z","at":6,"size":2,"later":"field"}]}
        ,
    });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{ .retention_days = 0 });
    defer s.deinit();
    s.load(10);
    try testing.expectEqual(@as(usize, 2), s.len());
    try testing.expectEqualStrings("/z", s.at(0).text);
    try testing.expectEqualStrings("y", s.at(1).text);
    // The skipped entry's blob is nobody's now.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "blobs/000000000000000b.png", .{}),
    );
}

test "an index of another version starts empty and is left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/0000000000000001.png", .data = "keep" },
    );
    const later = "{\"v\":2,\"entries\":[{\"hash\":\"01\",\"kind\":\"image\",\"size\":4}]}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.json", .data = later });
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.load(1);
    try testing.expectEqual(@as(usize, 0), s.len());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(later, try tmp.dir.readFile(testing.io, "index.json", &buf));
    try tmp.dir.access(testing.io, "blobs/0000000000000001.png", .{});
}

test "a corrupt index starts empty, is deleted, and its blobs are left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "blobs");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.json", .data = "{\"entries\": [oops" });
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/0000000000000001.png", .data = "keep" },
    );
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    s.load(1);
    try testing.expectEqual(@as(usize, 0), s.len());
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "index.json", .{}));
    try tmp.dir.access(testing.io, "blobs/0000000000000001.png", .{});
    // And it works from there.
    try testing.expect(s.add(textItem("fresh", ""), 2));
    try tmp.dir.access(testing.io, "index.json", .{});
}

test "clear forgets everything, blobs too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    _ = s.add(textItem("a", ""), 1);
    _ = s.add(.{ .kind = .image, .png = "p", .width = 1, .height = 1 }, 2);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "index.json.corrupt", .data = "secret" });
    try tmp.dir.writeFile(
        testing.io,
        .{ .sub_path = "blobs/0000000000000009.png.tmp", .data = "x" },
    );
    try s.clear();
    try testing.expectEqual(@as(usize, 0), s.len());
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(testing.io, "index.json.corrupt", .{}),
    );
    var blobs = try tmp.dir.openDir(testing.io, "blobs", .{ .iterate = true });
    defer blobs.close(testing.io);
    var it = blobs.iterate();
    try testing.expect((try it.next(testing.io)) == null);
    var again: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer again.deinit();
    again.load(3);
    try testing.expectEqual(@as(usize, 0), again.len());
}

test "clear that cannot write the index deletes it, and one that leaves a file says so" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    _ = s.add(textItem("secret", ""), 1);
    try tmp.dir.access(testing.io, "index.json", .{});
    // A directory where the temp index goes: every write of index.json fails.
    try tmp.dir.createDirPath(testing.io, "index.json.tmp");
    try s.clear();
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "index.json", .{}));
    // A prune that cannot write the index says so.
    _ = s.add(textItem("again", ""), 2);
    try testing.expect(if (s.prune(100 * std.time.s_per_day)) |_| false else |_| true);
    // Something in blobs/ that cannot be deleted: memory is cleared, the caller told.
    try tmp.dir.createDirPath(testing.io, "blobs/0000000000000001.png/x");
    try testing.expectError(error.Incomplete, s.clear());
    try testing.expectEqual(@as(usize, 0), s.len());
}

test "store files are user-only" {
    if (!@hasDecl(Perm, "fromMode")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s: Store = .init(testing.allocator, testing.io, tmp.dir, .{});
    defer s.deinit();
    _ = s.add(.{ .kind = .image, .png = "p", .width = 1, .height = 1 }, 1);
    for ([_][]const u8{ "index.json", "blobs" }) |name| {
        const st = try tmp.dir.statFile(testing.io, name, .{});
        try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(st.permissions.toMode())) & 0o077);
    }
    var it = try tmp.dir.openDir(testing.io, "blobs", .{ .iterate = true });
    defer it.close(testing.io);
    var walk = it.iterate();
    const f = (try walk.next(testing.io)).?;
    const st = try it.statFile(testing.io, f.name, .{});
    try testing.expectEqual(@as(u32, 0), @as(u32, @intCast(st.permissions.toMode())) & 0o077);
}

test "a PNG's header gives its size" {
    const hdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x03\x20\x00\x00\x02\x58";
    try testing.expectEqual([2]u32{ 800, 600 }, pngSize(hdr).?);
    try testing.expect(pngSize("not a png at all, really not") == null);
}

test "every OS's watcher has the same surface" {
    comptime {
        conforms(@import("clipboard_mac.zig").Watcher);
        conforms(@import("clipboard_win.zig").Watcher);
        conforms(@import("clipboard_linux.zig").Watcher);
    }
}
