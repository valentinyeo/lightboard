const std = @import("std");
const w = @import("win32.zig");
const clip = @import("clipboard.zig");
const history = @import("history.zig");

const MESSAGE_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("lightboard_msg");
const PICKER_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("lightboard_picker");
const WINDOW_NAME = std.unicode.utf8ToUtf16LeStringLiteral("lightboard");
const HOTKEY_ID: usize = 1;
const HOTKEY_ID_F8: usize = 2;
const TARGET_TRACK_TIMER_ID: usize = 1;
const TARGET_TRACK_INTERVAL_MS: w.UINT = 20;
const LIST_TOP: c_int = 8;
const CARD_GAP: c_int = 4;
const TEXT_LINE_H: c_int = 20;
const TEXT_PAD_V: c_int = 20; // 10 top + 10 bottom
const MAX_TEXT_LINES: usize = 5;
const MAX_WRAP_CHARS: usize = 40;
const IMAGE_CARD_H: c_int = 160;
const BOTTOM_MARGIN: c_int = 8;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var g_history = history.History.init(120);
var g_message_hwnd: w.HWND = null;
var g_picker_hwnd: w.HWND = null;
var g_hotkey_label: []const u8 = "Win+V";
var g_hotkey_registered = false;
var g_selected_from_newest: usize = 0;
var g_scroll_from_newest: usize = 0;
var g_ignore_clipboard_updates: usize = 0;
var g_log_file: ?std.fs.File = null;
var g_f8_hotkey_registered = false;
var g_last_target_hwnd: w.HWND = null;
var g_ui_font: w.HFONT = null;
var g_history_path: []u8 = &[_]u8{};
var g_prev_left_down = false;
var g_timer_logged = false;
var g_hotkey_debounce: i64 = 0; // timestamp of last toggle to prevent rapid re-toggle
var g_kb_hook: w.HHOOK = null; // low-level keyboard hook for Win+V
var g_win_key_down: bool = false; // tracking Win key state for the hook
var g_ate_winv: bool = false; // true if we consumed Win+V during current Win hold

pub fn main() !void {
    initDebugLog();
    defer {
        dbgLog("lightboard shutting down", .{});
        if (g_log_file) |f| f.close();

        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("memory leaks detected", .{});
        }
    }

    const allocator = gpa.allocator();
    try initPersistence(allocator);
    defer if (g_history_path.len > 0) allocator.free(g_history_path);
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
    removeCloseButton(g_picker_hwnd);
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
    _ = w.SetTimer(g_message_hwnd, TARGET_TRACK_TIMER_ID, TARGET_TRACK_INTERVAL_MS, null);
    defer _ = w.KillTimer(g_message_hwnd, TARGET_TRACK_TIMER_ID);

    // Try low-level keyboard hook for Win+V first (bypasses Windows shell reservation)
    const winv_hooked = installWinVHook();
    defer {
        if (g_kb_hook != null) _ = w.UnhookWindowsHookEx(g_kb_hook);
    }
    if (winv_hooked) {
        g_hotkey_label = "Win+V";
        g_hotkey_registered = true;
        std.log.info("lightboard running (Win+V opens picker via LL hook)", .{});
        dbgLog("hotkey active: Win+V (LL hook)", .{});
    } else if (registerHotkey()) {
        defer _ = w.UnregisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID));
        std.log.info("lightboard running ({s} opens picker)", .{g_hotkey_label});
        dbgLog("hotkey active: {s}", .{g_hotkey_label});
    } else {
        std.log.warn("lightboard running with no hotkey (all candidates unavailable)", .{});
        dbgLog("no hotkey available", .{});
    }

    g_f8_hotkey_registered = w.RegisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_F8), 0, w.VK_F8) != 0;
    if (g_f8_hotkey_registered) {
        defer _ = w.UnregisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID_F8));
        dbgLog("registered backup hotkey: F8", .{});
    } else {
        dbgLog("failed backup hotkey F8 winerr={d}", .{w.GetLastError()});
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
            const steps: i32 = @intCast(@max(@as(u32, 1), @divTrunc(@as(u32, @intCast(@abs(@as(i32, delta)))), @as(u32, 120))));
            if (delta > 0) scrollBy(-steps) else if (delta < 0) scrollBy(steps);
            dbgLog("wheel scroll(loop) delta={d}", .{delta});
            continue;
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

fn llKeyboardProc(nCode: w.INT, wParam: w.WPARAM, lParam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    if (nCode == w.HC_ACTION) {
        const kb: *const w.KBDLLHOOKSTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
        const msg = @as(w.UINT, @intCast(wParam));
        const is_injected = (kb.flags & w.LLKHF_INJECTED) != 0;

        // Track Win key state
        if (kb.vkCode == w.VK_LWIN or kb.vkCode == w.VK_RWIN) {
            if (msg == w.WM_KEYDOWN_LL or msg == w.WM_SYSKEYDOWN) {
                g_win_key_down = true;
            } else if (msg == w.WM_KEYUP_LL or msg == w.WM_SYSKEYUP) {
                g_win_key_down = false;
                // If we consumed Win+V during this hold, suppress the real
                // Win key-up (prevents Start menu) and inject a synthetic one
                // (LLKHF_INJECTED flag makes the shell ignore it).
                if (g_ate_winv and !is_injected) {
                    g_ate_winv = false;
                    var up = [1]w.INPUT{
                        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{
                            .wVk = @intCast(kb.vkCode),
                            .dwFlags = w.KEYEVENTF_KEYUP,
                        } } },
                    };
                    _ = w.SendInput(1, &up, @sizeOf(w.INPUT));
                    return 1; // swallow the real key-up
                }
            }
        }

        // Intercept Win+V: swallow both keydown and keyup of V while Win is held
        if (kb.vkCode == w.VK_V and g_win_key_down) {
            if (msg == w.WM_KEYDOWN_LL or msg == w.WM_SYSKEYDOWN) {
                g_ate_winv = true;
                _ = w.PostMessageW(g_message_hwnd, w.WM_APP, 0, 0);
                dbgLog("LL hook: Win+V intercepted, posting WM_APP", .{});
            }
            return 1; // swallow the keystroke
        }
    }
    return w.CallNextHookEx(g_kb_hook, nCode, wParam, lParam);
}

fn installWinVHook() bool {
    g_kb_hook = w.SetWindowsHookExW(w.WH_KEYBOARD_LL, llKeyboardProc, w.GetModuleHandleW(null), 0);
    if (g_kb_hook != null) {
        dbgLog("installed LL keyboard hook for Win+V", .{});
        return true;
    } else {
        dbgLog("failed LL keyboard hook winerr={d}", .{w.GetLastError()});
        return false;
    }
}

fn registerHotkey() bool {
    const candidates = [_]struct {
        mods: w.UINT,
        vk: w.UINT,
        label: []const u8,
    }{
        .{ .mods = w.MOD_CONTROL | w.MOD_ALT, .vk = w.VK_B, .label = "Ctrl+Alt+B" },
        .{ .mods = w.MOD_CONTROL | w.MOD_SHIFT, .vk = w.VK_V, .label = "Ctrl+Shift+V" },
        .{ .mods = w.MOD_CONTROL | w.MOD_ALT, .vk = w.VK_V, .label = "Ctrl+Alt+V" },
        .{ .mods = w.MOD_ALT, .vk = w.VK_V, .label = "Alt+V" },
    };

    for (candidates) |candidate| {
        dbgLog("trying hotkey: {s}", .{candidate.label});
        if (w.RegisterHotKey(g_message_hwnd, @intCast(HOTKEY_ID), candidate.mods, candidate.vk) != 0) {
            g_hotkey_label = candidate.label;
            g_hotkey_registered = true;
            dbgLog("registered hotkey: {s}", .{candidate.label});
            return true;
        }
        dbgLog("failed hotkey: {s} winerr={d}", .{ candidate.label, w.GetLastError() });
    }

    g_hotkey_registered = false;
    g_hotkey_label = "None";
    return false;
}

fn wndProc(hwnd: w.HWND, msg: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(w.WINAPI) w.LRESULT {
    switch (msg) {
        w.WM_APP => {
            // Win+V intercepted by low-level keyboard hook
            dbgLog("WM_APP: Win+V hook toggle", .{});
            const now = std.time.milliTimestamp();
            if (now - g_hotkey_debounce >= 300) {
                g_hotkey_debounce = now;
                togglePicker();
            }
            return 0;
        },
        w.WM_HOTKEY => {
            // WM_HOTKEY delivery is unreliable on some systems; polling handles it.
            // Just log if we ever receive one (for diagnostics).
            dbgLog("WM_HOTKEY received id={d} (ignored, poll handles it)", .{wparam});
            return 0;
        },
        w.WM_CLIPBOARDUPDATE => {
            onClipboardUpdate();
            return 0;
        },
        w.WM_TIMER => {
            if (wparam == TARGET_TRACK_TIMER_ID) {
                if (!g_timer_logged) {
                    g_timer_logged = true;
                    dbgLog("WM_TIMER first tick confirmed", .{});
                }
                trackForegroundTarget();
                pollHotkeyFallback();
                hideOnOutsideClick();
                return 0;
            }
        },
        w.WM_ACTIVATE => {
            if (g_picker_hwnd != null and hwnd == g_picker_hwnd) {
                if ((wparam & 0xFFFF) != w.WA_INACTIVE) {
                    _ = w.SetFocus(g_picker_hwnd);
                }
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
                if (hitTestClick(click_x, click_y)) |hit| {
                    switch (hit.zone) {
                        .delete => {
                            g_selected_from_newest = hit.from_newest;
                            deleteSelected();
                        },
                        .pin => {
                            const hlen = g_history.len();
                            const entry_idx = (hlen - 1) - hit.from_newest;
                            g_history.entries.items[entry_idx].sticky = !g_history.entries.items[entry_idx].sticky;
                            g_selected_from_newest = hit.from_newest;
                            _ = w.InvalidateRect(g_picker_hwnd, null, 1);
                            persistHistory();
                        },
                        .body => {
                            g_selected_from_newest = hit.from_newest;
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
                const steps: i32 = @intCast(@max(@as(u32, 1), @divTrunc(@as(u32, @intCast(@abs(@as(i32, delta)))), @as(u32, 120))));
                if (delta > 0) scrollBy(-steps) else if (delta < 0) scrollBy(steps);
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
                _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
                dbgLog("picker hidden by close", .{});
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
        std.log.err("clipboard capture failed: {s}", .{@errorName(err)});
        return;
    };

    if (maybe_entry) |entry| {
        g_history.push(allocator, entry) catch |err| {
            std.log.err("history push failed: {s}", .{@errorName(err)});
            if (entry.item == .text) allocator.free(entry.item.text);
            if (entry.item == .image) allocator.free(entry.item.image.data);
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
                std.log.info("captured image [{d}] {s} bytes={d}", .{ total, @tagName(img.format), img.data.len });
                dbgLog("captured image format={s} bytes={d} total={d}", .{ @tagName(img.format), img.data.len, total });
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
        _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
        dbgLog("picker hidden by hotkey", .{});
        return;
    }

    rememberTargetWindow();
    g_selected_from_newest = 0;
    g_scroll_from_newest = 0;
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    _ = w.ShowWindow(g_picker_hwnd, w.SW_SHOW);
    forceForeground(g_picker_hwnd);
    dbgLog("picker shown by hotkey", .{});
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
            _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
            dbgLog("picker hidden by Esc", .{});
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
            pasteSelection();
        },
        w.VK_PRIOR => {
            scrollBy(-4);
        },
        w.VK_NEXT => {
            scrollBy(4);
        },
        w.VK_DELETE => {
            if (ctrl_held) {
                deleteAllNonSticky();
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
        else => {},
    }
}

fn handlePickerChar(ch: w.UINT) void {
    // WM_CHAR is consumed here to prevent Windows beeping on unhandled chars.
    // j/k navigation is handled in handlePickerKey via WM_KEYDOWN.
    _ = ch;
}

fn moveSelection(delta: i32) void {
    const len = g_history.len();
    if (len == 0) return;

    var next = @as(i32, @intCast(g_selected_from_newest)) + delta;
    if (next < 0) next = 0;

    const max_idx: i32 = @intCast(len - 1);
    if (next > max_idx) next = max_idx;

    g_selected_from_newest = @intCast(next);
    ensureSelectionVisible();
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

fn pasteSelection() void {
    const len = g_history.len();
    if (len == 0) return;

    const from_newest = if (g_selected_from_newest < len) g_selected_from_newest else len - 1;
    const idx = (len - 1) - from_newest;
    const selected = g_history.entries.items[idx];

    clip.restoreToClipboard(selected) catch |err| {
        std.log.err("restore clipboard failed: {s} winerr={d}", .{ @errorName(err), w.GetLastError() });
        dbgLog("restore clipboard failed: {s} winerr={d}", .{ @errorName(err), w.GetLastError() });
        return;
    };

    g_ignore_clipboard_updates = 1;
    _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
    dbgLog("pasting selected entry", .{});

    const target = resolvePasteTarget();
    if (target != null and target != g_picker_hwnd) {
        _ = w.SetForegroundWindow(target);
        // Give Windows time to complete foreground handoff before synthetic keys.
        std.Thread.sleep(140 * std.time.ns_per_ms);
    } else {
        dbgLog("no previous target window available for focus restore", .{});
    }

    clip.sendCtrlV();
}

fn deleteSelected() void {
    const allocator = gpa.allocator();
    const len = g_history.len();
    if (len == 0) return;

    const from_newest = if (g_selected_from_newest < len) g_selected_from_newest else len - 1;
    const idx = (len - 1) - from_newest;

    g_history.removeAt(allocator, idx);
    dbgLog("deleted entry idx={d} from_newest={d}", .{ idx, from_newest });

    // Adjust selection: keep same position, but clamp to new bounds
    const new_len = g_history.len();
    if (new_len == 0) {
        g_selected_from_newest = 0;
        g_scroll_from_newest = 0;
    } else {
        if (g_selected_from_newest >= new_len) {
            g_selected_from_newest = new_len - 1;
        }
        if (g_scroll_from_newest >= new_len) {
            g_scroll_from_newest = if (new_len > 0) new_len - 1 else 0;
        }
    }

    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
}

fn deleteAllNonSticky() void {
    const allocator = gpa.allocator();
    g_history.clearNonSticky(allocator);
    g_selected_from_newest = 0;
    g_scroll_from_newest = 0;
    dbgLog("deleted all non-sticky entries, remaining={d}", .{g_history.len()});
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
}

fn toggleSticky() void {
    const len = g_history.len();
    if (len == 0) return;

    const from_newest = if (g_selected_from_newest < len) g_selected_from_newest else len - 1;
    const idx = (len - 1) - from_newest;

    g_history.entries.items[idx].sticky = !g_history.entries.items[idx].sticky;
    dbgLog("toggled sticky idx={d} now={}", .{ idx, g_history.entries.items[idx].sticky });
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
    persistHistory();
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

    const len = g_history.len();
    if (len == 0) {
        _ = w.SetTextColor(hdc, color_text_sub);
        drawUtf8Line(hdc, 16, 20, "Clipboard history is empty");
        return;
    }

    const selected = if (g_selected_from_newest < len) g_selected_from_newest else len - 1;
    const client_h = rect.bottom - rect.top;
    const start_from_newest = g_scroll_from_newest;

    var y: c_int = LIST_TOP;
    var visible_count: usize = 0;
    var i: usize = start_from_newest;
    while (i < len) : (i += 1) {
        const entry_idx = (len - 1) - i;
        const entry = g_history.entries.items[entry_idx];
        const card_h = entryCardHeight(entry);
        if (y + card_h > client_h - BOTTOM_MARGIN and visible_count > 0) break;

        const is_selected = i == selected;

        const row_rect = w.RECT{ .left = 12, .top = y, .right = rect.right - 20, .bottom = y + card_h };
        const row_brush = w.CreateSolidBrush(if (is_selected) color_card_selected else color_card);
        if (row_brush != null) {
            _ = w.FillRect(hdc, &row_rect, row_brush);
            _ = w.DeleteObject(row_brush);
        }

        if (is_selected) {
            const bar_h: c_int = @min(20, card_h - 8);
            const bar_top = y + @divTrunc(card_h - bar_h, 2);
            const accent_rect = w.RECT{ .left = 12, .top = bar_top, .right = 15, .bottom = bar_top + bar_h };
            const accent_brush = w.CreateSolidBrush(color_accent);
            if (accent_brush != null) {
                _ = w.FillRect(hdc, &accent_rect, accent_brush);
                _ = w.DeleteObject(accent_brush);
            }
        }

        renderEntryLine(hdc, row_rect, entry, color_text_main, color_text_sub, color_accent);
        y += card_h + CARD_GAP;
        visible_count += 1;
    }

    if (visible_count > 0) {
        drawScrollbar(hdc, rect, len, start_from_newest, visible_count);
    }
}

fn renderEntryLine(hdc: w.HDC, rect: w.RECT, entry: history.Entry, color_text_main: w.COLORREF, color_text_sub: w.COLORREF, color_accent: w.COLORREF) void {
    const text_x = rect.left + 14;
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
            const lens = wrapTextIntoLines(text, &lines, MAX_TEXT_LINES, MAX_WRAP_CHARS);
            var li: usize = 0;
            while (li < lens.len) : (li += 1) {
                if (lens[li] == 0) break;
                drawUtf8Line(hdc, text_x, text_y + @as(c_int, @intCast(li)) * TEXT_LINE_H, lines[li][0..lens[li]]);
            }
        },
        .image => |img| {
            const thumb_rect = w.RECT{
                .left = rect.left + 12,
                .top = rect.top + 8,
                .right = rect.right - 12,
                .bottom = rect.bottom - 8,
            };
            drawImageThumbnail(hdc, thumb_rect, img);
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

fn wrapTextIntoLines(src: []const u8, lines: anytype, max_lines: usize, max_chars: usize) []usize {
    var lengths: [8]usize = [_]usize{0} ** 8;
    var sanitized: [512]u8 = undefined;
    const n = sanitizeInto(&sanitized, src);
    const text = sanitized[0..n];

    var line_idx: usize = 0;
    var i: usize = 0;
    while (i < text.len and line_idx < max_lines) {
        while (i < text.len and text[i] == ' ') : (i += 1) {}
        if (i >= text.len) break;

        var end = @min(i + max_chars, text.len);
        if (end < text.len) {
            var j = end;
            while (j > i and text[j - 1] != ' ') : (j -= 1) {}
            if (j > i) end = j - 1;
        }

        const slice = text[i..end];
        const copy_len = @min(slice.len, lines[line_idx].len - 1);
        @memcpy(lines[line_idx][0..copy_len], slice[0..copy_len]);
        lengths[line_idx] = copy_len;
        line_idx += 1;

        i = end;
        while (i < text.len and text[i] == ' ') : (i += 1) {}
    }

    if (i < text.len and line_idx == max_lines and lengths[max_lines - 1] >= 3) {
        const last = max_lines - 1;
        lines[last][lengths[last] - 3] = '.';
        lines[last][lengths[last] - 2] = '.';
        lines[last][lengths[last] - 1] = '.';
    }

    return lengths[0..max_lines];
}

fn drawImageThumbnail(hdc: w.HDC, rect: w.RECT, image: history.ImageMeta) void {
    if (image.data.len < @sizeOf(w.BITMAPINFOHEADER)) return;

    const header: *const w.BITMAPINFOHEADER = @ptrCast(@alignCast(image.data.ptr));
    if (header.biSize < @sizeOf(w.BITMAPINFOHEADER)) return;
    if (header.biWidth == 0 or header.biHeight == 0) return;

    var color_table_bytes: usize = 0;
    if (header.biBitCount <= 8) {
        const color_count = if (header.biClrUsed != 0) header.biClrUsed else (@as(u32, 1) << @intCast(header.biBitCount));
        color_table_bytes = @as(usize, @intCast(color_count)) * 4;
    }

    const pixel_offset = @as(usize, @intCast(header.biSize)) + color_table_bytes;
    if (pixel_offset >= image.data.len) return;

    const bits_ptr: *const anyopaque = @ptrCast(image.data.ptr + pixel_offset);
    const bmi: *const w.BITMAPINFO = @ptrCast(@alignCast(header));

    const src_w: c_int = @intCast(@abs(header.biWidth));
    const src_h: c_int = @intCast(@abs(header.biHeight));
    const box_w: c_int = rect.right - rect.left;
    const box_h: c_int = rect.bottom - rect.top;

    // Fit image proportionally inside the destination box, centered
    const dst_w: c_int, const dst_h: c_int = blk: {
        if (src_w == 0 or src_h == 0) break :blk .{ box_w, box_h };
        const scale_w = @as(i64, box_w) * @as(i64, src_h);
        const scale_h = @as(i64, box_h) * @as(i64, src_w);
        if (scale_w <= scale_h) {
            // Width-limited
            const h: c_int = @intCast(@divTrunc((@as(i64, box_w) * @as(i64, src_h)), @as(i64, src_w)));
            break :blk .{ box_w, h };
        } else {
            // Height-limited
            const w_fit: c_int = @intCast(@divTrunc((@as(i64, box_h) * @as(i64, src_w)), @as(i64, src_h)));
            break :blk .{ w_fit, box_h };
        }
    };

    const x_off = rect.left + @divTrunc(box_w - dst_w, 2);
    const y_off = rect.top + @divTrunc(box_h - dst_h, 2);

    _ = w.StretchDIBits(
        hdc,
        x_off,
        y_off,
        dst_w,
        dst_h,
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

fn trackForegroundTarget() void {
    const fg = w.GetForegroundWindow();
    if (fg != null and fg != g_picker_hwnd and fg != g_message_hwnd) {
        g_last_target_hwnd = fg;
    }
}

fn pollHotkeyFallback() void {
    // Always poll hotkeys via GetAsyncKeyState because WM_HOTKEY delivery
    // is unreliable on some Windows configurations. Use timestamp debounce
    // to prevent rapid re-toggle (300ms cooldown).
    const now = std.time.milliTimestamp();
    if (now - g_hotkey_debounce < 300) return;

    // Check Ctrl+Alt+B
    const ctrl_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_CONTROL)));
    const alt_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_MENU)));
    const b_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_B)));
    if (ctrl_down and alt_down and b_down) {
        dbgLog("poll detected: Ctrl+Alt+B", .{});
        g_hotkey_debounce = now;
        togglePicker();
        return;
    }

    // Check F8
    const f8_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_F8)));
    if (f8_down) {
        dbgLog("poll detected: F8", .{});
        g_hotkey_debounce = now;
        togglePicker();
        return;
    }
}

fn hideOnOutsideClick() void {
    if (g_picker_hwnd == null) return;
    if (w.IsWindowVisible(g_picker_hwnd) == 0) {
        g_prev_left_down = false;
        return;
    }

    const left_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_LBUTTON)));
    const just_pressed = left_down and !g_prev_left_down;
    g_prev_left_down = left_down;
    if (!just_pressed) return;

    var cursor: w.POINT = .{};
    if (w.GetCursorPos(&cursor) == 0) return;

    var wr: w.RECT = .{};
    if (w.GetWindowRect(g_picker_hwnd, &wr) == 0) return;

    const inside = cursor.x >= wr.left and cursor.x <= wr.right and cursor.y >= wr.top and cursor.y <= wr.bottom;
    if (!inside) {
        _ = w.ShowWindow(g_picker_hwnd, w.SW_HIDE);
        dbgLog("picker hidden by outside click", .{});
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
    const len = g_history.len();
    if (len == 0) return null;

    const click_y = getYFromLParam(lp);
    if (click_y < LIST_TOP) return null;

    var y: c_int = LIST_TOP;
    var i: usize = g_scroll_from_newest;
    while (i < len) : (i += 1) {
        const entry_idx = (len - 1) - i;
        const card_h = entryCardHeight(g_history.entries.items[entry_idx]);
        if (click_y >= y and click_y < y + card_h) return i;
        y += card_h + CARD_GAP;
        if (y > 2000) break; // safety
    }

    return null;
}

const ClickZone = enum { body, pin, delete };
const HitResult = struct { from_newest: usize, zone: ClickZone };

fn hitTestClick(click_x: i32, click_y: i32) ?HitResult {
    const len = g_history.len();
    if (len == 0) return null;
    if (click_y < LIST_TOP) return null;

    var client_rect: w.RECT = .{};
    if (g_picker_hwnd != null) _ = w.GetClientRect(g_picker_hwnd, &client_rect);
    const card_right = client_rect.right - 20;

    var y: c_int = LIST_TOP;
    var i: usize = g_scroll_from_newest;
    while (i < len) : (i += 1) {
        const entry_idx = (len - 1) - i;
        const card_h = entryCardHeight(g_history.entries.items[entry_idx]);
        if (click_y >= y and click_y < y + card_h) {
            // Check delete icon area (right side)
            if (click_x >= card_right - 28 and click_x <= card_right - 4 and click_y < y + 24) {
                return .{ .from_newest = i, .zone = .delete };
            }
            // Check pin icon area (left of delete)
            if (click_x >= card_right - 52 and click_x < card_right - 28 and click_y < y + 24) {
                return .{ .from_newest = i, .zone = .pin };
            }
            return .{ .from_newest = i, .zone = .body };
        }
        y += card_h + CARD_GAP;
        if (y > 2000) break;
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

fn scrollBy(delta: i32) void {
    const len = g_history.len();
    if (len == 0) return;
    const max_start: i32 = @intCast(len - 1);
    var next: i32 = @intCast(g_scroll_from_newest);
    next += delta;
    if (next < 0) next = 0;
    if (next > max_start) next = max_start;
    g_scroll_from_newest = @intCast(next);
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

fn ensureSelectionVisible() void {
    const len = g_history.len();
    if (len == 0) return;

    // If selection is above scroll position, scroll up to it
    if (g_selected_from_newest < g_scroll_from_newest) {
        g_scroll_from_newest = g_selected_from_newest;
        return;
    }

    // If selection is below visible area, scroll down until it fits
    const client_h = getClientHeight();
    var y: c_int = LIST_TOP;
    var i: usize = g_scroll_from_newest;
    while (i < len) : (i += 1) {
        const entry_idx = (len - 1) - i;
        const card_h = entryCardHeight(g_history.entries.items[entry_idx]);
        if (i == g_selected_from_newest) {
            if (y + card_h > client_h - BOTTOM_MARGIN) {
                // Selection doesn't fit, scroll down
                g_scroll_from_newest += 1;
                return ensureSelectionVisible();
            }
            return; // visible
        }
        y += card_h + CARD_GAP;
    }
}

fn getClientHeight() c_int {
    if (g_picker_hwnd == null) return 480;
    var rect: w.RECT = .{};
    if (w.GetClientRect(g_picker_hwnd, &rect) == 0) return 480;
    return rect.bottom - rect.top;
}

fn drawScrollbar(hdc: w.HDC, rect: w.RECT, total: usize, start: usize, visible_rows: usize) void {
    if (total <= visible_rows) return;

    const track_left = rect.right - 6;
    const track_right = rect.right - 4;
    const track_top: c_int = 8;
    const track_bottom: c_int = rect.bottom - 8;
    const track_h = track_bottom - track_top;

    var thumb_h: i32 = @intCast(@divTrunc((@as(i64, track_h) * @as(i64, @intCast(visible_rows))), @as(i64, @intCast(total))));
    if (thumb_h < 24) thumb_h = 24;
    const max_start = total - visible_rows;
    const travel = track_h - thumb_h;
    const thumb_off: i32 = if (max_start == 0) 0 else @intCast(@divTrunc((@as(i64, travel) * @as(i64, @intCast(start))), @as(i64, @intCast(max_start))));

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

fn entryCardHeight(entry: history.Entry) c_int {
    return switch (entry.item) {
        .text => |text| blk: {
            var lines: [MAX_TEXT_LINES][120]u8 = [_][120]u8{[_]u8{0} ** 120} ** MAX_TEXT_LINES;
            const lens = wrapTextIntoLines(text, &lines, MAX_TEXT_LINES, MAX_WRAP_CHARS);
            var count: c_int = 0;
            for (lens) |l| {
                if (l > 0) count += 1;
            }
            if (count == 0) count = 1;
            break :blk count * TEXT_LINE_H + TEXT_PAD_V;
        },
        .image => IMAGE_CARD_H,
    };
}

fn getWheelDelta(wparam: w.WPARAM) i16 {
    const hi: u16 = @truncate((wparam >> 16) & 0xFFFF);
    return @bitCast(hi);
}

fn initDebugLog() void {
    const cwd = std.fs.cwd();
    g_log_file = cwd.openFile("lightboard-debug.log", .{ .mode = .write_only }) catch null;
    if (g_log_file) |file| {
        file.seekFromEnd(0) catch {};
    } else {
        g_log_file = cwd.createFile("lightboard-debug.log", .{ .truncate = false }) catch null;
    }

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
    const local_app_data = std.process.getEnvVarOwned(allocator, "LOCALAPPDATA") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            dbgLog("LOCALAPPDATA not found; persistence disabled", .{});
            g_history_path = &[_]u8{};
            return;
        },
        else => return err,
    };
    defer allocator.free(local_app_data);

    const data_dir = try std.fs.path.join(allocator, &[_][]const u8{ local_app_data, "lightboard" });
    defer allocator.free(data_dir);
    try std.fs.cwd().makePath(data_dir);

    g_history_path = try std.fs.path.join(allocator, &[_][]const u8{ data_dir, "history.bin" });
    dbgLog("persistence path: {s}", .{g_history_path});
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
    const ts = std.time.timestamp();
    const line = std.fmt.bufPrint(&line_buf, "[{d}] " ++ fmt ++ "\r\n", .{ts} ++ args) catch return;
    g_log_file.?.writeAll(line) catch {};
}
