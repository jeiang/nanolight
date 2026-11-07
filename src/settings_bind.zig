//! Settings' answers (settings_host.zig), each from what owns it: the
//! app's key and welcome, the clipboard history, sync and updates; and
//! every switch (toggles.zig), changed, kept and loaded one way here.
const std = @import("std");
const Choice = @import("keys.zig").Choice;
const prefs = @import("prefs.zig");
const shell = @import("shell.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const toggles = @import("toggles.zig");
const Toggle = toggles.Toggle;
const Theme = @import("palette.zig").Theme;
const App = @import("app.zig").App;
const after = @import("after.zig");
const menu_live = @import("menu_live.zig");
const clipboard_live = @import("clipboard_live.zig");
const account_live = @import("account_live.zig");
const update_live = @import("update_live.zig");

pub const Bind = struct {
    core: *App,
    menu: *menu_live.Menu,
    clip: *clipboard_live.Clip,
    sync: *account_live.Sync,
    update: *update_live.Update,

    pub fn host(b: *Bind) SettingsHost {
        return .{
            .ctx = b,
            .choice = choice,
            .apply = apply,
            .record = record,
            .toggle = toggle,
            .theme = theme,
            .clipboard_clear = clipboardClear,
            .sync_status = syncStatus,
            .version = version,
            .ready = ready,
            .check = check,
            .restart = restart,
            .welcome = welcome,
            .quit = quit,
        };
    }

    /// How the menu's checkbox and sync change a switch (`App.toggles`).
    pub fn setter(b: *Bind) toggles.Setter {
        return .{ .ctx = b, .func = setFrom };
    }

    /// Every switch this build shows, as kept (or its owner's or prefs'
    /// default), into its owner: once its owners are there (the clipboard's
    /// store opened; the menu bar icon, made after, follows what this says).
    pub fn load(b: *Bind) void {
        const gpa = b.core.app.gpa;
        const clip = b.core.s.hasClipboard();
        inline for (comptime std.enums.values(Toggle)) |t| {
            if (comptime t.row().pref != null) {
                if (t.present(clip)) b.own(t, t.kept(b.core.kv, gpa, b.unset(t)), true);
            }
        }
    }

    /// The one way a switch changes: kept, its owner told, synced when it
    /// syncs and changed `here`. The menu's checkbox follows.
    pub fn set(b: *Bind, t: Toggle, on: bool, origin: toggles.Origin) void {
        if (on == b.get(t)) return;
        switch (t) {
            inline else => |ct| {
                const row = comptime ct.row();
                // Unkept, the switch holds for this run; the next launch has the old one.
                const kept = if (row.pref) |k| prefs.setFlag(b.core.kv, k, on) else true;
                b.own(ct, on, kept);
                if (row.syncs) |f| if (origin == .here) b.core.touched(f);
            },
        }
        b.core.redraw();
        // Never rebuilt inside its own click.
        after.oneShot(0, b.core, App.menuChanged);
    }

    /// What the switch's owner says.
    fn get(b: *const Bind, t: Toggle) bool {
        const s = b.core.s;
        return switch (t) {
            .suggest => s.suggest_on,
            .files => s.files_on,
            .browser => s.searches_out,
            .login => shell.Login.enabled(null),
            .menu_bar => b.menu.iconShown(),
            .clipboard => b.clip.recording(),
        };
    }

    /// What the switch's owner says it is when nothing is kept; null for
    /// prefs.zig's default.
    fn unset(b: *const Bind, t: Toggle) ?bool {
        return switch (t) {
            .clipboard => b.clip.configured(),
            .suggest, .files, .browser, .login, .menu_bar => null,
        };
    }

    /// The switch's owner made to match `on`, `kept` when it was kept.
    fn own(b: *Bind, t: Toggle, on: bool, kept: bool) void {
        const s = b.core.s;
        switch (t) {
            .suggest => s.setSuggest(on),
            .files => s.setFiles(on),
            .browser => s.searches_out = on,
            .login => _ = shell.Login.enabled(on),
            .menu_bar => b.menu.showIcon(on),
            .clipboard => b.clip.turn(on, kept),
        }
    }
};

fn from(ctx: *anyopaque) *Bind {
    return @ptrCast(@alignCast(ctx));
}

fn choice(ctx: *anyopaque) Choice {
    return from(ctx).core.choice;
}

fn apply(ctx: *anyopaque, c: Choice) void {
    App.apply(from(ctx).core, c);
}

fn record(ctx: *anyopaque, on: bool) bool {
    return App.record(from(ctx).core, on);
}

fn toggle(ctx: *anyopaque, t: Toggle, set: ?bool) bool {
    const b = from(ctx);
    if (set) |on| b.set(t, on, .here);
    return b.get(t);
}

fn setFrom(ctx: *anyopaque, t: Toggle, on: bool, origin: toggles.Origin) void {
    from(ctx).set(t, on, origin);
}

fn theme(ctx: *anyopaque, set: ?Theme) Theme {
    const core = from(ctx).core;
    if (set) |t| {
        core.s.theme = t;
        // Unkept, the next launch has the old tint.
        prefs.keepText(core.kv, .theme, @tagName(t));
        core.redraw();
    }
    return core.s.theme;
}

fn clipboardClear(ctx: *anyopaque) bool {
    return from(ctx).clip.clear();
}

fn syncStatus(ctx: *anyopaque) []const u8 {
    return from(ctx).sync.status();
}

fn version(ctx: *anyopaque) []const u8 {
    return from(ctx).update.version();
}

fn ready(ctx: *anyopaque) ?[]const u8 {
    return from(ctx).update.ready();
}

fn check(ctx: *anyopaque) void {
    from(ctx).update.check();
}

fn restart(ctx: *anyopaque) void {
    from(ctx).update.restart();
}

fn welcome(ctx: *anyopaque) void {
    from(ctx).core.welcome(.settings);
}

fn quit(ctx: *anyopaque) void {
    from(ctx).core.app.quit();
}
