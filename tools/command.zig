//! Running the system's own programs (codesign, hdiutil, ditto, sips, curl,
//! osascript, …): they come with the Mac and are not dependencies, but they
//! are how a Mac signs, images, fetches and checks an app. And what a tool
//! says, line by line, between what those programs print.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

/// The most a captured program may print before it counts as a failure.
pub const output_bytes_max = 4 << 20;
const line_bytes_max = 4096;

/// Prints a line to standard output at once, so that it lands in order with
/// what the programs this tool runs print there.
pub fn say(io: Io, comptime format: []const u8, arguments: anytype) void {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", arguments) catch blk: {
        buffer[buffer.len - 4 ..].* = "...\n".*;
        break :blk &buffer;
    };
    // best effort: a closed standard output loses only this tool's commentary.
    Io.File.stdout().writeStreamingAll(io, line) catch {};
}

/// The same, to standard error.
pub fn complain(io: Io, comptime format: []const u8, arguments: anytype) void {
    var buffer: [line_bytes_max]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, format ++ "\n", arguments) catch blk: {
        buffer[buffer.len - 4 ..].* = "...\n".*;
        break :blk &buffer;
    };
    // best effort: as above, for standard error.
    Io.File.stderr().writeStreamingAll(io, line) catch {};
}

/// Runs `argv` with this tool's standard streams, as a line of a shell script
/// would: error.CommandFailed, after saying which, unless it exits 0.
pub fn run(io: Io, argv: []const []const u8) !void {
    assert(argv.len > 0);
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    if (term.success()) return;
    complain(io, "{s}: {f}", .{ argv[0], term });
    return error.CommandFailed;
}

/// Whether `argv` runs and exits 0, its output let through.
pub fn succeeds(io: Io, argv: []const []const u8) !bool {
    assert(argv.len > 0);
    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    return term.success();
}

pub const Captured = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    /// Both streams, standard output's first, as `2>&1` would show them.
    text: []const u8,

    pub fn ok(captured: Captured) bool {
        return captured.term.success();
    }

    /// Standard output without its last newline, as `$(…)` gives it.
    pub fn line(captured: Captured) []const u8 {
        return std.mem.trimEnd(u8, captured.stdout, "\r\n");
    }
};

pub const CaptureOptions = struct {
    /// Past it, the program is killed and error.Timeout returned.
    timeout: Io.Timeout = .none,
    /// The whole environment the program gets, when not this tool's.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Runs `argv` and keeps what it prints, in `arena`. Failing to start, or
/// printing more than `output_bytes_max`, is an error; exiting non-zero is not.
pub fn capture(
    arena: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    options: CaptureOptions,
) !Captured {
    assert(argv.len > 0);
    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(output_bytes_max),
        .stderr_limit = .limited(output_bytes_max),
        .timeout = options.timeout,
        .environ_map = options.environ_map,
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .text = try std.mem.concat(arena, u8, &.{ result.stdout, result.stderr }),
    };
}

pub fn sleep(io: Io, duration_ms: i64) !void {
    assert(duration_ms >= 0);
    try io.sleep(.fromMilliseconds(duration_ms), .awake);
}

/// Seconds since the epoch, by the wall clock.
pub fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

/// A fresh folder `<prefix>.XXXXXX` under /tmp, by its real path (macOS's
/// /tmp is a link to /private/tmp), as `mktemp -d` and `pwd -P` give it.
pub fn temporaryFolder(arena: std.mem.Allocator, io: Io, prefix: []const u8) ![]const u8 {
    const tries_max = 16;
    for (0..tries_max) |_| {
        var random: [6]u8 = undefined;
        io.random(&random);
        const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        for (&random) |*byte| byte.* = alphabet[byte.* % alphabet.len];
        const path = try std.fmt.allocPrint(arena, "/tmp/{s}.{s}", .{ prefix, &random });
        Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return Io.Dir.cwd().realPathFileAlloc(io, path, arena);
    }
    return error.PathAlreadyExists;
}
