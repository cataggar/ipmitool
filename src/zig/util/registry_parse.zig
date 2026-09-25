//! Header-free parsing for the IANA enterprise-number registry.

const std = @import("std");

/// Iterate lines as getline does, retaining newlines and the final partial line.
pub const Lines = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(it: *Lines) ?[]const u8 {
        if (it.pos >= it.text.len) return null;
        const start = it.pos;
        const end = if (std.mem.indexOfScalarPos(u8, it.text, start, '\n')) |nl|
            nl + 1
        else
            it.text.len;
        it.pos = end;
        return it.text[start..end];
    }
};

/// Mirror isdigit(line[0]) and strtol's saturation before uint32_t truncation.
pub fn leadingNumber(line: []const u8) ?u32 {
    if (line.len == 0 or !std.ascii.isDigit(line[0])) return null;

    var value: c_long = 0;
    var saturated = false;
    for (line) |ch| {
        if (!std.ascii.isDigit(ch)) break;
        if (saturated) continue;
        const digit: c_long = ch - '0';
        value = std.math.mul(c_long, value, 10) catch {
            saturated = true;
            continue;
        };
        value = std.math.add(c_long, value, digit) catch {
            saturated = true;
            continue;
        };
    }
    if (saturated) value = std.math.maxInt(c_long);
    return @truncate(@as(c_ulong, @bitCast(value)));
}

pub fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

/// Concatenate and truncate like snprintf("%s%s"), then NUL-terminate.
pub fn joinTruncating(buf: []u8, parts: []const []const u8) [:0]const u8 {
    var len: usize = 0;
    for (parts) |part| {
        const room = buf.len - 1 - len;
        const take = @min(room, part.len);
        @memcpy(buf[len..][0..take], part[0..take]);
        len += take;
        if (take < part.len) break;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

test "registry lines retain newlines, empty lines, and final partial input" {
    var lines: Lines = .{ .text = "42\r\n  Name\n\n7" };
    try std.testing.expectEqualStrings("42\r\n", lines.next().?);
    try std.testing.expectEqualStrings("  Name\n", lines.next().?);
    try std.testing.expectEqualStrings("\n", lines.next().?);
    try std.testing.expectEqualStrings("7", lines.next().?);
    try std.testing.expect(lines.next() == null);
    lines = .{ .text = "" };
    try std.testing.expect(lines.next() == null);
}

test "registry number parser saturates C long and truncates to uint32" {
    try std.testing.expectEqual(@as(?u32, 0), leadingNumber("0\n"));
    try std.testing.expectEqual(@as(?u32, 12), leadingNumber("0012 ignored"));
    try std.testing.expectEqual(@as(?u32, 123), leadingNumber("123a456"));
    const wide: u32 = if (@sizeOf(c_long) == 8) 0xffffffff else 0x7fffffff;
    try std.testing.expectEqual(@as(?u32, wide), leadingNumber("4294967295"));
    const saturated: u32 = @truncate(@as(c_ulong, std.math.maxInt(c_long)));
    try std.testing.expectEqual(@as(?u32, saturated), leadingNumber("999999999999999999999999999999"));
    for ([_][]const u8{ "", " 1", "\t1", "+1", "-1", "x1" }) |invalid|
        try std.testing.expect(leadingNumber(invalid) == null);
}

test "registry indentation counts only leading spaces" {
    try std.testing.expectEqual(@as(usize, 0), leadingSpaces(""));
    try std.testing.expectEqual(@as(usize, 0), leadingSpaces("\t  text"));
    try std.testing.expectEqual(@as(usize, 2), leadingSpaces("  text\n"));
    try std.testing.expectEqual(@as(usize, 3), leadingSpaces("   \ttext"));
}

test "registry paths truncate and NUL-terminate" {
    var buf: [6]u8 = undefined;
    try std.testing.expectEqualStrings("A/def", joinTruncating(&buf, &.{ "A", "/", "def" }));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
    try std.testing.expectEqualStrings("A/abc", joinTruncating(&buf, &.{ "A/", "abcdef", "unused" }));
    try std.testing.expectEqual(@as(u8, 0), buf[5]);
    var one: [1]u8 = undefined;
    try std.testing.expectEqualStrings("", joinTruncating(&one, &.{"input"}));
    try std.testing.expectEqual(@as(u8, 0), one[0]);
}
