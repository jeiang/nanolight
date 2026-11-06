//! Linux: single.zig's copies and commands, over a Unix socket at
//! $XDG_RUNTIME_DIR/nanolight.sock (else /tmp/nanolight-<uid>.sock). The
//! running copy listens; a second one connects and writes one line
//! (`single.Command.line`). nanoui's loop watches the socket; only the
//! startup wait for an older copy (`single.quitOlder`) polls.
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

pub fn send(cmd: single.Command) bool {
    const fd = connectTo();
    if (fd < 0) return false;
    defer _ = c.close(fd);
    const line = switch (cmd) {
        inline else => |k| comptime k.line() ++ "\n",
    };
    return c.write(fd, line.ptr, line.len) == line.len;
}

/// Whether a copy holds the socket: it takes a connection.
pub fn running() bool {
    const fd = connectTo();
    if (fd < 0) return false;
    _ = c.close(fd);
    return true;
}

/// Never: opening Nanolight's own row starts a new copy, which takes
/// over (`claim`).
pub fn isSelf(_: []const u8) bool {
    return false;
}

pub fn claim(io: std.Io, on: single.Listener) single.Older {
    const older = single.quitOlder(io, @This());
    // The older copy still answers on the socket: unlinking it would leave
    // that copy unreachable, by `--toggle` and by the next copy's quit. It
    // keeps the socket; this one runs beside it, deaf to commands.
    if (older == .stayed) {
        std.log.warn("nanolight: an older copy kept running; `--toggle` goes to it", .{});
        return older;
    }
    listen(on) catch |e|
        std.log.warn("nanolight: `--toggle` can't reach this copy ({t})", .{e});
    return older;
}

fn listen(on: single.Listener) !void {
    listener = on;
    var a = address() orelse return error.SocketPathTooLong;
    // No copy answers on it (`claim`): a socket file left by one that crashed.
    _ = c.unlink(@ptrCast(&a.path));
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    if (c.bind(fd, @ptrCast(&a), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    if (c.listen(fd, 4) != 0) return error.ListenFailed;
    watch = try nanoui.fdwatch.readable(fd, null, accepted);
    server = fd;
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
    l.func(l.ctx, single.Command.fromLine(line) orelse return);
}
