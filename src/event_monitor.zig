//! The Mac: AppKit's event monitors (NSEvent), for the masks this app
//! watches. A local monitor sees the app's own events before its windows
//! do, and may keep them (its handler returns null); a global one sees
//! other apps' events, and can only look.
const nanoui = @import("nanoui");
const objc = nanoui.objc;

/// NSEventMask bits.
pub const key_down: u64 = 1 << 10;
pub const mouse_moved: u64 = 1 << 5;
pub const left_dragged: u64 = 1 << 6;

pub const Scope = enum { local, global };

/// A monitor for `mask` calling `block` (an `objc.Block`/`objc.BlockRet`,
/// which AppKit copies), retained until `remove`; null if AppKit gave none.
pub fn add(scope: Scope, mask: u64, block: *anyopaque) ?objc.Object {
    const sel = switch (scope) {
        .local => "addLocalMonitorForEventsMatchingMask:handler:",
        .global => "addGlobalMonitorForEventsMatchingMask:handler:",
    };
    const m = objc.msg(?objc.Object, objc.class("NSEvent"), sel, .{ mask, block }) orelse
        return null;
    objc.msg(void, m, "retain", .{});
    return m;
}

/// Ends a monitor from `add`, and lets it go.
pub fn remove(m: objc.Object) void {
    objc.msg(void, objc.class("NSEvent"), "removeMonitor:", .{m});
    objc.release(m);
}
