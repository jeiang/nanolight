//! What this build can do, for the code that offers a feature or not, and
//! the words that differ by OS. The parts that do it are shell.zig's. A key
//! of one's own is `keys.any_key`: config.zig checks keys without this build.
const ui = @import("nanoui").ui;
const keys = @import("keys.zig");
const os = @import("os.zig");
const mac = os.mac;
/// A Nix build: the Nix modules own the key, startup and updates.
const nix = @import("build_options").nix_managed;

/// A key of one's own, recorded in Settings (`keys.any_key`).
pub const record = keys.any_key;
/// Local file search (Spotlight's index).
pub const files = mac;
/// A search's page in the panel; elsewhere it opens in the browser.
pub const preview = mac;
/// The menu bar icon: nanoui has no tray on Windows and Linux yet.
pub const tray = mac;
/// nanoui's updater restarts into an update itself (`autoRestart`) and says
/// so after (`updatedFrom`); elsewhere update_live.zig and prefs' `.updated` do.
pub const native_autorestart = mac;
/// Checking for and installing updates.
pub const updater = !nix;
/// Opening at login, switched in Nanolight.
pub const login_ui = !nix;
/// The welcome asks for the key.
pub const key_ui = !nix;
/// System Settings' panes, listed among the results (settings_panes.zig).
pub const panes = mac;
/// The system keeps a table of its shortcuts, read for who holds a key and
/// freed in Keyboard Shortcuts; a PC has none: each key is tried
/// (`hotkey.taken`), and another one is the fix.
pub const system_shortcuts = mac;
/// The launchers that may answer the same key (shortcut_clash.zig's
/// `known_launchers`) are Mac apps: looked for running, and asked to quit.
pub const launchers = mac;
/// The Mac's system font draws smaller than a PC's: Settings lays its
/// rows out tighter there.
pub const tight_text = mac;
/// Settings' heading for the settings that sync.
pub const sync_heading = "Sync Across " ++ machines;
/// The keyboard's modifiers are a PC's (Ctrl, Alt, Shift: `keys.Choice.pc`),
/// read as words; the Mac's as glyphs (⌃ ⌥ ⇧ ⌘).
pub const pc_modifiers = !mac;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on, and several.
pub const machine = if (mac) "Mac" else "PC";
pub const machines = if (mac) "Macs" else "Computers";

/// A key, and how the footer writes it.
pub const Chord = struct { shortcut: ui.Shortcut, text: []const u8 };
/// A script command's actions: ⌘K on the Mac; Ctrl+K moves up on a PC, so
/// Ctrl+O there.
pub const actions: Chord = if (mac)
    .{ .shortcut = .{ .key = 'k', .cmd = true }, .text = "⌘K" }
else
    .{ .shortcut = .{ .key = 'o', .ctrl = true }, .text = "Ctrl+O" };

/// A welcome example: what to type, what it does, and an icon nanoui draws
/// (SF Symbols on the Mac, its own set elsewhere).
pub const Example = struct { q: []const u8, what: []const u8, icon: []const u8 };
/// An app every machine of the kind has.
pub const example_app: Example = if (mac)
    .{ .q = "saf", .what = "Open Safari", .icon = "app.badge" }
else if (os.windows)
    .{ .q = "note", .what = "Open Notepad", .icon = "doc.text" }
else
    .{ .q = "term", .what = "Open a terminal", .icon = "terminal" };
/// Math's icon, by each set's name for it.
pub const math_icon = if (mac) "plus.forwardslash.minus" else "plus";
