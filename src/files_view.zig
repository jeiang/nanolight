//! File rows, the answer transferred from the lookup worker, and Tab
//! taking a found path.
const std = @import("std");
const ui = @import("nanoui").ui;
const files = @import("files.zig");
const paths = @import("paths.zig");
const spotlight = @import("spotlight.zig");
const Nanolight = @import("view.zig").Nanolight;
const Palette = @import("palette.zig").Palette;
const results = @import("results.zig");
const Row = results.Row;
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
    s.query.field.want_selection = .{ text.len, text.len };
}

/// A Spotlight answer lands only for the words still in the field.
pub fn filesAnswered(s: *Nanolight, typed: []const u8, found: *files.List) void {
    if (!s.files_on or !std.mem.eql(u8, typed, s.query.words())) return;
    s.refill(.{ .files = found });
}

pub fn row(s: *Nanolight, c: *ui.Context, p: Palette, i: usize, r: Row) void {
    const e = &s.found.entries[r.item];
    var buf: [files.max_path]u8 = undefined;
    const parent = paths.parent(&buf, e.path());
    chrome.nameDetail(c, p, e.name(), s.highlight(i, r, p), parent, .ellipsis);
    ui.text(c, if (e.folder) "Folder" else "File", .{ .size = 11.5, .color = p.sub });
}

pub fn tile(s: *Nanolight, c: *ui.Context, p: Palette, r: Row) void {
    const e = &s.found.entries[r.item];
    if (e.png.len > 0) return chrome.iconImage(c, e.path(), e.png);
    chrome.tile(c, p, if (e.folder) "folder" else results.providers.get(.file).symbol);
}

/// Retain matching rows while the worker answers the new query. A query
/// the answer card takes is not searched for.
pub fn rebuild(s: *Nanolight) void {
    const q = s.query.words();
    if (platform.files and s.files_on and
        (paths.isPath(q) or (spotlight.eligible(q) and !results.isMath(q, s.ratesTable()))))
    {
        s.found.filter(q);
        if (s.host) |host| if (host.files) |ask| ask.func(ask.ctx, q);
    } else s.found.deinit();
}

/// The file selected while a path is typed, its place among those found:
/// Tab takes its path (`takeFile`) rather than the faint completion.
pub fn tabFile(s: *const Nanolight) ?u32 {
    const r = s.selected() orelse return null;
    if (r.kind != .file or !paths.isPath(s.query.words())) return null;
    return r.item;
}
