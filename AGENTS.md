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
- Primary: `Win+V` (toggle picker; intercepts Windows clipboard history)
- Backups: `Ctrl+Alt+B`, `F8` (toggle picker)

## Hotkey Contract
- Do not change these hotkeys unless the user explicitly asks to change hotkeys.
- `Win+V` must remain the primary path. If Windows `TextInputHost.exe` / Windows Input Experience appears instead of Lightboard, fix the `Win+V` hook or disable `TextInputHost`; do not switch primary behavior to `Ctrl+Alt+B` or `F8`.
- If plain `v` opens Lightboard, the low-level hook is stale. The fix is to intercept `VK_V` only when `winKeyDown()` is physically true on keydown; do not track a persistent Win-key boolean that can get stuck.
- The TextInputHost disable script lives in `C:\Users\valen\Documents\GitHub\windows-stuff\Disable-TextInputHost.ps1` and must be run from elevated PowerShell.

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


<claude-mem-context>
# Memory Context

# [lightboard] recent context, 2026-05-09 1:17am GMT+2

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 5 obs (1,288t read) | 452,730t work | 100% savings

### May 9, 2026
18 12:28a 🟣 Windows-native timestamp implementation via FILETIME
19 " 🔴 Zig 0.16 ArrayList and ArrayListUnmanaged API compatibility
20 " 🔴 Thread.sleep removed in Zig 0.16; replaced with Windows Sleep API
21 " ✅ Hotkey registration simplified from multi-candidate fallback to single Ctrl+Alt+B
22 " 🔵 Application successfully compiles and initializes under Zig 0.16 with Windows FILETIME timestamps

Access 453k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>
