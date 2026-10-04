//! Borrowed, bounded POSIX TZ specifications; no environment or libc access.
const std = @import("std");
const calendar = @import("time_calendar.zig");

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
        const year = calendar.fromEpoch(instant).year;
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

fn transition(rule: Rule, year: i64, standard_offset: i32, wall_offset: i32) i128 {
    // Rules are validated and fromEpoch's years fit well inside i64. Day one
    // and the following month are valid even at either i64 instant endpoint.
    const january = (calendar.Civil{ .year = year, .month = 1, .day = 1 }).epochDay() catch unreachable;
    const days = switch (rule.day) {
        .julian => |day| january + day - 1 +
            @as(i128, @intFromBool(calendar.isLeapYear(year) and day >= 60)),
        .ordinal => |day| january + day,
        .month => |m| blk: {
            const date = calendar.Civil{ .year = year, .month = m.month, .day = 1 };
            const first = date.epochDay() catch unreachable;
            const weekday = date.weekday() catch unreachable;
            const next_month = calendar.Civil{
                .year = year + @as(i64, @intFromBool(m.month == 12)),
                .month = if (m.month == 12) 1 else m.month + 1,
                .day = 1,
            };
            const length = (next_month.epochDay() catch unreachable) - first;
            var day = @mod(@as(i128, m.weekday) - weekday, 7) + 7 * (@as(i128, m.week) - 1);
            if (day >= length) day -= 7;
            break :blk first + day;
        },
    };
    const offset = switch (rule.clock) {
        .wall => wall_offset,
        .standard => standard_offset,
        .utc => 0,
    };
    const anchored_days = if (year <= 1970) days - january else days;
    return anchored_days * calendar.seconds_per_day + rule.seconds - offset;
}
