// Editor — central application state, ported from core_lib/src/interface/editor.h.
// Owns the Object (project), all managers, and coordinates mutations.
// C++ Editor becomes a thin wrapper calling into this Zig core.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pencil2d = @import("pencil2d.zig");
const Object = pencil2d.object.Object;
const Layer = pencil2d.layer.Layer;
const LayerType = pencil2d.layer.LayerType;
const KeyFrame = pencil2d.keyframe.KeyFrame;
const managers = pencil2d.managers;
const tools = pencil2d.tools;

pub const Editor = struct {
    allocator: Allocator,

    // Core state
    current_frame: i32 = 1,
    current_layer_index: i32 = 0,
    is_modified: bool = false,

    // Managers
    playback: managers.PlaybackManager = .{},
    color: managers.ColorManager = .{},
    view: managers.ViewManager = .{},
    selection: managers.SelectionManager = .{},
    layer_mgr: managers.LayerManager = .{},
    tool_mgr: managers.ToolManager = .{},
    overlay: managers.OverlayManager = .{},

    // Tool state
    stroke: tools.StrokeContext = .{},

    // Project (nullable — no project loaded initially)
    object: ?*Object = null,

    // Callbacks to C++ Qt layer
    on_frame_changed: ?*const fn (i32) callconv(.c) void = null,
    on_frame_modified: ?*const fn (i32, i32) callconv(.c) void = null,
    on_timeline_changed: ?*const fn () callconv(.c) void = null,
    on_view_changed: ?*const fn () callconv(.c) void = null,

    pub fn init(allocator: Allocator) Editor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Editor) void {
        if (self.object) |obj| {
            obj.deinit();
            self.allocator.destroy(obj);
            self.object = null;
        }
    }

    // ── Project ──────────────────────────────────────────────────────

    pub fn newProject(self: *Editor) !void {
        // Close existing
        if (self.object) |obj| {
            obj.deinit();
            self.allocator.destroy(obj);
        }

        const obj = try self.allocator.create(Object);
        obj.* = Object.init(self.allocator);

        // Default layers
        _ = try obj.addNewLayer(.camera, "Camera Layer");
        _ = try obj.addNewLayer(.bitmap, "Bitmap Layer");

        self.object = obj;
        self.current_frame = 1;
        self.current_layer_index = 1;
        self.is_modified = false;
        self.playback.start_frame = 1;
        self.playback.end_frame = 1;
    }

    pub fn getObject(self: *Editor) ?*Object {
        return self.object;
    }

    // ── Frame Navigation ─────────────────────────────────────────────

    pub fn scrubTo(self: *Editor, frame: i32) void {
        const obj = self.object orelse return;
        const max_frame = @max(obj.animationLength(), 1);
        self.current_frame = std.math.clamp(frame, 1, max_frame);
        self.playback.current_frame = self.current_frame;
        if (self.on_frame_changed) |cb| cb(self.current_frame);
    }

    pub fn scrubForward(self: *Editor) void {
        self.scrubTo(self.current_frame + 1);
    }

    pub fn scrubBackward(self: *Editor) void {
        self.scrubTo(self.current_frame - 1);
    }

    pub fn scrubNextKeyFrame(self: *Editor) void {
        const layer = self.currentLayer() orelse return;
        const next = layer.getNextKeyFramePosition(self.current_frame);
        self.scrubTo(next);
    }

    pub fn scrubPreviousKeyFrame(self: *Editor) void {
        const layer = self.currentLayer() orelse return;
        const prev = layer.getPreviousKeyFramePosition(self.current_frame);
        self.scrubTo(prev);
    }

    // ── Layer Access ─────────────────────────────────────────────────

    pub fn currentLayer(self: *Editor) ?*Layer {
        const obj = self.object orelse return null;
        const idx: usize = @intCast(@max(0, self.current_layer_index));
        return obj.getLayer(idx);
    }

    pub fn setCurrentLayerIndex(self: *Editor, index: i32) void {
        self.current_layer_index = index;
        self.layer_mgr.setCurrentLayer(index);
    }

    pub fn layerCount(self: *Editor) i32 {
        const obj = self.object orelse return 0;
        return obj.layerCount();
    }

    // ── KeyFrame Operations ──────────────────────────────────────────

    pub fn addKeyFrame(self: *Editor, layer_index: i32, frame: i32) !bool {
        const obj = self.object orelse return false;
        const idx: usize = @intCast(@max(0, layer_index));
        const layer = obj.getLayer(idx) orelse return false;
        const added = try layer.addNewKeyFrameAt(frame);
        if (added) {
            self.setModified(layer_index, frame);
            if (self.on_timeline_changed) |cb| cb();
        }
        return added;
    }

    pub fn removeKeyFrame(self: *Editor, layer_index: i32, frame: i32) bool {
        const obj = self.object orelse return false;
        const idx: usize = @intCast(@max(0, layer_index));
        const layer = obj.getLayer(idx) orelse return false;
        const removed = layer.removeKeyFrame(frame);
        if (removed) {
            if (self.on_timeline_changed) |cb| cb();
        }
        return removed;
    }

    // ── Modification Tracking ────────────────────────────────────────

    pub fn setModified(self: *Editor, layer_index: i32, frame: i32) void {
        self.is_modified = true;
        if (self.on_frame_modified) |cb| cb(layer_index, frame);
    }

    // ── Playback ─────────────────────────────────────────────────────

    pub fn play(self: *Editor) void {
        const obj = self.object orelse return;
        self.playback.end_frame = obj.animationLength();
        self.playback.play();
    }

    pub fn stop(self: *Editor) void {
        self.playback.stop();
    }

    pub fn fps(self: *Editor) i32 {
        return self.playback.fps;
    }

    pub fn setFps(self: *Editor, new_fps: i32) void {
        self.playback.setFps(new_fps);
    }

    // ── Tool Operations ──────────────────────────────────────────────

    pub fn setCurrentTool(self: *Editor, tool: managers.ToolType) void {
        self.tool_mgr.setCurrentTool(tool);
    }

    pub fn setFrontColor(self: *Editor, c: managers.Color) void {
        self.color.setFrontColor(c);
    }

    // ── Info ─────────────────────────────────────────────────────────

    pub fn totalKeyFrameCount(self: *Editor) i32 {
        const obj = self.object orelse return 0;
        return obj.totalKeyFrameCount();
    }

    pub fn animationLength(self: *Editor) i32 {
        const obj = self.object orelse return 0;
        return obj.animationLength();
    }
};

// ── C ABI Exports ────────────────────────────────────────────────────
// These allow C++ to create and interact with a Zig Editor.

var g_editor: ?*Editor = null;

export fn zig_editor_init() c_int {
    const allocator = std.heap.smp_allocator;
    const editor = allocator.create(Editor) catch return -1;
    editor.* = Editor.init(allocator);
    g_editor = editor;
    return 0;
}

export fn zig_editor_deinit() void {
    if (g_editor) |editor| {
        editor.deinit();
        std.heap.smp_allocator.destroy(editor);
        g_editor = null;
    }
}

export fn zig_editor_new_project() c_int {
    const editor = g_editor orelse return -1;
    editor.newProject() catch return -2;
    return 0;
}

export fn zig_editor_scrub_to(frame: c_int) void {
    const editor = g_editor orelse return;
    editor.scrubTo(frame);
}

export fn zig_editor_current_frame() c_int {
    const editor = g_editor orelse return 0;
    return editor.current_frame;
}

export fn zig_editor_layer_count() c_int {
    const editor = g_editor orelse return 0;
    return editor.layerCount();
}

export fn zig_editor_play() void {
    const editor = g_editor orelse return;
    editor.play();
}

export fn zig_editor_stop() void {
    const editor = g_editor orelse return;
    editor.stop();
}

// ── Tests ────────────────────────────────────────────────────────────

test "Editor new project" {
    const allocator = std.testing.allocator;
    var editor = Editor.init(allocator);
    defer editor.deinit();

    try editor.newProject();
    try std.testing.expect(editor.object != null);
    try std.testing.expectEqual(@as(i32, 2), editor.layerCount());
    try std.testing.expectEqual(@as(i32, 1), editor.current_frame);
}

test "Editor scrub" {
    const allocator = std.testing.allocator;
    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.newProject();

    // Add keyframes to extend timeline
    const added = try editor.addKeyFrame(1, 10);
    try std.testing.expect(added);

    editor.scrubTo(5);
    try std.testing.expectEqual(@as(i32, 5), editor.current_frame);

    editor.scrubForward();
    try std.testing.expectEqual(@as(i32, 6), editor.current_frame);

    editor.scrubBackward();
    try std.testing.expectEqual(@as(i32, 5), editor.current_frame);

    // Clamp to bounds
    editor.scrubTo(999);
    try std.testing.expect(editor.current_frame <= editor.animationLength());
}

test "Editor keyframe ops" {
    const allocator = std.testing.allocator;
    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.newProject();

    try std.testing.expect(try editor.addKeyFrame(1, 5));
    try std.testing.expect(try editor.addKeyFrame(1, 10));
    try std.testing.expect(!try editor.addKeyFrame(1, 5)); // duplicate

    try std.testing.expect(editor.removeKeyFrame(1, 5));
    try std.testing.expect(!editor.removeKeyFrame(1, 5)); // already removed
}

test "Editor playback" {
    const allocator = std.testing.allocator;
    var editor = Editor.init(allocator);
    defer editor.deinit();
    try editor.newProject();

    editor.play();
    try std.testing.expect(editor.playback.is_playing);
    editor.stop();
    try std.testing.expect(!editor.playback.is_playing);

    editor.setFps(30);
    try std.testing.expectEqual(@as(i32, 30), editor.fps());
}

test "Editor tool and color" {
    const allocator = std.testing.allocator;
    var editor = Editor.init(allocator);
    defer editor.deinit();

    editor.setCurrentTool(.brush);
    try std.testing.expectEqual(managers.ToolType.brush, editor.tool_mgr.current_tool);

    editor.setFrontColor(.{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try std.testing.expectEqual(@as(u8, 255), editor.color.front_color.r);
}
