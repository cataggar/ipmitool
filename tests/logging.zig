//! The same script uses the C logger and the selected Zig logger. The latter
//! exports its C ABI from this root so the native and ABI paths share state.
const std = @import("std");
const c = @import("ipmi_c");
const log = @import("ipmi_zig").util.log;

comptime {
    for (@import("build_options").zig_modules) |module| {
        if (std.mem.eql(u8, module, "log")) log.exportSymbols();
    }
}

pub fn main() void {
    log.print(log.Level.notice, "lazy %d", .{@as(c_int, 3)});
    c.log_init("ignored", 1, 2);

    var count: c_int = -1;
    log.print(log.Level.info, "filtered%n", .{&count});
    log.perror(log.Level.info, "filtered%n", .{&count});
    if (count != -1) std.process.exit(1);

    c.log_level_set(2);
    log.print(log.Level.debug, "%d: %#06x %-9.4s %+d %%", .{
        @as(c_int, 7), @as(c_uint, 42), @as([*:0]const u8, "leftover"), @as(c_int, 3),
    });
    c.log_level_set(6);
    log.print(log.Level.debug + 4, "  Allocating %6zu entries", .{@as(usize, 42)});
    log.print(log.Level.debug + 4, "  [%6zu] %8d | %s", .{
        @as(usize, 42), @as(c_int, @bitCast(@as(u32, 0xffff_fffd))), @as([*:0]const u8, "Acme"),
    });
    log.print(log.Level.notice, "  %d\t0x%02x\t%s", .{
        @as(u32, 42), @as(u32, 42), @as([*:0]const u8, "Acme"),
    });
    c.lprintf(log.Level.notice, "ABI %d", @as(c_int, 11));

    std.c._errno().* = c.ENOENT;
    log.perror(log.Level.err, "errno %s", .{@as([*:0]const u8, "native")});
    std.c._errno().* = c.EACCES;
    c.lperror(log.Level.err, "ABI errno %d", @as(c_int, 5));
    std.c._errno().* = c.ENOENT;
    log.perror(log.Level.err, "%lc", .{@as(c_uint, 0x110000)});

    const long: [*:0]const u8 = "x" ** (log.msg_length + 8);
    log.print(log.Level.notice, "%s", .{long});

    c.log_halt();
    c.log_init("parity-daemon", 1, 1);
    log.print(log.Level.info, "daemon %-4s %i", .{ @as([*:0]const u8, "yes"), @as(c_int, -2) });
    c.lprintf(log.Level.notice, "ABI daemon %u", @as(c_uint, 12));
    std.c._errno().* = c.ENOENT;
    log.perror(log.Level.err, "daemon error", .{});
    c.log_halt();

    log.print(log.Level.notice, "reset", .{});
    c.log_halt();
}
