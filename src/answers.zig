//! Google's answers reaching the panel. Its rows clear with each key and
//! come back a moment later (`suggest.pause_ms`, then the network), so the
//! panel keeps their room until they do (`Nanolight.held_h`): its height
//! changes once the rows are known, not down and up with every key. An
//! answer counts for the same words in any case or spacing, as the cache
//! keeps them (`suggest.same`).
const suggest = @import("suggest.zig");
const Nanolight = @import("view.zig").Nanolight;

/// Google's answer to `typed` (the last words `Host.suggest` was asked
/// about): its completions, or null when none are coming (it failed, or was
/// never sent). The room kept for them goes; completions are kept, and
/// listed if `typed` is still what is typed (`Nanolight.refill`).
pub fn answered(s: *Nanolight, typed: []const u8, said: ?*const suggest.List) void {
    if (suggest.same(typed, s.query.words())) s.held_h = 0;
    // Turned off while it was on its way: nothing of it is kept or listed.
    if (!s.suggest_on) return;
    const list = said orelse return;
    s.cache.put(typed, list);
    if (!s.wants(typed)) return;
    s.refill(.{ .completions = list });
}

/// Whether an answer to `typed` would be listed: completions are on, and
/// `typed` is still what is typed. Google is asked only while it is.
pub fn wants(s: *const Nanolight, typed: []const u8) bool {
    return s.suggest_on and suggest.same(typed, s.query.words());
}
