//! Settings, in the panel itself: the shortcut, Google's suggestions and
//! where searches open, opening at login, the menu bar icon, the sync
//! status, updates. The same glass, the
//! same rows. Esc closes it and the panel; ↑/↓ move, Return and Space do the
//! row. The shortcut is one of four, or any key recorded with ⌘, ⌥ or ⌃
//! (the last chip). Its host (settings_host.zig) answers and keeps it all.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const panel = @import("view.zig");
const key_choice = @import("keys.zig");
const shortcut = @import("shortcut.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Choice = key_choice.Choice;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;
const Theme = @import("palette.zig").Theme;
const mac = @import("builtin").os.tag == .macos;
const platform = @import("platform.zig");
/// A Nix build: the Nix modules own startup and updates.
const nix = @import("build_options").nix_managed;

const RowKind = enum {
    choice,
    suggest,
    files,
    browser,
    login,
    menu_bar,
    clipboard,
    clear_clipboard,
    updates,
    welcome,
    quit,
    theme,
};

/// Recording a key of one's own: not, waiting for one, or waiting after
/// one that was refused. Recording only while the host's recorder runs.
pub const KeyInput = enum { idle, recording, refused };

/// The rows that switch something on or off. Each reads and writes its
/// owner: the panel's own fields, or the host's (no copy kept here).
const Toggle = enum {
    suggest,
    files,
    browser,
    login,
    menu_bar,
    clipboard,

    fn row(t: Toggle) RowKind {
        return switch (t) {
            inline else => |x| @field(RowKind, @tagName(x)),
        };
    }

    fn get(t: Toggle, n: *const panel.Nanolight, h: *const SettingsHost) bool {
        return switch (t) {
            .suggest => n.suggest_on,
            .files => n.files_on,
            .browser => n.searches_out,
            .login => h.login(null),
            .menu_bar => h.menu_bar(h.ctx, null),
            .clipboard => h.clipboard_enabled(h.ctx, null),
        };
    }

    fn set(t: Toggle, h: *const SettingsHost, on: bool) void {
        switch (t) {
            .suggest => h.suggest(h.ctx, on),
            .files => h.files(h.ctx, on),
            .browser => h.searches_out(h.ctx, on),
            .login => {
                _ = h.login(on);
            },
            .menu_bar => {
                _ = h.menu_bar(h.ctx, on);
            },
            .clipboard => {
                _ = h.clipboard_enabled(h.ctx, on);
            },
        }
    }
};

/// Whether this build shows `kind`, with or without the clipboard's rows:
/// the one rule for the keyboard's order and the drawing.
fn present(kind: RowKind, clip: bool) bool {
    return switch (kind) {
        .files => platform.files,
        .browser => platform.preview,
        .menu_bar => platform.tray,
        .login, .updates => !nix,
        .clipboard, .clear_clipboard => clip,
        .choice, .suggest, .welcome, .quit, .theme => true,
    };
}

/// The gap between Settings' parts, tighter on the Mac to fit its rows.
const gap: f32 = if (mac) 8 else 10;
/// A switch's or a button's row.
const row_h: f32 = 36;
/// A heading's line (`Palette.heading`, 11.5 points) as the font draws it:
/// measured (tests_clipboard.zig checks it).
pub const heading_h: f32 = 14;
/// Without the clipboard's section: measured, not added up. The Mac has
/// three rows more (file search, where searches open, and the menu bar
/// icon), and tighter spacing to fit them. Outside a Nix build the rows
/// have outgrown it: the footer shows only its top, below them.
const base_height: f32 = if (mac) 620 else 512;
/// The clipboard's section: a heading, a switch and a button, each with
/// the gap after it.
pub const clip_height: f32 = heading_h + 2 * row_h + 3 * gap;
/// The tallest it gets (with the clipboard's section).
pub const height: f32 = base_height + clip_height;

/// The height: the clipboard's section is there only where this system has
/// clipboard history (`Nanolight.hasClipboard`).
pub fn tall(clip: bool) f32 {
    return if (clip) height else base_height;
}

fn shown(clip: bool) []const RowKind {
    return if (clip) visible(true) else visible(false);
}
comptime {
    // The window is never resized: Settings fits in it.
    @import("std").debug.assert(height <= chrome.max_height);
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

    /// Settings opens (view.zig `Nanolight.open`).
    pub fn show(s: *Settings) void {
        s.sel = 0;
        s.cleared = .idle;
    }

    /// Settings goes: no key is waited for.
    pub fn leave(s: *Settings) void {
        s.key_input = .idle;
    }

    fn pull(s: *Settings, n: *panel.Nanolight) void {
        const h = hooks(n);
        s.choice = h.choice(h.ctx);
        if (s.choice.preset() == null) s.custom = s.choice;
        s.sync = h.sync_status(h.ctx);
        s.version = h.version(h.ctx);
        s.ready = h.ready(h.ctx);
    }

    /// Settings, as the screen up (view.zig `Nanolight.draw`): what the
    /// host says, pulled once a frame, then Return, then the rows.
    pub fn draw(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        s.pull(n);
        if (s.ret.once(c)) s.activateSelected(n);
        const rows = shown(n.hasClipboard());
        if (s.sel >= rows.len) s.sel = rows.len - 1;
        s.keys(c, n, rows);
        ui.key(c, "settings");
        const f = motion.frame(
            c,
            .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = chrome.spring } },
        );
        const page = ui.div(c).column().wFull().grow().motion(f);
        defer page.end();
        s.head(c, n, p, rows);
        s.body(c, n, p, rows);
        foot(c, p);
    }

    fn head(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
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
        s.themes(c, n, p, rows);
    }

    /// The theme's swatches, in the header: always in sight, however many
    /// rows are under it. The last row for ↑/↓; ←/→ step through them.
    fn themes(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
    ) void {
        const on = isSel(rows, s.sel, .theme);
        ui.key(c, "theme");
        const group = ui.div(c).row().h(30).px(10).gap(4).itemsCenter().rounded(10)
            .bg(if (on) p.sel else p.fill.alpha(0));
        defer group.end();
        ui.text(
            c,
            n.theme.title(),
            .{ .size = 12.5, .weight = .medium, .color = if (on) p.text else p.sub },
        );
        ui.div(c).w(4).end();
        for (Theme.all) |t| {
            ui.key(c, c.print("theme-{s}", .{@tagName(t)}));
            const ring = ui.div(c).size(20, 20).roundedFull().center().control()
                .border(if (t == n.theme) p.text.alpha(0.7) else p.fill.alpha(0));
            defer ring.end();
            if (ring.clicked()) setTheme(n, t);
            ui.div(c).size(12, 12).roundedFull().bg(t.hue(c.theme.dark) orelse p.sub).end();
        }
    }

    fn setTheme(n: *panel.Nanolight, t: Theme) void {
        n.theme = t;
        const h = hooks(n);
        h.theme(h.ctx, t);
    }

    fn body(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
    ) void {
        const clip = n.hasClipboard();
        const col = ui.div(c).column().wFull().px(20).pt(2).pb(6).gap(gap).grow();
        defer col.end();
        label(c, p, "Open Nanolight with");
        s.choices(c, n, p);
        label(c, p, "Search");
        s.switchRow(c, n, p, rows, .suggest, "Google Suggestions");
        if (present(.files, clip)) s.switchRow(c, n, p, rows, .files, "File Search");
        if (present(.browser, clip)) {
            s.switchRow(c, n, p, rows, .browser, "Open Searches in Browser");
        }
        if (present(.login, clip) or present(.menu_bar, clip)) {
            label(c, p, "This " ++ platform.machine);
        }
        if (present(.login, clip)) s.switchRow(c, n, p, rows, .login, "Open at Login");
        if (present(.menu_bar, clip)) s.switchRow(c, n, p, rows, .menu_bar, "Show in Menu Bar");
        if (present(.clipboard, clip)) {
            label(c, p, chrome.clipboard_title);
            s.switchRow(c, n, p, rows, .clipboard, "Record Copied Items");
            s.button(c, n, p, rows, .clear_clipboard, switch (s.cleared) {
                .idle => "Clear History",
                .done => chrome.clipboard_title ++ " Cleared",
                .failed => "Could Not Clear History",
            });
        }
        label(c, p, if (mac) "Sync Across Macs" else "Sync Across Computers");
        ui.text(c, s.sync, .{ .size = 12.5, .color = p.sub });
        if (present(.updates, clip)) {
            label(c, p, "Updates");
            s.updates(c, n, p, rows);
        }
        s.button(c, n, p, rows, .welcome, "Show Welcome Again");
        s.button(c, n, p, rows, .quit, "Quit Nanolight");
    }

    fn label(c: *ui.Context, p: Palette, name: []const u8) void {
        ui.text(c, name, p.heading());
    }

    fn choices(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        const row = ui.div(c).row().gap(8);
        defer row.end();
        for (Choice.all) |ch| {
            ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
            const on = ch.eql(s.choice) and s.key_input == .idle;
            const label_text = c.print("{f}", .{shortcut.text(ch)});
            const b = chrome.shortcutChip(c, p, label_text, on, chrome.settings_chip);
            defer b.end();
            if (b.clicked()) s.pick(n, ch);
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
        if (b.clicked()) s.record(n, !recording);
        if (recording) ui.kbd(c, "esc");
    }

    /// Starts or stops waiting for a key of one's own. Recording only once
    /// the host's recorder has started.
    pub fn record(s: *Settings, n: *panel.Nanolight, on: bool) void {
        const h = hooks(n);
        s.key_input = if (h.record(h.ctx, on)) .recording else .idle;
    }

    /// A key pressed while recording: kept and used, or not.
    pub fn took(s: *Settings, n: *panel.Nanolight, r: key_choice.Recorded) void {
        if (s.key_input == .idle) return;
        switch (r) {
            .unusable => s.key_input = .refused,
            .cancel => s.record(n, false),
            .key => |k| {
                s.record(n, false);
                s.custom = k;
                s.pick(n, k);
            },
        }
    }

    fn pick(s: *Settings, n: *panel.Nanolight, ch: Choice) void {
        if (s.key_input != .idle) s.record(n, false);
        s.choice = ch;
        const h = hooks(n);
        h.apply(h.ctx, ch);
    }

    fn switchRow(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
        t: Toggle,
        title: []const u8,
    ) void {
        const on = isSel(rows, s.sel, t.row());
        const d = ui.div(c).row().wFull().h(row_h).px(4).gap(10).itemsCenter().rounded(10)
            .control()
            .bg(if (on) p.sel else p.fill.alpha(0));
        defer d.end();
        if (d.clicked()) flip(n, t);
        ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        mark(c, p, t.get(n, hooks(n)));
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

    fn flip(n: *panel.Nanolight, t: Toggle) void {
        const h = hooks(n);
        t.set(h, !t.get(n, h));
    }

    fn updates(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
    ) void {
        ui.textf(c, .{ .size = 12.5, .color = p.sub }, "Nanolight {s}", .{s.version});
        const text = if (s.ready) |v|
            c.print("Restart to Update to {s}", .{v})
        else
            "Check for Updates";
        s.button(c, n, p, rows, .updates, text);
    }

    fn button(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
        kind: RowKind,
        text: []const u8,
    ) void {
        const on = isSel(rows, s.sel, kind);
        ui.key(c, @tagName(kind));
        const d = ui.div(c).row().wFull().h(row_h).px(12).gap(8).itemsCenter().rounded(10)
            .control()
            .bg(if (on) p.sel else p.tile.alpha(0.45)).border(p.rim);
        defer d.end();
        if (d.clicked()) s.activate(n, kind);
        ui.text(c, text, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        if (on) ui.kbd(c, "↩");
    }

    fn foot(c: *ui.Context, p: Palette) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        chrome.footerKey(c, p, "Close", "esc", false);
    }

    fn keys(s: *Settings, c: *ui.Context, n: *panel.Nanolight, rows: []const RowKind) void {
        const S = ui.Shortcut;
        if (chrome.moveDown(c)) s.sel = (s.sel + 1) % rows.len;
        if (chrome.moveUp(c)) s.sel = (s.sel + rows.len - 1) % rows.len;
        if (c.shortcut(.{ .key = S.left })) s.nudge(n, rows, -1);
        if (c.shortcut(.{ .key = S.right })) s.nudge(n, rows, 1);
        // Space is also typed into the field once Settings closes; only
        // Return and Space while this view has the keys.
        if (c.shortcut(.{ .key = ' ' })) s.activate(n, rows[s.sel]);
    }

    /// Return on the selected row. The field would have taken it.
    pub fn activateSelected(s: *Settings, n: *panel.Nanolight) void {
        const rows = shown(n.hasClipboard());
        if (s.sel >= rows.len) return;
        s.activate(n, rows[s.sel]);
    }

    fn nudge(s: *Settings, n: *panel.Nanolight, rows: []const RowKind, dir: i8) void {
        switch (rows[s.sel]) {
            .choice => s.pick(n, s.choice.step(dir)),
            .theme => setTheme(n, n.theme.step(dir)),
            else => {},
        }
    }

    fn activate(s: *Settings, n: *panel.Nanolight, kind: RowKind) void {
        const h = hooks(n);
        switch (kind) {
            // ←/→ step through the four; Return records one's own.
            .choice => if (key_choice.any_key)
                s.record(n, s.key_input == .idle)
            else
                s.nudge(n, shown(n.hasClipboard()), 1),
            inline .suggest, .files, .browser, .login, .menu_bar, .clipboard => |k| {
                flip(n, @field(Toggle, @tagName(k)));
            },
            .clear_clipboard => {
                s.cleared = if (h.clipboard_clear(h.ctx)) .done else .failed;
            },
            .updates => if (s.ready != null) h.restart(h.ctx) else h.check(h.ctx),
            // In place of Settings (view.zig `Nanolight.open`).
            .welcome => h.welcome(h.ctx),
            .quit => h.quit(h.ctx),
            .theme => setTheme(n, n.theme.step(1)),
        }
    }
};

/// The app's answers. Settings is never drawn, nor driven, without them.
fn hooks(n: *const panel.Nanolight) *const SettingsHost {
    return n.host.?.settings.?;
}

/// The rows this build shows, in order, with or without the clipboard's.
/// The theme's swatches, in the header, are the last for ↑/↓.
fn visible(comptime clip: bool) []const RowKind {
    const T = struct {
        /// In `RowKind`'s order, which is the drawing's.
        const rows = blk: {
            const all = @import("std").enums.values(RowKind);
            var list: [all.len]RowKind = undefined;
            var n: usize = 0;
            for (all) |k| {
                if (!present(k, clip)) continue;
                list[n] = k;
                n += 1;
            }
            const out = list[0..n].*;
            break :blk out;
        };
    };
    return &T.rows;
}

fn isSel(rows: []const RowKind, sel: usize, kind: RowKind) bool {
    if (sel >= rows.len) return false;
    return rows[sel] == kind;
}
