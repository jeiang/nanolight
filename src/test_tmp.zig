//! Where a test's `std.testing.tmpDir` is, for code that takes a path
//! rather than a directory.
const std = @import("std");

/// `tmp`'s absolute path, into `buf`.
pub fn path(buf: *[std.fs.max_path_bytes]u8, tmp: *const std.testing.TmpDir) ![]const u8 {
    const n = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..n];
}
