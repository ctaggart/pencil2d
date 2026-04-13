// Preferences — application settings stored as a Zig struct.
// Replaces Qt's QSettings with an in-memory typed struct.
// Can be serialized to/from JSON for persistence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DrawOnEmptyFrameAction = enum(i32) {
    create_new_key = 0,
    duplicate_previous_key = 1,
    keep_drawing_on_previous_key = 2,
};

pub const Preferences = struct {
    // Display
    antialias: bool = true,
    grid: bool = false,
    shadow: bool = false,
    tool_cursor: bool = true,
    canvas_cursor: bool = true,
    high_resolution: bool = true,
    window_opacity: i32 = 100,
    show_status_bar: bool = true,
    background_style: i32 = 1,

    // Onion skin
    prev_onion: bool = false,
    next_onion: bool = false,
    onion_blue: bool = false,
    onion_red: bool = false,
    onion_max_opacity: i32 = 50,
    onion_min_opacity: i32 = 20,
    onion_prev_frames: i32 = 5,
    onion_next_frames: i32 = 5,
    onion_while_playback: bool = false,
    onion_multiple_layers: bool = false,
    onion_type: i32 = 0,

    // Timeline
    fps: i32 = 24,
    frame_size: i32 = 12,
    timeline_size: i32 = 240,
    label_font_size: i32 = 12,
    draw_label: bool = false,
    short_scrub: bool = false,

    // Drawing
    curve_smoothing: i32 = 20,
    invisible_lines: bool = false,
    outlines: bool = false,
    quick_sizing: bool = true,

    // Auto-save
    auto_save: bool = true,
    auto_save_number: i32 = 15,

    // Camera
    field_w: i32 = 800,
    field_h: i32 = 600,

    // Flip
    flip_roll_msec: i32 = 100,
    flip_roll_drawings: i32 = 5,
    flip_inbetween_msec: i32 = 100,

    // Sound
    sound_scrub_active: bool = false,
    sound_scrub_msec: i32 = 100,

    // Overlay
    grid_size_w: i32 = 50,
    grid_size_h: i32 = 50,
    overlay_center: bool = false,
    overlay_thirds: bool = false,
    overlay_golden: bool = false,
    overlay_safe: bool = false,
    overlay_angle: i32 = 15,

    // View
    layer_visibility: i32 = 0,
    layer_visibility_threshold: f32 = 0.5,
    invert_drag_zoom: bool = false,
    invert_scroll_zoom: bool = false,
    rotation_increment: i32 = 15,

    // System
    frame_pool_size: i32 = 100,
    undo_redo_max_steps: i32 = 20,
    draw_on_empty_frame: DrawOnEmptyFrameAction = .create_new_key,
    load_most_recent: bool = false,
    show_selection_info: bool = false,

    /// Serialize preferences to JSON string.
    pub fn toJson(self: *const Preferences, allocator: Allocator) ![]u8 {
        var out: Io.Writer.Allocating = .init(allocator);
        const w = &out.writer;
        try w.writeByte('{');

        inline for (std.meta.fields(Preferences), 0..) |field, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("\"{s}\":", .{field.name});
            const val = @field(self, field.name);
            switch (@typeInfo(field.type)) {
                .bool => try w.writeAll(if (val) "true" else "false"),
                .int => try w.print("{d}", .{val}),
                .float => try w.print("{d}", .{val}),
                .@"enum" => try w.print("{d}", .{@intFromEnum(val)}),
                else => try w.writeAll("null"),
            }
        }

        try w.writeByte('}');
        return try out.toOwnedSlice();
    }

    /// Load preferences from a JSON Value.
    pub fn fromJsonValue(root: std.json.Value) Preferences {
        var prefs = Preferences{};
        if (root != .object) return prefs;

        inline for (std.meta.fields(Preferences)) |field| {
            if (root.object.get(field.name)) |val| {
                switch (@typeInfo(field.type)) {
                    .bool => {
                        if (val == .bool) @field(&prefs, field.name) = val.bool;
                    },
                    .int => {
                        if (val == .integer) @field(&prefs, field.name) = @intCast(val.integer);
                    },
                    .float => {
                        if (val == .float) @field(&prefs, field.name) = @floatCast(val.float);
                    },
                    .@"enum" => {
                        if (val == .integer) @field(&prefs, field.name) = @enumFromInt(@as(i32, @intCast(val.integer)));
                    },
                    else => {},
                }
            }
        }
        return prefs;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Preferences defaults" {
    const p = Preferences{};
    try std.testing.expect(p.antialias);
    try std.testing.expectEqual(@as(i32, 24), p.fps);
    try std.testing.expect(!p.grid);
}

test "Preferences toJson roundtrip" {
    const allocator = std.testing.allocator;
    var prefs = Preferences{};
    prefs.fps = 30;
    prefs.grid = true;
    prefs.curve_smoothing = 50;

    const json = try prefs.toJson(allocator);
    defer allocator.free(json);

    // Parse back
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const loaded = Preferences.fromJsonValue(parsed.value);
    try std.testing.expectEqual(@as(i32, 30), loaded.fps);
    try std.testing.expect(loaded.grid);
    try std.testing.expectEqual(@as(i32, 50), loaded.curve_smoothing);
    try std.testing.expect(loaded.antialias); // default preserved
}
