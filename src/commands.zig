//! System commands (sleep, lock, volume, dark mode), built in and found like
//! apps. Each is written once, with each OS's fixed argument lists (nothing a user
//! types reaches them, and no shell runs them); a command whose program is
//! not on the PATH is never listed, which is looked at once at startup.
//! A failure's message goes in the panel's footer.
//!
//! Windows has no volume commands: Windows offers none without a third-party
//! tool or an audio API. Its Sleep hibernates instead when hibernation is on
//! (`SetSuspendState`'s documented behavior).
const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");
const search = @import("search.zig");
const Counts = @import("launch_counts.zig").Counts;
const windows = @import("os.zig").windows;

/// Argument lists to try in order: the first whose program is on the PATH runs.
const Argvs = []const []const []const u8;

/// A command as this machine lists it.
pub const Command = struct {
    name: []const u8,
    /// What its runs are counted under (launch_counts.zig).
    key: []const u8,
    /// Other words for it, matched a little lower than its name.
    keywords: []const []const u8 = &.{},
    runs: Argvs,
};

/// How one OS runs a command.
const Way = struct {
    runs: Argvs,
    /// Words only this OS's way answers to.
    keywords: []const []const u8 = &.{},
};

/// A command, written once: its name and words, and how each OS runs it
/// (null: not listed there).
const Entry = struct {
    name: []const u8,
    keywords: []const []const u8 = &.{},
    mac: ?Way = null,
    linux: ?Way = null,
    windows: ?Way = null,
};

const sound = [_][]const u8{ "volume", "audio", "sound" };
const levels = [_]u8{ 0, 25, 50, 75, 100 };

fn volumes() [levels.len]Entry {
    var out: [levels.len]Entry = undefined;
    for (levels, 0..) |v, i| out[i] = .{
        .name = std.fmt.comptimePrint("Set Volume to {d}%", .{v}),
        .keywords = &(sound ++ .{std.fmt.comptimePrint("volume {d}", .{v})}),
        .mac = .{ .runs = &.{&.{
            "osascript",
            "-e",
            std.fmt.comptimePrint("set volume output volume {d}", .{v}),
        }} },
        .linux = .{ .runs = &.{
            &.{
                "wpctl",
                "set-volume",
                "@DEFAULT_AUDIO_SINK@",
                std.fmt.comptimePrint("{d}.{d:0>2}", .{ v / 100, v % 100 }),
            },
            &.{ "pactl", "set-sink-volume", "@DEFAULT_SINK@", std.fmt.comptimePrint("{d}%", .{v}) },
        } },
    };
    return out;
}

/// Absolute, so a rundll32.bat in the working directory is never found first.
const rundll32 = "C:\\Windows\\System32\\rundll32.exe";

/// Every OS's commands, in the order each lists its own.
const entries = volumes() ++ [_]Entry{
    .{
        .name = "Toggle Dark Mode",
        .keywords = &.{ "appearance", "theme", "light mode" },
        .mac = .{ .runs = &.{
            &.{
                "osascript",
                "-e",
                "tell application \"System Events\" to tell appearance preferences to set dark " ++
                    "mode to not dark mode",
            },
        } },
    },
    .{
        .name = "Mute",
        .keywords = &sound,
        .mac = .{ .runs = &.{&.{ "osascript", "-e", "set volume output muted true" }} },
        .linux = .{ .runs = &.{
            &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "1" },
            &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", "1" },
        } },
    },
    .{
        .name = "Unmute",
        .keywords = &sound,
        .mac = .{ .runs = &.{&.{ "osascript", "-e", "set volume output muted false" }} },
        .linux = .{ .runs = &.{
            &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0" },
            &.{ "pactl", "set-sink-mute", "@DEFAULT_SINK@", "0" },
        } },
    },
    .{
        .name = "Sleep",
        .keywords = &.{"suspend"},
        .mac = .{ .runs = &.{&.{ "pmset", "sleepnow" }} },
        .linux = .{ .runs = &.{&.{ "systemctl", "suspend" }} },
        // It hibernates when hibernation is on.
        .windows = .{
            .runs = &.{&.{ rundll32, "powrprof.dll,SetSuspendState", "0,1,0" }},
            .keywords = &.{"hibernate"},
        },
    },
    .{
        .name = "Sleep Display",
        .keywords = &.{ "display off", "screen off" },
        .mac = .{ .runs = &.{&.{ "pmset", "displaysleepnow" }} },
    },
    .{
        .name = "Lock Screen",
        .keywords = &.{"lock"},
        .linux = .{ .runs = &.{&.{ "loginctl", "lock-session" }} },
        .windows = .{ .runs = &.{&.{ rundll32, "user32.dll,LockWorkStation" }} },
    },
    .{
        .name = "Empty Trash",
        .keywords = &.{ "bin", "delete" },
        .mac = .{ .runs = &.{
            &.{ "osascript", "-e", "tell application \"Finder\" to empty trash" },
        } },
    },
    .{
        .name = "Dark Mode",
        .keywords = &.{ "appearance", "theme" },
        .linux = .{ .runs = &.{
            &.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "prefer-dark" },
        } },
    },
    .{
        .name = "Light Mode",
        .keywords = &.{ "appearance", "theme" },
        .linux = .{ .runs = &.{
            &.{ "gsettings", "set", "org.gnome.desktop.interface", "color-scheme", "default" },
        } },
    },
};

const Os = enum { mac, linux, windows };

/// The commands `os` lists, in table order.
pub fn table(comptime os: Os) []const Command {
    return comptime blk: {
        var n: usize = 0;
        for (entries) |e| {
            if (@field(e, @tagName(os)) != null) n += 1;
        }
        var out: [n]Command = undefined;
        var i: usize = 0;
        for (entries) |e| {
            const way = @field(e, @tagName(os)) orelse continue;
            out[i] = .{
                .name = e.name,
                .key = "command:" ++ e.name,
                .keywords = e.keywords ++ way.keywords,
                .runs = way.runs,
            };
            i += 1;
        }
        const done = out;
        break :blk &done;
    };
}

pub const all = table(switch (builtin.os.tag) {
    .macos => .mac,
    .windows => .windows,
    else => .linux,
});

const none = 0xff;

/// Which of each command's `runs` this machine has (`none` when no program
/// is): a command whose program is missing is not listed.
pub const Installed = struct {
    chosen: [all.len]u8 = @splat(none),

    pub fn listed(in: *const Installed, i: usize) bool {
        return in.chosen[i] != none;
    }
};

/// Looks at the PATH for each command's programs.
pub fn installed(io: std.Io, env: *const std.process.Environ.Map) Installed {
    const path = env.get("PATH") orelse "";
    var in: Installed = .{};
    for (all, 0..) |c, i| {
        in.chosen[i] = for (c.runs, 0..) |argv, k| {
            if (onPath(io, path, argv[0])) break @intCast(k);
        } else none;
    }
    return in;
}

fn onPath(io: std.Io, path: []const u8, program: []const u8) bool {
    if (std.fs.path.isAbsolute(program)) return if (std.Io.Dir.accessAbsolute(
        io,
        program,
        .{ .execute = !windows },
    ))
        true
    else |_|
        false;
    var dirs = std.mem.tokenizeScalar(u8, path, if (windows) ';' else ':');
    var buf: [1024]u8 = undefined;
    while (dirs.next()) |dir| {
        const file = std.fmt.bufPrint(
            &buf,
            "{s}{c}{s}{s}",
            .{ dir, std.fs.path.sep, program, if (windows) ".exe" else "" },
        ) catch continue;
        if (!std.fs.path.isAbsolute(file)) continue;
        if (std.Io.Dir.accessAbsolute(io, file, .{ .execute = !windows })) return true else |_| {}
    }
    return false;
}

/// The commands `query` asks for among those `in` lists, best first (table
/// order among equals), lifted by how often each was run (`counts`), into
/// `out`: how many.
pub fn rank(
    query: []const u8,
    in: *const Installed,
    counts: *const Counts,
    out: []search.Ranked,
) usize {
    const q = std.mem.trim(u8, query, " ");
    if (q.len < 2) return 0;
    var top: search.Top = .init(out);
    for (all, 0..) |c, i| {
        if (!in.listed(i)) continue;
        var m = search.scoreNamed(q, c.name, c.keywords, search.min_loose) orelse continue;
        m.score += search.lift(counts.of(c.key));
        top.offer(.{ .index = @intCast(i), .match = m });
    }
    return top.n;
}

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Said in the footer (a failure).
    footer: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// The command succeeded: the panel may go.
    done: *const fn (ctx: *anyopaque) void,
};

/// Runs a command, its end heard on the main thread (nothing polls).
pub const Runner = struct {
    /// The app's (processes need a real one).
    io: std.Io,
    hooks: Hooks,
    installed: Installed,
    index: usize = 0,
    proc: proc.Runner = .{},
    /// The tail of what it wrote to stderr.
    err: [160]u8 = undefined,
    err_len: usize = 0,
    said: [240]u8 = undefined,

    pub fn deinit(r: *Runner) void {
        r.proc.stop();
    }

    /// Runs command `i` of `all`, if it is listed.
    pub fn start(r: *Runner, i: usize) void {
        if (i >= all.len or !r.installed.listed(i)) return;
        r.index = i;
        r.err_len = 0;
        const options: std.process.SpawnOptions = .{
            .argv = all[i].runs[r.installed.chosen[i]],
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
            .create_no_window = windows,
        };
        r.proc.start(r.io, options, .{ .ctx = r, .bytes = feed, .ended = ended }) catch |e|
            r.fail(switch (e) {
                error.Spawn => "could not be started",
                error.Watch => "could not be followed",
            });
    }

    fn fail(r: *Runner, why: []const u8) void {
        const text = std.fmt.bufPrint(
            &r.said,
            "{s}: {s}",
            .{ all[r.index].name, why },
        ) catch all[r.index].name;
        r.hooks.footer(r.hooks.ctx, text);
    }

    fn feed(ctx: *anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.err_len = proc.keepTail(&r.err, r.err_len, bytes);
    }

    fn ended(ctx: *anyopaque, term: ?std.process.Child.Term) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        if (term) |t| if (t.success()) return r.hooks.done(r.hooks.ctx);
        var buf: [48]u8 = undefined;
        const why = proc.lastLine(r.err[0..r.err_len]);
        r.fail(if (why.len > 0) why else if (term) |t| switch (t) {
            .exited => |code| std.fmt.bufPrint(
                &buf,
                "exited with code {d}",
                .{code},
            ) catch "failed",
            else => "was stopped",
        } else "failed");
    }
};

test "every table has named commands with fixed, non-empty argument lists" {
    const t = std.testing;
    for ([_][]const Command{ table(.mac), table(.linux), table(.windows) }) |listed| {
        for (listed, 0..) |c, i| {
            try t.expect(c.name.len > 0 and c.runs.len > 0);
            for (c.runs) |argv| {
                try t.expect(argv.len > 0 and argv[0].len > 0);
                for (argv) |a| try t.expect(a.len > 0);
            }
            for (listed[0..i]) |other| try t.expect(!std.mem.eql(u8, c.name, other.name));
        }
    }
}

const no_counts: Counts = .{};

test "commands are ranked like apps, only when listed, and capped by the room given" {
    const t = std.testing;
    var out: [3]search.Ranked = undefined;
    // Nothing is listed until its program is found.
    try t.expectEqual(@as(usize, 0), rank("sleep", &.{}, &no_counts, &out));
    const every: Installed = .{ .chosen = @splat(0) };
    const name = struct {
        fn of(r: search.Ranked) []const u8 {
            return all[r.index].name;
        }
    }.of;
    try t.expect(rank("sleep", &every, &no_counts, &out) > 0);
    try t.expectEqualStrings("Sleep", name(out[0]));
    if (builtin.os.tag == .macos) {
        try t.expectEqual(@as(usize, 0), rank("lock", &every, &no_counts, &out));
        try t.expect(rank("sleep display", &every, &no_counts, &out) > 0);
        try t.expectEqualStrings("Sleep Display", name(out[0]));
    } else {
        try t.expect(rank("lock", &every, &no_counts, &out) > 0);
        try t.expectEqualStrings("Lock Screen", name(out[0]));
    }
    try t.expectEqual(@as(usize, 0), rank("volume", &every, &no_counts, out[0..0]));
    // Windows has no volume.
    if (!windows) {
        // Both are found for "mute", the exact name first.
        try t.expectEqual(@as(usize, 2), rank("mute", &every, &no_counts, &out));
        try t.expectEqualStrings("Mute", name(out[0]));
        try t.expectEqualStrings("Unmute", name(out[1]));
        // A cap: the first of equals, in table order.
        try t.expectEqual(@as(usize, 3), rank("volume", &every, &no_counts, &out));
        try t.expectEqual(@as(u32, 0), out[0].index);
        var one: [1]search.Ranked = undefined;
        try t.expectEqual(@as(usize, 1), rank("volume", &every, &no_counts, &one));
        // A word for it lights nothing in the name.
        try t.expectEqual(@as(u8, 0), out[0].match.n);
    }
    // Not for one letter or loose letters.
    try t.expectEqual(@as(usize, 0), rank("s", &every, &no_counts, &out));
    try t.expectEqual(@as(usize, 0), rank("qzx", &every, &no_counts, &out));
    if (builtin.os.tag == .linux) {
        try t.expect(rank("volume 25", &every, &no_counts, &out) > 0);
        try t.expectEqualStrings("Set Volume to 25%", name(out[0]));
    }
}

test "a program is found on the PATH only when it is there" {
    if (windows) return error.SkipZigTest;
    const io = std.testing.io;
    try std.testing.expect(onPath(io, "/nonexistent:/bin", "sh"));
    try std.testing.expect(!onPath(io, "/bin:/usr/bin:relative", "no-such-program-nanolight"));
    try std.testing.expect(!onPath(io, "", "sh"));
}
