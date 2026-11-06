//! The running app's side of clipboard history (clipboard.zig): the store
//! on disk, the OS's watcher feeding it, hourly pruning, and what Return and
//! ⌘↩ do to an entry in the panel (clipboard_view.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const main = @import("main.zig");
const clipboard = @import("clipboard.zig");
const prefs = @import("prefs.zig");
const account = @import("account.zig");
const Live = main.Live;

const prune_every_ms = 60 * 60 * 1000;

/// Opens the store in `<data dir>/clipboard` and, when history is on,
/// starts the watcher. Without a data directory history stays off.
pub fn init(l: *Live, store: *clipboard.Store) void {
    l.clip = store;
    store.load(account.now());
    l.clip_host = .{
        .ctx = l,
        .store = store,
        .status = status,
        .paste = paste,
        .copy = copy,
    };
    l.s.host.?.clipboard = &l.clip_host;
    if (store.on) startWatching(l);
    nanoui.App.after(prune_every_ms, l, pruneTick);
}

pub fn deinit(l: *Live) void {
    l.clip_watcher.stop();
}

/// The store's directory, made if missing; null when there is none.
pub fn openDir(gpa: std.mem.Allocator, io: std.Io) ?std.Io.Dir {
    const data = prefs.dataDir(gpa) catch return null;
    defer gpa.free(data);
    const path = std.fs.path.join(gpa, &.{ data, "clipboard" }) catch return null;
    defer gpa.free(path);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, path, clipboard.private_dir) catch return null;
    // best effort: an existing folder keeps its mode; its files are created private anyway.
    std.Io.Dir.cwd().setFilePermissions(io, path, clipboard.private_dir, .{}) catch {};
    return std.Io.Dir.cwd().openDir(io, path, .{}) catch null;
}

fn live(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn startWatching(l: *Live) void {
    if (!(l.clip orelse return).config_ok) return;
    l.clip_watcher.start(.{ .ctx = l, .observe = observe, .excluded = excluded }) catch |e|
        clipboard.log(.warn, "nanolight: clipboard history could not start: {t}", .{e});
}

fn observe(ctx: *anyopaque, item: clipboard.Item) void {
    const l = live(ctx);
    const store = l.clip orelse return;
    if (store.add(item, account.now())) if (l.s.clip_ui.open) if (l.window) |w| w.redraw();
}

fn excluded(ctx: *anyopaque, source: []const u8) bool {
    const store = live(ctx).clip orelse return true;
    return store.excluded(source);
}

fn pruneTick(ctx: ?*anyopaque) callconv(.c) void {
    const l: *Live = @ptrCast(@alignCast(ctx.?));
    if (l.clip) |store| store.pruneOrWarn(account.now());
    nanoui.App.after(prune_every_ms, l, pruneTick);
}

/// Settings' switch: whether history records; `set` changes it first (kept
/// in kv, so the app's change outlasts the config file's value; see
/// `clipboard.Store.turn`). Null on a system with no history.
pub fn enabled(ctx: *anyopaque, set: ?bool) ?bool {
    const l = live(ctx);
    const store = l.clip orelse return null;
    if (set) |on| {
        const was = store.on;
        store.turn(on, prefs.setFlag(l.kv, .clipboard, on));
        if (store.on == was) return was;
        if (store.on) startWatching(l) else l.clip_watcher.stop();
    }
    return store.on;
}

/// Settings' Clear History: false when something may be left on disk (logged).
pub fn clear(ctx: *anyopaque) bool {
    const store = live(ctx).clip orelse return true;
    store.clear() catch return false;
    return true;
}

/// Why the screen has nothing to show now, or null.
fn status(ctx: *anyopaque) ?[]const u8 {
    const l = live(ctx);
    if (l.clip_watcher.status()) |why| return why;
    const store = l.clip orelse return null;
    if (!store.config_ok) return "Clipboard history is paused until the config file loads.";
    return if (store.on) null else "Clipboard history is off. Turn it on in Settings.";
}

fn load(l: *Live, hash: u64) ?clipboard.Loaded {
    const store = l.clip orelse return null;
    const e = store.get(hash) orelse return null;
    return store.read(l.app.gpa, e.*) catch |err| {
        clipboard.log(.warn, "nanolight: clipboard: could not read an entry: {t}", .{err});
        return null;
    };
}

fn paste(ctx: *anyopaque, hash: u64) clipboard.PasteResult {
    const l = live(ctx);
    const loaded = load(l, hash) orelse return .unreadable;
    defer if (loaded.owned) |b| l.app.gpa.free(b);
    return l.clip_watcher.paste(loaded.content, .{ .ctx = l, .func = Live.hide });
}

fn copy(ctx: *anyopaque, hash: u64) clipboard.PasteResult {
    const l = live(ctx);
    const loaded = load(l, hash) orelse return .unreadable;
    defer if (loaded.owned) |b| l.app.gpa.free(b);
    return if (l.clip_watcher.copy(loaded.content)) .copied else .failed;
}
