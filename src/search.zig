//! Text: how well a query matches a name, and which of its bytes matched
//! (drawn brighter in the row); cutting UTF-8; escaping for URLs.
//! Case-insensitive (ASCII letters fold), no allocation: it runs on every
//! name at every keystroke, so it stays a few loops. ASCII text is read a
//! byte at a time, other text a codepoint at a time, by the same code.
//!
//! Tiers, best first: the whole name, its start, a word's start, the
//! words' initials ("vsc" for Visual Studio Code), anywhere inside it,
//! then the letters in order (a subsequence), worse the more they spread,
//! and last, typos: a name or a word in it that begins like the query but
//! for a letter or two swapped, wrong, missing or extra ("chorme" for
//! Chrome, "calandar" for Calendar). Text that isn't all ASCII has the
//! start, inside and in-order tiers only.
const std = @import("std");
const assert = std.debug.assert;

const tier = struct {
    const exact = 1000;
    const start = 900;
    const word = 800;
    const initials = 750;
    const inside = 600;
    const in_order = 300;
    const typo = 260;
};
/// A longer name, or a match further into it, lowers a tier by up to this.
const max_slack = 60;
/// Letters in order: one on a word's start or right after the last one
/// scores more; a gap before one costs up to `max_gap`.
const word_bonus = 12;
const next_bonus = 8;
const max_gap = 20;
/// Each edit a typo needs costs this.
const typo_cost = 70;
/// A word for a thing (a pane's, a command's) matches a little lower than
/// its name, and lights nothing in the name shown.
const keyword_cost = 40;

/// Below this a match is letters in order or a typo: too loose for a
/// short name that would list under nearly every query (a command, a pane).
pub const min_loose = 500;
/// `min_loose` for a long text: slack and the place a match starts lower
/// one inside it to 480 (`tier.inside` - 2 * `max_slack`), still kept.
pub const min_loose_long = 450;
/// A path typed out in full: above every tier.
pub const exact_path = 2000;

/// Up to this many matched bytes are kept for highlighting.
const max_hits = 32;
/// Hits are bytes: only a name's first 256 can be lit.
const Hit = u8;

pub const Match = struct {
    score: i32,
    /// The bytes of the name the query matched, in order.
    hits: [max_hits]Hit = undefined,
    n: u8 = 0,

    pub fn matched(m: *const Match) []const u8 {
        return m.hits[0..m.n];
    }

    fn run(points: i32, from: usize, len: usize) Match {
        var m: Match = .{ .score = points };
        for (from..from + len) |i| m.add(i);
        return m;
    }

    /// Past `max_hits`, or a byte past what a `Hit` holds, is not lit.
    fn add(m: *Match, i: usize) void {
        if (m.n < max_hits and i <= std.math.maxInt(Hit)) {
            m.hits[m.n] = @intCast(i);
            m.n += 1;
        }
    }
};

fn capped(n: usize, max: usize) i32 {
    return @intCast(@min(n, max));
}

/// What a long name costs a loose tier (in order, typos).
fn spread(len: usize) i32 {
    return @intCast(@min(len, max_slack) / 4);
}

// ----- characters -----

/// How text is read: a byte at a time when all of it is ASCII (the usual
/// case, and the fast one), else a codepoint at a time.
const Mode = enum { ascii, utf8 };

const Char = struct { cp: u21, len: usize };

fn hasNonAscii(s: []const u8) bool {
    for (s) |b| if (b >= 0x80) return true;
    return false;
}

fn modeOf(a: []const u8, b: []const u8) Mode {
    return if (hasNonAscii(a) or hasNonAscii(b)) .utf8 else .ascii;
}

/// The character at byte `i < s.len`, or null where `s` is not UTF-8.
inline fn charAt(comptime mode: Mode, s: []const u8, i: usize) ?Char {
    return switch (mode) {
        .ascii => .{ .cp = s[i], .len = 1 },
        .utf8 => decodeAt(s, i),
    };
}

fn decodeAt(s: []const u8, i: usize) ?Char {
    if (i >= s.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (i + len > s.len) return null;
    const cp = std.unicode.utf8Decode(s[i..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// Where the character before byte `i > 0` starts.
fn charBefore(comptime mode: Mode, s: []const u8, i: usize) usize {
    var p = i - 1;
    if (mode == .ascii) return p;
    while (p > 0 and s[p] & 0xC0 == 0x80) p -= 1;
    return p;
}

/// How far a search moves on from byte `i`.
fn step(comptime mode: Mode, s: []const u8, i: usize) usize {
    return switch (mode) {
        .ascii => 1,
        .utf8 => std.unicode.utf8ByteSequenceLength(s[i]) catch 1,
    };
}

fn fold(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + ('a' - 'A');
    return cp;
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x9FFF) or (cp >= 0xF900 and cp <= 0xFAFF);
}

/// Whether `s` has a CJK ideograph (a name a pinyin key can spell).
pub fn hasCjk(s: []const u8) bool {
    var i: usize = 0;
    while (decodeAt(s, i)) |d| : (i += d.len) if (isCjk(d.cp)) return true;
    return false;
}

fn isSeparator(cp: u21) bool {
    return cp == ' ' or cp == '-' or cp == '_' or cp == '.' or cp == '/' or cp == '(';
}

/// Whether byte `i` of `name` starts a word: the name's start, after a
/// space or punctuation, a capital after a lowercase letter (FaceTime),
/// or a CJK ideograph.
fn wordStart(comptime mode: Mode, name: []const u8, i: usize) bool {
    if (i == 0) return true;
    const ch = charAt(mode, name, i) orelse return false;
    const prev = charAt(mode, name, charBefore(mode, name, i)) orelse return true;
    if (isSeparator(prev.cp)) return ch.cp != ' ';
    if (ch.cp < 0x80 and prev.cp < 0x80) return std.ascii.isUpper(@intCast(ch.cp)) and
        std.ascii.isLower(@intCast(prev.cp));
    return isCjk(ch.cp);
}

fn startsWithIn(comptime mode: Mode, hay: []const u8, needle: []const u8) bool {
    // Folding keeps a character's length, so a longer needle never fits.
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i < needle.len) {
        const h = charAt(mode, hay, i) orelse return false;
        const n = charAt(mode, needle, i) orelse return false;
        if (fold(h.cp) != fold(n.cp)) return false;
        i += n.len;
    }
    return true;
}

/// Case-insensitive prefix on whole characters (ASCII letters folded).
pub fn startsWithFold(hay: []const u8, needle: []const u8) bool {
    return switch (modeOf(hay, needle)) {
        inline else => |mode| startsWithIn(mode, hay, needle),
    };
}

fn indexOfIn(comptime mode: Mode, hay: []const u8, needle: []const u8, from: usize) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += step(mode, hay, i)) {
        if (startsWithIn(mode, hay[i..], needle)) return i;
    }
    return null;
}

/// `s` cut to at most `max` bytes, on a character boundary.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return s[0..n];
}

/// `s` percent-encoded into `w`: letters, digits, `-_.~` and the bytes in
/// `how.keep` as they are, a space as `+` when `how.plus` (query values
/// only; a path needs `%20`), any other byte as `%XX`. Each byte goes in
/// whole: it stops at the first that does not fit.
pub fn percentEncode(
    w: *std.Io.Writer,
    s: []const u8,
    how: struct { keep: []const u8 = "", plus: bool = false },
) std.Io.Writer.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or
            std.mem.indexOfScalar(u8, "-_.~", ch) != null or
            std.mem.indexOfScalar(u8, how.keep, ch) != null;
        var unit: [3]u8 = .{ ch, 0, 0 };
        var len: usize = 1;
        if (ch == ' ' and how.plus) {
            unit[0] = '+';
        } else if (!plain) {
            unit = .{ '%', hex[ch >> 4], hex[ch & 0xF] };
            len = 3;
        }
        const dest = try w.writableSliceGreedy(len);
        @memcpy(dest[0..len], unit[0..len]);
        w.advance(len);
    }
}

// ----- scores -----

/// The match of `query` in `name`, or null when its letters aren't all
/// there in order. Spaces in the query are ignored past its first word.
pub fn score(query_in: []const u8, name: []const u8) ?Match {
    const query = std.mem.trim(u8, query_in, " ");
    if (query.len == 0 or name.len == 0) return null;
    return switch (modeOf(query, name)) {
        inline else => |mode| scoreIn(mode, query, name),
    };
}

/// `score` for text known to be ASCII (a pinyin key): the query as it is,
/// read a byte at a time.
pub fn scoreAscii(query: []const u8, name: []const u8) ?Match {
    return scoreIn(.ascii, query, name);
}

fn scoreIn(comptime mode: Mode, query: []const u8, name: []const u8) ?Match {
    const slack = capped(name.len -| query.len, max_slack);
    if (mode == .ascii and query.len == name.len and
        startsWithIn(mode, name, query)) return .run(tier.exact, 0, name.len);
    if (startsWithIn(mode, name, query)) return .run(tier.start - slack, 0, query.len);
    if (mode == .ascii) {
        // A word's start: "code" in Visual Studio Code.
        var at: usize = 0;
        while (indexOfIn(mode, name, query, at)) |i| : (at = i + 1) {
            if (wordStart(mode, name, i)) return .run(
                tier.word - slack - capped(i, max_slack),
                i,
                query.len,
            );
        }
        if (initials(query, name)) |m| return m;
    }
    if (indexOfIn(mode, name, query, 0)) |i| return .run(
        tier.inside - slack - capped(i, max_slack),
        i,
        query.len,
    );
    if (inOrder(mode, query, name)) |m| return m;
    return if (mode == .ascii) typo(query, name) else null;
}

/// The letters in order anywhere; each one on a word's start or right
/// after the last scores more, gaps score less.
fn inOrder(comptime mode: Mode, query: []const u8, name: []const u8) ?Match {
    const Found = struct { at: usize, len: usize };
    var m: Match = .{ .score = tier.in_order };
    var last: ?Found = null;
    var qi: usize = 0;
    var ni: usize = 0;
    while (qi < query.len) {
        if (query[qi] == ' ') {
            qi += 1;
            continue;
        }
        const q = charAt(mode, query, qi) orelse return null;
        const found: Found = while (ni < name.len) {
            const c = charAt(mode, name, ni) orelse {
                ni += 1;
                continue;
            };
            ni += c.len;
            if (fold(c.cp) == fold(q.cp)) break .{ .at = ni - c.len, .len = c.len };
        } else return null;
        if (wordStart(mode, name, found.at)) m.score += word_bonus;
        if (last) |l| {
            if (found.at == l.at + l.len)
                m.score += next_bonus
            else
                m.score -= capped(found.at - l.at, max_gap);
        } else m.score -= capped(found.at, max_gap);
        for (found.at..found.at + found.len) |i| m.add(i);
        last = found;
        qi += q.len;
    }
    m.score -= spread(name.len);
    return m;
}

/// The query as the words' initials, in order, every one of them.
fn initials(query: []const u8, name: []const u8) ?Match {
    if (query.len < 2) return null;
    var m: Match = .{ .score = 0 };
    var q: usize = 0;
    for (name, 0..) |ch, i| {
        if (q == query.len) break;
        if (!wordStart(.ascii, name, i)) continue;
        if (fold(ch) == fold(query[q])) {
            m.add(i);
            q += 1;
        }
    }
    if (q < query.len) return null;
    m.score = tier.initials - capped(name.len, max_slack);
    return m;
}

/// The typos a query of this length may have: none under 4 letters (too
/// many names are a letter from "map"), one, then two from 7.
fn allowed(len: usize) u8 {
    return if (len < 4) 0 else if (len < 7) 1 else 2;
}

/// A longer query is not guessed at.
const max_q = 32;
/// Only this much of a word is lined up with the query.
const max_n = 64;
/// Edit distances between the query's first i bytes and the name's first
/// j bytes from a word's start (`dist`).
const Table = [max_q + 1][max_n + 1]u8;

/// The query as a misspelt start of the name, or of one of its words: the
/// fewest edits (a byte put in, left out, changed, or two neighbours
/// swapped) that make the query some prefix of it, if few enough.
fn typo(query: []const u8, name: []const u8) ?Match {
    const most = allowed(query.len);
    if (most == 0 or query.len > max_q) return null;
    var t: Table = undefined;
    var best: ?struct { errs: u8, start: usize, end: usize } = null;
    for (0..name.len) |s| {
        if (!wordStart(.ascii, name, s)) continue;
        const word = name[s..@min(name.len, s + max_n)];
        const r = dist(&t, query, word);
        if (r.errs <= most and (best == null or
            r.errs < best.?.errs)) best = .{ .errs = r.errs, .start = s, .end = r.end };
    }
    const b = best orelse return null;
    // The bytes that line up with the query's, for the row's highlight.
    const word = name[b.start..@min(name.len, b.start + max_n)];
    _ = dist(&t, query, word);
    var back: [max_hits]Hit = undefined;
    var n: usize = 0;
    var i = query.len;
    var j = b.end;
    const last_hit = std.math.maxInt(Hit);
    while (i > 0 and j > 0) {
        const here = t[i][j];
        if (fold(query[i - 1]) == fold(word[j - 1]) and here == t[i - 1][j - 1]) {
            if (n < back.len) back[n] = @intCast(@min(b.start + j - 1, last_hit));
            n += 1;
            i -= 1;
            j -= 1;
        } else if (i > 1 and j > 1 and swapped(query, word, i, j) and here == t[i - 2][j - 2] + 1) {
            // Both letters are there, the wrong way round: both lit.
            for ([_]usize{ 1, 2 }) |d| {
                if (n < back.len) back[n] = @intCast(@min(b.start + j - d, last_hit));
                n += 1;
            }
            i -= 2;
            j -= 2;
        } else if (here == t[i - 1][j - 1] + 1) {
            i -= 1;
            j -= 1;
        } else if (here == t[i - 1][j] + 1) {
            i -= 1;
        } else j -= 1;
    }
    var m: Match = .{
        .score = tier.typo - typo_cost * @as(i32, b.errs) - spread(name.len) -
            capped(b.start, max_gap),
    };
    var k = @min(n, back.len);
    while (k > 0) : (k -= 1) m.add(back[k - 1]);
    return m;
}

fn swapped(q: []const u8, w: []const u8, i: usize, j: usize) bool {
    return fold(q[i - 1]) == fold(w[j - 2]) and fold(q[i - 2]) == fold(w[j - 1]);
}

/// Fills `t` (optimal string alignment: insert, delete, change, swap
/// neighbours) and returns the fewest edits to any prefix of `word`, and
/// that prefix's length.
fn dist(t: *Table, q: []const u8, word: []const u8) struct { errs: u8, end: usize } {
    for (0..word.len + 1) |j| t[0][j] = @intCast(j);
    for (1..q.len + 1) |i| {
        t[i][0] = @intCast(i);
        for (1..word.len + 1) |j| {
            const same = fold(q[i - 1]) == fold(word[j - 1]);
            var v = @min(t[i - 1][j] + 1, t[i][j - 1] + 1, t[i - 1][j - 1] + @intFromBool(!same));
            if (i > 1 and j > 1 and swapped(q, word, i, j)) v = @min(v, t[i - 2][j - 2] + 1);
            t[i][j] = v;
        }
    }
    var errs: u8 = 255;
    var end: usize = 0;
    for (0..word.len + 1) |j| if (t[q.len][j] < errs) {
        errs = t[q.len][j];
        end = j;
    };
    return .{ .errs = errs, .end = end };
}

/// A ranked candidate: which one (an index the caller keeps) and its score.
pub const Ranked = struct {
    index: u32,
    match: Match,
};

/// The best candidates offered, best first, at most `out.len` of them. Of
/// equal scores the one offered first stays first; past the end the worst
/// falls off.
pub const Top = struct {
    out: []Ranked,
    n: usize = 0,

    pub fn init(out: []Ranked) Top {
        return .{ .out = out };
    }

    pub fn offer(t: *Top, r: Ranked) void {
        assert(t.n <= t.out.len);
        var at = t.n;
        while (at > 0 and t.out[at - 1].match.score < r.match.score) : (at -= 1) {}
        if (at == t.out.len) return;
        if (t.n < t.out.len) t.n += 1;
        var j = t.n - 1;
        while (j > at) : (j -= 1) t.out[j] = t.out[j - 1];
        t.out[at] = r;
    }

    pub fn ranked(t: *const Top) []Ranked {
        return t.out[0..t.n];
    }
};

/// The match of `query` in `name` or one of its `keywords`, null below
/// `min` (letters in order and typos are too loose for these).
pub fn scoreNamed(
    query: []const u8,
    name: []const u8,
    keywords: []const []const u8,
    min: i32,
) ?Match {
    var best = score(query, name);
    if (best != null and best.?.score < min) best = null;
    for (keywords) |k| if (score(query, k)) |m| {
        var via = m;
        via.score -= keyword_cost;
        via.n = 0;
        if (m.score >= min and (best == null or via.score > best.?.score)) best = via;
    };
    return best;
}

test "the tiers rank as they should" {
    const t = std.testing;
    try t.expect(score("safari", "Safari").?.score > score("saf", "Safari").?.score);
    try t.expect(score("saf", "Safari").?.score > score("code", "Visual Studio Code").?.score);
    try t.expect(
        score("code", "Visual Studio Code").?.score > score("vsc", "Visual Studio Code").?.score,
    );
    try t.expect(
        score("vsc", "Visual Studio Code").?.score > score("tudi", "Visual Studio Code").?.score,
    );
    try t.expect(
        score("tudi", "Visual Studio Code").?.score > score("vsco", "Visual Studio Code").?.score,
    );
    try t.expect(score("xyz", "Safari") == null);
    try t.expect(score("", "Safari") == null);
}

test "initials and capitals start words" {
    const t = std.testing;
    const m = score("ft", "FaceTime").?;
    try t.expectEqualSlices(u8, &.{ 0, 4 }, m.matched());
    const s = score("ss", "System Settings").?;
    try t.expectEqualSlices(u8, &.{ 0, 7 }, s.matched());
}

test "typos still find the app, below every exact match" {
    const t = std.testing;
    // Swapped, changed, extra, and two wrong in a long word.
    try t.expect(score("chorme", "Google Chrome") != null);
    try t.expect(score("notse", "Notes") != null);
    try t.expect(score("safaro", "Safari") != null);
    try t.expect(score("safarii", "Safari") != null);
    try t.expect(score("calandr", "Calendar") != null);
    try t.expect(score("sistem", "System Settings") != null);
    // The word it misspells is the one lit: "Chrome", not "Google".
    try t.expectEqualSlices(
        u8,
        &.{ 7, 8, 9, 10, 11, 12 },
        score("chorme", "Google Chrome").?.matched(),
    );
    try t.expect(score("notse", "Notes").?.score < score("nts", "Notes").?.score);
    // Too far, or too short to guess at.
    try t.expect(score("zebra", "Safari") == null);
    try t.expect(score("sax", "Safari") == null);
    try t.expect(score("mapz", "Mail") == null);
}

test "a subsequence highlights the letters it took" {
    const m = score("sfr", "Safari").?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 4 }, m.matched());
}

test "unicode display names match by prefix and subsequence" {
    const t = std.testing;
    try t.expect(score("微信", "微信") != null);
    try t.expect(score("微", "微信") != null);
    try t.expect(score("信", "微信") != null);
    try t.expect(score("wx", "微信") == null);
}

test "top keeps at most its room, best first, the first of equals first" {
    const t = std.testing;
    var out: [3]Ranked = undefined;
    var top: Top = .init(&out);
    for ([_]i32{ 5, 9, 5, 1, 9, 7, 5 }, 0..) |s, i| {
        top.offer(.{ .index = @intCast(i), .match = .{ .score = s } });
        try t.expect(top.n <= out.len);
    }
    try t.expectEqual(@as(usize, 3), top.n);
    var got: [3]u32 = undefined;
    for (top.ranked(), &got) |r, *g| g.* = r.index;
    try t.expectEqualSlices(u32, &.{ 1, 4, 5 }, &got);
    // No room: nothing is kept, and nothing breaks.
    var none: Top = .init(&.{});
    none.offer(.{ .index = 0, .match = .{ .score = 1 } });
    try t.expectEqual(@as(usize, 0), none.n);
}

test "a keyword matches under the name and lights nothing; loose letters miss" {
    const t = std.testing;
    try t.expectEqual(
        @as(u8, 4),
        scoreNamed("blue", "Bluetooth", &.{"wireless"}, min_loose).?.n,
    );
    const k = scoreNamed("wireless", "Network", &.{"wireless"}, min_loose).?;
    try t.expectEqual(@as(i32, tier.exact - keyword_cost), k.score);
    try t.expectEqual(@as(u8, 0), k.n);
    try t.expect(scoreNamed("sfr", "Safari", &.{}, min_loose) == null);
}

test "a cut keeps whole characters; an escape keeps whole bytes" {
    const t = std.testing;
    try t.expectEqualStrings("é", clip("éé", 3));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try percentEncode(&w, "a b&c", .{});
    try t.expectEqualStrings("a%20b%26c", w.buffered());
    w = .fixed(&buf);
    try percentEncode(&w, "/a b/", .{ .keep = "/", .plus = true });
    try t.expectEqualStrings("/a+b/", w.buffered());
    // No room for all of "%26": none of it goes in.
    var small: [3]u8 = undefined;
    w = .fixed(&small);
    try t.expectError(error.WriteFailed, percentEncode(&w, "ab&", .{}));
    try t.expectEqualStrings("ab", w.buffered());
}
