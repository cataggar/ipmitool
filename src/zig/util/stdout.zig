const std = @import("std");
const c = @import("ipmi_c");
pub const printf_format = @import("printf.zig");

pub const Stream = enum { stdout, stderr };
pub const Error = error{ CStdoutFlushFailed, CStderrFlushFailed, WriteFailed, FlushFailed };

/// Command functions return -1 on failure; the CLI already maps that to exit 1.
/// Void legacy printers retain their fatal error policy instead of losing errors.
pub fn commandStatus(result: Error!void) c_int {
    result catch return -1;
    return 0;
}

pub const Mode = struct {
    csv: bool = false,
    verbose: c_int = 0,

    pub fn current() Mode {
        return .{ .csv = c.csv_output != 0, .verbose = c.verbose };
    }
};

/// Mirrors C's csv_output branch without changing either branch's argument types.
pub fn choice(
    writer: *std.Io.Writer,
    mode: Mode,
    comptime human: []const u8,
    human_args: anytype,
    comptime csv: []const u8,
    csv_args: anytype,
) std.Io.Writer.Error!void {
    if (mode.csv) {
        try printf(writer, csv, csv_args);
    } else {
        try printf(writer, human, human_args);
    }
}

pub fn verbose(
    writer: *std.Io.Writer,
    mode: Mode,
    minimum: c_int,
    comptime format: []const u8,
    args: anytype,
) std.Io.Writer.Error!void {
    if (mode.verbose >= minimum) try printf(writer, format, args);
}

/// Buffer storage belongs to the caller and must outlive this writer.
/// Never copy/move a Buffered after taking its interface pointer.
pub const Buffered = struct {
    file: std.Io.File.Writer,
    stream: Stream,

    pub fn init(stream: Stream, buffer: []u8) Buffered {
        const file = switch (stream) {
            .stdout => std.Io.File.stdout(),
            .stderr => std.Io.File.stderr(),
        };
        return .{ .file = file.writerStreaming(std.Options.debug_io, buffer), .stream = stream };
    }

    pub fn writer(self: *Buffered) *std.Io.Writer {
        return &self.file.interface;
    }

    pub fn begin(self: *Buffered) Error!Operation {
        return switch (self.stream) {
            .stdout => Operation.begin(self.writer(), trySyncC),
            .stderr => Operation.begin(self.writer(), trySyncCStderr),
        };
    }
};

/// A synchronous output phase, confined between C callbacks. finish is explicit
/// and checked; do not hide it in defer, which cannot propagate its error.
pub const Operation = struct {
    writer: *std.Io.Writer,

    pub fn begin(writer: *std.Io.Writer, preflush: anytype) Error!Operation {
        try preflush();
        return .{ .writer = writer };
    }

    pub fn bytes(self: Operation, text: []const u8) Error!void {
        self.writer.writeAll(text) catch return error.WriteFailed;
    }

    pub fn print(self: Operation, comptime format: []const u8, args: anytype) Error!void {
        write(self.writer, format, args) catch return error.WriteFailed;
    }

    pub fn printf(self: Operation, comptime format: []const u8, args: anytype) Error!void {
        printf_format.print(self.writer, format, args) catch return error.WriteFailed;
    }

    pub fn finish(self: Operation) Error!void {
        self.writer.flush() catch return error.FlushFailed;
    }
};

pub fn trySyncC() error{CStdoutFlushFailed}!void {
    if (c.fflush(c.stdout) != 0) return error.CStdoutFlushFailed;
}

pub fn trySyncCStderr() error{CStderrFlushFailed}!void {
    if (c.fflush(c.stderr) != 0) return error.CStderrFlushFailed;
}

pub fn syncC(context: []const u8) void {
    trySyncC() catch
        std.debug.panic("{s}: libc stdout flush failed: {d}", .{ context, std.c._errno().* });
}

pub fn write(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    try writer.print(format, args);
}

pub fn printf(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    try printf_format.print(writer, format, args);
}

pub fn print(context: []const u8, comptime format: []const u8, args: anytype) void {
    var storage: [4096]u8 = undefined;
    var stdout = Buffered.init(.stdout, &storage);
    const operation = stdout.begin() catch
        std.debug.panic("{s}: libc stdout flush failed: {d}", .{ context, std.c._errno().* });
    operation.print(format, args) catch
        std.debug.panic("{s}: stdout write failed: {t}", .{ context, stdout.file.err orelse error.WriteFailed });
    operation.finish() catch
        std.debug.panic("{s}: stdout flush failed: {t}", .{ context, stdout.file.err orelse error.WriteFailed });
}

test "buffered operation checks preflush writes final flush and status" {
    const Fake = struct {
        fn ok() error{CStdoutFlushFailed}!void {}
        fn bad() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn badStderr() error{CStderrFlushFailed}!void {
            return error.CStderrFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, Operation.begin(&writer, Fake.bad));
    try std.testing.expectError(error.CStderrFlushFailed, Operation.begin(&writer, Fake.badStderr));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    const operation = try Operation.begin(&writer, Fake.ok);
    try operation.printf("%02x %d", .{ @as(u8, 0x0f), @as(c_int, -3) });
    try std.testing.expectEqualStrings("0f -3", writer.buffered());
    try operation.finish();
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Fake.flushFail };
    try std.testing.expectError(error.FlushFailed, operation.finish());
    try std.testing.expectEqual(@as(c_int, -1), commandStatus(operation.finish()));
    var failing: std.Io.Writer = .failing;
    const failure = try Operation.begin(&failing, Fake.ok);
    try std.testing.expectError(error.WriteFailed, failure.bytes("x"));
    try std.testing.expectError(error.WriteFailed, failure.print("{s}", .{"x"}));
    try std.testing.expectError(error.WriteFailed, failure.printf("%s", .{"x"}));
    try std.testing.expectEqual(@as(c_int, 0), commandStatus({}));
}

test "csv and verbose helpers preserve C branch conventions" {
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try choice(&writer, .{}, "%-4d %-7s\n", .{ @as(c_int, 3), "name" }, "%d,%s\n", .{ @as(c_int, 3), "name" });
    try std.testing.expectEqualStrings("3    name   \n", writer.buffered());
    writer.end = 0;
    try choice(&writer, .{ .csv = true }, "%-4d %-7s\n", .{ @as(c_int, 3), "name" }, "%d,%s\n", .{ @as(c_int, 3), "name" });
    try verbose(&writer, .{}, 1, "hidden %d", .{@as(c_int, 1)});
    try verbose(&writer, .{ .verbose = 2 }, 2, "%02x\n", .{@as(u8, 15)});
    try std.testing.expectEqualStrings("3,name\n0f\n", writer.buffered());
}

test "buffered stdout and stderr flush at operation boundaries without reordering C" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    inline for (.{ Stream.stdout, Stream.stderr }) |stream| {
        const fd: c_int = if (stream == .stdout) 1 else 2;
        const c_stream = if (stream == .stdout) c.stdout else c.stderr;
        try std.testing.expectEqual(@as(c_int, 0), c.fflush(c_stream));
        const saved = c.dup(fd);
        try std.testing.expect(saved >= 0);
        defer _ = c.close(saved);
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
        defer _ = c.dup2(saved, fd);

        _ = c.fprintf(c_stream, "C-before|");
        var buffer: [64]u8 = undefined;
        var output = Buffered.init(stream, &buffer);
        const operation = try output.begin();
        try operation.printf("%02x|", .{@as(u8, 15)});
        try std.testing.expectEqualStrings("0f|", output.writer().buffered());
        try operation.finish();
        try std.testing.expectEqual(@as(usize, 0), output.writer().buffered().len);
        _ = c.fprintf(c_stream, "C-after\n");
        try std.testing.expectEqual(@as(c_int, 0), c.fflush(c_stream));
        try std.testing.expectEqual(fd, c.dup2(saved, fd));

        var captured: [64]u8 = undefined;
        const length = try @import("posix.zig").read(fds[0], &captured);
        try std.testing.expectEqualStrings("C-before|0f|C-after\n", captured[0..length]);
    }
}

test "buffered output surfaces delayed OS flush failures for both streams" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const full = c.open("/dev/full", c.O_WRONLY);
    try std.testing.expect(full >= 0);
    defer _ = c.close(full);
    inline for (.{ Stream.stdout, Stream.stderr }) |stream| {
        const fd: c_int = if (stream == .stdout) 1 else 2;
        const c_stream = if (stream == .stdout) c.stdout else c.stderr;
        try std.testing.expectEqual(@as(c_int, 0), c.fflush(c_stream));
        const saved = c.dup(fd);
        try std.testing.expect(saved >= 0);
        defer _ = c.close(saved);
        try std.testing.expectEqual(fd, c.dup2(full, fd));
        defer _ = c.dup2(saved, fd);
        defer c.clearerr(c_stream);

        var buffer: [64]u8 = undefined;
        var output = Buffered.init(stream, &buffer);
        const operation = try output.begin();
        try operation.printf("%02x", .{@as(u8, 15)});
        try std.testing.expectError(error.FlushFailed, operation.finish());
        try std.testing.expectEqual(@as(c_int, -1), commandStatus(operation.finish()));
        try std.testing.expect(output.file.err != null);
        try std.testing.expectEqual(fd, c.dup2(saved, fd));
    }
}

test "stdout formatting writes the version and propagates failures" {
    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try write(&writer, "{s} version {s}\n", .{ "ipmitool", "0.1.0" });
    try std.testing.expectEqualStrings("ipmitool version 0.1.0\n", writer.buffered());

    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, write(&failing, "Setting large buffer to {d}\n", .{@as(c_int, 256)}));
}
