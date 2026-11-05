//! Clipboard History through the Tester: the row that opens it, the screen
//! over an in-memory store with a fake watcher behind Return and ⌘↩, and the
//! Settings rows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const clipboard = @import("clipboard.zig");
const clipboard_view = @import("clipboard_view.zig");
const settings_view = @import("settings_view.zig");
const account = @import("account.zig");
const tests = @import("tests.zig");
const testing = std.testing;
const S = ui.Shortcut;

/// What the app does for the screen, recorded: the store is real, the
/// watcher and the OS are not.
const Fake = struct {
    store: clipboard.Store = undefined,
    why: ?[]const u8 = null,
    result: clipboard.PasteResult = .pasted,
    pasted: ?u64 = null,
    copied: ?u64 = null,
    hidden: bool = false,
    ch: clipboard_view.Host = undefined,

    fn init(f: *Fake) void {
        f.store = .init(testing.allocator, testing.io, null, .{});
        f.ch = .{ .ctx = f, .store = &f.store, .status = status, .paste = paste, .copy = copy };
    }

    fn deinit(f: *Fake) void {
        f.store.deinit();
    }

    fn host(f: *Fake) view.Host {
        return .{ .ctx = f, .open = open, .hide = hide, .clipboard = &f.ch };
    }

    fn open(_: *anyopaque, _: []const u8) void {}

    fn hide(ctx: *anyopaque) void {
        @as(*Fake, @ptrCast(@alignCast(ctx))).hidden = true;
    }

    fn status(ctx: *anyopaque) ?[]const u8 {
        return @as(*Fake, @ptrCast(@alignCast(ctx))).why;
    }

    /// Like the Mac's: a paste hides the panel first, a copy-only result leaves it.
    fn paste(ctx: *anyopaque, hash: u64) clipboard.PasteResult {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.pasted = hash;
        if (f.result == .pasted) f.hidden = true;
        return f.result;
    }

    fn copy(ctx: *anyopaque, hash: u64) bool {
        @as(*Fake, @ptrCast(@alignCast(ctx))).copied = hash;
        return true;
    }

    fn fill(f: *Fake) void {
        const now = account.now();
        _ = f.store.add(.{ .kind = .text, .text = "old note", .source = "com.apple.Notes" }, now - 7200);
        _ = f.store.add(.{ .kind = .file, .text = "/Users/me/report.pdf", .source = "com.apple.finder" }, now - 3600);
        _ = f.store.add(.{ .kind = .image, .png = "png", .width = 800, .height = 600, .source = "com.apple.Preview" }, now - 600);
        _ = f.store.add(.{ .kind = .text, .text = "hello world\nsecond line\nthird line", .source = "com.apple.Safari" }, now - 300);
    }
};

fn rig(gpa: std.mem.Allocator, ix: *Index, f: *Fake, s: *view.Nanolight, t: *ui.Tester) !void {
    _ = ix;
    s.host = f.host();
    s.reveal();
    try t.init(gpa, .init(s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    t.settle(1);
}

fn opened(t: *ui.Tester, s: *view.Nanolight) void {
    tests.press(t, &.{.{ .insert = "clip" }});
    tests.press(t, &.{.{ .command = .insert_newline }});
    std.debug.assert(s.clip_ui.open);
    t.settle(1);
}

test "the row appears for clip and clipboard, only with a host, and opens the screen" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    tests.press(&t, &.{.{ .insert = "clip" }});
    try testing.expect(t.hasText("Clipboard History"));
    try testing.expectEqual(@import("results.zig").Kind.clipboard, s.res.rows[0].kind);
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "clipboard" } });
    try testing.expectEqual(@import("results.zig").Kind.clipboard, s.res.rows[0].kind);
    // A letter or two of it is not enough, and neither is its middle.
    for ([_][]const u8{ "cl", "ho", "xyz" }) |q| {
        tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = q } });
        for (s.res.slice()) |r| try testing.expect(r.kind != .clipboard);
    }
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "clip" } });
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try testing.expect(s.clip_ui.open and !f.hidden);
    try testing.expect(t.hasText("Search Clipboard History…"));
    // Without a host for it the row is not listed.
    s.clip_ui.hide();
    s.host.?.clipboard = null;
    s.reveal();
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "clip" } });
    for (s.res.slice()) |r| try testing.expect(r.kind != .clipboard);
}

test "the screen lists newest first with type, app and time, and the selection's detail" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
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
    // ^J and ^K move too.
    try testing.expect(t.shortcut(.{ .key = 'j', .ctrl = true }));
    try testing.expectEqual(@as(usize, 2), s.clip_ui.sel);
    try testing.expect(t.shortcut(.{ .key = 'k', .ctrl = true }));
    try testing.expectEqual(@as(usize, 1), s.clip_ui.sel);
    // The screen fits the panel.
    try testing.expect(s.height() <= view.max_height);
}

test "typing searches text, file names and apps; Esc closes the screen and the panel" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    tests.press(&t, &.{.{ .insert = "report" }});
    try testing.expectEqual(@as(usize, 1), s.clip_ui.n);
    try testing.expect(t.hasText("report.pdf") and !t.hasText("hello world"));
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "preview" } });
    try testing.expectEqual(@as(usize, 1), s.clip_ui.n);
    try testing.expect(t.hasText("Image 800 × 600"));
    tests.press(&t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = "nothing like it" } });
    try testing.expect(t.hasText("No matches."));
    // Esc leaves the screen and hides the panel, the query cleared for the rows.
    try testing.expect(t.shortcut(.{ .key = S.escape }));
    try testing.expect(!s.clip_ui.open and f.hidden);
    try testing.expectEqualStrings("", s.query.text());
    t.settle(1);
    try testing.expect(t.hasText("Search apps, do math, search the web…"));
}

test "Return pastes the selection, ⌘↩ copies it, ⌘⌫ deletes it" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    const newest = f.store.entries.items[0].hash;
    const second = f.store.entries.items[1].hash;
    // ⌘↩: written, not pasted, the panel stays.
    try testing.expect(t.shortcut(.{ .key = S.enter, .cmd = true }));
    try testing.expectEqual(newest, f.copied.?);
    try testing.expect(f.pasted == null and !f.hidden);
    try testing.expect(t.hasText("Copied"));
    // Return on the second pastes it, and the panel goes.
    _ = t.shortcut(.{ .key = S.down });
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try testing.expectEqual(second, f.pasted.?);
    try testing.expect(f.hidden);
    // ⌘⌫ deletes the selected entry.
    try testing.expectEqual(@as(usize, 4), f.store.entries.items.len);
    try testing.expect(t.shortcut(.{ .key = 0x7f, .cmd = true }));
    try testing.expectEqual(@as(usize, 3), f.store.entries.items.len);
    try testing.expect(f.store.get(second) == null);
    try testing.expectEqual(@as(usize, 3), s.clip_ui.n);
    t.settle(1);
    try testing.expect(t.hasText("Deleted"));
    try testing.expect(!t.hasText("Image 800 × 600"));
}

test "a paste that could only copy says why in the footer, and the panel stays" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    for ([_]clipboard.PasteResult{ .copied_no_permission, .copied_unsupported, .failed }) |r| {
        f.result = r;
        f.hidden = false;
        tests.press(&t, &.{.{ .command = .insert_newline }});
        try testing.expect(!f.hidden and s.clip_ui.open);
        try testing.expectEqualStrings(clipboard.pasteNote(r).?, s.clip_ui.note);
    }
    try testing.expect(t.hasText(clipboard.pasteNote(.failed).?));
    // With paste_plain_text off, Return is a copy.
    f.ch.copy_only = true;
    f.copied = null;
    f.pasted = null;
    tests.press(&t, &.{.{ .command = .insert_newline }});
    try testing.expect(f.copied != null and f.pasted == null);
}

test "an empty history says why it is empty, and the panel reopens at the root" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    try testing.expect(t.hasText("Nothing copied yet."));
    f.why = "Clipboard history is not available on Linux yet.";
    t.settle(1);
    try testing.expect(t.hasText("Clipboard history is not available on Linux yet."));
    // Return, delete and copy with nothing selected do nothing.
    tests.press(&t, &.{.{ .command = .insert_newline }});
    _ = t.shortcut(.{ .key = S.enter, .cmd = true });
    _ = t.shortcut(.{ .key = 0x7f, .cmd = true });
    try testing.expect(f.pasted == null and f.copied == null);
    // Away longer than pop_to_root_seconds: the screen is popped.
    s.hid(1000);
    try testing.expect(s.popDue(1000 + s.pop_after + 1));
    s.toRoot();
    try testing.expect(!s.clip_ui.open);
}

test "the screen survives a hide inside pop_to_root_seconds, search text included" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    s.query.set("acme");
    s.hid(1000);
    try testing.expect(!s.popDue(1000 + s.pop_after));
    s.reveal();
    try testing.expect(s.clip_ui.open);
    // Other keys delete too: Ctrl+Backspace on GTK, Ctrl+D on Windows.
    const before = f.store.entries.items.len;
    s.query.clear();
    t.settle(1);
    try testing.expect(t.shortcut(.{ .key = 0x08, .cmd = true }));
    try testing.expect(t.shortcut(.{ .key = 'd', .cmd = true }));
    try testing.expectEqual(before - 2, f.store.entries.items.len);
}

test "an entry added while the screen is open appears at once" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var f: Fake = .{};
    f.init();
    defer f.deinit();
    f.fill();
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    var t: ui.Tester = undefined;
    try rig(gpa, &ix, &f, &s, &t);
    defer t.deinit();
    opened(&t, &s);
    _ = t.shortcut(.{ .key = S.down });
    const image = f.store.entries.items[1].hash;
    _ = f.store.add(.{ .kind = .text, .text = "fresh copy", .source = "org.mozilla.firefox" }, account.now());
    t.settle(1);
    try testing.expect(t.hasText("fresh copy"));
    try testing.expect(t.hasText("Text · firefox · just now"));
    // The selection stayed on the image, which moved down a row.
    try testing.expectEqual(@as(usize, 2), s.clip_ui.sel);
    try testing.expectEqual(image, f.store.entries.items[s.clip_ui.found[s.clip_ui.sel]].hash);
}

test "Settings: the clipboard rows toggle recording and clear the history" {
    const gpa = testing.allocator;
    var ix: Index = .init(gpa);
    defer ix.deinit();
    var prefs: tests.Prefs = .{};
    prefs.init();
    prefs.clip_on = true;
    var s: view.Nanolight = .{ .index = &ix };
    defer s.query.deinit();
    s.host = prefs.host();
    s.openSettings();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, view.Nanolight.view), .{ .width = view.width, .height = view.max_height, .dark = true });
    defer t.deinit();
    t.settle(1);
    try testing.expect(t.hasText("Record Copied Items"));
    try t.clickText("Record Copied Items");
    t.settle(1);
    try testing.expectEqual(false, prefs.clip_on.?);
    try t.clickText("Record Copied Items");
    t.settle(1);
    try testing.expectEqual(true, prefs.clip_on.?);
    try t.clickText("Clear History");
    t.settle(1);
    try testing.expectEqual(@as(u8, 1), prefs.clip_cleared);
    try testing.expect(t.hasText("Clipboard History Cleared"));
    // Everything fits in the window.
    const quit = t.findText("Quit Nanolight").?;
    try testing.expect(quit.y + quit.h <= s.settings_ui.tall());
    try testing.expect(s.settings_ui.tall() <= view.max_height);
}

test "Settings: no clipboard rows where the system has no history, and a shorter screen" {
    const gpa = testing.allocator;
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
    try testing.expect(!t.hasText("Record Copied Items") and !t.hasText("Clear History"));
    try testing.expect(s.settings_ui.tall() < settings_view.height);
    const quit = t.findText("Quit Nanolight").?;
    try testing.expect(quit.y + quit.h <= s.settings_ui.tall());
}
