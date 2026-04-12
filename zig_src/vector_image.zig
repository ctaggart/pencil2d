// VectorImage — vector/bezier drawing data for a frame.
// Ported from core_lib/src/graphics/vector/vectorimage.h and beziercurve.h

const std = @import("std");
const Allocator = std.mem.Allocator;
const Point = @import("pencil2d.zig").Point;

pub const VertexRef = struct {
    curve: i32 = -1,
    vertex: i32 = -1,

    pub fn eql(a: VertexRef, b: VertexRef) bool {
        return a.curve == b.curve and a.vertex == b.vertex;
    }
};

/// A single cubic Bezier curve with control points, pressure, and style.
pub const BezierCurve = struct {
    origin: Point = .{ .x = 0, .y = 0 },
    vertices: std.ArrayList(Point) = .{},
    c1: std.ArrayList(Point) = .{},
    c2: std.ArrayList(Point) = .{},
    pressure: std.ArrayList(f32) = .{},
    selected: std.ArrayList(bool) = .{},

    color_number: i32 = 0,
    width: f32 = 2.0,
    feather: f32 = 0,
    variable_width: bool = false,
    invisible: bool = false,
    filled: bool = false,

    pub fn deinit(self: *BezierCurve, allocator: Allocator) void {
        self.vertices.deinit(allocator);
        self.c1.deinit(allocator);
        self.c2.deinit(allocator);
        self.pressure.deinit(allocator);
        self.selected.deinit(allocator);
        self.* = undefined;
    }

    pub fn clone(self: BezierCurve, allocator: Allocator) !BezierCurve {
        return .{
            .origin = self.origin,
            .vertices = .{ .items = try allocator.dupe(Point, self.vertices.items), .capacity = self.vertices.items.len },
            .c1 = .{ .items = try allocator.dupe(Point, self.c1.items), .capacity = self.c1.items.len },
            .c2 = .{ .items = try allocator.dupe(Point, self.c2.items), .capacity = self.c2.items.len },
            .pressure = .{ .items = try allocator.dupe(f32, self.pressure.items), .capacity = self.pressure.items.len },
            .selected = .{ .items = try allocator.dupe(bool, self.selected.items), .capacity = self.selected.items.len },
            .color_number = self.color_number,
            .width = self.width,
            .feather = self.feather,
            .variable_width = self.variable_width,
            .invisible = self.invisible,
            .filled = self.filled,
        };
    }

    /// Append a cubic segment (c1, c2, vertex, pressure).
    pub fn appendCubic(self: *BezierCurve, allocator: Allocator, ctrl1: Point, ctrl2: Point, vertex: Point, press: f32) !void {
        try self.c1.append(allocator, ctrl1);
        try self.c2.append(allocator, ctrl2);
        try self.vertices.append(allocator, vertex);
        try self.pressure.append(allocator, press);
        try self.selected.append(allocator, false);
    }

    pub fn vertexCount(self: BezierCurve) i32 {
        return @as(i32, @intCast(self.vertices.items.len)) + 1; // +1 for origin
    }

    /// Get vertex: index 0 = origin, 1..n = vertices array.
    pub fn getVertex(self: BezierCurve, idx: i32) ?Point {
        if (idx == 0) return self.origin;
        const i: usize = @intCast(idx - 1);
        if (i >= self.vertices.items.len) return null;
        return self.vertices.items[i];
    }

    pub fn setVertex(self: *BezierCurve, idx: i32, p: Point) void {
        if (idx == 0) {
            self.origin = p;
        } else {
            const i: usize = @intCast(idx - 1);
            if (i < self.vertices.items.len) self.vertices.items[i] = p;
        }
    }

    /// Evaluate point on segment i at parameter t ∈ [0,1].
    pub fn getPointOnCubic(self: BezierCurve, segment: usize, t: f64) ?Point {
        if (segment >= self.vertices.items.len) return null;
        const p0 = if (segment == 0) self.origin else self.vertices.items[segment - 1];
        const p3 = self.vertices.items[segment];
        const cp1 = self.c1.items[segment];
        const cp2 = self.c2.items[segment];

        const bezier = @import("pencil2d.zig").bezier;
        return bezier.pointOnCubic(p0, cp1, cp2, p3, t);
    }

    pub fn isSelected(self: BezierCurve, vertex_idx: i32) bool {
        if (vertex_idx == 0) return if (self.selected.items.len > 0) self.selected.items[0] else false;
        const i: usize = @intCast(vertex_idx - 1);
        return if (i < self.selected.items.len) self.selected.items[i] else false;
    }
};

/// A fill region defined by vertex references.
pub const BezierArea = struct {
    vertex_refs: std.ArrayList(VertexRef) = .{},
    color_number: i32 = 0,
    is_selected: bool = false,

    pub fn deinit(self: *BezierArea, allocator: Allocator) void {
        self.vertex_refs.deinit(allocator);
        self.* = undefined;
    }
};

/// A vector image containing curves and fill areas.
pub const VectorImage = struct {
    curves: std.ArrayList(BezierCurve) = .{},
    areas: std.ArrayList(BezierArea) = .{},
    opacity: f64 = 1.0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) VectorImage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VectorImage) void {
        for (self.curves.items) |*c| c.deinit(self.allocator);
        self.curves.deinit(self.allocator);
        for (self.areas.items) |*a| a.deinit(self.allocator);
        self.areas.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn curveCount(self: VectorImage) i32 {
        return @intCast(self.curves.items.len);
    }

    pub fn getCurve(self: *VectorImage, idx: usize) ?*BezierCurve {
        if (idx >= self.curves.items.len) return null;
        return &self.curves.items[idx];
    }

    pub fn addCurve(self: *VectorImage, curve: BezierCurve) !void {
        try self.curves.append(self.allocator, curve);
    }

    pub fn removeCurveAt(self: *VectorImage, idx: usize) bool {
        if (idx >= self.curves.items.len) return false;
        var removed = self.curves.orderedRemove(idx);
        removed.deinit(self.allocator);
        return true;
    }

    pub fn isEmpty(self: VectorImage) bool {
        return self.curves.items.len == 0;
    }

    pub fn selectAll(self: *VectorImage) void {
        for (self.curves.items) |*curve| {
            for (curve.selected.items) |*s| s.* = true;
        }
    }

    pub fn deselectAll(self: *VectorImage) void {
        for (self.curves.items) |*curve| {
            for (curve.selected.items) |*s| s.* = false;
        }
    }

    /// Apply color to all selected curves.
    pub fn applyColorToSelected(self: *VectorImage, color_number: i32) void {
        for (self.curves.items) |*curve| {
            for (curve.selected.items) |s| {
                if (s) {
                    curve.color_number = color_number;
                    break;
                }
            }
        }
    }

    /// Apply width to all selected curves.
    pub fn applyWidthToSelected(self: *VectorImage, w: f32) void {
        for (self.curves.items) |*curve| {
            for (curve.selected.items) |s| {
                if (s) {
                    curve.width = w;
                    break;
                }
            }
        }
    }

    pub fn clear(self: *VectorImage) void {
        for (self.curves.items) |*c| c.deinit(self.allocator);
        self.curves.clearRetainingCapacity();
        for (self.areas.items) |*a| a.deinit(self.allocator);
        self.areas.clearRetainingCapacity();
    }

    pub fn addArea(self: *VectorImage, area: BezierArea) !void {
        try self.areas.append(self.allocator, area);
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "BezierCurve basic ops" {
    const allocator = std.testing.allocator;
    var curve = BezierCurve{ .origin = .{ .x = 0, .y = 0 } };
    defer curve.deinit(allocator);

    try curve.appendCubic(allocator, .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 30, .y = 0 }, 1.0);
    try curve.appendCubic(allocator, .{ .x = 40, .y = 5 }, .{ .x = 50, .y = 10 }, .{ .x = 60, .y = 0 }, 0.8);

    try std.testing.expectEqual(@as(i32, 3), curve.vertexCount()); // origin + 2
    try std.testing.expectEqual(@as(f64, 0), curve.getVertex(0).?.x); // origin
    try std.testing.expectEqual(@as(f64, 30), curve.getVertex(1).?.x); // first vertex
    try std.testing.expectEqual(@as(f64, 60), curve.getVertex(2).?.x); // second vertex

    // Evaluate midpoint of first segment
    const mid = curve.getPointOnCubic(0, 0.5).?;
    try std.testing.expect(mid.x > 0 and mid.x < 30);
}

test "BezierCurve clone" {
    const allocator = std.testing.allocator;
    var original = BezierCurve{ .origin = .{ .x = 5, .y = 5 }, .width = 3.0 };
    defer original.deinit(allocator);

    try original.appendCubic(allocator, .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 30, .y = 0 }, 1.0);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expectEqual(@as(f64, 5), cloned.origin.x);
    try std.testing.expectEqual(@as(f32, 3.0), cloned.width);
    try std.testing.expectEqual(@as(usize, 1), cloned.vertices.items.len);
}

test "VectorImage CRUD" {
    const allocator = std.testing.allocator;
    var img = VectorImage.init(allocator);
    defer img.deinit();

    var c1 = BezierCurve{ .origin = .{ .x = 0, .y = 0 }, .color_number = 1 };
    try c1.appendCubic(allocator, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 15, .y = 0 }, 1.0);
    try img.addCurve(c1);

    var c2 = BezierCurve{ .origin = .{ .x = 100, .y = 100 }, .color_number = 2 };
    try c2.appendCubic(allocator, .{ .x = 110, .y = 100 }, .{ .x = 120, .y = 100 }, .{ .x = 130, .y = 100 }, 1.0);
    try img.addCurve(c2);

    try std.testing.expectEqual(@as(i32, 2), img.curveCount());
    try std.testing.expectEqual(@as(i32, 1), img.getCurve(0).?.color_number);

    // Select all + apply color
    img.selectAll();
    img.applyColorToSelected(5);
    try std.testing.expectEqual(@as(i32, 5), img.getCurve(0).?.color_number);

    // Remove
    try std.testing.expect(img.removeCurveAt(0));
    try std.testing.expectEqual(@as(i32, 1), img.curveCount());
    try std.testing.expectEqual(@as(f64, 100), img.getCurve(0).?.origin.x);
}

test "VectorImage clear" {
    const allocator = std.testing.allocator;
    var img = VectorImage.init(allocator);
    defer img.deinit();

    var c = BezierCurve{ .origin = .{ .x = 0, .y = 0 } };
    try c.appendCubic(allocator, .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 15, .y = 0 }, 1.0);
    try img.addCurve(c);

    try std.testing.expect(!img.isEmpty());
    img.clear();
    try std.testing.expect(img.isEmpty());
}
