//! What clipboard history's parts say to each other: a kind of copy and its
//! limits, what a watcher saw, what a paste writes and how it went. The
//! store (clipboard.zig), each OS's watcher and the screen all take these;
//! this file takes none of them.
const std = @import("std");

pub const Kind = enum {
    text,
    image,
    file,

    /// What a kind's content is.
    pub const Info = struct {
        /// The most of it kept; a watcher reads (and converts) nothing larger.
        cap: usize,
        /// Its content is the PNG (`Item.png`), not text.
        png: bool,
    };

    pub fn info(k: Kind) Info {
        return switch (k) {
            .text => .{ .cap = 10 << 20, .png = false },
            .image => .{ .cap = 20 << 20, .png = true },
            // A copied list of files, as paths one a line.
            .file => .{ .cap = 256 << 10, .png = false },
        };
    }

    pub fn cap(k: Kind) usize {
        return k.info().cap;
    }
};

/// What a watcher saw on the clipboard. Slices are the watcher's own: the
/// store copies what it keeps.
pub const Item = struct {
    /// Any kind when `concealed`: nothing of it was read.
    kind: Kind,
    /// A text, or a file list's paths one a line.
    text: []const u8 = "",
    png: []const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    source: []const u8 = "",
    /// Marked concealed or transient by the app that copied it.
    concealed: bool = false,
};

/// What a paste or a copy writes to the clipboard: the full text (a file
/// list's paths one a line) or the PNG.
pub const Content = struct {
    kind: Kind,
    text: []const u8 = "",
    png: []const u8 = "",
};

/// How a paste or a copy of an entry went.
pub const PasteResult = enum {
    /// Written, and the keystroke sent to the app that had the keys.
    pasted,
    /// Written, as asked: no paste.
    copied,
    /// Written only: the OS has not allowed this app to send keys.
    copied_no_permission,
    /// Written only: pasting is not done on this system (yet).
    copied_unsupported,
    /// The clipboard could not be written.
    failed,
    /// The entry's content could not be read (its blob is gone or damaged).
    unreadable,
};

/// What a watcher tells the app.
pub const Sink = struct {
    ctx: *anyopaque,
    observe: *const fn (ctx: *anyopaque, item: Item) void,
    /// Whether this source is excluded: asked before the content is read.
    excluded: *const fn (ctx: *anyopaque, source: []const u8) bool,
};

/// Called to hide the panel, before the app that had the keys is woken.
pub const Hide = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

pub const StartError = error{Unavailable};

/// The width and height a PNG's header gives, or null if it is not one.
pub fn pngSize(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or
        !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        std.mem.readInt(u32, bytes[16..20], .big),
        std.mem.readInt(u32, bytes[20..24], .big),
    };
}

test "a PNG's header gives its size" {
    const hdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x03\x20\x00\x00\x02\x58";
    try std.testing.expectEqual([2]u32{ 800, 600 }, pngSize(hdr).?);
    try std.testing.expect(pngSize("not a png at all, really not") == null);
}
