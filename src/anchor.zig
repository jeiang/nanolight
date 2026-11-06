//! The selected row, held across a refill of the list (completions or files
//! landing): the selection stays on the same row wherever that row now is,
//! so Return a moment after typing does what the panel showed. A row is the
//! same row by what its provider says (`results.Identity`): apps, panes,
//! commands and quicklinks by their place in their lists; a file by its path
//! and a completion by its words, since their places move with each answer.
const std = @import("std");
const files = @import("files.zig");
const suggest = @import("suggest.zig");
const results = @import("results.zig");
const Row = results.Row;
const Nanolight = @import("view.zig").Nanolight;
const assert = std.debug.assert;

pub const Anchor = struct {
    row: ?Row = null,
    /// The file's path or the completion's text.
    text: [max_text]u8 = undefined,
    len: usize = 0,

    const max_text = @max(files.max_path, suggest.max_len);

    /// The row selected in `s`, if any.
    pub fn of(s: *const Nanolight) Anchor {
        var a: Anchor = .{};
        if (s.sel >= s.res.n) return a;
        const r = s.res.rows[s.sel];
        a.row = r;
        const text = textOf(s, r);
        assert(text.len <= max_text);
        @memcpy(a.text[0..text.len], text);
        a.len = text.len;
        return a;
    }

    /// Where the row is in `s` now, or null when it is no longer listed.
    pub fn find(a: *const Anchor, s: *const Nanolight) ?usize {
        const r = a.row orelse return null;
        const text = a.text[0..a.len];
        for (s.res.slice(), 0..) |now, i| {
            if (now.kind != r.kind) continue;
            const identity = results.providers.get(r.kind).identity;
            const same = switch (identity) {
                .item => now.item == r.item,
                .path => std.mem.eql(u8, textOf(s, now), text),
                .words => suggest.same(textOf(s, now), text),
                .kind => true,
            };
            if (same) return i;
        }
        return null;
    }
};

/// The file's path or the completion's words; empty for the rest.
fn textOf(s: *const Nanolight, r: Row) []const u8 {
    const identity = results.providers.get(r.kind).identity;
    return switch (identity) {
        .path => s.found.entries[r.item].path(),
        .words => s.web.get(r.item),
        .item, .kind => "",
    };
}
