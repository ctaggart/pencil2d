// Object — a Pencil2D project containing layers and a color palette.
// Ported from core_lib/src/structure/object.h

const std = @import("std");
const Allocator = std.mem.Allocator;
const Layer = @import("layer.zig").Layer;
const LayerType = @import("layer.zig").LayerType;

pub const ColorRef = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,
    name: []const u8 = "",
    name_owned: bool = false,

    pub fn deinit(self: *ColorRef, allocator: Allocator) void {
        if (self.name_owned) allocator.free(self.name);
        self.* = undefined;
    }

    pub fn fromRgba(r: u8, g: u8, b: u8, a: u8, name: []const u8) ColorRef {
        return .{ .r = r, .g = g, .b = b, .a = a, .name = name };
    }
};

pub const Object = struct {
    layers: std.ArrayList(*Layer) = .empty,
    palette: std.ArrayList(ColorRef) = .empty,
    file_path: ?[]const u8 = null,
    file_path_owned: bool = false,
    is_modified: bool = false,
    next_layer_id: i32 = 1,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Object {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Object) void {
        for (self.layers.items) |layer| {
            var l = layer;
            l.deinit();
            self.allocator.destroy(l);
        }
        self.layers.deinit(self.allocator);
        for (self.palette.items) |*c| c.deinit(self.allocator);
        self.palette.deinit(self.allocator);
        if (self.file_path_owned) if (self.file_path) |p| self.allocator.free(p);
        self.* = undefined;
    }

    // ── Layer management ─────────────────────────────────────────────

    pub fn layerCount(self: Object) i32 {
        return @intCast(self.layers.items.len);
    }

    pub fn getLayer(self: Object, index: usize) ?*Layer {
        if (index >= self.layers.items.len) return null;
        return self.layers.items[index];
    }

    pub fn findLayerByName(self: Object, name: []const u8) ?*Layer {
        for (self.layers.items) |layer| {
            if (std.mem.eql(u8, layer.name, name)) return layer;
        }
        return null;
    }

    pub fn findLayerById(self: Object, layer_id: i32) ?*Layer {
        for (self.layers.items) |layer| {
            if (layer.id == layer_id) return layer;
        }
        return null;
    }

    pub fn addNewLayer(self: *Object, layer_type: LayerType, name: []const u8) !*Layer {
        const layer = try self.allocator.create(Layer);
        layer.* = try Layer.init(self.allocator, self.next_layer_id, layer_type, name);
        self.next_layer_id += 1;
        try self.layers.append(self.allocator, layer);
        self.is_modified = true;
        return layer;
    }

    pub fn deleteLayer(self: *Object, index: usize) bool {
        if (index >= self.layers.items.len) return false;
        var layer = self.layers.orderedRemove(index);
        layer.deinit();
        self.allocator.destroy(layer);
        self.is_modified = true;
        return true;
    }

    pub fn swapLayers(self: *Object, i: usize, j: usize) bool {
        if (i >= self.layers.items.len or j >= self.layers.items.len) return false;
        const tmp = self.layers.items[i];
        self.layers.items[i] = self.layers.items[j];
        self.layers.items[j] = tmp;
        self.is_modified = true;
        return true;
    }

    /// Total keyframes across all layers.
    pub fn totalKeyFrameCount(self: Object) i32 {
        var total: i32 = 0;
        for (self.layers.items) |layer| {
            total += layer.keyFrameCount();
        }
        return total;
    }

    /// Animation length (max frame end across all layers).
    pub fn animationLength(self: Object) i32 {
        var max_len: i32 = 0;
        for (self.layers.items) |layer| {
            const len = layer.animationLength();
            if (len > max_len) max_len = len;
        }
        return max_len;
    }

    // ── Color palette ────────────────────────────────────────────────

    pub fn colorCount(self: Object) i32 {
        return @intCast(self.palette.items.len);
    }

    pub fn getColor(self: Object, index: usize) ?ColorRef {
        if (index >= self.palette.items.len) return null;
        return self.palette.items[index];
    }

    pub fn addColor(self: *Object, color: ColorRef) !void {
        try self.palette.append(self.allocator, color);
        self.is_modified = true;
    }

    pub fn removeColor(self: *Object, index: usize) bool {
        if (index >= self.palette.items.len) return false;
        var removed = self.palette.orderedRemove(index);
        removed.deinit(self.allocator);
        self.is_modified = true;
        return true;
    }

    pub fn setColor(self: *Object, index: usize, r: u8, g: u8, b: u8, a: u8) bool {
        if (index >= self.palette.items.len) return false;
        self.palette.items[index].r = r;
        self.palette.items[index].g = g;
        self.palette.items[index].b = b;
        self.palette.items[index].a = a;
        self.is_modified = true;
        return true;
    }

    // ── File path ────────────────────────────────────────────────────

    pub fn setFilePath(self: *Object, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        if (self.file_path_owned) if (self.file_path) |p| self.allocator.free(p);
        self.file_path = duped;
        self.file_path_owned = true;
    }

    /// Load a default palette with common colors.
    pub fn loadDefaultPalette(self: *Object) !void {
        const defaults = [_]struct { r: u8, g: u8, b: u8, name: []const u8 }{
            .{ .r = 0, .g = 0, .b = 0, .name = "Black" },
            .{ .r = 255, .g = 0, .b = 0, .name = "Red" },
            .{ .r = 0, .g = 255, .b = 0, .name = "Green" },
            .{ .r = 0, .g = 0, .b = 255, .name = "Blue" },
            .{ .r = 255, .g = 255, .b = 0, .name = "Yellow" },
            .{ .r = 255, .g = 255, .b = 255, .name = "White" },
        };
        for (defaults) |d| {
            try self.addColor(.{ .r = d.r, .g = d.g, .b = d.b, .name = d.name });
        }
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "Object create layers" {
    const allocator = std.testing.allocator;
    var obj = Object.init(allocator);
    defer obj.deinit();

    const bg = try obj.addNewLayer(.bitmap, "Background");
    _ = try obj.addNewLayer(.bitmap, "Foreground");
    _ = try obj.addNewLayer(.camera, "Camera");

    try std.testing.expectEqual(@as(i32, 3), obj.layerCount());
    try std.testing.expectEqualStrings("Background", obj.getLayer(0).?.name);
    try std.testing.expectEqual(@as(i32, 1), bg.id);
    try std.testing.expectEqual(@as(i32, 2), obj.getLayer(1).?.id);
}

test "Object find layer" {
    const allocator = std.testing.allocator;
    var obj = Object.init(allocator);
    defer obj.deinit();

    _ = try obj.addNewLayer(.bitmap, "Layer A");
    _ = try obj.addNewLayer(.vector, "Layer B");

    try std.testing.expectEqualStrings("Layer B", obj.findLayerByName("Layer B").?.name);
    try std.testing.expect(obj.findLayerByName("Nonexistent") == null);
    try std.testing.expectEqualStrings("Layer A", obj.findLayerById(1).?.name);
}

test "Object delete and swap layers" {
    const allocator = std.testing.allocator;
    var obj = Object.init(allocator);
    defer obj.deinit();

    _ = try obj.addNewLayer(.bitmap, "A");
    _ = try obj.addNewLayer(.bitmap, "B");
    _ = try obj.addNewLayer(.bitmap, "C");

    // Swap A and C
    try std.testing.expect(obj.swapLayers(0, 2));
    try std.testing.expectEqualStrings("C", obj.getLayer(0).?.name);
    try std.testing.expectEqualStrings("A", obj.getLayer(2).?.name);

    // Delete middle
    try std.testing.expect(obj.deleteLayer(1));
    try std.testing.expectEqual(@as(i32, 2), obj.layerCount());
}

test "Object animation length" {
    const allocator = std.testing.allocator;
    var obj = Object.init(allocator);
    defer obj.deinit();

    const layer = try obj.addNewLayer(.bitmap, "Anim");
    _ = try layer.addNewKeyFrameAt(1);
    _ = try layer.addNewKeyFrameAt(10);
    layer.getKeyFrameAt(10).?.length = 5;

    try std.testing.expectEqual(@as(i32, 15), obj.animationLength());
    try std.testing.expectEqual(@as(i32, 2), obj.totalKeyFrameCount());
}

test "Object palette" {
    const allocator = std.testing.allocator;
    var obj = Object.init(allocator);
    defer obj.deinit();

    try obj.loadDefaultPalette();
    try std.testing.expectEqual(@as(i32, 6), obj.colorCount());
    try std.testing.expectEqual(@as(u8, 0), obj.getColor(0).?.r); // Black
    try std.testing.expectEqual(@as(u8, 255), obj.getColor(1).?.r); // Red

    // Modify
    try std.testing.expect(obj.setColor(0, 128, 128, 128, 255));
    try std.testing.expectEqual(@as(u8, 128), obj.getColor(0).?.r);

    // Remove
    try std.testing.expect(obj.removeColor(0));
    try std.testing.expectEqual(@as(i32, 5), obj.colorCount());
}
