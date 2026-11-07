//! What the panel's tests share: a `Rig` (an index, the panel over it, and
//! the Tester that draws it), the hosts that record what the panel asked
//! of them, and the keys the tests press. Nothing is opened; no window shows.
const std = @import("std");
const assert = std.debug.assert;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Index = @import("apps.zig").Index;
const view = @import("view.zig");
const Nanolight = @import("nanolight.zig").Nanolight;
const Host = @import("host.zig").Host;
const chrome = @import("chrome.zig");
const Choice = @import("keys.zig").Choice;
const SettingsHost = @import("settings_host.zig").SettingsHost;
const Target = @import("host.zig").Target;

/// A panel over its own index, drawn by a Tester once mounted. Pinned: the
/// panel points at the index, so a Rig is initialized in place, and torn
/// down in the one order that frees everything the panel owns.
pub const Rig = struct {
    ix: Index,
    s: Nanolight,
    t: ui.Tester,
    mounted: bool,

    /// What the panel shows when it is mounted.
    pub const Screen = enum {
        /// Its rows, as a hotkey shows them (`Nanolight.show`).
        rows,
        /// Settings, as the tray's Settings… opens it.
        settings,
        /// Whatever the test set up before mounting.
        none,
    };

    pub const Options = struct {
        /// The panel's host; none keeps the one the test set, if any.
        host: ?Host = null,
        screen: Screen = .rows,
        width: f32 = chrome.width,
        height: f32 = chrome.max_height,
        dark: bool = true,
        /// A second of frames before the test goes on; off, the test draws
        /// its first frames itself.
        settle: bool = true,
    };

    /// An empty index and a panel over it; nothing drawn until `mount`.
    pub fn init(r: *Rig, gpa: std.mem.Allocator) void {
        r.ix = .init(gpa);
        r.s = .{ .index = &r.ix };
        r.t = undefined;
        r.mounted = false;
    }

    /// Adds each of `names` as an app at /Applications/<name>.app.
    pub fn apps(r: *Rig, names: []const []const u8) !void {
        for (names) |name| {
            var path: [64]u8 = undefined;
            try r.ix.add(name, try std.fmt.bufPrint(&path, "/Applications/{s}.app", .{name}));
        }
    }

    /// Shows the panel's first screen in a Tester's window.
    pub fn mount(r: *Rig, options: Options) !void {
        assert(!r.mounted);
        assert(r.s.index == &r.ix);
        if (options.host) |host| r.s.host = host;
        switch (options.screen) {
            .rows => _ = r.s.show(0),
            .settings => r.s.open(.settings),
            .none => {},
        }
        try r.t.init(r.ix.gpa, .init(&r.s, view.window), .{
            .width = options.width,
            .height = options.height,
            .dark = options.dark,
        });
        r.mounted = true;
        if (options.settle) r.t.settle(1);
    }

    /// Closes the Tester's window, before what the panel drew is freed.
    pub fn unmount(r: *Rig) void {
        if (!r.mounted) return;
        r.t.deinit();
        r.mounted = false;
    }

    pub fn deinit(r: *Rig) void {
        r.unmount();
        r.s.deinit();
        r.ix.deinit();
        r.* = undefined;
    }
};

/// What a host was asked to open, and whether it hid the panel.
pub const Probe = struct {
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    hidden: bool = false,

    pub fn host(p: *Probe) Host {
        return .{ .ctx = p, .open = open, .hide = hide };
    }
    fn open(ctx: *anyopaque, target: Target) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        const text = said(target);
        @memcpy(p.opened[0..text.len], text);
        p.opened_len = text.len;
    }

    /// The path or address `target` opens; a script's place in its list
    /// is not one, and is recorded as nothing.
    fn said(target: Target) []const u8 {
        return switch (target) {
            .app, .url => |text| text,
            .pane => |i| @import("settings_panes.zig").urls[i],
            .script => "",
        };
    }
    fn hide(ctx: *anyopaque) void {
        const p: *Probe = @ptrCast(@alignCast(ctx));
        p.hidden = true;
    }
};

/// The selected row is the first quicklink: the search for what was typed.
pub fn onFirstQuicklink(s: *const Nanolight) bool {
    const r = s.selected() orelse return false;
    return r.kind == .quicklink and r.item == 0;
}

pub fn press(t: *ui.Tester, ops: []const ui.TextOp) void {
    t.textOps(ops);
    t.settle(1);
}

/// The field's text replaced by `q`.
pub fn retype(t: *ui.Tester, q: []const u8) void {
    press(t, &.{ .{ .command = .select_all }, .{ .command = .delete_backward }, .{ .insert = q } });
}

/// Clicks the button the panel names `label` for assistive apps: its text,
/// or its icon's words ("Settings" for the gear).
pub fn clickButton(t: *ui.Tester, label: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var list: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena.allocator(), &list);
    for (list.items) |e| if (e.role == .button and std.mem.eql(u8, e.label, label)) {
        t.click(e.rect.x + e.rect.w / 2, e.rect.y + e.rect.h / 2);
        return;
    };
    return error.NoSuchButton;
}

/// A host that answers for Google and shows pages: what was asked, shown.
pub const Web = struct {
    probe: Probe = .{},
    asked: [64]u8 = undefined,
    asked_len: usize = 0,
    page: [256]u8 = undefined,
    page_len: ?usize = null,

    pub fn host(w: *Web) Host {
        return .{
            .ctx = w,
            .open = open,
            .hide = hide,
            .suggest = .{ .ctx = w, .func = ask },
            .preview = show,
        };
    }
    fn open(ctx: *anyopaque, target: Target) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.open(&w.probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        Probe.hide(&w.probe);
    }
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        @memcpy(w.asked[0..q.len], q);
        w.asked_len = q.len;
    }
    fn show(ctx: *anyopaque, url: ?[]const u8) void {
        const w: *Web = @ptrCast(@alignCast(ctx));
        const u = url orelse {
            w.page_len = null;
            return;
        };
        @memcpy(w.page[0..u.len], u);
        w.page_len = u.len;
    }
};

/// What `Prefs` says of sync: Settings shows the host's words as they are.
pub const sync_status = "Sync: as the test host says";

/// A host that records what Settings asked it to do.
pub const Prefs = struct {
    probe: Probe = .{},
    key: Choice = .cmd_space,
    applied: ?Choice = null,
    recording: bool = false,
    /// Whether the recorder can start (an event monitor the system refused).
    can_record: bool = true,
    suggest_sets: u8 = 0,
    searches_out: ?bool = null,
    files: ?bool = null,
    theme: ?@import("palette.zig").Theme = null,
    menu_bar_on: bool = true,
    clip_on: bool = false,
    clip_cleared: u8 = 0,
    /// What Clear History answers.
    clip_clear_ok: bool = true,
    box: SettingsHost = undefined,
    /// The panel whose suggestions and searches the app's host would set.
    nl: ?*Nanolight = null,
    /// Opening at login, as the system keeps it: one for the process,
    /// as `Login.enabled` has. `init` turns it off.
    pub var login_on: bool = false;

    pub fn init(p: *Prefs) void {
        login_on = false;
        p.box = .{
            .ctx = p,
            .choice = choice,
            .apply = apply,
            .record = record,
            .login = login,
            .suggest = suggestSet,
            .files = filesSet,
            .searches_out = searchesOut,
            .theme = themeSet,
            .menu_bar = menuBar,
            .clipboard_enabled = clipboardEnabled,
            .clipboard_clear = clipboardClear,
            .sync_status = syncStatus,
            .version = ver,
            .ready = ready,
            .check = noop,
            .restart = noop,
            .welcome = noop,
            .quit = noop,
        };
    }
    pub fn host(p: *Prefs) Host {
        return .{ .ctx = p, .open = open, .hide = hide, .settings = &p.box };
    }
    fn open(ctx: *anyopaque, target: Target) void {
        Probe.open(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe, target);
    }
    fn hide(ctx: *anyopaque) void {
        Probe.hide(&@as(*Prefs, @ptrCast(@alignCast(ctx))).probe);
    }
    fn choice(ctx: *anyopaque) Choice {
        return @as(*Prefs, @ptrCast(@alignCast(ctx))).key;
    }
    fn apply(ctx: *anyopaque, c: Choice) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.applied = c;
        p.key = c;
    }
    fn record(ctx: *anyopaque, on: bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.recording = on and p.can_record;
        return p.recording;
    }
    fn login(set: ?bool) bool {
        if (set) |on| login_on = on;
        return login_on;
    }
    fn suggestSet(ctx: *anyopaque, on: bool) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.suggest_sets += 1;
        if (p.nl) |s| s.setSuggest(on);
    }
    fn filesSet(ctx: *anyopaque, on: bool) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.files = on;
        if (p.nl) |s| s.setFiles(on);
    }
    fn searchesOut(ctx: *anyopaque, on: bool) void {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.searches_out = on;
        if (p.nl) |s| s.searches_out = on;
    }
    fn themeSet(ctx: *anyopaque, t: @import("palette.zig").Theme) void {
        @as(*Prefs, @ptrCast(@alignCast(ctx))).theme = t;
    }
    fn menuBar(ctx: *anyopaque, set: ?bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        if (set) |on| p.menu_bar_on = on;
        return p.menu_bar_on;
    }
    fn clipboardEnabled(ctx: *anyopaque, set: ?bool) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        if (set) |on| p.clip_on = on;
        return p.clip_on;
    }
    fn clipboardClear(ctx: *anyopaque) bool {
        const p: *Prefs = @ptrCast(@alignCast(ctx));
        p.clip_cleared += 1;
        return p.clip_clear_ok;
    }
    fn syncStatus(_: *anyopaque) []const u8 {
        return sync_status;
    }
    fn ver(_: *anyopaque) []const u8 {
        return @import("build_options").version;
    }
    fn ready(_: *anyopaque) ?[]const u8 {
        return null;
    }
    fn noop(_: *anyopaque) void {}
};
