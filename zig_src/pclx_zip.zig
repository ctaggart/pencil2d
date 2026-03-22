// ZIP read/write for Pencil2D .pclx files.
// All operations work on memory buffers — no file I/O or Io runtime needed.
// C++ handles file read/write via QFile; Zig handles zip format + compression.

const std = @import("std");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const zip = std.zip;
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

// ── ZIP Writer (memory-backed) ──────────────────────────────────────

pub const ZipWriter = struct {
    aw: Writer.Allocating,
    entries: [256]CdEntry = undefined,
    entry_count: usize = 0,
    allocator: Allocator,
    offset: u64 = 0,

    const CdEntry = struct {
        name: []const u8,
        crc32: u32,
        compressed_size: u32,
        uncompressed_size: u32,
        local_header_offset: u32,
        compression_method: u16,
    };

    pub fn init(allocator: Allocator) ZipWriter {
        return .{
            .aw = Writer.Allocating.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZipWriter) void {
        for (0..self.entry_count) |i| {
            self.allocator.free(self.entries[i].name);
        }
        self.aw.deinit();
    }

    /// Add raw bytes to the archive.
    pub fn addBytes(self: *ZipWriter, archive_name: []const u8, data: []const u8, compress: bool) !void {
        const crc = std.hash.Crc32.hash(data);
        const uncompressed_size: u32 = @intCast(data.len);

        var compressed_data: []const u8 = undefined;
        var compressed_owned = false;
        var method: u16 = 0; // store

        if (compress and data.len > 0) {
            const max_compressed = data.len + 512;
            const compress_buf = try self.allocator.alloc(u8, max_compressed);
            defer self.allocator.free(compress_buf);

            var hist_buf: [flate.max_window_len]u8 = undefined;
            var any_writer: Writer = .fixed(compress_buf);
            var compressor = try flate.Compress.init(&any_writer, &hist_buf, .raw, .fastest);
            try compressor.writer.writeAll(data);
            try compressor.finish();

            const compressed_len = max_compressed - any_writer.buffered().len;
            if (compressed_len < data.len) {
                const owned = try self.allocator.alloc(u8, compressed_len);
                @memcpy(owned, compress_buf[0..compressed_len]);
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
        const w = &self.aw.writer;

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
        const w = &self.aw.writer;
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
    }

    /// Returns the complete zip archive data.
    pub fn written(self: *ZipWriter) []const u8 {
        return self.aw.written();
    }
};

// ── ZIP Reader (memory-backed) ──────────────────────────────────────

pub const ZipReader = struct {
    data: []const u8,
    entries: []Entry,
    allocator: Allocator,

    pub const Entry = struct {
        name: []const u8,
        compression_method: u16,
        crc32: u32,
        compressed_size: u32,
        uncompressed_size: u32,
        local_header_offset: u32,
    };

    pub fn init(allocator: Allocator, data: []const u8) !ZipReader {
        if (data.len < 22) return error.InvalidZip;

        // Find End of Central Directory record (search backwards)
        const eocd_pos = findEocd(data) orelse return error.InvalidZip;

        const record_count = readU16(data, eocd_pos + 10);
        const cd_offset: usize = readU32(data, eocd_pos + 16);

        // Parse central directory entries
        const entries = try allocator.alloc(Entry, record_count);
        errdefer allocator.free(entries);

        var pos = cd_offset;
        for (0..record_count) |idx| {
            if (pos + 46 > data.len) {
                allocator.free(entries);
                return error.InvalidZip;
            }
            if (!std.mem.eql(u8, data[pos..][0..4], &zip.central_file_header_sig)) {
                allocator.free(entries);
                return error.InvalidZip;
            }

            const name_len: usize = readU16(data, pos + 28);
            const extra_len: usize = readU16(data, pos + 30);
            const comment_len: usize = readU16(data, pos + 32);

            if (pos + 46 + name_len > data.len) {
                allocator.free(entries);
                return error.InvalidZip;
            }

            entries[idx] = .{
                .name = data[pos + 46 ..][0..name_len],
                .compression_method = readU16(data, pos + 10),
                .crc32 = readU32(data, pos + 16),
                .compressed_size = readU32(data, pos + 20),
                .uncompressed_size = readU32(data, pos + 24),
                .local_header_offset = readU32(data, pos + 42),
            };

            pos += 46 + name_len + extra_len + comment_len;
        }

        return .{
            .data = data,
            .entries = entries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZipReader) void {
        self.allocator.free(self.entries);
    }

    pub fn count(self: *const ZipReader) usize {
        return self.entries.len;
    }

    pub fn entryName(self: *const ZipReader, index: usize) ?[]const u8 {
        if (index >= self.entries.len) return null;
        return self.entries[index].name;
    }

    pub fn entryIsDir(self: *const ZipReader, index: usize) bool {
        if (index >= self.entries.len) return false;
        const name = self.entries[index].name;
        return name.len > 0 and name[name.len - 1] == '/';
    }

    /// Extract a single entry, returning the decompressed data.
    pub fn extract(self: *const ZipReader, index: usize, allocator: Allocator) ![]u8 {
        if (index >= self.entries.len) return error.InvalidZip;
        const entry = self.entries[index];

        // Parse local file header to find data start
        const lh: usize = entry.local_header_offset;
        if (lh + 30 > self.data.len) return error.InvalidZip;
        if (!std.mem.eql(u8, self.data[lh..][0..4], &zip.local_file_header_sig))
            return error.InvalidZip;

        const local_name_len: usize = readU16(self.data, lh + 26);
        const local_extra_len: usize = readU16(self.data, lh + 28);
        const data_start = lh + 30 + local_name_len + local_extra_len;
        const data_end = data_start + entry.compressed_size;

        if (data_end > self.data.len) return error.InvalidZip;
        const compressed = self.data[data_start..data_end];

        if (entry.compression_method == 0) {
            // Stored — just copy
            const result = try allocator.alloc(u8, entry.uncompressed_size);
            @memcpy(result, compressed);
            return result;
        } else if (entry.compression_method == 8) {
            // Deflate — decompress using flate
            var reader: Reader = .fixed(compressed);
            var aw: Writer.Allocating = .init(allocator);
            errdefer aw.deinit();
            var decompress: flate.Decompress = .init(&reader, .raw, &.{});
            _ = try decompress.reader.streamRemaining(&aw.writer);
            return try aw.toOwnedSlice();
        } else {
            return error.InvalidZip;
        }
    }

    fn findEocd(data: []const u8) ?usize {
        if (data.len < 22) return null;
        var pos: usize = data.len - 22;
        while (true) {
            if (std.mem.eql(u8, data[pos..][0..4], &zip.end_record_sig)) return pos;
            if (pos == 0) break;
            pos -= 1;
            if (data.len - pos > 22 + 65535) break;
        }
        return null;
    }
};

/// Validate that data contains a valid ZIP archive.
pub fn validate(data: []const u8) !void {
    if (ZipReader.findEocd(data) == null) return error.InvalidZip;
}

fn readU16(data: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU32(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

// ── C ABI ────────────────────────────────────────────────────────────

const CZipWriter = opaque {};
const CZipReader = opaque {};

export fn zig_zip_writer_create() ?*CZipWriter {
    const allocator = std.heap.page_allocator;
    const writer = allocator.create(ZipWriter) catch return null;
    writer.* = ZipWriter.init(allocator);
    return @ptrCast(writer);
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

export fn zig_zip_writer_get_data(handle: *CZipWriter, out_data: *[*]const u8, out_len: *usize) c_int {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    const data = writer.written();
    out_data.* = data.ptr;
    out_len.* = data.len;
    return 0;
}

export fn zig_zip_writer_destroy(handle: *CZipWriter) void {
    const writer: *ZipWriter = @ptrCast(@alignCast(handle));
    writer.deinit();
    std.heap.page_allocator.destroy(writer);
}

export fn zig_zip_reader_open(data: [*]const u8, len: usize) ?*CZipReader {
    const allocator = std.heap.page_allocator;
    const reader = allocator.create(ZipReader) catch return null;
    reader.* = ZipReader.init(allocator, data[0..len]) catch {
        allocator.destroy(reader);
        return null;
    };
    return @ptrCast(reader);
}

export fn zig_zip_reader_count(handle: *CZipReader) c_int {
    const reader: *ZipReader = @ptrCast(@alignCast(handle));
    return @intCast(reader.count());
}

export fn zig_zip_reader_entry_name(handle: *CZipReader, index: c_int, out_name: *[*]const u8, out_len: *usize) c_int {
    const reader: *ZipReader = @ptrCast(@alignCast(handle));
    const name = reader.entryName(@intCast(index)) orelse return -1;
    out_name.* = name.ptr;
    out_len.* = name.len;
    return 0;
}

export fn zig_zip_reader_entry_is_dir(handle: *CZipReader, index: c_int) c_int {
    const reader: *ZipReader = @ptrCast(@alignCast(handle));
    return if (reader.entryIsDir(@intCast(index))) @as(c_int, 1) else @as(c_int, 0);
}

export fn zig_zip_reader_extract(handle: *CZipReader, index: c_int, out_data: *[*]u8, out_len: *usize) c_int {
    const reader: *ZipReader = @ptrCast(@alignCast(handle));
    const data = reader.extract(@intCast(index), std.heap.page_allocator) catch return -1;
    out_data.* = data.ptr;
    out_len.* = data.len;
    return 0;
}

export fn zig_zip_reader_destroy(handle: *CZipReader) void {
    const reader: *ZipReader = @ptrCast(@alignCast(handle));
    reader.deinit();
    std.heap.page_allocator.destroy(reader);
}

export fn zig_zip_validate(data: [*]const u8, len: usize) c_int {
    validate(data[0..len]) catch return -1;
    return 0;
}

export fn zig_free(ptr: [*]u8, len: usize) void {
    std.heap.page_allocator.free(ptr[0..len]);
}

// ── Tests ────────────────────────────────────────────────────────────

test "roundtrip: write and read zip" {
    const allocator = std.testing.allocator;

    // Write
    var writer = ZipWriter.init(allocator);
    defer writer.deinit();

    try writer.addBytes("hello.txt", "Hello, World!", true);
    try writer.addBytes("mimetype", "application/x-pencil2d", false);
    try writer.finalize();

    const zip_data = writer.written();

    // Validate
    try validate(zip_data);

    // Read back
    var reader = try ZipReader.init(allocator, zip_data);
    defer reader.deinit();

    try std.testing.expectEqual(@as(usize, 2), reader.count());
    try std.testing.expectEqualStrings("hello.txt", reader.entryName(0).?);
    try std.testing.expectEqualStrings("mimetype", reader.entryName(1).?);

    // Extract and verify content
    {
        const content = try reader.extract(0, allocator);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("Hello, World!", content);
    }
    {
        const content = try reader.extract(1, allocator);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("application/x-pencil2d", content);
    }
}

test "validate invalid data fails" {
    try std.testing.expectError(error.InvalidZip, validate("not a zip file"));
}

test "validate empty data fails" {
    try std.testing.expectError(error.InvalidZip, validate(""));
}
