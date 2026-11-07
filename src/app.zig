//! The app around the panel: its window, shown and hidden (panel_mac.zig,
//! panel_win.zig and panel_x11.zig), its key and its welcome. The features (`*_live.zig`)
//! keep the rest, and join in where the panel comes and goes through
//! `Hooks`; main.zig wires them.
const std = @import("std");
const nanoui = @import("nanoui");
const Nanolight = @import("nanolight.zig").Nanolight;
const view = @import("view.zig");
const onboard = @import("onboard.zig");
const keys = @import("keys.zig");
const shortcut = @import("shortcut.zig");
const shortcut_clash = @import("shortcut_clash.zig");
const shortcut_holders = @import("shortcut_holders.zig");
const settings_panes = @import("settings_panes.zig");
const hotkey = @import("hotkey.zig");
const shell = @import("shell.zig");
const panel = shell.panel;
const single = @import("single.zig");
const account = @import("account.zig");
const clock = @import("clock.zig");
const apps = @import("apps.zig");
const host = @import("host.zig");
const Target = host.Target;
const prefs = @import("prefs.zig");
const settings = @import("settings.zig");
const after = @import("after.zig");
const PageKey = @import("preview.zig").Key;
const Setter = @import("toggles.zig").Setter;

/// A menu's item waits for the menu: it closes first, then the panel
/// takes the keys.
const menu_closes_ms = 50;
/// Nanolight's own row: the panel hides as the row opens, and comes back
/// after this.
const reopen_ms = 60;
/// A launcher takes a moment to quit: then the welcome looks again.
const launcher_quits_ms = 900;
/// Where a key the system holds is freed (the welcome's fix).
const keyboard_pane = settings_panes.named("Keyboard").url();

/// A feature's part in an event, with its own context.
pub const Hook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,

    fn run(hook: ?Hook) void {
        const h = hook orelse return;
        h.func(h.ctx);
    }
};

/// A feature that opens script commands' rows (script_live.zig).
pub const Opens = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, target: host.ScriptTarget) void,
};

/// Where the features join the panel's comings and goings.
pub const Hooks = struct {
    /// Before the panel takes the keys: where a paste from the clipboard
    /// history goes (clipboard_live.zig).
    showing: ?Hook = null,
    /// As it opens: apps and script commands added or removed since are
    /// found (script_live.zig).
    rescan: ?Hook = null,
    /// It reopens at the root: a script command running in it ends.
    popped: ?Hook = null,
    /// Script commands' rows: a script, and their folder.
    opens: ?Opens = null,
    /// It went away unfocused: an update that is ready may go in
    /// (update_live.zig).
    away: ?Hook = null,
    /// What the menu bar icon's menu shows changed (menu_live.zig).
    menu: ?Hook = null,
};

pub const App = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *onboard.Onboard,
    kv: nanoui.kv.Store,
    /// The key that shows the panel.
    choice: keys.Choice,
    window: ?*nanoui.Window = null,
    preview: shell.Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: shell.ClickThrough = .{},
    /// A key of one's own, being recorded (recorder.zig): Settings starts
    /// and stops it, and says whether it runs (`Settings.key_input`).
    recorder: shell.Recorder = .{},
    /// The account settings sync through (account_live.zig); null without one.
    acct: ?*account.Account = null,
    hooks: Hooks = .{},
    /// How the menu's checkbox and sync change a switch (settings_bind.zig).
    toggles: Setter,

    pub fn from(ctx: *anyopaque) *App {
        return after.cast(*App, ctx);
    }

    pub fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    /// Says `text` in the footer (a command's, a script's).
    pub fn footer(ctx: *anyopaque, text: []const u8) void {
        const a = from(ctx);
        a.s.note = text;
        a.redraw();
    }

    /// Once the window is up, in a run with a person at it: the room round
    /// the panel, its key, click-through, the page's keys.
    pub fn start(a: *App) void {
        const w = a.window.?;
        a.s.fit = panel.setup(w);
        panel.resize(w, view.height(a.s));
        a.useKey(a.choice);
        a.through = .{ .window = w, .height = a.s.last_h };
        a.preview.watch(.{ .ctx = a, .func = pageKey });
    }

    /// What the welcome asks of the app: who holds the keys, the key kept,
    /// a holder made to let go, opening at login, the welcome kept as done.
    pub fn welcomeHooks(a: *App) onboard.Hooks {
        return .{
            .ctx = a,
            .look = shortcut_holders.look,
            .apply = apply,
            .fix = fix,
            .login = login,
            .done = done,
        };
    }

    /// A row's target: an address, a pane, a script command, Nanolight
    /// itself, or an app (a file, a folder).
    pub fn open(ctx: *anyopaque, target: Target) void {
        const a = from(ctx);
        switch (target) {
            .url => |u| _ = nanoui.shell.openUrl(u),
            .pane => |i| _ = nanoui.shell.openUrl(settings_panes.urls[i]),
            .script => |t| if (a.hooks.opens) |h| h.func(h.ctx, t),
            .app => |path| {
                if (shell.Single.isSelf(path)) {
                    // Nanolight is already open: the panel comes back, empty,
                    // rather than macOS starting a second copy.
                    a.s.query.clear();
                    after.oneShot(reopen_ms, @as(*anyopaque, a), toggle);
                    return;
                }
                _ = apps.launch(a.app.io, path);
            },
        }
    }

    pub fn hide(ctx: *anyopaque) void {
        const a = from(ctx);
        a.s.hid(clock.now());
        if (a.window) |w| w.hide();
    }

    /// The window (or the Mac's glass under the panel) to its height.
    pub fn resize(ctx: *anyopaque, h: f32) void {
        const a = from(ctx);
        a.preview.fit(h);
        // The panel grew or shrank under a still pointer.
        a.through.height = h;
        a.through.update();
        if (a.window) |w| panel.resize(w, h);
    }

    pub fn toggle(ctx: *anyopaque) void {
        const a = from(ctx);
        const w = a.window orelse return;
        const showing = panel.showing(w);
        const welcome_up = a.s.screen == .welcome;
        if (welcome_up) a.o.pressed(showing);
        if (showing) {
            a.s.hid(clock.now());
            return w.hide();
        }
        Hook.run(a.hooks.showing);
        // Freed a key in System Settings, quit a launcher: look again.
        if (welcome_up) a.o.refresh();
        panel.place(w);
        Hook.run(a.hooks.rescan);
        if (a.s.show(clock.now())) Hook.run(a.hooks.popped);
        w.show();
        panel.shown(w);
        a.through.start();
        if (a.acct) |x| x.maybePull();
        w.redraw();
    }

    /// A search's page in the panel, or (null) not.
    pub fn showPage(ctx: *anyopaque, url: ?[]const u8) void {
        const a = from(ctx);
        const w = a.window orelse return;
        if (url) |u| a.preview.show(w, u, a.s.last_h) else a.preview.hide();
    }

    /// Escape (the page gone, the panel with it) or ⌘↩ while the page has the keys.
    fn pageKey(ctx: *anyopaque, key: PageKey) void {
        const a = from(ctx);
        switch (key) {
            .escape => a.s.escape(),
            .open_out => {
                var buf: [2048]u8 = undefined;
                const shown = switch (a.s.screen) {
                    .preview => |page| page.url,
                    else => "",
                };
                open(a, .{ .url = a.preview.current(&buf) orelse shown });
                hide(a);
            },
        }
        a.redraw();
    }

    /// The panel became, or stopped being, the key window (it hides as it
    /// stops): an "Updated" note is done. (An update waiting goes in once
    /// the panel has been away a while: nanoui's `autoRestart`.)
    pub fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const a = from(ctx);
        if (w.isFocused()) return;
        // Recording ends through Settings, which shows it: the key is back.
        a.s.settings_ui.stopRecording(a.s.host.settings);
        a.s.hid(clock.now());
        a.through.stop();
        a.s.note = "";
        panel.lostKeys(w);
        Hook.run(a.hooks.away);
    }

    /// `nanolight --toggle`, or a newer copy starting (single.zig).
    pub fn command(ctx: *anyopaque, cmd: single.Command) void {
        const a = from(ctx);
        // Claimed before the window: a command that lands in that moment
        // has nothing to show or hide yet (an older copy's socket did not
        // exist before, so none came).
        if (a.window == null) return;
        switch (cmd) {
            .toggle => toggle(a),
            .quit => a.app.quit(),
        }
    }

    pub fn menuChanged(a: *App) void {
        Hook.run(a.hooks.menu);
    }

    /// This machine changed `choice` (one of `settings.choices`), just now.
    pub fn touched(a: *App, comptime choice: settings.Field) void {
        comptime std.debug.assert(settings.isChoice(choice));
        // Unkept, this change then syncs as an older one.
        prefs.keepInt(a.kv, .sync_at, clock.now());
        if (a.acct) |x| x.changed();
    }

    pub fn useKey(a: *App, choice: keys.Choice) void {
        a.choice = choice;
        hotkey.register(choice, .{ .ctx = a, .func = toggle }) catch |e|
            std.log.warn(
                "nanolight: {f} can't be registered ({s}); open it from the menu bar",
                .{ shortcut.text(choice), @errorName(e) },
            );
    }

    /// Settings records a key: until it has one, keys pressed go to it,
    /// and the current key is let go (pressed, it is recorded too) once
    /// the recorder runs. Whether it is recording now.
    pub fn record(ctx: *anyopaque, on: bool) bool {
        const a = from(ctx);
        if (on) {
            // No recorder, no recording: the key stays registered.
            if (!a.recorder.start(.{ .ctx = a, .func = recorded })) return false;
            hotkey.unregister();
            return true;
        }
        a.recorder.stop();
        a.useKey(a.choice);
        return false;
    }

    fn recorded(ctx: *anyopaque, r: keys.Recorded) void {
        const a = from(ctx);
        a.s.recorded(r);
        a.redraw();
    }

    pub fn apply(ctx: *anyopaque, choice: keys.Choice) void {
        const a = from(ctx);
        prefs.keepHotkey(a.kv, choice);
        a.useKey(choice);
        a.touched(.hotkey);
    }

    fn fix(ctx: *anyopaque, clash: shortcut_clash.Clash) void {
        const a = from(ctx);
        if (clash.system != null) {
            _ = nanoui.shell.openUrl(keyboard_pane);
        } else for (clash.launchers.slice()) |name| shortcut_holders.quit(name);
        after.oneShot(launcher_quits_ms, a, lookAgain);
    }

    fn lookAgain(a: *App) void {
        a.o.refresh();
        a.redraw();
    }

    fn login(ctx: *anyopaque, set: ?bool) bool {
        return shell.Login.enabled(from(ctx).app.io, set);
    }

    fn done(ctx: *anyopaque) void {
        const a = from(ctx);
        // Unkept, the welcome shows again at the next start.
        prefs.keepFlag(a.kv, .onboarded, true);
    }

    /// The welcome, in place of the screen up. At the first run it is the
    /// first screen; asked in Settings, it takes the panel's place at once;
    /// from the menu, the panel comes up anew with it.
    pub fn welcome(a: *App, asked: enum { first_run, settings, menu }) void {
        a.o.start(a.choice);
        a.s.open(.{ .welcome = a.o });
        switch (asked) {
            .first_run => {},
            .settings => if (a.window) |w| if (w.isVisible()) w.redraw(),
            .menu => {
                if (a.window) |w| if (w.isVisible()) w.hide();
                a.showAfterMenu();
            },
        }
    }

    /// The menu's Open Nanolight: the panel takes the keys.
    pub fn showAfterMenu(a: *App) void {
        after.oneShot(menu_closes_ms, @as(*anyopaque, a), toggle);
    }

    /// The menu's Settings…: the panel opens straight into Settings.
    pub fn settingsAfterMenu(a: *App) void {
        after.oneShot(menu_closes_ms, a, openSettings);
    }

    fn openSettings(a: *App) void {
        const w = a.window orelse return;
        if (!(w.isVisible() and w.isFocused())) toggle(a);
        a.s.open(.settings);
        w.redraw();
    }
};
