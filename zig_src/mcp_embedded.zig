// Embedded MCP server — runs inside Pencil2D, bridges to C++ via callback.
// The TCP listener and JSON-RPC parser run on a Zig thread.
// Tool calls are dispatched through a C function pointer to the Qt main thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;

// ── C ABI types ──────────────────────────────────────────────────────

/// Callback invoked for each MCP tool call.
/// Called on the Zig TCP thread — the C++ side must dispatch to the main thread.
/// `response_buf` is a caller-owned buffer; callback writes response JSON into it
/// and returns the number of bytes written (0 on error).
pub const McpCallback = *const fn (
    userdata: ?*anyopaque,
    method: [*:0]const u8,
    params_json: [*:0]const u8,
    response_buf: [*]u8,
    response_buf_len: usize,
) callconv(.c) usize;

const ServerState = struct {
    listener: ?net.Server = null,
    accept_thread: ?std.Thread = null,
    callback: McpCallback = undefined,
    userdata: ?*anyopaque = null,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_clients: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    threaded_io: Io.Threaded = undefined,
};

var g_server: ServerState = .{};

// ── Exported C ABI ───────────────────────────────────────────────────

/// Start the embedded MCP server on a TCP port.
/// The callback is invoked on a background thread for each JSON-RPC method call.
export fn zig_mcp_start(port: u16, callback: McpCallback, userdata: ?*anyopaque) c_int {
    g_server = .{};
    g_server.callback = callback;
    g_server.userdata = userdata;

    g_server.threaded_io = Io.Threaded.init(std.heap.smp_allocator, .{});
    const io = g_server.threaded_io.io();

    var address = net.IpAddress.parseIp4("127.0.0.1", port) catch return -1;
    g_server.listener = net.IpAddress.listen(&address, io, .{ .reuse_address = true }) catch return -2;

    g_server.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{}) catch {
        if (g_server.listener) |*l| l.deinit(io);
        g_server.listener = null;
        return -3;
    };

    return 0;
}

/// Stop the embedded MCP server and wait for all threads to finish.
export fn zig_mcp_stop() void {
    g_server.should_stop.store(true, .release);

    const io = g_server.threaded_io.io();

    // Close listener to unblock accept()
    if (g_server.listener) |*l| {
        l.deinit(io);
        g_server.listener = null;
    }

    // Wait for accept thread
    if (g_server.accept_thread) |t| {
        t.join();
        g_server.accept_thread = null;
    }

    // Wait for active clients to drain
    while (g_server.active_clients.load(.acquire) > 0) {
        std.atomic.spinLoopHint();
    }
}

// ── TCP accept loop ──────────────────────────────────────────────────

fn acceptLoop() void {
    const server = &(g_server.listener orelse return);
    const io = g_server.threaded_io.io();

    while (!g_server.should_stop.load(.acquire)) {
        const stream = server.accept(io) catch |err| {
            if (g_server.should_stop.load(.acquire)) break;
            std.debug.print("MCP accept error: {any}\n", .{err});
            continue;
        };

        _ = g_server.active_clients.fetchAdd(1, .acq_rel);

        const t = std.Thread.spawn(.{}, handleClient, .{stream}) catch {
            stream.close(io);
            _ = g_server.active_clients.fetchSub(1, .acq_rel);
            continue;
        };
        t.detach();
    }
}

fn handleClient(stream: net.Stream) void {
    const io = g_server.threaded_io.io();
    defer {
        stream.close(io);
        _ = g_server.active_clients.fetchSub(1, .acq_rel);
    }

    std.debug.print("MCP client connected\n", .{});

    var read_buf: [65536]u8 = undefined;
    var write_buf: [65536]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    const allocator = std.heap.smp_allocator;

    while (!g_server.should_stop.load(.acquire)) {
        // Read JSON-RPC frame
        const msg = readFrame(allocator, &reader.interface) catch break;
        defer allocator.free(msg);

        // Handle message
        const response = handleMessage(allocator, msg) catch continue;
        if (response) |resp| {
            defer allocator.free(resp);
            writeFrame(&writer.interface, resp) catch break;
        }
    }

    std.debug.print("MCP client disconnected\n", .{});
}

// ── JSON-RPC framing (same as mcp_server.zig) ───────────────────────

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
        if (line.len == 0) break;
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

    const method_str = if (root.object.get("method")) |v| (if (v == .string) v.string else null) else null;
    const id = root.object.get("id");
    const params = root.object.get("params");

    if (method_str == null) return try jsonError(allocator, id, -32600, "Invalid Request");
    const method = method_str.?;

    if (std.mem.eql(u8, method, "initialize")) return try handleInitialize(allocator, id);
    if (std.mem.eql(u8, method, "initialized")) return null;
    if (std.mem.eql(u8, method, "ping")) return try jsonResult(allocator, id, "{}");
    if (std.mem.eql(u8, method, "tools/list")) return try handleToolsList(allocator, id);
    if (std.mem.eql(u8, method, "tools/call")) return try handleToolsCall(allocator, id, params);
    if (std.mem.eql(u8, method, "notifications/cancelled")) return null;

    return try jsonError(allocator, id, -32601, "Method not found");
}

fn handleInitialize(allocator: Allocator, id: ?std.json.Value) ![]u8 {
    return try jsonResult(allocator, id,
        \\{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"pencil2d-mcp-embedded","version":"0.2.0"}}
    );
}

fn handleToolsList(allocator: Allocator, id: ?std.json.Value) ![]u8 {
    return try jsonResult(allocator, id,
        \\{"tools":[
        \\{"name":"project_info","description":"Get project info: layers, frames, FPS"},
        \\{"name":"layer_list","description":"List all layers with type and keyframe count"},
        \\{"name":"layer_add","description":"Add a layer","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"type":{"type":"string","enum":["bitmap","vector","camera","sound"]}},"required":["name","type"]}},
        \\{"name":"layer_remove","description":"Remove a layer","inputSchema":{"type":"object","properties":{"index":{"type":"integer"}},"required":["index"]}},
        \\{"name":"keyframe_list","description":"List keyframes","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"}},"required":["layer"]}},
        \\{"name":"keyframe_add","description":"Add keyframe","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"frame":{"type":"integer"}},"required":["layer","frame"]}},
        \\{"name":"goto_frame","description":"Go to frame","inputSchema":{"type":"object","properties":{"frame":{"type":"integer"}},"required":["frame"]}},
        \\{"name":"play","description":"Start playback"},
        \\{"name":"stop","description":"Stop playback"},
        \\{"name":"set_fps","description":"Set FPS","inputSchema":{"type":"object","properties":{"fps":{"type":"integer"}},"required":["fps"]}},
        \\{"name":"set_color","description":"Set color","inputSchema":{"type":"object","properties":{"r":{"type":"integer"},"g":{"type":"integer"},"b":{"type":"integer"},"a":{"type":"integer"}},"required":["r","g","b"]}},
        \\{"name":"draw_rect","description":"Draw rectangle","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"w":{"type":"integer"},"h":{"type":"integer"},"r":{"type":"integer"},"g":{"type":"integer"},"b":{"type":"integer"},"a":{"type":"integer"}},"required":["layer","x","y","w","h"]}},
        \\{"name":"draw_circle","description":"Draw circle","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"cx":{"type":"integer"},"cy":{"type":"integer"},"radius":{"type":"integer"},"r":{"type":"integer"},"g":{"type":"integer"},"b":{"type":"integer"},"a":{"type":"integer"}},"required":["layer","cx","cy","radius"]}},
        \\{"name":"draw_line","description":"Draw line","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"x0":{"type":"integer"},"y0":{"type":"integer"},"x1":{"type":"integer"},"y1":{"type":"integer"},"r":{"type":"integer"},"g":{"type":"integer"},"b":{"type":"integer"},"a":{"type":"integer"},"width":{"type":"integer"}},"required":["layer","x0","y0","x1","y1"]}},
        \\{"name":"clear_frame","description":"Clear frame","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"}},"required":["layer"]}},
        \\{"name":"flood_fill","description":"Flood fill at point","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"r":{"type":"integer"},"g":{"type":"integer"},"b":{"type":"integer"},"a":{"type":"integer"},"tolerance":{"type":"integer"}},"required":["layer","x","y"]}},
        \\{"name":"erase","description":"Erase circular area","inputSchema":{"type":"object","properties":{"layer":{"type":"integer"},"cx":{"type":"integer"},"cy":{"type":"integer"},"radius":{"type":"integer"}},"required":["layer","cx","cy","radius"]}}
        \\]}
    );
}

// ── C Bridge to Qt Editor ────────────────────────────────────────────

const EditorLayerInfo = extern struct {
    id: c_int,
    index: c_int,
    keyframe_count: c_int,
    layer_type: c_int,
    visible: c_int,
    name: [256]u8,
};

const EditorKeyframeInfo = extern struct {
    frame: c_int,
    length: c_int,
};

extern fn qt_editor_layer_count(editor: ?*anyopaque) c_int;
extern fn qt_editor_get_layer(editor: ?*anyopaque, index: c_int, out: *EditorLayerInfo) c_int;
extern fn qt_editor_get_keyframes(editor: ?*anyopaque, layer: c_int, out: [*]EditorKeyframeInfo, max: c_int) c_int;
extern fn qt_editor_current_frame(editor: ?*anyopaque) c_int;
extern fn qt_editor_fps(editor: ?*anyopaque) c_int;
extern fn qt_editor_scrub_to(editor: ?*anyopaque, frame: c_int) c_int;
extern fn qt_editor_add_layer(editor: ?*anyopaque, name: [*:0]const u8, layer_type: c_int) c_int;
extern fn qt_editor_remove_layer(editor: ?*anyopaque, index: c_int) c_int;
extern fn qt_editor_add_keyframe(editor: ?*anyopaque, layer: c_int, frame: c_int) c_int;
extern fn qt_editor_remove_keyframe(editor: ?*anyopaque, layer: c_int, frame: c_int) c_int;
extern fn qt_editor_play(editor: ?*anyopaque) c_int;
extern fn qt_editor_stop(editor: ?*anyopaque) c_int;
extern fn qt_editor_set_fps(editor: ?*anyopaque, fps: c_int) c_int;
extern fn qt_editor_set_color(editor: ?*anyopaque, r: c_int, g: c_int, b: c_int, a: c_int) c_int;
extern fn qt_editor_draw_rect(editor: ?*anyopaque, layer: c_int, x: c_int, y: c_int, w: c_int, h: c_int, r: c_int, g: c_int, b: c_int, a: c_int) c_int;
extern fn qt_editor_draw_circle(editor: ?*anyopaque, layer: c_int, cx: c_int, cy: c_int, radius: c_int, r: c_int, g: c_int, b: c_int, a: c_int) c_int;
extern fn qt_editor_draw_line(editor: ?*anyopaque, layer: c_int, x0: c_int, y0: c_int, x1: c_int, y1: c_int, r: c_int, g: c_int, b: c_int, a: c_int, w: c_int) c_int;
extern fn qt_editor_clear_frame(editor: ?*anyopaque, layer: c_int) c_int;
extern fn qt_editor_flood_fill(editor: ?*anyopaque, layer: c_int, x: c_int, y: c_int, r: c_int, g: c_int, b: c_int, a: c_int, tolerance: c_int) c_int;
extern fn qt_editor_erase(editor: ?*anyopaque, layer: c_int, cx: c_int, cy: c_int, radius: c_int) c_int;

fn getInt(args: ?std.json.Value, key: []const u8, default: i32) i32 {
    const obj = if (args) |a| (if (a == .object) &a.object else null) else null;
    const o = obj orelse return default;
    const v = o.get(key) orelse return default;
    return switch (v) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        .string => |s| std.fmt.parseInt(i32, s, 10) catch default,
        else => default,
    };
}

fn handleToolsCall(allocator: Allocator, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
    const p = params orelse return try jsonError(allocator, id, -32602, "Missing params");
    if (p != .object) return try jsonError(allocator, id, -32602, "Invalid params");

    const name_val = p.object.get("name") orelse return try jsonError(allocator, id, -32602, "Missing tool name");
    const name = if (name_val == .string) name_val.string else return try jsonError(allocator, id, -32602, "Invalid tool name");
    const args = p.object.get("arguments");
    const editor = g_server.userdata;

    // Dispatch tools — all logic in Zig, thin C calls to Qt
    const result: []const u8 = if (std.mem.eql(u8, name, "project_info"))
        try std.fmt.allocPrint(allocator, "{{\"layers\":{d},\"fps\":{d},\"current_frame\":{d}}}", .{
            qt_editor_layer_count(editor), qt_editor_fps(editor), qt_editor_current_frame(editor),
        })
    else if (std.mem.eql(u8, name, "layer_list"))
        try buildLayerList(allocator, editor)
    else if (std.mem.eql(u8, name, "layer_add"))
        try handleLayerAdd(allocator, args, editor)
    else if (std.mem.eql(u8, name, "layer_remove")) blk: {
        const r = qt_editor_remove_layer(editor, getInt(args, "index", 0));
        break :blk try std.fmt.allocPrint(allocator, "{{\"removed\":{s}}}", .{if (r == 0) "true" else "false"});
    } else if (std.mem.eql(u8, name, "keyframe_list"))
        try buildKeyframeList(allocator, args, editor)
    else if (std.mem.eql(u8, name, "keyframe_add")) blk: {
        const r = qt_editor_add_keyframe(editor, getInt(args, "layer", 0), getInt(args, "frame", 1));
        break :blk try std.fmt.allocPrint(allocator, "{{\"added\":{s},\"frame\":{d}}}", .{ if (r >= 0) "true" else "false", r });
    } else if (std.mem.eql(u8, name, "goto_frame")) blk: {
        const r = qt_editor_scrub_to(editor, getInt(args, "frame", 1));
        break :blk try std.fmt.allocPrint(allocator, "{{\"frame\":{d}}}", .{r});
    } else if (std.mem.eql(u8, name, "play")) blk: {
        _ = qt_editor_play(editor);
        break :blk try std.fmt.allocPrint(allocator, "{{\"playing\":true}}", .{});
    } else if (std.mem.eql(u8, name, "stop")) blk: {
        const f = qt_editor_stop(editor);
        break :blk try std.fmt.allocPrint(allocator, "{{\"playing\":false,\"frame\":{d}}}", .{f});
    } else if (std.mem.eql(u8, name, "set_fps")) blk: {
        const r = qt_editor_set_fps(editor, getInt(args, "fps", 24));
        break :blk try std.fmt.allocPrint(allocator, "{{\"fps\":{d}}}", .{r});
    } else if (std.mem.eql(u8, name, "set_color")) blk: {
        _ = qt_editor_set_color(editor, getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
        break :blk try std.fmt.allocPrint(allocator, "{{\"color\":\"set\"}}", .{});
    } else if (std.mem.eql(u8, name, "draw_rect")) blk: {
        _ = qt_editor_draw_rect(editor, getInt(args, "layer", 0), getInt(args, "x", 0), getInt(args, "y", 0), getInt(args, "w", 50), getInt(args, "h", 50), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
        break :blk try std.fmt.allocPrint(allocator, "{{\"drawn\":\"rect\"}}", .{});
    } else if (std.mem.eql(u8, name, "draw_circle")) blk: {
        _ = qt_editor_draw_circle(editor, getInt(args, "layer", 0), getInt(args, "cx", 0), getInt(args, "cy", 0), getInt(args, "radius", 25), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
        break :blk try std.fmt.allocPrint(allocator, "{{\"drawn\":\"circle\"}}", .{});
    } else if (std.mem.eql(u8, name, "draw_line")) blk: {
        _ = qt_editor_draw_line(editor, getInt(args, "layer", 0), getInt(args, "x0", 0), getInt(args, "y0", 0), getInt(args, "x1", 0), getInt(args, "y1", 0), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255), getInt(args, "width", 2));
        break :blk try std.fmt.allocPrint(allocator, "{{\"drawn\":\"line\"}}", .{});
    } else if (std.mem.eql(u8, name, "clear_frame")) blk: {
        _ = qt_editor_clear_frame(editor, getInt(args, "layer", 0));
        break :blk try std.fmt.allocPrint(allocator, "{{\"cleared\":true}}", .{});
    } else if (std.mem.eql(u8, name, "flood_fill")) blk: {
        _ = qt_editor_flood_fill(editor, getInt(args, "layer", 0), getInt(args, "x", 0), getInt(args, "y", 0), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255), getInt(args, "tolerance", 32));
        break :blk try std.fmt.allocPrint(allocator, "{{\"filled\":true}}", .{});
    } else if (std.mem.eql(u8, name, "erase")) blk: {
        _ = qt_editor_erase(editor, getInt(args, "layer", 0), getInt(args, "cx", 0), getInt(args, "cy", 0), getInt(args, "radius", 10));
        break :blk try std.fmt.allocPrint(allocator, "{{\"erased\":true}}", .{});
    } else try std.fmt.allocPrint(allocator, "{{\"error\":\"unknown tool\"}}", .{});

    defer allocator.free(result);
    return try toolResult(allocator, id, result);
}

fn buildLayerList(allocator: Allocator, editor: ?*anyopaque) ![]const u8 {
    const count = qt_editor_layer_count(editor);
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('[');
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        var info: EditorLayerInfo = undefined;
        if (qt_editor_get_layer(editor, i, &info) != 0) continue;
        if (i > 0) try out.writer.writeByte(',');
        const type_name = switch (info.layer_type) {
            1 => "bitmap",
            2 => "vector",
            4 => "sound",
            5 => "camera",
            else => "unknown",
        };
        const name_len = std.mem.indexOfScalar(u8, &info.name, 0) orelse 255;
        try out.writer.print("{{\"index\":{d},\"id\":{d},\"name\":\"", .{ info.index, info.id });
        try out.writer.writeAll(info.name[0..name_len]);
        try out.writer.print("\",\"type\":\"{s}\",\"visible\":{s},\"keyframes\":{d}}}", .{
            type_name, if (info.visible != 0) "true" else "false", info.keyframe_count,
        });
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn handleLayerAdd(allocator: Allocator, args: ?std.json.Value, editor: ?*anyopaque) ![]const u8 {
    const name_str = if (args) |a| (if (a == .object) (if (a.object.get("name")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const type_str = if (args) |a| (if (a == .object) (if (a.object.get("type")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const layer_type: c_int = if (type_str) |t| (if (std.mem.eql(u8, t, "bitmap")) @as(c_int, 1) else if (std.mem.eql(u8, t, "vector")) @as(c_int, 2) else if (std.mem.eql(u8, t, "camera")) @as(c_int, 5) else if (std.mem.eql(u8, t, "sound")) @as(c_int, 4) else 1) else 1;
    const name_z = if (name_str) |n| try allocator.dupeZ(u8, n) else try allocator.dupeZ(u8, "New Layer");
    defer allocator.free(name_z);
    const r = qt_editor_add_layer(editor, name_z, layer_type);
    return try std.fmt.allocPrint(allocator, "{{\"added\":{s},\"id\":{d}}}", .{ if (r >= 0) "true" else "false", r });
}

fn buildKeyframeList(allocator: Allocator, args: ?std.json.Value, editor: ?*anyopaque) ![]const u8 {
    var kfs: [1024]EditorKeyframeInfo = undefined;
    const count = qt_editor_get_keyframes(editor, getInt(args, "layer", 0), &kfs, 1024);
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeByte('[');
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try out.writer.writeByte(',');
        const idx: usize = @intCast(i);
        try out.writer.print("{{\"frame\":{d},\"length\":{d}}}", .{ kfs[idx].frame, kfs[idx].length });
    }
    try out.writer.writeByte(']');
    return try out.toOwnedSlice();
}

fn toolResult(allocator: Allocator, id: ?std.json.Value, content: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeId(&out.writer, id);
    try out.writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(&out.writer, content);
    try out.writer.writeAll("}]}}");
    return try out.toOwnedSlice();
}

// ── JSON helpers ─────────────────────────────────────────────────────

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
