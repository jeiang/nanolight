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
const launchers = @import("launchers.zig");
const script_commands = @import("script_commands.zig");
const settings_panes = @import("settings_panes.zig");
const web = @import("web.zig");
const platform = @import("platform.zig");
const clipboard = @import("clipboard.zig");
const files = @import("files.zig");
const files_view = @import("files_view.zig");
const answers = @import("answers.zig");
const suggest = @import("suggest.zig");
const Query = @import("query.zig").Query;
const Anchor = @import("anchor.zig").Anchor;
const rates = @import("rates.zig");
const rates_table = @import("rates_table.zig");
const search = @import("search.zig");
const clip = @import("text.zig").clip;
const settings_view = @import("settings_view.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const key_choice = @import("keys.zig");
const Row = results.Row;
const Kind = results.Kind;
const Target = results.Target;
const commands = @import("commands.zig");
const clipboard_view = @import("clipboard_view.zig");
const raycast_view = @import("raycast_view.zig");
const model = @import("raycast_model.zig");
const Onboard = @import("onboard.zig").Onboard;
const screen = @import("screen.zig");
const config = @import("config.zig");
const chrome = @import("chrome.zig");
const calc_card = @import("calc_card.zig");
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;
const palette = palette_mod.palette;
const Theme = palette_mod.Theme;

/// What the panel asks of whatever shows it (the window, or a test). The
/// window's answers share `ctx`; each feature's carries its own.
pub const Host = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, target: Target) void,
    hide: *const fn (ctx: *anyopaque) void,
    resize: ?*const fn (ctx: *anyopaque, h: f32) void = null,
    /// Shows a search's page in the panel, over `chrome.webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Asks Google about the query's words. The last ask is answered once
    /// through `Nanolight.answered`, with completions or with none; the
    /// panel keeps its room until it is.
    suggest: ?Ask = null,
    /// Looks for files for the query's words; what is found comes back
    /// through `Nanolight.filesAnswered`, if anything does.
    files: ?Ask = null,
    /// Settings' answers: Settings is drawn only with them.
    settings: ?*const SettingsHost = null,
    /// Runs system command `i` (commands.zig). Without it, nothing runs.
    command: ?Run = null,
    /// Clipboard history (clipboard_view.zig). Without it the "Clipboard
    /// History" row is not listed.
    clipboard: ?*const clipboard_view.Host = null,

    pub const Ask = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, query: []const u8) void,
    };
    pub const Run = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, i: usize) void,
        /// The commands it can run: those listed.
        installed: *const commands.Installed,
    };
};

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
comptime {
    // A card waiting on rates, and its head, take the room of the rows it
    // costs (results.zig `build`).
    std.debug.assert(calc_card.height + chrome.section.h <=
        (1 + results.pending_rows) * chrome.row_h);
}

/// The screen up: the launcher's rows, or one in their place. How long each
/// lasts, and the one way between them, is `Nanolight.open` and `leave`.
pub const Screen = union(screen.Kind) {
    rows,
    /// A search's page over the rows (`Host.preview`).
    preview: Page,
    /// Settings (`Nanolight.settings_ui`).
    settings,
    /// Clipboard History (`Nanolight.clip_ui`).
    clipboard,
    /// A script command's screen, while it runs (`Nanolight.script_ui`).
    script,
    /// The first-run welcome, which the app keeps.
    welcome: *Onboard,
};

/// A search's page: its address (in `Nanolight.preview_buf`), shown for the
/// query as it was then.
pub const Page = struct { url: []const u8, q: u64 };

const slide: motion.Spring = .{ .stiffness = 700, .damping = 52 };

pub const Nanolight = struct {
    index: *Index,
    /// The script commands found, listed among the apps (script_live.zig).
    scripts: ?*script_commands.List = null,
    /// How often each app and script command was opened, and where it is kept.
    tally: launchers.Tally = .{},
    query: Query = .{},
    res: results.Results = .{},
    sel: usize = 0,
    host: ?Host = null,
    /// How the window holds the panel (`platform.panel.setup`).
    fit: chrome.Fit = .{},
    /// Return sends a Google search to the browser and ⌘↩ shows it in
    /// the panel, the other way round from the default (issue #10).
    searches_out: bool = false,
    /// The panel's tint, chosen in Settings (`nanolight.theme`).
    theme: Theme = .system,
    /// Each showing gets a new one: the panel comes in again.
    shown: u32 = 0,
    copied_at: f64 = -10,
    spans: [results.max_rows][16]ui.Span = undefined,
    last_h: f32 = 0,
    /// The room the rows had, kept while Google is asked about the words
    /// typed (`rebuild`), until it answers (`answered`); 0 when it isn't.
    held_h: f32 = 0,
    /// The query as it was shown: selected, so no completion after it yet.
    revealed: u64 = 0,
    /// Said in the footer in place of the name ("Updated to 0.1.3"), if set.
    note: []const u8 = "",
    /// Local file search is opt-in on this Mac.
    files_on: bool = false,
    found: files.List = .{},
    /// Google's completions: whether to ask, those listed, the answers.
    suggest_on: bool = true,
    /// The quicklinks listed under the apps (config.toml, or synced).
    quicklinks: []const web.Quicklink = &web.default_quicklinks,
    web: suggest.List = .{},
    cache: suggest.Cache = .{},
    /// Currency rates and their fetching (rates.zig); without them none are fetched.
    rates: ?*rates.Live = null,
    /// A quicklink's address with the longest query, each byte escaped (3
    /// bytes), and room for the address round it; a longer one is not opened.
    preview_buf: [4 * max_query_bytes]u8 = undefined,
    screen: Screen = .rows,
    settings_ui: settings_view.Settings = .{},
    clip_ui: clipboard_view.Screen = .{},
    /// A script command's screen, drawn in place of the rows while it runs.
    script_ui: raycast_view.Ext = .{},
    away: screen.Away = .{ .pop_after = (config.Config{}).pop_to_root_seconds },

    pub fn deinit(s: *Nanolight) void {
        s.found.deinit();
        s.tally.deinit(s.index.gpa);
        s.query.deinit();
        s.script_ui.deinit();
    }

    /// The apps and script commands, and how often each was opened.
    pub fn launchable(s: *const Nanolight) launchers.Launchers {
        return .{ .apps = s.index, .scripts = s.scriptList(), .counts = &s.tally.counts };
    }

    fn scriptList(s: *const Nanolight) []script_commands.Script {
        return if (s.scripts) |l| l.items.items else &.{};
    }

    fn opened(s: *Nanolight, key: []const u8) void {
        s.tally.bump(s.index.gpa, key);
    }

    pub fn setSuggest(s: *Nanolight, on: bool) void {
        s.suggest_on = on;
        s.query.invalidate();
    }

    pub fn setFiles(s: *Nanolight, on: bool) void {
        s.files_on = on;
        s.query.invalidate();
    }

    /// Whether Clipboard History is up: a new copy is drawn at once.
    pub fn showsClipboard(s: *const Nanolight) bool {
        return s.screen == .clipboard;
    }

    /// Whether this system has clipboard history: the one answer for its
    /// row, its screen and Settings' section.
    pub fn hasClipboard(s: *const Nanolight) bool {
        const h = s.host orelse return false;
        return h.clipboard != null;
    }

    pub fn hid(s: *Nanolight, now: i64) void {
        s.away.hid(now);
    }

    /// The panel shown at `now`: at the root (no query, the first row) when
    /// it was away longer than `away.pop_after`, which is true; else as it
    /// was left, less the screens that last only while it is up
    /// (screen.zig). The query selected, the keys its own.
    pub fn show(s: *Nanolight, now: i64) bool {
        const why = s.away.shown(now);
        if (why == .popped) {
            s.query.clear();
            s.sel = 0;
        }
        s.leave(why);
        s.shown +%= 1;
        // Suggestions follow what was opened since.
        s.query.invalidate();
        s.revealed = s.query.hash();
        s.query.field.want_selection = .{ 0, s.query.text().len };
        s.query.focus();
        return why == .popped;
    }

    /// `next` in place of the screen up, which goes (`.replaced`). The
    /// screen up, opened again, stays and takes what is new (a page's
    /// address).
    pub fn open(s: *Nanolight, next: Screen) void {
        if (std.meta.activeTag(s.screen) != std.meta.activeTag(next)) s.leave(.replaced);
        s.screen = next;
        switch (next) {
            .rows, .welcome => {},
            .preview => |page| if (s.host) |h| if (h.preview) |f| f(h.ctx, page.url),
            .settings => s.settings_ui.show(),
            .clipboard => s.clip_ui.show(s),
            .script => s.query.clear(),
        }
    }

    /// The screen up goes for `why`, unless its kind lasts through it
    /// (screen.zig): the rows are up again.
    pub fn leave(s: *Nanolight, why: screen.Why) void {
        const was = s.screen;
        if (screen.lasts(was, why)) return;
        // First: a script's runner, told to end it, closes its screen
        // through `scriptTold` while this runs.
        s.screen = .rows;
        switch (was) {
            .rows => unreachable,
            .preview => if (s.host) |h| if (h.preview) |f| f(h.ctx, null),
            .settings => {
                s.settings_ui.leave();
                s.query.focus();
            },
            .clipboard => s.clearField(),
            .script => {
                s.script_ui.close();
                s.query.focus();
            },
            .welcome => |o| {
                // Another screen over it skips it, without the key it shows.
                o.end(if (why == .replaced) .drop_choice else .take_choice);
                s.clearField();
                // A first search (`Onboard.finish`) completes at once.
                s.revealed = 0;
            },
        }
    }

    /// Escape, on any screen: the screen goes, and the panel with it.
    pub fn escape(s: *Nanolight) void {
        s.leave(.closed);
        s.hidePanel();
    }

    fn hidePanel(s: *Nanolight) void {
        if (s.host) |h| h.hide(h.ctx);
    }

    /// The field the rows' again, empty: a screen that searched in it went.
    fn clearField(s: *Nanolight) void {
        s.query.clear();
        s.query.invalidate();
        s.query.focus();
    }

    /// Where a script command's runner tells its screen what to show
    /// (script_run.zig): it opens and closes as the other screens do.
    pub fn scriptScreen(s: *Nanolight) model.Screen {
        return .{ .ctx = s, .func = scriptTold };
    }

    fn scriptTold(ctx: *anyopaque, update: model.Update) void {
        const s: *Nanolight = @ptrCast(@alignCast(ctx));
        switch (update) {
            .start => |st| {
                s.open(.script);
                s.script_ui.start(s.index.gpa, st.command, st.to);
            },
            .show => |sh| s.script_ui.show(sh.arena, sh.view),
            .note => |n| s.script_ui.note(n.text, n.bad),
            // Closed from its side (its back button, a silent script),
            // or as it is left.
            .stop => {
                s.script_ui.stop();
                if (s.screen == .script) s.leave(.closed);
            },
        }
    }

    /// The rows listed, top first.
    pub fn rows(s: *const Nanolight) []const Row {
        return s.res.slice();
    }

    /// The head over row `i`, where a section starts.
    pub fn section(s: *const Nanolight, i: usize) ?[]const u8 {
        return s.res.section(i);
    }

    /// Where the selection is among `rows`; null when none are listed.
    pub fn selection(s: *const Nanolight) ?usize {
        return if (s.sel < s.res.n) s.sel else null;
    }

    pub fn selected(s: *const Nanolight) ?Row {
        const i = s.selection() orelse return null;
        return s.res.rows[i];
    }

    /// A key the host's recorder caught for Settings' shortcut.
    pub fn recorded(s: *Nanolight, r: key_choice.Recorded) void {
        s.settings_ui.took(s, r);
    }

    pub fn height(s: *const Nanolight) f32 {
        return switch (s.screen) {
            .rows => @max(s.rowsHeight(), s.held_h),
            .preview => chrome.max_height,
            .settings => settings_view.tall(s.hasClipboard()),
            .clipboard => clipboard_view.height,
            .script => s.script_ui.height(),
            .welcome => |o| o.height(),
        };
    }

    fn rowsHeight(s: *const Nanolight) f32 {
        var h: f32 = chrome.header_h + chrome.footer_h + 1;
        if (s.res.n == 0) return h;
        h += 1 + chrome.list_pad * 2;
        for (s.res.slice(), 0..) |r, i| {
            h += row_views.get(r.kind).height();
            if (s.res.section(i) != null) h += chrome.section.h;
        }
        return h;
    }

    /// The window's view: the panel, `fit.margin` in from the window's edges.
    pub fn view(s: *Nanolight, c: *ui.Context) void {
        ui.key(c, c.print("panel-{d}", .{s.shown}));
        const entrance: motion.Target = .{ .opacity = 0, .y = -6, .scale = 0.985 };
        const f = motion.frame(
            c,
            .{
                .initial = if (s.fit.window_fades) null else entrance,
                .transition = .{ .spring = chrome.spring },
            },
        );
        const root = ui.div(c).wFull().p(s.fit.margin).motion(f);
        defer root.end();
        s.panel(c);
    }

    pub fn panel(s: *Nanolight, c: *ui.Context) void {
        const p = palette(c.theme.dark, s.theme);
        const shell = ui.div(c).column().w(chrome.width).rounded(18).border(p.hair).clip();
        // The system's shadow is off (its outline drew a black ring round
        // the panel): this one is soft, and outside the panel only, so the
        // glass under it stays clear.
        _ = shell.bg(p.fill).shadows(&.{
            .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
            .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
        });
        defer shell.end();
        // Escape is the panel's on every screen (`escape`), before any of
        // them reads the keys.
        if (c.shortcut(.{ .key = ui.Shortcut.escape })) s.escape();
        s.draw(c, p);
    }

    /// The screen up. The launcher is as tall as the rows it builds as it
    /// draws; every other screen as tall as it says (`height`).
    fn draw(s: *Nanolight, c: *ui.Context, p: Palette) void {
        if (s.screen == .rows or s.screen == .preview) return s.launcher(c, p);
        const body = ui.div(c).column().wFull().h(s.follow(s.height())).clip();
        defer body.end();
        switch (s.screen) {
            .rows, .preview => unreachable,
            .settings => s.settings_ui.draw(c, s, p),
            .clipboard => s.clip_ui.draw(c, s, p),
            .script => s.script_ui.draw(c, p),
            .welcome => |o| o.draw(c, s, p),
        }
    }

    /// The rows, or a search's page over them.
    fn launcher(s: *Nanolight, c: *ui.Context, p: Palette) void {
        // The rows for the query as it is, before anything reads them. A
        // key or an edit that changes it has the frame built again (nanoui
        // passes until nothing changes), so the rows follow it at once.
        s.rebuild();
        s.keys(c);
        const submitted = s.header(c, p);
        // Typing takes the page away: the rows are for the new words.
        if (s.screen == .preview and s.query.hash() != s.screen.preview.q) s.leave(.closed);
        if (submitted) s.activate(c);
        const h = s.follow(s.height());
        {
            const body = ui.div(c).column().wFull().h(h - chrome.header_h).clip();
            defer body.end();
            if (s.screen == .preview) {
                // Under the page, until it draws.
                ui.div(c).wFull().h(1).bg(p.hair).end();
                const wait = ui.div(c).wFull().h(chrome.webArea(h).h).center();
                defer wait.end();
                ui.text(c, "Searching Google…", p.waiting());
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
        const h = @min(target, chrome.max_height);
        if (s.host) |host| if (host.resize) |f| if (@abs(h - s.last_h) > 0.25) {
            s.last_h = h;
            f(host.ctx, h);
        };
        return h;
    }

    /// Arrows, ^N/^P and ^J/^K, before the field sees them.
    fn keys(s: *Nanolight, c: *ui.Context) void {
        const S = ui.Shortcut;
        if (s.screen == .preview) {
            const page = s.screen.preview;
            if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.go(.{ .url = page.url });
            return;
        }
        // ⌘,: Settings, as on the Mac. The comma never reaches the field.
        if (c.shortcut(.{ .key = ',', .cmd = true })) return s.open(.settings);
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.activateOut(c);
        // Tab takes the selected file's path while a path is typed, else
        // the faint completion, as → does.
        if (s.tab()) |what| if (c.shortcut(.{ .key = S.tab })) switch (what) {
            .file => |i| files_view.takeFile(s, i),
            .completion => |more| s.take(more),
        };
        const n = s.res.n;
        if (chrome.moveDown(c)) {
            if (n > 0) s.sel = (s.sel + 1) % n;
        }
        if (chrome.moveUp(c)) {
            if (n > 0) s.sel = (s.sel + n - 1) % n;
        }
        if (chrome.numberKey(c, n)) |k| {
            s.sel = k;
            s.activate(c);
        }
    }

    fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(chrome.header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        ui.icon(
            c,
            "magnifyingglass",
            .{ .size = 19, .weight = .medium, .color = p.sub, .frame = 22 },
        );
        const r = ui.textField(c, &s.query.field, .{
            .suggestion = s.completion(),
            .bare = true,
            .size = 21,
            .width = .fill,
            .placeholder = "Search apps, do math, search the web…",
            .placeholder_color = p.placeholder(),
            .color = p.text,
        });
        s.capQuery();
        return r.submitted;
    }

    fn capQuery(s: *Nanolight) void {
        const q = s.query.text();
        if (q.len <= max_query_bytes) return;
        s.query.set(clip(q, max_query_bytes));
        std.debug.assert(s.query.text().len <= max_query_bytes);
    }

    /// What the query is the start of, drawn faintly after the caret; →
    /// or Tab takes it. The top app's name when one is listed first ("saf"
    /// → "ari"), else Google's first completion that goes on from the
    /// words ("liquid gl" → "ass"), so it is one key away, not a walk
    /// down the rows. Return never takes it: Return is the selected row.
    fn completion(s: *const Nanolight) []const u8 {
        const q = s.query.text();
        if (q.len == 0 or s.query.hash() == s.revealed) return "";
        const r = s.res.first() orelse return "";
        const completes = row_views.get(r.kind).completes orelse return "";
        return completes(s, r, q);
    }

    /// What Tab puts in the field: a found file's path (its place among
    /// those found), or what the field completes.
    const Tab = union(enum) { file: u32, completion: []const u8 };

    fn tab(s: *const Nanolight) ?Tab {
        if (files_view.tabFile(s)) |i| return .{ .file = i };
        const more = s.completion();
        return if (more.len > 0) .{ .completion = more } else null;
    }

    fn take(s: *Nanolight, more: []const u8) void {
        var buf: [suggest.max_len * 2]u8 = undefined;
        const q = s.query.text();
        if (q.len + more.len > buf.len) return;
        @memcpy(buf[0..q.len], q);
        @memcpy(buf[q.len..][0..more.len], more);
        const len = q.len + more.len;
        s.query.set(buf[0..len]);
        s.query.field.want_selection = .{ len, len };
    }

    /// The rows for the query, built once each time it changes or is
    /// invalidated (`Query.changed`); Google is asked for completions not
    /// in hand. `launcher` calls it once a frame, before anything reads them.
    pub fn rebuild(s: *Nanolight) void {
        if (!s.query.changed()) return;
        files_view.rebuild(s);
        s.web.n = 0;
        const held = @max(s.held_h, s.rowsHeight());
        s.held_h = 0;
        s.fill();
        const words = s.query.words();
        // Google is asked only for completions the rows would list: no card,
        // no keyword (`res.google`), and no conversion waiting on rates.
        const listed = s.res.google != null and !s.res.pending;
        const asks = listed and s.suggest_on and suggest.eligible(words);
        if (asks) if (s.host) |host| if (host.suggest) |ask| {
            // The answer, or one to fewer letters, stands in meanwhile.
            const cached = s.cache.lookup(words, &s.web);
            if (s.web.n > 0) s.fill();
            if (!cached) {
                s.held_h = held;
                ask.func(ask.ctx, words);
            }
        };
        // The first row: an app, the answer, or the search for what was
        // typed; never a completion nobody picked (they come after it).
        s.sel = s.res.actionable(0);
    }

    /// What lands for the query a moment after its rows.
    pub const Landed = union(enum) {
        completions: *const suggest.List,
        /// Files found for the words, moved into `found`.
        files: *files.List,
        /// The rates (or that they could not be had), in `rates` already.
        rates,
    };

    /// The rows again for the same query with what `landed`: the
    /// selection stays on the row it was on, wherever that row now is
    /// (anchor.zig), so Return a moment after typing does what the panel
    /// showed. A card that was waiting on rates and is the answer now is
    /// first again, and selected.
    pub fn refill(s: *Nanolight, landed: Landed) void {
        const was: Anchor = .of(s);
        const was_pending = s.res.pending;
        switch (landed) {
            .completions => |said| s.web = said.*,
            .files => |found| s.found.replace(found),
            .rates => {},
        }
        s.fill();
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

    pub fn ratesTable(s: *const Nanolight) ?*const rates_table.Rates {
        return if (s.rates) |r| r.feed.table() else null;
    }

    pub const answered = answers.answered;
    pub const wants = answers.wants;
    pub const filesAnswered = files_view.filesAnswered;

    fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const box = ui.div(c).column().wFull().p(chrome.list_pad);
        defer box.end();
        // Where the selected row is, so the highlight can slide to it.
        var y: f32 = 0;
        var sel_y: f32 = 0;
        var sel_h: f32 = chrome.row_h;
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i) != null) y += chrome.section.h;
            const rh = row_views.get(r.kind).height();
            if (i == s.sel) {
                sel_y = y;
                sel_h = rh;
            }
            y += rh;
        }
        // A new list: the highlight is there at once; moving in it, it slides.
        const fresh = s.query.built;
        const hy = motion.number(c, c.print("{d}", .{fresh}), sel_y, .{ .spring = slide });
        const hh = motion.number(c, c.print("{d}h", .{fresh}), sel_h, .{ .spring = slide });
        const hw = chrome.width - chrome.list_pad * 2;
        ui.div(c).absolute().offset(0, hy).w(hw).h(hh).rounded(10).bg(p.sel).border(p.rim).end();
        for (s.res.slice(), 0..) |r, i| {
            if (s.res.section(i)) |name| chrome.sectionHead(c, p, name, chrome.section);
            s.row(c, p, i, r);
        }
    }

    fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
        const v = row_views.get(r.kind);
        const d = ui.div(c).row().wFull().h(v.height()).px(chrome.row_px).gap(chrome.row_gap)
            .itemsCenter().control();
        defer d.end();
        if (d.clicked()) {
            s.sel = i;
            s.activate(c);
        }
        if (v.card) return v.body(s, c, p, i, r);
        v.picture(s, c, p, r);
        v.body(s, c, p, i, r);
        ui.spacer(c);
        if (i == s.sel) {
            const hint = results.providers.get(r.kind).hint;
            ui.text(c, hint, .{ .size = 12, .weight = .medium, .color = p.sub });
            ui.kbd(c, "↩");
        } else if (i < 9) ui.textf(c, p.hint(), "{s}{d}", .{ platform.mod, i + 1 });
    }

    /// The matched letters, full strength and heavier.
    pub fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
        const hits = r.match.matched();
        var n: usize = 0;
        var k: usize = 0;
        while (k < hits.len and n < s.spans[i].len) {
            var end = k + 1;
            while (end < hits.len and hits[end] == hits[end - 1] + 1) end += 1;
            s.spans[i][n] = .{
                .start = hits[k],
                .end = @as(u32, hits[end - 1]) + 1,
                .color = p.text,
                .weight = .semibold,
            };
            n += 1;
            k = end;
        }
        return s.spans[i][0..n];
    }

    /// A completion as a search box shows it: the words typed plain, what
    /// it adds stronger.
    fn added(s: *Nanolight, i: usize, w: []const u8, p: Palette) []const ui.Span {
        const q = s.query.words();
        if (q.len == 0 or w.len <= q.len or !search.startsWithFold(w, q)) return &.{};
        s.spans[i][0] = .{
            .start = @intCast(q.len),
            .end = @intCast(w.len),
            .color = p.text,
            .weight = .semibold,
        };
        return s.spans[i][0..1];
    }

    fn footer(s: *Nanolight, c: *ui.Context, p: Palette) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        chrome.appIcon(c, 16);
        ui.textf(
            c,
            p.caption(),
            "{s} · {d} apps",
            .{
                if (s.note.len > 0) s.note else "Nanolight",
                s.index.apps.items.len + s.scriptList().len,
            },
        );
        ui.spacer(c);
        {
            ui.key(c, "settings-gear");
            const g = ui.div(c).size(26, 26).rounded(7).center().control().hover(p.sel);
            defer g.end();
            if (g.clicked()) s.open(.settings);
            ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
        }
        if (s.screen == .preview) {
            chrome.footerKey(c, p, "Open in Browser", platform.mod ++ "↩", true);
            chrome.keySep(c, p);
            chrome.footerKey(c, p, "Close", "esc", false);
            return;
        }
        if (s.res.n == 0) return;
        const sel = s.res.rows[s.res.actionable(s.sel)];
        if (row_views.get(sel.kind).footer) |says| {
            says(s, c, p, sel);
        } else chrome.footerKey(c, p, results.providers.get(sel.kind).action, "↩", true);
        chrome.keySep(c, p);
        chrome.footerKey(c, p, "Close", "esc", false);
    }

    /// Return on the selected row.
    pub fn activate(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[s.res.actionable(s.sel)];
        row_views.get(r.kind).activate(s, c, r);
    }

    /// ⌘↩ on the selected row: a search goes where Return doesn't send it.
    fn activateOut(s: *Nanolight, c: *ui.Context) void {
        if (s.res.n == 0) return;
        const r = s.res.rows[s.res.actionable(s.sel)];
        const out = row_views.get(r.kind).out orelse return s.activate(c);
        out(s, r);
    }

    /// Quicklink `ql`'s page for `words`: in the panel when `in_panel` and
    /// the host can show it there, else in the browser.
    fn searchWith(s: *Nanolight, ql: u16, words: []const u8, in_panel: bool) void {
        const h = s.host orelse return;
        if (ql >= s.quicklinks.len) return;
        const link = s.quicklinks[ql];
        const u = web.url(&s.preview_buf, link.url, words) orelse {
            std.log.warn("nanolight: the address of {s} for these words is too long", .{link.name});
            return;
        };
        if (!in_panel or h.preview == null) return s.go(.{ .url = u });
        s.open(.{ .preview = .{ .url = u, .q = s.query.hash() } });
    }

    fn go(s: *Nanolight, target: Target) void {
        const h = s.host orelse return;
        h.open(h.ctx, target);
        if (!target.opensScreen()) h.hide(h.ctx);
    }
};

/// How the panel draws and acts on each kind of row; what the rows are
/// called and where they are listed is their provider's (results.zig).
const RowView = struct {
    /// The answer's card (calc_card.zig): taller, without a picture or a hint.
    card: bool = false,
    /// Its name and what it is, after its picture.
    body: *const fn (s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void,
    picture: *const fn (s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void = symbolTile,
    /// Return on it.
    activate: *const fn (s: *Nanolight, c: *ui.Context, r: Row) void,
    /// ⌘↩ on it, where that differs from Return.
    out: ?*const fn (s: *Nanolight, r: Row) void = null,
    /// What the footer says Return does, where its provider's words need more.
    footer: ?*const fn (s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void = null,
    /// What the field finishes faintly when this row is first; empty for none.
    completes: ?*const fn (s: *const Nanolight, r: Row, q: []const u8) []const u8 = null,

    fn height(v: RowView) f32 {
        return if (v.card) calc_card.height else chrome.row_h;
    }
};

const row_views = std.enums.EnumArray(Kind, RowView).init(.{
    .calc = .{ .card = true, .body = calcBody, .activate = copyAnswer },
    .app = .{
        .body = appBody,
        .picture = appPicture,
        .activate = openApp,
        .completes = appCompletes,
    },
    .script = .{
        .body = scriptBody,
        .picture = scriptPicture,
        .activate = openScript,
        .completes = scriptCompletes,
    },
    .file = .{ .body = files_view.row, .picture = files_view.tile, .activate = openFile },
    .pane = .{ .body = paneBody, .picture = panePicture, .activate = openPane },
    .command = .{ .body = commandBody, .activate = runCommand },
    .settings = .{ .body = settingsBody, .activate = openSettingsRow },
    .clipboard = .{ .body = clipboardBody, .activate = openClipboardRow },
    .quicklink = .{
        .body = quicklinkBody,
        .activate = searchQuicklink,
        .out = searchQuicklinkOut,
        .footer = quicklinkFooter,
        .completes = quicklinkCompletes,
    },
    .suggest = .{
        .body = completionBody,
        .activate = searchCompletion,
        .out = searchCompletionOut,
    },
});

fn symbolTile(_: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    chrome.tile(c, p, results.providers.get(r.kind).symbol);
}

/// `png` named by `key`, or the provider's symbol when there is none.
fn iconOr(c: *ui.Context, p: Palette, r: Row, key: []const u8, png: ?[]const u8) void {
    const bytes = png orelse return chrome.tile(c, p, results.providers.get(r.kind).symbol);
    chrome.iconImage(c, key, bytes);
}

fn appPicture(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    iconOr(c, p, r, s.index.apps.items[r.item].path, s.index.icon(r.item));
}

fn scriptPicture(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const list = s.scripts.?;
    iconOr(c, p, r, list.items.items[r.item].key, list.icon(r.item));
}

/// System Settings' own icon.
fn panePicture(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const app = s.index.findPath(settings_panes.app) orelse return symbolTile(s, c, p, r);
    iconOr(c, p, r, settings_panes.app, s.index.icon(app));
}

fn calcBody(s: *Nanolight, c: *ui.Context, p: Palette, _: usize, _: Row) void {
    calc_card.draw(
        c,
        p,
        if (s.res.expr.len > 0) s.res.expr else s.query.text(),
        s.res.answer,
        s.res.hex,
        s.res.note,
        c.time - s.copied_at < 1.4,
    );
}

fn appBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const a = s.index.apps.items[r.item];
    chrome.nameDetail(c, p, a.name, s.highlight(i, r, p), a.folder, .none);
}

fn scriptBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const x = s.scriptList()[r.item];
    chrome.nameDetail(c, p, x.title, s.highlight(i, r, p), x.package, .none);
}

fn paneBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const name = settings_panes.all[r.item].name;
    chrome.nameDetail(c, p, name, s.highlight(i, r, p), "System Settings", .none);
}

fn commandBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const name = commands.all[r.item].name;
    chrome.nameDetail(c, p, name, s.highlight(i, r, p), "System Command", .none);
}

fn ownBody(c: *ui.Context, p: Palette, title: []const u8, detail: []const u8) void {
    ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = p.text });
    ui.text(c, detail, p.detail());
}

fn settingsBody(_: *Nanolight, c: *ui.Context, p: Palette, _: usize, _: Row) void {
    ownBody(c, p, "Nanolight Settings", "Shortcut, sync, updates");
}

fn clipboardBody(_: *Nanolight, c: *ui.Context, p: Palette, _: usize, _: Row) void {
    ownBody(c, p, clipboard.title, "Text, images and files you copied");
}

fn completionBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const w = s.web.get(r.item);
    ui.richText(
        c,
        w,
        s.added(i, w, p),
        .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis },
    );
}

fn quicklinkBody(s: *Nanolight, c: *ui.Context, p: Palette, _: usize, r: Row) void {
    const ql = s.quicklinks[r.item];
    ui.textf(
        c,
        .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis },
        "Search {s} for “{s}”",
        .{ ql.name, s.res.argument(s.query.words()) },
    );
    ui.text(c, web.host(ql.url), p.detail());
}

/// "Search Google": the quicklink by name.
fn quicklinkFooter(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    var cut = p.action();
    cut.truncate = .ellipsis;
    const action = results.providers.get(.quicklink).action;
    ui.textf(c, cut, "{s} {s}", .{ action, s.quicklinks[r.item].name });
    ui.kbd(c, "↩");
}

fn copyAnswer(s: *Nanolight, c: *ui.Context, _: Row) void {
    if (s.res.copy.len == 0) return;
    c.clipboard.write(c.clipboard.ctx, s.res.copy);
    s.copied_at = c.time;
}

fn openApp(s: *Nanolight, _: *ui.Context, r: Row) void {
    const path = s.index.apps.items[r.item].path;
    s.opened(path);
    s.go(.{ .app = path });
}

fn openScript(s: *Nanolight, _: *ui.Context, r: Row) void {
    const x = s.scriptList()[r.item];
    s.opened(x.key);
    s.go(if (x.file == null) .folder else .{ .script = r.item });
}

fn openFile(s: *Nanolight, _: *ui.Context, r: Row) void {
    s.go(.{ .app = s.found.entries[r.item].path() });
}

fn openPane(s: *Nanolight, _: *ui.Context, r: Row) void {
    s.go(.{ .pane = @intCast(r.item) });
}

fn runCommand(s: *Nanolight, _: *ui.Context, r: Row) void {
    const h = s.host orelse return;
    const run = h.command orelse return;
    run.func(run.ctx, r.item);
}

fn openSettingsRow(s: *Nanolight, _: *ui.Context, _: Row) void {
    s.open(.settings);
}

fn openClipboardRow(s: *Nanolight, _: *ui.Context, _: Row) void {
    s.open(.clipboard);
}

fn searchQuicklink(s: *Nanolight, _: *ui.Context, r: Row) void {
    s.searchWith(@intCast(r.item), s.res.argument(s.query.words()), !s.searches_out);
}

fn searchQuicklinkOut(s: *Nanolight, r: Row) void {
    s.searchWith(@intCast(r.item), s.res.argument(s.query.words()), s.searches_out);
}

/// Its words fill the field, as a search box's would.
fn searchCompletion(s: *Nanolight, _: *ui.Context, r: Row) void {
    s.query.set(s.web.get(r.item));
    s.searchWith(s.res.google orelse return, s.query.text(), !s.searches_out);
}

fn searchCompletionOut(s: *Nanolight, r: Row) void {
    s.searchWith(s.res.google orelse return, s.web.get(r.item), s.searches_out);
}

/// What `name` adds to `q`, when `q` starts it.
fn rest(name: []const u8, q: []const u8) []const u8 {
    if (name.len <= q.len or !search.startsWithFold(name, q)) return "";
    return name[q.len..];
}

fn appCompletes(s: *const Nanolight, r: Row, q: []const u8) []const u8 {
    return rest(s.index.apps.items[r.item].name, q);
}

fn scriptCompletes(s: *const Nanolight, r: Row, q: []const u8) []const u8 {
    return rest(s.scriptList()[r.item].title, q);
}

/// Google's first completion that goes on from the words, under its quicklink.
fn quicklinkCompletes(s: *const Nanolight, r: Row, q: []const u8) []const u8 {
    const google = s.res.google orelse return "";
    if (google != r.item) return "";
    for (0..s.web.n) |i| {
        const more = rest(s.web.get(i), q);
        if (more.len > 0) return more;
    }
    return "";
}
