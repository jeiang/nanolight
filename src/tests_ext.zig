//! A script command's screen in the panel (raycast_view.zig), driven
//! through a Tester: its output, its actions, its arguments' form, opening
//! it from its row, and one screen up at a time. No process runs; a host
//! answers as script_run.zig's runner does.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("view.zig");
const support = @import("test_support.zig");
const model = @import("raycast_model.zig");
const rv = @import("raycast_view.zig");
const Ext = rv.Ext;

/// What a host was told, a line each: "pop", "run", "field 1 Rach".
const Heard = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn add(h: *Heard, event: model.Event) void {
        var w: std.Io.Writer = .fixed(h.buf[h.len..]);
        write(&w, event) catch {}; // best effort: a full log keeps what came first
        h.len += w.end;
    }

    fn write(w: *std.Io.Writer, event: model.Event) !void {
        switch (event) {
            .pop => try w.writeAll("pop\n"),
            .action => |a| try w.print("{t}\n", .{a}),
            .field => |f| try w.print("field {d} {s}\n", .{ f.slot, f.value }),
        }
    }

    fn text(h: *const Heard) []const u8 {
        return h.buf[0..h.len];
    }
};

/// A host that answers as script_run.zig's Runner does: inside the call,
/// with a new view or the screen closed, while the frame that sent the
/// event is still being drawn. Its views' arenas come from `backing`: the
/// page allocator hands freed pages back at once, so a read of a view
/// freed under the frame faults rather than reading stale bytes. Their
/// actions are in the arena too (the runner's are static) for the same
/// reason.
const Answering = struct {
    ext: *Ext,
    backing: std.mem.Allocator,
    heard: Heard = .{},

    const First = enum { confirm, output, form };

    fn said(ctx: *anyopaque, event: model.Event) void {
        const h: *Answering = @ptrCast(@alignCast(ctx));
        h.heard.add(event);
        switch (event) {
            .pop => h.ext.stop(),
            // A dropdown's pick is shown; a typed name stays in its field.
            .field => |f| if (f.slot == 0) h.form(std.mem.eql(u8, f.value, "fr")),
            .action => |a| switch (a) {
                .run => h.output(),
                .again => h.confirm(),
                .copy => h.ext.note("Copied to the clipboard", false),
            },
        }
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
        h.ext.show(arena, .{ .detail = .{
            .title = a.dupe(u8, "Greet") catch @panic("OOM"),
            .body = .{ .markdown = md },
            .actions = a.dupe(model.Action, &.{.run}) catch @panic("OOM"),
        } });
    }

    /// The script's output, done, with Copy and Run Again.
    fn output(h: *Answering) void {
        var arena: std.heap.ArenaAllocator = .init(h.backing);
        const a = arena.allocator();
        const out = a.dupe(u8, "Hello, Rach\nfrom a script") catch @panic("OOM");
        h.ext.show(arena, .{ .detail = .{
            .title = a.dupe(u8, "Greet") catch @panic("OOM"),
            .body = .{ .output = out },
            .actions = a.dupe(model.Action, &.{ .copy, .again }) catch @panic("OOM"),
        } });
    }

    /// The arguments' form: a language to pick, then a name.
    fn form(h: *Answering, french: bool) void {
        var arena: std.heap.ArenaAllocator = .init(h.backing);
        const a = arena.allocator();
        const opts = a.dupe(model.Option, &.{
            .{ .value = "en", .title = "English" },
            .{ .value = "fr", .title = "French" },
        }) catch @panic("OOM");
        const fields = a.dupe(model.Field, &.{
            .{
                .slot = 0,
                .kind = .dropdown,
                .title = "Language",
                .value = a.dupe(u8, if (french) "fr" else "en") catch @panic("OOM"),
                .options = opts,
            },
            .{ .slot = 1, .title = "Name", .placeholder = "Optional" },
        }) catch @panic("OOM");
        h.ext.show(arena, .{ .form = .{
            .title = a.dupe(u8, "Greet") catch @panic("OOM"),
            .fields = fields,
            .actions = a.dupe(model.Action, &.{.run}) catch @panic("OOM"),
        } });
    }
};

/// A script's screen in a panel, its host answering as the runner does.
/// The panel's host opens a script's row as script_live.zig does.
const Rig = struct {
    panel: support.Rig,
    /// The panel and its Tester, as the tests name them.
    s: *view.Nanolight,
    t: *ui.Tester,
    ext: Ext,
    host: Answering,
    opts: Options,
    hidden: bool,

    const row = "script:/scripts/greet.sh";

    const Options = struct {
        /// The host's first view; none leaves "Starting…".
        first: ?Answering.First = null,
        /// Where the host's views' arenas come from (`Answering`).
        backing: std.mem.Allocator = std.heap.page_allocator,
        /// The panel starts on its rows, the script's among them, rather
        /// than with the script open.
        rows: bool = false,
        /// The script is silent: its screen goes as it starts.
        silent: bool = false,
        /// Its row's icon.
        icon: ?[]const u8 = null,
    };

    /// In place: the panel, the screen and the host point at each other.
    fn init(r: *Rig, gpa: std.mem.Allocator, opts: Options) !void {
        r.panel.init(gpa);
        r.s = &r.panel.s;
        r.t = &r.panel.t;
        r.opts = opts;
        r.hidden = false;
        r.ext = .{ .gpa = gpa, .back = &r.s.query };
        r.s.ext = &r.ext;
        r.host = .{ .ext = &r.ext, .backing = opts.backing };
        errdefer r.deinit();
        try r.panel.ix.add("Greet", row);
        r.s.host = .{ .ctx = r, .open = open, .hide = hide };
        r.s.reveal();
        if (!opts.rows) r.script();
        try r.panel.mount(.{ .screen = .none });
    }

    fn script(r: *Rig) void {
        const command: model.Command = .{ .name = "Greet", .icon = r.opts.icon };
        r.ext.start(command, .{ .ctx = &r.host, .func = Answering.said });
        if (r.opts.silent) return r.ext.stop();
        if (r.opts.first) |first| r.host.show(first);
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const r: *Rig = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, target, row)) r.script();
    }

    fn hide(ctx: *anyopaque) void {
        const r: *Rig = @ptrCast(@alignCast(ctx));
        r.hidden = true;
    }

    fn deinit(r: *Rig) void {
        r.panel.unmount();
        r.ext.deinit();
        r.panel.deinit();
    }

    fn heard(r: *const Rig, what: []const u8) bool {
        return std.mem.indexOf(u8, r.host.heard.text(), what) != null;
    }
};

test "a script's output shows every line, and Escape closes it and the panel" {
    const gpa = std.testing.allocator;
    var r: Rig = undefined;
    try r.init(gpa, .{});
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Starting…"));
    // As a script prints: its first line, then the rest.
    for ([_][]const u8{
        "",
        "Linux 6.17 on x86_64\n",
        "Linux 6.17 on x86_64\nUp: 3 min\n\nFilesystem Size Used\n/dev/vda1 10G 2G",
    }) |sofar| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const out = try arena.allocator().dupe(u8, sofar);
        r.ext.show(arena, .{ .detail = .{
            .title = "System Info",
            .body = .{ .output = out },
            .loading = sofar.len < 40,
        } });
        r.t.settle(0.2);
    }
    r.t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT")) |p| try r.t.screenshot(std.mem.span(p));
    try std.testing.expect(r.t.hasText("System Info"));
    try std.testing.expect(r.t.hasText("Linux 6.17 on x86_64"));
    try std.testing.expect(r.t.hasText("Up: 3 min"));
    try std.testing.expect(r.t.hasText("/dev/vda1 10G 2G"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard("pop") and r.hidden and !r.ext.open);
    // The search has the keys again.
    r.t.settle(1);
    r.t.typeText("gre");
    r.t.settle(1);
    try std.testing.expectEqualStrings("gre", r.s.query.text());
}

test "a script's actions on ⌘K: Return runs the one chosen, Escape closes even with them open" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Copy Output"));
    try std.testing.expect(r.t.shortcut(rv.actions_key));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Actions") and r.t.hasText("Run Again"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.down });
    r.t.textOps(&.{.{ .command = .insert_newline }});
    r.t.settle(1);
    try std.testing.expect(r.heard("again\n") and !r.heard("copy"));
    try std.testing.expect(r.t.hasText("Run Greet?"));
    // With the actions open, one Escape pops and hides.
    try std.testing.expect(r.t.shortcut(rv.actions_key));
    r.t.settle(1);
    try std.testing.expect(r.ext.actions_open);
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard("pop") and r.hidden and !r.ext.open);
}

test "a script's arguments: typed at once, Return runs it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .form });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Language") and r.t.hasText("English"));
    r.t.typeText("Rach");
    r.t.settle(0.2);
    r.t.textOps(&.{.{ .command = .insert_newline }});
    r.t.settle(0.2);
    try std.testing.expect(r.heard("field 1 Rach\nrun\n"));
    try std.testing.expect(r.t.hasText("from a script"));
}

test "a compact script's last line, as the detail's heading" {
    const gpa = std.testing.allocator;
    var r: Rig = undefined;
    try r.init(gpa, .{});
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const md = try arena.allocator().dupe(u8, "# Hello, Rach - from a script");
    r.ext.show(arena, .{ .detail = .{ .title = "Greet", .body = .{ .markdown = md } } });
    r.t.settle(1);
    if (std.c.getenv("NANOLIGHT_SHOT2")) |p| try r.t.screenshot(std.mem.span(p));
    try std.testing.expect(r.t.hasText("Hello, Rach - from a script"));
}

test "Escape closes a script's screen in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Run Greet?"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard("pop") and r.hidden and !r.ext.open);
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
    try std.testing.expect(r.heard("pop") and !r.hidden and !r.ext.open);
    r.t.settle(1);
    try std.testing.expect(!r.t.hasText("from a script"));
}

test "Return on Run X? replaces the view in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.heard("run\n"));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("from a script"));
    try std.testing.expect(!r.t.containsText("Run Greet?"));
}

test "Run Again replaces the output in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expect(r.heard("again\n"));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Run Greet?"));
}

test "a dropdown pick shows the form again in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .form });
    defer r.deinit();
    try r.t.clickText("French");
    try std.testing.expect(r.heard("field 0 fr\n"));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("French") and r.ext.open);
    try std.testing.expectEqualStrings("fr", r.ext.view.?.form.fields[0].value);
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

test "a script's row opens its screen, and the panel stays" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm, .rows = true });
    defer r.deinit();
    r.t.typeText("greet");
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Greet") and !r.ext.open);
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.ext.open and !r.hidden);
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Run Greet?"));
}

test "a silent script's row hides the panel as it runs" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .rows = true, .silent = true });
    defer r.deinit();
    r.t.typeText("greet");
    r.t.settle(1);
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(!r.ext.open and r.hidden);
}

test "Settings opened over Clipboard History closes it, so Escape leaves the rows for next time" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .rows = true });
    defer r.deinit();
    r.s.openClipboard();
    r.t.settle(1);
    // As the tray's Settings… opens it.
    r.s.openSettings();
    try std.testing.expect(r.s.settings_ui.open and !r.s.clip_ui.open);
    r.t.settle(1);
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.hidden and !r.s.settings_ui.open);
    r.s.reveal();
    r.t.settle(1);
    try std.testing.expect(!r.s.clip_ui.open and r.t.hasText("Nanolight · 1 apps"));
}

test "Settings or Clipboard History opened over a script's screen end the script and close it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    // A hide and a reveal keep it.
    r.s.reveal();
    try std.testing.expect(r.ext.open);
    r.s.openSettings();
    try std.testing.expect(r.heard("pop") and !r.ext.open and r.s.settings_ui.open);
    r.t.settle(1);
    try std.testing.expect(!r.t.containsText("from a script"));
    r.s.openClipboard();
    try std.testing.expect(r.s.clip_ui.open and !r.s.settings_ui.open);
}

test "a script's icon outlives the index it came from" {
    const gpa = std.testing.allocator;
    // The index's icon, in page memory: handed back to the system when the
    // index is replaced, so a read of it afterwards faults.
    const png = try std.heap.page_allocator.dupe(u8, view.icon_png);
    var r: Rig = undefined;
    r.init(gpa, .{ .first = .output, .icon = png }) catch |err| {
        std.heap.page_allocator.free(png);
        return err;
    };
    defer r.deinit();
    // The apps change while the screen is up (script_live.zig `refresh`).
    std.heap.page_allocator.free(png);
    r.t.settle(1);
    // A window whose image cache starts empty, as after an eviction, reads
    // the icon's bytes again.
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(r.s, view.Nanolight.view), .{
        .width = view.width,
        .height = view.max_height,
        .dark = true,
    });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("from a script"));
    // Escape stops the screen while a frame is drawn: its icon goes after.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!r.ext.open and r.ext.icon == null);
    t.settle(1);
}
