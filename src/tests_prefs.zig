//! Issues #8, #9 and #10 through the Tester: the panel's first frame on
//! the Mac, searches sent to the browser, and the two Settings rows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const settings_view = @import("settings_view.zig");
const tests = @import("tests.zig");
const suggest = @import("suggest.zig");
const mac = @import("builtin").os.tag == .macos;
const placeholder = "Search apps, do math, search the web…";

/// Where the field's placeholder is in the first frame after the panel
/// shows, and once it has settled.
fn firstAndSettled(fades: bool) ![2]ui.Rect {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var s: view.Nanolight = .{ .index = &ix, .window_fades = fades, .margin = view.shadow_margin };
    defer s.query.deinit();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width + 2 * view.shadow_margin, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.frame();
    const first = t.findText(placeholder) orelse return error.NoField;
    t.settle(1);
    return .{ first, t.findText(placeholder) orelse return error.NoField };
}

test "on the Mac the panel's first frame is where it settles (issue #9)" {
    // The window fades in, the system's glass with it: the panel drawn
    // over that glass comes in at once, not from above and transparent.
    const r = try firstAndSettled(true);
    try std.testing.expectEqual(r[1].y, r[0].y);
    try std.testing.expectEqual(r[1].x, r[0].x);
    // Without the window's fade (Windows and Linux) it still comes in: this
    // is what the Mac's panel did over a glass that didn't.
    const own = try firstAndSettled(false);
    try std.testing.expect(own[0].y < own[1].y);
}

fn findRow(t: *ui.Tester, s: *view.Nanolight, words: []const u8) void {
    tests.press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = words } });
    while (!tests.onFirstQuicklink(s)) _ = t.shortcut(.{ .key = ui.Shortcut.down });
}

test "searches can open in the browser, ⌘↩ showing them in the panel (issue #10)" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("Safari", "/Applications/Safari.app");
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix, .searches_out = true };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    // Return: the browser, and the panel goes.
    findRow(&t, &s, "pizza");
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pizza", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden and web.page_len == null and !s.previewing);
    // ⌘↩: the page in the panel, which stays.
    web.probe = .{};
    s.reveal();
    t.settle(1);
    findRow(&t, &s, "pasta");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings("https://www.google.com/search?q=pasta", web.page[0..web.page_len.?]);
    try std.testing.expect(!web.probe.hidden and web.probe.opened_len == 0 and s.previewing);
}

test "Settings hides the menu bar icon and sends searches out (issues #8, #10)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    prefs.nl = &s;
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try t.clickText("Show in Menu Bar");
    t.settle(1);
    try std.testing.expect(!prefs.menu_bar_on);
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(s.searches_out and prefs.searches_out.?);
    // Twice more each: back as they were.
    try t.clickText("Show in Menu Bar");
    try t.clickText("Open Searches in Browser");
    t.settle(1);
    try std.testing.expect(prefs.menu_bar_on and !s.searches_out and !prefs.searches_out.?);
    // The rows fit: the last one is inside Settings, Settings in the window.
    const quit = t.findText("Quit Nanolight").?;
    try std.testing.expect(quit.y + quit.h <= settings_view.height);
    try std.testing.expect(settings_view.height <= view.max_height);
}

test "Settings' Open at Login flips what the system says, not a copy" {
    if (@import("build_options").nix_managed) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{
        .width = view.width,
        .height = view.max_height,
        .dark = true,
    });
    defer t.deinit();
    t.settle(1);
    try t.clickText("Open at Login");
    t.settle(1);
    try std.testing.expect(prefs.login_on);
    // Turned off elsewhere (System Settings) while Settings is open: the
    // next click turns it on again, from what the system says.
    prefs.login_on = false;
    t.settle(1);
    try t.clickText("Open at Login");
    t.settle(1);
    try std.testing.expect(prefs.login_on);
}

test "recording a key: idle, recording, refused, and never without a recorder" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{
        .width = view.width,
        .height = view.max_height,
        .dark = true,
    });
    defer t.deinit();
    t.settle(1);
    const ui_s = &s.settings_ui;
    const shortcut = @import("shortcut.zig");
    // Return on the shortcut row: recording, the recorder with it.
    ui_s.activateSelected(&s);
    try std.testing.expectEqual(settings_view.KeyInput.recording, ui_s.key_input);
    try std.testing.expect(prefs.recording);
    // A letter alone is refused; it still waits.
    ui_s.took(&s, shortcut.recorded(7, 0, 'x'));
    try std.testing.expectEqual(settings_view.KeyInput.refused, ui_s.key_input);
    try std.testing.expect(prefs.recording);
    // ⌥X is taken: idle, the recorder stopped, the key applied.
    ui_s.took(&s, shortcut.recorded(7, 1 << 19, 'x'));
    try std.testing.expectEqual(settings_view.KeyInput.idle, ui_s.key_input);
    try std.testing.expect(!prefs.recording);
    try std.testing.expect(prefs.applied.?.eql(.{ .code = 7, .mods = 1 << 11 }));
    // Esc while recording: idle, nothing applied.
    prefs.applied = null;
    ui_s.activateSelected(&s);
    ui_s.took(&s, shortcut.recorded(53, 0, 0));
    try std.testing.expectEqual(settings_view.KeyInput.idle, ui_s.key_input);
    try std.testing.expect(prefs.applied == null and !prefs.recording);
    // A key pressed while idle is no one's.
    ui_s.took(&s, shortcut.recorded(7, 1 << 19, 'x'));
    try std.testing.expect(prefs.applied == null);
    // The recorder could not start: not recording.
    prefs.can_record = false;
    ui_s.activateSelected(&s);
    try std.testing.expectEqual(settings_view.KeyInput.idle, ui_s.key_input);
    try std.testing.expect(!prefs.recording);
}

test "Settings' header picks the panel's theme, and keeps it" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.findText("System") != null);
    // ↑ from the first row: round to the header's swatches; → twice.
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    _ = t.shortcut(.{ .key = ui.Shortcut.right });
    _ = t.shortcut(.{ .key = ui.Shortcut.right });
    t.settle(1);
    try std.testing.expectEqual(view.Theme.forest, s.theme);
    try std.testing.expectEqual(view.Theme.forest, prefs.theme.?);
    try std.testing.expect(t.findText("Forest") != null);
    // ← past the first: round to the last.
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    _ = t.shortcut(.{ .key = ui.Shortcut.left });
    t.settle(1);
    try std.testing.expectEqual(view.Theme.violet, prefs.theme.?);
    // In the header, which the rows can't push out of sight.
    const name = t.findText("Violet").?;
    try std.testing.expect(name.y + name.h <= view.header_h);
}

test "System Settings' panes open from the panel, which stays in its window (#12)" {
    if (!mac) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    try ix.add("System Settings", "/System/Applications/System Settings.app");
    for ([_][]const u8{ "Sound A", "Sound B", "Sound C", "Sound D", "Sound E", "Sound F" }) |n| {
        var buf: [64]u8 = undefined;
        try ix.add(n, try std.fmt.bufPrint(&buf, "/Applications/{s}.app", .{n}));
    }
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    tests.press(&t, &.{.{ .insert = "login items" }});
    try std.testing.expect(t.hasText("Login Items & Extensions"));
    try std.testing.expect(t.hasText("Open in System Settings"));
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension", web.probe.opened[0..web.probe.opened_len]);
    try std.testing.expect(web.probe.hidden);
    // Every app row, a pane, and Google's completions: the tallest list
    // with four sections still fits.
    s.reveal();
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "sound" } });
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "sound 1", "sound 2", "sound 3", "sound 4" }) |w| four.push(w);
    s.answered("sound", &four);
    t.settle(1);
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expect(s.height() <= view.max_height);
}

test "the panel's height lands at once, and keeps Google's room between keys" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.host.?.resize = struct {
        fn f(_: *anyopaque, _: f32) void {}
    }.f;
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height });
    defer t.deinit();
    t.frame();
    t.textOps(&.{.{ .insert = "liq" }});
    t.frame();
    const bare = s.last_h;
    // Google's rows: taller, in the one frame that lists them.
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid", "liquid glass" }) |w| said.push(w);
    s.answered("liq", &said);
    t.frame();
    const full = s.last_h;
    try std.testing.expect(full > bare);
    // A key none of them begins with clears them, and the panel keeps
    // their room.
    t.textOps(&.{.{ .insert = "x" }});
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), s.web.n);
    try std.testing.expectEqual(full, s.last_h);
    // An answer to older words is no answer to these.
    s.unanswered("liq");
    t.frame();
    try std.testing.expectEqual(full, s.last_h);
    // No answer is coming: the room goes, at once.
    s.unanswered("liqx");
    t.frame();
    try std.testing.expectEqual(bare, s.last_h);
    // Nothing is asked about an empty field, so nothing is kept for it.
    s.answered("liqx", &said);
    t.frame();
    t.textOps(&.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    t.frame();
    try std.testing.expectEqual(s.height(), s.last_h);
    try std.testing.expectEqual(@as(f32, 0), s.held_h);
}

test "Google's answer landing after suggestions are turned off lists nothing" {
    const gpa = std.testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var web: tests.Web = .{};
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = web.host();
    s.reveal();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{
        .width = view.width,
        .height = view.max_height,
    });
    defer t.deinit();
    t.frame();
    t.textOps(&.{.{ .insert = "liq" }});
    t.frame();
    // Asked while on; turned off (the menu, Settings or sync) before it lands.
    s.suggest_on = false;
    s.built = 1;
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid", "liquid glass" }) |w| said.push(w);
    s.answered("liq", &said);
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 0), s.web.n);
    try std.testing.expect(!t.hasText("liquid glass"));
    try std.testing.expectEqual(@as(f32, 0), s.held_h);
    // Nor is it kept for when they come back on.
    var cached: suggest.List = .{};
    try std.testing.expect(!s.cache.lookup("liq", &cached));
}
