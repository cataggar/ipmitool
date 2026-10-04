const std = @import("std");
const builtin = @import("builtin");
const parser = @import("float_parse");
const oracle = @import("float_oracle");
const c = @import("ipmi_c");

fn expectMatchesLibc(input: [*:0]const u8) !void {
    const expected = oracle.parse(input);
    const actual = parser.parse(std.mem.span(input), if (builtin.abi.isMusl()) .musl else .glibc);
    const err: c_int = if (actual.range) c.ERANGE else if (builtin.abi.isMusl() and actual.no_conversion) c.EINVAL else 0;
    errdefer std.debug.print("standalone float input: {s}\n", .{std.mem.span(input)});
    try std.testing.expectEqual(@as(u64, @bitCast(expected.value)), @as(u64, @bitCast(actual.value)));
    try std.testing.expectEqual(expected.end, actual.end);
    try std.testing.expectEqual(expected.err, err);
}

test "standalone target C and Zig agree on long-double representation" {
    try std.testing.expectEqual(@as(c_int, std.math.floatFractionalBits(c_longdouble) + 1), @as(c_int, c.LDBL_MANT_DIG));
    try std.testing.expectEqual(@as(c_int, std.math.floatExponentMax(c_longdouble) + 1), @as(c_int, c.LDBL_MAX_EXP));
}

test "standalone parser grammar and range match target libc" {
    const cases = [_][*:0]const u8{
        "",                         " ",          "-",                       "-0",                       "0x",                      "1e-",                     "1_2",                      "inf",                      "-nan(123)",
        "1e9999",                   "-1e-9999",   "0x1p1024",                "0x1p1102",                 "0x1p1106",                "0x1.fffffffffffff8p1023", "-0x1p-1075",               "-0x1p-1076",               "-0x1.00000000000000000000000000001p-1076",
        "-0x1.8p-1100",             "-0x1p-1152", "-0x1p-1153",              "-0x1p-1174",               "-0x1p-1175",              "-0x1p-1272",              "-0x1p-1273",               "-0x1p-2000",               "0x1.8p-1074",
        "0x0.fffffffffffff8p-1022", "0x1p-1074",  "2.4703282292062328e-324", "-2.4703282292062327e-324", "2.2250738585072013e-308", "2.2250738585072012e-308", "0x0.fffffffffffffbp-1022", "0x0.fffffffffffffcp-1022", "0x0.fffffffffffffdp-1022",
    };
    for (cases) |input| try expectMatchesLibc(input);
    for (0..256) |byte| {
        var first = [_:0]u8{ @intCast(byte), '1', '.', '2' };
        try expectMatchesLibc(&first);
        var exponent = [_:0]u8{ '1', 'e', @intCast(byte), '2' };
        try expectMatchesLibc(&exponent);
        var hex = [_:0]u8{ '0', 'x', @intCast(byte), '1' };
        try expectMatchesLibc(&hex);
    }
}

test "standalone exact normal-precision tininess boundary matches libc" {
    var mantissa: u64 = (@as(u64, 1) << 54) - 1;
    var digits: [800]u8 = undefined;
    var len: usize = 0;
    while (mantissa != 0) : (mantissa /= 10) {
        digits[len] = @intCast(mantissa % 10);
        len += 1;
    }
    for (0..1076) |_| {
        var carry: u32 = 0;
        for (digits[0..len]) |*d| {
            const product = @as(u32, d.*) * 5 + carry;
            d.* = @intCast(product % 10);
            carry = product / 10;
        }
        if (carry != 0) {
            digits[len] = @intCast(carry);
            len += 1;
        }
    }
    std.mem.reverse(u8, digits[0..len]);
    for (digits[0..len]) |*d| d.* += '0';
    const last = digits[len - 1];
    var buffer: [850]u8 = undefined;
    for ([_]u8{ last - 1, last, last + 1 }) |digit_byte| {
        digits[len - 1] = digit_byte;
        for ([_][]const u8{ "", "-" }) |sign| {
            const input = try std.fmt.bufPrintZ(&buffer, "{s}{s}e-1076", .{ sign, digits[0..len] });
            try expectMatchesLibc(input);
        }
    }
}

test "standalone target long-double cancellation boundaries match libc" {
    var digits: [3400]u8 = undefined;
    var buffer: [3450]u8 = undefined;
    const precision = std.math.floatFractionalBits(c_longdouble);
    for ([_]usize{ 1075, 1076, 1100, 1200, 1500, 1800, 2000, 3000, 3900, 4000, 4400 }) |power| {
        digits[0] = 1;
        var len: usize = 1;
        for (0..power) |_| {
            var carry: u32 = 0;
            for (digits[0..len]) |*d| {
                const product = @as(u32, d.*) * 5 + carry;
                d.* = @intCast(product % 10);
                carry = product / 10;
            }
            if (carry != 0) {
                digits[len] = @intCast(carry);
                len += 1;
            }
        }

        std.mem.reverse(u8, digits[0..len]);
        for (digits[0..len]) |*d| d.* += '0';
        for ([_]u8{ '4', '5', '6' }) |last| {
            digits[len - 1] = last;
            for ([_][]const u8{ "", "-" }) |sign| {
                const input = try std.fmt.bufPrintZ(&buffer, "{s}{s}e-{d}", .{ sign, digits[0..len], power });
                try expectMatchesLibc(input);
            }
        }
    }
    for ([_]usize{ precision - 1, precision, precision + 1 }) |distance| {
        var mantissa = (@as(u128, 1) << @as(u7, @intCast(distance))) + 1;
        var len: usize = 0;
        while (mantissa != 0) : (mantissa /= 10) {
            digits[len] = @intCast(mantissa % 10);
            len += 1;
        }
        const power = 1075 + distance;
        for (0..power) |_| {
            var carry: u32 = 0;
            for (digits[0..len]) |*d| {
                const product = @as(u32, d.*) * 5 + carry;
                d.* = @intCast(product % 10);
                carry = product / 10;
            }
            if (carry != 0) {
                digits[len] = @intCast(carry);
                len += 1;
            }
        }
        std.mem.reverse(u8, digits[0..len]);
        for (digits[0..len]) |*d| d.* += '0';
        for ([_][]const u8{ "", "-" }) |sign| {
            const input = try std.fmt.bufPrintZ(&buffer, "{s}{s}e-{d}", .{ sign, digits[0..len], power });
            try expectMatchesLibc(input);
        }
    }
}

test "standalone decimal and hex differential corpus" {
    var prng = std.Random.DefaultPrng.init(0x228_f64);
    const random = prng.random();
    var buffer: [192:0]u8 = undefined;
    for (0..4000) |iteration| {
        const hex = iteration & 1 != 0;
        const alphabet = if (hex) "0123456789abcdef" else "0123456789";
        var pos: usize = 0;
        if (random.boolean()) {
            buffer[pos] = '-';
            pos += 1;
        }
        if (hex) {
            @memcpy(buffer[pos..][0..2], "0x");
            pos += 2;
        }
        const count = random.intRangeAtMost(usize, 1, 120);
        const dot = random.intRangeAtMost(usize, 0, count);
        for (0..count) |i| {
            if (i == dot) {
                buffer[pos] = '.';
                pos += 1;
            }
            buffer[pos] = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
            pos += 1;
        }
        const exponent = random.intRangeAtMost(i32, if (hex) -1300 else -400, if (hex) 1150 else 350);
        const suffix = try std.fmt.bufPrintZ(buffer[pos..], "{c}{d}{s}", .{
            @as(u8, if (hex) 'p' else 'e'), exponent, if (iteration % 7 == 0) "x" else "",
        });
        try expectMatchesLibc(buffer[0 .. pos + suffix.len :0]);
    }
}
