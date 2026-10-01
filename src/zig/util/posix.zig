//! Synchronous fd I/O for transports, using real Zig 0.16 OS bindings.
//! Linux bypasses libc cancellation wrappers; other POSIX hosts use std.c.
//! EINTR retries do not convert blocking descriptors into nonblocking ones.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

pub const PollFd = std.c.pollfd;
pub const Error = error{ Interrupted, WouldBlock, Io, UnexpectedEndOfStream, WriteZero };

fn errnoError(code: std.c.E) Error {
    return switch (code) {
        .INTR => error.Interrupted,
        .AGAIN => error.WouldBlock,
        else => error.Io,
    };
}

fn linuxResult(result: usize) Error!usize {
    const code = linux.errno(result);
    if (code == .SUCCESS) return result;
    // Mixed callers retain errno diagnostics; libc-free callers use the error.
    if (builtin.link_libc) std.c._errno().* = @intFromEnum(code);
    return errnoError(code);
}

/// One-shot native operations for cancellable callers. The convenience
/// read/write/poll functions below retry Interrupted using this same backend.
pub const System = struct {
    pub fn read(fd: c_int, buffer: []u8) Error!usize {
        if (builtin.os.tag == .linux) return linuxResult(linux.read(fd, buffer.ptr, buffer.len));
        const result = std.c.read(fd, buffer.ptr, buffer.len);
        if (result < 0) return errnoError(@enumFromInt(std.c._errno().*));
        return @intCast(result);
    }

    pub fn write(fd: c_int, bytes: []const u8) Error!usize {
        if (builtin.os.tag == .linux) return linuxResult(linux.write(fd, bytes.ptr, bytes.len));
        const result = std.c.write(fd, bytes.ptr, bytes.len);
        if (result < 0) return errnoError(@enumFromInt(std.c._errno().*));
        return @intCast(result);
    }

    pub fn poll(fds: []PollFd, timeout_ms: c_int) Error!usize {
        if (builtin.os.tag == .linux) return linuxResult(linux.poll(fds.ptr, fds.len, timeout_ms));
        const result = std.c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
        if (result < 0) return errnoError(@enumFromInt(std.c._errno().*));
        return @intCast(result);
    }
};

pub fn readWith(comptime Ops: type, fd: c_int, buffer: []u8) Error!usize {
    while (true) {
        return Ops.read(fd, buffer) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

pub fn writeWith(comptime Ops: type, fd: c_int, bytes: []const u8) Error!usize {
    while (true) {
        return Ops.write(fd, bytes) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

/// Like the existing serial loops, an interrupt restarts the supplied timeout.
/// Callers needing an absolute deadline must pass its remaining duration.
/// A readiness result still needs its revents inspected (HUP/ERR/NVAL).
pub fn pollWith(comptime Ops: type, fds: []PollFd, timeout_ms: c_int) Error!usize {
    while (true) {
        return Ops.poll(fds, timeout_ms) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

pub fn readExactWith(comptime Ops: type, fd: c_int, buffer: []u8) Error!void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const n = try readWith(Ops, fd, buffer[offset..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        offset += n;
    }
}

pub fn writeAllWith(comptime Ops: type, fd: c_int, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try writeWith(Ops, fd, bytes[offset..]);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

pub fn read(fd: c_int, buffer: []u8) Error!usize {
    return readWith(System, fd, buffer);
}

pub fn write(fd: c_int, bytes: []const u8) Error!usize {
    return writeWith(System, fd, bytes);
}

pub fn readExact(fd: c_int, buffer: []u8) Error!void {
    return readExactWith(System, fd, buffer);
}

pub fn writeAll(fd: c_int, bytes: []const u8) Error!void {
    return writeAllWith(System, fd, bytes);
}

pub fn poll(fds: []PollFd, timeout_ms: c_int) Error!usize {
    return pollWith(System, fds, timeout_ms);
}

test "fd helpers retry EINTR and advance after partial I/O" {
    const Fake = struct {
        var reads: usize = 0;
        var writes: usize = 0;
        var polls: usize = 0;
        var read_offset: usize = 0;
        var write_offset: usize = 0;
        var received: [6]u8 = undefined;

        pub fn read(_: c_int, buffer: []u8) Error!usize {
            reads += 1;
            if (reads == 1 or reads == 3) return error.Interrupted;
            const n = @min(buffer.len, 2);
            @memcpy(buffer[0..n], "abcdef"[read_offset..][0..n]);
            read_offset += n;
            return n;
        }
        pub fn write(_: c_int, bytes: []const u8) Error!usize {
            writes += 1;
            if (writes == 1 or writes == 3) return error.Interrupted;
            const n = @min(bytes.len, 2);
            @memcpy(received[write_offset..][0..n], bytes[0..n]);
            write_offset += n;
            return n;
        }
        pub fn poll(fds: []PollFd, timeout: c_int) Error!usize {
            std.debug.assert(timeout == 37);
            polls += 1;
            if (polls == 1) return error.Interrupted;
            fds[0].revents = 1;
            return 1;
        }
    };
    Fake.reads = 0;
    Fake.writes = 0;
    Fake.polls = 0;
    Fake.read_offset = 0;
    Fake.write_offset = 0;
    var bytes: [6]u8 = undefined;
    try readExactWith(Fake, 0, &bytes);
    try std.testing.expectEqualStrings("abcdef", &bytes);
    try writeAllWith(Fake, 1, "abcdef");
    try std.testing.expectEqualStrings("abcdef", &Fake.received);
    try std.testing.expectEqual(@as(usize, 5), Fake.reads);
    try std.testing.expectEqual(@as(usize, 5), Fake.writes);
    var fds = [_]PollFd{.{ .fd = 0, .events = 1, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try pollWith(Fake, &fds, 37));
    try std.testing.expectEqual(@as(c_short, 1), fds[0].revents);
    try std.testing.expectEqual(@as(usize, 2), Fake.polls);
}

test "fd helpers report EOF zero write would-block timeout and hard errors" {
    const Zero = struct {
        pub fn read(_: c_int, _: []u8) Error!usize {
            return 0;
        }
        pub fn write(_: c_int, _: []const u8) Error!usize {
            return 0;
        }
        pub fn poll(_: []PollFd, _: c_int) Error!usize {
            return 0;
        }
    };
    const Blocked = struct {
        pub fn read(_: c_int, _: []u8) Error!usize {
            return error.WouldBlock;
        }
        pub fn write(_: c_int, _: []const u8) Error!usize {
            return error.WouldBlock;
        }
        pub fn poll(_: []PollFd, _: c_int) Error!usize {
            return error.Io;
        }
    };
    var bytes: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try readWith(Zero, 0, &bytes));
    try std.testing.expectError(error.UnexpectedEndOfStream, readExactWith(Zero, 0, &bytes));
    try std.testing.expectError(error.WriteZero, writeAllWith(Zero, 1, "x"));
    try std.testing.expectError(error.WouldBlock, readWith(Blocked, 0, &bytes));
    try std.testing.expectError(error.WouldBlock, writeAllWith(Blocked, 1, "x"));
    try std.testing.expectEqual(@as(usize, 0), try pollWith(Zero, &.{}, 0));
    try std.testing.expectError(error.Io, pollWith(Blocked, &.{}, -1));
    std.c._errno().* = 0;
    try std.testing.expectError(error.Io, read(-1, &bytes));
    try std.testing.expectEqual(@intFromEnum(std.c.E.BADF), std.c._errno().*);
    std.c._errno().* = 0;
    try std.testing.expectError(error.Io, System.write(-1, "x"));
    try std.testing.expectEqual(@intFromEnum(std.c.E.BADF), std.c._errno().*);
    try std.testing.expectError(error.Io, writeAll(-1, "x"));
    if (builtin.os.tag == .linux) {
        const interrupted: isize = -@as(isize, @intFromEnum(std.c.E.INTR));
        try std.testing.expectError(error.Interrupted, linuxResult(@bitCast(interrupted)));
        try std.testing.expectEqual(@intFromEnum(std.c.E.INTR), std.c._errno().*);
    }
}

test "fd helpers exercise real pipe readiness nonblocking EOF and errno" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const c = @import("ipmi_c");
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    var write_open = true;
    defer if (write_open) {
        _ = c.close(fds[1]);
    };
    try writeAll(fds[1], "abcdef");
    var ready = [_]PollFd{.{ .fd = fds[0], .events = c.POLLIN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try poll(&ready, 0));
    try std.testing.expect(ready[0].revents & c.POLLIN != 0);
    var bytes: [6]u8 = undefined;
    std.c._errno().* = c.EACCES;
    try readExact(fds[0], &bytes);
    try std.testing.expectEqual(@as(c_int, c.EACCES), std.c._errno().*);
    try std.testing.expectEqualStrings("abcdef", &bytes);
    try std.testing.expectEqual(@as(usize, 0), try poll(&ready, 0));
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));
    try std.testing.expectError(error.WouldBlock, read(fds[0], &bytes));
    try std.testing.expectEqual(@as(c_int, c.EAGAIN), std.c._errno().*);
    try std.testing.expectEqual(@as(c_int, 0), c.close(fds[1]));
    write_open = false;
    try std.testing.expectEqual(@as(usize, 0), try read(fds[0], &bytes));
    try std.testing.expectError(error.UnexpectedEndOfStream, readExact(fds[0], &bytes));
}
