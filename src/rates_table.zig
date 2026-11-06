//! A table of currency rates (`Rates`, the JSON of
//! github.com/fawazahmed0/exchange-api: lowercase codes, each worth of one
//! USD) and what rows are built with (`Status`). Fetching and keeping it is
//! rates.zig's; converting by it, convert.zig's (through `Rates.perUsd`).
const std = @import("std");

/// A longer table is not read.
pub const max_bytes = 512 * 1024;

/// Currency rates, each worth of one USD, by lowercase three-letter code.
pub const Rates = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(f64) = .empty,
    /// YYYY-MM-DD, the day the table is for.
    date: [10]u8,

    pub fn deinit(r: *Rates) void {
        r.arena.deinit();
    }

    /// The table in `body` (`{"date":"2026-11-03","usd":{"eur":0.86,…}}`),
    /// or null if it isn't one. Names other than three letters are left out.
    pub fn parse(gpa: std.mem.Allocator, body: []const u8) ?Rates {
        if (body.len > max_bytes) return null;
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        const v = std.json.parseFromSliceLeaky(
            std.json.Value,
            tmp.allocator(),
            body,
            .{},
        ) catch return null;
        if (v != .object) return null;
        const day = v.object.get("date") orelse return null;
        const table = v.object.get("usd") orelse return null;
        if (day != .string or day.string.len != 10 or table != .object) return null;
        for (day.string, 0..) |c, i| if (if (i == 4 or
            i == 7) c != '-' else !std.ascii.isDigit(c)) return null;
        var r: Rates = .{ .arena = .init(gpa), .date = day.string[0..10].* };
        const a = r.arena.allocator();
        var it = table.object.iterator();
        while (it.next()) |e| {
            var b: [3]u8 = undefined;
            const k = code(e.key_ptr.*, &b) orelse continue;
            const x: f64 = switch (e.value_ptr.*) {
                .integer => |n| @floatFromInt(n),
                .float => |f| f,
                else => continue,
            };
            if (!(x > 0) or !std.math.isFinite(x)) continue;
            const key = a.dupe(u8, k) catch {
                r.deinit();
                return null;
            };
            r.map.put(a, key, x) catch {
                r.deinit();
                return null;
            };
        }
        if (r.map.count() == 0) {
            r.deinit();
            return null;
        }
        return r;
    }

    /// Lowercase code `c`'s worth of one USD, null when the table lacks it;
    /// `ctx` is the `*const Rates` (convert.zig's `Lookup.perUsd`).
    pub fn perUsd(ctx: *const anyopaque, c: []const u8) ?f64 {
        const r: *const Rates = @ptrCast(@alignCast(ctx));
        return r.map.get(c);
    }

    /// `name` lowercased when it is three letters.
    fn code(name: []const u8, buf: *[3]u8) ?[]const u8 {
        if (name.len != 3) return null;
        for (name, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c)) return null;
            buf[i] = std.ascii.toLower(c);
        }
        return buf;
    }
};

/// What rows are built with: the table in hand, and whether it could not be had.
pub const Status = struct {
    table: ?*const Rates = null,
    failed: bool = false,
};

const testing = std.testing;

test "rates read the fetched table" {
    const sample =
        \\{"date":"2026-11-03","usd":{"1inch":1.2,"usd":1,"TTD":6.785,"zzz":0,"bad":"x"}}
    ;
    var r = Rates.parse(testing.allocator, sample).?;
    defer r.deinit();
    try testing.expectEqualStrings("2026-11-03", &r.date);
    try testing.expectEqual(@as(f64, 6.785), Rates.perUsd(&r, "ttd").?);
    try testing.expectEqual(@as(f64, 1), Rates.perUsd(&r, "usd").?);
    try testing.expect(Rates.perUsd(&r, "1inch") == null);
    try testing.expect(Rates.perUsd(&r, "zzz") == null);
    for ([_][]const u8{
        "",
        "<html>",
        "[]",
        "{\"usd\":{\"eur\":1}}",
        "{\"date\":\"2026-11-03\"}",
        "{\"date\":\"tomorrow!!\",\"usd\":{\"eur\":1}}",
        "{\"date\":\"2026-11-03\",\"usd\":{}}",
    }) |bad|
        try testing.expect(Rates.parse(testing.allocator, bad) == null);
}
