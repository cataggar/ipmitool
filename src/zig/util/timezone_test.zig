const std = @import("std");
const tz = @import("timezone.zig");
const testing = std.testing;
const allocator = testing.allocator;

fn expect(zone: *const tz.Zone, instant: i64, seconds: i32, dst: bool, name: []const u8) !void {
    const actual = zone.offsetAt(instant);
    try testing.expectEqual(seconds, actual.utc_offset_seconds);
    try testing.expectEqual(dst, actual.is_dst);
    try testing.expectEqualStrings(name, actual.abbreviation);
}

const Sample = struct { instant: i64, offset: i32, is_dst: bool, abbreviation: []const u8 };
const Fixture = struct {
    schema_version: u8,
    tzdata_version: []const u8,
    libc: []const u8,
    tzif: []const struct {
        name: []const u8,
        sha256: []const u8,
        bytes_hex: []const u8,
        leap_aware: bool = false,
        samples: []const Sample,
    },
    posix: []const struct { spec: []const u8, samples: []const Sample },
};

test "frozen timezone oracle retains its separately reviewed SHA256" {
    const bytes = @embedFile("testdata/timezone-libc.json");
    const checksum = std.mem.trimEnd(u8, @embedFile("testdata/timezone-libc.SHA256SUMS"), "\n");
    try testing.expectEqualStrings("timezone-libc.json", checksum[66..]);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    try testing.expectEqualStrings(checksum[0..64], &std.fmt.bytesToHex(digest, .lower));
}

test "independent frozen TZif and libc observations: history, gap, fold, future tails" {
    const fixture = try std.json.parseFromSlice(Fixture, allocator, @embedFile("testdata/timezone-libc.json"), .{});
    defer fixture.deinit();
    try testing.expectEqual(@as(u8, 1), fixture.value.schema_version);
    try testing.expectEqual(@as(usize, 9), fixture.value.tzif.len);
    try testing.expectEqual(@as(usize, 9), fixture.value.posix.len);
    var observations: usize = 0;
    for (fixture.value.tzif) |entry| {
        const bytes = try allocator.alloc(u8, entry.bytes_hex.len / 2);
        defer allocator.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, entry.bytes_hex);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        try testing.expectEqualStrings(entry.sha256, &std.fmt.bytesToHex(hash, .lower));
        var zone = try tz.Zone.fromTZif(allocator, bytes);
        defer zone.deinit();
        for (entry.samples) |sample| {
            errdefer std.debug.print("{s} at {d}\n", .{ entry.name, sample.instant });
            try expect(&zone, sample.instant, sample.offset, sample.is_dst, sample.abbreviation);
            observations += 1;
        }
    }
    for (fixture.value.posix) |entry| {
        var zone = try tz.Zone.fromPosix(allocator, entry.spec);
        defer zone.deinit();
        for (entry.samples) |sample| {
            errdefer std.debug.print("{s} at {d}\n", .{ entry.spec, sample.instant });
            try expect(&zone, sample.instant, sample.offset, sample.is_dst, sample.abbreviation);
            observations += 1;
        }
    }
    try testing.expectEqual(@as(usize, 7325), observations);
}

const Type = struct { offset: i32, dst: u8, name: u8 };
const Leap = struct { instant: i64, correction: i32 };
const Builder = struct {
    out: std.ArrayList(u8) = .empty,
    fn deinit(self: *Builder) void {
        self.out.deinit(allocator);
    }
    fn int(self: *Builder, comptime T: type, value: T) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .big);
        try self.out.appendSlice(allocator, &bytes);
    }
    fn block(self: *Builder, version: u8, width: u8, times: []const i64, indices: []const u8, types: []const Type, names: []const u8, leaps: []const Leap) !void {
        try self.out.appendSlice(allocator, "TZif");
        try self.out.append(allocator, version);
        try self.out.appendNTimes(allocator, 0, 15);
        try self.int(u32, 0);
        try self.int(u32, 0);
        try self.int(u32, @intCast(leaps.len));
        try self.int(u32, @intCast(times.len));
        try self.int(u32, @intCast(types.len));
        try self.int(u32, @intCast(names.len));
        for (times) |instant| {
            if (width == 4) try self.int(i32, @intCast(instant)) else try self.int(i64, instant);
        }
        try self.out.appendSlice(allocator, indices);
        for (types) |entry| {
            try self.int(i32, entry.offset);
            try self.out.appendSlice(allocator, &.{ entry.dst, entry.name });
        }
        try self.out.appendSlice(allocator, names);
        for (leaps) |entry| {
            if (width == 4) try self.int(i32, @intCast(entry.instant)) else try self.int(i64, entry.instant);
            try self.int(i32, entry.correction);
        }
    }
};

test "TZif v1 signed transitions and glibc pre-first non-DST selection" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{ -100, 100 }, &.{ 0, 1 }, &.{
        .{ .offset = 3600, .dst = 1, .name = 0 },
        .{ .offset = -1800, .dst = 0, .name = 4 },
    }, "DST\x00STD\x00", &.{});
    var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
    defer zone.deinit();
    try expect(&zone, -101, -1800, false, "STD");
    try expect(&zone, -100, 3600, true, "DST");
    try expect(&zone, 99, 3600, true, "DST");
    try expect(&zone, 100, -1800, false, "STD");
    try expect(&zone, std.math.maxInt(i64), -1800, false, "STD");
}

test "all-DST pre-first table, signed 64-bit v2/v3, empty future tail" {
    for ([_]u8{ '2', '3' }) |version| {
        var builder = Builder{};
        defer builder.deinit();
        try builder.block(version, 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
        try builder.block(version, 8, &.{ -5000000000, 5000000000 }, &.{ 1, 0 }, &.{
            .{ .offset = 3600, .dst = 1, .name = 0 },
            .{ .offset = 7200, .dst = 1, .name = 4 },
        }, "ONE\x00TWO\x00", &.{});
        try builder.out.appendSlice(allocator, "\n\n");
        var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
        defer zone.deinit();
        try expect(&zone, std.math.minInt(i64), 3600, true, "ONE");
        try expect(&zone, -5000000000, 7200, true, "TWO");
        try expect(&zone, 5000000000, 3600, true, "ONE");
    }
}

test "TZif leap-aware transitions normalize to POSIX instants" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{ 78796802, 94694402 }, &.{ 1, 0 }, &.{
        .{ .offset = 0, .dst = 0, .name = 0 },
        .{ .offset = 3600, .dst = 1, .name = 4 },
    }, "STD\x00DST\x00", &.{
        .{ .instant = 78796800, .correction = 1 },
        .{ .instant = 94694401, .correction = 2 },
    });
    var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
    defer zone.deinit();
    try expect(&zone, 78796800, 0, false, "STD");
    try expect(&zone, 78796801, 3600, true, "DST");
    try expect(&zone, 94694399, 3600, true, "DST");
    try expect(&zone, 94694400, 0, false, "STD");
}

test "owned POSIX input, fixed zones and injected default DST rules" {
    var text = [_]u8{ 'X', 'Y', 'Z', '5' };
    var zone = try tz.Zone.fromPosix(allocator, &text);
    defer zone.deinit();
    text[0] = 'A';
    try expect(&zone, 0, -18000, false, "XYZ");
    for ([_][]const u8{ "", "UTC", "UTC0", "GMT" }) |spec| {
        var fixed = try tz.Zone.fromPosix(allocator, spec);
        defer fixed.deinit();
        try expect(&fixed, std.math.minInt(i64), 0, false, if (std.mem.eql(u8, spec, "GMT")) "GMT" else "UTC");
    }
    try testing.expectError(error.MissingDstRules, tz.Zone.fromPosix(allocator, "EST5EDT"));
    const rules = (try tz.Posix.parse("EST5EDT,M3.2.0,M11.1.0", null)).daylight.?.rules;
    var injected = try tz.Zone.fromPosixWithRules(allocator, "EST5EDT", rules);
    defer injected.deinit();
    try expect(&injected, 1626350400, -14400, true, "EDT");
    var invalid = rules;
    invalid.start.day = .{ .month = .{ .month = 0, .week = 2, .weekday = 0 } };
    try testing.expectError(error.InvalidSpecification, tz.Zone.fromPosixWithRules(allocator, "EST5EDT", invalid));
    invalid = rules;
    invalid.end.seconds = std.math.minInt(i32);
    try testing.expectError(error.InvalidSpecification, tz.Zone.fromPosixWithRules(allocator, "EST5EDT", invalid));
}

test "spring gap and autumn fold are actual local timeline jumps, not fixed offsets" {
    var zone = try tz.Zone.fromPosix(allocator, "EST5EDT,M3.2.0/2,M11.1.0/2");
    defer zone.deinit();
    const spring_before = 1615705199 + @as(i64, zone.offsetAt(1615705199).utc_offset_seconds);
    const spring_after = 1615705200 + @as(i64, zone.offsetAt(1615705200).utc_offset_seconds);
    try testing.expectEqual(@as(i64, 3601), spring_after - spring_before);
    const fall_before = 1636264799 + @as(i64, zone.offsetAt(1636264799).utc_offset_seconds);
    const fall_after = 1636264800 + @as(i64, zone.offsetAt(1636264800).utc_offset_seconds);
    try testing.expectEqual(@as(i64, -3599), fall_after - fall_before);
}

test "M last weekday, J versus ordinal leap rules, negative DST and clock suffixes" {
    var julian = try tz.Zone.fromPosix(allocator, "STD0DST,J60/0,J300/0");
    defer julian.deinit();
    var ordinal = try tz.Zone.fromPosix(allocator, "STD0DST,59/0,300/0");
    defer ordinal.deinit();
    try expect(&julian, 1582934400, 0, false, "STD"); // 2020-02-29 UTC.
    try expect(&ordinal, 1582934400, 3600, true, "DST");
    try expect(&julian, 1583020800, 3600, true, "DST");
    for ([_][]const u8{ "u", "g", "z", "s", "w" }) |suffix| {
        const spec = try std.fmt.allocPrint(allocator, "STD-2DST-3,M3.2.0/2{s},M11.1.0/2{s}", .{ suffix, suffix });
        defer allocator.free(spec);
        var zone = try tz.Zone.fromPosix(allocator, spec);
        defer zone.deinit();
        const start: i64 = if (suffix[0] == 's' or suffix[0] == 'w') 1615680000 else 1615687200;
        const end: i64 = if (suffix[0] == 's') 1636243200 else if (suffix[0] == 'w') 1636239600 else 1636250400;
        try expect(&zone, start - 1, 7200, false, "STD");
        try expect(&zone, start, 10800, true, "DST");
        try expect(&zone, end - 1, 10800, true, "DST");
        try expect(&zone, end, 7200, false, "STD");
    }
    var negative = try tz.Zone.fromPosix(allocator, "IST-1GMT0,M10.5.0,M3.5.0/1");
    defer negative.deinit();
    try expect(&negative, 1610712000, 0, true, "GMT");
    try expect(&negative, 1626350400, 3600, false, "IST");
}

test "POSIX signed/out-of-day transition clocks and full signed timestamp domain" {
    var zone = try tz.Zone.fromPosix(allocator, "STD0DST,M3.2.0/-2,M11.1.0/26");
    defer zone.deinit();
    try expect(&zone, 1615672799, 0, false, "STD"); // 2021-03-13 22:00 UTC.
    try expect(&zone, 1615672800, 3600, true, "DST");
    try expect(&zone, 1636333199, 3600, true, "DST"); // 2021-11-08 01:00 UTC.
    try expect(&zone, 1636333200, 0, false, "STD");
    _ = zone.offsetAt(std.math.minInt(i64));
    _ = zone.offsetAt(std.math.maxInt(i64));
}

test "glibc POSIX UTC-year boundary and pre-1970 semantics remain explicit" {
    var zone = try tz.Zone.fromPosix(allocator, "EST5EDT,0/0,J365/25");
    defer zone.deinit();
    try expect(&zone, -15854400, -18000, false, "EST"); // 1969-07-01 12:00 UTC.
    try expect(&zone, 1609459199, -14400, true, "EDT");
    try expect(&zone, 1609459200, -18000, false, "EST");
    try expect(&zone, 1609477199, -18000, false, "EST");
    try expect(&zone, 1609477200, -14400, true, "EDT");
}

test "malformed POSIX specifications return explicit errors" {
    for ([_][]const u8{
        "A0",                     "<AB>0",                  "UTC25",                  "UTC0:60",                "UTC0:0:60",                            "UTC0x",
        "STD0DST,M0.1.0,M11.1.0", "STD0DST,M3.0.0,M11.1.0", "STD0DST,M3.6.0,M11.1.0", "STD0DST,M3.2.7,M11.1.0", "STD0DST,J0,J300",                      "STD0DST,366,300",
        "STD0DST,59/168,300",     "STD0DST,59/2q,300",      "STD0DST,59",             "STD0DST,59,300extra",    "STD0DST,59/999999999999999999999,300", "UTC0\x00",
    }) |spec| try testing.expectError(error.InvalidSpecification, tz.Zone.fromPosix(allocator, spec));
}

test "bounded TZif truncation, counts, indices, strings and sorting rejection" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{ 0, 100 }, &.{ 0, 0 }, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    for (0..builder.out.items.len) |size| try testing.expectError(error.Truncated, tz.Zone.fromTZif(allocator, builder.out.items[0..size]));
    const original = try allocator.dupe(u8, builder.out.items);
    defer allocator.free(original);
    builder.out.items[0] = 'X';
    try testing.expectError(error.InvalidMagic, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[4] = '4';
    try testing.expectError(error.UnsupportedVersion, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[32] = 0xff; // Huge transition count.
    try testing.expectError(error.InvalidCounts, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[52] = 1; // Transition index, one type only.
    try testing.expectError(error.InvalidType, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[58] = 2; // isdst.
    try testing.expectError(error.InvalidType, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[59] = 4; // Abbreviation at the end, not within it.
    try testing.expectError(error.InvalidAbbreviation, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    builder.out.items[63] = 'X';
    try testing.expectError(error.InvalidAbbreviation, tz.Zone.fromTZif(allocator, builder.out.items));
    @memcpy(builder.out.items, original);
    @memset(builder.out.items[48..52], 0);
    try testing.expectError(error.InvalidTransition, tz.Zone.fromTZif(allocator, builder.out.items));
}

test "std.Io file loading owns bytes and propagates missing file errors" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "zone", .data = builder.out.items });
    var zone = try tz.Zone.loadFile(allocator, testing.io, tmp.dir, "zone");
    defer zone.deinit();
    try expect(&zone, 0, 0, false, "UTC");
    try testing.expectError(error.FileNotFound, tz.Zone.loadFile(allocator, testing.io, tmp.dir, "missing"));
}

test "v2/v3 skipped compatibility block, empty-table libc behavior and invalid footers" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block('3', 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    const second = builder.out.items.len;
    // A reader must not use the obsolete 32-bit block's data.
    builder.out.items[44] = 0xff;
    try builder.block('3', 8, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "STD\x00", &.{});
    const tail = builder.out.items.len;
    try builder.out.appendSlice(allocator, "\nSTD0DST,M3.2.0,M11.1.0\n");
    var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
    defer zone.deinit();
    try expect(&zone, 1626350400, 0, false, "STD");
    for (second..tail) |size| try testing.expectError(error.Truncated, tz.Zone.fromTZif(allocator, builder.out.items[0..size]));
    try testing.expectError(error.InvalidTail, tz.Zone.fromTZif(allocator, builder.out.items[0..tail]));
    try testing.expectError(error.InvalidTail, tz.Zone.fromTZif(allocator, builder.out.items[0 .. builder.out.items.len - 1]));
    builder.out.items[tail] = 'X';
    try testing.expectError(error.InvalidTail, tz.Zone.fromTZif(allocator, builder.out.items));
    builder.out.items[tail] = '\n';
    builder.out.items[tail + 2] = 0;
    try testing.expectError(error.InvalidTail, tz.Zone.fromTZif(allocator, builder.out.items));
    builder.out.items[second + 4] = '2';
    try testing.expectError(error.InvalidHeader, tz.Zone.fromTZif(allocator, builder.out.items));
}

test "bad leap corrections, indicators and resource budgets fail explicitly" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{
        .{ .instant = 78796800, .correction = 2 },
    });
    try testing.expectError(error.InvalidLeap, tz.Zone.fromTZif(allocator, builder.out.items));
    std.mem.writeInt(i32, builder.out.items[58..62], 1, .big);
    std.mem.writeInt(u32, builder.out.items[24..28], 1, .big);
    try builder.out.append(allocator, 2);
    try testing.expectError(error.InvalidIndicators, tz.Zone.fromTZif(allocator, builder.out.items));
    builder.out.items[62] = 0;
    std.mem.writeInt(u32, builder.out.items[20..24], 1, .big);
    try builder.out.append(allocator, 1);
    try testing.expectError(error.InvalidIndicators, tz.Zone.fromTZif(allocator, builder.out.items));
    const oversized = try allocator.alloc(u8, tz.max_file_bytes + 1);
    defer allocator.free(oversized);
    try testing.expectError(error.LimitExceeded, tz.Zone.fromTZif(allocator, oversized));
    try testing.expectError(error.LimitExceeded, tz.Zone.fromPosix(allocator, oversized));
}

fn allocationProbe(a: std.mem.Allocator, bytes: []const u8) !void {
    var zone = try tz.Zone.fromTZif(a, bytes);
    defer zone.deinit();
    try expect(&zone, 0, 0, false, "UTC");
    var fixed = try tz.Zone.fromPosix(a, "UTC0");
    defer fixed.deinit();
    try expect(&fixed, 0, 0, false, "UTC");
}

test "all initialization allocation failures release owned bytes and arrays" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{ 0, 100 }, &.{ 0, 0 }, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    try testing.checkAllAllocationFailures(allocator, allocationProbe, .{builder.out.items});
}

test "future footer cannot replace historical types and must agree at final transition" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block('2', 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    try builder.block('2', 8, &.{1000}, &.{1}, &.{
        .{ .offset = 1800, .dst = 0, .name = 0 },
        .{ .offset = 0, .dst = 0, .name = 4 },
    }, "LMT\x00STD\x00", &.{});
    const tail = builder.out.items.len;
    try builder.out.appendSlice(allocator, "\nSTD0DST,M3.2.0,M11.1.0\n");
    var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
    defer zone.deinit();
    try expect(&zone, 999, 1800, false, "LMT");
    try expect(&zone, 1000, 0, false, "STD");
    try expect(&zone, 1626350400, 3600, true, "DST");
    builder.out.items[tail + 4] = '1';
    try testing.expectError(error.InvalidTail, tz.Zone.fromTZif(allocator, builder.out.items));
    @memset(builder.out.items, 0xcc);
    try expect(&zone, 999, 1800, false, "LMT");
}

test "every byte mutation remains bounded and every successful parse is usable" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block(0, 4, &.{ -100, 100 }, &.{ 1, 0 }, &.{
        .{ .offset = 0, .dst = 0, .name = 0 },
        .{ .offset = 3600, .dst = 1, .name = 4 },
    }, "STD\x00DST\x00", &.{});
    var rejected: usize = 0;
    for (0..builder.out.items.len) |i| {
        const original = builder.out.items[i];
        for ([_]u8{ 0x80, 0xff }) |mask| {
            builder.out.items[i] = original ^ mask;
            var zone = tz.Zone.fromTZif(allocator, builder.out.items) catch |err| {
                try testing.expect(err != error.OutOfMemory);
                rejected += 1;
                continue;
            };
            defer zone.deinit();
            _ = zone.offsetAt(std.math.minInt(i64));
            _ = zone.offsetAt(0);
            _ = zone.offsetAt(std.math.maxInt(i64));
        }
        builder.out.items[i] = original;
    }
    try testing.expect(rejected > 40);
}

test "64-bit endpoints and leap normalization overflow are explicit" {
    var builder = Builder{};
    defer builder.deinit();
    try builder.block('3', 4, &.{}, &.{}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "UTC\x00", &.{});
    const second = builder.out.items.len;
    try builder.block('3', 8, &.{ std.math.minInt(i64), std.math.maxInt(i64) }, &.{ 1, 0 }, &.{
        .{ .offset = 0, .dst = 0, .name = 0 },
        .{ .offset = 3600, .dst = 1, .name = 4 },
    }, "STD\x00DST\x00", &.{});
    try builder.out.appendSlice(allocator, "\n\n");
    var zone = try tz.Zone.fromTZif(allocator, builder.out.items);
    defer zone.deinit();
    try expect(&zone, std.math.minInt(i64), 3600, true, "DST");
    try expect(&zone, std.math.maxInt(i64) - 1, 3600, true, "DST");
    try expect(&zone, std.math.maxInt(i64), 0, false, "STD");
    builder.out.shrinkRetainingCapacity(second);
    try builder.block('3', 8, &.{std.math.maxInt(i64)}, &.{0}, &.{.{ .offset = 0, .dst = 0, .name = 0 }}, "STD\x00", &.{
        .{ .instant = 78796800, .correction = -1 },
    });
    try builder.out.appendSlice(allocator, "\n\n");
    try testing.expectError(error.TimestampOverflow, tz.Zone.fromTZif(allocator, builder.out.items));
}
