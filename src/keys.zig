//! The key combination that opens the panel, as a value: the key, by where it
//! is on the keyboard (macOS's virtual key code, which Carbon takes, whatever
//! the layout), and Carbon's modifier bits, on every OS. A Mac takes any key;
//! a PC grabs Space with one of four sets of modifiers (`any_key`).
const std = @import("std");
const builtin = @import("builtin");

/// Carbon's modifier bits.
pub const cmd: u32 = 1 << 8;
pub const shift: u32 = 1 << 9;
pub const option: u32 = 1 << 11;
pub const control: u32 = 1 << 12;
const all_mods = cmd | shift | option | control;

/// AppKit's modifier flags (`NSEventModifierFlags`).
pub const ns_shift: u64 = 1 << 17;
pub const ns_ctrl: u64 = 1 << 18;
pub const ns_opt: u64 = 1 << 19;
pub const ns_cmd: u64 = 1 << 20;
pub const ns_mods: u64 = ns_shift | ns_ctrl | ns_opt | ns_cmd;

/// macOS's virtual key codes (kVK_*).
pub const space: u32 = 49;
pub const escape: u32 = 53;
pub const return_key: u32 = 36;
pub const keypad_enter: u32 = 76;
pub const left_bracket: u32 = 33;
/// F1 to F20, in order: the keys that may open the panel alone.
const function_keys = [_]u32{
    122, 120, 99,  118, 96,  97,  98, 100, 101, 109,
    103, 111, 105, 107, 113, 106, 64, 79,  80,  90,
};

/// Which function key `code` is (1 for F1), or null.
pub fn functionKey(code: u32) ?u8 {
    for (function_keys, 1..) |k, n| if (k == code) return @intCast(n);
    return null;
}

/// A Mac's Carbon hot key is any key; a PC grabs Space with an offered key's
/// modifiers (hotkey_win.zig, hotkey_x11.zig), so there only the four are
/// offered and kept.
pub const any_key = builtin.os.tag == .macos;

/// What the hot key calls, on the main thread (hotkey.zig).
pub const Pressed = struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque) void };

/// The modifiers held on a PC (Windows, Linux).
pub const Pc = struct { ctrl: bool = false, alt: bool = false, shift: bool = false };

/// The keys that open the panel. Four are offered; on the Mac any other can
/// be recorded in Settings.
pub const Choice = struct {
    code: u32 = space,
    /// Carbon's modifier bits.
    mods: u32 = cmd,
    /// What the key types, for its name (a recorded key's; 0: by its code).
    ch: u21 = 0,

    /// An offered key: the name it is kept and synced by (as before), and
    /// the modifiers it stands for on a PC.
    const Preset = struct { mods: u32, name: []const u8, pc: Pc };
    /// The four offered, in their order. The PC's sit where the Mac's do
    /// on a PC keyboard: Alt where ⌘ is (PowerToys Run and KRunner open on
    /// Alt Space).
    const presets = [_]Preset{
        .{ .mods = cmd, .name = "cmd_space", .pc = .{ .alt = true } },
        .{ .mods = option, .name = "opt_space", .pc = .{ .ctrl = true, .alt = true } },
        .{ .mods = control, .name = "ctrl_space", .pc = .{ .ctrl = true } },
        .{ .mods = option | cmd, .name = "opt_cmd_space", .pc = .{ .ctrl = true, .shift = true } },
    };

    pub const all = blk: {
        var out: [presets.len]Choice = undefined;
        for (presets, &out) |p, *c| c.* = .{ .mods = p.mods };
        break :blk out;
    };
    pub const cmd_space = all[0];
    pub const opt_space = all[1];
    pub const ctrl_space = all[2];
    pub const opt_cmd_space = all[3];

    pub fn eql(a: Choice, b: Choice) bool {
        return a.code == b.code and a.mods == b.mods;
    }

    /// Which of `all` it is; null for a recorded key.
    pub fn preset(c: Choice) ?usize {
        for (all, 0..) |p, i| if (p.eql(c)) return i;
        return null;
    }

    /// The offered one before or after it (from a recorded key: the last
    /// or the first).
    pub fn step(c: Choice, dir: i8) Choice {
        const i = c.preset() orelse return all[if (dir < 0) all.len - 1 else 0];
        return all[if (dir < 0) (i + all.len - 1) % all.len else (i + 1) % all.len];
    }

    /// The modifiers held on a PC: an offered key's from its preset;
    /// anything else, by its bits.
    pub fn pc(c: Choice) Pc {
        if (c.preset()) |i| return presets[i].pc;
        return .{
            .ctrl = c.mods & (cmd | control) != 0,
            .alt = c.mods & option != 0,
            .shift = c.mods & shift != 0,
        };
    }

    /// AppKit's modifier flags, as the system's shortcut table keeps them.
    pub fn appkit(c: Choice) u64 {
        var f: u64 = 0;
        if (c.mods & cmd != 0) f |= ns_cmd;
        if (c.mods & option != 0) f |= ns_opt;
        if (c.mods & control != 0) f |= ns_ctrl;
        if (c.mods & shift != 0) f |= ns_shift;
        return f;
    }

    /// Fit to open the panel: with ⌘, ⌥ or ⌃ (Shift alone would take a
    /// letter from typing everywhere), or a function key by itself.
    pub fn usable(c: Choice) bool {
        if (c.code > 127 or c.mods & ~all_mods != 0) return false;
        return c.mods & (cmd | option | control) != 0 or functionKey(c.code) != null;
    }

    /// One this OS can take (`any_key`).
    pub fn available(c: Choice) bool {
        return if (any_key) c.usable() else c.preset() != null;
    }

    /// How it is kept and synced: an offered one's name, else
    /// "key:<code>:<mods>:<char>" (older versions ignore it). Only a
    /// usable key is kept: its name always fits `name_max`.
    pub fn name(c: Choice, buf: *[name_max]u8) []const u8 {
        if (c.preset()) |i| return presets[i].name;
        std.debug.assert(c.usable());
        const fields = .{ c.code, c.mods, c.ch };
        return std.fmt.bufPrint(buf, "key:{d}:{d}:{d}", fields) catch unreachable;
    }

    /// A kept name, if it is a key this OS can take.
    pub fn parse(s: []const u8) ?Choice {
        for (presets, all) |p, c| if (std.mem.eql(u8, s, p.name)) return c;
        if (!std.mem.startsWith(u8, s, "key:")) return null;
        var it = std.mem.splitScalar(u8, s[4..], ':');
        const c: Choice = .{
            .code = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .mods = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null,
            .ch = std.fmt.parseInt(u21, it.next() orelse return null, 10) catch return null,
        };
        return if (it.next() == null and c.available()) c else null;
    }
};

/// The longest name `Choice.name` gives, which a synced record carries
/// (settings.zig): a usable recorded key's (code ≤ 127, `all_mods`, any
/// char) and every preset's fit.
pub const name_max = 32;
comptime {
    const max_ch = std.math.maxInt(u21);
    const longest = std.fmt.comptimePrint("key:{d}:{d}:{d}", .{ 127, all_mods, max_ch });
    std.debug.assert(longest.len <= name_max);
    for (Choice.presets) |p| std.debug.assert(p.name.len <= name_max);
}

/// A key pressed while Settings records one (recorder.zig).
pub const Recorded = union(enum) {
    key: Choice,
    /// Esc by itself: recording stops, the key stays as it was.
    cancel,
    /// Not fit to open the panel (`Choice.usable`): it waits for another.
    unusable,
};

/// The key event's code, AppKit's modifier flags and the character the
/// key types without modifiers, as a recorded key.
pub fn recorded(code: u16, flags: u64, ch: u21) Recorded {
    var mods: u32 = 0;
    if (flags & ns_cmd != 0) mods |= cmd;
    if (flags & ns_opt != 0) mods |= option;
    if (flags & ns_ctrl != 0) mods |= control;
    if (flags & ns_shift != 0) mods |= shift;
    if (code == escape and mods == 0) return .cancel;
    const c: Choice = .{
        .code = code,
        .mods = mods,
        // AppKit types the keys that type nothing as private-use characters.
        .ch = if (ch > 0x20 and ch != 0x7f and ch < 0xF700) ch else 0,
    };
    return if (c.usable()) .{ .key = c } else .unusable;
}

test "any key with ⌘, ⌥ or ⌃ can be recorded and kept" {
    const t = std.testing;
    // ⌥X, as AppKit reports it: X's code, Option's flag, "x".
    const r = recorded(7, ns_opt, 'x');
    try t.expect(r == .key);
    const x = r.key;
    try t.expectEqual(@as(u32, 7), x.code);
    try t.expectEqual(option, x.mods);
    try t.expectEqual(@as(?usize, null), x.preset());
    // Kept as its code, so a layout's letters don't move it.
    var buf: [name_max]u8 = undefined;
    try t.expectEqualStrings("key:7:2048:120", x.name(&buf));
    // The offered ones keep the names older versions read.
    try t.expectEqualStrings("opt_space", Choice.opt_space.name(&buf));
    try t.expect(Choice.parse("ctrl_space").?.eql(.ctrl_space));
    // ⇧⌃F5 and F5 by itself are fine; a letter alone or with Shift is not.
    try t.expect(recorded(96, ns_ctrl | ns_shift, 0xF708) == .key);
    try t.expect(recorded(96, 0, 0xF708) == .key);
    try t.expect(recorded(7, 0, 'x') == .unusable);
    try t.expect(recorded(7, ns_shift, 'x') == .unusable);
    try t.expect(recorded(escape, 0, 0x1b) == .cancel);
    // Garbled or unusable kept values fall back.
    try t.expect(Choice.parse("key:7:0:120") == null);
    try t.expect(Choice.parse("key:7:2048") == null);
    try t.expect(Choice.parse("cmd_spaces") == null);
    // Stepping from a recorded key lands on the offered ones.
    try t.expect(x.step(1).eql(.cmd_space));
    try t.expect(Choice.cmd_space.step(-1).eql(.opt_cmd_space));
}

test "a recorded key is read back on the Mac, and only the four on a PC" {
    var buf: [name_max]u8 = undefined;
    const kept = recorded(7, ns_opt, 'x').key.name(&buf);
    const back = Choice.parse(kept);
    if (any_key) try std.testing.expect(back.?.eql(.{ .code = 7, .mods = option })) else {
        try std.testing.expect(back == null);
    }
}
