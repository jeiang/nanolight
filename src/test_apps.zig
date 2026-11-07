//! Apps for tests, put in an index as a scan puts them.
const app_scan = @import("app_scan.zig");

/// Adds an app unless one of its name is there already, its folder the
/// one it is in.
pub fn add(sink: app_scan.Sink, name: []const u8, path: []const u8) !void {
    return sink.put(name, path, app_scan.folderOf(path));
}
