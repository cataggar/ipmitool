const std = @import("std");
const c = @import("ipmi_c");

pub fn trySyncC() error{CStdoutFlushFailed}!void {
    if (c.fflush(c.stdout) != 0) return error.CStdoutFlushFailed;
}

pub fn syncC(context: []const u8) void {
    trySyncC() catch
        std.debug.panic("{s}: libc stdout flush failed: {d}", .{ context, std.c._errno().* });
}

pub fn write(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    try writer.print(format, args);
}

pub fn print(context: []const u8, comptime format: []const u8, args: anytype) void {
    syncC(context);
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    write(&stdout.interface, format, args) catch
        std.debug.panic("{s}: stdout write failed: {t}", .{ context, stdout.err orelse error.WriteFailed });
    stdout.interface.flush() catch
        std.debug.panic("{s}: stdout flush failed: {t}", .{ context, stdout.err orelse error.WriteFailed });
}

test "stdout formatting writes the version and propagates failures" {
    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try write(&writer, "{s} version {s}\n", .{ "ipmitool", "0.1.0" });
    try std.testing.expectEqualStrings("ipmitool version 0.1.0\n", writer.buffered());

    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, write(&failing, "Setting large buffer to {d}\n", .{@as(c_int, 256)}));
}
