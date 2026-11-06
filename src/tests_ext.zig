//! A command's screen in the panel (raycast_view.zig), driven through a
//! Tester: a script's output, a list's rows and actions, a form. No
//! process runs; what a host would say is handed to the screen directly.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;

const Heard = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn said(ctx: *anyopaque, line: []const u8) void {
        const h: *Heard = @ptrCast(@alignCast(ctx));
        const n = @min(line.len, h.buf.len - h.len);
        @memcpy(h.buf[h.len..][0..n], line[0..n]);
        h.len += n;
    }

    fn text(h: *const Heard) []const u8 {
        return h.buf[0..h.len];
    }
};

fn noop(_: *anyopaque) void {}
fn hideFlag(ctx: *anyopaque) void {
    @as(*bool, @ptrCast(@alignCast(ctx))).* = true;
}
fn noopOpen(_: *anyopaque, _: []const u8) void {}

test "a script's output shows every line, and Escape closes it and the panel" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var hidden = false;
    s.host = .{ .ctx = &hidden, .open = noopOpen, .hide = hideFlag };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    s.reveal();
    var heard: Heard = .{};
    ext.start("System Info", null, .{ .ctx = &heard, .func = Heard.said });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    // As a script prints: its first line, then the rest.
    for ([_][]const u8{ "", "Linux 6.17 on x86_64\n", "Linux 6.17 on x86_64\nUp: 3 min\n\nFilesystem Size Used\n/dev/vda1 10G 2G" }) |sofar| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const out = try arena.allocator().dupe(u8, sofar);
        ext.show(arena, .{ .kind = "detail", .title = "System Info", .output = out, .loading = sofar.len < 40 });
        t.settle(0.2);
    }
    t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT")) |p| try t.screenshot(std.mem.span(p));
    try std.testing.expect(t.hasText("Linux 6.17 on x86_64"));
    try std.testing.expect(t.hasText("Up: 3 min"));
    try std.testing.expect(t.hasText("/dev/vda1 10G 2G"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"pop\"") != null);
    try std.testing.expect(hidden);
    // The runner stops the screen on a pop; the search has the keys again.
    ext.stop();
    t.settle(1);
    t.typeText("gre");
    t.settle(1);
    try std.testing.expectEqualStrings("gre", s.query.text());
}

test "a list's rows, its actions on ⌘K, Return runs the first, Escape closes even with them open" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var hidden = false;
    s.host = .{ .ctx = &hidden, .open = noopOpen, .hide = hideFlag };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Hacker News", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const line = "{\"type\":\"render\",\"view\":{\"kind\":\"list\",\"sections\":[{\"title\":\"Front Page\",\"items\":[{\"id\":\"a\",\"title\":\"Show HN: Nanolight\",\"subtitle\":\"rach\",\"icon\":{\"text\":\"1\"},\"accessories\":[\"128\"],\"actions\":[{\"id\":\"open\",\"title\":\"Open in Browser\"},{\"id\":\"copy\",\"title\":\"Copy Link\"}]},{\"id\":\"b\",\"title\":\"Zig 0.17\",\"actions\":[{\"id\":\"open2\",\"title\":\"Open in Browser\"}]}]}]}}";
    const m = try model.parse(arena.allocator(), line);
    ext.show(arena, m.view.?);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Front Page"));
    try std.testing.expect(t.hasText("Show HN: Nanolight"));
    try std.testing.expect(t.hasText("128"));
    try std.testing.expect(t.shortcut(@import("raycast_view.zig").actions_key));
    t.settle(1);
    try std.testing.expect(t.hasText("Copy Link"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.textOps(&.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"id\":\"copy\"") != null);
    // With the actions open and a query typed, one Escape pops and hides.
    t.typeText("zig");
    try std.testing.expect(t.shortcut(@import("raycast_view.zig").actions_key));
    t.settle(1);
    try std.testing.expect(ext.actions_open);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"pop\"") != null);
    try std.testing.expect(hidden);
}

test "a script's arguments: typed at once, Return runs it" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Greet", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    const fields = try a.dupe(model.Field, &.{.{ .id = "arg1", .type = "text", .title = "Name", .value = .{ .string = "" } }});
    const acts = try a.dupe(model.Action, &.{.{ .id = "run", .title = "Run" }});
    ext.show(arena, .{ .kind = "form", .title = "Greet", .fields = fields, .actions = acts });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    t.typeText("Rach");
    t.settle(0.2);
    t.textOps(&.{.{ .command = .insert_newline }});
    t.settle(0.2);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"value\":\"Rach\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, heard.text(), "\"id\":\"run\"") != null);
}

test "a compact script's last line, as the detail's heading" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var probe: u8 = 0;
    s.host = .{ .ctx = &probe, .open = noopOpen, .hide = noop };
    var ext: Ext = .{ .gpa = gpa, .back = &s.query };
    defer ext.deinit();
    s.ext = &ext;
    var heard: Heard = .{};
    ext.start("Greet", null, .{ .ctx = &heard, .func = Heard.said });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const md = try arena.allocator().dupe(u8, "# Hello, Rach - from a script");
    ext.show(arena, .{ .kind = "detail", .title = "Greet", .markdown = md });
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT2")) |p| try t.screenshot(std.mem.span(p));
    try std.testing.expect(t.hasText("Hello, Rach - from a script"));
}

/// A host that answers as script_run.zig's Runner does: inside the call,
/// with a new view or the screen closed, while the frame that sent the
/// event is still being drawn. Its views' arenas come from `backing`: the
/// page allocator hands freed pages back at once, so a read of a view
/// freed under the frame faults rather than reading stale bytes.
const Answering = struct {
    ext: *Ext,
    backing: std.mem.Allocator,
    heard: Heard = .{},

    const First = enum { confirm, output, form };

    fn said(ctx: *anyopaque, line: []const u8) void {
        const h: *Answering = @ptrCast(@alignCast(ctx));
        Heard.said(&h.heard, line);
        if (std.mem.indexOf(u8, line, "\"pop\"") != null) return h.ext.stop();
        const picked = std.mem.indexOf(u8, line, "\"fr\"") != null;
        if (std.mem.indexOf(u8, line, "\"field\"") != null) return h.form(picked);
        if (std.mem.indexOf(u8, line, "\"again\"") != null) return h.confirm();
        if (std.mem.indexOf(u8, line, "\"run\"") != null) return h.output();
    }

    fn show(h: *Answering, first: First) void {
        switch (first) {
            .confirm => h.confirm(),
            .output => h.output(),
            .form => h.form(false),
        }
    }

    /// "Run Greet?", as the runner asks before a script that needs it.
    fn confirm(h: *Answering) void {
        var arena: std.heap.ArenaAllocator = .init(h.backing);
        const a = arena.allocator();
        const md = a.dupe(u8, "# Run Greet?\nSays hello.") catch @panic("OOM");
        const acts = a.dupe(model.Action, &.{.{ .id = "run", .title = "Run" }}) catch @panic("OOM");
        h.ext.show(arena, .{ .kind = "detail", .title = "Greet", .markdown = md, .actions = acts });
    }

    /// The script's output, done, with Copy and Run Again.
    fn output(h: *Answering) void {
        var arena: std.heap.ArenaAllocator = .init(h.backing);
        const a = arena.allocator();
        const out = a.dupe(u8, "Hello, Rach\nfrom a script") catch @panic("OOM");
        const acts = a.dupe(model.Action, &.{
            .{ .id = "copy", .title = "Copy Output" },
            .{ .id = "again", .title = "Run Again" },
        }) catch @panic("OOM");
        h.ext.show(arena, .{ .kind = "detail", .title = "Greet", .output = out, .actions = acts });
    }

    /// The arguments' form: a language to pick.
    fn form(h: *Answering, french: bool) void {
        var arena: std.heap.ArenaAllocator = .init(h.backing);
        const a = arena.allocator();
        const opts = a.dupe(model.Option, &.{
            .{ .value = "en", .title = "English" },
            .{ .value = "fr", .title = "French" },
        }) catch @panic("OOM");
        const fields = a.dupe(model.Field, &.{.{
            .id = "arg1",
            .type = "dropdown",
            .title = "Language",
            .value = .{ .string = a.dupe(u8, if (french) "fr" else "en") catch @panic("OOM") },
            .options = opts,
        }}) catch @panic("OOM");
        const acts = a.dupe(model.Action, &.{.{ .id = "run", .title = "Run" }}) catch @panic("OOM");
        h.ext.show(arena, .{ .kind = "form", .title = "Greet", .fields = fields, .actions = acts });
    }
};

/// A script's screen in a panel, its host answering as the runner does.
const Rig = struct {
    ix: Index,
    s: view.Nanolight,
    ext: Ext,
    host: Answering,
    t: ui.Tester,
    hidden: bool,

    const Options = struct {
        first: Answering.First,
        /// Where the views' arenas come from (`Answering`).
        backing: std.mem.Allocator = std.heap.page_allocator,
    };

    /// In place: the panel, the screen and the host point at each other.
    fn init(r: *Rig, gpa: std.mem.Allocator, opts: Options) !void {
        r.ix = .init(gpa);
        r.s = .{ .index = &r.ix };
        r.hidden = false;
        r.s.host = .{ .ctx = &r.hidden, .open = noopOpen, .hide = hideFlag };
        r.ext = .{ .gpa = gpa, .back = &r.s.query };
        r.s.ext = &r.ext;
        r.host = .{ .ext = &r.ext, .backing = opts.backing };
        r.s.reveal();
        r.ext.start("Greet", null, .{ .ctx = &r.host, .func = Answering.said });
        r.host.show(opts.first);
        try r.t.init(gpa, .init(&r.s, view.Nanolight.view), .{
            .width = view.width,
            .height = view.max_height,
            .dark = true,
        });
        r.t.settle(1);
    }

    fn deinit(r: *Rig) void {
        r.t.deinit();
        r.ext.deinit();
        r.s.query.deinit();
        r.ix.deinit();
    }

    fn heard(r: *const Rig, what: []const u8) bool {
        return std.mem.indexOf(u8, r.host.heard.text(), what) != null;
    }
};

test "Escape closes a script's screen in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Run Greet?"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard("\"pop\"") and r.hidden and !r.ext.open);
    r.t.settle(1);
    try std.testing.expect(!r.t.hasText("Run Greet?"));
}

test "the back button closes a script's screen in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("from a script"));
    // The chevron, first in the header.
    r.t.click(18 + 13, view.header_h / 2);
    try std.testing.expect(r.heard("\"pop\"") and !r.hidden and !r.ext.open);
    r.t.settle(1);
    try std.testing.expect(!r.t.hasText("from a script"));
}

test "Return on Run X? replaces the view in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.heard("\"id\":\"run\""));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("from a script"));
    try std.testing.expect(!r.t.containsText("Run Greet?"));
}

test "Run Again replaces the output in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expect(r.heard("\"id\":\"again\""));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Run Greet?"));
}

test "a dropdown pick shows the form again in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .form });
    defer r.deinit();
    try r.t.clickText("French");
    try std.testing.expect(r.heard("\"value\":\"fr\""));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("French") and r.ext.open);
}

test "every view replaced under a frame is freed, the last ones at deinit" {
    const gpa = std.testing.allocator;
    var r: Rig = undefined;
    try r.init(gpa, .{ .first = .confirm, .backing = gpa });
    defer r.deinit();
    r.t.textOps(&.{.{ .command = .insert_newline }});
    _ = r.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true });
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expect(r.t.hasText("Run Greet?"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!r.ext.open);
}
