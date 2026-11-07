//! Clipboard history on Windows: GetClipboardSequenceNumber polled every
//! 500 ms on the main thread, and a paste that writes the entry, wakes the
//! window that had the keys and sends it Ctrl+V (SendInput; a window running
//! as administrator ignores it). Text is CF_UNICODETEXT, images CF_DIB and
//! CF_DIBV5 (kept as PNG), files CF_HDROP.
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard_types.zig");
const win_msg = @import("win_msg.zig");
const log = @import("log.zig");

const HANDLE = ?*anyopaque;
const INPUT = extern struct {
    type: u32 = 1, // INPUT_KEYBOARD
    // KEYBDINPUT, after the padding that aligns its pointer field.
    _pad: u32 = 0,
    vk: u16,
    scan: u16 = 0,
    flags: u32,
    time: u32 = 0,
    extra: usize = 0,
    _tail: [8]u8 = @splat(0), // the union is as large as MOUSEINPUT
};

extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) u32;
extern "user32" fn OpenClipboard(owner: HANDLE) callconv(.winapi) i32;
extern "user32" fn CloseClipboard() callconv(.winapi) i32;
extern "user32" fn EmptyClipboard() callconv(.winapi) i32;
extern "user32" fn GetClipboardData(format: u32) callconv(.winapi) HANDLE;
extern "user32" fn SetClipboardData(format: u32, mem: HANDLE) callconv(.winapi) HANDLE;
extern "user32" fn IsClipboardFormatAvailable(format: u32) callconv(.winapi) i32;
extern "user32" fn RegisterClipboardFormatW(name: [*:0]const u16) callconv(.winapi) u32;
extern "user32" fn GetClipboardOwner() callconv(.winapi) HANDLE;
extern "user32" fn GetForegroundWindow() callconv(.winapi) HANDLE;
extern "user32" fn SetForegroundWindow(hwnd: HANDLE) callconv(.winapi) i32;
extern "user32" fn GetWindowThreadProcessId(hwnd: HANDLE, pid: *u32) callconv(.winapi) u32;
extern "user32" fn SendInput(n: u32, inputs: [*]const INPUT, size: i32) callconv(.winapi) u32;
extern "kernel32" fn GlobalAlloc(flags: u32, bytes: usize) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalFree(mem: *anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalLock(mem: *anyopaque) callconv(.winapi) ?[*]u8;
extern "kernel32" fn GlobalUnlock(mem: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GlobalSize(mem: *anyopaque) callconv(.winapi) usize;
extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn QueryFullProcessImageNameW(
    process: *anyopaque,
    flags: u32,
    name: [*]u16,
    len: *u32,
) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const cf_unicodetext = 13;
const cf_dib = 8;
const cf_dibv5 = 17;
const cf_hdrop = 15;
const gmem_moveable = 0x2;
const process_query_limited = 0x1000;
const keyeventf_keyup = 0x2;
const vk_control = 0x11;
const vk_v = 0x56;
/// Another process holds the clipboard open for a moment after it copies.
const open_tries = 8;
/// The largest image written to the clipboard.
const max_pixels = 64 * 1024 * 1024;

// ----- pure parts: formats -----

pub const Error = error{ Unsupported, Corrupt, TooLarge, OutOfMemory };

/// The text of a NUL-terminated or unterminated UTF-16 buffer.
fn wideToUtf8(gpa: std.mem.Allocator, wide: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(wide, 0));
}

/// CF_UNICODETEXT's bytes as UTF-8, up to its NUL. `error.TooLarge` when it
/// has more UTF-16 units than `cap`, before anything is converted: each
/// unit is at least one byte of UTF-8.
fn unicodeText(gpa: std.mem.Allocator, bytes: []const u8, cap: usize) ![]u8 {
    var units = bytes.len / 2;
    for (0..units) |i| if (bytes[i * 2] == 0 and bytes[i * 2 + 1] == 0) {
        units = i;
        break;
    };
    if (units > cap) return error.TooLarge;
    const wide = try gpa.alloc(u16, units);
    defer gpa.free(wide);
    for (wide, 0..) |*u, i| u.* = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .little);
    return wideToUtf8(gpa, wide);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// A device-independent bitmap (CF_DIB, or CF_DIBV5 with its V5 header) as
/// PNG. 24 and 32 bits per pixel only, uncompressed; alpha is kept for a V5
/// bitmap that carries it, and a 32-bit bitmap without it is opaque.
/// `error.TooLarge` before converting when the PNG would be over `cap`: the
/// encoder stores its pixels unpacked, so it is never smaller than they are.
pub fn dibToPng(gpa: std.mem.Allocator, dib: []const u8, cap: usize) Error![]u8 {
    if (dib.len < 40) return error.Corrupt;
    const header = le32(dib, 0);
    if (header < 40 or header > dib.len) return error.Corrupt;
    const w_signed: i32 = @bitCast(le32(dib, 4));
    const h_signed: i32 = @bitCast(le32(dib, 8));
    const bits = std.mem.readInt(u16, dib[14..16], .little);
    const compression = le32(dib, 16);
    if (w_signed <= 0 or h_signed == 0) return error.Corrupt;
    if ((bits != 24 and bits != 32) or (compression != 0 and
        compression != 3)) return error.Unsupported;
    const w: usize = @intCast(w_signed);
    const h: usize = @abs(h_signed);
    if (w * h * 4 > cap) return error.TooLarge;
    var offset: usize = header;
    var alpha_mask: u32 = 0;
    if (compression == 3) {
        // Only the usual B, G, R byte order.
        if (bits != 32 or dib.len < 52) return error.Unsupported;
        const r = le32(dib, 40);
        if (r != 0x00ff0000 or le32(dib, 44) != 0x0000ff00 or
            le32(dib, 48) != 0x000000ff) return error.Unsupported;
        if (header >= 56) alpha_mask = le32(dib, 52);
        if (header == 40) offset += 12;
    }
    const stride = (w * bits + 31) / 32 * 4;
    if (offset > dib.len or dib.len - offset < stride * h) return error.Corrupt;
    const bytes = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(bytes);
    var has_alpha = false;
    if (alpha_mask == 0xff000000) for (0..h) |y| {
        const row = dib[offset + y * stride ..][0 .. w * 4];
        for (0..w) |x| has_alpha = has_alpha or row[x * 4 + 3] != 0;
    };
    const bottom_up = h_signed > 0;
    for (0..h) |y| {
        const src_row = dib[offset + (if (bottom_up) h - 1 - y else y) * stride ..];
        const dst = bytes[y * w * 4 ..][0 .. w * 4];
        for (0..w) |x| {
            const px = dst[x * 4 ..][0..4];
            const s = src_row[x * bits / 8 ..];
            const a: u8 = if (has_alpha) s[3] else 255;
            // The encoder takes premultiplied BGRA.
            for (0..3) |c| px[c] = @intCast((@as(u32, s[c]) * a + 127) / 255);
            px[3] = a;
        }
    }
    return nanoui.ui.png.encode(
        gpa,
        .{ .bytes = bytes, .width = w, .height = h },
    ) catch error.OutOfMemory;
}

/// The pixels of a PNG as straight RGBA rows (8-bit, RGB or RGBA, not
/// interlaced: what `nanoui.ui.png.encode` writes, and what screenshots are).
const Rgba = struct { w: usize, h: usize, px: []u8 };

fn pngPixels(gpa: std.mem.Allocator, png: []const u8) Error!Rgba {
    if (clipboard.pngSize(png) == null) return error.Corrupt;
    const size = clipboard.pngSize(png).?;
    if (png.len < 29 or png[24] != 8 or (png[25] != 2 and png[25] != 6) or
        png[28] != 0) return error.Unsupported;
    const w: usize = size[0];
    const h: usize = size[1];
    if (w == 0 or h == 0 or w * h > max_pixels) return error.TooLarge;
    const bpp: usize = if (png[25] == 6) 4 else 3;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var pos: usize = 8;
    while (pos + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[pos..][0..4], .big);
        if (len > png.len - pos - 12) return error.Corrupt;
        if (std.mem.eql(
            u8,
            png[pos + 4 ..][0..4],
            "IDAT",
        )) try idat.appendSlice(gpa, png[pos + 8 ..][0..len]);
        pos += 12 + len;
    }
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var input: std.Io.Reader = .fixed(idat.items);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, window);
    const raw = inflate.reader.allocRemaining(
        gpa,
        .limited(h * (w * bpp + 1) + 1),
    ) catch return error.Corrupt;
    defer gpa.free(raw);
    const row_len = w * bpp;
    if (raw.len != h * (row_len + 1)) return error.Corrupt;
    const px = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(px);
    for (0..h) |y| {
        const row = raw[y * (row_len + 1) ..][0 .. row_len + 1];
        const cur = row[1..];
        const prev: ?[]const u8 = if (y == 0)
            null
        else
            raw[(y - 1) * (row_len + 1) + 1 ..][0..row_len];
        for (0..row_len) |i| {
            const a: i32 = if (i >= bpp) cur[i - bpp] else 0;
            const b: i32 = if (prev) |p| p[i] else 0;
            const c: i32 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
            const add: u8 = switch (row[0]) {
                0 => 0,
                1 => @intCast(a),
                2 => @intCast(b),
                3 => @intCast(@divTrunc(a + b, 2)),
                4 => paeth(a, b, c),
                else => return error.Corrupt,
            };
            cur[i] +%= add;
        }
        for (0..w) |x| {
            const d = px[(y * w + x) * 4 ..][0..4];
            @memcpy(d[0..3], cur[x * bpp ..][0..3]);
            d[3] = if (bpp == 4) cur[x * 4 + 3] else 255;
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

fn paeth(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return @intCast(if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c);
}

/// A PNG as a 40-byte-header, bottom-up, 32-bit DIB (CF_DIB). Transparent
/// pixels are laid over white, because readers of CF_DIB ignore alpha.
pub fn pngToDib(gpa: std.mem.Allocator, png: []const u8) Error![]u8 {
    const img = try pngPixels(gpa, png);
    defer gpa.free(img.px);
    const out = try gpa.alloc(u8, 40 + img.w * img.h * 4);
    @memset(out[0..40], 0);
    std.mem.writeInt(u32, out[0..4], 40, .little);
    std.mem.writeInt(i32, out[4..8], @intCast(img.w), .little);
    std.mem.writeInt(i32, out[8..12], @intCast(img.h), .little);
    std.mem.writeInt(u16, out[12..14], 1, .little);
    std.mem.writeInt(u16, out[14..16], 32, .little);
    for (0..img.h) |y| {
        const dst = out[40 + (img.h - 1 - y) * img.w * 4 ..];
        for (0..img.w) |x| {
            const s = img.px[(y * img.w + x) * 4 ..][0..4];
            const a: u32 = s[3];
            for (0..3) |c| dst[x * 4 + c] = @intCast(
                (@as(u32, s[2 - c]) * a + 255 * (255 - a) + 127) / 255,
            );
            dst[x * 4 + 3] = 255;
        }
    }
    return out;
}

/// The paths in a DROPFILES block (CF_HDROP), one a line.
pub fn hdropPaths(gpa: std.mem.Allocator, drop: []const u8) ![]u8 {
    if (drop.len < 20) return error.Corrupt;
    const start = le32(drop, 0);
    const wide = le32(drop, 16) != 0;
    if (start < 20 or start > drop.len) return error.Corrupt;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const list = drop[start..];
    if (wide) {
        const units = list.len / 2;
        const buf = try gpa.alloc(u16, units);
        defer gpa.free(buf);
        for (buf, 0..) |*u, i| u.* = std.mem.readInt(u16, list[i * 2 ..][0..2], .little);
        var at: usize = 0;
        while (at < units and buf[at] != 0) {
            const end = std.mem.indexOfScalarPos(u16, buf, at, 0) orelse units;
            if (out.items.len > 0) try out.append(gpa, '\n');
            const path = try wideToUtf8(gpa, buf[at..end]);
            defer gpa.free(path);
            try out.appendSlice(gpa, path);
            at = end + 1;
        }
    } else {
        var it = std.mem.splitScalar(u8, list, 0);
        while (it.next()) |p| {
            if (p.len == 0) break;
            if (out.items.len > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, p);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// A wide DROPFILES block for the paths in `lines` (one a line).
pub fn dropfiles(gpa: std.mem.Allocator, lines: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 20, 0, 0, 0 });
    try out.appendNTimes(gpa, 0, 12);
    try out.appendSlice(gpa, &.{ 1, 0, 0, 0 });
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |p| {
        if (p.len == 0) continue;
        const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, p);
        defer gpa.free(wide);
        for (wide) |u| try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, u)));
        try out.appendSlice(gpa, &.{ 0, 0 });
    }
    try out.appendSlice(gpa, &.{ 0, 0 });
    return out.toOwnedSlice(gpa);
}

/// The file name of a Windows path.
fn exeName(path: []const u8) []const u8 {
    return path[if (std.mem.lastIndexOfAny(u8, path, "\\/")) |i| i + 1 else 0..];
}

// ----- the OS's side -----

fn registered(comptime name: []const u8) u32 {
    return RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral(name));
}

/// The clipboard, opened for us; another process may hold it a moment. A
/// writer passes a window of ours: EmptyClipboard makes it the owner, and
/// with no owner SetClipboardData fails.
fn open(owner: HANDLE) bool {
    for (0..open_tries) |_| {
        if (OpenClipboard(owner) != 0) return true;
        Sleep(10);
    }
    return false;
}

/// Bytes of the clipboard's `format`, or null; the clipboard is open.
fn data(format: u32) ?[]const u8 {
    const mem = GetClipboardData(format) orelse return null;
    const p = GlobalLock(mem) orelse return null;
    defer _ = GlobalUnlock(mem);
    return p[0..GlobalSize(mem)];
}

/// Whether the content asks not to be kept: the monitor-exclusion format,
/// or the history format holding a DWORD 0. The clipboard is open.
fn marked() bool {
    if (IsClipboardFormatAvailable(
        registered("ExcludeClipboardContentFromMonitorProcessing"),
    ) != 0) return true;
    const history = registered("CanIncludeInClipboardHistory");
    if (IsClipboardFormatAvailable(history) == 0) return false;
    const d = data(history) orelse return false;
    return d.len >= 4 and le32(d, 0) == 0;
}

/// The executable's name of the window's process, or "".
fn processName(hwnd: HANDLE, buf: []u8) []const u8 {
    var pid: u32 = 0;
    if (hwnd == null or GetWindowThreadProcessId(hwnd, &pid) == 0 or pid == 0) return "";
    const h = OpenProcess(process_query_limited, 0, pid) orelse return "";
    defer _ = CloseHandle(h);
    var wide: [1024]u16 = undefined;
    var n: u32 = wide.len;
    if (QueryFullProcessImageNameW(h, 0, &wide, &n) == 0) return "";
    const len = std.unicode.utf16LeToUtf8(buf, wide[0..n]) catch return "";
    return exeName(buf[0..len]);
}

fn ownedByUs(hwnd: HANDLE) bool {
    var pid: u32 = 0;
    return hwnd != null and GetWindowThreadProcessId(hwnd, &pid) != 0 and
        pid == GetCurrentProcessId();
}

/// Writes one format; the clipboard is open. The block is the clipboard's
/// once it has taken it, ours to free until then.
fn put(format: u32, bytes: []const u8) bool {
    const mem = GlobalAlloc(gmem_moveable, bytes.len) orelse return false;
    const p = GlobalLock(mem) orelse {
        _ = GlobalFree(mem);
        return false;
    };
    @memcpy(p[0..bytes.len], bytes);
    _ = GlobalUnlock(mem);
    if (SetClipboardData(format, mem) == null) {
        _ = GlobalFree(mem);
        return false;
    }
    return true;
}

/// The OS's side of the poll watcher (clipboard_poll.zig).
const Win = struct {
    /// The window that had the keys before the panel opened.
    previous: HANDLE = null,

    pub fn changeCount() u32 {
        return GetClipboardSequenceNumber();
    }

    pub fn read(_: *Win, sink: clipboard.Sink) void {
        var name_buf: [3 * 1024]u8 = undefined;
        var owner = processName(GetClipboardOwner(), &name_buf);
        if (owner.len == 0) owner = processName(GetForegroundWindow(), &name_buf);
        // Before the clipboard is opened at all.
        if (sink.excluded(sink.ctx, owner)) return;
        if (!open(null)) return log.warn(
            "nanolight: clipboard: the clipboard stayed busy; a copy was not read",
            .{},
        );
        defer _ = CloseClipboard();
        if (marked()) return sink.observe(
            sink.ctx,
            .{ .kind = .text, .concealed = true, .source = owner },
        );
        const gpa = std.heap.c_allocator;
        if (data(cf_hdrop)) |drop| {
            const paths = hdropPaths(gpa, drop) catch |e| return notRead(.file, e);
            defer gpa.free(paths);
            return sink.observe(sink.ctx, .{ .kind = .file, .text = paths, .source = owner });
        }
        if (data(cf_unicodetext)) |t| {
            const text = unicodeText(gpa, t, clipboard.Kind.text.cap()) catch |e|
                return notRead(.text, e);
            defer gpa.free(text);
            return sink.observe(sink.ctx, .{ .kind = .text, .text = text, .source = owner });
        }
        const dib = data(cf_dibv5) orelse data(cf_dib) orelse return;
        const png = dibToPng(gpa, dib, clipboard.Kind.image.cap()) catch |e|
            return notRead(.image, e);
        defer gpa.free(png);
        const size = clipboard.pngSize(png) orelse .{ 0, 0 };
        sink.observe(
            sink.ctx,
            .{ .kind = .image, .png = png, .width = size[0], .height = size[1], .source = owner },
        );
    }

    fn notRead(kind: clipboard.Kind, e: anyerror) void {
        log.info("nanolight: clipboard: a copied {t} was not kept: {t}", .{ kind, e });
    }

    /// The window in front now, unless it is ours: where a paste goes.
    pub fn noteFrontmost(w: *Win) void {
        const h = GetForegroundWindow();
        if (h != null and !ownedByUs(h)) w.previous = h;
    }

    /// SendInput needs no grant (a window running as administrator ignores it).
    pub fn keysAllowed(_: *Win) bool {
        return true;
    }

    pub fn wake(w: *Win) void {
        if (w.previous) |h| _ = SetForegroundWindow(h);
    }

    pub fn sendPaste(_: ?*anyopaque) callconv(.c) void {
        const keys = [_]INPUT{
            .{ .vk = vk_control, .flags = 0 },
            .{ .vk = vk_v, .flags = 0 },
            .{ .vk = vk_v, .flags = keyeventf_keyup },
            .{ .vk = vk_control, .flags = keyeventf_keyup },
        };
        _ = SendInput(keys.len, &keys, @sizeOf(INPUT));
    }

    /// Writes `c` as the clipboard's whole content: text as CF_UNICODETEXT
    /// only, an image as CF_DIB, files as CF_HDROP.
    pub fn write(c: clipboard.Content) bool {
        const gpa = std.heap.c_allocator;
        const bytes: []u8, const format: u32 = switch (c.kind) {
            .text => .{ textBytes(gpa, c.text) orelse return false, cf_unicodetext },
            .image => .{ pngToDib(gpa, c.png) catch return false, cf_dib },
            .file => .{ dropfiles(gpa, c.text) catch return false, cf_hdrop },
        };
        defer gpa.free(bytes);
        if (!open(win_msg.window())) return false;
        defer _ = CloseClipboard();
        if (EmptyClipboard() == 0) return false;
        return put(format, bytes);
    }
};

pub const Watcher = @import("clipboard_poll.zig").PollWatcher(Win);

/// UTF-16 with its NUL, as bytes.
fn textBytes(gpa: std.mem.Allocator, text: []const u8) ?[]u8 {
    const wide = std.unicode.utf8ToUtf16LeAlloc(gpa, text) catch return null;
    defer gpa.free(wide);
    const out = gpa.alloc(u8, wide.len * 2 + 2) catch return null;
    for (wide, 0..) |u, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], u, .little);
    @memset(out[wide.len * 2 ..], 0);
    return out;
}

// ----- tests -----

const testing = std.testing;
const max_image = clipboard.Kind.image.cap();

test "wide text stops at the NUL and rejects a lone surrogate" {
    const wide = std.unicode.utf8ToUtf16LeStringLiteral("héllo \u{1F600}");
    const s = try wideToUtf8(testing.allocator, wide);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("héllo \u{1F600}", s);
    const cut = try wideToUtf8(testing.allocator, &.{ 'a', 'b', 0, 'c' });
    defer testing.allocator.free(cut);
    try testing.expectEqualStrings("ab", cut);
    try testing.expectError(
        error.ExpectedSecondSurrogateHalf,
        wideToUtf8(testing.allocator, &.{ 0xd800, 'a' }),
    );
}

test "clipboard text over the cap is refused before it is converted" {
    const bytes = "a\x00b\x00\x00\x00c\x00";
    const s = try unicodeText(testing.allocator, bytes, 2);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("ab", s);
    try testing.expectError(error.TooLarge, unicodeText(testing.allocator, bytes, 1));
}

test "a process path is cut to its exe name" {
    try testing.expectEqualStrings(
        "Bitwarden.exe",
        exeName("C:\\Program Files\\Bitwarden\\Bitwarden.exe"),
    );
    try testing.expectEqualStrings("a.exe", exeName("a.exe"));
}

fn dibHeader(buf: []u8, w: i32, h: i32, bits: u16) void {
    @memset(buf[0..40], 0);
    std.mem.writeInt(u32, buf[0..4], 40, .little);
    std.mem.writeInt(i32, buf[4..8], w, .little);
    std.mem.writeInt(i32, buf[8..12], h, .little);
    std.mem.writeInt(u16, buf[12..14], 1, .little);
    std.mem.writeInt(u16, buf[14..16], bits, .little);
}

test "a bottom-up 24-bit DIB becomes a PNG that reads back" {
    // 2x2, rows padded to 8 bytes; bottom row first: red, green / blue, white.
    var dib: [40 + 16]u8 = undefined;
    dibHeader(&dib, 2, 2, 24);
    const rows = [_]u8{
        0, 0, 255, 0, 255, 0, 0, 0, // red, green (BGR)
        255, 0, 0, 255, 255, 255, 0, 0, // blue, white
    };
    @memcpy(dib[40..], &rows);
    const png = try dibToPng(testing.allocator, &dib, max_image);
    defer testing.allocator.free(png);
    try testing.expectEqual([2]u32{ 2, 2 }, clipboard.pngSize(png).?);
    const img = try pngPixels(testing.allocator, png);
    defer testing.allocator.free(img.px);
    // Top row is the DIB's last: blue, white.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 255, 255, 255 }, img.px[0..8]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, img.px[8..16]);
}

test "a 32-bit DIB is opaque unless its V5 mask carries alpha" {
    var plain: [40 + 4]u8 = undefined;
    dibHeader(&plain, 1, -1, 32);
    @memcpy(plain[40..], &[_]u8{ 10, 20, 30, 0 });
    const png = try dibToPng(testing.allocator, &plain, max_image);
    defer testing.allocator.free(png);
    const img = try pngPixels(testing.allocator, png);
    defer testing.allocator.free(img.px);
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10, 255 }, img.px);

    var v5: [124 + 4]u8 = undefined;
    @memset(&v5, 0);
    dibHeader(&v5, 1, 1, 32);
    std.mem.writeInt(u32, v5[0..4], 124, .little);
    std.mem.writeInt(u32, v5[16..20], 3, .little);
    std.mem.writeInt(u32, v5[40..44], 0x00ff0000, .little);
    std.mem.writeInt(u32, v5[44..48], 0x0000ff00, .little);
    std.mem.writeInt(u32, v5[48..52], 0x000000ff, .little);
    std.mem.writeInt(u32, v5[52..56], 0xff000000, .little);
    @memcpy(v5[124..], &[_]u8{ 0, 0, 100, 255 });
    const png5 = try dibToPng(testing.allocator, &v5, max_image);
    defer testing.allocator.free(png5);
    const img5 = try pngPixels(testing.allocator, png5);
    defer testing.allocator.free(img5.px);
    try testing.expectEqualSlices(u8, &.{ 100, 0, 0, 255 }, img5.px);
}

test "a truncated or unsupported DIB is refused" {
    var dib: [40 + 4]u8 = undefined;
    dibHeader(&dib, 2, 2, 24);
    try testing.expectError(error.Corrupt, dibToPng(testing.allocator, &dib, max_image));
    dibHeader(&dib, 1, 1, 8);
    try testing.expectError(error.Unsupported, dibToPng(testing.allocator, &dib, max_image));
    try testing.expectError(error.Corrupt, dibToPng(testing.allocator, "short", max_image));
    // Over the cap before a pixel is read: 2 × 2 at 4 bytes each is 16.
    dibHeader(&dib, 2, 2, 24);
    try testing.expectError(error.TooLarge, dibToPng(testing.allocator, &dib, 15));
}

test "a PNG written to the clipboard is a bottom-up DIB" {
    var dib_in: [40 + 8]u8 = undefined;
    dibHeader(&dib_in, 2, 1, 24);
    @memcpy(dib_in[40..], &[_]u8{ 0, 0, 255, 255, 0, 0, 0, 0 }); // red, blue
    const png = try dibToPng(testing.allocator, &dib_in, max_image);
    defer testing.allocator.free(png);
    const back = try pngToDib(testing.allocator, png);
    defer testing.allocator.free(back);
    try testing.expectEqual(@as(usize, 40 + 8), back.len);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 0, 0, 255 }, back[40..]);
}

test "file paths survive a DROPFILES round trip, wide and ANSI" {
    const block = try dropfiles(testing.allocator, "C:\\a b\\ü.txt\nD:\\x.png");
    defer testing.allocator.free(block);
    const paths = try hdropPaths(testing.allocator, block);
    defer testing.allocator.free(paths);
    try testing.expectEqualStrings("C:\\a b\\ü.txt\nD:\\x.png", paths);

    var ansi: [20 + 14]u8 = undefined;
    @memset(&ansi, 0);
    std.mem.writeInt(u32, ansi[0..4], 20, .little);
    @memcpy(ansi[20..][0..10], "C:\\a\x00D:\\b\x00");
    const p2 = try hdropPaths(testing.allocator, &ansi);
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings("C:\\a\nD:\\b", p2);
    try testing.expectError(error.Corrupt, hdropPaths(testing.allocator, "short"));
}
