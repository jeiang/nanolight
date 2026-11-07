//! The panel's look on Linux, read once at startup: `theme.json` in
//! `$XDG_CONFIG_HOME/nanolight` (or `~/.config/nanolight`), if there, sets
//! the colors (while the theme in Settings is System), the corner radius
//! and the font. Anything can write it: Omarchy's sync writes its theme,
//! Hyprland's rounding and its font. A change shows the next time
//! Nanolight starts. Without the file the panel is dark when the desktop
//! says so: nanoui only looks at `$GTK_THEME`, which most desktops leave
//! unset, so gsettings is asked too.
//!
//! ```json
//! { "dark": true, "background": "#1a1b26", "foreground": "#a9b1d6",
//!   "muted": "#565f89", "accent": "#7aa2f7", "selection": "#283457",
//!   "rounding": 10, "font": "JetBrainsMono Nerd Font" }
//! ```
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;

/// The panel's corners when the file doesn't say.
pub const default_radius: f32 = 18;

const File = struct {
    dark: bool = true,
    background: []const u8 = "#1b1b1c",
    foreground: []const u8 = "#eeeeee",
    muted: []const u8 = "#b5b5b5",
    accent: []const u8 = "#0a84ff",
    selection: []const u8 = "",
    rounding: ?f32 = null,
    font: ?[]const u8 = null,
};

const Look = struct {
    palette: Palette,
    theme: ui.Theme,
    radius: ?f32,
};

var loaded = false;
var look: ?Look = null;
var dark_desktop = false;
var font_buf: [128]u8 = undefined;

/// Reads the file, or asks the desktop whether it is dark. Once: the look
/// holds until the next launch. Nothing on the Mac or Windows.
pub fn load(io: std.Io, env: *const std.process.Environ.Map) void {
    if (loaded) return;
    loaded = true;
    // Tests draw the built-in look, whatever this machine's file says.
    if (builtin.os.tag != .linux or builtin.is_test) return;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var data_buf: [4096]u8 = undefined;
    if (path(env, &path_buf)) |p| if (read(io, p, &data_buf)) |data| {
        look = parse(data, &font_buf);
        if (look != null) return;
    };
    dark_desktop = desktopDark(io, env);
}

/// The panel's colors from the file, if there is one.
pub fn palette() ?Palette {
    return if (look) |l| l.palette else null;
}

/// The panel's corner radius.
pub fn radius() f32 {
    return if (look) |l| l.radius orelse default_radius else default_radius;
}

/// The window's theme: the file's, or dark when the desktop is. Null
/// leaves it to nanoui.
pub fn windowTheme() ?ui.Theme {
    if (look) |l| return l.theme;
    return if (dark_desktop) .dark_theme else null;
}

fn path(env: *const std.process.Environ.Map, buf: []u8) ?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0)
        return std.fmt.bufPrint(buf, "{s}/nanolight/theme.json", .{x}) catch null;
    const home = env.get("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/nanolight/theme.json", .{home}) catch null;
}

fn read(io: std.Io, p: []const u8, buf: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(io, p, buf) catch null;
}

fn rgb(s: []const u8) ?ui.Color {
    const t = if (std.mem.startsWith(u8, s, "#")) s[1..] else s;
    if (t.len != 6) return null;
    return .hex(std.fmt.parseInt(u24, t, 16) catch return null);
}

/// The look a theme.json describes; null if it isn't one. The font's
/// name is copied into `font_out`, which must outlive the look.
fn parse(data: []const u8, font_out: []u8) ?Look {
    var arena_buf: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_buf);
    const f = std.json.parseFromSliceLeaky(
        File,
        fba.allocator(),
        data,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    const bg = rgb(f.background) orelse return null;
    const fg = rgb(f.foreground) orelse return null;
    const muted = rgb(f.muted) orelse fg.alpha(0.7);
    const accent = rgb(f.accent) orelse ui.Color.hex(0x0a84ff);
    const sel = rgb(f.selection) orelse if (f.dark)
        ui.Color.white.alpha(0.16)
    else
        ui.Color.black.alpha(0.08);
    const base = palette_mod.grey(f.dark);
    var t: ui.Theme = if (f.dark) .dark_theme else .light;
    t.background = bg;
    t.surface = sel;
    t.surface_hover = sel;
    t.text = fg;
    t.muted = muted;
    t.accent = accent;
    t.accent_hover = accent;
    t.track = sel;
    if (f.font) |name| if (name.len > 0 and name.len <= font_out.len) {
        @memcpy(font_out[0..name.len], name);
        t.font = font_out[0..name.len];
        t.mono_font = t.font;
    };
    return .{
        // Hairlines, rims and tiles stay the built-in tints of the text's
        // side, so they suit whatever the background is.
        .palette = .{
            .text = fg,
            .sub = muted,
            .hair = base.hair,
            .sel = sel,
            .rim = base.rim,
            .tile = base.tile,
            .fill = bg,
        },
        .theme = t,
        .radius = if (f.rounding) |r| std.math.clamp(r, 0, 32) else null,
    };
}

/// Whether gsettings says the desktop is dark (`prefer-dark`, or a GTK
/// theme named dark), or `$GTK_THEME` does.
fn desktopDark(io: std.Io, env: *const std.process.Environ.Map) bool {
    if (env.get("GTK_THEME")) |v| {
        if (std.ascii.findIgnoreCase(v, "dark") != null) return true;
    }
    return gsettings(io, "color-scheme", "prefer-dark") or
        gsettings(io, "gtk-theme", "dark");
}

fn gsettings(io: std.Io, key: []const u8, needle: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ "gsettings", "get", "org.gnome.desktop.interface", key },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return false;
    // best effort: the answer is in what it printed, not how it ended.
    defer _ = child.wait(io) catch {};
    const out = child.stdout orelse return false;
    var buf: [128]u8 = undefined;
    var got: usize = 0;
    while (got < buf.len) {
        const n = out.readStreaming(io, &.{buf[got..]}) catch break;
        if (n == 0) break;
        got += n;
    }
    return std.ascii.findIgnoreCase(buf[0..got], needle) != null;
}

test "theme.json sets the colors, corners and font" {
    var font: [128]u8 = undefined;
    const l = parse(
        \\{ "dark": true, "background": "#1a1b26", "foreground": "#a9b1d6",
        \\  "muted": "#565f89", "accent": "#7aa2f7", "selection": "#283457",
        \\  "rounding": 10, "font": "JetBrainsMono Nerd Font", "added_later": 1 }
    , &font).?;
    try std.testing.expectEqual(ui.Color.hex(0x1a1b26), l.palette.fill);
    try std.testing.expectEqual(ui.Color.hex(0xa9b1d6), l.palette.text);
    try std.testing.expectEqual(ui.Color.hex(0x283457), l.palette.sel);
    try std.testing.expectEqual(@as(?f32, 10), l.radius);
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font", l.theme.font.?);
    try std.testing.expect(l.theme.dark);
    // An empty object is the defaults; not JSON is no theme at all.
    try std.testing.expectEqual(ui.Color.hex(0x1b1b1c), parse("{}", &font).?.palette.fill);
    try std.testing.expect(parse("nonsense", &font) == null);
    // Rounding outside a panel's corners is clamped.
    const wide = parse(
        \\{ "background": "#1a1b26", "foreground": "#a9b1d6", "rounding": 90 }
    , &font).?;
    try std.testing.expectEqual(@as(?f32, 32), wide.radius);
}
