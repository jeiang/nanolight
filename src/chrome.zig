//! What every screen of the panel, and every window that holds it, lays out
//! alike: the panel's size, the heights of its header, footer, rows and
//! section heads, and the pieces drawn the same on each screen (the footer,
//! a section's head, a row's name and detail, an icon's tile, a shortcut
//! chip), with the keys that move a selection.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const Palette = @import("palette.zig").Palette;
const app_facts = @import("app_facts.zig");

/// Clipboard history's name, as its row, its screen and Settings say it.
pub const clipboard_title = "Clipboard History";

pub const width: f32 = app_facts.panel_width;
/// The room a window leaves round the panel for its shadow (`Fit.margin`).
pub const shadow_margin: f32 = 40;
pub const header_h = 58;
pub const footer_h = 38;
pub const row_h = 40;
/// Round a list of rows, inside its hairlines.
pub const list_pad = 6;
/// A row's padding at either side, and the gap between its parts.
pub const row_px = 10;
pub const row_gap = 12;

/// A section's head over rows: its height, the name at its bottom.
pub const Section = struct { h: f32, pb: f32 };
/// Over the launcher's rows.
pub const section: Section = .{ .h = 28, .pb = 6 };
/// Over a script's actions (raycast_view.zig): a little tighter, as the
/// list has no other section.
pub const actions_section: Section = .{ .h = 26, .pb = 4 };

/// The rows and section heads the tallest list holds (results.zig's
/// `max_rows` and `max_heads`, which assert them).
pub const max_rows = 14;
pub const max_heads = 3;
/// The tallest the panel gets: the tallest list (math lists fewer), or a
/// search's page. The window is this tall.
pub const max_height: f32 = header_h + footer_h + 2 + list_pad * 2 +
    max_rows * row_h + max_heads * section.h;

/// Where a search's page goes in a panel `h` tall: from `y` down from its
/// top, `h` tall, between the header and the footer, the panel's width.
pub fn webArea(h: f32) struct { y: f32, h: f32 } {
    return .{ .y = header_h + 1, .h = @max(0, h - header_h - footer_h - 2) };
}

/// How a platform's window holds the panel (panel_mac/panel_pc `setup`).
pub const Fit = struct {
    /// Clear room round the panel in its window, for its shadow.
    margin: f32 = 0,
    /// The window fades in as it shows, the system's glass with it: the
    /// panel has no entrance of its own (issue #9).
    window_fades: bool = false,
};

/// A screen coming in: snappy, a touch under critical damping.
pub const spring: motion.Spring = .{ .stiffness = 320, .damping = 32 };

/// The app's icon (icon.png, made smaller), for the panel.
pub const icon_png = @embedFile("icon-256.png");

/// The app's icon, `size` points square.
pub fn appIcon(c: *ui.Context, size: f32) void {
    _ = ui.image(
        c,
        .{
            .key = "nanolight-icon",
            .bytes = icon_png,
            .max_width = size,
            .max_height = size,
            .radius = 0,
            .scale = 2,
        },
    );
}

/// ↓, ^N or ^J; offered before a field, so the key never edits.
pub fn moveDown(c: *ui.Context) bool {
    const S = ui.Shortcut;
    return c.shortcut(.{ .key = S.down }) or c.shortcut(.{ .key = 'n', .ctrl = true }) or
        c.shortcut(.{ .key = 'j', .ctrl = true });
}

/// ↑, ^P or ^K.
pub fn moveUp(c: *ui.Context) bool {
    const S = ui.Shortcut;
    return c.shortcut(.{ .key = S.up }) or c.shortcut(.{ .key = 'p', .ctrl = true }) or
        c.shortcut(.{ .key = 'k', .ctrl = true });
}

/// ⌘1…⌘`n` (at most 9): the place of the one pressed.
pub fn numberKey(c: *ui.Context, n: usize) ?usize {
    for (0..@min(n, 9)) |k| {
        if (c.shortcut(.{ .key = @intCast('1' + k), .cmd = true })) return k;
    }
    return null;
}

/// Return, as a key or as the field's newline command, acted on once for
/// each key event: a frame may draw twice.
pub const Return = struct {
    took: bool = false,

    /// Whether Return was pressed in this event, and not acted on yet.
    pub fn once(r: *Return, c: *const ui.Context) bool {
        if (!pressed(c)) {
            r.took = false;
            return false;
        }
        if (r.took) return false;
        r.took = true;
        return true;
    }

    fn pressed(c: *const ui.Context) bool {
        if (c.input.key == .enter) return true;
        for (c.input.ops) |op| if (op == .command and op.command == .insert_newline) return true;
        return false;
    }
};

/// The line across the panel between its parts.
pub fn hairline(c: *ui.Context, p: Palette) void {
    ui.div(c).wFull().h(1).bg(p.hair).end();
}

/// The footer's bar, under its hairline, with what the screen puts in it;
/// the caller ends it.
pub fn footer(c: *ui.Context, p: Palette) ui.Div {
    hairline(c, p);
    return ui.div(c).row().wFull().h(footer_h).px(16).gap(8).itemsCenter();
}

/// One of the footer's keys: what it does, then the key. The first is
/// the screen's main act, stronger than the rest.
pub fn footerKey(c: *ui.Context, p: Palette, what: []const u8, key: []const u8, first: bool) void {
    ui.text(c, what, if (first) p.action() else p.detail());
    ui.kbd(c, key);
}

/// The line between two of the footer's keys.
pub fn keySep(c: *ui.Context, p: Palette) void {
    ui.div(c).w(1).h(14).bg(p.hair).end();
}

/// The footer's last key: Escape closes the screen.
pub fn closeKey(c: *ui.Context, p: Palette) void {
    footerKey(c, p, close.what, close.key, close.first);
}

pub const Key = struct {
    what: []const u8,
    key: []const u8,
    first: bool = false,
};
const close: Key = .{ .what = "Close", .key = "esc" };

/// A screen's own footer keys, a line between each, then Close.
pub fn footerKeys(c: *ui.Context, p: Palette, keys: []const Key) void {
    footerKeysThen(c, p, keys, close);
}

/// The footer's keys, a line between each, then `last`: Escape's, when it
/// does other than close.
pub fn footerKeysThen(c: *ui.Context, p: Palette, keys: []const Key, last: Key) void {
    for (keys) |k| {
        footerKey(c, p, k.what, k.key, k.first);
        keySep(c, p);
    }
    footerKey(c, p, last.what, last.key, last.first);
}

/// A section's name, at the bottom of its head.
pub fn sectionHead(c: *ui.Context, p: Palette, name: []const u8, s: Section) void {
    const head = ui.div(c).row().wFull().h(s.h).px(12).pb(s.pb).itemsEnd();
    defer head.end();
    ui.text(c, name, p.heading());
}

/// A row's name, its matched letters in `spans`, and what it is.
pub fn nameDetail(
    c: *ui.Context,
    p: Palette,
    name: []const u8,
    spans: []const ui.Span,
    detail: []const u8,
    truncate: ui.Truncate,
) void {
    ui.richText(c, name, spans, p.name());
    var style = p.detail();
    style.truncate = truncate;
    ui.text(c, detail, style);
}

/// A row's picture when it has no image of its own: a symbol on a quiet tile.
pub fn tile(c: *ui.Context, p: Palette, icon: []const u8) void {
    const box = ui.div(c).size(26, 26).rounded(7).bg(p.tile).center();
    defer box.end();
    ui.icon(c, icon, .{ .size = 13, .weight = .medium, .color = p.text });
}

/// A row's picture: an app's or a file's icon, `key` naming it.
pub fn iconImage(c: *ui.Context, key: []const u8, png: []const u8) void {
    const box = ui.div(c).size(26, 26).center();
    defer box.end();
    _ = ui.image(
        c,
        .{
            .key = key,
            .bytes = png,
            .max_width = 26,
            .max_height = 26,
            .radius = 0,
            .scale = 1,
        },
    );
}

/// A shortcut chip's padding and text size: Settings' (a row of five)
/// and the welcome's (bigger, the step's one choice).
pub const Chip = struct { px: f32, size: f32 };
pub const settings_chip: Chip = .{ .px = 14, .size = 13.5 };
pub const welcome_chip: Chip = .{ .px = 16, .size = 14 };
/// Every chip's height, whichever its size.
pub const chip_h: f32 = 36;

/// A shortcut to pick, `on` when it is the one in use, saying `label`.
/// The caller keys it, reads its click, and ends it (after a key cap, if any).
pub fn shortcutChip(c: *ui.Context, p: Palette, label: []const u8, on: bool, size: Chip) ui.Div {
    const b = ui.div(c).row().h(chip_h).px(size.px).gap(6).itemsCenter().rounded(10).control()
        .bg(if (on) p.sel else p.tile.alpha(0.5)).border(if (on) p.text.alpha(0.35) else p.rim);
    const weight: ui.Weight = if (on) .semibold else .medium;
    ui.text(c, label, .{ .size = size.size, .weight = weight, .color = if (on) p.text else p.sub });
    return b;
}
