//! `zig build icon`: Nanolight's icon, after the Bauhaus: a magnifier made of
//! a circle, a ring and a bar, in the primaries on cream, on Apple's macOS
//! icon grid (an 824-pixel tile in 1024) with a soft shadow under the tile.
//!
//! Every shape is a signed distance, so its edge is anti-aliased exactly.
//! This draws src/icon.png, then the Mac's own sips and iconutil make
//! src/icon-256.png and macos/AppIcon.icns from it. src/icon.png is left as
//! it is when its pixels are already these, so that redrawing an unchanged
//! icon changes no file. Run from the repository's root (build.zig does).
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const command = @import("command.zig");
const png = @import("png.zig");

const size = 1024;
const Rgb = [3]f64;
const cream: Rgb = .{ 0xF0, 0xEB, 0xE0 };
const yellow: Rgb = .{ 0xF2, 0xB7, 0x05 };
const black: Rgb = .{ 0x1B, 0x1B, 0x1B };
const red: Rgb = .{ 0xD7, 0x37, 0x2A };
const shadow_color: Rgb = .{ 0, 0, 0 };

const tile_center = 512.0;
const tile_half = 412.0;
const tile_radius = 185.0;
const lens_x = 452.0;
const lens_y = 452.0;
const disc_radius = 132.0;
const ring_radius = 210.0;
const ring_width = 64.0;
// The handle: along 45 degrees from the lens's centre, from 252 to 448 out.
const bar_middle = 350.0;
const bar_half_length = 98.0;
const bar_half_width = 42.0;
const shadow_y = 10.0;
const shadow_sigma = 14.0;
const shadow_alpha = 0.30;

comptime {
    // The tile and the reach of its shadow fit the canvas.
    assert(tile_center + tile_half + shadow_y + 4 * shadow_sigma < size);
    assert(tile_center - tile_half > 0);
}

/// The system's erfc (libSystem's), which drew the committed icon.
extern "c" fn erfc(x: f64) f64;

const icon_path = "src/icon.png";
const small_path = "src/icon-256.png";
const icns_path = "macos/AppIcon.icns";
const icon_bytes_max = 16 << 20;
/// The iconset's sizes, each also at twice the size (`@2x`).
const iconset_sides = [_]u32{ 16, 32, 128, 256, 512 };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const pixels = try gpa.alloc(u8, png.rowBytes(size) * size);
    defer gpa.free(pixels);
    draw(pixels);
    if (try samePixels(gpa, io, pixels)) {
        command.say(io, "{s}: its pixels are these already; kept", .{icon_path});
    } else {
        var out: Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try png.write(gpa, &out.writer, .{ .width = size, .height = size }, pixels);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = icon_path, .data = out.written() });
        command.say(io, "{s}", .{icon_path});
    }
    try resize(io, arena, .{ .side = 256, .to = small_path });
    command.say(io, "{s}", .{small_path});

    const iconset_parent = try command.temporaryFolder(arena, io, "nanolight-icon");
    defer Io.Dir.cwd().deleteTree(io, iconset_parent) catch {}; // best effort: a temp folder.
    const iconset = try std.fs.path.join(arena, &.{ iconset_parent, "AppIcon.iconset" });
    try Io.Dir.cwd().createDir(io, iconset, .default_dir);
    for (iconset_sides) |side| {
        const one = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}.png", .{
            iconset, side, side,
        });
        try resize(io, arena, .{ .side = side, .to = one });
        const two = try std.fmt.allocPrint(arena, "{s}/icon_{d}x{d}@2x.png", .{
            iconset, side, side,
        });
        try resize(io, arena, .{ .side = side * 2, .to = two });
    }
    try command.run(io, &.{ "iconutil", "-c", "icns", "-o", icns_path, iconset });
    command.say(io, "{s}", .{icns_path});
}

/// src/icon.png made `side` pixels square by sips, as the committed sizes were.
fn resize(io: Io, arena: std.mem.Allocator, options: struct { side: u32, to: []const u8 }) !void {
    assert(options.side > 0 and options.side <= size);
    const side = try std.fmt.allocPrint(arena, "{d}", .{options.side});
    const result = try command.capture(arena, io, &.{
        "sips", "-z", side, side, icon_path, "--out", options.to,
    }, .{});
    if (result.ok()) return;
    command.complain(io, "sips: {s}", .{result.text});
    return error.CommandFailed;
}

/// Whether src/icon.png holds exactly `pixels` (its bytes may differ: any
/// encoder's deflate is its own).
fn samePixels(gpa: std.mem.Allocator, io: Io, pixels: []const u8) !bool {
    const limit: Io.Limit = .limited(icon_bytes_max);
    const bytes = Io.Dir.cwd().readFileAlloc(io, icon_path, gpa, limit) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer gpa.free(bytes);
    const image = png.read(gpa, bytes) catch return false;
    defer gpa.free(image.pixels);
    if (image.width != size or image.height != size) return false;
    return std.mem.eql(u8, image.pixels, pixels);
}

/// The whole icon, row by row, each pixel sampled at its centre.
fn draw(pixels: []u8) void {
    assert(pixels.len == png.rowBytes(size) * size);
    for (0..size) |row| {
        for (0..size) |column| {
            const x = @as(f64, @floatFromInt(column)) + 0.5;
            const y = @as(f64, @floatFromInt(row)) + 0.5;
            const at = (row * size + column) * 4;
            pixels[at..][0..4].* = straight(pixel(x, y));
        }
    }
}

/// Premultiplied red, green, blue and alpha.
const Premultiplied = [4]f64;

/// Straight alpha, as PNG keeps it, rounded half to even as Python's round().
fn straight(px: Premultiplied) [4]u8 {
    const alpha = px[3];
    if (!(alpha > 0.0)) return .{ 0, 0, 0, 0 };
    return .{
        byteOf(roundEven(px[0] / alpha)),
        byteOf(roundEven(px[1] / alpha)),
        byteOf(roundEven(px[2] / alpha)),
        byteOf(roundEven(alpha * 255)),
    };
}

fn byteOf(value: f64) u8 {
    assert(value >= 0 and value <= 255);
    return @intFromFloat(value);
}

fn roundEven(value: f64) f64 {
    const floor = @floor(value);
    const fraction = value - floor;
    if (fraction > 0.5) return floor + 1;
    if (fraction < 0.5) return floor;
    return if (@mod(floor, 2) == 0) floor else floor + 1;
}

fn pixel(x: f64, y: f64) Premultiplied {
    var px: Premultiplied = .{ 0, 0, 0, 0 };
    const shadow_distance = roundedBox(.{ .x = x, .y = y - shadow_y });
    if (shadow_distance < 4 * shadow_sigma) {
        const spread = shadow_distance / (shadow_sigma * @sqrt(2.0));
        px = over(px, shadow_color, shadow_alpha * 0.5 * erfc(spread));
    }
    const tile_distance = roundedBox(.{ .x = x, .y = y });
    if (tile_distance > 1.0) return px;
    px = over(px, cream, cover(tile_distance));
    const dx = x - lens_x;
    const dy = y - lens_y;
    if (@abs(dx) > 400 or @abs(dy) > 400) return px;
    const distance = std.math.hypot(dx, dy);
    px = over(px, yellow, cover(distance - disc_radius));
    px = over(px, black, cover(@abs(distance - ring_radius) - ring_width / 2));
    const u = (dx + dy) / @sqrt(2.0) - bar_middle;
    const v = (dy - dx) / @sqrt(2.0);
    px = over(px, red, cover(box(u, v)));
    return px;
}

/// The signed distance to the tile, a rounded square.
fn roundedBox(point: struct { x: f64, y: f64 }) f64 {
    const qx = @abs(point.x - tile_center) - (tile_half - tile_radius);
    const qy = @abs(point.y - tile_center) - (tile_half - tile_radius);
    const outside = std.math.hypot(@max(qx, 0.0), @max(qy, 0.0));
    return outside + @min(@max(qx, qy), 0.0) - tile_radius;
}

/// The signed distance to the handle, a box along its own axes.
fn box(u: f64, v: f64) f64 {
    const qx = @abs(u) - bar_half_length;
    const qy = @abs(v) - bar_half_width;
    return std.math.hypot(@max(qx, 0.0), @max(qy, 0.0)) + @min(@max(qx, qy), 0.0);
}

/// A shape's share of a pixel, from the distance at its centre.
fn cover(distance: f64) f64 {
    return @min(1.0, @max(0.0, 0.5 - distance));
}

/// Paints `rgb` at alpha `alpha` over the premultiplied `px`.
fn over(px: Premultiplied, rgb: Rgb, alpha: f64) Premultiplied {
    if (alpha <= 0.0) return px;
    const keep = 1.0 - alpha;
    return .{
        rgb[0] * alpha + px[0] * keep,
        rgb[1] * alpha + px[1] * keep,
        rgb[2] * alpha + px[2] * keep,
        alpha + px[3] * keep,
    };
}
