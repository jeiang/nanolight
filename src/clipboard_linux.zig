//! Clipboard history on Linux (X11 selections, Wayland data-control): not
//! done yet. History is unavailable here, and says so; copying an entry
//! still works for text.
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");

pub const Watcher = struct {
    pub const available = false;
    pub const unavailable_reason = "Clipboard history is not available on Linux yet.";

    pub fn start(_: *Watcher, _: clipboard.Sink) !void {
        return error.Unsupported;
    }

    pub fn stop(_: *Watcher) void {}

    pub fn noteFrontmost(_: *Watcher) void {}

    pub fn paste(w: *Watcher, c: clipboard.Content, _: clipboard.Hide) clipboard.PasteResult {
        return if (w.copy(c)) .copied_unsupported else .failed;
    }

    /// Text and file paths (as text); an image has no way onto the clipboard here yet.
    pub fn copy(_: *Watcher, c: clipboard.Content) bool {
        if (c.kind == .image) return false;
        nanoui.clipboard.writeText(c.text);
        return true;
    }
};
