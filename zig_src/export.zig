// Export — render and save animation frames as PNG files.
// Pure Zig implementation using zpix for PNG encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const png_mod = @import("png.zig");
const Object = @import("object.zig").Object;
const Layer = @import("layer.zig").Layer;
const LayerType = @import("layer.zig").LayerType;
const BitmapData = @import("keyframe.zig").BitmapData;

/// Export a single bitmap frame to a PNG file.
pub fn exportFramePng(
    allocator: Allocator,
    obj: *const Object,
    layer_index: usize,
    frame: i32,
    io: Io,
) ![]u8 {
    const layer = obj.getLayer(layer_index) orelse return error.InvalidLayer;
    if (layer.layer_type != .bitmap) return error.NotBitmapLayer;

    // Find the keyframe at or before this frame
    const kf = layer.getLastKeyFrameAtPosition(frame) orelse return error.NoKeyframe;
    if (kf.data != .bitmap) return error.NotBitmapData;
    const bmp = kf.data.bitmap;
    if (bmp.pixels == null or bmp.width == 0 or bmp.height == 0) return error.EmptyFrame;

    _ = io;
    return png_mod.encode(allocator, bmp.pixels.?, bmp.width, bmp.height);
}

/// Export a range of frames as numbered PNG files.
/// Returns the number of frames exported.
pub fn exportFrameSequence(
    allocator: Allocator,
    obj: *const Object,
    layer_index: usize,
    start_frame: i32,
    end_frame: i32,
    output_dir: []const u8,
    prefix: []const u8,
    io: Io,
) !i32 {
    const layer = obj.getLayer(layer_index) orelse return error.InvalidLayer;
    if (layer.layer_type != .bitmap) return error.NotBitmapLayer;

    const dir = Io.Dir.cwd(io);
    var count: i32 = 0;
    var frame = start_frame;

    while (frame <= end_frame) : (frame += 1) {
        const kf = layer.getLastKeyFrameAtPosition(frame) orelse continue;
        if (kf.data != .bitmap) continue;
        const bmp = kf.data.bitmap;
        if (bmp.pixels == null or bmp.width == 0 or bmp.height == 0) continue;

        const png_data = png_mod.encode(allocator, bmp.pixels.?, bmp.width, bmp.height) catch continue;
        defer allocator.free(png_data);

        // Build filename: {output_dir}/{prefix}{frame:04}.png
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}{d:0>4}.png", .{ output_dir, prefix, frame }) catch continue;

        // Write file
        const file = dir.createFile(path, .{}) catch continue;
        file.writeAll(io, png_data) catch {
            file.close(io);
            continue;
        };
        file.close(io);
        count += 1;
    }

    return count;
}

/// Generate a spritesheet from frame range.
/// Returns a single BitmapData with all frames arranged in a grid.
pub fn exportSpritesheet(
    allocator: Allocator,
    obj: *const Object,
    layer_index: usize,
    start_frame: i32,
    end_frame: i32,
    cols: u32,
) !BitmapData {
    const layer = obj.getLayer(layer_index) orelse return error.InvalidLayer;
    if (layer.layer_type != .bitmap) return error.NotBitmapLayer;

    // Find max frame dimensions
    var max_w: u32 = 1;
    var max_h: u32 = 1;
    var frame_count: u32 = 0;
    {
        var f = start_frame;
        while (f <= end_frame) : (f += 1) {
            const kf = layer.getLastKeyFrameAtPosition(f) orelse continue;
            if (kf.data != .bitmap) continue;
            const bmp = kf.data.bitmap;
            if (bmp.width > max_w) max_w = bmp.width;
            if (bmp.height > max_h) max_h = bmp.height;
            frame_count += 1;
        }
    }
    if (frame_count == 0) return error.EmptyFrame;

    const actual_cols = @min(cols, frame_count);
    const rows = (frame_count + actual_cols - 1) / actual_cols;
    const sheet_w = actual_cols * max_w;
    const sheet_h = rows * max_h;

    var sheet = try BitmapData.create(allocator, sheet_w, sheet_h, 0, 0);

    // Blit each frame into the sheet
    var idx: u32 = 0;
    var f = start_frame;
    while (f <= end_frame) : (f += 1) {
        const kf = layer.getLastKeyFrameAtPosition(f) orelse continue;
        if (kf.data != .bitmap) continue;
        const bmp = kf.data.bitmap;
        if (bmp.pixels == null or bmp.width == 0) continue;

        const col = idx % actual_cols;
        const row = idx / actual_cols;
        const dst_x: i32 = @intCast(col * max_w);
        const dst_y: i32 = @intCast(row * max_h);

        // Copy pixels
        var py: u32 = 0;
        while (py < bmp.height) : (py += 1) {
            var px: u32 = 0;
            while (px < bmp.width) : (px += 1) {
                const src_idx = (py * bmp.width + px) * 4;
                const pixel: [4]u8 = bmp.pixels.?[src_idx..][0..4].*;
                if (pixel[3] > 0) { // only copy non-transparent
                    sheet.setPixel(dst_x + @as(i32, @intCast(px)), dst_y + @as(i32, @intCast(py)), pixel);
                }
            }
        }
        idx += 1;
    }

    return sheet;
}

// ── Tests ────────────────────────────────────────────────────────────

test "exportFramePng single frame" {
    const allocator = std.testing.allocator;
    const Object2 = @import("object.zig").Object;

    var obj = Object2.init(allocator);
    defer obj.deinit();

    const layer = try obj.addNewLayer(.bitmap, "Art");
    var bmp = try BitmapData.create(allocator, 4, 4, 0, 0);
    bmp.drawRect(0, 0, 4, 4, .{ 255, 0, 0, 255 });
    _ = try layer.addKeyFrame(1, .{ .pos = 1, .data = .{ .bitmap = bmp } });

    const png_data = try exportFramePng(allocator, &obj, 0, 1, undefined);
    defer allocator.free(png_data);

    // Verify PNG header
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 0x50, 0x4E, 0x47 }, png_data[0..4]);
}

test "exportSpritesheet 2 frames" {
    const allocator = std.testing.allocator;
    const Object2 = @import("object.zig").Object;

    var obj = Object2.init(allocator);
    defer obj.deinit();

    const layer = try obj.addNewLayer(.bitmap, "Frames");

    // Frame 1: red
    var bmp1 = try BitmapData.create(allocator, 4, 4, 0, 0);
    bmp1.drawRect(0, 0, 4, 4, .{ 255, 0, 0, 255 });
    _ = try layer.addKeyFrame(1, .{ .pos = 1, .data = .{ .bitmap = bmp1 } });

    // Frame 2: blue
    var bmp2 = try BitmapData.create(allocator, 4, 4, 0, 0);
    bmp2.drawRect(0, 0, 4, 4, .{ 0, 0, 255, 255 });
    _ = try layer.addKeyFrame(2, .{ .pos = 2, .data = .{ .bitmap = bmp2 } });

    var sheet = try exportSpritesheet(allocator, &obj, 0, 1, 2, 2);
    defer sheet.deinit(allocator);

    // 2 frames side by side: 8x4
    try std.testing.expectEqual(@as(u32, 8), sheet.width);
    try std.testing.expectEqual(@as(u32, 4), sheet.height);

    // Left half red, right half blue
    const left = sheet.getPixel(1, 1).?;
    try std.testing.expectEqual(@as(u8, 255), left[0]); // R
    const right = sheet.getPixel(5, 1).?;
    try std.testing.expectEqual(@as(u8, 255), right[2]); // B
}
