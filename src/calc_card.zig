//! The math row: the expression, an arrow, the answer, each over a small
//! label; the answer's says Copied once it is, and a conversion's names
//! its rate.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;

/// The row's height: the answer over its chip, with room round them.
pub const height: f32 = 92;
const arrow_side = 32;

/// Into a row of the list (view.zig `row`): its padding and gaps leave the
/// expression and the answer half each of what the arrow does not take.
pub fn draw(
    c: *ui.Context,
    p: Palette,
    query: []const u8,
    answer: []const u8,
    hex: []const u8,
    note: []const u8,
    copied: bool,
) void {
    const inner = chrome.width - chrome.list_pad * 2 - chrome.row_px * 2;
    const half = (inner - arrow_side - chrome.row_gap * 2) / 2;
    {
        const l = ui.div(c).column().w(half).itemsCenter().gap(6);
        defer l.end();
        ui.text(
            c,
            std.mem.trim(u8, query, " ="),
            .{ .size = 20, .weight = .medium, .color = p.text.alpha(0.8), .tabular = true },
        );
        chip(c, p, "Expression", null);
    }
    {
        const arrow = ui.div(c).size(arrow_side, arrow_side).roundedFull().bg(p.tile).center();
        defer arrow.end();
        ui.icon(c, "arrow.right", .{ .size = 13, .weight = .semibold, .color = p.sub });
    }
    const r = ui.div(c).column().w(half).itemsCenter().gap(6);
    defer r.end();
    ui.text(
        c,
        answer,
        .{ .size = 28, .weight = .semibold, .color = p.text, .tabular = true, .tracking = -0.3 },
    );
    if (copied) {
        c.animationFrame();
        chip(c, p, "Copied", c.theme.success);
    } else chip(
        c,
        p,
        if (note.len > 0) note else if (hex.len > 0) c.print("Result · {s}", .{hex}) else "Result",
        null,
    );
}

fn chip(c: *ui.Context, p: Palette, str: []const u8, tone: ?ui.Color) void {
    const d = ui.div(c).row().gap(4).px(8).h(20).itemsCenter().rounded(6)
        .bg(if (tone) |t| t.alpha(0.16) else p.tile);
    defer d.end();
    if (tone) |t| ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = t });
    ui.text(
        c,
        str,
        .{ .size = 11, .weight = .medium, .color = tone orelse p.sub, .tabular = true },
    );
}
