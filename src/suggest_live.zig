//! The running app's side of Google's completions (suggest.zig): asked once
//! typing pauses, the answer handed to the panel; and the switch for them.
const std = @import("std");
const nanoui = @import("nanoui");
const suggest = @import("suggest.zig");
const prefs = @import("prefs.zig");
const Host = @import("host.zig").Host;
const pipeline = @import("pipeline.zig");
const after = @import("after.zig");
const App = @import("app.zig").App;

/// Seconds without a byte before asking Google gives up.
const timeout = 4;

pub const Suggest = struct {
    core: *App,
    /// The words Google is to be asked about once typing pauses (only the
    /// last pause asks).
    asking: [suggest.max_len]u8 = undefined,
    asking_len: usize = 0,
    pause: after.Debounce = .{},

    pub fn entry(sg: *Suggest) Host.Ask {
        return .{ .ctx = sg, .func = ask };
    }

    /// Google is asked once typing pauses (`suggest.pause_ms`); only the
    /// last ask is sent, and answered (`pipeline.answered`).
    fn ask(ctx: *anyopaque, words: []const u8) void {
        const sg = after.cast(*Suggest, ctx);
        // The panel asks only about words `suggest.eligible` lets out.
        std.debug.assert(words.len <= suggest.max_len);
        @memcpy(sg.asking[0..words.len], words);
        sg.asking_len = words.len;
        sg.pause.poke(suggest.pause_ms, Suggest, "pause", send);
    }

    fn send(sg: *Suggest) void {
        const core = sg.core;
        const q = sg.asking[0..sg.asking_len];
        // Typed on, or turned off, while it waited.
        if (!pipeline.wants(core.s, q)) return pipeline.answered(core.s, q, null);
        const a = core.app.gpa.create(Ask) catch return pipeline.answered(core.s, q, null);
        a.* = .{ .core = core, .len = q.len };
        @memcpy(a.text[0..q.len], q);
        var buf: [suggest.url_max]u8 = undefined;
        nanoui.http.fetch(core.app.gpa, .{
            .url = suggest.url(&buf, q),
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = timeout,
        }, a, Ask.done);
    }
};

/// A question to Google on its way: the words it is about.
const Ask = struct {
    core: *App,
    text: [suggest.max_len]u8 = undefined,
    len: usize,

    /// The answer, or none: either way the panel hears of it, once.
    fn done(a: *Ask, r: nanoui.http.Response) void {
        const core = a.core;
        defer core.app.gpa.destroy(a);
        defer core.redraw();
        var arena: std.heap.ArenaAllocator = .init(core.app.gpa);
        defer arena.deinit();
        const typed = a.text[0..a.len];
        var list: suggest.List = .{};
        const said = r.status == 200 and suggest.decode(arena.allocator(), r.body, typed, &list);
        pipeline.answered(core.s, typed, if (said) &list else null);
    }
};

/// Where a change to a setting came from: this machine (synced on) or the account.
pub const Origin = enum { here, synced };

/// Google's suggestions on or off: the one writer (the menu, Settings, sync).
pub fn set(core: *App, on: bool, origin: Origin) void {
    if (on == core.s.suggest_on) return;
    core.s.setSuggest(on);
    // Unkept, the choice holds for this run; the next launch falls back to on.
    prefs.keepFlag(core.kv, .suggest, on);
    if (origin == .here) core.touched(.suggest);
    core.redraw();
    // The menu's checkbox follows; never rebuilt inside its own click.
    after.oneShot(0, core, App.menuChanged);
}
