//! nanolight-server: keeps one settings record (settings.zig) per account
//! for the clients that sync to it (account.zig).
//!
//!   nanolight-server serve --listen 127.0.0.1:8890 --state /var/lib/nanolight --tokens /path/tokens
//!   nanolight-server hash-token <token>
//!
//! One request at a time: a stalled client is cut off by a deadline
//! (`read_deadline_s`), not waited on. `handle` is the whole protocol over
//! plain values, so the tests drive it without a socket.
const std = @import("std");
const Io = std.Io;
const settings = @import("settings.zig");

pub const max_body = 256 * 1024;
const read_deadline_s = 10;
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

/// Written to a temp file, fsynced, then renamed over the record: a crash
/// leaves the old record or the new one.
fn write(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var buf: [96]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{name});
    errdefer dir.deleteFile(io, tmp) catch {};
    const f = try dir.createFile(io, tmp, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
    try f.sync(io);
    try dir.rename(tmp, dir, name, io);
}

// ----- the socket -----

/// A reader that gives up at a deadline for the whole request.
const Timed = struct {
    io: Io,
    stream: Io.net.Stream,
    deadline: Io.Timeout,
    interface: Io.Reader,

    fn init(io: Io, stream: Io.net.Stream, buffer: []u8) Timed {
        return .{
            .io = io,
            .stream = stream,
            .deadline = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(read_deadline_s), .clock = .awake } }).toDeadline(io),
            .interface = .{ .vtable = &.{ .stream = streamFn }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn streamFn(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const t: *Timed = @alignCast(@fieldParentPtr("interface", r));
        var data: [1][]u8 = .{limit.slice(try w.writableSliceGreedy(1))};
        const done = t.io.operateTimeout(.{ .net_read = .{ .socket_handle = t.stream.socket.handle, .data = &data } }, t.deadline) catch return error.ReadFailed;
        const got = done.net_read catch return error.ReadFailed;
        if (got.data_len == 0) return error.EndOfStream;
        w.advance(got.data_len);
        return got.data_len;
    }
};

fn serveOne(gpa: std.mem.Allocator, io: Io, stream: Io.net.Stream, state: Io.Dir, tokens: []const Token) void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var in_buf: [8192]u8 = undefined;
    var out_buf: [2048]u8 = undefined;
    var timed: Timed = .init(io, stream, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var http: std.http.Server = .init(&timed.interface, &writer.interface);
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
        var body: []const u8 = "";
        if (req.head.method.requestHasBody() and length > 0) {
            req.writeExpectContinue() catch return;
            var chunk: [1024]u8 = undefined;
            const reader = req.readerExpectNone(&chunk);
            body = reader.readAlloc(arena, @intCast(length)) catch return;
        }
        reply = handle(arena, io, state, tokens, .{ .method = method, .path = path, .authorization = auth, .first = first, .body = body });
    }
    std.log.info("{s} {s} {d} {s}", .{ method, path, reply.status, if (reply.account.len > 0) reply.account else "-" });
    req.respond(reply.body, .{
        .status = @fromBackingInt(@intCast(reply.status)),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
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
            continue;
        };
        defer stream.close(init.io);
        serveOne(init.gpa, init.io, stream, state, tokens);
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
