//! Nanolight, after Peekalight: a launcher that opens over everything on
//! ⌘Space, or the key picked in its welcome (onboard.zig), or from its
//! menu bar icon; finds apps as you type (initials
//! too: "ss" is System Settings), answers math, and hands anything else to
//! your quicklinks (Google, Claude, Grok...), with Google's completions of it (suggest.zig) and its
//! results in the panel (preview.zig). Its panel is the system's vibrancy
//! (NSVisualEffectView, as launchers use), nanoui drawing on it.
//! It lives in the menu bar: no Dock icon, nothing drawn while idle.
//! `zig build run`, or `zig build app` and open zig-out/Nanolight.app.
const std = @import("std");
const nanoui = @import("nanoui");
const apps = @import("apps.zig");
const Index = apps.Index;
const view = @import("view.zig");
const Nanolight = view.Nanolight;
const hotkey = @import("hotkey.zig");
const keys = @import("keys.zig");
const shortcut = @import("shortcut.zig");
const shortcut_clash = @import("shortcut_clash.zig");
const Onboard = @import("onboard.zig").Onboard;
const suggest = @import("suggest.zig");
const convert = @import("convert.zig");
/// This OS's panel window, page, click-through, recorder, single copy and
/// login item, and what it can do (platform.zig).
const platform = @import("platform.zig");
const panel = platform.panel;
const single = @import("single.zig");
const account = @import("account.zig");
const rc = @import("script_live.zig");
const settings_mod = @import("settings.zig");
const Settings = settings_mod.Settings;
const config = @import("config.zig");
const commands = @import("commands.zig");
const clipboard = @import("clipboard.zig");
const clipboard_view = @import("clipboard_view.zig");
const clipboard_live = @import("clipboard_live.zig");
const prefs = @import("prefs.zig");
/// A Nix build: no updater and no login-item UI; the modules own both.
const nix_managed = @import("build_options").nix_managed;

pub fn applyChoice(ctx: *anyopaque, choice: keys.Choice) void {
    Live.apply(ctx, choice);
}

pub fn recordKey(ctx: *anyopaque, on: bool) bool {
    return Live.record(ctx, on);
}

pub fn loginItem(ctx: *anyopaque, set: ?bool) bool {
    return Live.login(ctx, set);
}

/// The app around the panel: its window, shown and hidden (panel_mac.zig,
/// panel_pc.zig), its key, its menu, its updates and its account.
pub const Live = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *Onboard,
    kv: nanoui.kv.Store,
    choice: keys.Choice = .cmd_space,
    window: ?*nanoui.Window = null,
    preview: platform.Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: platform.ClickThrough = .{},
    /// A key of one's own, being recorded in Settings (recorder.zig).
    recorder: platform.Recorder = .{},
    /// The words Google is to be asked about once typing pauses, and how
    /// many pauses are still being waited out (only the last one asks).
    asking: [suggest.max_len]u8 = undefined,
    asking_len: usize = 0,
    waiting: u32 = 0,
    files: @import("files_live.zig").State = .{},
    /// Updates from GitHub's releases (a signed build only), and the menu
    /// bar icon whose menu offers one once it's ready.
    updater: ?*nanoui.Updater = null,
    tray: ?*nanoui.Tray = null,
    update_label: [64]u8 = undefined,
    /// Settings synced through a nanolight-server (account.zig). Null in headless runs.
    acct: ?account.Account = null,
    account_label: [192]u8 = undefined,
    /// The script command running in the panel (script_live.zig).
    ext_ui: @import("raycast_view.zig").Ext = undefined,
    /// Raycast script commands, run by Nanolight itself (script_run.zig).
    scripts: @import("script_run.zig").Runner = undefined,
    env: ?*const std.process.Environ.Map = null,
    /// config.toml, as read at launch (strings live in main's arena).
    cfg: config.Config = .{},
    /// The quicklinks from the config or sync, empty for the built-in ones
    /// (`setQuicklinks`).
    ql_custom: []const settings_mod.Quicklink = &.{},
    ql_arena: ?*std.heap.ArenaAllocator = null,
    /// System commands, run by Nanolight itself (commands.zig).
    cmds: commands.Runner = undefined,
    /// Currency rates (convert.zig) and their fetching.
    rates: convert.Feed = .{},
    /// Clipboard history (clipboard_live.zig): the store, null in headless runs
    /// and without a data directory, and the OS's watcher.
    clip: ?*clipboard.Store = null,
    clip_watcher: clipboard.Watcher = .{},
    clip_host: clipboard_view.Host = undefined,

    fn host(l: *Live) view.Host {
        const bind = @import("settings_bind.zig");
        bind.box.ctx = l;
        return .{
            .ctx = l,
            .open = open,
            .hide = hide,
            .resize = resize,
            .suggest = ask,
            .files = if (platform.files) @import("files_live.zig").askFiles else null,
            .preview = if (platform.preview) showPage else null,
            .settings = &bind.box,
            .command = runCommand,
            .rates = needRates,
        };
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (apps.isUrl(target)) {
            _ = nanoui.shell.openUrl(target);
        } else if (rc.isCommand(target)) {
            rc.start(l, target);
        } else if (platform.Single.isSelf(target)) {
            // Nanolight is already open: the panel comes back, empty,
            // rather than macOS starting a second copy.
            l.s.query.clear();
            nanoui.App.after(60, l, struct {
                fn f(c: ?*anyopaque) callconv(.c) void {
                    toggle(c.?);
                }
            }.f);
        } else {
            _ = apps.launch(l.app.io, target);
            // Its count went up: the other Macs suggest it too.
            if (l.acct) |*a| a.changed();
        }
    }

    fn runCommand(ctx: *anyopaque, i: usize) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.note = "";
        l.cmds.start(i);
    }

    fn commandFooter(ctx: *anyopaque, text: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.note = text;
        if (l.window) |w| w.redraw();
    }

    fn commandDone(ctx: *anyopaque) void {
        hide(ctx);
    }

    // ----- sync (account.zig) -----

    fn accountHooks(l: *Live) account.Hooks {
        return .{ .ctx = l, .snapshot = snapshot, .apply = applySynced, .changed = accountChanged };
    }

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator) Settings {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const ix = l.s.index;
        var list: std.ArrayList(settings_mod.Launch) = .empty;
        for (ix.apps.items) |a| if (a.launches > 0) {
            const one: settings_mod.Launch = .{
                .name = a.name,
                .path = a.path,
                .count = a.launches,
            };
            list.append(arena, one) catch break;
        };
        const at = prefs.int(l.kv, arena, .sync_at);
        var out: Settings = .{ .hotkey = "cmd_space", .suggest = l.s.suggest_on, .at = at };
        out.launches = list.items;
        out.quicklinks = l.ql_custom;
        const name = arena.create([keys.name_max]u8) catch return out;
        out.hotkey = l.choice.name(name);
        return out;
    }

    /// Lists `list` (those `settings_mod.quicklinkProblem` lets through) in the panel,
    /// or the built-in quicklinks when none. False when nothing changed, or the list
    /// could not be copied (logged; the old one stays).
    fn setQuicklinks(l: *Live, list: []const settings_mod.Quicklink) bool {
        const arena = l.app.gpa.create(std.heap.ArenaAllocator) catch return false;
        arena.* = .init(l.app.gpa);
        const keep = copyQuicklinks(arena.allocator(), list) catch |e| {
            std.log.warn("nanolight: the quicklinks could not be listed: {t}", .{e});
            arena.deinit();
            l.app.gpa.destroy(arena);
            return false;
        };
        if (settings_mod.sameQuicklinks(keep, l.ql_custom)) {
            arena.deinit();
            l.app.gpa.destroy(arena);
            return false;
        }
        if (l.ql_arena) |old| {
            old.deinit();
            l.app.gpa.destroy(old);
        }
        l.ql_arena = arena;
        l.ql_custom = keep;
        l.s.quicklinks = if (keep.len > 0) keep else &settings_mod.default_quicklinks;
        l.s.built = 1;
        return true;
    }

    /// The quicklinks of `list` that can be listed, copied into `arena`.
    fn copyQuicklinks(
        arena: std.mem.Allocator,
        list: []const settings_mod.Quicklink,
    ) ![]const settings_mod.Quicklink {
        var keep: std.ArrayList(settings_mod.Quicklink) = .empty;
        for (list, 0..) |q, i| {
            if (settings_mod.quicklinkProblem(i, q)) |why| {
                std.log.warn("nanolight: quicklink \"{s}\": {s}; ignored", .{ q.name, why });
                continue;
            }
            try keep.append(arena, .{
                .name = try arena.dupe(u8, q.name),
                .url = try arena.dupe(u8, q.url),
                .keyword = try arena.dupe(u8, q.keyword),
            });
        }
        return keep.items;
    }

    /// The account's settings, merged: the key, the suggestions, the quicklinks, the counts.
    fn applySynced(ctx: *anyopaque, st: Settings) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        // A failure is logged; the next sync sends this machine's older time.
        _ = prefs.setInt(l.kv, .sync_at, st.at);
        if (keys.Choice.parse(st.hotkey)) |c| if (!c.eql(l.choice)) {
            _ = prefs.setHotkey(l.kv, c);
            l.useKey(c);
        };
        l.setSuggest(st.suggest, .synced);
        if (l.setQuicklinks(st.quicklinks)) prefs.setQuicklinks(l.kv, l.app.gpa, l.ql_custom);
        const ix = l.s.index;
        for (st.launches) |la| if (ix.resolve(la.path, la.name)) |i| {
            ix.apps.items[i].launches = @max(ix.apps.items[i].launches, la.count);
        };
        ix.save(l.kv);
        l.s.built = 1;
        l.menu();
        if (l.window) |w| w.redraw();
    }

    fn accountChanged(ctx: *anyopaque) void {
        menu(@ptrCast(@alignCast(ctx)));
    }

    /// This Mac chose its key or turned suggestions on or off, just now.
    fn touched(l: *Live) void {
        // A failure is logged; this change then syncs as an older one.
        _ = prefs.setInt(l.kv, .sync_at, account.now());
        if (l.acct) |*a| a.changed();
    }

    fn accountItem(l: *Live) nanoui.menu.MenuItem {
        return @import("account_menu.zig").item(if (l.acct) |*x| x else null, &l.account_label);
    }

    pub fn syncStatus(l: *Live) []const u8 {
        return if (l.acct) |*a| a.status(&l.account_label) else account.off_text;
    }

    /// Google is asked once typing pauses (`suggest.pause_ms`).
    fn ask(ctx: *anyopaque, query: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const q = std.mem.trim(u8, query, " ");
        if (q.len > suggest.max_len) return l.s.unanswered(q);
        @memcpy(l.asking[0..q.len], q);
        l.asking_len = q.len;
        l.waiting += 1;
        nanoui.App.after(suggest.pause_ms, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.waiting -= 1;
                if (live.waiting == 0) live.send();
            }
        }.f);
    }

    fn send(l: *Live) void {
        const q = l.asking[0..l.asking_len];
        // Typed on, or turned off, while it waited.
        if (!l.s.suggest_on or !suggest.same(q, l.s.query.text())) return l.s.unanswered(q);
        const a = l.app.gpa.create(Ask) catch return l.s.unanswered(q);
        a.* = .{ .live = l, .len = q.len };
        @memcpy(a.text[0..q.len], q);
        var buf: [suggest.url_max]u8 = undefined;
        nanoui.http.fetch(l.app.gpa, .{
            .url = suggest.url(&buf, q),
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 4,
        }, a, Ask.done);
    }

    fn ratesPath(l: *Live) ?[]u8 {
        const data = prefs.dataDir(l.app.gpa) catch return null;
        defer l.app.gpa.free(data);
        // best effort: without the folder no rates are read, and the write says why.
        std.Io.Dir.cwd().createDirPath(l.app.io, data) catch {};
        return std.fs.path.join(l.app.gpa, &.{ data, "rates.json" }) catch null;
    }

    /// A conversion is listed: the cached table on the first call, then a
    /// fetch when none is in hand or it is a day old (`convert.Feed.due`).
    fn needRates(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (!l.rates.cache_read) {
            l.readCachedRates();
            if (l.rates.table() != null) l.s.ratesLanded();
        }
        const now_s = account.now();
        if (!l.rates.due(now_s)) return;
        l.rates.begin(now_s);
        l.fetchRates(0);
    }

    /// The table and its day as the last fetch left them, if any.
    fn readCachedRates(l: *Live) void {
        const gpa = l.app.gpa;
        const fetched_s = prefs.int(l.kv, gpa, .rates_at);
        var table: ?convert.Rates = null;
        if (l.ratesPath()) |path| {
            defer gpa.free(path);
            const limit: std.Io.Limit = .limited(convert.max_bytes);
            if (std.Io.Dir.cwd().readFileAlloc(l.app.io, path, gpa, limit) catch null) |body| {
                defer gpa.free(body);
                table = convert.Rates.parse(gpa, body);
            }
        }
        l.rates.cached(table, fetched_s);
    }

    fn fetchRates(l: *Live, which: usize) void {
        const a = l.app.gpa.create(RatesAsk) catch return l.rates.fail();
        a.* = .{ .live = l, .which = which };
        nanoui.http.fetch(l.app.gpa, .{
            .url = convert.urls[which],
            .headers = &.{.{ .name = "Accept", .value = "application/json" }},
            .timeout = 10,
        }, a, RatesAsk.done);
    }

    /// A search's page in the panel, or (null) not.
    fn showPage(ctx: *anyopaque, url: ?[]const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        if (url) |u| l.preview.show(w, u, l.s.last_h) else l.preview.hide();
    }

    /// Escape (the page gone, the panel with it) or ⌘↩ while the page has the keys.
    fn pageKey(ctx: *anyopaque, key: @import("preview.zig").Key) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (key) {
            .escape => {
                l.s.back();
                hide(l);
            },
            .open_out => {
                var buf: [2048]u8 = undefined;
                open(l, l.preview.current(&buf) orelse l.s.preview_url);
                hide(l);
            },
        }
        if (l.window) |w| w.redraw();
    }

    fn toggleSuggest(l: *Live, item: *nanoui.menu.Item) void {
        l.setSuggest(item.checked, .here);
    }

    /// Where a change to a setting came from: this machine (synced on) or the account.
    pub const Origin = enum { here, synced };

    /// Google's suggestions on or off: the one writer (the menu, Settings, sync).
    pub fn setSuggest(l: *Live, on: bool, origin: Origin) void {
        if (on == l.s.suggest_on) return;
        l.s.suggest_on = on;
        // A failure is logged; the choice holds for this run, the next launch falls back to on.
        _ = prefs.setFlag(l.kv, .suggest, on);
        if (origin == .here) l.touched();
        // The rows again, with or without them.
        l.s.built = 1;
        if (l.window) |w| w.redraw();
        // The menu's checkbox follows; never rebuilt inside its own click.
        nanoui.App.after(0, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                menu(@ptrCast(@alignCast(c.?)));
            }
        }.f);
    }

    pub fn setSearchesOut(l: *Live, on: bool) void {
        l.s.searches_out = on;
        _ = prefs.setFlag(l.kv, .searches_out, on);
    }

    /// Whether the menu bar icon shows; `set` shows or hides it. Hidden,
    /// Nanolight is its key alone: Settings stays in the panel (⌘,), and
    /// opening the app again shows the panel. The status item stays, only
    /// unseen (nanoui's App keeps its trays until it quits).
    pub fn menuBar(l: *Live, set: ?bool) bool {
        if (comptime !platform.tray) return false;
        const objc = nanoui.objc;
        const t = l.tray orelse return false;
        if (set) |on| {
            _ = prefs.setFlag(l.kv, .menu_bar, on);
            objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
        }
        return objc.msg(objc.BOOL, t.item, "isVisible", .{});
    }

    /// The menu bar icon's menu, with the update waiting, if one is.
    fn menu(l: *Live) void {
        if (comptime !platform.tray) return;
        const t = l.tray orelse return;
        const ready = if (l.updater) |u| u.ready() else null;
        const label = if (ready) |v|
            std.fmt.bufPrint(
                &l.update_label,
                "Restart to Update to {s}",
                .{v},
            ) catch "Restart to Update"
        else
            "Check for Updates";
        const acc = l.accountItem();
        const Item = nanoui.menu.MenuItem;
        const update = if (nix_managed)
            [_]Item{}
        else
            [_]Item{
                .{ .label = label, .disabled = l.updater == null, .click = .of(l, Live.updateNow) },
            };
        t.setMenu("Nanolight", &([_]Item{
            .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(l, Live.menuSettings) },
            .{ .label = "Open Nanolight", .click = .of(l, Live.menuShow) },
            .{ .label = "Welcome…", .click = .of(l, Live.welcome) },
            .{
                .label = "Google Suggestions",
                .kind = .checkbox,
                .checked = l.s.suggest_on,
                .click = .of(l, Live.toggleSuggest),
            },
            .separator,
            acc,
            .separator,
            // best effort: without the menu, the panel still opens from its key.
        } ++ update ++ [_]Item{.{ .label = "Quit Nanolight", .role = .quit }})) catch {};
    }

    fn updateNow(l: *Live, _: *nanoui.menu.Item) void {
        const u = l.updater orelse return;
        if (u.ready() != null) l.restartForUpdate() else u.checkNow();
    }

    /// Restarts into the update that is ready, if one is. Off the Mac the
    /// new copy learns it was updated from prefs' `.updated` (the Mac's
    /// updater says so itself, `updatedFrom`).
    pub fn restartForUpdate(l: *Live) void {
        const u = l.updater orelse return;
        const v = u.ready() orelse return;
        const note = !platform.native_autorestart;
        // A failure is logged; without the note the new copy only skips "Updated to".
        if (note) _ = prefs.setText(l.kv, .updated, v);
        if (u.restart()) l.app.quit() else if (note) prefs.remove(l.kv, .updated);
    }

    fn updated(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        menu(l);
        if (!platform.native_autorestart) @import("update_pc.zig").away(l);
    }

    /// The panel became, or stopped being, the key window (it hides as it
    /// stops): an "Updated" note is done. (An update waiting goes in once
    /// the panel has been away a while: nanoui's `autoRestart`.)
    fn keyChanged(ctx: *anyopaque, w: *nanoui.Window) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (w.isFocused()) return;
        if (l.recorder.active()) _ = record(l, false);
        l.s.hid(account.now());
        l.through.stop();
        l.s.note = "";
        panel.lostKeys(w);
        if (!platform.native_autorestart) @import("update_pc.zig").away(l);
    }

    pub fn hide(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.hid(account.now());
        if (l.window) |w| w.hide();
    }

    /// The window (or the Mac's glass under the panel) to its height.
    fn resize(ctx: *anyopaque, h: f32) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.preview.fit(h);
        // The panel grew or shrank under a still pointer.
        l.through.update();
        if (l.window) |w| panel.resize(w, h);
    }

    fn toggle(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        const w = l.window orelse return;
        const showing = panel.showing(w);
        l.o.pressed(showing);
        if (showing) {
            l.s.hid(account.now());
            return w.hide();
        }
        // Where a paste from the clipboard history goes.
        if (l.clip != null) l.clip_watcher.noteFrontmost();
        // Freed a key in System Settings, quit a launcher: look again.
        if (l.o.active) l.o.refresh();
        panel.place(w);
        rc.refresh(l);
        if (l.s.popDue(account.now())) {
            l.scripts.pop();
            l.s.toRoot();
        }
        l.s.reveal();
        w.show();
        panel.shown(w);
        l.through.start();
        if (l.acct) |*a| a.maybePull();
        w.redraw();
    }

    fn hooks(l: *Live) @import("onboard.zig").Hooks {
        return .{
            .ctx = l,
            .apply = apply,
            .fix = fix,
            .login = if (l.o.skip_key) null else login,
            .done = done,
        };
    }

    fn useKey(l: *Live, choice: keys.Choice) void {
        l.choice = choice;
        hotkey.register(choice, .{ .ctx = l, .func = toggle }) catch |e|
            std.log.warn(
                "nanolight: {f} can't be registered ({s}); open it from the menu bar",
                .{ shortcut.text(choice), @errorName(e) },
            );
    }

    /// Settings records a key: until it has one, keys pressed go to it,
    /// and the current key is let go (pressed, it is recorded too) once
    /// the recorder runs. Whether it is recording now.
    pub fn record(ctx: *anyopaque, on: bool) bool {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (on) {
            // No recorder, no recording: the key stays registered.
            if (!l.recorder.start(.{ .ctx = l, .func = recorded })) return false;
            hotkey.unregister();
            return true;
        }
        l.recorder.stop();
        l.s.settings_ui.key_input = .idle;
        l.useKey(l.choice);
        return false;
    }

    fn recorded(ctx: *anyopaque, r: keys.Recorded) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.settings_ui.took(l.s, r);
        if (l.window) |w| w.redraw();
    }

    pub fn apply(ctx: *anyopaque, choice: keys.Choice) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        _ = prefs.setHotkey(l.kv, choice);
        l.useKey(choice);
        l.touched();
    }

    fn fix(ctx: *anyopaque, clash: shortcut_clash.Clash) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (clash.system != null) {
            _ = nanoui.shell.openUrl(
                "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            );
        } else for (clash.launchers.slice()) |name| shortcut_clash.quit(name);
        // A launcher takes a moment to quit: then the panel looks again.
        nanoui.App.after(900, l, struct {
            fn f(c: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(c.?));
                live.o.refresh();
                if (live.window) |w| w.redraw();
            }
        }.f);
    }

    /// Open at login (login.zig).
    pub fn login(_: *anyopaque, set: ?bool) bool {
        return platform.Login.enabled(set);
    }

    /// `nanolight --toggle`, or a newer copy starting (single.zig).
    fn command(ctx: *anyopaque, cmd: single.Command) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        switch (cmd) {
            .toggle => toggle(l),
            .quit => l.app.quit(),
        }
    }

    fn done(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        // A failure is logged; the welcome then shows again at the next start.
        _ = prefs.setFlag(l.kv, .onboarded, true);
    }

    fn welcome(l: *Live, item: *nanoui.menu.Item) void {
        l.o.start(l.choice);
        if (l.window) |w| if (w.isVisible()) w.hide();
        l.menuShow(item);
    }

    /// The menu opens the panel straight into Settings.
    fn menuSettings(l: *Live, _: *nanoui.menu.Item) void {
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                const live: *Live = @ptrCast(@alignCast(ctx.?));
                const w = live.window orelse return;
                if (!(w.isVisible() and w.isFocused())) toggle(live);
                // Over the welcome: skipped, kept as done, its key not taken.
                live.o.end(.drop_choice);
                live.s.openSettings();
                w.redraw();
            }
        }.f);
    }

    fn menuShow(l: *Live, _: *nanoui.menu.Item) void {
        // The menu closes first; then the panel takes the keys.
        nanoui.App.after(50, l, struct {
            fn f(ctx: ?*anyopaque) callconv(.c) void {
                toggle(ctx.?);
            }
        }.f);
    }
};

/// A question to Google on its way: the words it is about.
const Ask = struct {
    live: *Live,
    text: [suggest.max_len]u8 = undefined,
    len: usize,

    fn done(a: *Ask, r: nanoui.http.Response) void {
        const l = a.live;
        defer l.app.gpa.destroy(a);
        defer if (l.window) |w| w.redraw();
        var arena: std.heap.ArenaAllocator = .init(l.app.gpa);
        defer arena.deinit();
        var list: suggest.List = .{};
        if (r.status != 200 or
            !suggest.decode(
                arena.allocator(),
                r.body,
                a.text[0..a.len],
                &list,
            )) return l.s.unanswered(a.text[0..a.len]);
        l.s.answered(a.text[0..a.len], &list);
    }
};

/// A fetch of the rates on its way: which of `convert.urls` it asked.
const RatesAsk = struct {
    live: *Live,
    which: usize,

    fn done(a: *RatesAsk, r: nanoui.http.Response) void {
        const l = a.live;
        const gpa = l.app.gpa;
        defer gpa.destroy(a);
        const table = if (r.status == 200) convert.Rates.parse(gpa, r.body) else null;
        if (table) |t| {
            l.rates.landed(t, account.now());
            // A failure is logged; the next launch then fetches again.
            _ = prefs.setInt(l.kv, .rates_at, l.rates.fetched_s);
            if (l.ratesPath()) |path| {
                defer gpa.free(path);
                std.Io.Dir.cwd()
                    .writeFile(l.app.io, .{ .sub_path = path, .data = r.body }) catch |err|
                    std.log.warn("nanolight: the rates weren't kept in {s}: {t}", .{ path, err });
            }
        } else if (a.which + 1 < convert.urls.len) {
            return l.fetchRates(a.which + 1);
        } else {
            l.rates.fail();
        }
        l.s.ratesLanded();
        if (l.window) |w| w.redraw();
    }
};

/// This platform's file in each release.
const asset = @import("build_options").asset;
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
    var s: Nanolight = .{ .index = &index, .kv = kv, .onboard = &o };
    defer s.query.deinit();
    defer s.found.deinit();
    var live: Live = .{
        .app = app,
        .s = &s,
        .o = &o,
        .kv = kv,
        .choice = prefs.hotkey(kv, init.gpa),
        .cfg = cfg,
    };
    defer live.rates.deinit();
    s.feed = &live.rates;
    defer if (live.ql_arena) |a| {
        a.deinit();
        init.gpa.destroy(a);
    };
    s.host = live.host();
    s.pop_after = cfg.pop_to_root_seconds;
    if (!app.flags.hidden) _ = live.setQuicklinks(prefs.quicklinks(cfg_arena.allocator(), kv));
    @import("files_live.zig").load(&live);
    loadPreferences(&s, kv, init.gpa);
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    var options: nanoui.WindowOptions = .{
        .title = "Nanolight",
        .width = view.width,
        .height = s.height(),
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = &live, .func = Live.keyChanged },
        .content = .{ .view = .init(&s, Nanolight.view) },
    };
    panel.adjust(&options);
    // Headless (snapshots): the panel alone; `setup`, which leaves room
    // round it, never runs.
    if (app.flags.hidden) {
        options.width = view.width;
        options.height = s.height();
    }
    live.window = try app.newWindow(options);
    if (app.flags.hidden) return app.run();
    try runShown(init, &live, loaded);
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

/// A run with a person at it: script commands, the clipboard history, the
/// hotkey, the menu bar, updates and sync, then the app's loop.
fn runShown(init: std.process.Init, live: *Live, loaded: config.Loaded) !void {
    const app = live.app;
    const s = live.s;
    const o = live.o;
    const kv = live.kv;
    // Script commands among the apps (never in headless runs: they're this
    // machine's).
    rc.init(live, init.environ_map);
    defer rc.deinit(live);
    commands.init(init.io, init.environ_map);
    live.cmds = .{
        .io = app.io,
        .hooks = .{ .ctx = live, .footer = Live.commandFooter, .done = Live.commandDone },
    };
    defer live.cmds.deinit();
    rc.rescan(live);
    var clip_dir = clipboard_live.openDir(init.gpa, init.io);
    defer if (clip_dir) |*d| d.close(init.io);
    var clip_store: clipboard.Store = .init(init.gpa, init.io, clip_dir, loaded.clipboardConfig());
    defer clip_store.deinit();
    clip_store.on = prefs.flagOr(kv, init.gpa, .clipboard, clip_store.cfg.enabled orelse true);
    clip_store.config_ok = loaded != .unusable;
    // No data directory, no history: nothing could be kept.
    if (clip_dir != null) clipboard_live.init(live, &clip_store);
    defer clipboard_live.deinit(live);
    // The newest launch is the one that stays; it hears `--toggle` (single.zig).
    if (platform.Single.claim(.{ .ctx = live, .func = Live.command }) > 0) std.log.info(
        "nanolight: asked an older copy to quit",
        .{},
    );
    panel.setup(live.window.?, s);
    panel.resize(live.window.?, if (o.active) o.height() else s.height());
    live.useKey(live.choice);
    live.through = .{ .window = live.window, .height = &s.last_h };
    live.preview.watch(.{ .ctx = live, .func = Live.pageKey });
    o.hooks = live.hooks();
    // The first run: the welcome, in the panel.
    if (!prefs.has(kv, .onboarded)) o.start(live.choice);
    if (platform.tray) live.tray = try app.newTray(
        .{ .symbol = "magnifyingglass", .tooltip = "Nanolight" },
    );
    // The menu bar icon, unless Settings took it away.
    if (!prefs.flag(kv, init.gpa, .menu_bar)) _ = live.menuBar(false);
    const updater = startUpdater(init, live);
    defer if (updater) |u| u.deinit();
    // `[sync]` names a server: synced now.
    live.acct = .{
        .gpa = init.gpa,
        .io = init.io,
        .kv = kv,
        .hooks = live.accountHooks(),
        .cfg = live.cfg.sync,
    };
    live.acct.?.load();
    live.menu();
    var note_buf: [64]u8 = undefined;
    greet(init.gpa, live, &note_buf);
    try app.run();
}

/// A release build checks its GitHub releases; one run from zig-out
/// can't replace itself, and leaves the item off. A Nix build never
/// updates itself. The caller ends what this returns.
fn startUpdater(init: std.process.Init, live: *Live) ?*nanoui.Updater {
    if (nix_managed) return null;
    const u = nanoui.Updater.start(init, .{
        .repo = @import("build_options").repo,
        .asset = asset,
        .version = version,
        .name = "Nanolight",
        .changed = .{ .ctx = live, .func = Live.updated },
    }) catch return null;
    if (u.phase.load(.acquire) == .off) return u;
    live.updater = u;
    // A launcher almost never quits, so installing at quit would mean
    // never: it restarts into an update once the panel has been away
    // 10 s, unseen, and comes back as it was (update_pc.zig off the Mac).
    u.autoRestart(live.app, .{ .idle_ms = 10 * 1000 });
    return u;
}

/// Restarted by an automatic update: quietly, the panel saying so the
/// next time it opens (in `note_buf`). Otherwise launching stays in the
/// background, the key or the menu bar icon opening the panel, unless the
/// welcome is due.
fn greet(gpa: std.mem.Allocator, live: *Live, note_buf: *[64]u8) void {
    const kv = live.kv;
    const old = prefs.text(kv, gpa, .updated);
    defer if (old) |v| gpa.free(v);
    if (old != null) prefs.remove(kv, .updated);
    const restarted = if (live.updater) |u| u.updatedFrom() != null else false;
    if (restarted or old != null) {
        const now = if (live.updater) |u| u.current else old.?;
        live.s.note = std.fmt.bufPrint(note_buf, "Updated to {s}", .{now}) catch "Updated";
    } else if (live.o.active) Live.toggle(live);
}
