//! Currency rates fetched and kept: `Feed`, which says when to fetch the
//! table (rates_table.zig), and the running app's side (`Live`): the table
//! kept on disk with its day, read the first time a conversion asks,
//! fetched when none is in hand or it is a day old, the panel told when it
//! lands.
const std = @import("std");
const nanoui = @import("nanoui");
const prefs = @import("prefs.zig");
const rates_table = @import("rates_table.zig");
const Rates = rates_table.Rates;
const Status = rates_table.Status;
const assert = std.debug.assert;

pub const urls = [_][]const u8{
    "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.min.json",
    "https://latest.currency-api.pages.dev/v1/currencies/usd.min.json",
};
/// Rates are fetched at most this often (seconds) once they are in hand.
pub const max_age = 24 * 3600;
/// A failed fetch is tried again after this long (seconds).
pub const retry_after = 600;
/// Seconds without a byte before a fetch gives up.
const timeout = 10;

/// The rates in hand and their fetching: when they were fetched and when a
/// fetch last began (Unix seconds, 0 for never), and whether one is out.
pub const Feed = struct {
    rates: ?Rates = null,
    fetched_s: i64 = 0,
    tried_s: i64 = 0,
    state: State = .idle,
    /// The cached table was looked for (`cached`), once.
    cache_read: bool = false,

    pub const State = enum { idle, busy, missed };

    pub fn deinit(f: *Feed) void {
        if (f.rates) |*r| r.deinit();
        f.rates = null;
    }

    pub fn table(f: *const Feed) ?*const Rates {
        return if (f.rates) |*r| r else null;
    }

    /// Rates could not be had: the last fetch failed and none are in hand.
    /// A retry on its way is not a failure.
    pub fn failed(f: *const Feed) bool {
        return f.state == .missed and f.rates == null;
    }

    /// Whether a fetch should begin now: none is out, and the rates are
    /// missing or a day old; after a failure, not for `retry_after`.
    pub fn due(f: *const Feed, now_s: i64) bool {
        if (f.state == .busy) return false;
        if (f.tried_s != 0 and now_s - f.tried_s < retry_after) return false;
        return f.rates == null or now_s - f.fetched_s >= max_age;
    }

    /// What the cache held: the table, if any, and when it was fetched.
    pub fn cached(f: *Feed, r: ?Rates, fetched_s: i64) void {
        assert(!f.cache_read);
        assert(f.state == .idle);
        f.cache_read = true;
        f.fetched_s = fetched_s;
        if (r) |t| f.use(t);
    }

    pub fn begin(f: *Feed, now_s: i64) void {
        assert(f.state != .busy);
        f.state = .busy;
        f.tried_s = now_s;
    }

    /// The fetch brought `r`, now the table in use.
    pub fn landed(f: *Feed, r: Rates, now_s: i64) void {
        assert(f.state == .busy);
        f.use(r);
        f.fetched_s = now_s;
        f.state = .idle;
    }

    /// The fetch brought nothing, from any address.
    pub fn fail(f: *Feed) void {
        assert(f.state == .busy);
        f.state = .missed;
    }

    fn use(f: *Feed, r: Rates) void {
        f.deinit();
        f.rates = r;
    }
};

/// The rates the panel converts with, and their reading, keeping and fetching.
pub const Live = struct {
    feed: Feed = .{},
    /// What they are read, kept and fetched with: without it (tests) none are.
    env: ?Env = null,

    pub const Env = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        /// Keeps the day the table was fetched (`prefs.Key.rates_at`).
        kv: nanoui.kv.Store,
        /// Unix seconds.
        now: *const fn () i64,
        /// A fetch landed or failed: the panel redoes its conversion.
        landed: Call,
    };

    pub const Call = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) void,
    };

    pub fn deinit(l: *Live) void {
        l.feed.deinit();
    }

    pub fn status(l: *const Live) Status {
        return .{ .table = l.feed.table(), .failed = l.feed.failed() };
    }

    /// A conversion is listed: the cached table on the first call, then a
    /// fetch when none is in hand or it is a day old (`Feed.due`). True when
    /// the cache brought a table, to build with now.
    fn need(l: *Live) bool {
        const env = l.env orelse return false;
        var read = false;
        if (!l.feed.cache_read) {
            l.readCached(env);
            read = l.feed.table() != null;
        }
        const now_s = env.now();
        if (l.feed.due(now_s)) {
            l.feed.begin(now_s);
            l.fetch(env, 0);
        }
        return read;
    }

    fn path(env: Env) ?[]u8 {
        const data = prefs.dataDir(env.gpa) catch return null;
        defer env.gpa.free(data);
        // best effort: without the folder no rates are read, and the write says why.
        std.Io.Dir.cwd().createDirPath(env.io, data) catch {};
        return std.fs.path.join(env.gpa, &.{ data, "rates.json" }) catch null;
    }

    /// The table and its day as the last fetch left them, if any.
    fn readCached(l: *Live, env: Env) void {
        const fetched_s = prefs.int(env.kv, env.gpa, .rates_at);
        var table: ?Rates = null;
        if (path(env)) |file| {
            defer env.gpa.free(file);
            const limit: std.Io.Limit = .limited(rates_table.max_bytes);
            const read = std.Io.Dir.cwd().readFileAlloc(env.io, file, env.gpa, limit);
            if (read catch null) |body| {
                defer env.gpa.free(body);
                table = Rates.parse(env.gpa, body);
            }
        }
        l.feed.cached(table, fetched_s);
    }

    fn fetch(l: *Live, env: Env, which: usize) void {
        const a = env.gpa.create(Fetch) catch return l.feed.fail();
        a.* = .{ .live = l, .which = which };
        nanoui.http.fetch(env.gpa, .{
            .url = urls[which],
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = timeout,
        }, a, Fetch.done);
    }
};

/// Builds rows with the rates in hand: `build(ctx, status)` says whether
/// they list a currency conversion, which asks for the rates
/// (`Live.need`); when that read them from the cache, the rows are built
/// again with them.
pub fn fill(live: ?*Live, ctx: anytype, comptime build: fn (@TypeOf(ctx), Status) bool) void {
    const l = live orelse {
        _ = build(ctx, .{});
        return;
    };
    if (build(ctx, l.status()) and l.need()) _ = build(ctx, l.status());
}

/// A fetch of the rates on its way: which of `urls` it asked.
const Fetch = struct {
    live: *Live,
    which: usize,

    fn done(a: *Fetch, r: nanoui.http.Response) void {
        const live = a.live;
        const env = live.env.?;
        defer env.gpa.destroy(a);
        const table = if (r.status == 200) Rates.parse(env.gpa, r.body) else null;
        if (table) |t| {
            live.feed.landed(t, env.now());
            // A failure is logged; the next launch then fetches again.
            _ = prefs.setInt(env.kv, .rates_at, live.feed.fetched_s);
            if (Live.path(env)) |file| {
                defer env.gpa.free(file);
                std.Io.Dir.cwd()
                    .writeFile(env.io, .{ .sub_path = file, .data = r.body }) catch |err|
                    std.log.warn("nanolight: the rates weren't kept in {s}: {t}", .{ file, err });
            }
        } else if (a.which + 1 < urls.len) {
            return live.fetch(env, a.which + 1);
        } else {
            live.feed.fail();
        }
        env.landed.func(env.landed.ctx);
    }
};

const testing = std.testing;

const sample =
    \\{"date":"2026-11-03","usd":{"1inch":1.2,"usd":1,"ttd":6.785,"eur":0.86,"gbp":0.75,"jpy":150.0,
++
    \\"zzz":0,"bad":"x"}}
;

test "rates are fetched when missing or a day old, one at a time, not in a loop" {
    var f: Feed = .{};
    defer f.deinit();
    try testing.expect(f.due(1000));
    f.begin(1000);
    // One out: no second, and no failure yet.
    try testing.expect(!f.due(1000 + retry_after));
    try testing.expect(!f.failed());
    f.fail();
    try testing.expect(f.failed());
    try testing.expect(!f.due(1000 + retry_after - 1));
    try testing.expect(f.due(1000 + retry_after));
    // A retry on its way is not a failure.
    const t0 = 1000 + retry_after;
    f.begin(t0);
    try testing.expect(!f.failed());
    f.landed(Rates.parse(testing.allocator, sample).?, t0);
    try testing.expect(!f.failed());
    try testing.expect(f.table() != null);
    try testing.expect(!f.due(t0 + max_age - 1));
    try testing.expect(f.due(t0 + max_age));
    // Stale and the refresh failed: the old table still answers, and the
    // next try waits.
    f.begin(t0 + max_age);
    f.fail();
    try testing.expect(!f.failed());
    try testing.expect(f.table() != null);
    try testing.expect(!f.due(t0 + max_age + 1));
}

test "the cache's table and day count as fetched" {
    var f: Feed = .{};
    defer f.deinit();
    f.cached(Rates.parse(testing.allocator, sample).?, 5000);
    try testing.expect(f.cache_read);
    try testing.expect(!f.due(5000 + max_age - 1));
    try testing.expect(f.due(5000 + max_age));
    var none: Feed = .{};
    none.cached(null, 0);
    try testing.expect(none.due(1));
    try testing.expect(!none.failed());
}

test "rows are built once with the rates in hand, none read without an env" {
    const Rows = struct {
        builds: usize = 0,
        seen: Status = .{},
        fn build(r: *@This(), st: Status) bool {
            r.builds += 1;
            r.seen = st;
            return true;
        }
    };
    var rows: Rows = .{};
    fill(null, &rows, Rows.build);
    try testing.expectEqual(@as(usize, 1), rows.builds);
    var live: Live = .{};
    defer live.deinit();
    live.feed.begin(1);
    live.feed.fail();
    fill(&live, &rows, Rows.build);
    try testing.expectEqual(@as(usize, 2), rows.builds);
    try testing.expect(rows.seen.failed and rows.seen.table == null);
    try testing.expect(!live.feed.cache_read);
}
