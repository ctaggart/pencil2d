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

    /// Draw a line using Bresenham's algorithm.
    pub fn drawLine(self: *BitmapData, x0: i32, y0: i32, x1: i32, y1: i32, color: [4]u8) void {
        var cx = x0;
        var cy = y0;
        const dx = if (x1 > x0) x1 - x0 else x0 - x1;
        const dy = if (y1 > y0) y1 - y0 else y0 - y1;
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        while (true) {
            self.setPixel(cx, cy, color);
            if (cx == x1 and cy == y1) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                cx += sx;
            }
            if (e2 < dx) {
                err += dx;
                cy += sy;
            }
        }
    }

    /// Draw a filled rectangle.
    pub fn drawRect(self: *BitmapData, rx: i32, ry: i32, rw: i32, rh: i32, color: [4]u8) void {
        var y = ry;
        while (y < ry + rh) : (y += 1) {
            var x = rx;
            while (x < rx + rw) : (x += 1) {
                self.setPixel(x, y, color);
            }
        }
    }

    /// Draw a filled ellipse (Bresenham midpoint).
    pub fn drawEllipse(self: *BitmapData, cx: i32, cy: i32, rx: i32, ry: i32, color: [4]u8) void {
        if (rx <= 0 or ry <= 0) return;
        const rx2 = @as(i64, rx) * rx;
        const ry2 = @as(i64, ry) * ry;
        var y = -ry;
        while (y <= ry) : (y += 1) {
            const y2: i64 = @as(i64, y) * y;
            const x_span_sq = rx2 - @divTrunc(rx2 * y2, ry2);
            const x_span: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(if (x_span_sq > 0) x_span_sq else 0))));
            var x = -x_span;
            while (x <= x_span) : (x += 1) {
                self.setPixel(cx + x, cy + y, color);
            }
        }
    }

    /// Allocate a new BitmapData with given dimensions.
    pub fn create(allocator: Allocator, w: u32, h: u32, x: i32, y: i32) !BitmapData {
        const px = try allocator.alloc(u8, w * h * 4);
        @memset(px, 0);
        return .{
            .pixels = px,
            .width = w,
            .height = h,
            .top_left_x = x,
            .top_left_y = y,
        };
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
    const Matrix = @import("pencil2d.zig").Matrix;

    /// Compute the camera view matrix: translate * rotate * scale.
    pub fn getViewMatrix(self: CameraData) Matrix {
        const t = Matrix.translation(self.translate_x, self.translate_y);
        const r = Matrix.rotation(self.rotation * (std.math.pi / 180.0));
        const s = Matrix.scale(self.scaling, self.scaling);
        return t.multiply(r).multiply(s);
    }

    /// Linearly interpolate between two camera states.
    pub fn lerp(a: CameraData, b: CameraData, t: f64) CameraData {
        return .{
            .translate_x = a.translate_x + (b.translate_x - a.translate_x) * t,
            .translate_y = a.translate_y + (b.translate_y - a.translate_y) * t,
            .rotation = a.rotation + (b.rotation - a.rotation) * t,
            .scaling = a.scaling + (b.scaling - a.scaling) * t,
            .easing_type = b.easing_type,
            .path_control_x = a.path_control_x + (b.path_control_x - a.path_control_x) * t,
            .path_control_y = a.path_control_y + (b.path_control_y - a.path_control_y) * t,
            .path_control_moved = a.path_control_moved or b.path_control_moved,
        };
    }
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

test "CameraData getViewMatrix" {
    const cam = CameraData{ .translate_x = 100, .translate_y = 50, .scaling = 2 };
    const m = cam.getViewMatrix();
    // T*R*S: origin → translate(100,50) → scale(2) = (200,100)
    const p = m.mapPoint(.{ .x = 0, .y = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 200), p.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), p.y, 0.001);
}

test "CameraData lerp" {
    const a = CameraData{ .translate_x = 0, .scaling = 1 };
    const b = CameraData{ .translate_x = 100, .scaling = 2 };
    const mid = CameraData.lerp(a, b, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 50), mid.translate_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), mid.scaling, 0.001);
}

test "BitmapData drawLine" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 10, 10, 0, 0);
    defer bmp.deinit(allocator);

    bmp.drawLine(0, 0, 9, 0, .{ 255, 0, 0, 255 });
    // First pixel should be red
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(0, 0).?[0]);
    // Last pixel on line should be red
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(9, 0).?[0]);
    // Off-line pixel should be empty
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(0, 1).?[0]);
}

test "BitmapData drawRect" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 10, 10, 0, 0);
    defer bmp.deinit(allocator);

    bmp.drawRect(2, 2, 3, 3, .{ 0, 255, 0, 255 });
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(2, 2).?[1]); // green inside
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(4, 4).?[1]); // green corner
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(1, 1).?[1]); // outside
}

test "BitmapData drawEllipse" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 20, 20, 0, 0);
    defer bmp.deinit(allocator);

    bmp.drawEllipse(10, 10, 5, 5, .{ 0, 0, 255, 255 });
    // Center should be filled
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(10, 10).?[2]);
    // Far corner should be empty
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(0, 0).?[2]);
}
