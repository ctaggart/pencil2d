// Pencil2D definitions ported from core_lib/src/util/pencildef.h
// These enums and constants are the canonical source; the C++ header
// is generated or kept in sync with this file.

const std = @import("std");

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

// ── C ABI exports ────────────────────────────────────────────────────
// These allow C++ code to call Zig functions.

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
