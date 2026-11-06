//! The key combination that opens the panel from any app: Carbon's hot keys
//! on the Mac (hotkey_mac.zig), RegisterHotKey on Windows (hotkey_win.zig),
//! a key grab on X11 (hotkey_x11.zig). Wayland lets no app take a key for
//! the whole desktop: there the desktop's own shortcut settings run
//! `nanolight --toggle` (single.zig).
const builtin = @import("builtin");
const keys = @import("keys.zig");

const impl = switch (builtin.os.tag) {
    .macos => @import("hotkey_mac.zig"),
    .windows => @import("hotkey_win.zig"),
    else => @import("hotkey_x11.zig"),
};

/// Calls `on` on the main thread each time `choice` is pressed, from any
/// app. One per app: registering again replaces it.
pub fn register(choice: keys.Choice, on: keys.Pressed) !void {
    return impl.register(choice, on);
}

/// Gives the key back (while another is recorded); `register` takes one again.
pub fn unregister() void {
    if (@hasDecl(impl, "unregister")) impl.unregister();
}

/// Whether another program holds `choice` (Windows, X11; on the Mac the
/// system's shortcut table says, shortcut_clash.zig).
pub fn taken(choice: keys.Choice) bool {
    return if (@hasDecl(impl, "taken")) impl.taken(choice) else false;
}
