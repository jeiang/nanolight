//! Runs a Raycast script command (script_commands.zig) from its row, in
//! Zig: its arguments asked for first (a form in the panel, ⌘↩ runs), then
//! the script started with them, what it prints read as it comes (nothing
//! polls) and shown by its mode: `silent` hides the panel and says the last
//! line in the footer, `compact` and `inline` show the last line,
//! `fullOutput` everything, live. The panel's screen is raycast_view.zig's.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const assert = std.debug.assert;
const sc = @import("script_commands.zig");
const model = @import("raycast_model.zig");
const Ext = @import("raycast_view.zig").Ext;
const windows = builtin.os.tag == .windows;

comptime {
    // Each argument is a field of the form.
    assert(sc.max_args == model.max_fields);
}

pub const Hooks = struct {
    ctx: *anyopaque,
    hide: *const fn (ctx: *anyopaque) void,
    redraw: *const fn (ctx: *anyopaque) void,
    copy: *const fn (ctx: *anyopaque, text: []const u8) void,
    /// Said in the search's footer (a silent script's last line).
    footer: *const fn (ctx: *anyopaque, text: []const u8) void,
};

const max_out = 256 * 1024;
/// A script this size or larger isn't read, so it isn't run: its header,
/// which may ask to confirm or for arguments, would go unread.
const max_script_bytes = 1 << 20;

const run_actions = [_]model.Action{.run};
const done_actions = [_]model.Action{ .copy, .again };

/// The row a script is opened from.
pub const Row = struct {
    /// `script:<file>`.
    path: []const u8,
    title: []const u8,
    /// Its PNG, for the header.
    icon: ?[]const u8 = null,
};

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Runner = struct {
    gpa: std.mem.Allocator,
    /// The app's (processes need a real one: the global single-threaded
    /// Io can't start them).
    io: std.Io,
    ext: *Ext,
    hooks: Hooks,
    /// The script: its path, its bytes and its header (in `arena`).
    arena: ?std.heap.ArenaAllocator = null,
    file: []const u8 = "",
    bytes: []const u8 = "",
    meta: sc.Meta = .{},
    title: []const u8 = "",
    args: [sc.max_args]std.ArrayList(u8) = @splat(.empty),
    child: ?std.process.Child = null,
    watch: ?nanoui.fdwatch.Watch = null,
    out: std.ArrayList(u8) = .empty,
    footer_buf: [160]u8 = undefined,

    pub fn deinit(r: *Runner) void {
        r.stop();
        r.drop();
        for (&r.args) |*a| a.deinit(r.gpa);
        r.out.deinit(r.gpa);
    }

    fn drop(r: *Runner) void {
        if (r.arena) |*a| a.deinit();
        r.arena = null;
        r.file = "";
        r.bytes = "";
        r.meta = .{};
        r.title = "";
    }

    /// Opens a row's script.
    pub fn start(r: *Runner, row: Row) void {
        r.stop();
        r.drop();
        r.arena = .init(r.gpa);
        const a = r.arena.?.allocator();
        r.file = a.dupe(u8, row.path[sc.prefix.len..]) catch return;
        r.title = a.dupe(u8, row.title) catch return;
        for (&r.args) |*x| x.clearRetainingCapacity();
        r.ext.start(.{ .name = r.title, .icon = row.icon }, .{ .ctx = r, .func = heard });
        const limit: std.Io.Limit = .limited(max_script_bytes);
        r.bytes = std.Io.Dir.cwd().readFileAlloc(io(), r.file, a, limit) catch
            return r.fail("Couldn't read the script.");
        r.meta = sc.parse(a, r.bytes) orelse .{ .title = r.title };
        if (r.asks()) return r.ask();
        r.run();
    }

    /// It asks before it runs: for its arguments, or to confirm.
    fn asks(r: *const Runner) bool {
        return r.meta.argCount() > 0 or r.meta.confirm;
    }

    /// The arguments' form (or, with none, "Run X?"), Run on ⌘↩.
    fn ask(r: *Runner) void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const v = r.question(arena.allocator()) catch {
            // Out of memory: the screen keeps what it showed.
            arena.deinit();
            return;
        };
        r.ext.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `ask`'s view, its strings in `a`.
    fn question(r: *Runner, a: std.mem.Allocator) !model.View {
        const title = try a.dupe(u8, r.title);
        var fields: std.ArrayList(model.Field) = .empty;
        for (r.meta.args, 0..) |maybe, slot| {
            const arg = maybe orelse continue;
            const dropdown = std.mem.eql(u8, arg.type, "dropdown");
            // A dropdown starts on its first choice.
            if (dropdown and arg.data.len > 0 and r.args[slot].items.len == 0)
                try r.args[slot].appendSlice(r.gpa, arg.data[0].value);
            const opts = try a.alloc(model.Option, arg.data.len);
            for (opts, arg.data) |*o, d| o.* = .{
                .value = try a.dupe(u8, d.value),
                .title = try a.dupe(u8, d.title),
            };
            const label = if (arg.placeholder.len > 0) arg.placeholder else "Argument";
            try fields.append(a, .{
                .slot = slot,
                .kind = if (dropdown) .dropdown else .text,
                .title = try a.dupe(u8, label),
                .placeholder = if (arg.optional) "Optional" else "",
                .value = try a.dupe(u8, r.args[slot].items),
                .options = opts,
            });
        }
        const actions = &run_actions;
        if (fields.items.len > 0)
            return .{ .form = .{ .title = title, .fields = fields.items, .actions = actions } };
        const md = try std.fmt.allocPrint(a, "# Run {s}?\n{s}", .{ r.title, r.meta.description });
        return .{ .detail = .{ .title = title, .body = .{ .markdown = md }, .actions = actions } };
    }

    /// Starts the script with its arguments.
    fn run(r: *Runner) void {
        r.stop();
        r.out.clearRetainingCapacity();
        const a = r.arena.?.allocator();
        var cmd_buf: [8][]const u8 = undefined;
        const cmd = sc.command(r.bytes, r.file, &cmd_buf);
        var argv: std.ArrayList([]const u8) = .empty;
        // Its errors with its output: through sh, where there is one.
        if (!windows) argv.appendSlice(
            a,
            &.{ "/bin/sh", "-c", "exec \"$@\" 2>&1", "sh" },
        ) catch return;
        argv.appendSlice(a, cmd) catch return;
        for (r.meta.args, 0..) |maybe, i| {
            const arg = maybe orelse continue;
            const v = r.args[i].items;
            if (v.len == 0 and
                !arg.optional) return r.fail("Fill in every argument that isn't optional.");
            var enc: [2048]u8 = undefined;
            argv.append(
                a,
                a.dupe(u8, if (arg.percentEncoded) sc.encode(&enc, v) else v) catch return,
            ) catch return;
        }
        const dir = r.workDir(a);
        const child = std.process.spawn(
            r.io,
            .{
                .argv = argv.items,
                .cwd = .{ .path = dir },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = if (windows) .ignore else .inherit,
                .create_no_window = windows,
            },
        ) catch
            return r.fail("The script couldn't be started (is its interpreter installed?).");
        r.child = child;
        const out = child.stdout.?;
        r.watch = (if (windows)
            nanoui.fdwatch.reader(out.handle, r, bytesIn, ended)
        else
            nanoui.fdwatch.readable(out.handle, r, readable)) catch {
            // Unwatched, nothing would read its output or end it: it is
            // stopped here rather than left "Running…".
            r.stop();
            return r.fail("Couldn't follow the script's output.");
        };
        if (r.meta.mode == .silent) {
            r.ext.stop();
            r.hooks.hide(r.hooks.ctx);
        } else r.showOutput(false);
    }

    /// Its directory: `currentDirectoryPath` (with ~), else the script's.
    fn workDir(r: *Runner, a: std.mem.Allocator) []const u8 {
        const d = r.meta.cwd;
        if (d.len > 0) {
            if (d[0] != '~') return d;
            const home = std.c.getenv(if (windows) "USERPROFILE" else "HOME") orelse return d;
            return std.fs.path.join(a, &.{ std.mem.span(home), d[1..] }) catch d;
        }
        return std.fs.path.dirname(r.file) orelse ".";
    }

    fn fail(r: *Runner, why: []const u8) void {
        // Said in the panel (and the footer), not left at "Starting…".
        if (r.ext.view == null) {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            // Out of memory: the footer still says why.
            if (r.failed(arena.allocator(), why)) |v| r.ext.show(arena, v) else |_| arena.deinit();
        }
        r.ext.note(why, true);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `fail`'s view, its strings in `a`.
    fn failed(r: *Runner, a: std.mem.Allocator, why: []const u8) !model.View {
        const md = try std.fmt.allocPrint(a, "# {s}\n{s}", .{ r.title, why });
        return .{ .detail = .{ .title = try a.dupe(u8, r.title), .body = .{ .markdown = md } } };
    }

    /// What it printed so far, as its mode shows it.
    fn showOutput(r: *Runner, done: bool) void {
        if (!r.ext.open) return;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const v = r.printed(arena.allocator(), done) catch {
            // Out of memory: the screen keeps what it showed.
            arena.deinit();
            return;
        };
        r.ext.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `showOutput`'s view, its strings in `a`.
    fn printed(r: *Runner, a: std.mem.Allocator, done: bool) !model.View {
        const text = std.mem.trimEnd(u8, r.out.items, " \r\n");
        const body: model.Detail.Body = if (r.meta.mode == .full_output) .{
            .output = try a.dupe(u8, if (text.len == 0 and done) "(no output)" else text),
        } else body: {
            const last = lastLine(text);
            const heading = if (last.len > 0) last else if (done) "Done" else "Running…";
            break :body .{ .markdown = try std.fmt.allocPrint(a, "# {s}", .{heading}) };
        };
        return .{ .detail = .{
            .title = try a.dupe(u8, r.title),
            .body = body,
            .loading = !done,
            .actions = if (done) &done_actions else &.{},
        } };
    }

    /// What the screen said (raycast_view.zig `Sender`).
    fn heard(ctx: *anyopaque, event: model.Event) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        switch (event) {
            .field => |f| r.field(f.slot, f.value),
            .action => |a| switch (a) {
                .run => r.run(),
                .again => if (r.asks()) r.ask() else r.run(),
                .copy => {
                    r.hooks.copy(r.hooks.ctx, std.mem.trimEnd(u8, r.out.items, "\n"));
                    r.ext.note("Copied to the clipboard", false);
                },
            },
            .pop => {
                r.pop();
                r.hooks.redraw(r.hooks.ctx);
            },
        }
    }

    /// Argument `slot`'s new value.
    fn field(r: *Runner, slot: usize, value: []const u8) void {
        // The form's fields are the header's arguments (`question`).
        const arg = r.meta.args[slot].?;
        const held = &r.args[slot];
        // Out of memory: the old value stays.
        held.ensureTotalCapacity(r.gpa, value.len) catch return;
        held.clearRetainingCapacity();
        held.appendSliceAssumeCapacity(value);
        // A dropdown shows what was picked (text fields keep their own).
        if (std.mem.eql(u8, arg.type, "dropdown")) r.ask();
    }

    /// Ends the script and closes its screen.
    pub fn pop(r: *Runner) void {
        r.stop();
        r.ext.stop();
    }

    /// Ends a script still running.
    pub fn stop(r: *Runner) void {
        if (r.watch) |w| w.cancel();
        r.watch = null;
        if (r.child) |*c| {
            c.kill(r.io);
        }
        r.child = null;
    }

    fn readable(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const c = r.child orelse return;
        var buf: [16 * 1024]u8 = undefined;
        const n = std.c.read(c.stdout.?.handle, &buf, buf.len);
        if (n <= 0) return ended(ctx);
        r.feed(buf[0..@intCast(n)]);
    }

    fn bytesIn(ctx: ?*anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.feed(bytes);
    }

    /// Keeps what fits under `max_out`, and draws the screen again only when it kept
    /// something: a script printing forever stops costing renders once its output is full.
    fn feed(r: *Runner, bytes: []const u8) void {
        const room = max_out -| r.out.items.len;
        const kept = bytes[0..@min(bytes.len, room)];
        if (kept.len == 0) return;
        // Out of memory: this read is dropped and the screen keeps what it showed.
        r.out.appendSlice(r.gpa, kept) catch return;
        if (r.meta.mode == .full_output) r.showOutput(false);
    }

    fn ended(ctx: ?*anyopaque) callconv(.c) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        if (r.watch) |w| w.cancel();
        r.watch = null;
        var c = r.child orelse return;
        r.child = null;
        const term = c.wait(r.io) catch null;
        const ok = if (term) |t| t.success() else false;
        const text = std.mem.trimEnd(u8, r.out.items, " \r\n");
        const last = lastLine(text);
        if (!r.ext.open) {
            // Silent: the last line, said in the footer of the search.
            const said_text = if (last.len > 0) last else if (ok) r.title else "Failed";
            const n = @min(said_text.len, r.footer_buf.len);
            @memcpy(r.footer_buf[0..n], said_text[0..n]);
            r.hooks.footer(r.hooks.ctx, r.footer_buf[0..n]);
            return;
        }
        r.showOutput(true);
        if (!ok) {
            var buf: [64]u8 = undefined;
            const why = if (term) |t| switch (t) {
                .exited => |code| std.fmt.bufPrint(
                    &buf,
                    "Exited with code {d}",
                    .{code},
                ) catch "Failed",
                else => "Stopped",
            } else "Failed";
            r.ext.note(why, true);
        }
    }
};

fn lastLine(text: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return text;
    return text[nl + 1 ..];
}

fn ignore(_: *anyopaque) void {}
fn ignoreText(_: *anyopaque, _: []const u8) void {}

/// A runner whose hooks do nothing, for tests that start no process.
fn quiet(ext: *Ext, probe: *u8) Runner {
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .ext = ext, .hooks = .{
        .ctx = probe,
        .hide = ignore,
        .redraw = ignore,
        .copy = ignoreText,
        .footer = ignoreText,
    } };
}

fn countRedraw(ctx: *anyopaque) void {
    const count: *u8 = @ptrCast(ctx);
    count.* += 1;
}

test "output past the limit is dropped without drawing the screen again" {
    const t = std.testing;
    var ext: Ext = .{ .gpa = t.allocator };
    defer ext.deinit();
    var redraws: u8 = 0;
    var r = quiet(&ext, &redraws);
    defer r.deinit();
    r.hooks.redraw = countRedraw;
    r.meta.mode = .full_output;
    ext.start(.{ .name = "Yes" }, .{ .ctx = &r, .func = Runner.heard });
    const chunk: [16 * 1024]u8 = @splat('y');
    while (r.out.items.len < max_out) r.feed(&chunk);
    try t.expectEqual(max_out / chunk.len, redraws);
    r.feed(&chunk);
    r.feed("y\n");
    try t.expectEqual(max_out / chunk.len, redraws);
    try t.expectEqual(max_out, r.out.items.len);
}

test "a script too big to read isn't run, since its header could ask first" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const header = "#!/bin/sh\n# @raycast.schemaVersion 1\n# @raycast.title Wipe\n" ++
        "# @raycast.needsConfirmation true\n";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "wipe.sh", .data = header ++ "echo wiped\n" });
    // The same header, padded with comments to the limit.
    const big = try t.allocator.alloc(u8, max_script_bytes);
    defer t.allocator.free(big);
    @memset(big, '#');
    @memcpy(big[0..header.len], header);
    big[big.len - 1] = '\n';
    try tmp.dir.writeFile(t.io, .{ .sub_path = "big.sh", .data = big });

    var ext: Ext = .{ .gpa = t.allocator };
    defer ext.deinit();
    var probe: u8 = 0;
    var r = quiet(&ext, &probe);
    defer r.deinit();
    var buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}.zig-cache/tmp/{s}/", .{ sc.prefix, tmp.sub_path });
    var path_buf: [160]u8 = undefined;

    // Read whole, it asks before it runs.
    const small = try std.fmt.bufPrint(&path_buf, "{s}wipe.sh", .{dir});
    r.start(.{ .path = small, .title = "Wipe" });
    try t.expect(ext.open and r.child == null);
    try t.expect(std.mem.indexOf(u8, ext.view.?.detail.body.markdown, "Run Wipe?") != null);

    // Unread, it says so and doesn't run.
    r.start(.{ .path = try std.fmt.bufPrint(&path_buf, "{s}big.sh", .{dir}), .title = "Wipe" });
    try t.expect(ext.open and r.child == null);
    try t.expectEqualStrings("Couldn't read the script.", ext.note_buf[0..ext.note_len]);
    try t.expect(std.mem.indexOf(u8, ext.view.?.detail.body.markdown, "Couldn't read") != null);
}

test "a dropdown's pick is kept and shown in the form; a typed value is only kept" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "hi.sh", .data = "#!/bin/sh\n" ++
        "# @raycast.schemaVersion 1\n# @raycast.title Greet\n" ++
        "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"Name\" }\n" ++
        "# @raycast.argument3 { \"type\": \"dropdown\", \"placeholder\": \"Lang\", " ++
        "\"data\": [{\"title\": \"English\", \"value\": \"en\"}, " ++
        "{\"title\": \"French\", \"value\": \"fr\"}] }\n" });
    var ext: Ext = .{ .gpa = t.allocator };
    defer ext.deinit();
    var probe: u8 = 0;
    var r = quiet(&ext, &probe);
    defer r.deinit();
    var buf: [160]u8 = undefined;
    const dir = ".zig-cache/tmp/";
    const path = try std.fmt.bufPrint(&buf, "{s}{s}{s}/hi.sh", .{ sc.prefix, dir, tmp.sub_path });
    r.start(.{ .path = path, .title = "Greet" });
    // Two fields, the second for argument 3, on its first choice.
    const asked = ext.view.?.form.fields;
    try t.expectEqual(@as(usize, 2), asked.len);
    try t.expectEqual(@as(usize, 2), asked[1].slot);
    try t.expectEqualStrings("en", asked[1].value);
    try t.expectEqualStrings("French", asked[1].options[1].title);

    Runner.heard(&r, .{ .field = .{ .slot = 0, .value = "Rach" } });
    try t.expectEqualStrings("Rach", r.args[0].items);
    try t.expect(ext.view.?.form.fields.ptr == asked.ptr);

    Runner.heard(&r, .{ .field = .{ .slot = 2, .value = "fr" } });
    try t.expectEqualStrings("fr", r.args[2].items);
    const shown = ext.view.?.form.fields;
    try t.expectEqualStrings("fr", shown[1].value);
    try t.expectEqualStrings("Rach", shown[0].value);
    try t.expect(r.child == null);
}
