//! The running app's side of clipboard history (clipboard.zig): the store
//! on disk, the OS's watcher feeding it, hourly pruning, and what Return and
//! ⌘↩ do to an entry in the panel (clipboard_view.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const types = @import("clipboard_types.zig");
const Watcher = @import("clipboard_watcher.zig").Watcher;
const Host = @import("host.zig").Host.Clipboard;
const prefs = @import("prefs.zig");
const paths = @import("paths.zig");
const clock = @import("clock.zig");
const log = @import("log.zig");
const App = @import("app.zig").App;
const Hook = @import("app.zig").Hook;

const prune_every_ms = 60 * 60 * 1000;

/// Pinned once opened: the panel's host and the watcher point here.
pub const Clip = struct {
    core: *App,
    /// Where the store keeps its files, and the store: null in headless runs
    /// and without a data directory.
    dir: ?std.Io.Dir = null,
    store: ?clipboard.Store = null,
    watcher: Watcher = .{},
    /// What the Clipboard History screen asks of the app; set with the store.
    host: ?Host = null,

    /// Opens the store in `<data dir>/clipboard` and, when history is on,
    /// starts the watcher. Without that folder history stays off (logged).
    pub fn open(c: *Clip, cfg: clipboard.Config, config_ok: bool) void {
        const gpa = c.core.app.gpa;
        const io = c.core.app.io;
        c.dir = openDir(gpa, io) catch |e| {
            log.warn("nanolight: clipboard history is off: no folder: {t}", .{e});
            return;
        };
        c.store = .init(gpa, io, c.dir, cfg);
        const store = &c.store.?;
        store.on = prefs.flagOr(c.core.kv, gpa, .clipboard, store.cfg.enabled orelse true);
        store.config_ok = config_ok;
        store.load(clock.now());
        c.host = .{
            .ctx = c,
            .store = store,
            .copy_only = !store.cfg.paste_plain_text,
            .status = status,
            .paste = paste,
            .copy = copy,
        };
        if (store.on) c.startWatching();
        nanoui.App.after(prune_every_ms, c, pruneTick);
    }

    pub fn deinit(c: *Clip) void {
        c.watcher.stop();
        if (c.store) |*s| s.deinit();
        if (c.dir) |*d| d.close(c.core.app.io);
    }

    /// The panel's Clipboard History: null without history.
    pub fn entry(c: *Clip) ?*const Host {
        return if (c.host) |*h| h else null;
    }

    /// The core's `showing`: where a paste goes is noted.
    pub fn showingHook(c: *Clip) Hook {
        return .{ .ctx = c, .func = frontmost };
    }

    fn frontmost(ctx: *anyopaque) void {
        const c = from(ctx);
        if (c.store != null) c.watcher.noteFrontmost();
    }

    /// Settings' switch: whether history records; `set` changes it first (kept
    /// in kv, so the app's change outlasts the config file's value; see
    /// `clipboard.Store.turn`). Off on a system with no history.
    pub fn enabled(c: *Clip, set: ?bool) bool {
        const store = if (c.store) |*s| s else return false;
        if (set) |on| {
            const was = store.on;
            store.turn(on, prefs.setFlag(c.core.kv, .clipboard, on));
            if (store.on == was) return was;
            if (store.on) c.startWatching() else c.watcher.stop();
        }
        return store.on;
    }

    /// Settings' Clear History: false when something may be left on disk (logged).
    pub fn clear(c: *Clip) bool {
        const store = if (c.store) |*s| s else return true;
        store.clear() catch return false;
        return true;
    }

    fn startWatching(c: *Clip) void {
        const store = if (c.store) |*s| s else return;
        if (!store.config_ok) return;
        c.watcher.start(.{ .ctx = c, .observe = observe, .excluded = excluded }) catch |e|
            log.warn("nanolight: clipboard history could not start: {t}", .{e});
    }

    fn load(c: *Clip, hash: u64) ?clipboard.Loaded {
        const store = if (c.store) |*s| s else return null;
        const e = store.get(hash) orelse return null;
        return store.read(c.core.app.gpa, e.*) catch |err| {
            log.warn("nanolight: clipboard: could not read an entry: {t}", .{err});
            return null;
        };
    }
};

/// The store's directory, made if missing.
fn openDir(gpa: std.mem.Allocator, io: std.Io) !std.Io.Dir {
    const path = try paths.subdir(gpa, io, "clipboard", clipboard.private_dir);
    defer gpa.free(path);
    // best effort: an existing folder keeps its mode; its files are created private anyway.
    std.Io.Dir.cwd().setFilePermissions(io, path, clipboard.private_dir, .{}) catch {};
    return std.Io.Dir.cwd().openDir(io, path, .{});
}

fn from(ctx: *anyopaque) *Clip {
    return @ptrCast(@alignCast(ctx));
}

fn observe(ctx: *anyopaque, item: types.Item) void {
    const c = from(ctx);
    const store = if (c.store) |*s| s else return;
    if (store.add(item, clock.now())) if (c.core.s.showsClipboard()) c.core.redraw();
}

fn excluded(ctx: *anyopaque, source: []const u8) bool {
    const c = from(ctx);
    const store = if (c.store) |*s| s else return true;
    return store.excluded(source);
}

fn pruneTick(ctx: ?*anyopaque) callconv(.c) void {
    const c = from(ctx.?);
    if (c.store) |*store| store.pruneOrWarn(clock.now());
    nanoui.App.after(prune_every_ms, c, pruneTick);
}

/// Why the screen has nothing to show now, or null.
fn status(ctx: *anyopaque) ?[]const u8 {
    const c = from(ctx);
    if (c.watcher.status()) |why| return why;
    const store = if (c.store) |*s| s else return null;
    if (!store.config_ok) return "Clipboard history is paused until the config file loads.";
    return if (store.on) null else "Clipboard history is off. Turn it on in Settings.";
}

fn paste(ctx: *anyopaque, hash: u64) types.PasteResult {
    const c = from(ctx);
    const loaded = c.load(hash) orelse return .unreadable;
    defer if (loaded.owned) |b| c.core.app.gpa.free(b);
    return c.watcher.paste(loaded.content, .{ .ctx = c.core, .func = App.hide });
}

fn copy(ctx: *anyopaque, hash: u64) types.PasteResult {
    const c = from(ctx);
    const loaded = c.load(hash) orelse return .unreadable;
    defer if (loaded.owned) |b| c.core.app.gpa.free(b);
    return if (c.watcher.copy(loaded.content)) .copied else .failed;
}
