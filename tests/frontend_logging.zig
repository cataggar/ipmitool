//! A separate executable root calling the logger exported by the Zig archive.
const std = @import("std");
const c = @import("ipmi_c");
const log = @import("frontend_log");

pub fn main() void {
    log.print(c.LOG_NOTICE, "lazy %d", .{@as(c_int, 3)});
    c.log_init("ignored", 1, 2);

    var count: c_int = -1;
    log.print(c.LOG_INFO, "filtered%n", .{&count});
    log.perror(c.LOG_INFO, "filtered%n", .{&count});
    if (count != -1) std.process.exit(1);

    c.log_level_set(2);
    log.print(c.LOG_DEBUG, "%d: %#06x %-9.4s %+d %%", .{
        @as(c_int, 7), @as(c_uint, 42), @as([*:0]const u8, "leftover"), @as(c_int, 3),
    });
    c.lprintf(c.LOG_NOTICE, "ABI %d", @as(c_int, 11));

    std.c._errno().* = c.ENOENT;
    log.perror(c.LOG_ERR, "errno %s", .{@as([*:0]const u8, "native")});
    std.c._errno().* = c.EACCES;
    c.lperror(c.LOG_ERR, "ABI errno %d", @as(c_int, 5));
    std.c._errno().* = c.ENOENT;
    log.perror(c.LOG_ERR, "%lc", .{@as(c_uint, 0x110000)});

    const long: [*:0]const u8 = "x" ** (c.LOG_MSG_LENGTH + 8);
    log.print(c.LOG_NOTICE, "%s", .{long});

    c.log_halt();
    c.log_init("parity-daemon", 1, 1);
    log.print(c.LOG_INFO, "daemon %-4s %i", .{ @as([*:0]const u8, "yes"), @as(c_int, -2) });
    c.lprintf(c.LOG_NOTICE, "ABI daemon %u", @as(c_uint, 12));
    std.c._errno().* = c.ENOENT;
    log.perror(c.LOG_ERR, "daemon error", .{});
    c.log_halt();

    log.print(c.LOG_NOTICE, "reset", .{});
    c.log_halt();
}
