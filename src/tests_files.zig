//! File search regression coverage.
const std = @import("std");
const view = @import("view.zig");
const pipeline = @import("pipeline.zig");
const Nanolight = @import("nanolight.zig").Nanolight;
const Host = @import("host.zig").Host;
const Target = @import("host.zig").Target;
const chrome = @import("chrome.zig");
const Rig = @import("test_support.zig").Rig;
const suggest = @import("suggest.zig");
const results = @import("results.zig");

test "files share the local results' head and fit the original window" {
    const gpa = std.testing.allocator;
    var rig: Rig = undefined;
    rig.init(gpa);
    defer rig.deinit();
    const s = &rig.s;
    s.turn(.files, true);
    try rig.apps(&.{ "Safari", "Mail", "Maps", "Calendar", "Calculator", "System Settings Alpha" });
    // "settings" keeps Nanolight's Settings first; "a" matches all six apps.
    for ([_][]const u8{ "settings", "a" }) |q| {
        s.query.set(q);
        pipeline.rebuild(s);
        var four: suggest.List = .{};
        for (0..4) |i| {
            var buf: [64]u8 = undefined;
            four.push(try std.fmt.bufPrint(&buf, "{s}{d}", .{ q, i }));
        }
        for ([_]bool{ false, true }) |exact| {
            var found: @import("files.zig").List = .{ .allocator = gpa, .exact = exact };
            defer found.deinit();
            // A path typed out that exists scores above any name (files.complete).
            if (exact) found.add("/tmp/settings", true, .{ .score = 2000 });
            for (0..5) |i| {
                var path: [64]u8 = undefined;
                found.add(
                    try std.fmt.bufPrint(&path, "/tmp/settings{d}", .{i}),
                    false,
                    .{ .score = 0 },
                );
            }
            pipeline.filesAnswered(s, q, &found);
            pipeline.answered(s, q, &four);
            try std.testing.expect(view.height(s) <= chrome.max_height);
            const settings = std.mem.eql(u8, q, "settings");
            var apps: usize = 0;
            var file_rows: usize = 0;
            var heads: usize = 0;
            for (s.res.slice(), 0..) |row, i| {
                if (row.kind == .app) apps += 1;
                if (row.kind == .file) file_rows += 1;
                if (s.res.section(i) != null) heads += 1;
            }
            try std.testing.expectEqual(@as(usize, if (settings) 1 else 6), apps);
            try std.testing.expect(file_rows > 0);
            // Results, Search and Quicklinks: files bring no head of their own.
            try std.testing.expectEqual(@as(usize, 3), heads);
            if (exact) try std.testing.expectEqual(
                results.Kind.file,
                s.res.slice()[@intFromBool(settings)].kind,
            );
            // Every quicklink still follows, X's last, and one search for what was typed.
            const last = s.res.slice()[s.res.slice().len - 1];
            try std.testing.expectEqual(results.Kind.quicklink, last.kind);
            try std.testing.expectEqualStrings("X", s.links()[last.item].name);
            var google: usize = 0;
            for (s.res.slice()) |row| {
                const named = row.kind == .quicklink and
                    std.mem.eql(u8, s.links()[row.item].name, "Google");
                if (named) google += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), google);
        }
    }
}

test "file tiers merge duplicates and keep exact names against many subsequences" {
    const files = @import("files.zig");
    const search = @import("search.zig");
    var found: files.List = .{};
    // The first tier's exact name must survive a later, much larger tier.
    const exact = "/files/README";
    found.add(exact, false, search.score("readme", "README").?);
    var buf: [128]u8 = undefined;
    for (0..600) |i| {
        const path = try std.fmt.bufPrint(&buf, "/files/r-e-a-d-m-e-{d}", .{i});
        found.add(path, false, search.score("readme", std.fs.path.basename(path)).?);
    }
    const prefix = "/files/README.md";
    found.add(prefix, false, search.score("readme", "README.md").?);
    // Both prefix and subsequence Spotlight queries can return earlier paths.
    found.add(exact, false, search.score("readme", "README").?);
    found.add(prefix, false, search.score("readme", "README.md").?);
    try std.testing.expectEqual(@as(usize, files.max_rows), found.n);
    try std.testing.expectEqualStrings(exact, found.entries[0].path());
    try std.testing.expectEqualStrings(prefix, found.entries[1].path());
    for (found.entries[0..found.n], 0..) |*entry, i| {
        for (found.entries[i + 1 .. found.n]) |*other| {
            try std.testing.expect(!std.mem.eql(u8, entry.path(), other.path()));
        }
    }
    // A high-ranked entry also replaces an already-full weak tier.
    var late: files.List = .{};
    for (0..600) |i| {
        const path = try std.fmt.bufPrint(&buf, "/files/r-e-a-d-m-e-{d}", .{i});
        late.add(path, false, search.score("readme", std.fs.path.basename(path)).?);
    }
    try std.testing.expectEqual(@as(usize, files.max_rows), late.n);
    late.add(exact, false, search.score("readme", "README").?);
    try std.testing.expectEqualStrings(exact, late.entries[0].path());
}

test "Spotlight predicates prioritize literal names before subsequences" {
    const spotlight = @import("spotlight.zig");
    var buf: [spotlight.predicate_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"readme\"cd",
        spotlight.predicate(&buf, "readme", .exact),
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"readme*\"cd",
        spotlight.predicate(&buf, "readme", .prefix),
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"* readme*\"cd",
        spotlight.predicate(&buf, "readme", .word),
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"*r*e*a*d*m*e*\"cd",
        spotlight.predicate(&buf, "readme", .subsequence),
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"a\\*\\?\\\"\\\\*\"cd",
        spotlight.predicate(&buf, "a*?\"\\", .prefix),
    );
    // The longest query, every byte escaped, fits; invalid UTF-8 isn't asked.
    const longest: [256]u8 = @splat('*');
    try std.testing.expect(spotlight.eligible(&longest));
    try std.testing.expect(!spotlight.eligible(longest ++ "*"));
    _ = spotlight.predicate(&buf, &longest, .subsequence);
    try std.testing.expect(!spotlight.eligible("caf\xc3"));
}

test "name search excludes the home Library subtree by default" {
    const paths = @import("paths.zig");
    const spotlight = @import("spotlight.zig");
    const home = paths.home();
    if (home.len == 0) return error.SkipZigTest;
    var buf: [@import("files.zig").max_path]u8 = undefined;
    for ([_][]const u8{
        "Library",
        "Library/Application Support/App/readme",
        "Library/Logs/readme",
        "Library/WebKit/readme",
        "Library/HTTPStorages/readme",
        "Library/Application Scripts/readme",
        "Library/Caches/readme",
    }) |part| {
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, part });
        try std.testing.expect(spotlight.excluded(path, ""));
    }
    const lookalike = try std.fmt.bufPrint(&buf, "{s}/LibraryWork/readme", .{home});
    try std.testing.expect(!spotlight.excluded(lookalike, ""));
}

test "cached path rows are filtered without directory IO" {
    const files = @import("files.zig");
    var found: files.List = .{};
    found.add("/folder", true, .{ .score = 2000 });
    found.add("/folder/README.md", false, .{ .score = 900 });
    found.add("/folder/Report", true, .{ .score = 850 });
    found.add("/elsewhere/README.md", false, .{ .score = 800 });
    found.add("/folder/.hidden", false, .{ .score = 700 });
    found.filter("/folder/");
    try std.testing.expect(found.exact);
    try std.testing.expectEqual(@as(usize, 3), found.n);
    try std.testing.expectEqualStrings("/folder", found.entries[0].path());
    found.filter("/folder/Rea");
    try std.testing.expect(!found.exact);
    try std.testing.expectEqual(@as(usize, 1), found.n);
    try std.testing.expectEqualStrings("/folder/README.md", found.entries[0].path());
    found.filter("/other/");
    try std.testing.expectEqual(@as(usize, 0), found.n);
}

test "apps, panes, files and quicklinks share the window budget" {
    // Panes are the Mac's alone; with them the rows fill the budget exactly.
    const mac = @import("builtin").os.tag == .macos;
    const t = std.testing;
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.turn(.files, true);
    for (0..results.max_apps) |i| {
        var name: [64]u8 = undefined;
        try rig.apps(&.{try std.fmt.bufPrint(&name, "Login {d}", .{i})});
    }
    s.query.set("login");
    pipeline.rebuild(s);
    var found: @import("files.zig").List = .{ .allocator = t.allocator };
    defer found.deinit();
    // A file named just what was typed outranks the apps' names; the rest,
    // matching worse, give way to the apps and the pane.
    found.add("/tmp/login", false, @import("search.zig").score("login", "login").?);
    for (1..5) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/login{d}", .{i}), false, .{ .score = 1 });
    }
    pipeline.filesAnswered(s, "login", &found);
    var web: suggest.List = .{};
    for ([_][]const u8{
        "login mac",
        "login windows",
        "login iphone",
        "login help",
    }) |q| web.push(q);
    pipeline.answered(s, "login", &web);
    var heads: usize = 0;
    var apps = false;
    var panes = false;
    var files = false;
    var google = false;
    var links: usize = 0;
    for (s.res.slice(), 0..) |row, i| {
        if (s.res.section(i) != null) heads += 1;
        switch (row.kind) {
            .app => apps = true,
            .pane => panes = true,
            .file => files = true,
            .quicklink => {
                google = google or row.item == 0;
                links += 1;
            },
            else => {},
        }
    }
    try t.expect(apps and files and google);
    try t.expectEqual(mac, panes);
    try t.expectEqual(results.Kind.file, s.res.slice()[0].kind);
    try t.expectEqual(results.max_quicklink_rows, links);
    try t.expectEqual(@as(usize, 3), heads);
    if (mac) try t.expectEqual(results.max_rows, s.res.slice().len);
    try t.expect(view.height(s) <= chrome.max_height);
}

test "file icon allocations survive filtering, eviction and owning replacement" {
    const t = std.testing;
    const files = @import("files.zig");
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    for (0..files.max_rows) |i| {
        var path: [64]u8 = undefined;
        found.add(
            try std.fmt.bufPrint(&path, "/tmp/keep{d}", .{i}),
            false,
            .{ .score = @intCast(100 - i) },
        );
        found.entries[i].png = try t.allocator.dupe(u8, "icon");
    }
    found.add("/tmp/keep-new", false, .{ .score = 200 });
    found.entries[0].png = try t.allocator.dupe(u8, "new icon");
    found.filter("/tmp/keep0");
    try t.expectEqual(@as(usize, 1), found.n);
    try t.expectEqualStrings("icon", found.entries[0].png);
    var destination: files.List = .{ .allocator = t.allocator };
    defer destination.deinit();
    destination.add("/tmp/old", false, .{ .score = 1 });
    destination.entries[0].png = try t.allocator.dupe(u8, "old icon");
    destination.replace(&found);
    found.deinit();
    try t.expectEqual(@as(usize, 0), found.n);
    try t.expectEqualStrings("icon", destination.entries[0].png);
    destination.filter("nothing matches");
    try t.expectEqual(@as(usize, 0), destination.n);
}

test "file answers move icons only for the current enabled query" {
    const t = std.testing;
    const files = @import("files.zig");
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.turn(.files, true);
    s.query.set("report");
    pipeline.rebuild(s);
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report", false, .{ .score = 100 });
    found.entries[0].png = try t.allocator.dupe(u8, "worker icon");
    const bytes = found.entries[0].png.ptr;
    pipeline.filesAnswered(s, "stale", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    try t.expectEqual(@as(usize, 0), s.found.n);
    s.turn(.files, false);
    pipeline.filesAnswered(s, "report", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    s.turn(.files, true);
    pipeline.filesAnswered(s, "report", &found);
    try t.expectEqual(@as(usize, 0), found.n);
    // Moved, not copied (files.List.replace): the panel holds the worker's bytes.
    try t.expectEqual(bytes, s.found.entries[0].png.ptr);
    found.deinit();
    try t.expectEqualStrings("worker icon", s.found.entries[0].png);
    var replacement: files.List = .{ .allocator = t.allocator };
    defer replacement.deinit();
    replacement.add("/tmp/report2", false, .{ .score = 100 });
    replacement.entries[0].png = try t.allocator.dupe(u8, "replacement");
    pipeline.filesAnswered(s, "report", &replacement);
    try t.expectEqualStrings("replacement", s.found.entries[0].png);
    s.query.clear();
    pipeline.rebuild(s);
    try t.expectEqual(@as(usize, 0), s.found.n);
}

/// The row of `kind` showing `text` (a file's path or a completion), if listed.
fn rowOf(s: *const Nanolight, kind: results.Kind, text: []const u8) ?usize {
    for (s.res.slice(), 0..) |r, i| {
        if (r.kind == kind and std.mem.eql(u8, pipeline.textOf(s, r), text)) return i;
    }
    return null;
}

/// ↓ until the row of `kind` showing `text` is selected.
fn pick(rig: *Rig, kind: results.Kind, text: []const u8) !void {
    const want = rowOf(&rig.s, kind, text) orelse return error.NoRow;
    for (0..rig.s.res.slice().len) |_| {
        if (rig.s.selection() == want) return;
        _ = rig.t.shortcut(.{ .key = @import("nanoui").ui.Shortcut.down });
    }
    if (rig.s.selection() != want) return error.NotReached;
}

test "the selection stays on its row as files and completions land in any order" {
    const t = std.testing;
    const files = @import("files.zig");
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.turn(.files, true);
    try rig.mount(.{});
    @import("test_support.zig").retype(&rig.t, "report");
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report-a", false, .{ .score = 100 });
    found.add("/tmp/report-b", false, .{ .score = 50 });
    pipeline.filesAnswered(s, "report", &found);
    // A file picked, then completions land above nothing it had.
    try pick(&rig, .file, "/tmp/report-b");
    var web: suggest.List = .{};
    for ([_][]const u8{ "report card", "report template" }) |q| web.push(q);
    pipeline.answered(s, "report", &web);
    try t.expectEqual(rowOf(s, .file, "/tmp/report-b"), s.selection());
    // A completion picked, then files land in another order.
    try pick(&rig, .suggest, "report template");
    found.add("/tmp/report-c", false, .{ .score = 300 });
    found.add("/tmp/report-b", false, .{ .score = 200 });
    found.add("/tmp/report-a", false, .{ .score = 10 });
    pipeline.filesAnswered(s, "report", &found);
    try t.expectEqual(rowOf(s, .suggest, "report template"), s.selection());
    // The picked file moved up: the selection goes with it.
    const a_was = rowOf(s, .file, "/tmp/report-a").?;
    try pick(&rig, .file, "/tmp/report-a");
    found.add("/tmp/report-a", false, .{ .score = 900 });
    found.add("/tmp/report-c", false, .{ .score = 300 });
    pipeline.filesAnswered(s, "report", &found);
    const a_now = rowOf(s, .file, "/tmp/report-a").?;
    try t.expect(a_now != a_was);
    try t.expectEqual(@as(?usize, a_now), s.selection());
    // The picked completion is gone from the next answer: back to the top.
    try pick(&rig, .suggest, "report card");
    web = .{};
    web.push("report template");
    pipeline.answered(s, "report", &web);
    try t.expectEqual(@as(?usize, 0), s.selection());
}

/// A host that searches files: what it was asked, and how often.
const FileAsks = struct {
    last: [64]u8 = undefined,
    last_len: usize = 0,
    count: usize = 0,

    fn host(a: *FileAsks) Host {
        var h = @import("test_support.zig").quietHost(a, open, hide);
        h.files = .{ .ctx = a, .func = ask };
        return h;
    }
    fn open(_: *anyopaque, _: Target) void {}
    fn hide(_: *anyopaque) void {}
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const a: *FileAsks = @ptrCast(@alignCast(ctx));
        @memcpy(a.last[0..q.len], q);
        a.last_len = q.len;
        a.count += 1;
    }
};

test "a query the answer card takes is not searched for as a file" {
    if (!@import("platform.zig").files) return error.SkipZigTest;
    const t = std.testing;
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    var asks: FileAsks = .{};
    const s = &rig.s;
    s.host = asks.host();
    s.turn(.files, true);
    // Math typed so far, and conversions: the card shows, no search starts.
    const cards = [_][]const u8{
        "2 + 3",
        "2 + 3 *",
        "10 km to mi",
        "10 km to mi *",
        "100 usd to ttd",
    };
    for (cards) |q| {
        s.query.set(q);
        pipeline.rebuild(s);
        try t.expectEqual(results.Kind.calc, s.res.slice()[0].kind);
        try t.expectEqual(@as(usize, 0), asks.count);
    }
    // Words are searched for.
    s.query.set("10 km report");
    pipeline.rebuild(s);
    try t.expect(s.res.slice().len == 0 or s.res.slice()[0].kind != .calc);
    try t.expectEqual(@as(usize, 1), asks.count);
    try t.expectEqualStrings("10 km report", asks.last[0..asks.last_len]);
}

test "a tab or line break pasted round the words reads as the words, to rows and files alike" {
    if (!@import("platform.zig").files) return error.SkipZigTest;
    const t = std.testing;
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    var asks: FileAsks = .{};
    const s = &rig.s;
    s.host = asks.host();
    s.turn(.files, true);
    // Math: the card shows, and no file is looked for.
    s.query.set("2 + 3\t");
    pipeline.rebuild(s);
    try t.expectEqual(results.Kind.calc, s.res.slice()[0].kind);
    try t.expectEqual(@as(usize, 0), asks.count);
    // Words: searched for without the blanks, and what is found lands.
    s.query.set("\treport\r\n");
    pipeline.rebuild(s);
    try t.expectEqualStrings("report", asks.last[0..asks.last_len]);
    var found: @import("files.zig").List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report-a", false, .{ .score = 100 });
    pipeline.filesAnswered(s, "report", &found);
    try t.expect(rowOf(s, .file, "/tmp/report-a") != null);
}
