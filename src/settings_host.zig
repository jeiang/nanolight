//! What the Settings screen (settings_view.zig) asks of the app: the
//! shortcut, the switches (toggles.zig), the tint, the sync status,
//! updates. Settings is drawn only with one: the app's
//! (settings_bind.zig), or a test's (test_support.zig).
const Choice = @import("keys.zig").Choice;
const Theme = @import("palette.zig").Theme;
const Toggle = @import("toggles.zig").Toggle;

pub const SettingsHost = struct {
    ctx: *anyopaque,
    choice: *const fn (ctx: *anyopaque) Choice,
    apply: *const fn (ctx: *anyopaque, c: Choice) void,
    /// Starts or stops recording a key of one's own: the keys pressed go
    /// to `Settings.took`, not the panel (recorder.zig). Whether it is
    /// recording now (false when the recorder could not start).
    record: *const fn (ctx: *anyopaque, on: bool) bool,
    /// Whether switch `t` is on; `set` changes it first (kept, its owner
    /// told, synced when it syncs).
    toggle: *const fn (ctx: *anyopaque, t: Toggle, set: ?bool) bool,
    /// The panel's tint; `set` changes it first, kept for the next launch.
    theme: *const fn (ctx: *anyopaque, set: ?Theme) Theme,
    /// Deletes every clipboard entry; false when something may be left on
    /// disk. Whether this system has clipboard history at all is the
    /// panel's (`Nanolight.hasClipboard`).
    clipboard_clear: *const fn (ctx: *anyopaque) bool,
    /// The sync line ("Sync: host, last synced 3 min ago"); valid until the next call.
    sync_status: *const fn (ctx: *anyopaque) []const u8,
    /// The version running, and a newer one waiting (else null).
    version: *const fn (ctx: *anyopaque) []const u8,
    ready: *const fn (ctx: *anyopaque) ?[]const u8,
    check: *const fn (ctx: *anyopaque) void,
    restart: *const fn (ctx: *anyopaque) void,
    welcome: *const fn (ctx: *anyopaque) void,
    quit: *const fn (ctx: *anyopaque) void,
};
