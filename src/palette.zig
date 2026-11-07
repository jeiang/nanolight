//! The panel's colors, light and dark: text, rows, hairlines, tiles. A
//! theme other than `system` tints them with its hue, light or dark still
//! as the system is (nanoui's own controls follow the system too). And the
//! roles text plays on every screen, each one style.
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Palette = struct {
    text: ui.Color,
    sub: ui.Color,
    hair: ui.Color,
    sel: ui.Color,
    rim: ui.Color,
    tile: ui.Color,
    fill: ui.Color,

    /// A row's name.
    pub fn name(p: Palette) ui.TextStyle {
        return .{ .size = 13.5, .weight = .medium, .color = p.text.alpha(0.82) };
    }

    /// What a row is, and the footer's lesser keys.
    pub fn detail(p: Palette) ui.TextStyle {
        return .{ .size = 12, .color = p.sub.alpha(0.8) };
    }

    /// The footer's main act: what Return does.
    pub fn action(p: Palette) ui.TextStyle {
        return .{ .size = 12, .weight = .medium, .color = p.text.alpha(0.85) };
    }

    /// The footer's own words: the app's name, or the screen's.
    pub fn caption(p: Palette) ui.TextStyle {
        return .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.8) };
    }

    /// A section's name.
    pub fn heading(p: Palette) ui.TextStyle {
        return .{ .size = 11.5, .weight = .semibold, .color = p.sub.alpha(0.85) };
    }

    /// A row's ⌘1…⌘9.
    pub fn hint(p: Palette) ui.TextStyle {
        return .{ .size = 12, .weight = .medium, .color = p.sub.alpha(0.5), .tabular = true };
    }

    /// Said in place of what is still to come ("Searching Google…").
    pub fn waiting(p: Palette) ui.TextStyle {
        return .{ .size = 13, .color = p.sub.alpha(0.8) };
    }

    pub fn placeholder(p: Palette) ui.Color {
        return p.sub.alpha(0.75);
    }
};

const pc = @import("builtin").os.tag != .macos;

/// The panel's tint, chosen in Settings (`nanolight.theme`).
pub const Theme = enum {
    system,
    ocean,
    forest,
    rose,
    amber,
    violet,

    pub const all = [_]Theme{ .system, .ocean, .forest, .rose, .amber, .violet };

    pub fn title(t: Theme) []const u8 {
        return switch (t) {
            .system => "System",
            .ocean => "Ocean",
            .forest => "Forest",
            .rose => "Rose",
            .amber => "Amber",
            .violet => "Violet",
        };
    }

    /// The theme's hue: brighter over dark, deeper over light. Null for
    /// `system`, which keeps the greys.
    pub fn hue(t: Theme, dark: bool) ?ui.Color {
        const pair: [2]u24 = switch (t) {
            .system => return null,
            .ocean => .{ 0x4aa8ff, 0x0a6fd6 },
            .forest => .{ 0x4fd18b, 0x1e8a50 },
            .rose => .{ 0xff6f9c, 0xd23a6c },
            .amber => .{ 0xffb340, 0xc26a00 },
            .violet => .{ 0xb08cff, 0x7041d9 },
        };
        return .hex(if (dark) pair[0] else pair[1]);
    }

    /// The next or previous one, round.
    pub fn step(t: Theme, dir: i8) Theme {
        const n: i8 = all.len;
        const i: i8 = @intCast(@backingInt(t));
        return all[@intCast(@mod(i + dir, n))];
    }
};

pub fn palette(dark: bool, theme: Theme) Palette {
    const base = grey(dark);
    const h = theme.hue(dark) orelse return base;
    return if (dark) .{
        .text = base.text,
        .sub = base.sub.mix(h, 0.25),
        .hair = h.alpha(0.22),
        .sel = h.alpha(0.3),
        .rim = h.alpha(0.2),
        .tile = h.alpha(0.16),
        .fill = if (pc)
            ui.Color.hex(0x161616).mix(h, 0.14)
        else
            ui.Color.hex(0x141414).mix(h, 0.18).alpha(0.72),
    } else .{
        .text = base.text,
        .sub = base.sub.mix(h, 0.2),
        .hair = h.alpha(0.18),
        .sel = h.alpha(0.18),
        .rim = h.alpha(0.14),
        .tile = h.alpha(0.12),
        .fill = if (pc)
            ui.Color.hex(0xfafafa).mix(h, 0.08)
        else
            ui.Color.white.mix(h, 0.1).alpha(0.7),
    };
}

fn grey(dark: bool) Palette {
    return if (dark) .{
        .text = .hex(0xeeeeee),
        .sub = .hex(0xb5b5b5),
        .hair = ui.Color.white.alpha(0.12),
        .sel = ui.Color.white.alpha(0.16),
        .rim = ui.Color.white.alpha(0.1),
        .tile = ui.Color.white.alpha(0.09),
        // Over the Mac's vibrancy; solid on a PC, whose window is clear.
        .fill = if (pc) ui.Color.hex(0x1b1b1c) else ui.Color.hex(0x1a1a1a).alpha(0.5),
    } else .{
        .text = .hex(0x292929),
        .sub = .hex(0x6f6f6f),
        .hair = ui.Color.black.alpha(0.09),
        .sel = ui.Color.black.alpha(0.08),
        .rim = ui.Color.black.alpha(0.05),
        .tile = ui.Color.black.alpha(0.05),
        .fill = if (pc) ui.Color.hex(0xf9f9fa) else ui.Color.white.alpha(0.45),
    };
}

test "a theme tints the greys and steps round" {
    const t = @import("std").testing;
    try t.expect(!@import("std").meta.eql(grey(true).sel, palette(true, .ocean).sel));
    try t.expectEqual(Theme.violet, Theme.system.step(-1));
    try t.expectEqual(Theme.system, Theme.violet.step(1));
    try t.expectEqual(Theme.ocean, Theme.system.step(1));
}
