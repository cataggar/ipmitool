//! Port of `include/ipmitool/log.h`.
//!
//! `lib/log.c` is still C (issue #8 ports it), so the functions themselves come
//! from the `ipmi_c` bridge.  What lives here is the level namespace, checked
//! against `<syslog.h>` at comptime so a Zig caller never has to hardcode a
//! syslog number.

const std = @import("std");
const c = @import("ipmi_c");

/// `LOG_NAME_DEFAULT`.
pub const name_default = "ipmitool";

/// `LOG_MSG_LENGTH`.
pub const msg_length = 1024;

/// syslog priorities, plus the two aliases `log.h` adds.
pub const Level = struct {
    pub const emerg: c_int = c.LOG_EMERG;
    pub const alert: c_int = c.LOG_ALERT;
    pub const crit: c_int = c.LOG_CRIT;
    pub const err: c_int = c.LOG_ERR;
    pub const warning: c_int = c.LOG_WARNING;
    pub const notice: c_int = c.LOG_NOTICE;
    pub const info: c_int = c.LOG_INFO;
    pub const debug: c_int = c.LOG_DEBUG;

    /// `LOG_ERROR` in `log.h`.
    pub const @"error": c_int = c.LOG_ERR;
    /// `LOG_WARN` in `log.h`.
    pub const warn: c_int = c.LOG_WARNING;
};

comptime {
    if (Level.notice != 5) @compileError("unexpected LOG_NOTICE value");
    if (Level.debug != 7) @compileError("unexpected LOG_DEBUG value");
}

test "level aliases match log.h" {
    try std.testing.expectEqual(c.LOG_ERROR, Level.@"error");
    try std.testing.expectEqual(c.LOG_WARN, Level.warn);
    try std.testing.expectEqual(@as(c_int, c.LOG_MSG_LENGTH), msg_length);
    try std.testing.expectEqualStrings(c.LOG_NAME_DEFAULT, name_default);
}
