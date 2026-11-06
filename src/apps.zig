//! The apps Nanolight finds: on the Mac every `.app` in the usual folders
//! (and one folder down, for Utilities and suites), named without `.app`;
//! on Linux the desktop entries (apps_linux.zig), on Windows the Start
//! menu's shortcuts (apps_win.zig). Sorted and without duplicates. How
//! often each was opened is kept in the app's defaults and lifts it in the
//! ranking. Icons are asked of the system only for the rows on screen, and
//! kept.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const prefs = @import("prefs.zig");
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;
const assert = std.debug.assert;

pub const App = struct {
    name: []const u8,
    path: []const u8,
    /// The folder it is in, as the row shows it: "Applications", "Utilities".
    folder: []const u8,
    /// Mandarin reading as ASCII (scan time), for Latin queries.
    pinyin: []const u8 = "",
    /// Times it was opened (kept in prefs' `.launches`).
    launches: u16 = 0,
    /// Its icon, asked of the system the first time a row shows it.
    icon: Icon = .unloaded,
};

/// An app's icon: not asked for yet, asked for with no answer, or a PNG
/// (the index's gpa owns it).
pub const Icon = union(enum) { unloaded, none, png: []u8 };

/// Where apps are, in the order a name is first taken from.
pub const roots = [_][]const u8{
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices/Applications",
};

/// Shown with an empty query before anything was opened.
pub const default_starters: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "Safari", "Notes", "Calendar", "System Settings", "Finder" },
    .windows => &.{ "File Explorer", "Microsoft Edge", "Settings", "Notepad", "Calculator" },
    else => &.{ "Files", "Firefox", "Terminal", "Settings", "Text Editor" },
};

/// Finds this machine's apps.
pub fn scanSystem(ix: *Index, io: std.Io, env: *const std.process.Environ.Map) void {
    switch (builtin.os.tag) {
        .macos => return ix.scan(io, env.get("HOME")),
        .windows => @import("apps_win.zig").scan(ix, io, env),
        else => @import("apps_linux.zig").scan(ix, io),
    }
    ix.sort();
}

/// Apps in the folders config.toml names, found as this OS finds its own.
pub fn scanExtra(ix: *Index, io: std.Io, dirs: []const []const u8) void {
    for (dirs) |d| switch (builtin.os.tag) {
        .macos => ix.scanDir(io, d, 1),
        .windows => @import("apps_win.zig").scanDir(ix, io, d, 1),
        else => @import("apps_linux.zig").scanDir(ix, io, d, 1),
    };
}

/// An address for the browser or the system (a pane of System Settings),
/// not a file to open.
pub fn isUrl(target: []const u8) bool {
    for ([_][]const u8{
        "https://",
        "http://",
        @import("settings_panes.zig").url_prefix,
    }) |p| if (std.mem.startsWith(u8, target, p)) return true;
    return false;
}

/// Opens an app found by `scanSystem` (or a file, a folder).
pub fn launch(io: std.Io, path: []const u8) bool {
    if (builtin.os.tag == .linux and
        std.mem.endsWith(u8, path, ".desktop")) return @import("apps_linux.zig").launch(io, path);
    if (mac and std.mem.endsWith(u8, path, ".app")) {
        openApp(path);
        return true;
    }
    return nanoui.shell.openPath(path);
}

/// A scan looks at most this many folders below the one it is given.
pub const max_scan_depth = 2;
/// Longer paths are passed over.
const max_scan_path = 1024;

/// What a scan does after an entry `walk` found: on to the next, into it
/// (a folder, if the depth allows), or no further at all.
pub const Step = enum { next, descend, stop };

/// An entry `walk` found: `entry` in the open folder `dir`, whose path is
/// `folder`; `full` is the entry's own path.
pub const Found = struct {
    dir: std.Io.Dir,
    folder: []const u8,
    full: []const u8,
    entry: std.Io.Dir.Entry,
};

/// Hands `visit` everything in `root`, and in each folder it descends into
/// up to `depth` below, depth first in the order they are listed. Each open
/// folder is a frame on a fixed stack, not a call; one that cannot be
/// opened is passed over.
pub fn walk(
    io: std.Io,
    root: []const u8,
    depth: u8,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), Found) Step,
) void {
    assert(depth <= max_scan_depth);
    const Frame = struct {
        dir: std.Io.Dir,
        it: std.Io.Dir.Iterator,
        path: [max_scan_path]u8,
        len: usize,
        depth: u8,
    };
    var stack: [max_scan_depth + 1]Frame = undefined;
    if (root.len > max_scan_path) return;
    const first = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    stack[0] = .{
        .dir = first,
        .it = first.iterate(),
        .path = undefined,
        .len = root.len,
        .depth = depth,
    };
    @memcpy(stack[0].path[0..root.len], root);
    var n: usize = 1;
    defer for (stack[0..n]) |*f| f.dir.close(io);
    while (n > 0) {
        const top = &stack[n - 1];
        const e = (top.it.next(io) catch null) orelse {
            top.dir.close(io);
            n -= 1;
            continue;
        };
        const folder = top.path[0..top.len];
        var buf: [max_scan_path]u8 = undefined;
        const parts = .{ folder, std.fs.path.sep, e.name };
        const full = std.fmt.bufPrint(&buf, "{s}{c}{s}", parts) catch continue;
        switch (visit(ctx, .{ .dir = top.dir, .folder = folder, .full = full, .entry = e })) {
            .next => {},
            .stop => return,
            .descend => {
                if (top.depth == 0 or e.kind != .directory) continue;
                const sub = top.dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
                assert(n < stack.len);
                stack[n] = .{
                    .dir = sub,
                    .it = sub.iterate(),
                    .path = undefined,
                    .len = full.len,
                    .depth = top.depth - 1,
                };
                @memcpy(stack[n].path[0..full.len], full);
                n += 1;
            },
        }
    }
}

pub const Index = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    apps: std.ArrayList(App) = .empty,
    /// Counts in the store for apps this scan did not find (a volume not
    /// mounted, say): written back with the rest, so they are not lost.
    missed: std.ArrayList(Launch) = .empty,
    /// Listed with an empty query before anything was opened.
    starters: []const []const u8 = default_starters,

    pub fn init(gpa: std.mem.Allocator) Index {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ix: *Index) void {
        for (ix.apps.items) |a| switch (a.icon) {
            .png => |png| ix.gpa.free(png),
            .unloaded, .none => {},
        };
        ix.apps.deinit(ix.gpa);
        ix.missed.deinit(ix.gpa);
        ix.arena.deinit();
    }

    /// Adds an app unless one of its name is there already, its folder
    /// the one it is in.
    pub fn add(ix: *Index, name: []const u8, path: []const u8) !void {
        return ix.addIn(name, path, std.fs.path.basename(std.fs.path.dirname(path) orelse ""));
    }

    /// Adds an app, its row saying `folder` ("Applications", "Start").
    pub fn addIn(ix: *Index, name: []const u8, path: []const u8, folder: []const u8) !void {
        if (ix.find(name) != null) return;
        const a = ix.arena.allocator();
        try ix.apps.append(ix.gpa, .{
            .name = try a.dupe(u8, name),
            .path = try a.dupe(u8, path),
            .folder = try a.dupe(u8, folder),
        });
    }

    /// Finds the apps on this machine; `home` adds ~/Applications.
    pub fn scan(ix: *Index, io: std.Io, home: ?[]const u8) void {
        for (roots) |r| ix.scanDir(io, r, 1);
        // best effort: only memory can fail here, and the other apps still list.
        ix.add("Finder", "/System/Library/CoreServices/Finder.app") catch {};
        if (home) |h| {
            var buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(
                &buf,
                "{s}/Applications",
                .{h},
            )) |p| ix.scanDir(io, p, 1) else |_| {}
        }
        ix.sort();
        ix.localize();
    }

    /// Localized display names and pinyin keys for search (macOS only).
    pub fn localize(ix: *Index) void {
        if (!mac) return;
        const text = @import("text.zig");
        const a = ix.arena.allocator();
        for (ix.apps.items) |*app| {
            if (!wantsLocalizedDisplayName(app.path)) continue;
            if (displayNameInto(a, app.path)) |display_name| {
                const loc = withoutAppSuffix(display_name);
                if (loc.len > 0 and !std.ascii.eqlIgnoreCase(loc, app.name)) app.name = loc;
            }
            if (text.hasCjk(app.name)) app.pinyin = pinyinKey(a, app.name) orelse "";
        }
        ix.sort();
    }

    fn scanDir(ix: *Index, io: std.Io, dir_path: []const u8, depth: u8) void {
        walk(io, dir_path, depth, ix, visitBundle);
    }

    fn visitBundle(ix: *Index, f: Found) Step {
        const name = f.entry.name;
        if (name.len == 0 or name[0] == '.') return .next;
        if (!std.mem.endsWith(u8, name, ".app")) return .descend;
        ix.add(name[0 .. name.len - 4], f.full) catch return .stop;
        return .next;
    }

    /// Alphabetical, case-insensitive; each app's count and icon go with it.
    pub fn sort(ix: *Index) void {
        const Ctx = struct {
            pub fn lessThan(_: @This(), a: App, b: App) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        };
        std.sort.pdq(App, ix.apps.items, Ctx{}, Ctx.lessThan);
    }

    /// Whether `other` lists the same apps and commands, at the same
    /// paths: a rescan that found nothing new (script_live.zig `refresh`).
    pub fn same(ix: *const Index, other: *const Index) bool {
        if (ix.apps.items.len != other.apps.items.len) return false;
        for (ix.apps.items, other.apps.items) |a, b| {
            if (!std.mem.eql(u8, a.path, b.path) or !std.mem.eql(u8, a.name, b.name)) return false;
        }
        return true;
    }

    pub fn find(ix: *const Index, name: []const u8) ?u32 {
        for (ix.apps.items, 0..) |a, i| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return @intCast(i);
        }
        return null;
    }

    pub fn findPath(ix: *const Index, path: []const u8) ?u32 {
        for (ix.apps.items, 0..) |a, i| if (std.mem.eql(u8, a.path, path)) return @intCast(i);
        return null;
    }

    /// Up to `out.len` apps for an empty query: the most opened, else a
    /// few every Mac has.
    pub fn suggestions(ix: *const Index, out: []u32) usize {
        var n: usize = 0;
        // Most opened first: a few passes from the highest count down.
        var best: u16 = std.math.maxInt(u16);
        while (n < out.len) {
            var next: u16 = 0;
            for (ix.apps.items) |a| if (a.launches < best and a.launches > next) {
                next = a.launches;
            };
            if (next == 0) break;
            for (ix.apps.items, 0..) |a, i| if (a.launches == next and n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            };
            best = next;
        }
        for (ix.starters) |s| {
            if (n == out.len) break;
            const i = ix.find(s) orelse continue;
            if (std.mem.indexOfScalar(u32, out[0..n], i) == null) {
                out[n] = i;
                n += 1;
            }
        }
        return n;
    }

    /// Counts an opening, and keeps the counts in `store`.
    pub fn opened(ix: *Index, i: u32, store: ?nanoui.kv.Store) void {
        ix.apps.items[i].launches +|= 1;
        if (store) |kv| ix.save(kv);
    }

    /// Keeps every count in `kv` (as `opened` does, and a sync after it):
    /// the apps' and those `missed`, the `max_launches` most opened.
    pub fn save(ix: *Index, kv: nanoui.kv.Store) void {
        var list: std.ArrayList(Launch) = .empty;
        defer list.deinit(ix.gpa);
        // best effort: out of memory leaves the stored counts as they were.
        list.ensureTotalCapacity(ix.gpa, ix.apps.items.len + ix.missed.items.len) catch return;
        for (ix.apps.items) |a| if (a.launches > 0) {
            list.appendAssumeCapacity(.{ .key = a.path, .count = a.launches });
        };
        list.appendSliceAssumeCapacity(ix.missed.items);
        const kept = mostOpened(list.items);
        var aw: std.Io.Writer.Allocating = .init(ix.gpa);
        defer aw.deinit();
        // best effort: out of memory leaves the stored counts as they were.
        for (kept) |l| aw.writer.print("{s}\t{d}\n", .{ l.key, l.count }) catch return;
        // A failure is logged; the counts in memory stand for this run.
        _ = prefs.setText(kv, .launches, aw.written());
    }

    /// The counts `opened` kept. Keys are app paths; older rows used
    /// display names and are still read once. Rows for apps not found
    /// are kept in `missed`, at most `max_launches` of them.
    pub fn load(ix: *Index, store: nanoui.kv.Store) void {
        ix.missed.clearRetainingCapacity();
        const v = prefs.text(store, ix.gpa, .launches) orelse return;
        defer ix.gpa.free(v);
        var lines = std.mem.splitScalar(u8, v, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const key = line[0..tab];
            const count = std.fmt.parseInt(u16, line[tab + 1 ..], 10) catch 0;
            if (resolveLaunchKey(ix, key)) |i| {
                ix.apps.items[i].launches = count;
                continue;
            }
            if (count > 0) ix.keepMissed(key, count);
        }
        assert(ix.missed.items.len <= max_launches);
    }

    /// Keeps a stored count no app here has; once `max_launches` are kept,
    /// only in place of the least opened, if it beats it.
    fn keepMissed(ix: *Index, key: []const u8, count: u16) void {
        var slot: ?usize = null;
        if (ix.missed.items.len == max_launches) {
            var least: usize = 0;
            for (ix.missed.items, 0..) |l, i| if (l.count < ix.missed.items[least].count) {
                least = i;
            };
            if (ix.missed.items[least].count >= count) return;
            slot = least;
        }
        // best effort: a count not kept now is one fewer remembered.
        const owned = ix.arena.allocator().dupe(u8, key) catch return;
        if (slot) |i| {
            ix.missed.items[i] = .{ .key = owned, .count = count };
        } else {
            // best effort: as above.
            ix.missed.append(ix.gpa, .{ .key = owned, .count = count }) catch return;
        }
    }

    /// The app's icon as PNG, made the first time it is asked for.
    pub fn icon(ix: *Index, i: u32) ?[]const u8 {
        const app = &ix.apps.items[i];
        switch (app.icon) {
            .png => |png| return png,
            .none => return null,
            .unloaded => {},
        }
        const png = png: switch (builtin.os.tag) {
            .macos => iconPng(ix.gpa, app.path),
            .windows => @import("apps_win.zig").icon(ix.gpa, app.path),
            else => {
                const io = std.Io.Threaded.global_single_threaded.io();
                break :png @import("apps_linux.zig").icon(ix.gpa, io, app.path);
            },
        };
        app.icon = if (png) |p| .{ .png = p } else .none;
        return png;
    }
};

/// At most this many launch counts are stored: the most opened (the same
/// cap as a synced record's).
pub const max_launches = @import("settings.zig").max_launches;

/// A stored launch count: an app's path (or, in older rows, its name).
pub const Launch = struct { key: []const u8, count: u16 };

/// `list` sorted most opened first (ties by key, the same every run), cut
/// to `max_launches`.
fn mostOpened(list: []Launch) []const Launch {
    std.sort.pdq(Launch, list, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.f);
    return list[0..@min(list.len, max_launches)];
}

fn resolveLaunchKey(ix: *const Index, key: []const u8) ?u32 {
    if (ix.findPath(key)) |i| return i;
    return ix.find(key);
}

/// Opens the Mac app at `path` without waiting for it: LaunchServices
/// answers when the app has started, which can take seconds (an app
/// reinstalled while Nanolight ran, issue #7), and `openURL:` waited on
/// the main thread meanwhile, with the panel frozen in front.
fn openApp(path: []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(
        objc.Object,
        objc.class("NSURL"),
        "fileURLWithPath:",
        .{objc.nsString(path)},
    );
    const config = objc.msg(
        objc.Object,
        objc.class("NSWorkspaceOpenConfiguration"),
        "configuration",
        .{},
    );
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    objc.msg(
        void,
        ws,
        "openApplicationAtURL:configuration:completionHandler:",
        .{ url, config, @as(?*anyopaque, null) },
    );
}

fn wantsLocalizedDisplayName(path: []const u8) bool {
    if (std.mem.indexOf(u8, path, "zig-cache") != null) return false;
    for (roots) |r| if (std.mem.startsWith(u8, path, r)) return true;
    return std.mem.indexOf(u8, path, "/Applications/") != null;
}

/// Finder can include the bundle extension in its localized display name.
fn withoutAppSuffix(name: []const u8) []const u8 {
    const suffix = ".app";
    if (name.len >= suffix.len and
        std.ascii.eqlIgnoreCase(
            name[name.len - suffix.len ..],
            suffix,
        )) return name[0 .. name.len - suffix.len];
    return name;
}

/// The Finder's icon for `path`, drawn at 64 pixels and encoded as PNG.
fn displayNameInto(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    const ns = objc.msg(objc.Object, fm, "displayNameAtPath:", .{objc.nsString(path)});
    const utf8 = objc.msg(?[*]const u8, ns, "UTF8String", .{}) orelse return null;
    return a.dupe(u8, std.mem.sliceTo(utf8, 0)) catch null;
}

fn pinyinKey(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns = objc.nsString(name);
    const step1 = objc.msg(
        objc.Object,
        ns,
        "stringByApplyingTransform:reverse:",
        .{ objc.nsString("Mandarin-Latin"), objc.NO },
    );
    const step2 = objc.msg(
        objc.Object,
        step1,
        "stringByApplyingTransform:reverse:",
        .{ objc.nsString("Latin-ASCII"), objc.NO },
    );
    const latin = objc.msg(?[*]const u8, step2, "UTF8String", .{}) orelse return null;
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (std.mem.sliceTo(latin, 0)) |ch| {
        if (ch == ' ' or ch == '\'') continue;
        if (n == buf.len) break;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    if (n == 0) return null;
    return a.dupe(u8, buf[0..n]) catch null;
}

pub fn iconPng(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = objc.msg(objc.Object, ws, "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = 64, .height = 64 } };
    const cg = objc.msg(
        ?*anyopaque,
        img,
        "CGImageForProposedRect:context:hints:",
        .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) },
    ) orelse
        return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const data = objc.msg(
        ?objc.Object,
        rep,
        "representationUsingType:properties:",
        .{ @as(objc.NSUInteger, 4), props },
    ) orelse
        return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}

test "localized Mac names omit the app suffix" {
    const t = std.testing;
    try t.expectEqualStrings("Safari", withoutAppSuffix("Safari.app"));
    try t.expectEqualStrings("微信", withoutAppSuffix("微信.APP"));
    try t.expectEqualStrings("My.App", withoutAppSuffix("My.App.aPp"));
    try t.expectEqualStrings("App", withoutAppSuffix("App"));
    try t.expectEqualStrings("App.app helper", withoutAppSuffix("App.app helper"));
    try t.expectEqualStrings("", withoutAppSuffix(""));
    try t.expectEqualStrings("", withoutAppSuffix(".app"));
}

test "names are kept once, sorted, and opening one suggests it" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    ix.starters = &.{ "Safari", "Notes", "Calendar" };
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("notes", "/System/Applications/Notes.app");
    try ix.add("Notes", "/Applications/Notes.app");
    try ix.add("Calculator", "/System/Applications/Calculator.app");
    ix.sort();
    try t.expectEqual(@as(usize, 3), ix.apps.items.len);
    try t.expectEqualStrings("Calculator", ix.apps.items[0].name);
    try t.expectEqualStrings("Applications", ix.apps.items[0].folder);
    var out: [3]u32 = undefined;
    // Nothing opened yet: the starters there are.
    try t.expectEqual(@as(usize, 2), ix.suggestions(&out));
    try t.expectEqualStrings("Safari", ix.apps.items[out[0]].name);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.opened(0, mem.store());
    ix.opened(0, mem.store());
    try t.expectEqual(@as(usize, 3), ix.suggestions(&out));
    try t.expectEqualStrings("Calculator", ix.apps.items[out[0]].name);
    // Kept, and read back.
    ix.apps.items[0].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[0].launches);
}

test "a count and an icon stay with their app through a sort" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Mail", "/Applications/Mail.app");
    try ix.add("Zed", "/Applications/Zed.app");
    const zed_was = ix.find("Zed").?;
    ix.opened(zed_was, null);
    ix.apps.items[zed_was].icon = .{ .png = try t.allocator.dupe(u8, "zed") };
    // A name read later (localize) sorts again, after the count: Mail moves.
    ix.apps.items[ix.find("Mail").?].name = "Ångström";
    ix.sort();
    const zed = ix.findPath("/Applications/Zed.app").?;
    try t.expect(zed != zed_was);
    try t.expectEqual(@as(u16, 1), ix.apps.items[zed].launches);
    try t.expectEqualStrings("zed", ix.icon(zed).?);
    const mail = ix.findPath("/Applications/Mail.app").?;
    try t.expectEqual(@as(u16, 0), ix.apps.items[mail].launches);
    try t.expect(ix.apps.items[mail].icon == .unloaded);
}

test "counts outlive a scan that missed their app" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    {
        var ix: Index = .init(t.allocator);
        defer ix.deinit();
        try ix.add("Safari", "/Applications/Safari.app");
        try ix.add("Logic", "/Volumes/Studio/Logic.app");
        ix.opened(ix.find("Logic").?, null);
        ix.opened(ix.find("Logic").?, null);
        ix.opened(ix.find("Safari").?, mem.store());
    }
    {
        // The volume is not mounted: Safari opened again keeps Logic's count.
        var ix: Index = .init(t.allocator);
        defer ix.deinit();
        try ix.add("Safari", "/Applications/Safari.app");
        ix.load(mem.store());
        ix.opened(ix.find("Safari").?, mem.store());
    }
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    try ix.add("Logic", "/Volumes/Studio/Logic.app");
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[ix.find("Logic").?].launches);
    try t.expectEqual(@as(u16, 2), ix.apps.items[ix.find("Safari").?].launches);
    try t.expectEqual(@as(usize, 0), ix.missed.items.len);
}

test "past the cap, the least opened counts are dropped" {
    const t = std.testing;
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    // More stored than kept, least opened first (an order `save` never writes).
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    for (0..max_launches + 10) |i| try aw.writer.print("/gone/{d}.app\t{d}\n", .{ i, i + 1 });
    try mem.store().set(prefs.Key.launches.name(), aw.written());
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    ix.load(mem.store());
    try t.expectEqual(@as(usize, max_launches), ix.missed.items.len);
    for (ix.missed.items) |l| try t.expect(l.count > 10);
    // Safari, opened once, is the least opened of all: it is the one left out.
    ix.opened(0, mem.store());
    const v = (try mem.store().get(t.allocator, prefs.Key.launches.name())).?;
    defer t.allocator.free(v);
    try t.expectEqual(@as(usize, max_launches), std.mem.count(u8, v, "\n"));
    try t.expect(std.mem.indexOf(u8, v, "Safari") == null);
    try t.expect(std.mem.startsWith(u8, v, "/gone/521.app\t522\n"));
}

test "a scan looks in folders down to its depth, without recursion" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Top.app");
    try tmp.dir.createDirPath(t.io, "Suite/Inner.app");
    try tmp.dir.createDirPath(t.io, "Suite/Deeper/Deep.app");
    try tmp.dir.createDirPath(t.io, ".hidden/Hidden.app");
    var buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    ix.scanDir(t.io, root, 1);
    try t.expect(ix.find("Top") != null);
    try t.expect(ix.find("Inner") != null);
    try t.expectEqualStrings("Suite", ix.apps.items[ix.find("Inner").?].folder);
    try t.expect(ix.find("Deep") == null);
    try t.expect(ix.find("Hidden") == null);
    var deeper: Index = .init(t.allocator);
    defer deeper.deinit();
    deeper.scanDir(t.io, root, max_scan_depth);
    try t.expect(deeper.find("Deep") != null);
}

test "a second look tells an app installed since from no change (#15)" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Applications/Alpha.app");
    var buf: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    ix.scan(t.io, home);
    var again: Index = .init(t.allocator);
    defer again.deinit();
    again.scan(t.io, home);
    try t.expect(ix.same(&again));
    // DOSBox-X, installed while Nanolight ran.
    try tmp.dir.createDirPath(t.io, "Applications/DOSBox-X.app");
    var later: Index = .init(t.allocator);
    defer later.deinit();
    later.scan(t.io, home);
    try t.expect(!ix.same(&later));
    try t.expect(later.find("DOSBox-X") != null);
}

test "launch counts resolve stored paths on Windows-style keys" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("Explorer", "C:\\Windows\\explorer.exe");
    const i = ix.findPath("C:\\Windows\\explorer.exe").?;
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.apps.items[i].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 1), ix.apps.items[i].launches);
}

test "launch counts follow the app path when the display name changes" {
    const t = std.testing;
    var ix: Index = .init(t.allocator);
    defer ix.deinit();
    try ix.add("WeChat", "/Applications/WeChat.app");
    const i = ix.findPath("/Applications/WeChat.app").?;
    ix.opened(i, null);
    ix.opened(i, null);
    var mem: nanoui.kv.Memory = .{ .gpa = t.allocator };
    defer mem.deinit();
    ix.save(mem.store());
    ix.apps.items[i].name = "微信";
    ix.apps.items[i].launches = 0;
    ix.load(mem.store());
    try t.expectEqual(@as(u16, 2), ix.apps.items[i].launches);
}
