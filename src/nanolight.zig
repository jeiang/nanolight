//! The launcher panel's state: the query, the rows it finds, the screen up
//! and the host that shows them. pipeline.zig builds the rows; view.zig
//! draws them, and the screen up in their place.
const std = @import("std");
const ui = @import("nanoui").ui;
const Index = @import("apps.zig").Index;
const results = @import("results.zig");
const launchers = @import("launchers.zig");
const script_commands = @import("script_commands.zig");
const web = @import("web.zig");
const files = @import("files.zig");
const suggest = @import("suggest.zig");
const Query = @import("query.zig").Query;
const rates = @import("rates.zig");
const rates_table = @import("rates_table.zig");
const settings_view = @import("settings_view.zig");
const key_choice = @import("keys.zig");
const clipboard_view = @import("clipboard_view.zig");
const raycast_view = @import("raycast_view.zig");
const model = @import("raycast_model.zig");
const Onboard = @import("onboard.zig").Onboard;
const screen = @import("screen.zig");
const chrome = @import("chrome.zig");
const Theme = @import("palette.zig").Theme;
const Host = @import("host.zig").Host;
const Row = results.Row;

/// The longest query kept: a longer paste is cut here, as math, ranking and
/// hashing read the whole query each frame. It is the longest file path the
/// field must hold (Tab takes a found file's whole path, `pipeline.takeFile`),
/// and room for any query Google is asked.
pub const max_query_bytes = files.max_path;
comptime {
    std.debug.assert(max_query_bytes >= suggest.max_len);
    // A found path is shorter than `files.max_path`; a folder's adds a "/".
    std.debug.assert(max_query_bytes >= files.max_path);
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
    /// How the window holds the panel (`shell.panel.setup`).
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
    /// typed (`pipeline.rebuild`), until it answers (`pipeline.answered`);
    /// 0 when it isn't.
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
    away: screen.Away = .{},

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

    pub fn scriptList(s: *const Nanolight) []script_commands.Script {
        return if (s.scripts) |l| l.items.items else &.{};
    }

    pub fn opened(s: *Nanolight, key: []const u8) void {
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
        return s.clipboardHost() != null;
    }

    pub fn clipboardHost(s: *const Nanolight) ?*const Host.Clipboard {
        const h = s.host orelse return null;
        return h.clipboard;
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
            .clipboard => s.clip_ui.show(&s.query),
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

    pub fn ratesTable(s: *const Nanolight) ?*const rates_table.Rates {
        return if (s.rates) |r| r.feed.table() else null;
    }
};
