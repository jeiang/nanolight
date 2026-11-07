//! Windows: the apps are the Start menu's shortcuts (`.lnk`, `.url`) in the
//! machine's and the user's Programs folders, a folder or two down, and a
//! few the system shows without one (Settings, File Explorer, the Store).
//! An app opens through the shell (ShellExecute, nanoui's `openPath`).
//! Its icon is the shell's own, 64 pixels (IShellItemImageFactory).
const std = @import("std");
const nanoui = @import("nanoui");
const app_scan = @import("app_scan.zig");
const Sink = app_scan.Sink;

/// Rows the system shows without a shortcut, listed by `scan`.
const settings = "Settings";
const explorer = "File Explorer";
const calculator = "Calculator";

pub const starters: []const []const u8 = &.{
    explorer,
    "Microsoft Edge",
    settings,
    "Notepad",
    calculator,
};

pub fn scan(sink: Sink, io: std.Io, env: *const std.process.Environ.Map) void {
    for ([_][]const u8{ "ProgramData", "APPDATA" }) |v| {
        const base = env.get(v) orelse continue;
        var buf: [1024]u8 = undefined;
        // A folder past 1 KB is passed over.
        const p = std.fmt.bufPrint(
            &buf,
            "{s}\\Microsoft\\Windows\\Start Menu\\Programs",
            .{base},
        ) catch continue;
        scanDir(sink, io, p, 2);
    }
    const windir = env.get("WINDIR") orelse "C:\\Windows";
    var ex: [512]u8 = undefined;
    sink.add(settings, "ms-settings:", "Windows");
    // A Windows folder past 512 bytes lists no File Explorer.
    if (std.fmt.bufPrint(
        &ex,
        "{s}\\explorer.exe",
        .{windir},
    )) |p| sink.add(explorer, p, "Windows") else |_| {}
    sink.add("Microsoft Store", "ms-windows-store:", "Windows");
    sink.add(calculator, "calculator:", "Windows");
}

pub fn scanDir(sink: Sink, io: std.Io, path: []const u8, depth: u8) void {
    app_scan.walk(io, path, depth, sink, visit);
}

fn visit(sink: Sink, f: app_scan.Found) app_scan.Step {
    const ext = std.fs.path.extension(f.entry.name);
    const link = std.ascii.eqlIgnoreCase(ext, ".lnk") or std.ascii.eqlIgnoreCase(ext, ".url");
    if (!link) return .descend;
    const name = f.entry.name[0 .. f.entry.name.len - ext.len];
    if (skipped(name)) return .next;
    const parent = std.fs.path.basename(f.folder);
    const folder = if (std.ascii.eqlIgnoreCase(parent, "Programs")) "Start" else parent;
    sink.add(name, f.full, folder);
    return .next;
}

/// Opens an app (a shortcut, a built-in's address), a file or a folder
/// through the shell.
pub fn launch(io: std.Io, path: []const u8) bool {
    _ = io;
    return nanoui.shell.openPath(path);
}

/// Shortcuts nobody launches from a launcher.
pub fn skipped(name: []const u8) bool {
    for ([_][]const u8{ "uninstall", "readme", "release notes", "website", "documentation" }) |w| {
        if (std.ascii.findIgnoreCase(name, w) != null) return true;
    }
    return false;
}

test "uninstallers and readmes are skipped" {
    try std.testing.expect(skipped("Uninstall Foo"));
    try std.testing.expect(skipped("Foo ReadMe"));
    try std.testing.expect(!skipped("Visual Studio Code"));
}

// ----- icons -----

const GUID = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const iid_image_factory: GUID = .{
    .a = 0xbcc18b79,
    .b = 0xba16,
    .c = 0x442f,
    .d = .{ 0x80, 0xc4, 0x8a, 0x59, 0xc3, 0x0c, 0x46, 0x3b },
};
const SIZE = extern struct { cx: i32, cy: i32 };
const Factory = extern struct { vtbl: *const extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (*Factory) callconv(.winapi) u32,
    GetImage: *const fn (*Factory, SIZE, u32, *?*anyopaque) callconv(.winapi) i32,
} };
const BITMAP = extern struct {
    bmType: i32,
    bmWidth: i32,
    bmHeight: i32,
    bmWidthBytes: i32,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?*anyopaque,
};
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
extern "shell32" fn SHCreateItemFromParsingName(
    path: [*:0]const u16,
    ctx: ?*anyopaque,
    riid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) i32;
extern "gdi32" fn GetObjectW(h: *anyopaque, size: i32, out: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn GetDIBits(
    dc: *anyopaque,
    bmp: *anyopaque,
    start: u32,
    lines: u32,
    bits: [*]u8,
    info: *BITMAPINFOHEADER,
    usage: u32,
) callconv(.winapi) i32;
extern "gdi32" fn DeleteObject(h: *anyopaque) callconv(.winapi) i32;
extern "user32" fn GetDC(hwnd: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hwnd: ?*anyopaque, dc: *anyopaque) callconv(.winapi) i32;

/// SIIGBF_BIGGERSIZEOK | SIIGBF_ICONONLY: the icon, never a thumbnail.
const flags: u32 = 0x1 | 0x4;

/// The shell's icon for `path` at 64 pixels, as PNG.
pub fn icon(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    path: []const u8,
) ?[]u8 {
    _ = io;
    _ = env;
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return null; // ms-settings: and the like
    var wide: [1024:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0..1023], path) catch return null;
    wide[n] = 0;
    var out: ?*anyopaque = null;
    if (SHCreateItemFromParsingName(wide[0..n :0], null, &iid_image_factory, &out) < 0) return null;
    const f: *Factory = @ptrCast(@alignCast(out orelse return null));
    defer _ = f.vtbl.Release(f);
    var bmp: ?*anyopaque = null;
    if (f.vtbl.GetImage(f, .{ .cx = 64, .cy = 64 }, flags, &bmp) < 0) return null;
    const h = bmp orelse return null;
    defer _ = DeleteObject(h);
    var bm: BITMAP = undefined;
    if (GetObjectW(h, @sizeOf(BITMAP), &bm) == 0 or bm.bmWidth <= 0 or
        bm.bmHeight == 0) return null;
    const w: usize = @intCast(bm.bmWidth);
    const ht: usize = @abs(bm.bmHeight);
    const bytes = gpa.alloc(u8, w * ht * 4) catch return null;
    defer gpa.free(bytes);
    const dc = GetDC(null) orelse return null;
    defer _ = ReleaseDC(null, dc);
    // Top-down rows of premultiplied BGRA, which is what PNG encoding takes.
    var info: BITMAPINFOHEADER = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(ht)) };
    if (GetDIBits(dc, h, 0, @intCast(ht), bytes.ptr, &info, 0) == 0) return null;
    return nanoui.ui.png.encode(gpa, .{ .bytes = bytes, .width = w, .height = ht }) catch null;
}
