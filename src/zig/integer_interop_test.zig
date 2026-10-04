const std = @import("std");
const helper = @import("util/helper.zig");
const scan = helper.integers;
extern "c" fn integer_case_count() usize;
extern "c" fn integer_case_at(usize) [*:0]const u8;
extern "c" fn integer_long_bits() c_int;
extern "c" fn integer_space(u8) c_int;
extern "c" fn integer_set_locale([*:0]const u8) c_int;
extern "c" fn integer_locale() [*:0]const u8;
extern "c" fn integer_signed([*:0]const u8, c_int, c_int, *i64, *usize, *c_int) void;
extern "c" fn integer_unsigned([*:0]const u8, c_int, c_int, *u64, *usize, *c_int) void;
extern "c" fn integer_helper(?[*:0]const u8, c_int, c_int, *u64, *c_int, *c_int) void;

fn classify(byte: u8) bool {
    return if (helper.integer_dialect == .zig_0_16) std.ascii.isWhitespace(byte) else integer_space(byte) != 0;
}

fn compare(text: [*:0]const u8) !void {
    inline for (.{ 0, 2, 8, 10, 16, 36 }) |base| {
        inline for (.{ @as(c_int, 0), @intFromEnum(std.c.E.DOM) }) |seed| {
            var signed: i64 = undefined;
            var unsigned: u64 = undefined;
            var end: usize = undefined;
            var err: c_int = undefined;
            integer_signed(text, base, seed, &signed, &end, &err);
            const a = scan.scan(c_long, base, std.mem.span(text), helper.integer_dialect, classify);
            errdefer std.debug.print("integer signed base={d} input={s} expected={d}/{d}/{d} actual={d}/{d}/{t}\n", .{ base, text, signed, end, err, a.value, a.end, a.fault });
            try std.testing.expectEqual(signed, @as(i64, a.value));
            try std.testing.expectEqual(end, a.end);
            try std.testing.expectEqual(err, @as(c_int, if (a.fault == .range) @intFromEnum(std.c.E.RANGE) else seed));
            integer_unsigned(text, base, seed, &unsigned, &end, &err);
            const b = scan.scan(c_ulong, base, std.mem.span(text), helper.integer_dialect, classify);
            try std.testing.expectEqual(unsigned, @as(u64, b.value));
            try std.testing.expectEqual(end, b.end);
            try std.testing.expectEqual(err, @as(c_int, if (b.fault == .range) @intFromEnum(std.c.E.RANGE) else seed));
        }
    }
    inline for (.{ i64, u64, i32, u32, i16, u16, i8, u8 }, .{ helper.str2long, helper.str2ulong, helper.str2int, helper.str2uint, helper.str2short, helper.str2ushort, helper.str2char, helper.str2uchar }, 0..) |T, parse, which| {
        var expected: u64 = undefined;
        var status: c_int = undefined;
        var err: c_int = undefined;
        integer_helper(text, which, @intFromEnum(std.c.E.DOM), &expected, &status, &err);
        var actual: T = 42;
        std.c._errno().* = @intFromEnum(std.c.E.DOM);
        try std.testing.expectEqual(status, parse(text, &actual));
        const bits: u64 = if (@typeInfo(T).int.signedness == .signed) @bitCast(@as(i64, actual)) else actual;
        try std.testing.expectEqual(expected, bits);
        try std.testing.expectEqual(err, std.c._errno().*);
    }
}

test "integer compatibility actual C long grammar helper status out errno and all byte positions" {
    try std.testing.expectEqual(@as(c_int, @bitSizeOf(c_long)), integer_long_bits());
    var i: usize = 0;
    while (i < integer_case_count()) : (i += 1) try compare(integer_case_at(i));
    for (0..256) |byte| {
        var first = [_:0]u8{ @intCast(byte), '1', '2' };
        var sign = [_:0]u8{ '-', @intCast(byte), '7' };
        var zero = [_:0]u8{ '0', @intCast(byte), '7' };
        var prefix = [_:0]u8{ '0', 'x', @intCast(byte), '1' };
        try compare(&first);
        try compare(&sign);
        try compare(&zero);
        try compare(&prefix);
    }
}

test "integer compatibility installed LC_CTYPE and explicit classifier retain process locale" {
    var saved: [256:0]u8 = @splat(0);
    const original = std.mem.span(integer_locale());
    try std.testing.expect(original.len < saved.len);
    @memcpy(saved[0..original.len], original);
    defer std.debug.assert(integer_set_locale(&saved) != 0);
    var exercised: usize = 0;
    for ([_][*:0]const u8{ "C", "C.UTF-8", "C.utf8", "en_US.UTF-8", "de_DE.UTF-8", "fr_FR.ISO-8859-1" }) |locale| {
        if (integer_set_locale(locale) == 0) continue;
        exercised += 1;
        for (0..256) |byte| {
            var text = [_:0]u8{ @intCast(byte), '+', '1', '7' };
            try compare(&text);
        }
        std.debug.print("integer LC_CTYPE accepted: {s} (acceptance does not prove regional data)\n", .{integer_locale()});
    }
    try std.testing.expect(exercised > 0);
}

test "integer compatibility null arguments retain original out and errno" {
    inline for (.{ i64, u64, i32, u32, i16, u16, i8, u8 }, .{ helper.str2long, helper.str2ulong, helper.str2int, helper.str2uint, helper.str2short, helper.str2ushort, helper.str2char, helper.str2uchar }, 0..) |T, parse, which| {
        var expected: u64 = undefined;
        var status: c_int = undefined;
        var err: c_int = undefined;
        integer_helper(null, which, @intFromEnum(std.c.E.DOM), &expected, &status, &err);
        var out: T = 42;
        std.c._errno().* = @intFromEnum(std.c.E.DOM);
        try std.testing.expectEqual(status, parse(null, &out));
        try std.testing.expectEqual(@as(T, 42), out);
        try std.testing.expectEqual(err, std.c._errno().*);
        try std.testing.expectEqual(@as(c_int, -1), parse("1", null));
        try std.testing.expectEqual(err, std.c._errno().*);
    }
}
