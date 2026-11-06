//! Quicklinks: the web searches the panel lists under its other rows
//! (config.toml's `[[quicklinks]]`, or synced), the addresses they open for
//! what was typed, and which one is Google's, whose completions go with it.
const std = @import("std");
const search = @import("search.zig");

pub const Quicklink = struct {
    name: []const u8,
    /// `{argument}` is where the typed words go, escaped.
    url: []const u8,
    keyword: []const u8 = "",
};

/// What Nanolight searches with when no quicklinks are set; the first is
/// the search for what was typed, and Google's suggestions go with Google.
pub const default_quicklinks = [_]Quicklink{
    .{ .name = "Google", .url = "https://www.google.com/search?q={argument}" },
    .{ .name = "DuckDuckGo", .url = "https://duckduckgo.com/?q={argument}", .keyword = "ddg" },
    .{ .name = "Claude", .url = "https://claude.ai/new?q={argument}" },
    .{ .name = "Grok", .url = "https://grok.com/?q={argument}" },
    .{ .name = "X", .url = "https://x.com/search?f=live&q={argument}" },
};

/// A quicklink opens in a browser or the panel: http and https only.
pub fn webUrl(address: []const u8) bool {
    inline for (.{ "http://", "https://" }) |scheme| {
        if (address.len > scheme.len and
            std.ascii.eqlIgnoreCase(address[0..scheme.len], scheme)) return true;
    }
    return false;
}

/// The quicklink a query addresses by keyword, and where its words start.
pub const Keyed = struct { ql: u16, arg: usize };

/// `<keyword> words`, the keyword any case; `query` is trimmed.
pub fn keyed(ql: []const Quicklink, query: []const u8) ?Keyed {
    for (ql[0..@min(ql.len, std.math.maxInt(u16))], 0..) |q, i| {
        const k = q.keyword;
        if (k.len == 0 or query.len <= k.len or query[k.len] != ' ' or
            !std.ascii.eqlIgnoreCase(query[0..k.len], k)) continue;
        const rest = std.mem.trimStart(u8, query[k.len..], " ");
        return .{ .ql = @intCast(i), .arg = query.len - rest.len };
    }
    return null;
}

/// The host of an address: "www.google.com" of "https://www.google.com/search?q=".
pub fn host(address: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    const end = std.mem.indexOfAny(u8, rest, "/?#:") orelse rest.len;
    return rest[0..end];
}

fn isGoogle(address: []const u8) bool {
    const h = host(address);
    return std.ascii.eqlIgnoreCase(h, "google.com") or (h.len > 11 and
        std.ascii.eqlIgnoreCase(h[h.len - 11 ..], ".google.com"));
}

/// The first of `listed` whose address is Google's: the one its completions go with.
pub fn google(listed: []const Quicklink) ?u16 {
    for (listed[0..@min(listed.len, std.math.maxInt(u16))], 0..) |q, i| {
        if (isGoogle(q.url)) return @intCast(i);
    }
    return null;
}

/// The address `template` opens for `argument`: each `{argument}` is
/// replaced by it, escaped; a template without one opens as it is. Null
/// when it does not fit in `buf`: a cut address would open somewhere else.
pub fn url(buf: []u8, template: []const u8, argument: []const u8) ?[]const u8 {
    const mark = "{argument}";
    var w: std.Io.Writer = .fixed(buf);
    var rest = template;
    while (std.mem.indexOf(u8, rest, mark)) |i| {
        w.writeAll(rest[0..i]) catch return null;
        search.percentEncode(&w, std.mem.trim(u8, argument, " "), .{}) catch return null;
        rest = rest[i + mark.len ..];
    }
    w.writeAll(rest) catch return null;
    return w.buffered();
}

test "queries are escaped into the address" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://x.com/search?f=live&q=liquid%20glass%20%26%20UI",
        url(&buf, "https://x.com/search?f=live&q={argument}", " liquid glass & UI ").?,
    );
    try std.testing.expectEqualStrings(
        "https://claude.ai/new?q=what%20is%20zig%3F",
        url(&buf, "https://claude.ai/new?q={argument}", "what is zig?").?,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/hello%20world",
        url(&buf, "https://example.com/{argument}", "hello world").?,
    );
    try std.testing.expectEqualStrings(
        "https://a/zig/zig",
        url(&buf, "https://a/{argument}/{argument}", "zig").?,
    );
    try std.testing.expectEqualStrings(
        "https://example.com/",
        url(&buf, "https://example.com/", "ignored").?,
    );
    // An address that does not fit is none, not one cut short.
    var tiny: [8]u8 = undefined;
    try std.testing.expect(url(&tiny, "https://x.com/?q={argument}", "q") == null);
    var short: [20]u8 = undefined;
    try std.testing.expect(url(&short, "https://x.com/?q={argument}", "a long query") == null);
}

test "only http and https quicklinks are web addresses" {
    try std.testing.expect(webUrl("https://x.com/?q={argument}"));
    try std.testing.expect(webUrl("HTTP://a/b"));
    try std.testing.expect(!webUrl("file:///etc/passwd"));
    try std.testing.expect(!webUrl("javascript:alert(1)"));
    try std.testing.expect(!webUrl("https://"));
    for (default_quicklinks) |q| try std.testing.expect(webUrl(q.url));
}

test "Google is found by its host, any case, a subdomain too" {
    const ql: []const Quicklink = &.{
        .{ .name = "Duck", .url = "https://duckduckgo.com/?q={argument}" },
        .{ .name = "G", .url = "https://www.google.co.uk.example.com/?q={argument}" },
        .{ .name = "Web", .url = "https://WWW.Google.com/search?q={argument}" },
    };
    try std.testing.expectEqual(@as(?u16, 2), google(ql));
    try std.testing.expect(google(ql[0..2]) == null);
    try std.testing.expectEqualStrings("www.google.com", host(default_quicklinks[0].url));
}
