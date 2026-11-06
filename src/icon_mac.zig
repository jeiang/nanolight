//! The Finder's icon for a path (an app, a file, a folder), drawn at 64
//! pixels and encoded as PNG: for the app rows (apps_mac.zig) and the file
//! rows (files.zig).
const std = @import("std");
const objc = @import("nanoui").objc;

/// Null when the system draws none, or memory runs out.
pub fn png(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const img = objc.msg(objc.Object, ws, "iconForFile:", .{objc.nsString(path)});
    var rect: objc.CGRect = .{ .size = .{ .width = 64, .height = 64 } };
    const cg = objc.msg(
        ?*anyopaque,
        img,
        "CGImageForProposedRect:context:hints:",
        .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) },
    ) orelse
        return null;
    const rep = objc.msg(objc.Object, objc.alloc("NSBitmapImageRep"), "initWithCGImage:", .{cg});
    defer objc.release(rep);
    const props = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{});
    // NSBitmapImageFileTypePNG
    const data = objc.msg(
        ?objc.Object,
        rep,
        "representationUsingType:properties:",
        .{ @as(objc.NSUInteger, 4), props },
    ) orelse
        return null;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const bytes = objc.msg(?[*]const u8, data, "bytes", .{}) orelse return null;
    return gpa.dupe(u8, bytes[0..len]) catch null;
}
