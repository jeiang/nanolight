//! What the panel asks of whatever shows it (the window, or a test), and
//! what its screens ask: the app's side of the panel, named in one place
//! so the features that answer it need not know the panel.
const commands = @import("commands.zig");
const clipboard = @import("clipboard.zig");
const PasteResult = @import("clipboard_types.zig").PasteResult;
const SettingsHost = @import("settings_host.zig").SettingsHost;

/// What a row opens when Return is pressed on it.
pub const Target = union(enum) {
    /// An app, a file or a folder: its path.
    app: []const u8,
    url: []const u8,
    script: ScriptTarget,
    /// A pane of System Settings, its place in settings_panes.zig.
    pane: u16,

    /// Whether it opens a screen in the panel, which then stays up: a
    /// script command's runs there (its runner hides it for a silent one).
    pub fn opensScreen(t: Target) bool {
        return switch (t) {
            .script => true,
            .app, .url, .pane => false,
        };
    }
};

/// A script command's row or their folder's: the host's script feature
/// opens it (app.zig `Opens`).
pub const ScriptTarget = union(enum) {
    /// A script command, its place in `script_commands.List`.
    command: u32,
    /// Their folder.
    folder,
};

/// The window's answers share `ctx`; each feature's carries its own.
pub const Host = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque, target: Target) void,
    hide: *const fn (ctx: *anyopaque) void,
    resize: *const fn (ctx: *anyopaque, h: f32) void,
    /// Shows a search's page in the panel, over `chrome.webArea`; null takes it
    /// away. Without it, searches open in the browser.
    preview: ?*const fn (ctx: *anyopaque, url: ?[]const u8) void = null,
    /// Asks Google about the query's words. The last ask is answered once
    /// through `pipeline.answered`, with completions or with none; the
    /// panel keeps its room until it is.
    suggest: Ask,
    /// Looks for files for the query's words; what is found comes back
    /// through `pipeline.filesAnswered`, if anything does.
    files: ?Ask = null,
    /// Settings' answers.
    settings: *const SettingsHost,
    /// Runs system command `i` (commands.zig). Without it, nothing runs.
    command: ?Run = null,
    /// Clipboard history (clipboard_view.zig). Without it the "Clipboard
    /// History" row is not listed.
    clipboard: ?*const Clipboard = null,

    pub const Ask = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, query: []const u8) void,
    };
    pub const Run = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, i: usize) void,
        /// The commands it can run: those listed.
        installed: *const commands.Installed,
    };

    /// What Clipboard History asks of the app. Without it the screen says
    /// history is not available (tests draw it so).
    pub const Clipboard = struct {
        ctx: *anyopaque,
        store: *clipboard.Store,
        /// Return only copies, as ⌘↩ does (`paste_plain_text` off).
        copy_only: bool,
        /// Why entries are not being recorded now (this system cannot, or it
        /// is switched off); null while they are.
        status: *const fn (ctx: *anyopaque) ?[]const u8,
        /// Return: writes the entry and pastes it where it can.
        paste: *const fn (ctx: *anyopaque, hash: u64) PasteResult,
        /// ⌘↩: writes the entry only (Return too, when `copy_only`): `.copied`,
        /// `.failed` or `.unreadable`.
        copy: *const fn (ctx: *anyopaque, hash: u64) PasteResult,
    };
};
