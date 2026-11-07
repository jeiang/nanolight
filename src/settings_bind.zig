//! Settings' answers (settings_host.zig), each from what owns it: the
//! app's key and welcome, file search, suggestions, the menu bar icon, the
//! clipboard history, sync and updates. Where searches open and the tint
//! are Settings' own.
const Choice = @import("keys.zig").Choice;
const prefs = @import("prefs.zig");
const platform = @import("platform.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Theme = @import("palette.zig").Theme;
const App = @import("app.zig").App;
const suggest_live = @import("suggest_live.zig");
const files_live = @import("files_live.zig");
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
            .login = platform.Login.enabled,
            .suggest = suggest,
            .files = files,
            .searches_out = searchesOut,
            .theme = theme,
            .menu_bar = menuBar,
            .clipboard_enabled = clipboardEnabled,
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

fn suggest(ctx: *anyopaque, on: bool) void {
    suggest_live.set(from(ctx).core, on, .here);
}

fn files(ctx: *anyopaque, on: bool) void {
    files_live.set(from(ctx).core, on);
}

fn searchesOut(ctx: *anyopaque, on: bool) void {
    const core = from(ctx).core;
    core.s.searches_out = on;
    prefs.keepFlag(core.kv, .searches_out, on);
}

fn theme(ctx: *anyopaque, t: Theme) void {
    const core = from(ctx).core;
    core.s.theme = t;
    // Unkept, the next launch has the old tint.
    prefs.keepTheme(core.kv, t);
    core.redraw();
}

fn menuBar(ctx: *anyopaque, set: ?bool) bool {
    return from(ctx).menu.bar(set);
}

fn clipboardEnabled(ctx: *anyopaque, set: ?bool) bool {
    return from(ctx).clip.enabled(set);
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
