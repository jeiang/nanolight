//! `zig build verify-update -- vOLD vNEW`: what `zig build verify-release`
//! can't check headless, on a CI runner: the release used as a person uses
//! it, from a clean Mac (the welcome; the hotkey, a search, opening an app and
//! a System Settings pane), the release before it updating itself to this one
//! and coming back, and a feed that lies being refused.
//!
//! It presses keys, shows windows, resets the app's settings and replaces
//! /Applications/Nanolight.app, so it runs only where CI is set. A launcher
//! started with `open` gets the environment `open --env` gives it, so the new
//! copy, restarted by the updater, reads the real feed: vNEW must be the
//! newest release, or it would update again. SHOTS is where its screenshots
//! go; TYPING_EXPECT is the typing check's verdict (tools/verify_typing.zig).
//!
//! Its hotkey is ⌃⌥⌘N, a key of its own: on a clean Mac Spotlight answers
//! ⌘Space too, and takes the keys typed after it.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const command = @import("command.zig");
const feed_server = @import("feed_server.zig");
const macos = @import("macos.zig");
const release = @import("release.zig");
const screen = @import("screen.zig");
const typing = @import("verify_typing.zig");

const usage = "usage: zig build verify-update -- vOLD vNEW";
const releases_url = "https://github.com/jeiang/nanolight/releases/download";
const app = "/Applications/Nanolight.app";
const program = app ++ "/Contents/MacOS/nanolight";
const program_pattern = "^" ++ program;
const domain = "dev.nanoui.nanolight";
const port = 8765;
const local_feed = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{port});
const chord = "key:45:6400:110";
/// A version newer than any: only a lying feed could offer it.
const lie_version = "99.0.0";
const log_tail_lines = 20;
const crash_head_lines = 60;

pub const Died = error{Died};

const Session = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    from: []const u8,
    to: []const u8,
    from_version: []const u8,
    to_version: []const u8,
    work: []const u8,
    shots: []const u8,
    cache: []const u8,
    macos_version: []const u8,
    unpacked_count: u32 = 0,

    fn workPath(s: *const Session, name: []const u8) []const u8 {
        return std.fs.path.join(s.arena, &.{ s.work, name }) catch @panic("OOM");
    }

    fn print(s: *const Session, comptime format: []const u8, arguments: anytype) []const u8 {
        return std.fmt.allocPrint(s.arena, format, arguments) catch @panic("OOM");
    }

    /// Says what failed, with the app's log and its newest crash report, and
    /// takes a screenshot: the caller returns the error this gives.
    fn die(s: *const Session, comptime format: []const u8, arguments: anytype) Died {
        command.complain(s.io, "FAIL  " ++ format, arguments);
        printTail(s, s.workPath("app.log"));
        printNewestCrash(s);
        s.shot("failed");
        return error.Died;
    }

    fn ok(s: *const Session, comptime format: []const u8, arguments: anytype) void {
        command.say(s.io, "ok    " ++ format, arguments);
    }

    fn shot(s: *const Session, name: []const u8) void {
        const path = s.print("{s}/{s}-{s}.png", .{ s.shots, s.macos_version, name });
        // best effort: a screenshot shows what happened; it isn't a check.
        _ = command.capture(s.arena, s.io, &.{ "screencapture", "-x", path }, .{}) catch {};
    }

    fn sleepMs(s: *const Session, duration_ms: i64) !void {
        try command.sleep(s.io, duration_ms);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;
    if (!std.mem.eql(u8, environ.get("CI") orelse "", "true")) {
        command.complain(io, "verify-update presses keys and replaces the installed app: " ++
            "CI runners only", .{});
        std.process.exit(2);
    }
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3 or args[1].len == 0 or args[2].len == 0) {
        command.complain(io, usage, .{});
        std.process.exit(2);
    }
    const shots = environ.get("SHOTS") orelse "/tmp/nanolight-shots";
    try Io.Dir.cwd().createDirPath(io, shots);
    const home = environ.get("HOME") orelse return error.NoHome;
    const version_said = try command.capture(arena, io, &.{ "sw_vers", "-productVersion" }, .{});
    var session: Session = .{
        .arena = arena,
        .gpa = init.gpa,
        .io = io,
        .environ = environ,
        .from = args[1],
        .to = args[2],
        .from_version = withoutV(args[1]),
        .to_version = withoutV(args[2]),
        .work = try command.temporaryFolder(arena, io, "nanolight-update"),
        .shots = shots,
        .cache = try std.fs.path.join(arena, &.{ home, "Library/Caches/Nanolight" }),
        .macos_version = version_said.line(),
    };
    const result = verify(&session);
    // best effort: the app may already be gone.
    _ = command.capture(arena, io, &.{ "pkill", "-f", program_pattern }, .{}) catch {};
    // best effort: a temporary folder.
    Io.Dir.cwd().deleteTree(io, session.work) catch {};
    result catch |err| switch (err) {
        error.Died => std.process.exit(1),
        else => return err,
    };
    command.say(io, "", .{});
    command.say(io, "{s} -> {s}: all checks passed", .{ session.from, session.to });
}

fn withoutV(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
}

fn verify(s: *Session) !void {
    try firstLaunch(s);
    try welcome(s);
    try used(s);
    try lyingFeeds(s);
    try updatePutAway(s);
    try updateLeftOpen(s);
}

// ----- a clean Mac's first launch -----

fn firstLaunch(s: *Session) !void {
    command.say(s.io, "== {s}, first launch", .{s.to});
    try install(s, s.to);
    const pid = try launch(s, s.print("{s}/{s}", .{ releases_url, s.to }));
    try seePanels(s, 1, "the welcome is on screen");
    // Past the first update check (20 s), which finds nothing newer.
    try s.sleepMs(25_000);
    s.shot("first-launch");
    if (!samePid(try running(s), pid)) {
        return s.die("{s} died within 25 s of its first launch", .{s.to});
    }
    const now = try installed(s);
    if (!std.mem.eql(u8, now orelse "", s.to_version)) {
        return s.die("{s} replaced itself with {s}", .{ s.to, now orelse "" });
    }
    try trusted(s);
    s.ok("{s} launches from a clean install and stays up", .{s.to});
}

/// The welcome's steps, as a new person goes through them.
fn welcome(s: *Session) !void {
    try returnKey(s);
    try s.sleepMs(1500);
    s.shot("welcome-try-it");
    try hotkey(s);
    try seePanels(s, 0, "the welcome's hotkey step: it closes");
    try hotkey(s);
    try seePanels(s, 1, "the welcome's hotkey step: it opens again");
    try s.sleepMs(2000);
    s.shot("welcome-done");
    try returnKey(s);
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const read = try command.capture(s.arena, s.io, &.{
            "defaults", "read", domain, "nanolight.onboarded",
        }, .{});
        if (read.ok() and std.mem.eql(u8, read.line(), "1")) break;
        if (tries == 40) return s.die("Return didn't finish the welcome", .{});
        try s.sleepMs(250);
    }
    try s.sleepMs(1000);
    s.shot("welcome-finished");
    s.ok("the welcome finishes", .{});
}

// ----- used as a person uses it -----

fn used(s: *Session) !void {
    command.say(s.io, "== {s}, used", .{s.to});
    try install(s, s.to);
    try returning(s);
    const pid = try launch(s, s.print("{s}/{s}", .{ releases_url, s.to }));
    try seePanels(s, 1, "launching shows the panel");
    try hotkey(s);
    try seePanels(s, 0, "the hotkey hides it");
    try hotkey(s);
    try seePanels(s, 1, "the hotkey shows it");
    try s.sleepMs(500);
    const expect = typing.expectOf(s.environ.get("TYPING_EXPECT"));
    const typed = typing.check(s.arena, s.io, .{ .expect = expect, .shots = s.shots });
    if (!(typed catch false)) return s.die("typing (#24)", .{});
    try keys(s, "keystroke \"calculator\"");
    try s.sleepMs(1000);
    s.shot("used-search");
    try s.sleepMs(3000);
    s.shot("used-search-later");
    try returnKey(s);
    try opened(s, "Calculator");
    try seePanels(s, 0, "the panel goes as the app opens");
    try kill(s, &.{ "pkill", "-x", "Calculator" });
    try hotkey(s);
    try seePanels(s, 1, "the hotkey shows it again");
    try s.sleepMs(500);
    try keys(s, "keystroke \"login items\"");
    try s.sleepMs(1000);
    s.shot("used-pane-search");
    try returnKey(s);
    try opened(s, "System Settings");
    var tries: u32 = 0;
    while (std.mem.indexOf(u8, try paneTitle(s), "Login") == null) : (tries += 1) {
        if (tries == 40) {
            return s.die("System Settings opened at \"{s}\", not Login Items", .{try paneTitle(s)});
        }
        try s.sleepMs(500);
    }
    s.shot("used-pane");
    s.ok("System Settings opened at \"{s}\"", .{try paneTitle(s)});
    try kill(s, &.{ "pkill", "-x", "System Settings" });
    if (!samePid(try running(s), pid)) return s.die("{s} died while being used", .{s.to});
    s.ok("{s} is still up", .{s.to});
}

// ----- a feed that lies -----

/// The control first: the same road, told the truth. Without it, a feed
/// that nothing could get through would pass every refusal after it.
fn lyingFeeds(s: *Session) !void {
    command.say(s.io, "== {s} takes the same feed, told the truth", .{s.from});
    const truth = try feedOf(s, .{ .name = "feed-truth", .version = s.to_version });
    _ = try offer(s, truth);
    const staged = s.print("{s}/updates/{s}/unpacked/Nanolight.app", .{ s.cache, s.to_version });
    const took = exists(s, staged) or std.mem.eql(u8, (try installed(s)) orelse "", s.to_version);
    if (!took) return s.die("it took nothing from a good feed: refusals here prove nothing", .{});
    s.ok("{s} took it", .{s.from});

    const zeros: release.Sha256Hex = @splat('0');
    const sums = try feedOf(s, .{ .name = "feed-sum", .version = lie_version, .sum = zeros });
    try refused(s, "a checksum that doesn't match", sums);
    const names = try feedOf(s, .{ .name = "feed-name", .version = lie_version });
    try refused(s, "a real build that isn't the version named", names);
    const other = try feedOf(s, .{ .name = "feed-other", .version = lie_version, .resign = true });
    try refused(s, "a build not signed by the team", other);
}

const Feed = struct {
    name: []const u8,
    version: []const u8,
    /// The sum the manifest claims; the zip's own when null.
    sum: ?release.Sha256Hex = null,
    /// The zip's app said to be `version` and signed ad hoc, by no team.
    resign: bool = false,
};

/// A folder holding the update zip and a manifest naming it as `feed` says.
fn feedOf(s: *Session, feed: Feed) ![]const u8 {
    const folder = s.workPath(feed.name);
    try Io.Dir.cwd().createDir(s.io, folder, .default_dir);
    const zip = s.print("{s}/{s}", .{ folder, release.macos_update });
    if (feed.resign) {
        const unpacked = try unpack(s, s.to);
        const bundle = s.print("{s}/Nanolight.app", .{unpacked});
        const plist = s.print("{s}/Contents/Info.plist", .{bundle});
        try command.run(s.io, &.{
            "plutil", "-replace", "CFBundleShortVersionString", "-string", feed.version, plist,
        });
        try command.run(s.io, &.{ "codesign", "--force", "--deep", "--sign", "-", bundle });
        try command.run(s.io, &.{ "ditto", "-c", "-k", "--keepParent", bundle, zip });
        try Io.Dir.cwd().deleteTree(s.io, unpacked);
    } else {
        try Io.Dir.cwd().copyFile(try zipOf(s, s.to), Io.Dir.cwd(), zip, s.io, .{});
    }
    const sum = feed.sum orelse try release.sha256File(s.io, Io.Dir.cwd(), zip);
    const entries = [_]release.FeedEntry{.{ .name = release.macos_update, .sha256 = sum }};
    var manifest: Io.Writer.Allocating = .init(s.arena);
    try release.writeManifest(&manifest.writer, feed.version, &entries);
    const manifest_path = s.print("{s}/{s}", .{ folder, release.manifest_name });
    try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = manifest_path, .data = manifest.written() });
    return folder;
}

/// The older copy reads the feed in `folder`, and fetches what it offers.
/// Returns the pid it ran as.
fn offer(s: *Session, folder: []const u8) ![]const u8 {
    try install(s, s.from);
    var server: feed_server.Server = undefined;
    try server.start(.{ .gpa = s.gpa, .io = s.io, .folder = folder, .port = port });
    defer server.stop();
    const pid = try launch(s, local_feed);
    const asked = s.print("GET /{s}", .{release.macos_update});
    var waited_s: u32 = 0;
    while (!server.asked(asked)) : (waited_s += 1) {
        if (waited_s == 120) {
            command.say(s.io, "{s}", .{server.log()});
            return s.die("{s} never asked for the update", .{s.from});
        }
        try s.sleepMs(1000);
    }
    // Time to verify it, and for a restart (10 s away) if it took it.
    try s.sleepMs(25_000);
    return pid;
}

/// What's wrong, and its feed. A release newer than anything: the only
/// thing that could change this copy is this feed.
fn refused(s: *Session, what: []const u8, folder: []const u8) !void {
    command.say(s.io, "== {s} refuses: {s}", .{ s.from, what });
    const pid = try offer(s, folder);
    const now = (try installed(s)) orelse "";
    if (!std.mem.eql(u8, now, s.from_version)) {
        return s.die("took a bad update ({s}): installed {s}", .{ what, now });
    }
    if (!samePid(try running(s), pid)) {
        return s.die("{s} restarted or died on a bad update ({s})", .{ s.from, what });
    }
    // What it refuses it deletes; what it takes waits here, even in sight.
    if (exists(s, s.print("{s}/updates/{s}", .{ s.cache, lie_version }))) {
        return s.die("kept a bad update ({s}) in its cache", .{what});
    }
    s.ok("{s} refused it, and kept nothing", .{s.from});
}

// ----- the update -----

/// The update nearly everyone gets: the panel put away, another app in
/// front. Out of sight 10 s after it's fetched (20 s after launch), it
/// restarts then, and nobody sees it.
fn updatePutAway(s: *Session) !void {
    command.say(s.io, "== {s} updates itself to {s}, panel put away", .{ s.from, s.to });
    try install(s, s.from);
    try returning(s);
    const old = try launch(s, s.print("{s}/{s}", .{ releases_url, s.to }));
    try seePanels(s, 1, "launching shows the panel");
    try hotkey(s);
    try seePanels(s, 0, "the hotkey hides it");
    command.say(s.io, "      with the panel hidden, in front: {s}", .{try frontmost(s)});
    // With nothing else taking the front yet: does it go by itself?
    var waits: u32 = 0;
    while (waits < 25 and !try isInstalled(s, s.to_version)) : (waits += 1) {
        try s.sleepMs(2000);
    }
    if (!try isInstalled(s, s.to_version)) {
        command.say(s.io, "      not updated after 50 s with the panel hidden; " ++
            "now another app comes in front", .{});
        _ = try osascript(s, "tell application \"Finder\" to activate");
        try s.sleepMs(1000);
        command.say(s.io, "      in front: {s}", .{try frontmost(s)});
    }
    const new = try swapped(s, .{ .old = old, .within_s = 90 });
    try settled(s, new);
    try seePanels(s, 0, "it came back out of sight");
    if (std.ascii.eqlIgnoreCase(try frontmost(s), "nanolight")) {
        return s.die("it came back in front", .{});
    }
    try hotkey(s);
    try seePanels(s, 1, "the updated copy's hotkey shows the panel");
    try s.sleepMs(1000);
    s.shot("updated");
    s.ok("{s} answers its hotkey", .{s.to});
}

/// Left open, on the welcome: in sight, it waits for nobody to be at the
/// Mac (5 minutes with no input), and comes back as it was.
fn updateLeftOpen(s: *Session) !void {
    command.say(s.io, "== {s} updates itself to {s}, left open", .{ s.from, s.to });
    try install(s, s.from);
    const old = try launch(s, s.print("{s}/{s}", .{ releases_url, s.to }));
    try seePanels(s, 1, "the welcome is on screen");
    const new = try swapped(s, .{ .old = old, .within_s = 480 });
    try settled(s, new);
    try seePanels(s, 1, "it came back where it was");
    s.shot("updated-left-open");
}

const Swap = struct { old: []const u8, within_s: i64 };

/// The copy updating: swapped in, then back on its own. Returns the new pid.
fn swapped(s: *Session, swap: Swap) ![]const u8 {
    const start_s = command.nowSeconds(s.io);
    while (!try isInstalled(s, s.to_version)) {
        if (command.nowSeconds(s.io) - start_s > swap.within_s) {
            const now = (try installed(s)) orelse "";
            return s.die("still {s} after {d} s", .{ now, swap.within_s });
        }
        if (try running(s) == null) return s.die("{s} died before updating", .{s.from});
        try s.sleepMs(2000);
    }
    s.ok("swapped in {s} after {d} s", .{ s.to, command.nowSeconds(s.io) - start_s });
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (try running(s)) |new| {
            if (!std.mem.eql(u8, new, swap.old)) {
                s.ok("came back on its own, as {s}", .{s.to});
                return new;
            }
        }
        if (tries == 60) return s.die("{s} didn't come back after the update", .{s.to});
        try s.sleepMs(1000);
    }
}

/// What must be true of an update that's done.
fn settled(s: *Session, new: []const u8) !void {
    // Past its own first update check: it must not update, or restart, again.
    try s.sleepMs(30_000);
    if (!samePid(try running(s), new)) {
        return s.die("{s} died or restarted after updating", .{s.to});
    }
    if (!try isInstalled(s, s.to_version)) {
        return s.die("went on to {s} after updating", .{(try installed(s)) orelse ""});
    }
    const said = try command.capture(s.arena, s.io, &.{ program, "--version" }, .{});
    if (!std.mem.eql(u8, said.line(), s.print("nanolight {s}", .{s.to_version}))) {
        return s.die("the program says {s}", .{said.line()});
    }
    try trusted(s);
    const attributes = try command.capture(s.arena, s.io, &.{ "xattr", "-r", app }, .{});
    if (std.mem.indexOf(u8, attributes.stdout, "com.apple.quarantine") != null) {
        return s.die("the update came quarantined: macOS would ask on its next launch", .{});
    }
    if (try leftCopies(s)) |copies| return s.die("left copies in Applications: {s}", .{copies});
    if (exists(s, s.print("{s}/updates/{s}", .{ s.cache, s.to_version }))) {
        return s.die("left the update in its cache", .{});
    }
    s.ok("the update is notarized, unquarantined, and left nothing behind", .{});
}

fn leftCopies(s: *Session) !?[]const u8 {
    var applications = try Io.Dir.cwd().openDir(s.io, "/Applications", .{ .iterate = true });
    defer applications.close(s.io);
    var names: Io.Writer.Allocating = .init(s.arena);
    var entries = applications.iterate();
    while (try entries.next(s.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, ".Nanolight")) continue;
        try names.writer.print("{s} ", .{entry.name});
    }
    return if (names.written().len > 0) names.written() else null;
}

// ----- the app, as the system sees it -----

/// The app's copy in Applications, as the system sees it.
fn trusted(s: *Session) !void {
    if (try macos.signed(s.arena, s.io, app)) |said| return s.die("signature: {s}", .{said});
    const assessment = [_][]const u8{ "-t", "exec" };
    if (try macos.notarized(s.arena, s.io, &assessment, app)) |said| {
        return s.die("Gatekeeper: {s}", .{said});
    }
    if (try macos.stapled(s.arena, s.io, app, macos.staple_tries_default)) |_| {
        return s.die("no ticket stapled", .{});
    }
}

fn running(s: *Session) !?[]const u8 {
    const found = try command.capture(s.arena, s.io, &.{ "pgrep", "-f", program_pattern }, .{});
    var lines = std.mem.splitScalar(u8, found.stdout, '\n');
    const first = lines.first();
    return if (first.len > 0) first else null;
}

fn samePid(now: ?[]const u8, pid: []const u8) bool {
    return std.mem.eql(u8, now orelse "", pid);
}

fn installed(s: *Session) !?[]const u8 {
    const plist = app ++ "/Contents/Info.plist";
    const said = try command.capture(s.arena, s.io, &.{
        "plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist,
    }, .{});
    return if (said.ok()) said.line() else null;
}

fn isInstalled(s: *Session, version: []const u8) !bool {
    return std.mem.eql(u8, (try installed(s)) orelse "", version);
}

fn exists(s: *const Session, path: []const u8) bool {
    Io.Dir.cwd().access(s.io, path, .{}) catch return false;
    return true;
}

fn stop(s: *Session) !void {
    try kill(s, &.{ "pkill", "-f", program_pattern });
    var tries: u32 = 0;
    while (try running(s) != null) : (tries += 1) {
        if (tries == 20) return s.die("the app won't stop", .{});
        try s.sleepMs(500);
    }
}

/// Runs a pkill: finding nothing to stop is no failure.
fn kill(s: *Session, argv: []const []const u8) !void {
    _ = try command.capture(s.arena, s.io, argv, .{});
}

/// A tag's update, fetched once.
fn zipOf(s: *Session, tag: []const u8) ![]const u8 {
    const zip = s.print("{s}/{s}.zip", .{ s.work, tag });
    if (exists(s, zip)) return zip;
    const url = s.print("{s}/{s}/{s}", .{ releases_url, tag, release.macos_update });
    try command.run(s.io, &.{ "curl", "-fsSL", "--retry", "3", "-o", zip, url });
    return zip;
}

/// A tag's update unpacked into a fresh folder of its own.
fn unpack(s: *Session, tag: []const u8) ![]const u8 {
    s.unpacked_count += 1;
    const folder = s.print("{s}/unpack.{d}", .{ s.work, s.unpacked_count });
    try Io.Dir.cwd().createDir(s.io, folder, .default_dir);
    try command.run(s.io, &.{ "ditto", "-x", "-k", try zipOf(s, tag), folder });
    return folder;
}

/// A tag, as a person drags it to Applications, on a clean Mac.
fn install(s: *Session, tag: []const u8) !void {
    try stop(s);
    try Io.Dir.cwd().deleteTree(s.io, app);
    try Io.Dir.cwd().deleteTree(s.io, s.cache);
    _ = try command.capture(s.arena, s.io, &.{ "defaults", "delete", domain }, .{});
    try command.run(s.io, &.{ "defaults", "write", domain, "nanolight.hotkey", "-string", chord });
    const unpacked = try unpack(s, tag);
    try command.run(s.io, &.{ "ditto", s.print("{s}/Nanolight.app", .{unpacked}), app });
    try Io.Dir.cwd().deleteTree(s.io, unpacked);
    const now = (try installed(s)) orelse "";
    if (!std.mem.eql(u8, now, withoutV(tag))) return s.die("installed {s}, not {s}", .{ now, tag });
}

/// Someone past the welcome, as nearly everyone an update reaches is.
fn returning(s: *Session) !void {
    try command.run(s.io, &.{ "defaults", "write", domain, "nanolight.onboarded", "-string", "1" });
}

/// Opens the app reading `feed`; returns its pid.
fn launch(s: *Session, feed: []const u8) ![]const u8 {
    const environment = s.print("NANOUI_UPDATE_FEED={s}", .{feed});
    const log = s.workPath("app.log");
    try command.run(s.io, &.{ "open", "--stderr", log, "--env", environment, app });
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (try running(s)) |pid| return pid;
        if (tries == 60) return s.die("it never started", .{});
        try s.sleepMs(500);
    }
}

/// Waits for `count` panels on screen, which means `what`.
fn seePanels(s: *Session, count: usize, what: []const u8) !void {
    var tries: u32 = 0;
    while (screen.panelCount() != count) : (tries += 1) {
        if (tries == 40) {
            return s.die("{s}: {d} on screen, not {d}", .{ what, screen.panelCount(), count });
        }
        try s.sleepMs(250);
    }
    s.ok("{s}", .{what});
}

/// Waits for the app a search's Return should have opened.
fn opened(s: *Session, name: []const u8) !void {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const found = try command.capture(s.arena, s.io, &.{ "pgrep", "-x", name }, .{});
        if (found.ok()) break;
        if (tries == 40) return s.die("{s} never opened", .{name});
        try s.sleepMs(250);
    }
    s.ok("Return opened {s}", .{name});
}

/// Runs an AppleScript line; error.ScriptFailed when it fails.
fn osascript(s: *Session, script: []const u8) ![]const u8 {
    const said = try command.capture(s.arena, s.io, &.{ "osascript", "-e", script }, .{});
    if (!said.ok()) return error.ScriptFailed;
    return said.line();
}

fn keys(s: *Session, script: []const u8) !void {
    const line = s.print("tell application \"System Events\" to {s}", .{script});
    _ = osascript(s, line) catch return s.die("couldn't press keys: {s}", .{script});
}

fn hotkey(s: *Session) !void {
    try keys(s, "key code 45 using {control down, option down, command down}");
}

fn returnKey(s: *Session) !void {
    try keys(s, "key code 36");
}

fn frontmost(s: *Session) ![]const u8 {
    const script = "tell application \"System Events\" to " ++
        "name of first process whose frontmost is true";
    return osascript(s, script) catch "";
}

fn paneTitle(s: *Session) ![]const u8 {
    const script = "tell application \"System Events\" to " ++
        "name of window 1 of process \"System Settings\"";
    return osascript(s, script) catch "";
}

// ----- what a failure leaves to read -----

fn printTail(s: *const Session, path: []const u8) void {
    const limit: Io.Limit = .limited(command.output_bytes_max);
    const text = Io.Dir.cwd().readFileAlloc(s.io, path, s.arena, limit) catch return;
    if (text.len == 0) return;
    command.complain(s.io, "--- the app's log", .{});
    command.complain(s.io, "{s}", .{lastLines(text, log_tail_lines)});
}

fn lastLines(text: []const u8, count: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var seen: usize = 0;
    var index = trimmed.len;
    while (index > 0) : (index -= 1) {
        if (trimmed[index - 1] != '\n') continue;
        seen += 1;
        if (seen == count) return trimmed[index..];
    }
    return trimmed;
}

fn firstLines(text: []const u8, count: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte != '\n') continue;
        seen += 1;
        if (seen == count) return text[0..index];
    }
    return text;
}

/// The newest crash report of the app, if any.
fn printNewestCrash(s: *const Session) void {
    const home = s.environ.get("HOME") orelse return;
    const reports = s.print("{s}/Library/Logs/DiagnosticReports", .{home});
    var folder = Io.Dir.cwd().openDir(s.io, reports, .{ .iterate = true }) catch return;
    defer folder.close(s.io);
    var newest_name: ?[]const u8 = null;
    var newest_ns: i96 = 0;
    var entries = folder.iterate();
    while (entries.next(s.io) catch return) |entry| {
        if (std.mem.indexOf(u8, entry.name, "anolight") == null) continue;
        const stat = folder.statFile(s.io, entry.name, .{}) catch continue;
        const changed_ns = stat.mtime.toNanoseconds();
        if (newest_name != null and changed_ns <= newest_ns) continue;
        newest_name = s.arena.dupe(u8, entry.name) catch return;
        newest_ns = changed_ns;
    }
    const name = newest_name orelse return;
    const limit: Io.Limit = .limited(command.output_bytes_max);
    const text = folder.readFileAlloc(s.io, name, s.arena, limit) catch return;
    command.complain(s.io, "--- {s}/{s}", .{ reports, name });
    command.complain(s.io, "{s}", .{firstLines(text, crash_head_lines)});
}

test "a log's last lines and a report's first, as tail and head give them" {
    try std.testing.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd\n", 2));
    try std.testing.expectEqualStrings("a\nb", lastLines("a\nb\n", 5));
    try std.testing.expectEqualStrings("a\nb", firstLines("a\nb\nc\n", 2));
    try std.testing.expectEqualStrings("a", firstLines("a", 3));
}
