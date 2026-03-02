const std = @import("std");
const w = @import("win32.zig");

var g_images_dir: []const u8 = "";
var g_next_file_id: i64 = 0;
var g_workspace: ?[]u8 = null;

const FORMAT: u16 = w.COMPRESSION_FORMAT_LZNT1;
const FORMAT_COMPRESS: u16 = FORMAT | w.COMPRESSION_ENGINE_STANDARD;

pub fn init(allocator: std.mem.Allocator, dir: []const u8) void {
    g_images_dir = dir;

    var ws_size: w.DWORD = 0;
    var frag_size: w.DWORD = 0;
    const status = w.RtlGetCompressionWorkSpaceSize(FORMAT_COMPRESS, &ws_size, &frag_size);
    if (status >= 0 and ws_size > 0) {
        g_workspace = allocator.alloc(u8, ws_size) catch null;
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    if (g_workspace) |ws| allocator.free(ws);
    g_workspace = null;
}

pub fn nextFileId() i64 {
    const ts = std.time.milliTimestamp();
    g_next_file_id = @max(g_next_file_id + 1, ts);
    return g_next_file_id;
}

/// Compress raw_data with LZNT1 and write to disk. Returns compressed size.
pub fn save(allocator: std.mem.Allocator, raw_data: []const u8, file_id: i64) !u32 {
    const ws = g_workspace orelse return error.NoWorkspace;

    // LZNT1 worst case: slight expansion possible
    const comp_buf_size: usize = raw_data.len + raw_data.len / 16 + 256;
    const comp_buf = try allocator.alloc(u8, comp_buf_size);
    defer allocator.free(comp_buf);

    var final_size: w.DWORD = 0;
    const status = w.RtlCompressBuffer(
        FORMAT_COMPRESS,
        raw_data.ptr,
        @intCast(raw_data.len),
        comp_buf.ptr,
        @intCast(comp_buf_size),
        4096, // chunk size for LZNT1
        &final_size,
        @ptrCast(ws.ptr),
    );
    if (status < 0) return error.CompressionFailed;

    // Write to file
    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.lz", .{file_id}) catch return error.NameTooLong;

    const cwd = std.fs.cwd();
    var dir = cwd.openDir(g_images_dir, .{}) catch |err| {
        // Try creating the directory first
        cwd.makePath(g_images_dir) catch return err;
        return save(allocator, raw_data, file_id); // retry once
    };
    defer dir.close();

    const file = try dir.createFile(name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(comp_buf[0..final_size]);

    return final_size;
}

/// Load and decompress image from disk. Caller must free returned slice.
pub fn load(allocator: std.mem.Allocator, file_id: i64, raw_size: u32) ![]u8 {
    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.lz", .{file_id}) catch return error.NameTooLong;

    var dir = try std.fs.cwd().openDir(g_images_dir, .{});
    defer dir.close();
    const file = try dir.openFile(name, .{});
    defer file.close();

    const stat = try file.stat();
    const comp_data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(comp_data);
    _ = try file.readAll(comp_data);

    const result = try allocator.alloc(u8, raw_size);
    errdefer allocator.free(result);

    var final_size: w.DWORD = 0;
    const status = w.RtlDecompressBuffer(
        FORMAT,
        result.ptr,
        raw_size,
        comp_data.ptr,
        @intCast(comp_data.len),
        &final_size,
    );
    if (status < 0) {
        allocator.free(result);
        return error.DecompressionFailed;
    }

    return result;
}

/// Delete image file from disk.
pub fn delete(file_id: i64) void {
    var name_buf: [80]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}.lz", .{file_id}) catch return;

    var dir = std.fs.cwd().openDir(g_images_dir, .{}) catch return;
    defer dir.close();
    dir.deleteFile(name) catch {};
}
