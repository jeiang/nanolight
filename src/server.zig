//! nanolight-server: keeps one settings record (settings.zig) per account
//! for the clients that sync to it (account.zig).
//!
//!   nanolight-server serve --listen 127.0.0.1:8890 --state /var/lib/nanolight --tokens /path/tokens
//!   nanolight-server hash-token <token>
//!
//! One connection at a time, by design: a few machines per account sync a
//! few times an hour, so requests are served serially, never in parallel.
//! A stalled client is cut off by one deadline for the whole exchange
//! (`exchange_deadline_ms`), whether it stops sending its request or stops
//! reading the reply, so it holds the next one up for at most that long.
//! `handle` is the whole protocol over plain values, so the tests drive it
//! without a socket.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const settings = @import("settings.zig");

pub const max_body = 256 * 1024;
/// How long one connection may take, request and reply together.
const exchange_deadline_ms = 10_000;
/// The pause after a failed accept: its usual causes (no file descriptors or
/// memory left) last a while, and retrying at once would spin.
const accept_pause_ms = 100;
/// The most one send hands the kernel. Poll reports room only once more than
/// this is free (SO_SNDLOWAT, 2 KiB, on macOS; a third of the send buffer, which
/// is at least about 4.5 KiB, on Linux), so a send this size never blocks after it.
const max_write = 1024;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const Token = struct {
    account: []const u8,
    /// SHA-256 of the bearer token.
    digest: [sha256.digest_length]u8,
};

pub fn validAccount(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// A tokens file: `account:sha256hex(token)` per line; `#` starts a comment.
/// `line` is where it failed.
pub fn parseTokens(arena: std.mem.Allocator, text: []const u8, line: *usize) error{ BadLine, BadAccount, OutOfMemory }![]Token {
    var out: std.ArrayList(Token) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        line.* = n;
        const code = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        const l = std.mem.trim(u8, code, " \t\r");
        if (l.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return error.BadLine;
        const account = std.mem.trim(u8, l[0..colon], " \t");
        if (!validAccount(account)) return error.BadAccount;
        var t: Token = .{ .account = try arena.dupe(u8, account), .digest = undefined };
        const hex = std.mem.trim(u8, l[colon + 1 ..], " \t");
        if (hex.len != t.digest.len * 2) return error.BadLine;
        _ = std.fmt.hexToBytes(&t.digest, hex) catch return error.BadLine;
        try out.append(arena, t);
    }
    return out.items;
}

/// The account whose token this is. Every entry is compared, in constant
/// time, so the time taken does not say how close a guess was.
fn authenticate(tokens: []const Token, authorization: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    const given = if (std.mem.startsWith(u8, authorization, prefix)) authorization[prefix.len..] else "";
    var digest: [sha256.digest_length]u8 = undefined;
    sha256.hash(given, &digest, .{});
    var found: ?[]const u8 = null;
    for (tokens) |t| {
        if (std.crypto.timing_safe.eql([sha256.digest_length]u8, t.digest, digest)) found = t.account;
    }
    return if (given.len == 0) null else found;
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// The Authorization header, or "".
    authorization: []const u8 = "",
    /// `X-Nanolight-First: 1`: this machine's first sync.
    first: bool = false,
    body: []const u8 = "",
};

pub const Reply = struct {
    status: u16,
    body: []const u8 = "",
    /// Who it was, once authenticated (for the log).
    account: []const u8 = "",
};

/// The protocol. `state` holds `<account>.json`; `arena` owns the reply.
pub fn handle(arena: std.mem.Allocator, io: Io, state: Io.Dir, tokens: []const Token, req: Request) Reply {
    const is_get = std.mem.eql(u8, req.method, "GET");
    const is_put = std.mem.eql(u8, req.method, "PUT");
    if (std.mem.eql(u8, req.path, "/healthz")) {
        return if (is_get) .{ .status = 200, .body = "ok" } else .{ .status = 405 };
    }
    const account = authenticate(tokens, req.authorization) orelse return .{ .status = 401, .body = "unauthorized" };
    var r: Reply = .{ .status = 404, .account = account };
    if (!std.mem.eql(u8, req.path, "/v1/sync")) return r;
    if (!is_get and !is_put) {
        r.status = 405;
        return r;
    }
    const name = std.fmt.allocPrint(arena, "{s}.json", .{account}) catch return fail(r);
    const stored: ?[]const u8 = state.readFileAlloc(io, name, arena, .limited(max_body * 2)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return fail(r),
    };
    if (is_get) {
        const body = stored orelse return r;
        r.status = 200;
        r.body = body;
        return r;
    }
    if (req.body.len > max_body) {
        r.status = 413;
        return r;
    }
    const incoming = settings.decode(arena, req.body) orelse {
        r.status = 400;
        r.body = "bad record";
        return r;
    };
    // An unreadable stored record is not replaced: that would lose it.
    const have: ?settings.Settings = if (stored) |b| settings.decode(arena, b) orelse return fail(r) else null;
    const merged = settings.merge(arena, incoming, have orelse incoming, req.first) catch return fail(r);
    const body = (settings.encodeWithin(arena, merged, max_body * 2) catch return fail(r)) orelse {
        r.status = 413;
        return r;
    };
    write(io, state, name, body) catch return fail(r);
    r.status = 200;
    r.body = body;
    return r;
}

fn fail(r: Reply) Reply {
    var out = r;
    out.status = 500;
    out.body = "server error";
    return out;
}

/// Written to a temp file, fsynced, renamed over the record, then the directory
/// is fsynced: a crash leaves the old record or the new one, and an
/// acknowledged write survives power loss.
fn write(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var buf: [96]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{name});
    errdefer dir.deleteFile(io, tmp) catch {};
    const f = try dir.createFile(io, tmp, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.sync(io);
    try dir.rename(tmp, dir, name, io);
    if (builtin.os.tag != .windows) {
        const d = try dir.openDir(io, ".", .{ .iterate = true });
        defer d.close(io);
        try (Io.File{ .handle = d.handle, .flags = .{ .nonblocking = false } }).sync(io);
    }
}

// ----- the socket -----

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

/// What every connection is served with.
const Serve = struct {
    state: Io.Dir,
    tokens: []const Token,
    deadline_ms: u32 = exchange_deadline_ms,
};

fn serveOne(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream, serve: Serve) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in_buf: [8192]u8 = undefined;
    var out_buf: [2048]u8 = undefined;
    var timed: Timed = .init(io, stream, .{ .in = &in_buf, .out = &out_buf }, serve.deadline_ms);
    var http: std.http.Server = .init(&timed.reader, &timed.writer);
    var req = http.receiveHead() catch return;
    const method = @tagName(req.head.method);
    const target = arena.dupe(u8, req.head.target) catch return;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const length = req.head.content_length orelse 0;
    var auth: []const u8 = "";
    var first = false;
    var headers = req.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) auth = arena.dupe(u8, h.value) catch return;
        if (std.ascii.eqlIgnoreCase(h.name, "x-nanolight-first")) first = std.mem.eql(u8, h.value, "1");
    }
    var reply: Reply = undefined;
    if (length > max_body) {
        reply = .{ .status = 413 };
    } else {
        var body: ?[]const u8 = "";
        if (req.head.method.requestHasBody() and length > 0) {
            req.writeExpectContinue() catch return;
            var chunk: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&chunk);
            body = reader.readAlloc(arena, @intCast(length)) catch return;
        } else if (req.head.method.requestHasBody() and req.head.transfer_encoding == .chunked) {
            req.writeExpectContinue() catch return;
            var chunk: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&chunk);
            body = reader.allocRemaining(arena, .limited(max_body + 1)) catch |e| switch (e) {
                error.StreamTooLong => null,
                else => return,
            };
        }
        reply = .{ .status = 413 };
        if (body) |b| {
            const parsed: Request = .{
                .method = method,
                .path = path,
                .authorization = auth,
                .first = first,
                .body = b,
            };
            reply = handle(arena, io, serve.state, serve.tokens, parsed);
        }
    }
    std.log.info("{s} {s} {d} {s}", .{ method, path, reply.status, if (reply.account.len > 0) reply.account else "-" });
    req.respond(reply.body, .{
        .status = @fromBackingInt(@intCast(reply.status)),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {}; // best effort: the client left or passed the deadline; nothing to tell it.
}

const usage =
    \\usage: nanolight-server serve --listen 127.0.0.1:8890 --state DIR --tokens FILE
    \\       nanolight-server hash-token TOKEN
    \\
;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return fatal(usage);
    if (std.mem.eql(u8, cmd, "hash-token")) {
        const token = args.next() orelse return fatal(usage);
        var digest: [sha256.digest_length]u8 = undefined;
        sha256.hash(token, &digest, .{});
        var buf: [128]u8 = undefined;
        var w = Io.File.stdout().writer(init.io, &buf);
        try w.interface.print("ACCOUNT:{s}\n", .{std.fmt.bytesToHex(digest, .lower)});
        return w.interface.flush();
    }
    if (!std.mem.eql(u8, cmd, "serve")) return fatal(usage);

    var listen_arg: ?[]const u8 = null;
    var state_path: ?[]const u8 = null;
    var tokens_path: ?[]const u8 = null;
    while (args.next()) |a| {
        const slot = if (std.mem.eql(u8, a, "--listen")) &listen_arg else if (std.mem.eql(u8, a, "--state")) &state_path else if (std.mem.eql(u8, a, "--tokens")) &tokens_path else return fatal(usage);
        const v = args.next() orelse return fatal(usage);
        slot.* = v;
    }
    const listen = listen_arg orelse "127.0.0.1:8890";
    const state_dir = state_path orelse return fatal(usage);
    const tokens_file = tokens_path orelse return fatal(usage);

    const text = Io.Dir.cwd().readFileAlloc(init.io, tokens_file, init.arena.allocator(), .limited(1 << 20)) catch |e|
        return fatalf("nanolight-server: {s}: {t}\n", .{ tokens_file, e });
    var line: usize = 0;
    const tokens = parseTokens(init.arena.allocator(), text, &line) catch |e|
        return fatalf("nanolight-server: {s}:{d}: {t}\n", .{ tokens_file, line, e });
    if (tokens.len == 0) return fatalf("nanolight-server: {s} has no tokens\n", .{tokens_file});

    // Opened before any create: under systemd's DynamicUser the state
    // directory is a symlink, which createDirPath rejects as NotDir.
    const state = Io.Dir.cwd().openDir(init.io, state_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            Io.Dir.cwd().createDirPath(init.io, state_dir) catch |ce| return fatalf("nanolight-server: {s}: {t}\n", .{ state_dir, ce });
            break :blk Io.Dir.cwd().openDir(init.io, state_dir, .{}) catch |oe| return fatalf("nanolight-server: {s}: {t}\n", .{ state_dir, oe });
        },
        else => return fatalf("nanolight-server: {s}: {t}\n", .{ state_dir, e }),
    };
    const addr = Io.net.IpAddress.parseLiteral(listen) catch return fatalf("nanolight-server: bad --listen {s}\n", .{listen});
    var server = try addr.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    std.log.info("listening on {s}, {d} account(s)", .{ listen, tokens.len });
    while (true) {
        const stream = server.accept(init.io) catch |e| {
            std.log.warn("accept: {t}", .{e});
            try init.io.sleep(.fromMilliseconds(accept_pause_ms), .awake);
            continue;
        };
        defer stream.close(init.io);
        serveOne(init.gpa, init.io, stream, .{ .state = state, .tokens = tokens });
    }
}

fn fatal(msg: []const u8) error{Usage} {
    std.log.err("{s}", .{msg});
    return error.Usage;
}

fn fatalf(comptime fmt: []const u8, args: anytype) error{Usage} {
    std.log.err(fmt, args);
    return error.Usage;
}

// ----- tests -----

const testing = std.testing;
const test_token = "s3cret-token";

fn testTokens(arena: std.mem.Allocator) ![]Token {
    var digest: [sha256.digest_length]u8 = undefined;
    sha256.hash(test_token, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var line: usize = 0;
    return parseTokens(arena, try std.fmt.allocPrint(arena, "# accounts\nalice:{s}  # laptop\n\n", .{hex}), &line);
}

const bearer = "Bearer " ++ test_token;

fn send(arena: std.mem.Allocator, dir: Io.Dir, tokens: []const Token, req: Request) Reply {
    return handle(arena, testing.io, dir, tokens, req);
}

fn record(arena: std.mem.Allocator, hotkey: []const u8, at: i64) ![]const u8 {
    return settings.encode(arena, .{ .hotkey = hotkey, .suggest = true, .at = at });
}

test "a record round-trips with the right token, and is not there before the first PUT" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);

    try testing.expectEqual(@as(u16, 404), send(a, tmp.dir, tokens, .{ .method = "GET", .path = "/v1/sync", .authorization = bearer }).status);
    const body = try record(a, "cmd_space", 10);
    const put = send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = body });
    try testing.expectEqual(@as(u16, 200), put.status);
    try testing.expectEqualStrings("alice", put.account);
    const got = send(a, tmp.dir, tokens, .{ .method = "GET", .path = "/v1/sync", .authorization = bearer });
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(settings.same(settings.decode(a, got.body).?, settings.decode(a, body).?));
    try testing.expectEqualStrings("ok", send(a, tmp.dir, tokens, .{ .method = "GET", .path = "/healthz" }).body);
}

test "a missing or wrong token is refused, and nothing is read or written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const body = try record(a, "cmd_space", 10);
    for ([_][]const u8{ "", "Bearer ", "Bearer wrong", "Basic " ++ test_token, test_token }) |auth| {
        for ([_][]const u8{ "GET", "PUT" }) |m| {
            const r = send(a, tmp.dir, tokens, .{ .method = m, .path = "/v1/sync", .authorization = auth, .body = body });
            try testing.expectEqual(@as(u16, 401), r.status);
        }
    }
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "alice.json", .{}));
}

test "a body that is not a record is a 400, and one over 256 KiB a 413" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    for ([_][]const u8{ "not json", "{}", "{\"v\":9,\"hotkey\":\"x\",\"suggest\":true,\"at\":1}" }) |b| {
        try testing.expectEqual(@as(u16, 400), send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = b }).status);
    }
    const big = try a.alloc(u8, max_body + 1);
    @memset(big, ' ');
    try testing.expectEqual(@as(u16, 413), send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = big }).status);
    try testing.expectEqual(@as(u16, 404), send(a, tmp.dir, tokens, .{ .method = "GET", .path = "/v1/sync", .authorization = bearer }).status);
}

test "a merge that outgrows the stored limit sheds apps and stays readable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const pad = try a.alloc(u8, 480);
    @memset(pad, 'x');
    for (0..3) |k| {
        const launches = try a.alloc(settings.Launch, 450);
        for (launches, 0..) |*l, i| l.* = .{ .name = "App", .path = try std.fmt.allocPrint(a, "/Applications/{d}/{d:0>3}/{s}", .{ k, i, pad }), .count = 1 };
        const body = try settings.encode(a, .{ .hotkey = "cmd_space", .suggest = true, .at = 1, .launches = launches });
        try testing.expect(body.len <= max_body);
        const put = send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = body });
        try testing.expectEqual(@as(u16, 200), put.status);
        try testing.expect(put.body.len <= max_body * 2);
        const got = send(a, tmp.dir, tokens, .{ .method = "GET", .path = "/v1/sync", .authorization = bearer });
        try testing.expectEqual(@as(u16, 200), got.status);
    }
}

test "a first sync keeps the stored record, a later one the newer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const put = struct {
        fn f(al: std.mem.Allocator, dir: Io.Dir, t: []const Token, hotkey: []const u8, at: i64, first: bool) ![]const u8 {
            const r = send(al, dir, t, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .first = first, .body = try record(al, hotkey, at) });
            try testing.expectEqual(@as(u16, 200), r.status);
            return settings.decode(al, r.body).?.hotkey;
        }
    }.f;
    try testing.expectEqualStrings("cmd_space", try put(a, tmp.dir, tokens, "cmd_space", 100, false));
    // A new machine's first sync: the account's choice wins, though this one is newer.
    try testing.expectEqualStrings("cmd_space", try put(a, tmp.dir, tokens, "opt_space", 500, true));
    // Later: the newer wins, either way round.
    try testing.expectEqualStrings("opt_space", try put(a, tmp.dir, tokens, "opt_space", 600, false));
    try testing.expectEqualStrings("opt_space", try put(a, tmp.dir, tokens, "cmd_space", 200, false));
}

test "a write leaves no temp file, and an unreadable record is not overwritten" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const body = try record(a, "cmd_space", 10);
    try testing.expectEqual(@as(u16, 200), send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = body }).status);
    var it = tmp.dir.iterate();
    var names: usize = 0;
    while (try it.next(testing.io)) |e| {
        names += 1;
        try testing.expectEqualStrings("alice.json", e.name);
    }
    try testing.expectEqual(@as(usize, 1), names);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "alice.json", .data = "garbage" });
    try testing.expectEqual(@as(u16, 500), send(a, tmp.dir, tokens, .{ .method = "PUT", .path = "/v1/sync", .authorization = bearer, .body = body }).status);
    const kept = try tmp.dir.readFileAlloc(testing.io, "alice.json", a, .limited(100));
    try testing.expectEqualStrings("garbage", kept);
}

test "an invalid account name in the tokens file is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hash: [64]u8 = @splat('0');
    const long: [65]u8 = @splat('a');
    var line: usize = 0;
    for ([_][]const u8{ "Alice", "al ice", "../x", "", &long }) |name| {
        const text = try std.fmt.allocPrint(a, "{s}:{s}", .{ name, hash });
        try testing.expectError(error.BadAccount, parseTokens(a, text, &line));
    }
    try testing.expectError(error.BadLine, parseTokens(a, "ok:abc", &line));
    try testing.expectError(error.BadLine, parseTokens(a, "ok\n", &line));
    const not_hex: [64]u8 = @splat('g');
    try testing.expectError(error.BadLine, parseTokens(a, try std.fmt.allocPrint(a, "# fine\nok:{s}", .{not_hex}), &line));
    try testing.expectEqual(@as(usize, 2), line);
    const ok = try parseTokens(a, try std.fmt.allocPrint(a, "a_b-1:{0s}\n# c\nz:{0s} # trailing\n", .{hash}), &line);
    try testing.expectEqual(@as(usize, 2), ok.len);
}

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
    try w.interface.writeAll("GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n");
    try w.interface.flush();
    serveOne(testing.allocator, io, l.peer, .{ .state = tmp.dir, .tokens = &.{} });
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
    try w.interface.writeAll("GET /healthz HTTP/1.1\r\n");
    try w.interface.flush();
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const serve: Serve = .{ .state = tmp.dir, .tokens = &.{}, .deadline_ms = 100 };
    serveOne(testing.allocator, io, l.peer, serve);
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
