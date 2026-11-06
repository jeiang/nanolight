//! File search regression coverage.
const std = @import("std");
const view = @import("view.zig");
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
    s.files_on = true;
    try rig.apps(&.{ "Safari", "Mail", "Maps", "Calendar", "Calculator", "System Settings Alpha" });
    // "settings" keeps Nanolight's Settings first; "a" matches all six apps.
    for ([_][]const u8{ "settings", "a" }) |q| {
        s.query.set(q);
        s.rebuild();
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
            s.filesAnswered(q, &found);
            s.answered(q, &four);
            try std.testing.expect(s.height() <= chrome.max_height);
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
                s.res.rows[@intFromBool(settings)].kind,
            );
            // Every quicklink still follows, X's last, and one search for what was typed.
            try std.testing.expectEqual(results.Kind.quicklink, s.res.rows[s.res.n - 1].kind);
            try std.testing.expectEqual(@as(u16, 4), s.res.rows[s.res.n - 1].ql);
            var google: usize = 0;
            for (s.res.slice()) |row| {
                if (row.kind == .quicklink and row.ql == 0) google += 1;
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
    var buf: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"readme\"cd",
        spotlight.predicate(&buf, "readme", .exact).?,
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"readme*\"cd",
        spotlight.predicate(&buf, "readme", .prefix).?,
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"* readme*\"cd",
        spotlight.predicate(&buf, "readme", .word).?,
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"*r*e*a*d*m*e*\"cd",
        spotlight.predicate(&buf, "readme", .subsequence).?,
    );
    try std.testing.expectEqualStrings(
        "kMDItemFSName == \"a\\*\\?\\\"\\\\*\"cd",
        spotlight.predicate(&buf, "a*?\"\\", .prefix).?,
    );
}

test "name search excludes the home Library subtree by default" {
    const paths = @import("paths.zig");
    const spotlight = @import("spotlight.zig");
    const home = paths.home();
    if (home.len == 0) return;
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
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const t = std.testing;
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.files_on = true;
    for (0..results.max_apps) |i| {
        var name: [64]u8 = undefined;
        try rig.apps(&.{try std.fmt.bufPrint(&name, "Login {d}", .{i})});
    }
    s.query.set("login");
    s.rebuild();
    var found: @import("files.zig").List = .{ .allocator = t.allocator };
    defer found.deinit();
    // A file named just what was typed outranks the apps' names; the rest,
    // matching worse, give way to the apps and the pane.
    found.add("/tmp/login", false, @import("search.zig").score("login", "login").?);
    for (1..5) |i| {
        var path: [64]u8 = undefined;
        found.add(try std.fmt.bufPrint(&path, "/tmp/login{d}", .{i}), false, .{ .score = 1 });
    }
    s.filesAnswered("login", &found);
    var web: suggest.List = .{};
    for ([_][]const u8{
        "login mac",
        "login windows",
        "login iphone",
        "login help",
    }) |q| web.push(q);
    s.answered("login", &web);
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
                google = google or row.ql == 0;
                links += 1;
            },
            else => {},
        }
    }
    try t.expect(apps and panes and files and google);
    try t.expectEqual(results.Kind.file, s.res.rows[0].kind);
    try t.expectEqual(results.max_quicklink_rows, links);
    try t.expectEqual(@as(usize, 3), heads);
    try t.expectEqual(results.max_rows, s.res.n);
    try t.expect(s.height() <= chrome.max_height);
}

test "file icon allocations survive filtering, eviction and owning replacement" {
    const t = std.testing;
    const files = @import("files.zig");
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    // Keeping paths inline is intentional; the 32 KiB icons must stay out of rows.
    try t.expect(@sizeOf(files.Entry) < files.max_path + 1024);
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
    s.files_on = true;
    s.query.set("report");
    s.rebuild();
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report", false, .{ .score = 100 });
    found.entries[0].png = try t.allocator.dupe(u8, "worker icon");
    const bytes = found.entries[0].png.ptr;
    s.filesAnswered("stale", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    try t.expectEqual(@as(usize, 0), s.found.n);
    s.files_on = false;
    s.filesAnswered("report", &found);
    try t.expectEqual(@as(usize, 1), found.n);
    s.files_on = true;
    s.filesAnswered("report", &found);
    try t.expectEqual(@as(usize, 0), found.n);
    try t.expectEqual(bytes, s.found.entries[0].png.ptr);
    found.deinit();
    try t.expectEqualStrings("worker icon", s.found.entries[0].png);
    var replacement: files.List = .{ .allocator = t.allocator };
    defer replacement.deinit();
    replacement.add("/tmp/report2", false, .{ .score = 100 });
    replacement.entries[0].png = try t.allocator.dupe(u8, "replacement");
    s.filesAnswered("report", &replacement);
    try t.expectEqualStrings("replacement", s.found.entries[0].png);
    s.query.clear();
    s.rebuild();
    try t.expectEqual(@as(usize, 0), s.found.n);
}

/// The row of `kind` showing `text` (a file's path or a completion), if listed.
fn rowOf(s: *const view.Nanolight, kind: results.Kind, text: []const u8) ?usize {
    for (s.res.slice(), 0..) |r, i| {
        if (r.kind != kind) continue;
        const shown = switch (kind) {
            .file => s.found.entries[r.file].path(),
            .suggest => s.web.get(r.web),
            else => unreachable,
        };
        if (std.mem.eql(u8, shown, text)) return i;
    }
    return null;
}

test "the selection stays on its row as files and completions land in any order" {
    const t = std.testing;
    const files = @import("files.zig");
    var rig: Rig = undefined;
    rig.init(t.allocator);
    defer rig.deinit();
    const s = &rig.s;
    s.files_on = true;
    s.query.set("report");
    s.rebuild();
    var found: files.List = .{ .allocator = t.allocator };
    defer found.deinit();
    found.add("/tmp/report-a", false, .{ .score = 100 });
    found.add("/tmp/report-b", false, .{ .score = 50 });
    s.filesAnswered("report", &found);
    // A file picked, then completions land above nothing it had.
    s.sel = rowOf(s, .file, "/tmp/report-b").?;
    var web: suggest.List = .{};
    for ([_][]const u8{ "report card", "report template" }) |q| web.push(q);
    s.answered("report", &web);
    try t.expectEqual(rowOf(s, .file, "/tmp/report-b").?, s.sel);
    // A completion picked, then files land in another order.
    s.sel = rowOf(s, .suggest, "report template").?;
    found.add("/tmp/report-c", false, .{ .score = 300 });
    found.add("/tmp/report-b", false, .{ .score = 200 });
    found.add("/tmp/report-a", false, .{ .score = 10 });
    s.filesAnswered("report", &found);
    try t.expectEqual(rowOf(s, .suggest, "report template").?, s.sel);
    // The picked file moved up: the selection goes with it.
    const a_was = rowOf(s, .file, "/tmp/report-a").?;
    s.sel = a_was;
    found.add("/tmp/report-a", false, .{ .score = 900 });
    found.add("/tmp/report-c", false, .{ .score = 300 });
    s.filesAnswered("report", &found);
    const a_now = rowOf(s, .file, "/tmp/report-a").?;
    try t.expect(a_now != a_was);
    try t.expectEqual(a_now, s.sel);
    // The picked completion is gone from the next answer: back to the top.
    s.sel = rowOf(s, .suggest, "report card").?;
    web = .{};
    web.push("report template");
    s.answered("report", &web);
    try t.expectEqual(@as(usize, 0), s.sel);
}

/// A host that searches files: what it was asked, and how often.
const FileAsks = struct {
    last: [64]u8 = undefined,
    last_len: usize = 0,
    count: usize = 0,

    fn host(a: *FileAsks) view.Host {
        return .{ .ctx = a, .open = open, .hide = hide, .files = .{ .ctx = a, .func = ask } };
    }
    fn open(_: *anyopaque, _: []const u8) void {}
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
    s.files_on = true;
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
        s.rebuild();
        try t.expectEqual(results.Kind.calc, s.res.rows[0].kind);
        try t.expectEqual(@as(usize, 0), asks.count);
    }
    // Words are searched for.
    s.query.set("10 km report");
    s.rebuild();
    try t.expect(s.res.n == 0 or s.res.rows[0].kind != .calc);
    try t.expectEqual(@as(usize, 1), asks.count);
    try t.expectEqualStrings("10 km report", asks.last[0..asks.last_len]);
}
