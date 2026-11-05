//! Syncing settings (settings.zig) through a nanolight-server (server.zig)
//! to every machine on the same account. Off unless `[sync]` in config.toml
//! names a server (`url`) and a file holding the account's token
//! (`token_file`); nothing leaves the machine otherwise.
//!
//! One request does it all: PUT this machine's record, and the server's
//! answer is the two merged. It runs at launch, when the panel opens if the
//! last one is five minutes old, and two seconds after a change.
const std = @import("std");
const nanoui = @import("nanoui");
const settings = @import("settings.zig");
const config = @import("config.zig");
const Settings = settings.Settings;

/// Marks this machine's first sync with a server: the stored record wins.
const first_header = "X-Nanolight-First";
/// Holds the server this machine last synced with: a different one is a first sync again.
const synced_key = "nanolight.account.synced";
const pull_every_s = 5 * 60;
const push_after_ms = 2000;
pub const off_text = "Sync: off (set [sync] in config.toml)";

pub const Hooks = struct {
    ctx: *anyopaque,
    /// This machine's settings now (allocated with `arena`).
    snapshot: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) Settings,
    /// The server's settings merged with this machine's: take them.
    apply: *const fn (ctx: *anyopaque, s: Settings) void,
    /// The sync status changed: the menu changes.
    changed: *const fn (ctx: *anyopaque) void,
};

pub const State = enum { off, pending, ok, failed };

pub const Account = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kv: nanoui.kv.Store,
    hooks: Hooks,
    cfg: config.Sync,
    state: State = .off,
    token: ?[]u8 = null,
    last_ok: i64 = 0,
    last_pull: i64 = 0,
    reason_buf: [96]u8 = undefined,
    reason_len: usize = 0,
    busy: bool = false,
    /// Whether the request in flight is this machine's first sync, and the `at` it sent.
    first_sent: bool = false,
    sent_at: i64 = 0,
    pushes_waiting: u32 = 0,

    /// At launch: reads the token and syncs, if `[sync]` is set.
    pub fn load(a: *Account) void {
        if (a.cfg.url.len == 0) return;
        if (a.cfg.token_file.len == 0) return a.fail("sync.token_file is not set");
        if (baseUrl(a.cfg.url) == null) return a.fail("sync.url must start with http:// or https://");
        const text = std.Io.Dir.cwd().readFileAlloc(a.io, a.cfg.token_file, a.gpa, .limited(4096)) catch |e|
            return a.failf("cannot read token_file ({t})", .{e});
        defer a.gpa.free(text);
        const t = tokenOf(text) orelse return a.fail("token_file holds no token");
        a.token = a.gpa.dupe(u8, t) catch return a.fail("out of memory");
        a.state = .pending;
        a.hooks.changed(a.hooks.ctx);
        a.sync();
    }

    fn fail(a: *Account, reason: []const u8) void {
        a.failf("{s}", .{reason});
    }

    fn failf(a: *Account, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&a.reason_buf, fmt, args) catch a.reason_buf[0..0];
        a.reason_len = s.len;
        a.state = .failed;
        a.hooks.changed(a.hooks.ctx);
    }

    /// "Sync: host, last synced 3 min ago", "Sync: error ...", or `off_text`.
    pub fn status(a: *const Account, buf: []u8) []const u8 {
        const host = hostOf(a.cfg.url);
        return switch (a.state) {
            .off => off_text,
            .pending => std.fmt.bufPrint(buf, "Sync: {s}, syncing…", .{host}) catch off_text,
            .ok => blk: {
                var ago_buf: [32]u8 = undefined;
                break :blk std.fmt.bufPrint(buf, "Sync: {s}, last synced {s}", .{ host, ago(&ago_buf, now() - a.last_ok) }) catch off_text;
            },
            .failed => std.fmt.bufPrint(buf, "Sync: error {s}", .{a.reason_buf[0..a.reason_len]}) catch "Sync: error",
        };
    }

    /// When the panel opens: sync, if the last one is old.
    pub fn maybePull(a: *Account) void {
        if (a.token != null and now() - a.last_pull > pull_every_s) a.sync();
    }

    /// This machine's settings changed: sent once changes pause.
    pub fn changed(a: *Account) void {
        if (a.token == null) return;
        a.pushes_waiting += 1;
        nanoui.App.after(push_after_ms, a, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const acc: *Account = @ptrCast(@alignCast(ctx.?));
                acc.pushes_waiting -= 1;
                if (acc.pushes_waiting == 0) acc.sync();
            }
        }.f);
    }

    fn firstHere(a: *Account) bool {
        const have = a.kv.get(a.gpa, synced_key) catch return true;
        defer if (have) |h| a.gpa.free(h);
        return !sameServer(have orelse return true, a.cfg.url);
    }

    fn sync(a: *Account) void {
        const token = a.token orelse return;
        if (a.busy) return;
        a.last_pull = now();
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const sent = a.hooks.snapshot(a.hooks.ctx, al);
        const body = settings.encode(al, sent) catch return a.fail("out of memory");
        const base = baseUrl(a.cfg.url).?;
        const url = std.fmt.allocPrint(al, "{s}/v1/sync", .{base}) catch return a.fail("out of memory");
        const auth = std.fmt.allocPrint(al, "Bearer {s}", .{token}) catch return a.fail("out of memory");
        var headers = [_]nanoui.http.Header{
            .{ .name = "Authorization", .value = auth },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = first_header, .value = "1" },
        };
        a.busy = true;
        a.first_sent = a.firstHere();
        a.sent_at = sent.at;
        nanoui.http.fetch(a.gpa, .{
            .url = url,
            .method = "PUT",
            .headers = headers[0..if (a.first_sent) 3 else 2],
            .body = body,
            .timeout = 15,
        }, a, answered);
    }

    fn answered(a: *Account, r: nanoui.http.Response) void {
        a.busy = false;
        if (r.status == 0) return a.failf("{s}", .{if (r.err.len > 0) r.err else "unreachable"});
        if (r.status == 401) return a.fail("the server rejected the token");
        if (r.status != 200) return a.failf("the server answered {d}", .{r.status});
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        const al = arena.allocator();
        const theirs = settings.decode(al, r.body) orelse return a.fail("the server's answer is not a record");
        // Changed again while this was out: those choices are newer, and stay,
        // even on a first sync.
        const now_here = a.hooks.snapshot(a.hooks.ctx, al);
        const first = a.first_sent and now_here.at == a.sent_at;
        const merged = settings.merge(al, now_here, theirs, first) catch return a.fail("out of memory");
        a.hooks.apply(a.hooks.ctx, merged);
        a.kv.set(synced_key, a.cfg.url) catch {};
        a.last_ok = now();
        a.state = .ok;
        a.hooks.changed(a.hooks.ctx);
        if (!settings.same(merged, theirs)) a.changed();
    }
};

/// `url` without a trailing slash, if it is an http(s) address.
fn baseUrl(url: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
    return std.mem.trimEnd(u8, url, "/");
}

/// The same server whatever the trailing slash.
fn sameServer(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn hostOf(url: []const u8) []const u8 {
    const rest = url[(std.mem.indexOf(u8, url, "://") orelse return url) + 3 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// The token in a token file: its one line, trimmed. Null for none, or for
/// bytes that cannot go in a header.
fn tokenOf(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    for (t) |c| if (c < 0x21 or c > 0x7e) return null;
    return t;
}

fn ago(buf: []u8, secs: i64) []const u8 {
    const s = @max(secs, 0);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(s, 60)})
    else if (s < 86400)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(s, 86400)})) catch "";
}

extern "c" fn time(t: ?*i64) i64;

/// Unix seconds.
pub fn now() i64 {
    return time(null);
}

test "the server's address and the token file's token" {
    try std.testing.expectEqualStrings("http://100.64.0.3:8890", baseUrl("http://100.64.0.3:8890/").?);
    try std.testing.expect(baseUrl("100.64.0.3:8890") == null);
    try std.testing.expect(baseUrl("ftp://x") == null);
    try std.testing.expectEqualStrings("100.64.0.3:8890", hostOf("http://100.64.0.3:8890/v1"));
    try std.testing.expectEqualStrings("abc123", tokenOf("  abc123\n").?);
    try std.testing.expect(tokenOf("\n") == null);
    try std.testing.expect(tokenOf("two words") == null);
    try std.testing.expect(tokenOf("a\r\nX-Evil: 1") == null);
}

test "the status line says when it last synced" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", ago(&buf, 5));
    try std.testing.expectEqualStrings("3 min ago", ago(&buf, 190));
    try std.testing.expectEqualStrings("2 h ago", ago(&buf, 7300));
    try std.testing.expectEqualStrings("2 d ago", ago(&buf, 2 * 86400 + 5));
    const off: Account = .{ .gpa = std.testing.allocator, .io = std.testing.io, .kv = undefined, .hooks = undefined, .cfg = .{} };
    var line: [160]u8 = undefined;
    try std.testing.expectEqualStrings(off_text, off.status(&line));
    var bad = off;
    bad.cfg = .{ .url = "http://h:1" };
    bad.state = .failed;
    bad.reason_len = (std.fmt.bufPrint(&bad.reason_buf, "the server rejected the token", .{}) catch unreachable).len;
    try std.testing.expectEqualStrings("Sync: error the server rejected the token", bad.status(&line));
    var good = bad;
    good.state = .ok;
    good.last_ok = now() - 400;
    try std.testing.expectEqualStrings("Sync: h:1, last synced 6 min ago", good.status(&line));
}

test "a trailing slash does not make a server a new one" {
    try std.testing.expect(sameServer("http://100.64.0.3:8890", "http://100.64.0.3:8890/"));
    try std.testing.expect(!sameServer("http://100.64.0.3:8890", "http://sync.host:8890"));
}
