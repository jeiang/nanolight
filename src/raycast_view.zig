//! A script command's screen, drawn in the panel in place of the rows while
//! it runs: its arguments' form, or a detail (its output, or "Run X?"), with
//! its actions in the footer (Return the first, ⌘↩/Ctrl+↩ the second,
//! ⌘K/Ctrl+O all of them). What it shows comes from the runner
//! (script_run.zig) as `View`s; keys and choices go back to it as `Event`s.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const assert = std.debug.assert;
const model = @import("raycast_model.zig");
const pview = @import("view.zig");
const results = @import("results.zig");

/// ⌘K on the Mac; Ctrl+K moves up on a PC, so the actions are on Ctrl+O.
pub const actions_key: ui.Shortcut = if (@import("builtin").os.tag == .macos) .{ .key = 'k', .cmd = true } else .{ .key = 'o', .ctrl = true };
const actions_hint = if (@import("builtin").os.tag == .macos) "⌘K" else "Ctrl+O";
const Palette = pview.Palette;

const section_h: f32 = 26;
const pad: f32 = 6;
/// A dropdown's choices shown, as buttons in its row.
const max_options = 4;
/// An output's lines shown: its last ones.
const max_lines = 200;

/// Where the screen's events go. The host answers within the call: a new
/// view (`Ext.show`), a note, or, on a pop, the screen stopped (`Ext.stop`).
pub const Sender = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: model.Event) void,
};

/// The command's name and its icon (PNG), for the header and the footer.
pub const Command = struct {
    name: []const u8,
    icon: ?[]const u8 = null,
};

pub const Ext = struct {
    gpa: std.mem.Allocator,
    open: bool = false,
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    icon: ?[]const u8 = null,
    /// The top view and the arena it lives in (one per render). A frame
    /// reads `view` once, at the top of `panel`: an event sent while it
    /// draws can replace it.
    arena: ?std.heap.ArenaAllocator = null,
    view: ?model.View = null,
    /// The arena a frame drew from, replaced since: the frame's nodes may
    /// still point into it, so it is freed at the top of the next `panel`
    /// (or at `deinit`). One slot: a frame draws from one arena, and an
    /// arena no frame drew from is freed at once.
    retired: ?std.heap.ArenaAllocator = null,
    /// A frame drew from `arena`.
    drawn: bool = false,
    /// `panel` is building a frame.
    rendering: bool = false,
    actions_open: bool = false,
    act_sel: usize = 0,
    took_return: bool = false,
    /// A toast or HUD, said in the footer for a while.
    note_buf: [200]u8 = undefined,
    note_len: usize = 0,
    note_at: f64 = -10,
    note_bad: bool = false,
    /// What the host is told; set while `open`.
    to: ?Sender = null,
    /// A form's text fields, by the field's place.
    fields: [model.max_fields]ui.TextBuffer = @splat(.{}),
    form_key: u64 = 0,
    /// The field that has the keys once the command's screen goes (the
    /// panel's search).
    back: ?*ui.TextBuffer = null,

    pub fn start(e: *Ext, command: Command, to: Sender) void {
        // A command starts from the rows, never from its own screen.
        assert(!e.rendering);
        e.stop();
        const n = @min(command.name.len, e.name_buf.len);
        @memcpy(e.name_buf[0..n], command.name[0..n]);
        e.name_len = n;
        e.icon = command.icon;
        e.to = to;
        e.open = true;
    }

    pub fn stop(e: *Ext) void {
        e.open = false;
        e.view = null;
        e.release();
        e.actions_open = false;
        e.note_len = 0;
        e.form_key = 0;
        if (e.back) |b| b.focus();
    }

    /// Closes the screen as its back button does: the host ends the
    /// script and stops the screen. The panel stays.
    pub fn close(e: *Ext) void {
        e.send(.pop);
        assert(!e.open);
    }

    pub fn deinit(e: *Ext) void {
        assert(!e.rendering);
        e.stop();
        e.freeRetired();
        for (&e.fields) |*f| f.deinit();
    }

    /// The host's new top view; `arena` holds it and is now this one's.
    pub fn show(e: *Ext, arena: std.heap.ArenaAllocator, v: model.View) void {
        assert(e.open);
        e.release();
        e.arena = arena;
        e.view = v;
        switch (v) {
            .form => |f| e.loadForm(f),
            .detail => {},
        }
    }

    /// Lets go of the view's arena: freed now if no frame drew from it,
    /// else kept until the next frame.
    fn release(e: *Ext) void {
        var old = e.arena orelse return;
        e.arena = null;
        if (!e.drawn) return old.deinit();
        e.drawn = false;
        // Only the arena a frame drew from is kept, and the next frame
        // frees it before it draws.
        assert(e.retired == null);
        e.retired = old;
    }

    fn freeRetired(e: *Ext) void {
        assert(!e.rendering);
        if (e.retired) |*a| a.deinit();
        e.retired = null;
    }

    /// Says `text` in the footer for a while, from the next frame.
    pub fn note(e: *Ext, text: []const u8, bad: bool) void {
        const n = @min(text.len, e.note_buf.len);
        @memcpy(e.note_buf[0..n], text[0..n]);
        e.note_len = n;
        e.note_bad = bad;
        e.note_at = -1;
    }

    /// Tells the host, while the screen is open: a pop sent earlier in the
    /// frame closed it, and what follows was aimed at the old view.
    fn send(e: *Ext, event: model.Event) void {
        if (!e.open) return;
        const to = e.to.?;
        to.func(to.ctx, event);
    }

    fn run(e: *Ext, a: model.Action) void {
        e.actions_open = false;
        e.send(.{ .action = a });
    }

    pub fn height(e: *const Ext) f32 {
        const v = e.view orelse return pview.header_h + pview.footer_h + 80;
        const chrome: f32 = pview.header_h + pview.footer_h + 2;
        // As tall as what is shown, no taller.
        if (e.actions_open) {
            const n: f32 = @floatFromInt(v.actions().len);
            return @min(chrome + pad * 2 + section_h + n * 38, pview.max_height);
        }
        switch (v) {
            .form => |f| {
                const rows: f32 = @floatFromInt(@max(f.fields.len, 1));
                return @min(chrome + 32 + rows * 44, pview.max_height);
            },
            .detail => |d| switch (d.body) {
                .output => |out| {
                    const shown = std.mem.trimEnd(u8, out, "\n");
                    const n = @min(std.mem.count(u8, shown, "\n") + 1, max_lines);
                    const lines: f32 = @floatFromInt(n);
                    return @min(@max(chrome + 36 + lines * 19, 150), pview.max_height);
                },
                .markdown => |md| {
                    var lines: f32 = @floatFromInt(std.mem.count(u8, md, "\n") + 1);
                    // Long paragraphs wrap: about 80 characters a line.
                    lines += @floatFromInt(md.len / 80);
                    return @min(@max(chrome + 46 + lines * 24, 150), pview.max_height);
                },
            },
        }
    }

    /// The command in the panel (Nanolight.panel calls it while `open`).
    pub fn panel(e: *Ext, c: *ui.Context, n: *pview.Nanolight, p: Palette) void {
        // Nodes of the last frame are gone: what it drew from can go too.
        assert(!e.rendering);
        e.freeRetired();
        e.drawn = e.arena != null;
        e.rendering = true;
        defer e.rendering = false;
        const h = n.follow(e.height());
        const body = ui.div(c).column().wFull().h(h).clip();
        defer body.end();
        // Read once: the host may answer an event below with a new view.
        const v = e.view;
        const acts: []const model.Action = if (v) |vv| vv.actions() else &.{};
        e.keys(c, n, v, acts);
        e.header(c, p, v);
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const mid = ui.div(c).column().wFull().grow().clip();
        if (e.actions_open) {
            e.actionList(c, p, acts);
        } else if (v) |vv| switch (vv) {
            .form => |f| e.form(c, p, f),
            .detail => |d| detail(c, p, d),
        } else {
            const w = ui.div(c).wFull().h(80).center();
            ui.text(c, "Starting…", .{ .size = 13, .color = p.sub.alpha(0.8) });
            w.end();
        }
        mid.end();
        e.footer(c, p, acts);
    }

    fn keys(
        e: *Ext,
        c: *ui.Context,
        nl: *pview.Nanolight,
        v: ?model.View,
        acts: []const model.Action,
    ) void {
        const S = ui.Shortcut;
        // The arrows move in the actions, and never reach a field.
        const n = if (e.actions_open) acts.len else 0;
        if (pview.Nanolight.moveDown(c) and n > 0) e.act_sel = (e.act_sel + 1) % n;
        if (pview.Nanolight.moveUp(c) and n > 0) e.act_sel = (e.act_sel + n - 1) % n;
        if (c.shortcut(actions_key)) {
            e.actions_open = !e.actions_open and acts.len > 0;
            e.act_sel = 0;
        }
        if (c.shortcut(.{ .key = S.enter, .cmd = true })) {
            // A form submits with its first action, as Raycast's does.
            const k: usize = if (v != null and v.? == .form) 0 else 1;
            if (acts.len > k) e.run(acts[k]);
        }
        const ret = c.input.key == .enter or for (c.input.ops) |op| {
            if (op == .command and op.command == .insert_newline) break true;
        } else false;
        if (!ret) e.took_return = false;
        if (ret and !e.took_return) {
            e.took_return = true;
            if (e.actions_open) {
                if (e.act_sel < acts.len) e.run(acts[e.act_sel]);
            } else if (acts.len > 0) e.run(acts[0]);
        }
        if (c.shortcut(.{ .key = S.escape })) {
            e.send(.pop);
            nl.hidePanel();
        }
    }

    fn header(e: *Ext, c: *ui.Context, p: Palette, v: ?model.View) void {
        const bar = ui.div(c).row().wFull().h(pview.header_h).px(18).gap(12).itemsCenter();
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
        const col = ui.div(c).column().wFull().px(26).py(18).gap(10).grow().scrollY();
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
        const lines_box = ui.div(c).column().wFull().gap(4);
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
        assert(f.fields.len <= model.max_fields);
        var h = std.hash.Wyhash.init(0);
        for (f.fields) |field| h.update(std.mem.asBytes(&field.slot));
        const key = h.final();
        if (key == e.form_key) return;
        e.form_key = key;
        var focused = false;
        for (f.fields, 0..) |field, i| {
            e.fields[i].set(field.value);
            // The first field typed into has the keys.
            if (!focused and field.kind == .text) {
                e.fields[i].focus();
                focused = true;
            }
        }
    }

    fn form(e: *Ext, c: *ui.Context, p: Palette, f: model.Form) void {
        const col = ui.div(c).column().wFull().px(26).py(16).gap(12).grow().scrollY();
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
                .text => e.textBox(c, p, field, &e.fields[i]),
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
        const box = ui.div(c).grow().h(32).px(10).itemsCenter().row().rounded(8).bg(p.tile)
            .border(p.rim);
        defer box.end();
        const before = std.hash.Wyhash.hash(0, buf.text());
        _ = ui.textField(c, buf, .{
            .bare = true,
            .size = 14,
            .width = .fill,
            .placeholder = f.placeholder,
            .color = p.text,
            .placeholder_color = p.sub.alpha(0.6),
        });
        if (std.hash.Wyhash.hash(0, buf.text()) == before) return;
        e.send(.{ .field = .{ .slot = f.slot, .value = buf.text() } });
    }

    fn actionList(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        const col = ui.div(c).column().wFull().px(8).py(pad).grow().scrollY();
        defer col.end();
        const t = ui.div(c).row().wFull().h(section_h).px(12).itemsEnd().pb(4);
        ui.text(c, "Actions", .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
        t.end();
        for (acts, 0..) |a, i| {
            ui.key(c, c.print("rc-act-{d}", .{i}));
            const r = ui.div(c).row().wFull().h(38).px(12).gap(10).itemsCenter().rounded(9).control();
            if (i == e.act_sel) _ = r.bg(p.sel).border(p.rim);
            if (r.clicked()) e.run(a);
            ui.text(c, a.title(), .{ .size = 13.5, .weight = .medium, .color = p.text });
            ui.spacer(c);
            if (i == 0) ui.kbd(c, "↩") else if (i == 1) ui.kbd(c, results.mod ++ "↩");
            r.end();
        }
    }

    fn footer(e: *Ext, c: *ui.Context, p: Palette, acts: []const model.Action) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(pview.footer_h).px(16).gap(8).itemsCenter();
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
        } else ui.text(c, name, .{ .size = 12, .color = p.sub.alpha(0.8), .truncate = .ellipsis });
        ui.spacer(c);
        if (acts.len == 0) return;
        const first: ui.TextStyle = .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) };
        ui.text(c, acts[0].title(), first);
        ui.kbd(c, "↩");
        if (acts.len > 1) {
            ui.div(c).w(1).h(14).bg(p.hair).end();
            ui.text(c, "Actions", .{ .size = 12, .color = p.sub.alpha(0.8) });
            ui.kbd(c, actions_hint);
        }
    }
};
