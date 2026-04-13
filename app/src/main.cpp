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
#include "ziginterop.h"

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
