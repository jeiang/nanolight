//! File lookups run off the main thread; answers move their icons to the view.
const std = @import("std");
const files = @import("files.zig");
const prefs = @import("prefs.zig");
const suggest = @import("suggest.zig");
const Host = @import("host.zig").Host;
const pipeline = @import("pipeline.zig");
const platform = @import("platform.zig");
const paths = @import("paths.zig");
const after = @import("after.zig");
const App = @import("app.zig").App;

/// File search is the Mac's alone (`platform.files`): main.zig hands the
/// panel `entry` only there, so no other build reaches these.
const spotlight = if (platform.files) @import("spotlight.zig") else @compileError("no file search");
const icon_mac = if (platform.files) @import("icon_mac.zig") else @compileError("no file search");

pub const Files = struct {
    core: *App,
    query: [files.max_path]u8 = undefined,
    len: usize = 0,
    pause: after.Debounce = .{},
    epoch: u64 = 0,
    sent: u64 = 0,
    busy: bool = false,

    /// What the panel asks for files with.
    pub fn entry(f: *Files) Host.Ask {
        return .{ .ctx = f, .func = ask };
    }

    /// File lookups share the suggestions' pause and keep at most one worker.
    fn ask(ctx: *anyopaque, q: []const u8) void {
        if (q.len >= files.max_path) return;
        const f = after.cast(*Files, ctx);
        @memcpy(f.query[0..q.len], q);
        f.len = q.len;
        f.epoch +%= 1;
        f.pause.poke(suggest.pause_ms, Files, "pause", send);
    }

    fn send(f: *Files) void {
        const core = f.core;
        if (!core.s.files_on) return;
        if (f.busy) return;
        if (f.pause.waiting()) return;
        if (f.sent == f.epoch) return;
        const q = f.query[0..f.len];
        if (!std.mem.eql(u8, q, core.s.query.words())) return;
        const gpa = core.app.gpa;
        const a = gpa.create(FileAsk) catch return;
        a.* = .{
            .owner = f,
            .len = q.len,
            .epoch = f.epoch,
            .found = .{ .allocator = gpa },
        };
        @memcpy(a.text[0..q.len], q);
        a.locations = prefs.text(core.kv, gpa, .files_locations);
        a.exclusions = prefs.text(core.kv, gpa, .files_exclusions);
        f.busy = true;
        f.sent = f.epoch;
        const thread = std.Thread.spawn(.{}, FileAsk.run, .{a}) catch {
            f.busy = false;
            a.destroy();
            return;
        };
        thread.detach();
    }
};

/// One file query, with all filesystem, process and icon work off the UI thread.
const FileAsk = struct {
    owner: *Files,
    text: [files.max_path]u8 = undefined,
    len: usize,
    epoch: u64,
    locations: ?[]u8 = null,
    exclusions: ?[]u8 = null,
    found: files.List = .{},
    ok: bool = false,

    fn run(a: *FileAsk) void {
        const q = a.text[0..a.len];
        const io = a.owner.core.app.io;
        if (paths.isPath(q)) {
            files.complete(io, q, &a.found);
            a.ok = true;
        } else a.ok = spotlight.find(
            io,
            q,
            a.locations orelse "",
            a.exclusions orelse "",
            &a.found,
        ) catch |e| switch (e) {
            // Logged where mdfind failed.
            error.Unavailable => false,
            error.OutOfMemory => oom: {
                std.log.warn("file search: out of memory", .{});
                break :oom false;
            },
        };
        if (a.ok) icons(&a.found);
        after.oneShot(0, a, done);
    }

    fn done(a: *FileAsk) void {
        const f = a.owner;
        defer a.destroy();
        f.busy = false;
        if (a.ok and a.epoch == f.epoch) {
            pipeline.filesAnswered(f.core.s, a.text[0..a.len], &a.found);
            f.core.redraw();
        }
        f.send();
    }

    fn destroy(a: *FileAsk) void {
        const gpa = a.owner.core.app.gpa;
        if (a.locations) |v| gpa.free(v);
        if (a.exclusions) |v| gpa.free(v);
        a.found.deinit();
        gpa.destroy(a);
    }
};

/// Finder icons, prepared off the UI thread along with the answer.
fn icons(l: *files.List) void {
    for (l.entries[0..l.n]) |*e| {
        const png = icon_mac.png(l.allocator, e.path()) orelse continue;
        l.allocator.free(e.png);
        e.png = png;
    }
}
