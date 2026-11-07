//! The menu bar icon and its menu (the Mac; nanoui has no tray on Windows
//! and Linux yet): Settings, the panel, the welcome, Google's suggestions,
//! the sync status, and the update waiting, if one is.
const nanoui = @import("nanoui");
const platform = @import("platform.zig");
const shell = @import("shell.zig");
const update_live = @import("update_live.zig");
const account_live = @import("account_live.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;
const after = @import("after.zig");
const app_name = @import("app_facts.zig").app_name;

pub const Menu = struct {
    core: *App,
    update: *update_live.Update,
    sync: *account_live.Sync,
    tray: ?shell.Tray = null,
    /// Whether the icon is to show, until the tray is made (its switch is
    /// loaded first: settings_bind.zig `Bind.load`).
    wanted: bool = true,

    /// The icon, unless Settings took it away.
    pub fn start(m: *Menu) !void {
        m.tray = try shell.Tray.make(m.core.app, "magnifyingglass", app_name);
        if (!m.wanted) m.showIcon(false);
    }

    pub fn menuHook(m: *Menu) Hook {
        return .{ .ctx = m, .func = rebuild };
    }

    /// Whether the menu bar icon shows.
    pub fn iconShown(m: *const Menu) bool {
        const t = m.tray orelse return false;
        return t.visible();
    }

    /// Shows or hides the menu bar icon. Hidden, Nanolight is its key
    /// alone: Settings stays in the panel (⌘,), and opening the app again
    /// shows the panel. The status item stays, only unseen (nanoui's App
    /// keeps its trays until it quits).
    pub fn showIcon(m: *Menu, on: bool) void {
        m.wanted = on;
        const t = m.tray orelse return;
        t.show(on);
    }

    fn settings(m: *Menu, _: *nanoui.menu.Item) void {
        m.core.settingsAfterMenu();
    }

    fn show(m: *Menu, _: *nanoui.menu.Item) void {
        m.core.showAfterMenu();
    }

    fn welcome(m: *Menu, _: *nanoui.menu.Item) void {
        m.core.welcome(.menu);
    }

    fn suggestions(m: *Menu, item: *nanoui.menu.Item) void {
        m.core.toggles.set(.suggest, item.checked, .here);
    }
};

fn rebuild(ctx: *anyopaque) void {
    const m = after.cast(*Menu, ctx);
    const t = m.tray orelse return;
    const Item = nanoui.menu.MenuItem;
    const update = if (platform.updater) [_]Item{m.update.menuItem()} else [_]Item{};
    t.menu(app_name, &([_]Item{
        .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(m, Menu.settings) },
        .{ .label = "Open " ++ app_name, .click = .of(m, Menu.show) },
        .{ .label = "Welcome…", .click = .of(m, Menu.welcome) },
        .{
            .label = "Google Suggestions",
            .kind = .checkbox,
            .checked = m.core.toggles.get(.suggest),
            .click = .of(m, Menu.suggestions),
        },
        .separator,
        m.sync.menuItem(),
        .separator,
    } ++ update ++ [_]Item{.{ .label = "Quit " ++ app_name, .role = .quit }}));
}
