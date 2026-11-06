//! Nanolight: a launcher for the Mac (⌘Space), Windows and Linux (Alt
//! Space), drawn by nanoui. Any target builds from any machine
//! (`-Dtarget=x86_64-windows-gnu`, `-Dtarget=x86_64-linux-gnu`).
//!
//!   zig build run            build and open it
//!   zig build app            zig-out/Nanolight.app, for /Applications
//!   zig build test           its search, math, suggestions and panel
//!   zig build server         the sync server, zig-out/bin/nanolight-server
//!   zig build clip-probe     the Linux clipboard watcher, run without the panel
//!   -Dnix=true               a Nix build: Nix owns updates and startup, so
//!                            no updater and no login-item UI
//!
//! Release packages (the signed app, its disk image and the update feed)
//! are macos/package.sh's; Windows' zip and Linux's tarball, pc/package.sh's.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    const version = b.option([]const u8, "version", "Nanolight's version, as the app shows it (release builds)") orelse "0.1.0";
    // The version, for `--version` and the updater off the Mac (no bundle there).
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", version);
    opts.addOption(bool, "nix_managed", b.option(bool, "nix", "A Nix build: the Nix modules own updates and startup (no updater, no login-item UI)") orelse false);

    const exe = b.addExecutable(.{ .name = "nanolight", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    exe.root_module.addOptions("build_options", opts);
    // A release is shipped without its debug info (15 MB to 2.8 MB on Linux).
    if (optimize != .debug) exe.root_module.strip = true;
    switch (os) {
        .macos => {
            // Its hot key (⌘Space from any app, or the key its welcome picks) is Carbon's.
            exe.root_module.linkFramework("Carbon", .{});
            // Opening at login, from its welcome (SMAppService).
            exe.root_module.linkFramework("ServiceManagement", .{});
            // Clipboard history's paste: the Accessibility check, and ⌘V sent as a key event.
            exe.root_module.linkFramework("ApplicationServices", .{});
            exe.root_module.linkFramework("CoreGraphics", .{});
        },
        .windows => {
            // A window app: no console. The hot key, the Start menu's icons,
            // and the Run key.
            exe.subsystem = .windows;
            for ([_][]const u8{ "user32", "gdi32", "shell32", "advapi32", "dwmapi", "ole32" }) |lib| exe.root_module.linkSystemLibrary(lib, .{});
        },
        // Linux: X11, GTK and gdk-pixbuf are opened at run time (dlopen).
        else => {},
    }
    b.installArtifact(exe);
    // `zig build check`: compiles without linking, so a machine without the
    // target's SDK still type-checks it. `-Dsdk=<dir>` points at stub
    // frameworks and libraries (`<dir>/System/Library/Frameworks`, `<dir>/usr/lib`).
    const chk = b.addObject(.{ .name = "nanolight-check", .root_module = exe.root_module });
    if (b.option([]const u8, "sdk", "SDK root whose frameworks and libraries satisfy `check` (any target)")) |sdk| {
        exe.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        exe.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    }
    b.step("check", "Type-check without linking").dependOn(&chk.step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Nanolight (⌘Space)").dependOn(&run.step);

    // zig-out/Nanolight.app: the program with its icon, for /Applications.
    if (os == .macos) {
        const app = b.addInstallDirectory(.{ .source_dir = bundle(b, exe, version), .install_dir = .prefix, .install_subdir = "Nanolight.app" });
        b.getInstallStep().dependOn(&app.step);
        b.step("app", "Build zig-out/Nanolight.app").dependOn(&app.step);
    }

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    tests.root_module.addOptions("build_options", opts);
    if (os == .windows) for ([_][]const u8{ "user32", "gdi32", "shell32", "advapi32", "dwmapi", "ole32" }) |lib| tests.root_module.linkSystemLibrary(lib, .{});
    if (os == .macos) tests.root_module.linkFramework("ApplicationServices", .{});
    // zig-out/bin/nanolight-tests: the tests, to run on another machine.
    b.step("test-bin", "Install the tests as zig-out/bin/nanolight-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "nanolight-tests.exe" else "nanolight-tests" }).step);
    b.step("test", "Test Nanolight's search, math, suggestions and panel").dependOn(&b.addRunArtifact(tests).step);

    // nanolight-server: the sync server (src/server.zig). Plain std, no nanoui.
    const server = b.addExecutable(.{ .name = "nanolight-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    if (optimize != .debug) server.root_module.strip = true;
    b.step("server", "Build the sync server (zig-out/bin/nanolight-server)").dependOn(&b.addInstallArtifact(server, .{}).step);

    // Runs the Linux clipboard watcher without the panel (src/clipboard_probe.zig).
    if (os == .linux) {
        const probe = b.addExecutable(.{ .name = "clip-probe", .root_module = b.createModule(.{
            .root_source_file = b.path("src/clipboard_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }) });
        b.step("clip-probe", "Build the Linux clipboard probe (zig-out/bin/clip-probe)").dependOn(&b.addInstallArtifact(probe, .{}).step);
    }
}

/// Nanolight as a Mac app: its program, its icon, and an Info.plist that
/// keeps it out of the Dock (a menu bar app).
fn bundle(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.add("Contents/Info.plist", infoPlist(b, version));
    _ = wf.addCopyFile(exe.getEmittedBin(), "Contents/MacOS/nanolight");
    _ = wf.addCopyFile(b.path("macos/AppIcon.icns"), "Contents/Resources/AppIcon.icns");
    return wf.getDirectory();
}

/// The bundle's Info.plist (macos/package.sh writes the same one).
pub fn infoPlist(b: *std.Build, version: []const u8) []const u8 {
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key><string>nanolight</string>
        \\  <key>CFBundleIdentifier</key><string>dev.nanoui.nanolight</string>
        \\  <key>CFBundleName</key><string>Nanolight</string>
        \\  <key>CFBundleDisplayName</key><string>Nanolight</string>
        \\  <key>CFBundleIconFile</key><string>AppIcon</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{s}</string>
        \\  <key>CFBundleVersion</key><string>{s}</string>
        \\  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
        \\  <key>LSMinimumSystemVersion</key><string>14.0</string>
        \\  <key>LSUIElement</key><true/>
        \\  <key>NSPrincipalClass</key><string>NSApplication</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
        \\  <key>NSDesktopFolderUsageDescription</key><string>File Search lists the files and folders in a folder you type.</string>
        \\  <key>NSDocumentsFolderUsageDescription</key><string>File Search lists the files and folders in a folder you type.</string>
        \\  <key>NSDownloadsFolderUsageDescription</key><string>File Search lists the files and folders in a folder you type.</string>
        \\  <key>NSRemovableVolumesUsageDescription</key><string>File Search lists the files and folders in a folder you type.</string>
        \\  <key>NSNetworkVolumesUsageDescription</key><string>File Search lists the files and folders in a folder you type.</string>
        \\</dict>
        \\</plist>
        \\
    , .{ version, version });
}
