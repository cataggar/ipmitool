const std = @import("std");
const c = @import("ipmi_c");

const capacity: usize = @intCast(c.FD_SETSIZE);
const word_bits: usize = @bitSizeOf(c_ulong);
const word_count = capacity / word_bits;
const Words = [word_count]c_ulong;

comptime {
    if (capacity == 0 or capacity % word_bits != 0 or
        @sizeOf(c.fd_set) != capacity / 8 or
        @alignOf(c.fd_set) != @alignOf(c_ulong) or
        @sizeOf(c_long) != @sizeOf(c_ulong))
    {
        @compileError("unsupported libc fd_set size or alignment");
    }
    const info = @typeInfo(c.fd_set);
    if (info != .@"struct" or info.@"struct".layout != .@"extern")
        @compileError("libc fd_set must have an extern struct layout");
    const fields = info.@"struct".fields;
    if (fields.len != 1) @compileError("libc fd_set must have one word array");
    const field = fields[0];
    if ((field.type != [word_count]c_long and field.type != Words) or
        @offsetOf(c.fd_set, field.name) != 0 or
        @sizeOf(field.type) != @sizeOf(c.fd_set))
    {
        @compileError("unsupported libc fd_set word layout");
    }
}

fn words(fds: *c.fd_set) *Words {
    return @ptrCast(fds);
}

fn constWords(fds: *const c.fd_set) *const Words {
    return @ptrCast(fds);
}

pub fn valid(fd: c_int) bool {
    return fd >= 0 and fd < c.FD_SETSIZE;
}

pub fn zero(fds: *c.fd_set) void {
    @memset(words(fds), 0);
}

pub fn set(fd: c_int, fds: *c.fd_set) void {
    std.debug.assert(valid(fd));
    const bit: usize = @intCast(fd);
    words(fds).*[bit / word_bits] |= @as(c_ulong, 1) << @intCast(bit % word_bits);
}

pub fn isSet(fd: c_int, fds: *const c.fd_set) bool {
    std.debug.assert(valid(fd));
    const bit: usize = @intCast(fd);
    return (constWords(fds).*[bit / word_bits] & (@as(c_ulong, 1) << @intCast(bit % word_bits))) != 0;
}

extern fn ipmitool_test_fd_zero(*c.fd_set) void;
extern fn ipmitool_test_fd_set(c_int, *c.fd_set) void;
extern fn ipmitool_test_fd_isset(c_int, *const c.fd_set) c_int;
extern fn ipmitool_test_fd_size() usize;
extern fn ipmitool_test_fd_align() usize;

test "fd_set matches libc macros at word and capacity boundaries" {
    const descriptors = [_]c_int{
        0,
        @intCast(word_bits - 1),
        @intCast(word_bits),
        @intCast(word_bits + 1),
        @intCast(2 * word_bits - 1),
        @intCast(2 * word_bits),
        @intCast(capacity - word_bits - 1),
        @intCast(capacity - word_bits),
        c.FD_SETSIZE - 1,
    };
    try std.testing.expectEqual(@sizeOf(c.fd_set), ipmitool_test_fd_size());
    try std.testing.expectEqual(@alignOf(c.fd_set), ipmitool_test_fd_align());
    try std.testing.expect(!valid(-1));
    try std.testing.expect(!valid(c.FD_SETSIZE));

    var zig_fds: c.fd_set = undefined;
    var libc_fds: c.fd_set = undefined;
    zero(&zig_fds);
    ipmitool_test_fd_zero(&libc_fds);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&libc_fds), std.mem.asBytes(&zig_fds));
    for (descriptors) |fd| {
        try std.testing.expect(valid(fd));
        try std.testing.expect(!isSet(fd, &zig_fds));
        set(fd, &zig_fds);
        ipmitool_test_fd_set(fd, &libc_fds);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&libc_fds), std.mem.asBytes(&zig_fds));
        for (descriptors) |probe| {
            try std.testing.expectEqual(ipmitool_test_fd_isset(probe, &libc_fds) != 0, isSet(probe, &zig_fds));
        }
    }
    try std.testing.expect(!isSet(@intCast(word_bits + 2), &zig_fds));
    zero(&zig_fds);
    ipmitool_test_fd_zero(&libc_fds);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&libc_fds), std.mem.asBytes(&zig_fds));
    for (descriptors) |fd| try std.testing.expect(!isSet(fd, &zig_fds));
}
