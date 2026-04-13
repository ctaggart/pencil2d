// Managers — Zig ports of Pencil2D's manager layer.
// Each manager is a pure data struct with optional callbacks,
// replacing QObject signals with function pointers.

const std = @import("std");
const pencil2d = @import("pencil2d.zig");

// ── PlaybackManager ──────────────────────────────────────────────────

pub const PlaybackManager = struct {
    fps: i32 = 24,
    current_frame: i32 = 1,
    start_frame: i32 = 1,
    end_frame: i32 = 1,

    is_playing: bool = false,
    is_looping: bool = true,
    sound_enabled: bool = true,

    is_ranged: bool = false,
    mark_in: i32 = 1,
    mark_out: i32 = 1,

    on_frame_changed: ?*const fn (i32) callconv(.c) void = null,
    on_play_state_changed: ?*const fn (bool) callconv(.c) void = null,

    pub fn play(self: *PlaybackManager) void {
        self.is_playing = true;
        if (self.on_play_state_changed) |cb| cb(true);
    }

    pub fn stop(self: *PlaybackManager) void {
        self.is_playing = false;
        if (self.on_play_state_changed) |cb| cb(false);
    }

    pub fn scrubTo(self: *PlaybackManager, frame: i32) void {
        self.current_frame = std.math.clamp(frame, self.effectiveStart(), self.effectiveEnd());
        if (self.on_frame_changed) |cb| cb(self.current_frame);
    }

    pub fn nextFrame(self: *PlaybackManager) void {
        if (self.current_frame >= self.effectiveEnd()) {
            if (self.is_looping) {
                self.scrubTo(self.effectiveStart());
            } else {
                self.stop();
            }
        } else {
            self.scrubTo(self.current_frame + 1);
        }
    }

    pub fn effectiveStart(self: PlaybackManager) i32 {
        return if (self.is_ranged) self.mark_in else self.start_frame;
    }

    pub fn effectiveEnd(self: PlaybackManager) i32 {
        return if (self.is_ranged) self.mark_out else self.end_frame;
    }

    pub fn setFps(self: *PlaybackManager, fps: i32) void {
        self.fps = @max(1, fps);
    }

    pub fn frameDurationMs(self: PlaybackManager) f64 {
        return 1000.0 / @as(f64, @floatFromInt(self.fps));
    }
};

// ── ColorManager ─────────────────────────────────────────────────────

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn toArgb(self: Color) u32 {
        return (@as(u32, self.a) << 24) | (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | self.b;
    }

    pub fn fromArgb(argb: u32) Color {
        return .{
            .a = @truncate(argb >> 24),
            .r = @truncate(argb >> 16),
            .g = @truncate(argb >> 8),
            .b = @truncate(argb),
        };
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

pub const ColorManager = struct {
    front_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    color_number: i32 = 0,
    on_color_changed: ?*const fn (u32) callconv(.c) void = null,

    pub fn setFrontColor(self: *ColorManager, c: Color) void {
        self.front_color = c;
        if (self.on_color_changed) |cb| cb(c.toArgb());
    }

    pub fn setColorNumber(self: *ColorManager, n: i32) void {
        self.color_number = n;
    }
};

// ── ViewManager ──────────────────────────────────────────────────────

pub const ViewManager = struct {
    zoom: f64 = 1.0,
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    rotation: f64 = 0,
    is_flipped: bool = false,

    on_view_changed: ?*const fn () callconv(.c) void = null,

    pub fn setZoom(self: *ViewManager, z: f64) void {
        self.zoom = @max(0.01, @min(z, 100.0));
        self.notify();
    }

    pub fn zoomIn(self: *ViewManager) void {
        self.setZoom(self.zoom * 1.2);
    }

    pub fn zoomOut(self: *ViewManager) void {
        self.setZoom(self.zoom / 1.2);
    }

    pub fn pan(self: *ViewManager, dx: f64, dy: f64) void {
        self.offset_x += dx;
        self.offset_y += dy;
        self.notify();
    }

    pub fn rotate(self: *ViewManager, angle: f64) void {
        self.rotation += angle;
        if (self.rotation > 360) self.rotation -= 360;
        if (self.rotation < 0) self.rotation += 360;
        self.notify();
    }

    pub fn resetView(self: *ViewManager) void {
        self.zoom = 1.0;
        self.offset_x = 0;
        self.offset_y = 0;
        self.rotation = 0;
        self.is_flipped = false;
        self.notify();
    }

    pub fn flip(self: *ViewManager) void {
        self.is_flipped = !self.is_flipped;
        self.notify();
    }

    fn notify(self: ViewManager) void {
        if (self.on_view_changed) |cb| cb();
    }

    pub fn getTransform(self: ViewManager) pencil2d.Matrix {
        const t = pencil2d.Matrix.translation(self.offset_x, self.offset_y);
        const r = pencil2d.Matrix.rotation(self.rotation * (std.math.pi / 180.0));
        const s = pencil2d.Matrix.scale(
            if (self.is_flipped) -self.zoom else self.zoom,
            self.zoom,
        );
        return t.multiply(r).multiply(s);
    }
};

// ── SelectionManager ─────────────────────────────────────────────────

pub const MoveMode = enum(i32) {
    none = 0,
    translate = 1,
    rotate = 2,
    scale_top_left = 3,
    scale_top_right = 4,
    scale_bottom_left = 5,
    scale_bottom_right = 6,
    scale_left = 7,
    scale_right = 8,
    scale_top = 9,
    scale_bottom = 10,
};

pub const SelectionManager = struct {
    rect_x: f64 = 0,
    rect_y: f64 = 0,
    rect_w: f64 = 0,
    rect_h: f64 = 0,
    active: bool = false,
    move_mode: MoveMode = .none,

    translate_x: f64 = 0,
    translate_y: f64 = 0,
    rotation: f64 = 0,
    scale_x: f64 = 1,
    scale_y: f64 = 1,

    on_selection_changed: ?*const fn () callconv(.c) void = null,

    pub fn setSelection(self: *SelectionManager, x: f64, y: f64, w: f64, h: f64) void {
        self.rect_x = x;
        self.rect_y = y;
        self.rect_w = w;
        self.rect_h = h;
        self.active = true;
        self.resetTransform();
    }

    pub fn clearSelection(self: *SelectionManager) void {
        self.active = false;
        self.rect_w = 0;
        self.rect_h = 0;
        self.resetTransform();
    }

    pub fn translate(self: *SelectionManager, dx: f64, dy: f64) void {
        self.translate_x += dx;
        self.translate_y += dy;
    }

    pub fn flipHorizontal(self: *SelectionManager) void {
        self.scale_x = -self.scale_x;
    }

    pub fn flipVertical(self: *SelectionManager) void {
        self.scale_y = -self.scale_y;
    }

    pub fn resetTransform(self: *SelectionManager) void {
        self.translate_x = 0;
        self.translate_y = 0;
        self.rotation = 0;
        self.scale_x = 1;
        self.scale_y = 1;
    }

    pub fn somethingSelected(self: SelectionManager) bool {
        return self.active and self.rect_w > 0 and self.rect_h > 0;
    }
};

// ── LayerManager ─────────────────────────────────────────────────────

pub const LayerManager = struct {
    current_layer_index: i32 = 0,
    on_layer_changed: ?*const fn (i32) callconv(.c) void = null,
    on_layer_count_changed: ?*const fn () callconv(.c) void = null,

    pub fn setCurrentLayer(self: *LayerManager, index: i32) void {
        self.current_layer_index = index;
        if (self.on_layer_changed) |cb| cb(index);
    }
};

// ── ToolManager ──────────────────────────────────────────────────────

pub const ToolType = pencil2d.ToolType;

pub const ToolProperties = struct {
    width: f32 = 2.0,
    feather: f32 = 0,
    opacity: f32 = 1.0,
    pressure_enabled: bool = true,
    anti_aliasing: bool = true,
    stabilizer: i32 = 0,
};

pub const ToolManager = struct {
    current_tool: ToolType = .pencil,
    properties: [12]ToolProperties = [_]ToolProperties{.{}} ** 12,
    on_tool_changed: ?*const fn (ToolType) callconv(.c) void = null,

    pub fn setCurrentTool(self: *ToolManager, tool: ToolType) void {
        self.current_tool = tool;
        if (self.on_tool_changed) |cb| cb(tool);
    }

    pub fn currentProperties(self: *ToolManager) *ToolProperties {
        const idx: usize = @intCast(@intFromEnum(self.current_tool));
        if (idx < self.properties.len) return &self.properties[idx];
        return &self.properties[0];
    }

    pub fn setWidth(self: *ToolManager, w: f32) void {
        self.currentProperties().width = @max(0.1, @min(w, 200.0));
    }

    pub fn setOpacity(self: *ToolManager, o: f32) void {
        self.currentProperties().opacity = @max(0, @min(o, 1.0));
    }
};

// ── OverlayManager ──────────────────────────────────────────────────

pub const OverlayManager = struct {
    show_grid: bool = false,
    grid_size: i32 = 50,
    show_center: bool = false,
    show_safe_area: bool = false,
    show_thirds: bool = false,
    show_golden_ratio: bool = false,

    pub fn toggleGrid(self: *OverlayManager) void {
        self.show_grid = !self.show_grid;
    }

    pub fn toggleCenter(self: *OverlayManager) void {
        self.show_center = !self.show_center;
    }

    pub fn toggleSafeArea(self: *OverlayManager) void {
        self.show_safe_area = !self.show_safe_area;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "PlaybackManager basic" {
    var pm = PlaybackManager{ .end_frame = 10 };
    pm.play();
    try std.testing.expect(pm.is_playing);
    pm.scrubTo(5);
    try std.testing.expectEqual(@as(i32, 5), pm.current_frame);
    pm.nextFrame();
    try std.testing.expectEqual(@as(i32, 6), pm.current_frame);

    // Loop at end
    pm.scrubTo(10);
    pm.nextFrame();
    try std.testing.expectEqual(@as(i32, 1), pm.current_frame);

    // Stop without loop
    pm.is_looping = false;
    pm.scrubTo(10);
    pm.nextFrame();
    try std.testing.expect(!pm.is_playing);
}

test "PlaybackManager ranged" {
    var pm = PlaybackManager{ .end_frame = 100 };
    pm.is_ranged = true;
    pm.mark_in = 20;
    pm.mark_out = 30;
    try std.testing.expectEqual(@as(i32, 20), pm.effectiveStart());
    pm.scrubTo(50);
    try std.testing.expectEqual(@as(i32, 30), pm.current_frame); // clamped
}

test "ColorManager" {
    var cm = ColorManager{};
    cm.setFrontColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(u8, 255), cm.front_color.r);
    try std.testing.expectEqual(@as(u8, 0), cm.front_color.g);
}

test "Color argb roundtrip" {
    const c = Color{ .r = 128, .g = 64, .b = 32, .a = 200 };
    const argb = c.toArgb();
    const back = Color.fromArgb(argb);
    try std.testing.expect(Color.eql(c, back));
}

test "ViewManager zoom and transform" {
    var vm = ViewManager{};
    vm.zoomIn();
    try std.testing.expect(vm.zoom > 1.0);
    vm.pan(100, 50);
    try std.testing.expectEqual(@as(f64, 100), vm.offset_x);

    const m = vm.getTransform();
    const p = m.mapPoint(.{ .x = 0, .y = 0 });
    try std.testing.expect(p.x != 0); // translated
    vm.resetView();
    try std.testing.expectEqual(@as(f64, 1.0), vm.zoom);
}

test "SelectionManager" {
    var sm = SelectionManager{};
    try std.testing.expect(!sm.somethingSelected());
    sm.setSelection(10, 20, 100, 50);
    try std.testing.expect(sm.somethingSelected());
    sm.translate(5, 5);
    try std.testing.expectEqual(@as(f64, 5), sm.translate_x);
    sm.flipHorizontal();
    try std.testing.expectEqual(@as(f64, -1), sm.scale_x);
    sm.clearSelection();
    try std.testing.expect(!sm.somethingSelected());
}

test "ToolManager" {
    var tm = ToolManager{};
    try std.testing.expectEqual(ToolType.pencil, tm.current_tool);
    tm.setCurrentTool(.brush);
    try std.testing.expectEqual(ToolType.brush, tm.current_tool);
    tm.setWidth(10.0);
    try std.testing.expectEqual(@as(f32, 10.0), tm.currentProperties().width);
}

test "OverlayManager" {
    var om = OverlayManager{};
    try std.testing.expect(!om.show_grid);
    om.toggleGrid();
    try std.testing.expect(om.show_grid);
}
