// Timeline — playback state and selection for animation.
// Ported from core_lib/src/managers/playbackmanager.h and selectionmanager.h

const std = @import("std");

/// Playback and timeline state.
pub const Timeline = struct {
    current_frame: i32 = 1,
    fps: i32 = 24,
    is_playing: bool = false,
    is_looping: bool = true,

    start_frame: i32 = 1,
    end_frame: i32 = 1,

    is_ranged_playback: bool = false,
    mark_in_frame: i32 = 1,
    mark_out_frame: i32 = 1,

    sound_enabled: bool = true,

    /// Onion skin settings
    onion_prev_frames: i32 = 3,
    onion_next_frames: i32 = 3,
    onion_enabled: bool = false,

    pub fn play(self: *Timeline) void {
        self.is_playing = true;
    }

    pub fn stop(self: *Timeline) void {
        self.is_playing = false;
    }

    pub fn gotoFrame(self: *Timeline, frame: i32) void {
        self.current_frame = @max(self.start_frame, @min(frame, self.end_frame));
    }

    pub fn nextFrame(self: *Timeline) void {
        if (self.current_frame >= self.effectiveEndFrame()) {
            if (self.is_looping) {
                self.current_frame = self.effectiveStartFrame();
            } else {
                self.is_playing = false;
            }
        } else {
            self.current_frame += 1;
        }
    }

    pub fn prevFrame(self: *Timeline) void {
        if (self.current_frame <= self.effectiveStartFrame()) {
            if (self.is_looping) {
                self.current_frame = self.effectiveEndFrame();
            }
        } else {
            self.current_frame -= 1;
        }
    }

    pub fn effectiveStartFrame(self: Timeline) i32 {
        return if (self.is_ranged_playback) self.mark_in_frame else self.start_frame;
    }

    pub fn effectiveEndFrame(self: Timeline) i32 {
        return if (self.is_ranged_playback) self.mark_out_frame else self.end_frame;
    }

    pub fn setRange(self: *Timeline, start: i32, end: i32) void {
        self.mark_in_frame = start;
        self.mark_out_frame = end;
        self.is_ranged_playback = true;
    }

    /// Frame duration in milliseconds.
    pub fn frameDurationMs(self: Timeline) f64 {
        return 1000.0 / @as(f64, @floatFromInt(self.fps));
    }

    /// Total duration in seconds.
    pub fn durationSec(self: Timeline) f64 {
        const frames: f64 = @floatFromInt(self.effectiveEndFrame() - self.effectiveStartFrame() + 1);
        return frames / @as(f64, @floatFromInt(self.fps));
    }
};

/// 2D selection state with transform.
pub const Selection = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,
    active: bool = false,

    // Transform state
    translate_x: f64 = 0,
    translate_y: f64 = 0,
    rotation: f64 = 0,
    scale_x: f64 = 1,
    scale_y: f64 = 1,

    pub fn setRect(self: *Selection, sx: f64, sy: f64, sw: f64, sh: f64) void {
        self.x = sx;
        self.y = sy;
        self.width = sw;
        self.height = sh;
        self.active = true;
    }

    pub fn clear(self: *Selection) void {
        self.* = .{};
    }

    pub fn translate(self: *Selection, dx: f64, dy: f64) void {
        self.translate_x += dx;
        self.translate_y += dy;
    }

    pub fn rotate(self: *Selection, angle: f64) void {
        self.rotation += angle;
    }

    pub fn scale(self: *Selection, sx: f64, sy: f64) void {
        self.scale_x *= sx;
        self.scale_y *= sy;
    }

    pub fn flipHorizontal(self: *Selection) void {
        self.scale_x = -self.scale_x;
    }

    pub fn flipVertical(self: *Selection) void {
        self.scale_y = -self.scale_y;
    }

    pub fn resetTransform(self: *Selection) void {
        self.translate_x = 0;
        self.translate_y = 0;
        self.rotation = 0;
        self.scale_x = 1;
        self.scale_y = 1;
    }

    pub fn contains(self: Selection, px: f64, py: f64) bool {
        return self.active and
            px >= self.x and px <= self.x + self.width and
            py >= self.y and py <= self.y + self.height;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Timeline playback" {
    var t = Timeline{ .start_frame = 1, .end_frame = 10, .fps = 12 };

    t.play();
    try std.testing.expect(t.is_playing);

    t.gotoFrame(5);
    try std.testing.expectEqual(@as(i32, 5), t.current_frame);

    // Next wraps with looping
    t.current_frame = 10;
    t.nextFrame();
    try std.testing.expectEqual(@as(i32, 1), t.current_frame);

    // Prev wraps
    t.prevFrame();
    try std.testing.expectEqual(@as(i32, 10), t.current_frame);

    // Stop at end without looping
    t.is_looping = false;
    t.current_frame = 10;
    t.nextFrame();
    try std.testing.expect(!t.is_playing);
}

test "Timeline ranged playback" {
    var t = Timeline{ .start_frame = 1, .end_frame = 100, .fps = 24 };
    t.setRange(20, 30);
    try std.testing.expect(t.is_ranged_playback);
    try std.testing.expectEqual(@as(i32, 20), t.effectiveStartFrame());
    try std.testing.expectEqual(@as(i32, 30), t.effectiveEndFrame());
}

test "Timeline duration" {
    const t = Timeline{ .start_frame = 1, .end_frame = 24, .fps = 24 };
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), t.durationSec(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 41.667), t.frameDurationMs(), 0.1);
}

test "Selection basics" {
    var sel = Selection{};
    try std.testing.expect(!sel.active);

    sel.setRect(10, 20, 100, 50);
    try std.testing.expect(sel.active);
    try std.testing.expect(sel.contains(50, 40));
    try std.testing.expect(!sel.contains(0, 0));

    sel.translate(5, 5);
    try std.testing.expectEqual(@as(f64, 5), sel.translate_x);

    sel.flipHorizontal();
    try std.testing.expectEqual(@as(f64, -1), sel.scale_x);

    sel.resetTransform();
    try std.testing.expectEqual(@as(f64, 1), sel.scale_x);

    sel.clear();
    try std.testing.expect(!sel.active);
}
