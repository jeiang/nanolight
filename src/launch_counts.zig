//! How often apps and script commands were opened, as this machine keeps
//! it (`Counts`) and a synced record carries it (settings.zig): one cap and
//! one order for both.
const std = @import("std");
const assert = std.debug.assert;

/// At most this many counts are kept: the most opened.
pub const max = 512;

/// A count, by key: an app's path (or, in older rows, its name), or a
/// script command's (script_commands.zig `Script.key`).
pub const Launch = struct { key: []const u8, count: u16 };

/// Most opened first; of equals, the earlier key: the same order every run.
pub fn before(a: Launch, b: Launch) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.key, b.key);
}

pub fn mostOpened(list: []Launch) []const Launch {
    std.sort.pdq(Launch, list, {}, struct {
        fn f(_: void, a: Launch, b: Launch) bool {
            return before(a, b);
        }
    }.f);
    return list[0..@min(list.len, max)];
}

/// This machine's counts by key: what is listed and was opened, and what a
/// scan did not find (a volume not mounted), so no count is lost.
pub const Counts = struct {
    /// The keys are owned.
    map: std.StringArrayHashMapUnmanaged(u16) = .empty,

    pub fn deinit(c: *Counts, gpa: std.mem.Allocator) void {
        for (c.map.keys()) |k| gpa.free(k);
        c.map.deinit(gpa);
        c.* = undefined;
    }

    pub fn of(c: *const Counts, key: []const u8) u16 {
        return c.map.get(key) orelse 0;
    }

    /// Counts an opening of `key`; out of memory, a new key goes uncounted.
    pub fn bump(c: *Counts, gpa: std.mem.Allocator, key: []const u8) void {
        const n = c.slot(gpa, key) orelse return;
        n.* +|= 1;
    }

    /// `key`'s count, at least `count` (another machine's).
    pub fn raise(c: *Counts, gpa: std.mem.Allocator, key: []const u8, count: u16) void {
        if (count <= c.of(key)) return;
        const n = c.slot(gpa, key) orelse return;
        n.* = count;
    }

    /// `name`'s count, kept by an older row, is `key`'s from now on.
    pub fn rename(c: *Counts, gpa: std.mem.Allocator, name: []const u8, key: []const u8) void {
        if (std.mem.eql(u8, name, key)) return;
        const kv = c.map.fetchSwapRemove(name) orelse return;
        defer gpa.free(kv.key);
        if (c.map.contains(key)) return;
        const n = c.slot(gpa, key) orelse return;
        n.* = kv.value;
    }

    fn slot(c: *Counts, gpa: std.mem.Allocator, key: []const u8) ?*u16 {
        if (c.map.getPtr(key)) |n| return n;
        // best effort: out of memory, the key is not counted this run.
        const own = gpa.dupe(u8, key) catch return null;
        const got = c.map.getOrPut(gpa, own) catch {
            gpa.free(own);
            return null;
        };
        assert(!got.found_existing);
        got.value_ptr.* = 0;
        return got.value_ptr;
    }

    /// The counts in `text`, as `encode` writes them, into an empty table.
    /// Past `max`, a count only replaces the least opened, if it beats it; a
    /// count that is not a number is logged and passed over.
    pub fn parse(c: *Counts, gpa: std.mem.Allocator, text: []const u8) void {
        assert(c.map.count() == 0);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const key = line[0..tab];
            const count = std.fmt.parseInt(u16, line[tab + 1 ..], 10) catch |err| {
                std.log.warn("nanolight: launch count of {s} not read: {t}", .{ key, err });
                continue;
            };
            if (count == 0) continue;
            if (c.map.count() >= max and !c.map.contains(key)) {
                if (!c.dropLeast(gpa, count)) continue;
            }
            const n = c.slot(gpa, key) orelse return;
            n.* = count;
        }
        assert(c.map.count() <= max);
    }

    /// Makes room for a count of `count` by dropping the least opened, if it
    /// is opened less; false when it is not.
    fn dropLeast(c: *Counts, gpa: std.mem.Allocator, count: u16) bool {
        const values = c.map.values();
        var least: usize = 0;
        for (values, 0..) |v, i| if (v < values[least]) {
            least = i;
        };
        if (values[least] >= count) return false;
        gpa.free(c.map.keys()[least]);
        c.map.swapRemoveAt(least);
        return true;
    }

    /// The `max` most opened, a line each ("key\tcount"); null out of memory.
    pub fn encode(c: *const Counts, gpa: std.mem.Allocator) ?[]u8 {
        var list: std.ArrayList(Launch) = .empty;
        defer list.deinit(gpa);
        // best effort: out of memory, nothing is encoded.
        list.ensureTotalCapacity(gpa, c.map.count()) catch return null;
        for (c.map.keys(), c.map.values()) |k, v| if (v > 0) {
            list.appendAssumeCapacity(.{ .key = k, .count = v });
        };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        // best effort: as above.
        for (mostOpened(list.items)) |l| aw.writer.print("{s}\t{d}\n", .{ l.key, l.count }) catch
            return null;
        // best effort: as above.
        return aw.toOwnedSlice() catch null;
    }
};

test "counts are kept by key, raised by another machine's, and renamed once" {
    const t = std.testing;
    var c: Counts = .{};
    defer c.deinit(t.allocator);
    // An older row, by name: the app's path takes its count.
    c.parse(t.allocator, "Mail\t3\n");
    c.rename(t.allocator, "Mail", "/Applications/Mail.app");
    try t.expectEqual(@as(u16, 3), c.of("/Applications/Mail.app"));
    try t.expectEqual(@as(u16, 0), c.of("Mail"));
    c.bump(t.allocator, "/Applications/Safari.app");
    c.bump(t.allocator, "/Applications/Safari.app");
    c.raise(t.allocator, "/Applications/Safari.app", 1);
    try t.expectEqual(@as(u16, 2), c.of("/Applications/Safari.app"));
    c.raise(t.allocator, "script:/s/hi.sh", 5);
    try t.expectEqual(@as(u16, 5), c.of("script:/s/hi.sh"));
    const text = c.encode(t.allocator).?;
    defer t.allocator.free(text);
    try t.expectEqualStrings(
        "script:/s/hi.sh\t5\n/Applications/Mail.app\t3\n/Applications/Safari.app\t2\n",
        text,
    );
}

test "past the cap, the least opened counts are dropped" {
    const t = std.testing;
    // More stored than kept, least opened first (an order `encode` never writes).
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    for (0..max + 10) |i| try aw.writer.print("/gone/{d}.app\t{d}\n", .{ i, i + 1 });
    var c: Counts = .{};
    defer c.deinit(t.allocator);
    c.parse(t.allocator, aw.written());
    try t.expectEqual(@as(usize, max), c.map.count());
    for (c.map.values()) |v| try t.expect(v > 10);
    // Safari, opened once, is the least opened of all: it is the one left out.
    c.bump(t.allocator, "/Applications/Safari.app");
    const text = c.encode(t.allocator).?;
    defer t.allocator.free(text);
    try t.expectEqual(@as(usize, max), std.mem.count(u8, text, "\n"));
    try t.expect(std.mem.indexOf(u8, text, "Safari") == null);
    var first: [64]u8 = undefined;
    // The most opened of those stored leads.
    try t.expect(std.mem.startsWith(
        u8,
        text,
        try std.fmt.bufPrint(&first, "/gone/{d}.app\t{d}\n", .{ max + 9, max + 10 }),
    ));
}
