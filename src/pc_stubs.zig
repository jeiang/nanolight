//! What the Mac has and Windows and Linux don't yet: a search's page in
//! the panel (preview.zig; there it opens in the browser instead) and
//! clicks passing through the window round the panel (clickthrough.zig;
//! there the window is the panel's size, so there is nothing to pass),
//! and recording a key of one's own (recorder.zig; there the four offered
//! are the choice).
const nanoui = @import("nanoui");

pub const Key = enum { escape, open_out };
pub const Watch = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, key: Key) void };

pub const Preview = struct {
    pub fn show(_: *Preview, _: *nanoui.Window, _: []const u8, _: f32) void {}
    pub fn hide(_: *Preview) void {}
    pub fn showing(_: *const Preview) bool {
        return false;
    }
    pub fn fit(_: *Preview, _: f32) void {}
    pub fn current(_: *const Preview, _: []u8) ?[]const u8 {
        return null;
    }
    pub fn watch(_: *Preview, _: Watch) void {}
};

pub const ClickThrough = struct {
    window: ?*nanoui.Window = null,
    height: ?*const f32 = null,
    pub fn start(_: *ClickThrough) void {}
    pub fn stop(_: *ClickThrough) void {}
    pub fn update(_: *ClickThrough) void {}
};

pub const Recorder = struct {
    pub const Got = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, r: @import("shortcut.zig").Recorded) void,
    };
    pub fn active(_: *const Recorder) bool {
        return false;
    }
    pub fn start(_: *Recorder, _: Got) bool {
        return false;
    }
    pub fn stop(_: *Recorder) void {}
};
