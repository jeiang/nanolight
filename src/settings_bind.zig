//! Live's answers to Settings. The box is one, its context set to the
//! Live that is showing the panel (one Nanolight runs).
const shortcut = @import("shortcut.zig");
const prefs = @import("prefs.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Theme = @import("palette.zig").Theme;
pub var box: SettingsHost = .{
    .ctx = undefined,
    .choice = choice,
    .apply = @import("main.zig").applyChoice,
    .record = @import("main.zig").recordKey,
    .login = @import("main.zig").loginItem,
    .suggest = suggest,
    .files = files,
    .searches_out = searchesOut,
    .theme = theme,
    .menu_bar = menuBar,
    .clipboard_enabled = @import("clipboard_live.zig").enabled,
    .clipboard_clear = @import("clipboard_live.zig").clear,
    .sync_status = syncStatus,
    .version = version,
    .ready = ready,
    .check = check,
    .restart = restart,
    .welcome = welcome,
    .quit = quit,
};

const Live = @import("main.zig").Live;

fn l(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn choice(ctx: *anyopaque) shortcut.Choice {
    return l(ctx).choice;
}

fn suggest(ctx: *anyopaque, on: bool) void {
    l(ctx).setSuggest(on, .here);
}

fn files(ctx: *anyopaque, on: bool) void {
    const live = l(ctx);
    live.s.files_on = on;
    live.s.built = 1;
    // A failure is logged; file search follows the switch this run either way.
    _ = prefs.setFlag(live.kv, .files, on);
}

fn searchesOut(ctx: *anyopaque, on: bool) void {
    l(ctx).setSearchesOut(on);
}

fn theme(ctx: *anyopaque, t: Theme) void {
    const live = l(ctx);
    live.s.theme = t;
    // A failure is logged; the next launch then has the old tint.
    _ = prefs.setTheme(live.kv, t);
    if (live.window) |w| w.redraw();
}

fn menuBar(ctx: *anyopaque, set: ?bool) bool {
    return l(ctx).menuBar(set);
}

fn syncStatus(ctx: *anyopaque) []const u8 {
    return l(ctx).syncStatus();
}

/// The updater's version, else the build's.
fn version(ctx: *anyopaque) []const u8 {
    const built = @import("build_options").version;
    const u = l(ctx).updater orelse return built;
    return if (u.current.len > 0) u.current else built;
}

fn ready(ctx: *anyopaque) ?[]const u8 {
    const u = l(ctx).updater orelse return null;
    return u.ready();
}

fn check(ctx: *anyopaque) void {
    if (l(ctx).updater) |u| u.checkNow();
}

fn restart(ctx: *anyopaque) void {
    l(ctx).restartForUpdate();
}

fn welcome(ctx: *anyopaque) void {
    const live = l(ctx);
    live.o.start(live.choice);
    if (live.window) |w| if (w.isVisible()) w.redraw();
}

fn quit(ctx: *anyopaque) void {
    l(ctx).app.quit();
}
