const std = @import("std");
const app_io = @import("app_io.zig");
const img_store = @import("image_store.zig");

pub const ImageFormat = enum {
    dibv5,
    dib,
    bitmap,
};

pub const ImageMeta = struct {
    format: ImageFormat,
    file_id: i64,
    raw_size: u32,
    content_hash: u64 = 0,
};

pub const Item = union(enum) {
    text: []u8,
    image: ImageMeta,
};

pub const Entry = struct {
    ts_unix: i64,
    item: Item,
    sticky: bool = false,
};

pub const History = struct {
    entries: std.ArrayList(Entry) = .empty,
    max_items: usize,

    pub fn init(max_items: usize) History {
        return .{ .max_items = max_items };
    }

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            freeEntryData(allocator, entry);
        }
        self.entries.deinit(allocator);
    }

    pub fn len(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn push(self: *History, allocator: std.mem.Allocator, entry: Entry) !void {
        if (self.entries.items.len > 0 and isDuplicate(self.entries.items[self.entries.items.len - 1], entry)) {
            freeEntryData(allocator, entry);
            return;
        }

        try self.entries.append(allocator, entry);
        while (self.entries.items.len > self.max_items) {
            // Find first non-sticky entry from oldest end to evict
            var evict_idx: ?usize = null;
            for (self.entries.items, 0..) |e, ei| {
                if (!e.sticky) {
                    evict_idx = ei;
                    break;
                }
            }
            if (evict_idx) |idx| {
                const removed = self.entries.orderedRemove(idx);
                freeEntryData(allocator, removed);
            } else {
                // All entries are sticky — allow buffer to exceed max
                break;
            }
        }
    }

    pub fn removeAt(self: *History, allocator: std.mem.Allocator, idx: usize) void {
        if (idx >= self.entries.items.len) return;
        const removed = self.entries.orderedRemove(idx);
        freeEntryData(allocator, removed);
    }

    pub fn clearNonSticky(self: *History, allocator: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (!self.entries.items[i].sticky) {
                const removed = self.entries.orderedRemove(i);
                freeEntryData(allocator, removed);
            } else {
                i += 1;
            }
        }
    }

    fn isDuplicate(a: Entry, b: Entry) bool {
        return switch (a.item) {
            .text => |at| switch (b.item) {
                .text => |bt| std.mem.eql(u8, at, bt),
                else => false,
            },
            .image => |ai| switch (b.item) {
                .image => |bi| ai.raw_size == bi.raw_size and ai.content_hash != 0 and ai.content_hash == bi.content_hash,
                else => false,
            },
        };
    }
};

fn freeEntryData(allocator: std.mem.Allocator, entry: Entry) void {
    switch (entry.item) {
        .text => |text| allocator.free(text),
        .image => |image| img_store.delete(image.file_id),
    }
}

const file_magic_v1 = "LBRD1";
const file_magic_v2 = "LBRD2";
const file_magic_v3 = "LBRD3";
const file_magic_v4 = "LBRD4";
const file_magic = file_magic_v4;

pub fn hashImageData(data: []const u8) u64 {
    return std.hash.Wyhash.hash(0, data);
}

fn hashStoredImage(allocator: std.mem.Allocator, file_id: i64, raw_size: u32) u64 {
    const raw_data = img_store.load(allocator, file_id, raw_size) catch return 0;
    defer allocator.free(raw_data);
    return hashImageData(raw_data);
}

pub fn saveToFile(self: *const History, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(app_io.io, path, .{ .truncate = true });
    defer file.close(app_io.io);

    var offset: u64 = 0;
    try writeAllAt(file, &offset, file_magic);
    try writeIntLe(file, &offset, u32, @intCast(self.entries.items.len));

    for (self.entries.items) |entry| {
        try writeIntLe(file, &offset, i64, entry.ts_unix);
        const flags: u8 = if (entry.sticky) 1 else 0;
        try writeAllAt(file, &offset, &[_]u8{flags});
        switch (entry.item) {
            .text => |text| {
                try writeAllAt(file, &offset, &[_]u8{1});
                try writeIntLe(file, &offset, u32, @intCast(text.len));
                try writeAllAt(file, &offset, text);
            },
            .image => |image| {
                try writeAllAt(file, &offset, &[_]u8{2});
                try writeAllAt(file, &offset, &[_]u8{@intFromEnum(image.format)});
                try writeIntLe(file, &offset, i64, image.file_id);
                try writeIntLe(file, &offset, u32, image.raw_size);
                try writeIntLe(file, &offset, u64, image.content_hash);
            },
        }
    }
}

pub fn loadFromFile(self: *History, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(app_io.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(app_io.io);

    const stat = try file.stat(app_io.io);
    const file_size: usize = @intCast(stat.size);
    if (file_size < 5 + 4) return;

    const blob = try allocator.alloc(u8, file_size);
    defer allocator.free(blob);
    const bytes_read = try file.readPositionalAll(app_io.io, blob, 0);
    if (bytes_read != file_size) return error.InvalidData;

    var reader = BufferReader{ .data = blob };

    const magic_buf = try reader.readBytes(5);
    const is_v4 = std.mem.eql(u8, magic_buf, file_magic_v4);
    const is_v3 = std.mem.eql(u8, magic_buf, file_magic_v3);
    const is_v2 = std.mem.eql(u8, magic_buf, file_magic_v2);
    const is_v1 = std.mem.eql(u8, magic_buf, file_magic_v1);
    if (!is_v1 and !is_v2 and !is_v3 and !is_v4) return error.InvalidData;

    const count = try reader.readIntLe(u32);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ts_unix = try reader.readIntLe(i64);
        const sticky: bool = if (is_v1) false else (try reader.readByte()) & 1 != 0;
        const kind = try reader.readByte();

        if (kind == 1) {
            // Text entry; same layout across all versions.
            const text_len = try reader.readIntLe(u32);
            const text_bytes = try reader.readBytes(text_len);
            const text = try allocator.dupe(u8, text_bytes);
            try self.push(allocator, .{
                .ts_unix = ts_unix,
                .item = .{ .text = text },
                .sticky = sticky,
            });
        } else if (kind == 2) {
            const fmt_byte = try reader.readByte();
            const fmt: ImageFormat = switch (fmt_byte) {
                @intFromEnum(ImageFormat.dibv5) => .dibv5,
                @intFromEnum(ImageFormat.dib) => .dib,
                @intFromEnum(ImageFormat.bitmap) => .bitmap,
                else => .dib,
            };

            if (is_v3 or is_v4) {
                // V3/V4: metadata only (image data on disk). V4 also stores a content hash for duplicate suppression.
                const fid = try reader.readIntLe(i64);
                const raw_size = try reader.readIntLe(u32);
                const content_hash = if (is_v4) try reader.readIntLe(u64) else hashStoredImage(allocator, fid, raw_size);
                try self.push(allocator, .{
                    .ts_unix = ts_unix,
                    .item = .{ .image = .{ .format = fmt, .file_id = fid, .raw_size = raw_size, .content_hash = content_hash } },
                    .sticky = sticky,
                });
            } else {
                // V1/V2: inline image data; migrate to disk.
                const data_len = try reader.readIntLe(u32);
                const raw_data = try reader.readBytes(data_len);

                const file_id = img_store.nextFileId();
                _ = img_store.save(allocator, raw_data, file_id) catch {
                    continue; // skip image if compression/save fails
                };
                try self.push(allocator, .{
                    .ts_unix = ts_unix,
                    .item = .{ .image = .{ .format = fmt, .file_id = file_id, .raw_size = @intCast(data_len), .content_hash = hashImageData(raw_data) } },
                    .sticky = sticky,
                });
            }
        } else {
            return error.InvalidData;
        }
    }
}

const BufferReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readBytes(self: *BufferReader, len: usize) ![]const u8 {
        if (len > self.data.len - self.pos) return error.InvalidData;
        const out = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return out;
    }

    fn readByte(self: *BufferReader) !u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn readIntLe(self: *BufferReader, comptime T: type) !T {
        const bytes = try self.readBytes(@sizeOf(T));
        var buf: [@sizeOf(T)]u8 = undefined;
        @memcpy(&buf, bytes);
        return std.mem.readInt(T, &buf, .little);
    }
};

fn writeAllAt(file: std.Io.File, offset: *u64, bytes: []const u8) !void {
    try file.writePositionalAll(app_io.io, bytes, offset.*);
    offset.* += bytes.len;
}

fn writeIntLe(file: std.Io.File, offset: *u64, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try writeAllAt(file, offset, &buf);
}
