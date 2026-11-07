//! Nanolight's parts, and its panel driven through a Tester: keys in,
//! rows and the clipboard out. Nothing is opened; no window shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("view.zig");
const chrome = @import("chrome.zig");
const support = @import("test_support.zig");
const Rig = support.Rig;
const Probe = support.Probe;
const Web = support.Web;
const Prefs = support.Prefs;
const onFirstQuicklink = support.onFirstQuicklink;
const press = support.press;
const retype = support.retype;

test {
    _ = @import("search.zig");
    _ = @import("calc.zig");
    _ = @import("convert.zig");
    _ = @import("rates.zig");
    _ = @import("rates_table.zig");
    _ = @import("results.zig");
    _ = @import("query.zig");
    _ = @import("suggest.zig");
    _ = @import("settings.zig");
    _ = @import("sync_protocol.zig");
    _ = @import("server_protocol.zig");
    _ = @import("server_transport.zig");
    _ = @import("account.zig");
    _ = @import("toml.zig");
    _ = @import("config.zig");
    _ = @import("prefs.zig");
    _ = @import("palette.zig");
    _ = @import("apps.zig");
    _ = @import("app_scan.zig");
    _ = @import("launch_counts.zig");
    _ = @import("paths.zig");
    _ = @import("spotlight.zig");
    _ = @import("keys.zig");
    _ = @import("shortcut.zig");
    _ = @import("shortcut_clash.zig");
    _ = @import("settings_panes.zig");
    _ = @import("commands.zig");
    _ = @import("proc.zig");
    _ = @import("clipboard.zig");
    _ = @import("clipboard_win.zig");
    _ = @import("clipboard_poll.zig");
    _ = @import("clipboard_view.zig");
    _ = @import("tests_clipboard.zig");
    _ = @import("raycast_model.zig");
    _ = @import("raycast_view.zig");
    _ = @import("script_commands.zig");
    _ = @import("script_run.zig");
    _ = @import("tests_ext.zig");
    _ = @import("tests_prefs.zig");
    _ = @import("tests_files.zig");
    _ = @import("platform.zig");
    _ = @import("web.zig");
    _ = @import("launchers.zig");
    _ = @import("single.zig");
    _ = @import("screen.zig");
    switch (@import("builtin").os.tag) {
        .macos => {
            _ = @import("apps_mac.zig");
            _ = @import("single_mac.zig");
            _ = @import("clickthrough.zig");
            _ = @import("hotkey_mac.zig");
            _ = @import("recorder.zig");
        },
        .windows => {
            _ = @import("apps_win.zig");
            _ = @import("hotkey_win.zig");
        },
        else => {
            _ = @import("apps_linux.zig");
            _ = @import("hotkey_x11.zig");
            _ = @import("clipboard_linux.zig");
            _ = @import("clipboard_offer.zig");
            _ = @import("clipboard_x11.zig");
            _ = @import("clipboard_wl.zig");
        },
    }
}

test "the panel finds, moves, answers and hands off" {
    const gpa = std.testing.allocator;
    var probe: Probe = .{};
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const ix = &rig.ix;
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{ "Safari", "System Settings", "Notes", "Calculator", "Finder" });
    try rig.mount(.{ .host = probe.host(), .height = 480 });
    // No query: suggestions.
    try std.testing.expect(t.hasText("Suggestions"));
    try std.testing.expect(t.hasText("Safari"));
    // After an automatic update, the footer says so in place of the name.
    try std.testing.expect(t.hasText("Nanolight · 5 apps"));
    s.note = "Updated to 0.1.3";
    t.settle(1);
    try std.testing.expect(t.hasText("Updated to 0.1.3 · 5 apps"));
    s.note = "";

    // The top app's name completes what is typed; → takes it.
    press(t, &.{.{ .insert = "saf" }});
    try std.testing.expect(t.hasText("ari"));
    press(t, &.{.{ .command = .move_right }});
    try std.testing.expectEqualStrings("safari", s.query.text());
    press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });

    // An exact app name beats panes that may outrank its initials.
    press(t, &.{.{ .insert = "system settings" }});
    try std.testing.expect(t.hasText("System Settings"));
    try std.testing.expectEqual(@as(u32, ix.find("System Settings").?), s.rows()[0].item);
    // Down and back up, then Return opens the first.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try std.testing.expectEqual(@as(?usize, 1), s.selection());
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings(
        "/Applications/System Settings.app",
        probe.opened[0..probe.opened_len],
    );
    try std.testing.expect(probe.hidden);
    try std.testing.expectEqual(@as(u16, 1), s.counts.of("/Applications/System Settings.app"));

    // ⌘2 opens the second row at once: Safari, under System Settings,
    // which was just opened.
    retype(t, "s");
    try std.testing.expect(t.hasText(@import("platform.zig").mod ++ "2"));
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    try std.testing.expectEqualStrings(
        "/Applications/Safari.app",
        probe.opened[0..probe.opened_len],
    );

    // Math: answered, and Return copies it.
    retype(t, "2^10 * 3");
    try std.testing.expect(t.hasText("3,072"));
    try std.testing.expect(t.hasText("Result · 0xC00"));
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings("3072", t.clipboard.items);

    // Anything else: the quicklinks, Google first (Claude, Grok and X among them).
    retype(t, "liquid glass");
    try std.testing.expect(t.containsText("Search Claude for"));
    try std.testing.expect(t.containsText("Search X for"));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings(
        "https://claude.ai/new?q=liquid%20glass",
        probe.opened[0..probe.opened_len],
    );

    // Escape closes at once, even with a query; the query waits for next time.
    probe.hidden = false;
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(probe.hidden);
    try std.testing.expectEqualStrings("liquid glass", s.query.text());
}

const suggest = @import("suggest.zig");
const results = @import("results.zig");
const rates = @import("rates.zig");
const rates_table = @import("rates_table.zig");

test "a pending currency card is not the default row, and Return acts on the search under it" {
    const gpa = std.testing.allocator;
    var web: Web = .{};
    var live: rates.Live = .{};
    defer live.deinit();
    const feed = &live.feed;
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    s.rates = &live;
    try rig.mount(.{ .host = web.host() });
    press(t, &.{.{ .insert = "100 usd to ttd" }});
    // The card waits on the rates, unselected.
    try std.testing.expectEqual(results.Kind.calc, s.rows()[0].kind);
    try std.testing.expectEqual(@as(?usize, 1), s.selection());
    try std.testing.expect(onFirstQuicklink(s));
    try std.testing.expect(t.hasText("Search Google"));
    try std.testing.expect(!t.hasText("Copy Answer"));
    // Arrowing onto the card still leaves Return meaning the search.
    _ = t.shortcut(.{ .key = ui.Shortcut.up });
    try std.testing.expectEqual(@as(?usize, 0), s.selection());
    try std.testing.expect(t.hasText("Search Google"));
    // The fetch fails: the card stays pending and the selection stays put.
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    feed.begin(1);
    feed.fail();
    s.refill(.rates);
    t.settle(1);
    try std.testing.expectEqual(results.Kind.calc, s.rows()[0].kind);
    try std.testing.expectEqual(@as(?usize, 1), s.selection());
    try std.testing.expect(t.hasText("Rates unavailable"));
    // A retry on its way is not a failure.
    feed.begin(1 + rates.retry_after);
    s.refill(.rates);
    t.settle(1);
    try std.testing.expect(t.hasText("Loading rates…"));
    // The rates land: the card is the answer, and selected.
    const body = "{\"date\":\"2026-11-03\",\"usd\":{\"usd\":1,\"ttd\":6.785}}";
    feed.landed(rates_table.Rates.parse(gpa, body).?, 1 + rates.retry_after);
    s.refill(.rates);
    t.settle(1);
    try std.testing.expectEqual(results.Kind.calc, s.rows()[0].kind);
    try std.testing.expectEqual(@as(?usize, 0), s.selection());
    try std.testing.expect(t.hasText("Copy Answer"));
}

test "math being typed asks Google nothing while its card shows" {
    const gpa = std.testing.allocator;
    var web: Web = .{};
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = web.host() });
    // The answer so far, a conversion's, and one waiting on rates.
    for ([_][]const u8{ "2 + 3 *", "10 km to mi *", "500 usd to eur *" }) |q| {
        retype(t, q);
        try std.testing.expectEqual(results.Kind.calc, s.rows()[0].kind);
        try std.testing.expectEqual(@as(usize, 0), web.asked_len);
    }
    retype(t, "2 + 3 is");
    try std.testing.expectEqualStrings("2 + 3 is", web.asked[0..web.asked_len]);
}

test "a long paste is cut to the longest query, on a character boundary, a whole path is not" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .height = 480 });
    // A file path as long as any found one is kept whole.
    var path: [view.max_query_bytes]u8 = undefined;
    path[0] = '/';
    @memset(path[1..], 'a');
    press(t, &.{.{ .insert = &path }});
    try std.testing.expectEqualStrings(&path, s.query.text());
    press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward } });
    var paste: [view.max_query_bytes + 1]u8 = undefined;
    @memset(paste[0 .. view.max_query_bytes - 1], '(');
    @memcpy(paste[view.max_query_bytes - 1 ..], "é");
    press(t, &.{.{ .insert = &paste }});
    try std.testing.expectEqual(view.max_query_bytes - 1, s.query.text().len);
    t.settle(1);
    try std.testing.expect(s.rows().len > 0);
}

test "Google's completions land below, and a search shows in the panel" {
    const gpa = std.testing.allocator;
    var web: Web = .{};
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{"Safari"});
    try rig.mount(.{ .host = web.host() });
    // An address is never asked about; words are.
    press(t, &.{.{ .insert = "ziglang.org" }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);
    retype(t, "liquid gl");
    try std.testing.expectEqualStrings("liquid gl", web.asked[0..web.asked_len]);
    // Return would search what was typed. The selection, moved before
    // the answer comes, stays on its row, though the completions land
    // above it, a key under the search.
    try std.testing.expect(onFirstQuicklink(s));
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expectEqual(@as(u32, 2), s.selected().?.item);
    var said: suggest.List = .{};
    for ([_][]const u8{ "liquid glass", "liquid glass apple" }) |w| said.push(w);
    s.answered("liquid gl", &said);
    t.settle(1);
    try std.testing.expect(t.hasText("Search"));
    try std.testing.expect(t.hasText("liquid glass apple"));
    try std.testing.expectEqual(results.Kind.suggest, s.rows()[1].kind);
    try std.testing.expectEqual(@as(u32, 2), s.selected().?.item);
    // The first completion shows faintly in the field; Tab takes it.
    try std.testing.expect(t.hasText("ass"));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass", s.query.text());
    retype(t, "liquid gl");
    // Known at once this time, yet Return still searches what was typed,
    // not a completion nobody picked.
    try std.testing.expectEqual(results.Kind.suggest, s.rows()[1].kind);
    try std.testing.expect(onFirstQuicklink(s));
    // ⌘2 is Google's first completion.
    try std.testing.expect(t.hasText(@import("platform.zig").mod ++ "2"));
    // One more letter: the answer so far stands in, and nothing is asked
    // again for words already answered.
    web.asked_len = 0;
    press(t, &.{.{ .insert = "a" }});
    try std.testing.expectEqualStrings("liquid gla", web.asked[0..web.asked_len]);
    try std.testing.expect(t.hasText("liquid glass apple"));
    web.asked_len = 0;
    press(t, &.{.{ .command = .delete_backward }});
    try std.testing.expectEqual(@as(usize, 0), web.asked_len);

    // ⌘3, the second completion: its words in the field, Google's page in the panel.
    try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
    t.settle(1);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());
    try std.testing.expectEqualStrings(
        "https://www.google.com/search?q=liquid%20glass%20apple",
        web.page[0..web.page_len.?],
    );
    t.settle(2);
    try std.testing.expect(t.hasText("Open in Browser"));
    try std.testing.expectEqual(chrome.max_height, s.height());
    try std.testing.expect(!web.probe.hidden);
    // Escape: the page gone, and the panel with it.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(web.page_len == null);
    try std.testing.expect(web.probe.hidden);
    try std.testing.expectEqualStrings("liquid glass apple", s.query.text());
    web.probe.hidden = false;

    // Return on words no app matches: Google's page; typing takes it away.
    retype(t, "pizza");
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqualStrings(
        "https://www.google.com/search?q=pizza",
        web.page[0..web.page_len.?],
    );
    press(t, &.{.{ .insert = "s" }});
    try std.testing.expect(web.page_len == null);
    try std.testing.expect(t.hasText("Search Google for “pizzas”"));

    // ⌘↩ in the page, and on the row: the browser, and the panel hides.
    while (!onFirstQuicklink(s)) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(web.page_len != null);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings(
        "https://www.google.com/search?q=pizzas",
        web.probe.opened[0..web.probe.opened_len],
    );
    try std.testing.expect(web.probe.hidden);
    _ = s.show(0);
    try std.testing.expect(web.page_len == null);
    web.probe = .{};
    t.settle(1);
    while (!onFirstQuicklink(s)) _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }));
    try std.testing.expectEqualStrings(
        "https://www.google.com/search?q=pizzas",
        web.probe.opened[0..web.probe.opened_len],
    );
}

const onboard = @import("onboard.zig");
const keys = @import("keys.zig");
const shortcut_clash = @import("shortcut_clash.zig");
const nix = @import("build_options").nix_managed;

const Steps = struct {
    applied: ?keys.Choice = null,
    done: bool = false,
    ended: u8 = 0,
    fn apply(ctx: *anyopaque, c: keys.Choice) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.applied = c;
    }
    fn fix(_: *anyopaque, _: shortcut_clash.Clash) void {}
    fn finished(ctx: *anyopaque) void {
        const p: *Steps = @ptrCast(@alignCast(ctx));
        p.done = true;
        p.ended += 1;
    }
    fn loginOff(_: ?bool) bool {
        return false;
    }
};

/// Whether everything drawn is within the panel's height `h`: nothing
/// pushed below its edge, where the window clips it.
fn fitsPanel(t: *ui.Tester, h: f32) bool {
    for (t.ctx.nodes.items[1..]) |n| if (n.rect.y + n.rect.h > h + 0.01) return false;
    return true;
}

test "each welcome step fits the room its height gives it" {
    const gpa = std.testing.allocator;
    var o: onboard.Onboard = .{};
    o.start(.opt_space);
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    s.open(.{ .welcome = &o });
    try rig.mount(.{ .screen = .none });
    try std.testing.expect(fitsPanel(t, s.height()));
    if (@import("builtin").os.tag == .macos) {
        const sys = [_]shortcut_clash.SystemKey{
            .{ .id = .spotlight, .enabled = true, .key = keys.space, .mods = keys.ns_cmd },
        };
        o.holders.system = &sys;
        o.choice = .cmd_space;
        t.settle(1);
        try std.testing.expect(!o.clash().clear());
        try std.testing.expect(fitsPanel(t, s.height()));
    }
    // Hooks only once started (the system's shortcuts are not read in
    // tests), asking about login: the last step's tallest.
    var steps: Steps = .{};
    o.hooks = .{
        .ctx = &steps,
        .apply = Steps.apply,
        .fix = Steps.fix,
        .done = Steps.finished,
        .login = Steps.loginOff,
    };
    t.key(.enter);
    t.settle(1);
    try std.testing.expect(t.containsText(" now"));
    try std.testing.expect(fitsPanel(t, s.height()));
    o.pressed(true);
    o.pressed(false);
    t.settle(2);
    try std.testing.expect(t.hasText("You're set."));
    try std.testing.expect(t.hasText("Open Nanolight when you log in"));
    try std.testing.expect(fitsPanel(t, s.height()));
}

test "a screen over the welcome skips it once, without its key" {
    var o: onboard.Onboard = .{};
    o.start(.cmd_space);
    var steps: Steps = .{};
    o.hooks = .{ .ctx = &steps, .apply = Steps.apply, .fix = Steps.fix, .done = Steps.finished };
    o.choice = .opt_space;
    var rig: Rig = undefined;
    rig.init(std.testing.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.open(.{ .welcome = &o });
    s.open(.settings);
    try std.testing.expect(s.screen == .settings);
    try std.testing.expect(steps.ended == 1 and steps.applied == null);
    // Gone already: nothing ends it again.
    s.open(.clipboard);
    s.escape();
    try std.testing.expectEqual(@as(u8, 1), steps.ended);
}

test "the welcome: a key, pressed for real, then a first search" {
    // Its keys and clashes are the Mac's (macOS's own shortcuts).
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var o: onboard.Onboard = .{};
    // Hooks only once started: the system's shortcuts are not read in tests.
    o.start(.cmd_space);
    const sys = [_]shortcut_clash.SystemKey{
        .{ .id = .spotlight, .enabled = true, .key = keys.space, .mods = keys.ns_cmd },
    };
    o.holders.system = &sys;
    var steps: Steps = .{};
    o.hooks = .{ .ctx = &steps, .apply = Steps.apply, .fix = Steps.fix, .done = Steps.finished };
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const t = &rig.t;
    try rig.apps(&.{"Safari"});
    rig.s.open(.{ .welcome = &o });
    try rig.mount(.{ .screen = .none, .height = 480 });
    try std.testing.expect(t.hasText("Welcome to Nanolight"));
    // Who holds ⌘Space, by name; going on anyway is said as such.
    try std.testing.expect(t.hasText("macOS gives ⌘ Space to Spotlight first."));
    try std.testing.expect(t.hasText("Use ⌘ Space anyway"));
    t.key(.right);
    try std.testing.expect(t.hasText("⌥ Space is free on this Mac."));
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(keys.Choice.opt_space, steps.applied.?);
    try std.testing.expect(t.hasText("Press ⌥ Space now"));
    // A button never moves it on: the key closing the panel, then opening it.
    o.pressed(false);
    t.settle(1);
    try std.testing.expectEqual(onboard.Step.try_it, o.step);
    o.pressed(true);
    o.pressed(false);
    t.settle(2);
    try std.testing.expect(t.hasText("You're set."));
    // ⌘2: the math example, run in the launcher.
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(1);
    try std.testing.expect(steps.done and rig.s.screen != .welcome);
    try std.testing.expect(t.hasText("3,072"));

    // Esc skips from the first step, keeping the key shown there: applied
    // only when it is not the one in use already.
    steps = .{};
    o.start(.ctrl_space);
    rig.s.open(.{ .welcome = &o });
    t.settle(1);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(steps.done and rig.s.screen != .welcome);
    try std.testing.expect(steps.applied == null);
    steps = .{};
    o.start(.ctrl_space);
    rig.s.open(.{ .welcome = &o });
    t.settle(1);
    t.key(.right);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(steps.done and rig.s.screen != .welcome);
    try std.testing.expectEqual(keys.Choice.opt_cmd_space, steps.applied.?);
}

test "settings opens from ⌘,, from typing, and from the gear" {
    const gpa = std.testing.allocator;
    var prefs: Prefs = .{};
    prefs.init();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{"Safari"});
    prefs.nl = s;
    try rig.mount(.{ .host = prefs.host() });
    // The gear is in the footer, named for assistive apps.
    try support.clickButton(t, "Settings");
    t.settle(1);
    try std.testing.expect(s.screen == .settings);
    try std.testing.expect(t.hasText("Open Nanolight with"));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(s.screen != .settings and prefs.probe.hidden);
    prefs.probe.hidden = false;

    // ⌘, opens it; Esc closes it and the panel, the search there next time.
    try std.testing.expect(t.shortcut(.{ .key = ',', .cmd = true }));
    t.settle(1);
    try std.testing.expect(s.screen == .settings);
    try std.testing.expect(t.hasText("Google Suggestions"));
    try std.testing.expect(t.hasText(support.sync_status));
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try std.testing.expect(s.screen != .settings and prefs.probe.hidden);
    try std.testing.expect(t.hasText("Safari"));

    // Typing "settings" lists the row; Return opens it.
    press(t, &.{.{ .insert = "settings" }});
    try std.testing.expect(t.hasText("Nanolight Settings"));
    try std.testing.expectEqual(results.Kind.settings, s.rows()[0].kind);
    press(t, &.{.{ .command = .insert_newline }});
    t.settle(1);
    try std.testing.expect(s.screen == .settings);

    // → picks the next shortcut and tells the host.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
    try std.testing.expectEqual(keys.Choice.opt_space, prefs.applied.?);

    // On the Mac, Return on it records a key of one's own (issue #1): a
    // letter alone is refused, ⌥X is taken, kept, and shown as the chosen
    // one. (A PC keeps to the four.)
    if (keys.any_key) {
        press(t, &.{.{ .command = .insert_newline }});
        t.settle(1);
        try std.testing.expect(prefs.recording and t.hasText("Type a shortcut"));
        s.recorded(keys.recorded(7, 0, 'x'));
        t.settle(1);
        try std.testing.expect(prefs.recording and t.hasText("Add ⌘, ⌥ or ⌃"));
        s.recorded(keys.recorded(7, keys.ns_opt, 'x'));
        t.settle(1);
        try std.testing.expect(!prefs.recording and t.hasText("⌥ X"));
        try std.testing.expect(prefs.applied.?.eql(.{ .code = 7, .mods = keys.option }));
        // ← goes back to the four.
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.left }));
        try std.testing.expect(prefs.applied.?.eql(.opt_cmd_space));
        try std.testing.expect(t.hasText("⌥ X"));
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
        try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.right }));
        try std.testing.expectEqual(keys.Choice.opt_space, prefs.applied.?);
    }

    // ↓ onto Google Suggestions, Return flips it.
    try std.testing.expect(s.suggest_on);
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expect(s.screen == .settings);
    try std.testing.expectEqual(@as(u8, 1), prefs.suggest_sets);
    try std.testing.expect(!s.suggest_on);
    // Still on it: Return flips it back.
    press(t, &.{.{ .command = .insert_newline }});
    try std.testing.expectEqual(@as(u8, 2), prefs.suggest_sets);
    try std.testing.expect(s.suggest_on);
    try std.testing.expect(s.height() <= chrome.max_height);
}

test "the panel never outgrows its window, which is never resized" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    try rig.apps(&.{
        "Safari",  "Mail",  "Maps",   "Music",    "Notes",
        "Numbers", "Pages", "Photos", "Calendar", "Calculator",
    });
    var tallest: f32 = 0;
    for ([_][]const u8{ "", "a", "s", "ma", "2^10 * 3", "1+a", "liquid glass" }) |q| {
        s.query.set(q);
        s.rebuild();
        tallest = @max(tallest, s.height());
    }
    try std.testing.expect(tallest <= chrome.max_height);
    // "a" fills every app row there is, and Google's completions the
    // rest: the bound is the real one.
    s.query.set("a");
    s.rebuild();
    var four: @import("suggest.zig").List = .{};
    for ([_][]const u8{ "a1", "a2", "a3", "a4" }) |w| four.push(w);
    s.answered("a", &four);
    try std.testing.expectEqual(chrome.max_height, s.height());
}

fn settingsRig(rig: *Rig, prefs: *Prefs) !void {
    prefs.init();
    rig.init(std.testing.allocator);
    errdefer rig.deinit();
    prefs.nl = &rig.s;
    try rig.mount(.{ .host = prefs.host(), .screen = .settings });
}

test "Settings has login and updates rows, under this machine's name" {
    if (nix) return error.SkipZigTest;
    var prefs: Prefs = .{};
    var rig: Rig = undefined;
    try settingsRig(&rig, &prefs);
    defer rig.deinit();
    try std.testing.expect(rig.t.hasText("This " ++ @import("platform.zig").machine));
    try std.testing.expect(rig.t.hasText("Open at Login"));
    try std.testing.expect(rig.t.hasText("Check for Updates"));
}

test "a Nix build's Settings has no login or updates row" {
    if (!nix) return error.SkipZigTest;
    var prefs: Prefs = .{};
    var rig: Rig = undefined;
    try settingsRig(&rig, &prefs);
    defer rig.deinit();
    try std.testing.expect(rig.t.hasText("Google Suggestions"));
    try std.testing.expect(!rig.t.hasText("Open at Login"));
    try std.testing.expect(!rig.t.hasText("Check for Updates"));
}

test "on a PC the panel's keys are Ctrl's, and Settings says so" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var prefs: Prefs = .{};
    prefs.init();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{ "Safari", "System Settings" });
    try rig.mount(.{ .host = prefs.host() });
    press(t, &.{.{ .insert = "s" }});
    try std.testing.expect(t.hasText("Ctrl+2"));
    try std.testing.expect(!t.containsText("⌘"));
    try std.testing.expect(t.shortcut(.{ .key = ',', .ctrl = true }));
    t.settle(1);
    try std.testing.expect(s.screen == .settings);
    try std.testing.expect(t.hasText("Alt Space"));
    try std.testing.expect(t.hasText("Sync Across Computers"));
}

test "a welcome whose key is set elsewhere skips the key step, in two steps" {
    const gpa = std.testing.allocator;
    var o: onboard.Onboard = .{ .skip_key = true };
    o.start(.cmd_space);
    try std.testing.expectEqual(onboard.Step.try_it, o.step);
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const t = &rig.t;
    try rig.apps(&.{"Safari"});
    rig.s.open(.{ .welcome = &o });
    try rig.mount(.{ .screen = .none, .height = 480 });
    try std.testing.expect(!t.containsText("Open it with"));
    try std.testing.expect(t.containsText("1 of 2"));
    o.pressed(true);
    o.pressed(false);
    t.settle(2);
    try std.testing.expect(t.hasText("You're set."));
    try std.testing.expect(t.containsText("2 of 2"));
    // Showing it again starts at the same step.
    o.start(.cmd_space);
    try std.testing.expectEqual(onboard.Step.try_it, o.step);
}

test "Ctrl+J and Ctrl+K move down and up, and the field never sees them" {
    const gpa = std.testing.allocator;
    var probe: Probe = .{};
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{ "Safari", "System Settings", "Notes" });
    try rig.mount(.{ .host = probe.host(), .height = 480 });
    press(t, &.{.{ .insert = "s" }});
    try std.testing.expect(t.shortcut(.{ .key = 'j', .ctrl = true }));
    try std.testing.expectEqual(@as(?usize, 1), s.selection());
    try std.testing.expect(t.shortcut(.{ .key = 'k', .ctrl = true }));
    try std.testing.expectEqual(@as(?usize, 0), s.selection());
    // Up from the first wraps round to the last.
    try std.testing.expect(t.shortcut(.{ .key = 'k', .ctrl = true }));
    try std.testing.expectEqual(@as(?usize, s.rows().len - 1), s.selection());
    try std.testing.expectEqualStrings("s", s.query.text());
}

test "a hide and a show close Settings; away longer than pop_after, the root" {
    const gpa = std.testing.allocator;
    var prefs: Prefs = .{};
    prefs.init();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.apps(&.{"Notes"});
    prefs.nl = s;
    try rig.mount(.{ .host = prefs.host() });
    s.away.pop_after = 90;
    press(t, &.{.{ .insert = "notes" }});
    try support.clickButton(t, "Settings");
    t.settle(1);
    try std.testing.expect(s.screen == .settings);
    s.hid(1000);
    try std.testing.expect(!s.show(1090));
    t.settle(1);
    try std.testing.expectEqualStrings("notes", s.query.text());
    try std.testing.expect(s.screen == .rows);
    // Longer: no query, the first row, no other screen.
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    try std.testing.expectEqual(@as(?usize, 2), s.selection());
    try support.clickButton(t, "Settings");
    t.settle(1);
    s.hid(1000);
    try std.testing.expect(s.show(1091));
    t.settle(1);
    try std.testing.expectEqualStrings("", s.query.text());
    try std.testing.expectEqual(@as(?usize, 0), s.selection());
    try std.testing.expect(s.screen == .rows);
}
