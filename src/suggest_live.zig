//! The running app's side of Google's completions (suggest.zig): asked once
//! typing pauses, the answer handed to the panel; and the switch for them.
const std = @import("std");
const nanoui = @import("nanoui");
const suggest = @import("suggest.zig");
const prefs = @import("prefs.zig");
const view = @import("view.zig");
const after = @import("after.zig");
const App = @import("app.zig").App;

pub const Suggest = struct {
    core: *App,
    /// The words Google is to be asked about once typing pauses (only the
    /// last pause asks).
    asking: [suggest.max_len]u8 = undefined,
    asking_len: usize = 0,
    pause: after.Debounce = .{},

    /// What the panel asks for completions with.
    pub fn entry(sg: *Suggest) view.Host.Ask {
        return .{ .ctx = sg, .func = ask };
    }

    /// Google is asked once typing pauses (`suggest.pause_ms`).
    fn ask(ctx: *anyopaque, query: []const u8) void {
        const sg = after.cast(*Suggest, ctx);
        const q = std.mem.trim(u8, query, " ");
        if (q.len > suggest.max_len) return sg.core.s.unanswered(q);
        @memcpy(sg.asking[0..q.len], q);
        sg.asking_len = q.len;
        sg.pause.poke(suggest.pause_ms, Suggest, "pause", send);
    }

    fn send(sg: *Suggest) void {
        const core = sg.core;
        const q = sg.asking[0..sg.asking_len];
        // Typed on, or turned off, while it waited.
        if (!core.s.suggest_on or !suggest.same(q, core.s.query.text())) {
            return core.s.unanswered(q);
        }
        const a = core.app.gpa.create(Ask) catch return core.s.unanswered(q);
        a.* = .{ .core = core, .len = q.len };
        @memcpy(a.text[0..q.len], q);
        var buf: [suggest.url_max]u8 = undefined;
        nanoui.http.fetch(core.app.gpa, .{
            .url = suggest.url(&buf, q),
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 4,
        }, a, Ask.done);
    }
};

/// A question to Google on its way: the words it is about.
const Ask = struct {
    core: *App,
    text: [suggest.max_len]u8 = undefined,
    len: usize,

    fn done(a: *Ask, r: nanoui.http.Response) void {
        const core = a.core;
        defer core.app.gpa.destroy(a);
        defer core.redraw();
        var arena: std.heap.ArenaAllocator = .init(core.app.gpa);
        defer arena.deinit();
        var list: suggest.List = .{};
        if (r.status != 200 or
            !suggest.decode(
                arena.allocator(),
                r.body,
                a.text[0..a.len],
                &list,
            )) return core.s.unanswered(a.text[0..a.len]);
        core.s.answered(a.text[0..a.len], &list);
    }
};

/// Where a change to a setting came from: this machine (synced on) or the account.
pub const Origin = enum { here, synced };

/// Google's suggestions on or off: the one writer (the menu, Settings, sync).
pub fn set(core: *App, on: bool, origin: Origin) void {
    if (on == core.s.suggest_on) return;
    core.s.setSuggest(on);
    // A failure is logged; the choice holds for this run, the next launch falls back to on.
    _ = prefs.setFlag(core.kv, .suggest, on);
    if (origin == .here) core.touched(.suggest);
    core.redraw();
    // The menu's checkbox follows; never rebuilt inside its own click.
    after.oneShot(0, core, App.menuChanged);
}
