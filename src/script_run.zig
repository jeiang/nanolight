//! Runs a Raycast script command (script_commands.zig) from its row, in
//! Zig: its arguments asked for first (a form in the panel, ⌘↩ runs), then
//! the script started with them, what it prints read as it comes (nothing
//! polls) and shown by its mode: `silent` hides the panel and says the last
//! line in the footer, `compact` and `inline` show the last line,
//! `fullOutput` everything, live. It drives the panel's screen with
//! raycast_model.zig `Update`s.
const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");
const sc = @import("script_commands.zig");
const percentEncode = @import("text.zig").percentEncode;
const model = @import("raycast_model.zig");
const windows = builtin.os.tag == .windows;

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
/// The longest percent-encoded argument handed to a script.
const max_encoded = 2048;

const run_actions = [_]model.Action{.run};
const done_actions = actions: {
    var a: [2]model.Action = undefined;
    a[model.return_at] = .copy;
    a[model.cmd_return_at] = .again;
    break :actions a;
};

/// The row a script is opened from.
pub const Row = struct {
    file: []const u8,
    title: []const u8,
    /// Its PNG, for the header.
    icon: ?[]const u8 = null,
};

pub const Runner = struct {
    gpa: std.mem.Allocator,
    /// The app's (processes need a real one: the global single-threaded
    /// Io can't start them), which also reads the script.
    io: std.Io,
    screen: model.Screen,
    hooks: Hooks,
    open: bool = false,
    /// The screen shows a view, not "Starting…".
    shown: bool = false,
    /// The script: its path, its bytes and its header (in `arena`).
    arena: ?std.heap.ArenaAllocator = null,
    file: []const u8 = "",
    bytes: []const u8 = "",
    meta: sc.Meta = .{},
    title: []const u8 = "",
    args: [model.max_args]std.ArrayList(u8) = @splat(.empty),
    proc: proc.Runner = .{},
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

    pub fn start(r: *Runner, row: Row) void {
        r.stop();
        r.drop();
        r.arena = .init(r.gpa);
        const a = r.arena.?.allocator();
        r.file = a.dupe(u8, row.file) catch return;
        r.title = a.dupe(u8, row.title) catch return;
        for (&r.args) |*x| x.clearRetainingCapacity();
        const command: model.Command = .{ .name = r.title, .icon = row.icon };
        r.tell(.{ .start = .{ .command = command, .to = .{ .ctx = r, .func = heard } } });
        r.open = true;
        r.shown = false;
        const limit: std.Io.Limit = .limited(max_script_bytes);
        r.bytes = std.Io.Dir.cwd().readFileAlloc(r.io, r.file, a, limit) catch
            return r.fail("Couldn't read the script.");
        r.meta = sc.parse(a, r.bytes) orelse .{ .title = r.title };
        if (r.asks()) return r.ask();
        r.run();
    }

    fn tell(r: *Runner, update: model.Update) void {
        r.screen.func(r.screen.ctx, update);
    }

    /// `v`, its strings in `arena`, now the screen's.
    fn show(r: *Runner, arena: std.heap.ArenaAllocator, v: model.View) void {
        r.shown = true;
        r.tell(.{ .show = .{ .arena = arena, .view = v } });
    }

    fn note(r: *Runner, text: []const u8, bad: bool) void {
        r.tell(.{ .note = .{ .text = text, .bad = bad } });
    }

    fn close(r: *Runner) void {
        r.open = false;
        r.tell(.stop);
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
        r.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `ask`'s view, its strings in `a`.
    fn question(r: *Runner, a: std.mem.Allocator) !model.View {
        const title = try a.dupe(u8, r.title);
        var fields: std.ArrayList(model.Field) = .empty;
        for (r.meta.args, 0..) |maybe, slot| {
            const arg = maybe orelse continue;
            const kind = arg.kind();
            // A dropdown starts on its first choice.
            if (kind == .dropdown and arg.data.len > 0 and r.args[slot].items.len == 0)
                try r.args[slot].appendSlice(r.gpa, arg.data[0].value);
            const opts = try a.alloc(model.Option, arg.data.len);
            for (opts, arg.data) |*o, d| o.* = .{
                .value = try a.dupe(u8, d.value),
                .title = try a.dupe(u8, d.title),
            };
            const label = if (arg.placeholder.len > 0) arg.placeholder else "Argument";
            try fields.append(a, .{
                .slot = slot,
                .kind = kind,
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

    fn run(r: *Runner) void {
        r.stop();
        r.out.clearRetainingCapacity();
        const a = r.arena.?.allocator();
        const argv = r.commandLine(a) catch |e| return r.fail(switch (e) {
            error.Missing => "Fill in every argument that isn't optional.",
            error.TooLong => std.fmt.comptimePrint(
                "An argument is too long (over {d} bytes once encoded).",
                .{max_encoded},
            ),
            error.OutOfMemory => "Out of memory.",
        });
        const options: std.process.SpawnOptions = .{
            .argv = argv,
            .cwd = .{ .path = r.workDir(a) },
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = if (windows) .ignore else .inherit,
            .create_no_window = windows,
        };
        r.proc.start(r.io, options, .{ .ctx = r, .bytes = feed, .ended = ended }) catch |e|
            return r.fail(switch (e) {
                error.Spawn => "The script couldn't be started (is its interpreter installed?).",
                error.Watch => "Couldn't follow the script's output.",
            });
        if (r.meta.mode == .silent) {
            r.close();
            r.hooks.hide(r.hooks.ctx);
        } else r.showOutput(false);
    }

    const CommandLineError = error{ Missing, TooLong, OutOfMemory };

    /// The script's command line and its arguments, in `a`.
    fn commandLine(r: *const Runner, a: std.mem.Allocator) CommandLineError![]const []const u8 {
        var cmd_buf: [8][]const u8 = undefined;
        const cmd = sc.command(r.bytes, r.file, &cmd_buf);
        var argv: std.ArrayList([]const u8) = .empty;
        // Its errors with its output: through sh, where there is one.
        if (!windows) try argv.appendSlice(a, &.{ "/bin/sh", "-c", "exec \"$@\" 2>&1", "sh" });
        try argv.appendSlice(a, cmd);
        for (r.meta.args, 0..) |maybe, i| {
            const arg = maybe orelse continue;
            const v = r.args[i].items;
            if (v.len == 0 and !arg.optional) return error.Missing;
            if (!arg.percentEncoded) {
                try argv.append(a, try a.dupe(u8, v));
                continue;
            }
            var enc: [max_encoded]u8 = undefined;
            var w: std.Io.Writer = .fixed(&enc);
            percentEncode(&w, v, .{}) catch return error.TooLong;
            try argv.append(a, try a.dupe(u8, w.buffered()));
        }
        return argv.items;
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
        if (!r.shown) {
            var arena: std.heap.ArenaAllocator = .init(r.gpa);
            // Out of memory: the footer still says why.
            if (r.failed(arena.allocator(), why)) |v| r.show(arena, v) else |_| arena.deinit();
        }
        r.note(why, true);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `fail`'s view, its strings in `a`.
    fn failed(r: *Runner, a: std.mem.Allocator, why: []const u8) !model.View {
        const md = try std.fmt.allocPrint(a, "# {s}\n{s}", .{ r.title, why });
        return .{ .detail = .{ .title = try a.dupe(u8, r.title), .body = .{ .markdown = md } } };
    }

    /// What it printed so far, as its mode shows it.
    fn showOutput(r: *Runner, done: bool) void {
        if (!r.open) return;
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        const v = r.printed(arena.allocator(), done) catch {
            // Out of memory: the screen keeps what it showed.
            arena.deinit();
            return;
        };
        r.show(arena, v);
        r.hooks.redraw(r.hooks.ctx);
    }

    /// `showOutput`'s view, its strings in `a`.
    fn printed(r: *Runner, a: std.mem.Allocator, done: bool) !model.View {
        const text = std.mem.trimEnd(u8, r.out.items, " \r\n");
        const body: model.Detail.Body = if (r.meta.mode == .full_output) .{
            .output = try a.dupe(u8, if (text.len == 0 and done) "(no output)" else text),
        } else body: {
            const last = proc.lastLine(text);
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

    /// What the screen said (raycast_model.zig `Sender`).
    fn heard(ctx: *anyopaque, event: model.Event) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        switch (event) {
            .field => |f| r.field(f.slot, f.value),
            .action => |a| switch (a) {
                .run => r.run(),
                .again => if (r.asks()) r.ask() else r.run(),
                .copy => {
                    r.hooks.copy(r.hooks.ctx, std.mem.trimEnd(u8, r.out.items, "\n"));
                    r.note("Copied to the clipboard", false);
                },
            },
            .pop => {
                r.pop();
                r.hooks.redraw(r.hooks.ctx);
            },
        }
    }

    fn field(r: *Runner, slot: usize, value: []const u8) void {
        // The form's fields are the header's arguments (`question`).
        const arg = r.meta.args[slot].?;
        const held = &r.args[slot];
        // Out of memory: the old value stays.
        held.ensureTotalCapacity(r.gpa, value.len) catch return;
        held.clearRetainingCapacity();
        held.appendSliceAssumeCapacity(value);
        // A dropdown shows what was picked (typed fields keep their own).
        if (arg.kind() == .dropdown) r.ask();
    }

    /// Ends the script and closes its screen.
    pub fn pop(r: *Runner) void {
        r.stop();
        r.close();
    }

    pub fn stop(r: *Runner) void {
        r.proc.stop();
    }

    /// Keeps what fits under `max_out`, and draws the screen again only when it kept
    /// something: a script printing forever stops costing renders once its output is full.
    fn feed(ctx: *anyopaque, bytes: []const u8) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const room = max_out -| r.out.items.len;
        const kept = bytes[0..@min(bytes.len, room)];
        if (kept.len == 0) return;
        // Out of memory: this read is dropped and the screen keeps what it showed.
        r.out.appendSlice(r.gpa, kept) catch return;
        if (r.meta.mode == .full_output) r.showOutput(false);
    }

    fn ended(ctx: *anyopaque, term: ?std.process.Child.Term) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const ok = if (term) |t| t.success() else false;
        const last = proc.lastLine(r.out.items);
        if (!r.open) {
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
            r.note(why, true);
        }
    }
};

/// A screen that keeps what it was told last, for tests.
const Kept = struct {
    arena: ?std.heap.ArenaAllocator = null,
    view: ?model.View = null,
    open: bool = false,
    note_buf: [200]u8 = undefined,
    note_len: usize = 0,

    fn screen(k: *Kept) model.Screen {
        return .{ .ctx = k, .func = told };
    }

    fn told(ctx: *anyopaque, update: model.Update) void {
        const k: *Kept = @ptrCast(@alignCast(ctx));
        switch (update) {
            .start => k.open = true,
            .show => |s| {
                if (k.arena) |*a| a.deinit();
                k.arena = s.arena;
                k.view = s.view;
            },
            .note => |n| {
                k.note_len = @min(n.text.len, k.note_buf.len);
                @memcpy(k.note_buf[0..k.note_len], n.text[0..k.note_len]);
            },
            .stop => k.open = false,
        }
    }

    fn note(k: *const Kept) []const u8 {
        return k.note_buf[0..k.note_len];
    }

    fn deinit(k: *Kept) void {
        if (k.arena) |*a| a.deinit();
    }
};

fn ignore(_: *anyopaque) void {}
fn ignoreText(_: *anyopaque, _: []const u8) void {}

/// A runner whose hooks do nothing, for tests that start no process.
fn quiet(kept: *Kept, probe: *u8) Runner {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .screen = kept.screen(),
        .hooks = .{
            .ctx = probe,
            .hide = ignore,
            .redraw = ignore,
            .copy = ignoreText,
            .footer = ignoreText,
        },
    };
}

fn countRedraw(ctx: *anyopaque) void {
    const count: *u8 = @ptrCast(ctx);
    count.* += 1;
}

test "output past the limit is dropped without drawing the screen again" {
    const t = std.testing;
    var kept: Kept = .{};
    defer kept.deinit();
    var redraws: u8 = 0;
    var r = quiet(&kept, &redraws);
    defer r.deinit();
    r.hooks.redraw = countRedraw;
    r.meta.mode = .full_output;
    r.open = true;
    const chunk: [16 * 1024]u8 = @splat('y');
    while (r.out.items.len < max_out) Runner.feed(&r, &chunk);
    try t.expectEqual(max_out / chunk.len, redraws);
    Runner.feed(&r, &chunk);
    Runner.feed(&r, "y\n");
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

    var kept: Kept = .{};
    defer kept.deinit();
    var probe: u8 = 0;
    var r = quiet(&kept, &probe);
    defer r.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try @import("test_tmp.zig").path(&buf, &tmp);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Read whole, it asks before it runs.
    const small = try std.fmt.bufPrint(&path_buf, "{s}/wipe.sh", .{dir});
    r.start(.{ .file = small, .title = "Wipe" });
    try t.expect(kept.open and r.proc.live == null);
    try t.expect(std.mem.indexOf(u8, kept.view.?.detail.body.markdown, "Run Wipe?") != null);

    // Unread, it says so and doesn't run.
    r.start(.{ .file = try std.fmt.bufPrint(&path_buf, "{s}/big.sh", .{dir}), .title = "Wipe" });
    try t.expect(kept.open and r.proc.live == null);
    try t.expectEqualStrings("Couldn't read the script.", kept.note());
    try t.expect(std.mem.indexOf(u8, kept.view.?.detail.body.markdown, "Couldn't read") != null);
}

test "a dropdown's pick is kept and shown in the form; a typed value is only kept" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "hi.sh", .data = "#!/bin/sh\n" ++
        "# @raycast.schemaVersion 1\n# @raycast.title Greet\n" ++
        "# @raycast.argument1 { \"type\": \"text\", \"placeholder\": \"Name\" }\n" ++
        "# @raycast.argument2 { \"type\": \"password\", \"placeholder\": \"Token\" }\n" ++
        "# @raycast.argument3 { \"type\": \"dropdown\", \"placeholder\": \"Lang\", " ++
        "\"data\": [{\"title\": \"English\", \"value\": \"en\"}, " ++
        "{\"title\": \"French\", \"value\": \"fr\"}] }\n" });
    var kept: Kept = .{};
    defer kept.deinit();
    var probe: u8 = 0;
    var r = quiet(&kept, &probe);
    defer r.deinit();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try @import("test_tmp.zig").path(&dir_buf, &tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/hi.sh", .{dir});
    r.start(.{ .file = path, .title = "Greet" });
    const asked = kept.view.?.form.fields;
    try t.expectEqual(@as(usize, 3), asked.len);
    try t.expectEqual(model.Field.Kind.password, asked[1].kind);
    try t.expectEqual(@as(usize, 2), asked[2].slot);
    try t.expectEqualStrings("en", asked[2].value);
    try t.expectEqualStrings("French", asked[2].options[1].title);

    Runner.heard(&r, .{ .field = .{ .slot = 0, .value = "Rach" } });
    try t.expectEqualStrings("Rach", r.args[0].items);
    try t.expect(kept.view.?.form.fields.ptr == asked.ptr);

    Runner.heard(&r, .{ .field = .{ .slot = 2, .value = "fr" } });
    try t.expectEqualStrings("fr", r.args[2].items);
    const shown = kept.view.?.form.fields;
    try t.expectEqualStrings("fr", shown[2].value);
    try t.expectEqualStrings("Rach", shown[0].value);
    try t.expect(r.proc.live == null);
}

test "an argument too long once encoded fails, saying so, and runs nothing" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "find.sh", .data = "#!/bin/sh\n" ++
        "# @raycast.schemaVersion 1\n# @raycast.title Find\n" ++
        "# @raycast.argument1 { \"type\": \"text\", \"percentEncoded\": true }\n" });
    var kept: Kept = .{};
    defer kept.deinit();
    var probe: u8 = 0;
    var r = quiet(&kept, &probe);
    defer r.deinit();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try @import("test_tmp.zig").path(&dir_buf, &tmp);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    r.start(.{ .file = try std.fmt.bufPrint(&buf, "{s}/find.sh", .{dir}), .title = "Find" });
    // Each space encodes to three bytes: one past the limit.
    const long: [max_encoded / 3 + 1]u8 = @splat(' ');
    Runner.heard(&r, .{ .field = .{ .slot = 0, .value = &long } });
    Runner.heard(&r, .{ .action = .run });
    try t.expect(r.proc.live == null);
    const said = "An argument is too long (over 2048 bytes once encoded).";
    try t.expectEqualStrings(said, kept.note());
}
