//! One Nanolight at a time. Opening its own row from the panel would ask
//! macOS to open Nanolight.app, and once the bundle on disk has been
//! replaced (an update, a reinstall) macOS takes it for another app and
//! starts a second copy: a second menu bar icon, a second hot key. So the
//! panel recognises itself (`isSelf`), and a copy that starts while others
//! run quits them (`quitOthers`): the newest launch is the newest code.
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const single = @import("single.zig");

fn ours() ?objc.Object {
    const main = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, main, "bundleIdentifier", .{});
}

/// Whether the app at `path` is Nanolight (any copy of it).
pub fn isSelf(path: []const u8) bool {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return false;
    const b = objc.msg(
        ?objc.Object,
        objc.class("NSBundle"),
        "bundleWithPath:",
        .{objc.nsString(path)},
    ) orelse
        return false;
    const theirs = objc.msg(?objc.Object, b, "bundleIdentifier", .{}) orelse return false;
    return objc.msg(objc.BOOL, id, "isEqualToString:", .{theirs}) != objc.NO;
}

/// Asks every other running Nanolight to quit. Returns how many.
pub fn quitOthers() usize {
    const pool = objc.Pool.push();
    defer pool.pop();
    const id = ours() orelse return 0;
    const cls = objc.class("NSRunningApplication");
    const me = objc.msg(
        i32,
        objc.msg(objc.Object, cls, "currentApplication", .{}),
        "processIdentifier",
        .{},
    );
    const apps = objc.msg(objc.Object, cls, "runningApplicationsWithBundleIdentifier:", .{id});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{@as(objc.NSUInteger, i)});
        if (objc.msg(i32, a, "processIdentifier", .{}) == me) continue;
        _ = objc.msg(objc.BOOL, a, "terminate", .{});
        n += 1;
    }
    return n;
}

/// single.zig's: older copies quit; commands from a second copy aren't
/// taken on the Mac (its hot key works everywhere).
pub fn claim(_: std.Io, _: single.Listener) single.Older {
    return if (quitOthers() > 0) .quit else .none;
}

pub fn send(_: single.Command) bool {
    return false;
}

test "an app that isn't Nanolight isn't taken for it" {
    try std.testing.expect(!isSelf("/System/Applications/Calculator.app"));
    try std.testing.expect(!isSelf("/nowhere/Nothing.app"));
}
