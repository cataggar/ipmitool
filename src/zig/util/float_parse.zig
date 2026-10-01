//! Allocation-free C-locale binary64 parsing, with the glibc/musl strtod dialects.
//! Only the explicitly scanned decimal grammar reaches std.fmt.parseFloat.

const std = @import("std");
const musl53 = @import("float_musl53.zig");

pub const Dialect = enum { glibc, musl };
pub const Result = struct {
    value: f64,
    end: usize,
    range: bool = false,
    no_conversion: bool = false,
    positive_zero: bool = false,
};

fn muslLongDouble() type {
    const fractional = std.math.floatFractionalBits(c_longdouble);
    const exponent = std.math.floatExponentBits(c_longdouble);
    if (fractional == 52 and exponent == 11) return f64;
    if (fractional == 63 and exponent == 15) return f80;
    if (fractional == 112 and exponent == 15) return f128;
    @compileError("unsupported musl long double: expected binary64, x87 extended80, or binary128");
}

fn digit(byte: u8, base: u8) ?u8 {
    const d: u8 = switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => return null,
    };
    return if (d < base) d else null;
}

fn hasDigit(source: []const u8, pos: usize, base: u8) bool {
    return pos < source.len and digit(source[pos], base) != null;
}

fn signed(value: f64, negative: bool) f64 {
    return if (negative) -value else value;
}

pub fn parse(source: []const u8, comptime dialect: Dialect) Result {
    return parseWithLongDouble(source, dialect, if (dialect == .musl) muslLongDouble() else f64);
}

fn parseWithLongDouble(source: []const u8, comptime dialect: Dialect, comptime Extended: type) Result {
    var pos: usize = 0;
    while (pos < source.len and std.ascii.isWhitespace(source[pos])) : (pos += 1) {}
    const negative = pos < source.len and source[pos] == '-';
    if (pos < source.len and (negative or source[pos] == '+')) pos += 1;

    if (std.ascii.startsWithIgnoreCase(source[pos..], "inf")) {
        pos += 3;
        if (std.ascii.startsWithIgnoreCase(source[pos..], "inity")) pos += 5;
        return .{ .value = signed(std.math.inf(f64), negative), .end = pos };
    }
    if (std.ascii.startsWithIgnoreCase(source[pos..], "nan")) {
        pos += 3;
        var payload: []const u8 = "";
        if (pos < source.len and source[pos] == '(') {
            var end = pos + 1;
            while (end < source.len and
                (std.ascii.isAlphanumeric(source[end]) or source[end] == '_')) : (end += 1)
            {}
            if (end < source.len and source[end] == ')') {
                payload = source[pos + 1 .. end];
                pos = end + 1;
            }
        }
        const bits: u64 = if (dialect == .musl)
            0x7ff8_0000_0000_0000
        else
            0x7ff8_0000_0000_0000 | nanPayload(payload) |
                (if (negative) @as(u64, 1) << 63 else 0);
        return .{ .value = @bitCast(bits), .end = pos };
    }

    var base: u8 = 10;
    if (pos + 2 <= source.len and source[pos] == '0' and
        (source[pos + 1] == 'x' or source[pos + 1] == 'X') and
        (hasDigit(source, pos + 2, 16) or
            (pos + 2 < source.len and source[pos + 2] == '.' and hasDigit(source, pos + 3, 16))))
    {
        base = 16;
        pos += 2;
    }
    const start = pos;
    while (hasDigit(source, pos, base)) : (pos += 1) {}
    const integral_digits = pos - start;
    var fractional_digits: usize = 0;
    if (pos < source.len and source[pos] == '.') {
        pos += 1;
        const fraction_start = pos;
        while (hasDigit(source, pos, base)) : (pos += 1) {}
        fractional_digits = pos - fraction_start;
    }
    if (integral_digits == 0 and fractional_digits == 0)
        return .{ .value = 0, .end = 0, .no_conversion = true };

    const mantissa_end = pos;
    var exponent: i128 = 0;
    const marker: u8 = if (base == 16) 'p' else 'e';
    if (pos < source.len and std.ascii.toLower(source[pos]) == marker) {
        var end = pos + 1;
        const exponent_negative = end < source.len and source[end] == '-';
        if (end < source.len and (exponent_negative or source[end] == '+')) end += 1;
        if (hasDigit(source, end, 10)) {
            // Larger than any addressable significand: saturation cannot lose
            // cancellation between the exponent and leading/trailing zeros.
            const limit = @as(i128, 1) << 80;
            while (hasDigit(source, end, 10)) : (end += 1)
                exponent = @min(limit, exponent * 10 + source[end] - '0');
            if (exponent_negative) exponent = -exponent;
            pos = end;
        }
    }

    var result = if (base == 16)
        hexadecimal(source[start..mantissa_end], integral_digits, exponent, negative, dialect, Extended)
    else
        decimal(source[start..mantissa_end], integral_digits, exponent, negative, dialect, Extended);
    if (!result.positive_zero) result.value = signed(result.value, negative);
    result.end = pos;
    return result;
}

fn nanPayload(payload: []const u8) u64 {
    if (payload.len == 0) return 0;
    var pos: usize = 0;
    var base: u8 = 10;
    if (payload[0] == '0') {
        base = 8;
        if (payload.len > 2 and (payload[1] == 'x' or payload[1] == 'X') and
            digit(payload[2], 16) != null)
        {
            base = 16;
            pos = 2;
        }
    }
    var value: u64 = 0;
    for (payload[pos..]) |byte| {
        const d = digit(byte, base) orelse return 0;
        value = if (value > (@as(u64, std.math.maxInt(u64)) - d) / base)
            std.math.maxInt(u64)
        else
            value * base + d;
    }
    return value & 0x000f_ffff_ffff_ffff;
}

fn hexadecimal(token: []const u8, integral_digits: usize, exponent: i128, negative: bool, comptime dialect: Dialect, comptime Extended: type) Result {
    var leading_zeros: usize = 0;
    var kept: usize = 0;
    var mantissa: u64 = 0;
    var tail = false;
    for (token) |byte| {
        if (byte == '.') continue;
        const d = digit(byte, 16).?;
        if (mantissa == 0 and d == 0) {
            leading_zeros += 1;
        } else if (kept < 16) {
            mantissa = mantissa * 16 + d;
            kept += 1;
        } else {
            tail = tail or d != 0;
        }
    }
    if (mantissa == 0) return .{ .value = 0, .end = 0 };
    if (dialect == .musl and Extended == f64) {
        const actual = musl53.hexadecimal(token, integral_digits, exponent, negative);
        return .{
            .value = @abs(actual.value),
            .end = 0,
            .range = actual.range,
            .positive_zero = @as(u64, @bitCast(actual.value)) == 0,
        };
    }

    const unit = exponent + 4 * (@as(i128, integral_digits) - leading_zeros - kept);
    var highest = unit + (63 - @clz(mantissa));
    // musl hexfloat narrows long double to double after its range check.
    const raw_unit = exponent + 4 * (@as(i128, integral_digits) - leading_zeros) - 32;
    const overflow = dialect == .glibc or raw_unit > 1074;
    if (highest > 1023) return .{ .value = std.math.inf(f64), .end = 0, .range = overflow };
    const output_unit = @max(-1074, highest - 52);
    const shift = output_unit - unit;
    var rounded: u64 = 0;
    var inexact = tail;
    if (shift > 64) {
        inexact = true;
    } else if (shift > 0) {
        const half = @as(u64, 1) << @as(u6, @intCast(shift - 1));
        const remainder = mantissa & (half | (half - 1));
        rounded = if (shift == 64) 0 else mantissa >> @as(u6, @intCast(shift));
        if (remainder > half or (remainder == half and (tail or rounded & 1 != 0)))
            rounded += 1;
        inexact = inexact or remainder != 0;
    } else {
        rounded = mantissa << @as(u6, @intCast(-shift));
    }

    const long_double_bits = std.math.floatFractionalBits(Extended) + 1;
    const early_underflow = raw_unit < -1074 - 2 * long_double_bits;
    // musl clamps negative precision to zero before narrowing. Below the
    // halfway-to-zero binade only exact powers of two cancel its rounding bias.
    const cancelled = rounded == 0 and !early_underflow and
        (highest >= -1075 or (std.math.isPowerOfTwo(mantissa) and !tail));
    const underflow = if (dialect == .glibc)
        highest < -1022 and inexact
    else
        early_underflow or cancelled;
    if (highest < -1022) return .{
        .value = @bitCast(rounded),
        .end = 0,
        .range = underflow,
        .positive_zero = dialect == .musl and cancelled,
    };
    if (rounded == @as(u64, 1) << 53) {
        rounded >>= 1;
        highest += 1;
    }
    if (highest > 1023) return .{ .value = std.math.inf(f64), .end = 0, .range = overflow };
    const bits = (@as(u64, @intCast(highest + 1023)) << 52) | (rounded & 0x000f_ffff_ffff_ffff);
    return .{ .value = @bitCast(bits), .end = 0 };
}

const Decimal = struct {
    // Binary64 rounding boundaries need at most 768 significant decimal digits.
    // One additional sticky digit preserves any nonzero tail, however distant.
    digits: [769]u8 = undefined,
    len: usize = 0,
    point: i128,
    truncated: bool = false,
    full_digits: []const u8 = "",

    fn scan(token: []const u8, integral_digits: usize, exponent: i128) Decimal {
        var result: Decimal = .{ .point = undefined };
        var leading_zeros: usize = 0;
        var count: usize = 0;
        var last_nonzero: usize = 0;
        for (token, 0..) |byte, index| {
            if (byte == '.') continue;
            if (count == 0 and byte == '0') {
                leading_zeros += 1;
                continue;
            }
            if (count < 768) result.digits[count] = byte;
            if (count == 0) result.full_digits = token[index..];
            count += 1;
            if (byte != '0') last_nonzero = count;
        }
        result.point = exponent + @as(i128, integral_digits) - leading_zeros;
        result.len = @min(last_nonzero, 768);
        if (last_nonzero > 768) {
            result.truncated = true;
            result.digits[768] = '1';
            result.len = 769;
        }
        return result;
    }

    fn equalsSubnormal(self: *const Decimal, bits: u64) bool {
        if (self.truncated) return false;
        const exponent = self.point - self.len;
        if (exponent < -1074 or exponent >= 0) return false;

        // Cancel the decimal denominator's powers of five in a fixed integer.
        // A nonzero remainder proves inexactness without approximating in f128.
        var limbs = [_]u32{0} ** 80;
        var used: usize = 1;
        for (self.digits[0..self.len]) |byte| {
            var carry: u64 = byte - '0';
            for (limbs[0..used]) |*limb| {
                const product = @as(u64, limb.*) * 10 + carry;
                limb.* = @truncate(product);
                carry = product >> 32;
            }
            if (carry != 0) {
                limbs[used] = @intCast(carry);
                used += 1;
            }
        }
        var remaining: usize = @intCast(-exponent);
        while (remaining != 0) {
            const chunk = @min(remaining, 13);
            var divisor: u32 = 1;
            for (0..chunk) |_| divisor *= 5;
            var carry: u64 = 0;
            var i = used;
            while (i != 0) {
                i -= 1;
                const numerator = (carry << 32) | limbs[i];
                limbs[i] = @intCast(numerator / divisor);
                carry = numerator % divisor;
            }
            if (carry != 0) return false;
            while (used > 1 and limbs[used - 1] == 0) used -= 1;
            remaining -= chunk;
        }
        if (used > 2) return false;
        const quotient = @as(u64, limbs[0]) | (@as(u64, limbs[1]) << 32);
        const shift = exponent + 1074;
        return shift < 53 and quotient <= bits >> @as(u6, @intCast(shift)) and
            quotient << @as(u6, @intCast(shift)) == bits;
    }

    fn belowPowerOfTwo(self: *const Decimal, power: usize) bool {
        const minimum = if (power == 1022)
            comptime powerOfTwoDecimal(1022)
        else
            powerOfTwoDecimal(power);
        if (self.point != minimum.point) return self.point < minimum.point;
        for (0..@max(self.len, minimum.len)) |i| {
            const a = if (i < self.len) self.digits[i] else '0';
            const b = if (i < minimum.len) minimum.digits[i] else '0';
            if (a != b) return a < b;
        }
        return false;
    }

    fn compareExact(self: *const Decimal, exact: *const ExactDecimal) std.math.Order {
        if (self.point != exact.point) return std.math.order(self.point, exact.point);
        var pos: usize = 0;
        var i: usize = 0;
        while (pos < self.full_digits.len or i < exact.len) : (i += 1) {
            if (pos < self.full_digits.len and self.full_digits[pos] == '.') pos += 1;
            const a = if (pos < self.full_digits.len) self.full_digits[pos] else '0';
            const b = if (i < exact.len) exact.digits[i] else '0';
            if (a != b) return std.math.order(a, b);
            if (pos < self.full_digits.len) pos += 1;
        }
        return .eq;
    }

    fn muslCancellation(self: *const Decimal, canonical: []const u8, comptime Extended: type) bool {
        const fractional_bits = std.math.floatFractionalBits(Extended);
        if (self.point < -1074 - 2 * (fractional_bits + 1)) return false;
        const Probe = Extended;
        const probe_fractional_bits = std.math.floatFractionalBits(Probe);
        const exponent_bits = std.math.floatExponentBits(Probe);
        const extended = std.fmt.parseFloat(Probe, canonical) catch |err| switch (err) {
            error.InvalidCharacter => unreachable,
        };
        const U = std.meta.Int(.unsigned, @bitSizeOf(Probe));
        const bits: U = @bitCast(extended);
        const fraction = bits & ((@as(U, 1) << probe_fractional_bits) - 1);
        if (fraction > @as(U, 1) << (probe_fractional_bits - fractional_bits)) return false;
        const exponent_shift = if (Probe == f80) probe_fractional_bits + 1 else probe_fractional_bits;
        const exponent_mask = (@as(U, 1) << exponent_bits) - 1;
        const biased = (bits >> exponent_shift) & exponent_mask;
        if (biased == 0 or biased == exponent_mask) return false;
        const bias = (@as(i32, 1) << (exponent_bits - 1)) - 1;
        const highest = @as(i32, @intCast(biased)) - bias;
        if (highest > -1075) return false;
        const power: usize = @intCast(-highest);
        const lower = ExactDecimal.fromBinary(1, power);
        if (self.compareExact(&lower) == .lt) return false;
        const upper = ExactDecimal.fromBinary((@as(u128, 1) << fractional_bits) + 1, power + fractional_bits);
        return self.compareExact(&upper) == .lt;
    }
};

const ExactDecimal = struct {
    // Covers musl's pre-ERANGE decimal window, including 113-bit long double.
    digits: [3400]u8 = undefined,
    len: usize = 0,
    point: i128,

    fn fromBinary(mantissa: u128, power: usize) ExactDecimal {
        var result: ExactDecimal = .{ .point = undefined };
        var m = mantissa;
        while (m != 0) : (m /= 10) {
            result.digits[result.len] = @intCast(m % 10);
            result.len += 1;
        }
        for (0..power) |_| {
            var carry: u32 = 0;
            for (result.digits[0..result.len]) |*d| {
                const product = @as(u32, d.*) * 5 + carry;
                d.* = @intCast(product % 10);
                carry = product / 10;
            }
            if (carry != 0) {
                result.digits[result.len] = @intCast(carry);
                result.len += 1;
            }
        }
        std.mem.reverse(u8, result.digits[0..result.len]);
        for (result.digits[0..result.len]) |*d| d.* += '0';
        result.point = @as(i128, result.len) - power;
        return result;
    }
};

fn powerOfTwoDecimal(power: usize) Decimal {
    @setEvalBranchQuota(4_000_000);
    var result: Decimal = .{ .point = undefined };
    result.digits = @splat(0);
    result.digits[0] = 1;
    result.len = 1;
    for (0..power) |_| {
        var carry: u32 = 0;
        for (result.digits[0..result.len]) |*d| {
            const product = @as(u32, d.*) * 5 + carry;
            d.* = @intCast(product % 10);
            carry = product / 10;
        }
        if (carry != 0) {
            result.digits[result.len] = @intCast(carry);
            result.len += 1;
        }
    }
    std.mem.reverse(u8, result.digits[0..result.len]);
    for (result.digits[0..result.len]) |*d| d.* += '0';
    result.point = @as(i128, result.len) - power;
    return result;
}

fn decimal(token: []const u8, integral_digits: usize, exponent: i128, negative: bool, comptime dialect: Dialect, comptime Extended: type) Result {
    const normalized = Decimal.scan(token, integral_digits, exponent);
    if (normalized.len == 0) return .{ .value = 0, .end = 0 };

    var buffer: [800]u8 = undefined;
    @memcpy(buffer[0..normalized.len], normalized.digits[0..normalized.len]);
    const suffix = std.fmt.bufPrint(buffer[normalized.len..], "e{d}", .{
        @min(10000, @max(-10000, normalized.point)) - normalized.len,
    }) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };
    const value = std.fmt.parseFloat(f64, buffer[0 .. normalized.len + suffix.len]) catch |err| switch (err) {
        error.InvalidCharacter => unreachable, // Canonical digits + complete exponent only.
    };
    const bits: u64 = @bitCast(value);
    if (dialect == .musl and Extended == f64 and negative and bits <= 1) {
        const actual = musl53.negativeUnderflow(normalized.full_digits, normalized.point);
        return .{
            .value = @abs(actual.value),
            .end = 0,
            .range = actual.range,
            .positive_zero = @as(u64, @bitCast(actual.value)) == 0,
        };
    }
    // musl's signed long-double bias can cancel a negative halfway prefix
    // before narrowing, even when a distant positive tail would round to -MIN.
    if (dialect == .musl and Extended != f64 and negative and bits <= 1 and
        normalized.muslCancellation(buffer[0 .. normalized.len + suffix.len], Extended))
        return .{ .value = 0, .end = 0, .range = true, .positive_zero = true };
    const range = if (std.math.isInf(value))
        true
    else if (bits == 0)
        true
    else if (bits < 0x0010_0000_0000_0000)
        !normalized.equalsSubnormal(bits) and
            !(dialect == .musl and std.math.isPowerOfTwo(bits) and
                normalized.belowPowerOfTwo(@as(usize, 1074) - @ctz(bits)))
    else if (dialect == .glibc and bits == 0x0010_0000_0000_0000)
        normalized.belowPowerOfTwo(1022)
    else
        false;
    return .{ .value = value, .end = 0, .range = range };
}

test "target musl long double selects its actual representation" {
    try std.testing.expectEqual(std.math.floatFractionalBits(c_longdouble), std.math.floatFractionalBits(muslLongDouble()));
    try std.testing.expectEqual(std.math.floatExponentBits(c_longdouble), std.math.floatExponentBits(muslLongDouble()));
}

test "injectable musl precisions preserve hex early-underflow and range behavior" {
    inline for (.{ f64, f80, f128 }) |Extended| {
        const limit = 1074 + 2 * (std.math.floatFractionalBits(Extended) + 1) - 28;
        var buffer: [32]u8 = undefined;
        const before = try std.fmt.bufPrint(&buffer, "-0x1p-{d}", .{limit});
        const cancelled = parseWithLongDouble(before, .musl, Extended);
        try std.testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(cancelled.value)));
        try std.testing.expect(cancelled.range);
        const after = try std.fmt.bufPrint(&buffer, "-0x1p-{d}", .{limit + 1});
        const early = parseWithLongDouble(after, .musl, Extended);
        try std.testing.expectEqual(@as(u64, 1) << 63, @as(u64, @bitCast(early.value)));
        try std.testing.expect(early.range);
        const exact = parseWithLongDouble("-0x1p-1074", .musl, Extended);
        try std.testing.expectEqual((@as(u64, 1) << 63) | 1, @as(u64, @bitCast(exact.value)));
        try std.testing.expect(!exact.range);
        try std.testing.expect(!parseWithLongDouble("0x1p1024", .musl, Extended).range);
        try std.testing.expect(parseWithLongDouble("0x1p1106", .musl, Extended).range);
    }
}

test "binary64 musl negative underflow matches ARM characterization" {
    const cases = .{
        .{ 1075, [_]u64{ 1 << 63, 0, 0 } },
        .{ 1200, [_]u64{ 1 << 63, 0, 0 } },
        .{ 1800, [_]u64{ 1 << 63, 1 << 63, 1 << 63 } },
        .{ 2000, [_]u64{ 0, 0, 0 } },
        .{ 3000, [_]u64{ 0, 0, 0 } },
        .{ 4000, [_]u64{ 1 << 63, 1 << 63, 1 << 63 } },
    };
    inline for (cases) |case| {
        var exact = ExactDecimal.fromBinary(1, case[0]);
        var buffer: [3450]u8 = undefined;
        for ([_]u8{ '4', '5', '6' }, case[1]) |last, bits| {
            exact.digits[exact.len - 1] = last;
            const input = try std.fmt.bufPrint(&buffer, "-{s}e-{d}", .{ exact.digits[0..exact.len], case[0] });
            const actual = parseWithLongDouble(input, .musl, f64);
            try std.testing.expectEqual(bits, @as(u64, @bitCast(actual.value)));
            try std.testing.expect(actual.range);
        }
    }
}

test "binary64 musl hex accumulation matches ARM characterization" {
    const input = "-0x17c297e49a6bd897f533c5.4ab2fd255660d24966ec6bae2dd0p57";
    const actual = parseWithLongDouble(input, .musl, f64);
    try std.testing.expectEqual(@as(u64, 14467746285582183384), @as(u64, @bitCast(actual.value)));
    try std.testing.expect(!actual.range);
}
