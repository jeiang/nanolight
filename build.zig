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
//!   -Dmac-tools=false        leaves out the Mac's release tools, which need
//!                            its SDK (Nix's sandbox has none for them)
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
const app_facts = @import("src/app_facts.zig");

// A tool's module can't reach src/ by path, so release.zig can't import the
// app's name: it spells it again, and the build holds the two together.
comptime {
    std.debug.assert(std.mem.eql(u8, release.app_name, app_facts.app_name));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const version_option = b.option(
        []const u8,
        "version",
        "Nanolight's version, as the app shows it (X.Y.Z or vX.Y.Z; default build.zig.zon's)",
    );
    const version: ?[]const u8 = if (version_option) |given| release.versionOfTag(given) else null;
    const app_options: AppOptions = .{
        .target = target,
        .optimize = optimize,
        .version = version orelse manifestVersion(b),
        .nix_managed = b.option(
            bool,
            "nix",
            "A Nix build: the Nix modules own updates and startup (no updater, no login-item UI)",
        ) orelse false,
    };
    const on_mac = b.graph.host.result.os.tag == .macos;
    const mac_tools = b.option(
        bool,
        "mac-tools",
        "Build the Mac's release tools, which link its SDK's frameworks (default: on a Mac)",
    ) orelse on_mac;

    const exe = addApp(b, app_options);
    // A release is shipped without its debug info (15 MB to 2.8 MB on Linux).
    if (optimize != .debug) exe.root_module.strip = true;
    b.installArtifact(exe);
    addCheck(b, app_options);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run Nanolight (⌘Space)").dependOn(&run.step);

    if (os == .macos) addAppBundle(b, exe, app_options.version);

    const tests = b.addTest(.{ .root_module = appModule(b, "src/tests.zig", app_options) });
    const test_step = b.step(
        "test",
        "Test Nanolight's search, math, suggestions and panel, and the tools",
    );
    test_step.dependOn(&b.addRunArtifact(tests).step);

    addLint(b);
    addServer(b, target, optimize);
    addCheckConfig(b, target, optimize);

    if (os == .linux) {
        const probe = b.addExecutable(.{
            .name = "clip-probe",
            .root_module = appModule(b, "src/clipboard_probe.zig", app_options),
        });
        b.step("clip-probe", "Build the Linux clipboard probe (zig-out/bin/clip-probe)")
            .dependOn(&b.addInstallArtifact(probe, .{}).step);
    }

    addReleaseSteps(b, .{
        .version = version,
        .test_step = test_step,
        .on_mac = on_mac,
        .mac_tools = mac_tools,
    });
}

/// build.zig.zon's version: what a build without -Dversion says.
fn manifestVersion(b: *std.Build) []const u8 {
    const Manifest = struct { version: []const u8 };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = @embedFile("build.zig.zon"),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.ParseZon => {
            diagnostics.log("build.zig.zon");
            std.process.exit(1);
        },
    };
    return manifest.version;
}

/// `zig build check`: compiles without linking, so a machine without the
/// target's SDK still type-checks it. `-Dsdk=<dir>` points at stub
/// frameworks and libraries (`<dir>/System/Library/Frameworks`, `<dir>/usr/lib`).
fn addCheck(b: *std.Build, options: AppOptions) void {
    // Its own module: `-Dsdk`'s paths are for `check`, not the program that ships.
    const module = appModule(b, "src/main.zig", options);
    if (b.option(
        []const u8,
        "sdk",
        "SDK root whose frameworks and libraries satisfy `check` (any target)",
    )) |sdk| {
        const frameworks = b.fmt("{s}/System/Library/Frameworks", .{sdk});
        module.addFrameworkPath(.{ .cwd_relative = frameworks });
        module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
    }
    const chk = b.addObject(.{ .name = "nanolight-check", .root_module = module });
    b.step("check", "Type-check without linking").dependOn(&chk.step);
}

/// zig-out/Nanolight.app, installed with the program and as `zig build app`.
fn addAppBundle(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) void {
    const app = b.addInstallDirectory(.{
        .source_dir = bundle(b, exe, version),
        .install_dir = .prefix,
        .install_subdir = release.bundle_name,
    });
    b.getInstallStep().dependOn(&app.step);
    b.step("app", "Build zig-out/" ++ release.bundle_name).dependOn(&app.step);
}

const lint_scope = [_][]const u8{ "src", "tools", "build.zig" };

/// `zig build lint`: zig fmt's check, and the TigerStyle rules a machine
/// can check (tools/lint.zig, docs/TIGER_STYLE.md). Its own tests are in
/// tools/tests.zig.
fn addLint(b: *std.Build) void {
    const lint = b.addExecutable(.{ .name = "lint", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/lint.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const lint_run = b.addRunArtifact(lint);
    var fmt_paths: [lint_scope.len]std.Build.LazyPath = undefined;
    for (lint_scope, &fmt_paths) |entry, *fmt_path| {
        fmt_path.* = b.path(entry);
        if (std.mem.endsWith(u8, entry, ".zig")) {
            lint_run.addFileArg(fmt_path.*);
        } else {
            lint_run.addDirectoryArg(fmt_path.*);
        }
    }
    const lint_step = b.step("lint", "Check formatting and TigerStyle's mechanical rules");
    lint_step.dependOn(&b.addFmt(.{ .paths = &fmt_paths, .check = true }).step);
    lint_step.dependOn(&lint_run.step);
}

/// nanolight-server: the sync server (src/server.zig). Plain std, no nanoui.
fn addServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const server = b.addExecutable(.{ .name = "nanolight-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    if (optimize != .debug) server.root_module.strip = true;
    b.step("server", "Build the sync server (zig-out/bin/nanolight-server)")
        .dependOn(&b.addInstallArtifact(server, .{}).step);
}

/// Reads config.toml files as the app does (src/check_config.zig); the flake's
/// config-parse check runs it on what the Nix modules write.
fn addCheckConfig(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const check_config = b.addExecutable(.{
        .name = "nanolight-check-config",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/check_config.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "nanoui",
                .module = b.dependency("nanoui", .{
                    .target = target,
                    .optimize = optimize,
                }).module("nanoui"),
            }},
        }),
    });
    b.step("check-config", "Build zig-out/bin/nanolight-check-config")
        .dependOn(&b.addInstallArtifact(check_config, .{}).step);
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
        .name = release.program_name,
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
    const result = options.target.result;
    var asset: [release.name_bytes_max]u8 = undefined;
    const asset_name = release.updateAsset(result.os.tag, result.cpu.arch, &asset);
    build_options.addOption([]const u8, "asset", asset_name);
    build_options.addOption([]const u8, "repo", release.repo);
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
        .windows => for (windows_libraries) |library| module.linkSystemLibrary(library, .{}),
        // Linux: X11, GTK and gdk-pixbuf are opened at run time (dlopen).
        else => {},
    }
}

/// Nanolight as a Mac app: its program, its icon, and an Info.plist that
/// keeps it out of the Dock (a menu bar app).
fn bundle(b: *std.Build, exe: *std.Build.Step.Compile, version: []const u8) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.add(release.bundle_plist, infoPlist(b, version));
    _ = wf.addCopyFile(exe.getEmittedBin(), release.bundle_program);
    _ = wf.addCopyFile(b.path("macos/AppIcon.icns"), "Contents/Resources/AppIcon.icns");
    return wf.getDirectory();
}

/// The bundle's Info.plist, for `zig build app` and for the release's app
/// (`zig build package` signs this same bundle).
fn infoPlist(b: *std.Build, version: []const u8) []const u8 {
    return b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    ++
        \\ "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key><string>{[program]s}</string>
        \\  <key>CFBundleIdentifier</key><string>{[id]s}</string>
        \\  <key>CFBundleName</key><string>{[name]s}</string>
        \\  <key>CFBundleDisplayName</key><string>{[name]s}</string>
        \\  <key>CFBundleIconFile</key><string>AppIcon</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>{[version]s}</string>
        \\  <key>CFBundleVersion</key><string>{[version]s}</string>
        \\  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
        \\  <key>LSMinimumSystemVersion</key><string>{[macos_min]s}</string>
        \\  <key>LSUIElement</key><true/>
        \\  <key>NSPrincipalClass</key><string>NSApplication</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
        \\  <key>NSDesktopFolderUsageDescription</key><string>File Search lists the files and
    ++
        \\ folders in a folder you type.</string>
        \\  <key>NSDocumentsFolderUsageDescription</key><string>File Search lists the files and
    ++
        \\ folders in a folder you type.</string>
        \\  <key>NSDownloadsFolderUsageDescription</key><string>File Search lists the files and
    ++
        \\ folders in a folder you type.</string>
        \\  <key>NSRemovableVolumesUsageDescription</key><string>File Search lists the files and
    ++
        \\ folders in a folder you type.</string>
        \\  <key>NSNetworkVolumesUsageDescription</key><string>File Search lists the files and
    ++
        \\ folders in a folder you type.</string>
        \\</dict>
        \\</plist>
        \\
    , .{
        .program = release.program_name,
        .id = release.bundle_id,
        .name = release.app_name,
        .version = version,
        .macos_min = release.macos_min_text,
    });
}

// ----- releases: the packages, their checks, and the icon (tools/) -----

const ReleaseOptions = struct {
    /// `-Dversion`: required to package, since the version is compiled in.
    version: ?[]const u8,
    test_step: *std.Build.Step,
    on_mac: bool,
    /// `-Dmac-tools`: whether the Mac's tools are built (they link its SDK).
    mac_tools: bool,
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
    const availability: MacTool.Availability = if (!options.on_mac)
        .not_a_mac
    else if (!options.mac_tools)
        .left_out
    else
        .built;
    _ = addMacTool(b, .{
        .name = "verify-release",
        .root = "tools/verify_release.zig",
        .description = "Check a published release's files, notarization and first run (-- vX.Y.Z)",
        .availability = availability,
        .links = .nothing,
        .test_step = options.test_step,
    });
    _ = addMacTool(b, .{
        .name = "verify-update",
        .root = "tools/verify_update.zig",
        .description = "Launch a release for real and update to it (-- vOLD vNEW; CI only)",
        .availability = availability,
        .links = .screen,
        .test_step = options.test_step,
    });
    _ = addMacTool(b, .{
        .name = "verify-typing",
        .root = "tools/verify_typing.zig",
        .description = "Check the panel's query never goes back (-- [cycles]; CI only)",
        .availability = availability,
        .links = .screen,
        .test_step = options.test_step,
    });
    const icon = addMacTool(b, .{
        .name = "icon",
        .root = "tools/icon.zig",
        .description = "Redraw src/icon.png, src/icon-256.png and macos/AppIcon.icns",
        .availability = availability,
        .links = .libc,
        .test_step = options.test_step,
    });
    // It writes the icon's files in the source tree.
    if (icon) |run| run.setCwd(b.path("."));
}

/// A release tool's module: with the app's facts and its keys, which the
/// Mac's verifiers rely on (tools/mac_verify.zig), as `app_facts` and `keys`.
fn toolModule(b: *std.Build, root: []const u8) *std.Build.Module {
    return hostModule(b, root, &.{
        .{ .name = "app_facts", .module = hostModule(b, "src/app_facts.zig", &.{}) },
        .{ .name = "keys", .module = hostModule(b, "src/keys.zig", &.{}) },
    });
}

fn hostModule(
    b: *std.Build,
    root: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = imports,
    });
}

const MacTool = struct {
    name: []const u8,
    root: []const u8,
    description: []const u8,
    availability: Availability,
    links: Links,
    /// `zig build test` builds the tool, so that none rots between releases.
    test_step: *std.Build.Step,

    const Availability = enum { built, not_a_mac, left_out };

    const Links = enum {
        nothing,
        /// libc alone (icon.zig's erfc).
        libc,
        /// tools/screen.zig's window list: CoreGraphics and CoreFoundation.
        screen,
    };
};

/// A step that runs a tool of the Mac's (its arguments after `--`), or that
/// says why it can't.
fn addMacTool(b: *std.Build, tool: MacTool) ?*std.Build.Step.Run {
    const step = b.step(tool.name, tool.description);
    const missing = switch (tool.availability) {
        .built => null,
        .not_a_mac => "runs on a Mac",
        .left_out => "is left out of this build (-Dmac-tools=false)",
    };
    if (missing) |why| {
        step.dependOn(&b.addFail(b.fmt("zig build {s} {s}", .{ tool.name, why })).step);
        return null;
    }
    const module = toolModule(b, tool.root);
    switch (tool.links) {
        .nothing => {},
        .libc => module.link_libc = true,
        .screen => {
            module.link_libc = true;
            module.linkFramework("CoreFoundation", .{});
            module.linkFramework("CoreGraphics", .{});
        },
    }
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
    const version = options.version orelse {
        const message = "zig build package needs -Dversion=X.Y.Z: the version is compiled in";
        step.dependOn(&b.addFail(message).step);
        return;
    };
    const run = b.addRunArtifact(options.tool);
    run.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "package" } });
    run.addArgs(&.{ version, "--icon" });
    run.addFileArg(b.path("src/icon-256.png"));
    if (b.graph.host.result.os.tag == .macos) {
        // For the oldest macOS it supports and Apple silicon from the M1 on:
        // a native build would need the macOS and the CPU it was built on.
        const mac = addApp(b, releaseApp(b, version, .{
            .cpu_arch = .aarch64,
            .os_tag = .macos,
            .os_version_min = .{ .semver = release.macos_min },
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
