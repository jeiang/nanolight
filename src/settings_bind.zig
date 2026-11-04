//! Live's answers to Settings. The box is one, its context set to the
//! Live that is showing the panel (one Nanolight runs).
const nanoui = @import("nanoui");
const shortcut = @import("shortcut.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
pub var box: SettingsHost = .{
    .ctx = undefined,
    .choice = choice,
    .apply = @import("main.zig").applyChoice,
    .record = @import("main.zig").recordKey,
    .login = @import("main.zig").loginItem,
    .suggest = suggest,
    .searches_out = searchesOut,
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
    var item: nanoui.menu.Item = undefined;
    item.checked = on;
    l(ctx).toggleSuggest(&item);
}

fn searchesOut(ctx: *anyopaque, on: bool) void {
    l(ctx).setSearchesOut(on);
}

fn menuBar(ctx: *anyopaque, set: ?bool) bool {
    return l(ctx).menuBar(set);
}

fn syncStatus(ctx: *anyopaque) []const u8 {
    return l(ctx).syncStatus();
}

fn version(ctx: *anyopaque) []const u8 {
    const u = l(ctx).updater orelse return "0.1.0";
    return if (u.current.len > 0) u.current else "0.1.0";
}

fn ready(ctx: *anyopaque) ?[]const u8 {
    const u = l(ctx).updater orelse return null;
    return u.ready();
}

fn check(ctx: *anyopaque) void {
    if (l(ctx).updater) |u| u.checkNow();
}

fn restart(ctx: *anyopaque) void {
    const live = l(ctx);
    const u = live.updater orelse return;
    if (u.ready() != null and u.restart()) live.app.quit();
}

fn welcome(ctx: *anyopaque) void {
    const live = l(ctx);
    live.o.start(live.choice);
    if (live.window) |w| if (w.isVisible()) w.redraw();
}

fn quit(ctx: *anyopaque) void {
    l(ctx).app.quit();
}
