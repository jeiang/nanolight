//! File rows and the answer transferred from the lookup worker.
const std = @import("std");
const ui = @import("nanoui").ui;
const files = @import("files.zig");
const Nanolight = @import("view.zig").Nanolight;
const Palette = @import("palette.zig").Palette;
const Row = @import("results.zig").Row;
const Anchor = @import("anchor.zig").Anchor;
const platform = @import("platform.zig");
const chrome = @import("chrome.zig");

pub fn takeFile(s: *Nanolight, i: usize) void {
    const e = &s.found.entries[i];
    var buf: [files.max_path + 1]u8 = undefined;
    const path = e.path();
    const text = std.fmt.bufPrint(
        &buf,
        "{s}{s}",
        .{ path, if (e.folder and !std.mem.endsWith(u8, path, "/")) "/" else "" },
    ) catch return;
    s.query.set(text);
    s.query.want_selection = .{ text.len, text.len };
}

/// A Spotlight answer lands only for the query still in the field.
pub fn filesAnswered(s: *Nanolight, typed: []const u8, found: *files.List) void {
    if (!s.files_on or !std.mem.eql(u8, typed, std.mem.trim(u8, s.query.text(), " \t\r\n"))) return;
    const was: Anchor = .of(s);
    s.found.replace(found);
    s.fill();
    s.sel = was.find(s) orelse 0;
}

pub fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const e = &s.found.entries[r.file];
    var buf: [files.max_path]u8 = undefined;
    const parent = files.parent(&buf, e.path());
    chrome.nameDetail(c, p, e.name(), s.highlight(i, r, p), parent, .ellipsis);
    ui.text(c, if (e.folder) "Folder" else "File", .{ .size = 11.5, .color = p.sub });
}

pub fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const e = &s.found.entries[r.file];
    if (e.png.len > 0) return chrome.iconImage(c, e.path(), e.png);
    chrome.tile(c, p, if (e.folder) "folder" else "doc");
}

/// Retain matching rows while the worker answers the new query.
pub fn rebuild(s: *Nanolight) void {
    const q = std.mem.trim(u8, s.query.text(), " \t\r\n");
    if (platform.files and s.files_on and
        (files.isPath(q) or (files.eligible(q) and @import("calc.zig").eval(q) == null)))
    {
        s.found.filter(q);
        if (s.host) |host| if (host.files) |ask| ask(host.ctx, q);
    } else s.found.deinit();
}

pub fn takeOnTab(s: *Nanolight, c: *ui.Context) bool {
    if (s.sel >= s.res.n or s.res.rows[s.sel].kind != .file or
        !files.isPath(s.query.text())) return false;
    if (c.shortcut(.{ .key = ui.Shortcut.tab })) takeFile(s, s.res.rows[s.sel].file);
    return true;
}
