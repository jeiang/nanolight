//! The menu bar icon and its menu, as the Mac's status item (nanoui's tray).
//! A PC has none yet: pc_stubs.zig's `Tray` keeps the same declarations and
//! does nothing, so the menu's code has no OS branch of its own.
const nanoui = @import("nanoui");

pub const Tray = struct {
    item: *nanoui.Tray,

    pub fn make(app: *nanoui.App, symbol: []const u8, tooltip: []const u8) !Tray {
        return .{ .item = try app.newTray(.{ .symbol = symbol, .tooltip = tooltip }) };
    }

    /// The icon's glyph (SF Symbols), as the theme's.
    pub fn setSymbol(t: Tray, name: []const u8) void {
        t.item.setSymbol(name);
    }

    pub fn visible(t: Tray) bool {
        const objc = nanoui.objc;
        return objc.msg(objc.BOOL, t.item, "isVisible", .{}) == objc.YES;
    }

    pub fn show(t: Tray, on: bool) void {
        const objc = nanoui.objc;
        objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
    }

    /// Its menu, or none: `items` replaces what it had.
    pub fn menu(t: Tray, title: []const u8, items: []const nanoui.menu.MenuItem) void {
        // best effort: without the menu, the panel still opens from its key.
        t.item.setMenu(title, items) catch {};
    }
};
