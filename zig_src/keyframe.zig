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

    /// Flood fill from a point with tolerance (0-255).
    /// Uses scanline fill algorithm for efficiency.
    pub fn floodFill(self: *BitmapData, start_x: i32, start_y: i32, fill_color: [4]u8, tolerance: u32) void {
        const target = self.getPixel(start_x, start_y) orelse return;
        if (colorMatch(target, fill_color, 0)) return; // already filled

        const px = self.pixels orelse return;
        const w = self.width;
        const h = self.height;

        // Stack-based scanline fill
        var stack: [16384]struct { x: i32, y: i32 } = undefined;
        var sp: usize = 0;

        stack[sp] = .{ .x = start_x - self.top_left_x, .y = start_y - self.top_left_y };
        sp += 1;

        while (sp > 0) {
            sp -= 1;
            const pt = stack[sp];
            var lx = pt.x;

            if (pt.y < 0 or pt.y >= @as(i32, @intCast(h))) continue;
            if (lx < 0 or lx >= @as(i32, @intCast(w))) continue;

            // Scan left
            while (lx > 0 and colorMatch(getPixelLocal(px, w, @intCast(lx - 1), @intCast(pt.y)), target, tolerance)) lx -= 1;

            var rx = pt.x;
            // Scan right
            while (rx < @as(i32, @intCast(w)) - 1 and colorMatch(getPixelLocal(px, w, @intCast(rx + 1), @intCast(pt.y)), target, tolerance)) rx += 1;

            // Fill scanline and check above/below
            var x = lx;
            while (x <= rx) : (x += 1) {
                const ux: u32 = @intCast(x);
                const uy: u32 = @intCast(pt.y);
                if (colorMatch(getPixelLocal(px, w, ux, uy), target, tolerance)) {
                    const idx = (uy * w + ux) * 4;
                    px[idx..][0..4].* = fill_color;

                    // Push above
                    if (pt.y > 0 and sp < stack.len) {
                        if (colorMatch(getPixelLocal(px, w, ux, uy - 1), target, tolerance)) {
                            stack[sp] = .{ .x = x, .y = pt.y - 1 };
                            sp += 1;
                        }
                    }
                    // Push below
                    if (pt.y < @as(i32, @intCast(h)) - 1 and sp < stack.len) {
                        if (colorMatch(getPixelLocal(px, w, ux, uy + 1), target, tolerance)) {
                            stack[sp] = .{ .x = x, .y = pt.y + 1 };
                            sp += 1;
                        }
                    }
                }
            }
        }
    }

    /// Erase pixels in a circular area (set alpha to 0).
    pub fn erase(self: *BitmapData, cx: i32, cy: i32, radius: i32) void {
        const transparent = [4]u8{ 0, 0, 0, 0 };
        const r2 = @as(i64, radius) * radius;
        var y = cy - radius;
        while (y <= cy + radius) : (y += 1) {
            var x = cx - radius;
            while (x <= cx + radius) : (x += 1) {
                const dx = @as(i64, x - cx);
                const dy = @as(i64, y - cy);
                if (dx * dx + dy * dy <= r2) {
                    self.setPixel(x, y, transparent);
                }
            }
        }
    }

    fn getPixelLocal(px: []u8, w: u32, x: u32, y: u32) [4]u8 {
        const idx = (y * w + x) * 4;
        return px[idx..][0..4].*;
    }

    fn colorMatch(a: [4]u8, b: [4]u8, tolerance: u32) bool {
        const dr = if (a[0] > b[0]) a[0] - b[0] else b[0] - a[0];
        const dg = if (a[1] > b[1]) a[1] - b[1] else b[1] - a[1];
        const db = if (a[2] > b[2]) a[2] - b[2] else b[2] - a[2];
        const da = if (a[3] > b[3]) a[3] - b[3] else b[3] - a[3];
        const dist = @as(u32, dr) + @as(u32, dg) + @as(u32, db) + @as(u32, da);
        return dist <= tolerance;
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
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(10, 10).?[2]);
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(0, 0).?[2]);
}

test "BitmapData floodFill" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 10, 10, 0, 0);
    defer bmp.deinit(allocator);

    // Draw a red border box
    bmp.drawRect(0, 0, 10, 1, .{ 255, 0, 0, 255 }); // top
    bmp.drawRect(0, 9, 10, 1, .{ 255, 0, 0, 255 }); // bottom
    bmp.drawRect(0, 0, 1, 10, .{ 255, 0, 0, 255 }); // left
    bmp.drawRect(9, 0, 1, 10, .{ 255, 0, 0, 255 }); // right

    // Fill inside with green
    bmp.floodFill(5, 5, .{ 0, 255, 0, 255 }, 0);

    // Inside should be green
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(5, 5).?[1]);
    // Border should still be red
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(0, 0).?[0]);
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(0, 0).?[1]);
}

test "BitmapData floodFill with tolerance" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 8, 8, 0, 0);
    defer bmp.deinit(allocator);

    // Fill with slightly different shades of gray
    bmp.drawRect(0, 0, 4, 8, .{ 100, 100, 100, 255 });
    bmp.drawRect(4, 0, 4, 8, .{ 110, 110, 110, 255 });

    // With tolerance 0, only fills exact match
    bmp.floodFill(2, 2, .{ 0, 0, 255, 255 }, 0);
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(2, 2).?[2]); // blue
    try std.testing.expectEqual(@as(u8, 110), bmp.getPixel(6, 2).?[0]); // still gray
}

test "BitmapData erase" {
    const allocator = std.testing.allocator;
    var bmp = try BitmapData.create(allocator, 20, 20, 0, 0);
    defer bmp.deinit(allocator);

    bmp.drawRect(0, 0, 20, 20, .{ 255, 0, 0, 255 });
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(10, 10).?[3]); // opaque

    bmp.erase(10, 10, 3);
    try std.testing.expectEqual(@as(u8, 0), bmp.getPixel(10, 10).?[3]); // erased
    try std.testing.expectEqual(@as(u8, 255), bmp.getPixel(0, 0).?[3]); // untouched
}
