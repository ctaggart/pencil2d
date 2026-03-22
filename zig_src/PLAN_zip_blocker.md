# Blocker: Zig Io.Threaded crashes when linked into C++ executable

## Problem

The Zig ZIP module (`zig_src/pclx_zip.zig`) works correctly when run as a standalone Zig test (`zig test zig_src/pclx_zip.zig` — 2 tests pass). However, when its C ABI exports are linked into the Pencil2D C++ executable via the `pencil2d.zig` root module, the app crashes at startup.

## Root Cause

Zig 0.16-dev's new `std.Io` API requires an `Io` context for all file operations (`openFile`, `createFile`, `close`, etc.). In test mode, `std.testing.io` provides this automatically. In production code, you must create an `Io.Threaded` instance:

```zig
var threaded = Io.Threaded.init(std.heap.page_allocator, .{});
const io = threaded.io();
```

The problem: when this `Io.Threaded.init` runs inside a C++ process (the Pencil2D exe), it crashes. The crash happens because:

1. `Io.Threaded.init` expects to run in a Zig-native entry point where the Zig runtime is initialized
2. When Zig code is compiled as an object file and linked into a C++ executable, the Zig runtime startup (which normally initializes thread-local storage, signal handlers, etc.) may not run
3. The crash manifests as exit code 3 with a stack trace pointing to `__scrt_common_main_seh` (MSVC CRT startup)

## What Works

- All 28 non-Io Zig exports (enums, math, bezier, pixel buffer, events) work fine — they don't touch `std.Io`
- The ZIP module works perfectly in `zig test` mode
- The ZIP writer/reader logic is correct (roundtrip test passes)

## What Doesn't Work

When `pencil2d.zig` imports `pclx_zip.zig` via:
```zig
pub const pclx_zip = @import("pclx_zip.zig");
comptime { _ = &pclx_zip; }  // force exports
```

Even if the ZIP functions are never called, the crash occurs. Removing this import fixes the crash.

## Current Code

- `zig_src/pclx_zip.zig` — The ZIP module with C ABI exports
- `zig_src/pencil2d.zig` — The root module (currently does NOT import pclx_zip.zig)
- `core_lib/src/qminiz.h` / `qminiz.cpp` — C++ code still using vendored miniz

## Possible Solutions

### Option A: Use raw OS file handles instead of std.Io

Bypass `std.Io` entirely. Use Windows API directly:
```zig
const windows = std.os.windows;
const handle = windows.kernel32.CreateFileA(path, ...);
// Read/write using ReadFile/WriteFile
```

This avoids the `Io.Threaded` initialization entirely. The deflate compressor and CRC32 don't need Io — only file open/read/write/close do.

**Pros**: No runtime initialization needed, works in any host process
**Cons**: Platform-specific (need separate code for Linux/macOS), more verbose

### Option B: Have C++ pass file handles to Zig

Change the C ABI so C++ opens the files (using Qt's QFile or fopen) and passes the raw file descriptor/handle to Zig:

```c
// C++ opens the file
int fd = open(path, O_RDONLY);
// Pass to Zig
zig_zip_extract_from_fd(fd, dest_path);
```

**Pros**: Clean separation, works cross-platform via C file descriptors
**Cons**: More complex C ABI, still need Io for directory operations (mkdir, etc.)

### Option C: Initialize Zig runtime from C++

Call a Zig initialization function before any Io operations:
```zig
export fn zig_init() void {
    // Initialize whatever Io.Threaded needs
}
```

Have C++ call `zig_init()` early in `main()`.

**Pros**: Clean, works with current std.Io API
**Cons**: May not be possible — Zig runtime init may require being the actual entry point

### Option D: Wait for Zig 0.16 to stabilize

The Io API is brand new in 0.16-dev. It may get a simpler blocking mode that doesn't require Threaded initialization. The old `std.fs` API (used in Zig 0.13-0.14) didn't have this issue.

**Pros**: No work needed
**Cons**: Unknown timeline

## Recommended Approach

**Option A** is the most pragmatic. The ZIP operations only need:
- `CreateFileA` / `open()` — open a file
- `ReadFile` / `read()` — read bytes
- `WriteFile` / `write()` — write bytes
- `CloseHandle` / `close()` — close file
- `CreateDirectoryA` / `mkdir()` — create directory

These are simple syscalls that work without any Zig runtime initialization. The `std.compress.flate.Compress` and `std.hash.Crc32` modules do NOT use Io — they operate on in-memory buffers. Only the file I/O needs replacement.

## Build & Test Commands

```bash
# Run ZIP tests (standalone — works)
zig test zig_src/pclx_zip.zig

# Build full project (ZIP NOT linked — works)
zig build -Dtarget=x86_64-windows-msvc

# Run C++ tests
set QT_QPA_PLATFORM=minimal
set PATH=C:\Qt\6.8.2\msvc2022_64\bin;%PATH%
zig-out\bin\pencil2d_tests.exe
```

## Files to Modify

1. `zig_src/pclx_zip.zig` — Replace `std.Io.Dir.cwd().openFile(io, ...)` with raw OS calls
2. `zig_src/pencil2d.zig` — Re-add `comptime { _ = &pclx_zip; }` to link ZIP exports
3. `core_lib/src/qminiz.h` — Replace `#include "miniz.h"` with Zig C ABI declarations
4. `core_lib/src/qminiz.cpp` — Call Zig functions instead of miniz
5. `build.zig` — Remove `miniz.cpp` from source list
