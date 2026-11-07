//! A script command's screen, drawn in the panel in place of the rows while
//! it runs: its arguments' form, or a detail (its output, or "Run X?"), with
//! its actions in the footer (in key order, raycast_model.zig `return_at`;
//! ⌘K/Ctrl+O all of them). What it shows comes from the runner
//! (script_run.zig) as `Update`s, through nanolight.zig's `Nanolight.scriptScreen`;
//! keys and choices go back to it as `Event`s.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const assert = std.debug.assert;
const model = @import("raycast_model.zig");
const platform = @import("platform.zig");

/// ⌘K on the Mac; Ctrl+K moves up on a PC, so the actions are on Ctrl+O
/// (`platform.actions`).
pub const actions_key: ui.Shortcut = platform.actions.shortcut;
const actions_hint = platform.actions.text;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;
/// A dropdown's choices shown, as buttons in its row.
const max_options = 4;
/// An output's lines shown: its last ones.
const max_lines = 200;

// The screen's layout, which `Ext.height` adds up.
/// "Starting…", before the first view.
const starting_h = 80;
/// A row of the actions (⌘K).
const action_row_h = 38;
/// A form's padding, a text field's box (a dropdown's row is shorter) and
/// the gap after each.
const form_py = 16;
const field_h = 32;
const field_gap = 12;
/// A detail's padding, and the gap between its parts.
const detail_py = 18;
const detail_gap = 10;
/// An output line (12.5-point monospace) as the Mac's font draws it,
/// measured (tests_ext.zig checks it), and the gap after it.
pub const output_line_h = 15;
const output_gap = 4;
/// A Markdown line and its gap, as estimated: how its words wrap is not.
const markdown_line_h = 24;
const min_detail_h = 150;

/// An arena whose contents frames draw. Replaced after a frame drew from
/// it, it is kept until the next frame starts (`frame`): that frame's nodes
/// may still point into it. One slot: a frame draws from the arena it found
/// at its start, and an arena no frame drew from is freed at once.
const Held = struct {
    arena: ?std.heap.ArenaAllocator = null,
    /// A frame drew from `arena`.
    drawn: bool = false,
    /// The arena a frame drew from, replaced since.
    retired: ?std.heap.ArenaAllocator = null,

    fn set(h: *Held, arena: std.heap.ArenaAllocator) void {
        h.release();
        h.arena = arena;
    }

    /// Lets go of the arena: freed now if no frame drew from it, else
    /// kept until the next frame.
    fn release(h: *Held) void {
        var old = h.arena orelse return;
        h.arena = null;
        if (!h.drawn) return old.deinit();
        h.drawn = false;
        // Only the arena a frame drew from is kept, and the next frame
        // frees it before it draws.
        assert(h.retired == null);
        h.retired = old;
    }

    /// A frame starts: the last one's nodes are gone, so what it drew from
    /// can go, and this one draws from `arena`.
    fn frame(h: *Held) void {
        h.freeRetired();
        h.drawn = h.arena != null;
    }

    fn freeRetired(h: *Held) void {
        if (h.retired) |*a| a.deinit();
        h.retired = null;
    }

    fn deinit(h: *Held) void {
        h.release();
        h.freeRetired();
    }
};

pub const Ext = struct {
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    /// The command's icon, in `screen`, which lives as long as the screen.
    icon: ?[]const u8 = null,
    screen: Held = .{},
    /// The top view, in `held` (one arena per render). A frame reads
    /// `view` once, at the top of `draw`: an event sent while it draws can
    /// replace it.
    view: ?model.View = null,
    held: Held = .{},
    /// `draw` is building a frame.
    rendering: bool = false,
    actions_open: bool = false,
    act_sel: usize = 0,
    ret: chrome.Return = .{},
    /// A toast or HUD, said in the footer for a while.
    note_buf: [200]u8 = undefined,
    note_len: usize = 0,
    note_at: f64 = -10,
    note_bad: bool = false,
    /// What the host is told; set while the screen is up.
    to: ?model.Sender = null,
    /// A form's text fields, by the field's place.
    fields: [model.max_args]ui.TextBuffer = @splat(.{}),
    form_key: u64 = 0,

    /// `command` runs, telling `to`; its screen's things are in `gpa`.
    pub fn start(e: *Ext, gpa: std.mem.Allocator, command: model.Command, to: model.Sender) void {
        // A command starts from the rows, never from its own screen.
        assert(!e.rendering);
        e.stop();
        const n = @min(command.name.len, e.name_buf.len);
        @memcpy(e.name_buf[0..n], command.name[0..n]);
        e.name_len = n;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        // Out of memory: the screen goes without its icon.
        e.icon = if (command.icon) |png| arena.allocator().dupe(u8, png) catch null else null;
        e.screen.set(arena);
        e.to = to;
    }

    pub fn stop(e: *Ext) void {
        e.to = null;
        e.view = null;
        e.held.release();
        e.icon = null;
        e.screen.release();
        e.actions_open = false;
        e.note_len = 0;
        e.form_key = 0;
    }

    /// Closes the screen as its back button does: the host ends the
    /// script and stops the screen.
    pub fn close(e: *Ext) void {
        e.send(.pop);
        assert(e.to == null);
    }

    pub fn deinit(e: *Ext) void {
        assert(!e.rendering);
        e.stop();
        e.held.deinit();
        e.screen.deinit();
        for (&e.fields) |*f| f.deinit();
    }

    /// The host's new top view; `arena` holds it and is now this one's.
    pub fn show(e: *Ext, arena: std.heap.ArenaAllocator, v: model.View) void {
        assert(e.to != null);
        e.held.set(arena);
        e.view = v;
        switch (v) {
            .form => |f| e.loadForm(f),
            .detail => {},
        }
    }

    /// Says `text` in the footer for a while, from the next frame.
    pub fn note(e: *Ext, text: []const u8, bad: bool) void {
        const n = @min(text.len, e.note_buf.len);
        @memcpy(e.note_buf[0..n], text[0..n]);
        e.note_len = n;
        e.note_bad = bad;
        e.note_at = -1;
    }

    /// Tells the host, while the screen is up: a pop sent earlier in the
    /// frame closed it, and what follows was aimed at the old view.
    fn send(e: *Ext, event: model.Event) void {
        const to = e.to orelse return;
        to.func(to.ctx, event);
    }

    fn run(e: *Ext, a: model.Action) void {
        e.actions_open = false;
        e.send(.{ .action = a });
    }

    /// As tall as what is shown, no taller: the layout above added up.
    pub fn height(e: *const Ext) f32 {
        const v = e.view orelse return chrome.header_h + chrome.footer_h + starting_h;
        // With the hairlines under the header and over the footer.
        const bars: f32 = chrome.header_h + chrome.footer_h + 2;
        if (e.actions_open) {
            const n: f32 = @floatFromInt(v.actions().len);
            const list = chrome.list_pad * 2 + chrome.actions_section.h + n * action_row_h;
            return @min(bars + list, chrome.max_height);
        }
        switch (v) {
            .form => |f| {
                const rows: f32 = @floatFromInt(@max(f.fields.len, 1));
                const form_h = form_py * 2 + rows * (field_h + field_gap);
                return @min(bars + form_h, chrome.max_height);
            },
            .detail => |d| switch (d.body) {
                .output => |out| {
                    const shown = std.mem.trimEnd(u8, out, "\n");
                    const n = @min(std.mem.count(u8, shown, "\n") + 1, max_lines);
                    const lines: f32 = @floatFromInt(n);
                    const out_h = detail_py * 2 + lines * (output_line_h + output_gap);
                    return @min(@max(bars + out_h, min_detail_h), chrome.max_height);
                },
                .markdown => |md| {
                    var lines: f32 = @floatFromInt(std.mem.count(u8, md, "\n") + 1);
                    // Long paragraphs wrap: about 80 characters a line.
                    lines += @floatFromInt(md.len / 80);
                    const md_h = detail_py * 2 + detail_gap + lines * markdown_line_h;
                    return @min(@max(bars + md_h, min_detail_h), chrome.max_height);
                },
            },
        }
    }

    /// The command, as the screen up (view.zig `draw`).
    pub fn draw(e: *Ext, c: *ui.Context, p: Palette) void {
        // Nodes of the last frame are gone: what it drew from can go too.
        assert(!e.rendering);
        e.held.frame();
        e.screen.frame();
        e.rendering = true;
        defer e.rendering = false;
        // Read once: the host may answer an event below with a new view.
        const v = e.view;
        const acts: []const model.Action = if (v) |vv| vv.actions() else &.{};
        e.keys(c, v, acts);
        e.header(c, p, v);
        chrome.hairline(c, p);
        const mid = ui.div(c).column().wFull().grow().clip();
        if (e.actions_open) {
            e.actionList(c, p, acts);
        } else if (v) |vv| switch (vv) {
            .form => |f| e.form(c, p, f),
            .detail => |d| detail(c, p, d),
        } else {
            const w = ui.div(c).wFull().h(starting_h).center();
            ui.text(c, "Starting…", p.waiting());
            w.end();
        }
        mid.end();
        e.footer(c, p, acts);
    }

    fn keys(e: *Ext, c: *ui.Context, v: ?model.View, acts: []const model.Action) void {
        const S = ui.Shortcut;
        // The arrows move in the actions, and never reach a field.
        const n = if (e.actions_open) acts.len else 0;
        if (chrome.moveDown(c) and n > 0) e.act_sel = (e.act_sel + 1) % n;
        if (chrome.moveUp(c) and n > 0) e.act_sel = (e.act_sel + n - 1) % n;
        if (c.shortcut(actions_key)) {
            e.actions_open = !e.actions_open and acts.len > 0;
            e.act_sel = 0;
        }
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) {
            const form_shown = v != null and v.? == .form;
            const k: usize = if (form_shown) model.return_at else model.cmd_return_at;
            if (acts.len > k) e.run(acts[k]);
        }
        if (e.ret.once(c)) {
            if (e.actions_open) {
                if (e.act_sel < acts.len) e.run(acts[e.act_sel]);
            } else if (acts.len > model.return_at) e.run(acts[model.return_at]);
        }
    }

    fn header(e: *Ext, c: *ui.Context, p: Palette, v: ?model.View) void {
        const bar = ui.div(c).row().wFull().h(chrome.header_h).px(18).gap(12).itemsCenter();
        defer bar.end();
        const back = ui.div(c).size(26, 26).center().rounded(7).bg(p.tile).control();
        if (back.clicked()) e.send(.pop);
        ui.icon(c, "chevron.left", .{ .size = 13, .weight = .semibold, .color = p.sub });
        back.end();
        const title = if (v) |vv| vv.title() else "";
        ui.text(c, if (title.len > 0) title else e.name_buf[0..e.name_len], .{
            .size = 17,
            .weight = .semibold,
            .color = p.text,
            .truncate = .ellipsis,
        });
        ui.spacer(c);
        const loading = if (v) |vv| vv == .detail and vv.detail.loading else false;
        if (loading) ui.text(c, "Loading…", .{ .size = 12, .color = p.sub.alpha(0.7) });
    }

    fn detail(c: *ui.Context, p: Palette, d: model.Detail) void {
        const col = ui.div(c).column().wFull().px(26).py(detail_py).gap(detail_gap).grow()
            .scrollY();
        defer col.end();
        switch (d.body) {
            .output => |out| output(c, p, out),
            .markdown => |md| markdown(c, p, md),
        }
    }

    /// A script's output: its lines as printed, monospaced, the last ones.
    fn output(c: *ui.Context, p: Palette, out: []const u8) void {
        var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
        var from: usize = out.len;
        var k: usize = 0;
        while (lines.next()) |l| : (k += 1) {
            if (k == max_lines) break;
            from = @intFromPtr(l.ptr) - @intFromPtr(out.ptr);
        }
        const shown = std.mem.trimEnd(u8, out[@min(from, out.len)..], "\n");
        var rest = std.mem.splitScalar(u8, shown, '\n');
        const lines_box = ui.div(c).column().wFull().gap(output_gap);
        defer lines_box.end();
        const style: ui.TextStyle = .{ .size = 12.5, .mono = true, .color = p.text };
        while (rest.next()) |line| ui.text(c, if (line.len == 0) " " else line, style);
    }

    /// Markdown as text: the first line a heading.
    fn markdown(c: *ui.Context, p: Palette, md: []const u8) void {
        var buf: [8192]u8 = undefined;
        const text = model.plain(&buf, md);
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            // `buf` is this call's; the frame draws the text after it returns.
            ui.text(c, c.print("{s}", .{line}), .{
                .size = if (first) 19 else 14,
                .weight = if (first) .semibold else .regular,
                .color = p.text,
                .wrap = true,
            });
            first = false;
        }
    }

    fn loadForm(e: *Ext, f: model.Form) void {
        assert(f.fields.len <= model.max_args);
        var h = std.hash.Wyhash.init(0);
        for (f.fields) |field| h.update(std.mem.asBytes(&field.slot));
        const key = h.final();
        if (key == e.form_key) return;
        e.form_key = key;
        var focused = false;
        for (f.fields, 0..) |field, i| {
            e.fields[i].set(field.value);
            // The first field typed into has the keys.
            if (!focused and field.kind != .dropdown) {
                e.fields[i].focus();
                focused = true;
            }
        }
    }

    fn form(e: *Ext, c: *ui.Context, p: Palette, f: model.Form) void {
        const col = ui.div(c).column().wFull().px(26).py(form_py).gap(field_gap).grow()
            .scrollY();
        defer col.end();
        for (f.fields, 0..) |field, i| {
            ui.key(c, c.print("rc-field-{d}", .{i}));
            const r = ui.div(c).row().wFull().gap(14).itemsCenter();
            defer r.end();
            const lab = ui.div(c).w(130);
            ui.text(c, field.title, .{
                .size = 13,
                .weight = .medium,
                .color = p.sub,
                .truncate = .ellipsis,
            });
            lab.end();
            switch (field.kind) {
                .dropdown => e.dropdown(c, p, field),
                .text, .password => e.textBox(c, p, field, &e.fields[i]),
            }
        }
    }

    fn dropdown(e: *Ext, c: *ui.Context, p: Palette, f: model.Field) void {
        const opts = ui.div(c).row().gap(6);
        defer opts.end();
        for (f.options[0..@min(f.options.len, max_options)]) |o| {
            const on = std.mem.eql(u8, f.value, o.value);
            const b = ui.div(c).h(26).px(10).center().rounded(7).bg(if (on) p.sel else p.tile)
                .control();
            if (b.clicked()) e.send(.{ .field = .{ .slot = f.slot, .value = o.value } });
            ui.text(c, o.title, .{ .size = 12, .color = p.text });
            b.end();
        }
    }

    fn textBox(e: *Ext, c: *ui.Context, p: Palette, f: model.Field, buf: *ui.TextBuffer) void {
        const box = ui.div(c).grow().h(field_h).px(10).itemsCenter().row().rounded(8).bg(p.tile)
            .border(p.rim);
        defer box.end();
        const before = std.hash.Wyhash.hash(0, buf.text());
        _ = ui.textField(c, buf, .{
            .bare = true,
            .size = 14,
            .width = .fill,
            .placeholder = f.placeholder,
            .password = f.kind == .password,
            .color = p.text,
            .placeholder_color = p.sub.alpha(0.6),
        });
        if (std.hash.Wyhash.hash(0, buf.text()) == before) return;
        e.send(.{ .field = .{ .slot = f.slot, .value = buf.text() } });
    }

    fn actionList(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        const col = ui.div(c).column().wFull().px(8).py(chrome.list_pad).grow().scrollY();
        defer col.end();
        chrome.sectionHead(c, p, "Actions", chrome.actions_section);
        for (acts, 0..) |a, i| {
            ui.key(c, c.print("rc-act-{d}", .{i}));
            const r = ui.div(c).row().wFull().h(action_row_h).px(12).gap(10).itemsCenter()
                .rounded(9).control();
            if (i == e.act_sel) _ = r.bg(p.sel).border(p.rim);
            if (r.clicked()) e.run(a);
            ui.text(c, a.title(), .{ .size = 13.5, .weight = .medium, .color = p.text });
            ui.spacer(c);
            if (i == model.return_at) ui.kbd(c, "↩") else if (i == model.cmd_return_at)
                ui.kbd(c, platform.mod ++ "↩");
            r.end();
        }
    }

    fn footer(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        const name = e.name_buf[0..e.name_len];
        if (e.icon) |png| _ = ui.image(c, .{
            .key = name,
            .bytes = png,
            .max_width = 16,
            .max_height = 16,
            .radius = 4,
            .scale = 2,
        });
        if (e.note_len > 0 and e.note_at == -1) e.note_at = c.time;
        if (e.note_len > 0 and c.time - e.note_at < 2.5) {
            ui.text(c, e.note_buf[0..e.note_len], .{
                .size = 12,
                .weight = .medium,
                .color = if (e.note_bad) c.theme.danger else p.text,
                .truncate = .ellipsis,
            });
            c.animationFrame();
        } else {
            var cut = p.detail();
            cut.truncate = .ellipsis;
            ui.text(c, name, cut);
        }
        ui.spacer(c);
        if (acts.len <= model.return_at) return;
        chrome.footerKey(c, p, acts[model.return_at].title(), "↩", true);
        if (acts.len > 1) {
            chrome.keySep(c, p);
            chrome.footerKey(c, p, "Actions", actions_hint, false);
        }
    }
};
