//! The launcher panel: the query, then what it finds in sections, then a
//! footer naming what Return does. Neutral glass, a hairline rim, 40-point
//! rows, the selection a grey step that slides between them. Nothing moves
//! while nothing happens: frames come from keys.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const results = @import("results.zig");
const settings_panes = @import("settings_panes.zig");
const web = @import("web.zig");
const platform = @import("platform.zig");
const files = @import("files.zig");
const paths = @import("paths.zig");
const suggest = @import("suggest.zig");
const search = @import("search.zig");
const clip = @import("text.zig").clip;
const settings_view = @import("settings_view.zig");
const commands = @import("commands.zig");
const clipboard_view = @import("clipboard_view.zig");
const chrome = @import("chrome.zig");
const calc_card = @import("calc_card.zig");
const pipeline = @import("pipeline.zig");
const nanolight = @import("nanolight.zig");
const Nanolight = nanolight.Nanolight;
const app_name = @import("app_facts.zig").app_name;
const Target = @import("host.zig").Target;
const palette_mod = @import("palette.zig");
const log = @import("log.zig");
const Palette = palette_mod.Palette;
const palette = palette_mod.palette;
const Row = results.Row;
const Kind = results.Kind;

comptime {
    // A card waiting on rates, and its head, take the room of the rows it
    // costs (results.zig `build`).
    std.debug.assert(calc_card.height + chrome.section.h <=
        (1 + results.pending_rows) * chrome.row_h);
    // The panel's tallest list is sized for these (chrome.max_height).
    std.debug.assert(results.max_rows == chrome.max_rows);
    std.debug.assert(results.max_heads == chrome.max_heads);
}

const slide: motion.Spring = .{ .stiffness = 700, .damping = 52 };

/// The window's view: the panel, `fit.margin` in from the window's edges.
pub fn window(s: *Nanolight, c: *ui.Context) void {
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
    panel(s, c);
}

fn panel(s: *Nanolight, c: *ui.Context) void {
    const p = palette(c.theme.dark, s.theme);
    const shell = ui.div(c).column().w(chrome.width)
        .rounded(s.theme.radius()).border(p.hair).clip();
    // The system's shadow is off (its outline drew a black ring round
    // the panel): this one is soft, and outside the panel only, so the
    // glass under it stays clear.
    _ = shell.bg(p.fill).shadows(&.{
        .{ .color = .{ .a = 0.16 }, .blur = 3, .y = 1, .knockout = true },
        .{ .color = .{ .a = 0.24 }, .blur = 28, .y = 12, .knockout = true },
    });
    defer shell.end();
    // Escape is the panel's on every screen (`Nanolight.escape`), before
    // any of them reads the keys.
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) s.escape();
    draw(s, c, p);
}

pub fn height(s: *const Nanolight) f32 {
    return switch (s.screen) {
        .rows => @max(pipeline.rowsHeight(s), s.held_h),
        .preview => chrome.max_height,
        .settings => settings_view.height(s.hasClipboard()),
        .clipboard => clipboard_view.height,
        .script => s.script_ui.height(),
        .welcome => |o| o.height(),
    };
}

/// The screen up. The launcher is as tall as the rows it builds as it
/// draws; every other screen as tall as it says (`height`).
fn draw(s: *Nanolight, c: *ui.Context, p: Palette) void {
    if (s.screen == .rows or s.screen == .preview) return launcher(s, c, p);
    const body = ui.div(c).column().wFull().h(follow(s, height(s))).clip();
    defer body.end();
    switch (s.screen) {
        .rows, .preview => unreachable,
        .settings => s.settings_ui.draw(c, s.host.settings, s.hasClipboard(), p),
        .clipboard => switch (s.clip_ui.draw(c, &s.query, s.clipboardHost(), p)) {
            .stays => {},
            .back => s.leave(.closed),
        },
        .script => s.script_ui.draw(c, p),
        .welcome => |o| if (o.draw(c, p, s.theme)) |out| switch (out) {
            .finish => |q| s.finishWelcome(q),
        },
    }
}

/// The rows, or a search's page over them.
fn launcher(s: *Nanolight, c: *ui.Context, p: Palette) void {
    // The rows for the query as it is, before anything reads them. A
    // key or an edit that changes it has the frame built again (nanoui
    // passes until nothing changes), so the rows follow it at once.
    pipeline.rebuild(s);
    keys(s, c);
    const submitted = header(s, c, p);
    // Typing takes the page away: the rows are for the new words.
    if (s.screen == .preview and s.query.hash() != s.screen.preview.q) s.leave(.closed);
    if (submitted) activate(s, c);
    const h = follow(s, height(s));
    {
        const body = ui.div(c).column().wFull().h(h - chrome.header_h).clip();
        defer body.end();
        if (s.screen == .preview) {
            // Under the page, until it draws.
            chrome.hairline(c, p);
            const wait = ui.div(c).wFull().h(chrome.webArea(h).h).center();
            defer wait.end();
            ui.text(c, "Searching Google…", p.waiting());
        } else if (s.res.n > 0) {
            chrome.hairline(c, p);
            list(s, c, p);
        }
        ui.spacer(c);
        footer(s, c, p);
    }
}

/// The panel's height: `target`, at once, as the rows it fits are there
/// at once (easing to it only made each key wait); a window follows it.
fn follow(s: *Nanolight, target: f32) f32 {
    const h = @min(target, chrome.max_height);
    if (@abs(h - s.last_h) > 0.25) {
        s.last_h = h;
        s.host.resize(s.host.ctx, h);
    }
    return h;
}

/// Arrows, ^N/^P and ^J/^K, before the field sees them.
fn keys(s: *Nanolight, c: *ui.Context) void {
    const S = ui.Shortcut;
    if (s.screen == .preview) {
        const page = s.screen.preview;
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) go(s, .{ .url = page.url });
        return;
    }
    // ⌘,: Settings, as on the Mac. The comma never reaches the field.
    if (c.shortcut(.{ .key = ',', .cmd = true })) return s.open(.settings);
    if (c.shortcut(.{ .key = S.enter, .cmd = true })) activateOut(s, c);
    // Tab takes the selected file's path while a path is typed, else
    // the faint completion, as → does.
    if (tab(s)) |what| if (c.shortcut(.{ .key = S.tab })) switch (what) {
        .file => |i| pipeline.takeFile(s, i),
        .completion => |more| take(s, more),
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
        activate(s, c);
    }
}

fn header(s: *Nanolight, c: *ui.Context, p: Palette) bool {
    const bar = ui.div(c).row().wFull().h(chrome.header_h).px(18).gap(12).itemsCenter();
    defer bar.end();
    // The theme's glyph, in its hue; System's grey lens otherwise.
    ui.icon(c, s.theme.glyph(), .{
        .size = 19,
        .weight = .medium,
        .color = s.theme.hue(c.theme.dark) orelse p.sub,
        .frame = 22,
    });
    const r = ui.textField(c, &s.query.field, .{
        .suggestion = completion(s),
        .bare = true,
        .size = s.theme.fieldSize(),
        .width = .fill,
        .placeholder = "Search apps, do math, search the web…",
        .placeholder_color = p.placeholder(),
        .color = p.text,
    });
    capQuery(s);
    return r.submitted;
}

fn capQuery(s: *Nanolight) void {
    const q = s.query.text();
    if (q.len <= nanolight.max_query_bytes) return;
    s.query.set(clip(q, nanolight.max_query_bytes));
    std.debug.assert(s.query.text().len <= nanolight.max_query_bytes);
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
    if (pipeline.tabFile(s)) |i| return .{ .file = i };
    const more = completion(s);
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

fn list(s: *Nanolight, c: *ui.Context, p: Palette) void {
    const box = ui.div(c).column().wFull().p(chrome.list_pad);
    defer box.end();
    // Where the selected row is, so the highlight can slide to it.
    var y: f32 = 0;
    var sel_y: f32 = 0;
    var sel_h: f32 = chrome.row_h;
    for (s.res.slice(), 0..) |r, i| {
        if (s.res.section(i) != null) y += chrome.section.h;
        const rh = pipeline.rowHeight(r.kind);
        if (i == s.sel) {
            sel_y = y;
            sel_h = rh;
        }
        y += rh;
    }
    // A new list: the highlight is there at once; moving in it, it slides.
    const fresh = s.list_gen;
    const hy = motion.number(c, c.print("{d}", .{fresh}), sel_y, .{ .spring = slide });
    const hh = motion.number(c, c.print("{d}h", .{fresh}), sel_h, .{ .spring = slide });
    const hw = chrome.width - chrome.list_pad * 2;
    ui.div(c).absolute().offset(0, hy).w(hw).h(hh).rounded(10).bg(p.sel).border(p.rim).end();
    for (s.res.slice(), 0..) |r, i| {
        if (s.res.section(i)) |name| chrome.sectionHead(c, p, name, chrome.section);
        row(s, c, p, i, r);
    }
}

fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const v = row_views.get(r.kind);
    const d = ui.div(c).row().wFull().h(pipeline.rowHeight(r.kind)).px(chrome.row_px)
        .gap(chrome.row_gap).itemsCenter().control();
    defer d.end();
    if (d.clicked()) {
        s.sel = i;
        activate(s, c);
    }
    if (pipeline.isCard(r.kind)) return v.body(s, c, p, i, r);
    v.picture(s, c, p, r);
    v.body(s, c, p, i, r);
    ui.spacer(c);
    if (i == s.sel) {
        const hint = results.providers.get(r.kind).hint;
        ui.text(c, hint, .{ .size = 12, .weight = .medium, .color = p.sub });
        ui.kbd(c, "↩");
    } else if (i < chrome.number_keys) ui.textf(c, p.hint(), "{s}{d}", .{ platform.mod, i + 1 });
}

/// The matched letters, full strength and heavier.
fn highlight(s: *Nanolight, i: usize, r: Row, p: Palette) []const ui.Span {
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
            if (s.note.len > 0) s.note else app_name,
            s.index.apps.items.len + s.scriptList().len,
        },
    );
    ui.spacer(c);
    {
        ui.key(c, "settings-gear");
        const g = ui.div(c)
            .size(chrome.box_size, chrome.box_size)
            .rounded(7)
            .center()
            .control()
            .hover(p.sel);
        defer g.end();
        if (g.clicked()) s.open(.settings);
        ui.icon(c, "gearshape", .{ .size = 13, .weight = .medium, .color = p.sub });
    }
    if (s.screen == .preview) {
        return chrome.footerKeys(c, p, &.{
            .{ .what = "Open in Browser", .key = platform.mod ++ "↩", .first = true },
        });
    }
    if (s.res.n == 0) return;
    const sel = s.res.rows[s.res.actionable(s.sel)];
    if (row_views.get(sel.kind).footer) |says| {
        says(s, c, p, sel);
        chrome.keySep(c, p);
        chrome.closeKey(c, p);
    } else chrome.footerKeys(c, p, &.{
        .{ .what = results.providers.get(sel.kind).action, .key = "↩", .first = true },
    });
}

/// Return on the selected row.
fn activate(s: *Nanolight, c: *ui.Context) void {
    if (s.res.n == 0) return;
    const r = s.res.rows[s.res.actionable(s.sel)];
    row_views.get(r.kind).activate(s, c, r);
}

/// ⌘↩ on the selected row: a search goes where Return doesn't send it.
fn activateOut(s: *Nanolight, c: *ui.Context) void {
    if (s.res.n == 0) return;
    const r = s.res.rows[s.res.actionable(s.sel)];
    const out = row_views.get(r.kind).out orelse return activate(s, c);
    out(s, r);
}

/// Quicklink `ql`'s page for `words`: in the panel when `in_panel` and
/// the host can show it there, else in the browser.
fn searchWith(s: *Nanolight, ql: u16, words: []const u8, in_panel: bool) void {
    const h = s.host;
    const links = s.links();
    if (ql >= links.len) return;
    const link = links[ql];
    const u = web.url(&s.preview_buf, link.url, words) orelse {
        log.warn("nanolight: the address of {s} for these words is too long", .{link.name});
        return;
    };
    if (!in_panel or h.preview == null) return go(s, .{ .url = u });
    s.open(.{ .preview = .{ .url = u, .q = s.query.hash() } });
}

fn go(s: *Nanolight, target: Target) void {
    const h = s.host;
    h.open(h.ctx, target);
    if (!target.opensScreen()) h.hide(h.ctx);
}

/// How the panel draws and acts on each kind of row; what the rows are
/// called and where they are listed is their provider's (results.zig). A
/// card (`pipeline.isCard`) is drawn by its body alone.
const RowView = struct {
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
};

const row_views = std.enums.EnumArray(Kind, RowView).init(.{
    .calc = .{ .body = calcBody, .activate = copyAnswer },
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
    .file = .{ .body = fileBody, .picture = filePicture, .activate = openFile },
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
    const l = s.scripts.?;
    iconOr(c, p, r, l.items.items[r.item].key, l.icon(r.item));
}

/// The icon the lookup worker found, else a folder's or a file's symbol.
fn filePicture(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const e = &s.found.entries[r.item];
    if (e.png.len > 0) return chrome.iconImage(c, e.path(), e.png);
    chrome.tile(c, p, if (e.folder) "folder" else results.providers.get(.file).symbol);
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
    chrome.nameDetail(c, p, a.name, highlight(s, i, r, p), a.folder, .none);
}

fn scriptBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const x = s.scriptList()[r.item];
    chrome.nameDetail(c, p, x.title, highlight(s, i, r, p), x.package, .none);
}

/// A found file: its name, the folder it is in, and which it is.
fn fileBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const e = &s.found.entries[r.item];
    var buf: [files.max_path]u8 = undefined;
    // text() borrows until layout, after this returns: a home-relative
    // parent is in `buf`, so the frame keeps a copy.
    const parent = c.print("{s}", .{paths.parent(&buf, e.path())});
    chrome.nameDetail(c, p, e.name(), highlight(s, i, r, p), parent, .ellipsis);
    ui.text(c, if (e.folder) "Folder" else "File", .{ .size = 11.5, .color = p.sub });
}

fn paneBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const name = settings_panes.all[r.item].name;
    chrome.nameDetail(c, p, name, highlight(s, i, r, p), "System Settings", .none);
}

fn commandBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const name = commands.all[r.item].name;
    chrome.nameDetail(c, p, name, highlight(s, i, r, p), "System Command", .none);
}

fn ownBody(c: *ui.Context, p: Palette, title: []const u8, detail: []const u8) void {
    ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = p.text });
    ui.text(c, detail, p.detail());
}

fn settingsBody(_: *Nanolight, c: *ui.Context, p: Palette, _: usize, _: Row) void {
    ownBody(c, p, app_name ++ " Settings", "Shortcut, sync, updates");
}

fn clipboardBody(_: *Nanolight, c: *ui.Context, p: Palette, _: usize, _: Row) void {
    ownBody(c, p, chrome.clipboard_title, "Text, images and files you copied");
}

fn completionBody(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const w = s.web.get(r.item);
    ui.richText(
        c,
        w,
        added(s, i, w, p),
        .{ .size = 13.5, .color = p.text.alpha(0.72), .truncate = .ellipsis },
    );
}

fn quicklinkBody(s: *Nanolight, c: *ui.Context, p: Palette, _: usize, r: Row) void {
    const ql = s.links()[r.item];
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
    ui.textf(c, cut, "{s} {s}", .{ action, s.links()[r.item].name });
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
    go(s, .{ .app = path });
}

fn openScript(s: *Nanolight, _: *ui.Context, r: Row) void {
    const x = s.scriptList()[r.item];
    s.opened(x.key);
    go(s, .{ .script = if (x.file == null) .folder else .{ .command = r.item } });
}

fn openFile(s: *Nanolight, _: *ui.Context, r: Row) void {
    go(s, .{ .app = s.found.entries[r.item].path() });
}

fn openPane(s: *Nanolight, _: *ui.Context, r: Row) void {
    go(s, .{ .pane = @intCast(r.item) });
}

fn runCommand(s: *Nanolight, _: *ui.Context, r: Row) void {
    const run = s.host.command orelse return;
    run.func(run.ctx, r.item);
}

fn openSettingsRow(s: *Nanolight, _: *ui.Context, _: Row) void {
    s.open(.settings);
}

fn openClipboardRow(s: *Nanolight, _: *ui.Context, _: Row) void {
    s.open(.clipboard);
}

fn searchQuicklink(s: *Nanolight, _: *ui.Context, r: Row) void {
    searchWith(s, @intCast(r.item), s.res.argument(s.query.words()), !s.searches_out);
}

fn searchQuicklinkOut(s: *Nanolight, r: Row) void {
    searchWith(s, @intCast(r.item), s.res.argument(s.query.words()), s.searches_out);
}

/// Its words fill the field, as a search box's would.
fn searchCompletion(s: *Nanolight, _: *ui.Context, r: Row) void {
    s.query.set(s.web.get(r.item));
    searchWith(s, s.res.google orelse return, s.query.text(), !s.searches_out);
}

fn searchCompletionOut(s: *Nanolight, r: Row) void {
    searchWith(s, s.res.google orelse return, s.web.get(r.item), s.searches_out);
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
