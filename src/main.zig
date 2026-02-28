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
const MAX_VISIBLE_ROWS: usize = 4;
const LIST_TOP: c_int = 8;
const CARD_HEIGHT: c_int = 80;
const ROW_STEP: c_int = 84;

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

    if (registerHotkey()) {
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
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
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

fn registerHotkey() bool {
    const candidates = [_]struct {
        mods: w.UINT,
        vk: w.UINT,
        label: []const u8,
    }{
        .{ .mods = w.MOD_CONTROL | w.MOD_ALT, .vk = w.VK_B, .label = "Ctrl+Alt+B" },
        .{ .mods = w.MOD_WIN, .vk = w.VK_V, .label = "Win+V" },
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
        w.WM_HOTKEY => {
            if (wparam == HOTKEY_ID or wparam == HOTKEY_ID_F8) {
                dbgLog("WM_HOTKEY received id={d}", .{wparam});
                togglePicker();
                return 0;
            }
        },
        w.WM_CLIPBOARDUPDATE => {
            onClipboardUpdate();
            return 0;
        },
        w.WM_TIMER => {
            if (wparam == TARGET_TRACK_TIMER_ID) {
                trackForegroundTarget();
                pollHotkeyFallback();
                hideOnOutsideClick();
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
                if (hitTestEntryFromLParam(lparam)) |from_newest| {
                    g_selected_from_newest = from_newest;
                    ensureSelectionVisible();
                    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
                    pasteSelection();
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
    _ = w.SetForegroundWindow(g_picker_hwnd);
    dbgLog("picker shown by hotkey", .{});
}

fn handlePickerKey(key: w.UINT) void {
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
        else => {},
    }
}

fn handlePickerChar(ch: w.UINT) void {
    switch (ch) {
        'j', 'J' => moveSelection(1),
        'k', 'K' => moveSelection(-1),
        else => {},
    }
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
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
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

    const visible_rows = getVisibleRows();
    const selected = if (g_selected_from_newest < len) g_selected_from_newest else len - 1;
    const max_start = if (len > visible_rows) len - visible_rows else 0;
    const start_from_newest = @min(g_scroll_from_newest, max_start);
    g_scroll_from_newest = start_from_newest;

    var y: c_int = LIST_TOP;
    var row: usize = 0;
    while (row < visible_rows and (start_from_newest + row) < len) : (row += 1) {
        const from_newest = start_from_newest + row;
        const entry_idx = (len - 1) - from_newest;
        const is_selected = from_newest == selected;

        const row_rect = w.RECT{ .left = 12, .top = y, .right = rect.right - 20, .bottom = y + CARD_HEIGHT };
        const row_brush = w.CreateSolidBrush(if (is_selected) color_card_selected else color_card);
        if (row_brush != null) {
            _ = w.FillRect(hdc, &row_rect, row_brush);
            _ = w.DeleteObject(row_brush);
        }

        if (is_selected) {
            const bar_h: c_int = 20;
            const bar_top = y + @divTrunc(CARD_HEIGHT - bar_h, 2);
            const accent_rect = w.RECT{ .left = 12, .top = bar_top, .right = 15, .bottom = bar_top + bar_h };
            const accent_brush = w.CreateSolidBrush(color_accent);
            if (accent_brush != null) {
                _ = w.FillRect(hdc, &accent_rect, accent_brush);
                _ = w.DeleteObject(accent_brush);
            }
        }

        renderEntryLine(hdc, row_rect, g_history.entries.items[entry_idx], color_text_main, color_text_sub);
        y += ROW_STEP;
    }

    drawScrollbar(hdc, rect, len, start_from_newest, visible_rows);
}

fn renderEntryLine(hdc: w.HDC, rect: w.RECT, entry: history.Entry, color_text_main: w.COLORREF, color_text_sub: w.COLORREF) void {
    _ = color_text_sub;
    const text_x = rect.left + 14;
    const text_y = rect.top + 10;

    switch (entry.item) {
        .text => |text| {
            _ = w.SetTextColor(hdc, color_text_main);
            var lines: [3][120]u8 = [_][120]u8{[_]u8{0} ** 120} ** 3;
            const lens = wrapTextIntoLines(text, &lines, 3, 44);
            var li: usize = 0;
            while (li < lens.len) : (li += 1) {
                if (lens[li] == 0) break;
                drawUtf8Line(hdc, text_x, text_y + @as(c_int, @intCast(li * 20)), lines[li][0..lens[li]]);
            }
        },
        .image => |img| {
            const thumb_rect = w.RECT{
                .left = rect.left + 12,
                .top = rect.top + 8,
                .right = rect.right - 12,
                .bottom = rect.top + 72,
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
    var lengths: [3]usize = [_]usize{0} ** 3;
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
    const ctrl_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_CONTROL)));
    const alt_down = highBitSet(w.GetAsyncKeyState(@intCast(w.VK_MENU)));
    const b_state = w.GetAsyncKeyState(@intCast(w.VK_B));
    const b_pressed_since_last_poll = lowBitSet(b_state);

    if (ctrl_down and alt_down and b_pressed_since_last_poll) {
        dbgLog("fallback combo detected: Ctrl+Alt+B", .{});
        togglePicker();
    }

    const f8_state = w.GetAsyncKeyState(@intCast(w.VK_F8));
    if (lowBitSet(f8_state)) {
        dbgLog("fallback key detected: F8", .{});
        togglePicker();
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

    const y = getYFromLParam(lp);
    const list_top: i32 = LIST_TOP;
    const row_height: i32 = CARD_HEIGHT;
    const row_step: i32 = ROW_STEP;
    if (y < list_top) return null;

    const rel = y - list_top;
    const row = @divTrunc(rel, row_step);
    const visible_rows = getVisibleRows();
    if (row < 0 or row >= visible_rows) return null;
    if (@mod(rel, row_step) >= row_height) return null;

    const max_start = if (len > visible_rows) len - visible_rows else 0;
    const start_from_newest = @min(g_scroll_from_newest, max_start);
    const from_newest = start_from_newest + @as(usize, @intCast(row));
    if (from_newest >= len) return null;

    return from_newest;
}

fn getYFromLParam(lp: w.LPARAM) i32 {
    const raw: usize = @bitCast(lp);
    const y16: u16 = @truncate(raw >> 16);
    const y_i16: i16 = @bitCast(y16);
    return y_i16;
}

fn scrollBy(delta: i32) void {
    const len = g_history.len();
    const visible_rows = getVisibleRows();
    if (len <= visible_rows) return;
    const max_start: i32 = @intCast(len - visible_rows);
    var next: i32 = @intCast(g_scroll_from_newest);
    next += delta;
    if (next < 0) next = 0;
    if (next > max_start) next = max_start;
    g_scroll_from_newest = @intCast(next);
    _ = w.InvalidateRect(g_picker_hwnd, null, 1);
}

fn ensureSelectionVisible() void {
    const len = g_history.len();
    const visible_rows = getVisibleRows();
    if (len == 0) return;
    if (g_selected_from_newest < g_scroll_from_newest) {
        g_scroll_from_newest = g_selected_from_newest;
    } else if (g_selected_from_newest >= g_scroll_from_newest + visible_rows) {
        g_scroll_from_newest = g_selected_from_newest - visible_rows + 1;
    }
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

fn getVisibleRows() usize {
    if (g_picker_hwnd == null) return MAX_VISIBLE_ROWS;
    var rect: w.RECT = .{};
    if (w.GetClientRect(g_picker_hwnd, &rect) == 0) return MAX_VISIBLE_ROWS;

    const usable_h: i32 = (rect.bottom - rect.top) - LIST_TOP - 8;
    if (usable_h <= CARD_HEIGHT) return 1;
    const rows: i32 = @divTrunc(usable_h + (ROW_STEP - CARD_HEIGHT), ROW_STEP);
    if (rows <= 1) return 1;
    return @intCast(rows);
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
