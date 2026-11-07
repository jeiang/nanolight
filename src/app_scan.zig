//! What the app index (apps.zig) and each OS's backend (apps_mac.zig,
//! apps_linux.zig, apps_win.zig) share: the app row, where a scan puts the
//! apps it finds, the folder walk, and the declarations a backend makes.
const std = @import("std");
const assert = std.debug.assert;

pub const App = struct {
    name: []const u8,
    path: []const u8,
    /// The folder it is in, as the row shows it: "Applications", "Utilities".
    folder: []const u8,
    /// Mandarin reading as ASCII (scan time), for Latin queries.
    pinyin: []const u8 = "",
    /// Its icon, asked of the system the first time a row shows it.
    icon: Icon = .unloaded,
};

/// An app's icon: not asked for yet, asked for with no answer, or a PNG
/// (the index's gpa owns it).
pub const Icon = union(enum) { unloaded, none, png: []u8 };

/// What each backend declares, of these types: the apps an empty query
/// lists before anything was opened (names its scan lists), the scan of
/// this machine, the scan of one folder config.toml names, opening a found
/// app (or a file, a folder), and an app's icon as a 64-pixel PNG.
pub fn conforms(comptime Backend: type) void {
    const Env = std.process.Environ.Map;
    _ = @as([]const []const u8, Backend.starters);
    _ = @as(*const fn (Sink, std.Io, *const Env) void, &Backend.scan);
    _ = @as(*const fn (Sink, std.Io, []const u8, u8) void, &Backend.scanDir);
    _ = @as(*const fn (std.Io, []const u8) bool, &Backend.launch);
    _ = @as(
        *const fn (std.mem.Allocator, std.Io, ?*const Env, []const u8) ?[]u8,
        &Backend.icon,
    );
}

/// The index's apps, as a scan adds to them: the first of a name stays.
pub const Sink = struct {
    gpa: std.mem.Allocator,
    /// Owns each app's strings.
    arena: std.mem.Allocator,
    apps: *std.ArrayList(App),
    /// Apps found but not listed: memory ran out.
    lost: *u32,

    /// Lists an app unless one of its name is there already; one memory
    /// leaves out is counted in `lost`.
    pub fn add(s: Sink, name: []const u8, path: []const u8, folder: []const u8) void {
        s.put(name, path, folder) catch {
            s.lost.* += 1;
        };
    }

    /// As `add`, the failure the caller's.
    pub fn put(s: Sink, name: []const u8, path: []const u8, folder: []const u8) !void {
        if (findName(s.apps.items, name) != null) return;
        try s.apps.append(s.gpa, .{
            .name = try s.arena.dupe(u8, name),
            .path = try s.arena.dupe(u8, path),
            .folder = try s.arena.dupe(u8, folder),
        });
    }
};

pub fn findName(apps: []const App, name: []const u8) ?u32 {
    for (apps, 0..) |a, i| {
        if (std.ascii.eqlIgnoreCase(a.name, name)) return @intCast(i);
    }
    return null;
}

/// The folder a row shows for the app at `path`: the one it is in.
pub fn folderOf(path: []const u8) []const u8 {
    return std.fs.path.basename(std.fs.path.dirname(path) orelse "");
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
/// folder is a frame on a fixed stack, not a call. A folder that is not
/// there is passed over; one that cannot be read is logged and passed over.
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
    const first = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| {
        unread(root, err);
        return;
    };
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
        const folder = top.path[0..top.len];
        const next = top.it.next(io) catch |err| fail: {
            unread(folder, err);
            break :fail null;
        };
        const e = next orelse {
            top.dir.close(io);
            n -= 1;
            continue;
        };
        var buf: [max_scan_path]u8 = undefined;
        const parts = .{ folder, std.fs.path.sep, e.name };
        const full = std.fmt.bufPrint(&buf, "{s}{c}{s}", parts) catch continue;
        switch (visit(ctx, .{ .dir = top.dir, .folder = folder, .full = full, .entry = e })) {
            .next => {},
            .stop => return,
            .descend => {
                if (top.depth == 0 or e.kind != .directory) continue;
                const sub = top.dir.openDir(io, e.name, .{ .iterate = true }) catch |err| {
                    unread(full, err);
                    continue;
                };
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

/// A folder a scan could not read, unless it is just not there.
fn unread(path: []const u8, err: anyerror) void {
    if (err == error.FileNotFound or err == error.NotDir) return;
    std.log.warn("nanolight: {s} could not be scanned: {t}", .{ path, err });
}

test "a walk looks in folders down to its depth, without recursion" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "a/b/c");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try @import("test_tmp.zig").path(&buf, &tmp);
    const Seen = struct {
        names: [4][]const u8 = undefined,
        n: usize = 0,
        fn visit(s: *@This(), f: Found) Step {
            s.names[s.n] = std.fs.path.basename(f.full);
            s.n += 1;
            return .descend;
        }
    };
    var one: Seen = .{};
    walk(t.io, root, 1, &one, Seen.visit);
    try t.expectEqual(@as(usize, 2), one.n);
    try t.expectEqualStrings("b", one.names[1]);
    var all: Seen = .{};
    walk(t.io, root, max_scan_depth, &all, Seen.visit);
    try t.expectEqual(@as(usize, 3), all.n);
}
