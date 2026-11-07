//! What this build can do, for the code that offers a feature or not, and
//! the words that differ by OS. The parts that do it are shell.zig's.
const keys = @import("keys.zig");
const mac = @import("os.zig").mac;
/// A Nix build: the Nix modules own the key, startup and updates.
const nix = @import("build_options").nix_managed;

/// Local file search (Spotlight's index).
pub const files = mac;
/// A search's page in the panel; elsewhere it opens in the browser.
pub const preview = mac;
/// The menu bar icon: nanoui has no tray on Windows and Linux yet.
pub const tray = mac;
/// A key of one's own, recorded in Settings (`keys.any_key`).
pub const record = keys.any_key;
/// nanoui's updater restarts into an update itself (`autoRestart`) and says
/// so after (`updatedFrom`); elsewhere update_live.zig and prefs' `.updated` do.
pub const native_autorestart = mac;
/// Checking for and installing updates.
pub const updater = !nix;
/// Opening at login, switched in Nanolight.
pub const login_ui = !nix;
/// The welcome asks for the key.
pub const key_ui = !nix;

/// The key held for the panel's shortcuts (⌘1, ⌘↩, ⌘,): Ctrl on a PC.
pub const mod = if (mac) "⌘" else "Ctrl+";
/// What the panel calls the computer it runs on.
pub const machine = if (mac) "Mac" else "PC";
