//! Linux: the apps are the desktop entries (`*.desktop`) in the XDG data
//! directories' `applications` folders (and Flatpak's and Snap's), the
//! first of a name winning, as the desktop's own menus show them. An app
//! opens through `gio launch` (its Exec line, field codes and all), else
//! by its Exec line run here. Its icon is found in the icon themes and
//! drawn by gdk-pixbuf (SVG too) at 64 pixels.
const std = @import("std");
const apps = @import("apps.zig");
const Index = apps.Index;

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

/// The data directories, most personal first.
fn dataDirs(buf: *[16][]const u8, home_buf: []u8) [][]const u8 {
    var n: usize = 0;
    if (env("XDG_DATA_HOME")) |d| {
        buf[n] = d;
        n += 1;
    } else if (env("HOME")) |h| if (std.fmt.bufPrint(home_buf, "{s}/.local/share", .{h})) |p| {
        buf[n] = p;
        n += 1;
    } else |_| {};
    var it = std.mem.tokenizeScalar(u8, env("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (it.next()) |d| if (n < buf.len - 2) {
        buf[n] = d;
        n += 1;
    };
    buf[n] = "/var/lib/flatpak/exports/share";
    n += 1;
    return buf[0..n];
}

pub fn scan(ix: *Index, io: std.Io) void {
    var dirs: [16][]const u8 = undefined;
    var home: [512]u8 = undefined;
    for (dataDirs(&dirs, &home)) |d| {
        var p: [1024]u8 = undefined;
        const folder = std.fmt.bufPrint(&p, "{s}/applications", .{d}) catch continue;
        scanDir(ix, io, folder, 1);
    }
    scanDir(ix, io, "/var/lib/snapd/desktop/applications", 0);
}

pub fn scanDir(ix: *Index, io: std.Io, path: []const u8, depth: u8) void {
    const Scan = struct {
        ix: *Index,
        io: std.Io,

        fn visit(s: @This(), f: apps.Found) apps.Step {
            if (!std.mem.endsWith(u8, f.entry.name, ".desktop")) return .descend;
            var text: [16 * 1024]u8 = undefined;
            const bytes = f.dir.readFile(s.io, f.entry.name, &text) catch return .next;
            const entry = parse(bytes);
            if (!entry.shown()) return .next;
            s.ix.addIn(entry.name, f.full, "Application") catch return .stop;
            return .next;
        }
    };
    apps.walk(io, path, depth, Scan{ .ix = ix, .io = io }, Scan.visit);
}

pub const Entry = struct {
    name: []const u8 = "",
    exec: []const u8 = "",
    icon: []const u8 = "",
    app: bool = false,
    hidden: bool = false,

    fn shown(e: Entry) bool {
        return e.app and !e.hidden and e.name.len > 0 and e.exec.len > 0;
    }
};

/// The keys of a desktop file's [Desktop Entry] group (not translations).
pub fn parse(bytes: []const u8) Entry {
    var e: Entry = .{};
    var in_group = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_group = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_group) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "Name")) e.name = value else if (std.mem.eql(u8, key, "Exec")) e.exec = value else if (std.mem.eql(u8, key, "Icon")) e.icon = value else if (std.mem.eql(u8, key, "Type")) e.app = std.mem.eql(u8, value, "Application") else if (std.mem.eql(u8, key, "NoDisplay") or std.mem.eql(u8, key, "Hidden")) {
            if (std.mem.eql(u8, value, "true")) e.hidden = true;
        }
    }
    return e;
}

/// The Exec line's arguments: quoted ones unquoted, field codes (%f, %U…)
/// dropped, %% kept as %.
pub fn argv(exec: []const u8, store: []u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var s: usize = 0;
    var i: usize = 0;
    while (i < exec.len and n < out.len) {
        while (i < exec.len and exec[i] == ' ') i += 1;
        if (i >= exec.len) break;
        const start = s;
        var quoted = false;
        while (i < exec.len and (quoted or exec[i] != ' ')) : (i += 1) {
            const ch = exec[i];
            if (ch == '"') {
                quoted = !quoted;
                continue;
            }
            if (ch == '\\' and quoted and i + 1 < exec.len) {
                i += 1;
            } else if (ch == '%' and i + 1 < exec.len) {
                i += 1;
                if (exec[i] != '%') continue;
            }
            if (s == store.len) return out[0..n];
            store[s] = exec[i];
            s += 1;
        }
        if (s > start) {
            out[n] = store[start..s];
            n += 1;
        }
    }
    return out[0..n];
}

/// Opens the app of the desktop file at `path`.
pub fn launch(io: std.Io, path: []const u8) bool {
    if (spawn(io, &.{ "gio", "launch", path })) return true;
    var text: [16 * 1024]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &text) catch return false;
    const e = parse(bytes);
    var store: [4096]u8 = undefined;
    var args: [64][]const u8 = undefined;
    const a = argv(e.exec, &store, &args);
    return a.len > 0 and spawn(io, a);
}

fn spawn(io: std.Io, args: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = args, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .pgid = 0 }) catch return false;
    // Reaped once it ends (gio returns at once; an app runs on).
    const t = std.Thread.spawn(.{}, reap, .{ io, child }) catch {
        child.kill(io);
        return true;
    };
    t.detach();
    return true;
}

fn reap(io: std.Io, child: std.process.Child) void {
    var c = child;
    // best effort: the app was started; this only collects its exit status.
    _ = c.wait(io) catch {};
}

test "a desktop entry's keys and its Exec line" {
    const e = parse("[Desktop Entry]\nName=Files\nName[de]=Dateien\nExec=nautilus --new-window %U\nIcon=org.gnome.Nautilus\nType=Application\n[Desktop Action new]\nName=New\n");
    try std.testing.expectEqualStrings("Files", e.name);
    try std.testing.expectEqualStrings("org.gnome.Nautilus", e.icon);
    try std.testing.expect(e.shown());
    try std.testing.expect(!parse("[Desktop Entry]\nName=X\nExec=x\nType=Application\nNoDisplay=true\n").shown());
    var store: [256]u8 = undefined;
    var out: [8][]const u8 = undefined;
    const a = argv("\"/opt/My App/run\" --x=\"a b\" %f 100%%", &store, &out);
    try std.testing.expectEqual(@as(usize, 3), a.len);
    try std.testing.expectEqualStrings("/opt/My App/run", a[0]);
    try std.testing.expectEqualStrings("--x=a b", a[1]);
    try std.testing.expectEqualStrings("100%", a[2]);
}

// ----- icons -----

const sizes = [_][]const u8{ "64x64", "48x48", "96x96", "128x128", "256x256", "scalable", "512x512", "32x32" };
const themes = [_][]const u8{ "hicolor", "Adwaita", "breeze", "Papirus" };

/// The icon file for `name` (a path, or a name in the icon themes).
fn findIcon(io: std.Io, name: []const u8, out: []u8) ?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.isAbsolute(name)) return if (cwd.access(io, name, .{})) |_| name else |_| null;
    var dirs: [16][]const u8 = undefined;
    var home: [512]u8 = undefined;
    const data = dataDirs(&dirs, &home);
    for (themes) |theme| for (sizes) |size| for (data) |d| for ([_][]const u8{ "png", "svg" }) |ext| {
        const p = std.fmt.bufPrint(out, "{s}/icons/{s}/{s}/apps/{s}.{s}", .{ d, theme, size, name, ext }) catch continue;
        if (cwd.access(io, p, .{})) |_| return p else |_| {}
    };
    for ([_][]const u8{ "png", "svg", "xpm" }) |ext| {
        const p = std.fmt.bufPrint(out, "/usr/share/pixmaps/{s}.{s}", .{ name, ext }) catch continue;
        if (cwd.access(io, p, .{})) |_| return p else |_| {}
    }
    return null;
}

const Pixbuf = opaque {};
const Pb = struct {
    gdk_pixbuf_new_from_file_at_size: *const fn ([*:0]const u8, c_int, c_int, ?*?*anyopaque) callconv(.c) ?*Pixbuf,
    gdk_pixbuf_save_to_bufferv: *const fn (*Pixbuf, *?[*]u8, *usize, [*:0]const u8, ?*anyopaque, ?*anyopaque, ?*?*anyopaque) callconv(.c) c_int,
    g_object_unref: *const fn (*anyopaque) callconv(.c) void,
    g_free: *const fn (?*anyopaque) callconv(.c) void,
};
var pb: ?Pb = null;
var pb_tried = false;

fn pixbuf() ?Pb {
    if (pb_tried) return pb;
    pb_tried = true;
    const lib = std.c.dlopen("libgdk_pixbuf-2.0.so.0", .{ .NOW = true }) orelse return null;
    const gobj = std.c.dlopen("libgobject-2.0.so.0", .{ .NOW = true }) orelse return null;
    const glib = std.c.dlopen("libglib-2.0.so.0", .{ .NOW = true }) orelse return null;
    var v: Pb = undefined;
    inline for (@typeInfo(Pb).@"struct".field_names) |name| {
        const from = if (std.mem.startsWith(u8, name, "gdk")) lib else if (std.mem.eql(u8, name, "g_free")) glib else gobj;
        @field(v, name) = @ptrCast(@alignCast(std.c.dlsym(from, name) orelse return null));
    }
    pb = v;
    return v;
}

/// The icon of the desktop file at `path`, as a 64-pixel PNG.
pub fn icon(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    var text: [16 * 1024]u8 = undefined;
    const bytes = std.Io.Dir.cwd().readFile(io, path, &text) catch return null;
    const e = parse(bytes);
    if (e.icon.len == 0) return null;
    var buf: [1024]u8 = undefined;
    const file = findIcon(io, e.icon, &buf) orelse return null;
    const p = pixbuf() orelse {
        if (!std.mem.endsWith(u8, file, ".png")) return null;
        return std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(4 << 20)) catch null;
    };
    var z: [1025]u8 = undefined;
    @memcpy(z[0..file.len], file);
    z[file.len] = 0;
    const img = p.gdk_pixbuf_new_from_file_at_size(z[0..file.len :0], 64, 64, null) orelse return null;
    defer p.g_object_unref(img);
    var out: ?[*]u8 = null;
    var len: usize = 0;
    if (p.gdk_pixbuf_save_to_bufferv(img, &out, &len, "png", null, null, null) == 0) return null;
    defer p.g_free(out);
    const o = out orelse return null;
    return gpa.dupe(u8, o[0..len]) catch null;
}
