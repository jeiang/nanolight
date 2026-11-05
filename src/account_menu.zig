//! The menu bar's sync row: the status, as text. Nothing to click.
const nanoui = @import("nanoui");
const account = @import("account.zig");

pub fn item(a: ?*const account.Account, label: []u8) nanoui.menu.MenuItem {
    const text = if (a) |acct| acct.status(label) else account.off_text;
    return .{ .label = text, .disabled = true };
}
