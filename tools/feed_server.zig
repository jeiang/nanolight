//! A local update feed for tools/verify_update.zig: one folder's files over
//! HTTP on 127.0.0.1, served on a task of its own until stopped, with the
//! request lines it answered kept for the verdict and for a failure's report.
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const log_bytes_max = 64 * 1024;
const request_line_bytes_max = 512;
/// The largest file served: an update zip is a few megabytes.
const file_bytes_max = 256 << 20;
const accept_pause_ms = 100;

pub const Options = struct {
    gpa: std.mem.Allocator,
    io: Io,
    folder: []const u8,
    port: u16,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    folder: Io.Dir,
    listener: Io.net.Server,
    task: Io.Future(void),
    /// Request lines, one per line. Only the serving task writes; it
    /// publishes how much it wrote through `log_len`, which readers load.
    log_bytes: [log_bytes_max]u8,
    log_len: std.atomic.Value(usize),
    /// Set before the task is canceled: a cancel that lands inside a
    /// connection's read ends that read, not the task, so the task looks here.
    stopping: std.atomic.Value(bool),

    /// Pinned: the serving task holds a pointer to it until `stop`.
    pub fn start(server: *Server, options: Options) !void {
        var address_buffer: [32]u8 = undefined;
        const address_text =
            try std.fmt.bufPrint(&address_buffer, "127.0.0.1:{d}", .{options.port});
        const address = try Io.net.IpAddress.parseLiteral(address_text);
        server.* = .{
            .gpa = options.gpa,
            .io = options.io,
            .folder = try Io.Dir.cwd().openDir(options.io, options.folder, .{}),
            .listener = undefined,
            .task = undefined,
            .log_bytes = undefined,
            .log_len = .init(0),
            .stopping = .init(false),
        };
        errdefer server.folder.close(options.io);
        server.listener = try address.listen(options.io, .{ .reuse_address = true });
        errdefer server.listener.deinit(options.io);
        server.task = try options.io.concurrent(serve, .{server});
    }

    pub fn stop(server: *Server) void {
        server.stopping.store(true, .release);
        server.task.cancel(server.io);
        server.listener.deinit(server.io);
        server.folder.close(server.io);
    }

    /// Every request line answered so far, as `<method> <path> <status>`.
    pub fn log(server: *Server) []const u8 {
        return server.log_bytes[0..server.log_len.load(.acquire)];
    }

    /// Whether a request line began with `request` (`GET /manifest.json`).
    pub fn asked(server: *Server, request: []const u8) bool {
        var lines = std.mem.splitScalar(u8, server.log(), '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, request)) return true;
        }
        return false;
    }

    fn record(server: *Server, line: []const u8) void {
        const len = server.log_len.load(.monotonic);
        // A full log keeps its first lines: the feed's few requests come first.
        if (len + line.len + 1 > server.log_bytes.len) return;
        @memcpy(server.log_bytes[len..][0..line.len], line);
        server.log_bytes[len + line.len] = '\n';
        server.log_len.store(len + line.len + 1, .release);
    }
};

/// Answers one connection at a time until stopped.
fn serve(server: *Server) void {
    while (!server.stopping.load(.acquire)) {
        const stream = server.listener.accept(server.io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                // A failed accept is retried after a pause, not in a spin.
                server.io.sleep(.fromMilliseconds(accept_pause_ms), .awake) catch return;
                continue;
            },
        };
        defer stream.close(server.io);
        // A client that hangs up or sends nonsense loses only its own request.
        answer(server, stream) catch continue;
    }
}

fn answer(server: *Server, stream: Io.net.Stream) !void {
    var in_buffer: [8192]u8 = undefined;
    var out_buffer: [8192]u8 = undefined;
    var reader = stream.reader(server.io, &in_buffer);
    var writer = stream.writer(server.io, &out_buffer);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = try http.receiveHead();
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const method = request.head.method;
    const body = if (method == .GET or method == .HEAD) read(server, path) else null;
    defer if (body) |bytes| server.gpa.free(bytes);
    const status: std.http.Status = if (body == null) .not_found else .ok;
    var line_buffer: [request_line_bytes_max]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buffer, "{t} {s} {d}", .{
        method, path, @backingInt(status),
    }) catch "(a request line too long to keep)";
    server.record(line);
    try request.respond(body orelse "", .{ .status = status, .keep_alive = false });
}

/// A file of the folder, by its name only: no folders, nothing above it.
fn read(server: *Server, path: []const u8) ?[]u8 {
    if (path.len < 2 or path[0] != '/') return null;
    const name = path[1..];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    if (std.mem.startsWith(u8, name, ".")) return null;
    return server.folder.readFileAlloc(server.io, name, server.gpa, .limited(file_bytes_max)) catch
        null;
}
