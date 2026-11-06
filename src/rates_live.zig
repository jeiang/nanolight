//! The running app's side of currency rates (convert.zig's `Feed`): the
//! table cached on disk, read once; a fetch when none is in hand or it is a
//! day old; the panel told when it lands.
const std = @import("std");
const nanoui = @import("nanoui");
const convert = @import("convert.zig");
const prefs = @import("prefs.zig");
const account = @import("account.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

pub const Rates = struct {
    core: *App,
    feed: convert.Feed = .{},

    pub fn deinit(r: *Rates) void {
        r.feed.deinit();
    }

    /// What the panel asks for rates with.
    pub fn entry(r: *Rates) view.Host.Call {
        return .{ .ctx = r, .func = need };
    }

    /// A conversion is listed: the cached table on the first call, then a
    /// fetch when none is in hand or it is a day old (`convert.Feed.due`).
    fn need(ctx: *anyopaque) void {
        const r: *Rates = @ptrCast(@alignCast(ctx));
        if (!r.feed.cache_read) {
            r.readCached();
            if (r.feed.table() != null) r.core.s.ratesLanded();
        }
        const now_s = account.now();
        if (!r.feed.due(now_s)) return;
        r.feed.begin(now_s);
        r.fetch(0);
    }

    fn path(r: *Rates) ?[]u8 {
        const gpa = r.core.app.gpa;
        const data = prefs.dataDir(gpa) catch return null;
        defer gpa.free(data);
        // best effort: without the folder no rates are read, and the write says why.
        std.Io.Dir.cwd().createDirPath(r.core.app.io, data) catch {};
        return std.fs.path.join(gpa, &.{ data, "rates.json" }) catch null;
    }

    /// The table and its day as the last fetch left them, if any.
    fn readCached(r: *Rates) void {
        const gpa = r.core.app.gpa;
        const fetched_s = prefs.int(r.core.kv, gpa, .rates_at);
        var table: ?convert.Rates = null;
        if (r.path()) |file| {
            defer gpa.free(file);
            const limit: std.Io.Limit = .limited(convert.max_bytes);
            const read = std.Io.Dir.cwd().readFileAlloc(r.core.app.io, file, gpa, limit);
            if (read catch null) |body| {
                defer gpa.free(body);
                table = convert.Rates.parse(gpa, body);
            }
        }
        r.feed.cached(table, fetched_s);
    }

    fn fetch(r: *Rates, which: usize) void {
        const gpa = r.core.app.gpa;
        const a = gpa.create(Fetch) catch return r.feed.fail();
        a.* = .{ .rates = r, .which = which };
        nanoui.http.fetch(gpa, .{
            .url = convert.urls[which],
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 10,
        }, a, Fetch.done);
    }
};

/// A fetch of the rates on its way: which of `convert.urls` it asked.
const Fetch = struct {
    rates: *Rates,
    which: usize,

    fn done(a: *Fetch, r: nanoui.http.Response) void {
        const rates = a.rates;
        const core = rates.core;
        const gpa = core.app.gpa;
        defer gpa.destroy(a);
        const table = if (r.status == 200) convert.Rates.parse(gpa, r.body) else null;
        if (table) |t| {
            rates.feed.landed(t, account.now());
            // A failure is logged; the next launch then fetches again.
            _ = prefs.setInt(core.kv, .rates_at, rates.feed.fetched_s);
            if (rates.path()) |file| {
                defer gpa.free(file);
                std.Io.Dir.cwd()
                    .writeFile(core.app.io, .{ .sub_path = file, .data = r.body }) catch |err|
                    std.log.warn("nanolight: the rates weren't kept in {s}: {t}", .{ file, err });
            }
        } else if (a.which + 1 < convert.urls.len) {
            return rates.fetch(a.which + 1);
        } else {
            rates.feed.fail();
        }
        core.s.ratesLanded();
        core.redraw();
    }
};
