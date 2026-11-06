//! The Mac: the apps are every `.app` in the usual folders (and one folder
//! down, for Utilities and suites), named without `.app`, then by their
//! localized display name, with a pinyin key for a Chinese one. An app
//! opens through LaunchServices; its icon is the Finder's (icon_mac.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const app_scan = @import("app_scan.zig");
const search = @import("search.zig");
const objc = nanoui.objc;
const Sink = app_scan.Sink;

/// Where apps are, in the order a name is first taken from.
const roots = [_][]const u8{
    "/Applications",
    "/System/Applications",
    "/System/Library/CoreServices/Applications",
};

/// Finder is an app no root holds: it lives in CoreServices, among the
/// system's agents, so it is listed by its path.
const finder = "Finder";
const finder_path = "/System/Library/CoreServices/Finder.app";

pub const starters: []const []const u8 = &.{
    "Safari",
    "Notes",
    "Calendar",
    "System Settings",
    finder,
};

/// The roots' apps, Finder, and those in ~/Applications.
pub fn scan(sink: Sink, io: std.Io, env: *const std.process.Environ.Map) void {
    const first = sink.apps.items.len;
    for (roots) |r| scanDir(sink, io, r, 1);
    sink.add(finder, finder_path, app_scan.folderOf(finder_path));
    if (env.get("HOME")) |h| {
        var buf: [512]u8 = undefined;
        // A home past 512 bytes has no ~/Applications looked in.
        if (std.fmt.bufPrint(&buf, "{s}/Applications", .{h})) |p| {
            scanDir(sink, io, p, 1);
        } else |_| {}
    }
    localize(sink, first);
}

pub fn scanDir(sink: Sink, io: std.Io, dir_path: []const u8, depth: u8) void {
    app_scan.walk(io, dir_path, depth, sink, visitBundle);
}

fn visitBundle(sink: Sink, f: app_scan.Found) app_scan.Step {
    const name = f.entry.name;
    if (name.len == 0 or name[0] == '.') return .next;
    if (!std.mem.endsWith(u8, name, ".app")) return .descend;
    sink.add(name[0 .. name.len - 4], f.full, app_scan.folderOf(f.full));
    return .next;
}

/// The apps from `first` on, by their localized display names, with pinyin
/// keys for search.
fn localize(sink: Sink, first: usize) void {
    for (sink.apps.items[first..]) |*app| {
        if (!wantsLocalizedDisplayName(app.path)) continue;
        if (displayNameInto(sink.arena, app.path)) |display_name| {
            const loc = withoutAppSuffix(display_name);
            if (loc.len > 0 and !std.ascii.eqlIgnoreCase(loc, app.name)) app.name = loc;
        }
        if (search.hasCjk(app.name)) app.pinyin = pinyinKey(sink.arena, app.name) orelse "";
    }
}

/// Opens an app (a `.app`) without waiting for it, else a file or folder.
pub fn launch(io: std.Io, path: []const u8) bool {
    _ = io;
    if (!std.mem.endsWith(u8, path, ".app")) return nanoui.shell.openPath(path);
    openApp(path);
    return true;
}

pub fn icon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: ?*const std.process.Environ.Map,
    path: []const u8,
) ?[]u8 {
    _ = io;
    _ = env;
    return @import("icon_mac.zig").png(gpa, path);
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

/// The name the Finder shows for `path`, in this Mac's language.
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

test "a scan finds bundles down to its depth, hidden folders passed over" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "Top.app");
    try tmp.dir.createDirPath(t.io, "Suite/Inner.app");
    try tmp.dir.createDirPath(t.io, "Suite/Deeper/Deep.app");
    try tmp.dir.createDirPath(t.io, ".hidden/Hidden.app");
    var buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for ([_]u8{ 1, app_scan.max_scan_depth }) |depth| {
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        var apps: std.ArrayList(app_scan.App) = .empty;
        defer apps.deinit(t.allocator);
        var lost: u32 = 0;
        const sink: Sink = .{
            .gpa = t.allocator,
            .arena = arena.allocator(),
            .apps = &apps,
            .lost = &lost,
        };
        scanDir(sink, t.io, root, depth);
        try t.expect(app_scan.findName(apps.items, "Top") != null);
        const inner = app_scan.findName(apps.items, "Inner").?;
        try t.expectEqualStrings("Suite", apps.items[inner].folder);
        try t.expectEqual(depth > 1, app_scan.findName(apps.items, "Deep") != null);
        try t.expect(app_scan.findName(apps.items, "Hidden") == null);
        try t.expectEqual(@as(u32, 0), lost);
    }
}
