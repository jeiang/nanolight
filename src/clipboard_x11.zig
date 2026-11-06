//! Clipboard history on X11, over an Xlib connection of its own (libX11,
//! libXfixes and libXtst, opened with dlopen) whose socket nanoui's loop
//! watches. XFixes says when the CLIPBOARD's owner changes; the copy is read
//! from the owner into a hidden window of ours (TARGETS first, then the types
//! clipboard_linux.zig's plan picks; INCR transfers too). A paste makes that
//! window the owner, answers other clients' requests for as long as it is
//! (INCR for what one request cannot carry), and sends Ctrl+V with XTest once
//! the panel has gone.
const std = @import("std");
const nanoui = @import("nanoui");
const clipboard = @import("clipboard.zig");
const lx = @import("clipboard_linux.zig");

const Display = opaque {};
const Window = c_ulong;
const Atom = c_ulong;
const ErrorHandler = *const fn (*Display, *anyopaque) callconv(.c) c_int;

const Xlib = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) Window,
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *Event) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (?ErrorHandler) callconv(.c) ?ErrorHandler,
    XCreateSimpleWindow: *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window,
    XDestroyWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    XGetAtomName: *const fn (*Display, Atom) callconv(.c) ?[*:0]u8,
    XConvertSelection: *const fn (*Display, Atom, Atom, Atom, Window, c_ulong) callconv(.c) c_int,
    XSetSelectionOwner: *const fn (*Display, Atom, Window, c_ulong) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (*Display, Atom) callconv(.c) Window,
    XGetWindowProperty: *const fn (*Display, Window, Atom, c_long, c_long, c_int, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int,
    XChangeProperty: *const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
    XDeleteProperty: *const fn (*Display, Window, Atom) callconv(.c) c_int,
    XSendEvent: *const fn (*Display, Window, c_int, c_long, *Event) callconv(.c) c_int,
    XKeysymToKeycode: *const fn (*Display, c_ulong) callconv(.c) u8,
    XMaxRequestSize: *const fn (*Display) callconv(.c) c_long,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
};

const Xfixes = struct {
    XFixesQueryExtension: *const fn (*Display, *c_int, *c_int) callconv(.c) c_int,
    XFixesSelectSelectionInput: *const fn (*Display, Window, Atom, c_ulong) callconv(.c) void,
};

const Xtst = struct {
    XTestQueryExtension: *const fn (*Display, *c_int, *c_int, *c_int, *c_int) callconv(.c) c_int,
    XTestFakeKeyEvent: *const fn (*Display, c_uint, c_int, c_ulong) callconv(.c) c_int,
};

/// XEvent: a union 24 longs long; `type` first.
const Event = extern union { type: c_int, pad: [24]c_long };
const SelectionEvent = extern struct { type: c_int, serial: c_ulong, send_event: c_int, display: ?*Display, requestor: Window, selection: Atom, target: Atom, property: Atom, time: c_ulong };
const SelectionRequest = extern struct { type: c_int, serial: c_ulong, send_event: c_int, display: ?*Display, owner: Window, requestor: Window, selection: Atom, target: Atom, property: Atom, time: c_ulong };
const SelectionClear = extern struct { type: c_int, serial: c_ulong, send_event: c_int, display: ?*Display, window: Window, selection: Atom, time: c_ulong };
const PropertyEvent = extern struct { type: c_int, serial: c_ulong, send_event: c_int, display: ?*Display, window: Window, atom: Atom, time: c_ulong, state: c_int };
const FixesEvent = extern struct { type: c_int, serial: c_ulong, send_event: c_int, display: ?*Display, window: Window, subtype: c_int, owner: Window, selection: Atom, timestamp: c_ulong, selection_timestamp: c_ulong };

fn as(comptime T: type, ev: *const Event) *const T {
    return @ptrCast(ev);
}

const property_notify = 28;
const selection_clear = 29;
const selection_request = 30;
const selection_notify = 31;
const property_change_mask: c_long = 1 << 22;
const property_new_value = 0;
const property_delete = 1;
const prop_mode_replace = 0;
const xa_atom: Atom = 4;
const xa_string: Atom = 31;
const xk_control_l: c_ulong = 0xffe3;
const xk_v: c_ulong = 0x76;
const select_owner_mask: c_ulong = 1;
/// A client that does not answer one request in this long is given up on.
const step_ms = 2000;
/// Time for the window that had the keys to take them back before Ctrl+V.
const paste_delay_ms = 150;
const max_names = 128;

var x_failed = false;

fn onError(_: *Display, _: *anyopaque) callconv(.c) c_int {
    x_failed = true;
    return 0;
}

pub const X11 = struct {
    sink: ?clipboard.Sink = null,
    xl: Xlib = undefined,
    fx: Xfixes = undefined,
    xtst: ?Xtst = null,
    d: ?*Display = null,
    win: Window = 0,
    watch: ?nanoui.fdwatch.Watch = null,
    fixes_event: c_int = 0,
    clipboard_atom: Atom = 0,
    targets_atom: Atom = 0,
    incr_atom: Atom = 0,
    prop_atom: Atom = 0,

    // The copy being read.
    phase: Phase = .idle,
    /// Counts the steps of the read, so only the last one's timer counts.
    tick: u32 = 0,
    time: c_ulong = 0,
    gather: lx.Gather = undefined,
    want: Atom = 0,
    cap: usize = 0,
    names: std.ArrayList([]const u8) = .empty,
    buf: std.ArrayList(u8) = .empty,
    source_buf: [128]u8 = undefined,
    /// A change that came while one was being read.
    queued: ?struct { owner: Window, time: c_ulong } = null,

    // What Nanolight owns the clipboard with.
    served: ?lx.Served = null,
    served_atoms: [lx.max_served_mimes]Atom = undefined,
    /// The most one ChangeProperty carries.
    chunk_max: usize = 0,
    /// A transfer to a client in pieces, and its own timer's count.
    out: ?Out = null,
    out_tick: u32 = 0,

    /// What is sent to one requestor, in INCR pieces; its own copy of the bytes.
    const Out = struct { requestor: Window, prop: Atom, kind: Atom, data: []u8, at: usize = 0 };

    /// Where a read of the owner's copy is: its TARGETS asked for, one type asked for,
    /// or that type coming in INCR pieces.
    const Phase = enum { idle, targets, data, incr };

    const gpa = std.heap.c_allocator;

    pub fn open(x: *X11) error{ NoLibrary, NoConnection, NoXFixes }!void {
        x.xl = lx.dlLoad(Xlib, "libX11.so.6") orelse return error.NoLibrary;
        x.fx = lx.dlLoad(Xfixes, "libXfixes.so.3") orelse return error.NoLibrary;
        const xl = x.xl;
        const d = xl.XOpenDisplay(null) orelse return error.NoConnection;
        x.d = d;
        var base: c_int = 0;
        var err: c_int = 0;
        if (x.fx.XFixesQueryExtension(d, &base, &err) == 0) return error.NoXFixes;
        x.fixes_event = base;
        if (lx.dlLoad(Xtst, "libXtst.so.6")) |t| {
            var a: c_int = 0;
            var b: c_int = 0;
            var c: c_int = 0;
            var e: c_int = 0;
            if (t.XTestQueryExtension(d, &a, &b, &c, &e) != 0) x.xtst = t;
        }
        x.win = xl.XCreateSimpleWindow(d, xl.XDefaultRootWindow(d), 0, 0, 1, 1, 0, 0, 0);
        _ = xl.XSelectInput(d, x.win, property_change_mask);
        x.clipboard_atom = x.atom("CLIPBOARD");
        x.targets_atom = x.atom("TARGETS");
        x.incr_atom = x.atom("INCR");
        x.prop_atom = x.atom("NANOLIGHT_CLIPBOARD");
        x.chunk_max = @min(@as(usize, @intCast(@max(0, xl.XMaxRequestSize(d)))) *| 4 -| 100, 256 * 1024);
        x.fx.XFixesSelectSelectionInput(d, x.win, x.clipboard_atom, select_owner_mask);
        x.watch = nanoui.fdwatch.readable(xl.XConnectionNumber(d), x, readable) catch return error.NoConnection;
        _ = xl.XFlush(d);
    }

    pub fn close(x: *X11) void {
        if (x.watch) |w| w.cancel();
        x.watch = null;
        if (x.d) |d| _ = x.xl.XCloseDisplay(d);
        x.d = null;
    }

    fn atom(x: *X11, name: [*:0]const u8) Atom {
        return x.xl.XInternAtom(x.d.?, name, 0);
    }

    /// Requests that may name a window that is gone: errors are the
    /// answer's, not GDK's (which would end the program).
    fn trap(x: *X11) ?ErrorHandler {
        x_failed = false;
        return x.xl.XSetErrorHandler(&onError);
    }

    fn untrap(x: *X11, before: ?ErrorHandler) bool {
        _ = x.xl.XSync(x.d.?, 0);
        _ = x.xl.XSetErrorHandler(before);
        return !x_failed;
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const x: *X11 = @ptrCast(@alignCast(ctx.?));
        const d = x.d orelse return;
        while (x.xl.XPending(d) > 0) {
            var ev: Event = .{ .pad = @splat(0) };
            _ = x.xl.XNextEvent(d, &ev);
            if (ev.type == x.fixes_event) {
                const e = as(FixesEvent, &ev);
                if (e.selection == x.clipboard_atom and e.owner != 0 and e.owner != x.win) x.begin(e.owner, e.selection_timestamp);
                continue;
            }
            switch (ev.type) {
                selection_notify => x.notified(as(SelectionEvent, &ev)),
                property_notify => x.property(as(PropertyEvent, &ev)),
                selection_request => x.request(as(SelectionRequest, &ev)),
                selection_clear => if (as(SelectionClear, &ev).selection == x.clipboard_atom) x.release(),
                else => {},
            }
        }
    }

    // ----- reading what was copied -----

    /// The owner window's WM_CLASS (its class, else its name), in `source_buf`.
    /// GTK3 and Qt owner windows have no WM_CLASS, only a WM_NAME (the program's
    /// name, or "Qt Selection Owner for <name>"), which stands in for it.
    fn wmClass(x: *X11, owner: Window) []const u8 {
        const qt = "Qt Selection Owner for ";
        for ([_][*:0]const u8{ "WM_CLASS", "WM_NAME" }) |prop| {
            var kind: Atom = 0;
            var format: c_int = 0;
            var n: c_ulong = 0;
            var left: c_ulong = 0;
            var data: ?[*]u8 = null;
            const before = x.trap();
            const rc = x.xl.XGetWindowProperty(x.d.?, owner, x.atom(prop), 0, 64, 0, xa_string, &kind, &format, &n, &left, &data);
            const ok = x.untrap(before) and rc == 0;
            defer if (data) |p| {
                _ = x.xl.XFree(p);
            };
            const bytes = (data orelse continue)[0..if (ok and format == 8) n else 0];
            // "name\0class\0", or a bare name.
            var it = std.mem.splitScalar(u8, bytes, 0);
            const name = it.next() orelse "";
            const class = it.next() orelse "";
            var pick = if (class.len > 0) class else name;
            if (std.mem.startsWith(u8, pick, qt)) pick = pick[qt.len..];
            if (pick.len == 0) continue;
            const len = @min(pick.len, x.source_buf.len);
            @memcpy(x.source_buf[0..len], pick[0..len]);
            return x.source_buf[0..len];
        }
        return "";
    }

    fn begin(x: *X11, owner: Window, time: c_ulong) void {
        if (x.phase != .idle) {
            x.queued = .{ .owner = owner, .time = time };
            return;
        }
        const sink = x.sink orelse return;
        const source = x.wmClass(owner);
        if (sink.excluded(sink.ctx, source)) return;
        x.phase = .targets;
        x.time = time;
        x.gather = .{ .plan = undefined, .sink = sink, .source = source };
        x.ask(x.targets_atom, 8192);
    }

    /// Asks the owner to convert the selection to `target` into our property.
    fn ask(x: *X11, target: Atom, cap: usize) void {
        x.want = target;
        x.cap = cap;
        x.buf.clearRetainingCapacity();
        _ = x.xl.XConvertSelection(x.d.?, x.clipboard_atom, target, x.prop_atom, x.win, x.time);
        _ = x.xl.XFlush(x.d.?);
        x.step();
    }

    fn step(x: *X11) void {
        x.tick +%= 1;
        lx.after(X11, x, x.tick, step_ms, expired);
    }

    fn expired(x: *X11, id: u32) void {
        if (x.phase != .idle and id == x.tick) x.finish();
    }

    fn finish(x: *X11) void {
        x.phase = .idle;
        for (x.names.items) |n| gpa.free(n);
        x.names.clearRetainingCapacity();
        x.buf.clearRetainingCapacity();
        if (x.buf.capacity > (1 << 20)) x.buf.clearAndFree(gpa);
        _ = x.xl.XDeleteProperty(x.d.?, x.win, x.prop_atom);
        if (x.queued) |q| {
            x.queued = null;
            x.begin(q.owner, q.time);
        }
    }

    const Prop = struct { kind: Atom = 0, format: c_int = 0, n: c_ulong = 0, left: c_ulong = 0, data: ?[*]u8 = null };

    /// Our property, read and deleted; at most `cap` bytes.
    fn take(x: *X11, cap: usize) ?Prop {
        var p: Prop = .{};
        const words: c_long = @intCast((cap + 3) / 4 + 1);
        if (x.xl.XGetWindowProperty(x.d.?, x.win, x.prop_atom, 0, words, 1, 0, &p.kind, &p.format, &p.n, &p.left, &p.data) != 0) return null;
        return p;
    }

    fn drop(x: *X11, p: Prop) void {
        if (p.data) |d| _ = x.xl.XFree(d);
        // Not deleted by the read when more was left.
        if (p.left > 0) _ = x.xl.XDeleteProperty(x.d.?, x.win, x.prop_atom);
    }

    fn notified(x: *X11, e: *const SelectionEvent) void {
        if (x.phase == .idle or e.selection != x.clipboard_atom or e.target != x.want) return;
        if (e.time != 0 and e.time != x.time) return;
        if (e.property == 0) return x.failed();
        const p = x.take(x.cap) orelse return x.failed();
        defer x.drop(p);
        if (p.kind == x.incr_atom) {
            if (x.phase == .targets) return x.finish();
            x.phase = .incr;
            return x.step();
        }
        const data = p.data orelse return x.failed();
        if (x.phase == .targets) return x.targets(p);
        if (p.left > 0 or p.format != 8) return x.failed();
        x.advance(data[0..p.n]);
    }

    /// The targets are in: plan what to read.
    fn targets(x: *X11, p: Prop) void {
        if (p.format != 32 or p.kind != xa_atom) return x.finish();
        const atoms: [*]const c_ulong = @ptrCast(@alignCast(p.data.?));
        for (atoms[0..@min(p.n, max_names)]) |a| {
            const name = x.xl.XGetAtomName(x.d.?, a) orelse continue;
            defer _ = x.xl.XFree(name);
            const dup = gpa.dupe(u8, std.mem.span(name)) catch break;
            x.names.append(gpa, dup) catch {
                gpa.free(dup);
                break;
            };
        }
        x.phase = .data;
        x.gather.plan = lx.plan(x.names.items);
        if (x.gather.plan.own) return x.finish();
        const r = x.gather.first() orelse return x.finish();
        x.fetch(r);
    }

    fn fetch(x: *X11, r: lx.Request) void {
        var name: [128:0]u8 = undefined;
        const n = @min(r.mime.len, name.len);
        @memcpy(name[0..n], r.mime[0..n]);
        name[n] = 0;
        x.phase = .data;
        x.ask(x.atom(&name), r.cap);
    }

    /// A read gave `bytes` (null: it failed); on to the next or done.
    fn advance(x: *X11, bytes: ?[]const u8) void {
        const r = x.gather.feed(bytes) orelse return x.finish();
        x.fetch(r);
    }

    fn failed(x: *X11) void {
        if (x.phase == .targets) x.finish() else x.advance(null);
    }

    /// One piece of an INCR transfer: the owner puts it in our property
    /// and waits for us to delete it; an empty piece ends the transfer.
    fn property(x: *X11, e: *const PropertyEvent) void {
        if (e.window != x.win) return x.outgoing(e);
        if (x.phase != .incr or e.atom != x.prop_atom or e.state != property_new_value) return;
        const p = x.take(x.cap - x.buf.items.len + 4) orelse return x.advance(null);
        defer x.drop(p);
        if (p.format != 8 or p.left > 0) return x.advance(null);
        if (p.n == 0) {
            x.phase = .data;
            return x.advance(x.buf.items);
        }
        if (x.buf.items.len + p.n > x.cap) return x.advance(null);
        x.buf.appendSlice(gpa, p.data.?[0..p.n]) catch return x.advance(null);
        x.step();
    }

    // ----- owning the clipboard -----

    fn release(x: *X11) void {
        if (x.served) |*s| s.deinit();
        x.served = null;
    }

    fn serve(x: *X11, c: clipboard.Content) bool {
        var s = lx.Served.init(gpa, c) catch return false;
        const mimes = s.mimes();
        for (mimes, 0..) |m, i| {
            var name: [lx.max_mime_name + 1:0]u8 = undefined;
            std.debug.assert(m.len < name.len);
            @memcpy(name[0..m.len], m);
            name[m.len] = 0;
            x.served_atoms[i] = x.atom(&name);
        }
        x.release();
        x.served = s;
        _ = x.xl.XSetSelectionOwner(x.d.?, x.clipboard_atom, x.win, 0);
        _ = x.xl.XFlush(x.d.?);
        if (x.xl.XGetSelectionOwner(x.d.?, x.clipboard_atom) == x.win) return true;
        x.release();
        return false;
    }

    /// Answers another client's request for the clipboard.
    fn request(x: *X11, e: *const SelectionRequest) void {
        const prop = if (e.property == 0) e.target else e.property;
        const ok = e.selection == x.clipboard_atom and x.reply(e, prop);
        var out: Event = .{ .pad = @splat(0) };
        @as(*SelectionEvent, @ptrCast(&out)).* = .{
            .type = selection_notify,
            .serial = 0,
            .send_event = 1,
            .display = x.d,
            .requestor = e.requestor,
            .selection = e.selection,
            .target = e.target,
            .property = if (ok) prop else 0,
            .time = e.time,
        };
        const before = x.trap();
        _ = x.xl.XSendEvent(x.d.?, e.requestor, 0, 0, &out);
        _ = x.untrap(before);
    }

    fn reply(x: *X11, e: *const SelectionRequest, prop: Atom) bool {
        const s = &(x.served orelse return false);
        const mimes = s.mimes();
        var data: []const u8 = undefined;
        var kind: Atom = e.target;
        var format: c_int = 8;
        var atoms: [lx.max_served_mimes + 1]c_ulong = undefined;
        if (e.target == x.targets_atom) {
            atoms[0] = x.targets_atom;
            for (mimes, 0..) |_, i| atoms[i + 1] = x.served_atoms[i];
            data = std.mem.sliceAsBytes(atoms[0 .. mimes.len + 1]);
            kind = xa_atom;
            format = 32;
        } else {
            data = for (mimes, 0..) |m, i| {
                if (x.served_atoms[i] == e.target) break s.bytes(m) orelse return false;
            } else return false;
            if (data.len > x.chunk_max) return x.startOut(e.requestor, prop, kind, data);
        }
        const n: c_int = @intCast(if (format == 32) data.len / @sizeOf(c_ulong) else data.len);
        const before = x.trap();
        _ = x.xl.XChangeProperty(x.d.?, e.requestor, prop, kind, format, prop_mode_replace, data.ptr, n);
        return x.untrap(before);
    }

    /// Tells the requestor the size and that it comes in pieces: each is
    /// sent as the one before is deleted.
    fn startOut(x: *X11, requestor: Window, prop: Atom, kind: Atom, data: []const u8) bool {
        if (x.out != null or x.chunk_max == 0) return false;
        const dup = gpa.dupe(u8, data) catch return false;
        var size: c_ulong = data.len;
        const before = x.trap();
        _ = x.xl.XSelectInput(x.d.?, requestor, property_change_mask);
        _ = x.xl.XChangeProperty(x.d.?, requestor, prop, x.incr_atom, 32, prop_mode_replace, std.mem.asBytes(&size), 1);
        if (!x.untrap(before)) {
            gpa.free(dup);
            return false;
        }
        x.out = .{ .requestor = requestor, .prop = prop, .kind = kind, .data = dup };
        x.stepOut();
        return true;
    }

    fn stepOut(x: *X11) void {
        x.out_tick +%= 1;
        lx.after(X11, x, x.out_tick, step_ms, expiredOut);
    }

    fn expiredOut(x: *X11, id: u32) void {
        if (x.out != null and id == x.out_tick) x.endOut();
    }

    fn endOut(x: *X11) void {
        const o = x.out orelse return;
        x.out = null;
        const before = x.trap();
        _ = x.xl.XSelectInput(x.d.?, o.requestor, 0);
        _ = x.untrap(before);
        gpa.free(o.data);
    }

    /// The requestor took a piece (deleted the property): the next, and at
    /// the end an empty one.
    fn outgoing(x: *X11, e: *const PropertyEvent) void {
        const o = &(x.out orelse return);
        if (e.window != o.requestor or e.atom != o.prop or e.state != property_delete) return;
        const n = @min(x.chunk_max, o.data.len - o.at);
        const before = x.trap();
        _ = x.xl.XChangeProperty(x.d.?, o.requestor, o.prop, o.kind, 8, prop_mode_replace, o.data.ptr + o.at, @intCast(n));
        const ok = x.untrap(before);
        o.at += n;
        if (n == 0 or !ok) x.endOut() else x.stepOut();
    }

    // ----- paste -----

    pub fn copy(x: *X11, c: clipboard.Content) bool {
        return x.serve(c);
    }

    pub fn paste(x: *X11, c: clipboard.Content, hide: clipboard.Hide) clipboard.PasteResult {
        if (!x.serve(c)) return .failed;
        if (x.xtst == null) return .copied_unsupported;
        hide.func(hide.ctx);
        lx.after(X11, x, 0, paste_delay_ms, sendKeys);
        return .pasted;
    }

    fn sendKeys(x: *X11, _: u32) void {
        const t = x.xtst orelse return;
        const d = x.d orelse return;
        const ctrl = x.xl.XKeysymToKeycode(d, xk_control_l);
        const v = x.xl.XKeysymToKeycode(d, xk_v);
        if (ctrl == 0 or v == 0) return;
        for ([_][2]c_int{ .{ ctrl, 1 }, .{ v, 1 }, .{ v, 0 }, .{ ctrl, 0 } }) |k| _ = t.XTestFakeKeyEvent(d, @intCast(k[0]), k[1], 0);
        _ = x.xl.XFlush(d);
    }
};
