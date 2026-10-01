//! Borrowed, bounded POSIX TZ specifications; no environment or libc access.
const std = @import("std");

pub const max_spec_bytes = 4096;
pub const ParseError = error{ InvalidSpecification, MissingDstRules, LimitExceeded };
pub const Offset = struct {
    /// Seconds east of UTC, to add to a POSIX timestamp for local calendar time.
    utc_offset_seconds: i32,
    is_dst: bool,
    abbreviation: []const u8,
};
pub const Clock = enum { wall, standard, utc };
pub const Day = union(enum) {
    julian: u16,
    ordinal: u16,
    month: struct { month: u8, week: u8, weekday: u8 },
};
pub const Rule = struct {
    day: Day,
    seconds: i32 = 7200,
    clock: Clock = .wall,
};
pub const Rules = struct { start: Rule, end: Rule };
pub const Daylight = struct { abbreviation: []const u8, offset: i32, rules: Rules };
pub const Spec = struct {
    standard_abbreviation: []const u8,
    standard_offset: i32,
    daylight: ?Daylight = null,

    pub fn offsetAt(self: Spec, instant: i64) Offset {
        const dst = self.daylight orelse return self.standard();
        const year = yearFromDays(@divFloor(instant, 86400));
        // glibc evaluates rules in the UTC calendar year. Preserve this
        // characterized behavior, including its pre-1970 epoch anchoring and
        // UTC-year boundaries for out-of-day rules, rather than "fixing" it.
        const start = transition(dst.rules.start, year, self.standard_offset, self.standard_offset);
        const end = transition(dst.rules.end, year, self.standard_offset, dst.offset);
        const is_dst = if (start > end)
            instant >= start or instant < end
        else
            instant >= start and instant < end;
        return if (is_dst) .{
            .utc_offset_seconds = dst.offset,
            .is_dst = true,
            .abbreviation = dst.abbreviation,
        } else self.standard();
    }

    fn standard(self: Spec) Offset {
        return .{
            .utc_offset_seconds = self.standard_offset,
            .is_dst = false,
            .abbreviation = self.standard_abbreviation,
        };
    }
};

/// Abbreviation slices borrow `text`. Ruleless DST requires injected,
/// installation-specific rules, never an implicit US/UTC fallback.
pub fn parse(text: []const u8, default_rules: ?Rules) ParseError!Spec {
    if (text.len > max_spec_bytes) return error.LimitExceeded;
    if (text.len == 0 or std.mem.eql(u8, text, "UTC") or std.mem.eql(u8, text, "GMT"))
        return .{ .standard_abbreviation = if (text.len == 0) "UTC" else text, .standard_offset = 0 };
    var parser = Parser{ .text = text };
    const name = try parser.name();
    const offset = -(try parser.time(24));
    var spec = Spec{ .standard_abbreviation = name, .standard_offset = offset };
    if (parser.pos == text.len) return spec;
    const dst_name = try parser.name();
    const dst_offset = if (parser.peek() == ',' or parser.peek() == null)
        offset + 3600
    else
        -(try parser.time(24));
    const rules = if (parser.pos == text.len)
        default_rules orelse return error.MissingDstRules
    else blk: {
        try parser.expect(',');
        const start = try parser.rule();
        try parser.expect(',');
        const end = try parser.rule();
        break :blk Rules{ .start = start, .end = end };
    };
    if (parser.pos != text.len) return error.InvalidSpecification;
    try validateRule(rules.start);
    try validateRule(rules.end);
    spec.daylight = .{ .abbreviation = dst_name, .offset = dst_offset, .rules = rules };
    return spec;
}

fn validateRule(rule: Rule) ParseError!void {
    if (rule.seconds < -604799 or rule.seconds > 604799) return error.InvalidSpecification;
    switch (rule.day) {
        .julian => |day| if (day == 0 or day > 365) return error.InvalidSpecification,
        .ordinal => |day| if (day > 365) return error.InvalidSpecification,
        .month => |m| if (m.month == 0 or m.month > 12 or m.week == 0 or m.week > 5 or m.weekday > 6)
            return error.InvalidSpecification,
    }
}

const Parser = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(self: Parser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn expect(self: *Parser, byte: u8) ParseError!void {
        if (self.peek() != byte) return error.InvalidSpecification;
        self.pos += 1;
    }

    fn name(self: *Parser) ParseError![]const u8 {
        const quoted = self.peek() == '<';
        if (quoted) self.pos += 1;
        const start = self.pos;
        while (self.peek()) |byte| {
            if (!std.ascii.isAlphabetic(byte) and
                !(quoted and (std.ascii.isDigit(byte) or byte == '+' or byte == '-'))) break;
            self.pos += 1;
        }
        const result = self.text[start..self.pos];
        if (result.len < 3) return error.InvalidSpecification;
        if (quoted) try self.expect('>');
        return result;
    }

    fn number(self: *Parser, maximum: u32) ParseError!u32 {
        const start = self.pos;
        var value: u32 = 0;
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            value = std.math.mul(u32, value, 10) catch return error.InvalidSpecification;
            value = std.math.add(u32, value, byte - '0') catch return error.InvalidSpecification;
            if (value > maximum) return error.InvalidSpecification;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidSpecification;
        return value;
    }

    fn time(self: *Parser, max_hours: u32) ParseError!i32 {
        const negative = self.peek() == '-';
        if (negative or self.peek() == '+') self.pos += 1;
        const hours = try self.number(max_hours);
        var minutes: u32 = 0;
        var seconds: u32 = 0;
        if (self.peek() == ':') {
            self.pos += 1;
            minutes = try self.number(59);
            if (self.peek() == ':') {
                self.pos += 1;
                seconds = try self.number(59);
            }
        }
        const value: i32 = @intCast(hours * 3600 + minutes * 60 + seconds);
        return if (negative) -value else value;
    }

    fn rule(self: *Parser) ParseError!Rule {
        var day: Day = undefined;
        if (self.peek() == 'M') {
            self.pos += 1;
            const month = try self.number(12);
            try self.expect('.');
            const week = try self.number(5);
            try self.expect('.');
            const weekday = try self.number(6);
            if (month == 0 or week == 0) return error.InvalidSpecification;
            day = .{ .month = .{ .month = @intCast(month), .week = @intCast(week), .weekday = @intCast(weekday) } };
        } else if (self.peek() == 'J') {
            self.pos += 1;
            const ordinal = try self.number(365);
            if (ordinal == 0) return error.InvalidSpecification;
            day = .{ .julian = @intCast(ordinal) };
        } else {
            day = .{ .ordinal = @intCast(try self.number(365)) };
        }
        var result = Rule{ .day = day };
        if (self.peek() == '/') {
            self.pos += 1;
            result.seconds = try self.time(167);
            if (self.peek()) |suffix| {
                switch (suffix) {
                    'w' => result.clock = .wall,
                    's' => result.clock = .standard,
                    'u', 'g', 'z' => result.clock = .utc,
                    else => return result,
                }
                self.pos += 1;
            }
        }
        return result;
    }
};

fn leap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = year - @as(i64, @intFromBool(month <= 2));
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m = @as(i64, month) + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * m + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn yearFromDays(days: i64) i64 {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    return year + @as(i64, @intFromBool(mp >= 10));
}

fn transition(rule: Rule, year: i64, standard_offset: i32, wall_offset: i32) i128 {
    const days = switch (rule.day) {
        .julian => |day| daysFromCivil(year, 1, 1) + day - 1 +
            @as(i64, @intFromBool(leap(year) and day >= 60)),
        .ordinal => |day| daysFromCivil(year, 1, 1) + day,
        .month => |m| blk: {
            const first = daysFromCivil(year, m.month, 1);
            const weekday = @mod(first + 4, 7);
            var day = @mod(@as(i64, m.weekday) - weekday, 7) + 7 * (@as(i64, m.week) - 1);
            const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
            const length = lengths[m.month - 1] + @as(u8, @intFromBool(m.month == 2 and leap(year)));
            if (day >= length) day -= 7;
            break :blk first + day;
        },
    };
    const offset = switch (rule.clock) {
        .wall => wall_offset,
        .standard => standard_offset,
        .utc => 0,
    };
    const anchored_days = if (year <= 1970) days - daysFromCivil(year, 1, 1) else days;
    return @as(i128, anchored_days) * 86400 + rule.seconds - offset;
}
