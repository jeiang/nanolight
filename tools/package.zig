//! `zig build package -Dversion=X.Y.Z`: a release's files, in zig-out/package.
//!
//!   nanolight-macos-arm64.dmg         the app, to drag to Applications (Mac hosts)
//!   nanolight-macos-arm64.zip         the app, which the Mac's updater fetches
//!   nanolight-windows-x86_64.zip      nanolight.exe
//!   nanolight-linux-x86_64.tar.gz     nanolight, nanolight.desktop, nanolight.png
//!   nanolight-linux-aarch64.tar.gz    the same, for 64-bit Arm
//!   nanolight-*-symbols.*             each build's debug symbols (the programs are stripped)
//!   manifest.json, <file>.sha256      the update feed, written once from all of the above
//!
//! Each Windows and Linux archive holds one folder, nanolight-<version>-<os>-<arch>. The
//! app's updater (nanoui's update_portable.zig) finds the program in it, checks it says its
//! version (`--version`), and puts it where the running one is.
//!
//! The Mac's app is signed with $CODESIGN_IDENTITY (a "Developer ID Application" identity
//! in the keychain) when it is set, else ad hoc. The app and the disk image are notarized
//! and stapled when it is set and either NOTARY_PROFILE (a profile saved with
//! `xcrun notarytool store-credentials`) or NOTARY_KEY_PATH, NOTARY_KEY_ID and
//! NOTARY_ISSUER_ID (an App Store Connect API key) are set. Only a build signed by a team
//! updates itself (nanoui's updater checks the new bundle is signed by the running one's).
//!
//! build.zig builds every program and passes them here:
//!
//!   package OUT VERSION --icon PNG [--macos APP] [--pc OS-ARCH PROGRAM SYMBOLS]...
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const archive = @import("archive.zig");
const command = @import("command.zig");
const macos = @import("macos.zig");
const release = @import("release.zig");

/// The largest program, or debug file, an archive takes.
const file_bytes_max = 512 << 20;
const icon_bytes_max = 1 << 20;
/// The macOS the app is built for (build.zig's package target).
const macos_min = "14.0";

const desktop_entry =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=Nanolight
    \\Comment=A launcher: apps, math, Google and script commands
    \\Exec=nanolight
    \\Icon=nanolight
    \\Categories=Utility;
    \\
;

const PcBuild = struct {
    platform: release.Platform,
    program: []const u8,
    symbols: []const u8,
};

const Plan = struct {
    out: []const u8,
    version: []const u8,
    icon: []const u8,
    macos_app: ?[]const u8 = null,
    pc_builds: [release.pc_platforms.len]PcBuild = undefined,
    pc_count: usize = 0,

    fn parse(args: []const []const u8) !Plan {
        if (args.len < 3) return error.Usage;
        var plan: Plan = .{ .out = args[1], .version = args[2], .icon = "" };
        if (plan.version.len == 0 or plan.version.len > release.version_bytes_max) {
            return error.Usage;
        }
        var index: usize = 3;
        while (index < args.len) {
            const flag = args[index];
            if (std.mem.eql(u8, flag, "--icon") and index + 1 < args.len) {
                plan.icon = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, flag, "--macos") and index + 1 < args.len) {
                plan.macos_app = args[index + 1];
                index += 2;
            } else if (std.mem.eql(u8, flag, "--pc") and index + 3 < args.len) {
                if (plan.pc_count == plan.pc_builds.len) return error.Usage;
                const platform = release.Platform.parse(args[index + 1]) orelse return error.Usage;
                plan.pc_builds[plan.pc_count] = .{
                    .platform = platform,
                    .program = args[index + 2],
                    .symbols = args[index + 3],
                };
                plan.pc_count += 1;
                index += 4;
            } else return error.Usage;
        }
        if (plan.icon.len == 0) return error.Usage;
        return plan;
    }
};

/// What this run has made, in order, for the feed.
const Made = struct {
    names: [release.files_max][]const u8 = undefined,
    updates: [release.files_max]bool = undefined,
    count: usize = 0,

    fn add(made: *Made, name: []const u8, options: struct { update: bool }) void {
        assert(made.count < made.names.len);
        made.names[made.count] = name;
        made.updates[made.count] = options.update;
        made.count += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const plan = Plan.parse(args) catch |err| {
        command.complain(init.io, "usage: package OUT VERSION --icon PNG [--macos APP] " ++
            "[--pc OS-ARCH PROGRAM SYMBOLS]...", .{});
        return err;
    };
    const io = init.io;
    // This run makes everything the folder holds: what an earlier one left goes first.
    try Io.Dir.cwd().deleteTree(io, plan.out);
    try Io.Dir.cwd().createDirPath(io, plan.out);
    var out = try Io.Dir.cwd().openDir(io, plan.out, .{});
    defer out.close(io);

    var made: Made = .{};
    if (plan.macos_app) |app| {
        const mac: Mac = .{ .io = io, .arena = arena, .out = plan.out, .app = app };
        try mac.package(init.environ_map, &made);
    }
    const mtime_s: u64 = @intCast(command.nowSeconds(io));
    for (plan.pc_builds[0..plan.pc_count]) |build| {
        try packagePc(.{ .gpa = init.gpa, .arena = arena, .io = io, .out = out }, .{
            .plan = plan,
            .build = build,
            .mtime_s = mtime_s,
        }, &made);
    }
    var report_buffer: [4096]u8 = undefined;
    var report = Io.File.stdout().writer(io, &report_buffer);
    try writeFeed(arena, io, out, .{
        .version = plan.version,
        .made = &made,
        .report = &report.interface,
    });
    try report.interface.flush();
}

// ----- the Mac -----

const Mac = struct {
    io: Io,
    arena: std.mem.Allocator,
    out: []const u8,
    /// Nanolight.app as `zig build` made it, with its program's debug information.
    app: []const u8,

    fn path(mac: Mac, name: []const u8) []const u8 {
        return std.fs.path.join(mac.arena, &.{ mac.out, name }) catch @panic("OOM");
    }

    fn package(mac: Mac, environ: *const std.process.Environ.Map, made: *Made) !void {
        const identity: macos.Identity = if (environ.get("CODESIGN_IDENTITY")) |name|
            (if (name.len > 0) .{ .developer_id = name } else .ad_hoc)
        else
            .ad_hoc;
        const notary = notaryOf(environ, identity);
        try mac.checkMinimum();
        const bundle = mac.path("Nanolight.app");
        // The build's copy is read-only (the build cache's files): a writable one.
        try command.run(mac.io, &.{ "ditto", mac.app, bundle });
        try command.run(mac.io, &.{ "chmod", "-R", "u+w", bundle });
        try mac.splitSymbols(bundle);
        made.add(release.macos_symbols, .{ .update = false });

        try macos.sign(mac.io, bundle, identity);
        if (notary) |service| {
            const upload = mac.path("Nanolight.zip");
            try command.run(mac.io, &.{ "ditto", "-c", "-k", "--keepParent", bundle, upload });
            try macos.notarize(mac.io, upload, service);
            try macos.staple(mac.io, bundle);
            try Io.Dir.cwd().deleteFile(mac.io, upload);
        }

        const disk_image = mac.path(release.macos_disk_image);
        try mac.makeDiskImage(bundle, disk_image);
        try macos.sign(mac.io, disk_image, identity);
        if (notary) |service| {
            try macos.notarize(mac.io, disk_image, service);
            try macos.staple(mac.io, disk_image);
        }
        made.add(release.macos_disk_image, .{ .update = false });

        // The update: the (stapled) app zipped, which the manifest names.
        const update = mac.path(release.macos_update);
        try command.run(mac.io, &.{ "ditto", "-c", "-k", "--keepParent", bundle, update });
        made.add(release.macos_update, .{ .update = true });
        try mac.check(bundle, .{ .disk_image = disk_image, .notarized = notary != null });
    }

    /// For macOS 14 and Apple silicon from the M1 on: a native build would
    /// need the macOS and the CPU it was built on.
    fn checkMinimum(mac: Mac) !void {
        const program = try std.fs.path.join(mac.arena, &.{ mac.app, "Contents/MacOS/nanolight" });
        const argv = [_][]const u8{ "vtool", "-show-build", program };
        const shown = try command.capture(mac.arena, mac.io, &argv, .{});
        var lines = std.mem.splitScalar(u8, shown.stdout, '\n');
        while (lines.next()) |line| {
            if (std.mem.endsWith(u8, line, "minos " ++ macos_min)) return;
        }
        command.complain(mac.io, "Nanolight is not built for macOS {s}:\n{s}", .{
            macos_min, shown.text,
        });
        return error.WrongMinimumMacos;
    }

    /// Keeps the program's debug information as a dSYM, zipped beside the
    /// app, and strips the program that ships. Both keep the build's UUID,
    /// which ties a crash report to its symbols.
    fn splitSymbols(mac: Mac, bundle: []const u8) !void {
        const program = try std.fs.path.join(mac.arena, &.{ bundle, "Contents/MacOS/nanolight" });
        const dsym = mac.path("Nanolight.app.dSYM");
        try command.run(mac.io, &.{ "xcrun", "dsymutil", program, "-o", dsym });
        try command.run(mac.io, &.{ "xcrun", "strip", program });
        const symbols = mac.path(release.macos_symbols);
        try command.run(mac.io, &.{ "ditto", "-c", "-k", "--keepParent", dsym, symbols });
        try Io.Dir.cwd().deleteTree(mac.io, dsym);
    }

    /// The disk image: the app, and Applications to drag it to.
    fn makeDiskImage(mac: Mac, bundle: []const u8, disk_image: []const u8) !void {
        const stage = mac.path("dmg");
        try Io.Dir.cwd().createDirPath(mac.io, stage);
        const staged = try std.fs.path.join(mac.arena, &.{ stage, "Nanolight.app" });
        try command.run(mac.io, &.{ "ditto", bundle, staged });
        const link = try std.fs.path.join(mac.arena, &.{ stage, "Applications" });
        try Io.Dir.cwd().symLink(mac.io, "/Applications", link, .{ .is_directory = true });
        try command.run(mac.io, &.{
            "hdiutil", "create", "-quiet",  "-volname", "Nanolight", "-srcfolder", stage,
            "-fs",     "HFS+",   "-format", "UDZO",     "-ov",       disk_image,
        });
        try Io.Dir.cwd().deleteTree(mac.io, stage);
    }

    /// What release.yml checked after packaging: the signature, the image,
    /// and Apple's tickets when they were asked for.
    fn check(mac: Mac, bundle: []const u8, options: struct {
        disk_image: []const u8,
        notarized: bool,
    }) !void {
        try command.run(mac.io, &.{ "codesign", "--verify", "--strict", "--verbose=2", bundle });
        try command.run(mac.io, &.{ "hdiutil", "verify", options.disk_image });
        if (!options.notarized) return;
        for ([_][]const u8{ bundle, options.disk_image }) |stapled_path| {
            const tries = macos.staple_tries_default;
            if (try macos.stapled(mac.arena, mac.io, stapled_path, tries)) |said| {
                command.complain(mac.io, "no ticket stapled to {s}:\n{s}", .{ stapled_path, said });
                return error.NotStapled;
            }
        }
    }
};

/// Notarizing needs a Developer ID and either notary credential.
fn notaryOf(environ: *const std.process.Environ.Map, identity: macos.Identity) ?macos.Notary {
    if (identity == .ad_hoc) return null;
    if (nonEmpty(environ, "NOTARY_PROFILE")) |profile| return .{ .profile = profile };
    const key_path = nonEmpty(environ, "NOTARY_KEY_PATH") orelse return null;
    return .{ .api_key = .{
        .path = key_path,
        .id = environ.get("NOTARY_KEY_ID") orelse "",
        .issuer = environ.get("NOTARY_ISSUER_ID") orelse "",
    } };
}

fn nonEmpty(environ: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = environ.get(name) orelse return null;
    return if (value.len > 0) value else null;
}

// ----- Windows and Linux -----

const Folders = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    out: Io.Dir,
};

const PcJob = struct {
    plan: Plan,
    build: PcBuild,
    mtime_s: u64,
};

/// The program's archive, and its debug symbols' beside it.
fn packagePc(folders: Folders, job: PcJob, made: *Made) !void {
    const io = folders.io;
    const gpa = folders.gpa;
    const platform = job.build.platform;
    var folder_buffer: [release.name_bytes_max]u8 = undefined;
    const folder = try platform.folderName(&folder_buffer, job.plan.version);
    const cwd = Io.Dir.cwd();
    const program = try cwd.readFileAlloc(io, job.build.program, gpa, .limited(file_bytes_max));
    defer gpa.free(program);
    const icon = try cwd.readFileAlloc(io, job.plan.icon, gpa, .limited(icon_bytes_max));
    defer gpa.free(icon);

    var entries: Entries = .{ .arena = folders.arena, .folder = folder };
    try entries.add("", "", 0o755);
    try entries.add(platform.programName(), program, 0o755);
    if (platform.os == .linux) {
        try entries.add("nanolight.desktop", desktop_entry, 0o644);
        try entries.add("nanolight.png", icon, 0o644);
    }
    var name_buffer: [release.name_bytes_max]u8 = undefined;
    const name = try folders.arena.dupe(u8, platform.archiveName(&name_buffer));
    try writeArchive(folders, .{
        .name = name,
        .format = platform.format(),
        .mtime_s = job.mtime_s,
    }, entries.slice());
    made.add(name, .{ .update = true });

    const symbols = try cwd.readFileAlloc(io, job.build.symbols, gpa, .limited(file_bytes_max));
    defer gpa.free(symbols);
    entries.count = 1;
    try entries.add(platform.symbolsFileName(), symbols, 0o644);
    const symbols_name = try folders.arena.dupe(u8, platform.symbolsArchiveName(&name_buffer));
    try writeArchive(folders, .{
        .name = symbols_name,
        .format = platform.format(),
        .mtime_s = job.mtime_s,
    }, entries.slice());
    made.add(symbols_name, .{ .update = false });
}

/// An archive's entries, each in its one folder (the folder itself named "").
const Entries = struct {
    arena: std.mem.Allocator,
    folder: []const u8,
    items: [archive.entries_max]archive.Entry = undefined,
    count: usize = 0,

    fn add(entries: *Entries, name: []const u8, data: []const u8, mode: u32) !void {
        assert(entries.count < entries.items.len);
        entries.items[entries.count] = .{
            .name = try std.fmt.allocPrint(entries.arena, "{s}/{s}", .{ entries.folder, name }),
            .data = data,
            .mode = mode,
        };
        entries.count += 1;
    }

    fn slice(entries: *const Entries) []const archive.Entry {
        return entries.items[0..entries.count];
    }
};

const ArchiveOptions = struct {
    name: []const u8,
    format: archive.Format,
    mtime_s: u64,
};

fn writeArchive(folders: Folders, options: ArchiveOptions, entries: []const archive.Entry) !void {
    const file = try folders.out.createFile(folders.io, options.name, .{});
    defer file.close(folders.io);
    var buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(folders.io, &buffer);
    try archive.write(folders.gpa, &writer.interface, options.format, entries, options.mtime_s);
    try writer.interface.flush();
}

// ----- the feed: the one writer of manifest.json and the sums -----

const FeedOptions = struct {
    version: []const u8,
    made: *const Made,
    /// Where each sum line and the manifest are shown, as `tee` and `cat` showed them.
    report: *Io.Writer,
};

/// A `.sha256` beside every file made, and the manifest naming each update,
/// whichever builds this host made: none can drop another's entry.
fn writeFeed(arena: std.mem.Allocator, io: Io, out: Io.Dir, options: FeedOptions) !void {
    const made = options.made;
    var entries: [release.files_max]release.FeedEntry = undefined;
    var updates_count: usize = 0;
    for (made.names[0..made.count], made.updates[0..made.count]) |name, update| {
        const sum = try release.sha256File(io, out, name);
        var line: Io.Writer.Allocating = .init(arena);
        try release.writeSumLine(&line.writer, sum, name);
        const sum_name = try std.fmt.allocPrint(arena, "{s}.sha256", .{name});
        try out.writeFile(io, .{ .sub_path = sum_name, .data = line.written() });
        try options.report.writeAll(line.written());
        if (!update) continue;
        entries[updates_count] = .{ .name = name, .sha256 = sum };
        updates_count += 1;
    }
    var manifest: Io.Writer.Allocating = .init(arena);
    try release.writeManifest(&manifest.writer, options.version, entries[0..updates_count]);
    try out.writeFile(io, .{ .sub_path = release.manifest_name, .data = manifest.written() });
    try options.report.writeAll(manifest.written());
}

test {
    _ = archive;
    _ = macos;
    _ = release;
}

test "a plan takes the Mac's app and each other build, in any order" {
    const args = [_][]const u8{
        "package",       "out",     "1.2.3",         "--pc",
        "linux-aarch64", "bin/a",   "bin/a.debug",   "--icon",
        "icon.png",      "--macos", "Nanolight.app",
    };
    const plan = try Plan.parse(&args);
    try std.testing.expectEqualStrings("Nanolight.app", plan.macos_app.?);
    try std.testing.expectEqual(@as(usize, 1), plan.pc_count);
    try std.testing.expectEqual(std.Target.Cpu.Arch.aarch64, plan.pc_builds[0].platform.arch);
    try std.testing.expectError(error.Usage, Plan.parse(args[0..5]));
    const unknown = [_][]const u8{
        "package", "out", "1", "--icon", "i", "--pc", "linux-mips", "a", "b",
    };
    try std.testing.expectError(error.Usage, Plan.parse(&unknown));
}

test "the feed names every update made, Mac's and the others', and sums every file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var made: Made = .{};
    const files = [_]struct { []const u8, bool }{
        .{ "nanolight-windows-x86_64.zip", true },
        .{ "nanolight-windows-x86_64-symbols.zip", false },
        .{ release.macos_update, true },
        .{ release.macos_disk_image, false },
    };
    for (files) |file| {
        try tmp.dir.writeFile(io, .{ .sub_path = file[0], .data = file[0] });
        made.add(file[0], .{ .update = file[1] });
    }
    var report: Io.Writer.Allocating = .init(arena);
    try writeFeed(arena, io, tmp.dir, .{
        .version = "1.2.3",
        .made = &made,
        .report = &report.writer,
    });
    const text = try tmp.dir.readFileAlloc(io, release.manifest_name, arena, .limited(4096));
    // What was shown ends with the manifest, as `cat` showed it.
    try std.testing.expect(std.mem.endsWith(u8, report.written(), text));
    const manifest = try release.Manifest.parse(arena, text);
    try std.testing.expectEqualStrings("1.2.3", manifest.version);
    try std.testing.expectEqual(@as(usize, 2), manifest.files.count());
    const windows_sum = release.sha256Hex(files[0][0]);
    try std.testing.expectEqualStrings(&windows_sum, manifest.sum(files[0][0]).?);
    try std.testing.expectEqual(null, manifest.sum(release.macos_disk_image));
    const side_name = release.macos_disk_image ++ ".sha256";
    const side = try tmp.dir.readFileAlloc(io, side_name, arena, .limited(256));
    const disk_image_sum = release.sha256Hex(release.macos_disk_image);
    try std.testing.expectEqualStrings(&disk_image_sum, release.parseSumLine(side).?);
}
