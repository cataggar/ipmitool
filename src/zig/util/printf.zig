//! Allocation-free, typed subset of C printf. Unsupported conversions are
//! compile errors, not approximate Zig replacements for libc/locale behavior.
const std = @import("std");

pub const FormatError = error{ InvalidFormat, UnsupportedConversion };
const Length = enum { none, hh, h, l, ll, j, z, t };
const Spec = struct {
    end: usize,
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alternate: bool = false,
    zero: bool = false,
    width: usize = 0,
    width_star: bool = false,
    precision: ?usize = null,
    precision_star: bool = false,
    length: Length = .none,
    conversion: u8 = undefined,
};

fn number(format: []const u8, at: *usize) FormatError!usize {
    var n: usize = 0;
    while (at.* < format.len and std.ascii.isDigit(format[at.*])) : (at.* += 1) {
        n = std.math.mul(usize, n, 10) catch return error.InvalidFormat;
        n = std.math.add(usize, n, format[at.*] - '0') catch return error.InvalidFormat;
    }
    return n;
}

fn parse(format: []const u8, start: usize) FormatError!Spec {
    var at = start + 1;
    var spec: Spec = .{ .end = undefined };
    if (at == format.len) return error.InvalidFormat;
    if (format[at] == '%') {
        spec.conversion = '%';
        spec.end = at + 1;
        return spec;
    }
    while (at < format.len) : (at += 1) {
        switch (format[at]) {
            '-' => spec.left = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alternate = true,
            '0' => spec.zero = true,
            '\'' => return error.UnsupportedConversion,
            else => break,
        }
    }
    if (at < format.len and format[at] == '*') {
        spec.width_star = true;
        at += 1;
    } else {
        spec.width = try number(format, &at);
    }
    if (at < format.len and format[at] == '.') {
        at += 1;
        if (at < format.len and format[at] == '*') {
            spec.precision_star = true;
            at += 1;
        } else {
            spec.precision = try number(format, &at);
        }
    }
    if (spec.width > std.math.maxInt(c_int) or
        (spec.precision != null and spec.precision.? > std.math.maxInt(c_int)))
        return error.InvalidFormat;
    if (at < format.len) {
        switch (format[at]) {
            'h', 'l' => |ch| {
                at += 1;
                spec.length = if (ch == 'h') .h else .l;
                if (at < format.len and format[at] == ch) {
                    spec.length = if (ch == 'h') .hh else .ll;
                    at += 1;
                }
            },
            'j' => {
                spec.length = .j;
                at += 1;
            },
            'z' => {
                spec.length = .z;
                at += 1;
            },
            't' => {
                spec.length = .t;
                at += 1;
            },
            else => {},
        }
    }
    if (at == format.len) return error.InvalidFormat;
    spec.conversion = format[at];
    spec.end = at + 1;
    switch (spec.conversion) {
        'd', 'i', 'u', 'o', 'x', 'X' => {},
        's', 'c' => {
            if (spec.length != .none or spec.plus or spec.space or spec.alternate or spec.zero)
                return error.UnsupportedConversion;
            if (spec.conversion == 'c' and (spec.precision != null or spec.precision_star))
                return error.UnsupportedConversion;
        },
        else => return error.UnsupportedConversion,
    }
    return spec;
}

/// Also used by the inventory tests to pin explicitly unsupported forms.
pub fn validate(format: []const u8) FormatError!void {
    if (std.mem.indexOfScalar(u8, format, 0) != null) return error.InvalidFormat;
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, format, at, '%')) |start| {
        at = (try parse(format, start)).end;
    }
}

fn promotedType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => |info| if (info.bits < @bitSizeOf(c_int)) c_int else T,
        else => @compileError("printf integer argument must be a C-promotable integer"),
    };
}

fn star(value: anytype) c_int {
    if (@TypeOf(value) == comptime_int) return @as(c_int, value);
    if (promotedType(@TypeOf(value)) != c_int)
        @compileError("printf '*' requires a promoted C int");
    return @intCast(value);
}

fn bits(comptime length: Length) comptime_int {
    return switch (length) {
        .hh => 8,
        .h => @bitSizeOf(c_short),
        .none => @bitSizeOf(c_int),
        .l => @bitSizeOf(c_long),
        .ll, .j => @bitSizeOf(c_longlong),
        .z, .t => @bitSizeOf(usize),
    };
}

fn integerBits(comptime spec: Spec, value: anytype) std.meta.Int(.unsigned, bits(spec.length)) {
    const argument_bits = if (spec.length == .h or spec.length == .hh) @bitSizeOf(c_int) else bits(spec.length);
    if (@TypeOf(value) == comptime_int) {
        const I = std.meta.Int(if (value < 0 or spec.conversion == 'd' or spec.conversion == 'i') .signed else .unsigned, argument_bits);
        return @truncate(@as(std.meta.Int(.unsigned, argument_bits), @bitCast(@as(I, value))));
    }
    const P = promotedType(@TypeOf(value));
    if (@bitSizeOf(P) != argument_bits)
        @compileError("printf length modifier does not match the promoted C integer width; cast explicitly");
    const promoted: P = @intCast(value);
    return @truncate(@as(std.meta.Int(.unsigned, @bitSizeOf(P)), @bitCast(promoted)));
}

fn stringBytes(value: anytype, precision: ?usize) []const u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => return stringBytes(value.?, precision),
        .pointer => |ptr| {
            if (ptr.size == .slice or (ptr.size == .one and @typeInfo(ptr.child) == .array)) {
                const bytes: []const u8 = value;
                return std.mem.sliceTo(bytes[0..@min(bytes.len, precision orelse bytes.len)], 0);
            }
            if (ptr.child != u8) @compileError("printf %s requires bytes");
            // C defines no behavior for a null %s; do not copy a particular
            // libc's nonportable spelling or precision-dependent null handling.
            if (ptr.size == .c) std.debug.assert(value != null);
            if (precision) |limit| {
                var n: usize = 0;
                while (n < limit and value[n] != 0) : (n += 1) {}
                return value[0..n];
            }
            return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
        },
        else => @compileError("printf %s requires a byte slice or C string"),
    }
}

fn padded(writer: *std.Io.Writer, bytes: []const u8, width: usize, left: bool) std.Io.Writer.Error!void {
    if (!left) try writer.splatByteAll(' ', width -| bytes.len);
    try writer.writeAll(bytes);
    if (left) try writer.splatByteAll(' ', width -| bytes.len);
}

fn integer(
    writer: *std.Io.Writer,
    comptime spec: Spec,
    value: anytype,
    width: usize,
    precision: ?usize,
    left: bool,
) std.Io.Writer.Error!void {
    const U = std.meta.Int(.unsigned, bits(spec.length));
    const S = std.meta.Int(.signed, bits(spec.length));
    const raw = integerBits(spec, value);
    const signed = spec.conversion == 'd' or spec.conversion == 'i';
    const negative = signed and @as(S, @bitCast(raw)) < 0;
    var magnitude: U = if (negative) 0 -% raw else raw;
    const nonzero = magnitude != 0;
    const base: U = switch (spec.conversion) {
        'x', 'X' => 16,
        'o' => 8,
        else => 10,
    };
    const alphabet = if (spec.conversion == 'X') "0123456789ABCDEF" else "0123456789abcdef";
    var storage: [bits(spec.length)]u8 = undefined;
    var at = storage.len;
    if (nonzero or precision != 0) {
        while (true) {
            at -= 1;
            storage[at] = alphabet[@intCast(magnitude % base)];
            magnitude /= base;
            if (magnitude == 0) break;
        }
    }
    const digits = storage[at..];
    const sign: []const u8 = if (negative) "-" else if (signed and spec.plus) "+" else if (signed and spec.space) " " else "";
    const prefix: []const u8 = if (spec.alternate and nonzero and base == 16)
        (if (spec.conversion == 'X') "0X" else "0x")
    else
        "";
    var zeros = (precision orelse 0) -| digits.len;
    if (spec.alternate and base == 8 and zeros == 0 and (digits.len == 0 or digits[0] != '0')) zeros = 1;
    const occupied = sign.len + prefix.len + zeros + digits.len;
    const padding = width -| occupied;
    const zero_pad = spec.zero and !left and precision == null;
    if (!left and !zero_pad) try writer.splatByteAll(' ', padding);
    try writer.writeAll(sign);
    try writer.writeAll(prefix);
    if (zero_pad) try writer.splatByteAll('0', padding);
    try writer.splatByteAll('0', zeros);
    try writer.writeAll(digits);
    if (left) try writer.splatByteAll(' ', padding);
}

/// All formatting is checked at compile time. Arguments obey C default integer
/// promotions and length modifiers, not Zig's implicit arbitrary-width printing.
/// This is a writer, not snprintf: exhaustion is WriteFailed, never truncation.
pub fn print(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    @setEvalBranchQuota(100_000);
    comptime validate(format) catch |err|
        @compileError("unsupported printf format '" ++ format ++ "': " ++ @errorName(err));
    comptime var at: usize = 0;
    comptime var argument: usize = 0;
    const count = @typeInfo(@TypeOf(args)).@"struct".fields.len;
    inline while (at < format.len) {
        const start = comptime std.mem.indexOfScalarPos(u8, format, at, '%') orelse format.len;
        try writer.writeAll(format[at..start]);
        if (comptime start == format.len) break;
        const spec = comptime parse(format, start) catch |err|
            @compileError("unsupported printf format '" ++ format ++ "': " ++ @errorName(err));
        comptime at = spec.end;
        if (comptime spec.conversion == '%') {
            try writer.writeByte('%');
            continue;
        }
        var width = spec.width;
        var left = spec.left;
        if (comptime spec.width_star) {
            if (comptime argument == count) @compileError("missing printf width argument");
            const n = star(args[argument]);
            width = @intCast(if (n < 0) -@as(i64, n) else @as(i64, n));
            left = left or n < 0;
            comptime argument += 1;
        }
        var precision = spec.precision;
        if (comptime spec.precision_star) {
            if (comptime argument == count) @compileError("missing printf precision argument");
            const n = star(args[argument]);
            precision = if (n < 0) null else @intCast(n);
            comptime argument += 1;
        }
        if (comptime argument == count) @compileError("missing printf value argument");
        switch (comptime spec.conversion) {
            's' => try padded(writer, stringBytes(args[argument], precision), width, left),
            'c' => {
                const ch: [1]u8 = .{@truncate(integerBits(.{ .end = 0, .conversion = 'u' }, args[argument]))};
                try padded(writer, &ch, width, left);
            },
            else => try integer(writer, spec, args[argument], width, precision, left),
        }
        comptime argument += 1;
    }
    if (comptime argument != count) @compileError("unused printf arguments");
}

test "unsupported printf forms are explicit, not approximated" {
    for ([_][]const u8{ "%f", "%.*f", "%-10.3f", "%g", "%a", "%Lf", "%p", "%n", "%ls", "%lc", "%'d", "%2$d", "%*2$s" }) |format|
        try std.testing.expectError(error.UnsupportedConversion, validate(format));
    try std.testing.expectError(error.InvalidFormat, validate("unfinished %"));
    try std.testing.expectError(error.InvalidFormat, validate("%12."));
    try std.testing.expectError(error.InvalidFormat, validate("before\x00%d"));
    try std.testing.expectError(error.InvalidFormat, validate("%2147483648d"));
    try std.testing.expectError(error.InvalidFormat, validate("%.2147483648d"));
}

fn expectParity(comptime format: []const u8, args: anytype) !void {
    const c = @import("ipmi_c");
    var actual: [512]u8 = undefined;
    var expected: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&actual);
    try print(&writer, format, args);
    const length = @call(.auto, c.snprintf, .{ &expected, expected.len, format ++ "" } ++ args);
    try std.testing.expect(length >= 0 and length < expected.len);
    try std.testing.expectEqualSlices(u8, expected[0..@intCast(length)], writer.buffered());
}

fn expectIntegerParity(comptime format: []const u8, value: anytype) !void {
    const spec = comptime try parse(format, 0);
    if (comptime spec.width_star) {
        for ([_]c_int{ -25, 0, 1, 25 }) |width|
            try expectParity(format, .{ width, value });
    } else {
        try expectParity(format, .{value});
    }
}

test "every supported product printf inventory form matches libc" {
    @setEvalBranchQuota(100_000);
    const inventory = @import("printf_inventory.zig");
    inline for (inventory.supported) |format| {
        const spec = comptime try parse(format, 0);
        switch (comptime spec.conversion) {
            '%' => try expectParity(format, .{}),
            's' => {
                inline for (.{ "", "name", "spaces and a long field", "before\x00after" }) |text| {
                    if (comptime spec.width_star and spec.precision_star) {
                        for ([_]c_int{ -25, 0, 1, 25 }) |width| {
                            for ([_]c_int{ -1, 0, 1, 5, 40 }) |precision|
                                try expectParity(format, .{ width, precision, text });
                        }
                    } else if (comptime spec.width_star) {
                        for ([_]c_int{ -25, 0, 1, 25 }) |width|
                            try expectParity(format, .{ width, text });
                    } else if (comptime spec.precision_star) {
                        for ([_]c_int{ -1, 0, 1, 5, 40 }) |precision|
                            try expectParity(format, .{ precision, text });
                    } else {
                        try expectParity(format, .{text});
                    }
                }
            },
            'c' => for ([_]c_int{ 0, 'A', 255, 0x141, -1 }) |value| {
                try expectIntegerParity(format, value);
            },
            else => {
                const n = if (spec.length == .hh or spec.length == .h) @bitSizeOf(c_int) else bits(spec.length);
                if (comptime spec.conversion == 'd' or spec.conversion == 'i') {
                    const T = std.meta.Int(.signed, n);
                    for ([_]T{ std.math.minInt(T), -129, -1, 0, 1, 127, 255, std.math.maxInt(T) }) |value|
                        try expectIntegerParity(format, value);
                } else {
                    const T = std.meta.Int(.unsigned, n);
                    for ([_]T{ 0, 1, 15, 127, 255, 256, 65535, std.math.maxInt(T) }) |value|
                        try expectIntegerParity(format, value);
                }
            },
        }
    }
    inline for (inventory.unsupported) |format|
        try std.testing.expectError(error.UnsupportedConversion, validate(format));
}

test "printf flag precedence signedness precision and promotions match libc" {
    for ([_]c_int{ std.math.minInt(c_int), -123, -1, 0, 1, 123, std.math.maxInt(c_int) }) |value| {
        try expectParity("%+08d|% 08i|%-08d|%08.4d|%+5.0d", .{ value, value, value, value, value });
        for ([_]c_int{ -1, 0, 1, 10 }) |precision|
            try expectParity("%0*.*d", .{ @as(c_int, 12), precision, value });
    }
    for ([_]c_uint{ 0, 1, 15, 255, std.math.maxInt(c_uint) }) |value| {
        try expectParity("%#08x|%#08X|%#8.5x|%#.0o|%#.5o|%-#8o", .{ value, value, value, value, value, value });
    }
    try expectParity("%hhd %hhu %hd %hu", .{ @as(c_int, 255), @as(c_int, -1), @as(c_int, 65535), @as(c_int, -1) });
    try expectParity("%lld %llu %jd %ju %td %zu", .{
        @as(c_longlong, std.math.minInt(c_longlong)), @as(c_ulonglong, std.math.maxInt(c_ulonglong)),
        @as(c_longlong, -42),                         @as(c_ulonglong, 42),
        @as(isize, -42),                              @as(usize, 42),
    });

    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try print(&writer, "%d %u %02x %d", .{ @as(u8, 255), @as(u8, 255), @as(u8, 15), @as(i8, -1) });
    try std.testing.expectEqualStrings("255 255 0f -1", writer.buffered());
}

test "printf bounded strings and writer exhaustion do not truncate silently" {
    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const bytes = [_]u8{ 'a', 'b', 'c' };
    try print(&writer, "[%.*s]", .{ @as(c_int, 3), @as([*c]const u8, &bytes) });
    try std.testing.expectEqualStrings("[abc]", writer.buffered());
    writer.end = 0;
    try print(&writer, "[%.*s]", .{ @as(c_int, 3), @as([*]const u8, &bytes) });
    try std.testing.expectEqualStrings("[abc]", writer.buffered());
    writer.end = 0;
    try print(&writer, "[%-*s]", .{ @as(c_int, -8), @as([]const u8, "xy\x00ignored") });
    try std.testing.expectEqualStrings("[xy      ]", writer.buffered());
    var short: [2]u8 = undefined;
    var small = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.WriteFailed, print(&small, "%s", .{"long"}));
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, print(&failing, "%02x", .{@as(c_uint, 15)}));
}
