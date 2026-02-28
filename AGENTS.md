# AGENTS.md

## Project
- Name: `lightboard`
- Language: Zig
- Platform: Windows
- Goal: Lightweight clipboard history manager (text + images).

## Build And Run
- Build release: `zig build -Doptimize=ReleaseSmall`
- Run: `zig-out\\bin\\lightboard.exe`

## Current Hotkeys
- Primary: `Ctrl+Alt+B` (toggle picker)
- Backup: `F8` (toggle picker)

## Picker Behavior
- Window title: `Clipboard History`
- Hidden by default; opens with hotkey.
- Hides when:
  - Hotkey pressed again
  - `Esc` pressed
  - Outside click detected
  - Window close requested

## Navigation And Paste
- `Up/Down` or `j/k`: move selection
- `PageUp/PageDown`: scroll history
- `Enter` or click entry: paste selected item

## Clipboard Support
- Text: `CF_UNICODETEXT`
- Images: `CF_DIBV5`, `CF_DIB` (thumbnail rendering enabled in cards)

## Persistence
- History persisted to:
  - `%LOCALAPPDATA%\\lightboard\\history.bin`
- Loaded on startup, saved on capture and shutdown.

## Debug Logs
- File: `lightboard-debug.log` in repo root.
- Contains startup, hotkey, capture, and paste diagnostics.
