// PNG support via zpix library (ctaggart/zpix).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpix = @import("zpix");

pub const Image = zpix.Image;

/// Encode RGBA pixel data to PNG bytes.
pub fn encode(allocator: Allocator, pixels: []const u8, width: u32, height: u32) ![]u8 {
    const img = Image{
        .width = width,
        .height = height,
        .channels = 4,
        .data = @constCast(pixels),
        .allocator = allocator,
    };
    return zpix.savePngMemory(allocator, &img);
}

/// Decode PNG bytes to an Image.
pub fn decode(allocator: Allocator, png_data: []const u8) !Image {
    return zpix.loadPngMemory(allocator, png_data);
}

// ── Tests ────────────────────────────────────────────────────────────

test "encode 1x1 red pixel" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 255, 0, 0, 255 };
    const png_data = try encode(allocator, &pixels, 1, 1);
    defer allocator.free(png_data);

    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A }, png_data[0..8]);
    try std.testing.expect(png_data.len > 50);
}

test "encode and decode roundtrip" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const png_data = try encode(allocator, &pixels, 2, 2);
    defer allocator.free(png_data);

    var img = try decode(allocator, png_data);
    defer img.deinit();

    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    try std.testing.expectEqual(@as(u8, 255), img.data[0]); // red
    try std.testing.expectEqual(@as(u8, 0), img.data[1]);
}
