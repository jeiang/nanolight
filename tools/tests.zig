//! The release tools' tests, for `zig build test`: what runs on any host.
//! The checks that need a Mac's programs run in CI on a release
//! (.github/workflows/verify-release.yml).
test {
    _ = @import("archive.zig");
    _ = @import("macos.zig");
    _ = @import("package.zig");
    _ = @import("png.zig");
    _ = @import("release.zig");
    _ = @import("verify_typing.zig");
    _ = @import("verify_update.zig");
}
