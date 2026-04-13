#ifndef ZIG_INTEROP_H
#define ZIG_INTEROP_H

#include <cstdint>
#include <cstddef>

// Zig CLI parser (C ABI)
extern "C" {
    struct ZigParsedArgs {
        int mode;           // 0=gui, 1=export, 2=mcp, 3=help, 4=version, -1=err
        const char* input_path;
        const char** export_paths;
        int export_path_count;
        const char* camera;
        int width;
        int height;
        int start_frame;
        int end_frame;
        int transparency;
        int mcp_port;
    };
    ZigParsedArgs* zig_parse_args(int argc, const char** argv);

    // Embedded MCP server (C ABI from mcp_embedded.zig)
    typedef size_t (*McpCallback)(
        void* userdata,
        const char* method,
        const char* params_json,
        char* response_buf,
        size_t response_buf_len
    );
    int zig_mcp_start(uint16_t port, McpCallback callback, void* userdata);
    void zig_mcp_stop();

    // ── Qt bridge functions (C++ → called from Zig) ──────────────────
    // These are the minimal C-exported functions that Zig MCP calls
    // to interact with the Qt Editor. Implemented in mcphandler.cpp.

    struct EditorLayerInfo {
        int id;
        int index;
        int keyframe_count;
        int layer_type; // 1=bitmap, 2=vector, 4=sound, 5=camera
        int visible;
        char name[256];
    };

    struct EditorKeyframeInfo {
        int frame;
        int length;
    };

    // Query functions (read-only, safe from any thread via queued call)
    int qt_editor_layer_count(void* editor);
    int qt_editor_get_layer(void* editor, int index, EditorLayerInfo* out);
    int qt_editor_get_keyframes(void* editor, int layer_index,
                                EditorKeyframeInfo* out, int max_count);
    int qt_editor_current_frame(void* editor);
    int qt_editor_fps(void* editor);

    // Mutation functions (must run on Qt main thread)
    int qt_editor_scrub_to(void* editor, int frame);
    int qt_editor_add_layer(void* editor, const char* name, int type);
    int qt_editor_remove_layer(void* editor, int index);
    int qt_editor_rename_layer(void* editor, int index, const char* name);
    int qt_editor_set_layer_visibility(void* editor, int index, int visible);
    int qt_editor_add_keyframe(void* editor, int layer_index, int frame);
    int qt_editor_remove_keyframe(void* editor, int layer_index, int frame);
    int qt_editor_play(void* editor);
    int qt_editor_stop(void* editor);
    int qt_editor_set_fps(void* editor, int fps);
    int qt_editor_set_color(void* editor, int r, int g, int b, int a);
    int qt_editor_set_tool(void* editor, int tool_type);
    int qt_editor_draw_rect(void* editor, int layer, int x, int y, int w, int h,
                            int r, int g, int b, int a);
    int qt_editor_draw_circle(void* editor, int layer, int cx, int cy, int radius,
                              int r, int g, int b, int a);
    int qt_editor_draw_line(void* editor, int layer, int x0, int y0, int x1, int y1,
                            int r, int g, int b, int a, int width);
    int qt_editor_clear_frame(void* editor, int layer);
}

#endif // ZIG_INTEROP_H
