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

/// Why the last sync failed, for the status line.
pub const Reason = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn text(r: *const Reason) []const u8 {
        return r.buf[0..r.len];
    }
};

pub const Status = union(enum) {
    /// No `[sync]` in config.toml.
    off,
    /// The token is read; no answer yet.
    pending,
    /// Last synced (unix seconds).
    synced: i64,
    failed: Reason,
};

/// The request out: whether it is this machine's first sync, and the `at` it sent.
const Inflight = struct { first: bool, sent_at: i64 };

/// Sends a request; its answer goes to `answered`. Tests answer themselves.
pub const Send = *const fn (a: *Account, req: nanoui.http.Request) void;

fn fetch(a: *Account, req: nanoui.http.Request) void {
    nanoui.http.fetch(a.gpa, req, a, Account.answered);
}

pub const Account = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    kv: nanoui.kv.Store,
    hooks: Hooks,
    cfg: config.Sync,
    state: Status = .off,
    token: ?[]u8 = null,
    last_pull: i64 = 0,
    inflight: ?Inflight = null,
    /// Asked to sync while a request was out: synced once more when it
    /// succeeds. A failure drops it (no retry; the next change or pull asks).
    dirty: bool = false,
    pushes_waiting: u32 = 0,
    send: Send = fetch,

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
        var r: Reason = .{};
        // Too long to say: no reason given.
        r.len = if (std.fmt.bufPrint(&r.buf, fmt, args)) |s| s.len else |_| 0;
        a.state = .{ .failed = r };
        a.dirty = false;
        a.hooks.changed(a.hooks.ctx);
    }

    /// "Sync: host, last synced 3 min ago", "Sync: error ...", or `off_text`.
    pub fn status(a: *const Account, buf: []u8) []const u8 {
        const host = hostOf(a.cfg.url);
        return switch (a.state) {
            .off => off_text,
            .pending => std.fmt.bufPrint(buf, "Sync: {s}, syncing…", .{host}) catch off_text,
            .synced => |at| blk: {
                var ago_buf: [32]u8 = undefined;
                const when = ago(&ago_buf, now() - at);
                const line = std.fmt.bufPrint(buf, "Sync: {s}, last synced {s}", .{ host, when });
                break :blk line catch off_text;
            },
            .failed => |*r| std.fmt.bufPrint(buf, "Sync: error {s}", .{r.text()}) catch "Sync: error",
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

    /// Sends this machine's record; with one out already, sent again once
    /// that one succeeds.
    fn sync(a: *Account) void {
        const token = a.token orelse return;
        if (a.inflight != null) {
            a.dirty = true;
            return;
        }
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
        const first = a.firstHere();
        a.inflight = .{ .first = first, .sent_at = sent.at };
        a.send(a, .{
            .url = url,
            .method = "PUT",
            .headers = headers[0..if (first) 3 else 2],
            .body = body,
            .timeout = 15,
        });
    }

    fn answered(a: *Account, r: nanoui.http.Response) void {
        const out = a.inflight.?;
        a.inflight = null;
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
        const first = out.first and now_here.at == out.sent_at;
        const merged = settings.merge(al, now_here, theirs, first) catch return a.fail("out of memory");
        a.hooks.apply(a.hooks.ctx, merged);
        // best effort: unkept, the next sync is sent as a first one again.
        a.kv.set(synced_key, a.cfg.url) catch {};
        a.state = .{ .synced = now() };
        a.hooks.changed(a.hooks.ctx);
        if (!settings.same(merged, theirs)) a.changed();
        if (a.dirty) {
            a.dirty = false;
            a.sync();
        }
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
    var reason: Reason = .{};
    const why = "the server rejected the token";
    reason.len = (std.fmt.bufPrint(&reason.buf, why, .{}) catch unreachable).len;
    bad.state = .{ .failed = reason };
    const said = "Sync: error the server rejected the token";
    try std.testing.expectEqualStrings(said, bad.status(&line));
    var good = bad;
    good.state = .{ .synced = now() - 400 };
    try std.testing.expectEqualStrings("Sync: h:1, last synced 6 min ago", good.status(&line));
}

/// An account whose requests are only counted: tests answer them.
const TestSync = struct {
    mem: nanoui.kv.Memory = .{ .gpa = std.testing.allocator },
    acc: Account = undefined,
    sends: u32 = 0,
    statuses: u32 = 0,
    here: Settings = .{ .hotkey = "cmd_space", .suggest = true, .at = 100 },

    fn init(t: *TestSync) void {
        t.acc = .{
            .gpa = std.testing.allocator,
            .io = std.testing.io,
            .kv = t.mem.store(),
            .hooks = .{ .ctx = t, .snapshot = snapshot, .apply = apply, .changed = changed },
            .cfg = .{ .url = "http://h:1" },
            .token = @constCast("t"),
            .state = .pending,
            .send = send,
        };
    }
    fn of(ctx: *anyopaque) *TestSync {
        return @ptrCast(@alignCast(ctx));
    }
    fn snapshot(ctx: *anyopaque, _: std.mem.Allocator) Settings {
        return of(ctx).here;
    }
    fn apply(_: *anyopaque, _: Settings) void {}
    fn changed(ctx: *anyopaque) void {
        of(ctx).statuses += 1;
    }
    fn send(a: *Account, _: nanoui.http.Request) void {
        const t: *TestSync = @fieldParentPtr("acc", a);
        t.sends += 1;
    }
    /// The server agreeing with this machine.
    fn agree(t: *TestSync) !void {
        const body = try settings.encode(std.testing.allocator, t.here);
        defer std.testing.allocator.free(body);
        t.acc.answered(.{ .status = 200, .body = body });
    }
};

test "a failed sync says why and is not retried, even if asked again meanwhile" {
    var t: TestSync = .{};
    defer t.mem.deinit();
    t.init();
    t.acc.sync();
    try std.testing.expectEqual(@as(u32, 1), t.sends);
    // Asked again while it is out: not sent now.
    t.acc.sync();
    try std.testing.expectEqual(@as(u32, 1), t.sends);
    try std.testing.expect(t.acc.dirty);
    t.acc.answered(.{ .status = 500, .body = "" });
    try std.testing.expectEqual(@as(u32, 1), t.sends);
    try std.testing.expect(t.acc.inflight == null and !t.acc.dirty);
    var line: [160]u8 = undefined;
    try std.testing.expectEqualStrings("Sync: error the server answered 500", t.acc.status(&line));
}

test "a change made while a sync is out is sent once that one succeeds" {
    var t: TestSync = .{};
    defer t.mem.deinit();
    t.init();
    t.acc.sync();
    t.here.suggest = false;
    t.here.at = 200;
    t.acc.sync();
    try std.testing.expectEqual(@as(u32, 1), t.sends);
    try t.agree();
    try std.testing.expect(t.acc.state == .synced);
    // Sent again, once.
    try std.testing.expectEqual(@as(u32, 2), t.sends);
    try std.testing.expect(t.acc.inflight != null and !t.acc.dirty);
    try t.agree();
    try std.testing.expectEqual(@as(u32, 2), t.sends);
    try std.testing.expect(t.acc.inflight == null);
}

test "a trailing slash does not make a server a new one" {
    try std.testing.expect(sameServer("http://100.64.0.3:8890", "http://100.64.0.3:8890/"));
    try std.testing.expect(!sameServer("http://100.64.0.3:8890", "http://sync.host:8890"));
}
