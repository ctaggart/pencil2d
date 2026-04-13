[![CI](https://github.com/ctaggart/pencil/actions/workflows/ci.yml/badge.svg)](https://github.com/ctaggart/pencil/actions/workflows/ci.yml)

# Pencil2D - Zig Fork

This is a fork of [Pencil2D](https://www.pencil2d.org/) that ports the core engine from C++ to **Zig**, with an embedded **MCP (Model Context Protocol)** server for programmatic animation control.

## What's Different

| Component | Upstream (C++) | This Fork (Zig) |
|-----------|---------------|-----------------|
| Data model (KeyFrame, Layer, Object) | C++ with Qt types | Pure Zig |
| File I/O (.pclx ZIP/XML/PNG) | Qt + miniz | Pure Zig + zpix |
| Managers (7 of 7) | C++ QObject + signals | Zig structs + callbacks |
| Tool algorithms | C++ | Pure Zig |
| Editor state machine | C++ | Zig + C ABI exports |
| MCP server | n/a | Embedded in app (Zig) |
| Rendering | Qt QPainter | Qt QPainter (stays C++) |

**17 Zig files, 5,700+ lines, 106 tests, 21 MCP tools.**

## Build

Requires [Zig 0.16.0-dev](https://github.com/ctaggart/zig/releases) and Qt 6.8.

```bash
# Run Zig tests (no Qt needed)
zig build zig-test

# Build full app (Windows, requires Qt + MSVC)
zig build -Dqt-prefix="C:/Qt/6.8.2/msvc2022_64"
```

## MCP Server

Start Pencil2D with an embedded MCP server:

```bash
pencil2d --mcp 9876
```

Connect via TCP on port 9876 using JSON-RPC 2.0 with Content-Length framing.

### Available Tools (21)

| Category | Tools |
|----------|-------|
| **Project** | `project_info`, `open_project`, `save_project` |
| **Layers** | `layer_list`, `layer_add`, `layer_remove`, `layer_reorder` |
| **Keyframes** | `keyframe_list`, `keyframe_add` |
| **Navigation** | `goto_frame`, `play`, `stop`, `set_fps` |
| **Drawing** | `draw_rect`, `draw_circle`, `draw_line`, `flood_fill`, `erase`, `clear_frame` |
| **Settings** | `set_color`, `set_tool` |

## Architecture

```
+-----------------------------------+
|  Qt Rendering (C++ ~250 lines)    |  QPainter, QWidget, 20 bridge functions
+-----------------------------------+
|  Zig Core (5,700+ lines)          |
|  - editor.zig (state machine)     |
|  - managers.zig (7 managers)      |
|  - tools.zig (algorithms)         |
|  - keyframe/layer/object.zig      |
|  - pclx_file/xml/png.zig          |
|  - mcp_embedded.zig (MCP TCP)     |
|  - export/preferences/etc.        |
+-----------------------------------+
```

## License

[GNU General Public License v2.0](LICENSE.TXT)
