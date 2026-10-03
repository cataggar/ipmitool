const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const fd_io = @import("fd_io");

comptime {
    if (builtin.os.tag != .linux or builtin.link_libc)
        @compileError("the actual-System probe requires Linux with link_libc=false");
}

fn checked(result: usize) !usize {
    const code = linux.errno(result);
    if (code == .SUCCESS) return result;
    std.debug.print("probe setup syscall failed: {t}\n", .{code});
    return error.ProbeSetupFailed;
}

const Pipe = struct {
    fds: [2]c_int,
    capacity: usize,

    fn init() !Pipe {
        var self: Pipe = undefined;
        _ = try checked(linux.pipe2(&self.fds, .{ .NONBLOCK = true, .CLOEXEC = true }));
        errdefer self.deinit();
        self.capacity = try checked(linux.fcntl(self.fds[1], linux.F.SETPIPE_SZ, 4096));
        try std.testing.expect(self.capacity >= 4096);
        return self;
    }

    fn deinit(self: Pipe) void {
        std.debug.assert(linux.errno(linux.close(self.fds[0])) == .SUCCESS);
        std.debug.assert(linux.errno(linux.close(self.fds[1])) == .SUCCESS);
    }

    fn block(self: Pipe, end: usize) !void {
        _ = try checked(linux.fcntl(self.fds[end], linux.F.SETFL, 0));
    }
};

fn partialIo() !void {
    const pipe = try Pipe.init();
    defer pipe.deinit();
    const allocator = std.heap.page_allocator;
    const payload = try allocator.alloc(u8, pipe.capacity + 1);
    defer allocator.free(payload);
    const received = try allocator.alloc(u8, payload.len);
    defer allocator.free(received);
    for (payload, 0..) |*byte, i| byte.* = @truncate(i);

    try std.testing.expectError(error.WouldBlock, fd_io.System.read(pipe.fds[0], received));
    try std.testing.expectError(error.WouldBlock, fd_io.readExact(pipe.fds[0], received));
    const written = try fd_io.System.write(pipe.fds[1], payload);
    try std.testing.expectEqual(pipe.capacity, written);
    try std.testing.expect(written < payload.len);
    try std.testing.expectError(error.WouldBlock, fd_io.System.write(pipe.fds[1], "x"));
    try std.testing.expectError(error.WouldBlock, fd_io.writeAll(pipe.fds[1], "x"));
    const got = try fd_io.System.read(pipe.fds[0], received);
    try std.testing.expectEqual(written, got);
    try std.testing.expect(got < received.len);
    try std.testing.expectEqualSlices(u8, payload[0..got], received[0..got]);

    // The all helper exposes WouldBlock after actual partial progress.
    try std.testing.expectError(error.WouldBlock, fd_io.writeAll(pipe.fds[1], payload));
    try std.testing.expectEqual(pipe.capacity, try fd_io.read(pipe.fds[0], received));
    try std.testing.expectEqualSlices(u8, payload[0..pipe.capacity], received[0..pipe.capacity]);
    try fd_io.writeAll(pipe.fds[1], "abcdef");
    var ready = [_]fd_io.PollFd{.{ .fd = pipe.fds[0], .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try fd_io.poll(&ready, 0));
    try std.testing.expect(ready[0].revents & linux.POLL.IN != 0);
    try fd_io.readExact(pipe.fds[0], received[0..6]);
    try std.testing.expectEqualStrings("abcdef", received[0..6]);
    try std.testing.expectEqual(@as(usize, 0), try fd_io.System.poll(&ready, 0));
}

fn errorsAndEof() !void {
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.read(-1, &byte, 1)));
    try std.testing.expectError(error.Io, fd_io.System.read(-1, &byte));
    try std.testing.expectError(error.Io, fd_io.read(-1, &byte));
    try std.testing.expectError(error.Io, fd_io.System.write(-1, "x"));
    try std.testing.expectError(error.Io, fd_io.writeAll(-1, "x"));
    var invalid = [_]fd_io.PollFd{.{ .fd = std.math.maxInt(c_int), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try fd_io.poll(&invalid, 0));
    try std.testing.expect(invalid[0].revents & linux.POLL.NVAL != 0);

    // Change only this probe process's soft limit to exercise a real poll EINVAL.
    var old_limit: linux.rlimit = undefined;
    _ = try checked(linux.getrlimit(.NOFILE, &old_limit));
    const limited: linux.rlimit = .{ .cur = @min(old_limit.cur, 32), .max = old_limit.max };
    _ = try checked(linux.setrlimit(.NOFILE, &limited));
    defer std.debug.assert(linux.errno(linux.setrlimit(.NOFILE, &old_limit)) == .SUCCESS);
    var too_many: [33]fd_io.PollFd = @splat(.{ .fd = -1, .events = 0, .revents = 0 });
    try std.testing.expectError(error.Io, fd_io.System.poll(&too_many, 0));
    try std.testing.expectError(error.Io, fd_io.poll(&too_many, 0));

    var fds: [2]c_int = undefined;
    _ = try checked(linux.pipe(&fds));
    defer std.debug.assert(linux.errno(linux.close(fds[0])) == .SUCCESS);
    _ = try checked(linux.close(fds[1]));
    try std.testing.expectEqual(@as(usize, 0), try fd_io.System.read(fds[0], &byte));
    try std.testing.expectError(error.UnexpectedEndOfStream, fd_io.readExact(fds[0], &byte));
}

var signal_count: std.atomic.Value(u32) = .init(0);

fn onSignal(_: linux.SIG) callconv(.c) void {
    _ = signal_count.fetchAdd(1, .monotonic);
}

const Kind = enum { read, write, poll };

fn sleepBriefly() void {
    var delay: linux.timespec = .{ .sec = 0, .nsec = 2_000_000 };
    var result = linux.nanosleep(&delay, &delay);
    while (linux.errno(result) == .INTR) result = linux.nanosleep(&delay, &delay);
    std.debug.assert(linux.errno(result) == .SUCCESS);
}

const Signaller = struct {
    pipe: Pipe,
    kind: Kind,
    tid: linux.pid_t,
    retry: bool,
    discard: []u8,
    started: std.atomic.Value(bool) = .init(false),
    stopped: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn release(self: *Signaller) void {
        switch (self.kind) {
            .read, .poll => {
                const n = fd_io.System.write(self.pipe.fds[1], "S") catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (n != 1) self.failed.store(true, .release);
            },
            .write => {
                const n = fd_io.System.read(self.pipe.fds[0], self.discard) catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (n != self.pipe.capacity) self.failed.store(true, .release);
            },
        }
    }

    fn run(self: *Signaller) void {
        while (!self.started.load(.acquire)) sleepBriefly();
        for (0..500) |i| {
            if (self.stopped.load(.acquire)) return;
            sleepBriefly();
            if (linux.errno(linux.tgkill(linux.getpid(), self.tid, .USR1)) != .SUCCESS) {
                self.failed.store(true, .release);
                self.release();
                return;
            }
            if (self.retry and i == 3) {
                sleepBriefly();
                self.release();
                return;
            }
        }
        // A failed interruption must wake the test and fail, not hang indefinitely.
        self.failed.store(true, .release);
        self.release();
    }
};

fn interrupted(kind: Kind, retry: bool) !void {
    const pipe = try Pipe.init();
    defer pipe.deinit();
    if (kind == .write) {
        const fill = try std.heap.page_allocator.alloc(u8, pipe.capacity);
        defer std.heap.page_allocator.free(fill);
        @memset(fill, 'F');
        try fd_io.writeAll(pipe.fds[1], fill);
        try pipe.block(1);
    } else {
        try pipe.block(0);
    }
    const before = signal_count.load(.monotonic);
    const discard = try std.heap.page_allocator.alloc(u8, pipe.capacity);
    defer std.heap.page_allocator.free(discard);
    var signaller: Signaller = .{
        .pipe = pipe,
        .kind = kind,
        .tid = linux.gettid(),
        .retry = retry,
        .discard = discard,
    };
    const thread = try std.Thread.spawn(.{}, Signaller.run, .{&signaller});
    var joined = false;
    defer {
        signaller.stopped.store(true, .release);
        if (!joined) thread.join();
    }
    signaller.started.store(true, .release);
    var byte: [1]u8 = undefined;
    var fds = [_]fd_io.PollFd{.{ .fd = pipe.fds[0], .events = linux.POLL.IN, .revents = 0 }};
    switch (kind) {
        .read => if (retry) {
            try std.testing.expectEqual(@as(usize, 1), try fd_io.read(pipe.fds[0], &byte));
            try std.testing.expectEqual(@as(u8, 'S'), byte[0]);
        } else {
            try std.testing.expectError(error.Interrupted, fd_io.System.read(pipe.fds[0], &byte));
        },
        .write => if (retry) {
            try std.testing.expectEqual(@as(usize, 1), try fd_io.write(pipe.fds[1], "W"));
        } else {
            try std.testing.expectError(error.Interrupted, fd_io.System.write(pipe.fds[1], "W"));
        },
        .poll => if (retry) {
            try std.testing.expectEqual(@as(usize, 1), try fd_io.poll(&fds, 1000));
            try std.testing.expect(fds[0].revents & linux.POLL.IN != 0);
        } else {
            try std.testing.expectError(error.Interrupted, fd_io.System.poll(&fds, 1000));
        },
    }
    signaller.stopped.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(!signaller.failed.load(.acquire));
    try std.testing.expect(signal_count.load(.monotonic) > before);
}

pub fn main() !void {
    try partialIo();
    try errorsAndEof();
    const action: linux.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    var previous: linux.Sigaction = undefined;
    _ = try checked(linux.sigaction(.USR1, &action, &previous));
    defer std.debug.assert(linux.errno(linux.sigaction(.USR1, &previous, null)) == .SUCCESS);
    var unblocked = std.mem.zeroes(linux.sigset_t);
    linux.sigaddset(&unblocked, .USR1);
    var old_mask: linux.sigset_t = undefined;
    _ = try checked(linux.sigprocmask(linux.SIG.UNBLOCK, &unblocked, &old_mask));
    defer std.debug.assert(linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &old_mask, null)) == .SUCCESS);
    inline for (.{ Kind.read, Kind.write, Kind.poll }) |kind| {
        try interrupted(kind, false);
        try interrupted(kind, true);
    }
    try fd_io.writeAll(1, "posix no-libc: actual partial I/O, errors, EOF and read/write/poll EINTR verified\n");
}
