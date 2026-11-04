//! What the panel lists for a query, in order: the answer when it is math,
//! the apps that match it (or, with no query, suggestions), then the
//! quicklinks (settings.zig, `[[quicklinks]]`): the first is a search for
//! exactly what is typed, and Google's completions of it go under the
//! quicklink whose address is Google's, a key or two away. `<keyword> words`
//! runs only that quicklink. With no app or answer, Return searches what
//! was typed (as an address bar's does). Completions land a moment after the rest;
//! the panel keeps the selection on the row it was on (`Nanolight.answered`).
const std = @import("std");
const search = @import("search.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const panes = @import("settings_panes.zig");
const commands = @import("commands.zig");
const mac = @import("builtin").os.tag == .macos;
const Index = @import("apps.zig").Index;
pub const Quicklink = @import("settings.zig").Quicklink;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on.
pub const machine = if (mac) "Mac" else "PC";

pub const Kind = enum {
    calc,
    app,
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
            .app => if (suggested) "Suggestions" else "Applications",
            .settings => "Nanolight",
            .pane => "System Settings",
            .command => "Commands",
            .clipboard => "Nanolight",
            .quicklink, .suggest => unreachable,
        };
    }
};

pub const Row = struct {
    kind: Kind,
    /// The app's index (`.app`).
    app: u32 = 0,
    /// Which of the completions (`.suggest`).
    web: u8 = 0,
    /// Which quicklink (`.quicklink`).
    ql: u16 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// System Settings' panes, under the apps (the Mac's).
pub const max_panes = 3;
/// System commands, under the panes: they never take a row from an app, a
/// quicklink or the header of another section.
pub const max_commands = 3;
/// Google's completions fill what room is left, up to four.
pub const max_web = 4;
/// The quicklinks listed under the apps; later ones answer to their keyword.
pub const max_quicklink_rows = 5;
/// Every app and the quicklink rows leave room for three completions.
pub const max_rows = max_apps + max_quicklink_rows + 3;

/// The quicklink a query addresses by keyword, and where its words start.
pub const Keyed = struct { ql: u16, arg: usize };

/// `<keyword> words`, the keyword any case; `query` is trimmed.
pub fn keyed(ql: []const Quicklink, query: []const u8) ?Keyed {
    for (ql[0..@min(ql.len, std.math.maxInt(u16))], 0..) |q, i| {
        const k = q.keyword;
        if (k.len == 0 or query.len <= k.len or query[k.len] != ' ' or !std.ascii.eqlIgnoreCase(query[0..k.len], k)) continue;
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
    return std.ascii.eqlIgnoreCase(h, "google.com") or (h.len > 11 and std.ascii.eqlIgnoreCase(h[h.len - 11 ..], ".google.com"));
}

/// The listed quicklink whose address is Google's: the one its completions go with.
pub fn google(ql: []const Quicklink) ?u16 {
    for (ql[0..@min(ql.len, max_quicklink_rows)], 0..) |q, i| if (isGoogle(q.url)) return @intCast(i);
    return null;
}

pub const Results = struct {
    rows: [max_rows]Row = undefined,
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
    /// The quicklink holding Google's completions, when listed.
    google: ?u16 = null,
    /// The query went to one quicklink by its keyword.
    keyed: ?Keyed = null,
    /// Clipboard History can be opened (the host has it): it is listed for "clip".
    clip_on: bool = false,

    /// What a quicklink row searches for: the words, past any keyword.
    pub fn argument(r: *const Results, query: []const u8) []const u8 {
        const q = std.mem.trim(u8, query, " ");
        return if (r.keyed) |k| q[@min(k.arg, q.len)..] else q;
    }

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    /// Lists what `query` finds among `names` (with how often each was
    /// opened, `boost`), the quicklinks `ql`, and Google's completions of it
    /// (`web`), or `suggestions` when the query is empty.
    pub fn build(r: *Results, query_in: []const u8, ix: *const Index, suggestions: []const u32, web: []const []const u8, ql: []const Quicklink) void {
        const boost = ix.launches.items;
        r.n = 0;
        r.google = null;
        r.keyed = null;
        r.copy = "";
        r.expr = "";
        r.note = "";
        r.need_rates = false;
        const query = std.mem.trim(u8, query_in, " ");
        r.suggested = query.len == 0;
        if (query.len == 0) {
            for (suggestions[0..@min(suggestions.len, max_apps)]) |i| r.push(.{ .kind = .app, .app = i });
            return;
        }
        var pending = false;
        if (calc.eval(query)) |v| {
            r.answer = calc.format(&r.answer_buf, v, true);
            r.hex = if (v >= 0 and v < 1e15 and v == @round(v))
                std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{@as(u64, @intFromFloat(v))}) catch ""
            else
                "";
            r.push(.{ .kind = .calc });
        } else if (convert.answer(query, r.rates)) |a| {
            pending = a == .pending;
            r.convertRow(a);
            r.push(.{ .kind = .calc });
        }
        var ranked: [max_apps]search.Ranked = undefined;
        const n = search.rankApps(query, ix, boost, &ranked);
        for (ranked[0..n]) |x| r.push(.{ .kind = .app, .app = x.index, .match = x.match });
        // "settings" / "preferences": Nanolight's own screen, right under
        // the apps: Return still opens System Settings, a key away from this.
        if (isSettings(query)) r.push(.{ .kind = .settings });
        const clip = r.clip_on and isClipboard(query);
        if (clip) r.push(.{ .kind = .clipboard });
        if (r.n > 0 and r.rows[0].kind == .calc and !pending) return;
        // System Settings' panes, in their own section. A section's header
        // is less than a row: one completion fewer pays for it, so the
        // panel never grows past its tallest (view.max_height).
        var pane_rows: [max_panes]search.Ranked = undefined;
        const np = if (isSettings(query) or clip) 0 else panes.rank(query, &pane_rows);
        for (pane_rows[0..np]) |x| r.push(.{ .kind = .pane, .app = x.index, .match = x.match });
        const key = keyed(ql, query);
        // System commands take what room the apps, panes and quicklinks leave.
        const shown = @min(ql.len, max_quicklink_rows);
        var cmd_rows: [max_commands]search.Ranked = undefined;
        const cmd_room = @min(max_commands, max_rows -| r.n -| shown -| 1 -| @intFromBool(np > 0));
        const nc = if (key != null or isSettings(query) or clip) 0 else commands.rank(query, cmd_rows[0..cmd_room]);
        for (cmd_rows[0..nc]) |x| r.push(.{ .kind = .command, .app = x.index, .match = x.match });
        // A keyword sends the rest of the query to its quicklink alone.
        if (key) |k| {
            r.keyed = k;
            r.push(.{ .kind = .quicklink, .ql = k.ql });
            return;
        }
        // The quicklinks, the first a search for what was typed, Google's
        // completions (as many as leave room for the rest) under Google's.
        const room = max_rows -| r.n -| shown -| @intFromBool(np > 0) -| @intFromBool(nc > 0);
        r.google = google(ql);
        for (0..shown) |i| {
            r.push(.{ .kind = .quicklink, .ql = @intCast(i) });
            if (r.google == @as(u16, @intCast(i))) for (0..@min(web.len, max_web, room)) |j| r.push(.{ .kind = .suggest, .web = @intCast(j) });
        }
    }

    fn convertRow(r: *Results, a: convert.Answer) void {
        r.hex = "";
        var nb: [32]u8 = undefined;
        switch (a) {
            .unit => |u| {
                r.answer = convert.formatUnit(&r.answer_buf, u, true);
                r.copy = calc.format(&r.copy_buf, u.value, false);
                r.expr = std.fmt.bufPrint(&r.expr_buf, "{s} {s}", .{ calc.format(&nb, u.amount, true), u.from }) catch "";
            },
            .money => |m| {
                r.need_rates = true;
                r.answer = std.fmt.bufPrint(&r.answer_buf, "{s} {s}", .{ convert.formatMoney(&nb, m.value, true), m.to }) catch "";
                r.copy = convert.formatMoney(&r.copy_buf, m.value, false);
                r.expr = std.fmt.bufPrint(&r.expr_buf, "{s} {s}", .{ calc.format(&nb, m.amount, true), m.from }) catch "";
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
        return query.len >= 3 and m.score >= 500;
    }

    /// "settings" and "preferences", the words people type for this.
    fn isSettings(query: []const u8) bool {
        if (std.ascii.eqlIgnoreCase(query, "settings") or std.ascii.eqlIgnoreCase(query, "preferences")) return true;
        const keys = [_][]const u8{ "设置", "偏好设置", "系统设置", "nanolight 设置" };
        const q = std.mem.trim(u8, query, " ");
        for (keys) |k| if (std.mem.eql(u8, q, k)) return true;
        return false;
    }

    fn push(r: *Results, row: Row) void {
        if (r.n == max_rows) return;
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
        escape(&w, argument);
        rest = rest[i + mark.len ..];
    }
    w.writeAll(rest) catch return "";
    return w.buffered();
}

/// `query`, trimmed, as a URL's query value: spaces as `+`, the rest of
/// what isn't plain as `%XX`. Stops where `w` is full.
pub fn escape(w: *std.Io.Writer, query: []const u8) void {
    for (std.mem.trim(u8, query, " ")) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            w.writeByte(ch) catch break;
        } else if (ch == ' ') {
            w.writeByte('+') catch break;
        } else w.print("%{X:0>2}", .{ch}) catch break;
    }
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
    try t.expectEqualStrings("Applications", r.section(0).?);
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
    // "settings": System Settings first, Nanolight's own a row under it.
    r.build("settings", &ix, &.{}, &.{}, defaults);
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 1), r.rows[0].app);
    try t.expectEqual(Kind.settings, r.rows[1].kind);
    // A full list of apps still ends with every quicklink.
    var many_ix = try testIndex(t.allocator, &.{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" });
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
    try std.testing.expectEqualStrings("https://x.com/search?f=live&q=liquid+glass+%26+UI", url(&buf, "https://x.com/search?f=live&q={argument}", " liquid glass & UI "));
    try std.testing.expectEqualStrings("https://a/zig/zig", url(&buf, "https://a/{argument}/{argument}", "zig"));
    try std.testing.expectEqualStrings("https://example.com/", url(&buf, "https://example.com/", "ignored"));
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", url(&tiny, "https://x.com/?q={argument}", "q"));
}

test "System Settings' panes come under the apps and keep the panel's height (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build("login items", &ix, &.{}, &.{ "login items mac", "login items windows", "login items iphone" }, defaults);
    try t.expectEqual(Kind.pane, r.rows[0].kind);
    try t.expectEqualStrings("System Settings", r.section(0).?);
    try t.expectEqualStrings("Login Items & Extensions", panes.all[r.rows[0].app].name);
    // Google's completions give up a row for the section's header.
    try t.expect(r.n <= max_rows - 1);
    // "settings" is Nanolight's own Settings and System Settings the app,
    // not every pane with "settings" in a word for it.
    r.build("settings", &ix, &.{}, &.{}, defaults);
    for (r.slice()) |row| try t.expect(row.kind != .pane);
    // Math lists no panes.
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
    var rates = convert.Rates.parse(t.allocator, "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785}}").?;
    defer rates.deinit();
    r.rates = &rates;
    r.build("100 USD in TTD", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("678.50 TTD", r.answer);
    try t.expectEqualStrings("678.50", r.copy);
    try t.expectEqualStrings("100 USD", r.expr);
    try t.expectEqualStrings("1 USD = 6.785 TTD · 2026-11-03", r.note);
    try t.expectEqualStrings("", r.hex);
    // Math after a conversion forgets its note and copy.
    r.build("2+2", &ix, &.{}, &.{}, defaults);
    try t.expectEqualStrings("", r.note);
    try t.expectEqualStrings("", r.copy);
}

test "system commands list under the apps without taking an app's, a quicklink's or a header's row" {
    const t = std.testing;
    commands.listForTests(true);
    defer commands.listForTests(false);
    var ix = try testIndex(t.allocator, &.{ "Sleep Aid", "Sleepy", "Sleeper", "Sleeping", "Sleep Cycle", "Sleep Timer", "Sleep Log" });
    defer ix.deinit();
    var r: Results = .{};
    // Every app row stays, and so does every quicklink.
    r.build("sleep", &ix, &.{}, &.{ "sleep a", "sleep b", "sleep c", "sleep d" }, defaults);
    for (r.rows[0..max_apps]) |row| try t.expectEqual(Kind.app, row.kind);
    var cmds: usize = 0;
    var links: usize = 0;
    for (r.slice()) |row| {
        if (row.kind == .command) cmds += 1;
        if (row.kind == .quicklink) links += 1;
    }
    try t.expect(cmds <= max_commands);
    try t.expectEqual(@as(usize, 5), links);
    try t.expect(r.n + @intFromBool(cmds > 0) <= max_rows);
    // Alone, the command has its own section, after the apps.
    var few = try testIndex(t.allocator, &.{"Safari"});
    defer few.deinit();
    r.build("sleep", &few, &.{}, &.{}, defaults);
    const at = for (r.slice(), 0..) |row, i| {
        if (row.kind == .command) break i;
    } else return error.NoCommand;
    try t.expectEqualStrings("Sleep", commands.all[r.rows[at].app].name);
    try t.expectEqualStrings("Commands", r.section(at).?);
    try t.expectEqual(Kind.quicklink, r.rows[at + 1].kind);
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
