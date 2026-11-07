//! `zig build verify-release -- vX.Y.Z`: checks a published release as
//! someone who downloads it gets it: fetches the files from the release, and
//! checks the update feed agrees with them, that Apple's ticket is stapled to
//! each, that Gatekeeper takes them with the quarantine a browser leaves, and
//! that the signed app runs and draws. Safe on a developer's Mac: files stay
//! in a temporary folder, the app runs only headless (--nanoui-snapshot,
//! never a window; it reads no settings, and writes none), and
//! what's quarantined is assessed, never run.
//! `zig build verify-update` does what this can't: launches and updates for real.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const archive = @import("archive.zig");
const command = @import("command.zig");
const mac_verify = @import("mac_verify.zig");
const macos = @import("macos.zig");
const png = @import("png.zig");
const release = @import("release.zig");

const usage = "usage: zig build verify-release -- vX.Y.Z";
/// A release that hangs fails instead of being waited for.
const draw_timeout_s = 60;
const snapshot_width_min = 100;
const snapshot_bytes_min = 4096;

const Verifier = struct {
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    tag: []const u8,
    version: []const u8,
    work: []const u8,
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
    var verifier: Verifier = .{
        .arena = arena,
        .io = io,
        .environ = init.environ_map,
        .tag = tag,
        .version = release.versionOfTag(tag),
        .work = try command.temporaryFolder(arena, io, "nanolight-verify"),
    };
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
    const detach = [_][]const u8{ "hdiutil", "detach", mounted, "-quiet", "-force" };
    // best effort: nothing is mounted when a check failed before the attach.
    _ = command.capture(v.arena, v.io, &detach, .{}) catch {};
    // best effort: the folder in /tmp holds only downloads, and macOS clears /tmp.
    Io.Dir.cwd().deleteTree(v.io, v.work) catch {};
}

fn verify(v: *Verifier) !void {
    for ([_][]const u8{ "dl", "mnt", "home", "zip", "installed" }) |name| {
        try Io.Dir.cwd().createDir(v.io, v.path(&.{name}), .default_dir);
    }
    const base = try std.fmt.allocPrint(v.arena, "{s}/{s}", .{ release.releases_url, v.tag });
    command.say(v.io, "== {s} from {s}", .{ v.tag, base });
    try fetchAll(v, base);
    try feedChecks(v);
    try diskImageChecks(v);
    try installedChecks(v);
    try updateChecks(v);
}

fn fetchAll(v: *const Verifier, base: []const u8) !void {
    const mac = [_][]const u8{
        release.manifest_name,                          release.macos_disk_image,
        release.macos_disk_image ++ release.sum_suffix, release.macos_update,
    };
    for (mac) |name| try fetch(v, base, name);
    for (release.pc_platforms) |platform| {
        var buffer: [release.name_bytes_max]u8 = undefined;
        const name = platform.archiveName(&buffer);
        try fetch(v, base, name);
        try fetch(v, base, try std.mem.concat(v.arena, u8, &.{ name, release.sum_suffix }));
    }
}

fn fetch(v: *const Verifier, base: []const u8, name: []const u8) !void {
    const url = try std.fmt.allocPrint(v.arena, "{s}/{s}", .{ base, name });
    try mac_verify.fetch(v.io, url, v.downloaded(name));
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
    const side = try std.mem.concat(v.arena, u8, &.{ v.downloaded(name), release.sum_suffix });
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
    v.check("disk image: ticket stapled", macos.stapled(v.arena, v.io, disk_image));
    const assessment = [_][]const u8{ "-t", "open", "--context", "context:primary-signature" };
    const gatekeeper = macos.notarized(v.arena, v.io, &assessment, disk_image);
    v.check("disk image: Gatekeeper, quarantined", gatekeeper);

    const mount = v.path(&.{"mnt"});
    try command.run(v.io, &.{
        "hdiutil",     "attach", disk_image,    "-nobrowse", "-readonly",
        "-noautoopen", "-quiet", "-mountpoint", mount,
    });
    const mounted = v.path(&.{ "mnt", release.bundle_name });
    v.check("disk image offers Applications", offersApplications(v));
    v.check("disk image's app: signed, hardened", macos.signed(v.arena, v.io, mounted));
    const stapled = macos.stapled(v.arena, v.io, mounted);
    v.check("disk image's app: ticket stapled", stapled);
    const app_gatekeeper = macos.notarized(v.arena, v.io, &.{ "-t", "exec" }, mounted);
    v.check("disk image's app: Gatekeeper", app_gatekeeper);
    const says = try std.fmt.allocPrint(v.arena, "disk image's app: says {s}", .{v.version});
    v.check(says, saysVersion(v, mounted));
}

/// Dragged to Applications, as a browser's download comes: assessed only.
/// Run, macOS could ask about it on this screen.
fn installedChecks(v: *Verifier) !void {
    const mounted = v.path(&.{ "mnt", release.bundle_name });
    const installed = v.path(&.{ "installed", release.bundle_name });
    try command.run(v.io, &.{ "ditto", mounted, installed });
    try quarantine(v, installed);
    const assessment = [_][]const u8{ "-t", "exec" };
    const gatekeeper = macos.notarized(v.arena, v.io, &assessment, installed);
    v.check("installed copy: Gatekeeper, quarantined", gatekeeper);
    const policy = runs(v, &.{ "syspolicy_check", "distribution", installed });
    v.check("installed copy: syspolicy_check", policy);
    try command.run(v.io, &.{ "xattr", "-r", "-d", "com.apple.quarantine", installed });
    const program = v.path(&.{ "installed", release.bundle_name, release.bundle_program });
    const built_for = "installed copy: arm64, for macOS " ++ release.macos_min_text;
    v.check(built_for, forMinimum(v, program));
    const prints = try std.fmt.allocPrint(v.arena, "installed copy: runs, says {s}", .{v.version});
    v.check(prints, printsVersion(v, program));
    v.check("installed copy: runs hardened, draws", draws(v, program, v.path(&.{"panel.png"})));
}

fn updateChecks(v: *Verifier) !void {
    try command.run(v.io, &.{
        "ditto", "-x", "-k", v.downloaded(release.macos_update), v.path(&.{"zip"}),
    });
    const update = v.path(&.{ "zip", release.bundle_name });
    const mounted = v.path(&.{ "mnt", release.bundle_name });
    v.check("update: signed, hardened", macos.signed(v.arena, v.io, update));
    v.check("update: ticket stapled", macos.stapled(v.arena, v.io, update));
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
    const said = try mac_verify.plistVersion(v.arena, v.io, app) orelse "(none)";
    if (std.mem.eql(u8, said, v.version)) return null;
    return try std.fmt.allocPrint(v.arena, "Info.plist says {s}", .{said});
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

fn forMinimum(v: *const Verifier, program: []const u8) !?[]const u8 {
    const archs = try command.capture(v.arena, v.io, &.{ "lipo", "-archs", program }, .{});
    if (!std.mem.eql(u8, archs.line(), "arm64")) return archs.text;
    return macos.forMinimum(v.arena, v.io, program);
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
