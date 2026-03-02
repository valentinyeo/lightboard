const std = @import("std");
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
    entries: std.ArrayListUnmanaged(Entry) = .{},
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
            // Can't cheaply compare disk-stored images; skip dup check
            .image => false,
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
const file_magic = file_magic_v3;

pub fn saveToFile(self: *const History, path: []const u8) !void {
    const cwd = std.fs.cwd();
    const file = try cwd.createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(file_magic);
    try writeIntLe(file, u32, @intCast(self.entries.items.len));

    for (self.entries.items) |entry| {
        try writeIntLe(file, i64, entry.ts_unix);
        const flags: u8 = if (entry.sticky) 1 else 0;
        try file.writeAll(&[_]u8{flags});
        switch (entry.item) {
            .text => |text| {
                try file.writeAll(&[_]u8{1});
                try writeIntLe(file, u32, @intCast(text.len));
                try file.writeAll(text);
            },
            .image => |image| {
                try file.writeAll(&[_]u8{2});
                try file.writeAll(&[_]u8{@intFromEnum(image.format)});
                try writeIntLe(file, i64, image.file_id);
                try writeIntLe(file, u32, image.raw_size);
            },
        }
    }
}

pub fn loadFromFile(self: *History, allocator: std.mem.Allocator, path: []const u8) !void {
    const cwd = std.fs.cwd();
    const file = cwd.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(stat.size);
    if (file_size < 5 + 4) return;

    const blob = try allocator.alloc(u8, file_size);
    defer allocator.free(blob);
    const bytes_read = try file.readAll(blob);
    if (bytes_read != file_size) return error.InvalidData;

    var stream = std.io.fixedBufferStream(blob);
    const reader = stream.reader();

    var magic_buf: [5]u8 = undefined;
    _ = try reader.readAll(&magic_buf);
    const is_v3 = std.mem.eql(u8, &magic_buf, file_magic_v3);
    const is_v2 = std.mem.eql(u8, &magic_buf, file_magic_v2);
    const is_v1 = std.mem.eql(u8, &magic_buf, file_magic_v1);
    if (!is_v1 and !is_v2 and !is_v3) return error.InvalidData;

    const count = try reader.readInt(u32, .little);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ts_unix = try reader.readInt(i64, .little);
        const sticky: bool = if (is_v1) false else (try reader.readByte()) & 1 != 0;
        const kind = try reader.readByte();

        if (kind == 1) {
            // Text entry — same across all versions
            const text_len = try reader.readInt(u32, .little);
            const text = try allocator.alloc(u8, text_len);
            errdefer allocator.free(text);
            _ = try reader.readAll(text);
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

            if (is_v3) {
                // V3: metadata only (image data on disk)
                const fid = try reader.readInt(i64, .little);
                const raw_size = try reader.readInt(u32, .little);
                try self.push(allocator, .{
                    .ts_unix = ts_unix,
                    .item = .{ .image = .{ .format = fmt, .file_id = fid, .raw_size = raw_size } },
                    .sticky = sticky,
                });
            } else {
                // V1/V2: inline image data — migrate to disk
                const data_len = try reader.readInt(u32, .little);
                const raw_data = try allocator.alloc(u8, data_len);
                defer allocator.free(raw_data);
                _ = try reader.readAll(raw_data);

                const file_id = img_store.nextFileId();
                _ = img_store.save(allocator, raw_data, file_id) catch {
                    continue; // skip image if compression/save fails
                };
                try self.push(allocator, .{
                    .ts_unix = ts_unix,
                    .item = .{ .image = .{ .format = fmt, .file_id = file_id, .raw_size = @intCast(data_len) } },
                    .sticky = sticky,
                });
            }
        } else {
            return error.InvalidData;
        }
    }
}

fn writeIntLe(file: std.fs.File, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try file.writeAll(&buf);
}
