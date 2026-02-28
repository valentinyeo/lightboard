const std = @import("std");
const w = @import("win32.zig");
const history = @import("history.zig");

const max_text_bytes: usize = 20 * 1024;
const max_image_bytes: usize = 8 * 1024 * 1024;

pub fn capture(allocator: std.mem.Allocator) !?history.Entry {
    if (w.OpenClipboard(null) == 0) return null;
    defer _ = w.CloseClipboard();

    if (w.IsClipboardFormatAvailable(w.CF_UNICODETEXT) != 0) {
        const maybe_text = try readUnicodeText(allocator);
        if (maybe_text) |text| {
            return history.Entry{
                .ts_unix = std.time.timestamp(),
                .item = .{ .text = text },
            };
        }
    }

    if (try readImage(allocator)) |image| {
        return history.Entry{
            .ts_unix = std.time.timestamp(),
            .item = .{ .image = image },
        };
    }

    return null;
}

pub fn restoreToClipboard(entry: history.Entry) !void {
    if (w.OpenClipboard(null) == 0) return error.OpenClipboardFailed;
    defer _ = w.CloseClipboard();

    if (w.EmptyClipboard() == 0) return error.EmptyClipboardFailed;

    switch (entry.item) {
        .text => |text| try setText(text),
        .image => |image| try setImage(image),
    }
}

pub fn sendCtrlV() void {
    var inputs = [_]w.INPUT{
        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = @intCast(w.VK_CONTROL) } } },
        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = @intCast(w.VK_V) } } },
        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = @intCast(w.VK_V), .dwFlags = w.KEYEVENTF_KEYUP } } },
        .{ .type = w.INPUT_KEYBOARD, .u = .{ .ki = .{ .wVk = @intCast(w.VK_CONTROL), .dwFlags = w.KEYEVENTF_KEYUP } } },
    };

    _ = w.SendInput(inputs.len, &inputs, @sizeOf(w.INPUT));
}

fn readImage(allocator: std.mem.Allocator) !?history.ImageMeta {
    const formats = [_]struct { format_id: w.UINT, kind: history.ImageFormat }{
        .{ .format_id = w.CF_DIBV5, .kind = .dibv5 },
        .{ .format_id = w.CF_DIB, .kind = .dib },
    };

    for (formats) |candidate| {
        if (w.IsClipboardFormatAvailable(candidate.format_id) == 0) continue;

        const handle = w.GetClipboardData(candidate.format_id);
        if (handle == null) continue;

        const raw_size = w.GlobalSize(handle);
        if (raw_size == 0 or raw_size > max_image_bytes) continue;

        const raw_ptr = w.GlobalLock(handle) orelse continue;
        defer _ = w.GlobalUnlock(handle);

        const src: [*]const u8 = @ptrCast(@alignCast(raw_ptr));
        const data = try allocator.alloc(u8, raw_size);
        @memcpy(data, src[0..raw_size]);

        return .{ .format = candidate.kind, .data = data };
    }

    return null;
}

fn readUnicodeText(allocator: std.mem.Allocator) !?[]u8 {
    const handle = w.GetClipboardData(w.CF_UNICODETEXT);
    if (handle == null) return null;

    const raw_ptr = w.GlobalLock(handle) orelse return null;
    defer _ = w.GlobalUnlock(handle);

    const byte_size = w.GlobalSize(handle);
    if (byte_size < 2) return null;

    const u16_len_cap = byte_size / 2;
    const wide: [*]const u16 = @ptrCast(@alignCast(raw_ptr));

    var len: usize = 0;
    while (len < u16_len_cap and wide[len] != 0) : (len += 1) {}
    if (len == 0) return null;

    var text = try std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..len]);
    if (text.len > max_text_bytes) {
        text = try allocator.realloc(text, max_text_bytes);
    }

    return text;
}

fn setText(text: []const u8) !void {
    const required_wchars = try std.unicode.calcUtf16LeLen(text);
    const total_wchars = required_wchars + 1;
    const total_bytes = total_wchars * @sizeOf(u16);

    const mem = w.GlobalAlloc(w.GMEM_MOVEABLE | w.GMEM_ZEROINIT, total_bytes) orelse return error.GlobalAllocFailed;
    const raw = w.GlobalLock(mem) orelse return error.GlobalLockFailed;
    defer _ = w.GlobalUnlock(mem);

    const dst: [*]u16 = @ptrCast(@alignCast(raw));
    const utf16_slice = dst[0..required_wchars];
    _ = try std.unicode.utf8ToUtf16Le(utf16_slice, text);
    dst[required_wchars] = 0;

    if (w.SetClipboardData(w.CF_UNICODETEXT, mem) == null) {
        return error.SetClipboardDataFailed;
    }
}

fn setImage(image: history.ImageMeta) !void {
    const mem = w.GlobalAlloc(w.GMEM_MOVEABLE, image.data.len) orelse return error.GlobalAllocFailed;
    const raw = w.GlobalLock(mem) orelse return error.GlobalLockFailed;
    defer _ = w.GlobalUnlock(mem);

    const dst: [*]u8 = @ptrCast(@alignCast(raw));
    @memcpy(dst[0..image.data.len], image.data);

    const format_id: w.UINT = switch (image.format) {
        .dibv5 => w.CF_DIBV5,
        .dib => w.CF_DIB,
        .bitmap => w.CF_DIB,
    };

    if (w.SetClipboardData(format_id, mem) == null) {
        return error.SetClipboardDataFailed;
    }
}
