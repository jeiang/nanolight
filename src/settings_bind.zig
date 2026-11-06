//! Live's answers to Settings. The box is one, its context set to the
//! Live that is showing the panel (one Nanolight runs).
const nanoui = @import("nanoui");
const shortcut = @import("shortcut.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Theme = @import("palette.zig").Theme;
pub var box: SettingsHost = .{
    .ctx = undefined,
    .choice = choice,
    .apply = @import("main.zig").applyChoice,
    .record = @import("main.zig").recordKey,
    .login = @import("main.zig").loginItem,
    .suggest = suggest,
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

fn searchesOut(ctx: *anyopaque, on: bool) void {
    l(ctx).setSearchesOut(on);
}

/// The panel's tint: a `Theme`'s name ("system" when unset).
const theme_key = "nanolight.theme";

fn theme(ctx: *anyopaque, t: Theme) void {
    const live = l(ctx);
    live.s.theme = t;
    live.kv.set(theme_key, @tagName(t)) catch {};
    if (live.window) |w| w.redraw();
}

/// The theme kept on this Mac, at launch.
pub fn loadTheme(kv: nanoui.kv.Store, gpa: @import("std").mem.Allocator) Theme {
    const v = kv.get(gpa, theme_key) catch null orelse return .system;
    defer gpa.free(v);
    return @import("std").meta.stringToEnum(Theme, v) orelse .system;
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
