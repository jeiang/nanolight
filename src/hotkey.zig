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

comptime {
    conforms(impl);
}

/// Calls `on` on the main thread each time `choice` is pressed, from any
/// app. One per app: registering again replaces it.
pub fn register(choice: keys.Choice, on: keys.Pressed) !void {
    return impl.register(choice, on);
}

/// Gives the key back (while another is recorded); `register` takes one again.
pub fn unregister() void {
    impl.unregister();
}

/// Whether another program holds `choice` (Windows, X11; on the Mac the
/// system's shortcut table says, shortcut_holders.zig).
pub fn taken(choice: keys.Choice) bool {
    return impl.taken(choice);
}

/// Fails the build unless `Backend` declares the three above, of their
/// types (`register`'s errors its own).
fn conforms(comptime Backend: type) void {
    const register_fn = @typeInfo(@TypeOf(Backend.register)).@"fn";
    const params = register_fn.param_types;
    if (params.len != 2 or params[0].? != keys.Choice or params[1].? != keys.Pressed or
        @typeInfo(register_fn.return_type.?).error_union.payload != void)
        @compileError(@typeName(Backend) ++ ".register is not fn (Choice, Pressed) !void");
    if (@TypeOf(Backend.unregister) != fn () void)
        @compileError(@typeName(Backend) ++ ".unregister is not fn () void");
    if (@TypeOf(Backend.taken) != fn (keys.Choice) bool)
        @compileError(@typeName(Backend) ++ ".taken is not fn (keys.Choice) bool");
}

test "every OS's backend has the same surface" {
    comptime {
        conforms(@import("hotkey_mac.zig"));
        conforms(@import("hotkey_win.zig"));
        conforms(@import("hotkey_x11.zig"));
    }
}
