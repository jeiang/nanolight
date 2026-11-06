//! `zig build verify-release -- vX.Y.Z`: checks a published release as
//! someone who downloads it gets it: fetches the files from the release, and
//! checks the update feed agrees with them, that Apple's ticket is stapled to
//! each, that Gatekeeper takes them with the quarantine a browser leaves, and
//! that the signed app runs and draws.
//!
//! BASE overrides where the files come from (file:///..., to prove a bad
//! release fails). STAPLE_TRIES is how often a ticket is asked for (5).
//! KEEP_SNAPSHOT is where to keep the panel it drew. Safe on a developer's
//! Mac: files stay in a temporary folder, the app runs only headless
//! (--nanoui-snapshot, never a window; it reads this Mac's settings, and
//! writes none), and what's quarantined is assessed, never run.
//! `zig build verify-update` does what this can't: launches and updates for real.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const archive = @import("archive.zig");
const command = @import("command.zig");
const macos = @import("macos.zig");
const png = @import("png.zig");
const release = @import("release.zig");

const usage = "usage: zig build verify-release -- vX.Y.Z";
const releases_url = "https://github.com/jeiang/nanolight/releases/download";
/// A release that hangs fails instead of being waited for.
const draw_timeout_s = 60;
const snapshot_width_min = 100;
const snapshot_bytes_min = 4096;
const macos_min = "14.0";

const Verifier = struct {
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    tag: []const u8,
    version: []const u8,
    work: []const u8,
    staple_tries: u32,
    fails: u32 = 0,

    fn path(v: *const Verifier, parts: []const []const u8) []const u8 {
        const all = std.mem.concat(v.arena, []const u8, &.{ &.{v.work}, parts }) catch
            @panic("OOM");
        return std.fs.path.join(v.arena, all) catch @panic("OOM");
    }

    fn downloaded(v: *const Verifier, name: []const u8) []const u8 {
        return v.path(&.{ "dl", name });
    }

    /// Says whether a check held, and what it saw when it didn't.
    fn check(v: *Verifier, name: []const u8, outcome: anyerror!?[]const u8) void {
        const seen = outcome catch |err| @as(?[]const u8, @errorName(err));
        const text = seen orelse return command.say(v.io, "ok    {s}", .{name});
        command.say(v.io, "FAIL  {s}", .{name});
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (lines.next()) |line| command.say(v.io, "      {s}", .{line});
        v.fails += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2 or args[1].len == 0) {
        command.complain(io, usage, .{});
        std.process.exit(2);
    }
    const tag = args[1];
    const tries_text = init.environ_map.get("STAPLE_TRIES") orelse "";
    var verifier: Verifier = .{
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .tag = tag,
        .version = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag,
        .work = try command.temporaryFolder(arena, io, "nanolight-verify"),
        .staple_tries = std.fmt.parseInt(u32, tries_text, 10) catch macos.staple_tries_default,
    };
    if (verifier.staple_tries == 0) verifier.staple_tries = macos.staple_tries_default;
    const result = verify(&verifier);
    cleanUp(&verifier);
    try result;
    command.say(io, "", .{});
    if (verifier.fails > 0) {
        command.say(io, "{s}: {d} check(s) FAILED", .{ tag, verifier.fails });
        std.process.exit(1);
    }
    command.say(io, "{s}: all checks passed", .{tag});
}

fn cleanUp(v: *const Verifier) void {
    const mounted = v.path(&.{"mnt"});
    // best effort: nothing is mounted when a check failed before the attach.
    const detach = [_][]const u8{ "hdiutil", "detach", mounted, "-quiet", "-force" };
    // best effort: as above.
    _ = command.capture(v.arena, v.io, &detach, .{}) catch {};
    // best effort: a temporary folder.
    Io.Dir.cwd().deleteTree(v.io, v.work) catch {};
}

fn verify(v: *Verifier) !void {
    for ([_][]const u8{ "dl", "mnt", "home", "zip", "installed" }) |name| {
        try Io.Dir.cwd().createDir(v.io, v.path(&.{name}), .default_dir);
    }
    const base = v.environ.get("BASE") orelse
        try std.fmt.allocPrint(v.arena, "{s}/{s}", .{ releases_url, v.tag });
    command.say(v.io, "== {s} from {s}", .{ v.tag, base });
    try fetchAll(v, base);
    try feedChecks(v);
    try diskImageChecks(v);
    try installedChecks(v);
    try updateChecks(v);
}

fn fetchAll(v: *const Verifier, base: []const u8) !void {
    const mac = [_][]const u8{
        release.manifest_name,                 release.macos_disk_image,
        release.macos_disk_image ++ ".sha256", release.macos_update,
    };
    for (mac) |name| try fetch(v, base, name);
    for (release.pc_platforms) |platform| {
        var buffer: [release.name_bytes_max]u8 = undefined;
        const name = platform.archiveName(&buffer);
        try fetch(v, base, name);
        try fetch(v, base, try std.fmt.allocPrint(v.arena, "{s}.sha256", .{name}));
    }
}

fn fetch(v: *const Verifier, base: []const u8, name: []const u8) !void {
    const url = try std.fmt.allocPrint(v.arena, "{s}/{s}", .{ base, name });
    try command.run(v.io, &.{ "curl", "-fsSL", "--retry", "3", "-o", v.downloaded(name), url });
}

// ----- the feed -----

fn feedChecks(v: *Verifier) !void {
    const text = try Io.Dir.cwd().readFileAlloc(
        v.io,
        v.downloaded(release.manifest_name),
        v.arena,
        .limited(release.manifest_bytes_max),
    );
    const manifest = release.Manifest.parse(v.arena, text);
    const named = try std.fmt.allocPrint(v.arena, "manifest names {s}", .{v.version});
    v.check(named, feedVersion(v, manifest));
    var updates: [release.files_max][]const u8 = undefined;
    updates[0] = release.macos_update;
    for (release.pc_platforms, 1..) |platform, index| {
        var buffer: [release.name_bytes_max]u8 = undefined;
        updates[index] = try v.arena.dupe(u8, platform.archiveName(&buffer));
    }
    const update_names = updates[0 .. release.pc_platforms.len + 1];
    for (update_names) |name| {
        const label = try std.fmt.allocPrint(v.arena, "manifest's sha256 of {s}", .{name});
        v.check(label, feedSum(v, manifest, name));
    }
    v.check(".sha256 of " ++ release.macos_disk_image, sideSum(v, release.macos_disk_image));
    for (update_names[1..]) |name| {
        v.check(try std.fmt.allocPrint(v.arena, ".sha256 of {s}", .{name}), sideSum(v, name));
    }
    for (release.pc_platforms, update_names[1..]) |platform, name| {
        const label = try std.fmt.allocPrint(v.arena, "{s} holds the program", .{name});
        v.check(label, holdsProgram(v, platform, name));
    }
}

fn feedVersion(v: *const Verifier, parsed: anyerror!release.Manifest) !?[]const u8 {
    const manifest = try parsed;
    if (std.mem.eql(u8, manifest.version, v.version)) return null;
    return try std.fmt.allocPrint(v.arena, "manifest says {s}", .{manifest.version});
}

fn feedSum(v: *const Verifier, parsed: anyerror!release.Manifest, name: []const u8) !?[]const u8 {
    const manifest = try parsed;
    const got = try release.sha256File(v.io, Io.Dir.cwd(), v.downloaded(name));
    const want = manifest.sum(name) orelse "(none)";
    if (std.mem.eql(u8, want, &got)) return null;
    return try std.fmt.allocPrint(v.arena, "manifest {s}, file {s}", .{ want, &got });
}

/// The `.sha256` published beside a file.
fn sideSum(v: *const Verifier, name: []const u8) !?[]const u8 {
    const side = try std.fmt.allocPrint(v.arena, "{s}.sha256", .{v.downloaded(name)});
    const text = try Io.Dir.cwd().readFileAlloc(v.io, side, v.arena, .limited(1024));
    const want = release.parseSumLine(text) orelse "";
    const got = try release.sha256File(v.io, Io.Dir.cwd(), v.downloaded(name));
    if (std.mem.eql(u8, want, &got)) return null;
    return try std.fmt.allocPrint(v.arena, ".sha256 {s}, file {s}", .{ want, &got });
}

/// The program the portable updater looks for in its archive.
fn holdsProgram(v: *const Verifier, platform: release.Platform, name: []const u8) !?[]const u8 {
    var buffer: [release.name_bytes_max]u8 = undefined;
    const folder = try platform.folderName(&buffer, v.version);
    const wanted = try std.fmt.allocPrint(v.arena, "{s}/{s}", .{ folder, platform.programName() });
    if (try archive.holds(v.io, Io.Dir.cwd(), v.downloaded(name), platform.format(), wanted)) {
        return null;
    }
    return try std.fmt.allocPrint(v.arena, "no {s} in it", .{wanted});
}

// ----- the disk image, the app dragged from it, and the update -----

fn diskImageChecks(v: *Verifier) !void {
    const disk_image = v.downloaded(release.macos_disk_image);
    try quarantine(v, disk_image);
    v.check("disk image is whole", runs(v, &.{ "hdiutil", "verify", "-quiet", disk_image }));
    const signature = runs(v, &.{ "codesign", "--verify", "--strict", disk_image });
    v.check("disk image: signature holds", signature);
    v.check("disk image: ticket stapled", macos.stapled(v.arena, v.io, disk_image, v.staple_tries));
    const assessment = [_][]const u8{ "-t", "open", "--context", "context:primary-signature" };
    const gatekeeper = macos.notarized(v.arena, v.io, &assessment, disk_image);
    v.check("disk image: Gatekeeper, quarantined", gatekeeper);

    const mount = v.path(&.{"mnt"});
    try command.run(v.io, &.{
        "hdiutil",     "attach", disk_image,    "-nobrowse", "-readonly",
        "-noautoopen", "-quiet", "-mountpoint", mount,
    });
    const mounted = v.path(&.{ "mnt", "Nanolight.app" });
    v.check("disk image offers Applications", offersApplications(v));
    v.check("disk image's app: signed, hardened", macos.signed(v.arena, v.io, mounted));
    const stapled = macos.stapled(v.arena, v.io, mounted, v.staple_tries);
    v.check("disk image's app: ticket stapled", stapled);
    const app_gatekeeper = macos.notarized(v.arena, v.io, &.{ "-t", "exec" }, mounted);
    v.check("disk image's app: Gatekeeper", app_gatekeeper);
    const says = try std.fmt.allocPrint(v.arena, "disk image's app: says {s}", .{v.version});
    v.check(says, saysVersion(v, mounted));
}

/// Dragged to Applications, as a browser's download comes: assessed only.
/// Run, macOS could ask about it on this screen.
fn installedChecks(v: *Verifier) !void {
    const mounted = v.path(&.{ "mnt", "Nanolight.app" });
    const installed = v.path(&.{ "installed", "Nanolight.app" });
    try command.run(v.io, &.{ "ditto", mounted, installed });
    try quarantine(v, installed);
    const assessment = [_][]const u8{ "-t", "exec" };
    const gatekeeper = macos.notarized(v.arena, v.io, &assessment, installed);
    v.check("installed copy: Gatekeeper, quarantined", gatekeeper);
    const policy = runs(v, &.{ "syspolicy_check", "distribution", installed });
    v.check("installed copy: syspolicy_check", policy);
    try command.run(v.io, &.{ "xattr", "-r", "-d", "com.apple.quarantine", installed });
    const program = v.path(&.{ "installed", "Nanolight.app", "Contents", "MacOS", "nanolight" });
    v.check("installed copy: arm64, for macOS 14", forMacos14(v, program));
    const prints = try std.fmt.allocPrint(v.arena, "installed copy: runs, says {s}", .{v.version});
    v.check(prints, printsVersion(v, program));
    const snapshot = v.path(&.{"panel.png"});
    v.check("installed copy: runs hardened, draws", draws(v, program, snapshot));
    if (v.environ.get("KEEP_SNAPSHOT")) |keep| {
        // best effort: keeping the picture is a courtesy, not a check.
        Io.Dir.cwd().copyFile(snapshot, Io.Dir.cwd(), keep, v.io, .{}) catch {};
    }
}

fn updateChecks(v: *Verifier) !void {
    try command.run(v.io, &.{
        "ditto", "-x", "-k", v.downloaded(release.macos_update), v.path(&.{"zip"}),
    });
    const update = v.path(&.{ "zip", "Nanolight.app" });
    const mounted = v.path(&.{ "mnt", "Nanolight.app" });
    v.check("update: signed, hardened", macos.signed(v.arena, v.io, update));
    v.check("update: ticket stapled", macos.stapled(v.arena, v.io, update, v.staple_tries));
    v.check("update: Gatekeeper", macos.notarized(v.arena, v.io, &.{ "-t", "exec" }, update));
    const says = try std.fmt.allocPrint(v.arena, "update: says {s}", .{v.version});
    v.check(says, saysVersion(v, update));
    v.check("update is the disk image's build", sameBuild(v, update, mounted));
}

// ----- what each check asks -----

/// The program exits 0; what it printed, when it doesn't.
fn runs(v: *const Verifier, argv: []const []const u8) !?[]const u8 {
    const result = try command.capture(v.arena, v.io, argv, .{});
    return if (result.ok()) null else result.text;
}

fn quarantine(v: *const Verifier, path: []const u8) !void {
    var uuid: [16]u8 = undefined;
    v.io.random(&uuid);
    uuid[6] = (uuid[6] & 0x0f) | 0x40;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    const hex = std.fmt.bytesToHex(uuid, .upper);
    const value = try std.fmt.allocPrint(v.arena, "0083;{x};Safari;{s}-{s}-{s}-{s}-{s}", .{
        command.nowSeconds(v.io), hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
    });
    try command.run(v.io, &.{ "xattr", "-r", "-w", "com.apple.quarantine", value, path });
}

fn offersApplications(v: *const Verifier) !?[]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const link = v.path(&.{ "mnt", "Applications" });
    const length = Io.Dir.cwd().readLink(v.io, link, &buffer) catch |err| return @errorName(err);
    if (std.mem.eql(u8, buffer[0..length], "/Applications")) return null;
    return try v.arena.dupe(u8, buffer[0..length]);
}

fn saysVersion(v: *const Verifier, app: []const u8) !?[]const u8 {
    const plist = try std.fs.path.join(v.arena, &.{ app, "Contents", "Info.plist" });
    const result = try command.capture(v.arena, v.io, &.{
        "plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", plist,
    }, .{});
    if (result.ok() and std.mem.eql(u8, result.line(), v.version)) return null;
    return try std.fmt.allocPrint(v.arena, "Info.plist says {s}", .{result.line()});
}

/// The disk image's app and the update's are one signed build.
fn sameBuild(v: *const Verifier, update: []const u8, mounted: []const u8) !?[]const u8 {
    const a = try cdHash(v, update);
    const b = try cdHash(v, mounted);
    if (a.len > 0 and std.mem.eql(u8, a, b)) return null;
    return try std.fmt.allocPrint(v.arena, "{s} / {s}", .{ a, b });
}

fn cdHash(v: *const Verifier, app: []const u8) ![]const u8 {
    const result = try command.capture(v.arena, v.io, &.{ "codesign", "-dvvv", app }, .{});
    var lines = std.mem.splitScalar(u8, result.text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CDHash=")) return line;
    }
    return "";
}

fn forMacos14(v: *const Verifier, program: []const u8) !?[]const u8 {
    const archs = try command.capture(v.arena, v.io, &.{ "lipo", "-archs", program }, .{});
    if (!std.mem.eql(u8, archs.line(), "arm64")) return archs.text;
    const build = try command.capture(v.arena, v.io, &.{ "vtool", "-show-build", program }, .{});
    var lines = std.mem.splitScalar(u8, build.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, line, "minos " ++ macos_min)) return null;
    }
    return build.text;
}

fn printsVersion(v: *const Verifier, program: []const u8) !?[]const u8 {
    const result = try command.capture(v.arena, v.io, &.{ program, "--version" }, .{});
    const want = try std.fmt.allocPrint(v.arena, "nanolight {s}", .{v.version});
    if (result.ok() and std.mem.eql(u8, result.line(), want)) return null;
    return result.text;
}

/// Headless, with an alarm: a release that hangs fails instead of waiting.
fn draws(v: *const Verifier, program: []const u8, snapshot: []const u8) !?[]const u8 {
    var environ = try v.environ.clone(v.arena);
    const home = v.path(&.{"home"});
    try environ.put("HOME", home);
    try environ.put("CFFIXED_USER_HOME", home);
    const flag = try std.fmt.allocPrint(v.arena, "--nanoui-snapshot={s}", .{snapshot});
    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .fromSeconds(draw_timeout_s),
        .clock = .awake,
    } };
    const result = command.capture(v.arena, v.io, &.{ program, flag }, .{
        .timeout = timeout,
        .environ_map = &environ,
    }) catch |err| switch (err) {
        error.Timeout => return "still running after 60 s",
        else => return err,
    };
    if (!result.ok()) return result.text;
    const limit: Io.Limit = .limited(command.output_bytes_max);
    const bytes = Io.Dir.cwd().readFileAlloc(v.io, snapshot, v.arena, limit) catch |err|
        return @errorName(err);
    const width = png.widthOf(bytes) orelse 0;
    if (width > snapshot_width_min and bytes.len > snapshot_bytes_min) return null;
    return try std.fmt.allocPrint(v.arena, "{d} wide, {d} bytes", .{ width, bytes.len });
}
