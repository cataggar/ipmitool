//! Frontend logging through the selected logger's single stateful archive.
const std = @import("std");
const c = @import("ipmi_c");

extern fn ipmitool_zig_log_enabled(level: c_int) callconv(.c) c_int;
extern fn ipmitool_zig_log_message(level: c_int, message: [*:0]const u8) callconv(.c) void;
extern fn ipmitool_zig_log_error(level: c_int, message: [*:0]const u8, errnum: c_int) callconv(.c) void;

fn zigLoggerSelected() bool {
    for (@import("build_options").zig_modules) |module| {
        if (std.mem.eql(u8, module, "log")) return true;
    }
    return false;
}

pub fn print(level: c_int, format: [*:0]const u8, args: anytype) void {
    if (comptime zigLoggerSelected()) {
        if (ipmitool_zig_log_enabled(level) == 0) return;
        var message: [c.LOG_MSG_LENGTH]u8 = undefined;
        message[0] = 0;
        _ = @call(.auto, c.snprintf, .{ &message, message.len, format } ++ args);
        message[message.len - 1] = 0;
        ipmitool_zig_log_message(level, @ptrCast(&message));
    } else {
        @call(.auto, c.lprintf, .{ level, format } ++ args);
    }
}

pub fn perror(level: c_int, format: [*:0]const u8, args: anytype) void {
    if (comptime zigLoggerSelected()) {
        if (ipmitool_zig_log_enabled(level) == 0) return;
        var message: [c.LOG_MSG_LENGTH]u8 = undefined;
        message[0] = 0;
        _ = @call(.auto, c.snprintf, .{ &message, message.len, format } ++ args);
        message[message.len - 1] = 0;
        ipmitool_zig_log_error(level, @ptrCast(&message), std.c._errno().*);
    } else {
        @call(.auto, c.lperror, .{ level, format } ++ args);
    }
}
