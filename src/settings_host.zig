//! What the Settings screen (settings_view.zig) asks of the app: the
//! shortcut, opening at login, the sync status, updates. Optional,
//! like the panel's other host callbacks: tests, the film and the promo
//! draw Settings with defaults and call nothing.
const shortcut = @import("shortcut.zig");

pub const SettingsHost = struct {
    ctx: *anyopaque,
    choice: *const fn (ctx: *anyopaque) shortcut.Choice,
    apply: *const fn (ctx: *anyopaque, c: shortcut.Choice) void,
    /// Starts or stops recording a key of one's own: the keys pressed go
    /// to `Settings.took`, not the panel (recorder.zig).
    record: *const fn (ctx: *anyopaque, on: bool) void,
    /// Whether it opens at login; `set` changes it first.
    login: *const fn (ctx: *anyopaque, set: ?bool) bool,
    /// Google's suggestions turned on or off in Settings.
    suggest: *const fn (ctx: *anyopaque, on: bool) void,
    /// Return sends Google searches to the browser (on) or the panel.
    searches_out: *const fn (ctx: *anyopaque, on: bool) void,
    /// Whether the menu bar icon shows; `set` changes it first.
    menu_bar: *const fn (ctx: *anyopaque, set: ?bool) bool,
    /// Whether clipboard history records; `set` changes it first. Null where
    /// this system has no clipboard history (its rows are not shown).
    clipboard_enabled: *const fn (ctx: *anyopaque, set: ?bool) ?bool,
    /// Deletes every clipboard entry.
    clipboard_clear: *const fn (ctx: *anyopaque) void,
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
