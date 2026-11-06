//! Clipboard History, in the panel in place of the rows: a search field, the
//! entries newest first (type, source app, how long ago), and what the
//! selected one holds. Return pastes it, ⌘↩ (Ctrl+Enter) only copies it,
//! ⌘⌫ (Ctrl+Backspace, or ⌘D / Ctrl+D) deletes it, Esc closes it and the
//! panel. ↑ ↓, ^N ^P and ^J ^K move. The panel hides on a paste; a paste
//! that could only copy says why in the footer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const panel = @import("view.zig");
const clipboard = @import("clipboard.zig");
const search = @import("search.zig");
const results = @import("results.zig");
const account = @import("account.zig");
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;

/// What the screen asks of the app. Without it the screen says history is
/// not available (tests draw it so).
pub const Host = struct {
    ctx: *anyopaque,
    store: *clipboard.Store,
    /// Why entries are not being recorded now (this system cannot, or it
    /// is switched off); null while they are.
    status: *const fn (ctx: *anyopaque) ?[]const u8,
    /// Return: writes the entry and pastes it where it can.
    paste: *const fn (ctx: *anyopaque, hash: u64) clipboard.PasteResult,
    /// ⌘↩: writes the entry only (Return too, with `paste_plain_text` off): `.copied`,
    /// `.failed` or `.unreadable`.
    copy: *const fn (ctx: *anyopaque, hash: u64) clipboard.PasteResult,
};

const visible_rows = 7;
const detail_h: f32 = 112;
const max_found = 50;
const detail_lines = 4;
const list_h: f32 = visible_rows * chrome.row_h + chrome.list_pad * 2;
/// Header, list, detail and footer with their hairlines.
pub const height: f32 = chrome.header_h + 1 + list_h + 1 + detail_h + 1 + chrome.footer_h;

pub const Screen = struct {
    open: bool = false,
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

    /// The screen opens; it uses the panel's own field, cleared.
    pub fn show(s: *Screen, n: *panel.Nanolight) void {
        s.open = true;
        s.sel = 0;
        s.stale = true;
        s.note = "";
        n.query.clear();
        n.query.focus();
    }

    pub fn hide(s: *Screen) void {
        s.open = false;
    }

    /// Back to the rows, the field theirs again.
    fn back(s: *Screen, n: *panel.Nanolight) void {
        s.hide();
        n.query.clear();
        n.query.focus();
        n.built = 1;
    }

    fn host(n: *const panel.Nanolight) ?*const Host {
        const h = n.host orelse return null;
        return h.clipboard;
    }

    fn refresh(s: *Screen, n: *panel.Nanolight, h: *const Host) void {
        const q = std.hash.Wyhash.hash(0, n.query.text());
        if (!s.stale and q == s.built and h.store.gen == s.gen) return;
        const same_query = !s.stale and q == s.built;
        if (!same_query) s.sel = 0;
        s.stale = false;
        s.built = q;
        s.gen = h.store.gen;
        s.n = h.store.find(n.query.text(), &s.found);
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

    /// The screen in place of the rows, the panel's height following it.
    pub fn inPanel(s: *Screen, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        const h = n.follow(height);
        const box = ui.div(c).column().wFull().h(h).clip();
        defer box.end();
        const hh = host(n);
        if (hh) |x| s.refresh(n, x);
        s.keys(c, n, hh);
        const submitted = s.header(c, n, p);
        if (hh) |x| {
            s.refresh(n, x);
            if (submitted) s.paste(x);
        }
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const rows = ui.div(c).column().wFull().h(list_h).p(chrome.list_pad).clip();
        if (hh) |x| s.list(c, p, x) else empty(c, p, "Clipboard history is not available here.");
        rows.end();
        if (hh) |x| s.sel_hash = if (s.selected(x)) |e| e.hash else 0;
        ui.div(c).wFull().h(1).bg(p.hair).end();
        if (hh) |x| s.detail(c, p, x);
        s.footer(c, p, hh);
    }

    fn keys(s: *Screen, c: *ui.Context, n: *panel.Nanolight, hh: ?*const Host) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) {
            s.back(n);
            return n.hidePanel();
        }
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
            s.refresh(n, h);
        };
    }

    fn paste(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        if (!h.store.cfg.paste_plain_text) return s.copy(h);
        const r = h.paste(h.ctx, e.hash);
        s.note = note(r);
    }

    fn copy(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        s.note = note(h.copy(h.ctx, e.hash));
    }

    fn header(s: *Screen, c: *ui.Context, n: *panel.Nanolight, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(chrome.header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        const chevron = ui.div(c).size(26, 26).center().rounded(7).bg(p.tile).control();
        if (chevron.clicked()) s.back(n);
        ui.icon(c, "chevron.left", .{ .size = 13, .weight = .semibold, .color = p.sub });
        chevron.end();
        const before = std.hash.Wyhash.hash(0, n.query.text());
        const r = ui.textField(c, &n.query, .{
            .bare = true,
            .size = 19,
            .width = .fill,
            .placeholder = "Search Clipboard History…",
            .placeholder_color = p.placeholder(),
            .color = p.text,
        });
        if (std.hash.Wyhash.hash(0, n.query.text()) != before) s.note = "";
        return r.submitted;
    }

    fn list(s: *Screen, c: *ui.Context, p: Palette, h: *const Host) void {
        if (s.n == 0) {
            const why = h.status(h.ctx);
            const none = if (h.store.len() == 0) "Nothing copied yet." else "No matches.";
            return empty(c, p, if (why != null and h.store.len() == 0) why.? else none);
        }
        const first = if (s.sel >= visible_rows) s.sel + 1 - visible_rows else 0;
        const now = account.now();
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
            chrome.tile(c, p, switch (e.kind) {
                .text => "doc.text",
                .image => "photo",
                .file => "doc",
            });
            var tb: [48]u8 = undefined;
            ui.text(
                c,
                c.print("{s}", .{title(&tb, e)}),
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
                    kindLabel(e.kind),
                    if (app.len > 0) " · " else "",
                    app,
                    relative(&rb, now, e.at),
                },
            );
        }
    }

    fn detail(s: *Screen, c: *ui.Context, p: Palette, h: *const Host) void {
        const box = ui.div(c).column().wFull().h(detail_h).px(20).py(12).gap(4).clip();
        defer box.end();
        const e = s.selected(h) orelse return;
        var shown: usize = 0;
        switch (e.kind) {
            .image => {
                var sb: [24]u8 = undefined;
                ui.textf(
                    c,
                    .{ .size = 13, .color = p.text },
                    "Image, {d} × {d} pixels, {s}",
                    .{ e.width, e.height, sizeText(&sb, e.size) },
                );
            },
            .text, .file => {
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
                        if (line.len == 0) " " else search.clip(line, 240),
                        .{
                            .size = 12.5,
                            .mono = e.kind == .text,
                            .color = p.text,
                            .truncate = .ellipsis,
                        },
                    );
                    shown += 1;
                }
            },
        }
        ui.spacer(c);
        var rb: [24]u8 = undefined;
        ui.textf(
            c,
            .{ .size = 11.5, .color = p.sub.alpha(0.85) },
            "Copied {d} time{s} · last {s}",
            .{
                e.count,
                if (e.count == 1) "" else "s",
                relative(&rb, account.now(), e.at),
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
            ui.textf(c, cut, "Clipboard History · {d}", .{h.store.len()});
        } else ui.text(c, "Clipboard History", p.caption());
        ui.spacer(c);
        const h = hh orelse return;
        const copy_only = !h.store.cfg.paste_plain_text;
        if (!copy_only) {
            chrome.footerKey(c, p, "Paste", "↩", true);
            chrome.keySep(c, p);
        }
        chrome.footerKey(c, p, "Copy", if (copy_only) "↩" else results.mod ++ "↩", copy_only);
        chrome.keySep(c, p);
        chrome.footerKey(c, p, "Delete", results.mod ++ "⌫", false);
        chrome.keySep(c, p);
        chrome.footerKey(c, p, "Close", "esc", false);
    }
};

fn empty(c: *ui.Context, p: Palette, said: []const u8) void {
    const box = ui.div(c).wFull().grow().center();
    defer box.end();
    ui.text(c, said, .{ .size = 13, .color = p.sub, .wrap = true });
}

// ----- how an entry reads -----

/// The footer's word on how a paste or a copy went; empty after a paste.
pub fn note(r: clipboard.PasteResult) []const u8 {
    return switch (r) {
        .pasted => "",
        .copied => "Copied",
        .copied_no_permission => "Copied. Allow Nanolight in Privacy & Security > Accessibility " ++
            "to paste.",
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

/// "now", "5 min ago", "3 h ago", "2 d ago".
fn relative(buf: []u8, now: i64, at: i64) []const u8 {
    const d = @max(now - at, 0);
    const r = if (d < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (d < std.time.s_per_hour)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(d, 60)})
    else if (d < std.time.s_per_day)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(d, std.time.s_per_hour)})
    else
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(d, std.time.s_per_day)});
    return r catch "";
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

fn kindLabel(k: clipboard.Kind) []const u8 {
    return switch (k) {
        .text => "Text",
        .image => "Image",
        .file => "File",
    };
}

/// One line for a list: a text's first line, an image's size, a file's name
/// (and how many more).
fn title(buf: []u8, e: clipboard.Entry) []const u8 {
    switch (e.kind) {
        .text => {
            var lines = std.mem.splitScalar(u8, e.text, '\n');
            while (lines.next()) |l| {
                const t = std.mem.trim(u8, l, " \t\r");
                if (t.len > 0) return search.clip(t, 200);
            }
            return "";
        },
        .image => return std.fmt.bufPrint(
            buf,
            "Image {d} × {d}",
            .{ e.width, e.height },
        ) catch "Image",
        .file => {
            const n = std.mem.count(u8, e.text, "\n") + 1;
            const first = e.text[0 .. std.mem.indexOfScalar(u8, e.text, '\n') orelse e.text.len];
            const name = std.fs.path.basename(first);
            if (n == 1) return name;
            return std.fmt.bufPrint(buf, "{s} and {d} more", .{ name, n - 1 }) catch name;
        },
    }
}

const testing = std.testing;

test "how entries read" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Safari", appName("com.apple.Safari"));
    try testing.expectEqualStrings("chrome", appName("chrome.exe"));
    try testing.expectEqualStrings("firefox", appName("firefox"));
    try testing.expectEqualStrings("org.gnome", appName("org.gnome"));
    try testing.expectEqualStrings("just now", relative(&buf, 100, 90));
    try testing.expectEqualStrings("5 min ago", relative(&buf, 1000, 700));
    try testing.expectEqualStrings("3 h ago", relative(&buf, 20000, 9000));
    try testing.expectEqualStrings("2 d ago", relative(&buf, 200000, 20000));
    const t: clipboard.Entry = .{
        .hash = 1,
        .kind = .text,
        .text = "\n  hello\nworld",
        .size = 14,
        .at = 0,
    };
    try testing.expectEqualStrings("hello", title(&buf, t));
    const im: clipboard.Entry = .{
        .hash = 2,
        .kind = .image,
        .text = "",
        .size = 1,
        .width = 800,
        .height = 600,
        .at = 0,
    };
    try testing.expectEqualStrings("Image 800 × 600", title(&buf, im));
    const f: clipboard.Entry = .{
        .hash = 3,
        .kind = .file,
        .text = "/a/b/c.txt\n/a/d.txt",
        .size = 1,
        .at = 0,
    };
    try testing.expectEqualStrings("c.txt and 1 more", title(&buf, f));
    try testing.expectEqualStrings("12 bytes", sizeText(&buf, 12));
    try testing.expectEqualStrings("34 KB", sizeText(&buf, 34 * 1024 + 5));
    try testing.expectEqualStrings("1.5 MB", sizeText(&buf, 3 << 19));
}
