//! Integer compatibility profiles; callers supply byte classification explicitly.
const std = @import("std");

pub const Dialect = enum { gnu, zig_0_16 };
pub const Fault = enum { none, range };

pub fn dialectForTarget(target: std.Target) Dialect {
    return if (target.os.tag == .linux and target.abi.isMusl()) .zig_0_16 else .gnu;
}

pub fn Result(comptime T: type) type {
    return struct { value: T, end: usize, fault: Fault };
}

fn digit(byte: u8) ?u6 {
    if (byte >= '0' and byte <= '9') return @intCast(byte - '0');
    if (byte >= 'a' and byte <= 'z') return @intCast(byte - 'a' + 10);
    if (byte >= 'A' and byte <= 'Z') return @intCast(byte - 'A' + 10);
    return null;
}

pub fn scan(
    comptime T: type,
    comptime radix: u6,
    source: []const u8,
    dialect: Dialect,
    comptime isSpace: anytype,
) Result(T) {
    comptime {
        if (@typeInfo(T) != .int or (@bitSizeOf(T) != 32 and @bitSizeOf(T) != 64))
            @compileError("integer compatibility storage must be signed/unsigned 32 or 64 bits");
        if (radix == 1 or radix > 36)
            @compileError("integer compatibility radix must be zero or 2 through 36");
    }
    var pos: usize = 0;
    while (pos < source.len and source[pos] != 0 and isSpace(source[pos])) : (pos += 1) {}
    const negative = pos < source.len and source[pos] == '-';
    if (pos < source.len and (negative or source[pos] == '+')) pos += 1;
    var base: u6 = if (radix == 0) 10 else radix;
    var has_digit = false;
    if (pos < source.len and source[pos] == '0') {
        if (radix == 0) base = 8;
        const hex = (radix == 0 or radix == 16) and pos + 2 < source.len and
            (source[pos + 1] == 'x' or source[pos + 1] == 'X') and
            if (digit(source[pos + 2])) |d| d < 16 else false;
        if (hex) {
            pos += 2;
            base = 16;
        } else if (dialect == .zig_0_16) {
            pos += 1;
            has_digit = true;
        }
    }
    const signed = @typeInfo(T).int.signedness == .signed;
    const limit: u64 = if (signed)
        @as(u64, @intCast(std.math.maxInt(T))) + @intFromBool(negative)
    else
        std.math.maxInt(T);
    var magnitude: u64 = 0;
    var overflow = false;
    while (pos < source.len) {
        const value = digit(source[pos]) orelse break;
        if (value >= base) break;
        has_digit = true;
        pos += 1;
        if (!overflow) {
            if (magnitude > (limit - value) / base) {
                magnitude = limit;
                overflow = true;
                // The bundled Zig libc returns at the first overflowing digit.
                if (dialect == .zig_0_16) break;
            } else {
                magnitude = magnitude * base + value;
            }
        }
    }
    const value: T = if (overflow)
        if (signed and negative) std.math.minInt(T) else std.math.maxInt(T)
    else if (signed)
        if (negative and magnitude == @as(u64, @intCast(std.math.maxInt(T))) + 1)
            std.math.minInt(T)
        else if (negative)
            -@as(T, @intCast(magnitude))
        else
            @intCast(magnitude)
    else if (negative)
        0 -% @as(T, @intCast(magnitude))
    else
        @intCast(magnitude);
    return .{
        .value = value,
        .end = if (dialect == .gnu and !has_digit) 0 else pos,
        .fault = if (overflow) .range else .none,
    };
}
