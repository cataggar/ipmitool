const std = @import("std");

pub const capacity: usize = 1024;
const word_bits: usize = @bitSizeOf(c_ulong);
const word_count = capacity / word_bits;
const Words = [word_count]c_ulong;

pub const FdSet = extern struct {
    bits: Words,
};

fn compatible(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".layout != .@"extern") return false;
    if (@sizeOf(T) != capacity / 8 or @alignOf(T) != @alignOf(c_ulong)) return false;
    const fields = info.@"struct".fields;
    if (fields.len != 1) return false;
    const field = fields[0];
    return (field.type == [word_count]c_long or field.type == Words) and
        @offsetOf(T, field.name) == 0 and @sizeOf(field.type) == @sizeOf(T);
}

fn assertPointer(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("fd_set helpers require a single-item pointer");
    if (!compatible(info.pointer.child))
        @compileError("unsupported fd_set size, alignment or word layout");
}

fn words(fds: anytype) *Words {
    comptime assertPointer(@TypeOf(fds));
    return @ptrCast(fds);
}

fn constWords(fds: anytype) *const Words {
    comptime assertPointer(@TypeOf(fds));
    return @ptrCast(fds);
}

pub fn valid(fd: c_int) bool {
    return fd >= 0 and fd < capacity;
}

pub fn zero(fds: anytype) void {
    @memset(words(fds), 0);
}

pub fn set(fd: c_int, fds: anytype) void {
    std.debug.assert(valid(fd));
    const bit: usize = @intCast(fd);
    words(fds).*[bit / word_bits] |= @as(c_ulong, 1) << @intCast(bit % word_bits);
}

pub fn isSet(fd: c_int, fds: anytype) bool {
    std.debug.assert(valid(fd));
    const bit: usize = @intCast(fd);
    return (constWords(fds).*[bit / word_bits] & (@as(c_ulong, 1) << @intCast(bit % word_bits))) != 0;
}

extern fn ipmitool_test_fd_zero(*FdSet) void;
extern fn ipmitool_test_fd_set(c_int, *FdSet) void;
extern fn ipmitool_test_fd_isset(c_int, *const FdSet) c_int;
extern fn ipmitool_test_fd_size() usize;
extern fn ipmitool_test_fd_align() usize;

test "fd_set native storage and translated-compatible word arrays" {
    const SignedSet = extern struct {
        renamed_words: [word_count]c_long,
    };
    const WrongWords = extern struct {
        bits: [word_count * 2]c_uint,
    };
    const WrongCapacity = extern struct {
        bits: [word_count - 1]c_ulong,
    };
    const ExtraFields = extern struct {
        bits: Words,
        extra: c_ulong,
    };
    try std.testing.expect(compatible(FdSet));
    try std.testing.expect(compatible(SignedSet));
    try std.testing.expect(!compatible(WrongWords));
    try std.testing.expect(!compatible(WrongCapacity));
    try std.testing.expect(!compatible(ExtraFields));
    try std.testing.expect(!compatible(struct { bits: Words }));
    try std.testing.expect(!compatible(u128));
    try std.testing.expect(!valid(-1));
    try std.testing.expect(!valid(@intCast(capacity)));

    var native: FdSet = undefined;
    var signed: SignedSet = undefined;
    zero(&native);
    zero(&signed);
    for (0..capacity) |fd| {
        const descriptor: c_int = @intCast(fd);
        try std.testing.expect(!isSet(descriptor, &native));
        try std.testing.expect(!isSet(descriptor, &signed));
        set(descriptor, &native);
        set(descriptor, &signed);
        set(descriptor, &native);
        try std.testing.expect(isSet(descriptor, @as(*const FdSet, &native)));
        try std.testing.expect(isSet(descriptor, @as(*const SignedSet, &signed)));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&native), std.mem.asBytes(&signed));
    }
    try std.testing.expectEqual([_]c_ulong{~@as(c_ulong, 0)} ** word_count, native.bits);
    zero(&native);
    for (0..capacity) |fd| try std.testing.expect(!isSet(@intCast(fd), &native));
}

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
        @intCast(capacity - 1),
    };
    try std.testing.expectEqual(@sizeOf(FdSet), ipmitool_test_fd_size());
    try std.testing.expectEqual(@alignOf(FdSet), ipmitool_test_fd_align());
    try std.testing.expect(!valid(-1));
    try std.testing.expect(!valid(@intCast(capacity)));

    var zig_fds: FdSet = undefined;
    var libc_fds: FdSet = undefined;
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
