//! Records the key that is to open the panel, from Settings: the next key
//! pressed while the panel has the keys. An event monitor of the app's
//! own sees it before the panel does (and keeps it from the panel), with
//! what Carbon's hot keys need: the key's code, where it is on the
//! keyboard, not the letter a layout puts there. On only while recording.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const keys = @import("keys.zig");
const monitor = @import("event_monitor.zig");
const after = @import("after.zig");

pub const Got = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, r: keys.Recorded) void,
};

pub const Recorder = struct {
    monitor: ?objc.Object = null,
    got: ?Got = null,
    /// The key seen, handed on once the monitor's handler has returned
    /// (handling it may stop the monitor).
    last: ?keys.Recorded = null,

    pub fn active(r: *const Recorder) bool {
        return r.monitor != null;
    }

    /// Whether the monitor is on: keys pressed go to `got` from now on.
    pub fn start(r: *Recorder, got: Got) bool {
        r.got = got;
        if (r.monitor != null) return true;
        var b = objc.BlockRet(Recorder, &.{objc.Object}, ?objc.Object).init(r, seen);
        r.monitor = monitor.add(.local, monitor.key_down, @ptrCast(&b)) orelse return false;
        return true;
    }

    pub fn stop(r: *Recorder) void {
        const m = r.monitor orelse return;
        monitor.remove(m);
        r.monitor = null;
        r.last = null;
    }

    fn seen(r: *Recorder, ev: objc.Object) ?objc.Object {
        const code = objc.msg(u16, ev, "keyCode", .{});
        const flags: u64 = objc.msg(objc.NSUInteger, ev, "modifierFlags", .{});
        // What the key types without modifiers: "x" for ⌥X, not "≈".
        const plain = objc.msg(
            ?objc.Object,
            ev,
            "charactersByApplyingModifiers:",
            .{@as(objc.NSUInteger, 0)},
        );
        const s = objc.fromNSString(plain);
        const len = if (s.len > 0) std.unicode.utf8ByteSequenceLength(s[0]) catch 1 else 0;
        const ch: u21 = if (len > 0 and
            len <= s.len) std.unicode.utf8Decode(s[0..len]) catch 0 else 0;
        r.last = keys.recorded(code, flags, ch);
        after.oneShot(0, r, deliver);
        return null;
    }

    fn deliver(r: *Recorder) void {
        const last = r.last orelse return;
        r.last = null;
        const got = r.got orelse return;
        got.func(got.ctx, last);
    }
};
