//! What the window server shows: Nanolight's windows on screen, as a person
//! sees them (CGWindowListCopyWindowInfo). Its panel is any of them taller
//! than the menu bar icon's.
const std = @import("std");
const assert = std.debug.assert;

/// Taller than this is a panel; the menu bar icon's window is shorter.
pub const panel_height_min = 60;
const windows_max = 64;
const owner = "nanolight";
const owner_bytes_max = 256;

const CFTypeRef = *const anyopaque;
const CFIndex = isize;
const CGRect = extern struct { x: f64, y: f64, width: f64, height: f64 };
const option_on_screen_only: u32 = 1 << 0;
const null_window_id: u32 = 0;
const utf8_encoding: u32 = 0x08000100;

extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?CFTypeRef;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dictionary: CFTypeRef, rect: *CGRect) bool;
extern "c" fn CFArrayGetCount(array: CFTypeRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) ?CFTypeRef;
extern "c" fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) ?CFTypeRef;
extern "c" fn CFStringGetCString(string: CFTypeRef, buffer: [*]u8, size: CFIndex, encoding: u32) u8;
extern "c" fn CFRelease(value: CFTypeRef) void;
extern "c" const kCGWindowOwnerName: CFTypeRef;
extern "c" const kCGWindowBounds: CFTypeRef;

/// A window's place on screen, in points, as whole numbers (as Swift's `intValue`).
pub const Window = struct { x: i64, y: i64, width: i64, height: i64 };

/// Nanolight's panels on screen, front to back, into `buffer`.
pub fn panels(buffer: *[windows_max]Window) []Window {
    const list = CGWindowListCopyWindowInfo(option_on_screen_only, null_window_id) orelse
        return buffer[0..0];
    defer CFRelease(list);
    var count: usize = 0;
    const total = CFArrayGetCount(list);
    var index: CFIndex = 0;
    while (index < total and count < buffer.len) : (index += 1) {
        const info = CFArrayGetValueAtIndex(list, index) orelse continue;
        if (!ownedByNanolight(info)) continue;
        const bounds = CFDictionaryGetValue(info, kCGWindowBounds) orelse continue;
        var rect: CGRect = undefined;
        if (!CGRectMakeWithDictionaryRepresentation(bounds, &rect)) continue;
        const window: Window = .{
            .x = @intFromFloat(@trunc(rect.x)),
            .y = @intFromFloat(@trunc(rect.y)),
            .width = @intFromFloat(@trunc(rect.width)),
            .height = @intFromFloat(@trunc(rect.height)),
        };
        if (window.height <= panel_height_min) continue;
        buffer[count] = window;
        count += 1;
    }
    return buffer[0..count];
}

pub fn panelCount() usize {
    var buffer: [windows_max]Window = undefined;
    return panels(&buffer).len;
}

/// The frontmost panel, if one is on screen.
pub fn firstPanel() ?Window {
    var buffer: [windows_max]Window = undefined;
    const found = panels(&buffer);
    return if (found.len > 0) found[0] else null;
}

fn ownedByNanolight(info: CFTypeRef) bool {
    const name = CFDictionaryGetValue(info, kCGWindowOwnerName) orelse return false;
    var buffer: [owner_bytes_max]u8 = undefined;
    if (CFStringGetCString(name, &buffer, buffer.len, utf8_encoding) == 0) return false;
    const text = std.mem.sliceTo(&buffer, 0);
    return std.ascii.eqlIgnoreCase(text, owner);
}
