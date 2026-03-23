// Zig command-line parser for Pencil2D — replaces QCommandLineParser.
// Exported via C ABI so C++ main() can call it before Qt initialization.

const std = @import("std");

pub const Mode = enum(c_int) {
    gui = 0,
    export_mode = 1,
    mcp = 2,
    help = 3,
    version = 4,
    err = -1,
};

pub const ParsedArgs = extern struct {
    mode: Mode,
    input_path: ?[*:0]const u8,
    /// Null-terminated array of export output paths.
    export_paths: [*]?[*:0]const u8,
    export_path_count: c_int,
    camera: ?[*:0]const u8,
    width: c_int,
    height: c_int,
    start_frame: c_int,
    end_frame: c_int,
    transparency: c_int,
    mcp_port: c_int,
};

const version_text = "Pencil2D 0.1.0\n";

const help_text =
    \\Pencil2D - Traditional Animation Software
    \\
    \\Usage: pencil2d [options] [input]
    \\
    \\Options:
    \\  -o, --export <path>    Render the file to <path> (repeatable)
    \\  --camera <name>        Name of the camera layer to use
    \\  --width <int>          Width of the output frames
    \\  --height <int>         Height of the output frames
    \\  --start <frame>        First frame to export (default: 1)
    \\  --end <frame>          Last frame to export ("last" or "last-sound")
    \\  --transparency         Render transparency when possible
    \\  --mcp <port>           Start MCP server on TCP port
    \\  -h, --help             Show this help
    \\  -v, --version          Show version
    \\
    \\Arguments:
    \\  input                  Path to the input .pclx file
    \\
;

var export_path_storage: [64]?[*:0]const u8 = .{null} ** 64;

var parsed: ParsedArgs = .{
    .mode = .gui,
    .input_path = null,
    .export_paths = &export_path_storage,
    .export_path_count = 0,
    .camera = null,
    .width = -1,
    .height = -1,
    .start_frame = 1,
    .end_frame = -1,
    .transparency = 0,
    .mcp_port = 0,
};

fn parseInt(s: [*:0]const u8) ?c_int {
    const slice = std.mem.span(s);
    return std.fmt.parseInt(c_int, slice, 10) catch null;
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

export fn zig_parse_args(argc: c_int, argv: [*][*:0]const u8) *ParsedArgs {
    // Reset
    parsed = .{
        .mode = .gui,
        .input_path = null,
        .export_paths = &export_path_storage,
        .export_path_count = 0,
        .camera = null,
        .width = -1,
        .height = -1,
        .start_frame = 1,
        .end_frame = -1,
        .transparency = 0,
        .mcp_port = 0,
    };
    export_path_storage = .{null} ** 64;

    const args: [*][*:0]const u8 = argv;
    const count: usize = @intCast(argc);
    var i: usize = 1; // skip program name

    while (i < count) : (i += 1) {
        const arg = args[i];

        if (eql(arg, "-h") or eql(arg, "--help")) {
            std.debug.print("{s}", .{help_text});
            parsed.mode = .help;
            return &parsed;
        }
        if (eql(arg, "-v") or eql(arg, "--version")) {
            std.debug.print("{s}", .{version_text});
            parsed.mode = .version;
            return &parsed;
        }
        if (eql(arg, "--mcp")) {
            i += 1;
            if (i < count) {
                parsed.mcp_port = parseInt(args[i]) orelse 0;
            }
            if (parsed.mcp_port <= 0) {
                std.debug.print("Error: --mcp requires a valid port number\n", .{});
                parsed.mode = .err;
                return &parsed;
            }
            parsed.mode = .mcp;
            return &parsed;
        }
        if (eql(arg, "-o") or eql(arg, "--export") or eql(arg, "--export-sequence")) {
            i += 1;
            if (i < count) {
                const idx: usize = @intCast(parsed.export_path_count);
                if (idx < export_path_storage.len) {
                    export_path_storage[idx] = args[i];
                    parsed.export_path_count += 1;
                }
            }
            continue;
        }
        if (eql(arg, "--camera")) {
            i += 1;
            if (i < count) parsed.camera = args[i];
            continue;
        }
        if (eql(arg, "--width")) {
            i += 1;
            if (i < count) parsed.width = parseInt(args[i]) orelse -1;
            continue;
        }
        if (eql(arg, "--height")) {
            i += 1;
            if (i < count) parsed.height = parseInt(args[i]) orelse -1;
            continue;
        }
        if (eql(arg, "--start")) {
            i += 1;
            if (i < count) {
                const v = parseInt(args[i]) orelse 1;
                parsed.start_frame = if (v < 1) 1 else v;
            }
            continue;
        }
        if (eql(arg, "--end")) {
            i += 1;
            if (i < count) {
                if (eql(args[i], "last")) {
                    parsed.end_frame = -1;
                } else if (eql(args[i], "last-sound")) {
                    parsed.end_frame = -2;
                } else {
                    parsed.end_frame = parseInt(args[i]) orelse -1;
                }
            }
            continue;
        }
        if (eql(arg, "--transparency")) {
            parsed.transparency = 1;
            continue;
        }
        // Skip macOS debug argument
        if (eql(arg, "-NSDocumentRevisionsDebugMode")) {
            i += 1;
            continue;
        }
        // Positional argument = input file
        if (arg[0] != '-') {
            parsed.input_path = arg;
            continue;
        }
    }

    if (parsed.export_path_count > 0) {
        parsed.mode = .export_mode;
    }

    return &parsed;
}

export fn zig_get_help_text() [*:0]const u8 {
    return help_text;
}
