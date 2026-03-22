// ZIP read/write for Pencil2D .pclx files.
// Replaces vendored miniz with Zig's std.zip (reading) and a custom writer.

const std = @import("std");
const Io = std.Io;
const zip = std.zip;
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

// ── ZIP Writer ───────────────────────────────────────────────────────

pub const ZipWriter = struct {
    file: Io.File,
    entries: [256]CdEntry = undefined,
    entry_count: usize = 0,
    allocator: Allocator,
    offset: u64 = 0,
    io: Io,

    const CdEntry = struct {
        name: []const u8,
        crc32: u32,
        compressed_size: u32,
        uncompressed_size: u32,
        local_header_offset: u32,
        compression_method: u16,
    };

    pub fn init(allocator: Allocator, io: Io, path: []const u8) !ZipWriter {
        const cwd = Io.Dir.cwd();
        const file = try cwd.createFile(io, path, .{});
        return .{
            .file = file,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        for (0..self.entry_count) |i| {
            self.allocator.free(self.entries[i].name);
        }
        self.file.close(self.io);
    }

    /// Add a file from disk to the archive.
    pub fn addFile(self: *ZipWriter, archive_name: []const u8, src_path: []const u8, compress: bool) !void {
        const cwd = Io.Dir.cwd();
        var src_file = try cwd.openFile(self.io, src_path, .{});
        defer src_file.close(self.io);

        var read_buf: [8192]u8 = undefined;
        var reader = src_file.reader(self.io, &read_buf);
        const file_data = try reader.interface.allocRemaining(self.allocator, Io.Limit.unlimited);
        defer self.allocator.free(file_data);

        try self.addBytes(archive_name, file_data, compress);
    }

    /// Add raw bytes to the archive.
    pub fn addBytes(self: *ZipWriter, archive_name: []const u8, data: []const u8, compress: bool) !void {
        const crc = std.hash.Crc32.hash(data);
        const uncompressed_size: u32 = @intCast(data.len);

        var compressed_data: []const u8 = undefined;
        var compressed_owned = false;
        var method: u16 = 0; // store

        if (compress and data.len > 0) {
            // Allocate worst-case buffer for compressed output
            const max_compressed = data.len + 512; // deflate can expand slightly
            const compress_buf = try self.allocator.alloc(u8, max_compressed);
            defer self.allocator.free(compress_buf);

            var hist_buf: [flate.max_window_len]u8 = undefined;
            var any_writer: Io.Writer = .fixed(compress_buf);
            var compressor = try flate.Compress.init(&any_writer, &hist_buf, .raw, .fastest);
            try compressor.writer.writeAll(data);
            try compressor.finish();

            const written = max_compressed - any_writer.buffered().len;
            if (written < data.len) {
                const owned = try self.allocator.alloc(u8, written);
                @memcpy(owned, compress_buf[0..written]);
                compressed_data = owned;
                compressed_owned = true;
                method = 8; // deflate
            } else {
                compressed_data = data;
            }
        } else {
            compressed_data = data;
        }
        defer if (compressed_owned) self.allocator.free(compressed_data);

        const compressed_size: u32 = @intCast(compressed_data.len);
        const local_offset: u32 = @intCast(self.offset);

        // Write local file header
        var write_buf: [4096]u8 = undefined;
        var writer = self.file.writer(self.io, &write_buf);
        const w = &writer.interface;

        try w.writeAll(&zip.local_file_header_sig);
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, method, .little);
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, 0, .little); // mod date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, compressed_size, .little);
        try w.writeInt(u32, uncompressed_size, .little);
        try w.writeInt(u16, @intCast(archive_name.len), .little);
        try w.writeInt(u16, 0, .little); // extra len
        try w.writeAll(archive_name);
        try w.writeAll(compressed_data);
        try writer.flush();

        self.offset += 30 + archive_name.len + compressed_data.len;

        const name_copy = try self.allocator.dupe(u8, archive_name);
        self.entries[self.entry_count] = .{
            .name = name_copy,
            .crc32 = crc,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .local_header_offset = local_offset,
            .compression_method = method,
        };
        self.entry_count += 1;
    }

    /// Write the central directory and end record.
    pub fn finalize(self: *ZipWriter) !void {
        var write_buf: [4096]u8 = undefined;
        var writer = self.file.writer(self.io, &write_buf);
        const w = &writer.interface;
        const cd_offset: u32 = @intCast(self.offset);

        for (self.entries[0..self.entry_count]) |entry| {
            try w.writeAll(&zip.central_file_header_sig);
            try w.writeInt(u16, 20, .little); // version made by
            try w.writeInt(u16, 20, .little); // version needed
            try w.writeInt(u16, 0, .little); // flags
            try w.writeInt(u16, entry.compression_method, .little);
            try w.writeInt(u16, 0, .little); // mod time
            try w.writeInt(u16, 0, .little); // mod date
            try w.writeInt(u32, entry.crc32, .little);
            try w.writeInt(u32, entry.compressed_size, .little);
            try w.writeInt(u32, entry.uncompressed_size, .little);
            try w.writeInt(u16, @intCast(entry.name.len), .little);
            try w.writeInt(u16, 0, .little); // extra len
            try w.writeInt(u16, 0, .little); // comment len
            try w.writeInt(u16, 0, .little); // disk number
            try w.writeInt(u16, 0, .little); // internal attrs
            try w.writeInt(u32, 0, .little); // external attrs
            try w.writeInt(u32, entry.local_header_offset, .little);
            try w.writeAll(entry.name);
            self.offset += 46 + entry.name.len;
        }

        const cd_size: u32 = @intCast(self.offset - cd_offset);

        try w.writeAll(&zip.end_record_sig);
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // cd disk
        try w.writeInt(u16, @intCast(self.entry_count), .little);
        try w.writeInt(u16, @intCast(self.entry_count), .little);
        try w.writeInt(u32, cd_size, .little);
        try w.writeInt(u32, cd_offset, .little);
        try w.writeInt(u16, 0, .little); // comment len
        try writer.flush();
    }
};

// ── ZIP Reading / Extraction ─────────────────────────────────────────

pub fn extractZip(io: Io, zip_path: []const u8, dest_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, zip_path, .{});
    defer file.close(io);
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    const dest_dir = try cwd.openDir(io, dest_path, .{});
    try zip.extract(dest_dir, &reader, .{});
}

pub fn validateZip(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    _ = try zip.EndRecord.findFile(&reader);
}

// ── C ABI ────────────────────────────────────────────────────────────

const CZipWriter = opaque {};

fn getIo() Io {
    if (@import("builtin").is_test) {
        return std.testing.io;
    }
    // For non-test builds, use a thread-local Threaded Io instance
    const S = struct {
        threadlocal var instance: ?Io.Threaded = null;
        fn get() Io {
            if (instance) |*t| return t.io();
            instance = Io.Threaded.init(std.heap.page_allocator, .{});
            return instance.?.io();
        }
    };
    return S.get();
}

export fn zig_zip_writer_init(path: [*:0]const u8) ?*CZipWriter {
    const io = getIo();
    const allocator = std.heap.page_allocator;
    const writer = allocator.create(ZipWriter) catch return null;
    writer.* = ZipWriter.init(allocator, io, std.mem.sliceTo(path, 0)) catch {
        allocator.destroy(writer);
        return null;
    };
    return @ptrCast(writer);
}

export fn zig_zip_writer_add_file(handle: *CZipWriter, archive_name: [*:0]const u8, src_path: [*:0]const u8, compress: bool) c_int {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    writer.addFile(std.mem.sliceTo(archive_name, 0), std.mem.sliceTo(src_path, 0), compress) catch return -1;
    return 0;
}

export fn zig_zip_writer_add_bytes(handle: *CZipWriter, archive_name: [*:0]const u8, data: [*]const u8, len: usize, compress: bool) c_int {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    writer.addBytes(std.mem.sliceTo(archive_name, 0), data[0..len], compress) catch return -1;
    return 0;
}

export fn zig_zip_writer_finalize(handle: *CZipWriter) c_int {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    writer.finalize() catch return -1;
    return 0;
}

export fn zig_zip_writer_deinit(handle: *CZipWriter) void {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    writer.deinit();
    std.heap.page_allocator.destroy(writer);
}

export fn zig_zip_extract(zip_path: [*:0]const u8, dest_path: [*:0]const u8) c_int {
    const io = getIo();
    extractZip(io, std.mem.sliceTo(zip_path, 0), std.mem.sliceTo(dest_path, 0)) catch return -1;
    return 0;
}

export fn zig_zip_validate(zip_path: [*:0]const u8) c_int {
    const io = getIo();
    validateZip(io, std.mem.sliceTo(zip_path, 0)) catch return -1;
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────

test "roundtrip: write and read zip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const tmp_path = "zig-test-roundtrip.zip";

    // Write
    {
        var writer = try ZipWriter.init(allocator, io, tmp_path);
        defer writer.deinit();

        try writer.addBytes("hello.txt", "Hello, World!", true);
        try writer.addBytes("mimetype", "application/x-pencil2d", false);
        try writer.finalize();
    }

    // Validate
    try validateZip(io, tmp_path);

    // Read back - verify structure
    {
        const cwd = Io.Dir.cwd();
        var file = try cwd.openFile(io, tmp_path, .{});
        defer file.close(io);
        var read_buf: [8192]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const end = try zip.EndRecord.findFile(&reader);
        try std.testing.expectEqual(@as(u16, 2), end.record_count_total);
    }

    // Cleanup
    const cwd = Io.Dir.cwd();
    try cwd.deleteFile(io, tmp_path);
}

test "validate invalid file fails" {
    const io = std.testing.io;
    const result = validateZip(io, "nonexistent-file.zip");
    try std.testing.expectError(error.FileNotFound, result);
}
