//! `zig build lint`: the TigerStyle rules (docs/TIGER_STYLE.md) a machine
//! can check. Each argument is a `.zig` file or a folder of them (not its
//! subfolders). A line is at most 100 columns, except in a table laid out by
//! hand between `// zig fmt: off` and `// zig fmt: on`. An error dropped
//! with an empty catch says why: `// best effort: <why>` on its line or the
//! line above. `zig fmt --check` runs beside this, as its own step.
const std = @import("std");
const assert = std.debug.assert;

const columns_max = 100;
const file_bytes_max = 1 << 20;
const files_max = 1024;
const path_bytes_max = 1024;
const reason_marker = "// best effort:";
/// These are spelled in pieces, so that this file does not match itself.
const swallow_marker = "catch " ++ "{}";
const unformatted_start = "// zig fmt: " ++ "off";
const unformatted_end = "// zig fmt: " ++ "on";

comptime {
    // A reason must fit on the line above the catch it explains.
    assert(reason_marker.len < columns_max);
    assert(swallow_marker.len == 8);
}

pub const Problem = struct {
    line_number: u32,
    kind: Kind,
    columns: u32 = 0,

    pub const Kind = enum { too_wide, invalid_utf8, unexplained_catch };
};

/// The problems in one file's source, in line order.
pub const Linter = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_number: u32 = 0,
    line_previous: []const u8 = "",
    /// A line can break both rules: the second waits here.
    pending: ?Problem = null,
    /// Inside a `zig fmt: off` table, whose lines may run past the limit.
    unformatted: bool = false,

    pub fn init(source: []const u8) Linter {
        assert(source.len <= file_bytes_max);
        return .{ .lines = std.mem.splitScalar(u8, source, '\n') };
    }

    pub fn next(linter: *Linter) ?Problem {
        if (linter.pending) |problem| {
            linter.pending = null;
            return problem;
        }
        while (linter.lines.next()) |line| {
            linter.line_number += 1;
            defer linter.line_previous = line;
            if (std.mem.indexOf(u8, line, unformatted_start) != null) linter.unformatted = true;
            if (std.mem.indexOf(u8, line, unformatted_end) != null) linter.unformatted = false;
            var width = widthProblem(line, linter.line_number);
            if (linter.unformatted) {
                if (width) |problem| {
                    if (problem.kind == .too_wide) width = null;
                }
            }
            const swallow = catchProblem(line, linter.line_previous, linter.line_number);
            if (width) |problem| {
                linter.pending = swallow;
                return problem;
            }
            if (swallow) |problem| return problem;
        }
        assert(linter.pending == null);
        return null;
    }
};

fn widthProblem(line: []const u8, line_number: u32) ?Problem {
    const columns = std.unicode.utf8CountCodepoints(line) catch {
        return .{ .line_number = line_number, .kind = .invalid_utf8 };
    };
    assert(columns <= line.len);
    if (columns <= columns_max) return null;
    return .{ .line_number = line_number, .kind = .too_wide, .columns = @intCast(columns) };
}

fn catchProblem(line: []const u8, line_previous: []const u8, line_number: u32) ?Problem {
    if (std.mem.indexOf(u8, line, swallow_marker) == null) return null;
    if (std.mem.indexOf(u8, line, reason_marker) != null) return null;
    if (std.mem.indexOf(u8, line_previous, reason_marker) != null) return null;
    return .{ .line_number = line_number, .kind = .unexplained_catch };
}

const Totals = struct {
    files_count: u32 = 0,
    problems_count: u32 = 0,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) {
        std.log.err("usage: lint <file.zig or folder>...", .{});
        return error.Usage;
    }
    var totals: Totals = .{};
    for (args[1..]) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) {
            try lintFile(init, path, &totals);
        } else {
            try lintFolder(init, path, &totals);
        }
    }
    if (totals.problems_count == 0) return;
    std.debug.print("{d} problems in {d} files\n", .{ totals.problems_count, totals.files_count });
    std.process.exit(1);
}

fn lintFolder(init: std.process.Init, path: []const u8, totals: *Totals) !void {
    var dir = std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true }) catch |err| {
        std.log.err("{s}: {t}", .{ path, err });
        return err;
    };
    defer dir.close(init.io);
    var entries = dir.iterate();
    while (try entries.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        var buffer: [path_bytes_max]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ path, entry.name });
        try lintFile(init, file_path, totals);
    }
}

fn lintFile(init: std.process.Init, path: []const u8, totals: *Totals) !void {
    if (totals.files_count == files_max) return error.TooManyFiles;
    const limit: std.Io.Limit = .limited(file_bytes_max);
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, limit) catch |err| {
        std.log.err("{s}: {t}", .{ path, err });
        return err;
    };
    defer init.gpa.free(source);
    totals.files_count += 1;
    var linter: Linter = .init(source);
    while (linter.next()) |problem| {
        totals.problems_count += 1;
        switch (problem.kind) {
            .too_wide => std.debug.print("{s}:{d}: {d} columns (limit {d})\n", .{
                path, problem.line_number, problem.columns, columns_max,
            }),
            .invalid_utf8 => std.debug.print("{s}:{d}: not UTF-8\n", .{ path, problem.line_number }),
            .unexplained_catch => std.debug.print("{s}:{d}: {s} without \"{s} <why>\"\n", .{
                path, problem.line_number, swallow_marker, reason_marker,
            }),
        }
    }
}

// ----- tests -----

const testing = std.testing;

fn problemsOf(source: []const u8, buffer: []Problem) []Problem {
    var linter: Linter = .init(source);
    var count: usize = 0;
    while (linter.next()) |problem| {
        assert(count < buffer.len);
        buffer[count] = problem;
        count += 1;
    }
    return buffer[0..count];
}

/// `piece` written `count` times, at compile time.
fn repeated(comptime piece: []const u8, comptime count: usize) []const u8 {
    comptime var out: [piece.len * count]u8 = undefined;
    inline for (0..count) |index| @memcpy(out[index * piece.len ..][0..piece.len], piece);
    const final = out;
    return &final;
}

test "a line past 100 columns is too wide, and a character counts once however many bytes" {
    var buffer: [4]Problem = undefined;
    const fits = comptime repeated("x", columns_max) ++ "\n" ++ repeated("é", columns_max);
    try testing.expectEqual(0, problemsOf(fits, &buffer).len);
    const wide = problemsOf("ok\n" ++ comptime repeated("x", columns_max + 1), &buffer);
    try testing.expectEqual(1, wide.len);
    try testing.expectEqual(2, wide[0].line_number);
    try testing.expectEqual(Problem.Kind.too_wide, wide[0].kind);
    try testing.expectEqual(columns_max + 1, wide[0].columns);
}

test "a zig fmt: off table may run past the limit until zig fmt: on, and still needs reasons" {
    var buffer: [4]Problem = undefined;
    const wide = comptime repeated("x", columns_max + 1);
    const source = unformatted_start ++ "\n" ++ wide ++ "\n" ++ swallow_marker ++ "\n" ++
        unformatted_end ++ "\n" ++ wide;
    const problems = problemsOf(source, &buffer);
    try testing.expectEqual(2, problems.len);
    try testing.expectEqual(Problem.Kind.unexplained_catch, problems[0].kind);
    try testing.expectEqual(3, problems[0].line_number);
    try testing.expectEqual(Problem.Kind.too_wide, problems[1].kind);
    try testing.expectEqual(5, problems[1].line_number);
}

test "an empty catch needs a reason on its line or the line above, not further up" {
    var buffer: [4]Problem = undefined;
    const bare = "kv.set(a, b) " ++ swallow_marker ++ ";";
    const same_line = bare ++ " " ++ reason_marker ++ " a cache";
    const line_above = reason_marker ++ " a cache\n" ++ bare;
    const too_far = reason_marker ++ " a cache\n\n" ++ bare;
    try testing.expectEqual(1, problemsOf(bare, &buffer).len);
    try testing.expectEqual(0, problemsOf(same_line, &buffer).len);
    try testing.expectEqual(0, problemsOf(line_above, &buffer).len);
    const far = problemsOf(too_far, &buffer);
    try testing.expectEqual(1, far.len);
    try testing.expectEqual(3, far[0].line_number);
    try testing.expectEqual(Problem.Kind.unexplained_catch, far[0].kind);
}

test "a line breaking both rules reports both, and invalid UTF-8 is reported" {
    var buffer: [4]Problem = undefined;
    const both = problemsOf(comptime repeated("x", columns_max) ++ " " ++ swallow_marker, &buffer);
    try testing.expectEqual(2, both.len);
    try testing.expectEqual(Problem.Kind.too_wide, both[0].kind);
    try testing.expectEqual(Problem.Kind.unexplained_catch, both[1].kind);
    const invalid = problemsOf("ok\n\xff", &buffer);
    try testing.expectEqual(1, invalid.len);
    try testing.expectEqual(Problem.Kind.invalid_utf8, invalid[0].kind);
}
