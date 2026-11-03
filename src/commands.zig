//! System commands (sleep, lock, volume, dark mode), built in and found like
//! apps. Each OS has its own table of fixed argument lists (nothing a user
//! types reaches them, and no shell runs them); a command whose program is
//! not on the PATH is never listed, which is looked at once at startup.
//! A failure's message goes in the panel's footer.
//!
//! Windows has no volume commands: Windows offers none without a third-party
//! tool or an audio API. Its Sleep hibernates instead when hibernation is on
//! (`SetSuspendState`'s documented behavior).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const search = @import("search.zig");
const windows = builtin.os.tag == .windows;

pub const Command = struct {
    name: []const u8,
    /// Other words for it, matched a little lower than its name.
    keywords: []const []const u8 = &.{},
    /// Argument lists to try in order: the first whose program is on the PATH runs.
    runs: []const []const []const u8,
};

const levels = [_]u8{ 0, 25, 50, 75, 100 };

fn volumes(comptime make: fn (comptime u8) []const []const []const u8) [levels.len]Command {
    var out: [levels.len]Command = undefined;
    for (levels, 0..) |v, i| out[i] = .{
        .name = std.fmt.comptimePrint("Set Volume to {d}%", .{v}),
        .keywords = &.{ "volume", "audio", "sound", std.fmt.comptimePrint("volume {d}", .{v}) },
        .runs = make(v),
    };
    return out;
}

fn macVolume(comptime v: u8) []const []const []const u8 {
    return &.{&.{ "osascript", "-e", std.fmt.comptimePrint("set volume output volume {d}", .{v}) }};
}

fn linuxVolume(comptime v: u8) []const []const []const u8 {
    return &.{
        &.{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", std.fmt.comptimePrint("{d}.{d:0>2}", .{ v / 100, v % 100 }) },
        &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", std.fmt.comptimePrint("{d}%", .{v}) },
    };
}

pub const mac_table = volumes(macVolume) ++ [_]Command{
    .{ .name = "Toggle Dark Mode", .keywords = &.{ "appearance", "theme", "light mode" }, .runs = &.{&.{ "osascript", "-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode" }} },
    .{ .name = "Mute", .keywords = &.{ "volume", "audio", "sound" }, .runs = &.{&.{ "osascript", "-e", "set volume output muted true" }} },
    .{ .name = "Unmute", .keywords = &.{ "volume", "audio", "sound" }, .runs = &.{&.{ "osascript", "-e", "set volume output muted false" }} },
    .{ .name = "Sleep", .keywords = &.{"suspend"}, .runs = &.{&.{ "pmset", "sleepnow" }} },
    .{ .name = "Lock Screen", .keywords = &.{ "lock", "sleep display" }, .runs = &.{&.{ "pmset", "displaysleepnow" }} },
    .{ .name = "Empty Trash", .keywords = &.{ "bin", "delete" }, .runs = &.{&.{ "osascript", "-e", "tell application \"Finder\" to empty trash" }} },
};

pub const linux_table = volumes(linuxVolume) ++ [_]Command{
    .{ .name = "Mute", .keywords = &.{ "volume", "audio", "sound" }, .runs = &.{
        &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" },
        &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" },
    } },
    .{ .name = "Unmute", .keywords = &.{ "volume", "audio", "sound" }, .runs = &.{
        &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0" },
        &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", "0" },
    } },
    .{ .name = "Sleep", .keywords = &.{"suspend"}, .runs = &.{&.{ "systemctl", "suspend" }} },
    .{ .name = "Lock Screen", .keywords = &.{"lock"}, .runs = &.{&.{ "loginctl", "lock-session" }} },
    .{ .name = "Dark Mode", .keywords = &.{ "appearance", "theme" }, .runs = &.{&.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark" }} },
    .{ .name = "Light Mode", .keywords = &.{ "appearance", "theme" }, .runs = &.{&.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "default" }} },
};

pub const windows_table = [_]Command{
    .{ .name = "Sleep", .keywords = &.{ "suspend", "hibernate" }, .runs = &.{&.{ "rundll32", "powrprof.dll,SetSuspendState", "0,1,0" }} },
    .{ .name = "Lock Screen", .keywords = &.{"lock"}, .runs = &.{&.{ "rundll32", "user32.dll,LockWorkStation" }} },
};

/// This OS's commands.
pub const all: []const Command = switch (builtin.os.tag) {
    .macos => &mac_table,
    .windows => &windows_table,
    else => &linux_table,
};

const none = 0xff;
/// Which of each command's `runs` is installed (`none` when no program is).
var chosen: [all.len]u8 = @splat(none);

/// Looks at the PATH once: a command whose program is missing is not listed.
pub fn init(io: std.Io, env: *const std.process.Environ.Map) void {
    const path = env.get("PATH") orelse "";
    for (all, 0..) |c, i| {
        chosen[i] = for (c.runs, 0..) |argv, k| {
            if (onPath(io, path, argv[0])) break @intCast(k);
        } else none;
    }
}

fn onPath(io: std.Io, path: []const u8, program: []const u8) bool {
    var dirs = std.mem.tokenizeScalar(u8, path, if (windows) ';' else ':');
    var buf: [1024]u8 = undefined;
    while (dirs.next()) |dir| {
        const file = std.fmt.bufPrint(&buf, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, program, if (windows) ".exe" else "" }) catch continue;
        if (!std.fs.path.isAbsolute(file)) continue;
        if (std.Io.Dir.accessAbsolute(io, file, .{ .execute = !windows })) return true else |_| {}
    }
    return false;
}

fn listed(i: usize) bool {
    return chosen[i] != none;
}

/// Below this, a match is letters in order or a typo: too loose for a
/// command, which would list under nearly every query.
const min_score = 500;

/// The commands `query` asks for, best first (table order among equals),
/// into `out`: how many.
pub fn rank(query: []const u8, out: []search.Ranked) usize {
    const q = std.mem.trim(u8, query, " ");
    if (q.len < 2) return 0;
    var n: usize = 0;
    for (all, 0..) |c, i| {
        if (!listed(i)) continue;
        var best = search.score(q, c.name);
        if (best != null and best.?.score < min_score) best = null;
        for (c.keywords) |k| if (search.score(q, k)) |m| {
            // A word for it lights nothing in the name shown.
            var via = m;
            via.score -= 40;
            via.n = 0;
            if (m.score >= min_score and (best == null or via.score > best.?.score)) best = via;
        };
        const m = best orelse continue;
        // Insertion keeps the better first and the earlier of equals first;
        // past `out`, the worst falls off.
        var at = n;
        while (at > 0 and out[at - 1].match.score < m.score) : (at -= 1) {}
        if (at >= out.len) continue;
        if (n < out.len) n += 1;
        var j = n - 1;
        while (j > at) : (j -= 1) out[j] = out[j - 1];
        out[at] = .{ .index = @intCast(i), .match = m };
    }
    return n;
}

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Said in the footer (a failure).
    footer: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// The command succeeded: the panel may go.
    done: *const fn (ctx: *anyopaque) void,
};

/// Runs a command and waits for it on the main thread (nothing polls).
pub const Runner = struct {
    /// The app's (processes need a real one).
    io: std.Io,
    hooks: Hooks,
    index: usize = 0,
    child: ?std.process.Child = null,
    watch: ?nanoui.fdwatch.Watch = null,
    /// The tail of what it wrote to stderr.
    err: [160]u8 = undefined,
    err_len: usize = 0,
    said: [240]u8 = undefined,

    pub fn deinit(r: *Runner) void {
        r.stop();
    }

    fn stop(r: *Runner) void {
        if (r.watch) |w| w.cancel();
        r.watch = null;
        if (r.child) |*c| c.kill(r.io);
        r.child = null;
    }

    /// Runs command `i` of `all`, if it is listed.
    pub fn start(r: *Runner, i: usize) void {
        if (i >= all.len or !listed(i)) return;
        r.stop();
        r.index = i;
        r.err_len = 0;
        const argv = all[i].runs[chosen[i]];
        const child = std.process.spawn(r.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .pipe, .create_no_window = windows }) catch
            return r.fail("could not be started");
        r.child = child;
        const err = child.stderr.?;
        r.watch = (if (windows)
            nanoui.fdwatch.reader(err.handle, r, bytesIn, ended)
        else
            nanoui.fdwatch.readable(err.handle, r, readable)) catch null;
        // No watch means nothing would end it: wait for it here (it is short).
        if (r.watch == null) ended(r);
    }

    fn fail(r: *Runner, why: []const u8) void {
        const text = std.fmt.bufPrint(&r.said, "{s}: {s}", .{ all[r.index].name, why }) catch all[r.index].name;
        r.hooks.footer(r.hooks.ctx, text);
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const c = r.child orelse return;
        var buf: [512]u8 = undefined;
        const n = std.c.read(c.stderr.?.handle, &buf, buf.len);
        if (n <= 0) return ended(ctx);
        r.feed(buf[0..@intCast(n)]);
    }

    fn bytesIn(ctx: ?*anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.feed(bytes);
    }

    fn feed(r: *Runner, bytes: []const u8) void {
        r.err_len = keepTail(&r.err, r.err_len, bytes);
    }

    fn ended(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        if (r.watch) |w| w.cancel();
        r.watch = null;
        var c = r.child orelse return;
        r.child = null;
        const term = c.wait(r.io) catch null;
        if (term) |t| if (t.success()) return r.hooks.done(r.hooks.ctx);
        var buf: [48]u8 = undefined;
        const why = lastLine(r.err[0..r.err_len]);
        r.fail(if (why.len > 0) why else if (term) |t| switch (t) {
            .exited => |code| std.fmt.bufPrint(&buf, "exited with code {d}", .{code}) catch "failed",
            else => "was stopped",
        } else "failed");
    }
};

/// Appends `bytes` to the `len` bytes held in `buf`, keeping the last that fit: the new length.
fn keepTail(buf: []u8, len: usize, bytes: []const u8) usize {
    if (bytes.len >= buf.len) {
        @memcpy(buf, bytes[bytes.len - buf.len ..]);
        return buf.len;
    }
    var keep = len;
    if (keep + bytes.len > buf.len) {
        const drop = keep + bytes.len - buf.len;
        std.mem.copyForwards(u8, buf[0 .. keep - drop], buf[drop..keep]);
        keep -= drop;
    }
    @memcpy(buf[keep..][0..bytes.len], bytes);
    return keep + bytes.len;
}

/// The last non-empty line.
fn lastLine(text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, " \r\n");
    return std.mem.trim(u8, if (std.mem.lastIndexOfScalar(u8, t, '\n')) |nl| t[nl + 1 ..] else t, " \r");
}

/// Marks every command of this OS as installed, or none (for tests).
pub fn listForTests(on: bool) void {
    @memset(&chosen, if (on) 0 else none);
}

test "every table has named commands with fixed, non-empty argument lists" {
    const t = std.testing;
    for ([_][]const Command{ &mac_table, &linux_table, &windows_table }) |table| {
        for (table, 0..) |c, i| {
            try t.expect(c.name.len > 0 and c.runs.len > 0);
            for (c.runs) |argv| {
                try t.expect(argv.len > 0 and argv[0].len > 0);
                for (argv) |a| try t.expect(a.len > 0);
            }
            for (table[0..i]) |other| try t.expect(!std.mem.eql(u8, c.name, other.name));
        }
    }
}

test "tables hold what the spec lists for each OS" {
    const t = std.testing;
    const names = struct {
        fn has(table: []const Command, name: []const u8) bool {
            for (table) |c| if (std.mem.eql(u8, c.name, name)) return true;
            return false;
        }
    }.has;
    for ([_][]const u8{ "Toggle Dark Mode", "Set Volume to 0%", "Set Volume to 25%", "Set Volume to 50%", "Set Volume to 75%", "Set Volume to 100%", "Mute", "Unmute", "Sleep", "Lock Screen", "Empty Trash" }) |n| try t.expect(names(&mac_table, n));
    for ([_][]const u8{ "Set Volume to 50%", "Mute", "Unmute", "Sleep", "Lock Screen", "Dark Mode", "Light Mode" }) |n| try t.expect(names(&linux_table, n));
    // Volume falls back from wpctl to pactl.
    try t.expectEqualStrings("wpctl", linux_table[2].runs[0][0]);
    try t.expectEqualStrings("0.50", linux_table[2].runs[0][3]);
    try t.expectEqualStrings("1.00", linux_table[4].runs[0][3]);
    try t.expectEqualStrings("pactl", linux_table[2].runs[1][0]);
    try t.expectEqualStrings("50%", linux_table[2].runs[1][3]);
    try t.expectEqualStrings("set volume output volume 75", mac_table[3].runs[0][2]);
    // Windows lists no volume.
    try t.expect(!names(&windows_table, "Mute") and !names(&windows_table, "Set Volume to 50%"));
    try t.expectEqualStrings("user32.dll,LockWorkStation", windows_table[1].runs[0][1]);
}

test "commands are ranked like apps, only when listed, and capped by the room given" {
    const t = std.testing;
    defer listForTests(false);
    var out: [3]search.Ranked = undefined;
    // Nothing is listed until its program is found.
    listForTests(false);
    try t.expectEqual(@as(usize, 0), rank("sleep", &out));
    listForTests(true);
    const name = struct {
        fn of(r: search.Ranked) []const u8 {
            return all[r.index].name;
        }
    }.of;
    try t.expect(rank("sleep", &out) > 0);
    try t.expectEqualStrings("Sleep", name(out[0]));
    try t.expect(rank("lock", &out) > 0);
    try t.expectEqualStrings("Lock Screen", name(out[0]));
    try t.expectEqual(@as(usize, 0), rank("volume", out[0..0]));
    // Windows has no volume.
    if (!windows) {
        // Both are found for "mute", the exact name first.
        try t.expectEqual(@as(usize, 2), rank("mute", &out));
        try t.expectEqualStrings("Mute", name(out[0]));
        try t.expectEqualStrings("Unmute", name(out[1]));
        // A cap: the first of equals, in table order.
        try t.expectEqual(@as(usize, 3), rank("volume", &out));
        try t.expectEqual(@as(u32, 0), out[0].index);
        var one: [1]search.Ranked = undefined;
        try t.expectEqual(@as(usize, 1), rank("volume", &one));
        // A word for it lights nothing in the name.
        try t.expectEqual(@as(u8, 0), out[0].match.n);
    }
    // Not for one letter or loose letters.
    try t.expectEqual(@as(usize, 0), rank("s", &out));
    try t.expectEqual(@as(usize, 0), rank("qzx", &out));
    if (builtin.os.tag == .linux) {
        try t.expect(rank("volume 25", &out) > 0);
        try t.expectEqualStrings("Set Volume to 25%", name(out[0]));
    }
}

test "the stderr tail keeps the last bytes and its last line" {
    const t = std.testing;
    var buf: [8]u8 = undefined;
    var n = keepTail(&buf, 0, "ab\n");
    n = keepTail(&buf, n, "cdef");
    try t.expectEqualStrings("ab\ncdef", buf[0..n]);
    n = keepTail(&buf, n, "ghij");
    try t.expectEqualStrings("cdefghij", buf[0..n]);
    n = keepTail(&buf, n, "0123456789");
    try t.expectEqualStrings("23456789", buf[0..n]);
    try t.expectEqualStrings("last", lastLine("first\nlast\n"));
    try t.expectEqualStrings("", lastLine(" \n"));
}

test "a program is found on the PATH only when it is there" {
    if (windows) return error.SkipZigTest;
    const io = std.Io.Threaded.global_single_threaded.io();
    try std.testing.expect(onPath(io, "/nonexistent:/bin", "sh"));
    try std.testing.expect(!onPath(io, "/bin:/usr/bin:relative", "no-such-program-nanolight"));
    try std.testing.expect(!onPath(io, "", "sh"));
}
