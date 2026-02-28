# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Zig is installed via winget. It is NOT on PATH in Git Bash. Always use the full path:

```bash
export ZIG="/c/Users/valen/AppData/Local/Microsoft/WinGet/Packages/zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe/zig-x86_64-windows-0.15.2/zig.exe"
"$ZIG" build                          # debug build
"$ZIG" build -Doptimize=ReleaseSmall  # release build (smaller binary)
```

The exe gets locked while running. Always kill before building:
```bash
taskkill.exe //f //im lightboard.exe 2>/dev/null; "$ZIG" build
```

Requires Zig 0.15.2+. Links libc. Targets Windows only (subsystem = .Windows).

Output binary: `zig-out/bin/lightboard.exe`

No tests, linter, or formatter configured yet. Use `"$ZIG" fmt src/` if needed.

## MANDATORY: After Every Code Change

After every code change, always do all of the following in order:
1. Commit and push to GitHub immediately
2. Kill + rebuild: `taskkill.exe //f //im lightboard.exe 2>/dev/null; "$ZIG" build`
3. Launch the new binary: `./zig-out/bin/lightboard.exe &`
4. Verify it's running: `tasklist.exe | grep -i lightboard`
5. Tell the user it's ready to test

Never wait for the user to ask — do this automatically after every change.

## MANDATORY: Keep CLAUDE.md Updated

When making significant changes (new features, new files, architecture changes, new hotkeys, new dependencies), update this file to reflect them. Keep the Architecture and Key Patterns sections accurate so future sessions start productive immediately.

## Architecture

Lightboard is a Windows clipboard history manager written in pure Zig with no external dependencies. It uses raw Win32 API calls (no Zig std GUI abstractions).

### Source Files

- **`src/main.zig`** - Application entry point, Win32 message loop, window management, hotkey registration, picker UI rendering (GDI paint), keyboard/mouse input handling, debug logging, and persistence orchestration. Contains all global state as file-level `var` declarations.
- **`src/clipboard.zig`** - Clipboard read/write operations. `capture()` reads current clipboard content (text or image). `restoreToClipboard()` writes an entry back. `sendCtrlV()` synthesizes a Ctrl+V keystroke via `SendInput`.
- **`src/history.zig`** - Data model (`Entry`, `Item`, `ImageMeta`, `History`) and binary persistence. History is a bounded ring buffer (default 120 entries) with consecutive duplicate suppression. File format uses `"LBRD1"` magic header with little-endian integers.
- **`src/win32.zig`** - Hand-written Win32 FFI bindings (types, constants, extern function declarations). No auto-generated bindings - add new Win32 functions here as needed.

### Key Patterns

- **Two windows**: A hidden message-only window (`g_message_hwnd`) receives clipboard updates and hotkey messages. A visible picker window (`g_picker_hwnd`) displays history and handles user interaction.
- **Hotkey cascade**: Tries multiple hotkey combos in order (Ctrl+Alt+B, Win+V, Ctrl+Shift+V, etc.) and registers the first one that succeeds. Also polls Ctrl+Alt+B and F8 as fallbacks via a 20ms timer.
- **Self-trigger guard**: `g_ignore_clipboard_updates` counter prevents re-capturing items we just pasted.
- **Target window tracking**: Continuously tracks the foreground window so paste can restore focus to the correct app after picker selection.
- **Picker rendering**: Custom GDI paint in `paintPicker()` - dark theme, card-style layout, scrollbar, text wrapping, and DIB thumbnail rendering for images.
- **Persistence**: Auto-saves to `%LOCALAPPDATA%\lightboard\history.bin` on every capture and at shutdown. Custom binary format (not JSON).

### Debug Logging

Writes to `lightboard-debug.log` in the working directory. Contains timestamped entries for hotkey registration, clipboard captures, paste operations, and window events.
