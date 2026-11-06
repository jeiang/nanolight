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
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const mac = builtin.os.tag == .macos;
const apps = @import("apps.zig");
const Index = apps.Index;
const view = @import("view.zig");
const Nanolight = view.Nanolight;
const hotkey = @import("hotkey.zig");
const shortcut = @import("shortcut.zig");
const Onboard = @import("onboard.zig").Onboard;
const suggest = @import("suggest.zig");
const convert = @import("convert.zig");
/// The panel's window, the page in it and clicks through it: the Mac's own,
/// or Windows' and Linux's (panel_pc.zig, pc_stubs.zig).
const panel = if (mac) @import("panel_mac.zig") else @import("panel_pc.zig");
const preview_mod = if (mac) @import("preview.zig") else @import("pc_stubs.zig");
const Preview = preview_mod.Preview;
const single = @import("single.zig");
const ClickThrough = if (mac) @import("clickthrough.zig").ClickThrough else @import("pc_stubs.zig").ClickThrough;
const Recorder = if (mac) @import("recorder.zig").Recorder else @import("pc_stubs.zig").Recorder;
const account = @import("account.zig");
const rc = @import("script_live.zig");
const settings_mod = @import("settings.zig");
const Settings = settings_mod.Settings;
const config = @import("config.zig");
const commands = @import("commands.zig");
const clipboard = @import("clipboard.zig");
const clipboard_view = @import("clipboard_view.zig");
const clipboard_live = @import("clipboard_live.zig");
/// A Nix build: no updater and no login-item UI; the modules own both.
const nix_managed = @import("build_options").nix_managed;

const suggest_key = config.suggest_key;
const searches_out_key = config.searches_out_key;
const menu_bar_key = config.menu_bar_key;

pub fn applyChoice(ctx: *anyopaque, choice: shortcut.Choice) void {
    Live.apply(ctx, choice);
}

pub fn recordKey(ctx: *anyopaque, on: bool) bool {
    return Live.record(ctx, on);
}

pub fn loginItem(ctx: *anyopaque, set: ?bool) bool {
    return Live.login(ctx, set);
}
/// Left by a restart into an update off the Mac (`restartForUpdate`), and by
/// 0.1.6 and before on the Mac (nanoui's updater says so itself now).
pub const updated_key = "nanolight.updated";
const sync_at_key = config.sync_at_key;
const rates_at_key = "nanolight.rates.at";

/// The app around the panel: its window, shown and hidden (panel_mac.zig,
/// panel_pc.zig), its key, its menu, its updates and its account.
pub const Live = struct {
    app: *nanoui.App,
    s: *Nanolight,
    o: *Onboard,
    kv: nanoui.kv.Store,
    choice: shortcut.Choice = .cmd_space,
    window: ?*nanoui.Window = null,
    preview: Preview = .{},
    /// Clicks outside the panel go to what is under it (clickthrough.zig).
    through: ClickThrough = .{},
    /// A key of one's own, being recorded in Settings (recorder.zig).
    recorder: Recorder = .{},
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
    /// The next `hide` is skipped: a command just took the panel.
    keep_open: bool = false,
    /// Clipboard history (clipboard_live.zig): the store, null in headless runs
    /// and without a data directory, and the OS's watcher.
    clip: ?*clipboard.Store = null,
    clip_watcher: clipboard.Watcher = .{},
    clip_host: clipboard_view.Host = undefined,

    fn host(l: *Live) view.Host {
        const bind = @import("settings_bind.zig");
        bind.box.ctx = l;
        return .{ .ctx = l, .open = open, .hide = hide, .resize = resize, .suggest = ask, .files = if (mac) @import("files_live.zig").askFiles else null, .preview = if (mac) showPage else null, .settings = &bind.box, .command = runCommand, .rates = needRates };
    }

    fn open(ctx: *anyopaque, target: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (apps.isUrl(target)) {
            _ = nanoui.shell.openUrl(target);
        } else if (rc.isCommand(target)) {
            rc.start(l, target);
        } else if (single.isSelf(target)) {
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
        var at: i64 = 0;
        if (l.kv.get(arena, sync_at_key) catch null) |v| at = std.fmt.parseInt(i64, v, 10) catch 0;
        var out: Settings = .{ .hotkey = "cmd_space", .suggest = l.s.suggest_on, .at = at };
        out.launches = list.items;
        out.quicklinks = l.ql_custom;
        const name = arena.create([shortcut.name_max]u8) catch return out;
        out.hotkey = l.choice.name(name);
        return out;
    }

    /// Lists `list` (those with an http or https address) in the panel, or
    /// the built-in quicklinks when none. False when nothing changed.
    fn setQuicklinks(l: *Live, list: []const settings_mod.Quicklink) bool {
        const arena = l.app.gpa.create(std.heap.ArenaAllocator) catch return false;
        arena.* = .init(l.app.gpa);
        var keep: std.ArrayList(settings_mod.Quicklink) = .empty;
        for (list) |q| {
            if (!settings_mod.webUrl(q.url)) {
                std.log.warn("nanolight: quicklink \"{s}\": only http and https addresses work; ignored", .{q.name});
                continue;
            }
            const copy: settings_mod.Quicklink = .{
                .name = arena.allocator().dupe(u8, q.name) catch break,
                .url = arena.allocator().dupe(u8, q.url) catch break,
                .keyword = arena.allocator().dupe(u8, q.keyword) catch break,
            };
            keep.append(arena.allocator(), copy) catch break;
        }
        if (settings_mod.sameQuicklinks(keep.items, l.ql_custom)) {
            arena.deinit();
            l.app.gpa.destroy(arena);
            return false;
        }
        if (l.ql_arena) |old| {
            old.deinit();
            l.app.gpa.destroy(old);
        }
        l.ql_arena = arena;
        l.ql_custom = keep.items;
        l.s.quicklinks = if (keep.items.len > 0) keep.items else &settings_mod.default_quicklinks;
        l.s.built = 1;
        return true;
    }

    /// The account's settings, merged: the key, the suggestions, the quicklinks, the counts.
    fn applySynced(ctx: *anyopaque, st: Settings) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        var at: [24]u8 = undefined;
        const at_text = std.fmt.bufPrint(&at, "{d}", .{st.at}) catch unreachable;
        _ = config.kvSet(l.kv, sync_at_key, at_text);
        if (shortcut.Choice.parse(st.hotkey)) |c| if (!c.eql(l.choice)) {
            _ = shortcut.save(l.kv, c);
            l.useKey(c);
        };
        l.setSuggest(st.suggest, .synced);
        if (l.setQuicklinks(st.quicklinks)) config.saveQuicklinks(l.kv, l.app.gpa, l.ql_custom);
        const ix = l.s.index;
        for (st.launches) |la| {
            const i = if (la.path.len > 0)
                ix.findPath(la.path) orelse ix.find(la.name)
            else
                ix.find(la.name);
            if (i) |idx| ix.apps.items[idx].launches = @max(ix.apps.items[idx].launches, la.count);
        }
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
        var at: [24]u8 = undefined;
        const now = std.fmt.bufPrint(&at, "{d}", .{account.now()}) catch unreachable;
        _ = config.kvSet(l.kv, sync_at_key, now);
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
        const data = nanoui.path(l.app.gpa, .data, "Nanolight") catch return null;
        defer l.app.gpa.free(data);
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
        var fetched_s: i64 = 0;
        if (l.kv.get(gpa, rates_at_key) catch null) |v| {
            defer gpa.free(v);
            fetched_s = std.fmt.parseInt(i64, v, 10) catch 0;
        }
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
    fn pageKey(ctx: *anyopaque, key: preview_mod.Key) void {
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
        _ = config.kvSet(l.kv, suggest_key, if (on) "1" else "0");
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
        _ = config.kvSet(l.kv, searches_out_key, if (on) "1" else "0");
    }

    /// Whether the menu bar icon shows; `set` shows or hides it. Hidden,
    /// Nanolight is its key alone: Settings stays in the panel (⌘,), and
    /// opening the app again shows the panel. The status item stays, only
    /// unseen (nanoui's App keeps its trays until it quits).
    pub fn menuBar(l: *Live, set: ?bool) bool {
        if (comptime !mac) return false;
        const objc = nanoui.objc;
        const t = l.tray orelse return false;
        if (set) |on| {
            _ = config.kvSet(l.kv, menu_bar_key, if (on) "1" else "0");
            objc.msg(void, t.item, "setVisible:", .{if (on) objc.YES else objc.NO});
        }
        return objc.msg(objc.BOOL, t.item, "isVisible", .{});
    }

    /// The menu bar icon's menu, with the update waiting, if one is.
    fn menu(l: *Live) void {
        // No tray icon in nanoui on Windows and Linux yet: Settings has it all.
        if (comptime !mac) return;
        const t = l.tray orelse return;
        const ready = if (l.updater) |u| u.ready() else null;
        const label = if (ready) |v| std.fmt.bufPrint(&l.update_label, "Restart to Update to {s}", .{v}) catch "Restart to Update" else "Check for Updates";
        const acc = l.accountItem();
        const Item = nanoui.menu.MenuItem;
        const update = if (nix_managed) [_]Item{} else [_]Item{.{ .label = label, .disabled = l.updater == null, .click = .of(l, Live.updateNow) }};
        t.setMenu("Nanolight", &([_]Item{
            .{ .label = "Settings…", .accelerator = "Cmd+,", .click = .of(l, Live.menuSettings) },
            .{ .label = "Open Nanolight", .click = .of(l, Live.menuShow) },
            .{ .label = "Welcome…", .click = .of(l, Live.welcome) },
            .{ .label = "Google Suggestions", .kind = .checkbox, .checked = l.s.suggest_on, .click = .of(l, Live.toggleSuggest) },
            .separator,
            acc,
            .separator,
        } ++ update ++ [_]Item{.{ .label = "Quit Nanolight", .role = .quit }})) catch {};
    }

    fn updateNow(l: *Live, _: *nanoui.menu.Item) void {
        const u = l.updater orelse return;
        if (u.ready() != null) l.restartForUpdate() else u.checkNow();
    }

    /// Restarts into the update that is ready, if one is. Off the Mac the
    /// new copy learns it was updated from `updated_key` (the Mac's
    /// updater says so itself, `updatedFrom`).
    pub fn restartForUpdate(l: *Live) void {
        const u = l.updater orelse return;
        const v = u.ready() orelse return;
        // best effort: without the note the new copy only skips "Updated to".
        if (!mac) l.kv.set(updated_key, v) catch {};
        if (u.restart()) l.app.quit() else if (!mac) l.kv.remove(updated_key);
    }

    fn updated(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        menu(l);
        if (!mac) @import("update_pc.zig").away(l);
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
        // The Mac's popover hides itself; elsewhere the panel goes as
        // another window takes the keys.
        if (!mac and w.isVisible()) w.hide();
        if (!mac) @import("update_pc.zig").away(l);
    }

    pub fn hide(ctx: *anyopaque) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.keep_open) {
            l.keep_open = false;
            return;
        }
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
        const showing = w.isVisible() and panel.focused(w);
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
        return .{ .ctx = l, .apply = apply, .fix = fix, .login = if (l.o.skip_key) null else login, .done = done };
    }

    fn useKey(l: *Live, choice: shortcut.Choice) void {
        l.choice = choice;
        hotkey.register(choice, .{ .ctx = l, .func = toggle }) catch |e|
            std.log.warn("nanolight: {f} can't be registered ({s}); open it from the menu bar", .{ choice, @errorName(e) });
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

    fn recorded(ctx: *anyopaque, r: shortcut.Recorded) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        l.s.settings_ui.took(l.s, r);
        if (l.window) |w| w.redraw();
    }

    pub fn apply(ctx: *anyopaque, choice: shortcut.Choice) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        _ = shortcut.save(l.kv, choice);
        l.useKey(choice);
        l.touched();
    }

    fn fix(ctx: *anyopaque, clash: shortcut.Clash) void {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (clash.system != null) {
            _ = nanoui.shell.openUrl("x-apple.systempreferences:com.apple.Keyboard-Settings.extension");
        } else for (clash.launchers) |name| shortcut.quit(name);
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
        return @import("login.zig").login(set);
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
        shortcut.setOnboarded(l.kv);
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
        if (r.status != 200 or !suggest.decode(arena.allocator(), r.body, a.text[0..a.len], &list)) return l.s.unanswered(a.text[0..a.len]);
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
            var at: [24]u8 = undefined;
            const at_text = std.fmt.bufPrint(&at, "{d}", .{l.rates.fetched_s}) catch unreachable;
            _ = config.kvSet(l.kv, rates_at_key, at_text);
            if (l.ratesPath()) |path| {
                defer gpa.free(path);
                std.Io.Dir.cwd().writeFile(l.app.io, .{ .sub_path = path, .data = r.body }) catch {};
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

/// This platform's archive in each release (macos/package.sh, pc/package.sh).
const asset = switch (builtin.os.tag) {
    .macos => "nanolight-macos-arm64.zip",
    .windows => "nanolight-windows-x86_64.zip",
    else => "nanolight-linux-" ++ @tagName(builtin.cpu.arch) ++ ".tar.gz",
};
const version = @import("build_options").version;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    // `nanolight --toggle`: the running copy's panel (Wayland's shortcut);
    // `--version`: what the updater asks a downloaded copy.
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    for (try init.minimal.args.toSlice(arena.allocator())) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            var out: [64]u8 = undefined;
            var w = std.Io.File.stdout().writer(init.io, &out);
            try w.interface.print("nanolight {s}\n", .{version});
            return w.interface.flush();
        }
        if (std.mem.eql(u8, arg, "--toggle")) {
            if (single.send(.toggle)) return;
            break;
        }
    }
    // Linux: GTK 3, where a window can be put somewhere (GTK 4 lets only
    // the compositor place one), unless the user asked for another.
    if (builtin.os.tag == .linux and std.c.getenv("NANOUI_GTK") == null) _ = setenv("NANOUI_GTK", "3", 0);
    const app = try nanoui.App.create(init, .{ .name = "Nanolight", .quit_on_last_window_closed = false });
    defer app.destroy();
    var index: Index = .init(init.gpa);
    defer index.deinit();
    apps.scanSystem(&index, init.io, init.environ_map);
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
    var o: Onboard = .{ .skip_key = nix_managed or (if (cfg.hotkey) |h| shortcut.Choice.parse(h) != null else false) };
    var s: Nanolight = .{ .index = &index, .kv = kv, .onboard = &o };
    defer s.query.deinit();
    defer s.found.deinit();
    var live: Live = .{ .app = app, .s = &s, .o = &o, .kv = kv, .choice = shortcut.load(kv, init.gpa), .cfg = cfg };
    defer live.rates.deinit();
    s.feed = &live.rates;
    defer if (live.ql_arena) |a| {
        a.deinit();
        init.gpa.destroy(a);
    };
    s.host = live.host();
    s.pop_after = cfg.pop_to_root_seconds;
    if (!app.flags.hidden) _ = live.setQuicklinks(config.loadQuicklinks(cfg_arena.allocator(), kv));
    @import("files_live.zig").load(&live);
    // Google's completions are on unless turned off in Settings.
    if (kv.get(init.gpa, suggest_key) catch null) |v| {
        defer init.gpa.free(v);
        s.suggest_on = !std.mem.eql(u8, v, "0");
    }
    if (kv.get(init.gpa, searches_out_key) catch null) |v| {
        defer init.gpa.free(v);
        s.searches_out = std.mem.eql(u8, v, "1");
    }
    s.theme = @import("settings_bind.zig").loadTheme(kv, init.gpa);
    s.reveal();
    // The rows first, so a snapshot is as tall as the panel.
    s.rebuild();
    var options: nanoui.WindowOptions = .{
        .title = "Nanolight",
        .resizable = false,
        .visible = false,
        .on_key = .{ .ctx = &live, .func = Live.keyChanged },
        .content = .{ .view = .init(&s, Nanolight.view) },
    };
    panel.adjust(&options, app.flags.hidden, s.height());
    live.window = try app.newWindow(options);
    if (app.flags.hidden) return app.run();
    // Script commands among the apps (never in headless runs: they're this
    // machine's).
    rc.init(&live, init.environ_map);
    defer rc.deinit(&live);
    commands.init(init.io, init.environ_map);
    live.cmds = .{ .io = app.io, .hooks = .{ .ctx = &live, .footer = Live.commandFooter, .done = Live.commandDone } };
    defer live.cmds.deinit();
    rc.rescan(&live);
    var clip_dir = clipboard_live.openDir(init.gpa, init.io);
    defer if (clip_dir) |*d| d.close(init.io);
    const clip_cfg = config.clipboardConfig(kv, init.gpa, loaded);
    var clip_store: clipboard.Store = .init(init.gpa, init.io, clip_dir, clip_cfg);
    defer clip_store.deinit();
    // No data directory, no history: nothing could be kept.
    if (clip_dir != null) clipboard_live.init(&live, &clip_store);
    defer clipboard_live.deinit(&live);
    // The newest launch is the one that stays; it hears `--toggle` (single.zig).
    if (single.claim(.{ .ctx = &live, .func = Live.command }) > 0) std.log.info("nanolight: asked an older copy to quit", .{});
    panel.setup(app, live.window.?, &s, if (o.active) o.height() else s.height());
    live.useKey(live.choice);
    live.through = .{ .window = live.window, .height = &s.last_h };
    live.preview.watch(.{ .ctx = &live, .func = Live.pageKey });
    o.hooks = live.hooks();
    // The first run: the welcome, in the panel.
    if (!shortcut.onboarded(kv)) o.start(live.choice);
    if (mac) live.tray = try app.newTray(.{ .symbol = "magnifyingglass", .tooltip = "Nanolight" });
    // The menu bar icon, unless Settings took it away.
    if (kv.get(init.gpa, menu_bar_key) catch null) |v| {
        defer init.gpa.free(v);
        if (std.mem.eql(u8, v, "0")) _ = live.menuBar(false);
    }
    // A release build checks its GitHub releases; one run from zig-out
    // can't replace itself, and leaves the item off. A Nix build never
    // updates itself.
    const updater = if (nix_managed) null else nanoui.Updater.start(init, .{
        .repo = "jeiang/nanolight",
        .asset = asset,
        .version = version,
        .name = "Nanolight",
        .changed = .{ .ctx = &live, .func = Live.updated },
    }) catch null;
    defer if (updater) |u| u.deinit();
    if (updater) |u| if (u.phase.load(.acquire) != .off) {
        live.updater = u;
        // A launcher almost never quits, so installing at quit would mean
        // never: it restarts into an update once the panel has been away
        // 10 s, unseen, and comes back as it was (update_pc.zig off the Mac).
        u.autoRestart(app, .{ .idle_ms = 10 * 1000 });
    };
    // `[sync]` names a server: synced now.
    live.acct = .{ .gpa = init.gpa, .io = init.io, .kv = kv, .hooks = live.accountHooks(), .cfg = cfg.sync };
    live.acct.?.load();
    live.menu();
    // Restarted by an automatic update: quietly, the panel saying so the
    // next time it opens. Otherwise launching stays in the background,
    // the key or the menu bar icon opening the panel, unless the welcome
    // is due.
    var note_buf: [64]u8 = undefined;
    const old = kv.get(init.gpa, updated_key) catch null;
    defer if (old) |v| init.gpa.free(v);
    if (old != null) kv.remove(updated_key);
    const restarted = if (live.updater) |u| u.updatedFrom() != null else false;
    if (restarted or old != null) {
        const now = if (live.updater) |u| u.current else old.?;
        s.note = std.fmt.bufPrint(&note_buf, "Updated to {s}", .{now}) catch "Updated";
    } else if (o.active) Live.toggle(&live);
    try app.run();
}
