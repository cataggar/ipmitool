//! Test-only strtod oracle shared by helper and standalone parser coverage.
const std = @import("std");
const c = @import("ipmi_c");

pub const Result = struct {
    value: f64,
    err: c_int,
    end: usize,
    status: c_int,
};

pub fn parse(input: [*:0]const u8) Result {
    var end: [*c]u8 = null;
    std.c._errno().* = 0;
    const value = c.strtod(input, &end);
    const err = std.c._errno().*;
    return .{
        .value = value,
        .err = err,
        .end = @intFromPtr(end) - @intFromPtr(input),
        .status = if (end[0] != 0) -2 else if (err != 0) -3 else 0,
    };
}
