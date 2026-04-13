// Tool logic — stroke interpolation, pressure, tool state machine.
// Ported from core_lib/src/tool/strokeinterpolator.h, stroketool.h, basetool.h

const std = @import("std");
const pencil2d = @import("pencil2d.zig");
const Point = pencil2d.Point;
const Allocator = std.mem.Allocator;

// ── Pointer Event ────────────────────────────────────────────────────

pub const InputType = enum(i32) { mouse = 0, tablet = 1, touch = 2, unknown = 3 };
pub const EventType = enum(i32) { press = 0, move = 1, release = 2 };

pub const PointerEvent = struct {
    canvas_x: f64 = 0,
    canvas_y: f64 = 0,
    viewport_x: f64 = 0,
    viewport_y: f64 = 0,
    pressure: f64 = 1.0,
    rotation: f64 = 0,
    input_type: InputType = .mouse,
    event_type: EventType = .press,

    pub fn canvasPos(self: PointerEvent) Point {
        return .{ .x = self.canvas_x, .y = self.canvas_y };
    }
};

// ── Stroke Interpolator ─────────────────────────────────────────────

pub const StabilizerLevel = enum(i32) { none = 0, simple = 1, strong = 2 };

const QUEUE_LEN = 3;

pub const StrokeInterpolator = struct {
    current_pixel: Point = .{ .x = 0, .y = 0 },
    last_pixel: Point = .{ .x = 0, .y = 0 },
    last_interpolated: Point = .{ .x = 0, .y = 0 },
    previous_tangent: Point = .{ .x = 0, .y = 0 },
    has_tangent: bool = false,
    stroke_started: bool = false,
    pressure: f64 = 1.0,
    stabilizer: StabilizerLevel = .none,

    pos_queue: [QUEUE_LEN]Point = undefined,
    pressure_queue: [QUEUE_LEN]f64 = undefined,
    queue_len: usize = 0,

    pub fn reset(self: *StrokeInterpolator) void {
        self.stroke_started = false;
        self.has_tangent = false;
        self.queue_len = 0;
        self.pressure = 1.0;
    }

    pub fn setPressEvent(self: *StrokeInterpolator, pos: Point, p: f64) void {
        self.current_pixel = pos;
        self.last_pixel = pos;
        self.last_interpolated = pos;
        self.pressure = p;
        self.stroke_started = true;
        self.has_tangent = false;
        self.queue_len = 0;
    }

    pub fn setMoveEvent(self: *StrokeInterpolator, pos: Point, p: f64) void {
        self.last_pixel = self.current_pixel;
        self.pressure = p;
        self.smoothMousePos(pos);
    }

    /// Apply stabilization smoothing to mouse position.
    pub fn smoothMousePos(self: *StrokeInterpolator, pos: Point) void {
        switch (self.stabilizer) {
            .none => self.current_pixel = pos,
            .simple => {
                self.current_pixel = .{
                    .x = (pos.x + self.current_pixel.x) / 2.0,
                    .y = (pos.y + self.current_pixel.y) / 2.0,
                };
            },
            .strong => {
                self.current_pixel = .{
                    .x = (pos.x + self.last_interpolated.x) / 2.0,
                    .y = (pos.y + self.last_interpolated.y) / 2.0,
                };
            },
        }
    }

    /// Generate interpolated stroke segment: returns [P0, C1, C2, P1] cubic bezier.
    pub fn interpolateStroke(self: *StrokeInterpolator) [4]Point {
        if (self.queue_len < QUEUE_LEN) {
            return self.noInterpolation();
        }
        return self.tangentInterpolation();
    }

    /// No smoothing: straight line segment.
    fn noInterpolation(self: *StrokeInterpolator) [4]Point {
        const p0 = self.last_pixel;
        const p3 = self.current_pixel;
        // Enqueue
        if (self.queue_len < QUEUE_LEN) {
            self.pos_queue[self.queue_len] = self.current_pixel;
            self.pressure_queue[self.queue_len] = self.pressure;
            self.queue_len += 1;
        }
        return .{ p0, p0, p3, p3 };
    }

    /// Cubic Bezier with tangent continuity.
    fn tangentInterpolation(self: *StrokeInterpolator) [4]Point {
        const p0 = self.last_pixel;
        const p3 = self.current_pixel;
        const dx = p3.x - p0.x;
        const dy = p3.y - p0.y;
        const len = @sqrt(dx * dx + dy * dy);

        if (len < 0.001) return .{ p0, p0, p3, p3 };

        const scale = len / 3.0;
        const tangent = Point{
            .x = (p3.x - p0.x) / (3.0 * scale),
            .y = (p3.y - p0.y) / (3.0 * scale),
        };

        var c1: Point = undefined;
        if (self.has_tangent) {
            c1 = .{
                .x = p0.x + self.previous_tangent.x * scale,
                .y = p0.y + self.previous_tangent.y * scale,
            };
        } else {
            c1 = .{
                .x = p0.x + tangent.x * scale,
                .y = p0.y + tangent.y * scale,
            };
        }

        const c2 = Point{
            .x = p3.x - tangent.x * scale,
            .y = p3.y - tangent.y * scale,
        };

        self.previous_tangent = tangent;
        self.has_tangent = true;
        self.last_interpolated = p3;

        // Shift queue
        if (self.queue_len >= QUEUE_LEN) {
            var i: usize = 0;
            while (i < QUEUE_LEN - 1) : (i += 1) {
                self.pos_queue[i] = self.pos_queue[i + 1];
                self.pressure_queue[i] = self.pressure_queue[i + 1];
            }
            self.pos_queue[QUEUE_LEN - 1] = self.current_pixel;
            self.pressure_queue[QUEUE_LEN - 1] = self.pressure;
        }

        return .{ p0, c1, c2, p3 };
    }
};

// ── Tool State Machine ──────────────────────────────────────────────

pub const ToolState = enum { idle, drawing, released };

pub const StrokeContext = struct {
    interpolator: StrokeInterpolator = .{},
    state: ToolState = .idle,
    first_draw: bool = true,
    current_width: f64 = 2.0,
    current_pressure: f64 = 1.0,
    input_type: InputType = .mouse,

    // Accumulated stroke
    points_len: usize = 0,
    points: [4096]Point = undefined,
    pressures: [4096]f64 = undefined,

    /// Begin a new stroke.
    pub fn pressEvent(self: *StrokeContext, event: PointerEvent) void {
        self.state = .drawing;
        self.first_draw = true;
        self.points_len = 0;
        self.input_type = event.input_type;
        self.current_pressure = event.pressure;
        self.interpolator.setPressEvent(event.canvasPos(), event.pressure);
    }

    /// Continue a stroke.
    pub fn moveEvent(self: *StrokeContext, event: PointerEvent) void {
        if (self.state != .drawing) return;
        self.current_pressure = event.pressure;
        self.interpolator.setMoveEvent(event.canvasPos(), event.pressure);

        const seg = self.interpolator.interpolateStroke();
        self.addSegment(seg);
        self.first_draw = false;
    }

    /// End the stroke.
    pub fn releaseEvent(self: *StrokeContext, event: PointerEvent) void {
        if (self.state != .drawing) return;
        self.current_pressure = event.pressure;
        self.interpolator.setMoveEvent(event.canvasPos(), event.pressure);
        const seg = self.interpolator.interpolateStroke();
        self.addSegment(seg);
        self.state = .released;
        self.interpolator.reset();
    }

    fn addSegment(self: *StrokeContext, seg: [4]Point) void {
        for (seg) |p| {
            if (self.points_len < self.points.len) {
                self.points[self.points_len] = p;
                self.pressures[self.points_len] = self.current_pressure;
                self.points_len += 1;
            }
        }
    }

    /// Get the accumulated stroke points.
    pub fn getStrokePoints(self: *const StrokeContext) []const Point {
        return self.points[0..self.points_len];
    }

    /// Calculate brush width adjusted for pressure.
    pub fn effectiveWidth(self: StrokeContext, base_width: f64, pressure_enabled: bool) f64 {
        if (!pressure_enabled) return base_width;
        return base_width * self.current_pressure;
    }

    /// Calculate opacity adjusted for pressure.
    pub fn effectiveOpacity(self: StrokeContext, base_opacity: f64, pressure_enabled: bool) f64 {
        if (!pressure_enabled) return base_opacity;
        return base_opacity * (self.current_pressure * 0.5 + 0.5);
    }
};

// ── Brush Dab Generator ─────────────────────────────────────────────
// Generates dab positions along a stroke path with stepping.

pub const DabPoint = struct {
    x: f64,
    y: f64,
    width: f64,
    opacity: f64,
};

/// Generate dab positions along a stroke from last_point to current_point.
/// brush_step_ratio: fraction of width per step (0.5 = standard brush overlap).
pub fn generateDabs(
    last_point: Point,
    current_point: Point,
    width: f64,
    opacity: f64,
    pressure: f64,
    pressure_enabled: bool,
    buf: []DabPoint,
) usize {
    const eff_width = if (pressure_enabled) width * pressure else width;
    const eff_opacity = if (pressure_enabled) pressure * 0.5 else opacity;
    const brush_step = @max(1.0, 0.5 * eff_width);

    const dx = current_point.x - last_point.x;
    const dy = current_point.y - last_point.y;
    const dist = @sqrt(dx * dx + dy * dy) * 4.0; // 4x amplification

    if (dist < 0.001) return 0;
    const steps: usize = @intFromFloat(@round(dist / brush_step));
    const count = @min(steps, buf.len);

    for (0..count) |i| {
        const t = @as(f64, @floatFromInt(i + 1)) * brush_step / dist;
        buf[i] = .{
            .x = last_point.x + t * dx,
            .y = last_point.y + t * dy,
            .width = eff_width,
            .opacity = eff_opacity,
        };
    }
    return count;
}

// ── Selection Geometry ──────────────────────────────────────────────

pub const SelectionOp = enum { create, move, resize_tl, resize_tr, resize_bl, resize_br };

pub const SelectionRect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,

    /// Adjust selection based on drag operation.
    pub fn adjust(self: *SelectionRect, op: SelectionOp, press: Point, current: Point) void {
        const ox = current.x - press.x;
        const oy = current.y - press.y;

        switch (op) {
            .create => {
                self.x = @min(press.x, current.x);
                self.y = @min(press.y, current.y);
                self.w = @abs(current.x - press.x);
                self.h = @abs(current.y - press.y);
            },
            .move => {
                self.x += ox;
                self.y += oy;
            },
            .resize_tl => {
                self.x += ox;
                self.y += oy;
                self.w -= ox;
                self.h -= oy;
            },
            .resize_tr => {
                self.y += oy;
                self.w += ox;
                self.h -= oy;
            },
            .resize_bl => {
                self.x += ox;
                self.w -= ox;
                self.h += oy;
            },
            .resize_br => {
                self.w += ox;
                self.h += oy;
            },
        }
    }

    /// Normalize (fix negative width/height).
    pub fn normalize(self: *SelectionRect) void {
        if (self.w < 0) {
            self.x += self.w;
            self.w = -self.w;
        }
        if (self.h < 0) {
            self.y += self.h;
            self.h = -self.h;
        }
    }

    /// Check if point is inside.
    pub fn contains(self: SelectionRect, px: f64, py: f64) bool {
        return px >= self.x and px <= self.x + self.w and
            py >= self.y and py <= self.y + self.h;
    }

    /// Detect which handle a point is near (for resize).
    pub fn hitTest(self: SelectionRect, px: f64, py: f64, margin: f64) SelectionOp {
        const near_l = @abs(px - self.x) < margin;
        const near_r = @abs(px - (self.x + self.w)) < margin;
        const near_t = @abs(py - self.y) < margin;
        const near_b = @abs(py - (self.y + self.h)) < margin;

        if (near_l and near_t) return .resize_tl;
        if (near_r and near_t) return .resize_tr;
        if (near_l and near_b) return .resize_bl;
        if (near_r and near_b) return .resize_br;
        if (self.contains(px, py)) return .move;
        return .create;
    }
};

// ── Smudge Blend ────────────────────────────────────────────────────

/// Blend (smudge) pixels from src to dst in a circular area.
/// strength: 0.0 = no blend, 1.0 = full replace.
pub fn smudgeBlend(
    pixels: []u8,
    width: u32,
    height: u32,
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    radius: i32,
    strength: f64,
) void {
    const r2 = @as(i64, radius) * radius;
    var dy: i32 = -radius;
    while (dy <= radius) : (dy += 1) {
        var ddx: i32 = -radius;
        while (ddx <= radius) : (ddx += 1) {
            if (@as(i64, ddx) * ddx + @as(i64, dy) * dy > r2) continue;

            const sx: i32 = from_x + ddx;
            const sy: i32 = from_y + dy;
            const tx: i32 = to_x + ddx;
            const ty: i32 = to_y + dy;

            if (sx < 0 or sy < 0 or tx < 0 or ty < 0) continue;
            const usx: u32 = @intCast(sx);
            const usy: u32 = @intCast(sy);
            const utx: u32 = @intCast(tx);
            const uty: u32 = @intCast(ty);
            if (usx >= width or usy >= height or utx >= width or uty >= height) continue;

            const si = (usy * width + usx) * 4;
            const ti = (uty * width + utx) * 4;
            const s = strength;
            const inv = 1.0 - s;

            inline for (0..4) |c| {
                const src_val: f64 = @floatFromInt(pixels[si + c]);
                const dst_val: f64 = @floatFromInt(pixels[ti + c]);
                pixels[ti + c] = @intFromFloat(dst_val * inv + src_val * s);
            }
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "StrokeInterpolator smoothing none" {
    var si = StrokeInterpolator{};
    si.smoothMousePos(.{ .x = 100, .y = 50 });
    try std.testing.expectEqual(@as(f64, 100), si.current_pixel.x);
    try std.testing.expectEqual(@as(f64, 50), si.current_pixel.y);
}

test "StrokeInterpolator smoothing simple" {
    var si = StrokeInterpolator{ .stabilizer = .simple };
    si.current_pixel = .{ .x = 0, .y = 0 };
    si.smoothMousePos(.{ .x = 100, .y = 100 });
    try std.testing.expectEqual(@as(f64, 50), si.current_pixel.x);
    try std.testing.expectEqual(@as(f64, 50), si.current_pixel.y);
}

test "StrokeInterpolator generates segments" {
    var si = StrokeInterpolator{};
    si.setPressEvent(.{ .x = 0, .y = 0 }, 1.0);
    si.setMoveEvent(.{ .x = 10, .y = 0 }, 1.0);
    const seg = si.interpolateStroke();
    // First point should be near origin
    try std.testing.expect(seg[0].x >= 0 and seg[0].x <= 10);
    // Last point should be near (10,0)
    try std.testing.expect(seg[3].x >= 0 and seg[3].x <= 10);
}

test "StrokeContext full stroke" {
    var ctx = StrokeContext{};
    ctx.pressEvent(.{ .canvas_x = 0, .canvas_y = 0, .pressure = 0.8 });
    try std.testing.expectEqual(ToolState.drawing, ctx.state);

    ctx.moveEvent(.{ .canvas_x = 10, .canvas_y = 5, .pressure = 0.9, .event_type = .move });
    ctx.moveEvent(.{ .canvas_x = 20, .canvas_y = 10, .pressure = 1.0, .event_type = .move });
    ctx.moveEvent(.{ .canvas_x = 30, .canvas_y = 8, .pressure = 0.7, .event_type = .move });

    try std.testing.expect(ctx.points_len > 0);

    ctx.releaseEvent(.{ .canvas_x = 35, .canvas_y = 8, .pressure = 0.5, .event_type = .release });
    try std.testing.expectEqual(ToolState.released, ctx.state);
}

test "StrokeContext effective width" {
    const ctx = StrokeContext{ .current_pressure = 0.5 };
    try std.testing.expectEqual(@as(f64, 5.0), ctx.effectiveWidth(10.0, true));
    try std.testing.expectEqual(@as(f64, 10.0), ctx.effectiveWidth(10.0, false));
}

test "StrokeContext effective opacity" {
    const ctx = StrokeContext{ .current_pressure = 0.5 };
    const op = ctx.effectiveOpacity(1.0, true);
    try std.testing.expect(op > 0.5 and op < 1.0);
}

test "generateDabs produces steps" {
    var buf: [256]DabPoint = undefined;
    const count = generateDabs(
        .{ .x = 0, .y = 0 },
        .{ .x = 100, .y = 0 },
        10.0,
        1.0,
        1.0,
        false,
        &buf,
    );
    try std.testing.expect(count > 5); // 100px distance with ~5px steps
    try std.testing.expect(buf[0].x > 0);
    try std.testing.expectEqual(@as(f64, 10.0), buf[0].width);
}

test "generateDabs pressure scales width" {
    var buf: [256]DabPoint = undefined;
    const count = generateDabs(
        .{ .x = 0, .y = 0 },
        .{ .x = 50, .y = 0 },
        20.0,
        1.0,
        0.5,
        true,
        &buf,
    );
    try std.testing.expect(count > 0);
    try std.testing.expectEqual(@as(f64, 10.0), buf[0].width); // 20 * 0.5
}

test "SelectionRect create and resize" {
    var sel = SelectionRect{};
    sel.adjust(.create, .{ .x = 10, .y = 20 }, .{ .x = 110, .y = 80 });
    try std.testing.expectEqual(@as(f64, 10), sel.x);
    try std.testing.expectEqual(@as(f64, 100), sel.w);
    try std.testing.expect(sel.contains(50, 50));
    try std.testing.expect(!sel.contains(0, 0));

    // Hit test corners
    try std.testing.expectEqual(SelectionOp.resize_tl, sel.hitTest(10, 20, 5));
    try std.testing.expectEqual(SelectionOp.resize_br, sel.hitTest(110, 80, 5));
    try std.testing.expectEqual(SelectionOp.move, sel.hitTest(50, 50, 5));
}

test "SelectionRect normalize" {
    var sel = SelectionRect{ .x = 100, .y = 100, .w = -50, .h = -30 };
    sel.normalize();
    try std.testing.expectEqual(@as(f64, 50), sel.x);
    try std.testing.expectEqual(@as(f64, 70), sel.y);
    try std.testing.expectEqual(@as(f64, 50), sel.w);
    try std.testing.expectEqual(@as(f64, 30), sel.h);
}

test "smudgeBlend" {
    // 4x4 image: left half red, right half blue
    var pixels = [_]u8{
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
        255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255,
    };
    // Smudge from red (1,1) to blue (2,1) with 50% strength
    smudgeBlend(&pixels, 4, 4, 1, 1, 2, 1, 1, 0.5);
    // Pixel at (2,1) should be blended (not pure blue anymore)
    const idx = (1 * 4 + 2) * 4;
    try std.testing.expect(pixels[idx] > 0); // has some red
    try std.testing.expect(pixels[idx + 2] > 0); // still has blue
}
