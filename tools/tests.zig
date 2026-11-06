//! Every tool's tests, for `zig build test`: what runs on any host. The
//! checks that need a Mac's programs run in CI on a release
//! (.github/workflows/verify-release.yml). A new file in tools/ is listed here.
test {
    _ = @import("archive.zig");
    _ = @import("command.zig");
    _ = @import("feed_server.zig");
    _ = @import("icon.zig");
    _ = @import("lint.zig");
    _ = @import("mac_verify.zig");
    _ = @import("macos.zig");
    _ = @import("package.zig");
    _ = @import("png.zig");
    _ = @import("release.zig");
    _ = @import("screen.zig");
    _ = @import("verify_release.zig");
    _ = @import("verify_typing.zig");
    _ = @import("verify_update.zig");
}
