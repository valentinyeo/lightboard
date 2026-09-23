# Suggestions: battery / idle power

Date: 2026-09-23
Status: proposal, nothing implemented

## Measured
0.2-0.3 core-sec/min continuously while idle in background.

## Wake sources found
- src/main.zig:15, :201 — `SetTimer(g_message_hwnd, TARGET_TRACK_TIMER_ID, 20ms)` started at launch, never killed until exit, runs whether the picker is visible or not — 20 ms requested, rounds up to the ~15.6 ms system tick, so roughly 50-64 wakeups/s (about 3,000-3,800/min). At the measured 0.25 core-sec/min that works out to ~65-80 us per tick, which fits this timer being the main cost.
- src/main.zig:373-381 — the WM_TIMER handler runs three things on every tick:
  - src/main.zig:1206 `trackForegroundTarget()` — `GetForegroundWindow()` polling to remember the paste target — every tick.
  - src/main.zig:1213 `pollHotkeyFallback()` — calls `milliTimestamp()` and 4x `GetAsyncKeyState` (Ctrl, Alt, B, F8) — every tick. This duplicates the `RegisterHotKey` registrations at :214 and :332, which already deliver WM_HOTKEY.
  - src/main.zig:1240 `hideOnOutsideClick()` — returns early when the picker is hidden, but only after the wakeup has already happened.
- src/main.zig:316 — `SetWindowsHookExW(WH_KEYBOARD_LL)` for Win+V. Every keystroke system-wide context-switches into this process. Costs nothing while the machine is truly idle, but adds per-keystroke wakeups while typing. This is also a pre-existing stability risk: LL hooks crash this machine.
- src/main.zig:240 — the message loop uses blocking `GetMessageW`. No PeekMessage spin. OK.
- src/main.zig:197 — clipboard monitoring uses `AddClipboardFormatListener` (event-driven). No sequence-number polling. OK.
- src/main.zig:1606 `dbgLog` — only writes on events. The log's last write was Jun 8 and every entry comes from a clipboard/hotkey event. It does no scheduled disk I/O, but each call does a `stat` plus a positional write, and it is always on when `g_log_file` is open.
- src/main.zig:1600 — `history.saveToFile` rewrites the whole file on each change. It is event-driven, so it is not an idle cost.
- InvalidateRect calls (:93, :431, :509, :527, ...) all come from user actions or show events. None run on a timer. OK.
- Not present: worker threads or Sleep loops (the only `Sleep(140)`, at :658, is a one-shot during paste), file/registry/network polling, GetSystemPowerStatus, RegisterPowerSettingNotification, EcoQoS / ProcessPowerThrottling.

## Proposed fixes
1. Run the 20 ms timer only while the picker is visible. Call `SetTimer` in the show path (:528) and `KillTimer` in every hide path (:456, :520, :561, :651, :750, :1261), and remove the unconditional `SetTimer` at :201. Fixes the :201 timer and all three WM_TIMER callees. Expected: idle wakeups drop from ~60/s to 0. — risk: low — effort: S
2. Replace `trackForegroundTarget` polling (:1206) with an event. `rememberTargetWindow()` already runs on show (:1199). If continuous tracking is still needed, use `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, ..., WINEVENT_OUTOFCONTEXT)`, which is a WinEvent hook, not a keyboard hook. Removes the last reason to keep the timer running while the picker is hidden. — risk: low — effort: S
3. Stop running `pollHotkeyFallback` (:1213) whenever `RegisterHotKey` succeeded (`g_hotkey_registered` / `g_f8_hotkey_registered`). WM_HOTKEY already covers those hotkeys. Keep the poll only as a last resort when registration failed, and even then only at 100 ms+ with `SetCoalescableTimer` and a tolerance of 50 ms or more. — risk: low — effort: S
4. Replace `hideOnOutsideClick` polling (:1240) with WM_ACTIVATE `WA_INACTIVE` on the picker (the handler at :385 already exists), or with WM_KILLFOCUS, and hide the picker there. The picker then no longer needs a timer at all. — risk: med (focus edge cases with forceForeground/AttachThreadInput) — effort: S
5. Apply EcoQoS at startup: `SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, {Version=1, ControlMask=EXECUTION_SPEED|IGNORE_TIMER_RESOLUTION, StateMask=same})`. Clear it while the picker is shown if latency suffers. Lowers the cost of whatever wakeups remain. — risk: low — effort: S
6. Win+V via the LL hook (:316): keep the feature, but move it to `RegisterHotKey(MOD_WIN|MOD_NOREPEAT, 'V')`. This requires freeing Win+V from Explorer (`HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` `DisabledHotkeys` = `V`, then restart Explorer). This removes the per-keystroke wakeups and the crash risk. Win-held picker navigation (:292-307) would have to rely on normal WM_KEYDOWN once the picker has focus. Do not use any other keyboard-hook approach. — risk: med — effort: M
7. Put `dbgLog` behind a build option or env flag (default off in release). This is a minor gain: it is event-driven, but it adds a stat+write on every clipboard change. — risk: low — effort: S

Power notifications (GUID_ACDC_POWER_SOURCE etc.) are not needed once fixes 1-4 remove the idle timer, because there would be no idle work left to throttle.

## How to verify
Measure core-sec/min over 3 min idle before/after:
`(Get-Process lightboard).CPU` sampled at t0 and t0+180s, delta / 180 * 60 = core-sec/min. Compare against baseline above.
Expected after fixes 1-4: near 0 (< 0.01 core-sec/min). A wakeup check is also possible with `powercfg /energy` or WPR (CPU usage precise), which should show no timer-driven context switches for lightboard.exe while idle.
