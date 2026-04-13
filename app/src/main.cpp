/*

Pencil2D - Traditional Animation Software
Copyright (C) 2005-2007 Patrick Corrieri & Pascal Naidon
Copyright (C) 2012-2020 Matthew Chiawen Chang

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; version 2 of the License.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

*/

#include <cstdlib>
#include <cstdio>
#include "log.h"
#include "pencil2d.h"
#include "pencilerror.h"
#include "platformhandler.h"

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
}

#ifdef _WIN32
#include <process.h>
#else
#include <unistd.h>
#endif

static int launchMcpServer(int port, const char* argv0)
{
    // Derive pencil2d-mcp path from our own executable path
    std::string self(argv0);
    auto sep = self.find_last_of("/\\");
    std::string dir = (sep != std::string::npos) ? self.substr(0, sep + 1) : "";
#ifdef _WIN32
    std::string mcp_exe = dir + "pencil2d-mcp.exe";
#else
    std::string mcp_exe = dir + "pencil2d-mcp";
#endif

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    // Replace this process with pencil2d-mcp
#ifdef _WIN32
    return (int)_execl(mcp_exe.c_str(), "pencil2d-mcp", "--port", portStr, nullptr);
#else
    execl(mcp_exe.c_str(), "pencil2d-mcp", "--port", portStr, nullptr);
    return -1; // exec failed
#endif
}

/**
 * This is the entrypoint of the program. It performs basic initialization, then
 * boots the actual application (@ref Pencil2D).
 */
int main(int argc, char* argv[])
{
    // Parse CLI with Zig before Qt initialization
    auto* args = zig_parse_args(argc, const_cast<const char**>(argv));

    switch (args->mode)
    {
        case 3: // help
        case 4: // version
            return EXIT_SUCCESS;
        case -1: // error
            return EXIT_FAILURE;
        case 2: // mcp — start GUI with embedded MCP server
            args->mode = 0; // treat as GUI mode, port is already set
            break;
        default:
            break;
    }

    // GUI or export mode — proceed with Qt
    Q_INIT_RESOURCE(core_lib);
    PlatformHandler::initialise();
    initCategoryLogging();

    Pencil2D app(argc, argv);

    switch (app.handleCommandLineOptions(args).code())
    {
        case Status::OK:
            return Pencil2D::exec();
        case Status::SAFE:
            return EXIT_SUCCESS;
        default:
            return EXIT_FAILURE;
    }
}
