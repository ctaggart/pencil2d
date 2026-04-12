// PCLX file loader — reads .pclx archives into an Object.
// A .pclx file is a ZIP containing main.xml + data files (PNGs, VECs).

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");
const ZipReader = @import("pclx_zip.zig").ZipReader;
const Object = @import("object.zig").Object;
const ColorRef = @import("object.zig").ColorRef;
const Layer = @import("layer.zig").Layer;
const LayerType = @import("layer.zig").LayerType;
const KeyFrame = @import("keyframe.zig").KeyFrame;
const BitmapData = @import("keyframe.zig").BitmapData;
const CameraData = @import("keyframe.zig").CameraData;
const SoundData = @import("keyframe.zig").SoundData;

pub const PclxError = error{
    MainXmlNotFound,
    InvalidFormat,
    InvalidXml,
    OutOfMemory,
};

/// Load a .pclx file from a memory buffer into an Object.
pub fn load(allocator: Allocator, pclx_data: []const u8) !Object {
    var zip = try ZipReader.init(allocator, pclx_data);
    defer zip.deinit();

    // Find and extract main.xml
    const main_xml_data = blk: {
        var i: usize = 0;
        while (i < zip.count()) : (i += 1) {
            const name = zip.entryName(i) orelse continue;
            if (std.mem.eql(u8, name, "main.xml")) {
                break :blk try zip.extract(i, allocator);
            }
        }
        return error.MainXmlNotFound;
    };
    defer allocator.free(main_xml_data);

    // Parse XML
    var doc = xml.parse(allocator, main_xml_data) catch return error.InvalidXml;
    defer doc.deinit();

    if (!std.mem.eql(u8, doc.root.tag, "document")) return error.InvalidFormat;

    var obj = Object.init(allocator);
    errdefer obj.deinit();

    // Parse object element (contains layers)
    if (doc.root.findChild("object")) |obj_elem| {
        var layer_iter = obj_elem.childrenByTag("layer");
        while (layer_iter.next()) |layer_elem| {
            try loadLayer(&obj, layer_elem);
        }
    }

    // Parse version
    // (stored for info but not critical)

    return obj;
}

fn loadLayer(obj: *Object, elem: *const xml.Element) !void {
    const layer_type_int = elem.attrInt("type", 0);
    const layer_type: LayerType = switch (layer_type_int) {
        1 => .bitmap,
        2 => .vector,
        4 => .sound,
        5 => .camera,
        else => .undefined,
    };

    const name = elem.attr("name") orelse "untitled";
    const layer = try obj.addNewLayer(layer_type, name);

    const id = elem.attrInt("id", layer.id);
    layer.id = id;
    if (id >= obj.next_layer_id) obj.next_layer_id = id + 1;

    layer.visible = elem.attrInt("visibility", 1) != 0;

    // Load keyframes based on layer type
    switch (layer_type) {
        .bitmap => try loadBitmapFrames(layer, elem),
        .camera => try loadCameraFrames(layer, elem),
        .sound => try loadSoundFrames(layer, elem),
        .vector => try loadVectorFrames(layer, elem),
        .undefined => {},
    }
}

fn loadBitmapFrames(layer: *Layer, elem: *const xml.Element) !void {
    var iter = elem.childrenByTag("image");
    while (iter.next()) |img| {
        const frame = img.attrInt("frame", 1);
        const src = img.attr("src");
        const x = img.attrInt("topLeftX", 0);
        const y = img.attrInt("topLeftY", 0);
        const opacity = img.attrFloat("opacity", 1.0);

        var kf = KeyFrame{
            .pos = frame,
            .data = .{ .bitmap = .{
                .top_left_x = x,
                .top_left_y = y,
                .opacity = @floatCast(opacity),
            } },
        };

        // Store the source filename for later loading
        if (src) |s| {
            kf.filename = try layer.allocator.dupe(u8, s);
        }

        _ = try layer.addKeyFrame(frame, kf);
    }
}

fn loadCameraFrames(layer: *Layer, elem: *const xml.Element) !void {
    var iter = elem.childrenByTag("camera");
    while (iter.next()) |cam| {
        const frame = cam.attrInt("frame", 1);
        const dx = cam.attrFloat("dx", 0);
        const dy = cam.attrFloat("dy", 0);
        const r = cam.attrFloat("r", 0);
        const s = cam.attrFloat("s", 1);
        const easing_int = cam.attrInt("easing", 0);
        const path_x = cam.attrFloat("pathCPX", 0);
        const path_y = cam.attrFloat("pathCPY", 0);

        const kf = KeyFrame{
            .pos = frame,
            .data = .{ .camera = .{
                .translate_x = dx,
                .translate_y = dy,
                .rotation = r,
                .scaling = s,
                .easing_type = @enumFromInt(easing_int),
                .path_control_x = path_x,
                .path_control_y = path_y,
                .path_control_moved = path_x != 0 or path_y != 0,
            } },
        };

        _ = try layer.addKeyFrame(frame, kf);
    }
}

fn loadSoundFrames(layer: *Layer, elem: *const xml.Element) !void {
    var iter = elem.childrenByTag("sound");
    while (iter.next()) |snd| {
        const frame = snd.attrInt("frame", 1);
        const src = snd.attr("src");

        var kf = KeyFrame{
            .pos = frame,
            .data = .{ .sound = .{} },
        };

        if (src) |s| {
            kf.filename = try layer.allocator.dupe(u8, s);
        }

        _ = try layer.addKeyFrame(frame, kf);
    }
}

fn loadVectorFrames(layer: *Layer, elem: *const xml.Element) !void {
    var iter = elem.childrenByTag("image");
    while (iter.next()) |img| {
        const frame = img.attrInt("frame", 1);
        const src = img.attr("src");

        var kf = KeyFrame{ .pos = frame };

        if (src) |s| {
            kf.filename = try layer.allocator.dupe(u8, s);
        }

        _ = try layer.addKeyFrame(frame, kf);
    }
}

/// Summary info about a loaded project.
pub const ProjectInfo = struct {
    layer_count: i32,
    total_keyframes: i32,
    animation_length: i32,
    layers: []LayerInfo,
};

pub const LayerInfo = struct {
    id: i32,
    name: []const u8,
    layer_type: LayerType,
    visible: bool,
    keyframe_count: i32,
};

/// Get summary info about a loaded Object.
pub fn getProjectInfo(obj: *const Object, allocator: Allocator) !ProjectInfo {
    var infos = try allocator.alloc(LayerInfo, obj.layers.items.len);
    for (obj.layers.items, 0..) |layer, i| {
        infos[i] = .{
            .id = layer.id,
            .name = layer.name,
            .layer_type = layer.layer_type,
            .visible = layer.visible,
            .keyframe_count = layer.keyFrameCount(),
        };
    }
    return .{
        .layer_count = obj.layerCount(),
        .total_keyframes = obj.totalKeyFrameCount(),
        .animation_length = obj.animationLength(),
        .layers = infos,
    };
}

// ── PCLX Writer ──────────────────────────────────────────────────────

const ZipWriter = @import("pclx_zip.zig").ZipWriter;
const Io = std.Io;

/// Serialize an Object to main.xml content.
pub fn serializeMainXml(obj: *const Object, allocator: Allocator) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<document>\n<object>\n");

    for (obj.layers.items) |layer| {
        try w.print("<layer id=\"{d}\" name=\"", .{layer.id});
        try writeXmlEscaped(w, layer.name);
        try w.print("\" visibility=\"{d}\" type=\"{d}\"", .{
            @as(i32, if (layer.visible) 1 else 0),
            @as(i32, @intFromEnum(layer.layer_type)),
        });

        if (layer.frames.items.len == 0) {
            try w.writeAll("/>\n");
            continue;
        }

        try w.writeAll(">\n");

        for (layer.frames.items) |kf| {
            switch (kf.data) {
                .bitmap => |b| {
                    try w.print("<image frame=\"{d}\"", .{kf.pos});
                    if (kf.filename) |f| {
                        try w.writeAll(" src=\"");
                        try writeXmlEscaped(w, f);
                        try w.writeByte('"');
                    }
                    try w.print(" topLeftX=\"{d}\" topLeftY=\"{d}\"", .{ b.top_left_x, b.top_left_y });
                    if (b.opacity != 1.0) {
                        try w.print(" opacity=\"{d}\"", .{b.opacity});
                    }
                    try w.writeAll("/>\n");
                },
                .camera => |c| {
                    try w.print("<camera frame=\"{d}\" r=\"{d}\" s=\"{d}\" dx=\"{d}\" dy=\"{d}\"", .{
                        kf.pos, c.rotation, c.scaling, c.translate_x, c.translate_y,
                    });
                    const easing_int: i32 = @intFromEnum(c.easing_type);
                    if (easing_int != 0) {
                        try w.print(" easing=\"{d}\"", .{easing_int});
                    }
                    if (c.path_control_moved) {
                        try w.print(" pathCPX=\"{d}\" pathCPY=\"{d}\"", .{ c.path_control_x, c.path_control_y });
                    }
                    try w.writeAll("/>\n");
                },
                .sound => {
                    try w.print("<sound frame=\"{d}\"", .{kf.pos});
                    if (kf.filename) |f| {
                        try w.writeAll(" src=\"");
                        try writeXmlEscaped(w, f);
                        try w.writeByte('"');
                    }
                    try w.writeAll("/>\n");
                },
                .empty => {
                    try w.print("<image frame=\"{d}\"", .{kf.pos});
                    if (kf.filename) |f| {
                        try w.writeAll(" src=\"");
                        try writeXmlEscaped(w, f);
                        try w.writeByte('"');
                    }
                    try w.writeAll("/>\n");
                },
            }
        }

        try w.writeAll("</layer>\n");
    }

    try w.writeAll("</object>\n<version>0.7.2</version>\n</document>\n");
    return try out.toOwnedSlice();
}

/// Save an Object to a .pclx ZIP in memory.
pub fn save(obj: *const Object, allocator: Allocator) ![]const u8 {
    const main_xml = try serializeMainXml(obj, allocator);
    defer allocator.free(main_xml);

    var zip = ZipWriter.init(allocator);
    defer zip.deinit();
    try zip.addBytes("main.xml", main_xml, false);
    try zip.finalize();

    // Copy the written data since the ZipWriter owns it
    const data = zip.written();
    return try allocator.dupe(u8, data);
}

fn writeXmlEscaped(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "load pclx from memory" {
    const allocator = std.testing.allocator;

    // Build a minimal .pclx in memory
    const main_xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<document>
        \\  <object>
        \\    <layer id="1" name="Background" visibility="1" type="1">
        \\      <image frame="1" src="001.001.png" topLeftX="-32" topLeftY="-32" opacity="0.8"/>
        \\      <image frame="5" src="001.005.png" topLeftX="0" topLeftY="0"/>
        \\    </layer>
        \\    <layer id="2" name="Camera" visibility="1" type="5" width="800" height="600">
        \\      <camera frame="1" r="0" s="1" dx="0" dy="0"/>
        \\      <camera frame="10" r="45" s="1.5" dx="100" dy="50" easing="1"/>
        \\    </layer>
        \\  </object>
        \\  <version>0.7.2</version>
        \\</document>
    ;

    var zip_writer = @import("pclx_zip.zig").ZipWriter.init(allocator);
    defer zip_writer.deinit();
    try zip_writer.addBytes("main.xml", main_xml, false);
    try zip_writer.finalize();
    const zip_data = zip_writer.written();

    var obj = try load(allocator, zip_data);
    defer obj.deinit();

    try std.testing.expectEqual(@as(i32, 2), obj.layerCount());
    const bg = obj.getLayer(0).?;
    try std.testing.expectEqualStrings("Background", bg.name);
    try std.testing.expectEqual(@as(i32, 2), bg.keyFrameCount());
    const kf1 = bg.getKeyFrameAt(1).?;
    try std.testing.expectEqual(@as(i32, -32), kf1.data.bitmap.top_left_x);
    try std.testing.expectEqual(@as(f32, 0.8), kf1.data.bitmap.opacity);

    const info = try getProjectInfo(&obj, allocator);
    defer allocator.free(info.layers);
    try std.testing.expectEqual(@as(i32, 4), info.total_keyframes);
}

test "save and reload pclx roundtrip" {
    const allocator = std.testing.allocator;

    // Build an Object in memory
    var obj = Object.init(allocator);
    defer obj.deinit();

    const bg = try obj.addNewLayer(.bitmap, "Background");
    _ = try bg.addKeyFrame(1, .{ .pos = 1, .data = .{ .bitmap = .{ .top_left_x = -10, .top_left_y = -20, .opacity = 0.9 } } });
    _ = try bg.addKeyFrame(5, .{ .pos = 5, .data = .{ .bitmap = .{} } });

    const cam = try obj.addNewLayer(.camera, "Camera");
    _ = try cam.addKeyFrame(1, .{ .pos = 1, .data = .{ .camera = .{ .translate_x = 0, .scaling = 1 } } });
    _ = try cam.addKeyFrame(10, .{ .pos = 10, .data = .{ .camera = .{ .translate_x = 100, .translate_y = 50, .rotation = 30, .scaling = 1.5 } } });

    // Save to .pclx
    const pclx_data = try save(&obj, allocator);
    defer allocator.free(pclx_data);

    // Reload
    var obj2 = try load(allocator, pclx_data);
    defer obj2.deinit();

    // Verify structure preserved
    try std.testing.expectEqual(@as(i32, 2), obj2.layerCount());

    const bg2 = obj2.getLayer(0).?;
    try std.testing.expectEqualStrings("Background", bg2.name);
    try std.testing.expectEqual(LayerType.bitmap, bg2.layer_type);
    try std.testing.expectEqual(@as(i32, 2), bg2.keyFrameCount());
    try std.testing.expectEqual(@as(i32, -10), bg2.getKeyFrameAt(1).?.data.bitmap.top_left_x);

    const cam2 = obj2.getLayer(1).?;
    try std.testing.expectEqualStrings("Camera", cam2.name);
    try std.testing.expectEqual(LayerType.camera, cam2.layer_type);
    const cam_kf = cam2.getKeyFrameAt(10).?;
    try std.testing.expectEqual(@as(f64, 100), cam_kf.data.camera.translate_x);
    try std.testing.expectEqual(@as(f64, 30), cam_kf.data.camera.rotation);
    try std.testing.expectEqual(@as(f64, 1.5), cam_kf.data.camera.scaling);
}
