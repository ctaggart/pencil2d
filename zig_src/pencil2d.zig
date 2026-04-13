// Pencil2D definitions ported from core_lib/src/util/pencildef.h
// These enums and constants are the canonical source; the C++ header
// is generated or kept in sync with this file.

const std = @import("std");
pub const pclx_zip = @import("pclx_zip.zig");
pub const cli = @import("cli.zig");
pub const keyframe = @import("keyframe.zig");
pub const layer = @import("layer.zig");
pub const object = @import("object.zig");
pub const xml = @import("xml.zig");
pub const pclx_file = @import("pclx_file.zig");
pub const timeline = @import("timeline.zig");
pub const vector_image = @import("vector_image.zig");
pub const mcp_embedded = @import("mcp_embedded.zig");
pub const managers = @import("managers.zig");
comptime {
    _ = &pclx_zip;
    _ = &cli;
    _ = &keyframe;
    _ = &layer;
    _ = &object;
    _ = &xml;
    _ = &pclx_file;
    _ = &timeline;
    _ = &vector_image;
    _ = &mcp_embedded;
    _ = &managers;
}

pub const pi: f64 = 3.14159265358979323846;

pub const max_frames_bound: i32 = 9999;

pub const ToolCategory = enum(c_int) {
    base_tool = 0,
    stroke_tool = 1,
    transform_tool = 2,
};

pub const ToolType = enum(c_int) {
    invalid_tool = -1,
    pencil = 0,
    eraser,
    select,
    move,
    hand,
    smudge,
    camera,
    pen,
    polyline,
    bucket,
    eyedropper,
    brush,
    tool_type_count,
};

pub const DotColorType = enum(c_int) {
    red,
    blue,
    green,
    black,
    white,
};

pub const BackgroundStyle = enum(c_int) { _ };

pub const StabilizationLevel = enum(c_int) {
    none,
    simple,
    strong,
};

pub const TimecodeTextLevel = enum(c_int) {
    no_text,
    frames,
    smpte,
    sff,
};

pub const LayerVisibility = enum(c_int) {
    current_only = 0,
    related = 1,
    all = 2,

    pub fn next(self: LayerVisibility) LayerVisibility {
        return switch (self) {
            .all => .current_only,
            else => @enumFromInt(@intFromEnum(self) + 1),
        };
    }

    pub fn prev(self: LayerVisibility) LayerVisibility {
        return switch (self) {
            .current_only => .all,
            else => @enumFromInt(@intFromEnum(self) - 1),
        };
    }
};

// ── File types (from filetype.h) ─────────────────────────────────────

pub const FileType = enum(c_int) {
    animation,
    image,
    image_sequence,
    gif,
    animated_image,
    movie,
    sound,
    palette,
};

// ── Preferences (from preferencesdef.h) ──────────────────────────────

pub const Setting = enum(c_int) {
    antialias,
    grid,
    shadow,
    prev_onion,
    next_onion,
    invisible_lines,
    outlines,
    onion_blue,
    onion_red,
    tool_cursor,
    canvas_cursor,
    high_resolution,
    window_opacity,
    show_status_bar,
    curve_smoothing,
    background_style,
    auto_save,
    auto_save_number,
    short_scrub,
    fps,
    field_w,
    field_h,
    frame_size,
    timeline_size,
    label_font_size,
    draw_label,
    onion_max_opacity,
    onion_min_opacity,
    onion_prev_frames_num,
    onion_next_frames_num,
    onion_while_playback,
    onion_multiple_layers,
    onion_type,
    flip_roll_msec,
    flip_roll_drawings,
    flip_inbetween_msec,
    sound_scrub_active,
    sound_scrub_msec,
    layer_visibility,
    layer_visibility_threshold,
    grid_size_w,
    grid_size_h,
    overlay_center,
    overlay_thirds,
    overlay_golden,
    overlay_safe,
    overlay_perspective1,
    overlay_perspective2,
    overlay_perspective3,
    overlay_angle,
    overlay_safe_helper_text_on,
    action_safe_on,
    action_safe,
    timecode_text,
    title_safe_on,
    title_safe,
    new_undo_redo_system_on,
    quick_sizing,
    invert_drag_zoom_direction,
    invert_scroll_zoom_direction,
    language,
    layout_lock,
    draw_on_empty_frame_action,
    frame_pool_size,
    undo_redo_max_steps,
    rotation_increment,
    show_selection_info,
    ask_for_preset,
    load_most_recent,
    load_default_preset,
    default_preset,
    count, // must always be last
};

pub const DrawOnEmptyFrameAction = enum(c_int) {
    create_new_key,
    duplicate_previous_key,
    keep_drawing_on_previous_key,
};

// ── Camera easing types (from cameraeasingtype.h) ────────────────────

pub const CameraEasingType = enum(c_int) {
    linear,
    in_quad,
    out_quad,
    in_out_quad,
    out_in_quad,
    in_cubic,
    out_cubic,
    in_out_cubic,
    out_in_cubic,
    in_quart,
    out_quart,
    in_out_quart,
    out_in_quart,
    in_quint,
    out_quint,
    in_out_quint,
    out_in_quint,
    in_sine,
    out_sine,
    in_out_sine,
    out_in_sine,
    in_expo,
    out_expo,
    in_out_expo,
    out_in_expo,
    in_circ,
    out_circ,
    in_out_circ,
    out_in_circ,
    in_elastic,
    out_elastic,
    in_out_elastic,
    out_in_elastic,
    in_back,
    out_back,
    in_out_back,
    out_in_back,
    in_bounce,
    out_bounce,
    in_out_bounce,
    out_in_bounce,
};

// ── Math utilities (from mathutils.h) ────────────────────────────────

pub const math = struct {
    /// Get the angle from the difference vector a->b to the x-axis.
    /// Returns angle in radians from [-pi, +pi].
    pub fn getDifferenceAngle(ax: f64, ay: f64, bx: f64, by: f64) f64 {
        return std.math.atan2(by - ay, bx - ax);
    }

    /// Map one range onto another.
    pub fn map(x: f64, input_min: f64, input_max: f64, output_min: f64, output_max: f64) f64 {
        const slope = (output_max - output_min) / (input_max - input_min);
        return output_min + slope * (x - input_min);
    }

    /// Normalize x to a value between 0 and 1.
    pub fn normalize(x: f64, min: f64, max: f64) f64 {
        return @abs((x - max) / (min - max));
    }
};

// ── Painter utilities (from painterutils.h) ──────────────────────────

/// Calculate layer opacity based on current layer offset.
pub fn calculateRelativeOpacityForLayer(current_layer_index: i32, layer_index_next: i32, threshold: f32) f64 {
    const layer_offset = current_layer_index - layer_index_next;
    const absolute_offset: u32 = @intCast(@abs(layer_offset));
    if (absolute_offset == 0) return 1.0;
    return std.math.pow(f64, @floatCast(threshold), @floatFromInt(absolute_offset));
}

// ── Geometry types ───────────────────────────────────────────────────

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    pub fn scale(p: Point, s: f64) Point {
        return .{ .x = p.x * s, .y = p.y * s };
    }

    pub fn lerp(a: Point, b: Point, t: f64) Point {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }

    pub fn dot(a: Point, b: Point) f64 {
        return a.x * b.x + a.y * b.y;
    }

    /// Euclidean length.
    pub fn eLength(p: Point) f64 {
        return @sqrt(p.x * p.x + p.y * p.y);
    }

    /// Manhattan length. Returns 1.0 if zero to avoid division by zero.
    pub fn mLength(p: Point) f64 {
        const result = @abs(p.x) + @abs(p.y);
        return if (result == 0.0) 1.0 else result;
    }

    /// Normalize to unit length.
    pub fn normalized(p: Point) Point {
        const len = p.eLength();
        if (len > 1.0e-6) {
            return .{ .x = p.x / len, .y = p.y / len };
        }
        return p;
    }
};

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
};

// ── Bézier curve math (from beziercurve.cpp) ─────────────────────────

pub const bezier = struct {
    /// Evaluate a point on a cubic Bézier segment at parameter t ∈ [0,1].
    /// Uses the Bernstein polynomial form: B(t) = (1-t)³P₀ + 3t(1-t)²P₁ + 3t²(1-t)P₂ + t³P₃
    pub fn pointOnCubic(p0: Point, c1: Point, c2: Point, p1: Point, t: f64) Point {
        const u = 1.0 - t;
        const uu = u * u;
        const t2 = t * t;
        return .{
            .x = uu * u * p0.x + 3.0 * t * uu * c1.x + 3.0 * t2 * u * c2.x + t2 * t * p1.x,
            .y = uu * u * p0.y + 3.0 * t * uu * c1.y + 3.0 * t2 * u * c2.y + t2 * t * p1.y,
        };
    }

    /// De Casteljau split: split a cubic at parameter `fraction`, returning
    /// the control points for the two resulting cubics.
    pub const SplitResult = struct {
        // First half: p0 -> cA1 -> cA2 -> mid
        cA1: Point,
        cA2: Point,
        // Second half: mid -> cB1 -> cB2 -> p1
        cB1: Point,
        cB2: Point,
        mid: Point,
    };

    pub fn splitCubic(p0: Point, c1_in: Point, c2_in: Point, p1: Point, fraction: f64) SplitResult {
        const c12 = Point.lerp(c1_in, c2_in, fraction);
        const cA1 = Point.lerp(p0, c1_in, fraction);
        const cB2 = Point.lerp(c2_in, p1, fraction);
        const cA2 = Point.lerp(cA1, c12, fraction);
        const cB1 = Point.lerp(c12, cB2, fraction);
        const mid = Point.lerp(cA2, cB1, fraction);
        return .{ .cA1 = cA1, .cA2 = cA2, .cB1 = cB1, .cB2 = cB2, .mid = mid };
    }

    /// Find the minimum distance from a point P to a cubic Bézier segment,
    /// sampled at `steps` intervals. Returns distance, nearest point, and parameter t.
    pub const DistanceResult = struct {
        distance: f64,
        nearest: Point,
        t: f64,
    };

    pub fn findDistance(p0: Point, c1_pt: Point, c2_pt: Point, p1: Point, target: Point, steps: u32) DistanceResult {
        var best = DistanceResult{
            .distance = Point.sub(p0, target).eLength(),
            .nearest = p0,
            .t = 0,
        };
        const n: f64 = @floatFromInt(steps);
        for (1..steps + 1) |k| {
            const s: f64 = @as(f64, @floatFromInt(k)) / n;
            const q = pointOnCubic(p0, c1_pt, c2_pt, p1, s);
            const dist = Point.sub(q, target).eLength();
            if (dist <= best.distance) {
                best = .{ .distance = dist, .nearest = q, .t = s };
            }
        }
        return best;
    }

    /// Douglas-Peucker polyline simplification.
    /// Sets `keep[i] = true` for points that should be kept.
    pub fn simplify(tolerance: f64, points: []const Point, j: usize, k: usize, keep: []bool) void {
        if (k <= j + 1) return;

        var maxd: f64 = 0.0;
        var maxi: usize = j;

        const pj = points[j];
        const pk = points[k];
        const vjk = Point.sub(pj, pk);
        const dv_sq = Point.dot(vjk, vjk);

        var i = j + 1;
        while (i < k) : (i += 1) {
            const vij = Point.sub(points[i], pj);
            var d: f64 = undefined;
            if (dv_sq != 0.0) {
                const proj = Point.dot(vij, vjk);
                d = @sqrt(Point.dot(vij, vij) - (proj * proj) / dv_sq);
            } else {
                d = vij.eLength();
            }
            if (d >= maxd) {
                maxd = d;
                maxi = i;
            }
        }

        if (maxd >= tolerance) {
            keep[maxi] = true;
            simplify(tolerance, points, j, maxi, keep);
            simplify(tolerance, points, maxi, k, keep);
        }
    }
};

// ── Transform math (from transform.cpp) ──────────────────────────────
// 2D affine transformation matrix [m11 m12 m13; m21 m22 m23; m31 m32 m33]

pub const Matrix = struct {
    m: [3][3]f64 = .{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    },

    pub fn identity() Matrix {
        return .{};
    }

    /// Create a translation matrix.
    pub fn translation(dx: f64, dy: f64) Matrix {
        var m = identity();
        m.m[2][0] = dx;
        m.m[2][1] = dy;
        return m;
    }

    /// Create a rotation matrix (angle in radians).
    pub fn rotation(angle: f64) Matrix {
        const c = @cos(angle);
        const s = @sin(angle);
        var m = identity();
        m.m[0][0] = c;
        m.m[0][1] = s;
        m.m[1][0] = -s;
        m.m[1][1] = c;
        return m;
    }

    /// Create a scale matrix.
    pub fn scale(sx: f64, sy: f64) Matrix {
        var m = identity();
        m.m[0][0] = sx;
        m.m[1][1] = sy;
        return m;
    }

    /// Transform a point by this matrix.
    pub fn mapPoint(self: Matrix, p: Point) Point {
        const w = self.m[0][2] * p.x + self.m[1][2] * p.y + self.m[2][2];
        return .{
            .x = (self.m[0][0] * p.x + self.m[1][0] * p.y + self.m[2][0]) / w,
            .y = (self.m[0][1] * p.x + self.m[1][1] * p.y + self.m[2][1]) / w,
        };
    }

    /// Multiply two matrices.
    pub fn multiply(a: Matrix, b: Matrix) Matrix {
        var result: Matrix = undefined;
        for (0..3) |row| {
            for (0..3) |col| {
                result.m[row][col] = a.m[row][0] * b.m[0][col] +
                    a.m[row][1] * b.m[1][col] +
                    a.m[row][2] * b.m[2][col];
            }
        }
        return result;
    }

    /// Compute the inverse of this matrix. Returns identity if singular.
    pub fn inverted(self: Matrix) Matrix {
        const det = self.m[0][0] * (self.m[1][1] * self.m[2][2] - self.m[1][2] * self.m[2][1]) -
            self.m[0][1] * (self.m[1][0] * self.m[2][2] - self.m[1][2] * self.m[2][0]) +
            self.m[0][2] * (self.m[1][0] * self.m[2][1] - self.m[1][1] * self.m[2][0]);
        if (@abs(det) < 1e-12) return identity();
        const inv_det = 1.0 / det;
        var result: Matrix = undefined;
        result.m[0][0] = (self.m[1][1] * self.m[2][2] - self.m[1][2] * self.m[2][1]) * inv_det;
        result.m[0][1] = (self.m[0][2] * self.m[2][1] - self.m[0][1] * self.m[2][2]) * inv_det;
        result.m[0][2] = (self.m[0][1] * self.m[1][2] - self.m[0][2] * self.m[1][1]) * inv_det;
        result.m[1][0] = (self.m[1][2] * self.m[2][0] - self.m[1][0] * self.m[2][2]) * inv_det;
        result.m[1][1] = (self.m[0][0] * self.m[2][2] - self.m[0][2] * self.m[2][0]) * inv_det;
        result.m[1][2] = (self.m[0][2] * self.m[1][0] - self.m[0][0] * self.m[1][2]) * inv_det;
        result.m[2][0] = (self.m[1][0] * self.m[2][1] - self.m[1][1] * self.m[2][0]) * inv_det;
        result.m[2][1] = (self.m[0][1] * self.m[2][0] - self.m[0][0] * self.m[2][1]) * inv_det;
        result.m[2][2] = (self.m[0][0] * self.m[1][1] - self.m[0][1] * self.m[1][0]) * inv_det;
        return result;
    }

    /// Map a rect through the inverse of this matrix.
    pub fn mapFromLocalRect(self: Matrix, rect: Rect) Rect {
        const inv = self.inverted();
        const tl = inv.mapPoint(.{ .x = rect.x, .y = rect.y });
        const tr = inv.mapPoint(.{ .x = rect.x + rect.w, .y = rect.y });
        const bl = inv.mapPoint(.{ .x = rect.x, .y = rect.y + rect.h });
        const br = inv.mapPoint(.{ .x = rect.x + rect.w, .y = rect.y + rect.h });
        const min_x = @min(@min(tl.x, tr.x), @min(bl.x, br.x));
        const min_y = @min(@min(tl.y, tr.y), @min(bl.y, br.y));
        const max_x = @max(@max(tl.x, tr.x), @max(bl.x, br.x));
        const max_y = @max(@max(tl.y, tr.y), @max(bl.y, br.y));
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
    }

    /// Map a point through the inverse then through a world transform.
    pub fn mapToWorldPoint(self: Matrix, world: Matrix, p: Point) Point {
        return world.mapPoint(self.inverted().mapPoint(p));
    }

    /// Map a rect through the inverse then through a world transform.
    pub fn mapToWorldRect(self: Matrix, world: Matrix, rect: Rect) Rect {
        const local = self.mapFromLocalRect(rect);
        const tl = world.mapPoint(.{ .x = local.x, .y = local.y });
        const tr = world.mapPoint(.{ .x = local.x + local.w, .y = local.y });
        const bl = world.mapPoint(.{ .x = local.x, .y = local.y + local.h });
        const br = world.mapPoint(.{ .x = local.x + local.w, .y = local.y + local.h });
        const min_x = @min(@min(tl.x, tr.x), @min(bl.x, br.x));
        const min_y = @min(@min(tl.y, tr.y), @min(bl.y, br.y));
        const max_x = @max(@max(tl.x, tr.x), @max(bl.x, br.x));
        const max_y = @max(@max(tl.y, tr.y), @max(bl.y, br.y));
        return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
    }
};

// ── Pixel buffer (Phase 6) ───────────────────────────────────────────
// ARGB32 premultiplied pixel buffer, matching Qt's QImage::Format_ARGB32_Premultiplied.
// Pixel layout: 0xAARRGGBB (native u32, little-endian bytes: BB GG RR AA)

pub const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn fromArgb(argb: u32) Color {
        return @bitCast(argb);
    }

    pub fn toArgb(self: Color) u32 {
        return @bitCast(self);
    }

    /// Squared Euclidean color distance (for flood-fill tolerance).
    pub fn distanceSq(a: Color, b_col: Color) u32 {
        const dr: i32 = @as(i32, a.r) - @as(i32, b_col.r);
        const dg: i32 = @as(i32, a.g) - @as(i32, b_col.g);
        const db: i32 = @as(i32, a.b) - @as(i32, b_col.b);
        const da: i32 = @as(i32, a.a) - @as(i32, b_col.a);
        return @intCast(dr * dr + dg * dg + db * db + da * da);
    }
};

pub const PixelBuffer = struct {
    data: []Color,
    width: u32,
    height: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !PixelBuffer {
        const pixels = try allocator.alloc(Color, @as(usize, width) * height);
        @memset(pixels, Color.transparent);
        return .{ .data = pixels, .width = width, .height = height, .allocator = allocator };
    }

    pub fn deinit(self: *PixelBuffer) void {
        self.allocator.free(self.data);
    }

    pub fn getPixel(self: *const PixelBuffer, x: u32, y: u32) Color {
        if (x >= self.width or y >= self.height) return Color.transparent;
        return self.data[@as(usize, y) * self.width + x];
    }

    pub fn setPixel(self: *PixelBuffer, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.data[@as(usize, y) * self.width + x] = color;
    }

    /// Get a pointer to a scanline row.
    pub fn scanLine(self: *PixelBuffer, y: u32) ?[]Color {
        if (y >= self.height) return null;
        const start = @as(usize, y) * self.width;
        return self.data[start .. start + self.width];
    }

    pub fn constScanLine(self: *const PixelBuffer, y: u32) ?[]const Color {
        if (y >= self.height) return null;
        const start = @as(usize, y) * self.width;
        return self.data[start .. start + self.width];
    }

    /// Find the tight bounding box of non-transparent pixels.
    /// Returns null if the buffer is entirely transparent.
    pub fn autoCropBounds(self: *const PixelBuffer) ?struct { left: u32, top: u32, right: u32, bottom: u32 } {
        var top: u32 = 0;
        var bottom: u32 = self.height;

        // Scan from top
        while (top < self.height) : (top += 1) {
            const row = self.constScanLine(top).?;
            var has_content = false;
            for (row) |px| {
                if (px.a != 0) {
                    has_content = true;
                    break;
                }
            }
            if (has_content) break;
        }
        if (top >= self.height) return null; // entirely transparent

        // Scan from bottom
        bottom = self.height - 1;
        while (bottom > top) : (bottom -= 1) {
            const row = self.constScanLine(bottom).?;
            var has_content = false;
            for (row) |px| {
                if (px.a != 0) {
                    has_content = true;
                    break;
                }
            }
            if (has_content) break;
        }

        // Scan columns
        var left: u32 = self.width;
        var right: u32 = 0;
        var y = top;
        while (y <= bottom) : (y += 1) {
            const row = self.constScanLine(y).?;
            for (0..self.width) |col_usize| {
                const col: u32 = @intCast(col_usize);
                if (row[col_usize].a != 0) {
                    if (col < left) left = col;
                    if (col > right) right = col;
                }
            }
        }

        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }

    /// Scanline flood fill. Returns a bool buffer of filled pixels and the fill bounds.
    pub fn floodFill(
        self: *const PixelBuffer,
        start_x: u32,
        start_y: u32,
        tolerance_sq: u32,
    ) !struct { filled: []bool, left: u32, top: u32, right: u32, bottom: u32 } {
        const w = self.width;
        const h = self.height;
        const total = @as(usize, w) * h;
        const filled = try self.allocator.alloc(bool, total);
        @memset(filled, false);

        const old_color = self.getPixel(start_x, start_y);

        const QueueItem = struct { x: u32, y: u32 };
        var queue_buf = try self.allocator.alloc(QueueItem, total);
        defer self.allocator.free(queue_buf);
        var queue_head: usize = 0;
        var queue_tail: usize = 0;
        queue_buf[queue_tail] = .{ .x = start_x, .y = start_y };
        queue_tail += 1;

        var min_x: u32 = start_x;
        var min_y: u32 = start_y;
        var max_x: u32 = start_x;
        var max_y: u32 = start_y;

        while (queue_head < queue_tail) {
            const pt = queue_buf[queue_head];
            queue_head += 1;
            const idx = @as(usize, pt.y) * w + pt.x;
            if (filled[idx]) continue;

            // Scan left
            var x_left: u32 = pt.x;
            while (x_left > 0 and Color.distanceSq(self.getPixel(x_left - 1, pt.y), old_color) <= tolerance_sq) {
                x_left -= 1;
            }

            // Scan right and fill
            var x_cur = x_left;
            var span_up = false;
            var span_down = false;

            while (x_cur < w and Color.distanceSq(self.getPixel(x_cur, pt.y), old_color) <= tolerance_sq) {
                const cur_idx = @as(usize, pt.y) * w + x_cur;
                filled[cur_idx] = true;

                if (x_cur < min_x) min_x = x_cur;
                if (x_cur > max_x) max_x = x_cur;
                if (pt.y < min_y) min_y = pt.y;
                if (pt.y > max_y) max_y = pt.y;

                // Check above
                if (pt.y > 0) {
                    const above_idx = @as(usize, pt.y - 1) * w + x_cur;
                    const matches = Color.distanceSq(self.getPixel(x_cur, pt.y - 1), old_color) <= tolerance_sq;
                    if (!span_up and matches and !filled[above_idx]) {
                        queue_buf[queue_tail] = .{ .x = x_cur, .y = pt.y - 1 };
                        queue_tail += 1;
                        span_up = true;
                    } else if (span_up and !matches) {
                        span_up = false;
                    }
                }

                // Check below
                if (pt.y + 1 < h) {
                    const below_idx = @as(usize, pt.y + 1) * w + x_cur;
                    const matches = Color.distanceSq(self.getPixel(x_cur, pt.y + 1), old_color) <= tolerance_sq;
                    if (!span_down and matches and !filled[below_idx]) {
                        queue_buf[queue_tail] = .{ .x = x_cur, .y = pt.y + 1 };
                        queue_tail += 1;
                        span_down = true;
                    } else if (span_down and !matches) {
                        span_down = false;
                    }
                }

                x_cur += 1;
            }
        }

        return .{ .filled = filled, .left = min_x, .top = min_y, .right = max_x, .bottom = max_y };
    }

    /// Composite `src` onto `self` using source-over alpha blending (premultiplied alpha).
    /// src_x/src_y is the offset of src's top-left relative to self's coordinate space.
    pub fn compositeOver(self: *PixelBuffer, src: *const PixelBuffer, src_x: i32, src_y: i32) void {
        const dst_w: i32 = @intCast(self.width);
        const dst_h: i32 = @intCast(self.height);
        const src_w: i32 = @intCast(src.width);
        const src_h: i32 = @intCast(src.height);

        // Clamp iteration bounds
        const y_start: i32 = @max(0, -src_y);
        const y_end: i32 = @min(src_h, dst_h - src_y);
        const x_start: i32 = @max(0, -src_x);
        const x_end: i32 = @min(src_w, dst_w - src_x);

        var sy = y_start;
        while (sy < y_end) : (sy += 1) {
            const dy: u32 = @intCast(sy + src_y);
            const dst_row = self.scanLine(dy) orelse continue;
            const src_row = src.constScanLine(@intCast(sy)) orelse continue;
            var sx = x_start;
            while (sx < x_end) : (sx += 1) {
                const dx: u32 = @intCast(sx + src_x);
                const s = src_row[@intCast(sx)];
                if (s.a == 0) continue;
                if (s.a == 255) {
                    dst_row[dx] = s;
                } else {
                    // Premultiplied source-over: dst = src + dst * (1 - src.a)
                    const d = dst_row[dx];
                    const inv_a: u16 = 255 - @as(u16, s.a);
                    dst_row[dx] = .{
                        .r = @intCast(@as(u16, s.r) + (@as(u16, d.r) * inv_a + 127) / 255),
                        .g = @intCast(@as(u16, s.g) + (@as(u16, d.g) * inv_a + 127) / 255),
                        .b = @intCast(@as(u16, s.b) + (@as(u16, d.b) * inv_a + 127) / 255),
                        .a = @intCast(@as(u16, s.a) + (@as(u16, d.a) * inv_a + 127) / 255),
                    };
                }
            }
        }
    }

    /// Fill all non-transparent pixels with a solid color, preserving alpha.
    /// Equivalent to QPainter::CompositionMode_SourceIn with a solid fill.
    pub fn fillNonAlpha(self: *PixelBuffer, color: Color) void {
        for (self.data) |*px| {
            if (px.a != 0) {
                // Source-in: result.a = src.a * dst.a / 255
                const a = (@as(u16, color.a) * @as(u16, px.a) + 127) / 255;
                px.* = .{
                    .r = @intCast((@as(u16, color.r) * a + 127) / 255),
                    .g = @intCast((@as(u16, color.g) * a + 127) / 255),
                    .b = @intCast((@as(u16, color.b) * a + 127) / 255),
                    .a = @intCast(a),
                };
            }
        }
    }

    /// Clear all pixels to transparent.
    pub fn clear(self: *PixelBuffer) void {
        @memset(self.data, Color.transparent);
    }

    /// Clear a rectangular region to transparent.
    pub fn clearRect(self: *PixelBuffer, rx: u32, ry: u32, rw: u32, rh: u32) void {
        var y: u32 = ry;
        while (y < ry + rh and y < self.height) : (y += 1) {
            const row = self.scanLine(y) orelse continue;
            var x: u32 = rx;
            while (x < rx + rw and x < self.width) : (x += 1) {
                row[x] = Color.transparent;
            }
        }
    }
};

// ── C ABI for PixelBuffer ────────────────────────────────────────────

const CPixelBuffer = opaque {};

export fn zig_pixbuf_create(width: u32, height: u32) ?*CPixelBuffer {
    const buf = std.heap.page_allocator.create(PixelBuffer) catch return null;
    buf.* = PixelBuffer.init(std.heap.page_allocator, width, height) catch {
        std.heap.page_allocator.destroy(buf);
        return null;
    };
    return @ptrCast(buf);
}

export fn zig_pixbuf_destroy(handle: *CPixelBuffer) void {
    const buf: *PixelBuffer = @ptrCast(@alignCast(handle));
    buf.deinit();
    std.heap.page_allocator.destroy(buf);
}

export fn zig_pixbuf_get_pixel(handle: *const CPixelBuffer, x: u32, y: u32) u32 {
    const buf: *const PixelBuffer = @ptrCast(@alignCast(handle));
    return buf.getPixel(x, y).toArgb();
}

export fn zig_pixbuf_set_pixel(handle: *CPixelBuffer, x: u32, y: u32, argb: u32) void {
    const buf: *PixelBuffer = @ptrCast(@alignCast(handle));
    buf.setPixel(x, y, Color.fromArgb(argb));
}

export fn zig_pixbuf_data_ptr(handle: *CPixelBuffer) [*]u8 {
    const buf: *PixelBuffer = @ptrCast(@alignCast(handle));
    return @ptrCast(buf.data.ptr);
}

export fn zig_pixbuf_composite_over(dst: *CPixelBuffer, src: *const CPixelBuffer, src_x: c_int, src_y: c_int) void {
    const dst_buf: *PixelBuffer = @ptrCast(@alignCast(dst));
    const src_buf: *const PixelBuffer = @ptrCast(@alignCast(src));
    dst_buf.compositeOver(src_buf, src_x, src_y);
}

export fn zig_pixbuf_fill_non_alpha(handle: *CPixelBuffer, argb: u32) void {
    const buf: *PixelBuffer = @ptrCast(@alignCast(handle));
    buf.fillNonAlpha(Color.fromArgb(argb));
}

export fn zig_pixbuf_clear(handle: *CPixelBuffer) void {
    const buf: *PixelBuffer = @ptrCast(@alignCast(handle));
    buf.clear();
}

export fn zig_color_distance_sq(a: u32, b_val: u32) u32 {
    return Color.distanceSq(Color.fromArgb(a), Color.fromArgb(b_val));
}

// ── Event system (Phase 7) ───────────────────────────────────────────
// A simple observer/callback system to replace Qt signals/slots for
// non-UI manager communication. Each event type is a list of callbacks.

pub fn Event(comptime Args: type) type {
    return struct {
        const Self = @This();
        const Callback = *const fn (Args) void;

        callbacks: [max_callbacks]?Callback = .{null} ** max_callbacks,
        count: usize = 0,
        const max_callbacks = 16;

        pub fn connect(self: *Self, cb: Callback) void {
            if (self.count < max_callbacks) {
                self.callbacks[self.count] = cb;
                self.count += 1;
            }
        }

        pub fn disconnect(self: *Self, cb: Callback) void {
            var i: usize = 0;
            while (i < self.count) {
                if (self.callbacks[i] == cb) {
                    var j = i;
                    while (j + 1 < self.count) : (j += 1) {
                        self.callbacks[j] = self.callbacks[j + 1];
                    }
                    self.callbacks[self.count - 1] = null;
                    self.count -= 1;
                } else {
                    i += 1;
                }
            }
        }

        pub fn emit(self: *const Self, args: Args) void {
            for (0..self.count) |i| {
                if (self.callbacks[i]) |cb| {
                    cb(args);
                }
            }
        }

        pub fn disconnectAll(self: *Self) void {
            for (0..max_callbacks) |i| {
                self.callbacks[i] = null;
            }
            self.count = 0;
        }
    };
}

/// Void event (no arguments)
pub const VoidEvent = Event(void);

// ── C ABI exports for earlier functions ──────────────────────────────

export fn zig_pointOnCubic(
    p0x: f64,
    p0y: f64,
    c1x: f64,
    c1y: f64,
    c2x: f64,
    c2y: f64,
    p1x: f64,
    p1y: f64,
    t: f64,
    out_x: *f64,
    out_y: *f64,
) void {
    const result = bezier.pointOnCubic(
        .{ .x = p0x, .y = p0y },
        .{ .x = c1x, .y = c1y },
        .{ .x = c2x, .y = c2y },
        .{ .x = p1x, .y = p1y },
        t,
    );
    out_x.* = result.x;
    out_y.* = result.y;
}

export fn zig_eLength(x: f64, y: f64) f64 {
    return (Point{ .x = x, .y = y }).eLength();
}

export fn zig_mLength(x: f64, y: f64) f64 {
    return (Point{ .x = x, .y = y }).mLength();
}

// ── Tests ────────────────────────────────────────────────────────────

export fn zig_getDifferenceAngle(ax: f64, ay: f64, bx: f64, by: f64) f64 {
    return math.getDifferenceAngle(ax, ay, bx, by);
}

export fn zig_mapRange(x: f64, in_min: f64, in_max: f64, out_min: f64, out_max: f64) f64 {
    return math.map(x, in_min, in_max, out_min, out_max);
}

export fn zig_normalize(x: f64, min: f64, max: f64) f64 {
    return math.normalize(x, min, max);
}

export fn zig_calculateRelativeOpacityForLayer(current: c_int, next: c_int, threshold: f32) f64 {
    return calculateRelativeOpacityForLayer(current, next, threshold);
}

// ── Tests ────────────────────────────────────────────────────────────

test "LayerVisibility cycling" {
    const vis = LayerVisibility.current_only;
    try std.testing.expectEqual(LayerVisibility.related, vis.next());
    try std.testing.expectEqual(LayerVisibility.all, vis.next().next());
    try std.testing.expectEqual(LayerVisibility.current_only, vis.next().next().next());
}

test "LayerVisibility reverse cycling" {
    const vis = LayerVisibility.current_only;
    try std.testing.expectEqual(LayerVisibility.all, vis.prev());
    try std.testing.expectEqual(LayerVisibility.related, vis.prev().prev());
    try std.testing.expectEqual(LayerVisibility.current_only, vis.prev().prev().prev());
}

test "getDifferenceAngle" {
    const angle = math.getDifferenceAngle(0, 0, 1, 0);
    try std.testing.expectApproxEqAbs(0.0, angle, 1e-10);

    const angle90 = math.getDifferenceAngle(0, 0, 0, 1);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, angle90, 1e-10);
}

test "map range" {
    const result = math.map(5.0, 0.0, 10.0, 0.0, 100.0);
    try std.testing.expectApproxEqAbs(50.0, result, 1e-10);
}

test "normalize" {
    const result = math.normalize(5.0, 0.0, 10.0);
    try std.testing.expectApproxEqAbs(0.5, result, 1e-10);
}

test "calculateRelativeOpacityForLayer same layer" {
    const opacity = calculateRelativeOpacityForLayer(3, 3, 0.5);
    try std.testing.expectApproxEqAbs(1.0, opacity, 1e-10);
}

test "calculateRelativeOpacityForLayer offset 1" {
    const opacity = calculateRelativeOpacityForLayer(3, 4, 0.5);
    try std.testing.expectApproxEqAbs(0.5, opacity, 1e-10);
}

test "calculateRelativeOpacityForLayer offset 2" {
    const opacity = calculateRelativeOpacityForLayer(3, 5, 0.5);
    try std.testing.expectApproxEqAbs(0.25, opacity, 1e-10);
}

test "Point eLength" {
    const p = Point{ .x = 3, .y = 4 };
    try std.testing.expectApproxEqAbs(5.0, p.eLength(), 1e-10);
}

test "Point mLength" {
    const p = Point{ .x = 3, .y = -4 };
    try std.testing.expectApproxEqAbs(7.0, p.mLength(), 1e-10);
}

test "bezier pointOnCubic endpoints" {
    const p0 = Point{ .x = 0, .y = 0 };
    const c1 = Point{ .x = 1, .y = 2 };
    const c2 = Point{ .x = 3, .y = 2 };
    const p1 = Point{ .x = 4, .y = 0 };
    const start = bezier.pointOnCubic(p0, c1, c2, p1, 0.0);
    try std.testing.expectApproxEqAbs(0.0, start.x, 1e-10);
    try std.testing.expectApproxEqAbs(0.0, start.y, 1e-10);
    const end = bezier.pointOnCubic(p0, c1, c2, p1, 1.0);
    try std.testing.expectApproxEqAbs(4.0, end.x, 1e-10);
    try std.testing.expectApproxEqAbs(0.0, end.y, 1e-10);
}

test "bezier splitCubic midpoint" {
    const p0 = Point{ .x = 0, .y = 0 };
    const c1 = Point{ .x = 0, .y = 2 };
    const c2 = Point{ .x = 2, .y = 2 };
    const p1 = Point{ .x = 2, .y = 0 };
    const result = bezier.splitCubic(p0, c1, c2, p1, 0.5);
    // The midpoint should be on the curve at t=0.5
    const expected = bezier.pointOnCubic(p0, c1, c2, p1, 0.5);
    try std.testing.expectApproxEqAbs(expected.x, result.mid.x, 1e-10);
    try std.testing.expectApproxEqAbs(expected.y, result.mid.y, 1e-10);
}

test "bezier findDistance" {
    const p0 = Point{ .x = 0, .y = 0 };
    const c1 = Point{ .x = 1, .y = 2 };
    const c2 = Point{ .x = 3, .y = 2 };
    const p1 = Point{ .x = 4, .y = 0 };
    // Distance from a point on the curve should be ~0
    const on_curve = bezier.pointOnCubic(p0, c1, c2, p1, 0.5);
    const result = bezier.findDistance(p0, c1, c2, p1, on_curve, 100);
    try std.testing.expect(result.distance < 0.05);
}

test "bezier simplify" {
    // Collinear points should be simplified away
    const points = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 3, .y = 0 },
        .{ .x = 4, .y = 0 },
    };
    var keep = [_]bool{ true, false, false, false, true };
    bezier.simplify(0.1, &points, 0, 4, &keep);
    // Interior collinear points should NOT be marked (distance is 0 < tolerance)
    try std.testing.expect(!keep[1]);
    try std.testing.expect(!keep[2]);
    try std.testing.expect(!keep[3]);
}

test "Matrix identity mapPoint" {
    const m = Matrix.identity();
    const p = m.mapPoint(.{ .x = 3, .y = 7 });
    try std.testing.expectApproxEqAbs(3.0, p.x, 1e-10);
    try std.testing.expectApproxEqAbs(7.0, p.y, 1e-10);
}

test "Matrix inverted" {
    // Scale 2x matrix
    var m = Matrix.identity();
    m.m[0][0] = 2;
    m.m[1][1] = 2;
    const inv = m.inverted();
    const p = inv.mapPoint(.{ .x = 4, .y = 6 });
    try std.testing.expectApproxEqAbs(2.0, p.x, 1e-10);
    try std.testing.expectApproxEqAbs(3.0, p.y, 1e-10);
}

test "Color roundtrip" {
    const c = Color{ .r = 255, .g = 128, .b = 64, .a = 200 };
    const argb = c.toArgb();
    const c2 = Color.fromArgb(argb);
    try std.testing.expectEqual(c.r, c2.r);
    try std.testing.expectEqual(c.g, c2.g);
    try std.testing.expectEqual(c.b, c2.b);
    try std.testing.expectEqual(c.a, c2.a);
}

test "Color distanceSq identical" {
    const c = Color{ .r = 100, .g = 150, .b = 200, .a = 255 };
    try std.testing.expectEqual(@as(u32, 0), Color.distanceSq(c, c));
}

test "PixelBuffer create and access" {
    var buf = try PixelBuffer.init(std.testing.allocator, 10, 10);
    defer buf.deinit();
    try std.testing.expectEqual(Color.transparent, buf.getPixel(5, 5));
    buf.setPixel(5, 5, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(u8, 255), buf.getPixel(5, 5).r);
}

test "PixelBuffer autoCropBounds empty" {
    var buf = try PixelBuffer.init(std.testing.allocator, 10, 10);
    defer buf.deinit();
    try std.testing.expect(buf.autoCropBounds() == null);
}

test "PixelBuffer autoCropBounds single pixel" {
    var buf = try PixelBuffer.init(std.testing.allocator, 10, 10);
    defer buf.deinit();
    buf.setPixel(3, 7, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    const bounds = buf.autoCropBounds().?;
    try std.testing.expectEqual(@as(u32, 3), bounds.left);
    try std.testing.expectEqual(@as(u32, 7), bounds.top);
    try std.testing.expectEqual(@as(u32, 3), bounds.right);
    try std.testing.expectEqual(@as(u32, 7), bounds.bottom);
}

test "PixelBuffer floodFill" {
    var buf = try PixelBuffer.init(std.testing.allocator, 10, 10);
    defer buf.deinit();
    const result = try buf.floodFill(5, 5, 0);
    defer std.testing.allocator.free(result.filled);
    var count: usize = 0;
    for (result.filled) |f| {
        if (f) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), count);
}

test "PixelBuffer compositeOver" {
    var dst = try PixelBuffer.init(std.testing.allocator, 4, 4);
    defer dst.deinit();
    var src = try PixelBuffer.init(std.testing.allocator, 2, 2);
    defer src.deinit();

    // Fill dst with opaque white
    for (dst.data) |*px| px.* = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    // Fill src with semi-transparent red (premultiplied: r=128, a=128)
    for (src.data) |*px| px.* = .{ .r = 128, .g = 0, .b = 0, .a = 128 };

    dst.compositeOver(&src, 1, 1);

    // Pixel at (0,0) should be unchanged (white)
    try std.testing.expectEqual(@as(u8, 255), dst.getPixel(0, 0).r);
    // Pixel at (1,1) should be blended
    const blended = dst.getPixel(1, 1);
    try std.testing.expect(blended.r > 128); // red + white background
    try std.testing.expect(blended.a == 255); // fully opaque result
}

test "PixelBuffer fillNonAlpha" {
    var buf = try PixelBuffer.init(std.testing.allocator, 4, 4);
    defer buf.deinit();
    buf.setPixel(1, 1, .{ .r = 100, .g = 200, .b = 50, .a = 255 });
    buf.fillNonAlpha(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    // The non-transparent pixel should now be red
    const px = buf.getPixel(1, 1);
    try std.testing.expectEqual(@as(u8, 255), px.r);
    try std.testing.expectEqual(@as(u8, 0), px.g);
    // Transparent pixels should remain transparent
    try std.testing.expectEqual(@as(u8, 0), buf.getPixel(0, 0).a);
}

test "PixelBuffer clear" {
    var buf = try PixelBuffer.init(std.testing.allocator, 4, 4);
    defer buf.deinit();
    buf.setPixel(2, 2, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    buf.clear();
    try std.testing.expectEqual(@as(u8, 0), buf.getPixel(2, 2).a);
}

test "Event connect and emit" {
    const IntEvent = Event(i32);
    var ev: IntEvent = .{};
    var received: i32 = 0;
    const handler = struct {
        var value: i32 = 0;
        fn callback(v: i32) void {
            value = v;
        }
    };
    ev.connect(&handler.callback);
    ev.emit(42);
    received = handler.value;
    try std.testing.expectEqual(@as(i32, 42), received);
}

test "Event disconnect" {
    const IntEvent = Event(i32);
    var ev: IntEvent = .{};
    const handler = struct {
        var count: i32 = 0;
        fn callback(_: i32) void {
            count += 1;
        }
    };
    handler.count = 0;
    ev.connect(&handler.callback);
    ev.emit(1);
    try std.testing.expectEqual(@as(i32, 1), handler.count);
    ev.disconnect(&handler.callback);
    ev.emit(2);
    try std.testing.expectEqual(@as(i32, 1), handler.count); // still 1, disconnected
}

test "VoidEvent" {
    var ev: VoidEvent = .{};
    const handler = struct {
        var called: bool = false;
        fn callback(_: void) void {
            called = true;
        }
    };
    handler.called = false;
    ev.connect(&handler.callback);
    ev.emit({});
    try std.testing.expect(handler.called);
}
