//! The running app's side of clipboard history (clipboard.zig): the store
//! on disk, the OS's watcher feeding it, hourly pruning, and what Return and
//! ⌘↩ do to an entry in the panel (clipboard_view.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const main = @import("main.zig");
const clipboard = @import("clipboard.zig");
const config = @import("config.zig");
const account = @import("account.zig");
const Live = main.Live;

const prune_every_ms = 60 * 60 * 1000;

/// Opens the store in `<data dir>/clipboard` and, when history is on,
/// starts the watcher. Without a data directory history stays off.
pub fn init(l: *Live, store: *clipboard.Store) void {
    l.clip = store;
    store.load(account.now());
    l.clip_host = .{ .ctx = l, .store = store, .status = status, .paste = paste, .copy = copy, .copy_only = !l.cfg.clipboard.paste_plain_text };
    l.s.host.?.clipboard = &l.clip_host;
    if (store.cfg.enabled) startWatching(l);
    nanoui.App.after(prune_every_ms, l, pruneTick);
}

pub fn deinit(l: *Live) void {
    l.clip_watcher.stop();
}

/// The store's directory, made if missing; null when there is none.
pub fn openDir(gpa: std.mem.Allocator, io: std.Io) ?std.Io.Dir {
    const data = nanoui.path(gpa, .data, "Nanolight") catch return null;
    defer gpa.free(data);
    const path = std.fs.path.join(gpa, &.{ data, "clipboard" }) catch return null;
    defer gpa.free(path);
    _ = std.Io.Dir.cwd().createDirPathStatus(io, path, clipboard.private_dir) catch return null;
    std.Io.Dir.cwd().setFilePermissions(io, path, clipboard.private_dir, .{}) catch {};
    return std.Io.Dir.cwd().openDir(io, path, .{}) catch null;
}

fn live(ctx: *anyopaque) *Live {
    return @ptrCast(@alignCast(ctx));
}

fn startWatching(l: *Live) void {
    if (!clipboard.Watcher.available) return;
    l.clip_watcher.start(.{ .ctx = l, .observe = observe, .excluded = excluded }) catch |e|
        std.log.warn("nanolight: clipboard history could not start: {t}", .{e});
}

fn observe(ctx: *anyopaque, item: clipboard.Item) void {
    const l = live(ctx);
    const store = l.clip orelse return;
    switch (store.add(item, account.now())) {
        .added, .bumped => if (l.s.clip_ui.open) if (l.window) |w| w.redraw(),
        else => {},
    }
}

fn excluded(ctx: *anyopaque, source: []const u8) bool {
    const store = live(ctx).clip orelse return true;
    return store.excluded(source);
}

fn pruneTick(ctx: ?*anyopaque) callconv(.c) void {
    const l: *Live = @ptrCast(@alignCast(ctx.?));
    if (l.clip) |store| _ = store.prune(account.now());
    nanoui.App.after(prune_every_ms, l, pruneTick);
}

/// Settings' switch: whether history records; `set` changes it first (kept
/// in kv, so the app's change outlasts the config file's value). Null on a
/// system with no history.
pub fn enabled(ctx: *anyopaque, set: ?bool) ?bool {
    const l = live(ctx);
    const store = l.clip orelse return null;
    if (!clipboard.Watcher.available) return null;
    if (set) |on| {
        l.kv.set(config.clipboard_key, if (on) "1" else "0") catch {};
        store.cfg.enabled = on;
        if (on) startWatching(l) else l.clip_watcher.stop();
    }
    return store.cfg.enabled;
}

/// Settings' Clear History.
pub fn clear(ctx: *anyopaque) void {
    if (live(ctx).clip) |store| store.clear();
}

/// Why the screen has nothing to show now, or null.
fn status(ctx: *anyopaque) ?[]const u8 {
    if (!clipboard.Watcher.available) return clipboard.Watcher.unavailable_reason;
    const store = live(ctx).clip orelse return null;
    return if (store.cfg.enabled) null else "Clipboard history is off. Turn it on in Settings.";
}

/// An entry's content as the OS writes it; `owned` is freed by `release`.
const Loaded = struct { content: clipboard.Content, owned: ?[]u8 = null };

fn load(l: *Live, hash: u64) ?Loaded {
    const store = l.clip orelse return null;
    const e = store.get(hash) orelse return null;
    const gpa = l.app.gpa;
    switch (e.kind) {
        .file => return .{ .content = .{ .kind = .file, .text = e.text } },
        .text => {
            const full = store.fullText(gpa, e.*) catch return null;
            return .{ .content = .{ .kind = .text, .text = full }, .owned = full };
        },
        .image => {
            const bytes = store.png(gpa, e.*) orelse return null;
            return .{ .content = .{ .kind = .image, .png = bytes }, .owned = bytes };
        },
    }
}

fn paste(ctx: *anyopaque, hash: u64) clipboard.PasteResult {
    const l = live(ctx);
    const loaded = load(l, hash) orelse return .failed;
    defer if (loaded.owned) |b| l.app.gpa.free(b);
    return l.clip_watcher.paste(loaded.content, .{ .ctx = l, .func = Live.hide });
}

fn copy(ctx: *anyopaque, hash: u64) bool {
    const l = live(ctx);
    const loaded = load(l, hash) orelse return false;
    defer if (loaded.owned) |b| l.app.gpa.free(b);
    return l.clip_watcher.copy(loaded.content);
}
