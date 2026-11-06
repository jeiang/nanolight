//! The selected row, held across a refill of the list (completions or files
//! landing): the selection stays on the same row wherever that row now is,
//! so Return a moment after typing does what the panel showed. Apps, panes,
//! commands and quicklinks are the same row by index; a file by its path
//! and a completion by its words, since their indexes move with each answer.
const std = @import("std");
const files = @import("files.zig");
const suggest = @import("suggest.zig");
const Row = @import("results.zig").Row;
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
        const text: []const u8 = switch (r.kind) {
            .file => s.found.entries[r.file].path(),
            .suggest => s.web.get(r.web),
            else => "",
        };
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
            const same = switch (r.kind) {
                .app, .pane, .command => now.app == r.app,
                .quicklink => now.ql == r.ql,
                .file => std.mem.eql(u8, s.found.entries[now.file].path(), text),
                .suggest => suggest.same(s.web.get(now.web), text),
                else => true,
            };
            if (same) return i;
        }
        return null;
    }
};
