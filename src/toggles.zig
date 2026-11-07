//! The settings that are on or off, one row each: where it is kept, the
//! synced field it is (if any), where Settings lists it and whether this
//! build shows it. Settings draws, orders and sizes its switches from
//! here (settings_view.zig), config.zig's seeds take their sync from it,
//! and the app keeps and loads them all one way (settings_bind.zig, which
//! has each one's owner). A new one: a prefs key, a row and its owner.
const prefs = @import("prefs.zig");
const settings = @import("settings.zig");
const platform = @import("platform.zig");

pub const Toggle = enum {
    suggest,
    files,
    browser,
    login,
    menu_bar,
    clipboard,

    pub fn row(t: Toggle) Row {
        return switch (t) {
            .suggest => .{
                .title = "Google Suggestions",
                .section = .search,
                .pref = .suggest,
                .syncs = .suggest,
            },
            .files => .{ .title = "File Search", .section = .search, .pref = .files },
            .browser => .{
                .title = "Open Searches in Browser",
                .section = .search,
                .pref = .searches_out,
            },
            // The system keeps it (`shell.Login`).
            .login => .{ .title = "Open at Login", .section = .machine, .pref = null },
            .menu_bar => .{ .title = "Show in Menu Bar", .section = .machine, .pref = .menu_bar },
            .clipboard => .{
                .title = "Record Copied Items",
                .section = .clipboard,
                .pref = .clipboard,
            },
        };
    }

    /// Whether this build shows it, `clip` when this system has clipboard
    /// history: a switch not shown is not loaded either. Not a row's field:
    /// config.zig reads the rows in builds without build options.
    pub fn present(t: Toggle, clip: bool) bool {
        return switch (t) {
            .suggest => true,
            .files => platform.files,
            .browser => platform.preview,
            .login => platform.login_ui,
            .menu_bar => platform.tray,
            .clipboard => clip,
        };
    }
};

pub const Row = struct {
    /// Its line in Settings.
    title: []const u8,
    section: Section,
    /// Where it is kept; null for what the system keeps.
    pref: ?prefs.Key,
    /// The synced field it is: changed here, it syncs (`settings.choices`).
    syncs: ?settings.Field = null,
};

/// Settings' group a switch is listed in, in `Toggle`'s order.
pub const Section = enum { search, machine, clipboard };

/// Why a switch changes: here (it syncs, if it does), or brought by sync.
pub const Origin = enum { here, synced };

/// The one way a switch changes (settings_bind.zig `Bind.set`): kept, its
/// owner told, synced when it syncs. For what is not Settings: the menu's
/// checkbox, a sync.
pub const Setter = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, t: Toggle, on: bool, origin: Origin) void,

    pub fn set(s: Setter, t: Toggle, on: bool, origin: Origin) void {
        s.func(s.ctx, t, on, origin);
    }
};
