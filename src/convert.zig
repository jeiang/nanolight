//! Conversions typed into the bar: "10 km to mi", "32 f in c", "1.5 GiB to
//! MB", "100 usd to ttd", "$20 in eur", with math around them: "35 * 7 ttd
//! to usd" converts 245 TTD, "10 km to mi / 2" halves the miles. All of it
//! is pure parsing; calc.zig works out the math. Money is converted by
//! whatever rates `answer` is handed (a `Lookup`; rates_table.zig's table).
const std = @import("std");
const calc = @import("calc.zig");

const Family = enum { length, mass, temperature, volume, area, speed, data, time };

/// `names` are comma-separated, matched in any case; the first is shown. A value in
/// the family's base unit is `v * scale + offset`.
const Unit = struct { family: Family, names: []const u8, scale: f64, offset: f64 = 0 };

const units = [_]Unit{
    .{ .family = .length, .names = "m,meter,meters,metre,metres", .scale = 1 },
    .{ .family = .length, .names = "km,kilometer,kilometers,kilometre,kilometres", .scale = 1000 },
    .{
        .family = .length,
        .names = "cm,centimeter,centimeters,centimetre,centimetres",
        .scale = 0.01,
    },
    .{
        .family = .length,
        .names = "mm,millimeter,millimeters,millimetre,millimetres",
        .scale = 0.001,
    },
    .{ .family = .length, .names = "um,µm,micron,microns,micrometer,micrometers", .scale = 1e-6 },
    .{ .family = .length, .names = "nm,nanometer,nanometers", .scale = 1e-9 },
    .{ .family = .length, .names = "mi,mile,miles", .scale = 1609.344 },
    .{ .family = .length, .names = "yd,yds,yard,yards", .scale = 0.9144 },
    .{ .family = .length, .names = "ft,foot,feet", .scale = 0.3048 },
    .{ .family = .length, .names = "in,inch,inches", .scale = 0.0254 },
    .{ .family = .mass, .names = "kg,kilogram,kilograms,kilo,kilos", .scale = 1 },
    .{ .family = .mass, .names = "g,gram,grams", .scale = 0.001 },
    .{ .family = .mass, .names = "mg,milligram,milligrams", .scale = 1e-6 },
    .{ .family = .mass, .names = "lb,lbs,pound,pounds", .scale = 0.45359237 },
    .{ .family = .mass, .names = "oz,ounce,ounces", .scale = 0.028349523125 },
    .{ .family = .mass, .names = "st,stone,stones", .scale = 6.35029318 },
    .{ .family = .mass, .names = "t,tonne,tonnes", .scale = 1000 },
    .{ .family = .mass, .names = "ton,tons", .scale = 907.18474 },
    .{ .family = .temperature, .names = "°C,c,celsius", .scale = 1 },
    .{
        .family = .temperature,
        .names = "°F,f,fahrenheit",
        .scale = 5.0 / 9.0,
        .offset = -160.0 / 9.0,
    },
    .{ .family = .temperature, .names = "K,kelvin", .scale = 1, .offset = -273.15 },
    .{ .family = .volume, .names = "L,liter,liters,litre,litres", .scale = 1 },
    .{
        .family = .volume,
        .names = "mL,milliliter,milliliters,millilitre,millilitres",
        .scale = 0.001,
    },
    .{ .family = .volume, .names = "gal,gallon,gallons", .scale = 3.785411784 },
    .{ .family = .volume, .names = "qt,quart,quarts", .scale = 0.946352946 },
    .{ .family = .volume, .names = "pt,pint,pints", .scale = 0.473176473 },
    .{ .family = .volume, .names = "cup,cups", .scale = 0.2365882365 },
    .{
        .family = .volume,
        .names = "floz,fl oz,fluid ounce,fluid ounces",
        .scale = 0.0295735295625,
    },
    .{ .family = .volume, .names = "tbsp,tablespoon,tablespoons", .scale = 0.01478676478125 },
    .{ .family = .volume, .names = "tsp,teaspoon,teaspoons", .scale = 0.00492892159375 },
    .{
        .family = .area,
        .names = "m2,m²,sqm,square meter,square meters,square metre,square metres",
        .scale = 1,
    },
    .{ .family = .area, .names = "km2,km²,sqkm,square kilometer,square kilometers", .scale = 1e6 },
    .{ .family = .area, .names = "cm2,cm²,sqcm", .scale = 1e-4 },
    .{ .family = .area, .names = "ha,hectare,hectares", .scale = 1e4 },
    .{ .family = .area, .names = "acre,acres", .scale = 4046.8564224 },
    .{ .family = .area, .names = "ft2,ft²,sqft,square foot,square feet", .scale = 0.09290304 },
    .{ .family = .area, .names = "yd2,yd²,sqyd", .scale = 0.83612736 },
    .{ .family = .area, .names = "mi2,mi²,sqmi,square mile,square miles", .scale = 2589988.110336 },
    .{ .family = .speed, .names = "m/s,mps", .scale = 1 },
    .{ .family = .speed, .names = "km/h,kmh,kph,kmph", .scale = 1.0 / 3.6 },
    .{ .family = .speed, .names = "mph,mi/h", .scale = 0.44704 },
    .{ .family = .speed, .names = "kn,kt,knot,knots", .scale = 1852.0 / 3600.0 },
    .{ .family = .speed, .names = "ft/s,fps", .scale = 0.3048 },
    .{ .family = .data, .names = "B,byte,bytes", .scale = 1 },
    .{ .family = .data, .names = "KB,kilobyte,kilobytes", .scale = 1e3 },
    .{ .family = .data, .names = "MB,megabyte,megabytes", .scale = 1e6 },
    .{ .family = .data, .names = "GB,gigabyte,gigabytes", .scale = 1e9 },
    .{ .family = .data, .names = "TB,terabyte,terabytes", .scale = 1e12 },
    .{ .family = .data, .names = "KiB,kibibyte,kibibytes", .scale = 1 << 10 },
    .{ .family = .data, .names = "MiB,mebibyte,mebibytes", .scale = 1 << 20 },
    .{ .family = .data, .names = "GiB,gibibyte,gibibytes", .scale = 1 << 30 },
    .{ .family = .data, .names = "TiB,tebibyte,tebibytes", .scale = 1 << 40 },
    .{ .family = .time, .names = "s,sec,secs,second,seconds", .scale = 1 },
    .{ .family = .time, .names = "ms,msec,millisecond,milliseconds", .scale = 0.001 },
    .{ .family = .time, .names = "min,mins,minute,minutes", .scale = 60 },
    .{ .family = .time, .names = "h,hr,hrs,hour,hours", .scale = 3600 },
    .{ .family = .time, .names = "d,day,days", .scale = 86400 },
    .{ .family = .time, .names = "wk,week,weeks", .scale = 7 * 86400 },
    .{ .family = .time, .names = "mo,month,months", .scale = 2629746 },
    .{ .family = .time, .names = "y,yr,yrs,year,years", .scale = 31556952 },
};

/// The unit `name` is, in any case.
fn unit(name: []const u8) ?*const Unit {
    if (name.len == 0) return null;
    for (&units) |*u| {
        var it = std.mem.splitScalar(u8, u.names, ',');
        while (it.next()) |n| if (std.ascii.eqlIgnoreCase(n, name)) return u;
    }
    return null;
}

const symbols = [_]struct { sym: []const u8, code: []const u8 }{
    .{ .sym = "$", .code = "usd" },
    .{ .sym = "€", .code = "eur" },
    .{ .sym = "£", .code = "gbp" },
    .{ .sym = "¥", .code = "jpy" },
};

/// The lowercase currency code `word` is: three letters, or a symbol.
fn code(word: []const u8, buf: *[3]u8) ?[]const u8 {
    for (symbols) |s| if (std.mem.eql(u8, word, s.sym)) return s.code;
    if (word.len != 3) return null;
    for (word, 0..) |c, i| {
        if (!std.ascii.isAlphabetic(c)) return null;
        buf[i] = std.ascii.toLower(c);
    }
    return buf;
}

const Parsed = struct {
    amount: f64,
    from: []const u8,
    to: []const u8,
    /// Operators the converted value goes through ("* 12"), or empty.
    ops: []const u8 = "",
};

/// "<amount> <from> to|in <to>", or "<symbol><amount> to|in <to>", either
/// followed by operators on the converted value: "12 ttd to usd * 12". The
/// amount is any math (`calc.lead`): "3 * 10 km", "(2 + 3) km", "1,500 m".
/// Whether the names mean anything, and the operators, is for `answer`.
fn parse(query: []const u8) ?Parsed {
    var s = std.mem.trim(u8, query, " \t");
    var from: []const u8 = "";
    for (symbols) |sym| if (std.mem.startsWith(u8, s, sym.sym)) {
        from = sym.sym;
        s = std.mem.trimStart(u8, s[sym.sym.len..], " ");
        break;
    };
    const head = calc.lead(s) orelse return null;
    const rest = std.mem.trim(u8, head.rest, " \t");
    const target = if (from.len > 0) blk: {
        if (rest.len < 4 or !(std.ascii.startsWithIgnoreCase(rest, "to ") or
            std.ascii.startsWithIgnoreCase(rest, "in "))) return null;
        break :blk rest[3..];
    } else blk: {
        // The first " to " or " in " with something before it ("10 in in cm").
        var at: usize = 1;
        while (at + 4 <= rest.len) : (at += 1) {
            if (rest[at] != ' ' or rest[at + 3] != ' ') continue;
            const w = rest[at + 1 .. at + 3];
            if (!std.ascii.eqlIgnoreCase(w, "to") and !std.ascii.eqlIgnoreCase(w, "in")) continue;
            from = std.mem.trim(u8, rest[0..at], " \t");
            break :blk rest[at + 4 ..];
        }
        return null;
    };
    const tail = std.mem.trim(u8, target, " \t");
    const cut = opsStart(tail);
    const to = std.mem.trimEnd(u8, tail[0..cut], " \t");
    return if (to.len == 0)
        null
    else
        .{ .amount = head.value, .from = from, .to = to, .ops = tail[cut..] };
}

/// Where the operators after a conversion's target begin ("usd * 12" at the
/// `*`), or `s.len`. A slash between letters is a unit's own ("km/h").
fn opsStart(s: []const u8) usize {
    for (s, 0..) |ch, i| {
        const in_unit = ch == '/' and i > 0 and i + 1 < s.len and
            std.ascii.isAlphabetic(s[i - 1]) and std.ascii.isAlphabetic(s[i + 1]);
        if (calc.opLen(s[i..]) > 0 and !in_unit) return i;
    }
    return s.len;
}

/// Currency rates to convert money with: `perUsd` is a lowercase code's
/// worth of one USD (null when unknown), `date` the day they are for
/// (YYYY-MM-DD).
pub const Lookup = struct {
    ctx: *const anyopaque,
    perUsd: *const fn (ctx: *const anyopaque, code: []const u8) ?f64,
    date: [10]u8,
};

pub const UnitAnswer = struct { amount: f64, value: f64, from: []const u8, to: []const u8 };
pub const Money = struct {
    amount: f64,
    value: f64,
    /// One unit of `from` in `to`.
    rate: f64,
    from: [3]u8,
    to: [3]u8,
    date: [10]u8,
};

pub const Answer = union(enum) {
    unit: UnitAnswer,
    money: Money,
    /// Currencies by the look of it, but there is no table to say.
    pending,
};

/// What `query` converts to, or null if it is not a conversion: unknown
/// names, units of different kinds ("10 m to min"), or math that doesn't
/// compute around it ("10 km to mi *"). The answer's `amount` is the math
/// before the units worked out, its `value` the converted one carried
/// through the operators after them.
pub fn answer(query: []const u8, rates: ?Lookup) ?Answer {
    const p = parse(query) orelse return null;
    const a = unit(p.from);
    const b = unit(p.to);
    if (a != null or b != null) {
        const x = a orelse return null;
        const y = b orelse return null;
        if (x.family != y.family) return null;
        const v = calc.carry(((p.amount * x.scale + x.offset) - y.offset) / y.scale, p.ops) orelse
            return null;
        return .{ .unit = .{ .amount = p.amount, .value = v, .from = first(x), .to = first(y) } };
    }
    var fb: [3]u8 = undefined;
    var tb: [3]u8 = undefined;
    const f = code(p.from, &fb) orelse return null;
    const t = code(p.to, &tb) orelse return null;
    const table = rates orelse {
        // Nothing to convert with yet: the operators are tried on the
        // amount, which has the answer's sign, so bad math is not pending.
        _ = calc.carry(p.amount, p.ops) orelse return null;
        return .pending;
    };
    const rf = table.perUsd(table.ctx, f) orelse return null;
    const rt = table.perUsd(table.ctx, t) orelse return null;
    const rate = rt / rf;
    const v = calc.carry(p.amount * rate, p.ops) orelse return null;
    var m: Money = .{
        .amount = p.amount,
        .value = v,
        .rate = rate,
        .from = undefined,
        .to = undefined,
        .date = table.date,
    };
    _ = std.ascii.upperString(&m.from, f);
    _ = std.ascii.upperString(&m.to, t);
    return .{ .money = m };
}

fn first(u: *const Unit) []const u8 {
    return u.names[0 .. std.mem.indexOfScalar(u8, u.names, ',') orelse u.names.len];
}

/// `v` to `decimals` places, with thousands separators when `grouped`.
fn fixed(buf: []u8, v: f64, decimals: usize, grouped: bool) []const u8 {
    var tmp: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d:.[1]}", .{ v, decimals }) catch return "";
    if (!grouped) return std.fmt.bufPrint(buf, "{s}", .{s}) catch "";
    return calc.group(buf, s);
}

/// A converted amount of money: two places, more for a tiny one.
pub fn formatMoney(buf: []u8, v: f64, grouped: bool) []const u8 {
    const a = @abs(v);
    const places: usize = if (a >= 0.01 or
        a == 0) 2 else @intFromFloat(@min(10, @ceil(-@log10(a)) + 2));
    return fixed(buf, v, places, grouped);
}

/// An exchange rate to six significant digits, without trailing zeros.
pub fn formatRate(buf: []u8, v: f64) []const u8 {
    const places: usize = @intFromFloat(std.math.clamp(5 - @floor(@log10(@abs(v))), 0, 12));
    const s = fixed(buf, v, places, false);
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, s, "0"), ".");
}

/// "1 USD = 6.785 TTD · 2026-11-03".
pub fn rateLine(buf: []u8, m: Money) []const u8 {
    var rb: [40]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "1 {s} = {s} {s} · {s}",
        .{ m.from, formatRate(&rb, m.rate), m.to, m.date },
    ) catch "";
}

/// Six significant digits, "9.09091e-13": fixed decimals would print 0.
fn scientific(buf: []u8, v: f64) []const u8 {
    var tmp: [40]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{e:.5}", .{v}) catch return "";
    const at = std.mem.indexOfScalar(u8, s, 'e') orelse return s;
    const m = std.mem.trimEnd(u8, std.mem.trimEnd(u8, s[0..at], "0"), ".");
    return std.fmt.bufPrint(buf, "{s}{s}", .{ m, s[at..] }) catch "";
}

/// The unit answer as the row shows it, and as Return copies it.
pub fn formatUnit(buf: []u8, a: UnitAnswer, grouped: bool) []const u8 {
    var nb: [64]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "{s} {s}",
        .{ formatUnitValue(&nb, a.value, grouped), a.to },
    ) catch "";
}

/// The number of a unit answer, without its unit.
pub fn formatUnitValue(buf: []u8, v: f64, grouped: bool) []const u8 {
    return if (v != 0 and @abs(v) < 1e-4) scientific(buf, v) else calc.format(buf, v, grouped);
}

const testing = std.testing;

fn unitValue(q: []const u8) ?f64 {
    return switch (answer(q, null) orelse return null) {
        .unit => |u| u.value,
        else => null,
    };
}

fn expectUnit(want: f64, q: []const u8) !void {
    const got = unitValue(q) orelse return error.NotAConversion;
    try testing.expectApproxEqRel(want, got, 1e-9);
}

test "each unit family converts" {
    try expectUnit(6.21371192237334, "10 km to mi");
    try expectUnit(304.8, "1000 ft to m");
    try expectUnit(25.4, "1 in to mm");
    try expectUnit(1000, "1 kg to g");
    try expectUnit(16, "1 lb to oz");
    try expectUnit(3.785411784, "1 gal to l");
    try expectUnit(2, "2000 ml to l");
    try expectUnit(10000, "1 ha to m2");
    try expectUnit(43560, "1 acre to sqft");
    try expectUnit(36, "10 m/s to km/h");
    try expectUnit(26.8224, "60 mph to m/s");
    try expectUnit(120, "2 h to min");
    try expectUnit(86400, "1 day to s");
}

test "forms and spellings" {
    try expectUnit(6.21371192237334, "10km in miles");
    try expectUnit(6.21371192237334, "10 KM TO MI");
    try expectUnit(6.21371192237334, "10 Kilometers To Miles");
    try expectUnit(2.54, "1 inch in cm");
    try expectUnit(2.54, "1 in in cm");
    try expectUnit(2.54, "1 in to cm");
    try expectUnit(1.5, "1,500 m to km");
    try expectUnit(-1000, "-1 km to m");
    try expectUnit(0.5, ".5 km to km");
    try expectUnit(29.5735295625, "1 fl oz to ml");
    try expectUnit(29.5735295625, "1 floz to ml");
    // Forms from before math came around them.
    try expectUnit(1500, "1,500,000 m to km");
    try expectUnit(1609.344, "1mi in m");
    try expectUnit(6.21371192237334, "  10 km to mi  ");
}

test "temperature has offsets" {
    try expectUnit(0, "32 f to c");
    try expectUnit(100, "212 °F to °C");
    try expectUnit(273.15, "0 c to k");
    try expectUnit(-459.67, "0 k to f");
    try expectUnit(-40, "-40 c to f");
    try expectUnit(37, "98.6 f to c");
}

test "data units are decimal or binary by name" {
    try expectUnit(1000, "1 kb to b");
    try expectUnit(1024, "1 kib to b");
    try expectUnit(1610.612736, "1.5 GiB in MB");
    try expectUnit(1024, "1 GiB to MiB");
    try expectUnit(1000, "1 TB to GB");
    try expectUnit(1e12 / 1099511627776.0, "1 tb to tib");
}

test "unclear or mismatched names are not conversions" {
    try testing.expect(answer("10 m to min", null) == null);
    try testing.expect(answer("10 min to m", null) == null);
    try testing.expect(answer("10 kg to km", null) == null);
    try testing.expect(answer("10 c to kg", null) == null);
    try testing.expect(answer("10 km to usd", null) == null);
    try testing.expect(answer("10 usd to km", null) == null);
    try testing.expect(answer("10 foobar to bar", null) == null);
    try testing.expect(answer("10 km to", null) == null);
    try testing.expect(answer("10 km mi", null) == null);
    try testing.expect(answer("km to mi", null) == null);
    try testing.expect(answer("to mi", null) == null);
    try testing.expect(answer("10 to mi", null) == null);
    try testing.expect(answer("10 km to mi to ft", null) == null);
    try testing.expect(answer("safari", null) == null);
    try testing.expect(answer("2 + 2", null) == null);
    try testing.expect(answer("1 e to c", null) == null);
}

test "the parser splits on the first separator" {
    const p = parse("  1.5 GiB in MB ").?;
    try testing.expectEqual(@as(f64, 1.5), p.amount);
    try testing.expectEqualStrings("GiB", p.from);
    try testing.expectEqualStrings("MB", p.to);
    const q = parse("$20 to eur").?;
    try testing.expectEqual(@as(f64, 20), q.amount);
    try testing.expectEqualStrings("$", q.from);
    try testing.expectEqualStrings("eur", q.to);
    const w = parse("10 fl oz to ml").?;
    try testing.expectEqualStrings("fl oz", w.from);
    try testing.expect(parse("$ to eur") == null);
    try testing.expect(parse("$20 eur") == null);
    // The math before the units is the amount; operators after the target
    // are kept apart, and old forms have none.
    try testing.expectEqualStrings("", parse("10km in miles").?.ops);
    const e = parse("35 * 7 ttd to usd").?;
    try testing.expectEqual(@as(f64, 245), e.amount);
    try testing.expectEqualStrings("ttd", e.from);
    try testing.expectEqualStrings("usd", e.to);
    try testing.expectEqualStrings("", e.ops);
    const o = parse("12 ttd to usd * 12").?;
    try testing.expectEqual(@as(f64, 12), o.amount);
    try testing.expectEqualStrings("usd", o.to);
    try testing.expectEqualStrings("* 12", o.ops);
    const v = parse("10 m/s to km/h / 2").?;
    try testing.expectEqualStrings("m/s", v.from);
    try testing.expectEqualStrings("km/h", v.to);
    try testing.expectEqualStrings("/ 2", v.ops);
    try testing.expectEqualStrings("/2", parse("10 km to mi/2").?.ops);
    const f = parse("1 cup to fl oz × 2").?;
    try testing.expectEqualStrings("fl oz", f.to);
    try testing.expectEqualStrings("× 2", f.ops);
    const d = parse("$20 * 3 in eur").?;
    try testing.expectEqual(@as(f64, 60), d.amount);
    try testing.expectEqualStrings("$", d.from);
    try testing.expectEqualStrings("eur", d.to);
    try testing.expect(parse("10 km to * 2") == null);
}

/// The rates the tests convert by.
const sample_table = [_]struct { []const u8, f64 }{
    .{ "usd", 1 },
    .{ "ttd", 6.785 },
    .{ "eur", 0.86 },
    .{ "gbp", 0.75 },
    .{ "jpy", 150.0 },
};

fn samplePerUsd(_: *const anyopaque, c: []const u8) ?f64 {
    for (sample_table) |e| if (std.mem.eql(u8, e[0], c)) return e[1];
    return null;
}

const sample: Lookup = .{ .ctx = &sample_table, .perUsd = samplePerUsd, .date = "2026-11-03".* };

test "currencies cross through the dollar" {
    const m = answer("100 USD in TTD", sample).?.money;
    try testing.expectApproxEqRel(@as(f64, 678.5), m.value, 1e-12);
    try testing.expectEqualStrings("USD", &m.from);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("678.50", formatMoney(&buf, m.value, false));
    try testing.expectEqualStrings("1 USD = 6.785 TTD · 2026-11-03", rateLine(&buf, m));
    const x = answer("100 eur to gbp", sample).?.money;
    try testing.expectApproxEqRel(@as(f64, 100 * 0.75 / 0.86), x.value, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 0.75 / 0.86), x.rate, 1e-12);
    try testing.expectEqualStrings("1 EUR = 0.872093 GBP · 2026-11-03", rateLine(&buf, x));
    // Symbols.
    try testing.expectApproxEqRel(@as(f64, 86), answer("$100 to €", sample).?.money.value, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 86), answer("100 $ to €", sample).?.money.value, 1e-12);
    try testing.expectApproxEqRel(
        @as(f64, 15000),
        answer("100 $ in ¥", sample).?.money.value,
        1e-12,
    );
    try testing.expectApproxEqRel(
        @as(f64, 100.0 / 0.75),
        answer("£100 in usd", sample).?.money.value,
        1e-12,
    );
    // A code the table lacks is not a conversion; no table is pending.
    try testing.expect(answer("100 usd to xyz", sample) == null);
    try testing.expect(answer("10 foo to bar", sample) == null);
    try testing.expect(answer("100 usd to ttd", null).? == .pending);
    try testing.expect(answer("100 usd to km", null) == null);
}

test "math around a conversion: the amount before it, the answer after it" {
    const a = answer("35 * 7 ttd to usd", sample).?.money;
    try testing.expectEqual(@as(f64, 245), a.amount);
    try testing.expectApproxEqRel(@as(f64, 245.0 / 6.785), a.value, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.0 / 6.785), a.rate, 1e-12);
    try testing.expectEqualStrings("TTD", &a.from);
    try testing.expectEqualStrings("USD", &a.to);
    // The rate is still one of `from`: the operators act on the answer.
    const b = answer("12 ttd to usd * 12", sample).?.money;
    try testing.expectEqual(@as(f64, 12), b.amount);
    try testing.expectApproxEqRel(@as(f64, 12.0 * 12 / 6.785), b.value, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 1.0 / 6.785), b.rate, 1e-12);
    const c = answer("3 * 10 km to mi", null).?.unit;
    try testing.expectEqual(@as(f64, 30), c.amount);
    try testing.expectApproxEqRel(@as(f64, 30000.0 / 1609.344), c.value, 1e-12);
    try testing.expectEqualStrings("km", c.from);
    try testing.expectEqualStrings("mi", c.to);
    const d = answer("10 km to mi / 2", null).?.unit;
    try testing.expectEqual(@as(f64, 10), d.amount);
    try testing.expectApproxEqRel(@as(f64, 10000.0 / 1609.344 / 2.0), d.value, 1e-12);
    const e = answer("$20 * 3 in eur", sample).?.money;
    try testing.expectEqual(@as(f64, 60), e.amount);
    try testing.expectApproxEqRel(@as(f64, 51.6), e.value, 1e-12);
    try testing.expectEqualStrings("USD", &e.from);
    try testing.expectEqualStrings("EUR", &e.to);
    // Parentheses, functions and precedence, on either side.
    try expectUnit(10000, "(2 + 3) * 2 km to m");
    try expectUnit(2, "(1,500 + 500) m to km");
    try expectUnit(4000, "sqrt(16) km to m");
    try expectUnit(-6.21371192237334, "-(5 + 5) km to mi");
    try expectUnit(36, "2 * 5 m/s to km/h");
    try expectUnit(2 * 6.21371192237334 + 1, "10 km to mi * 2 + 1");
    try expectUnit(6.21371192237334 + 2, "10 km to mi + 1 * 2");
    try expectUnit(6.21371192237334 / 2.0, "10 km to mi / (1 + 1)");
    try expectUnit(6.21371192237334 / 2.0, "10 km to mi/2");
    try expectUnit(18, "10 m/s to km/h / 2");
    try expectUnit(180, "100 c to f - 32");
    try expectUnit(29.5735295625 * 2, "1 fl oz to ml × 2");
    try testing.expectApproxEqRel(
        @as(f64, 24.0 / 6.785),
        answer("12 ttd to usd * (1 + 1)", sample).?.money.value,
        1e-12,
    );
    try testing.expectApproxEqRel(
        @as(f64, 80),
        answer("$100 to € - 6", sample).?.money.value,
        1e-12,
    );
}

test "math that doesn't compute is not a conversion, pending or not" {
    for ([_][]const u8{
        "10 km to mi *",
        "10 km to mi / 0",
        "10 km to mi * 2 3",
        "10 km to mi * foo",
        "10 km to mi * (2",
        "10 km to mi )",
        "10 km to mi * 2 in cm",
        "10 km to * 2",
        "10 km * 2 to mi",
        "35 * km to mi",
        "* 7 km to mi",
        "(35 * 7 km to mi",
        "35 * 7) km to mi",
        "1/0 km to mi",
        "1e308 * 10 km to mi",
        "12 ttd to usd *",
        "12 ttd to usd / 0",
        "12 ttd * 2 to usd",
        "$20 * in eur",
        "$20 * 3 eur",
    }) |q| {
        try testing.expect(answer(q, null) == null);
        try testing.expect(answer(q, sample) == null);
    }
    // No table yet: math that computes waits for one, as a plain amount does.
    try testing.expect(answer("35 * 7 ttd to usd", null).? == .pending);
    try testing.expect(answer("12 ttd to usd * 12", null).? == .pending);
    try testing.expect(answer("$20 * 3 in eur", null).? == .pending);
}

test "tiny unit results keep their digits" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "1e-12 km",
        formatUnit(&buf, answer("1 nm to km", null).?.unit, true),
    );
    try testing.expectEqualStrings(
        "9.09495e-13 TiB",
        formatUnit(&buf, answer("1 b to tib", null).?.unit, true),
    );
    try testing.expectEqualStrings(
        "1e-12",
        formatUnitValue(&buf, answer("1 nm to km", null).?.unit.value, false),
    );
    try testing.expectEqualStrings(
        "0.5 km",
        formatUnit(&buf, answer("500 m to km", null).?.unit, true),
    );
}

test "money and rates read as people write them" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1,234,567.50", formatMoney(&buf, 1234567.5, true));
    try testing.expectEqualStrings("-1,234.00", formatMoney(&buf, -1234, true));
    try testing.expectEqualStrings("999.00", formatMoney(&buf, 999, true));
    try testing.expectEqualStrings("0.00", formatMoney(&buf, 0, true));
    try testing.expectEqualStrings("0.000123", formatMoney(&buf, 0.000123456, true));
    try testing.expectEqualStrings("6.785", formatRate(&buf, 6.785));
    try testing.expectEqualStrings("1500", formatRate(&buf, 1500));
    try testing.expectEqualStrings("0.00001", formatRate(&buf, 0.00001));
    try testing.expectEqualStrings("1", formatRate(&buf, 1));
    const u = answer("1.5 GiB in MB", null).?.unit;
    try testing.expectEqualStrings("1610.612736 MB", formatUnit(&buf, u, true));
    const w = answer("2 km to mm", null).?.unit;
    try testing.expectEqualStrings("2,000,000 mm", formatUnit(&buf, w, true));
    try testing.expectEqualStrings("2000000 mm", formatUnit(&buf, w, false));
}
