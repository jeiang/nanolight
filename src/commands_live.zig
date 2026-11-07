//! The running app's side of system commands (commands.zig): a command's
//! row runs it, a failure is said in the footer, success hides the panel.
const std = @import("std");
const commands = @import("commands.zig");
const view = @import("view.zig");
const App = @import("app.zig").App;

pub const Commands = struct {
    core: *App,
    runner: commands.Runner,

    /// The commands this machine can run (on `PATH`), and their runner.
    pub fn init(core: *App, env: *const std.process.Environ.Map) Commands {
        return .{
            .core = core,
            .runner = .{
                .io = core.app.io,
                .hooks = .{ .ctx = core, .footer = App.footer, .done = App.hide },
                .installed = commands.installed(core.app.io, env),
            },
        };
    }

    pub fn deinit(cm: *Commands) void {
        cm.runner.deinit();
    }

    /// What the panel runs a command with, and lists the commands of.
    pub fn entry(cm: *Commands) view.Host.Run {
        return .{ .ctx = cm, .func = run, .installed = &cm.runner.installed };
    }

    fn run(ctx: *anyopaque, i: usize) void {
        const cm: *Commands = @ptrCast(@alignCast(ctx));
        cm.core.s.note = "";
        cm.runner.start(i);
    }
};
