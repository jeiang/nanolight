//! The first run, inside the panel itself: no tour, no permissions (Carbon's
//! hot keys need none). Three steps, each one thing to do:
//!   1. the shortcut: ⌘Space by default, and who else holds it, by name,
//!      with the one thing that frees it;
//!   2. press it for real: the panel closes, and comes back on the second
//!      press — nothing advances on a button;
//!   3. a first search to run, where Nanolight lives (the menu bar), and
//!      whether it opens at login.
//! Esc skips at any step, closing the panel, and it stays skipped; the menu
//! bar icon replays it. It is up while it is the panel's screen (view.zig
//! `Screen.welcome`), which ends it once as it goes; it ends itself with
//! an `Outcome`.
const std = @import("std");
const nanoui = @import("nanoui");
const app_name = @import("app_facts.zig").app_name;
const ui = nanoui.ui;
const motion = ui.motion;
const keys = @import("keys.zig");
const shortcut = @import("shortcut.zig");
const shortcut_clash = @import("shortcut_clash.zig");
const platform = @import("platform.zig");
const Choice = keys.Choice;
const chrome = @import("chrome.zig");
const Palette = @import("palette.zig").Palette;
const Theme = @import("palette.zig").Theme;
const Toggle = @import("toggles.zig").Toggle;

pub const Step = enum { key, try_it, done };

/// What the steps ask of the app and the system.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Who holds the keys, the system's into `system_buf`
    /// (`shortcut_holders.look`). The system keeps it, so no context.
    look: *const fn (system_buf: []shortcut_clash.SystemKey) shortcut_clash.Holders,
    /// Uses `choice` from now on (registers it, keeps it).
    apply: *const fn (ctx: *anyopaque, choice: Choice) void,
    /// Frees the shortcut: Keyboard Shortcuts opened, a launcher quit.
    fix: *const fn (ctx: *anyopaque, clash: shortcut_clash.Clash) void,
    /// Whether it opens at login; `set` changes it first.
    login: *const fn (ctx: *anyopaque, set: ?bool) bool,
    /// The welcome is over: keep that.
    done: *const fn (ctx: *anyopaque) void,
};

/// The last step asks about login where Settings has its switch.
const asks_login = Toggle.login.present(false);

/// How the welcome ends itself: into the launcher, with `finish` typed (a
/// first search) or nothing.
pub const Outcome = union(enum) { finish: []const u8 };

/// Escape before the last step: the welcome is skipped.
const skip: chrome.Key = .{ .what = "Skip", .key = "esc" };
/// The last step's main act.
const start_key: chrome.Key = .{ .what = "Start searching", .key = "↩", .first = true };

/// An app every machine of the kind has, math, and words for a quicklink.
const examples = [_]platform.Example{
    platform.example_app,
    .{ .q = "2^10 * 3", .what = "Do math", .icon = platform.math_icon },
    .{ .q = "liquid glass", .what = "Search the web", .icon = "sparkles" },
};

pub const Onboard = struct {
    step: Step = .key,
    choice: Choice = .cmd_space,
    /// The key in use: the one at `start`, then the one applied. Only a
    /// different choice is applied (applying syncs it, over another Mac's).
    kept: Choice = .cmd_space,
    hooks: Hooks,
    system_buf: [96]shortcut_clash.SystemKey = undefined,
    holders: shortcut_clash.Holders = .{},
    /// Step 2: the shortcut closed the panel, then opened it again.
    closed: bool = false,
    reopened: bool = false,
    reopened_at: ?f64 = null,
    login: bool = false,
    /// The key is set elsewhere (config.toml, a Nix build): no key step.
    skip_key: bool = false,

    pub fn start(o: *Onboard, choice: Choice) void {
        o.step = if (o.skip_key) .try_it else .key;
        o.choice = choice;
        o.kept = choice;
        o.closed = false;
        o.reopened = false;
        o.reopened_at = null;
        o.refresh();
    }

    /// Looks again at who holds the keys (after a fix, on each showing).
    pub fn refresh(o: *Onboard) void {
        o.holders = o.hooks.look(&o.system_buf);
        if (asks_login) o.login = o.hooks.login(o.hooks.ctx, null);
    }

    pub fn clash(o: *const Onboard) shortcut_clash.Clash {
        return shortcut_clash.clash(o.choice, &o.holders);
    }

    /// The hot key fired while the welcome is up, the panel `visible`
    /// before it: step 2's presses.
    pub fn pressed(o: *Onboard, visible: bool) void {
        if (o.step != .try_it) return;
        if (visible) o.closed = true else if (o.closed) o.reopened = true;
    }

    /// Each step's room, measured: its content and some air under it, into
    /// which the page grows (tests.zig checks the content fits). The key
    /// step is taller by a line while the key clashes.
    const key_h: f32 = 330;
    const clash_h: f32 = 30;
    const try_h: f32 = 318;
    const done_h: f32 = 350;
    const login_h: f32 = 46;
    comptime {
        // The window is never resized: every step fits in it.
        const tallest = @max(key_h + clash_h, try_h, done_h + login_h);
        std.debug.assert(tallest <= chrome.max_height);
    }

    pub fn height(o: *const Onboard) f32 {
        const c = o.clash();
        return switch (o.step) {
            .key => key_h + @as(f32, if (c.clear()) 0 else clash_h),
            .try_it => try_h,
            .done => done_h + @as(f32, if (asks_login) login_h else 0),
        };
    }

    pub fn draw(o: *Onboard, c: *ui.Context, p: Palette, theme: Theme) ?Outcome {
        const enter = c.input.key == .enter;
        // Return moves it on: what changed shows in this frame.
        if (enter) c.changed = true;
        // A step's content comes in from the right, briefly.
        ui.key(c, @tagName(o.step));
        const f = motion.frame(
            c,
            .{ .initial = .{ .opacity = 0, .x = 14 }, .transition = .{ .spring = chrome.spring } },
        );
        const page = ui.div(c).column().wFull().grow().motion(f);
        var out: ?Outcome = null;
        switch (o.step) {
            .key => o.keyStep(c, p, enter),
            .try_it => o.tryStep(c, p),
            .done => out = o.doneStep(c, p, theme, enter),
        }
        page.end();
        o.footer(c, p);
        return out;
    }

    fn keyStep(o: *Onboard, c: *ui.Context, p: Palette, enter: bool) void {
        if (c.input.key == .left) o.choice = o.choice.step(-1);
        if (c.input.key == .right) o.choice = o.choice.step(1);
        if (enter) return o.next(c, .try_it);
        {
            const top = ui.div(c).row().wFull().px(28).pt(28).pb(22).gap(16).itemsCenter();
            defer top.end();
            chrome.appIcon(c, 56);
            const t = ui.div(c).column().gap(4);
            defer t.end();
            ui.text(
                c,
                "Welcome to " ++ app_name,
                .{ .size = 22, .weight = .semibold, .color = p.text, .tracking = -0.3 },
            );
            ui.text(
                c,
                "Apps, math and quicklinks — one keystroke away.",
                .{ .size = 13.5, .color = p.sub },
            );
        }
        chrome.hairline(c, p);
        const body = ui.div(c).column().wFull().px(28).pt(18).gap(12);
        defer body.end();
        ui.text(c, "Open it with", p.heading());
        {
            const row = ui.div(c).row().gap(8);
            defer row.end();
            // The four, and a key recorded in Settings when it is the one.
            var shown: [Choice.all.len + 1]Choice = undefined;
            @memcpy(shown[0..Choice.all.len], &Choice.all);
            shown[Choice.all.len] = o.choice;
            for (shown[0 .. Choice.all.len + @intFromBool(o.choice.preset() == null)]) |ch| {
                ui.key(c, c.print("key-{d}-{d}", .{ ch.code, ch.mods }));
                const on = ch.eql(o.choice);
                const label = c.print("{f}", .{shortcut.text(ch)});
                const b = chrome.shortcutChip(c, p, label, on, chrome.welcome_chip);
                defer b.end();
                if (b.clicked()) o.choice = ch;
            }
        }
        o.status(c, p);
        const sure = ui.div(c).row().gap(6).itemsCenter().pt(2);
        defer sure.end();
        ui.icon(c, "lock.open", .{ .size = 11, .color = p.sub.alpha(0.7) });
        ui.text(
            c,
            "No permissions to grant: the shortcut works as it is.",
            .{ .size = 12, .color = p.sub.alpha(0.7) },
        );
    }

    /// Who else answers the keys, by name, and the one thing that frees them.
    fn status(o: *Onboard, c: *ui.Context, p: Palette) void {
        const cl = o.clash();
        const keys_text = c.print("{f}", .{shortcut.text(o.choice)});
        const ok = c.theme.success;
        const warn: ui.Color = if (c.theme.dark) .hex(0xe0a33a) else .hex(0xb26b00);
        const box = ui.div(c).column().wFull().gap(8).p(12).rounded(10)
            .bg((if (cl.clear()) ok else warn).alpha(0.1));
        defer box.end();
        const line = ui.div(c).row().gap(8).itemsCenter();
        if (cl.clear()) {
            ui.icon(c, "checkmark.circle.fill", .{ .size = 14, .color = ok });
            ui.textf(
                c,
                .{ .size = 13, .weight = .medium, .color = p.text },
                "{s} is free on this {s}.",
                .{ keys_text, platform.machine },
            );
            line.end();
            return;
        }
        ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 13, .color = warn });
        if (cl.system) |who| {
            ui.textf(
                c,
                .{ .size = 13, .weight = .medium, .color = p.text },
                if (platform.system_shortcuts)
                    "macOS gives {s} to {s} first."
                else
                    "{s} is held by {s}.",
                .{ keys_text, who },
            );
        } else {
            ui.textf(
                c,
                .{ .size = 13, .weight = .medium, .color = p.text },
                "{s} {s} running and may answer {s} too.",
                .{
                    list(c, cl.launchers.slice()),
                    if (cl.launchers.n == 1) "is" else "are",
                    keys_text,
                },
            );
        }
        line.end();
        // Without the system's table there is no one place to free a key:
        // another one is the fix.
        if (!platform.system_shortcuts and cl.system != null) {
            const r = ui.div(c).row().pl(22);
            ui.text(c, "Pick another key above.", p.detail());
            return r.end();
        }
        const fix = ui.div(c).row().gap(10).itemsCenter().pl(22);
        defer fix.end();
        const label = if (cl.system != null)
            "Open Keyboard Shortcuts"
        else
            c.print("Quit {s}", .{cl.launchers.slice()[0]});
        const b = ui.div(c).row().h(26).px(12).itemsCenter().rounded(7).bg(p.sel).border(p.rim)
            .control();
        if (b.clicked()) o.hooks.fix(o.hooks.ctx, cl);
        ui.text(c, label, .{ .size = 12, .weight = .semibold, .color = p.text });
        b.end();
        ui.text(c, "or pick another key above", p.detail());
    }

    fn list(c: *ui.Context, names: []const []const u8) []const u8 {
        if (names.len == 1) return names[0];
        return c.print("{s} and {s}", .{ names[0], names[1] });
    }

    fn tryStep(o: *Onboard, c: *ui.Context, p: Palette) void {
        if (o.reopened) {
            const at = o.reopened_at orelse blk: {
                o.reopened_at = c.time;
                break :blk c.time;
            };
            // Both ticks show for a moment, then the last step.
            if (c.time - at > 0.75) return o.next(c, .done);
            c.animationFrame();
        }
        const col = ui.div(c).column().wFull().pt(34).gap(18).itemsCenter();
        defer col.end();
        {
            const caps = ui.div(c).row().gap(10).itemsCenter();
            defer caps.end();
            const ch = o.choice;
            const held_mod = modsHeld(ch, c);
            const mods = c.print("{f}", .{shortcut.held(ch)});
            if (mods.len > 0) {
                // A PC's "Ctrl Alt" is words, not glyphs: wider per key.
                const n: f32 = @floatFromInt(@popCount(ch.mods));
                const w: f32 = if (platform.pc_modifiers)
                    40 + 8 * @as(f32, @floatFromInt(mods.len))
                else
                    68 + 22 * @max(0, n - 2);
                cap(c, p, mods, w, held_mod or o.reopened);
                ui.text(c, "+", .{ .size = 20, .weight = .medium, .color = p.sub.alpha(0.6) });
            }
            cap(
                c,
                p,
                c.print("{f}", .{shortcut.key(ch)}),
                if (ch.code == keys.space) 180 else 68,
                o.reopened,
            );
        }
        {
            const t = ui.div(c).column().gap(6).itemsCenter();
            defer t.end();
            ui.textf(
                c,
                .{ .size = 20, .weight = .semibold, .color = p.text, .tracking = -0.2 },
                "Press {f} now",
                .{shortcut.text(o.choice)},
            );
            ui.text(
                c,
                "It closes. Press it again and it comes back, from any app.",
                .{ .size = 13.5, .color = p.sub },
            );
        }
        const ticks = ui.div(c).row().gap(10);
        defer ticks.end();
        tick(c, p, "Closed", o.closed);
        tick(c, p, "Back again", o.reopened);
    }

    /// Every modifier of `ch` is held now: on a PC by its preset's keys.
    fn modsHeld(ch: Choice, c: *const ui.Context) bool {
        const in = c.input;
        if (platform.pc_modifiers) {
            const pc = ch.pc();
            if (pc.ctrl and !in.ctrl) return false;
            if (pc.alt and !in.alt) return false;
            if (pc.shift and !in.shift) return false;
            return true;
        }
        if (ch.mods & keys.cmd != 0 and !in.cmd) return false;
        if (ch.mods & keys.option != 0 and !in.alt) return false;
        if (ch.mods & keys.control != 0 and !in.ctrl) return false;
        if (ch.mods & keys.shift != 0 and !in.shift) return false;
        return true;
    }

    fn cap(c: *ui.Context, p: Palette, str: []const u8, w: f32, lit: bool) void {
        const t = motion.number(
            c,
            str,
            if (lit) 1 else 0,
            .{ .spring = .{ .stiffness = 600, .damping = 40 } },
        );
        const d = ui.div(c).w(w).h(64).center().rounded(14).bg(p.tile.mix(p.text.alpha(0.22), t))
            .border(p.rim.mix(p.text.alpha(0.45), t))
            .shadow(.{ .color = .{ .a = 0.18 * (1 - t) }, .blur = 0, .y = 3 }).offset(0, 2 * t);
        defer d.end();
        ui.text(
            c,
            str,
            .{ .size = if (str.len > 3) 18 else 26, .weight = .medium, .color = p.text },
        );
    }

    fn tick(c: *ui.Context, p: Palette, str: []const u8, on: bool) void {
        const ok = c.theme.success;
        const d = ui.div(c).row().gap(6).h(28).px(12).itemsCenter().roundedFull()
            .bg(if (on) ok.alpha(0.16) else p.tile);
        defer d.end();
        ui.icon(
            c,
            if (on) "checkmark.circle.fill" else "circle",
            .{ .size = 13, .color = if (on) ok else p.sub.alpha(0.6) },
        );
        ui.text(c, str, .{ .size = 12.5, .weight = .medium, .color = if (on) p.text else p.sub });
    }

    fn doneStep(o: *Onboard, c: *ui.Context, p: Palette, theme: Theme, enter: bool) ?Outcome {
        if (enter) return .{ .finish = "" };
        if (chrome.numberKey(c, examples.len)) |i| return .{ .finish = examples[i].q };
        {
            const top = ui.div(c).column().wFull().px(28).pt(26).pb(16).gap(4);
            defer top.end();
            ui.text(
                c,
                "You're set.",
                .{ .size = 22, .weight = .semibold, .color = p.text, .tracking = -0.3 },
            );
            ui.textf(
                c,
                .{ .size = 13.5, .color = p.sub },
                "{f} opens it anywhere. Start with one of these:",
                .{shortcut.text(o.choice)},
            );
        }
        {
            const rows = ui.div(c).column().wFull().px(16).gap(2);
            defer rows.end();
            for (examples, 0..) |e, i| {
                ui.key(c, e.q);
                const r = ui.div(c).row().wFull().h(40).px(12).gap(12).itemsCenter().rounded(10)
                    .control().hover(p.sel);
                defer r.end();
                if (r.clicked()) return .{ .finish = e.q };
                chrome.tile(c, p, e.icon);
                ui.textf(
                    c,
                    .{ .size = 13.5, .weight = .medium, .color = p.text, .mono = true },
                    "{s}",
                    .{e.q},
                );
                ui.text(c, e.what, p.detail());
                ui.spacer(c);
                // A shade stronger than the launcher's `hint`; kept as drawn.
                var hint = p.hint();
                hint.color = p.sub.alpha(0.55);
                ui.textf(c, hint, "{s}{d}", .{ platform.mod, i + 1 });
            }
        }
        const home = ui.div(c).column().wFull().px(28).pt(16).gap(12);
        defer home.end();
        {
            const r = ui.div(c).row().gap(10).itemsCenter();
            defer r.end();
            const tile = ui.div(c).size(26, 22).rounded(6).bg(p.tile).center();
            ui.icon(c, theme.glyph(), .{ .size = 12, .weight = .semibold, .color = p.text });
            tile.end();
            ui.text(
                c,
                "Settings are on " ++ platform.mod ++ ", and the gear" ++ if (platform.tray)
                    ". It also lives in your menu bar."
                else
                    " at the bottom of the panel.",
                .{ .size = 12.5, .color = p.sub },
            );
        }
        if (asks_login and ui.toggle(c, "Open " ++ app_name ++ " when you log in", &o.login)) {
            o.login = o.hooks.login(o.hooks.ctx, o.login);
        }
        return null;
    }

    fn footer(o: *Onboard, c: *ui.Context, p: Palette) void {
        const bar = chrome.footer(c, p);
        defer bar.end();
        const first: usize = @intFromBool(o.skip_key);
        const total = 3 - first;
        const n: usize = @backingInt(o.step) - first;
        for (0..total) |i| ui.div(c).w(if (i == n) 16 else 6).h(6).roundedFull()
            .bg(if (i == n) p.text.alpha(0.7) else p.sub.alpha(0.3)).end();
        var count = p.detail();
        count.tabular = true;
        ui.textf(c, count, "  {d} of {d}", .{ n + 1, total });
        ui.spacer(c);
        const act: chrome.Key = switch (o.step) {
            .key => .{
                .what = if (o.clash().clear())
                    "Continue"
                else
                    c.print("Use {f} anyway", .{shortcut.text(o.choice)}),
                .key = "↩",
                .first = true,
            },
            .try_it => return chrome.footerKeysThen(c, p, &.{}, skip),
            .done => return chrome.footerKeys(c, p, &.{start_key}),
        };
        chrome.footerKeysThen(c, p, &.{act}, skip);
    }

    fn next(o: *Onboard, c: *ui.Context, step: Step) void {
        // This frame drew the old step: the new one is drawn now too.
        c.changed = true;
        c.animationFrame();
        if (o.step == .key) o.useChoice();
        o.step = step;
    }

    /// Applies the key chosen, if it is not the one in use.
    fn useChoice(o: *Onboard) void {
        if (o.choice.eql(o.kept)) return;
        o.kept = o.choice;
        o.hooks.apply(o.hooks.ctx, o.choice);
    }

    /// How the welcome ends: with the key shown on the key step, or
    /// without it (another screen opened over it).
    pub const Exit = enum { take_choice, drop_choice };

    /// The welcome's one way out: done, and kept as done. The panel calls
    /// it once, as its screen goes (view.zig `Nanolight.leave`).
    pub fn end(o: *Onboard, exit: Exit) void {
        if (exit == .take_choice and o.step == .key) o.useChoice();
        o.hooks.done(o.hooks.ctx);
    }
};

const TestHooks = struct {
    applied: ?Choice = null,
    ended: u8 = 0,

    fn hooks(t: *TestHooks) Hooks {
        return .{
            .ctx = t,
            .look = nobody,
            .apply = apply,
            .fix = fix,
            .login = login,
            .done = done,
        };
    }
    /// The system's shortcuts are not read in tests: nobody holds a key.
    fn nobody(_: []shortcut_clash.SystemKey) shortcut_clash.Holders {
        return .{};
    }
    fn apply(ctx: *anyopaque, c: Choice) void {
        @as(*TestHooks, @ptrCast(@alignCast(ctx))).applied = c;
    }
    fn fix(_: *anyopaque, _: shortcut_clash.Clash) void {}
    fn login(_: *anyopaque, set: ?bool) bool {
        return set orelse false;
    }
    fn done(ctx: *anyopaque) void {
        @as(*TestHooks, @ptrCast(@alignCast(ctx))).ended += 1;
    }
};

test "a welcome skipped applies no key" {
    var th: TestHooks = .{};
    var o: Onboard = .{ .hooks = th.hooks() };
    o.start(.cmd_space);
    o.choice = .opt_space;
    o.end(.drop_choice);
    try std.testing.expectEqual(@as(u8, 1), th.ended);
    try std.testing.expect(th.applied == null);
}

test "the welcome applies its key only when it changed" {
    var th: TestHooks = .{};
    var o: Onboard = .{ .hooks = th.hooks() };
    o.start(.ctrl_space);
    o.end(.take_choice);
    try std.testing.expect(th.applied == null);
    try std.testing.expectEqual(@as(u8, 1), th.ended);
    o.start(.ctrl_space);
    o.choice = .opt_space;
    o.end(.take_choice);
    try std.testing.expectEqual(Choice.opt_space, th.applied.?);
    try std.testing.expectEqual(@as(u8, 2), th.ended);
}
