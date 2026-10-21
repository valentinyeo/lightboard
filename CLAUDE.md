# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Requires Zig 0.16.0+ on Windows. If `zig` is not on PATH, use the installed Zig path or a downloaded 0.16.0+ compiler.

```bash
zig build                     # release build (ReleaseSmall by default, see below)
zig build -Doptimize=Debug    # debug build (safety checks, larger binary)
zig build -Dlog=true          # force dbgLog file logging on even in a release build
```

`zig build` with no flags now produces an optimized `ReleaseSmall` exe. Zig 0.16's
`standardOptimizeOption` only honors a preferred default when `-Drelease`/`--release=`
is passed on the command line; without it, that helper always falls back to `Debug`. So
`build.zig` reads `-Doptimize=` manually and supplies `ReleaseSmall` as the real default
(same pattern as `../zig-switch/build.zig`) while `-Doptimize=Debug`/`ReleaseSafe`/`ReleaseFast`
still override it. `ReleaseSmall` and `ReleaseFast` both disable Zig's runtime safety
checks; use `-Doptimize=Debug` or `ReleaseSafe` to get a safety panic with a stack trace.

The exe gets locked while running. Always kill before building:
```bash
taskkill.exe //f //im lightboard.exe 2>/dev/null; zig build
```

Links libc. Targets Windows only (subsystem = .Windows).

Output binary: `zig-out/bin/lightboard.exe`

Run `zig build test` for host-native clipboard privacy policy tests, including during Windows cross-compilation. Use `"$ZIG" fmt src/ build.zig` for formatting.

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

## MANDATORY: No WH_KEYBOARD_LL

Never install a low-level keyboard hook (`SetWindowsHookExW(WH_KEYBOARD_LL, ...)`) in this
project. It crashes this machine. This is why Win+V is delivered via `RegisterHotKey`
instead (see "Power behaviour" below) — do not "fix" a Win+V problem by reintroducing a
keyboard hook. `SetWinEventHook` (used for foreground-window tracking) is fine; it is a
WinEvent hook, not a keyboard hook, and does not receive keystrokes.

## MANDATORY: Hotkeys Are Fixed

See [AGENTS.md](AGENTS.md) for the canonical hotkey contract. Do not change Lightboard's hotkeys unless the user explicitly asks to change hotkeys.

- `Win+V` is the primary hotkey and must stay primary. It is registered with
  `RegisterHotKey(MOD_WIN | MOD_NOREPEAT, 'V')` — see `registerWinVHotkey()` in `src/main.zig`.
- `Ctrl+Alt+B` and `F8` are fallbacks only.
- Explorer reserves Win+V by default, which makes `RegisterHotKey` fail with no other
  symptom. The fix is `tools/free-win-v.ps1` (run manually, elevated; it edits
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\DisabledHotkeys` and
  restarts Explorer). Lightboard itself never touches the registry. If Win+V isn't
  working, check `lightboard-debug.log` (or console output) for `failed hotkey: Win+V` —
  that's the signal to run the script, not to reach for a keyboard hook.
- If `TextInputHost.exe` / Windows Input Experience comes back, fix the system disable
  (see below). Do not "solve" it by removing `Win+V` or making the fallbacks primary.
- Picker navigation while the picker has focus is plain `WM_KEYDOWN` — no hook involved.
  If the user keeps Win physically held down after triggering Win+V and then presses
  Up/Down/S/X/Enter, those may hit OS-reserved shortcuts (Snap, Search, Quick Link menu,
  Narrator) instead of reaching the picker. Releasing Win before navigating avoids this;
  this is an accepted, documented behaviour change from the old hook-based build, which
  force-delivered those keys to the picker regardless of what Windows wanted to do with them.

## TextInputHost Troubleshooting

When Windows Input Experience appears instead of Lightboard, use this sequence:

1. Verify Lightboard is running and the hotkey registered (requires a debug build or
   `-Dlog=true`, since dbgLog file logging is off by default in release builds):
   ```powershell
   Get-Process lightboard
   Get-Content .\lightboard-debug.log -Tail 30
   ```
   Look for `registered hotkey: Win+V` and `hotkey active: Win+V`. `failed hotkey: Win+V`
   means Explorer still owns it — run `tools/free-win-v.ps1` (elevated).
2. Press `Win+V` and check the log for `WM_HOTKEY toggle id=3` (id 3 = Win+V).
3. If `TextInputHost.exe` respawns, run the dedicated script from elevated PowerShell:
   ```powershell
   cd C:\Users\valen\Documents\GitHub\windows-stuff
   powershell -ExecutionPolicy Bypass -File .\Disable-TextInputHost.ps1
   ```
4. Undo, if needed:
   ```powershell
   cd C:\Users\valen\Documents\GitHub\windows-stuff
   powershell -ExecutionPolicy Bypass -File .\Disable-TextInputHost.ps1 -Undo
   ```

The disable script uses IFEO, preload/task/package settings, kills the running process, and renames `TextInputHost.exe` to `.bak` because COM activation can bypass IFEO and respawn it. Regular keyboard typing is not affected; Windows emoji picker, native clipboard history, voice typing, and touch keyboard are affected.

## Architecture

Lightboard is a Windows clipboard history manager written in pure Zig with no external dependencies. It uses raw Win32 API calls (no Zig std GUI abstractions). Also links ntdll for LZNT1 compression.

### Source Files

- **`src/main.zig`** - Application entry point, Win32 message loop, window management, hotkey registration, picker UI rendering (GDI paint), keyboard/mouse input handling, debug logging, and persistence orchestration. Contains all global state as file-level `var` declarations.
- **`src/clipboard.zig`** - Clipboard read/write operations. `capture()` reads current clipboard content (text or image), compresses images to disk. `restoreToClipboard()` loads images from disk for pasting. `sendCtrlV()` synthesizes a Ctrl+V keystroke via `SendInput`.
- **`src/history.zig`** - Data model (`Entry`, `Item`, `ImageMeta`, `History`) and binary persistence. History is a bounded ring buffer (default 20 entries) with consecutive duplicate suppression. File format uses `"LBRD3"` magic header (backward-compatible with `"LBRD1"`/`"LBRD2"`, auto-migrates on first save).
- **`src/image_store.zig`** - Compressed image file management. Saves raw DIB data as LZNT1-compressed `.lz` files in `%LOCALAPPDATA%\lightboard\images\`. Provides save/load/delete operations. Uses ntdll `RtlCompressBuffer`/`RtlDecompressBuffer`.
- **`src/win32.zig`** - Hand-written Win32 FFI bindings (types, constants, extern function declarations). Includes ntdll compression functions. No auto-generated bindings - add new Win32 functions here as needed.

### Key Patterns

- **Two windows**: A hidden message-only window (`g_message_hwnd`) receives clipboard updates and hotkey messages. A visible picker window (`g_picker_hwnd`) displays history and handles user interaction.
- **Hotkeys**: `Win+V`, `Ctrl+Alt+B`, and `F8` are all registered with `RegisterHotKey` and delivered as `WM_HOTKEY`. No keyboard hook is involved (see "No WH_KEYBOARD_LL" above). A low-frequency poll-fallback timer (`pollHotkeyFallback`, `HOTKEY_POLL_TIMER_ID`, `SetCoalescableTimer`, ≥100ms) only exists at all if one of the three `RegisterHotKey` calls failed at startup; if all three succeed there is no fallback timer.
- **Clipboard privacy**: `clipboard.capture()` checks registered `ExcludeClipboardContentFromMonitorProcessing` presence and `CanIncludeInClipboardHistory` DWORD zero while the clipboard is open, before reading text/images. The pure `shouldRecord()` policy has host-native tests. Excluded updates return `ClipboardMonitoringExcluded`, logged by `onClipboardUpdate()` via `dbgLog` without modifying history.
- **Self-trigger guard**: `g_ignore_clipboard_updates` counter prevents re-capturing items we just pasted.
- **Target window tracking**: Event-driven via `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT)` (`foregroundEventProc` in `src/main.zig`) — updates `g_last_target_hwnd` only when the foreground window actually changes, no polling. `rememberTargetWindow()` also runs on picker show as a defensive fallback in case the WinEvent hook failed to install.
- **Picker rendering**: Custom GDI paint in `paintPicker()` - dark theme, card-style layout, scrollbar, text wrapping, and DIB thumbnail rendering for images.
- **Persistence**: Auto-saves to `%LOCALAPPDATA%\lightboard\history.bin` on every capture and at shutdown. Custom binary format (LBRD3). Images stored as compressed files in `%LOCALAPPDATA%\lightboard\images\` — not kept in RAM, loaded on demand for rendering/pasting.
- **Image compression**: Raw DIB clipboard data is compressed with LZNT1 (Windows ntdll) before writing to disk. Typical 5-10x compression ratio for screenshots. Images are decompressed on the fly when rendering thumbnails or pasting.
- **Sticky entries**: Entries can be pinned/sticky. Sticky entries survive eviction when history is full and survive "delete all". Shown with a `*` accent indicator in top-right of card.

### Picker Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `Up` / `k` | Move selection up |
| `Down` / `j` | Move selection down |
| `Enter` | Paste selected entry |
| `Esc` | Hide picker |
| `PageUp` / `PageDown` | Scroll by 4 |
| `Delete` or `x` | Delete selected entry |
| `Ctrl+Delete` | Delete all non-sticky entries |
| `s` | Toggle sticky/pin on selected entry |
| `Tab` | Switch between History and Pinned tabs |

### Tab View

The picker has two tabs: **History** (default) and **Pinned**. The History tab shows non-sticky entries, the Pinned tab shows sticky entries only. Press `Tab` to switch between them, or click the tab labels at the top. Selection and scroll reset on tab switch. Toggling sticky (`s`) on an entry moves it to the other tab.

### Debug Logging

Writes to `lightboard-debug.log` in the working directory. Contains timestamped entries for hotkey registration, clipboard captures, paste operations, and window events. Off by default in release builds (see Build & Run) — build with `-Doptimize=Debug` or `-Dlog=true` to get it.

## Power Behaviour

Lightboard is a background utility and should do zero work while idle. As of the
idle-power pass (v0.2.0):

- **No timers while the picker is hidden**, in the common case. The old unconditional
  20ms `SetTimer` (used for foreground-window polling, hotkey polling, and outside-click
  polling) is gone entirely.
- **Foreground-window tracking** is event-driven (`SetWinEventHook`), not polled.
- **Outside-click hiding** is `WM_ACTIVATE`(`WA_INACTIVE`)/`WM_KILLFOCUS` on the picker
  window (see `hidePicker`/`showPicker` in `src/main.zig`), not a mouse-position poll. The
  picker needs no timer of its own at all.
- **Hotkeys** are `RegisterHotKey` + `WM_HOTKEY`, not polled. The only timer that can
  exist at all is `HOTKEY_POLL_TIMER_ID`, a `SetCoalescableTimer` at `HOTKEY_POLL_INTERVAL_MS`
  (150ms, ≥100ms tolerance) — and only if a `RegisterHotKey` call failed at startup, as a
  last-resort fallback so the app stays usable. When Win+V, Ctrl+Alt+B, and F8 all
  register successfully, this timer never starts.
- **EcoQoS**: `enableEcoQoS()` calls `SetProcessInformation(..., ProcessPowerThrottling, ...)`
  with `EXECUTION_SPEED` at startup, unconditionally (cheap for a background hotkey
  utility with no latency-critical hot path). If picker responsiveness ever suffers,
  clearing it while the picker is visible is the next thing to try.
- **No `WH_KEYBOARD_LL`**: see the mandatory note above. This was both the largest
  idle-adjacent cost (per-keystroke system-wide context switches while typing) and a
  standing crash risk; it's gone for good.

Verify with `(Get-Process lightboard).CPU` sampled ~180s apart while idle
(`delta / 180 * 60` = core-sec/min) — expect near 0. `suggestions.md` has the original
battery audit this work is based on, with file:line references (line numbers are now
stale post-refactor, but the reasoning holds).
