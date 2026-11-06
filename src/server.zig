//! nanolight-server: keeps one settings record (settings.zig) per account
//! for the clients that sync to it (account.zig). The wire is
//! sync_protocol.zig, served by server_protocol.zig over server_transport.zig.
//!
//!   nanolight-server serve --listen 127.0.0.1:8890 --state /var/lib/nanolight \
//!       --tokens /path/tokens
//!   nanolight-server hash-token <token>
const std = @import("std");
const Io = std.Io;
const server = @import("server_protocol.zig");
const transport = @import("server_transport.zig");

/// The pause after a failed accept: its usual causes (no file descriptors or
/// memory left) last a while, and retrying at once would spin.
const accept_pause_ms = 100;
const hash_token_prefix = "ACCOUNT:";

const usage =
    \\usage: nanolight-server serve --listen 127.0.0.1:8890 --state DIR --tokens FILE
    \\       nanolight-server hash-token TOKEN
    \\
;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const cmd = args.next() orelse return fatal(usage);
    if (std.mem.eql(u8, cmd, "hash-token")) {
        const token = args.next() orelse return fatal(usage);
        var buf: [hash_token_prefix.len + @sizeOf(server.Digest) * 2 + 1]u8 = undefined;
        var w = Io.File.stdout().writer(init.io, &buf);
        const hex = std.fmt.bytesToHex(server.digestOf(token), .lower);
        try w.interface.print(hash_token_prefix ++ "{s}\n", .{hex});
        return w.interface.flush();
    }
    if (!std.mem.eql(u8, cmd, "serve")) return fatal(usage);

    var listen_arg: ?[]const u8 = null;
    var state_path: ?[]const u8 = null;
    var tokens_path: ?[]const u8 = null;
    while (args.next()) |a| {
        const slot = if (std.mem.eql(u8, a, "--listen"))
            &listen_arg
        else if (std.mem.eql(u8, a, "--state")) &state_path else if (std.mem.eql(
            u8,
            a,
            "--tokens",
        )) &tokens_path else return fatal(usage);
        const v = args.next() orelse return fatal(usage);
        slot.* = v;
    }
    const listen = listen_arg orelse "127.0.0.1:8890";
    const state_dir = state_path orelse return fatal(usage);
    const tokens_file = tokens_path orelse return fatal(usage);

    const text = Io.Dir.cwd()
        .readFileAlloc(init.io, tokens_file, init.arena.allocator(), .limited(1 << 20)) catch |e|
        return fatalf("nanolight-server: {s}: {t}\n", .{ tokens_file, e });
    var line: usize = 0;
    const tokens = server.parseTokens(init.arena.allocator(), text, &line) catch |e|
        return fatalf("nanolight-server: {s}:{d}: {t}\n", .{ tokens_file, line, e });
    if (tokens.len == 0) return fatalf("nanolight-server: {s} has no tokens\n", .{tokens_file});

    // Opened before any create: under systemd's DynamicUser the state
    // directory is a symlink, which createDirPath rejects as NotDir.
    const state = Io.Dir.cwd().openDir(init.io, state_dir, .{}) catch |e| switch (e) {
        error.FileNotFound => blk: {
            Io.Dir.cwd()
                .createDirPath(init.io, state_dir) catch |ce| return fatalf(
                "nanolight-server: {s}: {t}\n",
                .{ state_dir, ce },
            );
            break :blk Io.Dir.cwd()
                .openDir(init.io, state_dir, .{}) catch |oe| return fatalf(
                "nanolight-server: {s}: {t}\n",
                .{ state_dir, oe },
            );
        },
        else => return fatalf("nanolight-server: {s}: {t}\n", .{ state_dir, e }),
    };
    const addr = Io.net.IpAddress.parseLiteral(listen) catch return fatalf(
        "nanolight-server: bad --listen {s}\n",
        .{listen},
    );
    var listener = try addr.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    std.log.info("listening on {s}, {d} account(s)", .{ listen, tokens.len });
    while (true) {
        const stream = listener.accept(init.io) catch |e| {
            std.log.warn("accept: {t}", .{e});
            try init.io.sleep(.fromMilliseconds(accept_pause_ms), .awake);
            continue;
        };
        defer stream.close(init.io);
        transport.serveOne(init.gpa, init.io, stream, .{ .state = state, .tokens = tokens });
    }
}

fn fatal(msg: []const u8) error{Usage} {
    std.log.err("{s}", .{msg});
    return error.Usage;
}

fn fatalf(comptime fmt: []const u8, args: anytype) error{Usage} {
    std.log.err(fmt, args);
    return error.Usage;
}
