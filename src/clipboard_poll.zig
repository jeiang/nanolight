//! The watcher the Mac and Windows share: the clipboard's change count
//! polled every `poll_ms` on the main run loop, and a paste that writes the
//! entry, hides the panel, wakes the app that had the keys and sends it the
//! paste keystroke. The OS's side is `B` (clipboard_mac.zig, clipboard_win.zig).
const nanoui = @import("nanoui");
const clipboard = @import("clipboard_types.zig");

const poll_ms = 500;
const paste_delay_ms = clipboard.paste_delay_ms;

/// `B` has, all called on the main thread:
///
///   `changeCount()`: changes whenever anything writes the clipboard
///   `read(b, sink)`: tells `sink` what the clipboard holds now
///   `write(c) bool`: makes `c` the clipboard's one item
///   `noteFrontmost(b)`: remembers the app in front, unless it is this one
///   `keysAllowed(b) bool`: whether keys may be sent to other apps
///   `wake(b)`: brings back the app `noteFrontmost` remembered
///   `sendPaste`: the keystroke, as a timer callback
pub fn PollWatcher(comptime B: type) type {
    return struct {
        const W = @This();
        const Count = @typeInfo(@TypeOf(B.changeCount)).@"fn".return_type.?;

        os: B = .{},
        sink: ?clipboard.Sink = null,
        running: bool = false,
        /// A tick is waiting on the run loop: `start` after `stop` reuses it.
        armed: bool = false,
        /// The change count as last seen or last written here, so what
        /// Nanolight writes itself is not recorded.
        last: Count = 0,

        pub fn start(w: *W, sink: clipboard.Sink) clipboard.StartError!void {
            w.sink = sink;
            w.last = B.changeCount();
            w.running = true;
            if (!w.armed) {
                w.armed = true;
                nanoui.App.after(poll_ms, w, tick);
            }
        }

        pub fn stop(w: *W) void {
            w.running = false;
        }

        /// A poll watcher always starts.
        pub fn status(_: *const W) ?[]const u8 {
            return null;
        }

        fn tick(ctx: ?*anyopaque) callconv(.c) void {
            const w: *W = @ptrCast(@alignCast(ctx.?));
            if (!w.running) {
                w.armed = false;
                return;
            }
            w.poll();
            nanoui.App.after(poll_ms, w, tick);
        }

        fn poll(w: *W) void {
            const count = B.changeCount();
            if (count == w.last) return;
            w.last = count;
            const sink = w.sink orelse return;
            w.os.read(sink);
        }

        pub fn noteFrontmost(w: *W) void {
            w.os.noteFrontmost();
        }

        pub fn paste(w: *W, c: clipboard.Content, hide: clipboard.Hide) clipboard.PasteResult {
            if (!w.copy(c)) return .failed;
            if (!w.os.keysAllowed()) return .copied_no_permission;
            hide.func(hide.ctx);
            w.os.wake();
            nanoui.App.after(paste_delay_ms, null, B.sendPaste);
            return .pasted;
        }

        pub fn copy(w: *W, c: clipboard.Content) bool {
            const ok = B.write(c);
            w.last = B.changeCount();
            return ok;
        }
    };
}
