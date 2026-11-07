//! Who else may answer a key choice. Carbon grants a hot key even when another
//! app holds the same one, so clashes are found here instead: in the system's
//! own shortcuts (Spotlight's ⌘Space, the input sources' ⌃Space) and among
//! the launchers that are running, as shortcut_holders.zig finds them. On a
//! PC, in the keys another program holds.
const std = @import("std");
const keys = @import("keys.zig");
const Choice = keys.Choice;

/// The system's shortcuts, by their id in `com.apple.symbolichotkeys`: those
/// that may hold an offered key are named.
pub const System = enum(u32) {
    input_source_previous = 60,
    input_source_next = 61,
    spotlight = 64,
    finder_search = 65,
    _,

    fn name(s: System) []const u8 {
        return switch (s) {
            .spotlight => "Spotlight",
            .finder_search => "Finder's search window",
            .input_source_previous, .input_source_next => "the input source switcher",
            _ => "a macOS shortcut",
        };
    }

    /// The key it holds on a Mac whose table doesn't list it.
    pub fn default(s: System) ?Choice {
        return switch (s) {
            .spotlight => .cmd_space,
            .finder_search => .opt_cmd_space,
            else => null,
        };
    }
};

/// One of the system's shortcuts, as `com.apple.symbolichotkeys` keeps it.
pub const SystemKey = struct { id: System, enabled: bool, key: u32, mods: u64 };

const Launcher = struct { bundle: []const u8, name: []const u8, keys: []const Choice };
/// They open on ⌘Space or ⌥Space, as set up; ⌃Space and ⌥⌘Space are quiet.
const space_launcher: []const Choice = &.{ .cmd_space, .opt_space };
pub const known_launchers = [_]Launcher{
    .{ .bundle = "com.raycast.macos", .name = "Raycast", .keys = space_launcher },
    .{ .bundle = "com.runningwithcrayons.Alfred", .name = "Alfred", .keys = space_launcher },
    .{ .bundle = "com.peeklight.peekalight", .name = "Peekalight", .keys = space_launcher },
    .{ .bundle = "at.obdev.LaunchBar", .name = "LaunchBar", .keys = space_launcher },
};

/// Launchers by name: those running, those in the way.
pub const Launchers = struct {
    names: [known_launchers.len][]const u8 = undefined,
    n: usize = 0,

    pub fn slice(l: *const Launchers) []const []const u8 {
        return l.names[0..l.n];
    }

    pub fn add(l: *Launchers, name: []const u8) void {
        for (l.slice()) |seen| if (std.mem.eql(u8, seen, name)) return;
        l.names[l.n] = name;
        l.n += 1;
    }
};

/// Who holds which keys: looked at once (`shortcut_holders.look`), asked per
/// choice (`clash`).
pub const Holders = struct {
    /// The Mac's: the system's shortcut table.
    system: []const SystemKey = &.{},
    /// A PC's: which of `Choice.all` another program holds.
    taken: [Choice.all.len]bool = @splat(false),
    running: Launchers = .{},
};

/// What is in the way of a choice: a system shortcut that takes it first,
/// and launchers that may be using it too.
pub const Clash = struct {
    /// "Spotlight", "Input sources"…, when the system takes it.
    system: ?[]const u8 = null,
    launchers: Launchers = .{},

    pub fn clear(c: *const Clash) bool {
        return c.system == null and c.launchers.n == 0;
    }
};

pub fn clash(c: Choice, h: *const Holders) Clash {
    var out: Clash = .{};
    if (c.preset()) |i| if (h.taken[i]) {
        out.system = "another app or your desktop";
    };
    for (h.system) |k| if (k.enabled and k.key == c.code and k.mods & keys.ns_mods == c.appkit()) {
        out.system = k.id.name();
        break;
    };
    for (h.running.slice()) |name| {
        const l = for (known_launchers) |l| {
            if (std.mem.eql(u8, l.name, name)) break l;
        } else continue;
        for (l.keys) |k| if (k.eql(c)) out.launchers.add(name);
    }
    return out;
}
test "a clash is found in the system's shortcuts and among launchers" {
    const t = std.testing;
    const sys = [_]SystemKey{
        .{ .id = .spotlight, .enabled = true, .key = keys.space, .mods = keys.ns_cmd },
        .{
            .id = .input_source_previous,
            .enabled = false,
            .key = keys.space,
            .mods = keys.ns_ctrl,
        },
        .{
            .id = .finder_search,
            .enabled = true,
            .key = keys.space,
            .mods = keys.ns_cmd | keys.ns_opt | (1 << 23),
        },
    };
    var h: Holders = .{ .system = &sys };
    h.running.add("Peekalight");
    const a = clash(.cmd_space, &h);
    try t.expectEqualStrings("Spotlight", a.system.?);
    try t.expectEqual(@as(usize, 1), a.launchers.n);
    // Turned off in System Settings: free.
    const quiet: Holders = .{ .system = &sys };
    try t.expect(clash(.ctrl_space, &quiet).clear());
    // Device bits beyond the modifiers don't hide a clash.
    try t.expectEqualStrings("Finder's search window", clash(.opt_cmd_space, &h).system.?);
    try t.expect(clash(.opt_cmd_space, &h).launchers.n == 0);
}

test "a key another program holds on a PC clashes" {
    var h: Holders = .{};
    h.taken[Choice.ctrl_space.preset().?] = true;
    try std.testing.expectEqualStrings(
        "another app or your desktop",
        clash(.ctrl_space, &h).system.?,
    );
    try std.testing.expect(clash(.cmd_space, &h).clear());
}

test "a recorded key clashes with the system's shortcut on the same key" {
    const sys = [_]SystemKey{.{ .id = unnamed, .enabled = true, .key = 7, .mods = keys.ns_opt }};
    const h: Holders = .{ .system = &sys };
    const c = clash(keys.recorded(7, keys.ns_opt, 'x').key, &h);
    try std.testing.expectEqualStrings("a macOS shortcut", c.system.?);
    try std.testing.expect(clash(keys.recorded(7, keys.ns_cmd, 'x').key, &h).clear());
}

/// A system shortcut no offered key is near.
const unnamed: System = @fromBackingInt(@as(u32, 33));
