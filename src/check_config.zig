//! `zig build check-config`: reads each config.toml it is given as the app
//! does (`config.parse`) and fails if the app would refuse one, or would
//! ignore any of it (an unknown key, a dropped quicklink: at run time both
//! are only logged). The flake runs it on the file each Nix module writes
//! (nix/tests/config-parse.nix).
//!
//!   nanolight-check-config FILE...
const std = @import("std");
const config = @import("config.zig");

/// The most a config may hold: `config.load` reads no more.
const max_config_bytes = 1 << 20;

/// Warnings `config.parse` logged for the file being read: each is a part the app ignores.
var ignored: u32 = 0;

pub const std_options: std.Options = .{ .logFn = log };

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@backingInt(level) <= @backingInt(std.log.Level.warn)) ignored += 1;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.log.err("usage: nanolight-check-config FILE...", .{});
        std.process.exit(2);
    }
    var failed: u32 = 0;
    for (args[1..]) |path| {
        if (!check(arena, init.io, path)) failed += 1;
    }
    if (failed > 0) std.process.exit(1);
}

/// Whether the app would take all of `path`; says why not.
fn check(arena: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, arena, .limited(max_config_bytes)) catch |e| {
        std.log.err("{s}: {t}", .{ path, e });
        return false;
    };
    ignored = 0;
    var problem: config.Problem = .{};
    _ = config.parse(arena, text, &problem) catch |e| {
        if (e == error.OutOfMemory) std.log.err("{s}: out of memory", .{path});
        if (problem.line > 0) {
            std.log.err("{s}:{d}: {s}", .{ path, problem.line, problem.msg });
        } else {
            std.log.err("{s}: {s}", .{ path, problem.msg });
        }
        return false;
    };
    if (ignored > 0) {
        std.log.err("{s}: the app would ignore {d} part(s), above", .{ path, ignored });
        return false;
    }
    return true;
}
