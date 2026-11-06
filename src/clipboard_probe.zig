//! `zig build clip-probe`: runs the Linux clipboard watcher without the
//! panel, for trying it against a real X server or compositor. Not shipped.
//!
//!   clip-probe watch <seconds>                 prints each copy it sees
//!   clip-probe paste-text <text> <seconds>     serves text, as a paste does
//!   clip-probe paste-png <file> <seconds>      serves a PNG
//!   clip-probe paste-files <path>... <seconds> serves a file list
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const search = @import("search.zig");

var done = false;

fn finish(_: ?*anyopaque) callconv(.c) void {
    done = true;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = std.c.write(1, line.ptr, line.len);
}

fn observe(_: *anyopaque, item: clipboard.Item) void {
    switch (item.kind) {
        .image => say(
            "observed image {d}x{d} {d} bytes source=\"{s}\"",
            .{ item.width, item.height, item.png.len, item.source },
        ),
        else => say(
            "observed {t} {d} bytes \"{f}\" source=\"{s}\"",
            .{
                item.kind,
                item.text.len,
                std.zig.fmtString(search.clip(item.text, 80)),
                item.source,
            },
        ),
    }
}

fn excluded(_: *anyopaque, source: []const u8) bool {
    return std.mem.eql(u8, source, "Excluded");
}

fn hide(_: *anyopaque) void {
    say("hidden", .{});
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return say(
        "usage: clip-probe watch|paste-text|paste-png|paste-files ... <seconds>",
        .{},
    );
    const secs = try std.fmt.parseInt(u64, args[args.len - 1], 10);
    var w: clipboard.Watcher = .{};
    var token: u8 = 0;
    w.start(.{ .ctx = &token, .observe = observe, .excluded = excluded }) catch |e| {
        return say("start failed: {t}: {s}", .{ e, w.why orelse "" });
    };
    say("started: {s}", .{@tagName(w.backend)});
    if (std.mem.eql(u8, args[1], "paste-text")) {
        say(
            "paste -> {t}",
            .{w.paste(.{ .kind = .text, .text = args[2] }, .{ .ctx = &token, .func = hide })},
        );
    } else if (std.mem.eql(u8, args[1], "paste-png")) {
        const png = try std.Io.Dir.cwd()
            .readFileAlloc(init.io, args[2], init.arena.allocator(), .limited(clipboard.max_image));
        say(
            "paste -> {t}",
            .{w.paste(.{ .kind = .image, .png = png }, .{ .ctx = &token, .func = hide })},
        );
    } else if (std.mem.eql(u8, args[1], "paste-files")) {
        const joined = try std.mem.join(init.arena.allocator(), "\n", args[2 .. args.len - 1]);
        say(
            "paste -> {t}",
            .{w.paste(.{ .kind = .file, .text = joined }, .{ .ctx = &token, .func = hide })},
        );
    }
    nanoui.App.after(secs * 1000, null, finish);
    const iterate: *const fn (?*anyopaque, c_int) callconv(.c) c_int = @ptrCast(
        std.c.dlsym(null, "g_main_context_iteration") orelse return say("no glib", .{}),
    );
    while (!done) _ = iterate(null, 1);
    say("done", .{});
}
