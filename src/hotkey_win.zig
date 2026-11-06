//! Windows: the panel's key, from any app (RegisterHotKey). The system
//! sends WM_HOTKEY to Nanolight's message window (win_msg.zig, made by
//! `single_win.claim`), which calls `pressed`; pressing it also lets
//! Nanolight bring its window to the front.
const std = @import("std");
const keys = @import("keys.zig");
const Choice = keys.Choice;
const msg = @import("win_msg.zig");

extern "user32" fn RegisterHotKey(
    hwnd: ?msg.HWND,
    id: i32,
    mods: u32,
    vk: u32,
) callconv(.winapi) i32;
extern "user32" fn UnregisterHotKey(hwnd: ?msg.HWND, id: i32) callconv(.winapi) i32;

const mod_alt: u32 = 0x1;
const mod_control: u32 = 0x2;
const mod_shift: u32 = 0x4;
const mod_norepeat: u32 = 0x4000;
const vk_space: u32 = 0x20;
const id: i32 = 1;

var on_press: ?keys.Pressed = null;
var registered = false;
var current: u32 = 0;

/// The message window's WM_HOTKEY.
pub fn pressed() void {
    if (on_press) |p| p.func(p.ctx);
}

/// The modifiers to hold with Space: a PC offers no other key (`keys.any_key`).
fn modifiers(choice: Choice) u32 {
    std.debug.assert(choice.available());
    const p = choice.pc();
    var m: u32 = mod_norepeat;
    if (p.ctrl) m |= mod_control;
    if (p.alt) m |= mod_alt;
    if (p.shift) m |= mod_shift;
    return m;
}

pub fn register(choice: Choice, on: keys.Pressed) !void {
    on_press = on;
    const h = msg.window() orelse return error.NoWindow;
    if (registered) _ = UnregisterHotKey(h, id);
    registered = RegisterHotKey(h, id, modifiers(choice), vk_space) != 0;
    if (!registered) return error.HotKeyTaken;
    current = modifiers(choice);
}

/// Whether another app holds `choice`: registered and let go again.
pub fn taken(choice: Choice) bool {
    const m = modifiers(choice);
    if (registered and m == current) return false;
    const h = msg.window() orelse return false;
    if (RegisterHotKey(h, id + 1, m, vk_space) == 0) return true;
    _ = UnregisterHotKey(h, id + 1);
    return false;
}

test "the choices' modifiers" {
    try std.testing.expectEqual(mod_alt | mod_norepeat, modifiers(.cmd_space));
    try std.testing.expectEqual(mod_control | mod_shift | mod_norepeat, modifiers(.opt_cmd_space));
}
