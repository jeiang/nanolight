//! The app's log lines. A test run keeps only errors (`src/tests.zig`'s
//! `std_options`), so a test that logs a warning says nothing; the app says
//! all of it.
const std = @import("std");

pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}
