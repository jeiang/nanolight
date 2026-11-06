//! What the Mac's verifiers (verify_release, verify_update, verify_typing)
//! share: fetching, waiting, AppleScript, and the app's facts they rely on.
//! Each of the app's facts names where the app or nanoui sets it: changed
//! there and not here, a verifier fails with a timeout, not a reason.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const command = @import("command.zig");
const release = @import("release.zig");

// ----- the app's facts -----

/// The defaults domain the app's settings are kept in: its bundle id (nanoui's kv).
pub const domain = release.bundle_id;
/// src/shortcut.zig `onboarded_key`: "1" once the welcome is done.
pub const onboarded_key = "nanolight.onboarded";
/// src/shortcut.zig `store_key`: the hotkey, as `Choice.name` writes it.
pub const hotkey_key = "nanolight.hotkey";
/// ⌃⌥⌘N as src/shortcut.zig's `Choice.name` writes it, `key:<code>:<mods>:<char>`:
/// key code 45, Carbon's control, option and command, and 'n'.
pub const hotkey_chord = "key:45:6400:110";
/// The same key, as System Events presses it.
pub const hotkey_keys = "key code 45 using {control down, option down, command down}";
/// src/view.zig `width`: the panel, inside its window's shadow margin.
pub const panel_width = 680;
/// nanoui's `Updater.Options.first_ms`: the first check, after launch.
pub const first_check_ms = 20 * 1000;
/// src/main.zig's `autoRestart(.idle_ms)`: away this long, an update restarts.
pub const restart_idle_ms = 10 * 1000;
/// nanoui's `Auto.away_ms`: in sight, an update waits for no input this long.
pub const away_ms = 5 * 60 * 1000;
/// nanoui's update.zig: the feed read instead of the GitHub release's.
pub const feed_env = "NANOUI_UPDATE_FEED";
/// nanoui's update.zig: `~/Library/Caches/<name>`, its updates in `updates/<version>`.
pub const cache_folder = "Library/Caches/" ++ release.app_name;

/// The folder nanoui's updater keeps `version` in, under `cache`.
pub fn stagedFolder(arena: std.mem.Allocator, cache: []const u8, version: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/updates/{s}", .{ cache, version }) catch @panic("OOM");
}

/// The app it unpacked and checked there, waiting to be swapped in.
pub fn stagedApp(arena: std.mem.Allocator, cache: []const u8, version: []const u8) []const u8 {
    const folder = stagedFolder(arena, cache, version);
    return std.fs.path.join(arena, &.{ folder, "unpacked", release.bundle_name }) catch
        @panic("OOM");
}

// ----- the runner -----

/// Where screenshots go when SHOTS doesn't say.
pub const shots_default = "/tmp/nanolight-shots";

/// A verifier that presses keys or replaces the installed app runs only on
/// CI's runners; elsewhere it says so, and exits.
pub fn requireCi(io: Io, environ: *const std.process.Environ.Map, comptime what: []const u8) void {
    if (std.mem.eql(u8, environ.get("CI") orelse "", "true")) return;
    command.complain(io, what ++ ": CI runners only", .{});
    std.process.exit(2);
}

/// This Mac's version, as `sw_vers` says it: screenshots are named by it.
pub fn macosVersion(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const said = try command.capture(arena, io, &.{ "sw_vers", "-productVersion" }, .{});
    return said.line();
}

pub fn fetch(io: Io, url: []const u8, path: []const u8) !void {
    try command.run(io, &.{ "curl", "-fsSL", "--retry", "3", "-o", path, url });
}

/// The version an app's Info.plist says, or null when it says none.
pub fn plistVersion(arena: std.mem.Allocator, io: Io, app: []const u8) !?[]const u8 {
    const plist = try std.fs.path.join(arena, &.{ app, release.bundle_plist });
    const said = try command.capture(arena, io, &.{
        "plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist,
    }, .{});
    return if (said.ok()) said.line() else null;
}

/// Runs an AppleScript line and gives what it printed; error.ScriptFailed,
/// after saying why, when it fails.
pub fn osascript(arena: std.mem.Allocator, io: Io, script: []const u8) ![]const u8 {
    const said = try command.capture(arena, io, &.{ "osascript", "-e", script }, .{});
    if (said.ok()) return said.line();
    command.complain(io, "osascript -e '{s}': {s}", .{ script, said.text });
    return error.ScriptFailed;
}

/// Presses keys through System Events: `script` is what it is told to do.
pub fn keys(arena: std.mem.Allocator, io: Io, script: []const u8) !void {
    const line = try std.fmt.allocPrint(arena, "tell application \"System Events\" to {s}", .{
        script,
    });
    _ = try osascript(arena, io, line);
}

pub const Wait = struct {
    tries: u32,
    pause_ms: i64,
};

/// Asks `holds(context)` up to `wait.tries` times, `wait.pause_ms` apart:
/// whether it held.
pub fn waitUntil(io: Io, wait: Wait, context: anytype, holds: anytype) !bool {
    assert(wait.tries > 0);
    for (0..wait.tries) |attempt| {
        if (try holds(context)) return true;
        if (attempt + 1 < wait.tries) try command.sleep(io, wait.pause_ms);
    }
    return false;
}

test "a wait asks until it holds, and no more" {
    const Counter = struct {
        asked: u32 = 0,
        fn third(counter: *@This()) !bool {
            counter.asked += 1;
            return counter.asked == 3;
        }
    };
    var counter: Counter = .{};
    const wait: Wait = .{ .tries = 5, .pause_ms = 0 };
    try std.testing.expect(try waitUntil(std.testing.io, wait, &counter, Counter.third));
    try std.testing.expectEqual(@as(u32, 3), counter.asked);
    counter = .{};
    const short: Wait = .{ .tries = 2, .pause_ms = 0 };
    try std.testing.expect(!try waitUntil(std.testing.io, short, &counter, Counter.third));
    try std.testing.expectEqual(@as(u32, 2), counter.asked);
}
