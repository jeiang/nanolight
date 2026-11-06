//! A child process run from the main thread, one of its streams read as
//! it comes (nothing polls), for system commands (commands.zig) and
//! script commands (script_run.zig).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const assert = std.debug.assert;
const windows = builtin.os.tag == .windows;

/// Where a child's output and its end go, on the main thread.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Bytes it wrote to its piped stream.
    bytes: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    /// It ended; null when it couldn't be waited for.
    ended: *const fn (ctx: *anyopaque, term: ?std.process.Child.Term) void,
};

pub const Runner = struct {
    /// The child, while it runs.
    live: ?Live = null,

    const Live = struct {
        io: std.Io,
        sink: Sink,
        child: std.process.Child,
        watch: nanoui.fdwatch.Watch,

        fn pipe(l: *const Live) std.Io.File {
            return l.child.stdout orelse l.child.stderr.?;
        }
    };

    pub const Error = error{ Spawn, Watch };

    /// Starts `options`' program, a running one stopped first. Exactly one
    /// of its stdout and stderr is piped, and that one goes to `sink`. A
    /// child whose stream can't be watched is stopped: nothing would read
    /// it or end it, and a wait here would hold the panel as long as it
    /// runs. `io` is the app's: the global single-threaded Io can't start
    /// processes.
    pub fn start(r: *Runner, io: std.Io, options: std.process.SpawnOptions, sink: Sink) Error!void {
        assert((options.stdout == .pipe) != (options.stderr == .pipe));
        r.stop();
        var child = std.process.spawn(io, options) catch return error.Spawn;
        const out = (child.stdout orelse child.stderr.?).handle;
        const watch = (if (windows)
            nanoui.fdwatch.reader(out, r, bytesIn, ended)
        else
            nanoui.fdwatch.readable(out, r, readable)) catch {
            child.kill(io);
            return error.Watch;
        };
        r.live = .{ .io = io, .sink = sink, .child = child, .watch = watch };
    }

    /// Ends a child still running; its sink hears nothing more.
    pub fn stop(r: *Runner) void {
        var l = r.live orelse return;
        r.live = null;
        l.watch.cancel();
        l.child.kill(l.io);
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const l = r.live orelse return;
        var buf: [16 * 1024]u8 = undefined;
        const n = std.c.read(l.pipe().handle, &buf, buf.len);
        if (n <= 0) return ended(ctx);
        l.sink.bytes(l.sink.ctx, buf[0..@intCast(n)]);
    }

    fn bytesIn(ctx: ?*anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const l = r.live orelse return;
        l.sink.bytes(l.sink.ctx, bytes);
    }

    fn ended(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        var l = r.live orelse return;
        r.live = null;
        l.watch.cancel();
        const term = l.child.wait(l.io) catch null;
        l.sink.ended(l.sink.ctx, term);
    }
};

/// Appends `bytes` to the `len` bytes held in `buf`, keeping the last that fit: the new length.
pub fn keepTail(buf: []u8, len: usize, bytes: []const u8) usize {
    if (bytes.len >= buf.len) {
        @memcpy(buf, bytes[bytes.len - buf.len ..]);
        return buf.len;
    }
    var keep = len;
    if (keep + bytes.len > buf.len) {
        const drop = keep + bytes.len - buf.len;
        std.mem.copyForwards(u8, buf[0 .. keep - drop], buf[drop..keep]);
        keep -= drop;
    }
    @memcpy(buf[keep..][0..bytes.len], bytes);
    return keep + bytes.len;
}

/// The last non-empty line, its spaces trimmed.
pub fn lastLine(text: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, text, " \r\n");
    return std.mem.trim(
        u8,
        if (std.mem.lastIndexOfScalar(u8, t, '\n')) |nl| t[nl + 1 ..] else t,
        " \r",
    );
}

test "a tail keeps the last bytes, and its last line is the last that isn't empty" {
    const t = std.testing;
    var buf: [8]u8 = undefined;
    var n = keepTail(&buf, 0, "ab\n");
    n = keepTail(&buf, n, "cdef");
    try t.expectEqualStrings("ab\ncdef", buf[0..n]);
    n = keepTail(&buf, n, "ghij");
    try t.expectEqualStrings("cdefghij", buf[0..n]);
    n = keepTail(&buf, n, "0123456789");
    try t.expectEqualStrings("23456789", buf[0..n]);
    try t.expectEqualStrings("last", lastLine("first\nlast\n"));
    try t.expectEqualStrings("last", lastLine("first\r\n  last \r\n\n"));
    try t.expectEqualStrings("", lastLine(" \n"));
}
