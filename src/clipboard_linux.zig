//! Clipboard history on Linux. Wayland first: a compositor that offers
//! data-control (clipboard_wl.zig); else the X11 selections
//! (clipboard_x11.zig); else history is unavailable and says why. This file
//! is the choice between them and what both share: which of an offer's types
//! to read, the order to read them in, and how a copied entry is served back.
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const x11 = @import("clipboard_x11.zig");
const wl = @import("clipboard_wl.zig");

pub const Watcher = struct {
    pub const available = true;
    pub const unavailable_reason = "Clipboard history needs an X11 session or a Wayland compositor with the data-control protocol.";

    /// Why history cannot run in this session, once `start` failed.
    why: ?[]const u8 = null,
    backend: union(enum) { none, x11: x11.X11, wl: wl.Wl } = .none,

    pub fn start(w: *Watcher, sink: clipboard.Sink) !void {
        if (w.backend == .none) try w.pick();
        switch (w.backend) {
            inline .x11, .wl => |*b| b.sink = sink,
            .none => unreachable,
        }
    }

    /// Opens the Wayland connection if there is data-control, else X11.
    fn pick(w: *Watcher) !void {
        const wayland = env("WAYLAND_DISPLAY") != null;
        var reason: []const u8 = "Clipboard history needs a display: neither WAYLAND_DISPLAY nor DISPLAY is set.";
        if (wayland) {
            w.backend = .{ .wl = .{} };
            if (w.backend.wl.open()) |_| return else |e| {
                w.backend.wl.close();
                w.backend = .none;
                reason = switch (e) {
                    error.NoDataControl => "This Wayland compositor has no data-control protocol (GNOME has none), so clipboard history cannot watch it.",
                    else => "Could not connect to the Wayland display (libwayland-client missing?).",
                };
            }
        }
        if (env("DISPLAY") != null) {
            w.backend = .{ .x11 = .{} };
            if (w.backend.x11.open()) |_| return else |_| {
                w.backend.x11.close();
                w.backend = .none;
                reason = "Could not open the X11 display with libX11 and libXfixes.";
            }
        }
        w.why = reason;
        return error.Unsupported;
    }

    pub fn stop(w: *Watcher) void {
        switch (w.backend) {
            inline .x11, .wl => |*b| b.sink = null,
            .none => {},
        }
    }

    /// Nothing to note: a window manager gives the keys back to the previous
    /// window, and a Wayland compositor does the same.
    pub fn noteFrontmost(_: *Watcher) void {}

    pub fn paste(w: *Watcher, c: clipboard.Content, hide: clipboard.Hide) clipboard.PasteResult {
        return switch (w.backend) {
            inline .x11, .wl => |*b| b.paste(c, hide),
            .none => if (w.copy(c)) .copied_unsupported else .failed,
        };
    }

    pub fn copy(w: *Watcher, c: clipboard.Content) bool {
        return switch (w.backend) {
            inline .x11, .wl => |*b| b.copy(c),
            .none => blk: {
                if (c.kind == .image) break :blk false;
                nanoui.clipboard.writeText(c.text);
                break :blk true;
            },
        };
    }
};

pub fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// A table of C functions from one shared library, by the field names.
pub fn dlLoad(comptime T: type, name: [*:0]const u8) ?T {
    const lib = std.c.dlopen(name, .{ .NOW = true }) orelse return null;
    var v: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names) |f| {
        const sym = std.c.dlsym(lib, f) orelse return null;
        @field(v, f) = @ptrCast(@alignCast(sym));
    }
    return v;
}

/// Calls `f(owner, id)` on the main thread after `ms`; the owner compares
/// `id` with the step it is on, so a timer that outlived its step does nothing.
pub fn after(comptime T: type, owner: *T, id: u32, ms: u64, comptime f: fn (*T, u32) void) void {
    const Box = struct {
        owner: *T,
        id: u32,
        fn fire(ctx: ?*anyopaque) callconv(.c) void {
            const b: *@This() = @ptrCast(@alignCast(ctx.?));
            const o, const i = .{ b.owner, b.id };
            std.heap.c_allocator.destroy(b);
            f(o, i);
        }
    };
    const b = std.heap.c_allocator.create(Box) catch return;
    b.* = .{ .owner = owner, .id = id };
    nanoui.App.after(ms, b, Box.fire);
}

// ----- what to read -----

pub const hint_mime = "x-kde-passwordManagerHint";
pub const uri_mime = "text/uri-list";
pub const png_mime = "image/png";
pub const gnome_mime = "x-special/gnome-copied-files";
/// Offered by Nanolight's own source, so the watcher can tell its own paste
/// from a copy somewhere else.
pub const own_mime = "application/x-nanolight-own";
/// In the order read; STRING is Latin-1 and counts only when it is also UTF-8.
pub const text_mimes = [_][]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING" };
const served_text = text_mimes[0..3];

pub const Step = enum { hint, files, text, image };
pub const Request = struct { step: Step, mime: []const u8, cap: usize };

/// The reads one copy takes, in order: the password manager's hint, then
/// file paths, text, an image. The first that gives something is the entry.
pub const Plan = struct {
    own: bool = false,
    steps: [4]Request = undefined,
    n: usize = 0,

    fn add(p: *Plan, step: Step, mime: []const u8, cap: usize) void {
        p.steps[p.n] = .{ .step = step, .mime = mime, .cap = cap };
        p.n += 1;
    }
};

pub fn plan(offered: []const []const u8) Plan {
    var p: Plan = .{};
    const has = struct {
        offered: []const []const u8,
        fn find(s: @This(), mime: []const u8) ?[]const u8 {
            for (s.offered) |o| if (std.mem.eql(u8, o, mime)) return o;
            return null;
        }
    }{ .offered = offered };
    p.own = has.find(own_mime) != null;
    if (has.find(hint_mime)) |m| p.add(.hint, m, 64);
    if (has.find(uri_mime)) |m| p.add(.files, m, clipboard.max_files);
    for (text_mimes) |t| if (has.find(t)) |m| {
        p.add(.text, m, clipboard.max_text);
        break;
    };
    if (has.find(png_mime)) |m| p.add(.image, m, clipboard.max_image);
    return p;
}

/// Reads a plan one request at a time, whatever the transport: `first`
/// names the first read, `feed` takes its bytes (null when it failed) and
/// names the next, or null when the copy is done.
pub const Gather = struct {
    plan: Plan,
    sink: clipboard.Sink,
    source: []const u8 = "",
    at: usize = 0,

    pub fn first(g: *Gather) ?Request {
        return g.current();
    }

    fn current(g: *const Gather) ?Request {
        return if (g.at < g.plan.n) g.plan.steps[g.at] else null;
    }

    pub fn feed(g: *Gather, bytes: ?[]const u8) ?Request {
        const r = g.current() orelse return null;
        g.at += 1;
        // A hint that cannot be read is treated as a secret.
        if (r.step == .hint) return if (bytes != null and !std.mem.startsWith(u8, bytes.?, "secret")) g.current() else null;
        const b = bytes orelse return g.current();
        const gpa = std.heap.c_allocator;
        switch (r.step) {
            .hint => unreachable,
            .files => {
                const paths = (uriListPaths(gpa, b) catch null) orelse return g.current();
                defer gpa.free(paths);
                g.sink.observe(g.sink.ctx, .{ .kind = .file, .text = paths, .source = g.source });
                return null;
            },
            .text => {
                const t = std.mem.trimEnd(u8, b, "\x00");
                if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) return g.current();
                g.sink.observe(g.sink.ctx, .{ .kind = .text, .text = t, .source = g.source });
                return null;
            },
            .image => {
                const size = clipboard.pngSize(b) orelse return g.current();
                g.sink.observe(g.sink.ctx, .{ .kind = .image, .png = b, .width = size[0], .height = size[1], .source = g.source });
                return null;
            },
        }
    }
};

// ----- file lists -----

fn unhex(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// A text/uri-list's file: URIs as paths, one a line; null when it names no
/// local file. Comments, other schemes and remote hosts are skipped.
pub fn uriListPaths(gpa: std.mem.Allocator, list: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    lines: while (lines.next()) |line| {
        var rest = line;
        if (!std.ascii.startsWithIgnoreCase(rest, "file://")) continue;
        rest = rest["file://".len..];
        if (std.ascii.startsWithIgnoreCase(rest, "localhost/")) rest = rest["localhost".len..];
        if (rest.len == 0 or rest[0] != '/') continue;
        const start = out.items.len;
        if (start > 0) try out.append(gpa, '\n');
        const from = out.items.len;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            var c = rest[i];
            if (c == '%' and i + 2 < rest.len and unhex(rest[i + 1]) != null and unhex(rest[i + 2]) != null) {
                c = unhex(rest[i + 1]).? << 4 | unhex(rest[i + 2]).?;
                i += 2;
            }
            // A newline in a name cannot be told from the next path.
            if (c == '\n' or c == '\r') {
                out.shrinkRetainingCapacity(start);
                continue :lines;
            }
            try out.append(gpa, c);
        }
        if (out.items.len - from == 0) out.shrinkRetainingCapacity(start);
        if (out.items.len > clipboard.max_files) {
            out.shrinkRetainingCapacity(start);
            break;
        }
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return null;
    }
    return try out.toOwnedSlice(gpa);
}

/// Paths one a line as `file://` URIs, percent-encoded, joined by `sep`
/// (and ended by it when `end`).
fn urisFromPaths(gpa: std.mem.Allocator, paths: []const u8, sep: []const u8, end: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, paths, '\n');
    var first = true;
    while (lines.next()) |p| {
        if (!first) try out.appendSlice(gpa, sep);
        first = false;
        try out.appendSlice(gpa, "file://");
        for (p) |c| {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-_.~", c) != null)
                try out.append(gpa, c)
            else
                try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
    if (end and !first) try out.appendSlice(gpa, sep);
    return out.toOwnedSlice(gpa);
}

// ----- what is served -----

/// An entry offered back to other apps: its bytes in each format it is
/// offered in.
pub const Served = struct {
    gpa: std.mem.Allocator,
    kind: clipboard.Kind,
    /// Text, a file list's paths, or the PNG.
    main: []u8,
    uris: []u8 = &.{},
    gnome: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, c: clipboard.Content) !Served {
        const main = try gpa.dupe(u8, if (c.kind == .image) c.png else c.text);
        errdefer gpa.free(main);
        var s: Served = .{ .gpa = gpa, .kind = c.kind, .main = main };
        if (c.kind == .file) {
            s.uris = try urisFromPaths(gpa, c.text, "\r\n", true);
            errdefer gpa.free(s.uris);
            const list = try urisFromPaths(gpa, c.text, "\n", false);
            defer gpa.free(list);
            s.gnome = try std.mem.concat(gpa, u8, &.{ "copy\n", list });
        }
        return s;
    }

    pub fn deinit(s: *Served) void {
        s.gpa.free(s.main);
        s.gpa.free(s.uris);
        s.gpa.free(s.gnome);
    }

    pub fn mimes(s: *const Served) []const []const u8 {
        return switch (s.kind) {
            .text => served_text,
            .image => &.{png_mime},
            .file => &.{ uri_mime, gnome_mime, "text/plain" },
        };
    }

    pub fn bytes(s: *const Served, mime: []const u8) ?[]const u8 {
        for (s.mimes()) |m| if (std.mem.eql(u8, m, mime)) {
            if (std.mem.eql(u8, m, uri_mime)) return s.uris;
            if (std.mem.eql(u8, m, gnome_mime)) return s.gnome;
            return s.main;
        };
        return null;
    }
};

// ----- tests -----

const testing = std.testing;

test "a uri list becomes paths, decoded, skipping what is not a local file" {
    const gpa = testing.allocator;
    const list = "# comment\r\nfile:///home/a%20b/c.txt\r\nhttps://example.com/x\r\nfile://localhost/tmp/d\r\nfile://host/remote\r\nfile:///tmp/a%0Ab\r\nfile:///tmp/%e2%82%ac\r\n";
    const paths = (try uriListPaths(gpa, list)).?;
    defer gpa.free(paths);
    try testing.expectEqualStrings("/home/a b/c.txt\n/tmp/d\n/tmp/\u{20ac}", paths);
    try testing.expect(try uriListPaths(gpa, "https://example.com\r\n") == null);
    try testing.expect(try uriListPaths(gpa, "") == null);
    // A stray percent sign stays as it is.
    const odd = (try uriListPaths(gpa, "file:///a%zz\nfile:///b%2")).?;
    defer gpa.free(odd);
    try testing.expectEqualStrings("/a%zz\n/b%2", odd);
}

test "paths are served as uris that read back" {
    const gpa = testing.allocator;
    var s = try Served.init(gpa, .{ .kind = .file, .text = "/home/a b/c.txt\n/tmp/\u{20ac}" });
    defer s.deinit();
    try testing.expectEqualStrings("file:///home/a%20b/c.txt\r\nfile:///tmp/%E2%82%AC\r\n", s.bytes(uri_mime).?);
    try testing.expectEqualStrings("copy\nfile:///home/a%20b/c.txt\nfile:///tmp/%E2%82%AC", s.bytes(gnome_mime).?);
    try testing.expectEqualStrings("/home/a b/c.txt\n/tmp/\u{20ac}", s.bytes("text/plain").?);
    const back = (try uriListPaths(gpa, s.bytes(uri_mime).?)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings("/home/a b/c.txt\n/tmp/\u{20ac}", back);
    try testing.expect(s.bytes("image/png") == null);
}

test "text and images are served in their own types only" {
    var t = try Served.init(testing.allocator, .{ .kind = .text, .text = "hi" });
    defer t.deinit();
    try testing.expectEqualStrings("hi", t.bytes("text/plain;charset=utf-8").?);
    try testing.expectEqualStrings("hi", t.bytes("UTF8_STRING").?);
    try testing.expect(t.bytes("image/png") == null and t.bytes(uri_mime) == null);
    var i = try Served.init(testing.allocator, .{ .kind = .image, .png = "\x89PNG" });
    defer i.deinit();
    try testing.expectEqualStrings("\x89PNG", i.bytes("image/png").?);
    try testing.expect(i.bytes("UTF8_STRING") == null);
}

test "the plan reads the hint, then files, text and image, each once" {
    const p = plan(&.{ "image/png", "text/html", "STRING", "text/plain", "text/uri-list", hint_mime });
    try testing.expect(!p.own);
    try testing.expectEqual(@as(usize, 4), p.n);
    try testing.expectEqual(Step.hint, p.steps[0].step);
    try testing.expectEqual(Step.files, p.steps[1].step);
    try testing.expectEqualStrings("text/plain", p.steps[2].mime);
    try testing.expectEqual(Step.image, p.steps[3].step);
    try testing.expectEqual(@as(usize, 0), plan(&.{"text/html"}).n);
    try testing.expect(plan(&.{ "UTF8_STRING", own_mime }).own);
}

const Seen = struct {
    item: ?clipboard.Item = null,
    text: [64]u8 = undefined,
    fn observe(ctx: *anyopaque, item: clipboard.Item) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.item = item;
        const n = @min(item.text.len, s.text.len);
        @memcpy(s.text[0..n], item.text[0..n]);
        s.item.?.text = s.text[0..n];
    }
    fn excluded(_: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn sink(s: *Seen) clipboard.Sink {
        return .{ .ctx = s, .observe = observe, .excluded = excluded };
    }
};

test "a gather falls through unreadable and unusable types" {
    var seen: Seen = .{};
    var g: Gather = .{ .plan = plan(&.{ "text/uri-list", "UTF8_STRING", "image/png" }), .sink = seen.sink(), .source = "app" };
    try testing.expectEqualStrings(uri_mime, g.first().?.mime);
    // A link, not a file: on to the text.
    try testing.expectEqualStrings("UTF8_STRING", g.feed("https://x.org\r\n").?.mime);
    // Not UTF-8: on to the image.
    try testing.expectEqual(Step.image, g.feed("\xff\xfe").?.step);
    // Not a PNG: nothing left.
    try testing.expect(g.feed("nope") == null and seen.item == null);

    g = .{ .plan = plan(&.{ "UTF8_STRING", "image/png" }), .sink = seen.sink(), .source = "app" };
    _ = g.first();
    try testing.expect(g.feed("hello\x00") == null);
    try testing.expectEqualStrings("hello", seen.item.?.text);
    try testing.expectEqualStrings("app", seen.item.?.source);
}

test "a password manager's hint stops the read, and so does one that cannot be read" {
    var seen: Seen = .{};
    const offered = [_][]const u8{ hint_mime, "UTF8_STRING" };
    var g: Gather = .{ .plan = plan(&offered), .sink = seen.sink() };
    try testing.expectEqualStrings(hint_mime, g.first().?.mime);
    try testing.expect(g.feed("secret") == null and seen.item == null);
    g = .{ .plan = plan(&offered), .sink = seen.sink() };
    _ = g.first();
    try testing.expect(g.feed(null) == null and seen.item == null);
    // Any other value is no secret.
    g = .{ .plan = plan(&offered), .sink = seen.sink() };
    _ = g.first();
    try testing.expectEqualStrings("UTF8_STRING", g.feed("").?.mime);
    try testing.expect(g.feed("visible") == null);
    try testing.expectEqualStrings("visible", seen.item.?.text);
}
