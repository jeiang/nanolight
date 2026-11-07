//! What a key choice reads as: "⌥ ⌘ Space" on the Mac, "Ctrl Alt Space" on
//! a PC; the modifiers and the key alone, for key caps.
const std = @import("std");
const keys = @import("keys.zig");
const Choice = keys.Choice;
const pc_modifiers = @import("platform.zig").pc_modifiers;

/// "⌥ ⌘ Space", "⌥ X": the modifiers, then the key. On a PC "Ctrl Alt Space".
pub fn text(c: Choice) Text {
    return .{ .choice = c };
}

/// The modifiers' glyphs alone, for a key cap: "⌥⌘".
pub fn held(c: Choice) Mods {
    return .{ .mods = c.mods };
}

/// The key alone, for a key cap: "Space", "X".
pub fn key(c: Choice) Key {
    return .{ .code = c.code, .ch = c.ch };
}

pub const Text = struct {
    choice: Choice,

    pub fn format(t: Text, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const c = t.choice;
        if (pc_modifiers) return w.print("{f} {f}", .{ held(c), key(c) });
        for (glyphs) |g| if (c.mods & g[0] != 0) try w.print("{s} ", .{g[1]});
        try w.print("{f}", .{key(c)});
    }
};

/// In the order macOS draws them.
const glyphs = [_]struct { u32, []const u8 }{
    .{ keys.control, "⌃" },
    .{ keys.option, "⌥" },
    .{ keys.shift, "⇧" },
    .{ keys.cmd, "⌘" },
};

pub const Mods = struct {
    mods: u32,

    pub fn format(m: Mods, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (pc_modifiers) {
            const p = (Choice{ .mods = m.mods }).pc();
            var sep: []const u8 = "";
            for ([_]struct {
                bool,
                []const u8,
            }{ .{ p.ctrl, "Ctrl" }, .{ p.alt, "Alt" }, .{ p.shift, "Shift" } }) |n| if (n[0]) {
                try w.print("{s}{s}", .{ sep, n[1] });
                sep = " ";
            };
            return;
        }
        for (glyphs) |g| if (m.mods & g[0] != 0) try w.writeAll(g[1]);
    }
};

// zig fmt: off
/// Keys that type nothing, but the function keys: their code and name.
const named = [_]struct { u32, []const u8 }{
    .{ keys.space, "Space" }, .{ keys.return_key, "↩" }, .{ keys.keypad_enter, "⌤" },
    .{ 48, "⇥" },    .{ 51, "⌫" },   .{ 117, "⌦" },   .{ keys.escape, "⎋" },  .{ 123, "←" },
    .{ 124, "→" },   .{ 125, "↓" },  .{ 126, "↑" },   .{ 115, "↖" },   .{ 119, "↘" },
    .{ 116, "⇞" },   .{ 121, "⇟" },
};
// zig fmt: on

pub const Key = struct {
    code: u32,
    ch: u21,

    pub fn format(k: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (keys.functionKey(k.code)) |n| return w.print("F{d}", .{n});
        for (named) |n| if (n[0] == k.code) return w.writeAll(n[1]);
        if (k.ch > 0x20 and k.ch != 0x7f) {
            const up: u21 = if (k.ch < 128) std.ascii.toUpper(@intCast(k.ch)) else k.ch;
            var b: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(up, &b) catch return w.print("Key {d}", .{k.code});
            return w.writeAll(b[0..n]);
        }
        try w.print("Key {d}", .{k.code});
    }
};

test "a key reads as its modifiers, then the key" {
    if (pc_modifiers) return error.SkipZigTest;
    const t = std.testing;
    var buf: [keys.name_max]u8 = undefined;
    const x = keys.recorded(7, keys.ns_opt, 'x').key;
    try t.expectEqualStrings("⌥ X", try std.fmt.bufPrint(&buf, "{f}", .{text(x)}));
    try t.expectEqualStrings(
        "⌥ ⌘ Space",
        try std.fmt.bufPrint(&buf, "{f}", .{text(.opt_cmd_space)}),
    );
    try t.expectEqualStrings(
        "⌥⌘",
        try std.fmt.bufPrint(&buf, "{f}", .{held(.opt_cmd_space)}),
    );
    const f5 = keys.recorded(96, keys.ns_ctrl | keys.ns_shift, 0xF708).key;
    try t.expectEqualStrings("⌃ ⇧ F5", try std.fmt.bufPrint(&buf, "{f}", .{text(f5)}));
    try t.expectEqualStrings("F20", try std.fmt.bufPrint(&buf, "{f}", .{key(.{ .code = 90 })}));
}
