//! The app's facts its Mac verifiers (tools/mac_verify.zig) also rely on,
//! spelled once: build.zig hands this file to the tools as a module, so a
//! change here reaches them, and a rename breaks their build, not a CI run.

/// The folder nanoui keeps the app's data and its updater's cache in.
pub const app_name = "Nanolight";
/// The panel's width, inside its window's shadow margin.
pub const panel_width = 680;
/// Away this long, the panel lets an update restart the app.
pub const restart_idle_ms = 10 * 1000;
/// The kv key that is "1" once the welcome is done.
pub const onboarded_key = "nanolight.onboarded";
/// The kv key the hotkey is kept under, as `keys.Choice.name` writes it.
pub const hotkey_key = "nanolight.hotkey";
