// Embedded MCP server — runs inside Pencil2D using the mcp.zig library.
// Streamable HTTP transport: listens on http://127.0.0.1:<port>/mcp
// Tool calls are dispatched through extern C functions to the Qt main thread.

const std = @import("std");
const mcp = @import("mcp");

// ── C ABI types ──────────────────────────────────────────────────────

/// Callback type (legacy, kept for C ABI compat).
pub const McpCallback = *const fn (
    userdata: ?*anyopaque,
    method: [*:0]const u8,
    params_json: [*:0]const u8,
    response_buf: [*]u8,
    response_buf_len: usize,
) callconv(.c) usize;

var g_userdata: ?*anyopaque = null;
var g_server: ?mcp.Server = null;
var g_server_thread: ?std.Thread = null;
var g_port: u16 = 0;

// ── Exported C ABI ───────────────────────────────────────────────────

/// Start the embedded MCP server on an HTTP port.
export fn zig_mcp_start(port: u16, callback: McpCallback, userdata: ?*anyopaque) c_int {
    _ = callback;
    g_userdata = userdata;
    g_port = port;

    g_server = mcp.Server.init(.{
        .name = "pencil2d",
        .version = "0.8.0-dev.8",
        .title = "Pencil2D Animation",
        .description = "MCP server for programmatic animation control",
        .instructions = "Use tools to control Pencil2D: manage layers, keyframes, draw shapes, and control playback.",
        .allocator = std.heap.smp_allocator,
    });

    const server = &(g_server.?);
    registerTools(server) catch return -1;

    g_server_thread = std.Thread.spawn(.{}, runServer, .{}) catch return -3;
    return 0;
}

/// Stop the embedded MCP server.
export fn zig_mcp_stop() void {
    if (g_server) |*s| {
        s.shutdown();
    }
    if (g_server_thread) |t| {
        t.join();
        g_server_thread = null;
    }
    if (g_server) |*s| {
        s.deinit();
        g_server = null;
    }
}

fn runServer() void {
    if (g_server) |*s| {
        s.run(.{ .http = .{ .host = "127.0.0.1", .port = g_port } }) catch |err| {
            std.debug.print("MCP server error: {any}\n", .{err});
        };
    }
}

// ── Tool registration ────────────────────────────────────────────────

fn registerTools(server: *mcp.Server) !void {
    try server.addTool(.{ .name = "project_info", .description = "Get project info: layers, frames, FPS", .handler = projectInfoHandler });
    try server.addTool(.{ .name = "layer_list", .description = "List all layers with type and keyframe count", .handler = layerListHandler });
    try server.addTool(.{ .name = "layer_add", .description = "Add a layer (name: string, type: bitmap|vector|camera|sound)", .handler = layerAddHandler });
    try server.addTool(.{ .name = "layer_remove", .description = "Remove a layer (index: integer)", .handler = layerRemoveHandler });
    try server.addTool(.{ .name = "keyframe_list", .description = "List keyframes (layer: integer)", .handler = keyframeListHandler });
    try server.addTool(.{ .name = "keyframe_add", .description = "Add keyframe (layer: integer, frame: integer)", .handler = keyframeAddHandler });
    try server.addTool(.{ .name = "goto_frame", .description = "Go to frame (frame: integer)", .handler = gotoFrameHandler });
    try server.addTool(.{ .name = "play", .description = "Start playback", .handler = playHandler });
    try server.addTool(.{ .name = "stop", .description = "Stop playback", .handler = stopHandler });
    try server.addTool(.{ .name = "set_fps", .description = "Set FPS (fps: integer)", .handler = setFpsHandler });
    try server.addTool(.{ .name = "set_color", .description = "Set color (r, g, b: integer, a: optional integer)", .handler = setColorHandler });
    try server.addTool(.{ .name = "set_tool", .description = "Switch tool (tool: pencil|eraser|select|move|hand|smudge|pen|polyline|bucket|eyedropper|brush)", .handler = setToolHandler });
    try server.addTool(.{ .name = "draw_rect", .description = "Draw rectangle (layer, x, y, w, h: integer; r, g, b, a: optional)", .handler = drawRectHandler });
    try server.addTool(.{ .name = "draw_circle", .description = "Draw circle (layer, cx, cy, radius: integer; r, g, b, a: optional)", .handler = drawCircleHandler });
    try server.addTool(.{ .name = "draw_line", .description = "Draw line (layer, x0, y0, x1, y1: integer; r, g, b, a, width: optional)", .handler = drawLineHandler });
    try server.addTool(.{ .name = "clear_frame", .description = "Clear frame (layer: integer)", .handler = clearFrameHandler });
    try server.addTool(.{ .name = "flood_fill", .description = "Flood fill at point (layer, x, y: integer; r, g, b, a, tolerance: optional)", .handler = floodFillHandler });
    try server.addTool(.{ .name = "erase", .description = "Erase circular area (layer, cx, cy, radius: integer)", .handler = eraseHandler });
    try server.addTool(.{ .name = "save_project", .description = "Save project to .pclx file (path: string)", .handler = saveProjectHandler });
    try server.addTool(.{ .name = "open_project", .description = "Open a .pclx file (path: string)", .handler = openProjectHandler });
    try server.addTool(.{ .name = "layer_reorder", .description = "Swap two layers (i, j: integer)", .handler = layerReorderHandler });

    // Batch tools — let the model paint a whole frame (or many frames) in a single MCP call.
    try server.addTool(.{
        .name = "frame_paint",
        .description = "Paint one frame in a single call. Args: layer (integer, default 0), frame (integer, default current; if >=1, navigates and ensures a keyframe exists), ops (array). " ++
            "Each op is an object with an 'op' field plus per-op args. Supported ops: " ++
            "'set_color' (r,g,b,a), 'line' (x0,y0,x1,y1, optional r,g,b,a,width), 'rect' (x,y,w,h, optional r,g,b,a), " ++
            "'circle' (cx,cy,radius, optional r,g,b,a), 'fill' (x,y, optional r,g,b,a,tolerance), 'erase' (cx,cy,radius), 'clear'. " ++
            "Color set by 'set_color' persists for subsequent ops within the call.",
        .handler = framePaintHandler,
    });
    try server.addTool(.{
        .name = "frames_paint",
        .description = "Paint many frames in a single call. Args: layer (integer, default 0), frames (array). " ++
            "Each frames[] entry is an object {frame: integer, ops: array} with the same op format as frame_paint. " ++
            "For each entry the server navigates to the frame, ensures a keyframe, then runs ops in order.",
        .handler = framesPaintHandler,
    });

    // Dev shutdown tool for stress testing.
    try server.addTool(.{ .name = "server_shutdown", .description = "Shutdown server (dev only)", .handler = serverShutdownHandler });
}

// ── Tool handlers ────────────────────────────────────────────────────

fn projectInfoHandler(allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const editor = g_userdata;
    const text = std.fmt.allocPrint(allocator, "{{\"layers\":{d},\"fps\":{d},\"current_frame\":{d}}}", .{
        qt_editor_layer_count(editor), qt_editor_fps(editor), qt_editor_current_frame(editor),
    }) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn layerListHandler(allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const editor = g_userdata;
    const text = buildLayerList(allocator, editor) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn layerAddHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const editor = g_userdata;
    const text = handleLayerAdd(allocator, args, editor) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn layerRemoveHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_remove_layer(g_userdata, getInt(args, "index", 0));
    const text = std.fmt.allocPrint(allocator, "{{\"removed\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn keyframeListHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const text = buildKeyframeList(allocator, args, g_userdata) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn keyframeAddHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_add_keyframe(g_userdata, getInt(args, "layer", 0), getInt(args, "frame", 1));
    const text = std.fmt.allocPrint(allocator, "{{\"added\":{s},\"frame\":{d}}}", .{ if (r >= 0) "true" else "false", r }) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn gotoFrameHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_scrub_to(g_userdata, getInt(args, "frame", 1));
    const text = std.fmt.allocPrint(allocator, "{{\"frame\":{d}}}", .{r}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn playHandler(allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = qt_editor_play(g_userdata);
    return mcp.tools.textResult(allocator, "{\"playing\":true}") catch return mcp.tools.ToolError.OutOfMemory;
}

fn stopHandler(allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const f = qt_editor_stop(g_userdata);
    const text = std.fmt.allocPrint(allocator, "{{\"playing\":false,\"frame\":{d}}}", .{f}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn setFpsHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_set_fps(g_userdata, getInt(args, "fps", 24));
    const text = std.fmt.allocPrint(allocator, "{{\"fps\":{d}}}", .{r}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn setColorHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = qt_editor_set_color(g_userdata, getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
    return mcp.tools.textResult(allocator, "{\"color\":\"set\"}") catch return mcp.tools.ToolError.OutOfMemory;
}

fn setToolHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const tool_str = getStr(args, "tool") orelse "pencil";
    const tool_id: c_int = if (std.mem.eql(u8, tool_str, "pencil")) 0 else if (std.mem.eql(u8, tool_str, "eraser")) 1 else if (std.mem.eql(u8, tool_str, "select")) 2 else if (std.mem.eql(u8, tool_str, "move")) 3 else if (std.mem.eql(u8, tool_str, "hand")) 4 else if (std.mem.eql(u8, tool_str, "smudge")) 5 else if (std.mem.eql(u8, tool_str, "pen")) 7 else if (std.mem.eql(u8, tool_str, "polyline")) 8 else if (std.mem.eql(u8, tool_str, "bucket")) 9 else if (std.mem.eql(u8, tool_str, "eyedropper")) 10 else if (std.mem.eql(u8, tool_str, "brush")) 11 else 0;
    _ = qt_editor_set_tool(g_userdata, tool_id);
    const text = std.fmt.allocPrint(allocator, "{{\"tool\":\"{s}\"}}", .{tool_str}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn drawRectHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_draw_rect(g_userdata, getInt(args, "layer", 0), getInt(args, "x", 0), getInt(args, "y", 0), getInt(args, "w", 50), getInt(args, "h", 50), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
    const text = std.fmt.allocPrint(allocator, "{{\"drawn\":\"rect\",\"ok\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn drawCircleHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_draw_circle(g_userdata, getInt(args, "layer", 0), getInt(args, "cx", 0), getInt(args, "cy", 0), getInt(args, "radius", 25), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255));
    const text = std.fmt.allocPrint(allocator, "{{\"drawn\":\"circle\",\"ok\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn drawLineHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_draw_line(g_userdata, getInt(args, "layer", 0), getInt(args, "x0", 0), getInt(args, "y0", 0), getInt(args, "x1", 0), getInt(args, "y1", 0), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255), getInt(args, "width", 2));
    const text = std.fmt.allocPrint(allocator, "{{\"drawn\":\"line\",\"ok\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn clearFrameHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = qt_editor_clear_frame(g_userdata, getInt(args, "layer", 0));
    return mcp.tools.textResult(allocator, "{\"cleared\":true}") catch return mcp.tools.ToolError.OutOfMemory;
}

fn floodFillHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = qt_editor_flood_fill(g_userdata, getInt(args, "layer", 0), getInt(args, "x", 0), getInt(args, "y", 0), getInt(args, "r", 0), getInt(args, "g", 0), getInt(args, "b", 0), getInt(args, "a", 255), getInt(args, "tolerance", 32));
    return mcp.tools.textResult(allocator, "{\"filled\":true}") catch return mcp.tools.ToolError.OutOfMemory;
}

fn eraseHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    _ = qt_editor_erase(g_userdata, getInt(args, "layer", 0), getInt(args, "cx", 0), getInt(args, "cy", 0), getInt(args, "radius", 10));
    return mcp.tools.textResult(allocator, "{\"erased\":true}") catch return mcp.tools.ToolError.OutOfMemory;
}

fn saveProjectHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path_str = getStr(args, "path") orelse return mcp.tools.textResult(allocator, "{\"error\":\"missing path\"}") catch return mcp.tools.ToolError.OutOfMemory;
    const path_z = allocator.dupeZ(u8, path_str) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(path_z);
    const r = qt_editor_save(g_userdata, path_z);
    const text = std.fmt.allocPrint(allocator, "{{\"saved\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn openProjectHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path_str = getStr(args, "path") orelse return mcp.tools.textResult(allocator, "{\"error\":\"missing path\"}") catch return mcp.tools.ToolError.OutOfMemory;
    const path_z = allocator.dupeZ(u8, path_str) catch return mcp.tools.ToolError.OutOfMemory;
    defer allocator.free(path_z);
    const r = qt_editor_open(g_userdata, path_z);
    const text = std.fmt.allocPrint(allocator, "{{\"opened\":{s},\"layers\":{d}}}", .{ if (r >= 0) "true" else "false", r }) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn layerReorderHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const r = qt_editor_swap_layers(g_userdata, getInt(args, "i", 0), getInt(args, "j", 1));
    const text = std.fmt.allocPrint(allocator, "{{\"swapped\":{s}}}", .{if (r == 0) "true" else "false"}) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn serverShutdownHandler(allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (g_server) |*s| {
        s.shutdown();
        return mcp.tools.textResult(allocator, "{\"shutdown\":true}") catch return mcp.tools.ToolError.OutOfMemory;
    }
    return mcp.tools.textResult(allocator, "{\"shutdown\":false}") catch return mcp.tools.ToolError.OutOfMemory;
}

// ── Batch handlers ───────────────────────────────────────────────────

fn framePaintHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const editor = g_userdata;
    const layer = getInt(args, "layer", 0);
    const requested_frame = getInt(args, "frame", -1);
    const frame: i32 = if (requested_frame >= 1) blk: {
        _ = qt_editor_scrub_to(editor, requested_frame);
        _ = qt_editor_add_keyframe(editor, layer, requested_frame);
        break :blk requested_frame;
    } else qt_editor_current_frame(editor);

    const ops_array = getArray(args, "ops") orelse {
        return mcp.tools.textResult(allocator, "{\"error\":\"missing ops array\"}") catch return mcp.tools.ToolError.OutOfMemory;
    };

    const result = executeOps(editor, layer, ops_array);

    const text = std.fmt.allocPrint(
        allocator,
        "{{\"frame\":{d},\"layer\":{d},\"executed\":{d},\"failed\":{d}}}",
        .{ frame, layer, result.executed, result.failed },
    ) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

fn framesPaintHandler(allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const editor = g_userdata;
    const layer = getInt(args, "layer", 0);

    const frames_array = getArray(args, "frames") orelse {
        return mcp.tools.textResult(allocator, "{\"error\":\"missing frames array\"}") catch return mcp.tools.ToolError.OutOfMemory;
    };

    var total_executed: usize = 0;
    var total_failed: usize = 0;
    var frames_processed: usize = 0;
    var frames_skipped: usize = 0;

    for (frames_array.items) |entry| {
        if (entry != .object) {
            frames_skipped += 1;
            continue;
        }
        const frame = getInt(entry, "frame", -1);
        if (frame < 1) {
            frames_skipped += 1;
            continue;
        }
        _ = qt_editor_scrub_to(editor, frame);
        _ = qt_editor_add_keyframe(editor, layer, frame);
        const ops_array = getArray(entry, "ops") orelse {
            frames_skipped += 1;
            continue;
        };
        const result = executeOps(editor, layer, ops_array);
        total_executed += result.executed;
        total_failed += result.failed;
        frames_processed += 1;
    }

    const text = std.fmt.allocPrint(
        allocator,
        "{{\"layer\":{d},\"frames_processed\":{d},\"frames_skipped\":{d},\"executed\":{d},\"failed\":{d}}}",
        .{ layer, frames_processed, frames_skipped, total_executed, total_failed },
    ) catch return mcp.tools.ToolError.OutOfMemory;
    return mcp.tools.textResult(allocator, text) catch return mcp.tools.ToolError.OutOfMemory;
}

const ExecResult = struct { executed: usize, failed: usize };

fn executeOps(editor: ?*anyopaque, default_layer: i32, ops: std.json.Array) ExecResult {
    var executed: usize = 0;
    var failed: usize = 0;
    for (ops.items) |op_v| {
        if (op_v != .object) {
            failed += 1;
            continue;
        }
        const op_name_v = op_v.object.get("op") orelse {
            failed += 1;
            continue;
        };
        if (op_name_v != .string) {
            failed += 1;
            continue;
        }
        const op_name = op_name_v.string;
        const op_layer = getInt(op_v, "layer", default_layer);

        if (std.mem.eql(u8, op_name, "set_color")) {
            _ = qt_editor_set_color(
                editor,
                getInt(op_v, "r", 0),
                getInt(op_v, "g", 0),
                getInt(op_v, "b", 0),
                getInt(op_v, "a", 255),
            );
        } else if (std.mem.eql(u8, op_name, "line")) {
            _ = qt_editor_draw_line(
                editor,
                op_layer,
                getInt(op_v, "x0", 0),
                getInt(op_v, "y0", 0),
                getInt(op_v, "x1", 0),
                getInt(op_v, "y1", 0),
                getInt(op_v, "r", 0),
                getInt(op_v, "g", 0),
                getInt(op_v, "b", 0),
                getInt(op_v, "a", 255),
                getInt(op_v, "width", 2),
            );
        } else if (std.mem.eql(u8, op_name, "rect")) {
            _ = qt_editor_draw_rect(
                editor,
                op_layer,
                getInt(op_v, "x", 0),
                getInt(op_v, "y", 0),
                getInt(op_v, "w", 50),
                getInt(op_v, "h", 50),
                getInt(op_v, "r", 0),
                getInt(op_v, "g", 0),
                getInt(op_v, "b", 0),
                getInt(op_v, "a", 255),
            );
        } else if (std.mem.eql(u8, op_name, "circle")) {
            _ = qt_editor_draw_circle(
                editor,
                op_layer,
                getInt(op_v, "cx", 0),
                getInt(op_v, "cy", 0),
                getInt(op_v, "radius", 25),
                getInt(op_v, "r", 0),
                getInt(op_v, "g", 0),
                getInt(op_v, "b", 0),
                getInt(op_v, "a", 255),
            );
        } else if (std.mem.eql(u8, op_name, "fill")) {
            _ = qt_editor_flood_fill(
                editor,
                op_layer,
                getInt(op_v, "x", 0),
                getInt(op_v, "y", 0),
                getInt(op_v, "r", 0),
                getInt(op_v, "g", 0),
                getInt(op_v, "b", 0),
                getInt(op_v, "a", 255),
                getInt(op_v, "tolerance", 32),
            );
        } else if (std.mem.eql(u8, op_name, "erase")) {
            _ = qt_editor_erase(
                editor,
                op_layer,
                getInt(op_v, "cx", 0),
                getInt(op_v, "cy", 0),
                getInt(op_v, "radius", 10),
            );
        } else if (std.mem.eql(u8, op_name, "clear")) {
            _ = qt_editor_clear_frame(editor, op_layer);
        } else {
            failed += 1;
            continue;
        }
        executed += 1;
    }
    return .{ .executed = executed, .failed = failed };
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
extern fn qt_editor_set_tool(editor: ?*anyopaque, tool_type: c_int) c_int;
extern fn qt_editor_draw_rect(editor: ?*anyopaque, layer: c_int, x: c_int, y: c_int, w: c_int, h: c_int, r: c_int, g: c_int, b: c_int, a: c_int) c_int;
extern fn qt_editor_draw_circle(editor: ?*anyopaque, layer: c_int, cx: c_int, cy: c_int, radius: c_int, r: c_int, g: c_int, b: c_int, a: c_int) c_int;
extern fn qt_editor_draw_line(editor: ?*anyopaque, layer: c_int, x0: c_int, y0: c_int, x1: c_int, y1: c_int, r: c_int, g: c_int, b: c_int, a: c_int, w: c_int) c_int;
extern fn qt_editor_clear_frame(editor: ?*anyopaque, layer: c_int) c_int;
extern fn qt_editor_flood_fill(editor: ?*anyopaque, layer: c_int, x: c_int, y: c_int, r: c_int, g: c_int, b: c_int, a: c_int, tolerance: c_int) c_int;
extern fn qt_editor_erase(editor: ?*anyopaque, layer: c_int, cx: c_int, cy: c_int, radius: c_int) c_int;
extern fn qt_editor_save(editor: ?*anyopaque, path: [*:0]const u8) c_int;
extern fn qt_editor_open(editor: ?*anyopaque, path: [*:0]const u8) c_int;
extern fn qt_editor_swap_layers(editor: ?*anyopaque, i: c_int, j: c_int) c_int;

// ── Argument helpers ─────────────────────────────────────────────────

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

fn getStr(args: ?std.json.Value, key: []const u8) ?[]const u8 {
    const obj = if (args) |a| (if (a == .object) &a.object else null) else null;
    const o = obj orelse return null;
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getArray(args: ?std.json.Value, key: []const u8) ?std.json.Array {
    const obj = if (args) |a| (if (a == .object) &a.object else null) else null;
    const o = obj orelse return null;
    const v = o.get(key) orelse return null;
    return if (v == .array) v.array else null;
}

// ── List builders ────────────────────────────────────────────────────

fn buildLayerList(allocator: std.mem.Allocator, editor: ?*anyopaque) ![]const u8 {
    const count = qt_editor_layer_count(editor);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        var info: EditorLayerInfo = undefined;
        if (qt_editor_get_layer(editor, i, &info) != 0) continue;
        if (i > 0) try buf.append(allocator, ',');
        const type_name = switch (info.layer_type) {
            1 => "bitmap",
            2 => "vector",
            4 => "sound",
            5 => "camera",
            else => "unknown",
        };
        const name_len = std.mem.indexOfScalar(u8, &info.name, 0) orelse 255;
        const entry = std.fmt.allocPrint(allocator, "{{\"index\":{d},\"id\":{d},\"name\":\"{s}\",\"type\":\"{s}\",\"visible\":{s},\"keyframes\":{d}}}", .{
            info.index, info.id,                                    info.name[0..name_len],
            type_name,  if (info.visible != 0) "true" else "false", info.keyframe_count,
        }) catch return error.OutOfMemory;
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }
    try buf.append(allocator, ']');
    return try allocator.dupe(u8, buf.items);
}

fn handleLayerAdd(allocator: std.mem.Allocator, args: ?std.json.Value, editor: ?*anyopaque) ![]const u8 {
    const name_str = if (args) |a| (if (a == .object) (if (a.object.get("name")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const type_str = if (args) |a| (if (a == .object) (if (a.object.get("type")) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const layer_type: c_int = if (type_str) |t| (if (std.mem.eql(u8, t, "bitmap")) @as(c_int, 1) else if (std.mem.eql(u8, t, "vector")) @as(c_int, 2) else if (std.mem.eql(u8, t, "camera")) @as(c_int, 5) else if (std.mem.eql(u8, t, "sound")) @as(c_int, 4) else 1) else 1;
    const name_z = if (name_str) |n| try allocator.dupeZ(u8, n) else try allocator.dupeZ(u8, "New Layer");
    defer allocator.free(name_z);
    const r = qt_editor_add_layer(editor, name_z, layer_type);
    return try std.fmt.allocPrint(allocator, "{{\"added\":{s},\"id\":{d}}}", .{ if (r >= 0) "true" else "false", r });
}

fn buildKeyframeList(allocator: std.mem.Allocator, args: ?std.json.Value, editor: ?*anyopaque) ![]const u8 {
    var kfs: [1024]EditorKeyframeInfo = undefined;
    const count = qt_editor_get_keyframes(editor, getInt(args, "layer", 0), &kfs, 1024);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        if (i > 0) try buf.append(allocator, ',');
        const idx: usize = @intCast(i);
        const entry = std.fmt.allocPrint(allocator, "{{\"frame\":{d},\"length\":{d}}}", .{ kfs[idx].frame, kfs[idx].length }) catch return error.OutOfMemory;
        defer allocator.free(entry);
        try buf.appendSlice(allocator, entry);
    }
    try buf.append(allocator, ']');
    return try allocator.dupe(u8, buf.items);
}
