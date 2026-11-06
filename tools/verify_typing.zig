//! `zig build verify-typing -- [cycles]`: the panel's query never goes back
//! to what it showed before a key (#24, a drawable from a slowed display link
//! covering the newer one). Types a word, waits as a person pauses, deletes
//! it, and watches the query's pixels: from the word to the placeholder and
//! no further. The word coming back counts.
//!
//! Needs /Applications/Nanolight.app, running with its panel in front.
//! Presses keys, so CI only. If most cycles see the word's pixels never
//! change, it fails in any mode: the keys went elsewhere, and "never went
//! back" would mean nothing. An odd such cycle doesn't: builds with the bug
//! have them (5 of 60 on v0.2.7, none of 24 on the fix).
//! TYPING_EXPECT=any only reports (a pull request can't change the published
//! build it runs on). SHOTS keeps what it saw of a cycle that went back.
//! tools/verify_update.zig runs this check too, between its own.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const command = @import("command.zig");
const mac_verify = @import("mac_verify.zig");
const release = @import("release.zig");
const screen = @import("screen.zig");

pub const Expect = enum { clean, any };

pub const Options = struct {
    cycles: u32 = 12,
    expect: Expect = .clean,
    /// Where the captures of a cycle that went back are kept.
    shots: []const u8 = mac_verify.shots_default,
};

/// The panel's window is a shadow's margin bigger than it all round.
const panel_width = mac_verify.panel_width;
/// The patch watched: inside the word, and clear of the caret at either end.
const patch_left = 56;
const patch_top = 14;
const patch_width = 60;
const patch_height = 32;
/// How long the deletion is watched, in whole seconds of the wall clock.
const watch_s = 2;
const captures_max = 999;
const cycles_max = 1000;
/// A state is the first eight hex digits of a capture's SHA-1, as `shasum | cut -c1-8`.
const State = [8]u8;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;
    mac_verify.requireCi(io, environ, "verify-typing presses keys");
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var options: Options = .{ .expect = expectOf(environ) };
    if (environ.get("SHOTS")) |shots| options.shots = shots;
    if (args.len > 1) {
        options.cycles = std.fmt.parseInt(u32, args[1], 10) catch {
            command.complain(io, "usage: zig build verify-typing -- [cycles]", .{});
            std.process.exit(2);
        };
    }
    if (!try check(arena, io, options)) std.process.exit(1);
}

/// TYPING_EXPECT: "any" only reports; anything else is a clean build.
pub fn expectOf(environ: *const std.process.Environ.Map) Expect {
    const value = environ.get("TYPING_EXPECT") orelse return .clean;
    return if (std.mem.eql(u8, value, "any")) .any else .clean;
}

/// Runs the check, saying what it sees: false when it fails.
pub fn check(arena: std.mem.Allocator, io: Io, options: Options) !bool {
    if (options.cycles == 0 or options.cycles > cycles_max) return error.Usage;
    try Io.Dir.cwd().createDirPath(io, options.shots);
    const work = try command.temporaryFolder(arena, io, "nanolight-typing");
    defer Io.Dir.cwd().deleteTree(io, work) catch {}; // best effort: macOS clears /tmp.
    const frame = screen.firstPanel() orelse {
        command.say(io, "FAIL  no panel on screen", .{});
        return false;
    };
    const margin = @divTrunc(frame.width - panel_width, 2);
    const rect = try std.fmt.allocPrint(arena, "{d},{d},{d},{d}", .{
        frame.x + margin + patch_left, frame.y + margin + patch_top, patch_width, patch_height,
    });
    command.say(io, "      watching {s}", .{rect});
    const macos_version = try mac_verify.macosVersion(arena, io);

    var tally: Tally = .{};
    for (1..options.cycles + 1) |cycle| {
        const watched: Watch = .{ .arena = arena, .io = io, .rect = rect, .work = work };
        const seen = try watched.cycle(cycle);
        tally.frames += seen.frames;
        if (seen.distinct < 2) tally.blind += 1;
        if (seen.runs.len > seen.distinct) {
            tally.back += 1;
            try reportRollback(arena, io, .{
                .cycle = cycle,
                .seen = seen,
                .shots = options.shots,
                .macos_version = macos_version,
            });
        }
        try Io.Dir.cwd().deleteTree(io, seen.folder);
    }
    return verdict(io, tally, options);
}

const Tally = struct {
    frames: usize = 0,
    back: u32 = 0,
    blind: u32 = 0,
};

fn verdict(io: Io, tally: Tally, options: Options) bool {
    const cycles = options.cycles;
    command.say(io, "      {d} captures, about {d} per {d} s; {d} of {d} went back; " ++
        "{d} saw no change", .{
        tally.frames, tally.frames / cycles, watch_s, tally.back, cycles, tally.blind,
    });
    if (tally.blind * 2 >= cycles) {
        command.say(io, "FAIL  the word's pixels never changed in {d} of {d} cycles: " ++
            "this check saw nothing", .{ tally.blind, cycles });
        return false;
    }
    switch (options.expect) {
        .any => command.say(io, "ok    typing checked, not judged: {d} of {d} went back", .{
            tally.back, cycles,
        }),
        .clean => {
            if (tally.back != 0) {
                command.say(io, "FAIL  the query went back to what it showed before a key", .{});
                return false;
            }
            command.say(io, "ok    typing never went back", .{});
        },
    }
    return true;
}

/// One cycle's captures: the states seen in order, each run of a same one counted once.
const Seen = struct {
    folder: []const u8,
    frames: usize,
    runs: []const State,
    distinct: usize,
};

const Watch = struct {
    arena: std.mem.Allocator,
    io: Io,
    rect: []const u8,
    work: []const u8,

    fn cycle(watch: Watch, number: usize) !Seen {
        const io = watch.io;
        try mac_verify.keys(watch.arena, io, "keystroke \"calendar\"");
        // A pause, at a different point of the caret's half-second blink each time.
        try command.sleep(io, 1000 + @as(i64, @intCast(number % 5)) * 100);
        const folder = try std.fmt.allocPrint(watch.arena, "{s}/c{d}", .{ watch.work, number });
        try Io.Dir.cwd().createDir(io, folder, .default_dir);
        try watch.capture(folder, "before");
        try mac_verify.keys(watch.arena, io, "key code 51 using option down");
        const end_s = command.nowSeconds(io) + watch_s;
        var frames: usize = 0;
        while (command.nowSeconds(io) <= end_s and frames < captures_max) {
            frames += 1;
            var name: [8]u8 = undefined;
            try watch.capture(folder, try std.fmt.bufPrint(&name, "{d:0>3}", .{frames}));
        }
        const states = try watch.arena.alloc(State, frames + 1);
        states[0] = try stateOf(watch.arena, io, folder, "before");
        for (1..frames + 1) |index| {
            var name: [8]u8 = undefined;
            const text = try std.fmt.bufPrint(&name, "{d:0>3}", .{index});
            states[index] = try stateOf(watch.arena, io, folder, text);
        }
        const runs = collapseRuns(states);
        const distinct = distinctCount(runs);
        return .{ .folder = folder, .frames = frames, .runs = runs, .distinct = distinct };
    }

    fn capture(watch: Watch, folder: []const u8, name: []const u8) !void {
        const path = try std.fmt.allocPrint(watch.arena, "{s}/{s}.png", .{ folder, name });
        try command.run(watch.io, &.{ "screencapture", "-x", "-R", watch.rect, path });
    }
};

fn stateOf(arena: std.mem.Allocator, io: Io, folder: []const u8, name: []const u8) !State {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ folder, name });
    const hex = try release.hashFile(std.crypto.hash.Sha1, io, Io.Dir.cwd(), path);
    return hex[0..8].*;
}

/// The states in order with each run of a same one counted once, as `uniq`.
fn collapseRuns(states: []State) []State {
    var count: usize = 0;
    for (states) |state| {
        if (count > 0 and std.mem.eql(u8, &states[count - 1], &state)) continue;
        states[count] = state;
        count += 1;
    }
    return states[0..count];
}

/// How many different states, as `sort -u | wc -l`.
fn distinctCount(states: []const State) usize {
    var count: usize = 0;
    for (states, 0..) |state, index| {
        for (states[0..index]) |earlier| {
            if (std.mem.eql(u8, &earlier, &state)) break;
        } else count += 1;
    }
    return count;
}

const Rollback = struct {
    cycle: usize,
    seen: Seen,
    shots: []const u8,
    macos_version: []const u8,
};

/// Says which states a cycle went back through, and keeps its captures.
fn reportRollback(arena: std.mem.Allocator, io: Io, rollback: Rollback) !void {
    var states: Io.Writer.Allocating = .init(arena);
    for (rollback.seen.runs) |state| try states.writer.print("{s} ", .{&state});
    command.say(io, "      cycle {d} went back: {s}", .{ rollback.cycle, states.written() });
    const kept = try std.fmt.allocPrint(arena, "{s}/rollback-{s}-{d}", .{
        rollback.shots, rollback.macos_version, rollback.cycle,
    });
    try Io.Dir.cwd().createDirPath(io, kept);
    try command.run(io, &.{ "ditto", rollback.seen.folder, kept });
}

test "a state seen again after another counts as going back; a long run of one doesn't" {
    var clean = [_]State{ "aaaaaaaa".*, "aaaaaaaa".*, "bbbbbbbb".*, "bbbbbbbb".* };
    const clean_runs = collapseRuns(&clean);
    try std.testing.expectEqual(@as(usize, 2), clean_runs.len);
    try std.testing.expectEqual(@as(usize, 2), distinctCount(clean_runs));
    var back = [_]State{ "aaaaaaaa".*, "bbbbbbbb".*, "aaaaaaaa".*, "bbbbbbbb".* };
    const back_runs = collapseRuns(&back);
    try std.testing.expect(back_runs.len > distinctCount(back_runs));
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.expectEqual(Expect.clean, expectOf(&environ));
    try environ.put("TYPING_EXPECT", "any");
    try std.testing.expectEqual(Expect.any, expectOf(&environ));
}
