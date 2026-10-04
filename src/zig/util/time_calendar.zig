//! Proleptic Gregorian calendar and explicitly C-locale timestamp formatting.
//! No timezone lookup, locale lookup, libc, translated headers, or allocation.

const std = @import("std");

pub const seconds_per_day = 86400;
const epoch_day = 719528;
const days_per_era = 146097;

pub const DateError = error{InvalidDate};
pub const EpochError = DateError || error{EpochOutOfRange};
pub const FormatError = DateError || error{ InvalidFormat, InvalidZone, YearOutOfRange } || std.Io.Writer.Error;

pub const Civil = struct {
    year: i64,
    month: u8,
    day: u8,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,

    pub fn validate(self: Civil) DateError!void {
        if (self.month < 1 or self.month > 12 or self.day < 1 or
            self.day > daysInMonth(self.year, self.month) or
            self.hour > 23 or self.minute > 59 or self.second > 59)
            return error.InvalidDate;
    }

    /// Zero-based, like tm_yday.
    pub fn dayOfYear(self: Civil) DateError!u16 {
        try self.validate();
        var days: u16 = self.day - 1;
        var month: u8 = 1;
        while (month < self.month) : (month += 1) days += daysInMonth(self.year, month);
        return days;
    }

    /// Sunday=0, like tm_wday.
    pub fn weekday(self: Civil) DateError!u3 {
        const days = daysBeforeYear(self.year) + try self.dayOfYear() - epoch_day;
        return @intCast(@mod(days + 4, 7));
    }

    /// The adapter must reject dates gmtime_r cannot represent in tm_year.
    pub fn tmYear(self: Civil) error{YearOutOfRange}!i32 {
        const year = @as(i128, self.year) - 1900;
        if (year < std.math.minInt(i32) or year > std.math.maxInt(i32))
            return error.YearOutOfRange;
        return @intCast(year);
    }
};

pub fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) u8 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (month == 2 and isLeapYear(year)) 29 else lengths[month - 1];
}

fn daysBeforeYear(year: i64) i128 {
    const y: i128 = year;
    return 365 * y + @divFloor(y + 3, 4) - @divFloor(y + 99, 100) + @divFloor(y + 399, 400);
}

/// Interpret seconds as a UTC/wall-clock scalar; a timezone adapter applies
/// its checked offset before calling this. Every i64 epoch is representable.
pub fn fromEpoch(seconds: i64) Civil {
    const days = @divFloor(seconds, seconds_per_day) + epoch_day;
    const era_year = @divFloor(days, days_per_era) * 400;
    var low: i64 = 0;
    var high: i64 = 400;
    while (low + 1 < high) {
        const middle = @divFloor(low + high, 2);
        if (daysBeforeYear(era_year + middle) <= days) low = middle else high = middle;
    }
    const year = era_year + low;
    var remainder: u16 = @intCast(days - daysBeforeYear(year));
    var month: u8 = 1;
    while (remainder >= daysInMonth(year, month)) : (month += 1) {
        remainder -= daysInMonth(year, month);
    }
    const clock: u32 = @intCast(@mod(seconds, seconds_per_day));
    return .{
        .year = year,
        .month = month,
        .day = @intCast(remainder + 1),
        .hour = @intCast(clock / 3600),
        .minute = @intCast((clock / 60) % 60),
        .second = @intCast(clock % 60),
    };
}

/// Strict, non-normalizing inverse. POSIX days have 86400 seconds; leap
/// seconds and DST gap/fold interpretation belong to a separate adapter.
pub fn toEpoch(date: Civil) EpochError!i64 {
    const days = daysBeforeYear(date.year) + try date.dayOfYear() - epoch_day;
    const seconds = days * seconds_per_day + @as(i128, date.hour) * 3600 +
        @as(i128, date.minute) * 60 + date.second;
    if (seconds < std.math.minInt(i64) or seconds > std.math.maxInt(i64))
        return error.EpochOutOfRange;
    return @intCast(seconds);
}

pub const Zone = struct {
    abbreviation: []const u8,
    offset_seconds: i32 = 0,
};

/// C-locale year formatting differs even between glibc and musl.
pub const Flavor = enum { gnu, musl };

pub const FormatOptions = struct {
    zone: Zone = .{ .abbreviation = "GMT" },
    flavor: Flavor = .gnu,
};

const short_days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const long_days = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const short_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const long_months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn validateFormat(format: []const u8) error{InvalidFormat}!void {
    var pos: usize = 0;
    while (pos < format.len) : (pos += 1) {
        if (format[pos] == 0) return error.InvalidFormat;
        if (format[pos] != '%') continue;
        pos += 1;
        if (pos == format.len or std.mem.indexOfScalar(u8, "%aAbBcdeHjmMSxXyYZzwuFTnt", format[pos]) == null)
            return error.InvalidFormat;
    }
}

fn number(writer: *std.Io.Writer, value: u64, width: usize, pad: u8) std.Io.Writer.Error!void {
    var storage: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&storage, "{d}", .{value}) catch unreachable;
    if (digits.len < width) try writer.splatByteAll(pad, width - digits.len);
    try writer.writeAll(digits);
}

fn yearNumber(writer: *std.Io.Writer, year: i64, flavor: Flavor) std.Io.Writer.Error!void {
    if (flavor == .gnu) {
        // glibc's %Y adds 1900 in a signed 32-bit int even when tm_year
        // itself is representable. Preserve its observed upper-bound wrap.
        const displayed: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(year)))));
        return writer.print("{d}", .{displayed});
    }
    if (year < 0) {
        try writer.writeByte('-');
        try number(writer, @abs(year), 3, '0');
    } else {
        if (year >= 10000) try writer.writeByte('+');
        try number(writer, @intCast(year), 4, '0');
    }
}

/// Only the documented conversion set is accepted. No GNU flags/width
/// modifiers, E/O modifiers, locale guessing, or libc fallback. Does not flush
/// or NUL-terminate the caller's writer; write and flush errors remain theirs.
pub fn write(writer: *std.Io.Writer, format: []const u8, date: Civil, options: FormatOptions) FormatError!void {
    try date.validate();
    _ = try date.tmYear();
    try validateFormat(format);
    if (std.mem.indexOfScalar(u8, options.zone.abbreviation, 0) != null)
        return error.InvalidZone;
    try render(writer, format, date, options);
}

fn render(writer: *std.Io.Writer, format: []const u8, date: Civil, options: FormatOptions) FormatError!void {
    var pos: usize = 0;
    while (pos < format.len) : (pos += 1) {
        if (format[pos] != '%') {
            try writer.writeByte(format[pos]);
            continue;
        }
        pos += 1;
        switch (format[pos]) {
            '%' => try writer.writeByte('%'),
            'a' => try writer.writeAll(short_days[try date.weekday()]),
            'A' => try writer.writeAll(long_days[try date.weekday()]),
            'b' => try writer.writeAll(short_months[date.month - 1]),
            'B' => try writer.writeAll(long_months[date.month - 1]),
            'c' => try render(writer, "%a %b %e %H:%M:%S %Y", date, options),
            'd' => try number(writer, date.day, 2, '0'),
            'e' => try number(writer, date.day, 2, ' '),
            'H' => try number(writer, date.hour, 2, '0'),
            'j' => try number(writer, @as(u64, try date.dayOfYear()) + 1, 3, '0'),
            'm' => try number(writer, date.month, 2, '0'),
            'M' => try number(writer, date.minute, 2, '0'),
            'S' => try number(writer, date.second, 2, '0'),
            'x' => try render(writer, "%m/%d/%y", date, options),
            'X', 'T' => try render(writer, "%H:%M:%S", date, options),
            'y' => try number(writer, if (options.flavor == .gnu) @intCast(@mod(date.year, 100)) else @abs(@rem(date.year, 100)), 2, '0'),
            'Y' => try yearNumber(writer, date.year, options.flavor),
            'Z' => try writer.writeAll(options.zone.abbreviation),
            'z' => {
                const offset = options.zone.offset_seconds;
                try writer.writeByte(if (offset < 0) '-' else '+');
                try number(writer, @abs(offset) / 3600, 2, '0');
                try number(writer, (@abs(offset) / 60) % 60, 2, '0');
            },
            'w' => try number(writer, try date.weekday(), 1, '0'),
            'u' => {
                const weekday = try date.weekday();
                try number(writer, if (weekday == 0) 7 else weekday, 1, '0');
            },
            'F' => try render(writer, "%Y-%m-%d", date, options),
            'n' => try writer.writeByte('\n'),
            't' => try writer.writeByte('\t'),
            else => unreachable,
        }
    }
}

/// strftime-style count excluding NUL, or zero on insufficient capacity.
/// Unlike snprintf, failure does not return a would-have-written length.
/// Failure leaves all destination bytes untouched (C leaves them unspecified).
/// An empty format succeeds with NUL when there is room, also returning zero.
pub fn formatZ(buffer: []u8, format: []const u8, date: Civil, options: FormatOptions) FormatError!usize {
    var count = std.Io.Writer.Discarding.init(&.{});
    try write(&count.writer, format, date, options);
    if (count.fullCount() >= buffer.len) return 0;
    var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
    try render(&writer, format, date, options);
    const len = writer.buffered().len;
    buffer[len] = 0;
    return len;
}

test "calendar frozen epochs cover negative days and leap centuries" {
    const cases = [_]struct { epoch: i64, year: i64, month: u8, day: u8 }{
        .{ .epoch = -11670998400, .year = 1600, .month = 2, .day = 29 },
        .{ .epoch = -8515238400, .year = 1700, .month = 3, .day = 1 },
        .{ .epoch = -5359564800, .year = 1800, .month = 3, .day = 1 },
        .{ .epoch = -2203891200, .year = 1900, .month = 3, .day = 1 },
        .{ .epoch = -310521600, .year = 1960, .month = 2, .day = 29 },
        .{ .epoch = 0, .year = 1970, .month = 1, .day = 1 },
        .{ .epoch = 951782400, .year = 2000, .month = 2, .day = 29 },
        .{ .epoch = 4107542400, .year = 2100, .month = 3, .day = 1 },
        .{ .epoch = 13574563200, .year = 2400, .month = 2, .day = 29 },
    };
    for (cases) |case| {
        const date = Civil{ .year = case.year, .month = case.month, .day = case.day };
        try std.testing.expectEqualDeep(date, fromEpoch(case.epoch));
        try std.testing.expectEqual(case.epoch, try toEpoch(date));
    }
    try std.testing.expectEqualDeep(
        Civil{ .year = 1969, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 59 },
        fromEpoch(-1),
    );
    try std.testing.expectEqualDeep(
        Civil{ .year = 1969, .month = 12, .day = 30, .hour = 23, .minute = 59, .second = 59 },
        fromEpoch(-86401),
    );
}

test "calendar round trips every signed 64-bit boundary and sampled epoch" {
    for ([_]i64{ std.math.minInt(i64), std.math.minInt(i64) + 1, -62198755200, -62167219200, -1, 0, 1, 0xffffffff, 253402300800, std.math.maxInt(i64) - 1, std.math.maxInt(i64) }) |epoch|
        try std.testing.expectEqual(epoch, try toEpoch(fromEpoch(epoch)));
    var state: u64 = 0x228;
    for (0..10000) |_| {
        state = state *% 6364136223846793005 +% 1;
        const epoch: i64 = @bitCast(state);
        try std.testing.expectEqual(epoch, try toEpoch(fromEpoch(epoch)));
    }
}

test "calendar weekdays and day of year cover complete Gregorian eras" {
    for ([_]i64{ -400, 0, 1600, 2000 }) |start_year| {
        const start = try toEpoch(.{ .year = start_year, .month = 1, .day = 1 });
        var weekday = try fromEpoch(start).weekday();
        for (0..days_per_era) |day| {
            const epoch = start + @as(i64, @intCast(day)) * seconds_per_day;
            const date = fromEpoch(epoch);
            try std.testing.expectEqual(epoch, try toEpoch(date));
            try std.testing.expectEqual(weekday, try date.weekday());
            const january = try toEpoch(.{ .year = date.year, .month = 1, .day = 1 });
            try std.testing.expectEqual(@divExact(epoch - january, seconds_per_day), try date.dayOfYear());
            weekday = @intCast((@as(u8, weekday) + 1) % 7);
        }
    }
}

test "calendar invalid dates and epoch overflow are explicit" {
    const invalid = [_]Civil{
        .{ .year = 1900, .month = 2, .day = 29 },
        .{ .year = 2100, .month = 2, .day = 29 },
        .{ .year = 2000, .month = 0, .day = 1 },
        .{ .year = 2000, .month = 13, .day = 1 },
        .{ .year = 2000, .month = 1, .day = 0 },
        .{ .year = 2000, .month = 4, .day = 31 },
        .{ .year = 2000, .month = 1, .day = 1, .hour = 24 },
        .{ .year = 2000, .month = 1, .day = 1, .minute = 60 },
        .{ .year = 2000, .month = 1, .day = 1, .second = 60 },
    };
    for (invalid) |date| try std.testing.expectError(error.InvalidDate, toEpoch(date));
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |year|
        try std.testing.expectError(error.EpochOutOfRange, toEpoch(.{ .year = year, .month = 1, .day = 1 }));
}

test "calendar libc tm year range is checked separately from epoch conversion" {
    const minimum: i64 = @as(i64, std.math.minInt(i32)) + 1900;
    const maximum: i64 = @as(i64, std.math.maxInt(i32)) + 1900;
    try std.testing.expectEqual(std.math.minInt(i32), try (Civil{ .year = minimum, .month = 1, .day = 1 }).tmYear());
    try std.testing.expectEqual(std.math.maxInt(i32), try (Civil{ .year = maximum, .month = 12, .day = 31 }).tmYear());
    for ([_]i64{ minimum - 1, maximum + 1, std.math.minInt(i64), std.math.maxInt(i64) }) |year|
        try std.testing.expectError(error.YearOutOfRange, (Civil{ .year = year, .month = 1, .day = 1 }).tmYear());
    var writer: std.Io.Writer = .failing;
    for ([_]i64{ std.math.minInt(i64), std.math.maxInt(i64) }) |epoch|
        try std.testing.expectError(error.YearOutOfRange, write(&writer, "%Y", fromEpoch(epoch), .{}));
}

test "calendar C locale frozen formatting and minimum widths" {
    const cases = [_]struct { epoch: i64, format: []const u8, text: []const u8 }{
        .{ .epoch = 0, .format = "%c %Z", .text = "Thu Jan  1 00:00:00 1970 GMT" },
        .{ .epoch = -1, .format = "%x %X %Z", .text = "12/31/69 23:59:59 GMT" },
        .{ .epoch = 951782400, .format = "%a %A %b %B %e %j %w %u", .text = "Tue Tuesday Feb February 29 060 2 2" },
        .{ .epoch = 3661, .format = "S+ %H:%M:%S", .text = "S+ 01:01:01" },
        .{ .epoch = 86400, .format = "S+%yy %jd %H:%M:%S", .text = "S+70y 002d 00:00:00" },
        .{ .epoch = 8640000, .format = "S+ %y years %j days %H:%M:%S", .text = "S+ 70 years 101 days 00:00:00" },
        .{ .epoch = 8640000, .format = "S+ %y/%j %H:%M:%S", .text = "S+ 70/101 00:00:00" },
        .{ .epoch = 8640000, .format = "S+ %y/%j", .text = "S+ 70/101" },
        .{ .epoch = 0, .format = "%% %Y-%m-%d %T%t%F%n", .text = "% 1970-01-01 00:00:00\t1970-01-01\n" },
    };
    for (cases) |case| {
        var storage: [160]u8 = undefined;
        const len = try formatZ(&storage, case.format, fromEpoch(case.epoch), .{});
        try std.testing.expectEqualStrings(case.text, storage[0..len]);
        try std.testing.expectEqual(@as(u8, 0), storage[len]);
    }
}

test "calendar gnu and musl year widths and negative year remainders are explicit" {
    const cases = [_]struct { year: i64, gnu: []const u8, musl: []const u8 }{
        .{ .year = -1, .gnu = "-1|99", .musl = "-001|01" },
        .{ .year = 0, .gnu = "0|00", .musl = "0000|00" },
        .{ .year = 1, .gnu = "1|01", .musl = "0001|01" },
        .{ .year = 9999, .gnu = "9999|99", .musl = "9999|99" },
        .{ .year = 10000, .gnu = "10000|00", .musl = "+10000|00" },
        .{ .year = -2147481748, .gnu = "-2147481748|52", .musl = "-2147481748|48" },
        .{ .year = 2147485547, .gnu = "-2147481749|47", .musl = "+2147485547|47" },
    };
    for (cases) |case| {
        const date = Civil{ .year = case.year, .month = 1, .day = 1 };
        inline for (.{ Flavor.gnu, Flavor.musl }) |flavor| {
            var storage: [40]u8 = undefined;
            const len = try formatZ(&storage, "%Y|%y", date, .{ .flavor = flavor });
            try std.testing.expectEqualStrings(if (flavor == .gnu) case.gnu else case.musl, storage[0..len]);
        }
    }
}

test "calendar zone names and offsets are injected without applying an offset" {
    const date = fromEpoch(0);
    const cases = [_]struct { zone: Zone, text: []const u8 }{
        .{ .zone = .{ .abbreviation = "GMT" }, .text = "00:00:00 GMT +0000" },
        .{ .zone = .{ .abbreviation = "UTC" }, .text = "00:00:00 UTC +0000" },
        .{ .zone = .{ .abbreviation = "EST", .offset_seconds = -18000 }, .text = "00:00:00 EST -0500" },
        .{ .zone = .{ .abbreviation = "+0530", .offset_seconds = 19800 }, .text = "00:00:00 +0530 +0530" },
        .{ .zone = .{ .abbreviation = "", .offset_seconds = -1 }, .text = "00:00:00  -0000" },
    };
    for (cases) |case| {
        var storage: [64]u8 = undefined;
        const len = try formatZ(&storage, "%X %Z %z", date, .{ .zone = case.zone });
        try std.testing.expectEqualStrings(case.text, storage[0..len]);
    }
}

test "calendar bounded formatting returns zero without writes at every boundary" {
    const text = "Thu Jan  1 00:00:00 1970 GMT";
    for (0..text.len + 3) |capacity| {
        var storage: [64]u8 = @splat(0xa5);
        const len = try formatZ(storage[0..capacity], "%c %Z", fromEpoch(0), .{});
        if (capacity <= text.len) {
            try std.testing.expectEqual(@as(usize, 0), len);
            try std.testing.expectEqual([_]u8{0xa5} ** 64, storage);
        } else {
            try std.testing.expectEqual(text.len, len);
            try std.testing.expectEqualStrings(text, storage[0..len]);
            try std.testing.expectEqual(@as(u8, 0), storage[len]);
            for (storage[len + 1 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
    }
    var one = [_]u8{0xa5};
    try std.testing.expectEqual(@as(usize, 0), try formatZ(one[0..0], "", fromEpoch(0), .{}));
    try std.testing.expectEqual(@as(u8, 0xa5), one[0]);
    try std.testing.expectEqual(@as(usize, 0), try formatZ(&one, "", fromEpoch(0), .{}));
    try std.testing.expectEqual(@as(u8, 0), one[0]);
}

test "calendar invalid formats dates and zones cannot masquerade as success" {
    var storage: [80]u8 = @splat(0xa5);
    for ([_][]const u8{ "%", "%Q", "%EY", "%OY", "%4Y", "%-d", "a\x00b" }) |format| {
        try std.testing.expectError(error.InvalidFormat, formatZ(&storage, format, fromEpoch(0), .{}));
        try std.testing.expectEqual([_]u8{0xa5} ** 80, storage);
    }
    try std.testing.expectError(error.InvalidZone, formatZ(&storage, "%Z", fromEpoch(0), .{ .zone = .{ .abbreviation = "a\x00b" } }));
    try std.testing.expectError(error.InvalidDate, formatZ(&storage, "%c", .{ .year = 2001, .month = 2, .day = 29 }, .{}));
}

test "calendar writer errors propagate initially and after partial output" {
    var failed: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, write(&failed, "%c %Z", fromEpoch(0), .{}));
    const text = "Thu Jan  1 00:00:00 1970 GMT";
    var storage: [80]u8 = undefined;
    for (0..text.len) |capacity| {
        var writer = std.Io.Writer.fixed(storage[0..capacity]);
        try std.testing.expectError(error.WriteFailed, write(&writer, "%c %Z", fromEpoch(0), .{}));
        try std.testing.expectEqualStrings(text[0..writer.buffered().len], writer.buffered());
    }
}
