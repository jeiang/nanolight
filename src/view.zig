//! The launcher panel: the query, then what it finds in sections, then a
//! footer naming what Return does. Neutral glass, a hairline rim, 40-point
//! rows, the selection a grey step that slides between them. Nothing moves
//! while nothing happens: frames come from keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Index = @import("apps.zig").Index;
const results = @import("results.zig");
const files = @import("files.zig");
const files_view = @import("files_view.zig");
const answers = @import("answers.zig");
const suggest = @import("suggest.zig");
const convert = @import("convert.zig");
const text = @import("text.zig");
const settings_view = @import("settings_view.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Row = results.Row;
const settings = @import("settings.zig");
const commands = @import("commands.zig");
const clipboard_view = @import("clipboard_view.zig");

/// What the panel asks of whatever shows it (the window, or a test).
pub const Host = struct {
    ctx: *anyopaque,
    /// Opens an app's path or a URL.
    open: *const fn (ctx: *anyopaque, target: []const u8) void,
    hide: *const fn (ctx: *anyopaque) void,
    /// The panel's height changed: a window follows it.
    resize: ?*const fn (ctx: *anyopaque, h: f32) void = null,
    /// Request completions, returned through `Nanolight.answered`.
    suggest: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    files: ?*const fn (ctx: *anyopaque, query: []const u8) void = null,
    /// Shows a search's page in the panel, over `webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Settings callbacks; without them, changes are not persisted.
    settings: ?*const SettingsHost = null,
    /// A currency conversion is listed: fetch the rates unless they are
    /// fresh, and answer with `Nanolight.ratesLanded`. Without it, none are
    /// fetched.
    rates: ?*const fn (ctx: *anyopaque) void = null,
    /// Runs system command `i` (commands.zig). Without it, nothing runs.
    command: ?*const fn (ctx: *anyopaque, i: usize) void = null,
    /// Clipboard history (clipboard_view.zig). Without it the "Clipboard
    /// History" row is not listed.
    clipboard: ?*const clipboard_view.Host = null,
};

pub const width: f32 = 680;

/// The longest query kept: a longer paste is cut here, as math, ranking and
/// hashing read the whole query each frame. It is the longest file path the
/// field must hold (Tab takes a found file's whole path, `files_view.takeFile`),
/// and room for any query Google is asked.
pub const max_query_bytes = files.max_path;
comptime {
    std.debug.assert(max_query_bytes >= suggest.max_len);
    // A found path is shorter than `files.max_path`; a folder's adds a "/".
    std.debug.assert(max_query_bytes >= files.max_path);
}

/// The app's icon (icon.png, made smaller), for the panel.
pub const icon_png = @embedFile("icon-256.png");

/// The app's icon, `size` points square.
pub fn appIcon(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{ .key = "nanolight-icon", .bytes = icon_png, .max_width = size, .max_height = size, .radius = 0, .scale = 2 });
}
pub const header_h = 58;
const row_h = 40;
const calc_h = 92;
const section_h = 28;
pub const footer_h = 38;
const list_pad = 6;
/// The room a window leaves round the panel for its shadow (`Nanolight.margin`).
pub const shadow_margin: f32 = 40;
/// The tallest the panel gets: every app row, the three web rows and
/// Google's completions, under three section heads (math lists fewer), or
/// a search's page. The window is this tall.
pub const max_height: f32 = header_h + footer_h + 2 + list_pad * 2 + results.max_rows * row_h + 3 * section_h;

/// Where a search's page goes in a panel `h` tall: from `y` down from its
/// top, `h` tall, between the header and the footer, the panel's width.
pub fn webArea(h: f32) struct { y: f32, h: f32 } {
    return .{ .y = header_h + 1, .h = @max(0, h - header_h - footer_h - 2) };
}
/// Opening: snappy, a touch under critical damping.
pub const spring: motion.Spring = .{ .stiffness = 320, .damping = 32 };
const slide: motion.Spring = .{ .stiffness = 700, .damping = 52 };

pub const Palette = @import("palette.zig").Palette;
pub const palette = @import("palette.zig").palette;
pub const Theme = @import("palette.zig").Theme;

pub const Nanolight = struct {
    index: *Index,
    query: ui.TextBuffer = .{},
    res: results.Results = .{},
    sel: usize = 0,
    /// The query the rows were built for.
    built: u64 = 1,
    host: ?Host = null,
    /// Clear room round the panel in its window, for its shadow.
    margin: f32 = 0,
    /// The window fades in as it shows, the system's glass with it
    /// (panel_mac.zig): the panel has no entrance of its own (issue #9).
    window_fades: bool = false,
    /// Return sends a Google search to the browser and ⌘↩ shows it in
    /// the panel, the other way round from the default (issue #10).
    searches_out: bool = false,
    /// The panel's tint, chosen in Settings (`nanolight.theme`).
    theme: Theme = .system,
    /// Each showing gets a new one: the panel comes in again.
    shown: u32 = 0,
    copied_at: f64 = -10,
    kv: ?nanoui.kv.Store = null,
    spans: [results.max_rows][16]ui.Span = undefined,
    last_h: f32 = 0,
    /// The height kept while Google is asked (answers.zig); 0 when it isn't.
    held_h: f32 = 0,
    /// The query as it was shown: selected, so no completion after it yet.
    revealed: u64 = 0,
    /// Said in the footer in place of the name ("Updated to 0.1.3"), if set.
    note: []const u8 = "",
    /// The first-run welcome, drawn while it is active.
    onboard: ?*@import("onboard.zig").Onboard = null,
    /// Local file search is opt-in on this Mac.
    files_on: bool = false,
    found: files.List = .{},
    /// Google's completions: whether to ask, those listed, the answers.
    suggest_on: bool = true,
    /// The quicklinks listed under the apps (config.toml, or synced).
    quicklinks: []const settings.Quicklink = &settings.default_quicklinks,
    web: suggest.List = .{},
    cache: suggest.Cache = .{},
    /// Currency rates, once fetched or read from the cache, and whether
    /// fetching them failed.
    rates: ?*const convert.Rates = null,
    rates_failed: bool = false,
    /// A search's page is in the panel, for the query as it was then.
    previewing: bool = false,
    preview_q: u64 = 0,
    preview_buf: [1024]u8 = undefined,
    preview_url: []const u8 = "",
    /// Settings, drawn in the panel in place of the rows.
    settings_ui: settings_view.Settings = .{},
    /// Clipboard History, drawn in the panel in place of the rows.
    clip_ui: clipboard_view.Screen = .{},
    ext: ?*@import("raycast_view.zig").Ext = null,
    /// When the panel last went away (seconds), and how long it may be away
    /// before it reopens at the root; 0 is never.
    away_at: ?i64 = null,
    pop_after: u32 = 90,

    /// The panel went away at `now`.
    pub fn hid(s: *Nanolight, now: i64) void {
        s.away_at = now;
    }

    /// Whether the panel, shown at `now`, was away longer than `pop_after`.
    pub fn popDue(s: *Nanolight, now: i64) bool {
        const t = s.away_at orelse return false;
        s.away_at = null;
        return s.pop_after > 0 and now - t > s.pop_after;
    }

    /// The first screen again: no query, the first row, no Settings or page.
    pub fn toRoot(s: *Nanolight) void {
        s.query.clear();
        s.sel = 0;
        s.back();
        s.settings_ui.hide();
        s.clip_ui.hide();
    }

    /// The panel away: Escape, on any screen, closes it (and the screen)
    /// rather than going back to the rows.
    pub fn hidePanel(s: *Nanolight) void {
        if (s.host) |h| h.hide(h.ctx);
    }

    /// Called as it is shown: the query selected, the keys its own.
    pub fn reveal(s: *Nanolight) void {
        s.back();
        s.settings_ui.hide();
        s.shown +%= 1;
        // Suggestions follow what was opened since.
        s.built = 1;
        s.revealed = std.hash.Wyhash.hash(0, s.query.text());
        s.query.want_selection = .{ 0, s.query.text().len };
        s.query.focus();
    }

    /// The panel's height for the rows it lists.
    pub fn height(s: *const Nanolight) f32 {
        if (s.settings_ui.open) return s.settings_ui.tall();
        if (s.clip_ui.open) return clipboard_view.height;
        if (s.ext) |e| if (e.open) return e.height();
        if (s.previewing) return max_height;
        return @max(s.rowsHeight(), s.held_h);
    }

    fn rowsHeight(s: *const Nanolight) f32 {
        var h: f32 = header_h + footer_h + 1;
        if (s.res.n == 0) return h;
        h += 1 + list_pad * 2;
        for (s.res.slice(), 0..) |r, i| {
            h += if (r.kind == .calc) calc_h else row_h;
            if (s.res.section(i) != null) h += section_h;
        }
        return h;
    }

    /// The window's view: the panel, `margin` in from the window's edges.
    pub fn view(s: *Nanolight, c: *ui.Context) void {
        ui.key(c, c.print("panel-{d}", .{s.shown}));
        const entrance: motion.Target = .{ .opacity = 0, .y = -6, .scale = 0.985 };
        const f = motion.frame(c, .{ .initial = if (s.window_fades) null else entrance, .transition = .{ .spring = spring } });
        const root = ui.div(c).wFull().p(s.margin).motion(f);
        defer root.end();
        s.panel(c);
    }

    pub fn panel(s: *Nanolight, c: *ui.Context) void {
        const p = palette(c.theme.dark, s.theme);
        const shell = ui.div(c).column().w(width).rounded(18).border(p.hair).clip();
        // The system's shadow is off (its outline drew a black ring round
        // the panel): this one is soft, and outside the panel only, so the
        // glass under it stays clear.
        _ = shell.bg(p.fill).shadows(&.{
            .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
            .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
        });
        defer shell.end();
        if (s.onboard) |o| if (o.active) {
            const h = s.follow(o.height());
            const body = ui.div(c).column().wFull().h(h).clip();
            defer body.end();
            o.view(c, s, p);
            return;
        };
        if (s.settings_ui.open) return s.settings_ui.inPanel(c, s, p);
        if (s.clip_ui.open) return s.clip_ui.inPanel(c, s, p);
        // A script command's output, while it runs (raycast_view.zig).
        if (s.ext) |e| if (e.open) return e.panel(c, s, p);

        s.keys(c);
        const submitted = s.header(c, p);
        s.rebuild();
        // Typing takes the page away: the rows are for the new words.
        if (s.previewing and std.hash.Wyhash.hash(0, s.query.text()) != s.preview_q) s.back();
        if (submitted) s.activate(c);
        const h = s.follow(s.height());
        {
            const body = ui.div(c).column().wFull().h(h - header_h).clip();
            defer body.end();
            if (s.previewing) {
                // Under the page, until it draws.
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const wait = ui.div(c).wFull().h(webArea(h).h).center();
                defer wait.end();
                ui.text(c, "Searching Google…", .{ .size = 13, .color = p.sub.alpha(0.8) });
            } else if (s.res.n > 0) {
                ui.div(c).wFull().h(1).bg(p.hair).end();
                s.list(c, p);
            }
            ui.spacer(c);
            s.footer(c, p);
        }
    }

    /// The panel's height: `target`, at once, as the rows it fits are there
    /// at once (easing to it only made each key wait); a window follows it.
    pub fn follow(s: *Nanolight, target: f32) f32 {
        const h = @min(target, max_height);
        if (s.host) |host| if (host.resize) |f| if (@abs(h - s.last_h) > 0.25) {
            s.last_h = h;
            f(host.ctx, h);
        };
        return h;
    }

    /// ↓, ^N or ^J; offered before the field, so the key never edits.
    pub fn moveDown(c: *ui.Context) bool {
        const S = ui.Shortcut;
        return c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true }) or c.shortcut(.{ .key = 'j', .ctrl = true });
    }

    /// ↑, ^P or ^K.
    pub fn moveUp(c: *ui.Context) bool {
        const S = ui.Shortcut;
        return c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true }) or c.shortcut(.{ .key = 'k', .ctrl = true });
    }

    /// Arrows, ^N/^P, ^J/^K and Escape, before the field sees them.
    fn keys(s: *Nanolight, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (s.previewing) {
            if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.go(s.preview_url);
            if (c.shortcut(.{ .key = S.escape })) {
                s.back();
                s.hidePanel();
            }
            return;
        }
        // ⌘,: Settings, as on the Mac. The comma never reaches the field.
        if (c.shortcut(.{ .key = ',', .cmd = true })) return s.openSettings();
        // ⌘↩: a search in the browser rather than in the panel.
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.activateOut(c);
        // Tab takes the faint completion, as → does.
        const more = s.completion();
        if (!files_view.takeOnTab(s, c) and more.len > 0 and c.shortcut(.{ .key = S.tab })) s.take(more);
        const n = s.res.n;
        if (moveDown(c)) {
            if (n > 0) s.sel = (s.sel + 1) % n;
        }
        if (moveUp(c)) {
            if (n > 0) s.sel = (s.sel + n - 1) % n;
        }
        // ⌘1…⌘9: the row of that number, at once.
        for (0..@min(n, 9)) |k| if (c.shortcut(.{ .key = @intCast('1' + k), .cmd = true })) {
            s.sel = k;
            s.activate(c);
        };
        if (c.shortcut(.{ .key = S.escape })) s.hidePanel();
    }

    fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        ui.icon(c, "magnifyingglass", .{ .size = 19, .weight = .medium, .color = p.sub, .frame = 22 });
        s.rebuild();
        const r = ui.textField(c, &s.query, .{
            .suggestion = s.completion(),
            .bare = true,
            .size = 21,
            .width = .fill,
            .placeholder = "Search apps, do math, search the web…",
            .placeholder_color = p.sub.alpha(0.75),
            .color = p.text,
        });
        s.capQuery();
        return r.submitted;
    }

    fn capQuery(s: *Nanolight) void {
        const q = s.query.text();
        if (q.len <= max_query_bytes) return;
        s.query.set(@import("clipboard.zig").clip(q, max_query_bytes));
        std.debug.assert(s.query.text().len <= max_query_bytes);
    }

    /// What the query is the start of, drawn faintly after the caret; →
    /// or Tab takes it. The top app's name when one is listed first ("saf"
    /// → "ari"), else Google's first completion that goes on from the
    /// words ("liquid gl" → "ass"), so it is one key away, not a walk
    /// down the rows. Return never takes it: Return is the selected row.
    fn completion(s: *const Nanolight) []const u8 {
        const q = s.query.text();
        if (q.len == 0 or s.res.n == 0 or std.hash.Wyhash.hash(0, q) == s.revealed) return "";
        const r = s.res.rows[0];
        if (r.kind == .app) {
            const name = s.index.apps.items[r.app].name;
            if (name.len <= q.len or !text.utf8StartsWithFold(name, q)) return "";
            return name[q.len..];
        }
        if (r.kind != .quicklink or s.res.keyed != null or s.res.google != r.ql) return "";
        for (0..s.web.n) |i| {
            const w = s.web.get(i);
            if (w.len > q.len and text.utf8StartsWithFold(w, q)) return w[q.len..];
        }
        return "";
    }

    fn take(s: *Nanolight, more: []const u8) void {
        var buf: [suggest.max_len * 2]u8 = undefined;
        const q = s.query.text();
        if (q.len + more.len > buf.len) return;
        @memcpy(buf[0..q.len], q);
        @memcpy(buf[q.len..][0..more.len], more);
        const len = q.len + more.len;
        s.query.set(buf[0..len]);
        s.query.want_selection = .{ len, len };
    }

    /// Rebuild changed queries, asking for missing completions.
    pub fn rebuild(s: *Nanolight) void {
        const q = s.query.text();
        const h = std.hash.Wyhash.hash(0, q);
        if (h == s.built) return;
        s.built = h;
        files_view.rebuild(s);
        s.web.n = 0;
        const held = @max(s.held_h, s.rowsHeight());
        s.held_h = 0;
        s.fill();
        // Google is asked only for completions the rows would list: no card,
        // no keyword (`res.google`), and no conversion waiting on rates.
        const listed = s.res.google != null and !s.res.pending;
        const asks = listed and s.suggest_on and suggest.eligible(q);
        if (asks) if (s.host) |host| if (host.suggest) |ask| {
            // The answer, or one to fewer letters, stands in meanwhile.
            const cached = s.cache.lookup(q, &s.web);
            if (s.web.n > 0) s.fill();
            if (!cached) {
                s.held_h = held;
                ask(host.ctx, q);
            }
        };
        if (s.res.need_rates) if (s.host) |host| if (host.rates) |get| get(host.ctx);
        // The first row: an app, the answer, or the search for what was
        // typed; never a completion nobody picked (they come after it).
        s.sel = s.res.actionable(0);
    }

    pub fn fill(s: *Nanolight) void {
        var sug: [results.max_apps]u32 = undefined;
        const ns = s.index.suggestions(&sug);
        var web: [suggest.max_rows][]const u8 = undefined;
        s.res.rates = s.rates;
        s.res.rates_failed = s.rates_failed;
        s.res.clip_on = if (s.host) |h| h.clipboard != null else false;
        s.res.found = &s.found;
        s.res.build(s.query.text(), s.index, sug[0..ns], s.web.slices(&web), s.quicklinks);
    }

    /// The rates arrived (or could not be had): the conversion listed, if
    /// any, is redone. The selection stays where it was.
    pub fn ratesLanded(s: *Nanolight) void {
        const was_pending = s.res.pending;
        s.fill();
        // The card is the answer now, and the first row again; a card
        // still pending (the fetch failed) keeps the selection off it.
        if (was_pending and !s.res.pending) s.sel = 0;
        if (s.sel >= s.res.n) s.sel = s.res.actionable(0);
    }

    pub const answered = answers.answered;
    pub const unanswered = answers.unanswered;
    pub const filesAnswered = files_view.filesAnswered;

    fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().p(list_pad);
        defer box.end();
        // Where the selected row is, so the highlight can slide to it.
        var y: f32 = 0;
        var sel_y: f32 = 0;
        var sel_h: f32 = row_h;
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i) != null) y += section_h;
            const rh: f32 = if (r.kind == .calc) calc_h else row_h;
            if (i == s.sel) {
                sel_y = y;
                sel_h = rh;
            }
            y += rh;
        }
        // A new list: the highlight is there at once; moving in it, it slides.
        const fresh = c.print("{d}", .{s.built});
        const hy = motion.number(c, fresh, sel_y, .{ .spring = slide });
        const hh = motion.number(c, c.print("{d}h", .{s.built}), sel_h, .{ .spring = slide });
        ui.div(c).absolute().offset(0, hy).w(width - list_pad * 2).h(hh).rounded(10).bg(p.sel).border(p.rim).end();
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i)) |name| {
                const head = ui.div(c).row().wFull().h(section_h).px(12).pb(6).itemsEnd();
                defer head.end();
                ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
            }
            s.row(c, p, i, r);
        }
    }

    fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
        const big = r.kind == .calc;
        const d = ui.div(c).row().wFull().h(if (big) calc_h else row_h).px(10).gap(12).itemsCenter().control();
        defer d.end();
        if (d.clicked()) {
            s.sel = i;
            s.activate(c);
        }
        if (big) return s.calcCard(c, p);
        s.tile(c, p, r);
        const q = s.query.text();
        switch (r.kind) {
            .calc => unreachable,
            .app => {
                const a = s.index.apps.items[r.app];
                ui.richText(c, a.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, a.folder, .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .pane => {
                const pane = @import("settings_panes.zig").all[r.app];
                ui.richText(c, pane.name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, "System Settings", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .command => {
                ui.richText(c, commands.all[r.app].name, s.highlight(i, r, p), .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) });
                ui.text(c, "System Command", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .clipboard => {
                ui.text(c, "Clipboard History", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Text, images and files you copied", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .file => files_view.row(s, c, p, i, r),
            .settings => {
                ui.text(c, "Nanolight Settings", .{ .size = 13.5, .weight = .medium, .color = p.text });
                ui.text(c, "Shortcut, sync, updates", .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
            .suggest => {
                const w = s.web.get(r.web);
                ui.richText(c, w, s.added(i, w, p), .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis });
            },
            .quicklink => {
                const ql = s.quicklinks[r.ql];
                ui.textf(c, .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis }, "Search {s} for “{s}”", .{ ql.name, s.res.argument(q) });
                ui.text(c, results.host(ql.url), .{ .size = 12, .color = p.sub.alpha(0.8) });
            },
        }
        ui.spacer(c);
        if (i == s.sel) {
            ui.text(c, switch (r.kind) {
                .app, .file, .settings, .pane, .clipboard => "Open",
                .command => "Run",
                else => "Go",
            }, .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (i < 9) ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true }, "{s}{d}", .{ results.mod, i + 1 });
    }

    fn calcCard(s: *Nanolight, c: *ui.Context, p: Palette) void {
        @import("calc_card.zig").draw(c, p, if (s.res.expr.len > 0) s.res.expr else s.query.text(), s.res.answer, s.res.hex, s.res.note, c.time - s.copied_at < 1.4);
    }

    /// The row's picture: the app's icon, or a symbol on a quiet tile.
    fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
        // A pane: System Settings' own icon.
        const app = if (r.kind == .pane) s.index.find("System Settings") else if (r.kind == .app) r.app else null;
        if (app) |a| if (s.index.icon(a)) |png| {
            const box = ui.div(c).size(26, 26).center();
            defer box.end();
            _ = ui.image(c, .{ .key = s.index.apps.items[a].path, .bytes = png, .max_width = 26, .max_height = 26, .radius = 0, .scale = 1 });
            return;
        };
        if (r.kind == .file) return files_view.tile(s, c, p, r);
        const big = r.kind == .calc;
        const side: f32 = if (big) 34 else 26;
        const box = ui.div(c).size(side, side).rounded(if (big) 9 else 7).bg(p.tile).center();
        defer box.end();
        ui.icon(c, switch (r.kind) {
            .calc => "plus.forwardslash.minus",
            .quicklink => "globe",
            .suggest => "magnifyingglass",
            .settings => "gearshape",
            .clipboard => "doc.on.doc",
            .command => "terminal",
            else => "app.dashed",
        }, .{ .size = if (big) 16 else 13, .weight = .medium, .color = p.text });
    }

    /// The matched letters, full strength and heavier.
    pub fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
        const hits = r.match.matched();
        var n: usize = 0;
        var k: usize = 0;
        while (k < hits.len and n < s.spans[i].len) {
            var end = k + 1;
            while (end < hits.len and hits[end] == hits[end - 1] + 1) end += 1;
            s.spans[i][n] = .{ .start = hits[k], .end = @as(u32, hits[end - 1]) + 1, .color = p.text, .weight = .semibold };
            n += 1;
            k = end;
        }
        return s.spans[i][0..n];
    }

    /// A completion as a search box shows it: the words typed plain, what
    /// it adds stronger.
    fn added(s: *Nanolight, i: usize, w: []const u8, p: Palette) []const ui.Span {
        const q = std.mem.trim(u8, s.query.text(), " ");
        if (q.len == 0 or w.len <= q.len or !text.utf8StartsWithFold(w, q)) return &.{};
        s.spans[i][0] = .{ .start = @intCast(q.len), .end = @intCast(w.len), .color = p.text, .weight = .semibold };
        return s.spans[i][0..1];
    }

    fn footer(s: *Nanolight, c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        appIcon(c, 16);
        ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) }, "{s} · {d} apps", .{ if (s.note.len > 0) s.note else "Nanolight", s.index.apps.items.len });
        ui.spacer(c);
        {
            ui.key(c, "settings-gear");
            const g = ui.div(c).size(26, 26).rounded(7).center().control().hover(p.sel);
            defer g.end();
            if (g.clicked()) s.openSettings();
            ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
            ui.text(c, "Settings", .{ .size = 1, .color = p.sub.alpha(0) });
        }
        if (s.previewing) {
            ui.text(c, "Open in Browser", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
            ui.kbd(c, results.mod ++ "↩");
            ui.div(c).w(1).h(14).bg(p.hair).end();
            ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, "esc");
            return;
        }
        if (s.res.n == 0) return;
        const sel = s.res.rows[s.res.actionable(s.sel)];
        if (sel.kind == .quicklink)
            ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85), .truncate = .ellipsis }, "Search {s}", .{s.quicklinks[sel.ql].name})
        else
            ui.text(c, sel.kind.action(), .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
        ui.kbd(c, "↩");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    /// Return on the selected row.
    pub fn activate(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[s.res.actionable(s.sel)];
        switch (r.kind) {
            .calc => {
                if (s.res.copy.len == 0) return;
                c.clipboard.write(c.clipboard.ctx, s.res.copy);
                s.copied_at = c.time;
                return;
            },
            .app => {
                s.index.opened(r.app, s.kv);
                s.go(s.index.apps.items[r.app].path);
            },
            .file => s.go(s.found.entries[r.file].path()),
            .quicklink => s.searchWith(r.ql, s.res.argument(s.query.text()), !s.searches_out),
            .settings => s.openSettings(),
            .clipboard => s.openClipboard(),
            .pane => s.go(@import("settings_panes.zig").urls[r.app]),
            .command => if (s.host) |h| if (h.command) |run| run(h.ctx, r.app),
            .suggest => {
                // Its words fill the field, as a search box's would.
                s.query.set(s.web.get(r.web));
                s.searchWith(s.res.google orelse return, s.query.text(), !s.searches_out);
            },
        }
    }

    /// ⌘↩ on the selected row: a search goes where Return doesn't send it.
    fn activateOut(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[s.res.actionable(s.sel)];
        switch (r.kind) {
            .quicklink => s.searchWith(r.ql, s.res.argument(s.query.text()), s.searches_out),
            .suggest => s.searchWith(s.res.google orelse return, s.web.get(r.web), s.searches_out),
            else => s.activate(c),
        }
    }

    /// Quicklink `ql`'s page for `words`: in the panel when `in_panel` and
    /// the host can show it there, else in the browser.
    fn searchWith(s: *Nanolight, ql: u16, words: []const u8, in_panel: bool) void {
        const h = s.host orelse return;
        if (ql >= s.quicklinks.len) return;
        const u = results.url(&s.preview_buf, s.quicklinks[ql].url, words);
        const show = (if (in_panel) h.preview else null) orelse return s.go(u);
        s.preview_url = u;
        s.previewing = true;
        s.preview_q = std.hash.Wyhash.hash(0, s.query.text());
        show(h.ctx, u);
    }

    pub fn openSettings(s: *Nanolight) void {
        s.back();
        s.settings_ui.show();
    }

    /// Clipboard History in place of the rows.
    pub fn openClipboard(s: *Nanolight) void {
        s.back();
        s.clip_ui.show(s);
    }

    /// The rows again, the page gone.
    pub fn back(s: *Nanolight) void {
        if (!s.previewing) return;
        s.previewing = false;
        if (s.host) |h| if (h.preview) |f| f(h.ctx, null);
    }

    fn go(s: *Nanolight, target: []const u8) void {
        const h = s.host orelse return;
        h.open(h.ctx, target);
        // A script's row opened its screen in the panel, which stays.
        if (s.ext) |e| if (e.open) return;
        h.hide(h.ctx);
    }
};
