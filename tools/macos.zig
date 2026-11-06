//! The Mac's trust in a release, in one place: the team that signs it;
//! signing, notarizing and stapling it (tools/package.zig); and checking each
//! of those as the system does (tools/verify_release.zig,
//! tools/verify_update.zig). The work is the system's: codesign, notarytool,
//! stapler and spctl.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const command = @import("command.zig");

/// The team every release is signed by. The updater refuses any other.
pub const team = "WWP9DLJ27P";
/// Apple's CloudKit, which stapling and validating ask for the ticket, drops
/// the connection now and then (error 68) though notarization succeeded.
pub const staple_tries_default = 5;
const staple_pause_step_ms = 10_000;

/// Who signs: a "Developer ID Application" identity in the keychain, or no
/// one (ad hoc: Gatekeeper asks once, and the app can't update itself).
pub const Identity = union(enum) {
    ad_hoc,
    developer_id: []const u8,
};

pub fn sign(io: Io, path: []const u8, identity: Identity) !void {
    switch (identity) {
        .developer_id => |name| try command.run(io, &.{
            "codesign", "--force", "--timestamp", "--options", "runtime", "--sign", name, path,
        }),
        .ad_hoc => try command.run(io, &.{ "codesign", "--force", "--sign", "-", path }),
    }
}

/// Apple's notary service, as `xcrun notarytool` takes it: a profile saved
/// with `store-credentials`, or an App Store Connect API key.
pub const Notary = union(enum) {
    profile: []const u8,
    api_key: struct { path: []const u8, id: []const u8, issuer: []const u8 },
};

pub fn notarize(io: Io, path: []const u8, notary: Notary) !void {
    switch (notary) {
        .profile => |profile| try command.run(io, &.{
            "xcrun", "notarytool", "submit", path, "--keychain-profile", profile, "--wait",
        }),
        .api_key => |key| try command.run(io, &.{
            "xcrun", "notarytool", "submit",   path,     "--key", key.path, "--key-id",
            key.id,  "--issuer",   key.issuer, "--wait",
        }),
    }
}

/// Staples the ticket to `path`, a few tries apart.
pub fn staple(io: Io, path: []const u8) !void {
    for (1..staple_tries_default + 1) |attempt| {
        if (try command.succeeds(io, &.{ "xcrun", "stapler", "staple", path })) return;
        command.complain(io, "stapling {s} failed (try {d}); retrying", .{ path, attempt });
        try command.sleep(io, @as(i64, @intCast(attempt)) * staple_pause_step_ms);
    }
    return error.StapleFailed;
}

// ----- the checks: each returns null when it holds, else what it saw -----

/// A ticket is stapled to `path`: `stapler validate`, a few tries apart.
pub fn stapled(arena: std.mem.Allocator, io: Io, path: []const u8, tries: u32) !?[]const u8 {
    assert(tries > 0);
    var said: Io.Writer.Allocating = .init(arena);
    for (1..tries + 1) |attempt| {
        const argv = [_][]const u8{ "xcrun", "stapler", "validate", path };
        const result = try command.capture(arena, io, &argv, .{});
        try said.writer.writeAll(result.text);
        if (result.ok()) return null;
        if (attempt == tries) break;
        try command.sleep(io, @as(i64, @intCast(attempt)) * staple_pause_step_ms);
    }
    return said.written();
}

/// A strict signature by `team`, hardened (the runtime flag) and timestamped.
pub fn signed(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    const verify = try command.capture(arena, io, &.{
        "codesign", "--verify", "--deep", "--strict", path,
    }, .{});
    if (!verify.ok()) return verify.text;
    const details_argv = [_][]const u8{ "codesign", "-dv", "--verbose=2", path };
    const details = try command.capture(arena, io, &details_argv, .{});
    const info = details.text;
    const flags = lineWith(info, "flags=") orelse "";
    const runtime = hasAfter(flags, "flags=", "runtime");
    if (std.mem.indexOf(u8, info, "TeamIdentifier=" ++ team) == null) {
        return try std.fmt.allocPrint(arena, "no TeamIdentifier={s} in:\n{s}", .{ team, info });
    }
    if (!runtime) return try std.fmt.allocPrint(arena, "no flags=…runtime in:\n{s}", .{info});
    if (std.mem.indexOf(u8, info, "Timestamp=") == null) {
        return try std.fmt.allocPrint(arena, "no Timestamp= in:\n{s}", .{info});
    }
    return null;
}

/// Gatekeeper takes it as notarized and signed by `team`. "accepted" alone
/// would pass on a Mac with Gatekeeper turned off. `assessment` is spctl's
/// arguments before the path: `-t exec`, or `-t open --context …`.
pub fn notarized(
    arena: std.mem.Allocator,
    io: Io,
    assessment: []const []const u8,
    path: []const u8,
) !?[]const u8 {
    const argv = try std.mem.concat(arena, []const u8, &.{
        &.{ "spctl", "-a", "-vvv" }, assessment, &.{path},
    });
    const result = try command.capture(arena, io, argv, .{});
    if (!result.ok()) return result.text;
    const notary = std.mem.indexOf(u8, result.text, "source=Notarized Developer ID") != null;
    const by_team = std.mem.indexOf(u8, result.text, "(" ++ team ++ ")") != null;
    if (!notary or !by_team) return result.text;
    return null;
}

/// The line of `text` that holds `needle`, as grep finds it.
fn lineWith(text: []const u8, needle: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const newline = std.mem.lastIndexOfScalar(u8, text[0..at], '\n');
    const start = if (newline) |index| index + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return text[start..end];
}

fn hasAfter(line: []const u8, first: []const u8, then: []const u8) bool {
    const at = std.mem.indexOf(u8, line, first) orelse return false;
    return std.mem.indexOf(u8, line[at + first.len ..], then) != null;
}

test "the runtime flag is read from codesign's flags line, as grep 'flags=.*runtime' does" {
    const info = "Identifier=x\nCodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1\n";
    const flags = lineWith(info, "flags=").?;
    try std.testing.expect(hasAfter(flags, "flags=", "runtime"));
    try std.testing.expect(!hasAfter("flags=0x0(none) runtime_not_here", "flags=", "kernel"));
    try std.testing.expectEqual(null, lineWith(info, "Timestamp="));
}
