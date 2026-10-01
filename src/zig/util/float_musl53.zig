//! Binary64-long-double musl's hexadecimal and negative-underflow rounding.
//! The fixed base-1e9 ring and floating bias operations preserve its zero sign
//! and distant-tail behavior, including its smaller significand capacity.
//!
//! Derived from musl src/internal/floatscan.c, under the MIT license:
//!
//! Copyright (c) 2005-2020 Rich Felker, et al.
//!
//! Permission is hereby granted, free of charge, to any person obtaining
//! a copy of this software and associated documentation files (the
//! "Software"), to deal in the Software without restriction, including
//! without limitation the rights to use, copy, modify, merge, publish,
//! distribute, sublicense, and/or sell copies of the Software, and to
//! permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be
//! included in all copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
//! EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
//! MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
//! IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
//! CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
//! TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
//! SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

const std = @import("std");
const base: u32 = 1_000_000_000;
const mask = 127;

pub const Result = struct { value: f64, range: bool };

pub fn hexadecimal(digits: []const u8, integral_digits: usize, explicit_exponent: i128, negative: bool) Result {
    @setFloatMode(.strict);
    var head: u32 = 0;
    var fraction: f64 = 0;
    var scale: f64 = 1;
    var leading_zeros: usize = 0;
    var count: usize = 0;
    var tail = false;
    for (digits) |byte| {
        if (byte == '.') continue;
        const digit: u8 = if (byte <= '9') byte - '0' else (byte | 32) - 'a' + 10;
        if (count == 0 and digit == 0) {
            leading_zeros += 1;
            continue;
        }
        if (count < 8) {
            head = head * 16 + digit;
        } else if (count < 14) {
            scale /= 16;
            fraction += @as(f64, @floatFromInt(digit)) * scale;
        } else if (digit != 0 and !tail) {
            fraction += 0.5 * scale;
            tail = true;
        }
        count += 1;
    }
    for (@min(count, 8)..8) |_| head *= 16;
    const raw_exponent = explicit_exponent + 4 * (@as(i128, integral_digits) - leading_zeros) - 32;
    const sign: f64 = if (negative) -1 else 1;
    if (raw_exponent > 1074) return .{ .value = sign * std.math.inf(f64), .range = true };
    if (raw_exponent < -1180) return .{ .value = sign * 0.0, .range = true };
    var exponent: i32 = @intCast(raw_exponent);
    while (head < 0x8000_0000) {
        if (fraction >= 0.5) {
            head = head + head + 1;
            fraction = fraction + fraction - 1;
        } else {
            head += head;
            fraction += fraction;
        }
        exponent -= 1;
    }
    const bits = @max(0, @min(53, 32 + exponent + 1074));
    const bias = if (bits < 53) sign * std.math.scalbn(@as(f64, 1), 84 - bits) else 0;
    if (bits < 32 and fraction != 0 and head & 1 == 0) {
        head += 1;
        fraction = 0;
    }
    var value = bias + sign * @as(f64, @floatFromInt(head)) + sign * fraction;
    value -= bias;
    return .{ .value = std.math.scalbn(value, exponent), .range = value == 0 };
}

pub fn negativeUnderflow(digits: []const u8, point: i128) Result {
    @setFloatMode(.strict);
    if (point < -1180) return .{ .value = -0.0, .range = true };
    std.debug.assert(point <= -323);

    var words: [128]u32 = undefined;
    var end: usize = 0;
    var partial: usize = 0;
    for (digits) |byte| {
        if (byte == '.') continue;
        if (end < 125) {
            words[end] = if (partial == 0) byte - '0' else words[end] * 10 + byte - '0';
            partial += 1;
            if (partial == 9) {
                end += 1;
                partial = 0;
            }
        } else if (byte != '0') {
            words[124] |= 1;
        }
    }
    if (partial != 0) {
        for (partial..9) |_| words[end] *= 10;
        end += 1;
    }
    while (words[end - 1] == 0) end -= 1;

    var start: usize = 0;
    var radix: i32 = @intCast(point);
    var exponent: i32 = 0;
    const remainder = @mod(radix, 9);
    if (remainder != 0) {
        var divisor: u32 = 1;
        for (0..@as(usize, @intCast(9 - remainder))) |_| divisor *= 10;
        var carry: u32 = 0;
        for (0..end) |i| {
            const low = words[i] % divisor;
            words[i] = words[i] / divisor + carry;
            carry = base / divisor * low;
            if (i == start and words[i] == 0) {
                start = (start + 1) & mask;
                radix -= 9;
            }
        }
        if (carry != 0) {
            words[end] = carry;
            end += 1;
        }
        radix += 9 - remainder;
    }

    while (radix < 18 or (radix == 18 and words[start] < 9_007_199)) {
        var carry: u32 = 0;
        exponent -= 29;
        var i = (end + mask) & mask;
        while (true) : (i = (i + mask) & mask) {
            const product = (@as(u64, words[i]) << 29) + carry;
            if (product > base) {
                carry = @intCast(product / base);
                words[i] = @intCast(product % base);
            } else {
                carry = 0;
                words[i] = @intCast(product);
            }
            if (i == (end + mask) & mask and i != start and words[i] == 0) end = i;
            if (i == start) break;
        }
        if (carry != 0) {
            radix += 9;
            start = (start + mask) & mask;
            if (start == end) {
                end = (end + mask) & mask;
                words[(end + mask) & mask] |= words[end];
            }
            words[start] = carry;
        }
    }

    const threshold = [_]u32{ 9_007_199, 254_740_991 };
    while (true) {
        var below = true;
        for (threshold, 0..) |limit, offset| {
            const i = (start + offset) & mask;
            if (i == end or words[i] < limit) break;
            if (words[i] > limit) {
                below = false;
                break;
            }
        }
        if (below and radix == 18) break;
        const shift: u5 = if (radix > 27) 9 else 1;
        exponent += shift;
        var carry: u32 = 0;
        var i = start;
        while (i != end) : (i = (i + 1) & mask) {
            const low = words[i] & ((@as(u32, 1) << shift) - 1);
            words[i] = (words[i] >> shift) + carry;
            carry = (base >> shift) * low;
            if (i == start and words[i] == 0) {
                start = (start + 1) & mask;
                radix -= 9;
            }
        }
        if (carry != 0) {
            if ((end + 1) & mask != start) {
                words[end] = carry;
                end = (end + 1) & mask;
            } else {
                words[(end + mask) & mask] |= 1;
            }
        }
    }

    var value: f64 = 0;
    for (0..2) |offset| {
        const i = (start + offset) & mask;
        if (i == end) {
            words[end] = 0;
            end = (end + 1) & mask;
        }
        value = @as(f64, base) * value + @as(f64, @floatFromInt(words[i]));
    }
    value = -value;
    const bits = @max(0, @min(53, 53 + exponent + 1074));
    var denormal = bits < 53;
    const bias = -std.math.scalbn(@as(f64, 1), 105 - bits);
    const magnitude: u64 = @intFromFloat(-value);
    const fraction_mask = (@as(u64, 1) << @as(u6, @intCast(53 - bits))) - 1;
    var fraction = -@as(f64, @floatFromInt(magnitude & fraction_mask));
    value -= fraction;
    value += bias;
    const tail = (start + 2) & mask;
    if (tail != end) {
        const digit = words[tail];
        if (digit < 500_000_000 and (digit != 0 or (tail + 1) & mask != end))
            fraction -= 0.25
        else if (digit > 500_000_000)
            fraction -= 0.75
        else if (digit == 500_000_000)
            fraction -= if ((tail + 1) & mask == end) @as(f64, 0.5) else 0.75;
        const integer: i64 = @intFromFloat(fraction);
        if (53 - bits >= 2 and fraction == @as(f64, @floatFromInt(integer))) fraction += 1;
    }
    value += fraction;
    value -= bias;
    if (@abs(value) >= 0x1p53) {
        if (denormal and bits == 53 + exponent + 1074) denormal = false;
        value *= 0.5;
        exponent += 1;
    }
    return .{
        .value = std.math.scalbn(value, exponent),
        .range = denormal and fraction != 0,
    };
}
