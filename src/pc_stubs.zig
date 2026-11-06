//! What the Mac has and Windows and Linux don't yet: a search's page in
//! the panel (preview.zig; there it opens in the browser instead) and
//! clicks passing through the window round the panel (clickthrough.zig;
//! there the window is the panel's size, so there is nothing to pass),
//! and recording a key of one's own (recorder.zig; there the four offered
//! are the choice). platform.zig checks each against the Mac's type.
const nanoui = @import("nanoui");
const preview = @import("preview.zig");
const recorder = @import("recorder.zig");

pub const Preview = struct {
    pub fn show(_: *Preview, _: *nanoui.Window, _: []const u8, _: f32) void {}
    pub fn hide(_: *Preview) void {}
    pub fn fit(_: *Preview, _: f32) void {}
    pub fn current(_: *const Preview, _: []u8) ?[]const u8 {
        return null;
    }
    pub fn watch(_: *Preview, _: preview.Watch) void {}
};

pub const ClickThrough = struct {
    window: ?*nanoui.Window = null,
    height: f32 = 0,
    pub fn start(_: *ClickThrough) void {}
    pub fn stop(_: *ClickThrough) void {}
    pub fn update(_: *ClickThrough) void {}
};

pub const Recorder = struct {
    pub fn active(_: *const Recorder) bool {
        return false;
    }
    pub fn start(_: *Recorder, _: recorder.Got) bool {
        return false;
    }
    pub fn stop(_: *Recorder) void {}
};
