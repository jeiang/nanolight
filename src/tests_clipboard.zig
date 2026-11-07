//! Clipboard History through the Tester: the row that opens it, the screen
//! over an in-memory store with a fake watcher behind Return and ⌘↩, and the
//! Settings rows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view = @import("view.zig");
const chrome = @import("chrome.zig");
const clipboard = @import("clipboard.zig");
const PasteResult = @import("clipboard_types.zig").PasteResult;
const clipboard_view = @import("clipboard_view.zig");
const settings_view = @import("settings_view.zig");
const clock = @import("clock.zig");
const support = @import("test_support.zig");
const Rig = support.Rig;
const testing = std.testing;
const S = ui.Shortcut;

/// What the app does for the screen, recorded: the store is real, the
/// watcher and the OS are not.
const Fake = struct {
    store: clipboard.Store = undefined,
    why: ?[]const u8 = null,
    result: PasteResult = .pasted,
    pasted: ?u64 = null,
    copied: ?u64 = null,
    hidden: bool = false,
    ch: clipboard_view.Host = undefined,

    fn init(f: *Fake) void {
        f.store = .init(testing.allocator, testing.io, null, .{});
        f.ch = .{
            .ctx = f,
            .store = &f.store,
            .copy_only = false,
            .status = status,
            .paste = paste,
            .copy = copy,
        };
    }

    fn deinit(f: *Fake) void {
        f.store.deinit();
    }

    fn host(f: *Fake) view.Host {
        return .{ .ctx = f, .open = open, .hide = hide, .clipboard = &f.ch };
    }

    fn open(_: *anyopaque, _: @import("results.zig").Target) void {}

    fn hide(ctx: *anyopaque) void {
        @as(*Fake, @ptrCast(@alignCast(ctx))).hidden = true;
    }

    fn status(ctx: *anyopaque) ?[]const u8 {
        return @as(*Fake, @ptrCast(@alignCast(ctx))).why;
    }

    /// Like the Mac's: a paste hides the panel first, a copy-only result leaves it.
    fn paste(ctx: *anyopaque, hash: u64) PasteResult {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.pasted = hash;
        if (f.result == .pasted) f.hidden = true;
        return f.result;
    }

    fn copy(ctx: *anyopaque, hash: u64) PasteResult {
        @as(*Fake, @ptrCast(@alignCast(ctx))).copied = hash;
        return .copied;
    }

    fn fill(f: *Fake) void {
        const now = clock.now();
        _ = f.store.add(
            .{ .kind = .text, .text = "old note", .source = "com.apple.Notes" },
            now - 7200,
        );
        _ = f.store.add(
            .{ .kind = .file, .text = "/Users/me/report.pdf", .source = "com.apple.finder" },
            now - 3600,
        );
        _ = f.store.add(
            .{
                .kind = .image,
                .png = "png",
                .width = 800,
                .height = 600,
                .source = "com.apple.Preview",
            },
            now - 600,
        );
        _ = f.store.add(
            .{
                .kind = .text,
                .text = "hello world\nsecond line\nthird line",
                .source = "com.apple.Safari",
            },
            now - 300,
        );
    }
};

fn opened(t: *ui.Tester, s: *view.Nanolight) void {
    support.press(t, &.{.{ .insert = "clip" }});
    support.press(t, &.{.{ .command = .insert_newline }});
    std.debug.assert(s.screen == .clipboard);
    t.settle(1);
}

/// Whether the footer shows `note`: whole, or cut to the panel's width.
/// How much a cut keeps is the fonts': with none installed (a Nix build's
/// sandbox), nothing but the "…".
fn showsNote(t: *ui.Tester, note: []const u8) bool {
    const cut = "…";
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| {
            if (std.mem.eql(u8, tx.str, note)) return true;
            if (!std.mem.endsWith(u8, tx.str, cut)) continue;
            const kept = std.mem.trimEnd(u8, tx.str[0 .. tx.str.len - cut.len], " ");
            if (std.mem.startsWith(u8, note, kept)) return true;
        },
        else => {},
    };
    return false;
}

test "the row appears for clip and clipboard, only with a host, and opens the screen" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    support.press(t, &.{.{ .insert = "clip" }});
    try testing.expect(t.hasText("Clipboard History"));
    try testing.expectEqual(@import("results.zig").Kind.clipboard, s.res.rows[0].kind);
    support.retype(t, "clipboard");
    try testing.expectEqual(@import("results.zig").Kind.clipboard, s.res.rows[0].kind);
    // A letter or two of it is not enough, and neither is its middle.
    for ([_][]const u8{ "cl", "ho", "xyz" }) |q| {
        support.retype(t, q);
        for (s.res.slice()) |r| try testing.expect(r.kind != .clipboard);
    }
    support.retype(t, "clip");
    support.press(t, &.{.{ .command = .insert_newline }});
    try testing.expect(s.screen == .clipboard and !f.hidden);
    try testing.expect(t.hasText("Search Clipboard History…"));
    // Without a host for it the row is not listed.
    s.leave(.closed);
    s.host.?.clipboard = null;
    _ = s.show(0);
    support.retype(t, "clip");
    for (s.res.slice()) |r| try testing.expect(r.kind != .clipboard);
}

test "the screen lists newest first with type, app and time, and the selection's detail" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    try testing.expect(t.hasText("hello world"));
    try testing.expect(t.hasText("Text · Safari · 5 min ago"));
    try testing.expect(t.hasText("Image 800 × 600"));
    try testing.expect(t.hasText("Image · Preview · 10 min ago"));
    try testing.expect(t.hasText("File · finder · 1 h ago"));
    try testing.expect(t.hasText("report.pdf"));
    // The newest is selected: its first lines are the detail.
    try testing.expect(t.hasText("second line"));
    try testing.expect(t.hasText("Copied 1 time · last 5 min ago"));
    const first = t.findText("hello world").?;
    const image = t.findText("Image 800 × 600").?;
    try testing.expect(first.y < image.y);
    // Down to the image: its size is the detail.
    try testing.expect(t.shortcut(.{ .key = S.down }));
    try testing.expect(t.hasText("Image, 800 × 600 pixels, 3 bytes"));
    // ^J and ^K move too: ⌘↩ copies the one they land on.
    try testing.expect(t.shortcut(.{ .key = 'j', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = S.enter, .cmd = true }));
    try testing.expectEqual(f.store.at(2).hash, f.copied.?);
    try testing.expect(t.shortcut(.{ .key = 'k', .ctrl = true }));
    try testing.expect(t.shortcut(.{ .key = S.enter, .cmd = true }));
    try testing.expectEqual(f.store.at(1).hash, f.copied.?);
    // The screen fits the panel.
    try testing.expect(s.height() <= chrome.max_height);
}

test "typing searches text, file names and apps; Esc closes the screen and the panel" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    support.press(t, &.{.{ .insert = "report" }});
    try testing.expect(t.hasText("report.pdf"));
    try testing.expect(!t.hasText("hello world") and !t.hasText("Image 800 × 600"));
    support.retype(t, "preview");
    try testing.expect(t.hasText("Image 800 × 600"));
    try testing.expect(!t.hasText("hello world") and !t.hasText("report.pdf"));
    support.retype(t, "nothing like it");
    try testing.expect(t.hasText("No matches."));
    // Esc leaves the screen and hides the panel, the query cleared for the rows.
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(s.screen != .clipboard and f.hidden);
    try testing.expectEqualStrings("", s.query.text());
    t.settle(1);
    try testing.expect(t.hasText("Search apps, do math, search the web…"));
}

test "Return pastes the selection, ⌘↩ copies it, ⌘⌫ deletes it" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    const newest = f.store.at(0).hash;
    const second = f.store.at(1).hash;
    // ⌘↩: written, not pasted, the panel stays.
    try testing.expect(t.shortcut(.{ .key = S.enter, .cmd = true }));
    try testing.expectEqual(newest, f.copied.?);
    try testing.expect(f.pasted == null and !f.hidden);
    try testing.expect(t.hasText("Copied"));
    // Return on the second pastes it, and the panel goes.
    _ = t.shortcut(.{ .key = S.down });
    support.press(t, &.{.{ .command = .insert_newline }});
    try testing.expectEqual(second, f.pasted.?);
    try testing.expect(f.hidden);
    // ⌘⌫ deletes the selected entry.
    try testing.expectEqual(@as(usize, 4), f.store.len());
    try testing.expect(t.shortcut(.{ .key = 0x7f, .cmd = true }));
    try testing.expectEqual(@as(usize, 3), f.store.len());
    try testing.expect(f.store.get(second) == null);
    t.settle(1);
    try testing.expect(t.hasText("Deleted"));
    try testing.expect(!t.hasText("Image 800 × 600"));
}

test "a paste that could only copy says why in the footer, and the panel stays" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    for ([_]struct { PasteResult, []const u8 }{
        .{
            .copied_no_permission,
            "Copied. Allow Nanolight in Privacy & Security > Accessibility to paste.",
        },
        .{ .copied_unsupported, "Copied. Pasting is not supported on this system yet." },
        .{ .failed, "Could not write the clipboard." },
    }) |case| {
        f.result = case[0];
        f.hidden = false;
        support.press(t, &.{.{ .command = .insert_newline }});
        try testing.expect(!f.hidden and s.screen == .clipboard);
        // How much of it fits is the fonts', so its words are checked here.
        try testing.expectEqualStrings(case[1], s.clip_ui.note);
        try testing.expect(showsNote(t, case[1]));
    }
    // Copy-only (`paste_plain_text` off): Return is a copy.
    f.ch.copy_only = true;
    f.copied = null;
    f.pasted = null;
    support.press(t, &.{.{ .command = .insert_newline }});
    try testing.expect(f.copied != null and f.pasted == null);
}

test "an empty history says why it is empty, and the panel reopens at the root" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    try testing.expect(t.hasText("Nothing copied yet."));
    f.why = "Clipboard history is not available on Linux yet.";
    t.settle(1);
    try testing.expect(t.hasText("Clipboard history is not available on Linux yet."));
    // Return, delete and copy with nothing selected do nothing.
    support.press(t, &.{.{ .command = .insert_newline }});
    _ = t.shortcut(.{ .key = S.enter, .cmd = true });
    _ = t.shortcut(.{ .key = 0x7f, .cmd = true });
    try testing.expect(f.pasted == null and f.copied == null);
    // Away longer than pop_to_root_seconds: the screen is popped.
    s.hid(1000);
    try testing.expect(s.show(1000 + s.away.pop_after + 1));
    try testing.expect(s.screen != .clipboard);
}

test "the screen survives a hide inside pop_to_root_seconds, search text included" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    support.press(t, &.{.{ .insert = "acme" }});
    s.hid(1000);
    try testing.expect(!s.show(1000 + s.away.pop_after));
    try testing.expect(s.screen == .clipboard);
    try testing.expectEqualStrings("acme", s.query.text());
    // Other keys delete too: Ctrl+Backspace on GTK, Ctrl+D on Windows.
    const before = f.store.len();
    support.retype(t, "");
    try testing.expect(t.shortcut(.{ .key = 0x08, .cmd = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expectEqual(before - 2, f.store.len());
}

test "an entry added while the screen is open appears at once" {
    const gpa = testing.allocator;
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = f.host() });
    opened(t, s);
    _ = t.shortcut(.{ .key = S.down });
    const image = f.store.at(1).hash;
    _ = f.store.add(
        .{ .kind = .text, .text = "fresh copy", .source = "org.mozilla.firefox" },
        clock.now(),
    );
    t.settle(1);
    try testing.expect(t.hasText("fresh copy"));
    try testing.expect(t.hasText("Text · firefox · just now"));
    // The selection stayed on the image, which moved down a row.
    try testing.expect(t.shortcut(.{ .key = S.enter, .cmd = true }));
    try testing.expectEqual(image, f.copied.?);
    try testing.expect(t.hasText("Image, 800 × 600 pixels, 3 bytes"));
}

test "Settings: the clipboard rows toggle recording and clear the history" {
    const gpa = testing.allocator;
    var prefs: support.Prefs = .{};
    prefs.init();
    prefs.clip_on = true;
    var f: Fake = undefined;
    f.init();
    defer f.deinit();
    var host = prefs.host();
    host.clipboard = &f.ch;
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = host, .screen = .settings });
    try testing.expect(t.hasText("Record Copied Items"));
    // Its section is as tall as the height it adds says. The heading's line
    // is measured in the Mac's system font; elsewhere it is whichever font
    // is installed, and only the rest of the sum is known.
    const mac = @import("builtin").os.tag == .macos;
    const head = t.findText("Clipboard History").?;
    const next = t.findText(if (mac) "Sync Across Macs" else "Sync Across Computers").?;
    if (mac) try testing.expectEqual(settings_view.heading_h, head.h);
    try testing.expectEqual(
        settings_view.clip_height - settings_view.heading_h + head.h,
        next.y - head.y,
    );
    try t.clickText("Record Copied Items");
    t.settle(1);
    try testing.expectEqual(false, prefs.clip_on);
    try t.clickText("Record Copied Items");
    t.settle(1);
    try testing.expectEqual(true, prefs.clip_on);
    try t.clickText("Clear History");
    t.settle(1);
    try testing.expectEqual(@as(u8, 1), prefs.clip_cleared);
    try testing.expect(t.hasText("Clipboard History Cleared"));
    // A clear that may have left something on disk says so.
    prefs.clip_clear_ok = false;
    try t.clickText("Clipboard History Cleared");
    t.settle(1);
    try testing.expectEqual(@as(u8, 2), prefs.clip_cleared);
    try testing.expect(t.hasText("Could Not Clear History"));
    // Everything fits in the window.
    const quit = t.findText("Quit Nanolight").?;
    try testing.expect(quit.y + quit.h <= s.height());
    try testing.expect(s.height() <= chrome.max_height);
}

test "Settings: no clipboard rows where the system has no history, and a shorter screen" {
    const gpa = testing.allocator;
    var prefs: support.Prefs = .{};
    prefs.init();
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    const t = &rig.t;
    try rig.mount(.{ .host = prefs.host(), .screen = .settings });
    try testing.expect(!t.hasText("Record Copied Items") and !t.hasText("Clear History"));
    try testing.expect(s.height() < settings_view.height);
    const quit = t.findText("Quit Nanolight").?;
    try testing.expect(quit.y + quit.h <= s.height());
}
