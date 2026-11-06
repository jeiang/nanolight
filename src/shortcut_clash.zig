//! Who else may answer a key choice. Carbon grants a hot key even when another
//! app holds the same one, so clashes are found here instead: in the system's
//! own shortcuts (Spotlight's ⌘Space, the input sources' ⌃Space) and among
//! the launchers that are running. A PC keeps no such table: each of the four
//! is tried (`hotkey.taken`).
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const keys = @import("keys.zig");
const hotkey = @import("hotkey.zig");
const Choice = keys.Choice;
const mac = builtin.os.tag == .macos;
const objc = nanoui.objc;

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
    fn default(s: System) ?Choice {
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
const known_launchers = [_]Launcher{
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

    fn add(l: *Launchers, name: []const u8) void {
        for (l.slice()) |seen| if (std.mem.eql(u8, seen, name)) return;
        l.names[l.n] = name;
        l.n += 1;
    }
};

/// Who holds which keys: looked at once (`look`), asked per choice (`clash`).
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

/// The system's shortcuts and the running launchers now; `system_buf` holds
/// the table.
pub fn look(system_buf: []SystemKey) Holders {
    if (!mac) {
        var h: Holders = .{};
        for (Choice.all, &h.taken) |c, *t| t.* = hotkey.taken(c);
        return h;
    }
    return .{ .system = systemKeys(system_buf), .running = runningLaunchers() };
}

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

/// The system's shortcuts (macOS keeps them in its defaults).
fn systemKeys(buf: []SystemKey) []SystemKey {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ud = objc.msg(objc.Object, objc.class("NSUserDefaults"), "standardUserDefaults", .{});
    const domain = as(
        objc.msg(
            ?objc.Object,
            ud,
            "persistentDomainForName:",
            .{objc.nsString("com.apple.symbolichotkeys")},
        ),
        "NSDictionary",
    );
    const table = if (domain) |d|
        objc.msg(?objc.Object, d, "objectForKey:", .{objc.nsString("AppleSymbolicHotKeys")})
    else
        null;
    return withDefaults(readTable(table, buf), buf);
}

/// macOS may list a shortcut only once it has been changed: on a clean Mac
/// the table lacks Spotlight's, which holds ⌘Space all the same.
fn withDefaults(found: []SystemKey, buf: []SystemKey) []SystemKey {
    var n = found.len;
    for (std.enums.values(System)) |s| {
        const d = s.default() orelse continue;
        const listed = for (buf[0..n]) |k| {
            if (k.id == s) break true;
        } else false;
        if (listed or n == buf.len) continue;
        buf[n] = .{ .id = s, .enabled = true, .key = d.code, .mods = d.appkit() };
        n += 1;
    }
    return buf[0..n];
}

/// `obj` if it is a `cls`, else null. A defaults value can be any property
/// list type, and not always the one expected: a boolean where a
/// dictionary was (macOS 27), which `objectForKey:` aborted on (#14).
fn as(obj: ?objc.Object, comptime cls: [:0]const u8) ?objc.Object {
    const o = obj orelse return null;
    return if (objc.msg(objc.BOOL, o, "isKindOfClass:", .{objc.class(cls)})) o else null;
}

fn field(dict: objc.Object, comptime key: []const u8, comptime cls: [:0]const u8) ?objc.Object {
    return as(objc.msg(?objc.Object, dict, "objectForKey:", .{objc.nsString(key)}), cls);
}

fn item(array: objc.Object, i: objc.NSUInteger, comptime cls: [:0]const u8) ?objc.Object {
    return as(objc.msg(?objc.Object, array, "objectAtIndex:", .{i}), cls);
}

/// The shortcuts in `AppleSymbolicHotKeys`: id → { enabled, value: {
/// parameters: [char, key code, modifiers] } }. Whatever isn't shaped so
/// is passed over.
fn readTable(table_in: ?objc.Object, buf: []SystemKey) []SystemKey {
    const table = as(table_in, "NSDictionary") orelse return buf[0..0];
    const ids = objc.msg(objc.Object, table, "allKeys", .{});
    var n: usize = 0;
    for (0..objc.msg(objc.NSUInteger, ids, "count", .{})) |i| {
        if (n == buf.len) break;
        const k = objc.msg(objc.Object, ids, "objectAtIndex:", .{i});
        // Ids are strings ("64"); numbers read as well.
        if (as(k, "NSString") == null and as(k, "NSNumber") == null) continue;
        const entry = as(
            objc.msg(?objc.Object, table, "objectForKey:", .{k}),
            "NSDictionary",
        ) orelse
            continue;
        const enabled = field(entry, "enabled", "NSNumber") orelse continue;
        const id: System = @fromBackingInt(@intCast(
            std.math.clamp(
                objc.msg(objc.NSInteger, k, "integerValue", .{}),
                0,
                std.math.maxInt(u32),
            ),
        ));
        // Turned off, it holds no key, and the entry may say no more than that.
        if (!objc.msg(objc.BOOL, enabled, "boolValue", .{})) {
            buf[n] = .{ .id = id, .enabled = false, .key = 0, .mods = 0 };
            n += 1;
            continue;
        }
        const value = field(entry, "value", "NSDictionary") orelse continue;
        const params = field(value, "parameters", "NSArray") orelse continue;
        if (objc.msg(objc.NSUInteger, params, "count", .{}) < 3) continue;
        const code = item(params, 1, "NSNumber") orelse continue;
        const mods = item(params, 2, "NSNumber") orelse continue;
        const key = objc.msg(objc.NSInteger, code, "integerValue", .{});
        if (key < 0 or key > 127) continue;
        buf[n] = .{
            .id = id,
            .enabled = true,
            .key = @intCast(key),
            .mods = @bitCast(@as(i64, objc.msg(objc.NSInteger, mods, "integerValue", .{}))),
        };
        n += 1;
    }
    return buf[0..n];
}

/// Asks the launcher called `name` to quit, as its Quit menu item would.
pub fn quit(name: []const u8) void {
    if (!mac) return;
    const pool = objc.Pool.push();
    defer pool.pop();
    const bundle = for (known_launchers) |l| {
        if (std.mem.eql(u8, l.name, name)) break l.bundle;
    } else return;
    const apps = objc.msg(
        objc.Object,
        objc.class("NSRunningApplication"),
        "runningApplicationsWithBundleIdentifier:",
        .{objc.nsString(bundle)},
    );
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i|
        _ = objc.msg(
            objc.BOOL,
            objc.msg(objc.Object, apps, "objectAtIndex:", .{i}),
            "terminate",
            .{},
        );
}

fn runningLaunchers() Launchers {
    var o: Launchers = .{};
    const pool = objc.Pool.push();
    defer pool.pop();
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    const apps = objc.msg(objc.Object, ws, "runningApplications", .{});
    for (0..objc.msg(objc.NSUInteger, apps, "count", .{})) |i| {
        const a = objc.msg(objc.Object, apps, "objectAtIndex:", .{i});
        const bundle = objc.fromNSString(objc.msg(?objc.Object, a, "bundleIdentifier", .{}));
        for (known_launchers) |l| if (std.mem.eql(u8, bundle, l.bundle)) o.add(l.name);
    }
    return o;
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

test "the system's shortcuts are read past entries of the wrong type (#14)" {
    if (!mac) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    // ⌘Space for Spotlight; then a boolean for an entry, for its value,
    // for its parameters, a string for a key code, and no value at all.
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        \\<key>64</key><dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key>
        \\<array><integer>32</integer><integer>49</integer><integer>1048576</integer></array></dict>
    ++
        \\</dict>
        \\<key>65</key><true/>
        \\<key>60</key><dict><key>enabled</key><true/><key>value</key><true/></dict>
        \\<key>61</key><dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key>
    ++
        \\<true/></dict></dict>
        \\<key>62</key><dict><key>enabled</key><true/><key>value</key><dict><key>parameters</key>
        \\<array><integer>32</integer><string>49</string><integer>0</integer></array></dict></dict>
        \\<key>63</key><dict><key>enabled</key><true/></dict>
        \\</dict></plist>
    ;
    var buf: [8]SystemKey = undefined;
    const got = readTable(plist(xml), &buf);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(
        SystemKey{ .id = .spotlight, .enabled = true, .key = keys.space, .mods = keys.ns_cmd },
        got[0],
    );
    // The table itself the wrong type: nothing, no abort.
    const yes = objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES});
    try std.testing.expectEqual(@as(usize, 0), readTable(yes, &buf).len);
}

test "Spotlight holds ⌘Space unless the system's table says otherwise" {
    var buf: [4]SystemKey = undefined;
    // A clean Mac: no entry for it.
    const clean: Holders = .{ .system = withDefaults(buf[0..0], &buf) };
    try std.testing.expectEqualStrings("Spotlight", clash(.cmd_space, &clean).system.?);
    try std.testing.expectEqualStrings(
        "Finder's search window",
        clash(.opt_cmd_space, &clean).system.?,
    );
    try std.testing.expect(clash(.ctrl_space, &clean).clear());
    buf[0] = .{ .id = .spotlight, .enabled = false, .key = 0, .mods = 0 };
    const off: Holders = .{ .system = withDefaults(buf[0..1], &buf) };
    try std.testing.expect(clash(.cmd_space, &off).clear());
    buf[0] = .{ .id = .spotlight, .enabled = true, .key = keys.space, .mods = keys.ns_ctrl };
    const moved: Holders = .{ .system = withDefaults(buf[0..1], &buf) };
    try std.testing.expect(clash(.cmd_space, &moved).clear());
    // No room left: what's found is kept.
    var one: [1]SystemKey = undefined;
    one[0] = .{ .id = unnamed, .enabled = true, .key = 7, .mods = keys.ns_opt };
    try std.testing.expectEqual(@as(usize, 1), withDefaults(one[0..1], &one).len);
}

/// A system shortcut no offered key is near.
const unnamed: System = @fromBackingInt(@as(u32, 33));

test "a shortcut turned off is read, whatever else its entry lacks" {
    if (!mac) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        \\<key>64</key><dict><key>enabled</key><false/></dict>
        \\</dict></plist>
    ;
    var buf: [4]SystemKey = undefined;
    const h: Holders = .{ .system = withDefaults(readTable(plist(xml), &buf), &buf) };
    try std.testing.expect(clash(.cmd_space, &h).clear());
}

fn plist(xml: []const u8) ?objc.Object {
    const data = objc.msg(
        objc.Object,
        objc.class("NSData"),
        "dataWithBytes:length:",
        .{ @as(*const anyopaque, xml.ptr), @as(objc.NSUInteger, xml.len) },
    );
    return objc.msg(
        ?objc.Object,
        objc.class("NSPropertyListSerialization"),
        "propertyListWithData:options:format:error:",
        .{ data, @as(objc.NSUInteger, 0), @as(?*anyopaque, null), @as(?*anyopaque, null) },
    );
}
