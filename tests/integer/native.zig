const std = @import("std");
const scan = @import("integer_scan");

fn bits(value: anytype) u64 {
    return if (@typeInfo(@TypeOf(value)).int.signedness == .signed)
        @bitCast(@as(i64, value))
    else
        value;
}

fn checkRow(comptime T: type, base: u6, text: []const u8, dialect: scan.Dialect, expected: u64, end: usize, err: u8) !void {
    inline for (.{ 0, 2, 8, 10, 16, 36 }) |radix| {
        if (base == radix) {
            const actual = scan.scan(T, radix, text, dialect, std.ascii.isWhitespace);
            try std.testing.expectEqual(expected, bits(actual.value));
            try std.testing.expectEqual(end, actual.end);
            try std.testing.expectEqual(err, @as(u8, if (actual.fault == .range) 34 else 0));
            return;
        }
    }
    return error.InvalidFixtureBase;
}

fn checkFixture(comptime Signed: type, comptime Unsigned: type, dialect: scan.Dialect, fixture: []const u8) !void {
    var rows = std.mem.tokenizeScalar(u8, fixture, '\n');
    _ = rows.next() orelse return error.EmptyFixture;
    var count: usize = 0;
    while (rows.next()) |row| {
        var fields = std.mem.splitScalar(u8, row, '|');
        const kind = fields.next() orelse return error.InvalidFixture;
        const base = try std.fmt.parseInt(u6, fields.next().?, 10);
        const hex = fields.next().?;
        var input: [256]u8 = undefined;
        const text = try std.fmt.hexToBytes(&input, hex);
        const value = try std.fmt.parseInt(u64, fields.next().?, 16);
        const finish = fields.next().?;
        const err = try std.fmt.parseInt(u8, fields.next().?, 10);
        if (fields.next() != null) return error.InvalidFixture;
        if (std.mem.eql(u8, kind, "S")) {
            try checkRow(Signed, base, text, dialect, value, try std.fmt.parseInt(usize, finish, 10), err);
            count += 1;
        } else if (std.mem.eql(u8, kind, "U")) {
            try checkRow(Unsigned, base, text, dialect, value, try std.fmt.parseInt(usize, finish, 10), err);
            count += 1;
        } else if (!std.mem.eql(u8, kind, "H")) {
            return error.InvalidFixture;
        }
    }
    try std.testing.expectEqual(@as(usize, 624), count);
}

test "integer native frozen GNU64 C oracle" {
    try checkFixture(i64, u64, .gnu, @embedFile("gnu64.tsv"));
}

test "integer native frozen bundled-musl64 C oracle" {
    try checkFixture(i64, u64, .zig_0_16, @embedFile("musl64.tsv"));
}

test "integer native frozen actual ARM-musl32 C oracle" {
    try checkFixture(i32, u32, .zig_0_16, @embedFile("musl32.tsv"));
}

test "integer native signed unsigned 32/64 profiles and bounded ctype input" {
    inline for (.{ i32, i64, u32, u64 }) |T| {
        inline for (.{ scan.Dialect.gnu, scan.Dialect.zig_0_16 }) |dialect| {
            const zero = scan.scan(T, 10, " \t+", dialect, std.ascii.isWhitespace);
            try std.testing.expectEqual(@as(T, 0), zero.value);
            try std.testing.expectEqual(@as(usize, if (dialect == .gnu) 0 else 3), zero.end);
            const maximum = std.fmt.comptimePrint("{d}", .{std.math.maxInt(T)});
            try std.testing.expectEqual(std.math.maxInt(T), scan.scan(T, 10, maximum, dialect, std.ascii.isWhitespace).value);
            const overflow = std.fmt.comptimePrint("{d}999x", .{std.math.maxInt(T)});
            const result = scan.scan(T, 10, overflow, dialect, std.ascii.isWhitespace);
            try std.testing.expectEqual(scan.Fault.range, result.fault);
            try std.testing.expectEqual(@as(usize, if (dialect == .gnu) overflow.len - 1 else maximum.len + 1), result.end);
            if (@typeInfo(T).int.signedness == .signed) {
                const minimum = std.fmt.comptimePrint("{d}", .{std.math.minInt(T)});
                try std.testing.expectEqual(std.math.minInt(T), scan.scan(T, 10, minimum, dialect, std.ascii.isWhitespace).value);
            } else {
                try std.testing.expectEqual(std.math.maxInt(T), scan.scan(T, 10, "-1", dialect, std.ascii.isWhitespace).value);
            }
        }
    }
    const Classify = struct {
        fn space(byte: u8) bool {
            return std.ascii.isWhitespace(byte) or byte == 0xa0;
        }
    };
    inline for (.{ scan.Dialect.gnu, scan.Dialect.zig_0_16 }) |dialect| {
        const result = scan.scan(i64, 10, "\xa0-17tail", dialect, Classify.space);
        try std.testing.expectEqual(@as(i64, -17), result.value);
        try std.testing.expectEqual(@as(usize, 4), result.end);
    }
    try std.testing.expectEqual(@as(i32, 12), scan.scan(i32, 10, "12\x0034", .gnu, Classify.space).value);
    try std.testing.expectEqual(@as(usize, 0), scan.scan(i32, 10, &.{}, .zig_0_16, Classify.space).end);
}
