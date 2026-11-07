//! The launcher's query: the field's text, the words it is read as, and
//! whether the rows are built for it. Ranking, math, Google's completions
//! and file search all read the same words (`Query.words`); what the field
//! adds to as it completes (`Nanolight.completion`) is the text as typed.
const std = @import("std");
const ui = @import("nanoui").ui;

/// Not part of the words at either end: spaces, and a tab or line break a
/// paste brings with them.
pub const blank = " \t\r\n";

pub const Query = struct {
    field: ui.TextBuffer = .{},
    /// The hash of the text the rows were last built for (`changed`), or
    /// `stale` until they are built again.
    built: u64 = stale,

    /// Hashed text is taken never to be this.
    const stale = 1;

    pub fn deinit(q: *Query) void {
        q.field.deinit();
    }

    /// The text as typed.
    pub fn text(q: *const Query) []const u8 {
        return q.field.text();
    }

    /// The text without `blank` at either end.
    pub fn words(q: *const Query) []const u8 {
        return std.mem.trim(u8, q.text(), blank);
    }

    /// Tells the text apart from what it was: any edit, a space too.
    pub fn hash(q: *const Query) u64 {
        return std.hash.Wyhash.hash(0, q.text());
    }

    pub fn set(q: *Query, t: []const u8) void {
        q.field.set(t);
    }

    pub fn clear(q: *Query) void {
        q.field.clear();
    }

    pub fn focus(q: *Query) void {
        q.field.focus();
    }

    /// The rows are built again though the text is the same: what they are
    /// built from changed (a setting, the quicklinks, the apps or counts).
    pub fn invalidate(q: *Query) void {
        q.built = stale;
    }

    /// Whether the rows are to be built: the text changed since they last
    /// were, or `invalidate`. From here they count as built for it.
    pub fn changed(q: *Query) bool {
        const h = q.hash();
        if (h == q.built) return false;
        q.built = h;
        return true;
    }
};

test "the rows are built once for each text, and again when invalidated" {
    var q: Query = .{};
    defer q.deinit();
    try std.testing.expect(q.changed());
    try std.testing.expect(!q.changed());
    q.set(" \tsaf \r\n");
    try std.testing.expectEqualStrings("saf", q.words());
    try std.testing.expect(q.changed());
    q.invalidate();
    try std.testing.expect(q.changed());
    try std.testing.expect(!q.changed());
    // A space is an edit: the rows are built again, from the same words.
    q.set(" \tsaf  \r\n");
    try std.testing.expect(q.changed());
    try std.testing.expectEqualStrings("saf", q.words());
}
