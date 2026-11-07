//! A script command's screen in the panel (raycast_view.zig), driven
//! through a Tester: its output, its actions, its arguments' form, opening
//! it from its row, and one screen up at a time. No process runs; a host
//! answers as script_run.zig's runner does.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("view.zig");
const chrome = @import("chrome.zig");
const support = @import("test_support.zig");
const model = @import("raycast_model.zig");
const rv = @import("raycast_view.zig");
const script_commands = @import("script_commands.zig");
const Target = @import("results.zig").Target;

/// What a host was told, in order; a field's value copied, as it lives
/// only until the runner returns.
const Heard = struct {
    told: [64]Told = undefined,
    n: usize = 0,
    values: [1024]u8 = undefined,
    values_len: usize = 0,

    const Told = union(enum) {
        pop,
        action: model.Action,
        /// The value is `values[at..][0..len]`.
        field: struct { slot: usize, at: usize, len: usize },
    };

    fn add(h: *Heard, event: model.Event) void {
        std.debug.assert(h.n < h.told.len);
        h.told[h.n] = switch (event) {
            .pop => .pop,
            .action => |a| .{ .action = a },
            .field => |f| field: {
                std.debug.assert(h.values_len + f.value.len <= h.values.len);
                const at = h.values_len;
                @memcpy(h.values[at..][0..f.value.len], f.value);
                h.values_len += f.value.len;
                break :field .{ .field = .{ .slot = f.slot, .at = at, .len = f.value.len } };
            },
        };
        h.n += 1;
    }

    fn same(h: *const Heard, told: Told, event: model.Event) bool {
        return switch (event) {
            .pop => told == .pop,
            .action => |a| told == .action and told.action == a,
            .field => |f| told == .field and told.field.slot == f.slot and
                std.mem.eql(u8, h.values[told.field.at..][0..told.field.len], f.value),
        };
    }

    fn has(h: *const Heard, event: model.Event) bool {
        for (h.told[0..h.n]) |told| if (h.same(told, event)) return true;
        return false;
    }

    /// Whether the last events told were `events`, in order.
    fn endsWith(h: *const Heard, events: []const model.Event) bool {
        if (events.len > h.n) return false;
        const last = h.told[h.n - events.len .. h.n];
        for (last, events) |told, event| if (!h.same(told, event)) return false;
        return true;
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
    /// The panel's script screen (`Nanolight.scriptScreen`).
    screen: model.Screen,
    backing: std.mem.Allocator,
    heard: Heard = .{},

    const First = enum { confirm, output, form };

    fn tell(h: *Answering, update: model.Update) void {
        h.screen.func(h.screen.ctx, update);
    }

    /// `v`, in `arena`, the screen's.
    fn put(h: *Answering, arena: std.heap.ArenaAllocator, v: model.View) void {
        h.tell(.{ .show = .{ .arena = arena, .view = v } });
    }

    fn said(ctx: *anyopaque, event: model.Event) void {
        const h: *Answering = @ptrCast(@alignCast(ctx));
        h.heard.add(event);
        switch (event) {
            .pop => h.tell(.stop),
            // A dropdown's pick is shown; a typed name stays in its field.
            .field => |f| if (f.slot == 0) h.form(std.mem.eql(u8, f.value, "fr")),
            .action => |a| switch (a) {
                .run => h.output(),
                .again => h.confirm(),
                .copy => h.tell(.{ .note = .{ .text = "Copied to the clipboard", .bad = false } }),
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
        h.put(arena, .{ .detail = .{
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
        h.put(arena, .{ .detail = .{
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
        h.put(arena, .{ .form = .{
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
    host: Answering,
    /// Settings' answers, for the tests that open it.
    prefs: support.Prefs,
    opts: Options,
    hidden: bool,
    /// The script's row, among the apps.
    scripts: script_commands.List,

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
        r.host = .{ .screen = r.s.scriptScreen(), .backing = opts.backing };
        r.prefs = .{};
        r.prefs.init();
        r.scripts = .init(gpa);
        errdefer r.deinit();
        r.scripts.add(r.panel.ix.apps.items, "Greet", "scripts", "/scripts/greet.sh");
        r.scripts.finish();
        r.s.scripts = &r.scripts;
        r.s.host = .{ .ctx = r, .open = open, .hide = hide, .settings = &r.prefs.box };
        _ = r.s.show(0);
        if (!opts.rows) r.script();
        try r.panel.mount(.{ .screen = .none });
    }

    fn script(r: *Rig) void {
        const command: model.Command = .{ .name = "Greet", .icon = r.opts.icon };
        r.host.tell(.{ .start = .{
            .command = command,
            .to = .{ .ctx = &r.host, .func = Answering.said },
        } });
        // A silent one closes its screen and hides the panel, as the runner does.
        if (r.opts.silent) {
            r.host.tell(.stop);
            return hide(r);
        }
        if (r.opts.first) |first| r.host.show(first);
    }

    fn open(ctx: *anyopaque, target: Target) void {
        const r: *Rig = @ptrCast(@alignCast(ctx));
        if (target == .script) r.script();
    }

    fn hide(ctx: *anyopaque) void {
        const r: *Rig = @ptrCast(@alignCast(ctx));
        r.hidden = true;
    }

    fn deinit(r: *Rig) void {
        r.panel.unmount();
        r.panel.deinit();
        r.scripts.deinit();
    }

    fn heard(r: *const Rig, event: model.Event) bool {
        return r.host.heard.has(event);
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
        r.host.put(arena, .{ .detail = .{
            .title = "System Info",
            .body = .{ .output = out },
            .loading = sofar.len < 40,
        } });
        r.t.settle(0.2);
    }
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("System Info"));
    try std.testing.expect(r.t.hasText("Linux 6.17 on x86_64"));
    try std.testing.expect(r.t.hasText("Up: 3 min"));
    try std.testing.expect(r.t.hasText("/dev/vda1 10G 2G"));
    // Its lines are as tall as its height says.
    try std.testing.expectEqual(rv.output_line_h, r.t.findText("Up: 3 min").?.h);
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard(.pop) and r.hidden and r.s.screen != .script);
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
    try std.testing.expect(r.heard(.{ .action = .again }) and !r.heard(.{ .action = .copy }));
    try std.testing.expect(r.t.hasText("Run Greet?"));
    // With the actions open, one Escape pops and hides.
    try std.testing.expect(r.t.shortcut(rv.actions_key));
    r.t.settle(1);
    // The actions take the detail's place.
    try std.testing.expect(!r.t.containsText("Run Greet?"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard(.pop) and r.hidden and r.s.screen != .script);
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
    try std.testing.expect(r.host.heard.endsWith(&.{
        .{ .field = .{ .slot = 1, .value = "Rach" } },
        .{ .action = .run },
    }));
    try std.testing.expect(r.t.hasText("from a script"));
}

test "a compact script's last line, as the detail's heading" {
    const gpa = std.testing.allocator;
    var r: Rig = undefined;
    try r.init(gpa, .{});
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const md = try arena.allocator().dupe(u8, "# Hello, Rach - from a script\nSays hi.");
    r.host.put(arena, .{ .detail = .{ .title = "Greet", .body = .{ .markdown = md } } });
    r.t.settle(1);
    // Above the rest, and larger.
    const heading = r.t.findText("Hello, Rach - from a script").?;
    const body = r.t.findText("Says hi.").?;
    try std.testing.expect(heading.y + heading.h <= body.y);
    try std.testing.expect(heading.h > body.h);
}

test "Escape closes a script's screen in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("Run Greet?"));
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.heard(.pop) and r.hidden and r.s.screen != .script);
    r.t.settle(1);
    try std.testing.expect(!r.t.hasText("Run Greet?"));
}

test "the back button closes a script's screen in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.hasText("from a script"));
    try support.clickButton(r.t, "Back");
    try std.testing.expect(r.heard(.pop) and !r.hidden and r.s.screen != .script);
    r.t.settle(1);
    try std.testing.expect(!r.t.hasText("from a script"));
}

test "Return on Run X? replaces the view in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm });
    defer r.deinit();
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.heard(.{ .action = .run }));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("from a script"));
    try std.testing.expect(!r.t.containsText("Run Greet?"));
}

test "Run Again replaces the output in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    try std.testing.expect(r.t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expect(r.heard(.{ .action = .again }));
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Run Greet?"));
}

test "a dropdown pick shows the form again in the frame that drew it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .form });
    defer r.deinit();
    const picked = optionBg(r.t, "English").?;
    const other = optionBg(r.t, "French").?;
    try std.testing.expect(!std.meta.eql(picked, other));
    try r.t.clickText("French");
    try std.testing.expect(r.heard(.{ .field = .{ .slot = 0, .value = "fr" } }));
    r.t.settle(1);
    try std.testing.expect(r.s.screen == .script);
    try std.testing.expectEqual(picked, optionBg(r.t, "French").?);
    try std.testing.expectEqual(other, optionBg(r.t, "English").?);
}

/// The background of the dropdown option titled `title`.
fn optionBg(t: *ui.Tester, title: []const u8) ?ui.Color {
    const nodes = t.ctx.nodes.items;
    for (nodes) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, title)) return nodes[n.parent].style.background,
        else => {},
    };
    return null;
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
    try std.testing.expect(r.s.screen != .script);
}

test "a script's row opens its screen, and the panel stays" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .confirm, .rows = true });
    defer r.deinit();
    r.t.typeText("greet");
    r.t.settle(1);
    try std.testing.expect(r.t.hasText("Greet") and r.s.screen != .script);
    r.t.textOps(&.{.{ .command = .insert_newline }});
    try std.testing.expect(r.s.screen == .script and !r.hidden);
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
    try std.testing.expect(r.s.screen != .script and r.hidden);
}

test "Settings opened over Clipboard History closes it, so Escape leaves the rows for next time" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .rows = true });
    defer r.deinit();
    r.s.open(.clipboard);
    r.t.settle(1);
    // As the tray's Settings… opens it.
    r.s.open(.settings);
    try std.testing.expect(r.s.screen == .settings);
    r.t.settle(1);
    _ = r.t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.hidden and r.s.screen != .settings);
    _ = r.s.show(0);
    r.t.settle(1);
    try std.testing.expect(r.s.screen != .clipboard);
    try std.testing.expect(r.t.hasText("Search apps, do math, search the web…"));
}

test "Settings or Clipboard History opened over a script's screen end the script and close it" {
    var r: Rig = undefined;
    try r.init(std.testing.allocator, .{ .first = .output });
    defer r.deinit();
    // A hide and a reveal keep it.
    _ = r.s.show(0);
    try std.testing.expect(r.s.screen == .script);
    r.s.open(.settings);
    try std.testing.expect(r.heard(.pop) and r.s.screen == .settings);
    r.t.settle(1);
    try std.testing.expect(!r.t.containsText("from a script"));
    r.s.open(.clipboard);
    try std.testing.expect(r.s.screen == .clipboard);
}

test "a script's icon outlives the index it came from" {
    const gpa = std.testing.allocator;
    // The index's icon, in page memory: handed back to the system when the
    // index is replaced, so a read of it afterwards faults.
    const png = try std.heap.page_allocator.dupe(u8, chrome.icon_png);
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
        .width = chrome.width,
        .height = chrome.max_height,
        .dark = true,
    });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("from a script"));
    // Escape stops the screen while a frame is drawn: its icon goes after.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(r.s.screen != .script);
    t.settle(1);
}
