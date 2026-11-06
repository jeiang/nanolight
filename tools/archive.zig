//! The archives a release carries, written and read in Zig: Windows' zip and
//! Linux's tar.gz. The updater unpacks either with the system's `tar`
//! (nanoui's update_portable.zig), so both are the plain kinds every `tar`
//! reads: deflate in a zip without zip64, ustar under gzip.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;
const zip = std.zip;
const Io = std.Io;

/// The most entries one archive holds: a folder and three files today.
pub const entries_max = 8;
pub const entry_name_bytes_max = 256;
/// A zip without zip64 counts its sizes and offsets in 32 bits.
const zip_bytes_max = std.math.maxInt(u32);
/// "Made by" Unix (3), to version 2.0 of the format; 2.0 is needed for deflate.
const zip_made_by: u16 = (3 << 8) | 20;
const zip_version_needed: u16 = 20;
const unix_file_type: u32 = 0o100000;
const unix_folder_type: u32 = 0o040000;
const dos_folder_attribute: u32 = 0x10;

pub const Format = enum { zip, tar_gz };

pub const Entry = struct {
    /// Its path inside, `/`-separated. A folder's ends in `/`.
    name: []const u8,
    /// A file's bytes. A folder has none.
    data: []const u8 = "",
    /// Its Unix permissions: 0o755 for a program or a folder, 0o644 otherwise.
    mode: u32,

    fn isFolder(entry: Entry) bool {
        return std.mem.endsWith(u8, entry.name, "/");
    }
};

/// Writes `entries` as one archive, each dated `mtime_s` (seconds since the
/// epoch, UTC), as `zip` and `tar` date the files they are given.
pub fn write(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    format: Format,
    entries: []const Entry,
    mtime_s: u64,
) !void {
    assert(entries.len > 0);
    assert(entries.len <= entries_max);
    for (entries) |entry| {
        assert(entry.name.len > 0 and entry.name.len <= entry_name_bytes_max);
        assert(!entry.isFolder() or entry.data.len == 0);
    }
    switch (format) {
        .zip => try writeZip(gpa, writer, entries, mtime_s),
        .tar_gz => try writeTarGz(gpa, writer, entries, mtime_s),
    }
}

const ZipRecord = struct {
    method: zip.CompressionMethod,
    crc32: u32,
    compressed_bytes: u32,
    bytes: u32,
    offset: u32,
};

fn writeZip(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    entries: []const Entry,
    mtime_s: u64,
) !void {
    const time = DosTime.fromEpoch(mtime_s);
    var records: [entries_max]ZipRecord = undefined;
    var offset: u64 = 0;
    for (entries, records[0..entries.len]) |entry, *record| {
        if (entry.data.len > zip_bytes_max) return error.ZipTooLarge;
        const deflated = try deflate(gpa, entry.data);
        defer gpa.free(deflated);
        // As zip does: a file that deflate can't shrink is stored.
        const stored = deflated.len >= entry.data.len;
        const body = if (stored) entry.data else deflated;
        if (offset > zip_bytes_max) return error.ZipTooLarge;
        record.* = .{
            .method = if (stored) .store else .deflate,
            .crc32 = std.hash.Crc32.hash(entry.data),
            .compressed_bytes = @intCast(body.len),
            .bytes = @intCast(entry.data.len),
            .offset = @intCast(offset),
        };
        try writer.writeStruct(zip.LocalFileHeader{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = zip_version_needed,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = record.method,
            .last_modification_time = time.time,
            .last_modification_date = time.date,
            .crc32 = record.crc32,
            .compressed_size = record.compressed_bytes,
            .uncompressed_size = record.bytes,
            .filename_len = @intCast(entry.name.len),
            .extra_len = 0,
        }, .little);
        try writer.writeAll(entry.name);
        try writer.writeAll(body);
        offset += @sizeOf(zip.LocalFileHeader) + entry.name.len + body.len;
    }
    try writeZipDirectory(writer, entries, records[0..entries.len], .{
        .time = time,
        .offset = offset,
    });
}

const ZipDirectoryOptions = struct {
    time: DosTime,
    /// Where the directory starts: the bytes of every entry before it.
    offset: u64,
};

fn writeZipDirectory(
    writer: *Io.Writer,
    entries: []const Entry,
    records: []const ZipRecord,
    options: ZipDirectoryOptions,
) !void {
    assert(entries.len == records.len);
    var directory_bytes: u64 = 0;
    for (entries, records) |entry, record| {
        const folder = entry.isFolder();
        const unix_type = if (folder) unix_folder_type else unix_file_type;
        const dos_attributes = if (folder) dos_folder_attribute else 0;
        try writer.writeStruct(zip.CentralDirectoryFileHeader{
            .signature = zip.central_file_header_sig,
            .version_made_by = zip_made_by,
            .version_needed_to_extract = zip_version_needed,
            .flags = @bitCast(@as(u16, 0)),
            .compression_method = record.method,
            .last_modification_time = options.time.time,
            .last_modification_date = options.time.date,
            .crc32 = record.crc32,
            .compressed_size = record.compressed_bytes,
            .uncompressed_size = record.bytes,
            .filename_len = @intCast(entry.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = ((unix_type | entry.mode) << 16) | dos_attributes,
            .local_file_header_offset = record.offset,
        }, .little);
        try writer.writeAll(entry.name);
        directory_bytes += @sizeOf(zip.CentralDirectoryFileHeader) + entry.name.len;
    }
    if (options.offset + directory_bytes > zip_bytes_max) return error.ZipTooLarge;
    try writer.writeStruct(zip.EndRecord{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = @intCast(entries.len),
        .record_count_total = @intCast(entries.len),
        .central_directory_size = @intCast(directory_bytes),
        .central_directory_offset = @intCast(options.offset),
        .comment_len = 0,
    }, .little);
}

/// Raw deflate at zip's and gzip's best, into memory the caller frees.
fn deflate(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    try compress(gpa, &out.writer, .raw, data);
    return out.toOwnedSlice();
}

/// Compresses `data` onto `writer` in `container`'s framing.
fn compress(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    container: flate.Container,
    data: []const u8,
) !void {
    // The compressor's tables are a quarter megabyte: on the heap, not the stack.
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    // The compressor writes through its output's buffer, of at least 8 bytes.
    try writer.ensureUnusedCapacity(64);
    compressor.* = try .init(writer, window, container, .best);
    try compressor.writer.writeAll(data);
    try compressor.finish();
}

fn writeTarGz(
    gpa: std.mem.Allocator,
    writer: *Io.Writer,
    entries: []const Entry,
    mtime_s: u64,
) !void {
    var tar_bytes: Io.Writer.Allocating = .init(gpa);
    defer tar_bytes.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
    for (entries) |entry| {
        const options: std.tar.Writer.Options = .{ .mode = entry.mode, .mtime = mtime_s };
        if (entry.isFolder()) {
            try tar.writeDir(entry.name[0 .. entry.name.len - 1], options);
        } else {
            try tar.writeFileBytes(entry.name, entry.data, options);
        }
    }
    try tar.finishPedantically();
    try compress(gpa, writer, .gzip, tar_bytes.written());
}

/// MS-DOS's date and time, which a zip entry carries: two-second steps from 1980.
const DosTime = struct {
    time: u16,
    date: u16,

    fn fromEpoch(seconds: u64) DosTime {
        const dos_epoch_s = 315532800; // 1980-01-01T00:00:00Z
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @max(seconds, dos_epoch_s) };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        assert(year_day.year >= 1980);
        const year: u16 = @min(year_day.year - 1980, 127);
        return .{
            .date = (year << 9) | (@as(u16, month_day.month.numeric()) << 5) |
                (@as(u16, month_day.day_index) + 1),
            .time = (@as(u16, day_seconds.getHoursIntoDay()) << 11) |
                (@as(u16, day_seconds.getMinutesIntoHour()) << 5) |
                (@as(u16, day_seconds.getSecondsIntoMinute()) / 2),
        };
    }
};

/// Whether the archive at `path` holds a file at `wanted` (its path inside).
pub fn holds(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    format: Format,
    wanted: []const u8,
) !bool {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var name_buffer: [entry_name_bytes_max]u8 = undefined;
    switch (format) {
        .zip => {
            var entries = try zip.Iterator.init(&reader);
            while (try entries.next()) |entry| {
                if (entry.filename_len > name_buffer.len) continue;
                const name = try entry.getFilename(&reader, &name_buffer, .{});
                if (std.mem.eql(u8, name, wanted)) return true;
            }
        },
        .tar_gz => {
            var window: [flate.max_window_len]u8 = undefined;
            var decompress: flate.Decompress = .init(&reader.interface, .gzip, &window);
            var link_buffer: [entry_name_bytes_max]u8 = undefined;
            var entries: std.tar.Iterator = .init(&decompress.reader, .{
                .file_name_buffer = &name_buffer,
                .link_name_buffer = &link_buffer,
            });
            while (try entries.next()) |entry| {
                if (entry.kind == .file and std.mem.eql(u8, entry.name, wanted)) return true;
            }
        },
    }
    return false;
}

// ----- tests -----

const testing = std.testing;

/// Text that deflate shrinks, so that a sample holds both of zip's methods.
const compressible: [4096]u8 = @splat('a');

const sample = [_]Entry{
    .{ .name = "nanolight-1.2.3-linux-x86_64/", .mode = 0o755 },
    .{ .name = "nanolight-1.2.3-linux-x86_64/nanolight", .data = "\x7fELF program", .mode = 0o755 },
    .{ .name = "nanolight-1.2.3-linux-x86_64/notes.txt", .data = &compressible, .mode = 0o644 },
};

fn writeSample(dir: Io.Dir, name: []const u8, format: Format) !void {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, format, &sample, 1_700_000_000);
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = out.written() });
}

test "a zip holds what it was given, and its files come out whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSample(tmp.dir, "a.zip", .zip);
    try testing.expect(try holds(testing.io, tmp.dir, "a.zip", .zip, sample[1].name));
    try testing.expect(!try holds(testing.io, tmp.dir, "a.zip", .zip, "nanolight"));

    const file = try tmp.dir.openFile(testing.io, "a.zip", .{});
    defer file.close(testing.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);
    var entries = try zip.Iterator.init(&reader);
    var count: usize = 0;
    while (try entries.next()) |entry| : (count += 1) {
        var out: Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try entry.extractTo(&reader, &out.writer);
        try testing.expectEqualStrings(sample[count].data, out.written());
    }
    try testing.expectEqual(sample.len, count);
}

test "a tar.gz holds what it was given, with each one's mode" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSample(tmp.dir, "a.tar.gz", .tar_gz);
    try testing.expect(try holds(testing.io, tmp.dir, "a.tar.gz", .tar_gz, sample[2].name));
    try testing.expect(!try holds(testing.io, tmp.dir, "a.tar.gz", .tar_gz, sample[0].name));

    const file = try tmp.dir.openFile(testing.io, "a.tar.gz", .{});
    defer file.close(testing.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&reader.interface, .gzip, &window);
    var name_buffer: [entry_name_bytes_max]u8 = undefined;
    var link_buffer: [entry_name_bytes_max]u8 = undefined;
    var entries: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    const folder = (try entries.next()).?;
    try testing.expectEqual(std.tar.FileKind.directory, folder.kind);
    const program = (try entries.next()).?;
    try testing.expectEqual(@as(u32, 0o755), program.mode);
    try testing.expectEqual(@as(u64, sample[1].data.len), program.size);
}

test "a zip entry's date is the packaging moment, in MS-DOS's steps" {
    // 2023-11-14T22:13:20Z
    const time = DosTime.fromEpoch(1_700_000_000);
    try testing.expectEqual(@as(u16, ((2023 - 1980) << 9) | (11 << 5) | 14), time.date);
    try testing.expectEqual(@as(u16, (22 << 11) | (13 << 5) | 10), time.time);
    // Before 1980, which MS-DOS can't say: its first moment.
    try testing.expectEqual(@as(u16, (1 << 5) | 1), DosTime.fromEpoch(0).date);
}
