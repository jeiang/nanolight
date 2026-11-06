//! How often apps were opened, as this machine keeps it (apps.zig) and a
//! synced record carries it (settings.zig): one cap and one order for both.
const std = @import("std");

/// At most this many counts are kept: the most opened.
pub const max = 512;

/// A count, by key: an app's path (or, in older rows, its name).
pub const Launch = struct { key: []const u8, count: u16 };

/// Most opened first; of equals, the earlier key: the same order every run.
pub fn before(a: Launch, b: Launch) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.key, b.key);
}

/// `list` sorted by `before`, cut to `max`.
pub fn mostOpened(list: []Launch) []const Launch {
    std.sort.pdq(Launch, list, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            return before(a, b);
        }
    }.f);
    return list[0..@min(list.len, max)];
}
