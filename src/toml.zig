//! A TOML 1.0 subset for config.toml: comments, bare and quoted keys,
//! dotted keys, `[table]`, `[[array.of.tables]]`, basic and literal strings
//! (multiline too), integers, floats, booleans, arrays and inline tables.
//! Datetimes are an error. It reads what `pkgs.formats.toml` writes.
//! Everything is allocated from the arena given to `parse`.
const std = @import("std");
const assert = std.debug.assert;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: *Array,
    table: *Table,

    /// The elements of an array (of values or of tables), else empty.
    pub fn items(v: Value) []const Value {
        return if (v == .array) v.array.items.items else &.{};
    }
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// Written as `[[name]]`: only more `[[name]]` may add to it.
    aot: bool = false,
};

pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,
    kind: Kind,

    /// How it came to be: what may still add to it.
    pub const Kind = enum { implicit, dotted, explicit, inline_ };

    pub fn get(t: *const Table, key: []const u8) ?Value {
        return t.map.get(key);
    }
};

/// Where and why a parse failed. `line` is 1-based.
pub const Diag = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

pub const Error = error{ Syntax, OutOfMemory };

/// The document's top-level table. On `error.Syntax`, `diag` says what.
pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: *Diag) Error!*Table {
    const bom = "\xEF\xBB\xBF";
    var p: Parser = .{ .a = arena, .src = src, .diag = diag };
    if (std.mem.startsWith(u8, src, bom)) p.pos = bom.len;
    const root = try p.newTable(.explicit);
    var cur = root;
    while (true) {
        p.skipBlank();
        const c = p.peek() orelse break;
        if (c == '[') {
            const aot = std.mem.startsWith(u8, src[p.pos..], "[[");
            p.pos += if (aot) 2 else 1;
            const path = try p.keyPath();
            if (!p.eat(']') or (aot and !p.eat(']'))) return p.fail("expected ] to close the table name");
            cur = try p.header(root, path, aot);
        } else {
            try p.keyValue(cur);
        }
        try p.endLine();
    }
    return root;
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    diag: *Diag,

    const max_depth = 64;

    fn fail(p: *Parser, msg: []const u8) error{Syntax} {
        var line: usize = 1;
        for (p.src[0..@min(p.pos, p.src.len)]) |c| line += @intFromBool(c == '\n');
        p.diag.* = .{ .line = line, .msg = msg };
        return error.Syntax;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn eat(p: *Parser, c: u8) bool {
        p.skipWs();
        if (p.peek() != c) return false;
        p.pos += 1;
        return true;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (c != ' ' and c != '\t') break;
    }

    fn skipComment(p: *Parser) void {
        if (p.peek() != '#') return;
        while (p.peek()) |c| : (p.pos += 1) if (c == '\n') break;
    }

    /// Whitespace, comments and line breaks.
    fn skipBlank(p: *Parser) void {
        while (true) {
            p.skipWs();
            p.skipComment();
            const rest = p.src[p.pos..];
            if (std.mem.startsWith(u8, rest, "\r\n")) {
                p.pos += 2;
            } else if (std.mem.startsWith(u8, rest, "\n")) {
                p.pos += 1;
            } else return;
        }
    }

    fn endLine(p: *Parser) Error!void {
        p.skipWs();
        p.skipComment();
        const rest = p.src[p.pos..];
        if (rest.len == 0) return;
        if (std.mem.startsWith(u8, rest, "\r\n")) p.pos += 2 else if (rest[0] == '\n') p.pos += 1 else return p.fail("expected the end of the line");
    }

    fn newTable(p: *Parser, kind: Table.Kind) Error!*Table {
        const t = try p.a.create(Table);
        t.* = .{ .kind = kind };
        return t;
    }

    // ----- keys and tables -----

    fn keyPath(p: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            p.skipWs();
            try parts.append(p.a, try p.key());
            if (!p.eat('.')) break;
        }
        return parts.items;
    }

    fn key(p: *Parser) Error![]const u8 {
        switch (p.peek() orelse return p.fail("expected a key")) {
            '"' => return p.basic(false),
            '\'' => return p.literal(false),
            else => {},
        }
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') break;
        if (p.pos == start) return p.fail("expected a key");
        return p.src[start..p.pos];
    }

    /// The table a `[path]` or `[[path]]` header opens.
    fn header(p: *Parser, root: *Table, path: []const []const u8, aot: bool) Error!*Table {
        var t = root;
        for (path[0 .. path.len - 1]) |k| t = try p.into(t, k, false);
        const k = path[path.len - 1];
        const gop = try t.map.getOrPut(p.a, k);
        if (aot) {
            if (!gop.found_existing) {
                const arr = try p.a.create(Array);
                arr.* = .{ .aot = true };
                gop.value_ptr.* = .{ .array = arr };
            }
            if (gop.value_ptr.* != .array or !gop.value_ptr.array.aot) return p.fail("this name is already used by something that is not an array of tables");
            const nt = try p.newTable(.explicit);
            try gop.value_ptr.array.items.append(p.a, .{ .table = nt });
            return nt;
        }
        if (!gop.found_existing) {
            const nt = try p.newTable(.explicit);
            gop.value_ptr.* = .{ .table = nt };
            return nt;
        }
        if (gop.value_ptr.* != .table or gop.value_ptr.table.kind != .implicit) return p.fail("this table is already defined");
        gop.value_ptr.table.kind = .explicit;
        return gop.value_ptr.table;
    }

    /// The table `k` inside `t` that a longer path goes through, made when
    /// absent. `dotted`: from a dotted key, which only extends tables that
    /// dotted keys made; a header goes through anything but inline tables.
    fn into(p: *Parser, t: *Table, k: []const u8, dotted: bool) Error!*Table {
        const gop = try t.map.getOrPut(p.a, k);
        if (!gop.found_existing) {
            const nt = try p.newTable(if (dotted) .dotted else .implicit);
            gop.value_ptr.* = .{ .table = nt };
            return nt;
        }
        const next: *Table = switch (gop.value_ptr.*) {
            .table => |x| x,
            .array => |arr| blk: {
                if (!arr.aot or dotted) return p.fail("this name is an array, not a table");
                break :blk arr.items.items[arr.items.items.len - 1].table;
            },
            else => return p.fail("this name is a value, not a table"),
        };
        if (next.kind == .inline_ or (dotted and next.kind != .dotted)) return p.fail("this table is closed: it cannot be added to here");
        return next;
    }

    fn keyValue(p: *Parser, t: *Table) Error!void {
        const path = try p.keyPath();
        if (!p.eat('=')) return p.fail("expected = after the key");
        p.skipWs();
        try p.put(t, path, try p.value());
    }

    /// Sets the dotted key `path` of `t` to `v`.
    fn put(p: *Parser, t: *Table, path: []const []const u8, v: Value) Error!void {
        var dest = t;
        for (path[0 .. path.len - 1]) |k| dest = try p.into(dest, k, true);
        const gop = try dest.map.getOrPut(p.a, path[path.len - 1]);
        if (gop.found_existing) return p.fail("this key is already set");
        gop.value_ptr.* = v;
    }

    // ----- values -----

    /// An array or an inline table still being read.
    const Open = struct {
        container: Value,
        /// In an inline table: the key of the value being read.
        path: []const []const u8 = &.{},
    };

    /// One value. Arrays and inline tables nest on an explicit stack, at
    /// most `max_depth` values deep.
    fn value(p: *Parser) Error!Value {
        var opens: [max_depth]Open = undefined;
        var len: usize = 0;
        while (true) {
            if (len == max_depth) return p.fail("arrays and inline tables nest too deeply");
            var v: Value = switch (p.peek() orelse return p.fail("expected a value")) {
                '"' => .{ .string = try p.basic(true) },
                '\'' => .{ .string = try p.literal(true) },
                '[', '{' => |c| blk: {
                    p.pos += 1;
                    opens[len] = .{ .container = try p.container(c) };
                    len += 1;
                    const empty = (try p.advance(&opens[len - 1], true)) orelse continue;
                    len -= 1;
                    break :blk empty;
                },
                else => try p.scalar(),
            };
            // `v` is whole: add it to its container, closing those it ends.
            while (len > 0) {
                const top = &opens[len - 1];
                switch (top.container) {
                    .array => |arr| try arr.items.append(p.a, v),
                    .table => |t| try p.put(t, top.path, v),
                    else => unreachable,
                }
                v = (try p.advance(top, false)) orelse break;
                len -= 1;
            }
            if (len == 0) return v;
        }
    }

    fn container(p: *Parser, open: u8) Error!Value {
        if (open == '{') return .{ .table = try p.newTable(.inline_) };
        assert(open == '[');
        const arr = try p.a.create(Array);
        arr.* = .{};
        return .{ .array = arr };
    }

    /// Reads up to `o`'s next value, or past its end (`first`: none read
    /// yet). Null when a value follows, else the closed container.
    fn advance(p: *Parser, o: *Open, first: bool) Error!?Value {
        const array = o.container == .array;
        assert(array or o.container == .table);
        const close: u8 = if (array) ']' else '}';
        if (!first) {
            p.skipBlank();
            if (p.peek() == ',') {
                p.pos += 1;
            } else if (p.peek() != close) {
                if (array) return p.fail("expected , or ] in the array");
                return p.fail("expected , or } in the inline table");
            }
        }
        p.skipBlank();
        if (p.peek() == close) {
            p.pos += 1;
            return o.container;
        }
        if (array) return null;
        o.path = try p.keyPath();
        if (!p.eat('=')) return p.fail("expected = after the key");
        p.skipWs();
        return null;
    }

    fn scalar(p: *Parser) Error!Value {
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) if (std.mem.indexOfScalar(u8, " \t\r\n,]}#", c) != null) break;
        const tok = p.src[start..p.pos];
        p.pos = start;
        if (tok.len == 0) return p.fail("expected a value");
        if (std.mem.eql(u8, tok, "true")) return p.done(tok, .{ .boolean = true });
        if (std.mem.eql(u8, tok, "false")) return p.done(tok, .{ .boolean = false });
        if (std.mem.indexOfScalar(u8, tok, ':') != null or (tok.len >= 10 and tok[4] == '-' and tok[7] == '-' and std.ascii.isDigit(tok[0])))
            return p.fail("dates and times are not supported");
        return p.done(tok, try p.number(tok));
    }

    fn done(p: *Parser, tok: []const u8, v: Value) Value {
        p.pos += tok.len;
        return v;
    }

    fn number(p: *Parser, tok: []const u8) Error!Value {
        const bad = "not a valid value (strings need quotes)";
        var body = tok;
        const neg = body[0] == '-';
        if (body[0] == '+' or neg) body = body[1..];
        if (std.mem.eql(u8, body, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (std.mem.eql(u8, body, "nan")) return .{ .float = std.math.nan(f64) };
        if (body.len == 0 or !std.ascii.isDigit(body[0])) return p.fail(bad);
        // `_` goes between digits only.
        for (body, 0..) |c, i| if (c == '_' and (i == 0 or i + 1 == body.len or !std.ascii.isHex(body[i - 1]) or !std.ascii.isHex(body[i + 1]))) return p.fail(bad);
        const prefixed = body.len > 2 and body[0] == '0' and std.mem.indexOfScalar(u8, "xob", body[1]) != null;
        if (prefixed) {
            if (tok[0] == '+' or neg) return p.fail("a hex, octal or binary number takes no sign");
            return .{ .int = std.fmt.parseInt(i64, body, 0) catch return p.fail(bad) };
        }
        if (std.mem.indexOfAny(u8, body, ".eE") == null) {
            if (body.len > 1 and body[0] == '0') return p.fail("an integer takes no leading zeros");
            return .{ .int = std.fmt.parseInt(i64, tok, 0) catch return p.fail("not a valid integer (or it does not fit in 64 bits)") };
        }
        // A digit on both sides of the point, and after `e`.
        for (body, 0..) |c, i| switch (c) {
            '.' => if (i + 1 == body.len or !std.ascii.isDigit(body[i + 1])) return p.fail(bad),
            'e', 'E' => if (i + 1 == body.len or body[i + 1] == '.') return p.fail(bad),
            else => {},
        };
        return .{ .float = std.fmt.parseFloat(f64, tok) catch return p.fail(bad) };
    }

    // ----- strings -----

    fn control(c: u8) bool {
        return (c < 0x20 and c != '\t') or c == 0x7f;
    }

    /// A `'literal'` or (`multi`, when it opens with three) `'''literal'''`.
    fn literal(p: *Parser, allow_multi: bool) Error![]const u8 {
        const multi = allow_multi and std.mem.startsWith(u8, p.src[p.pos..], "'''");
        p.pos += if (multi) 3 else 1;
        if (multi) p.skipFirstNewline();
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) {
            if (c == '\'') {
                if (!multi) {
                    p.pos += 1;
                    return p.src[start .. p.pos - 1];
                }
                const quotes = p.run('\'');
                if (quotes >= 3) {
                    if (quotes > 5) return p.fail("too many quotes closing the string");
                    const end = p.pos + quotes - 3;
                    p.pos += quotes;
                    return p.src[start..end];
                }
                p.pos += quotes - 1;
            } else if (c == '\n' and !multi) {
                break;
            } else if (control(c) and c != '\n' and c != '\r') {
                return p.fail("a control character in the string");
            }
        }
        return p.fail("the string is not closed");
    }

    /// A `"basic"` or `"""basic"""` string, escapes decoded.
    fn basic(p: *Parser, allow_multi: bool) Error![]const u8 {
        const multi = allow_multi and std.mem.startsWith(u8, p.src[p.pos..], "\"\"\"");
        p.pos += if (multi) 3 else 1;
        if (multi) p.skipFirstNewline();
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |c| {
            switch (c) {
                '"' => {
                    if (!multi) {
                        p.pos += 1;
                        return out.items;
                    }
                    const quotes = p.run('"');
                    if (quotes >= 3) {
                        if (quotes > 5) return p.fail("too many quotes closing the string");
                        try out.appendNTimes(p.a, '"', quotes - 3);
                        p.pos += quotes;
                        return out.items;
                    }
                    try out.appendNTimes(p.a, '"', quotes);
                    p.pos += quotes;
                },
                '\\' => {
                    p.pos += 1;
                    if (multi and p.lineEnding()) continue;
                    try p.escape(&out);
                },
                '\n' => {
                    if (!multi) break;
                    try out.append(p.a, c);
                    p.pos += 1;
                },
                '\r' => {
                    if (!multi) break;
                    if (!std.mem.startsWith(u8, p.src[p.pos..], "\r\n")) return p.fail("a control character in the string");
                    p.pos += 1;
                },
                else => {
                    if (control(c)) return p.fail("a control character in the string");
                    try out.append(p.a, c);
                    p.pos += 1;
                },
            }
        }
        return p.fail("the string is not closed");
    }

    /// How many `q` start here.
    fn run(p: *Parser, q: u8) usize {
        var n: usize = 0;
        while (p.pos + n < p.src.len and p.src[p.pos + n] == q) n += 1;
        return n;
    }

    fn skipFirstNewline(p: *Parser) void {
        if (std.mem.startsWith(u8, p.src[p.pos..], "\r\n")) p.pos += 2 else if (p.peek() == '\n') p.pos += 1;
    }

    /// After a `\` in a multiline string: spaces, then a line break, then
    /// all the whitespace up to the next word is dropped.
    fn lineEnding(p: *Parser) bool {
        var i = p.pos;
        while (i < p.src.len and (p.src[i] == ' ' or p.src[i] == '\t')) i += 1;
        if (i >= p.src.len or (p.src[i] != '\n' and p.src[i] != '\r')) return false;
        while (i < p.src.len and std.mem.indexOfScalar(u8, " \t\r\n", p.src[i]) != null) i += 1;
        p.pos = i;
        return true;
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        const c = p.peek() orelse return p.fail("the string is not closed");
        p.pos += 1;
        const simple: ?u8 = switch (c) {
            'b' => 8,
            't' => '\t',
            'n' => '\n',
            'f' => 12,
            'r' => '\r',
            'e' => 27,
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (simple) |s| return out.append(p.a, s);
        const digits: usize = switch (c) {
            'x' => 2,
            'u' => 4,
            'U' => 8,
            else => return p.fail("unknown escape in the string"),
        };
        if (p.pos + digits > p.src.len) return p.fail("the escape is cut short");
        const cp = std.fmt.parseInt(u21, p.src[p.pos..][0..digits], 16) catch return p.fail("the escape is not a valid code point");
        if (!std.unicode.utf8ValidCodepoint(cp)) return p.fail("the escape is not a valid code point");
        p.pos += digits;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail("the escape is not a valid code point");
        try out.appendSlice(p.a, buf[0..n]);
    }
};

// ----- tests -----

const testing = std.testing;

fn parseOk(arena: std.mem.Allocator, src: []const u8) !*Table {
    var d: Diag = .{};
    return parse(arena, src, &d) catch |e| {
        std.debug.print("line {d}: {s}\n", .{ d.line, d.msg });
        return e;
    };
}

fn expectFail(src: []const u8, line: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .{};
    try testing.expectError(error.Syntax, parse(arena.allocator(), src, &d));
    testing.expectEqual(line, d.line) catch |e| {
        std.debug.print("{s}\n", .{d.msg});
        return e;
    };
    try testing.expect(d.msg.len > 0);
}

test "scalars" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\s = "text"
        \\lit = 'C:\path'
        \\yes = true
        \\no = false
        \\n = 42
        \\pos = +7
        \\neg = -17
        \\big = 1_000_000
        \\hex = 0xDEAD_beef
        \\oct = 0o755
        \\bin = 0b1101
        \\f = 3.14
        \\exp = 5e+2
        \\fneg = -0.5e-1
        \\inf = inf
        \\ninf = -inf
        \\nan = nan
    );
    try testing.expectEqualStrings("text", r.get("s").?.string);
    try testing.expectEqualStrings("C:\\path", r.get("lit").?.string);
    try testing.expect(r.get("yes").?.boolean and !r.get("no").?.boolean);
    try testing.expectEqual(@as(i64, 42), r.get("n").?.int);
    try testing.expectEqual(@as(i64, 7), r.get("pos").?.int);
    try testing.expectEqual(@as(i64, -17), r.get("neg").?.int);
    try testing.expectEqual(@as(i64, 1_000_000), r.get("big").?.int);
    try testing.expectEqual(@as(i64, 0xDEADBEEF), r.get("hex").?.int);
    try testing.expectEqual(@as(i64, 0o755), r.get("oct").?.int);
    try testing.expectEqual(@as(i64, 13), r.get("bin").?.int);
    try testing.expectEqual(@as(f64, 3.14), r.get("f").?.float);
    try testing.expectEqual(@as(f64, 500), r.get("exp").?.float);
    try testing.expectEqual(@as(f64, -0.05), r.get("fneg").?.float);
    try testing.expect(std.math.isPositiveInf(r.get("inf").?.float));
    try testing.expect(std.math.isNegativeInf(r.get("ninf").?.float));
    try testing.expect(std.math.isNan(r.get("nan").?.float));
}

test "string escapes and multiline strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\esc = "tab\there \"quoted\" back\\slash \u00e9 \U0001F600 \x41"
        \\multi = """
        \\Roses are red
        \\Violets are blue"""
        \\folded = """The quick \
        \\
        \\      brown fox"""
        \\quotes = """She said ""hi"""""
        \\raw = '''
        \\C:\no\escapes
        \\here'''
        \\rawq = '''it''s'''
        \\empty = ""
        \\emptylit = ''
    );
    try testing.expectEqualStrings("tab\there \"quoted\" back\\slash \u{e9} \u{1F600} A", r.get("esc").?.string);
    try testing.expectEqualStrings("Roses are red\nViolets are blue", r.get("multi").?.string);
    try testing.expectEqualStrings("The quick brown fox", r.get("folded").?.string);
    try testing.expectEqualStrings("She said \"\"hi\"\"", r.get("quotes").?.string);
    try testing.expectEqualStrings("C:\\no\\escapes\nhere", r.get("raw").?.string);
    try testing.expectEqualStrings("it''s", r.get("rawq").?.string);
    try testing.expectEqualStrings("", r.get("empty").?.string);
    try testing.expectEqualStrings("", r.get("emptylit").?.string);
}

test "comments, CRLF, a BOM and no final newline" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(), "\xEF\xBB\xBF# top\r\na = 1 # one\r\n\r\n[t] # table\r\nb = \"x#y\"\r\nc = 3");
    try testing.expectEqual(@as(i64, 1), r.get("a").?.int);
    try testing.expectEqualStrings("x#y", r.get("t").?.table.get("b").?.string);
    try testing.expectEqual(@as(i64, 3), r.get("t").?.table.get("c").?.int);
}

test "arrays: multi-line, trailing comma, comments, nesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\empty = []
        \\strs = ["a", "b"]
        \\multi = [
        \\  "/x/one", # first
        \\  "/x/two",
        \\]
        \\nested = [[1, 2], ["a"]]
        \\mixed = [1, "two", 3.0, true]
    );
    try testing.expectEqual(@as(usize, 0), r.get("empty").?.items().len);
    try testing.expectEqual(@as(usize, 2), r.get("strs").?.items().len);
    try testing.expectEqualStrings("/x/two", r.get("multi").?.items()[1].string);
    try testing.expectEqual(@as(usize, 2), r.get("multi").?.items().len);
    try testing.expectEqual(@as(i64, 2), r.get("nested").?.items()[0].items()[1].int);
    try testing.expectEqual(@as(usize, 4), r.get("mixed").?.items().len);
}

test "inline tables" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\p = { x = 1, y = "two", z.deep = true }
        \\e = {}
        \\list = [{ name = "a" }, { name = "b", keyword = "bb" }]
    );
    const p = r.get("p").?.table;
    try testing.expectEqual(@as(i64, 1), p.get("x").?.int);
    try testing.expectEqualStrings("two", p.get("y").?.string);
    try testing.expect(p.get("z").?.table.get("deep").?.boolean);
    try testing.expectEqual(@as(usize, 0), r.get("e").?.table.map.count());
    try testing.expectEqualStrings("bb", r.get("list").?.items()[1].table.get("keyword").?.string);
}

test "tables, dotted and quoted keys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\top.dotted . key = 1
        \\"quoted key" = 2
        \\'lit key' = 3
        \\bare-key_1 = 4
        \\"a.b" = 5
        \\[a.b.c]
        \\v = 1
        \\[a]
        \\w = 2
        \\[ "sp ace" . x ]
        \\y = 3
        \\[fruit]
        \\apple.color = "red"
        \\[fruit.apple.texture]
        \\smooth = true
    );
    try testing.expectEqual(@as(i64, 1), r.get("top").?.table.get("dotted").?.table.get("key").?.int);
    try testing.expectEqual(@as(i64, 2), r.get("quoted key").?.int);
    try testing.expectEqual(@as(i64, 3), r.get("lit key").?.int);
    try testing.expectEqual(@as(i64, 4), r.get("bare-key_1").?.int);
    try testing.expectEqual(@as(i64, 5), r.get("a.b").?.int);
    const a = r.get("a").?.table;
    try testing.expectEqual(@as(i64, 1), a.get("b").?.table.get("c").?.table.get("v").?.int);
    try testing.expectEqual(@as(i64, 2), a.get("w").?.int);
    try testing.expectEqual(@as(i64, 3), r.get("sp ace").?.table.get("x").?.table.get("y").?.int);
    const apple = r.get("fruit").?.table.get("apple").?.table;
    try testing.expectEqualStrings("red", apple.get("color").?.string);
    try testing.expect(apple.get("texture").?.table.get("smooth").?.boolean);
}

test "arrays of tables, with sub-tables of the last one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\[[q]]
        \\name = "one"
        \\[q.extra]
        \\n = 1
        \\[[q]]
        \\name = "two"
        \\[[q]]
        \\[[x.y]]
        \\k = 1
        \\[[x.y]]
        \\k = 2
    );
    const q = r.get("q").?.items();
    try testing.expectEqual(@as(usize, 3), q.len);
    try testing.expectEqualStrings("one", q[0].table.get("name").?.string);
    try testing.expectEqual(@as(i64, 1), q[0].table.get("extra").?.table.get("n").?.int);
    try testing.expectEqualStrings("two", q[1].table.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), q[2].table.map.count());
    const y = r.get("x").?.table.get("y").?.items();
    try testing.expectEqual(@as(i64, 2), y[1].table.get("k").?.int);
}

test "what pkgs.formats.toml writes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try parseOk(arena.allocator(),
        \\hotkey = "cmd_space"
        \\open_searches_in_browser = false
        \\pop_to_root_seconds = 90
        \\suggestions = true
        \\
        \\[apps]
        \\extra_dirs = ["/Applications/Nix Apps", "/Users/me/Applications"]
        \\
        \\[clipboard]
        \\enabled = true
        \\exclude_apps = ["com.bitwarden.desktop", "com.yubico.yubioath"]
        \\max_entries = 1000
        \\paste_plain_text = true
        \\retention_days = 7
        \\
        \\[[quicklinks]]
        \\keyword = "ddg"
        \\name = "DuckDuckGo"
        \\url = "https://duckduckgo.com/?q={argument}"
        \\
        \\[[quicklinks]]
        \\name = "Claude"
        \\url = "https://claude.ai/new?q={argument}"
        \\
        \\[script_commands]
        \\dirs = []
        \\
        \\[sync]
        \\token_file = "/run/secrets/nanolight-token"
        \\url = "http://100.64.0.1:8890"
    );
    try testing.expectEqualStrings("cmd_space", r.get("hotkey").?.string);
    try testing.expectEqual(@as(usize, 2), r.get("apps").?.table.get("extra_dirs").?.items().len);
    try testing.expectEqualStrings("com.yubico.yubioath", r.get("clipboard").?.table.get("exclude_apps").?.items()[1].string);
    try testing.expectEqual(@as(usize, 2), r.get("quicklinks").?.items().len);
    try testing.expectEqualStrings("https://duckduckgo.com/?q={argument}", r.get("quicklinks").?.items()[0].table.get("url").?.string);
    try testing.expectEqual(@as(usize, 0), r.get("script_commands").?.table.get("dirs").?.items().len);
    try testing.expectEqualStrings("http://100.64.0.1:8890", r.get("sync").?.table.get("url").?.string);
}

test "errors carry the line" {
    try expectFail("a = 1\nb = \n", 2);
    try expectFail("a = 1\na = 2\n", 2);
    try expectFail("a = 1\n\n\nb = 1979-05-27\n", 4);
    try expectFail("t = 07:32:00\n", 1);
    try expectFail("a = 1\ns = \"open\n", 2);
    try expectFail("s = \"\"\"never\nends\n", 3);
    try expectFail("[t]\nx = 1\n[t]\n", 3);
    try expectFail("x\n", 1);
    try expectFail("a = 1 b = 2\n", 1);
    try expectFail("a = [1, 2\nb = 1\n", 2);
    try expectFail("a = [1 2]\n", 1);
    try expectFail("a = {x = 1\n", 2);
    try expectFail("a = word\n", 1);
    try expectFail("a = 012\n", 1);
    try expectFail("a = 1__0\n", 1);
    try expectFail("a = _1\n", 1);
    try expectFail("a = 1.\n", 1);
    try expectFail("a = .5\n", 1);
    try expectFail("a = 99999999999999999999\n", 1);
    try expectFail("a = \"bad \\q\"\n", 1);
    try expectFail("a = \"\\uD800\"\n", 1);
    try expectFail("[a\nx = 1\n", 1);
    try expectFail("[[a]\n", 1);
    try expectFail("= 1\n", 1);
    try expectFail("a = 'x\n", 1);
    for ([_][]const u8{ "[", "{a = " }) |open| {
        const src = try testing.allocator.alloc(u8, 4 + open.len * 100_000);
        defer testing.allocator.free(src);
        @memcpy(src[0..4], "a = ");
        for (0..100_000) |i| @memcpy(src[4 + i * open.len ..][0..open.len], open);
        try expectFail(src, 1);
    }
}

test "structure errors: closed and clashing tables" {
    // A value, then a table of that name.
    try expectFail("a = 1\n[a]\n", 2);
    try expectFail("a = 1\n[a.b]\n", 2);
    // A static array or inline table is closed.
    try expectFail("a = [{x = 1}]\n[[a]]\n", 2);
    try expectFail("a = {x = 1}\n[a.y]\n", 2);
    try expectFail("a = {x = 1}\na.y = 2\n", 2);
    // Headers and dotted keys do not extend each other's tables.
    try expectFail("[f]\napple.color = 1\n[f.apple]\n", 3);
    try expectFail("[a.b]\n[a]\nb.c = 1\n", 3);
    // A table and an array of tables of one name.
    try expectFail("[[a]]\n[a]\n", 2);
    try expectFail("[a]\n[[a]]\n", 2);
}

test "nesting at the depth limit reads, past it fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const depth = Parser.max_depth;
    var buf: [4 + 2 * (depth + 1) + 1]u8 = undefined;
    @memcpy(buf[0..4], "a = ");
    @memset(buf[4..][0..depth], '[');
    @memset(buf[4 + depth ..][0..depth], ']');
    var r = try parseOk(arena.allocator(), buf[0 .. 4 + 2 * depth]);
    var v = r.get("a").?;
    for (1..depth) |_| v = v.items()[0];
    try testing.expectEqual(@as(usize, 0), v.items().len);
    // One more level, or a value in the deepest array, is too deep.
    @memset(buf[4..][0 .. depth + 1], '[');
    @memset(buf[4 + depth + 1 ..][0 .. depth + 1], ']');
    try expectFail(buf[0 .. 4 + 2 * (depth + 1)], 1);
    @memset(buf[4..][0..depth], '[');
    buf[4 + depth] = '1';
    try expectFail(buf[0 .. 4 + 2 * depth + 1], 1);

    // Inline tables count the same: `{ b = ` per level.
    var tbuf: [4 + 6 * depth + 2 * depth]u8 = undefined;
    var n: usize = 0;
    @memcpy(tbuf[0..4], "a = ");
    n = 4;
    for (0..depth - 1) |_| {
        @memcpy(tbuf[n..][0..6], "{ b = ");
        n += 6;
    }
    tbuf[n] = '1';
    n += 1;
    @memset(tbuf[n..][0 .. depth - 1], '}');
    n += depth - 1;
    r = try parseOk(arena.allocator(), tbuf[0..n]);
    v = r.get("a").?;
    for (1..depth) |_| v = v.table.get("b").?;
    try testing.expectEqual(@as(i64, 1), v.int);
}

test "a long run of brackets fails cleanly" {
    const long = 100_000;
    var buf: [4 + long]u8 = undefined;
    @memcpy(buf[0..4], "a = ");
    @memset(buf[4..], '[');
    try expectFail(&buf, 1);
    @memset(buf[4..], '{');
    try expectFail(&buf, 1);
}
