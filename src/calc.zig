//! Math typed into the bar, answered as it's typed: + - * / % ^, × and ÷,
//! parentheses, pi and e, and sqrt, sin, cos, tan, ln, log, abs. A query
//! counts as math only with an operator or a function in it, so "42" or
//! "e" alone stay searches. Math around other text is read here too: `lead`
//! the math a text starts with, `carry` the operators after a value, both
//! with numbers grouped by commas ("1,500"), as amounts are written.
const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{ Syntax, Domain, Depth };

/// The most values, and the most pending operators and open parentheses,
/// one expression holds: about 40 levels of nesting. Deeper is not math.
const stack_max = 128;

const Op = enum {
    add,
    sub,
    mul,
    div,
    rem,
    pow,

    fn precedence(o: Op) u8 {
        return switch (o) {
            .add, .sub => 1,
            .mul, .div, .rem => 2,
            .pow => 3,
        };
    }
};

/// How an operator is written: in ASCII, and in UTF-8 if it has another form.
const Spelling = struct { op: Op, ascii: u8, utf8: []const u8 = "" };

/// Every operator as written, the one place they are listed: the parser,
/// `opLen` and `trimOps` all read it.
const spellings = [_]Spelling{
    .{ .op = .pow, .ascii = '^' },
    .{ .op = .mul, .ascii = '*', .utf8 = "×" },
    .{ .op = .div, .ascii = '/', .utf8 = "÷" },
    .{ .op = .rem, .ascii = '%' },
    .{ .op = .add, .ascii = '+' },
    .{ .op = .sub, .ascii = '-', .utf8 = "−" },
};

fn spelling(comptime o: Op) Spelling {
    inline for (spellings) |w| if (w.op == o) return w;
    unreachable;
}

/// The length of the operator `s` starts with, or 0.
pub fn opLen(s: []const u8) usize {
    for (spellings) |w| {
        if (s.len > 0 and s[0] == w.ascii) return 1;
        if (w.utf8.len > 0 and std.mem.startsWith(u8, s, w.utf8)) return w.utf8.len;
    }
    return 0;
}

/// `s` without the operators and spaces it ends with: "2 + 3 *" is "2 + 3".
pub fn trimOps(s: []const u8) []const u8 {
    var end = s.len;
    trim: while (end > 0) {
        if (s[end - 1] == ' ') {
            end -= 1;
            continue;
        }
        for (spellings) |w| {
            if (s[end - 1] == w.ascii) {
                end -= 1;
                continue :trim;
            }
            if (w.utf8.len > 0 and std.mem.endsWith(u8, s[0..end], w.utf8)) {
                end -= w.utf8.len;
                continue :trim;
            }
        }
        break;
    }
    return s[0..end];
}

/// How numbers are written: plain math reads "1500", an amount "1,500" too.
const Numbers = enum { plain, grouped };

const Func = enum { sqrt, sin, cos, tan, ln, log, abs };

/// An opening parenthesis, plain or a function's, and its operand's sign.
const Open = struct { func: ?Func, negate: bool };

const Entry = union(enum) { op: Op, open: Open };

const Word = union(enum) { value: f64, func: Func };

/// Operator precedence with explicit stacks (shunting-yard), evaluated as
/// it reads. The grammar, loosest first: sums, products (* / %), powers
/// (right-associative: 2^3^2 is 2^9), and operands, each a run of signs
/// then a number, a constant, or a parenthesis, plain or a function's.
const Parser = struct {
    s: []const u8,
    numbers: Numbers,
    i: usize = 0,
    /// An operator or a function was seen: this is math, not a name.
    math: bool = false,
    values: [stack_max]f64 = undefined,
    values_len: usize = 0,
    entries: [stack_max]Entry = undefined,
    entries_len: usize = 0,
    /// Open parentheses among `entries`.
    opens: usize = 0,

    fn skip(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }

    fn peek(p: *Parser) u8 {
        p.skip();
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    /// `ascii`, or its UTF-8 form (× and ÷ read as * and /).
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

    /// The whole expression from `i`, ending before the first thing that
    /// can't continue it; `first`, when given, is its first operand.
    fn expr(p: *Parser, first: ?f64) Error!f64 {
        assert(p.values_len == 0 and p.entries_len == 0);
        if (first) |v| try p.pushValue(v) else try p.operand();
        while (try p.operator()) try p.operand();
        assert(p.opens == 0);
        while (p.entries_len > 0) {
            p.entries_len -= 1;
            try p.apply(p.entries[p.entries_len].op);
        }
        assert(p.values_len == 1);
        return p.values[0];
    }

    /// Reads one operand onto `values`, opening any parentheses before it.
    fn operand(p: *Parser) Error!void {
        while (true) {
            var negate = false;
            const minus = comptime spelling(.sub);
            const plus = comptime spelling(.add);
            while (true) {
                if (p.op(minus.ascii, minus.utf8)) {
                    negate = !negate;
                } else if (!p.op(plus.ascii, plus.utf8)) break;
            }
            const ch = p.peek();
            if (ch == '(') {
                p.i += 1;
                try p.open(.{ .func = null, .negate = negate });
                continue;
            }
            const v = if (std.ascii.isDigit(ch) or ch == '.')
                try p.number()
            else if (std.ascii.isAlphabetic(ch)) switch (try p.word()) {
                .value => |constant| constant,
                .func => |f| {
                    try p.open(.{ .func = f, .negate = negate });
                    continue;
                },
            } else return error.Syntax;
            return p.pushValue(if (negate) -v else v);
        }
    }

    /// After an operand, closes parentheses until a binary operator (true:
    /// an operand follows) or the end of the expression (false).
    fn operator(p: *Parser) Error!bool {
        while (true) {
            const o = p.binary() orelse {
                if (p.opens == 0) return false;
                if (!p.op(')', "")) return error.Syntax;
                try p.close();
                continue;
            };
            p.math = true;
            // Apply what binds at least as tightly; powers wait for the right.
            while (p.entries_len > 0) {
                const top = switch (p.entries[p.entries_len - 1]) {
                    .op => |t| t,
                    .open => break,
                };
                if (top.precedence() < o.precedence()) break;
                if (top == .pow and o == .pow) break;
                p.entries_len -= 1;
                try p.apply(top);
            }
            try p.pushEntry(.{ .op = o });
            return true;
        }
    }

    fn binary(p: *Parser) ?Op {
        inline for (spellings) |w| if (p.op(w.ascii, w.utf8)) return w.op;
        return null;
    }

    fn open(p: *Parser, o: Open) Error!void {
        try p.pushEntry(.{ .open = o });
        p.opens += 1;
    }

    /// Applies the operators back to the innermost open parenthesis, then
    /// its function and sign.
    fn close(p: *Parser) Error!void {
        assert(p.opens > 0);
        while (true) {
            assert(p.entries_len > 0);
            p.entries_len -= 1;
            switch (p.entries[p.entries_len]) {
                .op => |o| try p.apply(o),
                .open => |o| {
                    p.opens -= 1;
                    assert(p.values_len > 0);
                    const v = try call(o.func, p.values[p.values_len - 1]);
                    p.values[p.values_len - 1] = if (o.negate) -v else v;
                    return;
                },
            }
        }
    }

    fn apply(p: *Parser, o: Op) Error!void {
        assert(p.values_len >= 2);
        const a = p.values[p.values_len - 2];
        const b = p.values[p.values_len - 1];
        p.values_len -= 1;
        p.values[p.values_len - 1] = switch (o) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) return error.Domain else a / b,
            .rem => if (b == 0) return error.Domain else @rem(a, b),
            .pow => std.math.pow(f64, a, b),
        };
    }

    fn pushValue(p: *Parser, v: f64) Error!void {
        if (p.values_len == stack_max) return error.Depth;
        p.values[p.values_len] = v;
        p.values_len += 1;
    }

    fn pushEntry(p: *Parser, e: Entry) Error!void {
        if (p.entries_len == stack_max) return error.Depth;
        p.entries[p.entries_len] = e;
        p.entries_len += 1;
    }

    fn number(p: *Parser) Error!f64 {
        const start = p.i;
        while (p.i < p.s.len and numeric(p.s[p.i], p.numbers)) p.i += 1;
        // 1e3, 2.5E-4
        const exponent = p.exponentMark();
        if (exponent > 0) {
            p.i += exponent;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        }
        const text = p.s[start..p.i];
        if (std.mem.indexOfScalar(u8, text, ',') == null) {
            return std.fmt.parseFloat(f64, text) catch error.Syntax;
        }
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

    /// The length of an exponent's mark ("e", "E-") at `p.i`, when digits follow
    /// it; else 0.
    fn exponentMark(p: *const Parser) usize {
        const rest = p.s[p.i..];
        if (rest.len < 2) return 0;
        if (rest[0] != 'e' and rest[0] != 'E') return 0;
        if (std.ascii.isDigit(rest[1])) return 1;
        if (rest[1] != '-' and rest[1] != '+') return 0;
        if (rest.len < 3) return 0;
        if (!std.ascii.isDigit(rest[2])) return 0;
        return 2;
    }

    /// A constant, or a function name and its opening parenthesis.
    fn word(p: *Parser) Error!Word {
        const start = p.i;
        while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        const w = p.s[start..p.i];
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "pi")) return .{ .value = std.math.pi };
        if (eq(w, "e")) return .{ .value = std.math.e };
        const f = std.meta.stringToEnum(Func, w) orelse return error.Syntax;
        p.math = true;
        if (!p.op('(', "")) return error.Syntax;
        return .{ .func = f };
    }
};

fn numeric(ch: u8, numbers: Numbers) bool {
    return std.ascii.isDigit(ch) or ch == '.' or ch == '_' or
        (numbers == .grouped and ch == ',');
}

/// `x` through a parenthesis' function, if it has one.
fn call(func: ?Func, x: f64) Error!f64 {
    const f = func orelse return x;
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

/// The value of `query` if it is math, or null if it isn't math at all.
/// Math that can't be computed (1/0, a dangling operator) is null too.
pub fn eval(query: []const u8) ?f64 {
    const s = std.mem.trim(u8, query, " =");
    if (s.len == 0) return null;
    var p: Parser = .{ .s = s, .numbers = .plain };
    const v = p.expr(null) catch return null;
    if (p.peek() != 0 or !p.math) return null;
    if (std.math.isNan(v) or std.math.isInf(v)) return null;
    return v;
}

pub const Lead = struct { value: f64, rest: []const u8 };

/// The math `s` starts with and what follows it: "35 * 7 ttd" is 245,
/// then "ttd". A plain number counts, and numbers may group thousands with
/// commas ("1,500"). Null when `s` doesn't start with math that computes.
pub fn lead(s: []const u8) ?Lead {
    var p: Parser = .{ .s = s, .numbers = .grouped };
    const v = p.expr(null) catch return null;
    if (!std.math.isFinite(v)) return null;
    return .{ .value = v, .rest = s[p.i..] };
}

/// `v` carried through `ops`, the rest of an expression that `v` begins:
/// "* 12 + 1" is v * 12 + 1, by the usual precedence; nothing is `v`
/// itself. Null when `ops` isn't that, or the value can't be computed.
pub fn carry(v: f64, ops: []const u8) ?f64 {
    var p: Parser = .{ .s = ops, .numbers = .grouped };
    const x = p.expr(v) catch return null;
    if (p.peek() != 0 or !std.math.isFinite(x)) return null;
    return x;
}

/// The room `scientific` needs at most: "-1.23456e-308".
pub const scientific_len = "-1.23456e-308".len;

/// The value as the row shows it and the clipboard takes it: whole numbers
/// with thousands separators ("1,048,576"), others to 10 significant digits.
/// When the grouped form doesn't fit `buf`, both forms are `scientific`, so
/// the row and what it copies agree.
pub fn format(buf: []u8, v: f64, grouped: bool) []const u8 {
    assert(buf.len >= scientific_len);
    if (@abs(v) < 1e15 and v == @round(v)) {
        const n: i64 = @intFromFloat(v);
        var digits: [24]u8 = undefined;
        // Below 1e15 a whole number is at most 16 characters.
        const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
        const g = group(buf, d) orelse return scientific(buf, v);
        if (grouped) return g;
        @memcpy(buf[0..d.len], d);
        return buf[0..d.len];
    }
    const s = std.fmt.bufPrint(buf, "{d:.10}", .{v}) catch return scientific(buf, v);
    var end = s.len;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        while (end > 0 and s[end - 1] == '0') end -= 1;
        if (end > 0 and s[end - 1] == '.') end -= 1;
    }
    return s[0..end];
}

/// Six significant digits, "9.09091e-13", for a value too large or too
/// small to write out.
pub fn scientific(buf: []u8, v: f64) []const u8 {
    assert(buf.len >= scientific_len);
    var tmp: [scientific_len]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{e:.5}", .{v}) catch unreachable;
    const at = std.mem.indexOfScalar(u8, s, 'e') orelse s.len;
    const m = std.mem.trimEnd(u8, std.mem.trimEnd(u8, s[0..at], "0"), ".");
    return std.fmt.bufPrint(buf, "{s}{s}", .{ m, s[at..] }) catch unreachable;
}

/// The number `text` ("-1234567.50") in `buf` with its whole part's
/// thousands separated ("-1,234,567.50"); null if it doesn't fit.
pub fn group(buf: []u8, text: []const u8) ?[]const u8 {
    const neg = text.len > 0 and text[0] == '-';
    const body = text[@intFromBool(neg)..];
    const int_end = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    var o: usize = 0;
    if (neg) {
        if (buf.len == 0) return null;
        buf[o] = '-';
        o += 1;
    }
    for (body, 0..) |ch, i| {
        const comma = i < int_end and i > 0 and (int_end - i) % 3 == 0;
        if (o + 1 + @intFromBool(comma) > buf.len) return null;
        if (comma) {
            buf[o] = ',';
            o += 1;
        }
        buf[o] = ch;
        o += 1;
    }
    return buf[0..o];
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

test "a value too long to write out is scientific, never empty" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const big = eval("10^70").?;
    try t.expectEqualStrings("1e70", format(&buf, big, true));
    try t.expectEqualStrings("1e70", format(&buf, big, false));
    try t.expectEqualStrings("-1.23457e-308", scientific(&buf, -1.234567e-308));
    // Where the grouped form doesn't fit, the plain one isn't used either.
    var small: [scientific_len]u8 = undefined;
    try t.expectEqualStrings("1.23457e14", format(&small, 123456789012345, false));
}

test "one operator set: the parser's, at a start and an end" {
    const t = std.testing;
    inline for (.{ "^", "*", "×", "/", "÷", "%", "+", "-", "−" }) |o| {
        try t.expectEqual(@as(usize, o.len), opLen(o ++ " 2"));
        try t.expectEqualStrings("2", trimOps("2 " ++ o));
        try t.expect(carry(2, o ++ " 2") != null);
    }
    try t.expectEqual(@as(usize, 0), opLen("2"));
    try t.expectEqual(@as(usize, 0), opLen(""));
    try t.expectEqualStrings("2 + 3", trimOps("2 + 3 * "));
    try t.expectEqualStrings("10 km to mi", trimOps("10 km to mi × −"));
    try t.expectEqualStrings("", trimOps(" + "));
    try t.expectEqualStrings("café", trimOps("café"));
    var buf: [9]u8 = undefined;
    try t.expectEqualStrings("-1,234.50", group(&buf, "-1234.50").?);
    try t.expectEqual(null, group(buf[0..8], "-1234.50"));
}

test "long or deeply nested input fails cleanly, without deep recursion" {
    const t = std.testing;
    const long = 100_000;
    var buf: [long + 2]u8 = undefined;
    @memset(buf[0..long], '(');
    buf[long] = '1';
    try t.expectEqual(@as(?f64, null), eval(buf[0 .. long + 1]));
    try t.expect(lead(buf[0 .. long + 1]) == null);
    try t.expectEqual(@as(?f64, null), carry(1, buf[0 .. long + 1]));
    // Signs need no stack: a long run of them still reads.
    @memset(buf[0..long], '-');
    buf[long] = '2';
    try t.expectEqual(@as(?f64, 2), lead(buf[0 .. long + 1]).?.value);
    try t.expectEqual(@as(?f64, null), eval(buf[0 .. long + 1]));
    buf[long] = '*';
    buf[long + 1] = '2';
    try t.expectEqual(@as(?f64, null), eval(buf[0 .. long + 2]));
    // A long chain of right-associative powers runs out of stack.
    var pow: [2 * long]u8 = undefined;
    for (0..long) |i| {
        pow[2 * i] = '1';
        pow[2 * i + 1] = '^';
    }
    try t.expectEqual(@as(?f64, null), eval(pow[0 .. 2 * long - 1]));
}

test "nesting within the stack is math as usual" {
    const t = std.testing;
    const depth = 40;
    var buf: [4 * depth + 1]u8 = undefined;
    var n: usize = 0;
    for (0..depth) |_| {
        @memcpy(buf[n..][0..3], "1+(");
        n += 3;
    }
    buf[n] = '1';
    n += 1;
    @memset(buf[n..][0..depth], ')');
    n += depth;
    try t.expectEqual(@as(?f64, depth + 1), eval(buf[0..n]));
    try t.expectEqual(@as(?f64, -4), eval("-(-(1+1))*-2"));
    try t.expectEqual(@as(?f64, 4), eval("-2^2"));
    try t.expectEqual(@as(?f64, 0.25), eval("2^-2"));
    try t.expectEqual(@as(?f64, 2), eval("abs(-sqrt(4))"));
    try t.expectEqual(@as(?f64, -2), eval("-sqrt (4) + 0"));
    try t.expectEqual(@as(?f64, 3), eval("10 - 4 - 3"));
    try t.expectEqual(@as(?f64, 5), eval("40 / 4 / 2"));
}
