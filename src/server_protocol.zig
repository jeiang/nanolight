//! nanolight-server's side of the sync wire (sync_protocol.zig) over plain
//! values, so the tests drive it without a socket: the tokens, and one
//! settings record (settings.zig) per account, kept as `<account>.json`.
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const builtin = @import("builtin");
const protocol = @import("sync_protocol.zig");
const settings = @import("settings.zig");

const sha256 = std.crypto.hash.sha2.Sha256;
pub const Digest = [sha256.digest_length]u8;

pub const Token = struct {
    account: []const u8,
    /// SHA-256 of the bearer token.
    digest: Digest,
};

/// What a tokens file holds for `token`.
pub fn digestOf(token: []const u8) Digest {
    var digest: Digest = undefined;
    sha256.hash(token, &digest, .{});
    return digest;
}

/// A tokens file: `account:sha256hex(token)` per line; `#` starts a comment.
/// `line` is where it failed.
pub fn parseTokens(
    arena: std.mem.Allocator,
    text: []const u8,
    line: *usize,
) error{ BadLine, BadAccount, OutOfMemory }![]Token {
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
        if (!protocol.validAccount(account)) return error.BadAccount;
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
    const prefix = protocol.bearer_prefix;
    const given = if (std.mem.startsWith(u8, authorization, prefix))
        authorization[prefix.len..]
    else
        "";
    const digest = digestOf(given);
    var found: ?[]const u8 = null;
    for (tokens) |t| {
        if (std.crypto.timing_safe.eql(Digest, t.digest, digest)) found = t.account;
    }
    return if (given.len == 0) null else found;
}

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    /// The `protocol.authorization_header`, or "".
    authorization: []const u8 = "",
    /// `protocol.first_header`: this machine's first sync.
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
pub fn handle(
    arena: std.mem.Allocator,
    io: Io,
    state: Io.Dir,
    tokens: []const Token,
    req: Request,
) Reply {
    const is_get = std.mem.eql(u8, req.method, "GET");
    const is_put = std.mem.eql(u8, req.method, "PUT");
    if (std.mem.eql(u8, req.path, protocol.health_path)) {
        return if (is_get) .{ .status = 200, .body = "ok" } else .{ .status = 405 };
    }
    const account = authenticate(tokens, req.authorization) orelse
        return .{ .status = 401, .body = "unauthorized" };
    var r: Reply = .{ .status = 404, .account = account };
    if (!std.mem.eql(u8, req.path, protocol.path)) return r;
    if (!is_get and !is_put) {
        r.status = 405;
        return r;
    }
    var name_buf: [record_name_max]u8 = undefined;
    const name = recordName(&name_buf, account);
    const stored: ?[]const u8 = state.readFileAlloc(
        io,
        name,
        arena,
        .limited(protocol.max_stored),
    ) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return fail(r),
    };
    if (is_get) {
        const body = stored orelse return r;
        r.status = 200;
        r.body = body;
        return r;
    }
    if (req.body.len > protocol.max_body) {
        r.status = 413;
        return r;
    }
    const incoming = settings.decode(arena, req.body) orelse {
        r.status = 400;
        r.body = "bad record";
        return r;
    };
    // An unreadable stored record is not replaced: that would lose it.
    const have: ?settings.Settings = if (stored) |b|
        settings.decode(arena, b) orelse return fail(r)
    else
        null;
    const merged = settings.merge(
        arena,
        incoming,
        have orelse incoming,
        req.first,
    ) catch return fail(r);
    const body = (settings.encodeWithin(arena, merged, protocol.max_stored) catch
        return fail(r)) orelse {
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

const record_suffix = ".json";
const temp_suffix = ".tmp";
const record_name_max = protocol.account_max + record_suffix.len;

/// `<account>.json`: a valid account name is safe as a file name.
fn recordName(buf: *[record_name_max]u8, account: []const u8) []const u8 {
    assert(protocol.validAccount(account));
    @memcpy(buf[0..account.len], account);
    @memcpy(buf[account.len..][0..record_suffix.len], record_suffix);
    return buf[0 .. account.len + record_suffix.len];
}

/// Written to a temp file, fsynced, renamed over the record, then the directory
/// is fsynced: a crash leaves the old record or the new one, and an
/// acknowledged write survives power loss.
fn write(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    assert(name.len <= record_name_max);
    var buf: [record_name_max + temp_suffix.len]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    @memcpy(buf[name.len..][0..temp_suffix.len], temp_suffix);
    const tmp = buf[0 .. name.len + temp_suffix.len];
    errdefer dir.deleteFile(io, tmp) catch |err| std.log.warn(
        "{s}: not removed: {t}",
        .{ tmp, err },
    );
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

// ----- tests -----

const testing = std.testing;
const test_token = "s3cret-token";

fn testTokens(arena: std.mem.Allocator) ![]Token {
    const hex = std.fmt.bytesToHex(digestOf(test_token), .lower);
    var line: usize = 0;
    return parseTokens(
        arena,
        try std.fmt.allocPrint(arena, "# accounts\nalice:{s}  # laptop\n\n", .{hex}),
        &line,
    );
}

const bearer = protocol.bearer_prefix ++ test_token;
const get: Request = .{ .method = "GET", .path = protocol.path, .authorization = bearer };

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

    try testing.expectEqual(
        @as(u16, 404),
        send(a, tmp.dir, tokens, get).status,
    );
    const body = try record(a, "cmd_space", 10);
    const put = send(
        a,
        tmp.dir,
        tokens,
        .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = body },
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    try testing.expectEqualStrings("alice", put.account);
    const got = send(
        a,
        tmp.dir,
        tokens,
        .{ .method = "GET", .path = protocol.path, .authorization = bearer },
    );
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expect(settings.same(settings.decode(a, got.body).?, settings.decode(a, body).?));
    try testing.expectEqualStrings(
        "ok",
        send(a, tmp.dir, tokens, .{ .method = "GET", .path = protocol.health_path }).body,
    );
}

test "a missing or wrong token is refused, and nothing is read or written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const body = try record(a, "cmd_space", 10);
    for ([_][]const u8{
        "",
        protocol.bearer_prefix,
        protocol.bearer_prefix ++ "wrong",
        "Basic " ++ test_token,
        test_token,
    }) |auth| {
        for ([_][]const u8{ "GET", "PUT" }) |m| {
            const r = send(
                a,
                tmp.dir,
                tokens,
                .{ .method = m, .path = protocol.path, .authorization = auth, .body = body },
            );
            try testing.expectEqual(@as(u16, 401), r.status);
        }
    }
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "alice.json", .{}));
}

test "a body that is not a record is a 400, and one over the limit a 413" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    for ([_][]const u8{
        "not json",
        "{}",
        "{\"v\":9,\"hotkey\":\"x\",\"suggest\":true,\"at\":1}",
    }) |b| {
        try testing.expectEqual(
            @as(u16, 400),
            send(
                a,
                tmp.dir,
                tokens,
                .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = b },
            ).status,
        );
    }
    const big = try a.alloc(u8, protocol.max_body + 1);
    @memset(big, ' ');
    try testing.expectEqual(
        @as(u16, 413),
        send(
            a,
            tmp.dir,
            tokens,
            .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = big },
        ).status,
    );
    try testing.expectEqual(
        @as(u16, 404),
        send(a, tmp.dir, tokens, get).status,
    );
}

test "a merge that outgrows the stored limit sheds apps and stays readable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    // Control bytes are sent escaped, six bytes each: a few PUTs' apps,
    // each body under the request limit, merge past the stored one.
    const pad = try a.alloc(u8, 400);
    @memset(pad, 0x01);
    const per_put = 100;
    for (0..3) |k| {
        const launches = try a.alloc(settings.Launch, per_put);
        for (launches, 0..) |*l, i| l.* = .{
            .name = "App",
            .path = try std.fmt.allocPrint(a, "/Applications/{d}/{d:0>3}/{s}", .{ k, i, pad }),
            .count = 1,
        };
        const body = try settings.encode(
            a,
            .{ .hotkey = "cmd_space", .suggest = true, .at = 1, .launches = launches },
        );
        try testing.expect(body.len <= protocol.max_body);
        const put = send(
            a,
            tmp.dir,
            tokens,
            .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = body },
        );
        try testing.expectEqual(@as(u16, 200), put.status);
        try testing.expect(put.body.len <= protocol.max_stored);
        const got = send(
            a,
            tmp.dir,
            tokens,
            .{ .method = "GET", .path = protocol.path, .authorization = bearer },
        );
        try testing.expectEqual(@as(u16, 200), got.status);
        const kept = settings.decode(a, got.body).?;
        try testing.expectEqualStrings("cmd_space", kept.hotkey);
        try testing.expect(kept.launches.len > 0);
        // All of them, until they no longer fit.
        if (k < 2) try testing.expectEqual(per_put * (k + 1), kept.launches.len);
        if (k == 2) try testing.expect(kept.launches.len < per_put * 3);
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
        fn f(
            al: std.mem.Allocator,
            dir: Io.Dir,
            t: []const Token,
            hotkey: []const u8,
            at: i64,
            first: bool,
        ) ![]const u8 {
            const r = send(
                al,
                dir,
                t,
                .{
                    .method = "PUT",
                    .path = protocol.path,
                    .authorization = bearer,
                    .first = first,
                    .body = try record(al, hotkey, at),
                },
            );
            try testing.expectEqual(@as(u16, 200), r.status);
            return settings.decode(al, r.body).?.hotkey;
        }
    }.f;
    try testing.expectEqualStrings(
        "cmd_space",
        try put(a, tmp.dir, tokens, "cmd_space", 100, false),
    );
    // A new machine's first sync: the account's choice wins, though this one is newer.
    try testing.expectEqualStrings(
        "cmd_space",
        try put(a, tmp.dir, tokens, "opt_space", 500, true),
    );
    // Later: the newer wins, either way round.
    try testing.expectEqualStrings(
        "opt_space",
        try put(a, tmp.dir, tokens, "opt_space", 600, false),
    );
    try testing.expectEqualStrings(
        "opt_space",
        try put(a, tmp.dir, tokens, "cmd_space", 200, false),
    );
}

test "a write leaves no temp file, and an unreadable record is not overwritten" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = try testTokens(a);
    const body = try record(a, "cmd_space", 10);
    try testing.expectEqual(
        @as(u16, 200),
        send(
            a,
            tmp.dir,
            tokens,
            .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = body },
        ).status,
    );
    var it = tmp.dir.iterate();
    var names: usize = 0;
    while (try it.next(testing.io)) |e| {
        names += 1;
        try testing.expectEqualStrings("alice.json", e.name);
    }
    try testing.expectEqual(@as(usize, 1), names);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "alice.json", .data = "garbage" });
    try testing.expectEqual(
        @as(u16, 500),
        send(
            a,
            tmp.dir,
            tokens,
            .{ .method = "PUT", .path = protocol.path, .authorization = bearer, .body = body },
        ).status,
    );
    const kept = try tmp.dir.readFileAlloc(testing.io, "alice.json", a, .limited(100));
    try testing.expectEqualStrings("garbage", kept);
}

test "the longest account name's record is written" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const longest: [protocol.account_max]u8 = @splat('z');
    const hex = std.fmt.bytesToHex(digestOf(test_token), .lower);
    var line: usize = 0;
    const text = try std.fmt.allocPrint(a, "{s}:{s}", .{ &longest, hex });
    const tokens = try parseTokens(a, text, &line);
    const put = send(
        a,
        tmp.dir,
        tokens,
        .{
            .method = "PUT",
            .path = protocol.path,
            .authorization = bearer,
            .body = try record(a, "cmd_space", 10),
        },
    );
    try testing.expectEqual(@as(u16, 200), put.status);
    try tmp.dir.access(testing.io, longest ++ record_suffix, .{});
}

test "an invalid account name in the tokens file is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hash: [64]u8 = @splat('0');
    const long: [protocol.account_max + 1]u8 = @splat('a');
    var line: usize = 0;
    for ([_][]const u8{ "Alice", "al ice", "../x", "", &long }) |name| {
        const text = try std.fmt.allocPrint(a, "{s}:{s}", .{ name, hash });
        try testing.expectError(error.BadAccount, parseTokens(a, text, &line));
    }
    try testing.expectError(error.BadLine, parseTokens(a, "ok:abc", &line));
    try testing.expectError(error.BadLine, parseTokens(a, "ok\n", &line));
    const not_hex: [64]u8 = @splat('g');
    try testing.expectError(
        error.BadLine,
        parseTokens(a, try std.fmt.allocPrint(a, "# fine\nok:{s}", .{not_hex}), &line),
    );
    try testing.expectEqual(@as(usize, 2), line);
    const ok = try parseTokens(
        a,
        try std.fmt.allocPrint(a, "a_b-1:{0s}\n# c\nz:{0s} # trailing\n", .{hash}),
        &line,
    );
    try testing.expectEqual(@as(usize, 2), ok.len);
}
