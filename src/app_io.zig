const std = @import("std");
const w = @import("win32.zig");

pub var io: std.Io = std.Io.failing;

pub fn init(new_io: std.Io) void {
    io = new_io;
}

pub fn milliTimestamp() i64 {
    var file_time: w.FILETIME = undefined;
    w.GetSystemTimeAsFileTime(&file_time);

    const ticks = (@as(u64, file_time.dwHighDateTime) << 32) | @as(u64, file_time.dwLowDateTime);
    const windows_to_unix_100ns: u64 = 11_644_473_600 * 10_000_000;
    if (ticks <= windows_to_unix_100ns) return 0;
    return @intCast(@divTrunc(ticks - windows_to_unix_100ns, 10_000));
}

pub fn unixTimestamp() i64 {
    return @divTrunc(milliTimestamp(), 1000);
}
