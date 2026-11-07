//! nanolight-server's socket: one HTTP exchange per connection, read into a
//! `server_protocol.Request` and its `Reply` written back.
//!
//! One connection at a time, by design: a few machines per account sync a
//! few times an hour, so requests are served serially, never in parallel.
//! A stalled client is cut off by one deadline for the whole exchange
//! (`exchange_deadline_ms`), whether it stops sending its request or stops
//! reading the reply, so it holds the next one up for at most that long.
const std = @import("std");
const Io = std.Io;
const protocol = @import("sync_protocol.zig");
const server = @import("server_protocol.zig");
const log = @import("log.zig");

/// How long one connection may take, request and reply together.
const exchange_deadline_ms = 10_000;
/// The most one send hands the kernel. Poll reports room only once more than
/// this is free (SO_SNDLOWAT, 2 KiB, on macOS; a third of the send buffer, which
/// is at least about 4.5 KiB, on Linux), so a send this size never blocks after it.
const max_write = 1024;

/// The connection's reader and writer, which share one deadline for the
/// whole exchange.
const Timed = struct {
    io: Io,
    stream: Io.net.Stream,
    deadline: Io.Timeout,
    reader: Io.Reader,
    writer: Io.Writer,

    const Buffers = struct { in: []u8, out: []u8 };

    fn init(io: Io, stream: Io.net.Stream, buffers: Buffers, deadline_ms: u32) Timed {
        std.debug.assert(deadline_ms > 0);
        const timeout: Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(deadline_ms),
            .clock = .awake,
        } };
        return .{
            .io = io,
            .stream = stream,
            .deadline = timeout.toDeadline(io),
            .reader = .{
                .vtable = &.{ .stream = streamFn },
                .buffer = buffers.in,
                .seek = 0,
                .end = 0,
            },
            .writer = .{ .vtable = &.{ .drain = drainFn }, .buffer = buffers.out },
        };
    }

    fn streamFn(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Timed = @alignCast(@fieldParentPtr("reader", r));
        var data: [1][]u8 = .{limit.slice(try w.writableSliceGreedy(1))};
        const op: Io.Operation = .{ .net_read = .{
            .socket_handle = t.stream.socket.handle,
            .data = &data,
        } };
        const done = t.io.operateTimeout(op, t.deadline) catch return error.ReadFailed;
        const got = done.net_read catch return error.ReadFailed;
        if (got.data_len == 0) return error.EndOfStream;
        w.advance(got.data_len);
        return got.data_len;
    }

    /// Sends at most `max_write` bytes: the deadline bounds only the wait for
    /// room (poll), and a blocking send of more than the room it reported could
    /// then wait on the client without limit.
    fn drainFn(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const t: *Timed = @alignCast(@fieldParentPtr("writer", w));
        const buffered = w.buffered();
        const next: []const u8 = if (buffered.len > 0) buffered else for (data, 0..) |d, i| {
            const repeats = if (i == data.len - 1) splat else 1;
            if (d.len > 0 and repeats > 0) break d;
        } else return 0;
        const chunk = next[0..@min(next.len, max_write)];
        const op: Io.Operation = .{ .net_write = .{
            .socket_handle = t.stream.socket.handle,
            .data = &.{chunk},
        } };
        const done = t.io.operateTimeout(op, t.deadline) catch return error.WriteFailed;
        const n = done.net_write catch return error.WriteFailed;
        std.debug.assert(n <= chunk.len);
        return w.consume(n);
    }
};

pub const Serve = struct {
    state: Io.Dir,
    tokens: []const server.Token,
    deadline_ms: u32 = exchange_deadline_ms,
};

/// One exchange on `stream`. An error is a request dropped unanswered, or a
/// reply the client didn't take.
pub fn serveOne(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream, serve: Serve) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in_buf: [8192]u8 = undefined;
    var out_buf: [2048]u8 = undefined;
    var timed: Timed = .init(io, stream, .{ .in = &in_buf, .out = &out_buf }, serve.deadline_ms);
    var http: std.http.Server = .init(&timed.reader, &timed.writer);
    var req = try http.receiveHead();
    const method = @tagName(req.head.method);
    const target = try arena.dupe(u8, req.head.target);
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const length = req.head.content_length orelse 0;
    var auth: []const u8 = "";
    var first = false;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(
            h.name,
            protocol.authorization_header,
        )) auth = try arena.dupe(u8, h.value);
        if (std.ascii.eqlIgnoreCase(
            h.name,
            protocol.first_header,
        )) first = std.mem.eql(u8, h.value, protocol.first_value);
    }
    const reply: server.Reply = if (length > protocol.max_body) .{ .status = 413 } else reply: {
        var body: []const u8 = "";
        if (req.head.method.requestHasBody() and
            (length > 0 or req.head.transfer_encoding == .chunked))
        {
            try req.writeExpectContinue();
            var chunk: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&chunk);
            body = reader.allocRemaining(arena, .limited(protocol.max_body + 1)) catch |e|
                switch (e) {
                    error.StreamTooLong => break :reply .{ .status = 413 },
                    else => |other| return other,
                };
        }
        break :reply server.handle(arena, io, serve.state, serve.tokens, .{
            .method = method,
            .path = path,
            .authorization = auth,
            .first = first,
            .body = body,
        });
    };
    log.info(
        "{s} {s} {d} {s}",
        .{ method, path, reply.status, if (reply.account.len > 0) reply.account else "-" },
    );
    try req.respond(reply.body, .{
        .status = @fromBackingInt(@intCast(reply.status)),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = protocol.content_type }},
    });
}

// ----- tests -----

const testing = std.testing;

/// A connected pair on loopback: the client's end and the server's.
const Loopback = struct {
    listener: Io.net.Server,
    client: Io.net.Stream,
    peer: Io.net.Stream,

    fn open(io: Io) !Loopback {
        const any = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var listener = try any.listen(io, .{});
        errdefer listener.deinit(io);
        const client = try listener.socket.address.connect(io, .{ .mode = .stream });
        errdefer client.close(io);
        return .{ .listener = listener, .client = client, .peer = try listener.accept(io) };
    }

    fn close(l: *Loopback, io: Io) void {
        l.client.close(io);
        l.listener.deinit(io);
    }

    /// Everything the server sent, once it has closed its end.
    fn received(l: *Loopback, io: Io, arena: std.mem.Allocator) ![]const u8 {
        var buf: [1024]u8 = undefined;
        var r = l.client.reader(io, &buf);
        return r.interface.allocRemaining(arena, .limited(64 * 1024));
    }
};

fn elapsedMs(io: Io, start: Io.Clock.Timestamp) i64 {
    return start.untilNow(io).raw.toMilliseconds();
}

test "a whole request over the socket is answered" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Loopback = try .open(io);
    defer l.close(io);
    var out: [256]u8 = undefined;
    var w = l.client.writer(io, &out);
    try w.interface.writeAll("GET " ++ protocol.health_path ++ " HTTP/1.1\r\nHost: x\r\n\r\n");
    try w.interface.flush();
    try serveOne(testing.allocator, io, l.peer, .{ .state = tmp.dir, .tokens = &.{} });
    l.peer.close(io);
    const got = try l.received(io, arena.allocator());
    try testing.expect(std.mem.startsWith(u8, got, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, got, "\r\n\r\nok"));
}

test "a client that stops sending its request is cut off at the deadline, unanswered" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var l: Loopback = try .open(io);
    defer l.close(io);
    var out: [256]u8 = undefined;
    var w = l.client.writer(io, &out);
    try w.interface.writeAll("GET " ++ protocol.health_path ++ " HTTP/1.1\r\n");
    try w.interface.flush();
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const serve: Serve = .{ .state = tmp.dir, .tokens = &.{}, .deadline_ms = 100 };
    try testing.expectError(error.ReadFailed, serveOne(testing.allocator, io, l.peer, serve));
    // Well under the default deadline; a little early is the clock's rounding.
    const elapsed_ms = elapsedMs(io, start);
    try testing.expect(elapsed_ms >= 50 and elapsed_ms < 5000);
    l.peer.close(io);
    try testing.expectEqualStrings("", try l.received(io, arena.allocator()));
}

test "a client that stops reading the reply is cut off at the deadline" {
    const io = testing.io;
    var l: Loopback = try .open(io);
    defer l.close(io);
    defer l.peer.close(io);
    var in_buf: [16]u8 = undefined;
    var out_buf: [16]u8 = undefined;
    var timed: Timed = .init(io, l.peer, .{ .in = &in_buf, .out = &out_buf }, 100);
    // Far more than the socket buffers hold, in one slice as `respond` hands
    // over a body, and the client reads none of it.
    const reply = try testing.allocator.alloc(u8, 16 << 20);
    defer testing.allocator.free(reply);
    @memset(reply, 'x');
    const start: Io.Clock.Timestamp = .now(io, .awake);
    try testing.expectError(error.WriteFailed, timed.writer.writeAll(reply));
    const elapsed_ms = elapsedMs(io, start);
    try testing.expect(elapsed_ms >= 50 and elapsed_ms < 5000);
}
