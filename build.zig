const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        // Force MSVC ABI on Windows so Zig uses MSVC system headers
        // instead of its bundled mingw headers.
        // Leave default ABI on macOS so the SDK is auto-detected.
        .default_target = if (@import("builtin").os.tag == .windows) .{
            .abi = .msvc,
        } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});

    const qt_prefix = b.option([]const u8, "qt-prefix", "Qt6 installation prefix") orelse
        "C:/Qt/6.8.2/msvc2022_64";

    const is_mac = @import("builtin").os.tag == .macos;
    const is_win = @import("builtin").os.tag == .windows;

    // ── zpix dependency (PNG/JPEG image support) ─────────────────────
    const zpix_dep = b.dependency("zpix", .{ .target = target, .optimize = optimize });
    const zpix_mod = zpix_dep.module("zpix");

    // ── pencil2d executable ──────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "pencil2d",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = if (is_win) null else true,
        }),
    });
    if (is_win) exe.subsystem = .Windows;
    configurePencil2d(b, exe, qt_prefix, zpix_mod, false, is_mac, is_win);
    b.installArtifact(exe);

    // ── pencil2d_tests executable ────────────────────────────────────
    const tests_exe = b.addExecutable(.{
        .name = "pencil2d_tests",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = if (is_win) null else true,
        }),
    });
    if (is_win) tests_exe.subsystem = .Console;
    configurePencil2d(b, tests_exe, qt_prefix, zpix_mod, true, is_mac, is_win);
    b.installArtifact(tests_exe);

    // ── run steps ────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run pencil2d");
    run_step.dependOn(&run_cmd.step);

    const test_cmd = b.addRunArtifact(tests_exe);
    test_cmd.step.dependOn(b.getInstallStep());
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_cmd.step);

    // ── Zig unit tests ───────────────────────────────────────────────
    const zig_test_mod = b.createModule(.{
        .root_source_file = b.path("zig_src/pencil2d.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_test_mod.addImport("zpix", zpix_mod);
    const zig_tests = b.addTest(.{ .root_module = zig_test_mod });
    const run_zig_tests = b.addRunArtifact(zig_tests);
    const zig_test_step = b.step("zig-test", "Run Zig unit tests");
    zig_test_step.dependOn(&run_zig_tests.step);
}

// ─────────────────────────────────────────────────────────────────────
// Build configuration shared by both pencil2d and pencil2d_tests
// ─────────────────────────────────────────────────────────────────────

fn configurePencil2d(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    qt_prefix: []const u8,
    zpix_mod: *std.Build.Module,
    is_test: bool,
    is_mac: bool,
    is_win: bool,
) void {
    const mod = exe.root_module;

    const cpp_flags: []const []const u8 = if (is_mac) &.{
        "-std=c++17",
        "-stdlib=libc++",
        "-DAPP_VERSION=\"0.0.0.0\"",
        "-DQT_DEPRECATED_WARNINGS",
        "-DQT_DISABLE_DEPRECATED_UP_TO=0x050F00",
        "-include",
        "core_lib/src/corelib-pch.h",
        "-include",
        "app/src/app-pch.h",
    } else &.{
        "-std=c++17",
        "-DAPP_VERSION=\"0.0.0.0\"",
        "-DQT_DEPRECATED_WARNINGS",
        "-DQT_DISABLE_DEPRECATED_UP_TO=0x050F00",
        "-Wno-unused-command-line-argument", // -nostdinc++ passed by Zig even when link_libcpp is null (ctaggart/zig#242)
        "-include",
        "core_lib/src/corelib-pch.h",
        "-include",
        "app/src/app-pch.h",
    };

    // ── Zig module (compiled as object, linked with C++) ────────────
    const zig_lib = b.addObject(.{
        .name = "pencil2d_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("zig_src/pencil2d.zig"),
            .target = mod.resolved_target,
            .optimize = mod.optimize,
        }),
    });
    zig_lib.root_module.addImport("zpix", zpix_mod);
    mod.addObject(zig_lib);

    // ── Embedded MCP server (separate object — has extern C deps) ────
    if (!is_test) {
        const mcp_lib = b.addObject(.{
            .name = "pencil2d_mcp_embedded",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zig_src/mcp_embedded.zig"),
                .target = mod.resolved_target,
                .optimize = mod.optimize,
            }),
        });
        mod.addObject(mcp_lib);
    }

    // ── Source include paths ─────────────────────────────────────────
    for (project_include_dirs) |dir| {
        mod.addIncludePath(b.path(dir));
    }
    // Platform header
    if (is_win) {
        mod.addIncludePath(b.path("core_lib/src/external/win32"));
    } else if (is_mac) {
        mod.addIncludePath(b.path("core_lib/src/external/macosx"));
    }

    // ── Qt include paths ─────────────────────────────────────────────
    if (is_mac) {
        // macOS Homebrew Qt uses frameworks; add framework search path for linking
        // and explicit include paths for C++ compilation
        mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/lib", .{qt_prefix}) });
        for (qt_modules) |qmod| {
            mod.addSystemIncludePath(.{
                .cwd_relative = b.fmt("{s}/lib/{s}.framework/Headers", .{ qt_prefix, qmod }),
            });
        }
    } else {
        const qt_inc = b.fmt("{s}/include", .{qt_prefix});
        mod.addSystemIncludePath(.{ .cwd_relative = qt_inc });
        for (qt_modules) |qmod| {
            mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/include/{s}", .{ qt_prefix, qmod }) });
        }
    }

    // ── Qt tool executables ──────────────────────────────────────────
    // Different Qt installations put tools in different places:
    //   Homebrew Qt 6.11+: share/qt/libexec/
    //   aqtinstall (CI):   libexec/ or bin/
    //   System Qt:         bin/
    const exe_ext = if (is_win) ".exe" else "";
    const qt_tool_dir = findQtToolDir(b, qt_prefix, exe_ext);

    // On macOS, Qt tools (moc/uic/rcc) need to find Qt frameworks at runtime.
    // When Qt is installed to a non-standard prefix (e.g. CI via aqtinstall),
    // we must set DYLD_FRAMEWORK_PATH so the tools can load their dependencies.
    const qt_lib_dir: ?[]const u8 = if (is_mac) b.fmt("{s}/lib", .{qt_prefix}) else null;

    // ── UIC: generate ui_*.h from .ui files ──────────────────────────
    const uic_path = b.fmt("{s}/{s}/uic{s}", .{ qt_prefix, qt_tool_dir, exe_ext });
    const uic_dir = runUic(b, uic_path, qt_lib_dir);
    mod.addIncludePath(uic_dir);

    // ── MOC: generate moc_*.cpp from Q_OBJECT headers ────────────────
    const moc_path = b.fmt("{s}/{s}/moc{s}", .{ qt_prefix, qt_tool_dir, exe_ext });
    runMoc(b, mod, moc_path, qt_prefix, cpp_flags, core_moc_headers, is_mac, qt_lib_dir);
    if (!is_test) {
        runMoc(b, mod, moc_path, qt_prefix, cpp_flags, app_moc_headers, is_mac, qt_lib_dir);
    }

    // ── RCC: generate qrc_*.cpp from .qrc files ─────────────────────
    const rcc_path = b.fmt("{s}/{s}/rcc{s}", .{ qt_prefix, qt_tool_dir, exe_ext });
    if (is_test) {
        runRcc(b, mod, rcc_path, cpp_flags, test_qrc_files, qt_lib_dir);
    } else {
        runRcc(b, mod, rcc_path, cpp_flags, qrc_files, qt_lib_dir);
    }

    // ── C++ source files ─────────────────────────────────────────────
    mod.addCSourceFiles(.{
        .root = b.path("."),
        .files = core_lib_sources,
        .flags = cpp_flags,
    });
    // Platform source
    if (is_win) {
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = &.{"core_lib/src/external/win32/win32.cpp"},
            .flags = cpp_flags,
        });
    } else if (is_mac) {
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = &.{"core_lib/src/external/macosx/macosx.cpp"},
            .flags = cpp_flags,
        });
        // Objective-C++ source
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = &.{"core_lib/src/external/macosx/macosxnative.mm"},
            .flags = &.{ "-std=c++17", "-stdlib=libc++", "-fobjc-arc" },
        });
    }

    if (is_test) {
        mod.addIncludePath(b.path("tests/src"));
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = test_sources,
            .flags = cpp_flags,
        });
    } else {
        mod.addIncludePath(b.path("app/src"));
        mod.addCSourceFiles(.{
            .root = b.path("."),
            .files = app_sources,
            .flags = cpp_flags,
        });
    }

    // ── Link Qt6 libraries ───────────────────────────────────────────
    if (is_win) {
        // Windows: link .lib import libraries directly
        for (qt_link_libs) |lib| {
            mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}.lib", .{ qt_prefix, lib }) });
        }
        // Windows system libraries
        for (win_system_libs) |lib| {
            mod.linkSystemLibrary(lib, .{});
        }
    } else if (is_mac) {
        // macOS: link Qt frameworks
        mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/lib", .{qt_prefix}) });
        for (qt_framework_names) |fw| {
            mod.linkFramework(fw, .{});
        }
        // macOS system frameworks
        mod.linkFramework("Cocoa", .{});
        mod.linkFramework("IOKit", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.linkFramework("CoreText", .{});
        mod.linkFramework("Metal", .{});
        mod.linkFramework("AppKit", .{});
    }
}

// ─────────────────────────────────────────────────────────────────────
// Qt tool runners
// ─────────────────────────────────────────────────────────────────────

/// Probe common Qt tool directories and return the first one containing "moc".
fn findQtToolDir(b: *std.Build, qt_prefix: []const u8, exe_ext: []const u8) []const u8 {
    const candidates = [_][]const u8{
        "share/qt/libexec", // Homebrew Qt 6.11+
        "libexec",          // aqtinstall on macOS
        "bin",              // system Qt / Windows / Linux
    };
    if (std.fs.path.isAbsolute(qt_prefix)) {
        for (candidates) |dir| {
            const probe = b.fmt("{s}/{s}/moc{s}", .{ qt_prefix, dir, exe_ext });
            std.Io.Dir.accessAbsolute(b.graph.io, probe, .{}) catch continue;
            return dir;
        }
    }
    // Fall back to "bin" if nothing found or prefix is not absolute.
    return "bin";
}

fn runUic(b: *std.Build, uic_path: []const u8, qt_lib_dir: ?[]const u8) std.Build.LazyPath {
    // Generate all ui_*.h into a shared output directory.
    // We use a WriteFiles step to collect outputs.
    const wf = b.addWriteFiles();
    for (ui_files) |ui| {
        const basename = std.fs.path.stem(ui);
        const cmd = b.addSystemCommand(&.{uic_path});
        if (qt_lib_dir) |lib_dir| cmd.setEnvironmentVariable("DYLD_FRAMEWORK_PATH", lib_dir);
        cmd.addFileArg(b.path(ui));
        cmd.addArg("-o");
        const out = cmd.addOutputFileArg(b.fmt("ui_{s}.h", .{basename}));
        _ = wf.addCopyFile(out, b.fmt("ui_{s}.h", .{basename}));
    }
    return wf.getDirectory();
}

fn runMoc(
    b: *std.Build,
    mod: *std.Build.Module,
    moc_path: []const u8,
    qt_prefix: []const u8,
    cpp_flags: []const []const u8,
    headers: []const []const u8,
    is_mac: bool,
    qt_lib_dir: ?[]const u8,
) void {
    for (headers) |hdr| {
        const basename = std.fs.path.stem(hdr);
        const cmd = b.addSystemCommand(&.{moc_path});
        if (qt_lib_dir) |lib_dir| cmd.setEnvironmentVariable("DYLD_FRAMEWORK_PATH", lib_dir);
        // Pass Qt defines to MOC
        cmd.addArgs(&.{
            "-DQT_DEPRECATED_WARNINGS",
            "-DQT_DISABLE_DEPRECATED_UP_TO=0x050F00",
        });
        // Pass Qt include paths to MOC
        if (is_mac) {
            // macOS: use framework search paths
            cmd.addArgs(&.{ "-F", b.fmt("{s}/lib", .{qt_prefix}) });
        } else {
            cmd.addArgs(&.{ "-I", b.fmt("{s}/include", .{qt_prefix}) });
            cmd.addArgs(&.{ "-I", b.fmt("{s}/include/QtCore", .{qt_prefix}) });
            cmd.addArgs(&.{ "-I", b.fmt("{s}/include/QtWidgets", .{qt_prefix}) });
            cmd.addArgs(&.{ "-I", b.fmt("{s}/include/QtGui", .{qt_prefix}) });
        }
        // Pass project include paths to MOC
        for (project_include_dirs) |dir| {
            cmd.addArgs(&.{ "-I", b.pathJoin(&.{ b.build_root.path orelse ".", dir }) });
        }
        cmd.addFileArg(b.path(hdr));
        cmd.addArg("-o");
        const moc_out = cmd.addOutputFileArg(b.fmt("moc_{s}.cpp", .{basename}));
        mod.addCSourceFile(.{ .file = moc_out, .flags = cpp_flags });
    }
}

fn runRcc(
    b: *std.Build,
    mod: *std.Build.Module,
    rcc_path: []const u8,
    cpp_flags: []const []const u8,
    files: []const []const u8,
    qt_lib_dir: ?[]const u8,
) void {
    for (files) |qrc| {
        const basename = std.fs.path.stem(qrc);
        const cmd = b.addSystemCommand(&.{rcc_path});
        if (qt_lib_dir) |lib_dir| cmd.setEnvironmentVariable("DYLD_FRAMEWORK_PATH", lib_dir);
        cmd.addArg("--name");
        cmd.addArg(basename);
        cmd.addFileArg(b.path(qrc));
        cmd.addArg("-o");
        const rcc_out = cmd.addOutputFileArg(b.fmt("qrc_{s}.cpp", .{basename}));
        mod.addCSourceFile(.{ .file = rcc_out, .flags = cpp_flags });
    }
}

// ─────────────────────────────────────────────────────────────────────
// File lists (mirrors CMake configuration)
// ─────────────────────────────────────────────────────────────────────

const project_include_dirs: []const []const u8 = &.{
    "core_lib/src",
    "core_lib/src/graphics",
    "core_lib/src/graphics/bitmap",
    "core_lib/src/graphics/vector",
    "core_lib/src/interface",
    "core_lib/src/structure",
    "core_lib/src/tool",
    "core_lib/src/util",
    "core_lib/src/managers",
    "core_lib/src/external",
    "app/src",
};

const qt_modules: []const []const u8 = &.{
    "QtCore",
    "QtWidgets",
    "QtGui",
    "QtXml",
    "QtMultimedia",
    "QtSvg",
    "QtNetwork",
};

const qt_link_libs: []const []const u8 = &.{
    "Qt6Core",
    "Qt6Widgets",
    "Qt6Gui",
    "Qt6Xml",
    "Qt6Multimedia",
    "Qt6Svg",
    "Qt6Network",
    "Qt6EntryPoint",
};

// macOS Qt framework names (without "6" prefix or EntryPoint)
const qt_framework_names: []const []const u8 = &.{
    "QtCore",
    "QtWidgets",
    "QtGui",
    "QtXml",
    "QtMultimedia",
    "QtSvg",
    "QtNetwork",
};

const win_system_libs: []const []const u8 = &.{
    "user32",
    "gdi32",
    "shell32",
    "ole32",
    "advapi32",
    "ws2_32",
    "dwmapi",
    "uxtheme",
    "imm32",
    "winmm",
    "version",
    "opengl32",
};

const core_lib_sources: []const []const u8 = &.{
    "core_lib/src/activeframepool.cpp",
    "core_lib/src/camerapainter.cpp",
    "core_lib/src/canvascursorpainter.cpp",
    "core_lib/src/canvaspainter.cpp",
    "core_lib/src/graphics/bitmap/bitmapbucket.cpp",
    "core_lib/src/graphics/bitmap/bitmapimage.cpp",
    "core_lib/src/graphics/bitmap/tile.cpp",
    "core_lib/src/graphics/bitmap/tiledbuffer.cpp",
    "core_lib/src/graphics/vector/bezierarea.cpp",
    "core_lib/src/graphics/vector/beziercurve.cpp",
    "core_lib/src/graphics/vector/colorref.cpp",
    "core_lib/src/graphics/vector/vectorimage.cpp",
    "core_lib/src/graphics/vector/vectorselection.cpp",
    "core_lib/src/graphics/vector/vertexref.cpp",
    "core_lib/src/interface/backgroundwidget.cpp",
    "core_lib/src/interface/editor.cpp",
    "core_lib/src/interface/flowlayout.cpp",
    "core_lib/src/interface/legacybackupelement.cpp",
    "core_lib/src/interface/recentfilemenu.cpp",
    "core_lib/src/interface/scribblearea.cpp",
    "core_lib/src/interface/toolboxlayout.cpp",
    "core_lib/src/interface/undoredocommand.cpp",
    "core_lib/src/managers/basemanager.cpp",
    "core_lib/src/managers/clipboardmanager.cpp",
    "core_lib/src/managers/colormanager.cpp",
    "core_lib/src/managers/layermanager.cpp",
    "core_lib/src/managers/overlaymanager.cpp",
    "core_lib/src/managers/playbackmanager.cpp",
    "core_lib/src/managers/preferencemanager.cpp",
    "core_lib/src/managers/selectionmanager.cpp",
    "core_lib/src/managers/soundmanager.cpp",
    "core_lib/src/managers/toolmanager.cpp",
    "core_lib/src/managers/undoredomanager.cpp",
    "core_lib/src/managers/viewmanager.cpp",
    "core_lib/src/movieexporter.cpp",
    "core_lib/src/movieimporter.cpp",
    "core_lib/src/onionskinsubpainter.cpp",
    "core_lib/src/overlaypainter.cpp",
    "core_lib/src/qminiz.cpp",
    "core_lib/src/selectionpainter.cpp",
    "core_lib/src/soundplayer.cpp",
    "core_lib/src/structure/camera.cpp",
    "core_lib/src/structure/filemanager.cpp",
    "core_lib/src/structure/keyframe.cpp",
    "core_lib/src/structure/layer.cpp",
    "core_lib/src/structure/layerbitmap.cpp",
    "core_lib/src/structure/layercamera.cpp",
    "core_lib/src/structure/layersound.cpp",
    "core_lib/src/structure/layervector.cpp",
    "core_lib/src/structure/object.cpp",
    "core_lib/src/structure/objectdata.cpp",
    "core_lib/src/structure/pegbaraligner.cpp",
    "core_lib/src/structure/soundclip.cpp",
    "core_lib/src/tool/basetool.cpp",
    "core_lib/src/tool/brushtool.cpp",
    "core_lib/src/tool/buckettool.cpp",
    "core_lib/src/tool/cameratool.cpp",
    "core_lib/src/tool/erasertool.cpp",
    "core_lib/src/tool/eyedroppertool.cpp",
    "core_lib/src/tool/handtool.cpp",
    "core_lib/src/tool/movetool.cpp",
    "core_lib/src/tool/penciltool.cpp",
    "core_lib/src/tool/pentool.cpp",
    "core_lib/src/tool/polylinetool.cpp",
    "core_lib/src/tool/radialoffsettool.cpp",
    "core_lib/src/tool/selecttool.cpp",
    "core_lib/src/tool/smudgetool.cpp",
    "core_lib/src/tool/strokeinterpolator.cpp",
    "core_lib/src/tool/stroketool.cpp",
    "core_lib/src/tool/transformtool.cpp",
    "core_lib/src/util/blitrect.cpp",
    "core_lib/src/util/cameraeasingtype.cpp",
    "core_lib/src/util/fileformat.cpp",
    "core_lib/src/util/log.cpp",
    "core_lib/src/util/pencilerror.cpp",
    "core_lib/src/util/pencilsettings.cpp",
    "core_lib/src/util/pointerevent.cpp",
    "core_lib/src/util/transform.cpp",
    "core_lib/src/util/util.cpp",
};

const app_sources: []const []const u8 = &.{
    "app/src/aboutdialog.cpp",
    "app/src/actioncommands.cpp",
    "app/src/addtransparencytopaperdialog.cpp",
    "app/src/app_util.cpp",
    "app/src/basedockwidget.cpp",
    "app/src/basewidget.cpp",
    "app/src/bucketoptionswidget.cpp",
    "app/src/buttonappearancewatcher.cpp",
    "app/src/cameracontextmenu.cpp",
    "app/src/cameraoptionswidget.cpp",
    "app/src/camerapropertiesdialog.cpp",
    "app/src/checkupdatesdialog.cpp",
    "app/src/colorbox.cpp",
    "app/src/colorinspector.cpp",
    "app/src/colorpalettewidget.cpp",
    "app/src/colorslider.cpp",
    "app/src/colorwheel.cpp",
    "app/src/commandlineexporter.cpp",
    // "app/src/commandlineparser.cpp", // replaced by zig_src/cli.zig
    "app/src/doubleprogressdialog.cpp",
    "app/src/elidedlabel.cpp",
    "app/src/errordialog.cpp",
    "app/src/exportimagedialog.cpp",
    "app/src/exportmoviedialog.cpp",
    "app/src/filedialog.cpp",
    "app/src/filespage.cpp",
    "app/src/generalpage.cpp",
    "app/src/importexportdialog.cpp",
    "app/src/importimageseqdialog.cpp",
    "app/src/importlayersdialog.cpp",
    "app/src/importpositiondialog.cpp",
    "app/src/layeropacitydialog.cpp",
    "app/src/main.cpp",
    "app/src/mainwindow2.cpp",
    "app/src/mcphandler.cpp",
    "app/src/onionskinwidget.cpp",
    "app/src/pegbaralignmentdialog.cpp",
    "app/src/pencil2d.cpp",
    "app/src/predefinedsetmodel.cpp",
    "app/src/preferencesdialog.cpp",
    "app/src/presetdialog.cpp",
    "app/src/repositionframesdialog.cpp",
    "app/src/shortcutfilter.cpp",
    "app/src/shortcutspage.cpp",
    "app/src/spinslider.cpp",
    "app/src/statusbar.cpp",
    "app/src/strokeoptionswidget.cpp",
    "app/src/timecontrols.cpp",
    "app/src/timeline.cpp",
    "app/src/timelinecells.cpp",
    "app/src/timelinepage.cpp",
    "app/src/titlebarwidget.cpp",
    "app/src/toolbox.cpp",
    "app/src/toolboxwidget.cpp",
    "app/src/tooloptionwidget.cpp",
    "app/src/toolspage.cpp",
    "app/src/transformoptionswidget.cpp",
};

const test_sources: []const []const u8 = &.{
    "tests/src/main.cpp",
    "tests/src/test_colormanager.cpp",
    "tests/src/test_layer.cpp",
    "tests/src/test_layerbitmap.cpp",
    "tests/src/test_layercamera.cpp",
    "tests/src/test_layermanager.cpp",
    "tests/src/test_layersound.cpp",
    "tests/src/test_layervector.cpp",
    "tests/src/test_object.cpp",
    "tests/src/test_filemanager.cpp",
    "tests/src/test_bitmapimage.cpp",
    "tests/src/test_bitmapbucket.cpp",
    "tests/src/test_vectorimage.cpp",
    "tests/src/test_viewmanager.cpp",
};

// Headers containing Q_OBJECT that need MOC processing
const core_moc_headers: []const []const u8 = &.{
    // core_lib
    "core_lib/src/graphics/bitmap/tiledbuffer.h",
    "core_lib/src/interface/backgroundwidget.h",
    "core_lib/src/interface/editor.h",
    "core_lib/src/interface/legacybackupelement.h",
    "core_lib/src/interface/recentfilemenu.h",
    "core_lib/src/interface/scribblearea.h",
    "core_lib/src/managers/basemanager.h",
    "core_lib/src/managers/clipboardmanager.h",
    "core_lib/src/managers/colormanager.h",
    "core_lib/src/managers/layermanager.h",
    "core_lib/src/managers/overlaymanager.h",
    "core_lib/src/managers/playbackmanager.h",
    "core_lib/src/managers/preferencemanager.h",
    "core_lib/src/managers/selectionmanager.h",
    "core_lib/src/managers/soundmanager.h",
    "core_lib/src/managers/toolmanager.h",
    "core_lib/src/managers/undoredomanager.h",
    "core_lib/src/managers/viewmanager.h",
    "core_lib/src/movieimporter.h",
    "core_lib/src/soundplayer.h",
    "core_lib/src/structure/filemanager.h",
    "core_lib/src/tool/basetool.h",
    "core_lib/src/tool/brushtool.h",
    "core_lib/src/tool/buckettool.h",
    "core_lib/src/tool/cameratool.h",
    "core_lib/src/tool/erasertool.h",
    "core_lib/src/tool/eyedroppertool.h",
    "core_lib/src/tool/handtool.h",
    "core_lib/src/tool/movetool.h",
    "core_lib/src/tool/penciltool.h",
    "core_lib/src/tool/pentool.h",
    "core_lib/src/tool/polylinetool.h",
    "core_lib/src/tool/radialoffsettool.h",
    "core_lib/src/tool/selecttool.h",
    "core_lib/src/tool/smudgetool.h",
    "core_lib/src/tool/stroketool.h",
    "core_lib/src/tool/transformtool.h",
};

const app_moc_headers: []const []const u8 = &.{
    // app
    "app/src/aboutdialog.h",
    "app/src/actioncommands.h",
    "app/src/addtransparencytopaperdialog.h",
    "app/src/basedockwidget.h",
    "app/src/basewidget.h",
    "app/src/bucketoptionswidget.h",
    "app/src/buttonappearancewatcher.h",
    "app/src/cameracontextmenu.h",
    "app/src/cameraoptionswidget.h",
    "app/src/camerapropertiesdialog.h",
    "app/src/checkupdatesdialog.h",
    "app/src/colorbox.h",
    "app/src/colorinspector.h",
    "app/src/colorpalettewidget.h",
    "app/src/colorslider.h",
    "app/src/colorwheel.h",
    "app/src/commandlineexporter.h",
    // "app/src/commandlineparser.h", // replaced by zig_src/cli.zig
    "app/src/doubleprogressdialog.h",
    "app/src/elidedlabel.h",
    "app/src/errordialog.h",
    "app/src/exportimagedialog.h",
    "app/src/exportmoviedialog.h",
    "app/src/filedialog.h",
    "app/src/filespage.h",
    "app/src/generalpage.h",
    "app/src/importexportdialog.h",
    "app/src/importimageseqdialog.h",
    "app/src/importlayersdialog.h",
    "app/src/importpositiondialog.h",
    "app/src/layeropacitydialog.h",
    "app/src/mainwindow2.h",
    "app/src/mcphandler.h",
    "app/src/onionskinwidget.h",
    "app/src/pegbaralignmentdialog.h",
    "app/src/pencil2d.h",
    "app/src/predefinedsetmodel.h",
    "app/src/preferencesdialog.h",
    "app/src/presetdialog.h",
    "app/src/repositionframesdialog.h",
    "app/src/shortcutfilter.h",
    "app/src/shortcutspage.h",
    "app/src/spinslider.h",
    "app/src/statusbar.h",
    "app/src/strokeoptionswidget.h",
    "app/src/timecontrols.h",
    "app/src/timeline.h",
    "app/src/timelinecells.h",
    "app/src/timelinepage.h",
    "app/src/titlebarwidget.h",
    "app/src/toolbox.h",
    "app/src/toolboxwidget.h",
    "app/src/tooloptionwidget.h",
    "app/src/toolspage.h",
    "app/src/transformoptionswidget.h",
};

const ui_files: []const []const u8 = &.{
    "app/ui/aboutdialog.ui",
    "app/ui/addtransparencytopaperdialog.ui",
    "app/ui/bucketoptionswidget.ui",
    "app/ui/cameraoptionswidget.ui",
    "app/ui/camerapropertiesdialog.ui",
    "app/ui/colorinspector.ui",
    "app/ui/colorpalette.ui",
    "app/ui/doubleprogressdialog.ui",
    "app/ui/errordialog.ui",
    "app/ui/exportimageoptions.ui",
    "app/ui/exportmovieoptions.ui",
    "app/ui/filespage.ui",
    "app/ui/generalpage.ui",
    "app/ui/importexportdialog.ui",
    "app/ui/importimageseqoptions.ui",
    "app/ui/importimageseqpreview.ui",
    "app/ui/importlayersdialog.ui",
    "app/ui/importpositiondialog.ui",
    "app/ui/layeropacitydialog.ui",
    "app/ui/mainwindow2.ui",
    "app/ui/onionskin.ui",
    "app/ui/pegbaralignmentdialog.ui",
    "app/ui/preferencesdialog.ui",
    "app/ui/presetdialog.ui",
    "app/ui/repositionframesdialog.ui",
    "app/ui/shortcutspage.ui",
    "app/ui/strokeoptionswidget.ui",
    "app/ui/timelinepage.ui",
    "app/ui/toolboxwidget.ui",
    "app/ui/tooloptions.ui",
    "app/ui/toolspage.ui",
    "app/ui/transformoptionswidget.ui",
};

const qrc_files: []const []const u8 = &.{
    "core_lib/data/core_lib.qrc",
    "app/data/app.qrc",
};

const test_qrc_files: []const []const u8 = &.{
    "core_lib/data/core_lib.qrc",
    "tests/data/tests.qrc",
};
