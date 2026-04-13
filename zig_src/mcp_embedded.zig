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
    // Dispatch to C++ to get tool list
    var response_buf: [65536]u8 = undefined;
    const n = g_server.callback(g_server.userdata, "tools/list", "{}", &response_buf, response_buf.len);
    if (n == 0) return try jsonError(allocator, id, -32603, "Internal error");
    return try jsonResult(allocator, id, response_buf[0..n]);
}

fn handleToolsCall(allocator: Allocator, id: ?std.json.Value, params: ?std.json.Value) !?[]u8 {
    const p = params orelse return try jsonError(allocator, id, -32602, "Missing params");
    if (p != .object) return try jsonError(allocator, id, -32602, "Invalid params");

    const name_val = p.object.get("name") orelse return try jsonError(allocator, id, -32602, "Missing tool name");
    const name = if (name_val == .string) name_val.string else return try jsonError(allocator, id, -32602, "Invalid tool name");

    // Serialize arguments to JSON string for the C callback
    const args_val = p.object.get("arguments");
    var args_json: []const u8 = "{}";
    var args_owned = false;
    if (args_val) |av| {
        // Re-serialize the Value to JSON using allocPrint with json.fmt
        const formatted = std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(av, .{})}) catch "{}";
        args_json = formatted;
        args_owned = true;
    }
    defer if (args_owned) allocator.free(args_json);

    // Create null-terminated copies for C ABI
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    const args_z = try allocator.dupeZ(u8, args_json);
    defer allocator.free(args_z);

    // Call C++ handler
    var response_buf: [65536]u8 = undefined;
    const n = g_server.callback(g_server.userdata, name_z, args_z, &response_buf, response_buf.len);
    if (n == 0) return try jsonError(allocator, id, -32603, "Tool execution failed");

    const content = response_buf[0..n];

    // Build tool result envelope
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
