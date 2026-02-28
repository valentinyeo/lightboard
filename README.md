# lightboard (Zig)

Minimal Windows clipboard manager prototype focused on low overhead.

## Current status (usable v1)
- Hidden Win32 window + message loop
- Clipboard listener via `WM_CLIPBOARDUPDATE`
- Global hotkey to toggle picker window:
  - tries `Win+V`
  - falls back to `Ctrl+Shift+V` if `Win+V` is already registered by Windows/another app
- Native picker window with keyboard controls:
  - Up/Down to select entry
  - Enter to paste selected entry
  - Esc to close picker
- Captures:
  - text (`CF_UNICODETEXT`)
  - image payloads (`CF_DIBV5`, `CF_DIB`) with 8MB per-item cap
- Bounded in-memory history (default 120 entries)
- Consecutive duplicate suppression
- Clipboard restore + simulated `Ctrl+V` paste
- Persistent history on disk:
  - `%LOCALAPPDATA%\\lightboard\\history.bin`
  - auto-load on startup
  - auto-save when new clipboard items are captured

## Build
```powershell
zig build
```

## Run
```powershell
zig build run
```

## Notes
- If an app puts images on clipboard as `CF_BITMAP` only, this build may not capture that image entry.
- If you want startup-on-login next, we can add a small installer-less registry setup command.
