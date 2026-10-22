# lightboard (Zig)

Minimal Windows clipboard manager prototype focused on low overhead.

## Current status (usable v0.1.2)
- Hidden Win32 window + message loop
- Clipboard listener via `WM_CLIPBOARDUPDATE`
- Global hotkey to toggle picker window:
  - primary: `Win+V` (intercepts Windows clipboard history)
  - backups: `Ctrl+Alt+B`, `F8`
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

## Tests and releases

GitHub Actions runs `zig build test` on Windows for pushes to `master` and pull
requests, including the clipboard privacy policy tests. CI pins Zig 0.16.0.

Push a tag such as `v1.2.3` to publish a release, or run the **Release** workflow
manually with an existing `vX.Y.Z` tag to retry it. The workflow checks out that
exact tag, runs the tests, then builds Windows x86_64 with
`zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-windows`. It creates the GitHub
release if needed and uploads `lightboard.exe` and `SHA256SUMS.txt`; retries
replace those assets. Download both into the same directory and verify with
`sha256sum -c SHA256SUMS.txt` (or compare `Get-FileHash lightboard.exe -Algorithm
SHA256` in PowerShell). No locally built executable is uploaded.

## Run
```powershell
zig build run
```

## Notes
- If an app puts images on clipboard as `CF_BITMAP` only, this build may not capture that image entry.
- If you want startup-on-login next, we can add a small installer-less registry setup command.
