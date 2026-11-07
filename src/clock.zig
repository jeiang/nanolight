//! Wall-clock seconds and how long ago a moment was, in words.
const std = @import("std");

extern "c" fn time(t: ?*i64) i64;

/// Unix seconds.
pub fn now() i64 {
    return time(null);
}

/// "just now", "5 min ago", "3 h ago", "2 d ago" for `secs` elapsed; a
/// negative span (a clock set back) reads as just now.
pub fn ago(buf: []u8, secs: i64) []const u8 {
    const s = @max(secs, 0);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (s < std.time.s_per_hour)
        std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(s, 60)})
    else if (s < std.time.s_per_day)
        std.fmt.bufPrint(buf, "{d} h ago", .{@divFloor(s, std.time.s_per_hour)})
    else
        std.fmt.bufPrint(buf, "{d} d ago", .{@divFloor(s, std.time.s_per_day)})) catch "";
}

test "how long ago, in words" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", ago(&buf, 5));
    try std.testing.expectEqualStrings("just now", ago(&buf, -30));
    try std.testing.expectEqualStrings("3 min ago", ago(&buf, 190));
    try std.testing.expectEqualStrings("2 h ago", ago(&buf, 7300));
    try std.testing.expectEqualStrings("2 d ago", ago(&buf, 2 * 86400 + 5));
}
