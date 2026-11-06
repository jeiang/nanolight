//! Linux: single.zig's copies and commands, over a Unix socket at
//! $XDG_RUNTIME_DIR/nanolight.sock (else /tmp/nanolight-<uid>.sock). The
//! running copy listens; a second one connects and writes one line,
//! "toggle" or "quit". nanoui's loop watches the socket: nothing polls.
const std = @import("std");
const nanoui = @import("nanoui");
const single = @import("single.zig");
const c = std.c;

var listener: ?single.Listener = null;
var server: c_int = -1;
var watch: ?nanoui.fdwatch.Watch = null;

fn address() ?c.sockaddr.un {
    var a: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = @splat(0) };
    const p = if (c.getenv("XDG_RUNTIME_DIR")) |d|
        std.fmt.bufPrint(&a.path, "{s}/nanolight.sock", .{std.mem.span(d)}) catch return null
    else
        std.fmt.bufPrint(&a.path, "/tmp/nanolight-{d}.sock", .{c.getuid()}) catch return null;
    if (p.len >= a.path.len) return null;
    return a;
}

fn connectTo() c_int {
    var a = address() orelse return -1;
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return -1;
    if (c.connect(fd, @ptrCast(&a), @sizeOf(c.sockaddr.un)) != 0) {
        _ = c.close(fd);
        return -1;
    }
    return fd;
}

fn write(cmd: single.Command) bool {
    const fd = connectTo();
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const line = if (cmd == .quit) "quit\n" else "toggle\n";
    return c.write(fd, line.ptr, line.len) == line.len;
}

pub fn send(cmd: single.Command) bool {
    return write(cmd);
}

pub fn claim(on: single.Listener) usize {
    listener = on;
    var n: usize = 0;
    if (write(.quit)) {
        n = 1;
        // Gone (its socket refuses) within two seconds.
        var i: usize = 0;
        while (i < 40) : (i += 1) {
            const fd = connectTo();
            if (fd < 0) break;
            _ = c.close(fd);
            var ts: c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
        }
    }
    var a = address() orelse return n;
    _ = c.unlink(@ptrCast(&a.path));
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return n;
    if (c.bind(fd, @ptrCast(&a), @sizeOf(c.sockaddr.un)) != 0 or c.listen(fd, 4) != 0) {
        _ = c.close(fd);
        return n;
    }
    server = fd;
    watch = nanoui.fdwatch.readable(fd, null, accepted) catch null;
    return n;
}

fn accepted(_: ?*anyopaque) callconv(.c) void {
    const fd = c.accept(server, null, null);
    if (fd < 0) return;
    defer _ = c.close(fd);
    var buf: [16]u8 = undefined;
    const got = c.read(fd, &buf, buf.len);
    if (got <= 0) return;
    const line = std.mem.trim(u8, buf[0..@intCast(got)], " \r\n");
    const l = listener orelse return;
    if (std.mem.eql(u8, line, "quit")) l.func(l.ctx, .quit) else if (std.mem.eql(
        u8,
        line,
        "toggle",
    )) l.func(l.ctx, .toggle);
}
