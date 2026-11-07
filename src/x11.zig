//! libX11 as Nanolight uses it: the hot key's grab (hotkey_x11.zig), the
//! panel's focus (panel_x11.zig) and clipboard history (clipboard_x11.zig),
//! each over a connection of its own. The library is opened once, with
//! dlopen; its types and names are libX11's, not each user's.
const dl = @import("dl.zig");

pub const Display = opaque {};
pub const Window = c_ulong;
pub const Atom = c_ulong;
/// XEvent: a union 24 longs long; `type` first.
pub const Event = extern union { type: c_int, pad: [24]c_long };
pub const ErrorHandler = *const fn (*Display, *anyopaque) callconv(.c) c_int;

pub const property_notify: c_int = 28;
pub const property_change_mask: c_long = 1 << 22;

pub const Lib = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) Window,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *Event) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (?ErrorHandler) callconv(.c) ?ErrorHandler,
    XCreateSimpleWindow: *const fn (
        *Display,
        Window,
        c_int,
        c_int,
        c_uint,
        c_uint,
        c_uint,
        c_ulong,
        c_ulong,
    ) callconv(.c) Window,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    XGetAtomName: *const fn (*Display, Atom) callconv(.c) ?[*:0]u8,
    XConvertSelection: *const fn (*Display, Atom, Atom, Atom, Window, c_ulong) callconv(.c) c_int,
    XSetSelectionOwner: *const fn (*Display, Atom, Window, c_ulong) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (*Display, Atom) callconv(.c) Window,
    XGetWindowProperty: *const fn (
        *Display,
        Window,
        Atom,
        c_long,
        c_long,
        c_int,
        Atom,
        *Atom,
        *c_int,
        *c_ulong,
        *c_ulong,
        *?[*]u8,
    ) callconv(.c) c_int,
    XChangeProperty: *const fn (
        *Display,
        Window,
        Atom,
        Atom,
        c_int,
        c_int,
        [*]const u8,
        c_int,
    ) callconv(.c) c_int,
    XDeleteProperty: *const fn (*Display, Window, Atom) callconv(.c) c_int,
    XSendEvent: *const fn (*Display, Window, c_int, c_long, *Event) callconv(.c) c_int,
    XKeysymToKeycode: *const fn (*Display, c_ulong) callconv(.c) u8,
    XGrabKey: *const fn (*Display, c_int, c_uint, Window, c_int, c_int, c_int) callconv(.c) c_int,
    XUngrabKey: *const fn (*Display, c_int, c_uint, Window) callconv(.c) c_int,
    XMaxRequestSize: *const fn (*Display) callconv(.c) c_long,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
};

var lib: ?Lib = null;
var tried = false;

/// The functions, looked up on the first call; null (logged once) without
/// libX11.
pub fn load() ?Lib {
    if (!tried) {
        tried = true;
        lib = dl.table(Lib, &.{.{ .name = "libX11.so.6" }}, "no X11 hot key, focus or clipboard");
    }
    return lib;
}

/// The X server's time of the last press of the panel's key, set by
/// hotkey_x11.zig; 0 before one. Window managers refuse focus to a window
/// shown without a recent one (panel_x11.zig).
pub var last_press: u32 = 0;

// ----- where an event's fields are -----
// Xlib's events are unions of C structs, so a field's place is its offset
// in bytes: type, then the serial's padding, then the fields in order.

/// XKeyEvent's `time`, after type, serial, send_event, display and window.
pub const time_offset = 7 * @sizeOf(c_long);
/// XPropertyEvent's `atom`, after type, serial, send_event, display and window.
pub const atom_offset = 5 * @sizeOf(c_long);

// ----- the atoms every client knows -----
/// XA_ATOM.
pub const xa_atom: Atom = 4;
/// XA_STRING.
pub const xa_string: Atom = 31;
/// XA_WINDOW.
pub const xa_window: Atom = 33;
