// Layer — animation layer containing keyframes on a timeline.
// Ported from core_lib/src/structure/layer.h

const std = @import("std");
const Allocator = std.mem.Allocator;
const KeyFrame = @import("keyframe.zig").KeyFrame;

pub const LayerType = enum(u8) {
    undefined = 0,
    bitmap = 1,
    vector = 2,
    sound = 4,
    camera = 5,
};

pub const Layer = struct {
    id: i32 = 0,
    layer_type: LayerType = .undefined,
    name: []const u8 = "",
    name_owned: bool = false,
    visible: bool = true,
    frames: std.ArrayList(KeyFrame) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: i32, layer_type: LayerType, name: []const u8) !Layer {
        return .{
            .id = id,
            .layer_type = layer_type,
            .name = try allocator.dupe(u8, name),
            .name_owned = true,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Layer) void {
        for (self.frames.items) |*kf| kf.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        if (self.name_owned) self.allocator.free(self.name);
        self.* = undefined;
    }

    pub fn setName(self: *Layer, new_name: []const u8) !void {
        const duped = try self.allocator.dupe(u8, new_name);
        if (self.name_owned) self.allocator.free(self.name);
        self.name = duped;
        self.name_owned = true;
    }

    // ── KeyFrame queries ─────────────────────────────────────────────

    pub fn keyFrameCount(self: Layer) i32 {
        return @intCast(self.frames.items.len);
    }

    pub fn keyExists(self: Layer, position: i32) bool {
        return self.findIndex(position) != null;
    }

    pub fn getKeyFrameAt(self: Layer, position: i32) ?*KeyFrame {
        const idx = self.findIndex(position) orelse return null;
        return &self.frames.items[idx];
    }

    pub fn getKeyFrameAtConst(self: *const Layer, position: i32) ?*const KeyFrame {
        const idx = self.findIndex(position) orelse return null;
        return &self.frames.items[idx];
    }

    /// Get the last keyframe at or before this position.
    pub fn getLastKeyFrameAtPosition(self: Layer, position: i32) ?*KeyFrame {
        var best: ?usize = null;
        for (self.frames.items, 0..) |*kf, i| {
            if (kf.pos <= position) {
                if (best == null or kf.pos > self.frames.items[best.?].pos) {
                    best = i;
                }
            }
        }
        if (best) |idx| return &self.frames.items[idx];
        return null;
    }

    pub fn firstKeyFramePosition(self: Layer) i32 {
        if (self.frames.items.len == 0) return 0;
        var min_pos: i32 = std.math.maxInt(i32);
        for (self.frames.items) |kf| {
            if (kf.pos < min_pos) min_pos = kf.pos;
        }
        return min_pos;
    }

    pub fn getMaxKeyFramePosition(self: Layer) i32 {
        if (self.frames.items.len == 0) return 0;
        var max_pos: i32 = std.math.minInt(i32);
        for (self.frames.items) |kf| {
            if (kf.pos > max_pos) max_pos = kf.pos;
        }
        return max_pos;
    }

    pub fn getPreviousKeyFramePosition(self: Layer, position: i32) i32 {
        var best: i32 = std.math.minInt(i32);
        for (self.frames.items) |kf| {
            if (kf.pos < position and kf.pos > best) best = kf.pos;
        }
        return if (best == std.math.minInt(i32)) position else best;
    }

    pub fn getNextKeyFramePosition(self: Layer, position: i32) i32 {
        var best: i32 = std.math.maxInt(i32);
        for (self.frames.items) |kf| {
            if (kf.pos > position and kf.pos < best) best = kf.pos;
        }
        return if (best == std.math.maxInt(i32)) position else best;
    }

    /// Animation length: max keyframe position + its exposure length.
    pub fn animationLength(self: Layer) i32 {
        var max_end: i32 = 0;
        for (self.frames.items) |kf| {
            const end = kf.pos + kf.length;
            if (end > max_end) max_end = end;
        }
        return max_end;
    }

    // ── KeyFrame mutations ───────────────────────────────────────────

    /// Add a new empty keyframe. Returns false if one already exists.
    pub fn addNewKeyFrameAt(self: *Layer, position: i32) !bool {
        if (self.keyExists(position)) return false;
        try self.frames.append(self.allocator, .{ .pos = position });
        return true;
    }

    /// Add a keyframe at position. Returns false if one already exists.
    pub fn addKeyFrame(self: *Layer, position: i32, kf: KeyFrame) !bool {
        if (self.keyExists(position)) return false;
        var frame = kf;
        frame.pos = position;
        try self.frames.append(self.allocator, frame);
        return true;
    }

    /// Remove keyframe at position. Returns false if none exists.
    pub fn removeKeyFrame(self: *Layer, position: i32) bool {
        const idx = self.findIndex(position) orelse return false;
        var removed = self.frames.orderedRemove(idx);
        removed.deinit(self.allocator);
        return true;
    }

    /// Swap positions of two keyframes.
    pub fn swapKeyFrames(self: *Layer, pos1: i32, pos2: i32) bool {
        const idx1 = self.findIndex(pos1) orelse return false;
        const idx2 = self.findIndex(pos2) orelse return false;
        self.frames.items[idx1].pos = pos2;
        self.frames.items[idx2].pos = pos1;
        return true;
    }

    /// Move keyframe from position by offset.
    pub fn moveKeyFrame(self: *Layer, position: i32, offset: i32) bool {
        const new_pos = position + offset;
        if (new_pos < 1) return false;
        if (self.keyExists(new_pos)) return false;
        const idx = self.findIndex(position) orelse return false;
        self.frames.items[idx].pos = new_pos;
        return true;
    }

    // ── Internals ────────────────────────────────────────────────────

    fn findIndex(self: anytype, position: i32) ?usize {
        const items = self.frames.items;
        for (items, 0..) |kf, i| {
            if (kf.pos == position) return i;
        }
        return null;
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Layer add and query keyframes" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Layer 1");
    defer layer.deinit();

    try std.testing.expect(try layer.addNewKeyFrameAt(1));
    try std.testing.expect(try layer.addNewKeyFrameAt(5));
    try std.testing.expect(try layer.addNewKeyFrameAt(10));
    try std.testing.expect(!try layer.addNewKeyFrameAt(5)); // duplicate

    try std.testing.expectEqual(@as(i32, 3), layer.keyFrameCount());
    try std.testing.expect(layer.keyExists(5));
    try std.testing.expect(!layer.keyExists(6));

    try std.testing.expectEqual(@as(i32, 1), layer.firstKeyFramePosition());
    try std.testing.expectEqual(@as(i32, 10), layer.getMaxKeyFramePosition());
}

test "Layer navigation" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Nav");
    defer layer.deinit();

    _ = try layer.addNewKeyFrameAt(1);
    _ = try layer.addNewKeyFrameAt(5);
    _ = try layer.addNewKeyFrameAt(10);

    try std.testing.expectEqual(@as(i32, 5), layer.getNextKeyFramePosition(1));
    try std.testing.expectEqual(@as(i32, 10), layer.getNextKeyFramePosition(5));
    try std.testing.expectEqual(@as(i32, 10), layer.getNextKeyFramePosition(10)); // no next

    try std.testing.expectEqual(@as(i32, 5), layer.getPreviousKeyFramePosition(10));
    try std.testing.expectEqual(@as(i32, 1), layer.getPreviousKeyFramePosition(5));
    try std.testing.expectEqual(@as(i32, 1), layer.getPreviousKeyFramePosition(1)); // no prev
}

test "Layer remove and move keyframes" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Ops");
    defer layer.deinit();

    _ = try layer.addNewKeyFrameAt(1);
    _ = try layer.addNewKeyFrameAt(5);
    _ = try layer.addNewKeyFrameAt(10);

    // Remove
    try std.testing.expect(layer.removeKeyFrame(5));
    try std.testing.expectEqual(@as(i32, 2), layer.keyFrameCount());
    try std.testing.expect(!layer.keyExists(5));

    // Move
    try std.testing.expect(layer.moveKeyFrame(1, 4)); // 1 → 5
    try std.testing.expect(layer.keyExists(5));
    try std.testing.expect(!layer.keyExists(1));

    // Move blocked by existing
    try std.testing.expect(!layer.moveKeyFrame(5, 5)); // 5 → 10, blocked
}

test "Layer swap keyframes" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Swap");
    defer layer.deinit();

    _ = try layer.addNewKeyFrameAt(1);
    _ = try layer.addNewKeyFrameAt(10);

    layer.getKeyFrameAt(1).?.length = 3;
    layer.getKeyFrameAt(10).?.length = 7;

    try std.testing.expect(layer.swapKeyFrames(1, 10));

    try std.testing.expectEqual(@as(i32, 7), layer.getKeyFrameAt(1).?.length);
    try std.testing.expectEqual(@as(i32, 3), layer.getKeyFrameAt(10).?.length);
}

test "Layer getLastKeyFrameAtPosition" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Last");
    defer layer.deinit();

    _ = try layer.addNewKeyFrameAt(1);
    _ = try layer.addNewKeyFrameAt(5);
    _ = try layer.addNewKeyFrameAt(10);

    // Exact match
    try std.testing.expectEqual(@as(i32, 5), layer.getLastKeyFrameAtPosition(5).?.pos);
    // Between frames
    try std.testing.expectEqual(@as(i32, 5), layer.getLastKeyFrameAtPosition(7).?.pos);
    // Before any
    try std.testing.expect(layer.getLastKeyFrameAtPosition(0) == null);
}

test "Layer rename" {
    const allocator = std.testing.allocator;
    var layer = try Layer.init(allocator, 1, .bitmap, "Old Name");
    defer layer.deinit();

    try std.testing.expectEqualStrings("Old Name", layer.name);
    try layer.setName("New Name");
    try std.testing.expectEqualStrings("New Name", layer.name);
}
