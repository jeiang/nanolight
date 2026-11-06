//! `zig build check-config`: reads each config.toml it is given as the app
//! does (`config.parse`) and fails if the app would refuse one, or would
//! ignore any of it (an unknown key, a dropped quicklink, a hotkey this
//! system can't use: at run time each is only logged). The flake runs it on
//! the file each Nix module writes (nix/tests/config-parse.nix).
//!
//!   nanolight-check-config FILE...
const std = @import("std");
const config = @import("config.zig");

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
    const text = cwd.readFileAlloc(io, path, arena, .limited(config.max_bytes)) catch |e| {
        std.log.err("{s}: {t}", .{ path, e });
        return false;
    };
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
    const ignored = problem.ignored.items;
    for (ignored) |what| std.log.err("{s}: {s}", .{ path, what });
    if (ignored.len > 0) {
        std.log.err("{s}: the app would ignore {d} part(s), above", .{ path, ignored.len });
        return false;
    }
    return true;
}
