//! Math typed into the bar, answered as it's typed: + - * / % ^, × and ÷,
//! parentheses, pi and e, and sqrt, sin, cos, tan, ln, log, abs. A query
//! counts as math only with an operator or a function in it, so "42" or
//! "e" alone stay searches. Conversions (convert.zig) work out the math
//! around them here too: `lead` before the units, `carry` after them.
const std = @import("std");

pub const Error = error{ Syntax, Domain };

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    /// An operator or a function was seen: this is math, not a name.
    math: bool = false,
    /// Numbers may group thousands with commas ("1,500"), as amounts are
    /// written in a conversion.
    commas: bool = false,
    /// The first operand, already worked out: `carry` goes on from it.
    seed: ?f64 = null,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    /// × and ÷ (UTF-8) read as * and /.
    fn op(p: *Parser, comptime ascii: u8, comptime utf8: []const u8) bool {
        p.skip();
        if (p.i < p.s.len and p.s[p.i] == ascii) {
            p.i += 1;
            return true;
        }
        if (utf8.len > 0 and std.mem.startsWith(u8, p.s[p.i..], utf8)) {
            p.i += utf8.len;
            return true;
        }
        return false;
    }

    fn expr(p: *Parser) Error!f64 {
        var v = try p.term();
        while (true) {
            if (p.op('+', "")) {
                p.math = true;
                v += try p.term();
            } else if (p.op('-', "−")) {
                p.math = true;
                v -= try p.term();
            } else return v;
        }
    }

    fn term(p: *Parser) Error!f64 {
        var v = try p.power();
        while (true) {
            if (p.op('*', "×")) {
                p.math = true;
                v *= try p.power();
            } else if (p.op('/', "÷")) {
                p.math = true;
                const d = try p.power();
                if (d == 0) return error.Domain;
                v /= d;
            } else if (p.op('%', "")) {
                p.math = true;
                const d = try p.power();
                if (d == 0) return error.Domain;
                v = @rem(v, d);
            } else return v;
        }
    }

    /// Right-associative: 2^3^2 is 2^9.
    fn power(p: *Parser) Error!f64 {
        const base = p.seed orelse try p.unary();
        p.seed = null;
        if (p.op('^', "")) {
            p.math = true;
            return std.math.pow(f64, base, try p.power());
        }
        return base;
    }

    fn unary(p: *Parser) Error!f64 {
        if (p.op('-', "−")) return -(try p.unary());
        if (p.op('+', "")) return p.unary();
        return p.primary();
    }

    fn primary(p: *Parser) Error!f64 {
        const ch = p.peek();
        if (ch == '(') {
            p.i += 1;
            const v = try p.expr();
            if (!p.op(')', "")) return error.Syntax;
            return v;
        }
        if (std.ascii.isDigit(ch) or ch == '.') return p.number();
        if (std.ascii.isAlphabetic(ch)) return p.word();
        return error.Syntax;
    }

    fn number(p: *Parser) Error!f64 {
        const start = p.i;
        while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or p.s[p.i] == '.' or p.s[p.i] == '_' or (p.commas and p.s[p.i] == ','))) p.i += 1;
        // 1e3, 2.5E-4
        if (p.i < p.s.len and (p.s[p.i] == 'e' or p.s[p.i] == 'E') and p.i + 1 < p.s.len and
            (std.ascii.isDigit(p.s[p.i + 1]) or ((p.s[p.i + 1] == '-' or p.s[p.i + 1] == '+') and p.i + 2 < p.s.len and std.ascii.isDigit(p.s[p.i + 2]))))
        {
            p.i += 2;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        }
        const text = p.s[start..p.i];
        if (std.mem.indexOfScalar(u8, text, ',') == null) return std.fmt.parseFloat(f64, text) catch error.Syntax;
        // "1,500": the commas only group the digits.
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (text) |ch| {
            if (ch == ',') continue;
            if (n == buf.len) return error.Syntax;
            buf[n] = ch;
            n += 1;
        }
        return std.fmt.parseFloat(f64, buf[0..n]) catch error.Syntax;
    }

    fn word(p: *Parser) Error!f64 {
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        const w = p.s[start..p.i];
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "pi")) return std.math.pi;
        if (eq(w, "e")) return std.math.e;
        const f = std.meta.stringToEnum(Func, w) orelse return error.Syntax;
        p.math = true;
        if (!p.op('(', "")) return error.Syntax;
        const x = try p.expr();
        if (!p.op(')', "")) return error.Syntax;
        return switch (f) {
            .sqrt => if (x < 0) error.Domain else @sqrt(x),
            .sin => @sin(x),
            .cos => @cos(x),
            .tan => @tan(x),
            .ln => if (x <= 0) error.Domain else @log(x),
            .log => if (x <= 0) error.Domain else @log10(x),
            .abs => @abs(x),
        };
    }
};

const Func = enum { sqrt, sin, cos, tan, ln, log, abs };

/// The value of `query` if it is math, or null if it isn't math at all.
/// Math that can't be computed (1/0, a dangling operator) is null too.
pub fn eval(query: []const u8) ?f64 {
    const s = std.mem.trim(u8, query, " =");
    if (s.len == 0) return null;
    var p: Parser = .{ .s = s };
    const v = p.expr() catch return null;
    if (p.peek() != 0 or !p.math) return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return v;
}

pub const Lead = struct { value: f64, rest: []const u8 };

/// The math `s` starts with and what follows it: "35 * 7 ttd" is 245,
/// then "ttd". A plain number counts, and numbers may group thousands with
/// commas ("1,500"). Null when `s` doesn't start with math that computes.
pub fn lead(s: []const u8) ?Lead {
    var p: Parser = .{ .s = s, .commas = true };
    const v = p.expr() catch return null;
    if (!std.math.isFinite(v)) return null;
    return .{ .value = v, .rest = s[p.i..] };
}

/// `v` carried through `ops`, the rest of an expression that `v` begins:
/// "* 12 + 1" is v * 12 + 1, by the usual precedence; nothing is `v`
/// itself. Null when `ops` isn't that, or the value can't be computed.
pub fn carry(v: f64, ops: []const u8) ?f64 {
    var p: Parser = .{ .s = ops, .commas = true, .seed = v };
    const x = p.expr() catch return null;
    if (p.peek() != 0 or !std.math.isFinite(x)) return null;
    return x;
}

/// The value as the row shows it and the clipboard takes it: whole numbers
/// with thousands separators ("1,048,576"), others to 10 significant digits.
pub fn format(buf: []u8, v: f64, grouped: bool) []const u8 {
    if (@abs(v) < 1e15 and v == @round(v)) {
        const n: i64 = @intFromFloat(v);
        if (!grouped) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
        var digits: [24]u8 = undefined;
        const d = std.fmt.bufPrint(&digits, "{d}", .{@abs(n)}) catch return "";
        var o: usize = 0;
        if (n < 0) {
            buf[o] = '-';
            o += 1;
        }
        for (d, 0..) |ch, i| {
            if (i > 0 and (d.len - i) % 3 == 0) {
                buf[o] = ',';
                o += 1;
            }
            buf[o] = ch;
            o += 1;
        }
        return buf[0..o];
    }
    const s = std.fmt.bufPrint(buf, "{d:.10}", .{v}) catch return "";
    // Trailing zeros of the fraction, then a bare point.
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
    }
    return s[0..end];
}

test "math is answered, names are not" {
    const t = std.testing;
    try t.expectEqual(@as(?f64, 7), eval("1 + 2 * 3"));
    try t.expectEqual(@as(?f64, 9), eval("(1+2)*3"));
    try t.expectEqual(@as(?f64, 512), eval("2^3^2"));
    try t.expectEqual(@as(?f64, 3), eval("sqrt(9)"));
    try t.expectEqual(@as(?f64, 12), eval("3 × 4"));
    try t.expectEqual(@as(?f64, 2.5), eval("10 ÷ 4"));
    try t.expectEqual(@as(?f64, -4), eval("-2*2"));
    try t.expectEqual(@as(?f64, 2000), eval("2e3 + 0"));
    try t.expectEqual(@as(?f64, 1), eval("7 % 3 ="));
    try t.expectEqual(@as(?f64, null), eval("42"));
    try t.expectEqual(@as(?f64, null), eval("safari"));
    try t.expectEqual(@as(?f64, null), eval("e"));
    try t.expectEqual(@as(?f64, null), eval("1/0"));
    try t.expectEqual(@as(?f64, null), eval("2 +"));
    try t.expectEqual(@as(?f64, null), eval("sqrt(-1)"));
}

test "math before a conversion's units, and after them" {
    const t = std.testing;
    const l = lead("35 * 7 ttd to usd").?;
    try t.expectEqual(@as(f64, 245), l.value);
    try t.expectEqualStrings("ttd to usd", l.rest);
    const k = lead("(2 + 3) * 2km").?;
    try t.expectEqual(@as(f64, 10), k.value);
    try t.expectEqualStrings("km", k.rest);
    try t.expectEqual(@as(f64, 1500.5), lead("1,500.5 m").?.value);
    try t.expectEqual(@as(f64, -1), lead("-1 km").?.value);
    try t.expectEqual(@as(f64, 0.5), lead(".5 km").?.value);
    try t.expect(lead("km to mi") == null);
    try t.expect(lead("35 * ttd") == null);
    try t.expect(lead("(35 * 7 ttd") == null);
    try t.expect(lead("1/0 km") == null);
    try t.expectEqual(@as(?f64, 24), carry(12, "* 2"));
    try t.expectEqual(@as(?f64, 25), carry(12, "* 2 + 1"));
    try t.expectEqual(@as(?f64, 14), carry(12, "+ 1 * 2"));
    try t.expectEqual(@as(?f64, 144), carry(12, "^ 2"));
    try t.expectEqual(@as(?f64, 6), carry(12, "/ (1 + 1)"));
    try t.expectEqual(@as(?f64, 12000), carry(12, "× 1,000"));
    try t.expectEqual(@as(?f64, 12), carry(12, ""));
    try t.expectEqual(@as(?f64, null), carry(12, "*"));
    try t.expectEqual(@as(?f64, null), carry(12, "/ 0"));
    try t.expectEqual(@as(?f64, null), carry(12, "2"));
    try t.expectEqual(@as(?f64, null), carry(12, "* (2"));
    try t.expectEqual(@as(?f64, null), carry(12, "* 2 in cm"));
    try t.expectEqual(@as(?f64, null), carry(std.math.inf(f64), ""));
    // Plain math still reads no commas.
    try t.expectEqual(@as(?f64, null), eval("1,000 * 2"));
}

test "values read as people write them" {
    var buf: [64]u8 = undefined;
    const t = std.testing;
    try t.expectEqualStrings("1,048,576", format(&buf, 1048576, true));
    try t.expectEqualStrings("1048576", format(&buf, 1048576, false));
    try t.expectEqualStrings("-1,000", format(&buf, -1000, true));
    try t.expectEqualStrings("2.5", format(&buf, 2.5, true));
    try t.expectEqualStrings("0.3333333333", format(&buf, 1.0 / 3.0, true));
}
