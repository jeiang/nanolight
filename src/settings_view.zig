//! Settings, in the panel itself: the shortcut, the switches (toggles.zig),
//! the sync status, updates. The same glass, the same rows. Esc closes it
//! and the panel; ↑/↓ move, Return and Space do the row. The shortcut is
//! one of four, or any key recorded with ⌘, ⌥ or ⌃ (the last chip). Its
//! host (settings_host.zig) answers and keeps it all; what it lists
//! (`groups`) is the one order for the drawing, the keys and the height.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const key_choice = @import("keys.zig");
const shortcut = @import("shortcut.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const toggles = @import("toggles.zig");
const Toggle = toggles.Toggle;
const Choice = key_choice.Choice;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;
const Theme = @import("palette.zig").Theme;
const mac = @import("os.zig").mac;
const platform = @import("platform.zig");

/// Recording a key of one's own: not, waiting for one, or waiting after
/// one that was refused. Recording only while the host's recorder runs.
pub const KeyInput = enum { idle, recording, refused };

const Button = enum { clear_clipboard, updates, welcome, quit };
/// A line of the host's words.
const Note = enum { sync, version };

/// One thing Settings lists, as drawn.
const Part = union(enum) {
    /// A group's name.
    heading: []const u8,
    /// The shortcut's chips.
    chips,
    toggle: Toggle,
    button: Button,
    note: Note,

    /// Whether this build shows it, `clip` with clipboard history.
    fn present(part: Part, clip: bool) bool {
        return switch (part) {
            .heading, .chips => true,
            .toggle => |t| t.present(clip),
            .button => |b| switch (b) {
                .clear_clipboard => clip,
                .updates => platform.updater,
                .welcome, .quit => true,
            },
            .note => |n| switch (n) {
                .sync => true,
                .version => platform.updater,
            },
        };
    }

    fn height(part: Part) f32 {
        return switch (part) {
            .heading => heading_h,
            .chips => chrome.chip_h,
            .toggle, .button => row_h,
            .note => note_h,
        };
    }
};

/// A heading and what is under it; the heading shows with any of it.
const Group = struct {
    heading: ?[]const u8,
    parts: []const Part,
};

/// The switches of `section`, in `Toggle`'s order.
fn switches(comptime section: toggles.Section) []const Part {
    comptime {
        var list: []const Part = &.{};
        for (std.enums.values(Toggle)) |t| {
            if (t.row().section == section) list = list ++ [_]Part{.{ .toggle = t }};
        }
        const out = list[0..list.len].*;
        return &out;
    }
}

/// What Settings lists, top to bottom.
const groups = [_]Group{
    .{ .heading = "Open Nanolight with", .parts = &.{.chips} },
    .{ .heading = "Search", .parts = switches(.search) },
    .{ .heading = "This " ++ platform.machine, .parts = switches(.machine) },
    .{
        .heading = chrome.clipboard_title,
        .parts = switches(.clipboard) ++ [_]Part{.{ .button = .clear_clipboard }},
    },
    .{
        .heading = if (mac) "Sync Across Macs" else "Sync Across Computers",
        .parts = &.{.{ .note = .sync }},
    },
    .{ .heading = "Updates", .parts = &.{ .{ .note = .version }, .{ .button = .updates } } },
    .{ .heading = null, .parts = &.{ .{ .button = .welcome }, .{ .button = .quit } } },
};

/// What this build draws, in order, with or without the clipboard's.
fn parts(comptime clip: bool) []const Part {
    const out = comptime blk: {
        var list: []const Part = &.{};
        for (groups) |g| {
            var under: []const Part = &.{};
            for (g.parts) |part| {
                if (part.present(clip)) under = under ++ [_]Part{part};
            }
            if (under.len == 0) continue;
            if (g.heading) |name| list = list ++ [_]Part{.{ .heading = name }};
            list = list ++ under;
        }
        break :blk list[0..list.len].*;
    };
    return &out;
}

/// What ↑/↓ select: the parts that do something, then the theme's
/// swatches, in the header.
const Row = union(enum) {
    choice,
    toggle: Toggle,
    button: Button,
    theme,

    fn eql(a: Row, b: Row) bool {
        return std.meta.eql(a, b);
    }
};

fn rowsOf(comptime clip: bool) []const Row {
    const out = comptime blk: {
        var list: []const Row = &.{};
        for (parts(clip)) |part| switch (part) {
            .chips => list = list ++ [_]Row{.choice},
            .toggle => |t| list = list ++ [_]Row{.{ .toggle = t }},
            .button => |b| list = list ++ [_]Row{.{ .button = b }},
            .heading, .note => {},
        };
        list = list ++ [_]Row{.theme};
        break :blk list[0..list.len].*;
    };
    return &out;
}

fn shownParts(clip: bool) []const Part {
    return if (clip) parts(true) else parts(false);
}

fn shownRows(clip: bool) []const Row {
    return if (clip) rowsOf(true) else rowsOf(false);
}

/// The gap between Settings' parts, tighter on the Mac to fit its rows:
/// with the clipboard's, 8 there was 5 points past the window (DECISION D1).
const gap: f32 = if (mac) 7 else 10;
/// A switch's or a button's row.
const row_h: f32 = 36;
/// Room over the first part and under the last.
const pad_top: f32 = 2;
const pad_bottom: f32 = 6;
/// A heading's line (`Palette.heading`, 11.5 points) and a note's (12.5
/// points) as the Mac's system font draws them: measured (tests check
/// them there; elsewhere the installed font decides).
pub const heading_h: f32 = 14;
pub const note_h: f32 = 15;

/// Settings' height: its header, what it lists with a gap between each,
/// its footer (`chrome.footer`: a hairline, then the keys). With `clip`
/// when this system has clipboard history (`Nanolight.hasClipboard`).
pub fn height(clip: bool) f32 {
    return if (clip) heightOf(true) else heightOf(false);
}

fn heightOf(comptime clip: bool) f32 {
    return comptime chrome.header_h + pad_top + partsHeight(clip) + pad_bottom +
        1 + chrome.footer_h;
}

/// What it lists, and a gap between each.
fn partsHeight(comptime clip: bool) f32 {
    comptime {
        const list = parts(clip);
        var sum: f32 = gap * @as(f32, @floatFromInt(list.len - 1));
        for (list) |part| sum += part.height();
        return sum;
    }
}

comptime {
    // The window is never resized: Settings fits in it, as tall as it gets.
    std.debug.assert(heightOf(true) <= chrome.max_height);
}

pub const Settings = struct {
    sel: usize = 0,
    ret: chrome.Return = .{},
    choice: Choice = .cmd_space,
    /// The last chip's key, recorded (this run or before), if any.
    custom: ?Choice = null,
    /// Recording a key for the last chip, and whether the one pressed last
    /// was refused (no ⌘, ⌥ or ⌃).
    key_input: KeyInput = .idle,
    cleared: enum { idle, done, failed } = .idle,
    /// The host's sync status, pulled each frame.
    sync: []const u8 = "",
    version: []const u8 = @import("build_options").version,
    ready: ?[]const u8 = null,
    theme: Theme = .system,

    /// Settings opens (view.zig `Nanolight.open`).
    pub fn show(s: *Settings) void {
        s.sel = 0;
        s.cleared = .idle;
    }

    /// Settings goes: no key is waited for, the host's recorder stopped.
    pub fn leave(s: *Settings, h: *const SettingsHost) void {
        s.stopRecording(h);
    }

    fn pull(s: *Settings, h: *const SettingsHost) void {
        s.choice = h.choice(h.ctx);
        if (s.choice.preset() == null) s.custom = s.choice;
        s.sync = h.sync_status(h.ctx);
        s.version = h.version(h.ctx);
        s.ready = h.ready(h.ctx);
        s.theme = h.theme(h.ctx, null);
    }

    /// Settings, as the screen up (view.zig `draw`): what the host says,
    /// pulled once a frame, then Return, then the rows. Everything it does
    /// is the host's, leaving too (Show Welcome Again, Quit): no outcome.
    pub fn draw(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        clip: bool,
        p: Palette,
    ) void {
        s.pull(h);
        const rows = shownRows(clip);
        if (s.sel >= rows.len) s.sel = rows.len - 1;
        if (s.ret.once(c)) s.activate(h, rows[s.sel]);
        s.keys(c, h, rows);
        ui.key(c, "settings");
        const f = motion.frame(
            c,
            .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = chrome.spring } },
        );
        const page = ui.div(c).column().wFull().grow().motion(f);
        defer page.end();
        s.head(c, h, p, rows);
        s.body(c, h, p, rows, shownParts(clip));
        foot(c, p);
    }

    fn head(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        p: Palette,
        rows: []const Row,
    ) void {
        const bar = ui.div(c).row().wFull().h(chrome.header_h).px(16).gap(10).itemsCenter();
        defer bar.end();
        const badge = ui.div(c).size(28, 28).rounded(8).center().bg(p.tile);
        ui.icon(c, "gearshape", .{ .size = 15, .weight = .medium, .color = p.text });
        badge.end();
        ui.text(
            c,
            "Settings",
            .{ .size = 18, .weight = .semibold, .color = p.text, .tracking = -0.2 },
        );
        ui.spacer(c);
        s.themes(c, h, p, rows);
    }

    /// The theme's swatches, in the header: always in sight, however many
    /// rows are under it. The last row for ↑/↓; ←/→ step through them.
    fn themes(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        p: Palette,
        rows: []const Row,
    ) void {
        const on = isSel(rows, s.sel, .theme);
        ui.key(c, "theme");
        const group = ui.div(c).row().h(30).px(10).gap(4).itemsCenter().rounded(10)
            .bg(if (on) p.sel else p.fill.alpha(0));
        defer group.end();
        ui.text(
            c,
            s.theme.title(),
            .{ .size = 12.5, .weight = .medium, .color = if (on) p.text else p.sub },
        );
        ui.div(c).w(4).end();
        for (Theme.all) |t| {
            ui.key(c, c.print("theme-{s}", .{@tagName(t)}));
            const ring = ui.div(c).size(20, 20).roundedFull().center().control()
                .border(if (t == s.theme) p.text.alpha(0.7) else p.fill.alpha(0));
            defer ring.end();
            if (ring.clicked()) s.setTheme(h, t);
            ui.div(c).size(12, 12).roundedFull().bg(t.hue(c.theme.dark) orelse p.sub).end();
        }
    }

    fn setTheme(s: *Settings, h: *const SettingsHost, t: Theme) void {
        s.theme = h.theme(h.ctx, t);
    }

    fn body(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        p: Palette,
        rows: []const Row,
        list: []const Part,
    ) void {
        const col = ui.div(c).column().wFull().px(20).pt(pad_top).pb(pad_bottom).gap(gap).grow();
        defer col.end();
        for (list) |part| switch (part) {
            .heading => |name| ui.text(c, name, p.heading()),
            .chips => s.choices(c, h, p),
            .toggle => |t| s.switchRow(c, h, p, rows, t),
            .button => |b| s.button(c, h, p, rows, b),
            .note => |n| switch (n) {
                .sync => ui.text(c, s.sync, .{ .size = 12.5, .color = p.sub }),
                .version => ui.textf(
                    c,
                    .{ .size = 12.5, .color = p.sub },
                    "Nanolight {s}",
                    .{s.version},
                ),
            },
        };
    }

    fn choices(s: *Settings, c: *ui.Context, h: *const SettingsHost, p: Palette) void {
        const row = ui.div(c).row().gap(8);
        defer row.end();
        for (Choice.all) |ch| {
            ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
            const on = ch.eql(s.choice) and s.key_input == .idle;
            const label_text = c.print("{f}", .{shortcut.text(ch)});
            const b = chrome.shortcutChip(c, p, label_text, on, chrome.settings_chip);
            defer b.end();
            if (b.clicked()) s.pick(h, ch);
        }
        // One's own: the key recorded, or a press away (`keys.any_key`).
        if (!key_choice.any_key) return;
        ui.key(c, "key-own");
        const recording = s.key_input != .idle;
        const on = recording or (s.custom != null and s.custom.?.eql(s.choice));
        const text = switch (s.key_input) {
            .refused => "Add ⌘, ⌥ or ⌃",
            .recording => "Type a shortcut",
            .idle => if (s.custom) |k| c.print("{f}", .{shortcut.text(k)}) else "Record…",
        };
        const b = chrome.shortcutChip(c, p, text, on, chrome.settings_chip);
        defer b.end();
        if (b.clicked()) s.record(h, !recording);
        if (recording) ui.kbd(c, "esc");
    }

    /// Starts or stops waiting for a key of one's own. Recording only once
    /// the host's recorder has started: `key_input` is the one word on
    /// whether it runs.
    fn record(s: *Settings, h: *const SettingsHost, on: bool) void {
        s.key_input = if (h.record(h.ctx, on)) .recording else .idle;
    }

    /// No key waited for any more (Settings goes, the panel loses the
    /// keys): the recorder stops and the key is back.
    pub fn stopRecording(s: *Settings, h: *const SettingsHost) void {
        if (s.key_input != .idle) s.record(h, false);
    }

    /// A key pressed while recording: kept and used, or not.
    pub fn took(s: *Settings, h: *const SettingsHost, r: key_choice.Recorded) void {
        if (s.key_input == .idle) return;
        switch (r) {
            .unusable => s.key_input = .refused,
            .cancel => s.record(h, false),
            .key => |k| {
                s.record(h, false);
                s.custom = k;
                s.pick(h, k);
            },
        }
    }

    fn pick(s: *Settings, h: *const SettingsHost, ch: Choice) void {
        s.stopRecording(h);
        s.choice = ch;
        h.apply(h.ctx, ch);
    }

    fn switchRow(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        p: Palette,
        rows: []const Row,
        t: Toggle,
    ) void {
        const on = isSel(rows, s.sel, .{ .toggle = t });
        const d = ui.div(c).row().wFull().h(row_h).px(4).gap(10).itemsCenter().rounded(10)
            .control()
            .bg(if (on) p.sel else p.fill.alpha(0));
        defer d.end();
        if (d.clicked()) flip(h, t);
        ui.text(c, t.row().title, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        mark(c, p, h.toggle(h.ctx, t, null));
    }

    /// A quiet on/off mark. Not `ui.toggle`: that flips on its own click,
    /// and this row already does.
    fn mark(c: *ui.Context, p: Palette, on: bool) void {
        const ok = c.theme.success;
        const d = ui.div(c).row().w(40).h(24).px(2).itemsCenter().roundedFull()
            .bg(if (on) ok else p.tile);
        defer d.end();
        // On: the knob at the right, as the system's switches have it.
        if (on) ui.spacer(c);
        ui.div(c).size(20, 20).roundedFull().bg(ui.Color.white).end();
        if (!on) ui.spacer(c);
    }

    /// What its owner says now, the other way.
    fn flip(h: *const SettingsHost, t: Toggle) void {
        _ = h.toggle(h.ctx, t, !h.toggle(h.ctx, t, null));
    }

    fn button(
        s: *Settings,
        c: *ui.Context,
        h: *const SettingsHost,
        p: Palette,
        rows: []const Row,
        b: Button,
    ) void {
        const text = switch (b) {
            .clear_clipboard => switch (s.cleared) {
                .idle => "Clear History",
                .done => chrome.clipboard_title ++ " Cleared",
                .failed => "Could Not Clear History",
            },
            .updates => if (s.ready) |v|
                c.print("Restart to Update to {s}", .{v})
            else
                "Check for Updates",
            .welcome => "Show Welcome Again",
            .quit => "Quit Nanolight",
        };
        const on = isSel(rows, s.sel, .{ .button = b });
        ui.key(c, @tagName(b));
        const d = ui.div(c).row().wFull().h(row_h).px(12).gap(8).itemsCenter().rounded(10)
            .control()
            .bg(if (on) p.sel else p.tile.alpha(0.45)).border(p.rim);
        defer d.end();
        if (d.clicked()) s.activate(h, .{ .button = b });
        ui.text(c, text, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        if (on) ui.kbd(c, "↩");
    }

    fn foot(c: *ui.Context, p: Palette) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        chrome.closeKey(c, p);
    }

    fn keys(s: *Settings, c: *ui.Context, h: *const SettingsHost, rows: []const Row) void {
        const S = ui.Shortcut;
        if (chrome.moveDown(c)) s.sel = (s.sel + 1) % rows.len;
        if (chrome.moveUp(c)) s.sel = (s.sel + rows.len - 1) % rows.len;
        if (c.shortcut(.{ .key = S.left })) s.nudge(h, rows[s.sel], -1);
        if (c.shortcut(.{ .key = S.right })) s.nudge(h, rows[s.sel], 1);
        // Space is also typed into the field once Settings closes; only
        // Return and Space while this view has the keys.
        if (c.shortcut(.{ .key = ' ' })) s.activate(h, rows[s.sel]);
    }

    fn nudge(s: *Settings, h: *const SettingsHost, row: Row, dir: i8) void {
        switch (row) {
            .choice => s.pick(h, s.choice.step(dir)),
            .theme => s.setTheme(h, s.theme.step(dir)),
            .toggle, .button => {},
        }
    }

    fn activate(s: *Settings, h: *const SettingsHost, row: Row) void {
        switch (row) {
            // ←/→ step through the four; Return records one's own.
            .choice => if (key_choice.any_key)
                s.record(h, s.key_input == .idle)
            else
                s.nudge(h, .choice, 1),
            .toggle => |t| flip(h, t),
            .button => |b| switch (b) {
                .clear_clipboard => {
                    s.cleared = if (h.clipboard_clear(h.ctx)) .done else .failed;
                },
                .updates => if (s.ready != null) h.restart(h.ctx) else h.check(h.ctx),
                // In place of Settings (view.zig `Nanolight.open`).
                .welcome => h.welcome(h.ctx),
                .quit => h.quit(h.ctx),
            },
            .theme => s.setTheme(h, s.theme.step(1)),
        }
    }
};

fn isSel(rows: []const Row, sel: usize, row: Row) bool {
    if (sel >= rows.len) return false;
    return rows[sel].eql(row);
}
