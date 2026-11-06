//! What the panel lists for a query, in order: the answer when it is math,
//! local results ranked together by match (apps and script commands, files
//! and folders, panes, commands; or what was opened most, with no query),
//! then the quicklinks (web.zig, `[[quicklinks]]`): the first is a search for
//! exactly what is typed, and Google's completions of it go under the
//! quicklink whose address is Google's, a key or two away. `<keyword> words`
//! runs only that quicklink. With no app or answer, Return searches what
//! was typed (as an address bar's does). Completions land a moment after the rest;
//! the panel keeps the selection on the row it was on (`Nanolight.refill`).
//!
//! Each kind of row has one provider (`providers`): what lists its rows, the
//! header they go under, and what Return does to them as the panel says it.
const std = @import("std");
const search = @import("search.zig");
const files = @import("files.zig");
const calc = @import("calc.zig");
const convert = @import("convert.zig");
const rates_table = @import("rates_table.zig");
const panes = @import("settings_panes.zig");
const commands = @import("commands.zig");
const clipboard = @import("clipboard.zig");
const web = @import("web.zig");
const suggest = @import("suggest.zig");
const launchers = @import("launchers.zig");
const chrome = @import("chrome.zig");
const assert = std.debug.assert;
const Launchers = launchers.Launchers;
const Quicklink = web.Quicklink;

pub const Kind = enum {
    calc,
    /// An app (`Row.item` its place in `apps.Index`).
    app,
    /// A script command, or the row that opens their folder (`Row.item` its
    /// place in `script_commands.List`).
    script,
    /// A file or folder found (`Row.item` its place in `Input.found`).
    file,
    /// A pane of System Settings (`Row.item` its place in settings_panes.zig).
    pane,
    /// A system command (`Row.item` its place in commands.zig).
    command,
    /// Nanolight's own Settings, listed when the query asks for them.
    settings,
    /// Clipboard History, listed when the query asks for it.
    clipboard,
    /// A quicklink (`Row.item` its place in the quicklinks).
    quicklink,
    /// One of Google's completions (`Row.item` its place among them).
    suggest,
};

/// What a row opens when Return is pressed on it.
pub const Target = union(enum) {
    /// An app, a file or a folder: its path.
    app: []const u8,
    url: []const u8,
    /// A script command, its place in `script_commands.List`.
    script: u32,
    folder,
    /// A pane of System Settings, its place in settings_panes.zig.
    pane: u16,

    /// Whether it opens a screen in the panel, which then stays up: a
    /// script command's runs there (its runner hides it for a silent one).
    pub fn opensScreen(t: Target) bool {
        return switch (t) {
            .script => true,
            .app, .url, .folder, .pane => false,
        };
    }
};

/// The header over a provider's rows.
pub const Section = enum {
    /// "Calculator", over the answer's card.
    card,
    /// "Results", or "Suggestions" with no query: the local rows, ranked together.
    local,
    /// "Search" over the first quicklink (the search for what was typed),
    /// "Quicklinks" over the rest.
    web,
    /// The section of the row above: a completion goes with its quicklink.
    above,
};

/// What keeps a row the same row when the list is filled again (anchor.zig).
pub const Identity = enum {
    /// Its place in its provider's list.
    item,
    /// Its path: the files found come back in another order.
    path,
    /// Its words: completions come back in another order.
    words,
    /// Its kind: there is one row of it at most.
    kind,
};

/// Where a kind of row comes from and what the panel says Return does to it.
pub const Provider = struct {
    section: Section,
    /// What Return does, as the footer says it ("Open Application").
    action: []const u8,
    /// The same, as the selected row says it ("Open"); a card says nothing.
    hint: []const u8 = "",
    /// The symbol on its row's tile when it has no icon of its own.
    symbol: []const u8 = "",
    identity: Identity = .item,
    /// Lists what the query finds among the local rows. Null for rows `build`
    /// lists itself, and for script commands, ranked with the apps.
    rank: ?*const fn (r: *Results, in: *const Input) void = null,
    /// Listed beside an answer card (one not waiting on rates).
    with_card: bool = false,
    /// Listed when a keyword sends the query to one quicklink.
    with_keyword: bool = true,
    /// Nanolight's own row: when one is listed, those that `yields` are not.
    own: bool = false,
    yields: bool = false,
    /// The query that puts its row first, past a much-opened app's.
    first_for: ?[]const u8 = null,
};

pub const providers = std.enums.EnumArray(Kind, Provider).init(.{
    .calc = .{ .section = .card, .action = "Copy Answer", .identity = .kind },
    .app = .{
        .section = .local,
        .action = "Open Application",
        .hint = "Open",
        .symbol = "app.dashed",
        .rank = rankLaunchers,
        .with_card = true,
    },
    .script = .{
        .section = .local,
        .action = "Open Application",
        .hint = "Open",
        .symbol = "app.dashed",
        .with_card = true,
    },
    .file = .{
        .section = .local,
        .action = "Open",
        .hint = "Open",
        .symbol = "doc",
        .identity = .path,
        .rank = rankFiles,
    },
    .pane = .{
        .section = .local,
        .action = "Open in System Settings",
        .hint = "Open",
        .symbol = "app.dashed",
        .rank = rankPanes,
        .yields = true,
    },
    .command = .{
        .section = .local,
        .action = "Run Command",
        .hint = "Run",
        .symbol = "terminal",
        .rank = rankCommands,
        .with_keyword = false,
        .yields = true,
    },
    .settings = .{
        .section = .local,
        .action = "Open Settings",
        .hint = "Open",
        .symbol = "gearshape",
        .identity = .kind,
        .rank = rankSettings,
        .with_card = true,
        .own = true,
        .first_for = "settings",
    },
    .clipboard = .{
        .section = .local,
        .action = "Open " ++ clipboard.title,
        .hint = "Open",
        .symbol = "doc.on.doc",
        .identity = .kind,
        .rank = rankClipboard,
        .with_card = true,
        .own = true,
        .first_for = "clip",
    },
    // The footer names the quicklink after it: "Search Google".
    .quicklink = .{ .section = .web, .action = "Search", .hint = "Go", .symbol = "globe" },
    .suggest = .{
        .section = .above,
        .action = "Search Google",
        .hint = "Go",
        .symbol = "magnifyingglass",
        .identity = .words,
    },
});

/// The local providers, in the order their rows are listed: equals keep it.
const local_order = [_]Kind{ .app, .settings, .clipboard, .pane, .command, .file };
comptime {
    for (std.enums.values(Kind)) |k| {
        const listed = std.mem.indexOfScalar(Kind, &local_order, k) != null;
        assert(listed == (providers.get(k).rank != null));
    }
}

pub const Row = struct {
    kind: Kind,
    /// Its place in its provider's list (`Kind` says which).
    item: u32 = 0,
    /// Which of its name's bytes the query matched.
    match: search.Match = .{ .score = 0 },
};

pub const max_apps = 6;
/// Per-kind caps within the shared, match-ranked local results.
pub const max_panes = 3;
pub const max_commands = 3;
/// The quicklinks listed under the apps; later ones answer to their keyword.
pub const max_quicklink_rows = 5;
/// The tallest list: every app and quicklink row, and Google's completions
/// (`suggest.max_rows`) but one; with fewer local rows, all of them.
pub const max_rows = max_apps + max_quicklink_rows + suggest.max_rows - 1;
/// The heads over the tallest list: the local rows', "Search" and
/// "Quicklinks". An answer lists no quicklinks; a card waiting on rates
/// pays for its head with `pending_rows` rows (`build`).
pub const max_heads = 3;
/// The rows a card waiting on rates costs: its extra height and its head
/// (view.zig asserts they fit).
pub const pending_rows = 2;
comptime {
    // The panel's tallest list is sized for these (chrome.max_height).
    assert(max_rows == chrome.max_rows);
    assert(max_heads == chrome.max_heads);
}
/// Every local candidate, and a card, fit before ranking keeps the best of
/// them and trims the list to `max_rows`. Apps and scripts share `max_apps`.
const max_candidates = 1 + max_apps + files.max_rows + max_panes + max_commands;
comptime {
    // The Settings and Clipboard History rows, two at most, are listed only
    // in place of the panes and commands.
    assert(max_panes + max_commands >= 2);
}

/// "settings" and "preferences", the words people type for Nanolight's Settings.
const settings_words = [_][]const u8{
    "settings",
    "preferences",
    "设置",
    "偏好设置",
    "系统设置",
    "nanolight 设置",
};

/// The apps and script commands the words name, best first.
fn rankLaunchers(r: *Results, in: *const Input) void {
    var ranked: [max_apps]search.Ranked = undefined;
    const n = in.from.rank(in.words, &ranked);
    for (ranked[0..n]) |x| r.push(launcherRow(in.from.at(x), x.match));
}

fn launcherRow(it: launchers.Item, match: search.Match) Row {
    return switch (it) {
        .app => |i| .{ .kind = .app, .item = i, .match = match },
        .script => |i| .{ .kind = .script, .item = i, .match = match },
    };
}

fn rankSettings(r: *Results, in: *const Input) void {
    for (settings_words) |w| if (std.ascii.eqlIgnoreCase(in.words, w)) {
        r.push(.{
            .kind = .settings,
            .match = search.score(in.words, "Settings") orelse .{ .score = 0 },
        });
        return;
    };
}

/// Clipboard History, when the host has it: for "clip", or a name's worth
/// of its name (not a stray letter or two).
fn rankClipboard(r: *Results, in: *const Input) void {
    if (!in.clip_on) return;
    const m = search.score(in.words, clipboard.title) orelse return;
    const named = in.words.len >= 3 and m.score >= search.min_loose;
    if (!named and !std.ascii.eqlIgnoreCase(in.words, "clip")) return;
    r.push(.{ .kind = .clipboard, .match = m });
}

fn rankPanes(r: *Results, in: *const Input) void {
    var ranked: [max_panes]search.Ranked = undefined;
    const n = panes.rank(in.words, &r.panes, &ranked);
    for (ranked[0..n]) |x| r.push(.{ .kind = .pane, .item = x.index, .match = x.match });
}

fn rankCommands(r: *Results, in: *const Input) void {
    const installed = in.commands orelse return;
    var ranked: [max_commands]search.Ranked = undefined;
    const n = commands.rank(in.words, installed, &ranked);
    for (ranked[0..n]) |x| r.push(.{ .kind = .command, .item = x.index, .match = x.match });
}

/// Files and folders compete by their names' match (equal scores after the
/// rest); a path typed out that exists leads (files.zig).
fn rankFiles(r: *Results, in: *const Input) void {
    const found = in.found orelse return;
    for (found.entries[0..found.n], 0..) |e, i| {
        r.push(.{ .kind = .file, .item = @intCast(i), .match = e.match });
    }
}

/// The answer card's: `text`, the words without the operators they end
/// with, and what that works out to.
pub const Math = struct {
    text: []const u8,
    answer: union(enum) { value: f64, conversion: convert.Answer },
};

/// The card for the query's `words`, converting money by `table` when in
/// hand. Operators they end with are left off ("2 + 3 *", "500 usd to eur
/// *"), so the card stays while the next number is typed.
pub fn math(words: []const u8, table: ?*const rates_table.Rates) ?Math {
    const text = calc.trimOps(words);
    if (calc.eval(text)) |v| return .{ .text = text, .answer = .{ .value = v } };
    const by: ?convert.Lookup = if (table) |x|
        .{ .ctx = x, .perUsd = rates_table.Rates.perUsd, .date = x.date }
    else
        null;
    const a = convert.answer(text, by) orelse return null;
    return .{ .text = text, .answer = .{ .conversion = a } };
}

/// Whether the query's `words` show the answer card: then they are not
/// searched for.
pub fn isMath(words: []const u8, table: ?*const rates_table.Rates) bool {
    return math(words, table) != null;
}

/// A whole answer is shown in hexadecimal too below this, and its room.
const hex_below = 1e15;
const hex_len = std.fmt.comptimePrint("0x{X}", .{@as(u64, hex_below)}).len;
/// A number as the card writes it beside a unit or a currency code.
const number_len = 32;
/// Each of the card's lines: the answer, what Return copies, the expression.
const line_len = 64;
comptime {
    // A unit's or a currency's expression, and a money answer, fit.
    assert(line_len >= number_len + " ".len + @max(convert.unit_name_len, "USD".len));
}

/// What `Results.build` lists rows from.
pub const Input = struct {
    /// The query's words (`Query.words`): nothing blank at either end.
    words: []const u8,
    /// The apps and script commands, and how often each was opened: the
    /// most opened are listed for no words.
    from: Launchers,
    /// The quicklinks, the first a search for exactly the words.
    quicklinks: []const Quicklink,
    completions: []const []const u8 = &.{},
    /// Currency rates, when in hand, and whether fetching them failed.
    rates: rates_table.Status = .{},
    /// Clipboard History can be opened (the host has it): it is listed for "clip".
    clip_on: bool = false,
    /// The files and folders file search found for the words (files.zig),
    /// if it is on: local rows like the rest.
    found: ?*const files.List = null,
    /// The system commands this machine can run, if the host runs them.
    commands: ?*const commands.Installed = null,
};

pub const Results = struct {
    rows: [@max(max_rows, max_candidates)]Row = undefined,
    n: usize = 0,
    /// No query: the most opened are suggestions, nothing else is listed.
    suggested: bool = false,
    /// The math's answer, as shown.
    answer_buf: [line_len]u8 = undefined,
    answer: []const u8 = "",
    /// A whole answer in hexadecimal too ("0xC00"), else empty.
    hex_buf: [hex_len]u8 = undefined,
    hex: []const u8 = "",
    /// A conversion: what Return copies, the expression as the card shows
    /// it, and the line under the answer (the rate and its day).
    copy_buf: [line_len]u8 = undefined,
    copy: []const u8 = "",
    expr_buf: [line_len]u8 = undefined,
    expr: []const u8 = "",
    note_buf: [96]u8 = undefined,
    note: []const u8 = "",
    /// The words are a currency conversion: rates are needed (or may be stale).
    need_rates: bool = false,
    /// Row 0 is a currency card still waiting for rates: nothing to copy yet.
    pending: bool = false,
    /// The quicklink holding Google's completions, when listed (never with
    /// a keyword).
    google: ?u16 = null,
    /// The words went to one quicklink by its keyword.
    keyed: ?web.Keyed = null,
    panes: panes.Present = .{},

    /// What a quicklink row searches for: the query's `words`, past any
    /// keyword.
    pub fn argument(r: *const Results, words: []const u8) []const u8 {
        return if (r.keyed) |k| words[@min(k.arg, words.len)..] else words;
    }

    /// The row listed first: an app, the answer, or the search for what was
    /// typed (`build`); never a completion nobody picked.
    pub fn first(r: *const Results) ?Row {
        return if (r.n > 0) r.rows[0] else null;
    }

    pub fn slice(r: *const Results) []const Row {
        return r.rows[0..r.n];
    }

    /// Lists what `in.words` find among the apps and script commands (lifted
    /// by how often each was opened, the most opened for no words), from
    /// the other local providers, the quicklinks, and Google's completions.
    pub fn build(r: *Results, in: Input) void {
        r.clear();
        const words = in.words;
        r.suggested = words.len == 0;
        if (words.len == 0) {
            var opened: [max_apps]launchers.Item = undefined;
            const n = in.from.suggestions(&opened);
            for (opened[0..n]) |x| r.push(launcherRow(x, .{ .score = 0 }));
            return;
        }
        const card = math(words, in.rates.table);
        if (card) |m| switch (m.answer) {
            .value => |v| r.calcRow(v, m.text, words.len),
            .conversion => |a| {
                r.pending = a == .pending;
                r.convertRow(a, in.rates.failed);
                r.push(.{ .kind = .calc });
            },
        };
        // An answer is the point: only what opens by name is listed with it.
        // A card waiting on rates is not an answer yet.
        const answered = card != null and !r.pending;
        const ql = in.quicklinks;
        const key = web.keyed(ql, words);
        const local_start = r.n;
        var own = false;
        for (local_order) |kind| {
            const p = providers.get(kind);
            if (answered and !p.with_card) continue;
            if (key != null and !p.with_keyword) continue;
            if (own and p.yields) continue;
            const before = r.n;
            p.rank.?(r, &in);
            own = own or (p.own and r.n > before);
        }
        r.rankLocal(local_start, words);
        if (answered) return;
        const shown = @min(ql.len, max_quicklink_rows);
        // Reserve the quicklinks and one completion before filling local rows.
        const row_limit = max_rows - @as(usize, if (r.pending) pending_rows else 0);
        r.n = @min(r.n, row_limit -| shown -| 1);
        // A keyword sends the rest of the words to its quicklink alone.
        if (key) |k| {
            r.keyed = k;
            r.push(.{ .kind = .quicklink, .item = k.ql });
            return;
        }
        // The quicklinks, the first a search for what was typed, Google's
        // completions (as many as leave room for the rest) under Google's.
        const room = row_limit -| r.n -| shown;
        r.google = web.google(ql[0..shown]);
        for (0..shown) |i| {
            r.push(.{ .kind = .quicklink, .item = @intCast(i) });
            if (r.google != @as(u16, @intCast(i))) continue;
            for (0..@min(in.completions.len, suggest.max_rows, room)) |j| {
                r.push(.{ .kind = .suggest, .item = @intCast(j) });
            }
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
    /// and, when `text` is the start of a longer query, the expression so far.
    fn calcRow(r: *Results, v: f64, text: []const u8, query_len: usize) void {
        r.answer = calc.format(&r.answer_buf, v, true);
        r.copy = calc.format(&r.copy_buf, v, false);
        if (text.len < query_len and text.len <= r.expr_buf.len) {
            @memcpy(r.expr_buf[0..text.len], text);
            r.expr = r.expr_buf[0..text.len];
        }
        r.hex = "";
        if (v >= 0 and v < hex_below and v == @round(v)) {
            const whole: u64 = @intFromFloat(v);
            // `hex_buf` holds the longest.
            r.hex = std.fmt.bufPrint(&r.hex_buf, "0x{X}", .{whole}) catch unreachable;
        }
        r.push(.{ .kind = .calc });
    }

    /// The row Return acts on when `sel` is chosen: a pending card has no
    /// action of its own, so the row under it stands in.
    pub fn actionable(r: *const Results, sel: usize) usize {
        if (r.pending and sel == 0 and r.n > 1) return 1;
        return @min(sel, r.n -| 1);
    }

    /// A conversion's card, saying so when the rates `failed`. Its
    /// expression and a money answer always fit (the comptime check above).
    fn convertRow(r: *Results, a: convert.Answer, failed: bool) void {
        r.hex = "";
        var nb: [number_len]u8 = undefined;
        switch (a) {
            .unit => |u| {
                r.answer = convert.formatUnit(&r.answer_buf, u, true);
                r.copy = convert.formatUnitValue(&r.copy_buf, u.value, false);
                r.expr = std.fmt.bufPrint(
                    &r.expr_buf,
                    "{s} {s}",
                    .{ calc.format(&nb, u.amount, true), u.from },
                ) catch unreachable;
            },
            .money => |m| {
                r.need_rates = true;
                r.answer = std.fmt.bufPrint(
                    &r.answer_buf,
                    "{s} {s}",
                    .{ convert.formatMoney(&nb, m.value, true), m.to },
                ) catch unreachable;
                r.copy = convert.formatMoney(&r.copy_buf, m.value, false);
                r.expr = std.fmt.bufPrint(
                    &r.expr_buf,
                    "{s} {s}",
                    .{ calc.format(&nb, m.amount, true), m.from },
                ) catch unreachable;
                r.note = convert.rateLine(&r.note_buf, m);
            },
            .pending => {
                r.need_rates = true;
                r.answer = if (failed) "Rates unavailable" else "Loading rates…";
            },
        }
    }

    /// The local rows best first; a provider's `first_for` query keeps its
    /// row first, past an app a launch count lifts.
    fn rankLocal(r: *Results, start: usize, query: []const u8) void {
        const Order = struct {
            fn before(preferred: ?Kind, a: Row, b: Row) bool {
                if (preferred) |kind| {
                    if ((a.kind == kind) != (b.kind == kind)) return a.kind == kind;
                }
                return a.match.score > b.match.score;
            }
        };
        const preferred: ?Kind = for (local_order) |kind| {
            const word = providers.get(kind).first_for orelse continue;
            if (std.ascii.eqlIgnoreCase(query, word)) break kind;
        } else null;
        std.sort.insertion(Row, r.rows[start..r.n], preferred, Order.before);
    }

    /// Local candidates may pass `max_rows` until `build` trims them, but
    /// never `max_candidates`.
    fn push(r: *Results, row: Row) void {
        assert(r.n < r.rows.len);
        r.rows[r.n] = row;
        r.n += 1;
    }

    /// The header above row `i`, if a section starts there.
    pub fn section(r: *const Results, i: usize) ?[]const u8 {
        const name = r.sectionName(i);
        if (i > 0 and std.mem.eql(u8, r.sectionName(i - 1), name)) return null;
        return name;
    }

    fn sectionName(r: *const Results, i: usize) []const u8 {
        var j = i;
        while (j > 0 and providers.get(r.rows[j].kind).section == .above) j -= 1;
        const row = r.rows[j];
        const under = providers.get(row.kind).section;
        return switch (under) {
            .card => "Calculator",
            .local => if (r.suggested) "Suggestions" else "Results",
            .web => if (row.item == 0) "Search" else "Quicklinks",
            .above => unreachable,
        };
    }
};

const mac = @import("builtin").os.tag == .macos;
const apps = @import("apps.zig");
const launch_counts = @import("launch_counts.zig");
const defaults = &web.default_quicklinks;
const no_counts: launch_counts.Counts = .{};

fn testIndex(a: std.mem.Allocator, names: []const []const u8) !apps.Index {
    var ix: apps.Index = .init(a);
    for (names) |n| {
        var buf: [128]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    return ix;
}

/// The apps of `ix`, none opened yet, and no script commands.
fn only(ix: *const apps.Index) Launchers {
    return .{ .apps = ix, .counts = &no_counts };
}

/// What `words` list from the apps of `ix` (none opened, no script
/// commands), with Google's `completions` and the default quicklinks.
fn input(ix: *const apps.Index, words: []const u8, completions: []const []const u8) Input {
    return .{
        .words = words,
        .from = only(ix),
        .quicklinks = defaults,
        .completions = completions,
    };
}

test "math first, then apps; quicklinks only without an answer" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build(input(&ix, "saf", &.{}));
    try t.expectEqual(Kind.app, r.rows[0].kind);
    try t.expectEqual(@as(u32, 0), r.rows[0].item);
    try t.expectEqual(Kind.quicklink, r.rows[1].kind);
    try t.expectEqual(@as(u32, 0), r.rows[1].item);
    try t.expectEqual(@as(usize, 6), r.n);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqualStrings("Search", r.section(1).?);
    try t.expectEqualStrings("Quicklinks", r.section(2).?);
    try t.expect(r.section(3) == null);
    r.build(input(&ix, "2^10 * 3", &.{"ignored"}));
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("3,072", r.answer);
    try t.expectEqualStrings("0xC00", r.hex);
    try t.expectEqual(@as(usize, 1), r.n);
    r.build(input(&ix, "", &.{}));
    try t.expectEqual(@as(usize, 2), r.n);
    try t.expectEqualStrings("Suggestions", r.section(0).?);
    r.build(input(&ix, "liquid glass", &.{}));
    try t.expectEqual(@as(usize, 5), r.n);
    // No app: the search for what was typed comes first.
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqualStrings("Search", r.section(0).?);
    try t.expectEqualStrings("Quicklinks", r.section(1).?);
    // Completions under Google, in its section, then the other quicklinks.
    r.build(input(&ix, "liquid gl", &.{ "liquid glass", "liquid glue" }));
    try t.expectEqual(@as(usize, 7), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqual(Kind.suggest, r.rows[1].kind);
    try t.expectEqual(@as(u32, 1), r.rows[2].item);
    try t.expectEqual(@as(u32, 1), r.rows[3].item);
    try t.expect(r.section(1) == null and r.section(2) == null);
    try t.expectEqualStrings("Quicklinks", r.section(3).?);
    r.build(input(&ix, "settings", &.{}));
    try t.expectEqual(Kind.settings, r.rows[0].kind);
    try t.expectEqual(Kind.app, r.rows[1].kind);
    try t.expectEqual(@as(u32, 1), r.rows[1].item);
    // A full list of apps still ends with every quicklink.
    var many_ix = try testIndex(
        t.allocator,
        &.{ "Safari", "Mail", "Maps", "Pages", "Calendar", "Calculator", "FaceTime" },
    );
    defer many_ix.deinit();
    r.build(input(&many_ix, "a", &.{ "a1", "a2", "a3", "a4" }));
    try t.expectEqual(max_rows, r.n);
    try t.expectEqual(Kind.quicklink, r.rows[max_apps].kind);
    try t.expectEqual(Kind.suggest, r.rows[max_apps + 1].kind);
    try t.expectEqual(Kind.quicklink, r.rows[max_rows - 1].kind);
    try t.expectEqual(@as(u32, 4), r.rows[max_rows - 1].item);
}

test "a keyword sends the rest of the query to that quicklink alone" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    r.build(input(&ix, "DDG  zig lang", &.{"ignored"}));
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    try t.expectEqual(@as(u32, 1), r.rows[0].item);
    try t.expectEqualStrings("zig lang", r.argument("DDG  zig lang"));
    // The keyword alone, or a longer word, is an ordinary query.
    r.build(input(&ix, "ddg", &.{}));
    try t.expect(r.keyed == null and r.n == 5);
    r.build(input(&ix, "ddgs zig", &.{}));
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
    const words: []const []const u8 = &.{ "pizza near me", "pizza hut" };
    r.build(.{ .words = "pizza", .from = only(&ix), .quicklinks = ql, .completions = words });
    try t.expectEqual(@as(?u16, 2), r.google);
    try t.expectEqual(Kind.suggest, r.rows[3].kind);
    try t.expectEqual(@as(usize, 5), r.n);
    try t.expectEqualStrings("Quicklinks", r.section(3) orelse "Quicklinks");
    r.build(.{ .words = "pizza", .from = only(&ix), .quicklinks = ql[0..2], .completions = words });
    try t.expect(r.google == null);
    try t.expectEqual(@as(usize, 2), r.n);
}

test "System Settings' panes share the local results header and keep the panel's height (#12)" {
    if (!mac) return error.SkipZigTest;
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "Safari", "System Settings", "Calculator" });
    defer ix.deinit();
    var r: Results = .{};
    r.build(input(
        &ix,
        "login items",
        &.{ "login items mac", "login items windows", "login items iphone" },
    ));
    try t.expectEqual(Kind.pane, r.rows[0].kind);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqualStrings("Login Items & Extensions", panes.all[r.rows[0].item].name);
    try t.expect(r.n <= max_rows);
    // "settings" is Nanolight's own Settings and System Settings the app,
    // not every pane with "settings" in a word for it.
    r.build(input(&ix, "settings", &.{}));
    for (r.slice()) |row| try t.expect(row.kind != .pane);
    r.build(input(&ix, "2+2", &.{}));
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
    const words = [_][]const u8{ "hola", "hotmail", "hoy", "horoscopo" };
    const local = max_rows - max_quicklink_rows - 1;
    var in = input(&ix, "ho", &words);
    r.build(in);
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
    try t.expectEqual(@as(u32, 4), r.rows[r.n - 1].item);
    // Files too, with no head of their own: a path typed out leads, and
    // names that match worse give way to the apps and panes.
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/ho", true, .{ .score = 2000 });
    for (1..files.max_rows) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/ho{d}", .{i}), false, .{ .score = 1 });
    }
    in.found = &found;
    r.build(in);
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
    r.build(input(&ix, "2+2", &.{}));
    try t.expectEqual(@as(usize, 1), r.n);
}

test "a conversion is answered like math, with the rate under a currency's" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    r.build(input(&ix, "10 km to mi", &.{}));
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("6.2137119224 mi", r.answer);
    try t.expectEqualStrings("6.2137119224", r.copy);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expect(!r.need_rates);
    r.build(input(&ix, "10 m to min", &.{}));
    try t.expect(r.n == 0 or r.rows[0].kind != .calc);
    var in = input(&ix, "100 usd to ttd", &.{});
    r.build(in);
    try t.expectEqualStrings("Loading rates…", r.answer);
    try t.expect(r.need_rates);
    try t.expectEqualStrings("", r.copy);
    in.rates.failed = true;
    r.build(in);
    try t.expectEqualStrings("Rates unavailable", r.answer);
    var web_row = false;
    for (r.slice()) |row| web_row = web_row or row.kind == .quicklink;
    try t.expect(web_row);
    try t.expect(r.pending);
    try t.expectEqual(@as(usize, 1), r.actionable(0));
    try t.expectEqual(Kind.quicklink, r.rows[r.actionable(0)].kind);
    var table = rates_table.Rates.parse(
        t.allocator,
        "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785}}",
    ).?;
    defer table.deinit();
    in.rates = .{ .table = &table };
    in.words = "100 USD in TTD";
    r.build(in);
    try t.expectEqualStrings("678.50 TTD", r.answer);
    try t.expectEqualStrings("678.50", r.copy);
    try t.expectEqualStrings("100 USD", r.expr);
    try t.expectEqualStrings("1 USD = 6.785 TTD · 2026-11-03", r.note);
    try t.expectEqualStrings("", r.hex);
    try t.expect(!r.pending);
    try t.expectEqual(@as(usize, 0), r.actionable(0));
    // Math after a conversion forgets its note, and copies its own answer.
    in.words = "2+2";
    r.build(in);
    try t.expectEqualStrings("", r.note);
    try t.expectEqualStrings("4", r.copy);
}

test "math around a conversion: the card shows the amount worked out and copies the answer" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{"Safari"});
    defer ix.deinit();
    var r: Results = .{};
    var in = input(&ix, "3 * 10 km to mi", &.{});
    r.build(in);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("30 km", r.expr);
    try t.expectEqualStrings("18.6411357671 mi", r.answer);
    try t.expectEqualStrings("18.6411357671", r.copy);
    in.words = "10 km to mi / 2";
    r.build(in);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expectEqualStrings("3.1068559612 mi", r.answer);
    try t.expectEqualStrings("3.1068559612", r.copy);
    in.words = "(2 + 3) * 2 km to m";
    r.build(in);
    try t.expectEqualStrings("10 km", r.expr);
    try t.expectEqualStrings("10,000 m", r.answer);
    try t.expectEqualStrings("10000", r.copy);
    // An operator with nothing after it yet keeps the answer so far.
    in.words = "10 km to mi *";
    r.build(in);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("6.2137119224 mi", r.answer);
    in.words = "2 + 3 *";
    r.build(in);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expectEqualStrings("2 + 3", r.expr);
    try t.expectEqualStrings("5", r.copy);
    in.words = "12 ttd to usd * 12";
    r.build(in);
    try t.expectEqual(Kind.calc, r.rows[0].kind);
    try t.expect(r.pending);
    try t.expect(r.need_rates);
    try t.expectEqualStrings("Loading rates…", r.answer);
    try t.expectEqualStrings("", r.copy);
    in.words = "12 ttd to usd /";
    r.build(in);
    try t.expect(r.pending);
    var table = rates_table.Rates.parse(
        t.allocator,
        "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785,\"eur\":0.86}}",
    ).?;
    defer table.deinit();
    in.rates = .{ .table = &table };
    in.words = "35 * 7 ttd to usd";
    r.build(in);
    try t.expect(!r.pending);
    try t.expectEqualStrings("245 TTD", r.expr);
    try t.expectEqualStrings("36.11 USD", r.answer);
    try t.expectEqualStrings("36.11", r.copy);
    try t.expectEqualStrings("1 TTD = 0.147384 USD · 2026-11-03", r.note);
    in.words = "12 ttd to usd * 12";
    r.build(in);
    try t.expectEqualStrings("12 TTD", r.expr);
    try t.expectEqualStrings("21.22 USD", r.answer);
    try t.expectEqualStrings("21.22", r.copy);
    try t.expectEqualStrings("1 TTD = 0.147384 USD · 2026-11-03", r.note);
    in.words = "12 ttd to usd *";
    r.build(in);
    try t.expectEqualStrings("12 TTD", r.expr);
    try t.expectEqualStrings("1.77 USD", r.answer);
    in.words = "$20 * 3 in eur";
    r.build(in);
    try t.expectEqualStrings("60 USD", r.expr);
    try t.expectEqualStrings("51.60 EUR", r.answer);
    try t.expectEqualStrings("51.60", r.copy);
    try t.expectEqualStrings("1 USD = 0.86 EUR · 2026-11-03", r.note);
}

test "system commands compete by match without taking a quicklink's row" {
    const t = std.testing;
    const every: commands.Installed = .{ .chosen = @splat(0) };
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
    var in = input(&ix, "sleep", &.{ "sleep a", "sleep b", "sleep c", "sleep d" });
    in.commands = &every;
    r.build(in);
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
    var few = try testIndex(t.allocator, &.{"Safari"});
    defer few.deinit();
    in = .{ .words = "sleep", .from = only(&few), .quicklinks = defaults, .commands = &every };
    r.build(in);
    const at = for (r.slice(), 0..) |row, i| {
        if (row.kind == .command) break i;
    } else return error.NoCommand;
    try t.expectEqualStrings("Sleep", commands.all[r.rows[at].item].name);
    try t.expectEqualStrings("Results", r.section(at).?);
    // Other commands can match too (the Mac's Sleep Display says "sleep
    // display"); the quicklinks follow them.
    const after = for (r.slice()[at..], at..) |row, i| {
        if (row.kind != .command) break i;
    } else return error.NoQuicklink;
    try t.expectEqual(Kind.quicklink, r.rows[after].kind);
    in.words = "sa";
    r.build(in);
    try t.expectEqual(Kind.app, r.rows[0].kind);
    // Not with a keyword, math, or the words for Nanolight's Settings.
    in.words = "ddg sleep";
    r.build(in);
    try t.expectEqual(@as(usize, 1), r.n);
    try t.expectEqual(Kind.quicklink, r.rows[0].kind);
    in.words = "2+2";
    r.build(in);
    try t.expectEqual(@as(usize, 1), r.n);
    // Unlisted (their program missing), they are not rows.
    const none: commands.Installed = .{};
    in.commands = &none;
    in.words = "sleep";
    r.build(in);
    for (r.slice()) |row| try t.expect(row.kind != .command);
}

test "Clipboard History competes with apps by its name's match" {
    const t = std.testing;
    var ix = try testIndex(t.allocator, &.{ "ColorSync Utility", "Archive Utility" });
    defer ix.deinit();
    var r: Results = .{};
    var in = input(&ix, "cli", &.{});
    in.clip_on = true;
    r.build(in);
    try t.expectEqual(Kind.clipboard, r.rows[0].kind);
    try t.expectEqual(search.score("cli", "Clipboard History").?.score, r.rows[0].match.score);
    try t.expectEqualStrings("Results", r.section(0).?);
    try t.expectEqual(Kind.app, r.rows[1].kind);
    try t.expect(r.section(1) == null);
    // Explicit shortcuts win even over a frequently opened app.
    try ix.add("Clip", "/Clip.app");
    var counts: launch_counts.Counts = .{};
    defer counts.deinit(t.allocator);
    counts.raise(t.allocator, "/Clip.app", 100);
    in.words = "clip";
    in.from = .{ .apps = &ix, .counts = &counts };
    r.build(in);
    try t.expectEqual(Kind.clipboard, r.rows[0].kind);
    in.clip_on = false;
    in.words = "cli";
    in.from = only(&ix);
    r.build(in);
    for (r.slice()) |row| try t.expect(row.kind != .clipboard);
}

test "math is what the card takes: trailing operators, conversions, money by the table" {
    const t = std.testing;
    for ([_][]const u8{ "2 + 3", "2 + 3 *", " 2 * 3 − ", "10 km to mi", "10 km to mi *" }) |q|
        try t.expect(isMath(q, null));
    // "2 +" is "2" so far: no operator, no card.
    for ([_][]const u8{ "", "42", "2 +", "safari", "10 km report", "10 m to min" }) |q|
        try t.expect(!isMath(q, null));
    // Money waits for a table; with one, only the codes it has convert.
    try t.expect(isMath("100 usd to xyz", null));
    var table = rates_table.Rates.parse(
        t.allocator,
        "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1}}",
    ).?;
    defer table.deinit();
    try t.expect(isMath("100 usd to usd", &table));
    try t.expect(!isMath("100 usd to xyz", &table));
}
