//! The query's rows: built once each time it changes, then filled again as
//! what was asked for lands (Google's completions, files found, the
//! rates), the selection held on its row. Google's rows clear with each key
//! and come back a moment later (`suggest.pause_ms`, then the network), so
//! the panel keeps their room until they do (`Nanolight.held_h`): its height
//! changes once the rows are known, not down and up with every key.
const std = @import("std");
const files = @import("files.zig");
const paths = @import("paths.zig");
const spotlight = @import("spotlight.zig");
const platform = @import("platform.zig");
const suggest = @import("suggest.zig");
const results = @import("results.zig");
const rates = @import("rates.zig");
const rates_table = @import("rates_table.zig");
const chrome = @import("chrome.zig");
const calc_card = @import("calc_card.zig");
const Nanolight = @import("nanolight.zig").Nanolight;
const Row = results.Row;
const Kind = results.Kind;
const assert = std.debug.assert;

/// The rows for the query, built once each time it changes or is
/// invalidated (`Query.changed`); Google is asked for completions not
/// in hand. The launcher calls it once a frame, before anything reads them.
pub fn rebuild(s: *Nanolight) void {
    if (!s.query.changed()) return;
    findFiles(s);
    s.web.n = 0;
    const held = @max(s.held_h, rowsHeight(s));
    s.held_h = 0;
    fill(s);
    const words = s.query.words();
    // Google is asked only for completions the rows would list: no card,
    // no keyword (`res.google`), and no conversion waiting on rates.
    const listed = s.res.google != null and !s.res.pending;
    const asks = listed and s.suggest_on and suggest.eligible(words);
    if (asks) if (s.host) |host| if (host.suggest) |ask| {
        // The answer, or one to fewer letters, stands in meanwhile.
        const cached = s.cache.lookup(words, &s.web);
        if (s.web.n > 0) fill(s);
        if (!cached) {
            s.held_h = held;
            ask.func(ask.ctx, words);
        }
    };
    // The first row: an app, the answer, or the search for what was
    // typed; never a completion nobody picked (they come after it).
    s.sel = s.res.actionable(0);
}

/// Retain matching rows while the worker answers the new query. A query
/// the answer card takes is not searched for.
fn findFiles(s: *Nanolight) void {
    const q = s.query.words();
    if (platform.files and s.files_on and
        (paths.isPath(q) or (spotlight.eligible(q) and !results.isMath(q, s.ratesTable()))))
    {
        s.found.filter(q);
        if (s.host) |host| if (host.files) |ask| ask.func(ask.ctx, q);
    } else s.found.deinit();
}

/// What lands for the query a moment after its rows.
pub const Landed = union(enum) {
    completions: *const suggest.List,
    /// Files found for the words, moved into `found`.
    files: *files.List,
    /// The rates (or that they could not be had), in `rates` already.
    rates,
};

/// The rows again for the same query with what `landed`: the selection
/// stays on the row it was on, wherever that row now is (`Anchor`), so
/// Return a moment after typing does what the panel showed. A card that
/// was waiting on rates and is the answer now is first again, and selected.
pub fn refill(s: *Nanolight, landed: Landed) void {
    const was: Anchor = .of(s);
    const was_pending = s.res.pending;
    switch (landed) {
        .completions => |said| s.web = said.*,
        .files => |found| s.found.replace(found),
        .rates => {},
    }
    fill(s);
    s.sel = if (was_pending and !s.res.pending) 0 else was.find(s) orelse 0;
}

fn fill(s: *Nanolight) void {
    rates.fill(s.rates, s, buildRows);
}

/// Lists the query's rows with `status`; true when they list a currency
/// conversion, which asks for the rates.
fn buildRows(s: *Nanolight, status: rates_table.Status) bool {
    var said: [suggest.max_rows][]const u8 = undefined;
    s.res.build(.{
        .words = s.query.words(),
        .from = s.launchable(),
        .quicklinks = s.quicklinks,
        .completions = s.web.slices(&said),
        .rates = status,
        .clip_on = s.hasClipboard(),
        .found = &s.found,
        .commands = if (s.host) |h| if (h.command) |run| run.installed else null else null,
    });
    return s.res.need_rates;
}

/// Google's answer to `typed` (the last words `Host.suggest` was asked
/// about): its completions, or null when none are coming (it failed, or was
/// never sent). The room kept for them goes; completions are kept, and
/// listed if `typed` is still what is typed (`refill`). An answer counts
/// for the same words in any case or spacing, as the cache keeps them
/// (`suggest.same`).
pub fn answered(s: *Nanolight, typed: []const u8, said: ?*const suggest.List) void {
    if (suggest.same(typed, s.query.words())) s.held_h = 0;
    // Turned off while it was on its way: nothing of it is kept or listed.
    if (!s.suggest_on) return;
    const list = said orelse return;
    s.cache.put(typed, list);
    if (!wants(s, typed)) return;
    refill(s, .{ .completions = list });
}

/// Whether an answer to `typed` would be listed: completions are on, and
/// `typed` is still what is typed. Google is asked only while it is.
pub fn wants(s: *const Nanolight, typed: []const u8) bool {
    return s.suggest_on and suggest.same(typed, s.query.words());
}

/// A Spotlight answer lands only for the words still in the field.
pub fn filesAnswered(s: *Nanolight, typed: []const u8, found: *files.List) void {
    if (!s.files_on or !std.mem.eql(u8, typed, s.query.words())) return;
    refill(s, .{ .files = found });
}

/// The file selected while a path is typed, its place among those found:
/// Tab takes its path (`takeFile`) rather than the faint completion.
pub fn tabFile(s: *const Nanolight) ?u32 {
    const r = s.selected() orelse return null;
    if (r.kind != .file or !paths.isPath(s.query.words())) return null;
    return r.item;
}

/// Found file `i`'s whole path in the field, a folder's with its "/".
pub fn takeFile(s: *Nanolight, i: usize) void {
    const e = &s.found.entries[i];
    var buf: [files.max_path + 1]u8 = undefined;
    const path = e.path();
    const text = std.fmt.bufPrint(
        &buf,
        "{s}{s}",
        .{ path, if (e.folder and !std.mem.endsWith(u8, path, "/")) "/" else "" },
    ) catch return;
    s.query.set(text);
    s.query.field.want_selection = .{ text.len, text.len };
}

/// How tall the rows listed are, with their heads, the field and the footer.
pub fn rowsHeight(s: *const Nanolight) f32 {
    var h: f32 = chrome.header_h + chrome.footer_h + 1;
    if (s.res.n == 0) return h;
    h += 1 + chrome.list_pad * 2;
    for (s.res.slice(), 0..) |r, i| {
        h += rowHeight(r.kind);
        if (s.res.section(i) != null) h += chrome.section.h;
    }
    return h;
}

/// A row's height: the answer's card is taller (calc_card.zig).
pub fn rowHeight(kind: Kind) f32 {
    return if (isCard(kind)) calc_card.height else chrome.row_h;
}

pub fn isCard(kind: Kind) bool {
    return results.providers.get(kind).section == .card;
}

/// The selected row, held across a refill of the list (completions, files
/// or the rates landing): the selection stays on the same row wherever that
/// row now is. A row is the same row by what its provider says
/// (`results.Identity`): apps, panes, commands and quicklinks by their
/// place in their lists; a file by its path and a completion by its words,
/// since their places move with each answer.
const Anchor = struct {
    row: ?Row = null,
    /// The file's path or the completion's text.
    text: [max_text]u8 = undefined,
    len: usize = 0,

    const max_text = @max(files.max_path, suggest.max_len);

    /// The row selected in `s`, if any.
    fn of(s: *const Nanolight) Anchor {
        var a: Anchor = .{};
        const r = s.selected() orelse return a;
        a.row = r;
        const text = textOf(s, r);
        assert(text.len <= max_text);
        @memcpy(a.text[0..text.len], text);
        a.len = text.len;
        return a;
    }

    /// Where the row is in `s` now, or null when it is no longer listed.
    fn find(a: *const Anchor, s: *const Nanolight) ?usize {
        const r = a.row orelse return null;
        const text = a.text[0..a.len];
        for (s.res.slice(), 0..) |now, i| {
            if (now.kind != r.kind) continue;
            const identity = results.providers.get(r.kind).identity;
            const same = switch (identity) {
                .item => now.item == r.item,
                .path => std.mem.eql(u8, textOf(s, now), text),
                .words => suggest.same(textOf(s, now), text),
                .kind => true,
            };
            if (same) return i;
        }
        return null;
    }
};

/// The file's path or the completion's words; empty for the rest.
pub fn textOf(s: *const Nanolight, r: Row) []const u8 {
    const identity = results.providers.get(r.kind).identity;
    return switch (identity) {
        .path => s.found.entries[r.item].path(),
        .words => s.web.get(r.item),
        .item, .kind => "",
    };
}
