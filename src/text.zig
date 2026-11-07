//! Byte-level text helpers: cutting UTF-8, escaping for URLs.
const std = @import("std");

/// `s` cut to at most `max` bytes, on a character boundary.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

/// `s` percent-encoded into `w`: letters, digits, `-_.~` and the bytes in
/// `how.keep` as they are, a space as `+` when `how.plus` (query values
/// only; a path needs `%20`), any other byte as `%XX`. Each byte goes in
/// whole: it stops at the first that does not fit.
pub fn percentEncode(
    w: *std.Io.Writer,
    s: []const u8,
    how: struct { keep: []const u8 = "", plus: bool = false },
) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or
            std.mem.indexOfScalar(u8, "-_.~", ch) != null or
            std.mem.indexOfScalar(u8, how.keep, ch) != null;
        var unit: [3]u8 = .{ ch, 0, 0 };
        var len: usize = 1;
        if (ch == ' ' and how.plus) {
            unit[0] = '+';
        } else if (!plain) {
            unit = .{ '%', hex[ch >> 4], hex[ch & 0xF] };
            len = 3;
        }
        const dest = try w.writableSliceGreedy(len);
        @memcpy(dest[0..len], unit[0..len]);
        w.advance(len);
    }
}

test "a cut keeps whole characters; an escape keeps whole bytes" {
    const t = std.testing;
    try t.expectEqualStrings("é", clip("éé", 3));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncode(&w, "a b&c", .{});
    try t.expectEqualStrings("a%20b%26c", w.buffered());
    w = .fixed(&buf);
    try percentEncode(&w, "/a b/", .{ .keep = "/", .plus = true });
    try t.expectEqualStrings("/a+b/", w.buffered());
    // No room for all of "%26": none of it goes in.
    var small: [3]u8 = undefined;
    w = .fixed(&small);
    try t.expectError(error.WriteFailed, percentEncode(&w, "ab&", .{}));
    try t.expectEqualStrings("ab", w.buffered());
}
