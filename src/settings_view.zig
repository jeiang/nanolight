//! Settings, in the panel itself: the shortcut, Google's suggestions and
//! where searches open, opening at login, the menu bar icon, the sync
//! status, updates. The same glass, the
//! same rows. Esc closes it and the panel; ↑/↓ move, Return and Space do the
//! row. The shortcut is one of four, or any key recorded with ⌘, ⌥ or ⌃
//! (the last chip). Without a host (tests) it still draws, and changes
//! nothing the app keeps.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const panel = @import("view.zig");
const shortcut = @import("shortcut.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Choice = shortcut.Choice;
const Palette = panel.Palette;
const mac = @import("builtin").os.tag == .macos;
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

    fn get(t: Toggle, n: *const panel.Nanolight, h: ?*const SettingsHost) bool {
        return switch (t) {
            .suggest => n.suggest_on,
            .files => n.files_on,
            .browser => n.searches_out,
            // Without a host (tests): as a fresh install has them.
            .login => if (h) |host| host.login(host.ctx, null) else false,
            .menu_bar => if (h) |host| host.menu_bar(host.ctx, null) else true,
            .clipboard => blk: {
                const host = h orelse break :blk false;
                break :blk host.clipboard_enabled(host.ctx, null) orelse false;
            },
        };
    }

    fn set(t: Toggle, n: *panel.Nanolight, h: ?*const SettingsHost, on: bool) void {
        switch (t) {
            .suggest => if (h) |host| host.suggest(host.ctx, on) else {
                n.suggest_on = on;
                n.built = 1;
            },
            .files => if (h) |host| host.files(host.ctx, on) else {
                n.files_on = on;
                n.built = 1;
            },
            .browser => if (h) |host| host.searches_out(host.ctx, on) else {
                n.searches_out = on;
            },
            .login => if (h) |host| {
                _ = host.login(host.ctx, on);
            },
            .menu_bar => if (h) |host| {
                _ = host.menu_bar(host.ctx, on);
            },
            .clipboard => if (h) |host| {
                _ = host.clipboard_enabled(host.ctx, on);
            },
        }
    }
};

/// Whether this build shows `kind`, with or without the clipboard's rows:
/// the one rule for the keyboard's order and the drawing.
fn present(kind: RowKind, clip: bool) bool {
    return switch (kind) {
        .files, .browser, .menu_bar => mac,
        .login, .updates => !nix,
        .clipboard, .clear_clipboard => clip,
        .choice, .suggest, .welcome, .quit, .theme => true,
    };
}
const Theme = @import("palette.zig").Theme;

/// As tall as its sections, never past the window. The Mac has three rows
/// more (file search, where searches open, and the menu bar icon), and
/// tighter spacing to fit them.
const base_height: f32 = if (mac) 620 else 512;
/// The clipboard's section: a heading, a switch and a button.
const clip_height: f32 = if (mac) 110 else 116;
/// The tallest it gets (with the clipboard's section).
pub const height: f32 = base_height + clip_height;
comptime {
    // The window is never resized: Settings fits in it.
    @import("std").debug.assert(height <= panel.max_height);
}

pub const Settings = struct {
    open: bool = false,
    sel: usize = 0,
    /// Return already handled for this key event (a frame may draw twice).
    took_return: bool = false,
    choice: Choice = .cmd_space,
    /// The last chip's key, recorded (this run or before), if any.
    custom: ?Choice = null,
    /// Recording a key for the last chip, and whether the one pressed last
    /// was refused (no ⌘, ⌥ or ⌃).
    key_input: KeyInput = .idle,
    /// Whether this system has clipboard history (its section shows).
    clip_here: bool = false,
    cleared: enum { idle, done, failed } = .idle,
    sync: []const u8 = @import("account.zig").off_text,
    version: []const u8 = @import("build_options").version,
    ready: ?[]const u8 = null,

    pub fn show(s: *Settings) void {
        s.open = true;
        s.sel = 0;
        s.cleared = .idle;
    }

    /// The height now: the clipboard's section is there only where this system has it.
    pub fn tall(s: *const Settings) f32 {
        return if (s.clip_here) height else base_height;
    }

    pub fn hide(s: *Settings) void {
        s.open = false;
        s.key_input = .idle;
    }

    /// The rows shown now: the clipboard's only where this system has it.
    fn shown(s: *const Settings) []const RowKind {
        return if (s.clip_here) visible(true) else visible(false);
    }

    fn hooks(s: *Settings, n: *panel.Nanolight) ?*const SettingsHost {
        _ = s;
        const h = n.host orelse return null;
        return h.settings;
    }

    fn pull(s: *Settings, n: *panel.Nanolight) void {
        const h = s.hooks(n) orelse return;
        s.choice = h.choice(h.ctx);
        if (s.choice.preset() == null) s.custom = s.choice;
        s.clip_here = h.clipboard_enabled(h.ctx, null) != null;
        s.sync = h.sync_status(h.ctx);
        s.version = h.version(h.ctx);
        s.ready = h.ready(h.ctx);
    }

    pub fn view(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        s.pull(n);
        const rows = s.shown();
        if (s.sel >= rows.len) s.sel = rows.len - 1;
        s.keys(c, n, rows);
        ui.key(c, "settings");
        const f = motion.frame(
            c,
            .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = panel.spring } },
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
        const bar = ui.div(c).row().wFull().h(panel.header_h).px(16).gap(10).itemsCenter();
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
            if (ring.clicked()) s.setTheme(n, t);
            ui.div(c).size(12, 12).roundedFull().bg(t.hue(c.theme.dark) orelse p.sub).end();
        }
    }

    fn setTheme(s: *Settings, n: *panel.Nanolight, t: Theme) void {
        n.theme = t;
        const h = s.hooks(n) orelse return;
        h.theme(h.ctx, t);
    }

    fn body(
        s: *Settings,
        c: *ui.Context,
        n: *panel.Nanolight,
        p: Palette,
        rows: []const RowKind,
    ) void {
        const clip = s.clip_here;
        const col = ui.div(c).column().wFull().px(20).pt(2).pb(6).gap(if (mac) 8 else 10).grow();
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
            label(c, p, "This " ++ @import("results.zig").machine);
        }
        if (present(.login, clip)) s.switchRow(c, n, p, rows, .login, "Open at Login");
        if (present(.menu_bar, clip)) s.switchRow(c, n, p, rows, .menu_bar, "Show in Menu Bar");
        if (present(.clipboard, clip)) {
            label(c, p, "Clipboard History");
            s.switchRow(c, n, p, rows, .clipboard, "Record Copied Items");
            s.button(c, n, p, rows, .clear_clipboard, switch (s.cleared) {
                .idle => "Clear History",
                .done => "Clipboard History Cleared",
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
        ui.text(c, name, .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) });
    }

    fn choices(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        const row = ui.div(c).row().gap(8);
        defer row.end();
        for (Choice.all) |ch| {
            ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
            const on = ch.eql(s.choice) and s.key_input == .idle;
            const b = ui.div(c).row().h(36).px(14).itemsCenter().rounded(10).control()
                .bg(if (on) p.sel else p.tile.alpha(0.5))
                .border(if (on) p.text.alpha(0.35) else p.rim);
            defer b.end();
            if (b.clicked()) s.pick(n, ch);
            ui.text(
                c,
                c.print("{f}", .{ch}),
                .{
                    .size = 13.5,
                    .weight = if (on) .semibold else .medium,
                    .color = if (on) p.text else p.sub,
                },
            );
        }
        // One's own: the key recorded, or a press away (on the Mac, where
        // Carbon takes any key; a PC keeps to the four).
        if (!mac) return;
        ui.key(c, "key-own");
        const recording = s.key_input != .idle;
        const on = recording or (s.custom != null and s.custom.?.eql(s.choice));
        const b = ui.div(c).row().h(36).px(14).gap(6).itemsCenter().rounded(10).control()
            .bg(if (on) p.sel else p.tile.alpha(0.5)).border(if (on) p.text.alpha(0.35) else p.rim);
        defer b.end();
        if (b.clicked()) s.record(n, !recording);
        const text = switch (s.key_input) {
            .refused => "Add ⌘, ⌥ or ⌃",
            .recording => "Type a shortcut",
            .idle => if (s.custom) |k| c.print("{f}", .{k}) else "Record…",
        };
        const weight: ui.Weight = if (on) .semibold else .medium;
        ui.text(c, text, .{ .size = 13.5, .weight = weight, .color = if (on) p.text else p.sub });
        if (recording) ui.kbd(c, "esc");
    }

    /// Starts or stops waiting for a key of one's own. Recording only once
    /// the host's recorder has started (none in tests: as asked).
    fn record(s: *Settings, n: *panel.Nanolight, on: bool) void {
        const h = s.hooks(n) orelse {
            s.key_input = if (on) .recording else .idle;
            return;
        };
        s.key_input = if (h.record(h.ctx, on)) .recording else .idle;
    }

    /// A key pressed while recording: kept and used, or not.
    pub fn took(s: *Settings, n: *panel.Nanolight, r: shortcut.Recorded) void {
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
        const h = s.hooks(n) orelse return;
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
        const d = ui.div(c).row().wFull().h(36).px(4).gap(10).itemsCenter().rounded(10).control()
            .bg(if (on) p.sel else p.fill.alpha(0));
        defer d.end();
        if (d.clicked()) s.flip(n, t);
        ui.text(c, title, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        mark(c, p, t.get(n, s.hooks(n)));
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

    fn flip(s: *Settings, n: *panel.Nanolight, t: Toggle) void {
        const h = s.hooks(n);
        t.set(n, h, !t.get(n, h));
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
        const d = ui.div(c).row().wFull().h(36).px(12).gap(8).itemsCenter().rounded(10).control()
            .bg(if (on) p.sel else p.tile.alpha(0.45)).border(p.rim);
        defer d.end();
        if (d.clicked()) s.activate(n, kind);
        ui.text(c, text, .{ .size = 13.5, .weight = .medium, .color = p.text });
        ui.spacer(c);
        if (on) ui.kbd(c, "↩");
    }

    fn foot(c: *ui.Context, p: Palette) void {
        ui.div(c).wFull().h(1).bg(p.hair).end();
        const bar = ui.div(c).row().wFull().h(panel.footer_h).px(16).gap(8).itemsCenter();
        defer bar.end();
        ui.text(c, "Close", .{ .size = 12, .color = p.sub.alpha(0.8) });
        ui.kbd(c, "esc");
    }

    fn keys(s: *Settings, c: *ui.Context, n: *panel.Nanolight, rows: []const RowKind) void {
        const S = ui.Shortcut;
        if (c.shortcut(.{ .key = S.escape })) {
            s.hide();
            n.query.focus();
            return n.hidePanel();
        }
        if (!s.returned(c)) s.took_return = false;
        if (panel.Nanolight.moveDown(c)) s.sel = (s.sel + 1) % rows.len;
        if (panel.Nanolight.moveUp(c)) s.sel = (s.sel + rows.len - 1) % rows.len;
        if (c.shortcut(.{ .key = S.left })) s.nudge(n, rows, -1);
        if (c.shortcut(.{ .key = S.right })) s.nudge(n, rows, 1);
        // Space is also typed into the field once Settings closes; only
        // Return and Space while this view has the keys.
        if (c.shortcut(.{ .key = ' ' })) s.activate(n, rows[s.sel]);
    }

    /// Return, as a key or as the field's newline command.
    /// Settings in place of the rows, the panel's height following them.
    pub fn inPanel(s: *Settings, c: *ui.Context, n: *panel.Nanolight, p: Palette) void {
        // Return is the field's command, or a key. One event, one act.
        if (s.returned(c) and !s.took_return) {
            s.took_return = true;
            s.activateSelected(n);
        }
        s.pull(n);
        const h = n.follow(s.tall());
        const box = ui.div(c).column().wFull().h(h).clip();
        defer box.end();
        s.view(c, n, p);
    }

    pub fn returned(s: *Settings, c: *ui.Context) bool {
        _ = s;
        if (c.input.key == .enter) return true;
        for (c.input.ops) |op| if (op == .command and op.command == .insert_newline) return true;
        return false;
    }

    /// Return on the selected row. The field would have taken it.
    pub fn activateSelected(s: *Settings, n: *panel.Nanolight) void {
        s.pull(n);
        const rows = s.shown();
        if (s.sel >= rows.len) return;
        s.activate(n, rows[s.sel]);
    }

    fn nudge(s: *Settings, n: *panel.Nanolight, rows: []const RowKind, dir: i8) void {
        switch (rows[s.sel]) {
            .choice => s.pick(n, s.choice.step(dir)),
            .theme => s.setTheme(n, n.theme.step(dir)),
            else => {},
        }
    }

    fn activate(s: *Settings, n: *panel.Nanolight, kind: RowKind) void {
        const h = s.hooks(n);
        switch (kind) {
            // ←/→ step through the four; Return records one's own.
            .choice => if (mac) s.record(n, s.key_input == .idle) else s.nudge(n, s.shown(), 1),
            inline .suggest, .files, .browser, .login, .menu_bar, .clipboard => |k| {
                s.flip(n, @field(Toggle, @tagName(k)));
            },
            .clear_clipboard => {
                const ok = if (h) |host| host.clipboard_clear(host.ctx) else true;
                s.cleared = if (ok) .done else .failed;
            },
            .updates => if (h) |host| {
                if (s.ready != null) host.restart(host.ctx) else host.check(host.ctx);
            },
            .welcome => if (h) |host| {
                s.hide();
                host.welcome(host.ctx);
            },
            .quit => if (h) |host| host.quit(host.ctx),
            .theme => s.setTheme(n, n.theme.step(1)),
        }
    }
};

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

test "a Nix build's Settings has no login or updates row" {
    var login = false;
    var updates = false;
    for (visible(true)) |k| {
        login = login or k == .login;
        updates = updates or k == .updates;
    }
    try @import("std").testing.expectEqual(!nix, login);
    try @import("std").testing.expectEqual(!nix, updates);
}
