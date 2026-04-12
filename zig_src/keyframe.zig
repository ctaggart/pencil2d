// KeyFrame — base type for all animation frame data.
// Ported from core_lib/src/structure/keyframe.h

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KeyFrame = struct {
    pos: i32 = -1,
    length: i32 = 1,
    is_modified: bool = true,
    filename: ?[]const u8 = null,
    data: Data = .empty,

    pub const Data = union(enum) {
        empty,
        bitmap: BitmapData,
        camera: CameraData,
        sound: SoundData,
    };

    pub fn clone(self: KeyFrame, allocator: Allocator) !KeyFrame {
        var copy = self;
        if (self.filename) |name| {
            copy.filename = try allocator.dupe(u8, name);
        }
        copy.data = switch (self.data) {
            .bitmap => |b| .{ .bitmap = try b.clone(allocator) },
            .camera => |c| .{ .camera = c },
            .sound => |s| .{ .sound = try s.clone(allocator) },
            .empty => .empty,
        };
        return copy;
    }

    pub fn deinit(self: *KeyFrame, allocator: Allocator) void {
        if (self.filename) |name| allocator.free(name);
        switch (self.data) {
            .bitmap => |*b| b.deinit(allocator),
            .sound => |*s| s.deinit(allocator),
            .camera, .empty => {},
        }
        self.* = undefined;
    }
};

/// Bitmap frame — RGBA pixel data with position offset.
pub const BitmapData = struct {
    pixels: ?[]u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    top_left_x: i32 = 0,
    top_left_y: i32 = 0,
    opacity: f32 = 1.0,

    pub fn clone(self: BitmapData, allocator: Allocator) !BitmapData {
        var copy = self;
        if (self.pixels) |px| {
            copy.pixels = try allocator.dupe(u8, px);
        }
        return copy;
    }

    pub fn deinit(self: *BitmapData, allocator: Allocator) void {
        if (self.pixels) |px| allocator.free(px);
        self.* = undefined;
    }

    pub fn bounds(self: BitmapData) Rect {
        return .{
            .x = self.top_left_x,
            .y = self.top_left_y,
            .w = @intCast(self.width),
            .h = @intCast(self.height),
        };
    }

    pub fn clear(self: *BitmapData) void {
        if (self.pixels) |px| @memset(px, 0);
    }

    pub fn getPixel(self: BitmapData, x: i32, y: i32) ?[4]u8 {
        const lx = x - self.top_left_x;
        const ly = y - self.top_left_y;
        if (lx < 0 or ly < 0) return null;
        const ux: u32 = @intCast(lx);
        const uy: u32 = @intCast(ly);
        if (ux >= self.width or uy >= self.height) return null;
        const idx = (uy * self.width + ux) * 4;
        const px = self.pixels orelse return null;
        return px[idx..][0..4].*;
    }

    pub fn setPixel(self: *BitmapData, x: i32, y: i32, rgba: [4]u8) void {
        const lx = x - self.top_left_x;
        const ly = y - self.top_left_y;
        if (lx < 0 or ly < 0) return;
        const ux: u32 = @intCast(lx);
        const uy: u32 = @intCast(ly);
        if (ux >= self.width or uy >= self.height) return;
        const idx = (uy * self.width + ux) * 4;
        const px = self.pixels orelse return;
        px[idx..][0..4].* = rgba;
    }
};

/// Camera keyframe data — position, rotation, scale + easing.
pub const CameraData = struct {
    translate_x: f64 = 0,
    translate_y: f64 = 0,
    rotation: f64 = 0,
    scaling: f64 = 1,
    easing_type: EasingType = .linear,
    path_control_x: f64 = 0,
    path_control_y: f64 = 0,
    path_control_moved: bool = false,

    pub const EasingType = @import("pencil2d.zig").CameraEasingType;
};

/// Sound clip keyframe data.
pub const SoundData = struct {
    sound_file: ?[]const u8 = null,
    clip_name: ?[]const u8 = null,
    duration_ms: i64 = 0,

    pub fn clone(self: SoundData, allocator: Allocator) !SoundData {
        var copy = self;
        if (self.sound_file) |f| copy.sound_file = try allocator.dupe(u8, f);
        if (self.clip_name) |n| copy.clip_name = try allocator.dupe(u8, n);
        return copy;
    }

    pub fn deinit(self: *SoundData, allocator: Allocator) void {
        if (self.sound_file) |f| allocator.free(f);
        if (self.clip_name) |n| allocator.free(n);
        self.* = undefined;
    }
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "KeyFrame defaults" {
    var kf = KeyFrame{};
    try std.testing.expectEqual(@as(i32, -1), kf.pos);
    try std.testing.expectEqual(@as(i32, 1), kf.length);
    try std.testing.expect(kf.is_modified);
    try std.testing.expect(kf.filename == null);
    kf.pos = 5;
    try std.testing.expectEqual(@as(i32, 5), kf.pos);
}

test "KeyFrame clone and deinit" {
    const allocator = std.testing.allocator;
    var original = KeyFrame{
        .pos = 10,
        .length = 3,
        .filename = try allocator.dupe(u8, "frame010.png"),
        .data = .{ .camera = .{ .translate_x = 100, .rotation = 45 } },
    };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(@as(i32, 10), cloned.pos);
    try std.testing.expectEqual(@as(i32, 3), cloned.length);
    try std.testing.expectEqualStrings("frame010.png", cloned.filename.?);
    try std.testing.expectEqual(@as(f64, 100), cloned.data.camera.translate_x);
    // Verify independent memory
    try std.testing.expect(original.filename.?.ptr != cloned.filename.?.ptr);
}

test "BitmapData pixel access" {
    const allocator = std.testing.allocator;
    const w: u32 = 4;
    const h: u32 = 4;
    const px = try allocator.alloc(u8, w * h * 4);
    defer allocator.free(px);
    @memset(px, 0);

    var bmp = BitmapData{
        .pixels = px,
        .width = w,
        .height = h,
        .top_left_x = 10,
        .top_left_y = 20,
    };

    // Out of bounds
    try std.testing.expect(bmp.getPixel(0, 0) == null);
    // Set and get
    bmp.setPixel(11, 22, .{ 255, 0, 128, 255 });
    const got = bmp.getPixel(11, 22).?;
    try std.testing.expectEqual(@as(u8, 255), got[0]);
    try std.testing.expectEqual(@as(u8, 128), got[2]);
}

test "CameraData defaults" {
    const cam = CameraData{};
    try std.testing.expectEqual(@as(f64, 0), cam.translate_x);
    try std.testing.expectEqual(@as(f64, 1), cam.scaling);
}
