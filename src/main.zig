//! Nanolight, after Peekalight: a launcher that opens over everything on
//! ⌘Space, or the key picked in its welcome (onboard.zig), or from its
//! menu bar icon; finds apps as you type (initials
//! too: "ss" is System Settings), answers math, and hands anything else to
//! your quicklinks (Google, Claude, Grok...), with Google's completions of it (suggest.zig) and its
//! results in the panel (preview.zig). Its panel is the system's vibrancy
//! (NSVisualEffectView, as launchers use), nanoui drawing on it.
//! It lives in the menu bar: no Dock icon, nothing drawn while idle.
//! `zig build run`, or `zig build app` and open zig-out/Nanolight.app.
//!
//! This file starts it: the arguments, the panel and its window (app.zig),
//! the features round it (`*_live.zig`) wired in, then the app's loop.
const std = @import("std");
const nanoui = @import("nanoui");
const apps = @import("apps.zig");
const Index = apps.Index;
const Nanolight = @import("view.zig").Nanolight;
const chrome = @import("chrome.zig");
const Onboard = @import("onboard.zig").Onboard;
const platform = @import("platform.zig");
const panel = platform.panel;
const account = @import("account.zig");
const config = @import("config.zig");
const prefs = @import("prefs.zig");
const App = @import("app.zig").App;
const suggest_live = @import("suggest_live.zig");
const rates_live = @import("rates_live.zig");
const files_live = @import("files_live.zig");
const script_live = @import("script_live.zig");
const commands_live = @import("commands_live.zig");
const clipboard_live = @import("clipboard_live.zig");
const account_live = @import("account_live.zig");
const update_live = @import("update_live.zig");
const menu_live = @import("menu_live.zig");
const settings_bind = @import("settings_bind.zig");
/// A Nix build: no updater and no login-item UI; the modules own both.
const nix_managed = @import("build_options").nix_managed;
const version = @import("build_options").version;

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    if (try answeredArgs(init, try init.minimal.args.toSlice(arena.allocator()))) return;
    panel.prepare();
    const app = try nanoui.App.create(
        init,
        .{ .name = "Nanolight", .quit_on_last_window_closed = false },
    );
    defer app.destroy();
    var index: Index = .init(init.gpa);
    defer index.deinit();
    apps.scan(&index, init.io, init.environ_map, &.{});
    index.finish();
    const kv = nanoui.kv.standard();
    index.load(kv);
    // A headless run is no one's: neither their config nor their settings.
    var cfg_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer cfg_arena.deinit();
    const loaded: config.Loaded = if (app.flags.hidden)
        .unusable
    else
        config.load(cfg_arena.allocator(), init.io, init.environ_map, kv);
    const cfg = loaded.config();
    config.apply(kv, init.gpa, loaded, account.now());
    // The key is the config's or the Nix module's: the welcome does not ask.
    // `config.parse` lets through only a hotkey this system can use.
    var o: Onboard = .{ .skip_key = nix_managed or cfg.hotkey != null };
    var s: Nanolight = .{
        .index = &index,
        .kv = kv,
        .onboard = &o,
        .pop_after = cfg.pop_to_root_seconds,
    };
    defer s.deinit();
    var core: App = .{
        .app = app,
        .s = &s,
        .o = &o,
        .kv = kv,
        .choice = prefs.hotkey(kv, init.gpa),
    };
    try run(init, &core, loaded, &cfg, cfg_arena.allocator());
}

/// The features round the panel, wired to it; its window; the app's loop.
/// Script commands, system commands and the clipboard history are this
/// machine's: never in headless runs.
fn run(
    init: std.process.Init,
    core: *App,
    loaded: config.Loaded,
    cfg: *const config.Config,
    cfg_arena: std.mem.Allocator,
) !void {
    const shown = !core.app.flags.hidden;
    const s = core.s;
    var rates: rates_live.Rates = .{ .core = core };
    defer rates.deinit();
    s.feed = &rates.feed;
    var sug: suggest_live.Suggest = .{ .core = core };
    var files: files_live.Files = .{ .core = core };
    var sync: account_live.Sync = .{ .core = core };
    defer sync.deinit();
    var scripts: script_live.Scripts = undefined;
    var cmds: commands_live.Commands = undefined;
    if (shown) {
        scripts.init(core, init.environ_map, cfg);
        cmds.init(core, init.environ_map);
    }
    defer if (shown) {
        cmds.deinit();
        scripts.deinit();
    };
    var clip: clipboard_live.Clip = .{ .core = core };
    defer clip.deinit();
    if (shown) clip.open(loaded.clipboardConfig(), loaded != .unusable);
    var update: update_live.Update = .{ .core = core };
    defer update.deinit();
    var menu: menu_live.Menu = .{ .core = core, .update = &update, .sync = &sync };
    var bind: settings_bind.Bind = .{
        .core = core,
        .menu = &menu,
        .clip = &clip,
        .sync = &sync,
        .update = &update,
    };
    const settings = bind.host();
    s.host = .{
        .ctx = core,
        .open = App.open,
        .hide = App.hide,
        .resize = App.resize,
        .preview = if (platform.preview) App.showPage else null,
        .suggest = sug.entry(),
        .files = if (platform.files) files.entry() else null,
        .settings = &settings,
        .rates = rates.entry(),
        .command = if (shown) cmds.entry() else null,
        .clipboard = clip.entry(),
    };
    core.hooks = .{
        .showing = clip.showingHook(),
        .rescan = if (shown) scripts.rescanHook() else null,
        .popped = if (shown) scripts.poppedHook() else null,
        .opens = if (shown) scripts.opensHook() else null,
        .away = update.awayHook(),
        .menu = menu.menuHook(),
    };
    if (shown) _ = sync.setQuicklinks(prefs.quicklinks(cfg_arena, core.kv));
    if (shown) scripts.rescan();
    files_live.load(core);
    loadPreferences(s, core.kv, init.gpa);
    try openWindow(core);
    if (!shown) return core.app.run();
    try runShown(init, core, &menu, &update, &sync, cfg.sync);
}

/// `nanolight --toggle`: the running copy's panel (Wayland's shortcut);
/// `--version`: what the updater asks a downloaded copy. True when the
/// arguments were the whole job.
fn answeredArgs(init: std.process.Init, args: []const [:0]const u8) !bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var out: [64]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &out);
            try w.interface.print("nanolight {s}\n", .{version});
            try w.interface.flush();
            return true;
        }
        if (std.mem.eql(u8, arg, "--toggle")) return platform.Single.send(.toggle);
    }
    return false;
}

/// The settings kept outside the config: Google's completions (on unless
/// turned off in Settings), searches sent out, and the theme.
fn loadPreferences(s: *Nanolight, kv: nanoui.kv.Store, gpa: std.mem.Allocator) void {
    s.suggest_on = prefs.flag(kv, gpa, .suggest);
    s.searches_out = prefs.flag(kv, gpa, .searches_out);
    s.theme = prefs.theme(kv, gpa);
}

/// The panel as a hotkey shows it, then its window, hidden until its key
/// or its menu shows it.
fn openWindow(core: *App) !void {
    const s = core.s;
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    var options: nanoui.WindowOptions = .{
        .title = "Nanolight",
        .width = chrome.width,
        .height = s.height(),
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = core, .func = App.keyChanged },
        .content = .{ .view = .init(s, Nanolight.view) },
    };
    panel.adjust(&options);
    // Headless (snapshots): the panel alone; `setup`, which leaves room
    // round it, never runs.
    if (core.app.flags.hidden) {
        options.width = chrome.width;
        options.height = s.height();
    }
    core.window = try core.app.newWindow(options);
}

/// A run with a person at it: one copy, the window round the panel, the
/// key, the menu bar, updates and sync, then the app's loop.
fn runShown(
    init: std.process.Init,
    core: *App,
    menu: *menu_live.Menu,
    update: *update_live.Update,
    sync: *account_live.Sync,
    sync_cfg: account.Config,
) !void {
    // The newest launch is the one that stays; it hears `--toggle` (single.zig).
    if (platform.Single.claim(.{ .ctx = core, .func = App.command }) > 0) std.log.info(
        "nanolight: asked an older copy to quit",
        .{},
    );
    core.start();
    // The first run: the welcome, in the panel.
    if (!prefs.has(core.kv, .onboarded)) core.o.start(core.choice);
    try menu.start();
    update.start(init);
    sync.start(sync_cfg);
    core.menuChanged();
    var note_buf: [64]u8 = undefined;
    greet(core, update, &note_buf);
    try core.app.run();
}

/// Restarted by an automatic update: quietly, the panel saying so the
/// next time it opens (in `note_buf`). Otherwise launching stays in the
/// background, the key or the menu bar icon opening the panel, unless the
/// welcome is due.
fn greet(core: *App, update: *update_live.Update, note_buf: *[64]u8) void {
    if (update.greeting(note_buf)) |note| {
        core.s.note = note;
    } else if (core.o.active) App.toggle(core);
}
