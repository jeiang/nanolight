//! Clipboard History, in the panel in place of the rows: a search field, the
//! entries newest first (type, source app, how long ago), and what the
//! selected one holds. Return pastes it, ⌘↩ (Ctrl+Enter) only copies it,
//! ⌘⌫ (Ctrl+Backspace, or ⌘D / Ctrl+D) deletes it, Esc goes back. ↑ ↓, ^N ^P and ^J ^K move.
//! The panel hides on a paste; a paste that could only copy says why in the
//! footer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const panel = @import("view.zig");
const clipboard = @import("clipboard.zig");
const results = @import("results.zig");
const account = @import("account.zig");
const Palette = panel.Palette;

/// What the screen asks of the app. Without it the screen says history is
/// not available (tests and the film draw it so).
pub const Host = struct {
    ctx: *anyopaque,
    store: *clipboard.Store,
    /// Why entries are not being recorded now (this system cannot, or it
    /// is switched off); null while they are.
    status: *const fn (ctx: *anyopaque) ?[]const u8,
    /// Return: writes the entry and pastes it where it can.
    paste: *const fn (ctx: *anyopaque, hash: u64) clipboard.PasteResult,
    /// ⌘↩: writes the entry only.
    copy: *const fn (ctx: *anyopaque, hash: u64) bool,
    /// `paste_plain_text` is off: Return only copies, as ⌘↩ does.
    copy_only: bool = false,
};

const row_h: f32 = 40;
const visible_rows = 7;
const list_pad: f32 = 6;
const detail_h: f32 = 112;
const max_found = 50;
const detail_lines = 4;
/// Header, list, detail and footer with their hairlines.
pub const height: f32 = panel.header_h + 1 + visible_rows * row_h + list_pad * 2 + 1 + detail_h + 1 + panel.footer_h;

pub const Screen = struct {
    open: bool = false,
    sel: usize = 0,
    /// The entries found: places in the store's list.
    found: [max_found]u32 = undefined,
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
        if (same_query) for (s.found[0..s.n], 0..) |at, i| if (h.store.entries.items[at].hash == s.sel_hash) {
            s.sel = i;
            break;
        };
        if (s.sel >= s.n) s.sel = s.n -| 1;
    }

    fn selected(s: *const Screen, h: *const Host) ?clipboard.Entry {
        if (s.sel >= s.n) return null;
        return h.store.entries.items[s.found[s.sel]];
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
        const rows = ui.div(c).column().wFull().h(visible_rows * row_h + list_pad * 2).p(list_pad).clip();
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
        if (panel.Nanolight.moveDown(c)) {
            s.note = "";
            if (s.n > 0) s.sel = (s.sel + 1) % s.n;
        }
        if (panel.Nanolight.moveUp(c)) {
            s.note = "";
            if (s.n > 0) s.sel = (s.sel + s.n - 1) % s.n;
        }
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) s.copy(h);
        // ⌫ is 0x7f on the Mac and 0x08 on GTK; Windows offers no key for it, so ⌘D / Ctrl+D too.
        if (c.shortcut(.{ .key = 0x7f, .cmd = true }) or c.shortcut(.{ .key = 0x08, .cmd = true }) or c.shortcut(.{ .key = 'd', .cmd = true })) if (s.selected(h)) |e| {
            _ = h.store.remove(e.hash);
            s.note = "Deleted";
            s.refresh(n, h);
        };
    }

    fn paste(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        if (h.copy_only) return s.copy(h);
        const r = h.paste(h.ctx, e.hash);
        s.note = clipboard.pasteNote(r) orelse "";
    }

    fn copy(s: *Screen, h: *const Host) void {
        const e = s.selected(h) orelse return;
        s.note = if (h.copy(h.ctx, e.hash)) "Copied" else "Could not write the clipboard.";
    }

    fn header(s: *Screen, c: *ui.Context, n: *panel.Nanolight, p: Palette) bool {
        const bar = ui.div(c).row().wFull().h(panel.header_h).px(18).gap(12).itemsCenter();
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
            .placeholder_color = p.sub.alpha(0.75),
            .color = p.text,
        });
        if (std.hash.Wyhash.hash(0, n.query.text()) != before) s.note = "";
        return r.submitted;
    }

    fn list(s: *Screen, c: *ui.Context, p: Palette, h: *const Host) void {
        if (s.n == 0) {
            const why = h.status(h.ctx);
            const none = if (h.store.entries.items.len == 0) "Nothing copied yet." else "No matches.";
            return empty(c, p, if (why != null and h.store.entries.items.len == 0) why.? else none);
        }
        const first = if (s.sel >= visible_rows) s.sel + 1 - visible_rows else 0;
        const now = account.now();
        for (first..@min(s.n, first + visible_rows)) |i| {
            const e = h.store.entries.items[s.found[i]];
            ui.key(c, c.print("clip-row-{d}", .{i}));
            const r = ui.div(c).row().wFull().h(row_h).px(10).gap(12).itemsCenter().rounded(10).control();
            defer r.end();
            if (i == s.sel) _ = r.bg(p.sel).border(p.rim);
            if (r.clicked()) {
                if (s.sel == i) s.paste(h) else s.sel = i;
            }
            const tile = ui.div(c).size(26, 26).rounded(7).bg(p.tile).center();
            ui.icon(c, switch (e.kind) {
                .text => "doc.text",
                .image => "photo",
                .file => "doc",
            }, .{ .size = 13, .weight = .medium, .color = p.text });
            tile.end();
            var tb: [48]u8 = undefined;
            ui.text(c, c.print("{s}", .{clipboard.title(&tb, e)}), .{ .size = 13.5, .weight = .medium, .color = p.text, .truncate = .ellipsis });
            ui.spacer(c);
            var rb: [24]u8 = undefined;
            const app = clipboard.appName(e.source);
            ui.textf(c, .{ .size = 12, .color = p.sub.alpha(0.85), .tabular = true }, "{s}{s}{s} · {s}", .{ clipboard.kindLabel(e.kind), if (app.len > 0) " · " else "", app, clipboard.relative(&rb, now, e.at) });
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
                ui.textf(c, .{ .size = 13, .color = p.text }, "Image, {d} × {d} pixels, {s}", .{ e.width, e.height, clipboard.sizeText(&sb, e.size) });
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
                    ui.text(c, if (line.len == 0) " " else clipboard.clip(line, 240), .{ .size = 12.5, .mono = e.kind == .text, .color = p.text, .truncate = .ellipsis });
                    shown += 1;
                }
            },
        }
        ui.spacer(c);
        var rb: [24]u8 = undefined;
        ui.textf(c, .{ .size = 11.5, .color = p.sub.alpha(0.85) }, "Copied {d} time{s} · last {s}", .{ e.count, if (e.count == 1) "" else "s", clipboard.relative(&rb, account.now(), e.at) });
    }

    fn footer(s: *Screen, c: *ui.Context, p: Palette, hh: ?*const Host) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(panel.footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        panel.appIcon(c, 16);
        if (s.note.len > 0)
            ui.text(c, s.note, .{ .size = 12, .weight = .medium, .color = p.text, .truncate = .ellipsis })
        else if (hh) |h|
            ui.textf(c, .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8), .truncate = .ellipsis }, "Clipboard History · {d}", .{h.store.entries.items.len})
        else
            ui.text(c, "Clipboard History", .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) });
        ui.spacer(c);
        if (hh == null) return;
        if (!hh.?.copy_only) {
            ui.text(c, "Paste", .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) });
            ui.kbd(c, "↩");
            ui.div(c).w(1).h(14).bg(p.hair).end();
        }
        ui.text(c, "Copy", .{ .size = 12, .weight = if (hh.?.copy_only) .medium else .regular, .color = if (hh.?.copy_only) p.text.alpha(0.85) else p.sub.alpha(0.8) });
        ui.kbd(c, if (hh.?.copy_only) "↩" else results.mod ++ "↩");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Delete", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, results.mod ++ "⌫");
        ui.div(c).w(1).h(14).bg(p.hair).end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }
};

fn empty(c: *ui.Context, p: Palette, said: []const u8) void {
    const box = ui.div(c).wFull().grow().center();
    defer box.end();
    ui.text(c, said, .{ .size = 13, .color = p.sub, .wrap = true });
}
