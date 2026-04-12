const std = @import("std");
const pencil2d = @import("pencil2d.zig");

const Point = pencil2d.Point;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Object = pencil2d.object.Object;
const pclx_file = pencil2d.pclx_file;

// ── Minimal MCP Protocol Implementation ──────────────────────────────
// JSON-RPC 2.0 over Content-Length framing (MCP spec 2025-11-25)

const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ?[]const u8 = null,
    handler: *const fn (Allocator, ?std.json.Value) anyerror![]const u8,
};

const tools = [_]ToolDef{
    .{ .name = "list_tool_types", .description = "List all Pencil2D animation tool types (pencil, eraser, brush, etc.)", .handler = handleListToolTypes },
    .{ .name = "list_settings", .description = "List all Pencil2D preference settings", .handler = handleListSettings },
    .{ .name = "list_easing_types", .description = "List all camera easing types for animation interpolation", .handler = handleListEasingTypes },
    .{
        .name = "bezier_point_on_cubic",
        .description = "Evaluate a point on a cubic Bezier curve at parameter t in [0,1]",
        .handler = handleBezierPoint,
        .input_schema = @embedFile("schemas/bezier_point.json"),
    },
    .{
        .name = "bezier_find_distance",
        .description = "Find the minimum distance from a target point to a cubic Bezier curve",
        .handler = handleBezierDistance,
        .input_schema = @embedFile("schemas/bezier_distance.json"),
    },
    .{
        .name = "math_get_angle",
        .description = "Get the angle (radians) from vector a->b relative to the x-axis",
        .handler = handleMathAngle,
        .input_schema = @embedFile("schemas/math_angle.json"),
    },
    .{
        .name = "math_map_range",
        .description = "Map a value from one range to another",
        .handler = handleMathMapRange,
        .input_schema = @embedFile("schemas/math_map_range.json"),
    },
    .{
        .name = "math_normalize",
        .description = "Normalize a value to [0,1] given a min/max range",
        .handler = handleMathNormalize,
        .input_schema = @embedFile("schemas/math_normalize.json"),
    },
    .{
        .name = "color_distance",
        .description = "Calculate squared color distance between two ARGB colors (for flood-fill tolerance)",
        .handler = handleColorDistance,
        .input_schema = @embedFile("schemas/color_distance.json"),
    },
    .{
        .name = "calculate_opacity",
        .description = "Calculate relative opacity for onion-skin layer display",
        .handler = handleCalculateOpacity,
        .input_schema = @embedFile("schemas/calculate_opacity.json"),
    },
    .{
        .name = "point_operations",
        .description = "2D point math: add, subtract, dot, lerp, length, manhattan_length, normalize",
        .handler = handlePointOps,
        .input_schema = @embedFile("schemas/point_operations.json"),
    },
    .{
        .name = "matrix_transform_point",
        .description = "Apply a 2D affine transformation matrix to a point",
        .handler = handleMatrixTransform,
        .input_schema = @embedFile("schemas/matrix_transform.json"),
    },
    // ── Project / Layer / Keyframe tools ──
    .{
        .name = "project_open",
        .description = "Open a .pclx animation file. Provide the file path.",
        .handler = handleProjectOpen,
        .input_schema =
        \\{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to .pclx file"}},"required":["path"]}
        ,
    },
    .{ .name = "project_info", .description = "Get info about the currently loaded project (layers, keyframe count, animation length)", .handler = handleProjectInfo },
    .{ .name = "layer_list", .description = "List all layers in the current project with type, visibility, and keyframe count", .handler = handleLayerList },
    .{
        .name = "layer_add",
        .description = "Add a new layer. Type: bitmap, vector, camera, sound",
        .handler = handleLayerAdd,
        .input_schema =
        \\{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string","enum":["bitmap","vector","camera","sound"]}},"required":["name","type"]}
        ,
    },
    .{
        .name = "layer_remove",
        .description = "Remove a layer by index (0-based)",
        .handler = handleLayerRemove,
        .input_schema =
        \\{"type":"object","properties":{"index":{"type":"integer"}},"required":["index"]}
        ,
    },
    .{
        .name = "keyframe_list",
        .description = "List all keyframes on a layer (by index or name)",
        .handler = handleKeyframeList,
        .input_schema =
        \\{"type":"object","properties":{"layer":{"type":"string","description":"Layer name or index"}},"required":["layer"]}
        ,
    },
    .{
        .name = "keyframe_add",
        .description = "Add an empty keyframe at a position on a layer",
        .handler = handleKeyframeAdd,
        .input_schema =
        \\{"type":"object","properties":{"layer":{"type":"string","description":"Layer name or index"},"frame":{"type":"integer"}},"required":["layer","frame"]}
        ,
    },
    .{
        .name = "keyframe_remove",
        .description = "Remove a keyframe at a position from a layer",
        .handler = handleKeyframeRemove,
        .input_schema =
        \\{"type":"object","properties":{"layer":{"type":"string","description":"Layer name or index"},"frame":{"type":"integer"}},"required":["layer","frame"]}
        ,
    },
};

// ── JSON-RPC framing ─────────────────────────────────────────────────

fn readFrame(allocator: Allocator, reader: *Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    var hdr_buf: [512]u8 = undefined;

    while (true) {
        var len: usize = 0;
        while (len < hdr_buf.len) {
            const byte = (reader.take(1) catch return error.EndOfStream)[0];
            if (byte == '\n') break;
            hdr_buf[len] = byte;
            len += 1;
        }
        const line = std.mem.trimEnd(u8, hdr_buf[0..len], &.{ '\r', ' ' });
        if (line.len == 0) break; // empty line = end of headers
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], &.{ ' ', '\t' });
            content_length = std.fmt.parseInt(usize, val, 10) catch return error.InvalidContentLength;
        }
    }
    const length = content_length orelse return error.MissingContentLength;
    const buf = try allocator.alloc(u8, length);
    errdefer allocator.free(buf);
    reader.readSliceAll(buf) catch return error.EndOfStream;
    return buf;
}

fn writeFrame(writer: *Io.Writer, data: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{data.len});
    try writer.writeAll(data);
    try writer.flush();
}

// ── JSON-RPC dispatch ────────────────────────────────────────────────

fn handleMessage(allocator: Allocator, msg: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg, .{}) catch
        return try jsonError(allocator, null, -32700, "Parse error");

    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return try jsonError(allocator, null, -32600, "Invalid Request");

    const method = if (root.object.get("method")) |v| (if (v == .string) v.string else null) else null;
    const id = root.object.get("id");
    const params = root.object.get("params");

    if (method == null) return try jsonError(allocator, id, -32600, "Invalid Request");

    if (std.mem.eql(u8, method.?, "initialize")) return try handleInitialize(allocator, id);
    if (std.mem.eql(u8, method.?, "initialized")) return null; // notification, no response
    if (std.mem.eql(u8, method.?, "ping")) return try jsonResult(allocator, id, "{}");
    if (std.mem.eql(u8, method.?, "tools/list")) return try handleToolsList(allocator, id);
    if (std.mem.eql(u8, method.?, "tools/call")) return try handleToolsCall(allocator, id, params);
    if (std.mem.eql(u8, method.?, "notifications/cancelled")) return null;

    return try jsonError(allocator, id, -32601, "Method not found");
}

fn handleInitialize(allocator: Allocator, id: ?std.json.Value) ![]u8 {
    return try jsonResult(allocator, id,
        \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"pencil2d-mcp","version":"0.1.0"}}
    );
}

fn handleToolsList(allocator: Allocator, id: ?std.json.Value) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    for (tools, 0..) |tool, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\"", .{ tool.name, tool.description });
        if (tool.input_schema) |schema| {
            try out.writer.writeAll(",\"inputSchema\":");
            try out.writer.writeAll(schema);
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}");
    return try jsonResult(allocator, id, out.writer.buffered());
}

fn handleToolsCall(allocator: Allocator, id: ?std.json.Value, params: ?std.json.Value) ![]u8 {
    const p = params orelse return try jsonError(allocator, id, -32602, "Missing params");
    if (p != .object) return try jsonError(allocator, id, -32602, "Invalid params");

    const name_val = p.object.get("name") orelse return try jsonError(allocator, id, -32602, "Missing tool name");
    const name = if (name_val == .string) name_val.string else return try jsonError(allocator, id, -32602, "Invalid tool name");
    const arguments = p.object.get("arguments");

    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) {
            const content = tool.handler(allocator, arguments) catch
                return try toolError(allocator, id, "Tool execution failed");
            defer allocator.free(content);
            return try toolResult(allocator, id, content);
        }
    }
    return try jsonError(allocator, id, -32602, "Unknown tool");
}

// ── JSON-RPC response builders ───────────────────────────────────────

fn jsonResult(allocator: Allocator, id: ?std.json.Value, result: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&out.writer, id);
    try out.writer.writeAll(",\"result\":");
    try out.writer.writeAll(result);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn jsonError(allocator: Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&out.writer, id);
    try out.writer.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
    return try out.toOwnedSlice();
}

fn toolResult(allocator: Allocator, id: ?std.json.Value, text_content: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&out.writer, id);
    try out.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(&out.writer, text_content);
    try out.writer.writeAll("}]}}");
    return try out.toOwnedSlice();
}

fn toolError(allocator: Allocator, id: ?std.json.Value, msg: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&out.writer, id);
    try out.writer.writeAll(",\"result\":{\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"");
    try out.writer.writeAll(msg);
    try out.writer.writeAll("\"}]}}");
    return try out.toOwnedSlice();
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            },
        }
    }
    try w.writeByte('"');
}

fn writeId(w: *Io.Writer, id: ?std.json.Value) !void {
    if (id) |v| switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .string => |s| {
            try w.writeByte('"');
            try w.writeAll(s);
            try w.writeByte('"');
        },
        else => try w.writeAll("null"),
    } else try w.writeAll("null");
}

// ── Tool Handlers ────────────────────────────────────────────────────

fn enumNames(comptime E: type) []const []const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    const names = comptime blk: {
        var result: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| result[i] = f.name;
        break :blk result;
    };
    return &names;
}

fn jsonArray(allocator: Allocator, items: []const []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeByte('"');
        try out.writer.writeAll(item);
        try out.writer.writeByte('"');
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn handleListToolTypes(allocator: Allocator, _: ?std.json.Value) anyerror![]const u8 {
    return jsonArray(allocator, comptime enumNames(pencil2d.ToolType));
}

fn handleListSettings(allocator: Allocator, _: ?std.json.Value) anyerror![]const u8 {
    return jsonArray(allocator, comptime enumNames(pencil2d.Setting));
}

fn handleListEasingTypes(allocator: Allocator, _: ?std.json.Value) anyerror![]const u8 {
    return jsonArray(allocator, comptime enumNames(pencil2d.CameraEasingType));
}

fn getNum(args: ?std.json.Value, key: []const u8) ?f64 {
    const obj = if (args) |a| (if (a == .object) &a.object else null) else null;
    const o = obj orelse return null;
    const v = o.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => null,
    };
}

fn getStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const obj = if (args) |a| (if (a == .object) &a.object else null) else null;
    const o = obj orelse return null;
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn handleBezierPoint(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const p0 = Point{ .x = getNum(args, "p0x") orelse 0, .y = getNum(args, "p0y") orelse 0 };
    const c1 = Point{ .x = getNum(args, "c1x") orelse 0, .y = getNum(args, "c1y") orelse 0 };
    const c2 = Point{ .x = getNum(args, "c2x") orelse 0, .y = getNum(args, "c2y") orelse 0 };
    const p1 = Point{ .x = getNum(args, "p1x") orelse 0, .y = getNum(args, "p1y") orelse 0 };
    const t = getNum(args, "t") orelse 0.5;
    const r = pencil2d.bezier.pointOnCubic(p0, c1, c2, p1, t);
    return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ r.x, r.y });
}

fn handleBezierDistance(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const p0 = Point{ .x = getNum(args, "p0x") orelse 0, .y = getNum(args, "p0y") orelse 0 };
    const c1 = Point{ .x = getNum(args, "c1x") orelse 0, .y = getNum(args, "c1y") orelse 0 };
    const c2 = Point{ .x = getNum(args, "c2x") orelse 0, .y = getNum(args, "c2y") orelse 0 };
    const p1 = Point{ .x = getNum(args, "p1x") orelse 0, .y = getNum(args, "p1y") orelse 0 };
    const target = Point{ .x = getNum(args, "target_x") orelse 0, .y = getNum(args, "target_y") orelse 0 };
    const steps: u32 = if (getNum(args, "steps")) |s| @intFromFloat(s) else 100;
    const r = pencil2d.bezier.findDistance(p0, c1, c2, p1, target, steps);
    return std.fmt.allocPrint(allocator, "{{\"distance\":{d},\"nearest_x\":{d},\"nearest_y\":{d},\"t\":{d}}}", .{ r.distance, r.nearest.x, r.nearest.y, r.t });
}

fn handleMathAngle(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const angle = pencil2d.math.getDifferenceAngle(
        getNum(args, "ax") orelse 0,
        getNum(args, "ay") orelse 0,
        getNum(args, "bx") orelse 0,
        getNum(args, "by") orelse 0,
    );
    return std.fmt.allocPrint(allocator, "{d}", .{angle});
}

fn handleMathMapRange(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const result = pencil2d.math.map(
        getNum(args, "x") orelse 0,
        getNum(args, "input_min") orelse 0,
        getNum(args, "input_max") orelse 1,
        getNum(args, "output_min") orelse 0,
        getNum(args, "output_max") orelse 1,
    );
    return std.fmt.allocPrint(allocator, "{d}", .{result});
}

fn handleMathNormalize(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const result = pencil2d.math.normalize(
        getNum(args, "x") orelse 0,
        getNum(args, "min") orelse 0,
        getNum(args, "max") orelse 1,
    );
    return std.fmt.allocPrint(allocator, "{d}", .{result});
}

fn handleColorDistance(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const a: u32 = if (getNum(args, "color_a")) |v| @intFromFloat(v) else 0;
    const b: u32 = if (getNum(args, "color_b")) |v| @intFromFloat(v) else 0;
    const dist = pencil2d.Color.distanceSq(pencil2d.Color.fromArgb(a), pencil2d.Color.fromArgb(b));
    return std.fmt.allocPrint(allocator, "{d}", .{dist});
}

fn handleCalculateOpacity(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const current: i32 = if (getNum(args, "current_layer")) |v| @intFromFloat(v) else 0;
    const target: i32 = if (getNum(args, "target_layer")) |v| @intFromFloat(v) else 0;
    const threshold: f32 = if (getNum(args, "threshold")) |v| @floatCast(v) else 0.5;
    const result = pencil2d.calculateRelativeOpacityForLayer(current, target, threshold);
    return std.fmt.allocPrint(allocator, "{d}", .{result});
}

fn handlePointOps(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const op = getStr(args, "operation") orelse "length";
    const a = Point{ .x = getNum(args, "ax") orelse 0, .y = getNum(args, "ay") orelse 0 };

    if (std.mem.eql(u8, op, "length")) return std.fmt.allocPrint(allocator, "{d}", .{a.eLength()});
    if (std.mem.eql(u8, op, "manhattan_length")) return std.fmt.allocPrint(allocator, "{d}", .{a.mLength()});
    if (std.mem.eql(u8, op, "normalize")) {
        const n = a.normalized();
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ n.x, n.y });
    }

    const b = Point{ .x = getNum(args, "bx") orelse 0, .y = getNum(args, "by") orelse 0 };
    if (std.mem.eql(u8, op, "add")) {
        const r = Point.add(a, b);
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ r.x, r.y });
    }
    if (std.mem.eql(u8, op, "subtract")) {
        const r = Point.sub(a, b);
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ r.x, r.y });
    }
    if (std.mem.eql(u8, op, "dot")) return std.fmt.allocPrint(allocator, "{d}", .{Point.dot(a, b)});
    if (std.mem.eql(u8, op, "lerp")) {
        const t = getNum(args, "t") orelse 0.5;
        const r = Point.lerp(a, b, t);
        return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ r.x, r.y });
    }
    return std.fmt.allocPrint(allocator, "\"unknown operation: {s}\"", .{op});
}

fn handleMatrixTransform(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    var m = pencil2d.Matrix.identity();
    m.m[0][0] = getNum(args, "m00") orelse 1;
    m.m[0][1] = getNum(args, "m01") orelse 0;
    m.m[1][0] = getNum(args, "m10") orelse 0;
    m.m[1][1] = getNum(args, "m11") orelse 1;
    m.m[2][0] = getNum(args, "tx") orelse 0;
    m.m[2][1] = getNum(args, "ty") orelse 0;
    const p = m.mapPoint(.{ .x = getNum(args, "px") orelse 0, .y = getNum(args, "py") orelse 0 });
    return std.fmt.allocPrint(allocator, "{{\"x\":{d},\"y\":{d}}}", .{ p.x, p.y });
}

// ── Project State ────────────────────────────────────────────────────

var g_project: ?*Object = null;
var g_project_allocator: Allocator = std.heap.smp_allocator;

fn getProject() ?*Object {
    return g_project;
}

fn resolveLayer(args: ?std.json.Value) ?*pencil2d.layer.Layer {
    const proj = getProject() orelse return null;
    const layer_str = getStr(args, "layer") orelse return null;

    // Try as index first
    if (std.fmt.parseInt(usize, layer_str, 10) catch null) |idx| {
        return proj.getLayer(idx);
    }
    // Try as name
    return proj.findLayerByName(layer_str);
}

fn handleProjectOpen(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const path = getStr(args, "path") orelse return std.fmt.allocPrint(allocator, "\"error: missing path argument\"", .{});

    // Read file from disk
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "\"error: cannot open file: {s}\"", .{@errorName(err)});
    };
    defer file.close();
    const data = file.readToEndAlloc(g_project_allocator, 100 * 1024 * 1024) catch |err| {
        return std.fmt.allocPrint(allocator, "\"error: cannot read file: {s}\"", .{@errorName(err)});
    };
    defer g_project_allocator.free(data);

    // Close existing project
    if (g_project) |old| {
        old.deinit();
        g_project_allocator.destroy(old);
        g_project = null;
    }

    // Load
    const proj = g_project_allocator.create(Object) catch return std.fmt.allocPrint(allocator, "\"error: out of memory\"", .{});
    proj.* = pclx_file.load(g_project_allocator, data) catch |err| {
        g_project_allocator.destroy(proj);
        return std.fmt.allocPrint(allocator, "\"error: failed to parse pclx: {s}\"", .{@errorName(err)});
    };
    g_project = proj;

    const info = pclx_file.getProjectInfo(proj, allocator) catch
        return std.fmt.allocPrint(allocator, "\"project loaded\"", .{});
    defer allocator.free(info.layers);

    return std.fmt.allocPrint(allocator,
        \\{{"loaded":true,"layers":{d},"keyframes":{d},"animation_length":{d}}}
    , .{ info.layer_count, info.total_keyframes, info.animation_length });
}

fn handleProjectInfo(allocator: Allocator, _: ?std.json.Value) anyerror![]const u8 {
    const proj = getProject() orelse return std.fmt.allocPrint(allocator, "\"error: no project loaded. Use project_open first.\"", .{});
    const info = try pclx_file.getProjectInfo(proj, allocator);
    defer allocator.free(info.layers);

    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.print("{{\"layers\":{d},\"keyframes\":{d},\"animation_length\":{d},\"palette_colors\":{d}}}", .{
        info.layer_count,
        info.total_keyframes,
        info.animation_length,
        proj.colorCount(),
    });
    return try out.toOwnedSlice();
}

fn handleLayerList(allocator: Allocator, _: ?std.json.Value) anyerror![]const u8 {
    const proj = getProject() orelse return std.fmt.allocPrint(allocator, "\"error: no project loaded\"", .{});

    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('[');
    for (proj.layers.items, 0..) |layer, i| {
        if (i > 0) try out.writer.writeByte(',');
        const type_name = switch (layer.layer_type) {
            .bitmap => "bitmap",
            .vector => "vector",
            .camera => "camera",
            .sound => "sound",
            .undefined => "unknown",
        };
        try out.writer.print("{{\"index\":{d},\"id\":{d},\"name\":\"", .{ i, layer.id });
        try writeJsonStringRaw(&out.writer, layer.name);
        try out.writer.print("\",\"type\":\"{s}\",\"visible\":{s},\"keyframes\":{d}}}", .{
            type_name,
            if (layer.visible) "true" else "false",
            layer.keyFrameCount(),
        });
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn handleLayerAdd(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const proj = getProject() orelse return std.fmt.allocPrint(allocator, "\"error: no project loaded\"", .{});
    const name = getStr(args, "name") orelse return std.fmt.allocPrint(allocator, "\"error: missing name\"", .{});
    const type_str = getStr(args, "type") orelse "bitmap";
    const layer_type: pencil2d.layer.LayerType = if (std.mem.eql(u8, type_str, "bitmap")) .bitmap else if (std.mem.eql(u8, type_str, "vector")) .vector else if (std.mem.eql(u8, type_str, "camera")) .camera else if (std.mem.eql(u8, type_str, "sound")) .sound else .bitmap;

    const layer = proj.addNewLayer(layer_type, name) catch
        return std.fmt.allocPrint(allocator, "\"error: failed to add layer\"", .{});

    return std.fmt.allocPrint(allocator,
        \\{{"added":true,"id":{d},"index":{d}}}
    , .{ layer.id, proj.layerCount() - 1 });
}

fn handleLayerRemove(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const proj = getProject() orelse return std.fmt.allocPrint(allocator, "\"error: no project loaded\"", .{});
    const idx: usize = if (getNum(args, "index")) |n| @intFromFloat(n) else return std.fmt.allocPrint(allocator, "\"error: missing index\"", .{});

    if (proj.deleteLayer(idx)) {
        return std.fmt.allocPrint(allocator, "{{\"removed\":true,\"remaining_layers\":{d}}}", .{proj.layerCount()});
    }
    return std.fmt.allocPrint(allocator, "\"error: invalid layer index\"", .{});
}

fn handleKeyframeList(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const layer = resolveLayer(args) orelse return std.fmt.allocPrint(allocator, "\"error: layer not found or no project loaded\"", .{});

    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('[');
    for (layer.frames.items, 0..) |kf, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"frame\":{d},\"length\":{d}", .{ kf.pos, kf.length });
        switch (kf.data) {
            .bitmap => |b| try out.writer.print(",\"type\":\"bitmap\",\"x\":{d},\"y\":{d},\"opacity\":{d}", .{ b.top_left_x, b.top_left_y, b.opacity }),
            .camera => |c| try out.writer.print(",\"type\":\"camera\",\"dx\":{d},\"dy\":{d},\"rotation\":{d},\"scale\":{d}", .{ c.translate_x, c.translate_y, c.rotation, c.scaling }),
            .sound => try out.writer.writeAll(",\"type\":\"sound\""),
            .empty => try out.writer.writeAll(",\"type\":\"empty\""),
        }
        if (kf.filename) |f| {
            try out.writer.writeAll(",\"file\":\"");
            try writeJsonStringRaw(&out.writer, f);
            try out.writer.writeByte('"');
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn handleKeyframeAdd(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const layer = resolveLayer(args) orelse return std.fmt.allocPrint(allocator, "\"error: layer not found or no project loaded\"", .{});
    const frame: i32 = if (getNum(args, "frame")) |n| @intFromFloat(n) else return std.fmt.allocPrint(allocator, "\"error: missing frame\"", .{});

    const added = layer.addNewKeyFrameAt(frame) catch return std.fmt.allocPrint(allocator, "\"error: failed to add keyframe\"", .{});
    if (added) {
        return std.fmt.allocPrint(allocator, "{{\"added\":true,\"frame\":{d},\"total_keyframes\":{d}}}", .{ frame, layer.keyFrameCount() });
    }
    return std.fmt.allocPrint(allocator, "\"error: keyframe already exists at frame {d}\"", .{frame});
}

fn handleKeyframeRemove(allocator: Allocator, args: ?std.json.Value) anyerror![]const u8 {
    const layer = resolveLayer(args) orelse return std.fmt.allocPrint(allocator, "\"error: layer not found or no project loaded\"", .{});
    const frame: i32 = if (getNum(args, "frame")) |n| @intFromFloat(n) else return std.fmt.allocPrint(allocator, "\"error: missing frame\"", .{});

    if (layer.removeKeyFrame(frame)) {
        return std.fmt.allocPrint(allocator, "{{\"removed\":true,\"frame\":{d},\"remaining\":{d}}}", .{ frame, layer.keyFrameCount() });
    }
    return std.fmt.allocPrint(allocator, "\"error: no keyframe at frame {d}\"", .{frame});
}

fn writeJsonStringRaw(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ── Transport ────────────────────────────────────────────────────────

fn serveConnection(allocator: Allocator, reader: *Io.Reader, writer: *Io.Writer) void {
    while (true) {
        const msg = readFrame(allocator, reader) catch break;
        defer allocator.free(msg);

        const response = handleMessage(allocator, msg) catch continue;
        if (response) |resp| {
            defer allocator.free(resp);
            writeFrame(writer, resp) catch break;
        }
    }
}

fn handleTcpClient(conn: std.net.Server.Connection, allocator: Allocator) void {
    defer conn.stream.close();
    std.debug.print("MCP client connected\n", .{});
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = conn.stream.reader(&read_buf);
    var writer = conn.stream.writer(&write_buf);
    serveConnection(allocator, reader.interface(), &writer.interface);
    std.debug.print("MCP client disconnected\n", .{});
}

fn runTcpServer(port: u16, allocator: Allocator) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", port);
    var tcp_server = address.listen(.{}) catch |err| {
        std.debug.print("Failed to listen: {any}\n", .{err});
        return err;
    };
    defer tcp_server.deinit();
    std.debug.print("Pencil2D MCP server listening on 127.0.0.1:{d}\n", .{port});

    while (true) {
        const conn = tcp_server.accept() catch |err| {
            std.debug.print("Accept error: {any}\n", .{err});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleTcpClient, .{ conn, allocator }) catch continue;
        t.detach();
    }
}

fn runStdioServer(allocator: Allocator) void {
    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = std.fs.File.stdin().reader(&read_buf);
    var writer = std.fs.File.stdout().writer(&write_buf);
    serveConnection(allocator, &reader.interface, &writer.interface);
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: ?u16 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "--mcp")) {
            i += 1;
            if (i < args.len) {
                port = std.fmt.parseInt(u16, args[i], 10) catch {
                    std.debug.print("Invalid port number\n", .{});
                    std.process.exit(1);
                };
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Pencil2D MCP Server
                \\
                \\Usage: pencil2d-mcp [OPTIONS]
                \\
                \\Options:
                \\  --port, --mcp PORT  Listen on TCP port (default: stdio)
                \\  --help, -h          Show this help
                \\
            , .{});
            return;
        }
    }

    if (port) |p| {
        try runTcpServer(p, allocator);
    } else {
        runStdioServer(allocator);
    }
}
