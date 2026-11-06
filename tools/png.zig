//! PNG, as far as the tools need it: writing 8-bit RGBA, reading back the
//! pixels of an 8-bit RGBA image, and an image's width. Enough to draw the
//! icon and to check a panel snapshot, with no image tools.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const Io = std.Io;

const signature = "\x89PNG\r\n\x1a\n";
const ihdr_bytes = 13;
const bit_depth = 8;
const color_rgba = 6;
const channels = 4;
/// The largest image read back: the icon is 1024 square.
pub const side_max = 4096;
const chunks_max = 4096;

pub fn rowBytes(width: u32) usize {
    return @as(usize, width) * channels;
}

/// Writes `pixels` (rows of straight-alpha RGBA, top first) as one PNG, each
/// row unfiltered, deflated at zlib's best.
pub fn write(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    size: struct { width: u32, height: u32 },
    pixels: []const u8,
) !void {
    assert(size.width > 0 and size.height > 0);
    assert(pixels.len == rowBytes(size.width) * size.height);
    const row_bytes = rowBytes(size.width);
    var rows: Io.Writer.Allocating = try .initCapacity(gpa, (row_bytes + 1) * size.height);
    defer rows.deinit();
    for (0..size.height) |row| {
        try rows.writer.writeByte(0); // filter: none
        try rows.writer.writeAll(pixels[row * row_bytes ..][0..row_bytes]);
    }
    var data: Io.Writer.Allocating = try .initCapacity(gpa, rows.written().len / 2 + 64);
    defer data.deinit();
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    compressor.* = try .init(&data.writer, window, .zlib, .best);
    try compressor.writer.writeAll(rows.written());
    try compressor.finish();

    var header: [ihdr_bytes]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], size.width, .big);
    std.mem.writeInt(u32, header[4..8], size.height, .big);
    header[8..].* = .{ bit_depth, color_rgba, 0, 0, 0 };
    try writer.writeAll(signature);
    try writeChunk(writer, "IHDR", &header);
    try writeChunk(writer, "IDAT", data.written());
    try writeChunk(writer, "IEND", "");
}

fn writeChunk(writer: *Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try writer.writeInt(u32, @intCast(data.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc.final(), .big);
}

/// The width an image says it is, or null when it isn't a PNG.
pub fn widthOf(bytes: []const u8) ?u32 {
    if (bytes.len < signature.len + 8 + ihdr_bytes) return null;
    if (!std.mem.eql(u8, bytes[0..signature.len], signature)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return std.mem.readInt(u32, bytes[16..20], .big);
}

pub const Image = struct {
    width: u32,
    height: u32,
    /// Rows of straight-alpha RGBA, top first.
    pixels: []u8,
};

/// The pixels of an 8-bit RGBA PNG without interlacing, in memory the caller
/// frees; error.Unsupported for any other kind. Its bytes come from disk:
/// whatever they say is checked, never trusted.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (widthOf(bytes) == null) return error.NotPng;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    var header: ?[]const u8 = null;
    var at: usize = signature.len;
    var chunks: usize = 0;
    while (at + 12 <= bytes.len) : (chunks += 1) {
        if (chunks == chunks_max) return error.Unsupported;
        const length = std.mem.readInt(u32, bytes[at..][0..4], .big);
        if (length > bytes.len - at - 12) return error.Truncated;
        const kind = bytes[at + 4 ..][0..4];
        const data = bytes[at + 8 ..][0..length];
        if (std.mem.eql(u8, kind, "IHDR")) header = data;
        if (std.mem.eql(u8, kind, "IDAT")) try compressed.appendSlice(gpa, data);
        if (std.mem.eql(u8, kind, "IEND")) break;
        at += 12 + length;
    }
    const ihdr = header orelse return error.Truncated;
    if (ihdr.len != ihdr_bytes) return error.Unsupported;
    const image_width = std.mem.readInt(u32, ihdr[0..4], .big);
    const image_height = std.mem.readInt(u32, ihdr[4..8], .big);
    const kind_ok = ihdr[8] == bit_depth and ihdr[9] == color_rgba and ihdr[12] == 0;
    if (!kind_ok) return error.Unsupported;
    if (image_width == 0 or image_height == 0) return error.Unsupported;
    if (image_width > side_max or image_height > side_max) return error.Unsupported;

    const row_bytes = rowBytes(image_width);
    const filtered = try gpa.alloc(u8, (row_bytes + 1) * image_height);
    defer gpa.free(filtered);
    var input: Io.Reader = .fixed(compressed.items);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&input, .zlib, &window);
    try decompress.reader.readSliceAll(filtered);

    const pixels = try gpa.alloc(u8, row_bytes * image_height);
    errdefer gpa.free(pixels);
    try unfilter(filtered, pixels, row_bytes);
    return .{ .width = image_width, .height = image_height, .pixels = pixels };
}

/// Undoes each row's filter (PNG's five), from `filtered` into `pixels`.
fn unfilter(filtered: []const u8, pixels: []u8, row_bytes: usize) !void {
    const height = pixels.len / row_bytes;
    assert(filtered.len == (row_bytes + 1) * height);
    for (0..height) |row| {
        const line = filtered[row * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const out = pixels[row * row_bytes ..][0..row_bytes];
        const above: ?[]const u8 =
            if (row == 0) null else pixels[(row - 1) * row_bytes ..][0..row_bytes];
        for (out, line[1..], 0..) |*byte, raw, index| {
            const left: u8 = if (index >= channels) out[index - channels] else 0;
            const up: u8 = if (above) |a| a[index] else 0;
            const corner: u8 =
                if (above != null and index >= channels) above.?[index - channels] else 0;
            byte.* = switch (line[0]) {
                0 => raw,
                1 => raw +% left,
                2 => raw +% up,
                3 => raw +% @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => raw +% paeth(left, up, corner),
                else => return error.Unsupported,
            };
        }
    }
}

fn paeth(left: u8, up: u8, corner: u8) u8 {
    const estimate: i16 = @as(i16, left) + up - corner;
    const to_left = @abs(estimate - left);
    const to_up = @abs(estimate - up);
    const to_corner = @abs(estimate - corner);
    if (to_left <= to_up and to_left <= to_corner) return left;
    if (to_up <= to_corner) return up;
    return corner;
}

test "an image written reads back pixel for pixel, and says its width" {
    const gpa = std.testing.allocator;
    var pixels: [3 * 2 * channels]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @intCast((index * 37) % 256);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, .{ .width = 3, .height = 2 }, &pixels);
    try std.testing.expectEqual(@as(?u32, 3), widthOf(out.written()));
    const image = try read(gpa, out.written());
    defer gpa.free(image.pixels);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &pixels, image.pixels);
}

test "each of PNG's filters is undone" {
    // Two rows of one pixel, filtered by Sub, Up, Average and Paeth in turn.
    const row_bytes = channels * 2;
    const want = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 15, 25, 35, 45, 55, 65, 75, 85 };
    var pixels: [want.len]u8 = undefined;
    const sub = [_]u8{ 1, 10, 20, 30, 40, 40, 40, 40, 40 } ++
        [_]u8{ 0, 15, 25, 35, 45, 55, 65, 75, 85 };
    try unfilter(&sub, &pixels, row_bytes);
    try std.testing.expectEqualSlices(u8, &want, &pixels);
    const up = [_]u8{ 0, 10, 20, 30, 40, 50, 60, 70, 80 } ++ [_]u8{ 2, 5, 5, 5, 5, 5, 5, 5, 5 };
    try unfilter(&up, &pixels, row_bytes);
    try std.testing.expectEqualSlices(u8, &want, &pixels);
    const paeth_row = [_]u8{ 0, 10, 20, 30, 40, 50, 60, 70, 80 } ++
        [_]u8{ 4, 5, 5, 5, 5, 5, 5, 5, 5 };
    try unfilter(&paeth_row, &pixels, row_bytes);
    try std.testing.expectEqualSlices(u8, &want, &pixels);
    try std.testing.expectEqual(null, widthOf("GIF89a"));
}
