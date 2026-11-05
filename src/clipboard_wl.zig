//! Clipboard history on Wayland, over a connection of its own (libwayland-client,
//! opened with dlopen) whose socket nanoui's loop watches. The protocol glue is
//! written out here: no generated code. A compositor with ext-data-control-v1
//! (or wlr-data-control-unstable-v1) tells us each new selection as an offer;
//! its types are read through pipes, without blocking the loop. A paste serves a
//! data-control source for the entry, and sends Ctrl+V through a virtual
//! keyboard (virtual-keyboard-unstable-v1) with a keymap of two keys.
//!
//! No source app is known here, so `exclude_apps` cannot apply on Wayland.
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const lx = @import("clipboard_linux.zig");

const Proxy = opaque {};
const Display = opaque {};

// ----- the protocol, as libwayland wants it described -----

const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: [*]const Message,
    event_count: c_int,
    events: [*]const Message,
};

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    /// One entry per argument: its interface when it is an object, else null.
    types: [*]const ?*const Interface,
};

/// The arguments in a signature: its letters, without versions and `?`.
fn argCount(comptime sig: []const u8) usize {
    var n: usize = 0;
    for (sig) |c| {
        if (!std.ascii.isDigit(c) and c != '?') n += 1;
    }
    return n;
}

fn msg(comptime name: [:0]const u8, comptime sig: [:0]const u8, comptime types: anytype) Message {
    if (@typeInfo(@typeInfo(@TypeOf(types)).pointer.child).array.len != argCount(sig)) @compileError("types of " ++ name ++ " do not match " ++ sig);
    return .{ .name = name, .signature = sig, .types = types };
}

const none0 = [0]?*const Interface{};
const none1 = [1]?*const Interface{null};
const none2 = [2]?*const Interface{ null, null };

/// The data-control protocol, which `ext_data_control` and
/// `zwlr_data_control` have in common except for their names.
fn DataControl(comptime ns: []const u8, comptime version: c_int) type {
    return struct {
        fn name(comptime what: []const u8) [:0]const u8 {
            return std.fmt.comptimePrint("{s}_{s}_v1", .{ ns, what });
        }

        var get_device_types = [2]?*const Interface{ &device, null };
        const source_type = [1]?*const Interface{&source};
        const offer_type = [1]?*const Interface{&offer};

        pub const manager: Interface = .{
            .name = name("manager"),
            .version = version,
            .method_count = 3,
            .methods = &manager_methods,
            .event_count = 0,
            .events = &none_messages,
        };
        const manager_methods = [_]Message{
            msg("create_data_source", "n", &source_type),
            msg("get_data_device", "no", &get_device_types),
            msg("destroy", "", &none0),
        };

        pub const device: Interface = .{
            .name = name("device"),
            .version = version,
            .method_count = 3,
            .methods = &device_methods,
            .event_count = 4,
            .events = &device_events,
        };
        const device_methods = [_]Message{
            msg("set_selection", "?o", &source_type),
            msg("destroy", "", &none0),
            msg("set_primary_selection", "?o", &source_type),
        };
        const device_events = [_]Message{
            msg("data_offer", "n", &offer_type),
            msg("selection", "?o", &offer_type),
            msg("finished", "", &none0),
            msg("primary_selection", "?o", &offer_type),
        };

        pub const source: Interface = .{
            .name = name("source"),
            .version = version,
            .method_count = 2,
            .methods = &source_methods,
            .event_count = 2,
            .events = &source_events,
        };
        const source_methods = [_]Message{ msg("offer", "s", &none1), msg("destroy", "", &none0) };
        const source_events = [_]Message{ msg("send", "sh", &none2), msg("cancelled", "", &none0) };

        pub const offer: Interface = .{
            .name = name("offer"),
            .version = version,
            .method_count = 2,
            .methods = &offer_methods,
            .event_count = 1,
            .events = &offer_events,
        };
        const offer_methods = [_]Message{ msg("receive", "sh", &none2), msg("destroy", "", &none0) };
        const offer_events = [_]Message{msg("offer", "s", &none1)};

        /// The seat's interface comes from libwayland at run time.
        fn setSeat(seat: *const Interface) void {
            get_device_types[1] = seat;
        }
    };
}

const none_messages = [0]Message{};

const Ext = DataControl("ext_data_control", 1);
const Wlr = DataControl("zwlr_data_control", 3);

/// The interfaces of whichever data-control protocol the compositor has.
const Proto = struct {
    manager: *const Interface,
    device: *const Interface,
    source: *const Interface,
    offer: *const Interface,
    setSeat: *const fn (*const Interface) void,

    fn of(comptime T: type) Proto {
        return .{ .manager = &T.manager, .device = &T.device, .source = &T.source, .offer = &T.offer, .setSeat = T.setSeat };
    }
};

const ext_proto = Proto.of(Ext);
const wlr_proto = Proto.of(Wlr);

var vk_create_types = [2]?*const Interface{ null, &vk_interface };
const vk_manager_methods = [_]Message{msg("create_virtual_keyboard", "on", &vk_create_types)};
const vk_manager_interface: Interface = .{ .name = "zwp_virtual_keyboard_manager_v1", .version = 1, .method_count = 1, .methods = &vk_manager_methods, .event_count = 0, .events = &none_messages };
const vk_three = [3]?*const Interface{ null, null, null };
const vk_four = [4]?*const Interface{ null, null, null, null };
const vk_keymap_types = [3]?*const Interface{ null, null, null };
const vk_methods = [_]Message{
    msg("keymap", "uhu", &vk_keymap_types),
    msg("key", "uuu", &vk_three),
    msg("modifiers", "uuuu", &vk_four),
    msg("destroy", "", &none0),
};
const vk_interface: Interface = .{ .name = "zwp_virtual_keyboard_v1", .version = 1, .method_count = 4, .methods = &vk_methods, .event_count = 0, .events = &none_messages };

const Lib = struct {
    wl_display_connect: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    wl_display_disconnect: *const fn (*Display) callconv(.c) void,
    wl_display_get_fd: *const fn (*Display) callconv(.c) c_int,
    wl_display_flush: *const fn (*Display) callconv(.c) c_int,
    wl_display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    wl_display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    wl_display_prepare_read: *const fn (*Display) callconv(.c) c_int,
    wl_display_read_events: *const fn (*Display) callconv(.c) c_int,
    wl_proxy_marshal_flags: *const fn (*Proxy, u32, ?*const Interface, u32, u32, ...) callconv(.c) ?*Proxy,
    wl_proxy_add_listener: *const fn (*Proxy, [*]const ?*const anyopaque, ?*anyopaque) callconv(.c) c_int,
    wl_proxy_get_user_data: *const fn (*Proxy) callconv(.c) ?*anyopaque,
    wl_proxy_get_version: *const fn (*Proxy) callconv(.c) u32,
    wl_registry_interface: *const Interface,
    wl_seat_interface: *const Interface,
};

/// WL_MARSHAL_FLAG_DESTROY: the request destroys the proxy.
const destroy_flag: u32 = 1;
const no_fd: c_int = -1;

// ----- keys -----

/// The keymap a virtual keyboard is given: Left Control and V, nothing else.
/// Keycodes are evdev's (29 and 47) plus 8.
pub const keymap_text =
    \\xkb_keymap {
    \\xkb_keycodes { <LCTL> = 37; <AB04> = 55; };
    \\xkb_types { include "complete" };
    \\xkb_compat { include "complete" };
    \\xkb_symbols { key <LCTL> { [ Control_L ] }; key <AB04> { [ v, V ] }; modifier_map Control { <LCTL> }; };
    \\};
    \\
;
const key_leftctrl: u32 = 29;
const key_v: u32 = 47;
const mod_control: u32 = 4;
/// Time for the window that had the keys to take them back before Ctrl+V.
const paste_delay_ms = 150;
const step_ms = 3000;
const max_mimes = 64;
const write_tick_ms = 10;
const write_tries = 500;

// ----- C -----

const O_NONBLOCK: c_int = 0o4000;
const O_CLOEXEC: c_int = 0o2000000;
const F_SETFL: c_int = 4;
const F_GETFL: c_int = 3;
extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
const closeFd = close;

fn nonblocking(fd: c_int) void {
    _ = std.c.fcntl(fd, F_SETFL, std.c.fcntl(fd, F_GETFL) | O_NONBLOCK);
}

fn wouldBlock() bool {
    return std.c._errno().* == @backingInt(std.c.E.AGAIN);
}

fn nowMs() u32 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @truncate(@as(u64, @intCast(ts.sec)) *% 1000 +% @as(u64, @intCast(ts.nsec)) / 1_000_000);
}

/// A memfd holding `text` and its NUL, rewound; -1 when it cannot be made.
fn memfdWith(text: []const u8) c_int {
    const fd = std.c.memfd_create("nanolight-keymap", 0);
    if (fd < 0) return no_fd;
    const all = text.len + 1;
    var done: usize = 0;
    var tmp: [1024]u8 = undefined;
    if (std.c.ftruncate(fd, @intCast(all)) != 0) {
        _ = closeFd(fd);
        return no_fd;
    }
    while (done < all) {
        const n = @min(tmp.len, all - done);
        for (0..n) |i| tmp[i] = if (done + i < text.len) text[done + i] else 0;
        const w = std.c.write(fd, &tmp, n);
        if (w <= 0) {
            _ = closeFd(fd);
            return no_fd;
        }
        done += @intCast(w);
    }
    return fd;
}

// ----- the client -----

const Offer = struct {
    w: *Wl,
    proxy: *Proxy,
    mimes: std.ArrayList([]const u8) = .empty,
};

/// What is left to write to the pipe a client gave for a paste.
const Write = struct {
    fd: c_int,
    data: []u8,
    at: usize = 0,
    tries: u32 = 0,

    fn pump(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Write = @ptrCast(@alignCast(ctx.?));
        while (j.at < j.data.len) {
            const n = std.c.write(j.fd, j.data.ptr + j.at, j.data.len - j.at);
            if (n > 0) {
                j.at += @intCast(n);
                continue;
            }
            // Full: the reader has not caught up. Gone or too slow: give up.
            if (n < 0 and wouldBlock() and j.tries < write_tries) {
                j.tries += 1;
                return nanoui.App.after(write_tick_ms, j, pump);
            }
            break;
        }
        _ = closeFd(j.fd);
        std.heap.c_allocator.free(j.data);
        std.heap.c_allocator.destroy(j);
    }
};

pub const Wl = struct {
    sink: ?clipboard.Sink = null,
    lib: Lib = undefined,
    d: ?*Display = null,
    registry: ?*Proxy = null,
    seat: ?*Proxy = null,
    ext_manager: ?*Proxy = null,
    wlr_manager: ?*Proxy = null,
    vk_manager: ?*Proxy = null,
    proto: Proto = undefined,
    manager: ?*Proxy = null,
    device: ?*Proxy = null,
    watch: ?nanoui.fdwatch.Watch = null,

    // The selection now, and the read of it.
    current: ?*Offer = null,
    tick: u32 = 0,
    reading: bool = false,
    gather: lx.Gather = undefined,
    cap: usize = 0,
    rd_fd: c_int = -1,
    rd_watch: ?nanoui.fdwatch.Watch = null,
    buf: std.ArrayList(u8) = .empty,

    // What Nanolight owns the selection with.
    source: ?*Proxy = null,
    served: ?lx.Served = null,
    vk: ?*Proxy = null,

    const gpa = std.heap.c_allocator;

    pub fn open(w: *Wl) error{ NoLibrary, NoConnection, NoDataControl }!void {
        w.lib = lx.dlLoad(Lib, "libwayland-client.so.0") orelse return error.NoLibrary;
        const lib = w.lib;
        const d = lib.wl_display_connect(null) orelse return error.NoConnection;
        w.d = d;
        w.registry = lib.wl_proxy_marshal_flags(@ptrCast(d), 1, lib.wl_registry_interface, lib.wl_proxy_get_version(@ptrCast(d)), 0, @as(?*anyopaque, null));
        _ = lib.wl_proxy_add_listener(w.registry orelse return error.NoConnection, &registry_listener, w);
        if (lib.wl_display_roundtrip(d) < 0) return error.NoConnection;
        const seat = w.seat orelse return error.NoDataControl;
        if (w.ext_manager) |m| {
            w.manager = m;
            w.proto = ext_proto;
        } else if (w.wlr_manager) |m| {
            w.manager = m;
            w.proto = wlr_proto;
        } else return error.NoDataControl;
        w.proto.setSeat(lib.wl_seat_interface);
        vk_create_types[0] = lib.wl_seat_interface;
        const m = w.manager.?;
        const device = lib.wl_proxy_marshal_flags(m, 1, w.proto.device, lib.wl_proxy_get_version(m), 0, @as(?*anyopaque, null), seat) orelse return error.NoConnection;
        w.device = device;
        _ = lib.wl_proxy_add_listener(device, &device_listener, w);
        // The selection that is there already arrives now, and is not recorded.
        if (lib.wl_display_roundtrip(d) < 0) return error.NoConnection;
        ignoreSigpipe();
        w.watch = nanoui.fdwatch.readable(lib.wl_display_get_fd(d), w, readable) catch return error.NoConnection;
    }

    pub fn close(w: *Wl) void {
        if (w.watch) |x| x.cancel();
        w.watch = null;
        if (w.d) |d| w.lib.wl_display_disconnect(d);
        w.d = null;
    }

    fn ignoreSigpipe() void {
        var act: std.c.Sigaction = .{ .handler = .{ .handler = std.c.SIG.IGN }, .mask = undefined, .flags = 0 };
        _ = std.c.sigemptyset(&act.mask);
        _ = std.c.sigaction(.PIPE, &act, null);
    }

    fn flush(w: *Wl) void {
        _ = w.lib.wl_display_flush(w.d.?);
    }

    fn version(w: *Wl, p: *Proxy) u32 {
        return w.lib.wl_proxy_get_version(p);
    }

    /// Takes whatever the compositor has sent.
    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(ctx.?));
        const d = w.d orelse return;
        while (w.lib.wl_display_prepare_read(d) != 0) _ = w.lib.wl_display_dispatch_pending(d);
        w.flush();
        // The socket is non-blocking: this takes what is there.
        if (w.lib.wl_display_read_events(d) < 0) {
            // The compositor is gone: stop being woken for its closed socket.
            if (w.watch) |x| x.cancel();
            w.watch = null;
            return;
        }
        _ = w.lib.wl_display_dispatch_pending(d);
    }

    // ----- the registry -----

    const registry_listener = [2]?*const anyopaque{ @ptrCast(&onGlobal), @ptrCast(&onGlobalRemove) };

    fn onGlobal(data: ?*anyopaque, registry: *Proxy, name: u32, interface: [*:0]const u8, _: u32) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        const i = std.mem.span(interface);
        if (std.mem.eql(u8, i, "wl_seat")) {
            if (w.seat == null) w.seat = w.bind(registry, name, w.lib.wl_seat_interface, 1);
        } else if (std.mem.eql(u8, i, std.mem.span(Ext.manager.name))) {
            w.ext_manager = w.bind(registry, name, &Ext.manager, 1);
        } else if (std.mem.eql(u8, i, std.mem.span(Wlr.manager.name))) {
            w.wlr_manager = w.bind(registry, name, &Wlr.manager, 1);
        } else if (std.mem.eql(u8, i, "zwp_virtual_keyboard_manager_v1")) {
            w.vk_manager = w.bind(registry, name, &vk_manager_interface, 1);
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

    fn bind(w: *Wl, registry: *Proxy, name: u32, interface: *const Interface, v: u32) ?*Proxy {
        return w.lib.wl_proxy_marshal_flags(registry, 0, interface, v, 0, name, interface.name, v, @as(?*anyopaque, null));
    }

    // ----- what is copied -----

    const device_listener = [4]?*const anyopaque{ @ptrCast(&onDataOffer), @ptrCast(&onSelection), @ptrCast(&onFinished), @ptrCast(&onPrimary) };
    const offer_listener = [1]?*const anyopaque{@ptrCast(&onOfferType)};

    fn onDataOffer(data: ?*anyopaque, _: *Proxy, proxy: *Proxy) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        const o = gpa.create(Offer) catch return;
        o.* = .{ .w = w, .proxy = proxy };
        _ = w.lib.wl_proxy_add_listener(proxy, &offer_listener, o);
    }

    fn onOfferType(data: ?*anyopaque, _: *Proxy, mime: [*:0]const u8) callconv(.c) void {
        const o: *Offer = @ptrCast(@alignCast(data.?));
        if (o.mimes.items.len >= max_mimes) return;
        const name = gpa.dupe(u8, std.mem.span(mime)) catch return;
        o.mimes.append(gpa, name) catch gpa.free(name);
    }

    fn onFinished(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}

    /// The primary selection is not history: its offers are let go.
    fn onPrimary(data: ?*anyopaque, _: *Proxy, proxy: ?*Proxy) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        if (proxy) |p| if (w.lib.wl_proxy_get_user_data(p)) |o| w.discard(@ptrCast(@alignCast(o)));
    }

    fn discard(w: *Wl, o: *Offer) void {
        // `destroy` is the offer's second request.
        _ = w.lib.wl_proxy_marshal_flags(o.proxy, 1, null, w.version(o.proxy), destroy_flag);
        for (o.mimes.items) |m| gpa.free(m);
        o.mimes.deinit(gpa);
        gpa.destroy(o);
    }

    fn onSelection(data: ?*anyopaque, _: *Proxy, proxy: ?*Proxy) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        w.abortRead();
        if (w.current) |old| w.discard(old);
        w.current = null;
        const p = proxy orelse return;
        const o: *Offer = @ptrCast(@alignCast(w.lib.wl_proxy_get_user_data(p) orelse return));
        w.current = o;
        const sink = w.sink orelse return;
        const plan = lx.plan(o.mimes.items);
        if (plan.own or plan.n == 0) return;
        w.gather = .{ .plan = plan, .sink = sink };
        w.reading = true;
        w.fetch(w.gather.first().?);
    }

    fn fetch(w: *Wl, r: lx.Request) void {
        const o = w.current orelse return w.endRead();
        var fds: [2]c_int = undefined;
        if (pipe2(&fds, O_CLOEXEC) != 0) return w.endRead();
        nonblocking(fds[0]);
        var name: [128:0]u8 = undefined;
        const n = @min(r.mime.len, name.len - 1);
        @memcpy(name[0..n], r.mime[0..n]);
        name[n] = 0;
        // `receive` is the offer's first request; libwayland keeps its own copy of the fd.
        _ = w.lib.wl_proxy_marshal_flags(o.proxy, 0, null, w.version(o.proxy), 0, @as([*:0]const u8, &name), fds[1]);
        _ = closeFd(fds[1]);
        w.flush();
        w.rd_fd = fds[0];
        w.cap = r.cap;
        w.buf.clearRetainingCapacity();
        w.rd_watch = nanoui.fdwatch.readable(fds[0], w, readData) catch {
            _ = closeFd(fds[0]);
            w.rd_fd = -1;
            return w.endRead();
        };
        w.step();
    }

    fn step(w: *Wl) void {
        w.tick +%= 1;
        lx.after(Wl, w, w.tick, step_ms, expired);
    }

    fn expired(w: *Wl, id: u32) void {
        if (w.reading and id == w.tick) w.advance(null);
    }

    /// Reads what the source has written so far; at its end, the step is done.
    fn readData(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(ctx.?));
        var tmp: [64 * 1024]u8 = undefined;
        while (w.reading and w.rd_fd >= 0) {
            const n = std.c.read(w.rd_fd, &tmp, tmp.len);
            if (n < 0 and wouldBlock()) return;
            if (n <= 0) return w.advance(w.buf.items);
            if (w.buf.items.len + @as(usize, @intCast(n)) > w.cap) return w.advance(null);
            w.buf.appendSlice(gpa, tmp[0..@intCast(n)]) catch return w.advance(null);
        }
    }

    fn closeRead(w: *Wl) void {
        if (w.rd_watch) |x| x.cancel();
        w.rd_watch = null;
        if (w.rd_fd >= 0) _ = closeFd(w.rd_fd);
        w.rd_fd = -1;
    }

    fn endRead(w: *Wl) void {
        w.closeRead();
        w.reading = false;
        w.tick +%= 1;
        w.buf.clearAndFree(gpa);
    }

    fn abortRead(w: *Wl) void {
        if (w.reading) w.endRead();
    }

    /// A read gave `bytes` (null: it failed or ran out of time); on to the next, or done.
    fn advance(w: *Wl, bytes: ?[]const u8) void {
        w.closeRead();
        const next = w.gather.feed(bytes) orelse return w.endRead();
        w.fetch(next);
    }

    // ----- owning the selection -----

    const source_listener = [2]?*const anyopaque{ @ptrCast(&onSend), @ptrCast(&onCancelled) };

    fn onSend(data: ?*anyopaque, src: *Proxy, mime: [*:0]const u8, fd: c_int) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        const bytes = if (src == w.source and w.served != null) w.served.?.bytes(std.mem.span(mime)) else null;
        const data_copy = if (bytes) |b| gpa.dupe(u8, b) catch null else null;
        const job = if (data_copy != null) gpa.create(Write) catch null else null;
        if (job) |j| {
            j.* = .{ .fd = fd, .data = data_copy.? };
            nonblocking(fd);
            return Write.pump(j);
        }
        if (data_copy) |c| gpa.free(c);
        _ = closeFd(fd);
    }

    fn onCancelled(data: ?*anyopaque, src: *Proxy) callconv(.c) void {
        const w: *Wl = @ptrCast(@alignCast(data.?));
        if (src == w.source) w.release();
        _ = w.lib.wl_proxy_marshal_flags(src, 1, null, w.version(src), destroy_flag);
    }

    fn release(w: *Wl) void {
        if (w.served) |*s| s.deinit();
        w.served = null;
        w.source = null;
    }

    fn serve(w: *Wl, c: clipboard.Content) bool {
        var s = lx.Served.init(gpa, c) catch return false;
        const m = w.manager.?;
        const src = w.lib.wl_proxy_marshal_flags(m, 0, w.proto.source, w.version(m), 0, @as(?*anyopaque, null)) orelse {
            s.deinit();
            return false;
        };
        _ = w.lib.wl_proxy_add_listener(src, &source_listener, w);
        const sv = w.version(src);
        for (s.mimes()) |mime| w.offerType(src, sv, mime);
        w.offerType(src, sv, lx.own_mime);
        // `set_selection` is the device's first request.
        _ = w.lib.wl_proxy_marshal_flags(w.device.?, 0, null, w.version(w.device.?), 0, src);
        const old = w.source;
        w.release();
        w.source = src;
        w.served = s;
        if (old) |o| _ = w.lib.wl_proxy_marshal_flags(o, 1, null, w.version(o), destroy_flag);
        w.flush();
        return true;
    }

    fn offerType(w: *Wl, src: *Proxy, v: u32, mime: []const u8) void {
        var name: [128:0]u8 = undefined;
        const n = @min(mime.len, name.len - 1);
        @memcpy(name[0..n], mime[0..n]);
        name[n] = 0;
        _ = w.lib.wl_proxy_marshal_flags(src, 0, null, v, 0, @as([*:0]const u8, &name));
    }

    // ----- paste -----

    pub fn copy(w: *Wl, c: clipboard.Content) bool {
        return w.serve(c);
    }

    pub fn paste(w: *Wl, c: clipboard.Content, hide: clipboard.Hide) clipboard.PasteResult {
        if (!w.serve(c)) return .failed;
        if (!w.keyboard()) return .copied_unsupported;
        hide.func(hide.ctx);
        lx.after(Wl, w, 0, paste_delay_ms, sendKeys);
        return .pasted;
    }

    /// The virtual keyboard, made with its keymap the first time.
    fn keyboard(w: *Wl) bool {
        if (w.vk != null) return true;
        const m = w.vk_manager orelse return false;
        const seat = w.seat orelse return false;
        const fd = memfdWith(keymap_text);
        if (fd < 0) return false;
        defer _ = closeFd(fd);
        const vk = w.lib.wl_proxy_marshal_flags(m, 0, &vk_interface, w.version(m), 0, seat, @as(?*anyopaque, null)) orelse return false;
        // format 1: xkb_v1 text.
        _ = w.lib.wl_proxy_marshal_flags(vk, 0, null, w.version(vk), 0, @as(u32, 1), fd, @as(u32, @intCast(keymap_text.len + 1)));
        w.vk = vk;
        w.flush();
        return true;
    }

    fn sendKeys(w: *Wl, _: u32) void {
        const vk = w.vk orelse return;
        const v = w.version(vk);
        const t = nowMs();
        const lib = w.lib;
        _ = lib.wl_proxy_marshal_flags(vk, 2, null, v, 0, mod_control, @as(u32, 0), @as(u32, 0), @as(u32, 0));
        for ([_][2]u32{ .{ key_leftctrl, 1 }, .{ key_v, 1 }, .{ key_v, 0 }, .{ key_leftctrl, 0 } }) |k| {
            _ = lib.wl_proxy_marshal_flags(vk, 1, null, v, 0, t, k[0], k[1]);
        }
        _ = lib.wl_proxy_marshal_flags(vk, 2, null, v, 0, @as(u32, 0), @as(u32, 0), @as(u32, 0), @as(u32, 0));
        w.flush();
    }
};

// ----- tests -----

const testing = std.testing;

test "the protocol tables describe every request and event, ending where they should" {
    inline for (.{ Ext, Wlr }) |P| {
        try testing.expectEqual(@as(usize, 3), @as(usize, @intCast(P.manager.method_count)));
        try testing.expectEqualStrings("create_data_source", std.mem.span(P.manager.methods[0].name));
        try testing.expectEqualStrings("no", std.mem.span(P.manager.methods[1].signature));
        try testing.expectEqualStrings("set_selection", std.mem.span(P.device.methods[0].name));
        try testing.expectEqualStrings("selection", std.mem.span(P.device.events[1].name));
        try testing.expectEqualStrings("?o", std.mem.span(P.device.events[1].signature));
        try testing.expectEqual(&P.offer, P.device.events[0].types[0].?);
        try testing.expectEqual(&P.source, P.manager.methods[0].types[0].?);
        try testing.expectEqualStrings("receive", std.mem.span(P.offer.methods[0].name));
        try testing.expectEqualStrings("send", std.mem.span(P.source.events[0].name));
        try testing.expectEqualStrings("sh", std.mem.span(P.source.events[0].signature));
    }
    try testing.expectEqualStrings("ext_data_control_manager_v1", std.mem.span(Ext.manager.name));
    try testing.expectEqualStrings("zwlr_data_control_device_v1", std.mem.span(Wlr.device.name));
    try testing.expectEqualStrings("zwp_virtual_keyboard_v1", std.mem.span(vk_interface.name));
    try testing.expectEqualStrings("uhu", std.mem.span(vk_interface.methods[0].signature));
}

test "argument letters are counted without versions or nullability" {
    try testing.expectEqual(@as(usize, 0), argCount(""));
    try testing.expectEqual(@as(usize, 1), argCount("2?o"));
    try testing.expectEqual(@as(usize, 4), argCount("uuuu"));
}

test "the keymap names the two keys it presses and is a whole keymap" {
    try testing.expect(std.mem.startsWith(u8, keymap_text, "xkb_keymap {\n"));
    try testing.expect(std.mem.endsWith(u8, keymap_text, "};\n"));
    for ([_][]const u8{ "<LCTL> = 37", "<AB04> = 55", "Control_L", "[ v, V ]", "modifier_map Control" }) |part| {
        try testing.expect(std.mem.indexOf(u8, keymap_text, part) != null);
    }
    // evdev code plus 8 is the xkb keycode.
    try testing.expectEqual(@as(u32, 37), key_leftctrl + 8);
    try testing.expectEqual(@as(u32, 55), key_v + 8);
}

test "a keymap fd holds the text and its NUL, from the start" {
    const fd = memfdWith(keymap_text);
    try testing.expect(fd >= 0);
    defer _ = closeFd(fd);
    var buf: [1024]u8 = undefined;
    // pread: the fd is shared with nobody, but its offset is at the end.
    const n = std.c.pread(fd, &buf, buf.len, 0);
    try testing.expectEqual(@as(isize, @intCast(keymap_text.len + 1)), n);
    try testing.expectEqualStrings(keymap_text, buf[0..keymap_text.len]);
    try testing.expectEqual(@as(u8, 0), buf[keymap_text.len]);
}
