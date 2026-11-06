//! The menu bar icon and its menu (the Mac; nanoui has no tray on Windows
//! and Linux yet): Settings, the panel, the welcome, Google's suggestions,
//! the sync status, and the update waiting, if one is.
const nanoui = @import("nanoui");
const prefs = @import("prefs.zig");
const platform = @import("platform.zig");
const suggest_live = @import("suggest_live.zig");
const update_live = @import("update_live.zig");
const account_live = @import("account_live.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;
const after = @import("after.zig");
/// A Nix build: no updater, so no update item.
const nix_managed = @import("build_options").nix_managed;

pub const Menu = struct {
    core: *App,
    update: *update_live.Update,
    sync: *account_live.Sync,
    tray: ?*nanoui.Tray = null,

    /// The icon, unless Settings took it away.
    pub fn start(m: *Menu) !void {
        if (comptime !platform.tray) return;
        m.tray = try m.core.app.newTray(.{ .symbol = "magnifyingglass", .tooltip = "Nanolight" });
        if (!prefs.flag(m.core.kv, m.core.app.gpa, .menu_bar)) _ = m.bar(false);
    }

    pub fn menuHook(m: *Menu) Hook {
        return .{ .ctx = m, .func = rebuild };
    }

    /// Whether the menu bar icon shows; `set` shows or hides it. Hidden,
    /// Nanolight is its key alone: Settings stays in the panel (⌘,), and
    /// opening the app again shows the panel. The status item stays, only
    /// unseen (nanoui's App keeps its trays until it quits).
    pub fn bar(m: *Menu, set: ?bool) bool {
        if (comptime !platform.tray) return false;
        const objc = nanoui.objc;
        const t = m.tray orelse return false;
        if (set) |on| {
            _ = prefs.setFlag(m.core.kv, .menu_bar, on);
            objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
        }
        return objc.msg(objc.BOOL, t.item, "isVisible", .{});
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
        suggest_live.set(m.core, item.checked, .here);
    }
};

fn rebuild(ctx: *anyopaque) void {
    if (comptime !platform.tray) return;
    const m = after.cast(*Menu, ctx);
    const t = m.tray orelse return;
    const Item = nanoui.menu.MenuItem;
    const update = if (nix_managed) [_]Item{} else [_]Item{m.update.menuItem()};
    t.setMenu("Nanolight", &([_]Item{
        .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(m, Menu.settings) },
        .{ .label = "Open Nanolight", .click = .of(m, Menu.show) },
        .{ .label = "Welcome…", .click = .of(m, Menu.welcome) },
        .{
            .label = "Google Suggestions",
            .kind = .checkbox,
            .checked = m.core.s.suggest_on,
            .click = .of(m, Menu.suggestions),
        },
        .separator,
        m.sync.menuItem(),
        .separator,
        // best effort: without the menu, the panel still opens from its key.
    } ++ update ++ [_]Item{.{ .label = "Quit Nanolight", .role = .quit }})) catch {};
}
