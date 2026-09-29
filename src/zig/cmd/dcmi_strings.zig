const std = @import("std");

pub fn formatUnknown(buffer: []u8, value: u16) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buffer, "Unknown (0x{x})", .{value}, 0);
}
