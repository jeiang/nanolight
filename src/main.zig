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
const Nanolight = @import("nanolight.zig").Nanolight;
const view = @import("view.zig");
const pipeline = @import("pipeline.zig");
const chrome = @import("chrome.zig");
const Onboard = @import("onboard.zig").Onboard;
const platform = @import("platform.zig");
const shell = @import("shell.zig");
const single = @import("single.zig");
const panel = shell.panel;
const account = @import("account.zig");
const clock = @import("clock.zig");
const config = @import("config.zig");
const prefs = @import("prefs.zig");
const Theme = @import("palette.zig").Theme;
const App = @import("app.zig").App;
const suggest_live = @import("suggest_live.zig");
const rates = @import("rates.zig");
const files_live = @import("files_live.zig");
const script_live = @import("script_live.zig");
const commands_live = @import("commands_live.zig");
const clipboard_live = @import("clipboard_live.zig");
const account_live = @import("account_live.zig");
const update_live = @import("update_live.zig");
const menu_live = @import("menu_live.zig");
const settings_bind = @import("settings_bind.zig");
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Host = @import("host.zig").Host;
const version = @import("build_options").version;
const app_name = @import("app_facts.zig").app_name;

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    if (try answeredArgs(init, try init.minimal.args.toSlice(arena.allocator()))) return;
    panel.prepare();
    const app = try nanoui.App.create(
        init,
        .{ .name = app_name, .quit_on_last_window_closed = false },
    );
    defer app.destroy();
    // A headless run is no one's: neither their config nor their settings.
    var mem: nanoui.kv.Memory = .{ .gpa = init.gpa };
    defer mem.deinit();
    const kv = if (app.flags.hidden) mem.store() else nanoui.kv.standard();
    var cfg_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer cfg_arena.deinit();
    const loaded: config.Loaded = if (app.flags.hidden)
        .unusable
    else
        config.load(cfg_arena.allocator(), init.io, init.environ_map, kv);
    const cfg = loaded.config();
    config.apply(kv, init.gpa, loaded, clock.now());
    // The apps, once: the config names folders to look in besides.
    var index: Index = .init(init.gpa, init.io, init.environ_map);
    defer index.deinit();
    apps.scan(&index, cfg.apps.extra_dirs);
    index.finish();
    // The key is the config's or the Nix module's: the welcome does not ask.
    // `config.parse` lets through only a hotkey this system can use.
    var o: Onboard = .{
        .skip_key = !platform.key_ui or cfg.hotkey != null,
        .hooks = undefined, // The App's, below: their context.
    };
    var s: Nanolight = .{
        .index = &index,
        .starters = apps.starters,
        .tally = .{ .kv = kv },
        .away = .{ .pop_after = cfg.pop_to_root_seconds },
        // Both answer through the App, and come with the features `run` wires.
        .host = undefined,
        .rates = undefined,
    };
    defer s.deinit();
    s.tally.load(init.gpa);
    var core: App = .{
        .app = app,
        .s = &s,
        .o = &o,
        .kv = kv,
        .choice = prefs.hotkey(kv, init.gpa),
        .toggles = undefined, // Settings' (`run`): their context.
    };
    o.hooks = core.welcomeHooks();
    // The newest launch is the one that stays; it hears `--toggle`
    // (single.zig). Before any feature writes: an older copy's clipboard,
    // counts and switches are not both copies' to write.
    if (!app.flags.hidden) claim(init.io, &core);
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
    const s = core.s;
    var money: rates.Live = .{ .env = .{
        .gpa = core.app.gpa,
        .io = core.app.io,
        .kv = core.kv,
        .now = clock.now,
        .landed = .{ .ctx = core, .func = ratesLanded },
    } };
    defer money.deinit();
    s.rates = &money;
    var sug: suggest_live.Suggest = .{ .core = core };
    var files: files_live.Files = .{ .core = core };
    var sync: account_live.Sync = .{ .core = core };
    defer sync.deinit();
    var clip: clipboard_live.Clip = .{ .core = core };
    defer clip.deinit();
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
    core.toggles = bind.setter();
    const hidden = core.app.flags.hidden;
    // Opened, or null: without its folder there is no history. Never headless.
    if (!hidden) clip.open(loaded.clipboardConfig(), loaded != .unusable);
    var scripts: script_live.Scripts = .init(core, init.environ_map, cfg);
    defer scripts.deinit();
    var cmds: commands_live.Commands = .init(core, init.environ_map);
    defer cmds.deinit();
    if (!hidden) s.scripts = &scripts.list;
    s.host = host(core, &settings, sug.entry(), &files, &clip, &cmds);
    core.hooks = .{
        .showing = clip.showingHook(),
        .away = update.awayHook(),
        .menu = menu.menuHook(),
    };
    if (hidden) {
        ready(core, &bind, init.gpa);
        core.window = try core.app.newWindow(windowOptions(core, .snapshot));
        return core.app.run();
    }
    core.hooks.rescan = scripts.rescanHook();
    core.hooks.popped = scripts.poppedHook();
    core.hooks.opens = scripts.opensHook();
    _ = sync.setQuicklinks(prefs.quicklinks(cfg_arena, core.kv));
    ready(core, &bind, init.gpa);
    core.window = try core.app.newWindow(windowOptions(core, .panel));
    try runShown(init, core, &menu, &update, &sync, cfg.sync);
}

/// What the panel asks of the app, once: the features it has on this
/// machine, null where it has none (headless runs, a platform without).
fn host(
    core: *App,
    settings: *const SettingsHost,
    suggest: Host.Ask,
    files: *files_live.Files,
    clip: *clipboard_live.Clip,
    cmds: *commands_live.Commands,
) Host {
    return .{
        .ctx = core,
        .open = App.open,
        .hide = App.hide,
        .resize = App.resize,
        .preview = if (platform.preview) App.showPage else null,
        .suggest = suggest,
        .files = if (platform.files) files.entry() else null,
        .settings = settings,
        .clipboard = clip.entry(),
        .command = cmds.entry(),
    };
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
        if (std.mem.eql(u8, arg, "--toggle")) return shell.Single.send(.toggle);
    }
    return false;
}

/// What the panel lists from, once all of it is there: the counts kept by
/// name are their app's or script's, the switches and the theme kept
/// outside the config.
fn ready(core: *App, bind: *settings_bind.Bind, gpa: std.mem.Allocator) void {
    const s = core.s;
    s.tally.adopt(gpa, s.launchable());
    bind.load();
    const name = prefs.text(core.kv, gpa, .theme);
    defer if (name) |n| gpa.free(n);
    s.theme = Theme.parse(name);
}

/// The panel as a hotkey shows it, then its window's: hidden until its key
/// or its menu shows it. A snapshot is the panel alone: `setup`, which
/// leaves room round it for the shadow, never runs.
const Sized = enum { panel, snapshot };

fn windowOptions(core: *App, sized: Sized) nanoui.WindowOptions {
    const s = core.s;
    _ = s.show(clock.now());
    // The rows first, so a snapshot is as tall as the panel.
    pipeline.rebuild(s);
    var options: nanoui.WindowOptions = .{
        .title = app_name,
        .width = chrome.width,
        .height = view.height(s),
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = core, .func = App.keyChanged },
        .content = .{ .view = .init(s, view.window) },
    };
    panel.adjust(&options);
    if (sized == .snapshot) {
        options.width = chrome.width;
        options.height = view.height(s);
    }
    return options;
}

/// Asks an older copy to quit, and says what became of it.
fn claim(io: std.Io, core: *App) void {
    switch (shell.Single.claim(io, .{ .ctx = core, .func = App.command })) {
        .none => {},
        .quit => std.log.info("nanolight: asked an older copy to quit", .{}),
        .stayed => std.log.warn(
            "nanolight: an older copy didn't quit within {d} ms; both run",
            .{single.quit_wait_ms},
        ),
    }
}

/// A run with a person at it: the window round the panel, the key, the menu
/// bar, updates and sync, then the app's loop.
fn runShown(
    init: std.process.Init,
    core: *App,
    menu: *menu_live.Menu,
    update: *update_live.Update,
    sync: *account_live.Sync,
    sync_cfg: account.Config,
) !void {
    core.start();
    if (!prefs.keptOn(core.kv, core.app.gpa, .onboarded)) core.welcome(.first_run);
    try menu.start();
    update.start(init);
    sync.start(sync_cfg);
    core.menuChanged();
    greet(core, update);
    try core.app.run();
}

/// The rates arrived (or could not be had): the panel redoes its conversion,
/// the selection kept (`pipeline.refill`).
fn ratesLanded(ctx: *anyopaque) void {
    const core = App.from(ctx);
    pipeline.refill(core.s, .rates);
    core.redraw();
}

/// Restarted by an automatic update: quietly, the panel saying so the
/// next time it opens (in `note_buf`). Otherwise launching stays in the
/// background, the key or the menu bar icon opening the panel, unless the
/// welcome is due.
fn greet(core: *App, update: *update_live.Update) void {
    var buf: [64]u8 = undefined;
    if (update.greeting(&buf)) |note| {
        core.s.setNote(note);
    } else if (core.s.screen == .welcome) App.toggle(core);
}
