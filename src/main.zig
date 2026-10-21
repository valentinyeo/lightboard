const std = @import("std");
const w = @import("win32.zig");
const app_io = @import("app_io.zig");
const clip = @import("clipboard.zig");
const history = @import("history.zig");
const img_store = @import("image_store.zig");
const build_options = @import("build_options");

const MESSAGE_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("lightboard_msg");
const PICKER_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("lightboard_picker");
const WINDOW_NAME = std.unicode.utf8ToUtf16LeStringLiteral("lightboard");
const APP_VERSION = "v0.2.0";
const HOTKEY_ID: usize = 1; // Ctrl+Alt+B fallback
const HOTKEY_ID_F8: usize = 2; // F8 fallback
const HOTKEY_ID_WINV: usize = 3; // Win+V primary
const HOTKEY_POLL_TIMER_ID: usize = 10;
const HOTKEY_POLL_INTERVAL_MS: w.UINT = 150; // only used if a RegisterHotKey call failed
const HOTKEY_POLL_TOLERANCE_MS: w.DWORD = 100; // SetCoalescableTimer slack
const TAB_Y: c_int = 8;
const LIST_TOP: c_int = 32;
const CARD_GAP: c_int = 4;
const CARD_LEFT: c_int = 12;
const CARD_RIGHT_MARGIN: c_int = 20;
const CARD_MIN_W: c_int = 80;
const TEXT_LINE_H: c_int = 20;
const TEXT_PAD_V: c_int = 20; // 10 top + 10 bottom
const TEXT_PAD_LEFT: c_int = 14;
const TEXT_ACTION_GUTTER: c_int = 64;
const TEXT_AVG_CHAR_W: c_int = 7;
const MIN_TEXT_LINES: c_int = 2;
const MAX_TEXT_LINES: usize = 5;
const MIN_WRAP_CHARS: usize = 12;
const MAX_WRAP_CHARS: usize = 80;
const IMAGE_SIDE_PAD: c_int = 12;
const IMAGE_PAD_V: c_int = 16; // 8 top + 8 bottom
const IMAGE_MAX_THUMB_H: c_int = 104;
const IMAGE_MIN_CARD_H: c_int = 48;
const IMAGE_FALLBACK_CARD_H: c_int = 96;
const BOTTOM_MARGIN: c_int = 8;
const WHEEL_SCROLL_PX: c_int = 48;
const PAGE_SCROLL_OVERLAP_PX: c_int = 32;

var gpa = std.heap.DebugAllocator(.{}){};
var g_history = history.History.init(20);
var g_message_hwnd: w.HWND = null;
var g_picker_hwnd: w.HWND = null;
var g_hotkey_label: []const u8 = "Win+V";
var g_hotkey_registered = false;
var g_ignore_clipboard_updates: usize = 0;
var g_log_file: ?std.Io.File = null;
var g_f8_hotkey_registered = false;
var g_last_target_hwnd: w.HWND = null;
var g_ui_font: w.HFONT = null;
var g_history_path: []u8 = &[_]u8{};
var g_images_dir_path: []u8 = &[_]u8{};
var g_hotkey_debounce: i64 = 0; // timestamp of last toggle to prevent rapid re-toggle
var g_win_event_hook: w.HWINEVENTHOOK = null; // event-driven foreground-window tracking
var g_winv_registered = false;
var g_f8_needs_poll_fallback = false;
var g_altb_needs_poll_fallback = false;
var g_winv_needs_poll_fallback = false;
var g_poll_timer_running = false;

const ActiveTab = enum { history, pinned };
const ViewState = struct {
    selected_from_newest: usize = 0,
    scroll_px: c_int = 0,
};

var g_active_tab: ActiveTab = .history;
var g_history_view: ViewState = .{};
var g_pinned_view: ViewState = .{};

fn activeView() *ViewState {
    return switch (g_active_tab) {
        .history => &g_history_view,
        .pinned => &g_pinned_view,
    };
}

fn resetView(view: *ViewState) void {
    view.* = .{};
}

fn resetActiveView() void {
    resetView(activeView());
}

fn switchActiveTab(tab: ActiveTab) void {
    g_active_tab = tab;
    clampActiveView();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

pub fn main(init: std.process.Init) !void {
    app_io.init(init.io);
    initDebugLog();
    defer {
        dbgLog("lightboard shutting down", .{});
        if (g_log_file) |f| f.close(app_io.io);

        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("memory leaks detected", .{});
        }
    }

    const allocator = gpa.allocator();
    try initPersistence(allocator);
    defer if (g_history_path.len > 0) allocator.free(g_history_path);
    defer if (g_images_dir_path.len > 0) allocator.free(g_images_dir_path);
    defer img_store.deinit(allocator);
    defer g_history.deinit(allocator);
    defer persistHistory();

    history.loadFromFile(&g_history, allocator, g_history_path) catch |err| {
        dbgLog("history load failed: {s}", .{@errorName(err)});
    };
    dbgLog("history loaded entries={d}", .{g_history.len()});

    const hinstance = w.GetModuleHandleW(null);

    const message_class = w.WNDCLASSEXW{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .lpszClassName = MESSAGE_CLASS,
    };
    if (w.RegisterClassExW(&message_class) == 0) {
        return error.RegisterClassFailed;
    }

    const picker_class = w.WNDCLASSEXW{
        .lpfnWndProc = wndProc,
        .hInstance = hinstance,
        .hCursor = w.LoadCursorW(null, w.IDC_ARROW),
        .lpszClassName = PICKER_CLASS,
    };
    if (w.RegisterClassExW(&picker_class) == 0) {
        return error.RegisterClassFailed;
    }

    g_message_hwnd = w.CreateWindowExW(
        0,
        MESSAGE_CLASS,
        WINDOW_NAME,
        0,
        0,
        0,
        0,
        0,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;

    g_picker_hwnd = w.CreateWindowExW(
        w.WS_EX_TOPMOST | w.WS_EX_TOOLWINDOW,
        PICKER_CLASS,
        std.unicode.utf8ToUtf16LeStringLiteral("Clipboard History"),
        w.WS_OVERLAPPEDWINDOW,
        w.CW_USEDEFAULT,
        w.CW_USEDEFAULT,
        368,
        480,
        null,
        null,
        hinstance,
        null,
    ) orelse return error.CreateWindowFailed;
    _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
    applyWindowTheme(g_picker_hwnd);

    g_ui_font = w.CreateFontW(
        -14,
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Variable"),
    );
    defer {
        if (g_ui_font != null) {
            _ = w.DeleteObject(g_ui_font);
        }
    }

    if (w.AddClipboardFormatListener(g_message_hwnd) == 0) {
        return error.AddClipboardFormatListenerFailed;
    }
    defer _ = w.RemoveClipboardFormatListener(g_message_hwnd);

    enableEcoQoS();

    // Event-driven foreground-window tracking (WinEvent hook, not a keyboard
    // hook — safe on this machine). Replaces the old 20ms polling timer.
    g_win_event_hook = w.SetWinEventHook(
        w.EVENT_SYSTEM_FOREGROUND,
        w.EVENT_SYSTEM_FOREGROUND,
        null,
        foregroundEventProc,
        0,
        0,
        w.WINEVENT_OUTOFCONTEXT,
    );
    defer {
        if (g_win_event_hook != null) _ = w.UnhookWinEvent(g_win_event_hook);
    }
    if (g_win_event_hook == null) {
        dbgLog("SetWinEventHook(EVENT_SYSTEM_FOREGROUND) failed winerr={d}; falling back to remember-on-show only", .{w.GetLastError()});
    }

    // Win+V is delivered via RegisterHotKey (MOD_WIN|MOD_NOREPEAT), not a
    // low-level keyboard hook. WH_KEYBOARD_LL crashes this machine and must
    // never be reintroduced. If Explorer still owns Win+V, this fails and we
    // fall back to Ctrl+Alt+B / F8; see tools/free-win-v.ps1.
    g_winv_registered = registerWinVHotkey();
    defer if (g_winv_registered) {
        _ = w.UnregisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_WINV));
    };
    g_winv_needs_poll_fallback = !g_winv_registered;

    const fallback_hotkey_registered = registerHotkey();
    defer if (fallback_hotkey_registered) {
        _ = w.UnregisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID));
    };
    g_altb_needs_poll_fallback = !fallback_hotkey_registered;

    g_f8_hotkey_registered = w.RegisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_F8), 0, w.VK_F8) != 0;
    defer if (g_f8_hotkey_registered) {
        _ = w.UnregisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_F8));
    };
    g_f8_needs_poll_fallback = !g_f8_hotkey_registered;
    if (g_f8_hotkey_registered) {
        dbgLog("registered backup hotkey: F8", .{});
    } else {
        dbgLog("failed backup hotkey F8 winerr={d}", .{w.GetLastError()});
    }

    // Poll-fallback timer: only runs if a RegisterHotKey call above failed.
    // When all three succeed (the common case) there is no timer at all
    // while the picker is hidden — zero idle wakeups. If it does run, it's
    // coalesced and well above 100ms per the no-tight-polling rule.
    if (g_winv_needs_poll_fallback or g_altb_needs_poll_fallback or g_f8_needs_poll_fallback) {
        _ = w.SetCoalescableTimer(g_message_hwnd, HOTKEY_POLL_TIMER_ID, HOTKEY_POLL_INTERVAL_MS, null, HOTKEY_POLL_TOLERANCE_MS);
        g_poll_timer_running = true;
        dbgLog("hotkey poll-fallback timer started ({d}ms coalesced): winv={} altb={} f8={}", .{ HOTKEY_POLL_INTERVAL_MS, g_winv_needs_poll_fallback, g_altb_needs_poll_fallback, g_f8_needs_poll_fallback });
    }
    defer if (g_poll_timer_running) {
        _ = w.KillTimer(g_message_hwnd, HOTKEY_POLL_TIMER_ID);
    };

    if (g_winv_registered) {
        g_hotkey_label = "Win+V";
        g_hotkey_registered = true;
        std.log.info("lightboard running (Win+V opens picker)", .{});
        dbgLog("hotkey active: Win+V (RegisterHotKey), fallback Ctrl+Alt+B={}, F8={}", .{ fallback_hotkey_registered, g_f8_hotkey_registered });
    } else if (fallback_hotkey_registered) {
        std.log.warn("lightboard running (Win+V unavailable; Ctrl+Alt+B opens picker). Explorer likely still owns Win+V - run tools\\free-win-v.ps1 (elevated) to free it, then restart lightboard.", .{});
        dbgLog("hotkey active: Ctrl+Alt+B fallback, F8={}", .{g_f8_hotkey_registered});
    } else if (g_f8_hotkey_registered) {
        std.log.warn("lightboard running (Win+V/Ctrl+Alt+B unavailable; F8 opens picker). Run tools\\free-win-v.ps1 (elevated) to free Win+V from Explorer.", .{});
        dbgLog("hotkey active: F8 backup only", .{});
    } else {
        std.log.warn("lightboard running with no registered hotkey. Run tools\\free-win-v.ps1 (elevated) to free Win+V from Explorer.", .{});
        dbgLog("no registered hotkey available", .{});
    }

    var msg: w.MSG = .{};
    var loop_count: u64 = 0;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        loop_count += 1;
        // Log first few iterations to confirm loop is running
        if (loop_count <= 3) {
            dbgLog("msg loop iter={d} msg=0x{X:0>4} hwnd={d}", .{ loop_count, msg.message, @intFromPtr(msg.hwnd) });
        }
        // Always log WM_HOTKEY in the loop
        if (msg.message == w.WM_HOTKEY) {
            dbgLog("WM_HOTKEY in loop wparam={d} hwnd={d}", .{ msg.wParam, @intFromPtr(msg.hwnd) });
        }
        if (msg.message == w.WM_MOUSEWHEEL and g_picker_hwnd != null and w.IsWindowVisible(g_picker_hwnd) != 0) {
            const delta = getWheelDelta(msg.wParam);
            const steps: c_int = @intCast(@max(@as(u32, 1), @divTrunc(@as(u32, @intCast(@abs(@as(i32, delta)))), @as(u32, 120))));
            if (delta > 0) scrollByPixels(-(steps * WHEEL_SCROLL_PX)) else if (delta < 0) scrollByPixels(steps * WHEEL_SCROLL_PX);
            dbgLog("wheel scroll(loop) delta={d}", .{delta});
            continue;
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

// WinEvent callback: fires only on real foreground-window changes (event
// driven, no polling). Mirrors what the old 20ms `trackForegroundTarget`
// poll did, minus the per-tick wakeup cost.
fn foregroundEventProc(
    hook: w.HWINEVENTHOOK,
    event: w.DWORD,
    hwnd: w.HWND,
    id_object: c_long,
    id_child: c_long,
    id_event_thread: w.DWORD,
    dwms_event_time: w.DWORD,
) callconv(w.WINAPI) void {
    _ = hook;
    _ = event;
    _ = id_object;
    _ = id_child;
    _ = id_event_thread;
    _ = dwms_event_time;
    if (hwnd != null and hwnd != g_picker_hwnd and hwnd != g_message_hwnd) {
        g_last_target_hwnd = hwnd;
    }
}

fn registerWinVHotkey() bool {
    dbgLog("trying hotkey: Win+V", .{});
    if (w.RegisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_WINV), w.MOD_WIN | w.MOD_NOREPEAT, w.VK_V) != 0) {
        dbgLog("registered hotkey: Win+V", .{});
        return true;
    }
    dbgLog("failed hotkey: Win+V winerr={d} (Explorer likely owns Win+V; see tools/free-win-v.ps1)", .{w.GetLastError()});
    return false;
}

fn registerHotkey() bool {
    const mods = w.MOD_CONTROL | w.MOD_ALT;
    const vk = w.VK_B;
    const label = "Ctrl+Alt+B";

    dbgLog("trying hotkey: {s}", .{label});
    if (w.RegisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID), mods, vk) != 0) {
        g_hotkey_label = label;
        g_hotkey_registered = true;
        dbgLog("registered hotkey: {s}", .{label});
        return true;
    }
    dbgLog("failed hotkey: {s} winerr={d}", .{ label, w.GetLastError() });

    g_hotkey_registered = false;
    g_hotkey_label = "None";
    return false;
}

fn wndProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_HOTKEY => {
            if (wparam == HOTKEY_ID or wparam == HOTKEY_ID_F8 or wparam == HOTKEY_ID_WINV) {
                const now = app_io.milliTimestamp();
                if (now - g_hotkey_debounce >= 300) {
                    g_hotkey_debounce = now;
                    dbgLog("WM_HOTKEY toggle id={d}", .{wparam});
                    togglePicker();
                }
            } else {
                dbgLog("WM_HOTKEY unknown id={d}", .{wparam});
            }
            return 0;
        },
        w.WM_CLIPBOARDUPDATE => {
            onClipboardUpdate();
            return 0;
        },
        w.WM_TIMER => {
            if (wparam == HOTKEY_POLL_TIMER_ID) {
                // Only reached at all when at least one RegisterHotKey call
                // failed at startup; see main(). Coalesced, >=100ms.
                pollHotkeyFallback();
                return 0;
            }
        },
        w.WM_ACTIVATE => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                if ((wparam & 0xFFFF) == w.WA_INACTIVE) {
                    hidePicker("deactivate");
                } else {
                    _ = w.SetFocus(g_picker_hwnd);
                }
                return 0;
            }
        },
        w.WM_KILLFOCUS => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                hidePicker("killfocus");
                return 0;
            }
        },
        w.WM_KEYDOWN => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                handlePickerKey(@intCast(wparam));
                return 0;
            }
        },
        w.WM_CHAR => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                handlePickerChar(@intCast(wparam));
                return 0;
            }
        },
        w.WM_LBUTTONDOWN => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                const click_x = getXFromLParam(lparam);
                const click_y = getYFromLParam(lparam);
                // Tab bar click detection
                if (click_y >= TAB_Y and click_y < LIST_TOP) {
                    if (click_x >= 16 and click_x < 80) {
                        switchActiveTab(.history);
                    } else if (click_x >= 80 and click_x < 150) {
                        switchActiveTab(.pinned);
                    }
                    return 0;
                }
                if (hitTestClick(click_x, click_y)) |hit| {
                    switch (hit.zone) {
                        .delete => {
                            activeView().selected_from_newest = hit.from_newest;
                            deleteSelected();
                        },
                        .pin => {
                            activeView().selected_from_newest = hit.from_newest;
                            toggleSticky();
                        },
                        .body => {
                            activeView().selected_from_newest = hit.from_newest;
                            ensureSelectionVisible();
                            _ = w.InvalidateRect(g_picker_hwnd, null, 1);
                            pasteSelection();
                        },
                    }
                    return 0;
                }
            }
        },
        w.WM_MOUSEWHEEL => {
            if (g_picker_hwnd != null and w.IsWindowVisible(g_picker_hwnd) != 0) {
                const delta = getWheelDelta(wparam);
                const steps: c_int = @intCast(@max(@as(u32, 1), @divTrunc(@as(u32, @intCast(@abs(@as(i32, delta)))), @as(u32, 120))));
                if (delta > 0) scrollByPixels(-(steps * WHEEL_SCROLL_PX)) else if (delta < 0) scrollByPixels(steps * WHEEL_SCROLL_PX);
                dbgLog("wheel scroll(proc) delta={d}", .{delta});
                return 0;
            }
        },
        w.WM_PAINT => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                paintPicker(hwnd);
                return 0;
            }
        },
        w.WM_CLOSE => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                hidePicker("close");
                return 0;
            }
        },
        w.WM_DESTROY => {
            if (g_message_hwnd != null and hwnd == g_message_hwnd) {
                w.PostQuitMessage(0);
            }
            return 0;
        },
        else => {},
    }

    return w.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn onClipboardUpdate() void {
    if (g_ignore_clipboard_updates > 0) {
        g_ignore_clipboard_updates -= 1;
        dbgLog("clipboard update ignored (self-trigger)", .{});
        return;
    }

    const allocator = gpa.allocator();

    const maybe_entry = clip.capture(allocator) catch |err| {
        if (err == error.ClipboardMonitoringExcluded) {
            dbgLog("clipboard update ignored (monitor/history exclusion)", .{});
            return;
        }
        std.log.err("clipboard capture failed: {s}", .{@errorName(err)});
        return;
    };

    if (maybe_entry) |entry| {
        g_history.push(allocator, entry) catch |err| {
            std.log.err("history push failed: {s}", .{@errorName(err)});
            if (entry.item == .text) allocator.free(entry.item.text);
            if (entry.item == .image) img_store.delete(entry.item.image.file_id);
            return;
        };

        const total = g_history.len();
        switch (entry.item) {
            .text => |text| {
                const preview_len = @min(text.len, 60);
                std.log.info("captured text [{d}] {s}", .{ total, text[0..preview_len] });
                dbgLog("captured text len={d} total={d}", .{ text.len, total });
            },
            .image => |img| {
                std.log.info("captured image [{d}] {s} raw={d}", .{ total, @tagName(img.format), img.raw_size });
                dbgLog("captured image format={s} raw={d} fid={d} total={d}", .{ @tagName(img.format), img.raw_size, img.file_id, total });
            },
        }

        if (g_picker_hwnd != null and w.IsWindowVisible(g_picker_hwnd) != 0) {
            _ = w.InvalidateRect(g_picker_hwnd, null, 1);
        }

        persistHistory();
    }
}

fn togglePicker() void {
    if (g_picker_hwnd == null) return;

    if (w.IsWindowVisible(g_picker_hwnd) != 0) {
        hidePicker("hotkey");
        return;
    }

    showPicker();
    dbgLog("picker shown by hotkey", .{});
}

// Idle = zero timers. There is currently nothing that needs a timer while
// the picker is visible either (foreground tracking is event-driven via
// SetWinEventHook, and outside-click hiding is WM_ACTIVATE/WM_KILLFOCUS
// driven) — these are no-ops today but kept so a future visible-only need
// has an obvious home instead of resurrecting an always-on timer.
fn showPicker() void {
    if (g_picker_hwnd == null) return;
    rememberTargetWindow();
    resetActiveView();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    _ = w.ShowWindow(g_picker_hwnd, w.SW_SHOW);
    forceForeground(g_picker_hwnd);
}

fn hidePicker(reason: []const u8) void {
    if (g_picker_hwnd == null) return;
    if (w.IsWindowVisible(g_picker_hwnd) == 0) return;
    _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
    dbgLog("picker hidden by {s}", .{reason});
}

fn forceForeground(hwnd: w.HWND) void {
    const fg_hwnd = w.GetForegroundWindow();
    const my_tid = w.GetCurrentThreadId();

    if (fg_hwnd != null and fg_hwnd != hwnd) {
        const fg_tid = w.GetWindowThreadProcessId(fg_hwnd, null);
        if (fg_tid != 0 and fg_tid != my_tid) {
            _ = w.AttachThreadInput(my_tid, fg_tid, 1);
            _ = w.BringWindowToTop(hwnd);
            _ = w.SetForegroundWindow(hwnd);
            _ = w.SetFocus(hwnd);
            _ = w.AttachThreadInput(my_tid, fg_tid, 0);
            dbgLog("forceForeground: attached tid={d} to fg_tid={d}", .{ my_tid, fg_tid });
            return;
        }
    }

    _ = w.BringWindowToTop(hwnd);
    _ = w.SetForegroundWindow(hwnd);
    _ = w.SetFocus(hwnd);
    dbgLog("forceForeground: direct (no thread attach needed)", .{});
}

fn handlePickerKey(key: w.UINT) void {
    dbgLog("handlePickerKey vk=0x{X:0>2}", .{key});
    const ctrl_held = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_CONTROL)));
    switch (key) {
        w.VK_ESCAPE => {
            hidePicker("Esc");
        },
        w.VK_UP => {
            moveSelection(-1);
        },
        w.VK_K => {
            moveSelection(-1);
        },
        w.VK_DOWN => {
            moveSelection(1);
        },
        w.VK_J => {
            moveSelection(1);
        },
        w.VK_RETURN => {
            if (ctrl_held) {
                openSelectedImage();
            } else {
                pasteSelection();
            }
        },
        w.VK_PRIOR => {
            scrollByPixels(-pageScrollAmount());
        },
        w.VK_NEXT => {
            scrollByPixels(pageScrollAmount());
        },
        w.VK_DELETE => {
            if (ctrl_held) {
                if (g_active_tab == .history) {
                    deleteAllNonSticky();
                }
            } else {
                deleteSelected();
            }
        },
        w.VK_X => {
            deleteSelected();
        },
        w.VK_S => {
            toggleSticky();
        },
        w.VK_TAB => {
            switchActiveTab(if (g_active_tab == .history) .pinned else .history);
            dbgLog("tab switched to {s}", .{if (g_active_tab == .history) "history" else "pinned"});
        },
        else => {},
    }
}

fn handlePickerChar(ch: w.UINT) void {
    // WM_CHAR is consumed here to prevent Windows beeping on unhandled chars.
    // j/k navigation is handled in handlePickerKey via WM_KEYDOWN.
    _ = ch;
}

fn moveSelection(delta: i32) void {
    const len = filteredCount();
    if (len == 0) return;

    const view = activeView();
    var next = @as(i32, @intCast(view.selected_from_newest)) + delta;
    if (next < 0) next = 0;

    const max_idx: i32 = @intCast(len - 1);
    if (next > max_idx) next = max_idx;

    view.selected_from_newest = @intCast(next);
    ensureSelectionVisible();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

fn pasteSelection() void {
    const flen = filteredCount();
    if (flen == 0) return;
    clampActiveView();
    const view = activeView();

    const from_newest = if (view.selected_from_newest < flen) view.selected_from_newest else flen - 1;
    const result = filteredEntry(from_newest) orelse return;
    const selected = result.entry;

    clip.restoreToClipboard(gpa.allocator(), selected) catch |err| {
        std.log.err("restore clipboard failed: {s} winerr={d}", .{ @errorName(err), w.GetLastError() });
        dbgLog("restore clipboard failed: {s} winerr={d}", .{ @errorName(err), w.GetLastError() });
        return;
    };

    g_ignore_clipboard_updates = 1;
    hidePicker("paste");
    dbgLog("pasting selected entry", .{});

    const target = resolvePasteTarget();
    if (target != null and target != g_picker_hwnd) {
        _ = w.SetForegroundWindow(target);
        // Give Windows time to complete foreground handoff before synthetic keys.
        w.Sleep(140);
    } else {
        dbgLog("no previous target window available for focus restore", .{});
    }

    clip.sendCtrlV();
}

fn openSelectedImage() void {
    const flen = filteredCount();
    if (flen == 0) return;
    clampActiveView();
    const view = activeView();

    const from_newest = if (view.selected_from_newest < flen) view.selected_from_newest else flen - 1;
    const result = filteredEntry(from_newest) orelse return;
    const selected = result.entry;

    const img = switch (selected.item) {
        .image => |image| image,
        .text => {
            dbgLog("Ctrl+Enter on text entry, ignoring", .{});
            return;
        },
    };

    const allocator = gpa.allocator();

    // Load raw image data from disk
    const raw_data = img_store.load(allocator, img.file_id, img.raw_size) catch |err| {
        dbgLog("failed to load image for preview: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(raw_data);

    // Write BMP file: 14-byte BITMAPFILEHEADER + DIB data
    const bmp_header_size: u32 = 14;
    const dib_header_size: u32 = if (raw_data.len >= 4)
        std.mem.readInt(u32, raw_data[0..4], .little)
    else
        0;
    const file_size: u32 = bmp_header_size + @as(u32, @intCast(raw_data.len));
    const pixel_offset: u32 = bmp_header_size + dib_header_size;

    var header: [14]u8 = undefined;
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], file_size, .little);
    std.mem.writeInt(u16, header[6..8], 0, .little);
    std.mem.writeInt(u16, header[8..10], 0, .little);
    std.mem.writeInt(u32, header[10..14], pixel_offset, .little);

    // Write to %LOCALAPPDATA%\lightboard\preview.bmp
    const env: std.process.Environ = .{ .block = .global };
    const local_app_data = env.getAlloc(allocator, "LOCALAPPDATA") catch {
        dbgLog("LOCALAPPDATA not found, can't open image", .{});
        return;
    };
    defer allocator.free(local_app_data);

    const bmp_path = std.fs.path.joinZ(allocator, &.{ local_app_data, "lightboard", "preview.bmp" }) catch return;
    defer allocator.free(bmp_path);

    const file = std.Io.Dir.createFileAbsolute(app_io.io, bmp_path, .{}) catch |err| {
        dbgLog("failed to create preview.bmp: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(app_io.io);

    file.writePositionalAll(app_io.io, &header, 0) catch return;
    file.writePositionalAll(app_io.io, raw_data, header.len) catch return;

    dbgLog("wrote preview.bmp, opening with shell", .{});

    // Convert path to wide string for ShellExecuteW
    var wide_path: [std.fs.max_path_bytes]u16 = undefined;
    var i: usize = 0;
    for (bmp_path) |c| {
        wide_path[i] = c;
        i += 1;
    }
    wide_path[i] = 0;

    _ = w.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        @ptrCast(&wide_path),
        null,
        null,
        w.SW_SHOW,
    );

    hidePicker("open image");
}

fn deleteSelected() void {
    const allocator = gpa.allocator();
    const flen = filteredCount();
    if (flen == 0) return;
    clampActiveView();
    const view = activeView();

    const from_newest = if (view.selected_from_newest < flen) view.selected_from_newest else flen - 1;
    const r = filteredEntry(from_newest) orelse return;

    g_history.removeAt(allocator, r.real_idx);
    dbgLog("deleted entry idx={d} from_newest={d}", .{ r.real_idx, from_newest });

    clampActiveView();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
}

fn deleteAllNonSticky() void {
    const allocator = gpa.allocator();
    g_history.clearNonSticky(allocator);
    resetView(&g_history_view);
    dbgLog("deleted all non-sticky entries, remaining={d}", .{g_history.len()});
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
}

fn toggleSticky() void {
    const flen = filteredCount();
    if (flen == 0) return;
    clampActiveView();
    const view = activeView();

    const from_newest = if (view.selected_from_newest < flen) view.selected_from_newest else flen - 1;
    const r = filteredEntry(from_newest) orelse return;

    g_history.entries.items[r.real_idx].sticky = !g_history.entries.items[r.real_idx].sticky;
    dbgLog("toggled sticky idx={d} now={}", .{ r.real_idx, g_history.entries.items[r.real_idx].sticky });

    // Entry moved to the other tab — clamp the active tab without losing the other tab's scroll state.
    clampActiveView();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
}

const FilteredResult = struct { entry: history.Entry, real_idx: usize };

fn filteredCount() usize {
    const want_sticky = g_active_tab == .pinned;
    var count: usize = 0;
    const len = g_history.len();
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (g_history.entries.items[i].sticky == want_sticky) count += 1;
    }
    return count;
}

fn filteredEntry(from_newest: usize) ?FilteredResult {
    const want_sticky = g_active_tab == .pinned;
    const len = g_history.len();
    var count: usize = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const entry_idx = (len - 1) - i;
        const entry = g_history.entries.items[entry_idx];
        if (entry.sticky == want_sticky) {
            if (count == from_newest) return .{ .entry = entry, .real_idx = entry_idx };
            count += 1;
        }
    }
    return null;
}

fn paintPicker(hwnd: w.HWND) void {
    var ps: w.PAINTSTRUCT = .{};
    const hdc = w.BeginPaint(hwnd, &ps);
    if (hdc == null) return;
    defer _ = w.EndPaint(hwnd, &ps);
    if (g_ui_font != null) _ = w.SelectObject(hdc, g_ui_font);

    const color_bg = w.RGB(32, 32, 32);
    const color_card = w.RGB(44, 44, 44);
    const color_card_selected = w.RGB(48, 48, 48);
    const color_accent = w.RGB(96, 205, 255);
    const color_text_main = w.RGB(255, 255, 255);
    const color_text_sub = w.RGB(157, 157, 157);

    var rect: w.RECT = .{};
    _ = w.GetClientRect(hwnd, &rect);

    const bg_brush = w.CreateSolidBrush(color_bg);
    if (bg_brush != null) {
        _ = w.FillRect(hdc, &rect, bg_brush);
        _ = w.DeleteObject(bg_brush);
    }
    _ = w.SetBkMode(hdc, w.TRANSPARENT);
    _ = w.SetTextColor(hdc, color_text_main);

    // Draw tab bar
    _ = w.SetTextColor(hdc, if (g_active_tab == .history) color_accent else color_text_sub);
    drawUtf8Line(hdc, 16, TAB_Y, "History");
    _ = w.SetTextColor(hdc, if (g_active_tab == .pinned) color_accent else color_text_sub);
    drawUtf8Line(hdc, 90, TAB_Y, "Pinned");
    // Active tab underline
    {
        const ux: c_int = if (g_active_tab == .history) 16 else 90;
        const uw: c_int = if (g_active_tab == .history) 54 else 48;
        const underline = w.RECT{ .left = ux, .top = TAB_Y + 18, .right = ux + uw, .bottom = TAB_Y + 20 };
        const u_brush = w.CreateSolidBrush(color_accent);
        if (u_brush != null) {
            _ = w.FillRect(hdc, &underline, u_brush);
            _ = w.DeleteObject(u_brush);
        }
    }
    _ = w.SetTextColor(hdc, color_text_main);

    const flen = filteredCount();
    if (flen == 0) {
        _ = w.SetTextColor(hdc, color_text_sub);
        const empty_msg = if (g_active_tab == .history) "Clipboard history is empty" else "No pinned entries";
        drawUtf8Line(hdc, 16, LIST_TOP + 12, empty_msg);
        drawVersion(hdc, rect, color_text_sub);
        return;
    }

    const client_h = rect.bottom - rect.top;
    const card_w = cardWidthFromClientRect(rect);
    clampActiveViewWithMetrics(card_w, client_h);
    const view = activeView();
    const selected = if (view.selected_from_newest < flen) view.selected_from_newest else flen - 1;
    const viewport_h = listViewportHeight(client_h);
    const list_bottom = LIST_TOP + viewport_h;

    const saved_dc = w.SaveDC(hdc);
    if (saved_dc != 0) _ = w.IntersectClipRect(hdc, 0, LIST_TOP, rect.right, list_bottom);
    defer {
        if (saved_dc != 0) _ = w.RestoreDC(hdc, saved_dc);
    }

    var item_top: c_int = 0;
    var visible_count: usize = 0;
    var i: usize = 0;
    while (i < flen) : (i += 1) {
        const result = filteredEntry(i) orelse break;
        const entry = result.entry;
        const card_h = entryCardHeight(entry, card_w);
        const item_bottom = item_top + card_h;

        if (item_bottom >= view.scroll_px and item_top <= view.scroll_px + viewport_h) {
            const y = LIST_TOP + item_top - view.scroll_px;
            const is_selected = i == selected;

            const row_rect = w.RECT{ .left = CARD_LEFT, .top = y, .right = CARD_LEFT + card_w, .bottom = y + card_h };
            const row_brush = w.CreateSolidBrush(if (is_selected) color_card_selected else color_card);
            if (row_brush != null) {
                _ = w.FillRect(hdc, &row_rect, row_brush);
                _ = w.DeleteObject(row_brush);
            }

            if (is_selected) {
                const bar_h: c_int = @min(20, card_h - 8);
                const bar_top = y + @divTrunc(card_h - bar_h, 2);
                const accent_rect = w.RECT{ .left = CARD_LEFT, .top = bar_top, .right = CARD_LEFT + 3, .bottom = bar_top + bar_h };
                const accent_brush = w.CreateSolidBrush(color_accent);
                if (accent_brush != null) {
                    _ = w.FillRect(hdc, &accent_rect, accent_brush);
                    _ = w.DeleteObject(accent_brush);
                }
            }

            renderEntryLine(hdc, row_rect, entry, color_text_main, color_text_sub, color_accent);
            visible_count += 1;
        }

        item_top += card_h + CARD_GAP;
        if (item_top > view.scroll_px + viewport_h) break;
    }

    if (visible_count > 0) {
        drawScrollbar(hdc, rect, totalContentHeight(card_w), view.scroll_px, viewport_h);
    }
    drawVersion(hdc, rect, color_text_sub);
}

fn drawVersion(hdc: w.HDC, rect: w.RECT, color_text_sub: w.COLORREF) void {
    _ = w.SetTextColor(hdc, color_text_sub);
    drawUtf8Line(hdc, rect.right - 54, rect.bottom - 22, APP_VERSION);
}

fn renderEntryLine(hdc: w.HDC, rect: w.RECT, entry: history.Entry, color_text_main: w.COLORREF, color_text_sub: w.COLORREF, color_accent: w.COLORREF) void {
    const text_x = rect.left + TEXT_PAD_LEFT;
    const text_y = rect.top + 10;
    const color_icon_dim = w.RGB(100, 100, 100);

    // Draw pin icon (always visible, top-right area)
    // U+25CF BLACK CIRCLE when sticky, U+25CB WHITE CIRCLE when not
    if (entry.sticky) {
        _ = w.SetTextColor(hdc, color_accent);
        drawUtf8Line(hdc, rect.right - 42, rect.top + 4, "\xE2\x97\x8F");
    } else {
        _ = w.SetTextColor(hdc, color_icon_dim);
        drawUtf8Line(hdc, rect.right - 42, rect.top + 4, "\xE2\x97\x8B");
    }

    // Draw delete icon × (U+00D7) — always visible
    _ = w.SetTextColor(hdc, color_text_sub);
    drawUtf8Line(hdc, rect.right - 20, rect.top + 4, "\xC3\x97");

    switch (entry.item) {
        .text => |text| {
            _ = w.SetTextColor(hdc, color_text_main);
            var lines: [MAX_TEXT_LINES][120]u8 = [_][120]u8{[_]u8{0} ** 120} ** MAX_TEXT_LINES;
            const wrap_chars = textWrapCharsForCardWidth(rect.right - rect.left);
            const wrapped = wrapTextIntoLines(text, &lines, wrap_chars);
            var li: usize = 0;
            while (li < wrapped.line_count) : (li += 1) {
                drawUtf8Line(hdc, text_x, text_y + @as(c_int, @intCast(li)) * TEXT_LINE_H, lines[li][0..wrapped.lengths[li]]);
            }
        },
        .image => |img| {
            const thumb_rect = w.RECT{
                .left = rect.left + IMAGE_SIDE_PAD,
                .top = rect.top + 8,
                .right = rect.right - IMAGE_SIDE_PAD,
                .bottom = rect.bottom - 8,
            };
            const raw_data = img_store.load(gpa.allocator(), img.file_id, img.raw_size) catch {
                drawUtf8Line(hdc, rect.left + IMAGE_SIDE_PAD, rect.top + 8, "[image load failed]");
                return;
            };
            defer gpa.allocator().free(raw_data);
            drawImageThumbnail(hdc, thumb_rect, raw_data);
        },
    }
}

fn sanitizeInto(dst: []u8, src: []const u8) usize {
    if (dst.len == 0) return 0;

    var j: usize = 0;
    for (src) |c| {
        if (j >= dst.len - 1) break;
        dst[j] = if (c == '\r' or c == '\n' or c == '\t') ' ' else c;
        j += 1;
    }
    return j;
}

fn sanitizeAndClipInto(dst: []u8, src: []const u8, max_chars: usize) usize {
    if (dst.len == 0) return 0;
    const n = sanitizeInto(dst, src);
    if (n <= max_chars or max_chars < 3) return n;
    dst[max_chars - 3] = '.';
    dst[max_chars - 2] = '.';
    dst[max_chars - 1] = '.';
    return max_chars;
}

fn textWrapCharsForCardWidth(card_width: c_int) usize {
    const content_w = card_width - TEXT_PAD_LEFT - TEXT_ACTION_GUTTER;
    var chars: usize = MIN_WRAP_CHARS;
    if (content_w > 0) {
        chars = @intCast(@divTrunc(content_w, TEXT_AVG_CHAR_W));
    }
    if (chars < MIN_WRAP_CHARS) return MIN_WRAP_CHARS;
    if (chars > MAX_WRAP_CHARS) return MAX_WRAP_CHARS;
    return chars;
}

const TextWrapResult = struct {
    lengths: [MAX_TEXT_LINES]usize = [_]usize{0} ** MAX_TEXT_LINES,
    line_count: usize = 0,
};

fn utf8BoundaryBefore(text: []const u8, start: usize, end_in: usize) usize {
    var end = end_in;
    while (end > start and end < text.len and (text[end] & 0xC0) == 0x80) : (end -= 1) {}
    return end;
}

fn wrapTextIntoLines(src: []const u8, lines: *[MAX_TEXT_LINES][120]u8, max_chars: usize) TextWrapResult {
    var result: TextWrapResult = .{};
    var sanitized: [512]u8 = undefined;
    const n = sanitizeInto(&sanitized, src);
    const text = sanitized[0..n];

    var line_idx: usize = 0;
    var i: usize = 0;
    while (i < text.len and line_idx < MAX_TEXT_LINES) {
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        if (i >= text.len) break;

        const hard_end = @min(i + max_chars, text.len);
        var end = hard_end;
        if (end < text.len) {
            var j = end;
            while (j > i and text[j - 1] != ' ') : (j -= 1) {}
            if (j > i) end = j - 1;
        }
        end = utf8BoundaryBefore(text, i, end);
        if (end <= i) end = utf8BoundaryBefore(text, i, hard_end);
        if (end <= i) end = hard_end;

        const slice = text[i..end];
        const copy_len = @min(slice.len, lines.*[line_idx].len - 1);
        @memcpy(lines.*[line_idx][0..copy_len], slice[0..copy_len]);
        result.lengths[line_idx] = copy_len;
        line_idx += 1;

        i = end;
        while (i < text.len and text[i] == ' ') : (i += 1) {}
    }

    result.line_count = line_idx;
    if (i < text.len and result.line_count == MAX_TEXT_LINES and result.lengths[MAX_TEXT_LINES - 1] >= 3) {
        const last = MAX_TEXT_LINES - 1;
        lines.*[last][result.lengths[last] - 3] = '.';
        lines.*[last][result.lengths[last] - 2] = '.';
        lines.*[last][result.lengths[last] - 1] = '.';
    }

    return result;
}

const ImageSize = struct { width: c_int, height: c_int };

fn dibImageSize(data: []const u8) ?ImageSize {
    if (data.len < 12) return null;

    const header_size = std.mem.readInt(u32, data[0..4], .little);
    const header_size_usize: usize = @intCast(header_size);
    if (header_size_usize < @sizeOf(w.BITMAPINFOHEADER) or header_size_usize > data.len) return null;

    const raw_w = std.mem.readInt(i32, data[4..8], .little);
    const raw_h = std.mem.readInt(i32, data[8..12], .little);
    if (raw_w == 0 or raw_h == 0) return null;

    const width_i64 = if (raw_w < 0) -@as(i64, raw_w) else @as(i64, raw_w);
    const height_i64 = if (raw_h < 0) -@as(i64, raw_h) else @as(i64, raw_h);
    if (width_i64 <= 0 or height_i64 <= 0) return null;
    if (width_i64 > std.math.maxInt(c_int) or height_i64 > std.math.maxInt(c_int)) return null;

    return .{ .width = @intCast(width_i64), .height = @intCast(height_i64) };
}

fn imageSizeFromDisk(img: history.ImageMeta) ?ImageSize {
    const raw_data = img_store.load(gpa.allocator(), img.file_id, img.raw_size) catch return null;
    defer gpa.allocator().free(raw_data);
    return dibImageSize(raw_data);
}

fn scaledDim(limit: c_int, value: c_int, denom: c_int) c_int {
    if (limit <= 0 or value <= 0 or denom <= 0) return 1;
    var out: c_int = @intCast(@divTrunc(@as(i64, limit) * @as(i64, value), @as(i64, denom)));
    if (out < 1) out = 1;
    return out;
}

fn fitImageNoUpscale(src_w: c_int, src_h: c_int, box_w: c_int, box_h: c_int) ImageSize {
    if (src_w <= 0 or src_h <= 0 or box_w <= 0 or box_h <= 0) return .{ .width = 1, .height = 1 };

    var dst_w = src_w;
    var dst_h = src_h;

    if (dst_w > box_w) {
        dst_h = scaledDim(box_w, dst_h, dst_w);
        dst_w = box_w;
    }
    if (dst_h > box_h) {
        dst_w = scaledDim(box_h, dst_w, dst_h);
        dst_h = box_h;
    }

    if (dst_w < 1) dst_w = 1;
    if (dst_h < 1) dst_h = 1;
    return .{ .width = dst_w, .height = dst_h };
}

fn imageThumbBoxWidth(card_width: c_int) c_int {
    var box_w = card_width - (IMAGE_SIDE_PAD * 2);
    if (box_w < 1) box_w = 1;
    return box_w;
}

fn imageCardHeight(img: history.ImageMeta, card_width: c_int) c_int {
    const size = imageSizeFromDisk(img) orelse return IMAGE_FALLBACK_CARD_H;
    const fit = fitImageNoUpscale(size.width, size.height, imageThumbBoxWidth(card_width), IMAGE_MAX_THUMB_H);
    var card_h = fit.height + IMAGE_PAD_V;
    if (card_h < IMAGE_MIN_CARD_H) card_h = IMAGE_MIN_CARD_H;
    return card_h;
}

fn drawImageThumbnail(hdc: w.HDC, rect: w.RECT, data: []const u8) void {
    if (data.len < @sizeOf(w.BITMAPINFOHEADER)) return;

    const header: *const w.BITMAPINFOHEADER = @ptrCast(@alignCast(data.ptr));
    if (header.biSize < @sizeOf(w.BITMAPINFOHEADER)) return;
    if (header.biWidth == 0 or header.biHeight == 0) return;

    var color_table_bytes: usize = 0;
    if (header.biBitCount <= 8) {
        const color_count = if (header.biClrUsed != 0) header.biClrUsed else (@as(u32, 1) << @intCast(header.biBitCount));
        color_table_bytes = @as(usize, @intCast(color_count)) * 4;
    }

    const pixel_offset = @as(usize, @intCast(header.biSize)) + color_table_bytes;
    if (pixel_offset >= data.len) return;

    const bits_ptr: *const anyopaque = @ptrCast(data.ptr + pixel_offset);
    const bmi: *const w.BITMAPINFO = @ptrCast(@alignCast(header));

    const src_w: c_int = @intCast(@abs(header.biWidth));
    const src_h: c_int = @intCast(@abs(header.biHeight));
    const box_w: c_int = rect.right - rect.left;
    const box_h: c_int = rect.bottom - rect.top;
    const dst = fitImageNoUpscale(src_w, src_h, box_w, box_h);

    const x_off = rect.left + @divTrunc(box_w - dst.width, 2);
    const y_off = rect.top + @divTrunc(box_h - dst.height, 2);

    _ = w.StretchDIBits(
        hdc,
        x_off,
        y_off,
        dst.width,
        dst.height,
        0,
        0,
        src_w,
        src_h,
        bits_ptr,
        bmi,
        w.DIB_RGB_COLORS,
        w.SRCCOPY,
    );
}

fn drawUtf8Line(hdc: w.HDC, x: c_int, y: c_int, text: []const u8) void {
    var wide_buf: [512]u16 = [_]u16{0} ** 512;
    const len = std.unicode.utf8ToUtf16Le(wide_buf[0 .. wide_buf.len - 1], text) catch 0;
    if (len == 0) return;
    _ = w.TextOutW(hdc, x, y, wide_buf[0..len].ptr, @intCast(len));
}

fn rememberTargetWindow() void {
    const fg = w.GetForegroundWindow();
    if (fg != null and fg != g_picker_hwnd) {
        g_last_target_hwnd = fg;
        dbgLog("remembered target window", .{});
    }
}

// Only reached via HOTKEY_POLL_TIMER_ID, which only exists when at least one
// RegisterHotKey call failed at startup (see main()). Each branch is gated
// on its own *_needs_poll_fallback flag so a hotkey that registered
// successfully is never redundantly polled — WM_HOTKEY already covers it.
fn pollHotkeyFallback() void {
    const now = app_io.milliTimestamp();
    if (now - g_hotkey_debounce < 300) return;

    if (g_winv_needs_poll_fallback) {
        const win_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_LWIN))) or highBitSet(w.GetAsyncKeyState(@intCast(w.VK_RWIN)));
        const v_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_V)));
        if (win_down and v_down) {
            dbgLog("poll detected: Win+V", .{});
            g_hotkey_debounce = now;
            togglePicker();
            return;
        }
    }

    if (g_altb_needs_poll_fallback) {
        const ctrl_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_CONTROL)));
        const alt_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_MENU)));
        const b_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_B)));
        if (ctrl_down and alt_down and b_down) {
            dbgLog("poll detected: Ctrl+Alt+B", .{});
            g_hotkey_debounce = now;
            togglePicker();
            return;
        }
    }

    if (g_f8_needs_poll_fallback) {
        const f8_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_F8)));
        if (f8_down) {
            dbgLog("poll detected: F8", .{});
            g_hotkey_debounce = now;
            togglePicker();
            return;
        }
    }
}

fn highBitSet(value: i16) bool {
    const bits: u16 = @bitCast(value);
    return (bits & 0x8000) != 0;
}

fn lowBitSet(value: i16) bool {
    const bits: u16 = @bitCast(value);
    return (bits & 0x0001) != 0;
}

fn resolvePasteTarget() w.HWND {
    const fg = w.GetForegroundWindow();
    if (fg != null and fg != g_picker_hwnd and fg != g_message_hwnd) {
        g_last_target_hwnd = fg;
        return fg;
    }
    return g_last_target_hwnd;
}

fn hitTestEntryFromLParam(lp: w.LPARAM) ?usize {
    const click_y = getYFromLParam(lp);
    return hitTestEntryAtY(click_y);
}

fn hitTestEntryAtY(click_y: i32) ?usize {
    const len = filteredCount();
    if (len == 0) return null;
    if (click_y < LIST_TOP) return null;

    const card_w = getCardWidth();
    const view = activeView();
    const list_y = click_y - LIST_TOP + view.scroll_px;
    var item_top: c_int = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const r = filteredEntry(i) orelse break;
        const card_h = entryCardHeight(r.entry, card_w);
        if (list_y >= item_top and list_y < item_top + card_h) return i;
        item_top += card_h + CARD_GAP;
    }

    return null;
}

const ClickZone = enum { body, pin, delete };
const HitResult = struct { from_newest: usize, zone: ClickZone };

fn hitTestClick(click_x: i32, click_y: i32) ?HitResult {
    const len = filteredCount();
    if (len == 0) return null;
    if (click_y < LIST_TOP) return null;

    var client_rect: w.RECT = .{};
    if (g_picker_hwnd != null) _ = w.GetClientRect(g_picker_hwnd, &client_rect);
    const client_h = client_rect.bottom - client_rect.top;
    const viewport_h = listViewportHeight(client_h);
    if (click_y >= LIST_TOP + viewport_h) return null;

    const card_w = cardWidthFromClientRect(client_rect);
    const card_right = CARD_LEFT + card_w;
    if (click_x < CARD_LEFT or click_x > card_right) return null;

    const view = activeView();
    const list_y = click_y - LIST_TOP + view.scroll_px;
    var item_top: c_int = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const r = filteredEntry(i) orelse break;
        const card_h = entryCardHeight(r.entry, card_w);
        if (list_y >= item_top and list_y < item_top + card_h) {
            const local_y = list_y - item_top;
            // Check delete icon area (right side)
            if (click_x >= card_right - 28 and click_x <= card_right - 4 and local_y < 24) {
                return .{ .from_newest = i, .zone = .delete };
            }
            // Check pin icon area (left of delete)
            if (click_x >= card_right - 52 and click_x < card_right - 28 and local_y < 24) {
                return .{ .from_newest = i, .zone = .pin };
            }
            return .{ .from_newest = i, .zone = .body };
        }
        item_top += card_h + CARD_GAP;
    }
    return null;
}

fn getXFromLParam(lp: w.LPARAM) i32 {
    const raw: usize = @bitCast(lp);
    const x16: u16 = @truncate(raw);
    const x_i16: i16 = @bitCast(x16);
    return x_i16;
}

fn getYFromLParam(lp: w.LPARAM) i32 {
    const raw: usize = @bitCast(lp);
    const y16: u16 = @truncate(raw >> 16);
    const y_i16: i16 = @bitCast(y16);
    return y_i16;
}

fn scrollByPixels(delta_px: c_int) void {
    const flen = filteredCount();
    if (flen == 0) return;

    const card_w = getCardWidth();
    const client_h = getClientHeight();
    const view = activeView();
    view.scroll_px = clampScrollPx(view.scroll_px + delta_px, card_w, client_h);
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

fn pageScrollAmount() c_int {
    var amount = listViewportHeight(getClientHeight()) - PAGE_SCROLL_OVERLAP_PX;
    if (amount < WHEEL_SCROLL_PX) amount = WHEEL_SCROLL_PX;
    return amount;
}

const ItemBounds = struct { top: c_int, height: c_int };

fn selectedItemBounds(from_newest: usize, card_width: c_int) ?ItemBounds {
    var item_top: c_int = 0;
    var i: usize = 0;
    while (i <= from_newest) : (i += 1) {
        const r = filteredEntry(i) orelse return null;
        const card_h = entryCardHeight(r.entry, card_width);
        if (i == from_newest) return .{ .top = item_top, .height = card_h };
        item_top += card_h + CARD_GAP;
    }
    return null;
}

fn ensureSelectionVisible() void {
    const len = filteredCount();
    if (len == 0) return;
    clampActiveView();

    const client_h = getClientHeight();
    const card_w = getCardWidth();
    const viewport_h = listViewportHeight(client_h);
    if (viewport_h <= 0) return;

    const view = activeView();
    const selected = if (view.selected_from_newest < len) view.selected_from_newest else len - 1;
    const bounds = selectedItemBounds(selected, card_w) orelse return;
    const selected_top = bounds.top;
    const selected_bottom = bounds.top + bounds.height;

    if (selected_top < view.scroll_px) {
        view.scroll_px = selected_top;
    } else if (selected_bottom > view.scroll_px + viewport_h) {
        view.scroll_px = selected_bottom - viewport_h;
    }
    view.scroll_px = clampScrollPx(view.scroll_px, card_w, client_h);
}

fn getClientHeight() c_int {
    if (g_picker_hwnd == null) return 480;
    var rect: w.RECT = .{};
    if (w.GetClientRect(g_picker_hwnd, &rect) == 0) return 480;
    return rect.bottom - rect.top;
}

fn getClientWidth() c_int {
    if (g_picker_hwnd == null) return 368;
    var rect: w.RECT = .{};
    if (w.GetClientRect(g_picker_hwnd, &rect) == 0) return 368;
    return rect.right - rect.left;
}

fn getCardWidth() c_int {
    const rect = w.RECT{ .left = 0, .top = 0, .right = getClientWidth(), .bottom = getClientHeight() };
    return cardWidthFromClientRect(rect);
}

fn cardWidthFromClientRect(rect: w.RECT) c_int {
    var card_w = (rect.right - rect.left) - CARD_LEFT - CARD_RIGHT_MARGIN;
    if (card_w < CARD_MIN_W) card_w = CARD_MIN_W;
    return card_w;
}

fn listViewportHeight(client_h: c_int) c_int {
    var h = client_h - LIST_TOP - BOTTOM_MARGIN;
    if (h < 0) h = 0;
    return h;
}

fn totalContentHeight(card_width: c_int) c_int {
    const len = filteredCount();
    var total: c_int = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const r = filteredEntry(i) orelse break;
        if (i > 0) total += CARD_GAP;
        total += entryCardHeight(r.entry, card_width);
    }
    return total;
}

fn maxScrollPx(card_width: c_int, client_h: c_int) c_int {
    const total_h = totalContentHeight(card_width);
    const viewport_h = listViewportHeight(client_h);
    if (total_h <= viewport_h) return 0;
    return total_h - viewport_h;
}

fn clampScrollPx(scroll_px: c_int, card_width: c_int, client_h: c_int) c_int {
    const max_scroll = maxScrollPx(card_width, client_h);
    if (scroll_px < 0) return 0;
    if (scroll_px > max_scroll) return max_scroll;
    return scroll_px;
}

fn clampActiveViewWithMetrics(card_width: c_int, client_h: c_int) void {
    const view = activeView();
    const len = filteredCount();
    if (len == 0) {
        resetView(view);
        return;
    }
    if (view.selected_from_newest >= len) view.selected_from_newest = len - 1;
    view.scroll_px = clampScrollPx(view.scroll_px, card_width, client_h);
}

fn clampActiveView() void {
    clampActiveViewWithMetrics(getCardWidth(), getClientHeight());
}

fn drawScrollbar(hdc: w.HDC, rect: w.RECT, total_content_h: c_int, scroll_px: c_int, viewport_h: c_int) void {
    if (viewport_h <= 0 or total_content_h <= viewport_h) return;

    const track_left = rect.right - 6;
    const track_right = rect.right - 4;
    const track_top: c_int = LIST_TOP;
    const track_bottom: c_int = LIST_TOP + viewport_h;
    const track_h = track_bottom - track_top;
    if (track_h <= 0) return;

    var thumb_h: c_int = @intCast(@divTrunc(@as(i64, track_h) * @as(i64, viewport_h), @as(i64, total_content_h)));
    if (thumb_h < 24) thumb_h = 24;
    if (thumb_h > track_h) thumb_h = track_h;

    const max_scroll = total_content_h - viewport_h;
    const travel = track_h - thumb_h;
    const thumb_off: c_int = if (max_scroll == 0) 0 else @intCast(@divTrunc(@as(i64, travel) * @as(i64, scroll_px), @as(i64, max_scroll)));

    const thumb = w.RECT{
        .left = track_left,
        .top = track_top + thumb_off,
        .right = track_right,
        .bottom = track_top + thumb_off + thumb_h,
    };
    const thumb_brush = w.CreateSolidBrush(w.RGB(153, 153, 153));
    if (thumb_brush != null) {
        _ = w.FillRect(hdc, &thumb, thumb_brush);
        _ = w.DeleteObject(thumb_brush);
    }
}

fn entryCardHeight(entry: history.Entry, card_width: c_int) c_int {
    return switch (entry.item) {
        .text => |text| blk: {
            var lines: [MAX_TEXT_LINES][120]u8 = [_][120]u8{[_]u8{0} ** 120} ** MAX_TEXT_LINES;
            const wrap_chars = textWrapCharsForCardWidth(card_width);
            const wrapped = wrapTextIntoLines(text, &lines, wrap_chars);
            var count: c_int = @intCast(wrapped.line_count);
            if (count < MIN_TEXT_LINES) count = MIN_TEXT_LINES;
            break :blk count * TEXT_LINE_H + TEXT_PAD_V;
        },
        .image => |img| imageCardHeight(img, card_width),
    };
}

fn getWheelDelta(wparam: w.WPARAM) i16 {
    const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
    return @bitCast(hi);
}

// EcoQoS: ask the scheduler to run this process on efficiency cores / at
// lower clocks when it's not the thing the user is actively interacting
// with. Cheap to leave on all the time for a background hotkey utility with
// no latency-critical hot path; if picker responsiveness ever suffers, this
// is the first thing to make visible-only.
fn enableEcoQoS() void {
    var state = w.PROCESS_POWER_THROTTLING_STATE{
        .Version = w.PROCESS_POWER_THROTTLING_CURRENT_VERSION,
        .ControlMask = w.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
        .StateMask = w.PROCESS_POWER_THROTTLING_EXECUTION_SPEED,
    };
    const ok = w.SetProcessInformation(
        w.GetCurrentProcess(),
        w.ProcessPowerThrottling,
        &state,
        @sizeOf(w.PROCESS_POWER_THROTTLING_STATE),
    );
    if (ok == 0) {
        dbgLog("SetProcessInformation(EcoQoS) failed winerr={d}", .{w.GetLastError()});
    } else {
        dbgLog("EcoQoS enabled", .{});
    }
}

fn initDebugLog() void {
    if (!build_options.debug_log) return;

    const cwd = std.Io.Dir.cwd();
    g_log_file = cwd.createFile(app_io.io, "lightboard-debug.log", .{ .read = true, .truncate = false }) catch null;

    dbgLog("lightboard boot", .{});
}

fn applyWindowTheme(hwnd: w.HWND) void {
    var dark: w.BOOL = 1;
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(w.BOOL));

    var corner: w.DWORD = w.DWMWCP_ROUND;
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_WINDOW_CORNER_PREFERENCE, &corner, @sizeOf(w.DWORD));

    var caption: w.DWORD = w.RGB(32, 32, 32);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_CAPTION_COLOR, &caption, @sizeOf(w.DWORD));

    var text: w.DWORD = w.RGB(255, 255, 255);
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_TEXT_COLOR, &text, @sizeOf(w.DWORD));
}

fn removeCloseButton(hwnd: w.HWND) void {
    const menu = w.GetSystemMenu(hwnd, 0);
    if (menu != null) {
        _ = w.DeleteMenu(menu, w.SC_CLOSE, w.MF_BYCOMMAND);
        _ = w.DrawMenuBar(hwnd);
    }
}

fn initPersistence(allocator: std.mem.Allocator) !void {
    const env: std.process.Environ = .{ .block = .global };
    const local_app_data = env.getAlloc(allocator, "LOCALAPPDATA") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            dbgLog("LOCALAPPDATA not found; persistence disabled", .{});
            g_history_path = &[_]u8{};
            return;
        },
        else => return err,
    };
    defer allocator.free(local_app_data);

    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{ local_app_data, "lightboard" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(app_io.io, data_dir);

    g_history_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "history.bin" });
    dbgLog("persistence path: {s}", .{g_history_path});

    // Set up images directory and compression workspace
    const images_dir = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "images" });
    try std.Io.Dir.cwd().createDirPath(app_io.io, images_dir);
    g_images_dir_path = images_dir;
    img_store.init(allocator, images_dir);
    dbgLog("images dir: {s}", .{images_dir});
}

fn persistHistory() void {
    if (g_history_path.len == 0) return;
    history.saveToFile(&g_history, g_history_path) catch |err| {
        dbgLog("history save failed: {s}", .{@errorName(err)});
    };
}

fn dbgLog(comptime fmt: []const u8, args: anytype) void {
    if (g_log_file == null) return;

    var line_buf: [1024]u8 = undefined;
    const ts = app_io.unixTimestamp();
    const line = std.fmt.bufPrint(&line_buf, "[{d}] " ++ fmt ++ "\r\n", .{ts} ++ args) catch return;
    const file = g_log_file.?;
    const stat = file.stat(app_io.io) catch return;
    file.writePositionalAll(app_io.io, line, stat.size) catch {};
}
