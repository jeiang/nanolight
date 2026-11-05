//! What the promo's camera looks at: a desktop, dimmed, and on it the
//! panel (the app's own `view.zig`), Google's page in it while it
//! previews, a quiet label naming what is shown, and the end, where the
//! panel's own rectangle becomes the icon beside the name. Labels are
//! sized against the camera's zoom, so they read the same at every zoom.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const motion = ui.motion;
const view = @import("view.zig");
const suggest = @import("suggest.zig");
const cam = @import("promo_camera.zig");

pub const width: f32 = 1440;
pub const height: f32 = 810;
pub const panel_x: f32 = (width - view.width) / 2;
/// The panel's top: lower at rest, higher while a page makes it tall.
pub const panel_top: f32 = 120;
pub const panel_top_tall: f32 = 24;
/// The room under the panel its label takes.
pub const label_room: f32 = 84;

/// The wallpaper's pixels a point: a 1920-pixel picture across the stage.
const wall_density: f32 = 1920.0 / width;

pub const Label = struct { text: []const u8, key: []const u8 = "", at: f32 };

/// What Google answered for these words (suggestqueries, client=firefox,
/// 2 November 2026), decoded as the app decodes them.
const answers = [_]struct { []const u8, []const u8 }{
    .{ "liquid gl", "[\"liquid gl\",[\"liquid glass\",\"liquid glue\",\"liquid glass apple\",\"liquid glass wallpaper\",\"liquid glycerol\"]]" },
    .{ "liquid glass", "[\"liquid glass\",[\"liquid glass\",\"liquid glass apple\",\"liquid glass wallpaper\",\"liquid glass ui\",\"liquid glass iphone\"]]" },
};

pub const Scene = struct {
    s: *view.Nanolight,
    gpa: std.mem.Allocator,
    wall: ?[]const u8,
    serp: ?[]const u8,
    /// Seconds into the video, and the camera this frame is shot through.
    now: f32 = 0,
    view: cam.View = .{ .cx = width / 2, .cy = height / 2 },
    /// Only the desktop (the laptop's display), at its own size.
    screen: bool = false,
    w: f32 = width,
    h: f32 = height,
    shown: bool = false,
    /// The panel's top as last drawn (it springs), for the camera.
    top: f32 = panel_top,
    label: ?Label = null,
    /// When the end begins (the panel becomes the icon), if it has.
    end_at: ?f32 = null,
    page: bool = false,
    asked: [suggest.max_len]u8 = undefined,
    asked_len: usize = 0,
    asked_at: f32 = -1,

    pub fn draw(d: *Scene, c: *ui.Context) void {
        const root = ui.div(c).size(d.w, d.h);
        defer root.end();
        {
            const wl = ui.div(c).absolute().offset(0, 0).size(d.w, d.h).bg(.hex(0x0b0c0f));
            defer wl.end();
            if (d.wall) |bytes| _ = ui.image(c, .{ .key = "wall", .bytes = bytes, .max_width = d.w, .max_height = d.h, .radius = 0, .scale = wall_density });
        }
        d.menuBar(c);
        // The desktop dims as the panel opens, and nearly to black at the end.
        const lit: f32 = if (d.shown) 1 else 0;
        const dim = cam.mix(0.18, 0.5, lit) + if (d.end_at) |e| 0.45 * cam.ease(cam.out, d.now, e, 0.6) else 0;
        ui.div(c).absolute().offset(0, 0).size(d.w, d.h).bg(ui.Color.hex(0x0b0c0f).alpha(dim)).end();
        if (d.end_at) |e| return d.end(c, e);
        const top = motion.number(c, "panel-top", if (d.s.previewing) panel_top_tall else panel_top, .{ .spring = view.spring });
        d.top = top;
        const px = if (d.screen) (d.w - view.width) / 2 else panel_x;
        const py = if (d.screen) d.h * 0.2 else top;
        if (motion.present(c, "panel", d.shown, .{
            .initial = .{ .opacity = 0, .y = -8, .scale = 0.96 },
            .transition = .{ .spring = .{ .stiffness = 340, .damping = 32 } },
        })) |f| {
            const p = ui.div(c).absolute().offset(px, py).motion(f);
            defer p.end();
            d.s.panel(c);
        }
        if (!d.screen) {
            d.results(c, top);
            d.caption(c, top);
        }
    }

    /// Google's page in the panel's body while it previews, a moment after
    /// Return, as a page loads.
    fn results(d: *Scene, c: *ui.Context, top: f32) void {
        const bytes = d.serp orelse return;
        const area = view.webArea(d.s.last_h);
        if (motion.present(c, "page", d.s.previewing and d.page, .{
            .initial = .{ .opacity = 0, .y = 6 },
            .exit = .{ .opacity = 0 },
            .transition = .{ .spring = .{ .stiffness = 300, .damping = 34 } },
            .delay = 0.35,
        })) |f| {
            const pg = ui.div(c).absolute().offset(panel_x, top + area.y).size(view.width, area.h).clip().bg(.white).motion(f);
            defer pg.end();
            _ = ui.image(c, .{ .key = "serp", .bytes = bytes, .max_width = view.width, .max_height = 1000, .radius = 0, .scale = 2 });
        }
    }

    /// The label: small, centred under the panel, in on the enter ease. Its
    /// size is undone by the zoom, so it reads the same at every zoom.
    fn caption(d: *Scene, c: *ui.Context, top: f32) void {
        const l = d.label orelse return;
        if (l.text.len == 0) return;
        const a = cam.ease(cam.out, d.now, l.at, 0.32);
        const z = @max(1, d.view.zoom);
        const box_w: f32 = 900;
        const y = top + d.s.last_h + 18 + 8 * (1 - a);
        const row = ui.div(c).absolute().offset(width / 2 - box_w / 2, y).w(box_w).h(60).row().justifyCenter().itemsCenter()
            .pivot(0.5, 0).scale(1.2 / z).opacity(a);
        defer row.end();
        const pill = ui.div(c).row().gap(10).px(18).h(44).itemsCenter().roundedFull().bg(ui.Color.black.alpha(0.42)).border(ui.Color.white.alpha(0.1));
        defer pill.end();
        ui.text(c, l.text, .{ .size = 19, .weight = .medium, .color = ui.Color.white.alpha(0.88) });
        if (l.key.len > 0) {
            const k = ui.div(c).row().px(9).h(26).minW(26).justifyCenter().itemsCenter().rounded(7).bg(ui.Color.white.alpha(0.14)).border(ui.Color.white.alpha(0.18));
            defer k.end();
            ui.text(c, l.key, .{ .size = 14, .weight = .semibold, .color = .white });
        }
    }

    /// The end: the panel's rectangle shrinks into the icon beside the
    /// name, then the line under it, then the address. Then black.
    fn end(d: *Scene, c: *ui.Context, at: f32) void {
        const k = cam.ease(cam.in_out, d.now, at, 0.6);
        const icon: f32 = 104;
        const name_w: f32 = 372;
        const gap: f32 = 26;
        const ix = (width - icon - gap - name_w) / 2;
        const iy: f32 = 292;
        const from_h = @max(d.s.last_h, 160);
        const bx = cam.mix(panel_x, ix, k);
        const by = cam.mix(panel_top, iy, k);
        const bw = cam.mix(view.width, icon, k);
        const bh = cam.mix(from_h, icon, k);
        const radius = cam.mix(18, 24, k);
        const solid = 1 - cam.ease(cam.out, d.now, at + 0.45, 0.3);
        if (solid > 0) ui.div(c).absolute().offset(bx, by).size(bw, bh).rounded(radius).bg(ui.Color.hex(0x2a2b30).alpha(solid)).border(ui.Color.white.alpha(0.14 * solid)).end();
        const icon_a = cam.ease(cam.out, d.now, at + 0.4, 0.35);
        {
            const ic = ui.div(c).absolute().offset(ix, iy).size(icon, icon).opacity(icon_a);
            defer ic.end();
            view.appIcon(c, icon);
        }
        const lines = [_]struct { f32, []const u8, f32, ui.Weight, f32, f32, f32 }{
            // when, words, size, weight, alpha, x, y
            .{ 0.7, "Nanolight", 76, .bold, 0.97, ix + icon + gap, iy + 8 },
            .{ 0.95, "Mac  ·  Windows  ·  Linux", 26, .medium, 0.6, 0, iy + icon + 46 },
            .{ 1.3, "github.com/jeiang/nanolight", 18, .medium, 0.4, 0, iy + icon + 92 },
        };
        for (lines, 0..) |l, i| {
            const a = cam.ease(cam.out, d.now, at + l[0], 0.4);
            // The name beside the icon; the lines under both, centred.
            const row = ui.div(c).absolute().offset(l[5], l[6] + 8 * (1 - a)).opacity(a).w(if (i == 0) 600 else width).row();
            defer row.end();
            if (i > 0) ui.spacer(c);
            ui.text(c, l[1], .{ .size = l[2], .weight = l[3], .color = ui.Color.hex(0xf7f7f8).alpha(l[4]), .tracking = if (i == 0) -3 else 0, .mono = i == 2 });
            ui.spacer(c);
        }
    }

    fn menuBar(d: *Scene, c: *ui.Context) void {
        const z: f32 = if (d.screen) 1.15 else 1;
        const bar = ui.div(c).absolute().offset(0, 0).size(d.w, 26 * z).row().px(16).gap(18).itemsCenter().bg(ui.Color.black.alpha(0.2));
        defer bar.end();
        const st: ui.TextStyle = .{ .size = 12.5 * z, .weight = .medium, .color = .white };
        ui.text(c, "\u{F8FF}", .{ .size = 14 * z, .color = .white });
        ui.text(c, "Finder", .{ .size = 12.5 * z, .weight = .bold, .color = .white });
        for ([_][]const u8{ "File", "Edit", "View", "Go", "Window", "Help" }) |m| ui.text(c, m, st);
        ui.spacer(c);
        {
            const on = ui.div(c).row().px(6).h(20 * z).itemsCenter().rounded(5).bg(ui.Color.white.alpha(if (d.shown) 0.25 else 0));
            defer on.end();
            ui.icon(c, "magnifyingglass", .{ .size = 12 * z, .weight = .semibold, .color = .white });
        }
        ui.icon(c, "wifi", .{ .size = 13 * z, .weight = .medium, .color = .white });
        ui.icon(c, "battery.75percent", .{ .size = 15 * z, .color = .white });
        ui.text(c, "Mon 2 Nov  9:41", st);
    }

    /// Google answers a beat after it's asked, as it would.
    pub fn google(d: *Scene) void {
        if (d.asked_at < 0 or d.now - d.asked_at < 0.3) return;
        d.asked_at = -1;
        const q = d.asked[0..d.asked_len];
        for (answers) |a| if (std.mem.eql(u8, a[0], q)) {
            var arena: std.heap.ArenaAllocator = .init(d.gpa);
            defer arena.deinit();
            var list: suggest.List = .{};
            if (suggest.decode(arena.allocator(), a[1], q, &list)) d.s.answered(q, &list);
        };
    }

    pub fn host(d: *Scene) view.Host {
        return .{ .ctx = d, .open = open, .hide = hide, .resize = resize, .suggest = ask, .preview = preview };
    }
    fn open(_: *anyopaque, _: []const u8) void {}
    fn hide(ctx: *anyopaque) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        d.shown = false;
    }
    /// Only so the panel keeps its height (`last_h`) for the page.
    fn resize(_: *anyopaque, _: f32) void {}
    fn ask(ctx: *anyopaque, q: []const u8) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        const t = std.mem.trim(u8, q, " ");
        @memcpy(d.asked[0..t.len], t);
        d.asked_len = t.len;
        d.asked_at = d.now;
    }
    fn preview(ctx: *anyopaque, url: ?[]const u8) void {
        const d: *Scene = @ptrCast(@alignCast(ctx));
        d.page = url != null;
    }
};
