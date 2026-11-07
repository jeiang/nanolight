//! Clipboard History, in the panel in place of the rows: a search field, the
//! entries newest first (type, source app, how long ago), and what the
//! selected one holds. Return pastes it, ⌘↩ (Ctrl+Enter) only copies it,
//! ⌘⌫ (Ctrl+Backspace, or ⌘D / Ctrl+D) deletes it, Esc closes it and the
//! panel. ↑ ↓, ^N ^P and ^J ^K move. The panel hides on a paste; a paste
//! that could only copy says why in the footer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Query = @import("query.zig").Query;
const Host = @import("host.zig").Host.Clipboard;
const app_name = @import("app_facts.zig").app_name;
const clipboard = @import("clipboard.zig");
const types = @import("clipboard_types.zig");
const search = @import("search.zig");
const platform = @import("platform.zig");
const clock = @import("clock.zig");
const clip = @import("text.zig").clip;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;

const visible_rows = 7;
const detail_h: f32 = 112;
const max_found = 50;
const detail_lines = 4;
const list_h: f32 = visible_rows * chrome.row_h + chrome.list_pad * 2;
/// Header, list, detail and footer with their hairlines.
pub const height: f32 = chrome.header_h + 1 + list_h + 1 + detail_h + 1 + chrome.footer_h;

pub const Screen = struct {
    sel: usize = 0,
    /// The entries found: places in the store's list.
    found: [max_found]search.Ranked = undefined,
    n: usize = 0,
    /// What `found` was made for: the query, and the store's change count.
    built: u64 = 0,
    gen: u32 = 0,
    stale: bool = true,
    /// The selected entry as last drawn: a new copy landing above it moves
    /// the selection with it.
    sel_hash: u64 = 0,
    /// Said in the footer until the next key.
    note: []const u8 = "",

    /// The screen opens (nanolight.zig `Nanolight.open`); it uses the panel's
    /// own field, cleared, which is the rows' again once it goes.
    pub fn show(s: *Screen, q: *Query) void {
        s.sel = 0;
        s.stale = true;
        s.note = "";
        q.clear();
        q.focus();
    }

    fn refresh(s: *Screen, query: *const Query, h: *const Host) void {
        const q = query.hash();
        if (!s.stale and q == s.built and h.store.gen == s.gen) return;
        const same_query = !s.stale and q == s.built;
        if (!same_query) s.sel = 0;
        s.stale = false;
        s.built = q;
        s.gen = h.store.gen;
        s.n = h.store.find(query.text(), &s.found);
        if (same_query) for (s.found[0..s.n], 0..) |f, i|
            if (h.store.at(f.index).hash == s.sel_hash) {
                s.sel = i;
                break;
            };
        if (s.sel >= s.n) s.sel = s.n -| 1;
    }

    fn selected(s: *const Screen, h: *const Host) ?clipboard.Entry {
        if (s.sel >= s.n) return null;
        return h.store.at(s.found[s.sel].index);
    }

    /// What the screen asks of the panel as it draws: its back chevron
    /// takes it away.
    pub const Outcome = enum { stays, back };

    /// The screen, as the screen up (view.zig `draw`), searching in the
    /// panel's field `q`; `hh` null where history is not available.
    pub fn draw(s: *Screen, c: *ui.Context, q: *Query, hh: ?*const Host, p: Palette) Outcome {
        if (hh) |x| s.refresh(q, x);
        s.keys(c, q, hh);
        const head = s.header(c, q, p);
        if (hh) |x| {
            s.refresh(q, x);
            if (head.submitted) s.paste(x);
        }
        chrome.hairline(c, p);
        const rows = ui.div(c).column().wFull().h(list_h).p(chrome.list_pad).clip();
        if (hh) |x| s.list(c, p, x) else empty(c, p, "Clipboard history is not available here.");
        rows.end();
        if (hh) |x| s.sel_hash = if (s.selected(x)) |e| e.hash else 0;
        chrome.hairline(c, p);
        if (hh) |x| s.detail(c, p, x);
        s.footer(c, p, hh);
        return if (head.back) .back else .stays;
    }

    fn keys(s: *Screen, c: *ui.Context, q: *const Query, hh: ?*const Host) void {
        const S = ui.Shortcut;
        const h = hh orelse return;
        if (chrome.moveDown(c)) {
            s.note = "";
            if (s.n > 0) s.sel = (s.sel + 1) % s.n;
        }
        if (chrome.moveUp(c)) {
            s.note = "";
            if (s.n > 0) s.sel = (s.sel + s.n - 1) % s.n;
        }
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.copy(h);
        // ⌫ is 0x7f on the Mac and 0x08 on GTK; Windows offers no key for it, so ⌘D / Ctrl+D too.
        if (c.shortcut(.{ .key = 0x7f, .cmd = true }) or
            c.shortcut(.{ .key = 0x08, .cmd = true }) or
            c.shortcut(.{ .key = 'd', .cmd = true })) if (s.selected(h)) |e|
        {
            _ = h.store.remove(e.hash);
            s.note = "Deleted";
            s.refresh(q, h);
        };
    }

    fn paste(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        if (h.copy_only) return s.copy(h);
        const r = h.paste(h.ctx, e.hash);
        s.note = note(r);
    }

    fn copy(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        s.note = note(h.copy(h.ctx, e.hash));
    }

    const Head = struct { submitted: bool, back: bool };

    fn header(s: *Screen, c: *ui.Context, q: *Query, p: Palette) Head {
        const bar = ui.div(c).row().wFull().h(chrome.header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        const chevron = ui.div(c).size(26, 26).center().rounded(7).bg(p.tile).control();
        const back = chevron.clicked();
        ui.icon(c, "chevron.left", .{ .size = 13, .weight = .semibold, .color = p.sub });
        chevron.end();
        const before = q.hash();
        const r = ui.textField(c, &q.field, .{
            .bare = true,
            .size = 19,
            .width = .fill,
            .placeholder = "Search " ++ chrome.clipboard_title ++ "…",
            .placeholder_color = p.placeholder(),
            .color = p.text,
        });
        if (q.hash() != before) s.note = "";
        return .{ .submitted = r.submitted, .back = back };
    }

    fn list(s: *Screen, c: *ui.Context, p: Palette, h: *const Host) void {
        if (s.n == 0) {
            const why = h.status(h.ctx);
            const none = if (h.store.len() == 0) "Nothing copied yet." else "No matches.";
            return empty(c, p, if (why != null and h.store.len() == 0) why.? else none);
        }
        const first = if (s.sel >= visible_rows) s.sel + 1 - visible_rows else 0;
        const now = clock.now();
        for (first..@min(s.n, first + visible_rows)) |i| {
            const e = h.store.at(s.found[i].index);
            ui.key(c, c.print("clip-row-{d}", .{i}));
            const r = ui.div(c).row().wFull().h(chrome.row_h).px(chrome.row_px).gap(chrome.row_gap)
                .itemsCenter().rounded(10).control();
            defer r.end();
            if (i == s.sel) _ = r.bg(p.sel).border(p.rim);
            if (r.clicked()) {
                if (s.sel == i) s.paste(h) else s.sel = i;
            }
            const look = lookOf(e.kind);
            chrome.tile(c, p, look.symbol);
            var tb: [48]u8 = undefined;
            ui.text(
                c,
                c.print("{s}", .{look.title(&tb, e)}),
                .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis },
            );
            ui.spacer(c);
            var rb: [24]u8 = undefined;
            const app = appName(e.source);
            ui.textf(
                c,
                .{ .size = 12, .color = p.sub.alpha(0.85), .tabular = true },
                "{s}{s}{s} · {s}",
                .{
                    look.label,
                    if (app.len > 0) " · " else "",
                    app,
                    clock.ago(&rb, now - e.at),
                },
            );
        }
    }

    fn detail(s: *Screen, c: *ui.Context, p: Palette, h: *const Host) void {
        const box = ui.div(c).column().wFull().h(detail_h).px(20).py(12).gap(4).clip();
        defer box.end();
        const e = s.selected(h) orelse return;
        lookOf(e.kind).detail(c, p, e);
        ui.spacer(c);
        var rb: [24]u8 = undefined;
        ui.textf(
            c,
            .{ .size = 11.5, .color = p.sub.alpha(0.85) },
            "Copied {d} time{s} · last {s}",
            .{
                e.count,
                if (e.count == 1) "" else "s",
                clock.ago(&rb, clock.now() - e.at),
            },
        );
    }

    fn footer(s: *Screen, c: *ui.Context, p: Palette, hh: ?*const Host) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        chrome.appIcon(c, 16);
        if (s.note.len > 0)
            ui.text(
                c,
                s.note,
                .{ .size = 12, .weight = .medium, .color = p.text, .truncate = .ellipsis },
            )
        else if (hh) |h| {
            var cut = p.caption();
            cut.truncate = .ellipsis;
            ui.textf(c, cut, chrome.clipboard_title ++ " · {d}", .{h.store.len()});
        } else ui.text(c, chrome.clipboard_title, p.caption());
        ui.spacer(c);
        const h = hh orelse return;
        const copy_key = if (h.copy_only) "↩" else platform.mod ++ "↩";
        const says = [_]chrome.Key{
            .{ .what = "Paste", .key = "↩", .first = true },
            .{ .what = "Copy", .key = copy_key, .first = h.copy_only },
            .{ .what = "Delete", .key = platform.mod ++ "⌫" },
        };
        // Copy only: Return copies, and nothing pastes.
        chrome.footerKeys(c, p, says[@intFromBool(h.copy_only)..]);
    }
};

fn empty(c: *ui.Context, p: Palette, said: []const u8) void {
    const box = ui.div(c).wFull().grow().center();
    defer box.end();
    ui.text(c, said, .{ .size = 13, .color = p.sub, .wrap = true });
}

// ----- how an entry reads -----

/// The footer's word on how a paste or a copy went; empty after a paste.
pub fn note(r: types.PasteResult) []const u8 {
    return switch (r) {
        .pasted => "",
        .copied => "Copied",
        .copied_no_permission => "Copied. Allow " ++ app_name ++
            " in Privacy & Security > Accessibility to paste.",
        .copied_unsupported => "Copied. Pasting is not supported on this system yet.",
        .failed => "Could not write the clipboard.",
        .unreadable => "Could not read this entry: its saved content is gone or damaged.",
    };
}

/// "Safari" of "com.apple.Safari", "chrome" of "chrome.exe"; an app ID that
/// is not a dotted name stays as it is.
fn appName(source: []const u8) []const u8 {
    const s = if (std.ascii.endsWithIgnoreCase(source, ".exe"))
        source[0 .. source.len - 4]
    else
        source;
    if (s.len != source.len) return s;
    if (std.mem.count(
        u8,
        s,
        ".",
    ) >= 2) if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| if (i + 1 < s.len) return s[i + 1 ..];
    return s;
}

/// "12 bytes", "34 KB", "1.5 MB".
fn sizeText(buf: []u8, n: u64) []const u8 {
    const r = if (n < 1024)
        std.fmt.bufPrint(buf, "{d} bytes", .{n})
    else if (n < 1 << 20)
        std.fmt.bufPrint(buf, "{d} KB", .{n >> 10})
    else
        std.fmt.bufPrint(buf, "{d}.{d} MB", .{ n >> 20, (n & ((1 << 20) - 1)) * 10 >> 20 });
    return r catch "";
}

/// How a kind reads: its row's symbol, its word, its one line for the list,
/// and what the detail pane shows of it.
const Look = struct {
    symbol: []const u8,
    label: []const u8,
    title: *const fn (buf: []u8, e: clipboard.Entry) []const u8,
    detail: *const fn (c: *ui.Context, p: Palette, e: clipboard.Entry) void,
};

fn lookOf(k: types.Kind) Look {
    return switch (k) {
        .text => .{
            .symbol = "doc.text",
            .label = "Text",
            .title = textTitle,
            .detail = textDetail,
        },
        .image => .{
            .symbol = "photo",
            .label = "Image",
            .title = imageTitle,
            .detail = imageDetail,
        },
        .file => .{
            .symbol = "doc",
            .label = "File",
            .title = fileTitle,
            .detail = fileDetail,
        },
    };
}

/// Its first line that is not blank.
fn textTitle(_: []u8, e: clipboard.Entry) []const u8 {
    var lines = std.mem.splitScalar(u8, e.text, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (t.len > 0) return clip(t, 200);
    }
    return "";
}

fn imageTitle(buf: []u8, e: clipboard.Entry) []const u8 {
    return std.fmt.bufPrint(buf, "Image {d} × {d}", .{ e.width, e.height }) catch "Image";
}

/// The first file's name, and how many more.
fn fileTitle(buf: []u8, e: clipboard.Entry) []const u8 {
    const n = std.mem.count(u8, e.text, "\n") + 1;
    const first = e.text[0 .. std.mem.indexOfScalar(u8, e.text, '\n') orelse e.text.len];
    const name = std.fs.path.basename(first);
    if (n == 1) return name;
    return std.fmt.bufPrint(buf, "{s} and {d} more", .{ name, n - 1 }) catch name;
}

fn imageDetail(c: *ui.Context, p: Palette, e: clipboard.Entry) void {
    var sb: [24]u8 = undefined;
    ui.textf(
        c,
        .{ .size = 13, .color = p.text },
        "Image, {d} × {d} pixels, {s}",
        .{ e.width, e.height, sizeText(&sb, e.size) },
    );
}

fn textDetail(c: *ui.Context, p: Palette, e: clipboard.Entry) void {
    lineDetail(c, p, e, true);
}

fn fileDetail(c: *ui.Context, p: Palette, e: clipboard.Entry) void {
    lineDetail(c, p, e, false);
}

/// Its first `detail_lines` lines, leading blank ones skipped.
fn lineDetail(c: *ui.Context, p: Palette, e: clipboard.Entry, mono: bool) void {
    var shown: usize = 0;
    var lines = std.mem.splitScalar(u8, e.text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 and shown == 0) continue;
        if (shown == detail_lines) {
            ui.text(c, "…", .{ .size = 12.5, .color = p.sub });
            break;
        }
        ui.text(
            c,
            if (line.len == 0) " " else clip(line, 240),
            .{ .size = 12.5, .mono = mono, .color = p.text, .truncate = .ellipsis },
        );
        shown += 1;
    }
}

const testing = std.testing;

test "how entries read" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Safari", appName("com.apple.Safari"));
    try testing.expectEqualStrings("chrome", appName("chrome.exe"));
    try testing.expectEqualStrings("firefox", appName("firefox"));
    try testing.expectEqualStrings("org.gnome", appName("org.gnome"));
    const t: clipboard.Entry = .{
        .hash = 1,
        .kind = .text,
        .text = "\n  hello\nworld",
        .size = 14,
        .at = 0,
    };
    try testing.expectEqualStrings("hello", lookOf(t.kind).title(&buf, t));
    const im: clipboard.Entry = .{
        .hash = 2,
        .kind = .image,
        .text = "",
        .size = 1,
        .width = 800,
        .height = 600,
        .at = 0,
    };
    try testing.expectEqualStrings("Image 800 × 600", lookOf(im.kind).title(&buf, im));
    const f: clipboard.Entry = .{
        .hash = 3,
        .kind = .file,
        .text = "/a/b/c.txt\n/a/d.txt",
        .size = 1,
        .at = 0,
    };
    try testing.expectEqualStrings("c.txt and 1 more", lookOf(f.kind).title(&buf, f));
    try testing.expectEqualStrings("12 bytes", sizeText(&buf, 12));
    try testing.expectEqualStrings("34 KB", sizeText(&buf, 34 * 1024 + 5));
    try testing.expectEqualStrings("1.5 MB", sizeText(&buf, 3 << 19));
}
