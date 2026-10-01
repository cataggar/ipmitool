const std = @import("std");
const printf = @import("printf");
const case = @import("case");

pub fn main() !void {
    var bytes: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    switch (case.scenario) {
        0 => try printf.print(&writer, case.format, .{@as(f64, 1.25)}),
        1 => try printf.print(&writer, case.format, .{ @as(c_uint, 8), "text" }),
        2 => try printf.print(&writer, case.format, .{@as(u64, 1)}),
        3 => try printf.print(&writer, case.format, .{}),
        else => unreachable,
    }
}
