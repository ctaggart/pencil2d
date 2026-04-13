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
}

#endif // ZIG_INTEROP_H
