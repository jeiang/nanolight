//! A release, spelled once for build.zig, the app (through build.zig's
//! build_options), tools/package.zig and the verifiers: where it is
//! published, the Mac's bundle, each build's files, and its update feed. The
//! feed is `manifest.json`, which the app's updater reads (nanoui's
//! update.zig and update_portable.zig):
//!
//!     {"version":"0.2.7","files":{"nanolight-macos-arm64.zip":{"sha256":"…"}}}
//!
//! and a `<file>.sha256` beside each file, as `shasum -a 256` prints it.
const std = @import("std");
const assert = std.debug.assert;
const sha256 = std.crypto.hash.sha2.Sha256;
const archive = @import("archive.zig");

/// The longest name of a release's file, and of its version.
pub const name_bytes_max = 96;
pub const version_bytes_max = 64;
/// The most files one release attaches (the Mac's three, two per other build).
pub const files_max = 16;
/// The largest manifest a verifier reads.
pub const manifest_bytes_max = 64 * 1024;
pub const sha256_hex_len = sha256.digest_length * 2;
pub const Sha256Hex = [sha256_hex_len]u8;

/// The GitHub repository whose releases the updater and the verifiers read.
pub const repo = "jeiang/nanolight";
pub const releases_url = "https://github.com/" ++ repo ++ "/releases/download";

/// The Mac's app: its bundle, the program in it, and the oldest macOS it runs on.
pub const app_name = "Nanolight";
pub const bundle_id = "dev.nanoui.nanolight";
pub const bundle_name = app_name ++ ".app";
pub const program_name = "nanolight";
pub const bundle_program = "Contents/MacOS/" ++ program_name;
pub const bundle_plist = "Contents/Info.plist";
pub const macos_min: std.SemanticVersion = .{ .major = 14, .minor = 0, .patch = 0 };
/// As Info.plist's LSMinimumSystemVersion and vtool's `minos` say it.
pub const macos_min_text = std.fmt.comptimePrint("{d}.{d}", .{
    macos_min.major,
    macos_min.minor,
});

/// The Mac's disk image, the update its updater fetches, and its debug symbols.
pub const macos_disk_image = "nanolight-macos-arm64.dmg";
pub const macos_update = "nanolight-macos-arm64.zip";
pub const macos_symbols = "nanolight-macos-arm64-symbols.zip";
pub const manifest_name = "manifest.json";

/// The version a tag names: `v0.2.7` is 0.2.7.
pub fn versionOfTag(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
}

/// The file a build for `os` and `arch` updates itself from: that of the
/// shipped build it runs. A build no release carries asks for a file no
/// manifest names, and finds nothing.
pub fn updateAsset(
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
    buffer: *[name_bytes_max]u8,
) []const u8 {
    const platform: Platform = switch (os) {
        // The one Apple silicon app.
        .macos => return macos_update,
        // Windows on ARM runs the x86_64 build (emulated).
        .windows => .{ .os = .windows, .arch = .x86_64 },
        else => .{ .os = os, .arch = arch },
    };
    return platform.archiveName(buffer);
}

/// A Windows or Linux build that each release carries.
pub const Platform = struct {
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,

    pub fn format(platform: Platform) archive.Format {
        return if (platform.os == .windows) .zip else .tar_gz;
    }

    fn extension(platform: Platform) []const u8 {
        return switch (platform.format()) {
            .zip => "zip",
            .tar_gz => "tar.gz",
        };
    }

    /// `windows-x86_64`, as `--pc` takes it.
    pub fn key(platform: Platform, buffer: *[name_bytes_max]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{t}-{t}", .{ platform.os, platform.arch }) catch
            unreachable; // The longest os and arch fit name_bytes_max.
    }

    /// Its update: `nanolight-windows-x86_64.zip`, `nanolight-linux-x86_64.tar.gz`.
    pub fn archiveName(platform: Platform, buffer: *[name_bytes_max]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "nanolight-{t}-{t}.{s}", .{
            platform.os, platform.arch, platform.extension(),
        }) catch unreachable; // Fits, as above.
    }

    /// Its debug symbols: `nanolight-linux-x86_64-symbols.tar.gz`.
    pub fn symbolsArchiveName(platform: Platform, buffer: *[name_bytes_max]u8) []const u8 {
        return std.fmt.bufPrint(buffer, "nanolight-{t}-{t}-symbols.{s}", .{
            platform.os, platform.arch, platform.extension(),
        }) catch unreachable; // Fits, as above.
    }

    /// The one folder an archive holds, where the updater looks for the
    /// program: `nanolight-0.2.7-linux-x86_64`.
    pub fn folderName(
        platform: Platform,
        buffer: []u8,
        version: []const u8,
    ) error{NoSpaceLeft}![]u8 {
        return std.fmt.bufPrint(buffer, "nanolight-{s}-{t}-{t}", .{
            version, platform.os, platform.arch,
        });
    }

    pub fn programName(platform: Platform) []const u8 {
        return if (platform.os == .windows) program_name ++ ".exe" else program_name;
    }

    /// What a debugger reads beside the program: Windows' PDB, or the same
    /// ELF build left unstripped (`gdb -e nanolight -s nanolight.debug`).
    pub fn symbolsFileName(platform: Platform) []const u8 {
        return if (platform.os == .windows) "nanolight.pdb" else "nanolight.debug";
    }

    /// The platform `key` names, among `pc_platforms`.
    pub fn parse(text: []const u8) ?Platform {
        for (pc_platforms) |platform| {
            var buffer: [name_bytes_max]u8 = undefined;
            if (std.mem.eql(u8, platform.key(&buffer), text)) return platform;
        }
        return null;
    }
};

/// Windows' and Linux's builds: `zig build package` builds and archives each,
/// and `zig build verify-release` expects each in a release.
pub const pc_platforms = [_]Platform{
    .{ .os = .windows, .arch = .x86_64 },
    .{ .os = .linux, .arch = .x86_64 },
    .{ .os = .linux, .arch = .aarch64 },
};

comptime {
    // The Mac's three files and each other build's two fit one release.
    assert(3 + pc_platforms.len * 2 <= files_max);
}

pub fn sha256Hex(bytes: []const u8) Sha256Hex {
    var digest: [sha256.digest_length]u8 = undefined;
    sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// The sha256 of a file, in hex.
pub fn sha256File(io: std.Io, dir: std.Io.Dir, path: []const u8) !Sha256Hex {
    return hashFile(sha256, io, dir, path);
}

/// A file's digest by `Hash`, in hex, read in pieces (a debug file is tens
/// of megabytes; a verifier hashes dozens of screen captures).
pub fn hashFile(
    comptime Hash: type,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![Hash.digest_length * 2]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var hasher: Hash = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    var digest: [Hash.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// `<sha256>  <name>\n`, the line `shasum -a 256` prints.
pub fn writeSumLine(writer: *std.Io.Writer, sum: Sha256Hex, name: []const u8) !void {
    assert(name.len <= name_bytes_max);
    try writer.print("{s}  {s}\n", .{ &sum, name });
}

/// The sum a `.sha256` file names: its first field.
pub fn parseSumLine(text: []const u8) ?[]const u8 {
    const end = std.mem.indexOfAny(u8, text, " \t\n") orelse text.len;
    if (end == 0) return null;
    return text[0..end];
}

pub const FeedEntry = struct {
    name: []const u8,
    sha256: Sha256Hex,
};

/// The manifest naming `version` and each update's sum, on one line.
pub fn writeManifest(
    writer: *std.Io.Writer,
    version: []const u8,
    entries: []const FeedEntry,
) !void {
    assert(entries.len > 0);
    assert(entries.len <= files_max);
    assert(version.len > 0 and version.len <= version_bytes_max);
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("version");
    try json.write(version);
    try json.objectField("files");
    try json.beginObject();
    for (entries) |entry| {
        try json.objectField(entry.name);
        try json.beginObject();
        try json.objectField("sha256");
        try json.write(entry.sha256[0..]);
        try json.endObject();
    }
    try json.endObject();
    try json.endObject();
    try writer.writeByte('\n');
}

/// A manifest as a verifier reads it: what it names, not trusted to be well formed.
pub const Manifest = struct {
    version: []const u8,
    files: std.json.ObjectMap,

    /// The sum the manifest gives `name`, or null when it names no such file.
    pub fn sum(manifest: Manifest, name: []const u8) ?[]const u8 {
        const file = manifest.files.get(name) orelse return null;
        if (file != .object) return null;
        const value = file.object.get("sha256") orelse return null;
        if (value != .string) return null;
        return value.string;
    }

    pub fn parse(arena: std.mem.Allocator, text: []const u8) !Manifest {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        if (root != .object) return error.BadManifest;
        const version = root.object.get("version") orelse return error.BadManifest;
        const files = root.object.get("files") orelse return error.BadManifest;
        if (version != .string or files != .object) return error.BadManifest;
        return .{ .version = version.string, .files = files.object };
    }
};

// ----- tests -----

const testing = std.testing;

test "each build's files are named as the updater and the release expect" {
    var buffer: [name_bytes_max]u8 = undefined;
    const windows: Platform = .{ .os = .windows, .arch = .x86_64 };
    const arm: Platform = .{ .os = .linux, .arch = .aarch64 };
    try testing.expectEqualStrings("nanolight-windows-x86_64.zip", windows.archiveName(&buffer));
    try testing.expectEqualStrings("nanolight-linux-aarch64.tar.gz", arm.archiveName(&buffer));
    const symbols = arm.symbolsArchiveName(&buffer);
    try testing.expectEqualStrings("nanolight-linux-aarch64-symbols.tar.gz", symbols);
    try testing.expectEqualStrings("nanolight-0.2.7-windows-x86_64", try windows.folderName(
        &buffer,
        "0.2.7",
    ));
    try testing.expectEqualStrings("nanolight.exe", windows.programName());
    try testing.expectEqual(arm, Platform.parse("linux-aarch64").?);
    try testing.expectEqual(null, Platform.parse("linux-riscv64"));
}

test "each build updates from its own release file, and a tag names its version" {
    var buffer: [name_bytes_max]u8 = undefined;
    try testing.expectEqualStrings(macos_update, updateAsset(.macos, .x86_64, &buffer));
    const linux = updateAsset(.linux, .aarch64, &buffer);
    try testing.expectEqualStrings("nanolight-linux-aarch64.tar.gz", linux);
    const windows = updateAsset(.windows, .aarch64, &buffer);
    try testing.expectEqualStrings("nanolight-windows-x86_64.zip", windows);
    try testing.expectEqualStrings("0.2.7", versionOfTag("v0.2.7"));
    try testing.expectEqualStrings("0.2.7", versionOfTag("0.2.7"));
}

test "the manifest names every update given, and reads back" {
    const entries = [_]FeedEntry{
        .{ .name = macos_update, .sha256 = sha256Hex("mac") },
        .{ .name = "nanolight-linux-x86_64.tar.gz", .sha256 = sha256Hex("linux") },
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeManifest(&out.writer, "0.2.7", &entries);
    const text = out.written();
    try testing.expect(std.mem.startsWith(u8, text, "{\"version\":\"0.2.7\",\"files\":{"));
    try testing.expect(std.mem.endsWith(u8, text, "}}}\n"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const manifest = try Manifest.parse(arena.allocator(), text);
    try testing.expectEqualStrings("0.2.7", manifest.version);
    try testing.expectEqualStrings(&entries[0].sha256, manifest.sum(macos_update).?);
    try testing.expectEqualStrings(&entries[1].sha256, manifest.sum(entries[1].name).?);
    try testing.expectEqual(null, manifest.sum("nanolight-windows-x86_64.zip"));
}

test "a manifest of the wrong shape is refused, not trusted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadManifest, Manifest.parse(a, "[]"));
    try testing.expectError(error.BadManifest, Manifest.parse(a, "{\"version\":1,\"files\":{}}"));
    const odd = try Manifest.parse(a, "{\"version\":\"1\",\"files\":{\"x\":{\"sha256\":2}}}");
    try testing.expectEqual(null, odd.sum("x"));
}

test "a sum line reads back as shasum writes it" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const sum = sha256Hex("");
    try writeSumLine(&out.writer, sum, macos_disk_image);
    try testing.expectEqualStrings(&sum, parseSumLine(out.written()).?);
    try testing.expectEqual(null, parseSumLine(""));
}
