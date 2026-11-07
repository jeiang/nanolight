//! Which screen the panel shows, one at a time, and how long each lasts once
//! the panel goes away. nanolight.zig's `Nanolight` holds the one that is up and
//! moves between them (`open`, `leave`, `escape`, `show`).
const std = @import("std");

pub const Kind = enum { rows, preview, settings, clipboard, script, welcome };

/// What takes the screen up away, mildest first: each kind lasts through
/// the milder ones (`lasts`) and goes at the rest.
pub const Why = enum {
    /// The panel is shown again, within `Away.pop_after` of going.
    shown,
    /// The panel is shown again after it: it reopens at the root.
    popped,
    /// Another screen opens in its place.
    replaced,
    /// Escape, or the screen's own way out.
    closed,
};

/// The mildest `Why` each kind goes at; the rows, the root, never go.
const goes_at = std.enums.EnumArray(Kind, ?Why).init(.{
    .rows = null,
    // A page and Settings are for the one showing.
    .preview = .shown,
    .settings = .shown,
    // Clipboard History and a script's screen wait, until the root.
    .clipboard = .popped,
    .script = .popped,
    // The welcome waits until it is done or skipped.
    .welcome = .replaced,
});

pub fn lasts(kind: Kind, why: Why) bool {
    const at = goes_at.get(kind) orelse return true;
    return @backingInt(why) < @backingInt(at);
}

/// When the panel went away, and how long it may be away before it
/// reopens at the root.
pub const Away = struct {
    /// Seconds; null while it is up.
    at: ?i64 = null,
    /// Seconds; 0 is never.
    pop_after: u32,

    pub fn hid(a: *Away, now: i64) void {
        a.at = now;
    }

    /// What showing it at `now` takes away: one answer per going away.
    pub fn shown(a: *Away, now: i64) Why {
        const t = a.at orelse return .shown;
        a.at = null;
        return if (a.pop_after > 0 and now - t > a.pop_after) .popped else .shown;
    }
};

test "each screen lasts through what its kind says" {
    const t = std.testing;
    try t.expect(lasts(.rows, .closed));
    try t.expect(!lasts(.settings, .shown) and !lasts(.preview, .shown));
    try t.expect(lasts(.clipboard, .shown) and !lasts(.clipboard, .popped));
    try t.expect(lasts(.script, .shown) and !lasts(.script, .popped));
    try t.expect(lasts(.welcome, .popped) and !lasts(.welcome, .replaced));
}

test "the panel reopens at the root only after being away longer than pop_after" {
    const t = std.testing;
    var a: Away = .{ .pop_after = 90 };
    // Never hidden: nothing to pop.
    try t.expectEqual(Why.shown, a.shown(1000));
    a.hid(1000);
    try t.expectEqual(Why.shown, a.shown(1090));
    a.hid(1000);
    try t.expectEqual(Why.popped, a.shown(1091));
    // One answer per hiding.
    try t.expectEqual(Why.shown, a.shown(5000));
    a.pop_after = 0;
    a.hid(1000);
    try t.expectEqual(Why.shown, a.shown(1_000_000));
}
