const std = @import("std");

pub const ImageFormat = enum {
    dibv5,
    dib,
    bitmap,
};

pub const ImageMeta = struct {
    format: ImageFormat,
    data: []u8,
};

pub const Item = union(enum) {
    text: []u8,
    image: ImageMeta,
};

pub const Entry = struct {
    ts_unix: i64,
    item: Item,
};

pub const History = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    max_items: usize,

    pub fn init(max_items: usize) History {
        return .{ .max_items = max_items };
    }

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            switch (entry.item) {
                .text => |text| allocator.free(text),
                .image => |image| allocator.free(image.data),
            }
        }
        self.entries.deinit(allocator);
    }

    pub fn len(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn push(self: *History, allocator: std.mem.Allocator, entry: Entry) !void {
        if (self.entries.items.len > 0 and isDuplicate(self.entries.items[self.entries.items.len - 1], entry)) {
            switch (entry.item) {
                .text => |text| allocator.free(text),
                .image => |image| allocator.free(image.data),
            }
            return;
        }

        try self.entries.append(allocator, entry);
        while (self.entries.items.len > self.max_items) {
            const removed = self.entries.orderedRemove(0);
            switch (removed.item) {
                .text => |text| allocator.free(text),
                .image => |image| allocator.free(image.data),
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
                .image => |bi| ai.format == bi.format and std.mem.eql(u8, ai.data, bi.data),
                else => false,
            },
        };
    }
};

const file_magic = "LBRD1";

pub fn saveToFile(self: *const History, path: []const u8) !void {
    const cwd = std.fs.cwd();
    const file = try cwd.createFile(path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(file_magic);
    try writeIntLe(file, u32, @intCast(self.entries.items.len));

    for (self.entries.items) |entry| {
        try writeIntLe(file, i64, entry.ts_unix);
        switch (entry.item) {
            .text => |text| {
                try file.writeAll(&[_]u8{1});
                try writeIntLe(file, u32, @intCast(text.len));
                try file.writeAll(text);
            },
            .image => |image| {
                try file.writeAll(&[_]u8{2});
                try file.writeAll(&[_]u8{@intFromEnum(image.format)});
                try writeIntLe(file, u32, @intCast(image.data.len));
                try file.writeAll(image.data);
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
    if (file_size < file_magic.len + 4) return;

    const blob = try allocator.alloc(u8, file_size);
    defer allocator.free(blob);
    const bytes_read = try file.readAll(blob);
    if (bytes_read != file_size) return error.InvalidData;

    var stream = std.io.fixedBufferStream(blob);
    const reader = stream.reader();

    var magic_buf: [file_magic.len]u8 = undefined;
    _ = try reader.readAll(&magic_buf);
    if (!std.mem.eql(u8, &magic_buf, file_magic)) return error.InvalidData;

    const count = try reader.readInt(u32, .little);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ts_unix = try reader.readInt(i64, .little);
        const kind = try reader.readByte();

        if (kind == 1) {
            const len = try reader.readInt(u32, .little);
            const text = try allocator.alloc(u8, len);
            errdefer allocator.free(text);
            _ = try reader.readAll(text);
            try self.push(allocator, .{
                .ts_unix = ts_unix,
                .item = .{ .text = text },
            });
        } else if (kind == 2) {
            const fmt_byte = try reader.readByte();
            const len = try reader.readInt(u32, .little);
            const data = try allocator.alloc(u8, len);
            errdefer allocator.free(data);
            _ = try reader.readAll(data);
            const fmt: ImageFormat = switch (fmt_byte) {
                @intFromEnum(ImageFormat.dibv5) => .dibv5,
                @intFromEnum(ImageFormat.dib) => .dib,
                @intFromEnum(ImageFormat.bitmap) => .bitmap,
                else => .dib,
            };
            try self.push(allocator, .{
                .ts_unix = ts_unix,
                .item = .{ .image = .{ .format = fmt, .data = data } },
            });
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
