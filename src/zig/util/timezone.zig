//! Owned TZif/POSIX timezone decoding for POSIX (non-leap-counting) instants.
//! Environment/TZDIR resolution and calendar/locale formatting belong to callers.
const std = @import("std");
pub const Posix = @import("timezone_posix.zig");
pub const Offset = Posix.Offset;
pub const max_file_bytes = 1 << 20;
pub const ParseError = Posix.ParseError || error{
    Truncated,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    InvalidCounts,
    InvalidTransition,
    InvalidType,
    InvalidAbbreviation,
    InvalidLeap,
    InvalidIndicators,
    InvalidTail,
    TimestampOverflow,
};
const InitError = ParseError || std.mem.Allocator.Error;
const Transition = struct { instant: i64, type_index: u8 };

pub const Zone = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    transitions: []Transition = &.{},
    types: []Offset = &.{},
    default_type: u8 = 0,
    spec: ?Posix.Spec = null,

    /// Copies bytes; all returned abbreviations borrow this Zone, not input.
    pub fn fromTZif(allocator: std.mem.Allocator, bytes: []const u8) InitError!Zone {
        if (bytes.len > max_file_bytes) return error.LimitExceeded;
        return decodeOwned(allocator, try allocator.dupe(u8, bytes));
    }

    pub fn fromPosix(allocator: std.mem.Allocator, text: []const u8) InitError!Zone {
        return fromPosixWithRules(allocator, text, null);
    }

    pub fn fromPosixWithRules(allocator: std.mem.Allocator, text: []const u8, defaults: ?Posix.Rules) InitError!Zone {
        if (text.len > Posix.max_spec_bytes) return error.LimitExceeded;
        const data = try allocator.dupe(u8, text);
        errdefer allocator.free(data);
        return .{ .allocator = allocator, .data = data, .spec = try Posix.parse(data, defaults) };
    }

    /// Bounded std.Io loading; open/read/limit/parse errors propagate unchanged.
    pub fn loadFile(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !Zone {
        const data = try dir.readFileAlloc(io, path, allocator, .limited(max_file_bytes));
        return decodeOwned(allocator, data);
    }

    pub fn deinit(self: *Zone) void {
        self.allocator.free(self.transitions);
        self.allocator.free(self.types);
        self.allocator.free(self.data);
        self.* = undefined;
    }

    pub fn offsetAt(self: *const Zone, instant: i64) Offset {
        if (self.spec) |spec| {
            if (self.types.len == 0 or (self.transitions.len != 0 and instant >= self.transitions[self.transitions.len - 1].instant))
                return spec.offsetAt(instant);
        }
        var lo: usize = 0;
        var hi = self.transitions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.transitions[mid].instant <= instant) lo = mid + 1 else hi = mid;
        }
        return self.types[if (lo == 0) self.default_type else self.transitions[lo - 1].type_index];
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, count: usize) ParseError![]const u8 {
        if (count > self.bytes.len - self.pos) return error.Truncated;
        const result = self.bytes[self.pos..][0..count];
        self.pos += count;
        return result;
    }

    fn int(self: *Reader, comptime T: type) ParseError!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn timestamp(self: *Reader, width: u8) ParseError!i64 {
        return if (width == 4) try self.int(i32) else try self.int(i64);
    }
};

const Header = struct {
    version: u8,
    ut: usize,
    standard: usize,
    leaps: usize,
    times: usize,
    types: usize,
    chars: usize,

    fn read(reader: *Reader) ParseError!Header {
        const bytes = try reader.take(44);
        if (!std.mem.eql(u8, bytes[0..4], "TZif")) return error.InvalidMagic;
        if (bytes[4] != 0 and bytes[4] != '2' and bytes[4] != '3') return error.UnsupportedVersion;
        for (bytes[5..20]) |byte| if (byte != 0) return error.InvalidHeader;
        var counts = Reader{ .bytes = bytes[20..] };
        const result = Header{
            .version = bytes[4],
            .ut = try counts.int(u32),
            .standard = try counts.int(u32),
            .leaps = try counts.int(u32),
            .times = try counts.int(u32),
            .types = try counts.int(u32),
            .chars = try counts.int(u32),
        };
        if (result.types == 0 or result.types > 256 or result.chars == 0 or result.chars > 65536 or
            result.times > 32768 or result.leaps > 1024) return error.InvalidCounts;
        if ((result.ut != 0 and result.ut != result.types) or
            (result.standard != 0 and result.standard != result.types)) return error.InvalidCounts;
        return result;
    }

    fn size(self: Header, width: u8) ParseError!usize {
        var result = std.math.mul(usize, self.times, width + 1) catch return error.InvalidCounts;
        result = std.math.add(usize, result, self.types * 6) catch return error.InvalidCounts;
        result = std.math.add(usize, result, self.chars) catch return error.InvalidCounts;
        result = std.math.add(usize, result, self.leaps * (width + 4)) catch return error.InvalidCounts;
        result = std.math.add(usize, result, self.standard) catch return error.InvalidCounts;
        return std.math.add(usize, result, self.ut) catch error.InvalidCounts;
    }
};

fn decodeOwned(allocator: std.mem.Allocator, data: []u8) InitError!Zone {
    errdefer allocator.free(data);
    var reader = Reader{ .bytes = data };
    var header = try Header.read(&reader);
    var width: u8 = 4;
    if (header.version != 0) {
        _ = try reader.take(try header.size(4));
        const version = header.version;
        header = try Header.read(&reader);
        if (header.version != version) return error.InvalidHeader;
        width = 8;
    }
    var block = Reader{ .bytes = try reader.take(try header.size(width)) };
    const time_bytes = try block.take(header.times * width);
    const indices = try block.take(header.times);
    const type_bytes = try block.take(header.types * 6);
    const abbreviations = try block.take(header.chars);
    if (abbreviations[abbreviations.len - 1] != 0) return error.InvalidAbbreviation;
    const leap_bytes = try block.take(header.leaps * (width + 4));
    const standard = try block.take(header.standard);
    const ut = try block.take(header.ut);
    for (standard) |byte| if (byte > 1) return error.InvalidIndicators;
    for (ut, 0..) |byte, i| {
        if (byte > 1 or (byte == 1 and (standard.len == 0 or standard[i] == 0)))
            return error.InvalidIndicators;
    }

    const types = try allocator.alloc(Offset, header.types);
    errdefer allocator.free(types);
    var type_reader = Reader{ .bytes = type_bytes };
    var default_type: ?u8 = null;
    for (types, 0..) |*entry, i| {
        const offset = try type_reader.int(i32);
        const is_dst = (try type_reader.take(1))[0];
        const index = (try type_reader.take(1))[0];
        if (offset == std.math.minInt(i32) or is_dst > 1) return error.InvalidType;
        if (index >= abbreviations.len) return error.InvalidAbbreviation;
        const end = std.mem.indexOfScalarPos(u8, abbreviations, index, 0) orelse return error.InvalidAbbreviation;
        entry.* = .{ .utc_offset_seconds = offset, .is_dst = is_dst != 0, .abbreviation = abbreviations[index..end] };
        if (is_dst == 0 and default_type == null) default_type = @intCast(i);
    }
    const transitions = try allocator.alloc(Transition, header.times);
    errdefer allocator.free(transitions);
    var time_reader = Reader{ .bytes = time_bytes };
    for (transitions, indices, 0..) |*entry, index, i| {
        const instant = try time_reader.timestamp(width);
        if (index >= types.len) return error.InvalidType;
        if (i != 0 and instant <= transitions[i - 1].instant) return error.InvalidTransition;
        entry.* = .{ .instant = instant, .type_index = index };
    }
    var leaps = Reader{ .bytes = leap_bytes };
    var previous_time: i64 = -1;
    var correction: i32 = 0;
    for (0..header.leaps) |_| {
        const instant = try leaps.timestamp(width);
        const next = try leaps.int(i32);
        const difference = @as(i64, next) - correction;
        if (instant < 0 or instant <= previous_time or (difference != 1 and difference != -1))
            return error.InvalidLeap;
        previous_time = instant;
        correction = next;
    }
    // TZif leap-aware transition values count leap seconds; our input instants
    // do not. Normalize the table once, without manufacturing a second 60.
    leaps.pos = 0;
    var leap_time: ?i64 = null;
    var next_correction: i32 = 0;
    correction = 0;
    if (header.leaps != 0) {
        leap_time = try leaps.timestamp(width);
        next_correction = try leaps.int(i32);
    }
    for (transitions, 0..) |*entry, i| {
        while (leap_time) |instant| {
            if (instant > entry.instant) break;
            correction = next_correction;
            if (leaps.pos == leap_bytes.len) {
                leap_time = null;
            } else {
                leap_time = try leaps.timestamp(width);
                next_correction = try leaps.int(i32);
            }
        }
        entry.instant = std.math.sub(i64, entry.instant, correction) catch return error.TimestampOverflow;
        if (i != 0 and entry.instant <= transitions[i - 1].instant) return error.InvalidTransition;
    }

    var spec: ?Posix.Spec = null;
    const tail = data[reader.pos..];
    if (width == 8) {
        if (tail.len < 2 or tail[0] != '\n' or tail[tail.len - 1] != '\n') return error.InvalidTail;
        const text = tail[1 .. tail.len - 1];
        if (std.mem.indexOfAny(u8, text, "\n\x00") != null) return error.InvalidTail;
        if (text.len != 0) spec = try Posix.parse(text, null);
        if (spec) |rules| {
            if (transitions.len != 0) {
                const last = transitions[transitions.len - 1];
                const expected = types[last.type_index];
                const actual = rules.offsetAt(last.instant);
                if (actual.utc_offset_seconds != expected.utc_offset_seconds or actual.is_dst != expected.is_dst or
                    !std.mem.eql(u8, actual.abbreviation, expected.abbreviation)) return error.InvalidTail;
            }
        }
    } else if (tail.len != 0) return error.InvalidTail;
    return .{
        .allocator = allocator,
        .data = data,
        .transitions = transitions,
        .types = types,
        .default_type = default_type orelse 0,
        .spec = spec,
    };
}
