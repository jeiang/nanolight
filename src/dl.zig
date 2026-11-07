//! C functions looked up at run time: the libraries Nanolight can run
//! without (libX11 and its extensions, GTK's, libwayland-client,
//! gdk-pixbuf) are opened with dlopen, not linked.
const std = @import("std");
const log = @import("log.zig");

/// A library to look in. `loaded`: only if the process has it already
/// (GTK's, which nanoui loads), never a copy of its own.
pub const Lib = struct { name: [:0]const u8, loaded: bool = false };

/// A table of C functions by `T`'s field names, each from the first of
/// `libs` that has it; null when one is in none, logged with the function's
/// name and `effect`, what goes without it.
pub fn table(comptime T: type, comptime libs: []const Lib, effect: []const u8) ?T {
    var handles: [libs.len]?*anyopaque = undefined;
    inline for (libs, &handles) |l, *h| h.* = std.c.dlopen(l.name, .{
        .NOW = true,
        .NOLOAD = l.loaded,
    });
    var v: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |name| {
        const sym = find(&handles, name) orelse {
            log.warn("nanolight: no {s} in {s}: {s}", .{ name, comptime names(libs), effect });
            return null;
        };
        @field(v, name) = @ptrCast(@alignCast(sym));
    }
    return v;
}

/// The first of `handles` that has `name`; a library that didn't open is
/// skipped (dlsym's null handle would search the whole process).
fn find(handles: []const ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    for (handles) |h| if (std.c.dlsym(h orelse continue, name)) |sym| return sym;
    return null;
}

fn names(comptime libs: []const Lib) []const u8 {
    comptime var s: []const u8 = libs[0].name;
    inline for (libs[1..]) |l| s = s ++ ", " ++ l.name;
    return s;
}
