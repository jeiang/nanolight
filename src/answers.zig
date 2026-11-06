//! Google's answers reaching the panel. Its rows clear with each key and
//! come back a moment later (`suggest.pause_ms`, then the network), so the
//! panel keeps their room until they do (`Nanolight.held_h`): its height
//! changes once the rows are known, not down and up with every key.
const suggest = @import("suggest.zig");
const Nanolight = @import("view.zig").Nanolight;
const Anchor = @import("anchor.zig").Anchor;

/// Google's completions of `typed` (what `Host.suggest` asked): kept,
/// and listed if it is still what is typed. The selection stays on the
/// row it was on, wherever that row now is: Return a moment after
/// typing does what the panel showed, not a completion that just came.
pub fn answered(s: *Nanolight, typed: []const u8, said: *const suggest.List) void {
    // Turned off while it was on its way: nothing of it is kept or listed.
    if (!s.suggest_on) return unanswered(s, typed);
    s.cache.put(typed, said);
    if (!suggest.same(typed, s.query.text())) return;
    const was: Anchor = .of(s);
    s.web = said.*;
    s.held_h = 0;
    s.fill();
    s.sel = was.find(s) orelse 0;
}

/// No answer to `typed` is coming (it failed, or was never sent): the room
/// kept for it goes.
pub fn unanswered(s: *Nanolight, typed: []const u8) void {
    if (suggest.same(typed, s.query.text())) s.held_h = 0;
}
