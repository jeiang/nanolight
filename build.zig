//! Nanolight: a launcher for the Mac (⌘Space), Windows and Linux (Alt
//! Space), drawn by nanoui. Any target builds from any machine
//! (`-Dtarget=x86_64-windows-gnu`, `-Dtarget=x86_64-linux-gnu`).
//!
//!   zig build run            build and open it
//!   zig build app            zig-out/Nanolight.app, for /Applications
//!   zig build test           its search, math, suggestions and panel
//!   zig build server         the sync server, zig-out/bin/nanolight-server
//!   zig build check-config   a tool that reads config.toml files as the app does
//!   zig build clip-probe     the Linux clipboard watcher, run without the panel
//!   zig build lint           zig fmt's check and TigerStyle's line and catch rules
//!   -Dnix=true               a Nix build: Nix owns updates and startup, so
//!                            no updater and no login-item UI
//!
//! Releases (tools/, below `build`):
//!
//!   zig build package -Dversion=X.Y.Z    a release's files in zig-out/package
//!   zig build verify-release -- vX.Y.Z   checks a published release (Mac)
//!   zig build verify-update -- vOLD vNEW updates to it for real (Mac, CI only)
//!   zig build verify-typing -- [cycles]  the query never goes back (Mac, CI only)
//!   zig build icon                       redraws the icon (Mac)
const std = @import("std");
const release = @import("tools/release.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const version_option = b.option(
        []const u8,
        "version",
        "Nanolight's version, as the app shows it (release builds)",
    );
    const app_options: AppOptions = .{
        .target = target,
        .optimize = optimize,
        .version = version_option orelse "0.1.0",
        .nix_managed = b.option(
            bool,
            "nix",
            "A Nix build: the Nix modules own updates and startup (no updater, no login-item UI)",
        ) orelse false,
    };

    const exe = addApp(b, app_options);
    // A release is shipped without its debug info (15 MB to 2.8 MB on Linux).
    if (optimize != .debug) exe.root_module.strip = true;
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
        const app = b.addInstallDirectory(.{
            .source_dir = bundle(b, exe, app_options.version),
            .install_dir = .prefix,
            .install_subdir = "Nanolight.app",
        });
        b.getInstallStep().dependOn(&app.step);
        b.step("app", "Build zig-out/Nanolight.app").dependOn(&app.step);
    }

    const tests = b.addTest(.{ .root_module = appModule(b, "src/tests.zig", app_options) });
    // zig-out/bin/nanolight-tests: the tests, to run on another machine.
    b.step("test-bin", "Install the tests as zig-out/bin/nanolight-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = if (os == .windows) "nanolight-tests.exe" else "nanolight-tests" }).step);
    const test_step = b.step("test", "Test Nanolight's search, math, suggestions and panel, and the lint");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `zig build lint`: zig fmt's check, and the TigerStyle rules a machine
    // can check (tools/lint.zig, docs/TIGER_STYLE.md).
    const lint = b.addExecutable(.{ .name = "lint", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lint.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const lint_run = b.addRunArtifact(lint);
    lint_run.addDirectoryArg(b.path("src"));
    lint_run.addDirectoryArg(b.path("tools"));
    lint_run.addFileArg(b.path("build.zig"));
    const lint_step = b.step("lint", "Check formatting and TigerStyle's mechanical rules");
    const fmt_paths = [_]std.Build.LazyPath{ b.path("src"), b.path("tools"), b.path("build.zig") };
    lint_step.dependOn(&b.addFmt(.{ .paths = &fmt_paths, .check = true }).step);
    lint_step.dependOn(&lint_run.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lint.root_module })).step);

    // nanolight-server: the sync server (src/server.zig). Plain std, no nanoui.
    const server = b.addExecutable(.{ .name = "nanolight-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    if (optimize != .debug) server.root_module.strip = true;
    b.step("server", "Build the sync server (zig-out/bin/nanolight-server)").dependOn(&b.addInstallArtifact(server, .{}).step);

    // Reads config.toml files as the app does (src/check_config.zig); the flake's
    // config-parse check runs it on what the Nix modules write.
    const check_config = b.addExecutable(.{
        .name = "nanolight-check-config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nanoui", .module = nanoui }},
        }),
    });
    b.step("check-config", "Build zig-out/bin/nanolight-check-config")
        .dependOn(&b.addInstallArtifact(check_config, .{}).step);

    // Runs the Linux clipboard watcher without the panel (src/clipboard_probe.zig).
    if (os == .linux) {
        const probe = b.addExecutable(.{
            .name = "clip-probe",
            .root_module = appModule(b, "src/clipboard_probe.zig", app_options),
        });
        b.step("clip-probe", "Build the Linux clipboard probe (zig-out/bin/clip-probe)").dependOn(&b.addInstallArtifact(probe, .{}).step);
    }

    addReleaseSteps(b, .{ .version = version_option, .test_step = test_step });
}

/// One build of the app: its target, and what it is told at compile time.
const AppOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// For `--version`, and the updater off the Mac (no bundle there).
    version: []const u8,
    nix_managed: bool,
};

/// The program. Its caller decides whether it ships with its debug information.
fn addApp(b: *std.Build, options: AppOptions) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "nanolight",
        .root_module = appModule(b, "src/main.zig", options),
    });
    // Windows: a window app, with no console.
    if (options.target.result.os.tag == .windows) exe.subsystem = .windows;
    return exe;
}

/// A module of the app's code (the program, its tests, the clipboard probe):
/// nanoui, the build options, and what the platform links.
fn appModule(b: *std.Build, root: []const u8, options: AppOptions) *std.Build.Module {
    const nanoui = b.dependency("nanoui", .{
        .target = options.target,
        .optimize = options.optimize,
    }).module("nanoui");
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", options.version);
    build_options.addOption(bool, "nix_managed", options.nix_managed);
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    module.addOptions("build_options", build_options);
    linkPlatform(module, options.target.result.os.tag);
    return module;
}

/// Windows' libraries: the hot key, the Start menu's icons, and the Run key.
const windows_libraries = [_][]const u8{
    "user32", "gdi32", "shell32", "advapi32", "dwmapi", "ole32",
};

/// What the app links on each OS, for the program and its tests alike.
fn linkPlatform(module: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .macos => {
            // Its hot key (⌘Space from any app, or the key its welcome picks) is Carbon's.
            module.linkFramework("Carbon", .{});
            // Opening at login, from its welcome (SMAppService).
            module.linkFramework("ServiceManagement", .{});
            // Clipboard history's paste: the Accessibility check, and ⌘V sent as a key event.
            module.linkFramework("ApplicationServices", .{});
            module.linkFramework("CoreGraphics", .{});
        },
        // Windows: see windows_libraries.
        .windows => for (windows_libraries) |library| module.linkSystemLibrary(library, .{}),
        // Linux: X11, GTK and gdk-pixbuf are opened at run time (dlopen).
        else => {},
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

/// The bundle's Info.plist, for `zig build app` and for the release's app
/// (`zig build package` signs this same bundle).
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

// ----- releases: the packages, their checks, and the icon (tools/) -----

const ReleaseOptions = struct {
    /// `-Dversion`: required to package, since the version is compiled in.
    version: ?[]const u8,
    test_step: *std.Build.Step,
};

fn addReleaseSteps(b: *std.Build, options: ReleaseOptions) void {
    const tools_tests = b.addTest(.{ .root_module = toolModule(b, "tools/tests.zig") });
    options.test_step.dependOn(&b.addRunArtifact(tools_tests).step);
    // `zig build test` builds every tool, so that none rots between releases.
    const package_tool = b.addExecutable(.{
        .name = "package",
        .root_module = toolModule(b, "tools/package.zig"),
    });
    options.test_step.dependOn(&package_tool.step);
    addPackage(b, .{ .version = options.version, .tool = package_tool });
    const on_mac = b.graph.host.result.os.tag == .macos;
    _ = addMacTool(b, .{
        .name = "verify-release",
        .root = "tools/verify_release.zig",
        .description = "Check a published release's files, notarization and first run (-- vX.Y.Z)",
        .on_mac = on_mac,
        .test_step = options.test_step,
    });
    _ = addMacTool(b, .{
        .name = "verify-update",
        .root = "tools/verify_update.zig",
        .description = "Launch a release for real and update to it (-- vOLD vNEW; CI only)",
        .on_mac = on_mac,
        .test_step = options.test_step,
    });
    _ = addMacTool(b, .{
        .name = "verify-typing",
        .root = "tools/verify_typing.zig",
        .description = "Check the panel's query never goes back (-- [cycles]; CI only)",
        .on_mac = on_mac,
        .test_step = options.test_step,
    });
    const icon = addMacTool(b, .{
        .name = "icon",
        .root = "tools/icon.zig",
        .description = "Redraw src/icon.png, src/icon-256.png and macos/AppIcon.icns",
        .on_mac = on_mac,
        .test_step = options.test_step,
    });
    // It writes the icon's files in the source tree.
    if (icon) |run| run.setCwd(b.path("."));
}

fn toolModule(b: *std.Build, root: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
}

const MacTool = struct {
    name: []const u8,
    root: []const u8,
    description: []const u8,
    on_mac: bool,
    test_step: *std.Build.Step,
};

/// A step that runs a tool of the Mac's (its arguments after `--`), or that
/// says it needs a Mac.
fn addMacTool(b: *std.Build, tool: MacTool) ?*std.Build.Step.Run {
    const step = b.step(tool.name, tool.description);
    if (!tool.on_mac) {
        step.dependOn(&b.addFail(b.fmt("zig build {s} runs on a Mac", .{tool.name})).step);
        return null;
    }
    const module = toolModule(b, tool.root);
    module.link_libc = true;
    module.linkFramework("CoreFoundation", .{});
    module.linkFramework("CoreGraphics", .{});
    const exe = b.addExecutable(.{ .name = tool.name, .root_module = module });
    tool.test_step.dependOn(&exe.step);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    step.dependOn(&run.step);
    return run;
}

/// `zig build package -Dversion=X.Y.Z`: every release file this host can
/// make, in zig-out/package (tools/package.zig). The Mac's app needs a Mac;
/// Windows' and Linux' builds come from any host. Each program is built with
/// its debug information, which the package keeps beside it, stripped off
/// the program that ships.
const PackageOptions = struct {
    version: ?[]const u8,
    tool: *std.Build.Step.Compile,
};

fn addPackage(b: *std.Build, options: PackageOptions) void {
    const step = b.step("package", "A release's files in zig-out/package (-Dversion=X.Y.Z)");
    const given = options.version orelse {
        const message = "zig build package needs -Dversion=X.Y.Z: the version is compiled in";
        step.dependOn(&b.addFail(message).step);
        return;
    };
    const version = if (std.mem.startsWith(u8, given, "v")) given[1..] else given;
    const run = b.addRunArtifact(options.tool);
    run.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "package" } });
    run.addArgs(&.{ version, "--icon" });
    run.addFileArg(b.path("src/icon-256.png"));
    if (b.graph.host.result.os.tag == .macos) {
        // For macOS 14 and Apple silicon from the M1 on: a native build would
        // need the macOS and the CPU it was built on.
        const mac = addApp(b, releaseApp(b, version, .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_m1 },
        }));
        mac.root_module.strip = false;
        run.addArg("--macos");
        run.addDirectoryArg(bundle(b, mac, version));
    }
    for (release.pc_platforms) |platform| {
        const exe = addApp(b, releaseApp(b, version, .{
            .cpu_arch = platform.arch,
            .os_tag = platform.os,
            .abi = .gnu,
        }));
        exe.root_module.strip = false;
        var key: [release.name_bytes_max]u8 = undefined;
        run.addArgs(&.{ "--pc", b.dupe(platform.key(&key)) });
        if (platform.os == .windows) {
            run.addFileArg(exe.getEmittedBin());
            run.addFileArg(exe.getEmittedPdb());
        } else {
            // Zig's objcopy can't yet split ELF debug sections off
            // (`--extract-to` is unimplemented), so the same build is made
            // twice: stripped to ship, whole as its symbols.
            const shipped = addApp(b, releaseApp(b, version, .{
                .cpu_arch = platform.arch,
                .os_tag = platform.os,
                .abi = .gnu,
            }));
            shipped.root_module.strip = true;
            run.addFileArg(shipped.getEmittedBin());
            run.addFileArg(exe.getEmittedBin());
        }
    }
    step.dependOn(&run.step);
}

fn releaseApp(b: *std.Build, version: []const u8, query: std.Target.Query) AppOptions {
    return .{
        .target = b.resolveTargetQuery(query),
        .optimize = .ReleaseSafe,
        .version = version,
        .nix_managed = false,
    };
}
