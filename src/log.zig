//! The app's log lines, silent under test: the build fails a test run that
//! writes to stderr.
const std = @import("std");
const builtin = @import("builtin");

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.warn(fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (!builtin.is_test) std.log.info(fmt, args);
}
