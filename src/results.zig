//! What the panel lists for a query, in order: the answer when it is math,
//! local results ranked together by match (apps, files and folders, panes,
//! commands; or apps suggested with no query),
//! then the quicklinks (settings.zig, `[[quicklinks]]`): the first is a search for
//! exactly what is typed, and Google's completions of it go under the
//! quicklink whose address is Google's, a key or two away. `<keyword> words`
//! runs only that quicklink. With no app or answer, Return searches what
//! was typed (as an address bar's does). Completions land a moment after the rest;
//! the panel keeps the selection on the row it was on (`Nanolight.answered`).
const std = @import("std");
const search = @import("search.zig");
const files = @import("files.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const panes = @import("settings_panes.zig");
const commands = @import("commands.zig");
const mac = @import("builtin").os.tag == .macos;
const apps = @import("apps.zig");
const Index = apps.Index;
pub const Quicklink = @import("settings.zig").Quicklink;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on.
pub const machine = if (mac) "Mac" else "PC";

pub const Kind = enum {
    calc,
    app,
    /// A file or folder found (`Row.file` its place in `Results.found`).
    file,
    /// A quicklink (`Row.ql`).
    quicklink,
    /// One of Google's completions (`Row.web`).
    suggest,
    /// Nanolight's own Settings, listed when the query asks for them.
    settings,
    /// A pane of System Settings (`Row.app` its place in settings_panes.zig).
    pane,
    /// A system command (`Row.app` its place in commands.zig).
    command,
    /// Clipboard History, listed when the query asks for it.
    clipboard,

    /// The row's kind as its trailing label shows it.
    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app => "Application",
            .file => "File",
            .settings => "Nanolight",
            .pane => "System Settings",
            .command => "Command",
            .clipboard => "Nanolight",
            .quicklink, .suggest => "Web",
        };
    }

    /// What Return does to it.
    pub fn action(k: Kind) []const u8 {
        return switch (k) {
            .calc => "Copy Answer",
            .app => "Open Application",
            .file => "Open",
            .settings => "Open Settings",
            .pane => "Open in System Settings",
            .command => "Run Command",
            .clipboard => "Open Clipboard History",
            .quicklink => "Search",
            .suggest => "Search Google",
        };
    }

    fn section(k: Kind, suggested: bool) []const u8 {
        return switch (k) {
            .calc => "Calculator",
            .app, .file, .settings, .pane, .command, .clipboard => if (suggested)
                "Suggestions"
            else
                "Results",
            .quicklink, .suggest => unreachable,
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    /// Which of the files found (`.file`).
    file: u8 = 0,
    /// Which of the completions (`.suggest`).
    web: u8 = 0,
    /// Which quicklink (`.quicklink`).
    ql: u16 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// Per-kind caps within the shared, match-ranked local results.
pub const max_panes = 3;
pub const max_commands = 3;
/// Google's completions fill what room is left, up to four.
pub const max_web = 4;
/// The quicklinks listed under the apps; later ones answer to their keyword.
pub const max_quicklink_rows = 5;
/// Every app and the quicklink rows leave room for three completions.
pub const max_rows = max_apps + max_quicklink_rows + 3;
comptime {
    // The panel's tallest list is sized for this many (chrome.max_height).
    std.debug.assert(max_rows == @import("chrome.zig").max_rows);
}
/// Every local candidate, and a card, fit before ranking keeps the best of
/// them and trims the list to `max_rows`.
const max_candidates = 1 + max_apps + files.max_rows + max_panes + max_commands;
comptime {
    // The Settings and Clipboard History rows, two at most, are listed only
    // in place of the panes and commands.
    std.debug.assert(max_panes + max_commands >= 2);
}

/// The quicklink a query addresses by keyword, and where its words start.
pub const Keyed = struct { ql: u16, arg: usize };

/// `<keyword> words`, the keyword any case; `query` is trimmed.
pub fn keyed(ql: []const Quicklink, query: []const u8) ?Keyed {
    for (ql[0..@min(ql.len, std.math.maxInt(u16))], 0..) |q, i| {
        const k = q.keyword;
        if (k.len == 0 or query.len <= k.len or query[k.len] != ' ' or
            !std.ascii.eqlIgnoreCase(query[0..k.len], k)) continue;
        const rest = std.mem.trimStart(u8, query[k.len..], " ");
        return .{ .ql = @intCast(i), .arg = query.len - rest.len };
    }
    return null;
}

/// The host of an address: "www.google.com" of "https://www.google.com/search?q=".
pub fn host(address: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    return rest[0..end];
}

fn isGoogle(address: []const u8) bool {
    const h = host(address);
    return std.ascii.eqlIgnoreCase(h, "google.com") or (h.len > 11 and
        std.ascii.eqlIgnoreCase(h[h.len - 11 ..], ".google.com"));
}

/// The listed quicklink whose address is Google's: the one its completions go with.
pub fn google(ql: []const Quicklink) ?u16 {
    for (ql[0..@min(
        ql.len,
        max_quicklink_rows,
    )], 0..) |q, i| if (isGoogle(q.url)) return @intCast(i);
    return null;
}

pub const Results = struct {
    rows: [@max(max_rows, max_candidates)]Row = undefined,
    n: usize = 0,
    /// No query: the apps are suggestions, nothing else is listed.
    suggested: bool = false,
    /// The math's answer, as shown.
    answer_buf: [64]u8 = undefined,
    answer: []const u8 = "",
    /// A whole answer in hexadecimal too ("0xC00"), else empty.
    hex_buf: [24]u8 = undefined,
    hex: []const u8 = "",
    /// A conversion: what Return copies, the expression as the card shows
    /// it, and the line under the answer (the rate and its day).
    copy_buf: [64]u8 = undefined,
    copy: []const u8 = "",
    expr_buf: [64]u8 = undefined,
    expr: []const u8 = "",
    note_buf: [96]u8 = undefined,
    note: []const u8 = "",
    /// Currency rates, when in hand, and whether fetching them failed.
    rates: ?*const convert.Rates = null,
    rates_failed: bool = false,
    /// The query is a currency conversion: rates are needed (or may be stale).
    need_rates: bool = false,
    /// Row 0 is a currency card still waiting for rates: nothing to copy yet.
    pending: bool = false,
    /// The quicklink holding Google's completions, when listed.
    google: ?u16 = null,
    /// The query went to one quicklink by its keyword.
    keyed: ?Keyed = null,
    /// Clipboard History can be opened (the host has it): it is listed for "clip".
    clip_on: bool = false,
    /// The files and folders file search found for the query (files.zig),
    /// if it is on: local rows like the rest.
    found: ?*const files.List = null,

    /// What a quicklink row searches for: the words, past any keyword.
    pub fn argument(r: *const Results, query: []const u8) []const u8 {
        const q = std.mem.trim(u8, query, " ");
        return if (r.keyed) |k| q[@min(k.arg, q.len)..] else q;
    }

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    /// Lists what `query` finds among the apps of `ix` (lifted by how often
    /// each was opened) and in `found`, the quicklinks `ql`, and Google's
    /// completions of it (`web`), or `suggestions` when the query is empty.
    pub fn build(
        r: *Results,
        query_in: []const u8,
        ix: *const Index,
        suggestions: []const u32,
        web: []const []const u8,
        ql: []const Quicklink,
    ) void {
        r.clear();
        const query = std.mem.trim(u8, query_in, " ");
        r.suggested = query.len == 0;
        if (query.len == 0) {
            for (suggestions[0..@min(suggestions.len, max_apps)]) |i| r.push(
                .{ .kind = .app, .app = i },
            );
            return;
        }
        // "2 + 3 *" or "500 usd to eur *": the answer so far, so the card
        // stays while the next number is typed.
        const math = std.mem.trimEnd(u8, query, " +-*/%^×÷");
        if (calc.eval(math)) |v| {
            r.calcRow(v, math, query.len);
        } else if (convert.answer(math, r.rates)) |a| {
            r.pending = a == .pending;
            r.convertRow(a);
            r.push(.{ .kind = .calc });
        }
        const local_start = r.n;
        var ranked: [max_apps]search.Ranked = undefined;
        const n = apps.rankApps(query, ix, &ranked);
        for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        if (isSettings(query)) r.push(.{
            .kind = .settings,
            .match = search.score(query, "Settings") orelse .{ .score = 0 },
        });
        const clip = r.clip_on and isClipboard(query);
        if (clip) r.push(
            .{ .kind = .clipboard, .match = search.score(query, "Clipboard History").? },
        );
        if (local_start > 0 and !r.pending) {
            r.rankLocal(local_start, query);
            return;
        }
        var pane_rows: [max_panes]search.Ranked = undefined;
        const np = if (isSettings(query) or clip) 0 else panes.rank(query, &pane_rows);
        for (pane_rows[0..np]) |x| r.push(.{ .kind = .pane, .app = x.index, .match = x.match });
        const key = keyed(ql, query);
        const shown = @min(ql.len, max_quicklink_rows);
        var cmd_rows: [max_commands]search.Ranked = undefined;
        const nc = if (key != null or isSettings(query) or
            clip) 0 else commands.rank(query, &cmd_rows);
        for (cmd_rows[0..nc]) |x| r.push(.{ .kind = .command, .app = x.index, .match = x.match });
        // Files and folders compete by their names' match (equal scores
        // after the rest); a path typed out that exists leads (files.zig).
        if (r.found) |found| for (found.entries[0..found.n], 0..) |e, i| r.push(
            .{ .kind = .file, .file = @intCast(i), .match = e.match },
        );
        r.rankLocal(local_start, query);
        // Reserve the quicklinks and one completion before filling local rows.
        // A pending card's extra height and header cost two ordinary rows.
        const row_limit = max_rows - @as(usize, if (r.pending) 2 else 0);
        r.n = @min(r.n, row_limit -| shown -| 1);
        // A keyword sends the rest of the query to its quicklink alone.
        if (key) |k| {
            r.keyed = k;
            r.push(.{ .kind = .quicklink, .ql = k.ql });
            return;
        }
        // The quicklinks, the first a search for what was typed, Google's
        // completions (as many as leave room for the rest) under Google's.
        const room = row_limit -| r.n -| shown;
        r.google = google(ql);
        for (0..shown) |i| {
            r.push(.{ .kind = .quicklink, .ql = @intCast(i) });
            if (r.google == @as(u16, @intCast(i))) for (0..@min(web.len, max_web, room)) |j| r.push(
                .{ .kind = .suggest, .web = @intCast(j) },
            );
        }
    }

    /// Nothing listed, and nothing left from the last query's cards.
    fn clear(r: *Results) void {
        r.n = 0;
        r.google = null;
        r.keyed = null;
        r.copy = "";
        r.expr = "";
        r.note = "";
        r.need_rates = false;
        r.pending = false;
    }

    /// The math's card for `v`: shown, copied, in hexadecimal when whole,
    /// and, when `math` is the start of a longer query, the expression so far.
    fn calcRow(r: *Results, v: f64, math: []const u8, query_len: usize) void {
        r.answer = calc.format(&r.answer_buf, v, true);
        r.copy = calc.format(&r.copy_buf, v, false);
        if (math.len < query_len and math.len <= r.expr_buf.len) {
            @memcpy(r.expr_buf[0..math.len], math);
            r.expr = r.expr_buf[0..math.len];
        }
        r.hex = if (v >= 0 and v < 1e15 and v == @round(v))
            std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{@as(u64, @intFromFloat(v))}) catch ""
        else
            "";
        r.push(.{ .kind = .calc });
    }

    /// The row Return acts on when `sel` is chosen: a pending card has no
    /// action of its own, so the row under it stands in.
    pub fn actionable(r: *const Results, sel: usize) usize {
        if (r.pending and sel == 0 and r.n > 1) return 1;
        return @min(sel, r.n -| 1);
    }

    fn convertRow(r: *Results, a: convert.Answer) void {
        r.hex = "";
        var nb: [32]u8 = undefined;
        switch (a) {
            .unit => |u| {
                r.answer = convert.formatUnit(&r.answer_buf, u, true);
                r.copy = convert.formatUnitValue(&r.copy_buf, u.value, false);
                r.expr = std.fmt.bufPrint(
                    &r.expr_buf,
                    "{s} {s}",
                    .{ calc.format(&nb, u.amount, true), u.from },
                ) catch "";
            },
            .money => |m| {
                r.need_rates = true;
                r.answer = std.fmt.bufPrint(
                    &r.answer_buf,
                    "{s} {s}",
                    .{ convert.formatMoney(&nb, m.value, true), m.to },
                ) catch "";
                r.copy = convert.formatMoney(&r.copy_buf, m.value, false);
                r.expr = std.fmt.bufPrint(
                    &r.expr_buf,
                    "{s} {s}",
                    .{ calc.format(&nb, m.amount, true), m.from },
                ) catch "";
                r.note = convert.rateLine(&r.note_buf, m);
            },
            .pending => {
                r.need_rates = true;
                r.answer = if (r.rates_failed) "Rates unavailable" else "Loading rates…";
            },
        }
    }

    /// "clip", or a name's worth of "Clipboard History" (not a stray letter or two).
    fn isClipboard(query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(query, "clip")) return true;
        const m = search.score(query, "Clipboard History") orelse return false;
        return query.len >= 3 and m.score >= search.min_loose;
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(query, "settings") or
            std.ascii.eqlIgnoreCase(query, "preferences")) return true;
        const keys = [_][]const u8{ "设置", "偏好设置", "系统设置", "nanolight 设置" };
        const q = std.mem.trim(u8, query, " ");
        for (keys) |k| if (std.mem.eql(u8, q, k)) return true;
        return false;
    }

    fn rankLocal(r: *Results, start: usize, query: []const u8) void {
        const Order = struct {
            fn before(preferred: ?Kind, a: Row, b: Row) bool {
                if (preferred) |kind| {
                    if ((a.kind == kind) != (b.kind == kind)) return a.kind == kind;
                }
                return a.match.score > b.match.score;
            }
        };
        // These explicit shortcuts keep their own row first, even when an
        // app's launch-count boost would otherwise put it ahead.
        const preferred: ?Kind = if (std.ascii.eqlIgnoreCase(query, "settings"))
            .settings
        else if (r.clip_on and std.ascii.eqlIgnoreCase(query, "clip"))
            .clipboard
        else
            null;
        std.sort.insertion(Row, r.rows[start..r.n], preferred, Order.before);
    }

    /// Local candidates may pass `max_rows` until `build` trims them, but
    /// never `max_candidates`.
    fn push(r: *Results, row: Row) void {
        std.debug.assert(r.n < r.rows.len);
        r.rows[r.n] = row;
        r.n += 1;
    }

    /// The header above row `i`, if a section starts there.
    pub fn section(r: *const Results, i: usize) ?[]const u8 {
        const name = r.sectionName(i);
        if (i > 0 and std.mem.eql(u8, r.sectionName(i - 1), name)) return null;
        return name;
    }

    /// A completion sits in its quicklink's section.
    fn sectionName(r: *const Results, i: usize) []const u8 {
        var j = i;
        while (j > 0 and r.rows[j].kind == .suggest) j -= 1;
        const row = r.rows[j];
        if (row.kind == .quicklink) return if (row.ql == 0) "Search" else "Quicklinks";
        return row.kind.section(r.suggested);
    }
};

/// The address `template` opens for `argument`: each `{argument}` is
/// replaced by it, escaped; a template without one opens as it is.
pub fn url(buf: []u8, template: []const u8, argument: []const u8) []const u8 {
    const mark = "{argument}";
    var w: std.Io.Writer = .fixed(buf);
    var rest = template;
    while (std.mem.indexOf(u8, rest, mark)) |i| {
        w.writeAll(rest[0..i]) catch return "";
        // best effort: the address is cut where `buf` is full.
        search.percentEncode(&w, std.mem.trim(u8, argument, " "), .{}) catch {};
        rest = rest[i + mark.len ..];
    }
    w.writeAll(rest) catch return "";
    return w.buffered();
}

fn testIndex(a: std.mem.Allocator, names: []const []const u8) !Index {
    var ix: Index = .init(a);
    for (names) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    return ix;
}

const defaults = &@import("settings.zig").default_quicklinks;

test "math first, then apps; quicklinks only without an answer" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build("saf", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].app);
    try t.expectEqual(Kind.quicklink, r.rows[1].kind);
    try t.expectEqual(@as(u16, 0), r.rows[1].ql);
    try t.expectEqual(@as(usize, 6), r.n);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqualStrings("Search", r.section(1).?);
    try t.expectEqualStrings("Quicklinks", r.section(2).?);
    try t.expect(r.section(3) == null);
    r.build("2^10 * 3", &ix, &.{}, &.{"ignored"}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build("", &ix, &.{ 2, 0 }, &.{}, defaults);
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build("liquid glass", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(@as(usize, 5), r.n);
    // No app: the search for what was typed comes first.
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqualStrings("Search", r.section(0).?);
    try t.expectEqualStrings("Quicklinks", r.section(1).?);
    // Completions under Google, in its section, then the other quicklinks.
    r.build("liquid gl", &ix, &.{}, &.{ "liquid glass", "liquid glue" }, defaults);
    try t.expectEqual(@as(usize, 7), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqual(Kind.suggest, r.rows[1].kind);
    try t.expectEqual(@as(u8, 1), r.rows[2].web);
    try t.expectEqual(@as(u16, 1), r.rows[3].ql);
    try t.expect(r.section(1) == null and r.section(2) == null);
    try t.expectEqualStrings("Quicklinks", r.section(3).?);
    // The explicit Settings shortcut stays first, ahead of System Settings.
    r.build("settings", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.settings, r.rows[0].kind);
    try t.expectEqual(Kind.app, r.rows[1].kind);
    try t.expectEqual(@as(u32, 1), r.rows[1].app);
    // A full list of apps still ends with every quicklink.
    var many_ix = try testIndex(
        t.allocator,
        &.{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" },
    );
    defer many_ix.deinit();
    r.build("a", &many_ix, &.{}, &.{ "a1", "a2", "a3", "a4" }, defaults);
    try t.expectEqual(max_rows, r.n);
    try t.expectEqual(Kind.quicklink, r.rows[max_apps].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 1].kind);
    try t.expectEqual(Kind.quicklink, r.rows[max_rows - 1].kind);
    try t.expectEqual(@as(u16, 4), r.rows[max_rows - 1].ql);
}

test "a keyword sends the rest of the query to that quicklink alone" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    r.build("DDG  zig lang", &ix, &.{}, &.{"ignored"}, defaults);
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqual(@as(u16, 1), r.rows[0].ql);
    try t.expectEqualStrings("zig lang", r.argument(" DDG  zig lang "));
    // The keyword alone, or a longer word, is an ordinary query.
    r.build("ddg", &ix, &.{}, &.{}, defaults);
    try t.expect(r.keyed == null and r.n == 5);
    r.build("ddgs zig", &ix, &.{}, &.{}, defaults);
    try t.expect(r.keyed == null);
    try t.expectEqualStrings("ddgs zig", r.argument("ddgs zig"));
}

test "Google's completions go with the quicklink that is Google, wherever it is" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{});
    defer ix.deinit();
    var r: Results = .{};
    const ql: []const Quicklink = &.{
        .{ .name = "Duck", .url = "https://duckduckgo.com/?q={argument}" },
        .{ .name = "G", .url = "https://www.google.co.uk.example.com/?q={argument}" },
        .{ .name = "Web", .url = "https://WWW.Google.com/search?q={argument}" },
    };
    r.build("pizza", &ix, &.{}, &.{ "pizza near me", "pizza hut" }, ql);
    try t.expectEqual(@as(?u16, 2), r.google);
    try t.expectEqual(Kind.suggest, r.rows[3].kind);
    try t.expectEqual(@as(usize, 5), r.n);
    try t.expectEqualStrings("Quicklinks", r.section(3) orelse "Quicklinks");
    // Without Google, none are listed.
    r.build("pizza", &ix, &.{}, &.{"pizza near me"}, ql[0..2]);
    try t.expect(r.google == null);
    try t.expectEqual(@as(usize, 2), r.n);
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://x.com/search?f=live&q=liquid%20glass%20%26%20UI",
        url(&buf, "https://x.com/search?f=live&q={argument}", " liquid glass & UI "),
    );
    try std.testing.expectEqualStrings(
        "https://claude.ai/new?q=what%20is%20zig%3F",
        url(&buf, "https://claude.ai/new?q={argument}", "what is zig?"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/hello%20world",
        url(&buf, "https://example.com/{argument}", "hello world"),
    );
    try std.testing.expectEqualStrings(
        "https://a/zig/zig",
        url(&buf, "https://a/{argument}/{argument}", "zig"),
    );
    try std.testing.expectEqualStrings(
        "https://example.com/",
        url(&buf, "https://example.com/", "ignored"),
    );
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", url(&tiny, "https://x.com/?q={argument}", "q"));
}

test "System Settings' panes share the local results header and keep the panel's height (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build(
        "login items",
        &ix,
        &.{},
        &.{ "login items mac", "login items windows", "login items iphone" },
        defaults,
    );
    try t.expectEqual(Kind.pane, r.rows[0].kind);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqualStrings("Login Items & Extensions", panes.all[r.rows[0].app].name);
    try t.expect(r.n <= max_rows);
    // "settings" is Nanolight's own Settings and System Settings the app,
    // not every pane with "settings" in a word for it.
    r.build("settings", &ix, &.{}, &.{}, defaults);
    for (r.slice()) |row| try t.expect(row.kind != .pane);
    // Math lists no panes.
    r.build("2+2", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(@as(usize, 1), r.n);
}

test "a full list of apps, panes and files still fits, with every quicklink" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    // Six apps match "ho", and so do three panes (Desktop & Dock, Sound,
    // Keyboard): typing "hola" used to overflow the room left for Google.
    // They share the local rows, ranked by match; every quicklink stays.
    var ix = try testIndex(
        t.allocator,
        &.{ "Home", "Hopper", "Hotspot Shield", "Photos", "Shortcuts", "Photo Booth", "Phone" },
    );
    defer ix.deinit();
    var r: Results = .{};
    const web = [_][]const u8{ "hola", "hotmail", "hoy", "horoscopo" };
    const local = max_rows - max_quicklink_rows - 1;
    r.build("ho", &ix, &.{}, &web, defaults);
    var counts = std.enums.EnumArray(Kind, usize).initFill(0);
    for (r.slice()) |row| counts.set(row.kind, counts.get(row.kind) + 1);
    try t.expect(counts.get(.pane) > 0);
    try t.expectEqual(local, counts.get(.app) + counts.get(.pane) + counts.get(.command));
    try t.expectEqual(@as(usize, max_quicklink_rows), counts.get(.quicklink));
    try t.expectEqual(max_rows, r.n);
    var heads: usize = 0;
    for (0..r.n) |i| heads += @intFromBool(r.section(i) != null);
    try t.expectEqual(@as(usize, 3), heads);
    try t.expectEqual(Kind.quicklink, r.rows[r.n - 1].kind);
    try t.expectEqual(@as(u16, 4), r.rows[r.n - 1].ql);
    // Files too, with no head of their own: a path typed out leads, and
    // names that match worse give way to the apps and panes.
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/ho", true, .{ .score = 2000 });
    for (1..files.max_rows) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/ho{d}", .{i}), false, .{ .score = 1 });
    }
    r.found = &found;
    r.build("ho", &ix, &.{}, &web, defaults);
    counts = .initFill(0);
    for (r.slice()) |row| counts.set(row.kind, counts.get(row.kind) + 1);
    try t.expectEqual(Kind.file, r.rows[0].kind);
    try t.expectEqual(@as(usize, 1), counts.get(.file));
    try t.expectEqual(
        local,
        counts.get(.app) + counts.get(.pane) + counts.get(.command) + counts.get(.file),
    );
    try t.expectEqual(@as(usize, max_quicklink_rows), counts.get(.quicklink));
    heads = 0;
    for (0..r.n) |i| heads += @intFromBool(r.section(i) != null);
    try t.expectEqual(@as(usize, 3), heads);
    // Math lists no files.
    r.build("2+2", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(@as(usize, 1), r.n);
}

test "a conversion is answered like math, with the rate under a currency's" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    r.build("10 km to mi", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("6.2137119224 mi", r.answer);
    try t.expectEqualStrings("6.2137119224", r.copy);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expect(!r.need_rates);
    r.build("10 m to min", &ix, &.{}, &.{}, defaults);
    try t.expect(r.n == 0 or r.rows[0].kind != .calc);
    // No rates yet: it says so, and asks for them.
    r.build("100 usd to ttd", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("Loading rates…", r.answer);
    try t.expect(r.need_rates);
    try t.expectEqualStrings("", r.copy);
    r.rates_failed = true;
    r.build("100 usd to ttd", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("Rates unavailable", r.answer);
    // The pending card does not drop the web search under it.
    var web_row = false;
    for (r.slice()) |row| web_row = web_row or row.kind == .quicklink;
    try t.expect(web_row);
    try t.expect(r.pending);
    try t.expectEqual(@as(usize, 1), r.actionable(0));
    try t.expectEqual(Kind.quicklink, r.rows[r.actionable(0)].kind);
    var rates = convert.Rates.parse(
        t.allocator,
        "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785}}",
    ).?;
    defer rates.deinit();
    r.rates = &rates;
    r.build("100 USD in TTD", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("678.50 TTD", r.answer);
    try t.expectEqualStrings("678.50", r.copy);
    try t.expectEqualStrings("100 USD", r.expr);
    try t.expectEqualStrings("1 USD = 6.785 TTD · 2026-11-03", r.note);
    try t.expectEqualStrings("", r.hex);
    try t.expect(!r.pending);
    try t.expectEqual(@as(usize, 0), r.actionable(0));
    // Math after a conversion forgets its note, and copies its own answer.
    r.build("2+2", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("", r.note);
    try t.expectEqualStrings("4", r.copy);
}

test "math around a conversion: the card shows the amount worked out and copies the answer" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    r.build("3 * 10 km to mi", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("30 km", r.expr);
    try t.expectEqualStrings("18.6411357671 mi", r.answer);
    try t.expectEqualStrings("18.6411357671", r.copy);
    r.build("10 km to mi / 2", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expectEqualStrings("3.1068559612 mi", r.answer);
    try t.expectEqualStrings("3.1068559612", r.copy);
    r.build("(2 + 3) * 2 km to m", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expectEqualStrings("10,000 m", r.answer);
    try t.expectEqualStrings("10000", r.copy);
    // An operator with nothing after it yet keeps the answer so far.
    r.build("10 km to mi *", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("6.2137119224 mi", r.answer);
    r.build("2 + 3 *", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("2 + 3", r.expr);
    try t.expectEqualStrings("5", r.copy);
    // No rates yet: still pending, nothing to copy.
    r.build("12 ttd to usd * 12", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expect(r.pending);
    try t.expect(r.need_rates);
    try t.expectEqualStrings("Loading rates…", r.answer);
    try t.expectEqualStrings("", r.copy);
    r.build("12 ttd to usd /", &ix, &.{}, &.{}, defaults);
    try t.expect(r.pending);
    var rates = convert.Rates.parse(
        t.allocator,
        "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785,\"eur\":0.86}}",
    ).?;
    defer rates.deinit();
    r.rates = &rates;
    r.build("35 * 7 ttd to usd", &ix, &.{}, &.{}, defaults);
    try t.expect(!r.pending);
    try t.expectEqualStrings("245 TTD", r.expr);
    try t.expectEqualStrings("36.11 USD", r.answer);
    try t.expectEqualStrings("36.11", r.copy);
    try t.expectEqualStrings("1 TTD = 0.147384 USD · 2026-11-03", r.note);
    r.build("12 ttd to usd * 12", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("12 TTD", r.expr);
    try t.expectEqualStrings("21.22 USD", r.answer);
    try t.expectEqualStrings("21.22", r.copy);
    try t.expectEqualStrings("1 TTD = 0.147384 USD · 2026-11-03", r.note);
    r.build("12 ttd to usd * ", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("12 TTD", r.expr);
    try t.expectEqualStrings("1.77 USD", r.answer);
    r.build("$20 * 3 in eur", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("60 USD", r.expr);
    try t.expectEqualStrings("51.60 EUR", r.answer);
    try t.expectEqualStrings("51.60", r.copy);
    try t.expectEqualStrings("1 USD = 0.86 EUR · 2026-11-03", r.note);
}

test "system commands compete by match without taking a quicklink's row" {
    const t = std.testing;
    commands.listForTests(true);
    defer commands.listForTests(false);
    var ix = try testIndex(
        t.allocator,
        &.{
            "Sleep Aid",
            "Sleepy",
            "Sleeper",
            "Sleeping",
            "Sleep Cycle",
            "Sleep Timer",
            "Sleep Log",
        },
    );
    defer ix.deinit();
    var r: Results = .{};
    // An exact command beats prefix app matches; every quicklink stays.
    r.build("sleep", &ix, &.{}, &.{ "sleep a", "sleep b", "sleep c", "sleep d" }, defaults);
    try t.expectEqual(Kind.command, r.rows[0].kind);
    var cmds: usize = 0;
    var links: usize = 0;
    for (r.slice()) |row| {
        if (row.kind == .command) cmds += 1;
        if (row.kind == .quicklink) links += 1;
    }
    try t.expect(cmds <= max_commands);
    try t.expectEqual(@as(usize, 5), links);
    try t.expect(r.n <= max_rows);
    // Alone, the command still uses the shared Results section.
    var few = try testIndex(t.allocator, &.{"Safari"});
    defer few.deinit();
    r.build("sleep", &few, &.{}, &.{}, defaults);
    const at = for (r.slice(), 0..) |row, i| {
        if (row.kind == .command) break i;
    } else return error.NoCommand;
    try t.expectEqualStrings("Sleep", commands.all[r.rows[at].app].name);
    try t.expectEqualStrings("Results", r.section(at).?);
    // Other commands can match too (the Mac's Sleep Display says "sleep
    // display"); the quicklinks follow them.
    const after = for (r.slice()[at..], at..) |row, i| {
        if (row.kind != .command) break i;
    } else return error.NoQuicklink;
    try t.expectEqual(Kind.quicklink, r.rows[after].kind);
    r.build("sa", &few, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.app, r.rows[0].kind);
    // Not with a keyword, math, or the words for Nanolight's Settings.
    r.build("ddg sleep", &few, &.{}, &.{}, defaults);
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    r.build("2+2", &few, &.{}, &.{}, defaults);
    try t.expectEqual(@as(usize, 1), r.n);
    // Unlisted (their program missing), they are not rows.
    commands.listForTests(false);
    r.build("sleep", &few, &.{}, &.{}, defaults);
    for (r.slice()) |row| try t.expect(row.kind != .command);
}

test "Clipboard History competes with apps by its name's match" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "ColorSync Utility", "Archive Utility" });
    defer ix.deinit();
    var r: Results = .{ .clip_on = true };
    r.build("cli", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.clipboard, r.rows[0].kind);
    try t.expectEqual(search.score("cli", "Clipboard History").?.score, r.rows[0].match.score);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqual(Kind.app, r.rows[1].kind);
    try t.expect(r.section(1) == null);
    // Explicit shortcuts win even over a frequently opened app.
    try ix.add("Clip", "/Clip.app");
    ix.apps.items[2].launches = 100;
    r.build("clip", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.clipboard, r.rows[0].kind);
    r.clip_on = false;
    r.build("cli", &ix, &.{}, &.{}, defaults);
    for (r.slice()) |row| try t.expect(row.kind != .clipboard);
}
