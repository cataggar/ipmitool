//! Port of `lib/ipmi_chassis.c`: the `chassis` command tree and the `power`
//! shortcut - power status and control, identify, POH counter, restart cause,
//! self test, power restore policy, and the whole Get/Set System Boot Options
//! surface including the boot initiator mailbox.
//!
//! Selected with `zig build -Dzig-modules=chassis`, which drops
//! `lib/ipmi_chassis.c` from the compile and links this module instead.
//! `src/ipmitool.c` reaches `ipmi_chassis_main()` and `ipmi_power_main()`
//! through `ipmitool_cmd_list[]`; the other four exported symbols keep their C
//! names for the same reason the C file exported them, even though nothing in
//! the tree currently calls them.
//!
//! Four things are worth knowing before reading on:
//!
//! * **Command results use checked Zig stdout.** Diagnostics use `log.print()`
//!   from the selected logger archive (or its C fallback). Boot mailbox
//!   request selectors use bounded, NUL-terminated Zig formatting; `printf`
//!   remains in tests to seed buffered C output. C-string comparisons,
//!   prefix checks and lengths use NUL-terminated Zig slices; `str2uchar`
//!   keeps its C arguments. Boot options split writable strings in place in
//!   Zig, matching `strtok_r`. The `power_usage` format is a constant.
//! * **The POH counter arithmetic is `float`, deliberately.**  C computes
//!   `minutes = (float)count * mins_per_count` and then splits it, so a large
//!   counter loses precision and reports a day count that integer arithmetic
//!   would never produce.  The port keeps `f32`.  `chassis_poh_precision` pins
//!   that with a counter whose exact and `f32` renderings differ.
//!
//!   One subtlety: `minutes -= (float)days * 1440` is a multiply followed by a
//!   subtract, which a C compiler is allowed to contract into a single FMA
//!   (clang does so on aarch64; it cannot on baseline x86-64) while Zig never
//!   does.  The golden fixtures therefore use counters for which `days * 1440`
//!   is itself exactly representable, so the fused and unfused results agree
//!   and the snapshot is neither arch- nor compiler-dependent.
//! * **Mailbox byte arguments are validated before writing.** An invalid
//!   byte in a later block fails without starting a partial mailbox write;
//!   text mode still writes the input string and its terminator.
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `chassis` is
//!   selected; see the note there.
//!
//! Allocation: `ipmi_chassis_set_bootparam()` builds its request with
//! `malloc`/`free` exactly as C does, so that the failure path and the request
//! length are identical.  Everything else is a local.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const stdout_io = @import("../util/stdout.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const netfn_chassis: u6 = 0x00;
const netfn_app: u6 = 0x06;

const IPMI_CHASSIS_CTL_POWER_DOWN: u8 = 0x0;
const IPMI_CHASSIS_CTL_POWER_UP: u8 = 0x1;
const IPMI_CHASSIS_CTL_POWER_CYCLE: u8 = 0x2;
const IPMI_CHASSIS_CTL_HARD_RESET: u8 = 0x3;
const IPMI_CHASSIS_CTL_PULSE_DIAG: u8 = 0x4;
const IPMI_CHASSIS_CTL_ACPI_SOFT: u8 = 0x5;

const IPMI_CHASSIS_POLICY_NO_CHANGE: u8 = 0x3;
const IPMI_CHASSIS_POLICY_ALWAYS_ON: u8 = 0x2;
const IPMI_CHASSIS_POLICY_PREVIOUS: u8 = 0x1;
const IPMI_CHASSIS_POLICY_ALWAYS_OFF: u8 = 0x0;

const IPMI_CHASSIS_BOOTPARAM_SET_IN_PROGRESS: u8 = 0;
const IPMI_CHASSIS_BOOTPARAM_FLAG_VALID: u8 = 3;
const IPMI_CHASSIS_BOOTPARAM_INFO_ACK: u8 = 4;
const IPMI_CHASSIS_BOOTPARAM_BOOT_FLAGS: u8 = 5;
const IPMI_CHASSIS_BOOTPARAM_INIT_MBOX: u8 = 7;

const IPMI_CC_OK: c_int = 0x00;
const IPMI_CC_PARAM_OUT_OF_RANGE: c_int = 0xc9;
const IPMI_CC_UNSPECIFIED_ERROR: c_int = 0xff;

const CHASSIS_BOOT_MBOX_IANA_SZ = 3;
const CHASSIS_BOOT_MBOX_BLOCK_SZ = 16;
const CHASSIS_BOOT_MBOX_BLOCK0_SZ = CHASSIS_BOOT_MBOX_BLOCK_SZ - CHASSIS_BOOT_MBOX_IANA_SZ;
const CHASSIS_BOOT_MBOX_MAX_BLOCK = 0xFF;
const CHASSIS_BOOT_MBOX_MAX_BLOCKS = CHASSIS_BOOT_MBOX_MAX_BLOCK + 1;

// Boot flags byte 1 bits.
const BF1_VALID: u8 = 1 << 7;
const BF1_PERSIST: u8 = 1 << 6;
const BF1_BOOT_TYPE_EFI: u8 = 1 << 5;

// Boot flags byte 2 bits.
const BF2_CMOS_CLEAR: u8 = 1 << 7;
const BF2_KEYLOCK: u8 = 1 << 6;
const BF2_BOOTDEV_SHIFT = 2;
const BF2_BOOTDEV_DEFAULT: u8 = 0 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_PXE: u8 = 1 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_HDD: u8 = 2 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_HDD_SAFE: u8 = 3 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_DIAG_PART: u8 = 4 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_CDROM: u8 = 5 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_SETUP: u8 = 6 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_REMOTE_FDD: u8 = 7 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_REMOTE_CDROM: u8 = 8 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_REMOTE_PRIMARY_MEDIA: u8 = 9 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_REMOTE_HDD: u8 = 11 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_FDD: u8 = 15 << BF2_BOOTDEV_SHIFT;
const BF2_BOOTDEV_MASK: u8 = 0xF << BF2_BOOTDEV_SHIFT;
const BF2_BLANK_SCREEN: u8 = 1 << 1;
const BF2_RESET_LOCKOUT: u8 = 1 << 0;

// Boot flags byte 3 bits.
const BF3_POWER_LOCKOUT: u8 = 1 << 7;
const BF3_VERBOSITY_SHIFT = 5;
const BF3_VERBOSITY_DEFAULT: u8 = 0 << BF3_VERBOSITY_SHIFT;
const BF3_VERBOSITY_QUIET: u8 = 1 << BF3_VERBOSITY_SHIFT;
const BF3_VERBOSITY_VERBOSE: u8 = 2 << BF3_VERBOSITY_SHIFT;
const BF3_VERBOSITY_MASK: u8 = 3 << BF3_VERBOSITY_SHIFT;
const BF3_EVENT_TRAPS: u8 = 1 << 4;
const BF3_PASSWD_BYPASS: u8 = 1 << 3;
const BF3_SLEEP_LOCKOUT: u8 = 1 << 2;
const BF3_CONSOLE_REDIR_SHIFT = 0;
const BF3_CONSOLE_REDIR_DEFAULT: u8 = 0 << BF3_CONSOLE_REDIR_SHIFT;
const BF3_CONSOLE_REDIR_SUPPRESS: u8 = 1 << BF3_CONSOLE_REDIR_SHIFT;
const BF3_CONSOLE_REDIR_ENABLE: u8 = 2 << BF3_CONSOLE_REDIR_SHIFT;
const BF3_CONSOLE_REDIR_MASK: u8 = 3 << BF3_CONSOLE_REDIR_SHIFT;

// Boot flags byte 4 bits.
const BF4_SHARED_MODE: u8 = 1 << 3;
const BF4_BIOS_MUX_SHIFT = 0;
const BF4_BIOS_MUX_DEFAULT: u8 = 0 << BF4_BIOS_MUX_SHIFT;
const BF4_BIOS_MUX_BMC: u8 = 1 << BF4_BIOS_MUX_SHIFT;
const BF4_BIOS_MUX_SYSTEM: u8 = 2 << BF4_BIOS_MUX_SHIFT;
const BF4_BIOS_MUX_MASK: u8 = 7 << BF4_BIOS_MUX_SHIFT;

// Offsets into the five byte boot flags block, from the macros
// bootdev_parse_options() uses to keep its table readable.
const BF1_OFFSET = 0;
const BF2_OFFSET = 1;
const BF3_OFFSET = 2;
const BF_BYTE_COUNT = 5;

/// `struct valstr`.
const ValStr = extern struct {
    val: u32,
    str: ?[*:0]const u8,
};

/// `get_bootparam_cc_vals[]`.
const get_bootparam_cc_vals = [_]ValStr{
    .{ .val = 0x80, .str = "Unsupported parameter" },
    .{ .val = 0x00, .str = null },
};

/// `set_bootparam_cc_vals[]`.
const set_bootparam_cc_vals = [_]ValStr{
    .{ .val = 0x80, .str = "Unsupported parameter" },
    .{ .val = 0x81, .str = "Attempt to set 'in progress' while not in 'complete' state" },
    .{ .val = 0x82, .str = "Parameter is read-only" },
    .{ .val = 0x00, .str = null },
};

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

fn bootparamCcString(ccode: u8, specific: []const ValStr) [*c]const u8 {
    return c.specific_val2str(ccode, @ptrCast(specific.ptr), c.completion_code_vals);
}

// A `?:` over two string literals yields a slice, which cannot cross a
// variadic boundary; this picks the NUL-terminated pointer instead.
fn pick(cond: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (cond) yes else no;
}

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    return intf.sendrecv.?(intf, req);
}

fn eqlArg(arg: [*:0]const u8, want: [*:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(arg), std.mem.span(want));
}

fn hasArgPrefix(arg: [*:0]const u8, prefix: [*:0]const u8) bool {
    return std.mem.startsWith(u8, std.mem.span(arg), std.mem.span(prefix));
}

test "chassis cstrings match libc equality prefixes and lengths" {
    const Oracle = struct {
        fn check(arg: [*:0]const u8, want: [*:0]const u8) !void {
            try std.testing.expectEqual(c.strcmp(arg, want) == 0, eqlArg(arg, want));
            try std.testing.expectEqual(c.strncmp(arg, want, std.mem.len(want)) == 0, hasArgPrefix(arg, want));
            try std.testing.expectEqual(c.strlen(arg), std.mem.len(arg));
        }
    };
    const words = [_][*:0]const u8{
        "",     "options=", "options", "options=PEF", "Options=PEF", "no-",         "no", "no-reset",
        "help", "help ",    "bootdev", "bootparam",   "persistent",  "verbose=yes",
    };
    for (words) |arg| {
        for (words) |want| try Oracle.check(arg, want);
    }
    for (0..256) |byte| {
        const arg = [_:0]u8{ @intCast(byte), 'o', '-', 'x' };
        for ([_][*:0]const u8{ "", "no-", "options=", "help" }) |want| {
            try Oracle.check(&arg, want);
        }
    }
    const hidden = [_:0]u8{ 'o', 'p', 't', 'i', 'o', 'n', 's', '=', 0, 'n', 'o', '-' };
    try Oracle.check(&hidden, "options=");
    try Oracle.check(&hidden, "options=PEF");
}

// ---------------------------------------------------------------------------
// Power status and control
// ---------------------------------------------------------------------------

/// `ipmi_chassis_power_status()` - the low bit of Get Chassis Status, or -1.
fn chassisPowerStatus(intf: *Intf) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x1;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Unable to get Chassis Power Status", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Get Chassis Power Status failed: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    return rsp.data[0] & 1;
}

/// `ipmi_chassis_print_power_status()`.
const PowerStatusOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisPowerStatus(writer: *std.Io.Writer, ps: c_int) std.Io.Writer.Error!void {
    try writer.writeAll("Chassis Power is ");
    try writer.writeAll(if (ps != 0) "on\n" else "off\n");
}

fn emitChassisPowerStatus(writer: *std.Io.Writer, ps: c_int, preflush: anytype) PowerStatusOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisPowerStatus(writer, ps) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisPrintPowerStatusTo(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) PowerStatusOutputError!c_int {
    const ps = chassisPowerStatus(intf);
    if (ps < 0) return -1;

    try emitChassisPowerStatus(writer, ps, preflush);
    return 0;
}

fn chassisPrintPowerStatus(intf: *Intf) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisPrintPowerStatusTo(intf, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis power status stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis power status stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis power status stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis power status stdout matches C bytes" {
    for ([_]c_int{ 0, 1 }) |ps| {
        var expected: [32]u8 = undefined;
        const n = c.snprintf(&expected, expected.len, "Chassis Power is %s\n", pick(ps != 0, "on", "off"));
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisPowerStatus(&writer, ps);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis power status stdout reports preflush, early, late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisPowerStatus(&writer, 1, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerStatus(&early, 1, Stub.preflushOk));
    var short: [17]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerStatus(&late, 1, Stub.preflushOk));
    try std.testing.expectEqualStrings("Chassis Power is ", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisPowerStatus(&writer, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("Chassis Power is off\n", writer.buffered());
}

test "chassis power status stdout orders buffered C around Zig results" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisPowerStatus(&stdout.interface, 0, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisPowerStatus(&stdout.interface, 1, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [100]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|Chassis Power is off\n|between|Chassis Power is on\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis power status preserves request and response statuses" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = true;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x1 and req.msg.data_len == 0);
            return if (present) &response else null;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]struct { status: u8, text: []const u8 }{
        .{ .status = 0, .text = "Chassis Power is off\n" },
        .{ .status = 1, .text = "Chassis Power is on\n" },
        .{ .status = 0xfe, .text = "Chassis Power is off\n" },
        .{ .status = 0xff, .text = "Chassis Power is on\n" },
    }) |case| {
        Stub.response = std.mem.zeroes(Response);
        Stub.response.data[0] = case.status;
        Stub.requests = 0;
        Stub.present = true;
        var storage: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, 0), try chassisPrintPowerStatusTo(&intf, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
    for ([_]bool{ false, true }) |present| {
        Stub.response.ccode = 0xc1;
        Stub.present = present;
        Stub.requests = 0;
        var storage: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisPrintPowerStatusTo(&intf, &writer, Stub.preflushFail));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

/// `ipmi_chassis_power_control()`.
const ControlOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisPowerControl(writer: *std.Io.Writer, ctl: u8) std.Io.Writer.Error!void {
    try writer.print("Chassis Power Control: {s}\n", .{
        std.mem.span(c.val2str(ctl, c.ipmi_chassis_power_control_vals)),
    });
}

fn emitChassisPowerControl(writer: *std.Io.Writer, ctl: u8, preflush: anytype) ControlOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisPowerControl(writer, ctl) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisPowerControlTo(intf: *Intf, ctl: u8, writer: *std.Io.Writer, preflush: anytype) ControlOutputError!c_int {
    var ctl_byte = ctl;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x2;
    req.msg.data = @ptrCast(&ctl_byte);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(
            log.Level.err,
            "Unable to set Chassis Power Control to %s",
            .{
                c.val2str(ctl, c.ipmi_chassis_power_control_vals),
            },
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(
            log.Level.err,
            "Set Chassis Power Control to %s failed: %s",
            .{
                c.val2str(ctl, c.ipmi_chassis_power_control_vals),
                ccString(rsp.ccode),
            },
        );
        return -1;
    }

    try emitChassisPowerControl(writer, ctl, preflush);
    return 0;
}

/// `ipmi_chassis_power_control()`.
fn chassisPowerControl(intf: *Intf, ctl: u8) callconv(.c) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisPowerControlTo(intf, ctl, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis control stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis control stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis control stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis control stdout matches C for all control bytes" {
    for (0..256) |value| {
        const ctl: u8 = @intCast(value);
        var expected: [96]u8 = undefined;
        const n = c.snprintf(
            &expected,
            expected.len,
            "Chassis Power Control: %s\n",
            c.val2str(ctl, c.ipmi_chassis_power_control_vals),
        );
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisPowerControl(&writer, ctl);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis control stdout propagates preflush, early, late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisPowerControl(&writer, IPMI_CHASSIS_CTL_POWER_UP, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerControl(&early, IPMI_CHASSIS_CTL_POWER_UP, Stub.preflushOk));
    var short: [23]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerControl(&late, IPMI_CHASSIS_CTL_POWER_UP, Stub.preflushOk));
    try std.testing.expectEqualStrings("Chassis Power Control: ", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisPowerControl(&writer, IPMI_CHASSIS_CTL_POWER_UP, Stub.preflushOk));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Chassis Power Control: "));
}

test "chassis control stdout orders buffered C and Zig output" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisPowerControl(&stdout.interface, IPMI_CHASSIS_CTL_POWER_UP, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisPowerControl(&stdout.interface, IPMI_CHASSIS_CTL_POWER_DOWN, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [160]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    var expected_storage: [160]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    try expected.writeAll("before|");
    try writeChassisPowerControl(&expected, IPMI_CHASSIS_CTL_POWER_UP);
    try expected.writeAll("|between|");
    try writeChassisPowerControl(&expected, IPMI_CHASSIS_CTL_POWER_DOWN);
    try expected.writeAll("|after\n");
    try std.testing.expectEqualStrings(expected.buffered(), captured[0..@intCast(length)]);
}

test "chassis control preserves request bytes and errors" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var ctl: u8 = 0;
        var present = false;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x2);
            std.debug.assert(req.msg.data_len == 1);
            ctl = req.msg.data.?[0];
            return if (present) &response else null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.requests = 0;
        Stub.response = std.mem.zeroes(Response);
        Stub.response.ccode = 0xc1;
        var storage: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisPowerControlTo(&intf, IPMI_CHASSIS_CTL_POWER_CYCLE, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(IPMI_CHASSIS_CTL_POWER_CYCLE, Stub.ctl);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
    Stub.present = true;
    Stub.requests = 0;
    Stub.response.ccode = 0;
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisPowerControlTo(&intf, IPMI_CHASSIS_CTL_POWER_UP, &writer, stdout_io.trySyncC));
    try std.testing.expectEqual(@as(usize, 1), Stub.requests);
    try std.testing.expectEqual(IPMI_CHASSIS_CTL_POWER_UP, Stub.ctl);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "Chassis Power Control: "));
}

// ---------------------------------------------------------------------------
// Identify
// ---------------------------------------------------------------------------

/// `ipmi_chassis_identify()`.
///
/// With no argument the request carries no data at all; with `force` it
/// carries both bytes so the BMC can reject the optional second one.
const IdentifyOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisIdentify(writer: *std.Io.Writer, has_arg: bool, forced: bool, interval: u8) std.Io.Writer.Error!void {
    try writer.writeAll("Chassis identify interval: ");
    if (!has_arg) {
        try writer.writeAll("default (15 seconds)\n");
    } else if (forced) {
        try writer.writeAll("indefinite\n");
    } else if (interval == 0) {
        try writer.writeAll("off\n");
    } else {
        try writer.print("{d} seconds\n", .{interval});
    }
}

fn emitChassisIdentify(writer: *std.Io.Writer, has_arg: bool, forced: bool, interval: u8, preflush: anytype) IdentifyOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisIdentify(writer, has_arg, forced, interval) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisIdentifyTo(intf: *Intf, arg: ?[*:0]const u8, writer: *std.Io.Writer, preflush: anytype) IdentifyOutputError!c_int {
    var identify_data = [2]u8{ 0, 0 };
    const interval = &identify_data[0];
    const force_on = &identify_data[1];

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x4;

    if (arg) |a| {
        if (eqlArg(a, "force")) {
            force_on.* = 1;
        } else {
            const rc = c.str2uchar(a, interval);
            if (rc != 0) {
                if (rc == -2) {
                    log.print(log.Level.err, "Invalid interval given.", .{});
                } else {
                    log.print(log.Level.err, "Given interval is too big.", .{});
                }
                return -1;
            }
        }
        req.msg.data = &identify_data;
        req.msg.data_len = if (force_on.* != 0) 2 else 1;
    }

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Unable to set Chassis Identify", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Set Chassis Identify failed: %s", .{ccString(rsp.ccode)});
        if (force_on.* != 0) {
            // Intel SE7501WV2 F/W 1.2 returns CC 0xC7, but the IPMI v1.5 spec
            // does not standardize a CC if unsupported, so we warn.
            log.print(log.Level.warning, "Chassis may not support Force Identify On\n", .{});
        }
        return -1;
    }

    try emitChassisIdentify(writer, arg != null, force_on.* != 0, interval.*, preflush);
    return 0;
}

/// `ipmi_chassis_identify()`.
fn chassisIdentify(intf: *Intf, arg: ?[*:0]const u8) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisIdentifyTo(intf, arg, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis identify stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis identify stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis identify stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis identify stdout matches C default, force, off and seconds" {
    for ([_]struct { has_arg: bool, forced: bool, interval: u8 }{
        .{ .has_arg = false, .forced = false, .interval = 0 },
        .{ .has_arg = true, .forced = true, .interval = 0 },
        .{ .has_arg = true, .forced = false, .interval = 0 },
        .{ .has_arg = true, .forced = false, .interval = 1 },
        .{ .has_arg = true, .forced = false, .interval = 15 },
        .{ .has_arg = true, .forced = false, .interval = 255 },
    }) |case| {
        var expected: [80]u8 = undefined;
        const n = if (!case.has_arg)
            c.snprintf(&expected, expected.len, "Chassis identify interval: default (15 seconds)\n")
        else if (case.forced)
            c.snprintf(&expected, expected.len, "Chassis identify interval: indefinite\n")
        else if (case.interval == 0)
            c.snprintf(&expected, expected.len, "Chassis identify interval: off\n")
        else
            c.snprintf(&expected, expected.len, "Chassis identify interval: %i seconds\n", @as(c_int, case.interval));
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [80]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisIdentify(&writer, case.has_arg, case.forced, case.interval);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis identify stdout propagates preflush, write and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [80]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisIdentify(&writer, true, false, 255, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisIdentify(&early, false, false, 0, Stub.preflushOk));
    var short: [27]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisIdentify(&late, true, true, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("Chassis identify interval: ", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisIdentify(&writer, true, false, 255, Stub.preflushOk));
    try std.testing.expectEqualStrings("Chassis identify interval: 255 seconds\n", writer.buffered());
}

test "chassis identify stdout orders buffered C around Zig results" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisIdentify(&stdout.interface, false, false, 0, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisIdentify(&stdout.interface, true, false, 255, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [160]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|Chassis identify interval: default (15 seconds)\n" ++
            "|between|Chassis identify interval: 255 seconds\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis identify preserves request lengths and statuses" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var last_len: u16 = 0;
        var data = [2]u8{ 0, 0 };
        var present = true;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x4);
            last_len = req.msg.data_len;
            if (last_len > 0) @memcpy(data[0..last_len], req.msg.data.?[0..last_len]);
            return if (present) &response else null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]struct { arg: ?[*:0]const u8, length: u16, interval: u8, forced: u8, text: []const u8 }{
        .{ .arg = null, .length = 0, .interval = 0, .forced = 0, .text = "Chassis identify interval: default (15 seconds)\n" },
        .{ .arg = "force", .length = 2, .interval = 0, .forced = 1, .text = "Chassis identify interval: indefinite\n" },
        .{ .arg = "0", .length = 1, .interval = 0, .forced = 0, .text = "Chassis identify interval: off\n" },
        .{ .arg = "255", .length = 1, .interval = 255, .forced = 0, .text = "Chassis identify interval: 255 seconds\n" },
    }) |case| {
        Stub.requests = 0;
        Stub.present = true;
        Stub.response = std.mem.zeroes(Response);
        var storage: [80]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, 0), try chassisIdentifyTo(&intf, case.arg, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(case.length, Stub.last_len);
        if (case.length > 0) try std.testing.expectEqual(case.interval, Stub.data[0]);
        if (case.length == 2) try std.testing.expectEqual(case.forced, Stub.data[1]);
        try std.testing.expectEqualStrings(case.text, writer.buffered());
    }
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.requests = 0;
        Stub.response.ccode = 0xc1;
        var storage: [80]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisIdentifyTo(&intf, "force", &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

// ---------------------------------------------------------------------------
// POH counter
// ---------------------------------------------------------------------------

const PohCounts = struct { days: u32, hours: u32, minutes: c_long };
const PohOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

/// The C arithmetic uses float and subtracts a float product before an
/// integer product; changing either rounding step changes large counters.
fn pohCounts(mins_per_count: u8, count: u32) PohCounts {
    var minutes: f32 = @as(f32, @floatFromInt(count)) * @as(f32, @floatFromInt(mins_per_count));
    const days: u32 = @intFromFloat(minutes / 1440);
    minutes -= @as(f32, @floatFromInt(days)) * 1440;
    const hours: u32 = @intFromFloat(minutes / 60);
    minutes -= @floatFromInt(hours *% 60);
    return .{ .days = days, .hours = hours, .minutes = @intFromFloat(minutes) };
}

fn writeChassisPoh(writer: *std.Io.Writer, mins_per_count: u8, count: u32) std.Io.Writer.Error!void {
    const poh = pohCounts(mins_per_count, count);
    try writer.print("POH Counter  : {d} days, {d} hours", .{ poh.days, poh.hours });
    if (mins_per_count < 60)
        try writer.print(", {d} minutes\n", .{poh.minutes})
    else
        try writer.writeByte('\n');
}

fn emitChassisPoh(writer: *std.Io.Writer, mins_per_count: u8, count: u32, preflush: anytype) PohOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisPoh(writer, mins_per_count, count) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisPohTo(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) PohOutputError!c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0xf;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Unable to get Chassis Power-On-Hours", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Get Chassis Power-On-Hours failed: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    const mins_per_count: u8 = rsp.data[0];
    const count = std.mem.readInt(u32, rsp.data[1..5], .little);

    try emitChassisPoh(writer, mins_per_count, count, preflush);
    return 0;
}

/// `ipmi_chassis_poh()`.
fn chassisPoh(intf: *Intf) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisPohTo(intf, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis POH stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis POH stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis POH stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis poh stdout matches libc output for count and minute boundaries" {
    for ([_]u8{ 0, 1, 5, 59, 60, 61, 255 }) |mins_per_count| {
        for ([_]u32{ 0, 1, 60, 1440, 0x01020304, 0xffffffff }) |count| {
            const poh = pohCounts(mins_per_count, count);
            var expected: [96]u8 = undefined;
            const n = if (mins_per_count < 60)
                c.snprintf(&expected, expected.len, "POH Counter  : %i days, %i hours, %li minutes\n", poh.days, poh.hours, poh.minutes)
            else
                c.snprintf(&expected, expected.len, "POH Counter  : %i days, %i hours\n", poh.days, poh.hours);
            try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
            var storage: [96]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try writeChassisPoh(&writer, mins_per_count, count);
            try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
        }
    }
}

test "chassis poh stdout propagates preflush early late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisPoh(&writer, 1, 5, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPoh(&early, 1, 5, Stub.preflushOk));
    var short: [30]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPoh(&late, 1, 5, Stub.preflushOk));
    try std.testing.expect(std.mem.startsWith(u8, late.buffered(), "POH Counter  : 0 days, "));
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisPoh(&writer, 60, 1, Stub.preflushOk));
    try std.testing.expectEqualStrings("POH Counter  : 0 days, 1 hours\n", writer.buffered());
}

test "chassis poh stdout orders buffered C around Zig results" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisPoh(&stdout.interface, 1, 5, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisPoh(&stdout.interface, 60, 1, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [160]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|POH Counter  : 0 days, 0 hours, 5 minutes\n|between|POH Counter  : 0 days, 1 hours\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis poh stdout retains request and response statuses" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = true;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0xf and req.msg.data_len == 0);
            return if (present) &response else null;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    Stub.response = std.mem.zeroes(Response);
    Stub.response.data[0] = 1;
    Stub.response.data[1] = 5;
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisPohTo(&intf, &writer, stdout_io.trySyncC));
    try std.testing.expectEqualStrings("POH Counter  : 0 days, 0 hours, 5 minutes\n", writer.buffered());
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.response.ccode = 0xc1;
        var empty: [96]u8 = undefined;
        var silent = std.Io.Writer.fixed(&empty);
        try std.testing.expectEqual(@as(c_int, -1), try chassisPohTo(&intf, &silent, Stub.preflushFail));
        try std.testing.expectEqual(@as(usize, 0), silent.buffered().len);
    }
    Stub.present = true;
    Stub.response.ccode = 0;
    var silent = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, chassisPohTo(&intf, &silent, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 4), Stub.requests);
}

// ---------------------------------------------------------------------------
// Restart cause, status, self test
// ---------------------------------------------------------------------------

/// `ipmi_chassis_restart_cause()`.
const RestartCauseOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisRestartCause(writer: *std.Io.Writer, cause: u8) std.Io.Writer.Error!void {
    try writer.print("System restart cause: {s}\n", .{
        std.mem.span(c.val2str(cause & 0x0f, c.ipmi_chassis_restart_cause_vals)),
    });
}

fn emitChassisRestartCause(writer: *std.Io.Writer, cause: u8, preflush: anytype) RestartCauseOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisRestartCause(writer, cause) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisRestartCauseTo(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) RestartCauseOutputError!c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x7;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Unable to get Chassis Restart Cause", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Get Chassis Restart Cause failed: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    try emitChassisRestartCause(writer, rsp.data[0], preflush);
    return 0;
}

/// `ipmi_chassis_restart_cause()`.
fn chassisRestartCause(intf: *Intf) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisRestartCauseTo(intf, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis restart cause stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis restart cause stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis restart cause stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis restart cause stdout matches C masked, known and unknown codes" {
    for (0..256) |value| {
        const cause: u8 = @intCast(value);
        var expected: [96]u8 = undefined;
        const n = c.snprintf(
            &expected,
            expected.len,
            "System restart cause: %s\n",
            c.val2str(cause & 0x0f, c.ipmi_chassis_restart_cause_vals),
        );
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisRestartCause(&writer, cause);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis restart cause stdout reports preflush, write and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisRestartCause(&writer, 0, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisRestartCause(&early, 0, Stub.preflushOk));
    var short: [22]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisRestartCause(&late, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("System restart cause: ", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisRestartCause(&writer, 0, Stub.preflushOk));
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "System restart cause: "));
}

test "chassis restart cause stdout orders buffered C and Zig output" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisRestartCause(&stdout.interface, 0x05, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [128]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    var expected_storage: [128]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    try expected.writeAll("before|");
    try writeChassisRestartCause(&expected, 0x05);
    try expected.writeAll("|after\n");
    try std.testing.expectEqualStrings(expected.buffered(), captured[0..@intCast(length)]);
}

test "chassis restart cause preserves request errors without stdout" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = false;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x7);
            return if (present) &response else null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.requests = 0;
        Stub.response = std.mem.zeroes(Response);
        Stub.response.ccode = 0xc1;
        var storage: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisRestartCauseTo(&intf, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

/// `ipmi_chassis_status()`.
const StatusOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisStatus(writer: *std.Io.Writer, rsp: *const Response) std.Io.Writer.Error!void {
    const status = rsp.data[0];
    try writer.print(
        "System Power         : {s}\n" ++
            "Power Overload       : {s}\n" ++
            "Power Interlock      : {s}\n" ++
            "Main Power Fault     : {s}\n" ++
            "Power Control Fault  : {s}\n",
        .{
            if (status & 0x01 != 0) "on" else "off",
            if (status & 0x02 != 0) "true" else "false",
            if (status & 0x04 != 0) "active" else "inactive",
            if (status & 0x08 != 0) "true" else "false",
            if (status & 0x10 != 0) "true" else "false",
        },
    );
    const policy: []const u8 = switch ((status & 0x60) >> 5) {
        0 => "always-off",
        1 => "previous",
        2 => "always-on",
        else => "unknown",
    };
    try writer.print("Power Restore Policy : {s}\n", .{policy});

    const events = rsp.data[1];
    try writer.writeAll("Last Power Event     : ");
    if (events & 0x01 != 0) try writer.writeAll("ac-failed ");
    if (events & 0x02 != 0) try writer.writeAll("overload ");
    if (events & 0x04 != 0) try writer.writeAll("interlock ");
    if (events & 0x08 != 0) try writer.writeAll("fault ");
    if (events & 0x10 != 0) try writer.writeAll("command");
    try writer.writeByte('\n');

    const faults = rsp.data[2];
    try writer.print(
        "Chassis Intrusion    : {s}\n" ++
            "Front-Panel Lockout  : {s}\n" ++
            "Drive Fault          : {s}\n" ++
            "Cooling/Fan Fault    : {s}\n",
        .{
            if (faults & 0x01 != 0) "active" else "inactive",
            if (faults & 0x02 != 0) "active" else "inactive",
            if (faults & 0x04 != 0) "true" else "false",
            if (faults & 0x08 != 0) "true" else "false",
        },
    );

    if (rsp.data_len > 3) {
        const panel = rsp.data[3];
        if (panel == 0) {
            try writer.writeAll("Front Panel Control  : none\n");
        } else {
            try writer.print(
                "Sleep Button Disable : {s}\n" ++
                    "Diag Button Disable  : {s}\n" ++
                    "Reset Button Disable : {s}\n" ++
                    "Power Button Disable : {s}\n" ++
                    "Sleep Button Disabled: {s}\n" ++
                    "Diag Button Disabled : {s}\n" ++
                    "Reset Button Disabled: {s}\n" ++
                    "Power Button Disabled: {s}\n",
                .{
                    if (panel & 0x80 != 0) "allowed" else "not allowed",
                    if (panel & 0x40 != 0) "allowed" else "not allowed",
                    if (panel & 0x20 != 0) "allowed" else "not allowed",
                    if (panel & 0x10 != 0) "allowed" else "not allowed",
                    if (panel & 0x08 != 0) "true" else "false",
                    if (panel & 0x04 != 0) "true" else "false",
                    if (panel & 0x02 != 0) "true" else "false",
                    if (panel & 0x01 != 0) "true" else "false",
                },
            );
        }
    }
}

fn emitChassisStatus(writer: *std.Io.Writer, rsp: *const Response, preflush: anytype) StatusOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisStatus(writer, rsp) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisStatusTo(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) StatusOutputError!c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x1;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error sending Chassis Status command", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error sending Chassis Status command: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    try emitChassisStatus(writer, rsp, preflush);
    return 0;
}

/// `ipmi_chassis_status()`.
fn chassisStatus(intf: *Intf) callconv(.c) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisStatusTo(intf, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis status stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis status stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis status stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis status stdout matches C fields, masks and optional panel" {
    for ([_]u8{ 0, 0x1f, 0x40, 0x60, 0xff }) |status| {
        for ([_]u8{ 0, 1, 0x0a, 0x10, 0xff }) |events| {
            for ([_]u8{ 0, 5, 0x0a, 0xff }) |faults| {
                for ([_]u8{ 0, 1, 0x80, 0x55, 0xff }) |panel| {
                    for ([_]c_int{ 3, 4, 5 }) |data_len| {
                        var rsp = std.mem.zeroes(Response);
                        rsp.data_len = data_len;
                        rsp.data[0] = status;
                        rsp.data[1] = events;
                        rsp.data[2] = faults;
                        rsp.data[3] = panel;
                        var expected: [900]u8 = undefined;
                        const policy: [*:0]const u8 = switch ((status & 0x60) >> 5) {
                            0 => "always-off",
                            1 => "previous",
                            2 => "always-on",
                            else => "unknown",
                        };
                        const first = c.snprintf(
                            &expected,
                            expected.len,
                            "System Power         : %s\n" ++
                                "Power Overload       : %s\n" ++
                                "Power Interlock      : %s\n" ++
                                "Main Power Fault     : %s\n" ++
                                "Power Control Fault  : %s\n" ++
                                "Power Restore Policy : %s\n" ++
                                "Last Power Event     : %s%s%s%s%s\n" ++
                                "Chassis Intrusion    : %s\n" ++
                                "Front-Panel Lockout  : %s\n" ++
                                "Drive Fault          : %s\n" ++
                                "Cooling/Fan Fault    : %s\n",
                            pick(status & 0x01 != 0, "on", "off"),
                            pick(status & 0x02 != 0, "true", "false"),
                            pick(status & 0x04 != 0, "active", "inactive"),
                            pick(status & 0x08 != 0, "true", "false"),
                            pick(status & 0x10 != 0, "true", "false"),
                            policy,
                            pick(events & 0x01 != 0, "ac-failed ", ""),
                            pick(events & 0x02 != 0, "overload ", ""),
                            pick(events & 0x04 != 0, "interlock ", ""),
                            pick(events & 0x08 != 0, "fault ", ""),
                            pick(events & 0x10 != 0, "command", ""),
                            pick(faults & 0x01 != 0, "active", "inactive"),
                            pick(faults & 0x02 != 0, "active", "inactive"),
                            pick(faults & 0x04 != 0, "true", "false"),
                            pick(faults & 0x08 != 0, "true", "false"),
                        );
                        try std.testing.expect(first > 0 and @as(usize, @intCast(first)) < expected.len);
                        var length: usize = @intCast(first);
                        if (data_len > 3) {
                            const next = if (panel == 0)
                                c.snprintf(@ptrCast(&expected[length]), expected.len - length, "Front Panel Control  : none\n")
                            else
                                c.snprintf(
                                    @ptrCast(&expected[length]),
                                    expected.len - length,
                                    "Sleep Button Disable : %s\n" ++
                                        "Diag Button Disable  : %s\n" ++
                                        "Reset Button Disable : %s\n" ++
                                        "Power Button Disable : %s\n" ++
                                        "Sleep Button Disabled: %s\n" ++
                                        "Diag Button Disabled : %s\n" ++
                                        "Reset Button Disabled: %s\n" ++
                                        "Power Button Disabled: %s\n",
                                    pick(panel & 0x80 != 0, "allowed", "not allowed"),
                                    pick(panel & 0x40 != 0, "allowed", "not allowed"),
                                    pick(panel & 0x20 != 0, "allowed", "not allowed"),
                                    pick(panel & 0x10 != 0, "allowed", "not allowed"),
                                    pick(panel & 0x08 != 0, "true", "false"),
                                    pick(panel & 0x04 != 0, "true", "false"),
                                    pick(panel & 0x02 != 0, "true", "false"),
                                    pick(panel & 0x01 != 0, "true", "false"),
                                );
                            try std.testing.expect(next > 0 and @as(usize, @intCast(next)) < expected.len - length);
                            length += @intCast(next);
                        }
                        var storage: [900]u8 = undefined;
                        var writer = std.Io.Writer.fixed(&storage);
                        try writeChassisStatus(&writer, &rsp);
                        try std.testing.expectEqualSlices(u8, expected[0..length], writer.buffered());
                    }
                }
            }
        }
    }
}

test "chassis status stdout propagates preflush, early, late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 4;
    rsp.data[0] = 0xff;
    rsp.data[1] = 0x1f;
    rsp.data[2] = 0xff;
    rsp.data[3] = 0xff;
    var storage: [900]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisStatus(&writer, &rsp, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisStatus(&early, &rsp, Stub.preflushOk));
    var short: [200]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisStatus(&late, &rsp, Stub.preflushOk));
    try std.testing.expect(std.mem.startsWith(u8, late.buffered(), "System Power         : on\n"));
    try std.testing.expect(late.buffered().len > 100);
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisStatus(&writer, &rsp, Stub.preflushOk));
    try std.testing.expect(writer.buffered().len > 400);
}

test "chassis status stdout orders buffered C around Zig fields" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 3;
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisStatus(&stdout.interface, &rsp, stdout_io.trySyncC);
    _ = c.printf("|between|");
    rsp.data_len = 4;
    rsp.data[3] = 0x55;
    try emitChassisStatus(&stdout.interface, &rsp, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [2048]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    var expected_storage: [2048]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    try expected.writeAll("before|");
    rsp.data_len = 3;
    try writeChassisStatus(&expected, &rsp);
    try expected.writeAll("|between|");
    rsp.data_len = 4;
    try writeChassisStatus(&expected, &rsp);
    try expected.writeAll("|after\n");
    try std.testing.expectEqualStrings(expected.buffered(), captured[0..@intCast(length)]);
}

test "chassis status preserves request errors without stdout" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = false;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x1);
            return if (present) &response else null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.requests = 0;
        Stub.response = std.mem.zeroes(Response);
        Stub.response.ccode = 0xc1;
        var storage: [900]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisStatusTo(&intf, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
    Stub.present = true;
    Stub.requests = 0;
    Stub.response.ccode = 0;
    Stub.response.data_len = 3;
    var storage: [900]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisStatusTo(&intf, &writer, stdout_io.trySyncC));
    try std.testing.expectEqual(@as(usize, 1), Stub.requests);
    try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), "System Power         : off\n"));
}

/// `broken_dev_vals[]`, a block local table in `ipmi_chassis_selftest()`.
const broken_dev_vals = [_]ValStr{
    .{ .val = 0, .str = "firmware corrupted" },
    .{ .val = 1, .str = "boot block corrupted" },
    .{ .val = 2, .str = "FRU Internal Use Area corrupted" },
    .{ .val = 3, .str = "SDR Repository empty" },
    .{ .val = 4, .str = "IPMB not responding" },
    .{ .val = 5, .str = "cannot access BMC FRU" },
    .{ .val = 6, .str = "cannot access SDR Repository" },
    .{ .val = 7, .str = "cannot access SEL Device" },
    .{ .val = 0xff, .str = null },
};

/// `ipmi_chassis_selftest()`.
const SelftestOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisSelftest(writer: *std.Io.Writer, code: u8, detail: u8) std.Io.Writer.Error!void {
    try writer.writeAll("Self Test Results    : ");
    switch (code) {
        0x55 => try writer.writeAll("passed\n"),
        0x56 => try writer.writeAll("not implemented\n"),
        0x57 => {
            try writer.writeAll("device error\n");
            for (broken_dev_vals[0..8], 0..) |entry, bit| {
                if (detail & (@as(u8, 1) << @intCast(bit)) != 0) {
                    try writer.print("                       [{s}]\n", .{std.mem.span(entry.str.?)});
                }
            }
        },
        0x58 => try writer.print("Fatal hardware error: {x:0>2}h\n", .{detail}),
        else => try writer.print("Device-specific failure {x:0>2}h:{x:0>2}h\n", .{ code, detail }),
    }
}

fn emitChassisSelftest(writer: *std.Io.Writer, code: u8, detail: u8, preflush: anytype) SelftestOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisSelftest(writer, code, detail) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisSelftestTo(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) SelftestOutputError!c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = 0x4;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error sending Get Self Test command", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error sending Get Self Test command: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    const code = rsp.data[0];
    const detail: u8 = if (code == 0x55 or code == 0x56) 0 else rsp.data[1];
    try emitChassisSelftest(writer, code, detail, preflush);
    return 0;
}

/// `ipmi_chassis_selftest()`.
fn chassisSelftest(intf: *Intf) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisSelftestTo(intf, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis selftest stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis selftest stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis selftest stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis selftest stdout matches C codes and failure bits" {
    for ([_]u8{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 0x55, 0xaa, 0xff }) |bits| {
        for ([_]u8{ 0x55, 0x56, 0x57, 0x58, 0x80 }) |code| {
            var expected: [512]u8 = undefined;
            const first = c.snprintf(&expected, expected.len, "Self Test Results    : ");
            try std.testing.expect(first > 0);
            var length: usize = @intCast(first);
            const next = switch (code) {
                0x55 => c.snprintf(@ptrCast(&expected[length]), expected.len - length, "passed\n"),
                0x56 => c.snprintf(@ptrCast(&expected[length]), expected.len - length, "not implemented\n"),
                0x57 => c.snprintf(@ptrCast(&expected[length]), expected.len - length, "device error\n"),
                0x58 => c.snprintf(@ptrCast(&expected[length]), expected.len - length, "Fatal hardware error: %02xh\n", @as(c_uint, bits)),
                else => c.snprintf(@ptrCast(&expected[length]), expected.len - length, "Device-specific failure %02xh:%02xh\n", @as(c_uint, code), @as(c_uint, bits)),
            };
            try std.testing.expect(next > 0 and @as(usize, @intCast(next)) < expected.len - length);
            length += @intCast(next);
            if (code == 0x57) {
                for (0..8) |bit| {
                    if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                    const n = c.snprintf(
                        @ptrCast(&expected[length]),
                        expected.len - length,
                        "                       [%s]\n",
                        c.val2str(@intCast(bit), @ptrCast(&broken_dev_vals)),
                    );
                    try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len - length);
                    length += @intCast(n);
                }
            }
            var storage: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try writeChassisSelftest(&writer, code, bits);
            try std.testing.expectEqualSlices(u8, expected[0..length], writer.buffered());
        }
    }
}

test "chassis selftest stdout reports preflush, write and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisSelftest(&writer, 0x57, 0xff, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisSelftest(&early, 0x55, 0, Stub.preflushOk));
    var short: [23]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisSelftest(&late, 0x57, 0xff, Stub.preflushOk));
    try std.testing.expectEqualStrings("Self Test Results    : ", late.buffered());
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisSelftest(&writer, 0x55, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("Self Test Results    : passed\n", writer.buffered());
}

test "chassis selftest stdout orders buffered C around Zig results" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisSelftest(&stdout.interface, 0x55, 0, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisSelftest(&stdout.interface, 0x58, 0x80, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [160]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|Self Test Results    : passed\n" ++
            "|between|Self Test Results    : Fatal hardware error: 80h\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis selftest preserves request errors without stdout" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = false;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_app and req.msg.cmd == 0x4);
            return if (present) &response else null;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.requests = 0;
        Stub.response = std.mem.zeroes(Response);
        Stub.response.ccode = 0xc1;
        var storage: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(@as(c_int, -1), try chassisSelftestTo(&intf, &writer, stdout_io.trySyncC));
        try std.testing.expectEqual(@as(usize, 1), Stub.requests);
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    }
}

// ---------------------------------------------------------------------------
// Set System Boot Options
// ---------------------------------------------------------------------------

/// `ipmi_chassis_set_bootparam()`.
///
/// Returns the completion code, or -1 when the request could not be sent or
/// the request buffer could not be allocated.
fn chassisSetBootparam(intf: *Intf, param: u8, data: [*]const u8, len: c_int) c_int {
    const BOOTPARAM_MASK: u8 = 0x7F;
    const msgsize: usize = @intCast(1 + len);

    var rc: c_int = -1;

    const raw = std.c.malloc(msgsize) orelse return rc;
    const msg_data: [*]u8 = @ptrCast(raw);
    defer std.c.free(raw);

    @memset(msg_data[0..msgsize], 0);
    msg_data[0] = param & BOOTPARAM_MASK;
    @memcpy(msg_data[1..msgsize], data[0..@intCast(len)]);

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x8;
    req.msg.data = msg_data;
    req.msg.data_len = @intCast(msgsize);

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error setting Chassis Boot Parameter %d", .{@as(c_int, param)});
        return -1;
    };

    rc = rsp.ccode;
    if (rc != 0) {
        if (param != 0) {
            log.print(
                log.Level.err,
                "Set Chassis Boot Parameter %d failed: %s",
                .{
                    @as(c_int, param),
                    bootparamCcString(rsp.ccode, &set_bootparam_cc_vals),
                },
            );
        }
        return rc;
    }

    log.print(
        log.Level.debug,
        "Chassis Set Boot Parameter %d to %s",
        .{
            @as(c_int, param),
            c.buf2str(data, len),
        },
    );

    return rc;
}

// ---------------------------------------------------------------------------
// Get System Boot Options
// ---------------------------------------------------------------------------

/// `chassis_bootparam_flags_t` and `chassis_bootmbox_parse_t`, as bit numbers.
const PARAM_NO_GENERIC_INFO = 0;
const PARAM_NO_DATA_DUMP = 1;
const PARAM_NO_RANGE_ERROR = 2;
const PARAM_SPECIFIC = 3;
const MBOX_PARSE_USE_TEXT = PARAM_SPECIFIC;
const MBOX_PARSE_ALLBLOCKS = PARAM_SPECIFIC + 1;

fn bpFlag(comptime bit: u5) c_int {
    return 1 << bit;
}

fn writeBootparamHex(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    // buf2str() has a 3073-byte static buffer and emits two digits per byte.
    for (bytes[0..@min(bytes.len, 1536)]) |byte|
        try writer.print("{x:0>2}", .{byte});
}

/// `chassis_bootmailbox_parse()`. `buf` starts with the block selector.
fn writeChassisBootmailbox(writer: *std.Io.Writer, buf: [*]const u8, len: usize, flags: c_int) std.Io.Writer.Error!void {
    const use_text = flags & bpFlag(MBOX_PARSE_USE_TEXT) != 0;
    const all_blocks = flags & bpFlag(MBOX_PARSE_ALLBLOCKS) != 0;

    if (len == 0) return;

    const block = buf[0];
    var blockdata: [*]const u8 = buf + 1;
    var datalen: usize = len - 1;

    if (!all_blocks) {
        // Print block selector only if a single block is printed.
        try writer.print(" Selector       : {d}\n", .{block});
    }
    if (block == 0) {
        const iana = c.ipmi24toh(@constCast(buf + 1));
        // For block zero print the IANA Private Enterprise Number.
        try writer.print(" IANA PEN       : {d} [{s}]\n", .{ iana, std.mem.span(c.val2str(iana, c.ipmi_oem_info)) });
        blockdata = buf + 1 + CHASSIS_BOOT_MBOX_IANA_SZ;
        datalen -%= CHASSIS_BOOT_MBOX_IANA_SZ;
    }

    try writer.writeAll(" Block ");
    if (all_blocks) {
        try writer.print("{d: >3} Data : ", .{block});
    } else {
        try writer.writeAll("Data     : ");
    }
    if (use_text) {
        // Ensure the data string is null-terminated.
        var text = [_]u8{0} ** (CHASSIS_BOOT_MBOX_BLOCK_SZ + 1);
        @memcpy(text[0..datalen], blockdata[0..datalen]);
        try writer.print("'{s}'\n", .{std.mem.sliceTo(text[0..], 0)});
    } else {
        try writeBootparamHex(writer, blockdata[0..datalen]);
        try writer.writeByte('\n');
    }
}

const BootparamOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn emitChassisBootparam(writer: *std.Io.Writer, rsp: *Response, flags: c_int, preflush: anytype) BootparamOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisBootparam(writer, rsp, flags) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

/// `ipmi_chassis_get_bootparam()`.
fn chassisGetBootparamTo(
    intf: *Intf,
    argc_in: c_int,
    argv_in: [*]const [*:0]const u8,
    flags: c_int,
    writer: *std.Io.Writer,
    preflush: anytype,
) BootparamOutputError!c_int {
    var argc = argc_in;
    var argv = argv_in;

    var param_id: u8 = 0;
    const skip_range = flags & bpFlag(PARAM_NO_RANGE_ERROR) != 0;

    if (argc < 1) return -1;

    if (c.str2uchar(argv[0], &param_id) != 0) {
        log.print(
            log.Level.err,
            "Invalid parameter '%s' given instead of bootparam.",
            .{
                argv[0],
            },
        );
        return -1;
    }

    argc -= 1;
    argv += 1;

    var msg_data = [3]u8{ 0, 0, 0 };
    msg_data[0] = param_id & 0x7f;

    if (argc != 0) {
        if (c.str2uchar(argv[0], &msg_data[1]) != 0) {
            log.print(
                log.Level.err,
                "Invalid argument '%s' given to bootparam %u",
                .{
                    argv[0],
                    @as(c_uint, msg_data[0]),
                },
            );
            return -1;
        }
    }

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x9;
    req.msg.data = &msg_data;
    req.msg.data_len = 3;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(
            log.Level.err,
            "Error Getting Chassis Boot Parameter %u",
            .{
                @as(c_uint, msg_data[0]),
            },
        );
        return -1;
    };
    if (rsp.ccode == IPMI_CC_PARAM_OUT_OF_RANGE and skip_range) {
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(
            log.Level.err,
            "Get Chassis Boot Parameter %u failed: %s",
            .{
                @as(c_uint, msg_data[0]),
                bootparamCcString(rsp.ccode, &get_bootparam_cc_vals),
            },
        );
        return -1;
    }

    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "Boot Option");

    try emitChassisBootparam(writer, rsp, flags, preflush);
    return IPMI_CC_OK;
}

fn chassisGetBootparam(
    intf: *Intf,
    argc: c_int,
    argv: [*]const [*:0]const u8,
    flags: c_int,
) BootparamOutputError!c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisGetBootparamTo(intf, argc, argv, flags, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis bootparam stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis bootparam stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis bootparam stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return err;
    };
}

fn writeChassisBootparam(writer: *std.Io.Writer, rsp: *Response, flags: c_int) std.Io.Writer.Error!void {
    const skip_generic = flags & bpFlag(PARAM_NO_GENERIC_INFO) != 0;
    const skip_data = flags & bpFlag(PARAM_NO_DATA_DUMP) != 0;
    const param_id = rsp.data[1] & 0x7f;

    if (!skip_generic) {
        try writer.print("Boot parameter version: {d}\n", .{rsp.data[0]});
        try writer.print("Boot parameter {d} is {s}\n", .{
            param_id,
            if (rsp.data[1] & 0x80 != 0) "invalid/locked" else "valid/unlocked",
        });
        if (!skip_data) {
            try writer.writeAll("Boot parameter data: ");
            try writeBootparamHex(writer, rsp.data[2..][0..@intCast(@max(rsp.data_len - 2, 0))]);
            try writer.writeByte('\n');
        }
    }

    switch (param_id) {
        0 => {
            try writer.writeAll(" Set In Progress : ");
            try writer.writeAll(switch (rsp.data[2] & 0x03) {
                0 => "set complete\n",
                1 => "set in progress\n",
                2 => "commit write\n",
                else => "error, reserved bit\n",
            });
        },
        1 => {
            try writer.writeAll(" Service Partition Selector : ");
            if (rsp.data[2] == 0) {
                try writer.writeAll("unspecified\n");
            } else {
                try writer.print("{d}\n", .{rsp.data[2]});
            }
        },
        2 => {
            try writer.writeAll(" Service Partition Scan :\n");
            if (rsp.data[2] & 0x03 != 0) {
                if (rsp.data[2] & 0x01 == 0x01)
                    try writer.writeAll("     - Request BIOS to scan\n");
                if (rsp.data[2] & 0x02 == 0x02)
                    try writer.writeAll("     - Service Partition Discovered\n");
            } else {
                try writer.writeAll("     No flag set\n");
            }
        },
        3 => {
            try writer.writeAll(" BMC boot flag valid bit clearing :\n");
            if (rsp.data[2] & 0x1f != 0) {
                if (rsp.data[2] & 0x10 == 0x10)
                    try writer.writeAll("     - Don't clear valid bit on reset/power cycle cause by PEF\n");
                if (rsp.data[2] & 0x08 == 0x08)
                    try writer.writeAll("     - Don't automatically clear boot flag valid bit on timeout\n");
                if (rsp.data[2] & 0x04 == 0x04)
                    try writer.writeAll("     - Don't clear valid bit on reset/power cycle cause by watchdog\n");
                if (rsp.data[2] & 0x02 == 0x02)
                    try writer.writeAll("     - Don't clear valid bit on push button reset // soft reset\n");
                if (rsp.data[2] & 0x01 == 0x01)
                    try writer.writeAll("     - Don't clear valid bit on power up via power push button or wake event\n");
            } else {
                try writer.writeAll("     No flag set\n");
            }
        },
        4 => {
            try writer.writeAll(" Boot Info Acknowledge :\n");
            if (rsp.data[3] & 0x1f != 0) {
                if (rsp.data[3] & 0x10 == 0x10)
                    try writer.writeAll("    - OEM has handled boot info\n");
                if (rsp.data[3] & 0x08 == 0x08)
                    try writer.writeAll("    - SMS has handled boot info\n");
                if (rsp.data[3] & 0x04 == 0x04)
                    try writer.writeAll("    - OS // service partition has handled boot info\n");
                if (rsp.data[3] & 0x02 == 0x02)
                    try writer.writeAll("    - OS Loader has handled boot info\n");
                if (rsp.data[3] & 0x01 == 0x01)
                    try writer.writeAll("    - BIOS/POST has handled boot info\n");
            } else {
                try writer.writeAll("     No flag set\n");
            }
        },
        5 => try writeBootFlags(writer, rsp),
        6 => {
            var session_id: c_ulong = @as(c_ulong, rsp.data[3]);
            session_id |= @as(c_ulong, rsp.data[4]) << 8;
            session_id |= @as(c_ulong, rsp.data[5]) << 16;
            session_id |= @as(c_ulong, rsp.data[6]) << 24;
            const timestamp = c.ipmi32toh(&rsp.data[7]);

            try writer.writeAll(" Boot Initiator Info :\n");
            try writer.print("    Channel Number : {d}\n", .{rsp.data[2] & 0x0f});
            try writer.print("    Session Id     : {X:0>8}h\n", .{session_id});
            try writer.print("    Timestamp      : {s}\n", .{std.mem.span(c.ipmi_timestamp_numeric(timestamp))});
        },
        7 => try writeChassisBootmailbox(
            writer,
            rsp.data[2..],
            @intCast(@max(rsp.data_len - 2, 0)),
            flags,
        ),
        else => try writer.print(" Unsupported parameter {d}\n", .{param_id}),
    }
}

/// The boot flags (parameter 5) decoder, split out of the `switch` above only
/// because it is long.
fn writeBootFlags(writer: *std.Io.Writer, rsp: *Response) std.Io.Writer.Error!void {
    try writer.writeAll(" Boot Flags :\n");

    if (rsp.data[2] & BF1_VALID != 0) {
        try writer.writeAll("   - Boot Flag Valid\n");
    } else {
        try writer.writeAll("   - Boot Flag Invalid\n");
    }

    if (rsp.data[2] & BF1_PERSIST != 0) {
        try writer.writeAll("   - Options apply to all future boots\n");
    } else {
        try writer.writeAll("   - Options apply to only next boot\n");
    }

    if (rsp.data[2] & BF1_BOOT_TYPE_EFI != 0) {
        try writer.writeAll("   - BIOS EFI boot \n");
    } else {
        try writer.writeAll("   - BIOS PC Compatible (legacy) boot \n");
    }

    if (rsp.data[3] & BF2_CMOS_CLEAR != 0) try writer.writeAll("   - CMOS Clear\n");
    if (rsp.data[3] & BF2_KEYLOCK != 0) try writer.writeAll("   - Lock Keyboard\n");
    try writer.writeAll("   - Boot Device Selector : ");
    try writer.writeAll(switch (rsp.data[3] & BF2_BOOTDEV_MASK) {
        BF2_BOOTDEV_DEFAULT => "No override\n",
        BF2_BOOTDEV_PXE => "Force PXE\n",
        BF2_BOOTDEV_HDD => "Force Boot from default Hard-Drive\n",
        BF2_BOOTDEV_HDD_SAFE => "Force Boot from default Hard-Drive, request Safe-Mode\n",
        BF2_BOOTDEV_DIAG_PART => "Force Boot from Diagnostic Partition\n",
        BF2_BOOTDEV_CDROM => "Force Boot from CD/DVD\n",
        BF2_BOOTDEV_SETUP => "Force Boot into BIOS Setup\n",
        BF2_BOOTDEV_REMOTE_FDD => "Force Boot from remotely connected Floppy/primary removable media\n",
        BF2_BOOTDEV_REMOTE_CDROM => "Force Boot from remotely connected CD/DVD\n",
        BF2_BOOTDEV_REMOTE_PRIMARY_MEDIA => "Force Boot from primary remote media\n",
        BF2_BOOTDEV_REMOTE_HDD => "Force Boot from remotely connected Hard-Drive\n",
        BF2_BOOTDEV_FDD => "Force Boot from Floppy/primary removable media\n",
        else => "Flag error\n",
    });
    if (rsp.data[3] & BF2_BLANK_SCREEN != 0) try writer.writeAll("   - Screen blank\n");
    if (rsp.data[3] & BF2_RESET_LOCKOUT != 0) try writer.writeAll("   - Lock out Reset buttons\n");

    if (rsp.data[4] & BF3_POWER_LOCKOUT != 0)
        try writer.writeAll("   - Lock out (power off/sleep request) via Power Button\n");

    try writer.writeAll("   - BIOS verbosity : ");
    try writer.writeAll(switch (rsp.data[4] & BF3_VERBOSITY_MASK) {
        BF3_VERBOSITY_DEFAULT => "System Default\n",
        BF3_VERBOSITY_QUIET => "Request Quiet Display\n",
        BF3_VERBOSITY_VERBOSE => "Request Verbose Display\n",
        else => "Flag error\n",
    });
    if (rsp.data[4] & BF3_EVENT_TRAPS != 0) try writer.writeAll("   - Force progress event traps\n");
    if (rsp.data[4] & BF3_PASSWD_BYPASS != 0) try writer.writeAll("   - User password bypass\n");
    if (rsp.data[4] & BF3_SLEEP_LOCKOUT != 0) try writer.writeAll("   - Lock Out Sleep Button\n");
    try writer.writeAll("   - Console Redirection control : ");
    try writer.writeAll(switch (rsp.data[4] & BF3_CONSOLE_REDIR_MASK) {
        BF3_CONSOLE_REDIR_DEFAULT => "Console redirection occurs per BIOS configuration setting (default)\n",
        BF3_CONSOLE_REDIR_SUPPRESS => "Suppress (skip) console redirection if enabled\n",
        BF3_CONSOLE_REDIR_ENABLE => "Request console redirection be enabled\n",
        else => "Flag error\n",
    });

    if (rsp.data[5] & BF4_SHARED_MODE != 0) try writer.writeAll("   - BIOS Shared Mode Override\n");
    try writer.writeAll("   - BIOS Mux Control Override : ");
    try writer.writeAll(switch (rsp.data[5] & BF4_BIOS_MUX_MASK) {
        BF4_BIOS_MUX_DEFAULT => "BIOS uses recommended setting of the mux at the end of POST\n",
        BF4_BIOS_MUX_BMC => "Requests BIOS to force mux to BMC at conclusion of POST/start of OS boot\n",
        BF4_BIOS_MUX_SYSTEM => "Requests BIOS to force mux to system at conclusion of POST/start of OS boot\n",
        else => "Flag error\n",
    });
}

test "chassis bootparam stdout hex matches libc buffer conversion and truncation" {
    var data: [1600]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = @truncate(index);
    for ([_]usize{ 0, 1, 16, 255, data.len }) |length| {
        var storage: [3100]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeBootparamHex(&writer, data[0..length]);
        try std.testing.expectEqualStrings(
            std.mem.span(c.buf2str(&data, @intCast(length))),
            writer.buffered(),
        );
    }
}

test "chassis bootparam stdout preserves generic fields flags and mailbox text" {
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 3;
    rsp.data[0] = 1;
    rsp.data[1] = 0x80;
    rsp.data[2] = 3;
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootparam(&writer, &rsp, 0);
    try std.testing.expectEqualStrings(
        "Boot parameter version: 1\nBoot parameter 0 is invalid/locked\n" ++
            "Boot parameter data: 03\n Set In Progress : error, reserved bit\n",
        writer.buffered(),
    );

    writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootparam(&writer, &rsp, bpFlag(PARAM_NO_DATA_DUMP));
    try std.testing.expectEqualStrings(
        "Boot parameter version: 1\nBoot parameter 0 is invalid/locked\n Set In Progress : error, reserved bit\n",
        writer.buffered(),
    );
    writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootparam(&writer, &rsp, bpFlag(PARAM_NO_GENERIC_INFO));
    try std.testing.expectEqualStrings(" Set In Progress : error, reserved bit\n", writer.buffered());

    rsp.data[1] = 8;
    writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootparam(&writer, &rsp, bpFlag(PARAM_NO_GENERIC_INFO));
    try std.testing.expectEqualStrings(" Unsupported parameter 8\n", writer.buffered());

    const block = [4]u8{ 1, 'A', 0, 'B' };
    writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootmailbox(&writer, &block, block.len, bpFlag(MBOX_PARSE_USE_TEXT));
    try std.testing.expectEqualStrings(" Selector       : 1\n Block Data     : 'A'\n", writer.buffered());
    writer = std.Io.Writer.fixed(&storage);
    try writeChassisBootmailbox(&writer, &block, block.len, bpFlag(MBOX_PARSE_ALLBLOCKS));
    try std.testing.expectEqualStrings(" Block   1 Data : 410042\n", writer.buffered());
}

test "chassis bootparam stdout propagates preflush early late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 6;
    rsp.data[0] = 1;
    rsp.data[1] = 5;
    rsp.data[2] = 0xff;
    rsp.data[3] = 0xff;
    rsp.data[4] = 0xff;
    rsp.data[5] = 0xff;
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisBootparam(&writer, &rsp, 0, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisBootparam(&early, &rsp, 0, Stub.preflushOk));
    var short: [280]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisBootparam(&late, &rsp, 0, Stub.preflushOk));
    try std.testing.expect(std.mem.indexOf(u8, late.buffered(), " Boot Flags :\n") != null);
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisBootparam(&writer, &rsp, 0, Stub.preflushOk));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " BIOS Mux Control Override : ") != null);
}

test "chassis bootparam stdout orders buffered C across Zig results" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    var rsp = std.mem.zeroes(Response);
    rsp.data_len = 3;
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisBootparam(&stdout.interface, &rsp, bpFlag(PARAM_NO_GENERIC_INFO), stdout_io.trySyncC);
    _ = c.printf("|between|");
    rsp.data[1] = 1;
    rsp.data[2] = 7;
    try emitChassisBootparam(&stdout.interface, &rsp, bpFlag(PARAM_NO_GENERIC_INFO), stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [192]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before| Set In Progress : set complete\n|between| Service Partition Selector : 7\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis bootparam stdout retains request and response statuses" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = true;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x9 and req.msg.data_len == 3);
            std.debug.assert(req.msg.data[0] == 0 and req.msg.data[1] == 0 and req.msg.data[2] == 0);
            return if (present) &response else null;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    Stub.response = std.mem.zeroes(Response);
    Stub.response.data_len = 3;
    const args = [_][*:0]const u8{"0"};
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisGetBootparamTo(&intf, args.len, &args, 0, &writer, stdout_io.trySyncC));
    try std.testing.expectEqualStrings(
        "Boot parameter version: 0\nBoot parameter 0 is valid/unlocked\n" ++
            "Boot parameter data: 00\n Set In Progress : set complete\n",
        writer.buffered(),
    );
    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.response.ccode = 0xc1;
        var empty: [128]u8 = undefined;
        var silent = std.Io.Writer.fixed(&empty);
        try std.testing.expectEqual(@as(c_int, -1), try chassisGetBootparamTo(&intf, args.len, &args, 0, &silent, Stub.preflushFail));
        try std.testing.expectEqual(@as(usize, 0), silent.buffered().len);
    }
    Stub.present = true;
    Stub.response.ccode = 0;
    var empty: [128]u8 = undefined;
    var silent = std.Io.Writer.fixed(&empty);
    try std.testing.expectError(error.CStdoutFlushFailed, chassisGetBootparamTo(&intf, args.len, &args, 0, &silent, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 4), Stub.requests);
}

// ---------------------------------------------------------------------------
// options= parsing for `bootparam set bootflag`
// ---------------------------------------------------------------------------

const BootparamOption = struct {
    name: [*:0]const u8,
    value: u8,
    desc: [*:0]const u8,
};

/// The `options[]` table inside `get_bootparam_options()`.
const bootparam_options = [_]BootparamOption{
    .{ .name = "PEF", .value = 0x10, .desc = "Clear valid bit on reset/power cycle cause by PEF" },
    .{ .name = "timeout", .value = 0x08, .desc = "Automatically clear boot flag valid bit on timeout" },
    .{ .name = "watchdog", .value = 0x04, .desc = "Clear valid bit on reset/power cycle cause by watchdog" },
    .{ .name = "reset", .value = 0x02, .desc = "Clear valid bit on push button reset/soft reset" },
    .{ .name = "power", .value = 0x01, .desc = "Clear valid bit on power up via power push button or wake event" },
};

const CommaTokens = struct {
    remaining: ?[*:0]u8,

    fn init(input: [*:0]u8) CommaTokens {
        return .{ .remaining = input };
    }

    fn next(self: *CommaTokens) ?[*:0]u8 {
        var cursor = self.remaining orelse return null;
        while (cursor[0] == ',') : (cursor += 1) {}
        if (cursor[0] == 0) {
            self.remaining = null;
            return null;
        }
        const token = cursor;
        while (cursor[0] != 0 and cursor[0] != ',') : (cursor += 1) {}
        if (cursor[0] == ',') {
            cursor[0] = 0;
            self.remaining = cursor + 1;
        } else {
            self.remaining = null;
        }
        return token;
    }
};

test "chassis comma tokens match libc token pointers and input mutations" {
    const Oracle = struct {
        fn check(input: []const u8) !void {
            var actual_bytes = [_]u8{0xa5} ** 128;
            try std.testing.expect(input.len < actual_bytes.len);
            @memcpy(actual_bytes[0..input.len], input);
            actual_bytes[input.len] = 0;
            var expected_bytes = actual_bytes;
            var tokens = CommaTokens.init(@ptrCast(&actual_bytes));
            var saveptr: [*c]u8 = null;
            var first = true;
            while (true) {
                const expected = c.strtok_r(if (first) @ptrCast(&expected_bytes) else null, ",", &saveptr);
                first = false;
                const actual = tokens.next();
                try std.testing.expectEqual(expected == null, actual == null);
                try std.testing.expectEqualSlices(u8, &expected_bytes, &actual_bytes);
                if (expected == null) break;
                try std.testing.expectEqual(
                    @intFromPtr(expected) - @intFromPtr(&expected_bytes),
                    @intFromPtr(actual.?) - @intFromPtr(&actual_bytes),
                );
                try std.testing.expectEqualStrings(std.mem.span(expected), std.mem.span(actual.?));
            }
        }
    };

    for ([_][]const u8{
        "",        ",",        ",,,",              "help",                           "a,", ",a", "a,,b", ",a,b,,c,", "options=,,PEF,no-watchdog,",
        "a\x00,b", "a,\x00,b", "a,,help,,ignored", "verbose=yes,cons_redirect=skip",
    }) |input| try Oracle.check(input);
    for (0..256) |byte| {
        const input = [_]u8{ 'a', @intCast(byte), ',', 'b', ',', 'c' };
        try Oracle.check(&input);
    }
}

/// `get_bootparam_options()`.
///
/// `optstring` must be writable: option commas are split in place, exactly as
/// in C.  The only caller that passes a literal is
/// `ipmi_chassis_set_bootflag_help()`, whose "options=help" contains no comma
/// and so is never written to.
fn getBootparamOptions(optstring: [*:0]u8, set_flag: *u8, clr_flag: *u8) c_int {
    var option_error = false;
    set_flag.* = 0;
    clr_flag.* = 0;

    const optkw: [*:0]const u8 = "options=";
    if (!hasArgPrefix(optstring, optkw)) {
        log.print(log.Level.err, "No options= keyword found \"%s\"", .{optstring});
        return -1;
    }

    var tokens = CommaTokens.init(optstring + 8);
    while (tokens.next()) |token| {
        var setbit = false;
        var name: [*:0]u8 = token;
        if (eqlArg(name, "help")) {
            option_error = true;
            break;
        }
        if (hasArgPrefix(name, "no-")) {
            setbit = true;
            name += 3;
        }
        var found = false;
        for (bootparam_options) |op| {
            if (eqlArg(name, op.name)) {
                if (setbit) {
                    set_flag.* |= op.value;
                } else {
                    clr_flag.* |= op.value;
                }
                found = true;
                break;
            }
        }
        if (!found) {
            // Option not found.
            option_error = true;
            if (setbit) name -= 3;
            log.print(log.Level.err, "Invalid option: %s", .{name});
        }
    }

    if (option_error) {
        log.print(log.Level.notice, " Legal options are:", .{});
        log.print(log.Level.notice, "  %-8s: print this message", .{@as([*:0]const u8, "help")});
        for (bootparam_options) |op| {
            log.print(log.Level.notice, "  %-8s: %s", .{ op.name, op.desc });
        }
        log.print(log.Level.notice, " Any Option may be prepended with no- to invert sense of operation\n", .{});
        return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Boot valid flag and boot device
// ---------------------------------------------------------------------------

/// `ipmi_chassis_get_bootvalid()` - the current parameter 3 byte, or -1.
fn chassisGetBootvalid(intf: *Intf) c_int {
    const param_id: u8 = IPMI_CHASSIS_BOOTPARAM_FLAG_VALID;
    var msg_data = [3]u8{ param_id & 0x7f, 0, 0 };

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x9;
    req.msg.data = &msg_data;
    req.msg.data_len = 3;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(
            log.Level.err,
            "Error Getting Chassis Boot Parameter %d",
            .{
                @as(c_int, param_id),
            },
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(
            log.Level.err,
            "Get Chassis Boot Parameter %d failed: %s",
            .{
                @as(c_int, param_id),
                bootparamCcString(rsp.ccode, &get_bootparam_cc_vals),
            },
        );
        return -1;
    }

    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "Boot Option");

    return rsp.data[2];
}

/// `progress_t`.
const SET_COMPLETE: u8 = 0;
const SET_IN_PROGRESS: u8 = 1;
const COMMIT_WRITE: u8 = 2;

/// `chassis_bootparam_set_in_progress.use_progress`, a function local static.
var use_progress: bool = true;

/// `chassis_bootparam_set_in_progress()`.
fn chassisBootparamSetInProgress(intf: *Intf, progress: u8) void {
    if (!use_progress) return;

    var flag = progress;
    const rc = chassisSetBootparam(
        intf,
        IPMI_CHASSIS_BOOTPARAM_SET_IN_PROGRESS,
        @ptrCast(&flag),
        1,
    );

    // Only disable future checks if set in progress status setting failed.
    // Setting of other statuses may fail legitimately.
    if (rc != 0 and progress == SET_IN_PROGRESS) use_progress = false;
}

/// `bootinfo_ack_t`.
const BIOS_POST_ACK: u8 = 1 << 0;
const OS_LOADER_ACK: u8 = 1 << 1;
const RESERVED_ACK_MASK: u8 = 7 << 5;

/// `chassis_bootparam_clear_ack()`.
fn chassisBootparamClearAck(intf: *Intf, flag: u8) c_int {
    const flags = [2]u8{ flag & ~RESERVED_ACK_MASK, flag & ~RESERVED_ACK_MASK };
    return chassisSetBootparam(intf, IPMI_CHASSIS_BOOTPARAM_INFO_ACK, &flags, 2);
}

/// `ipmi_chassis_set_bootvalid()`.
fn chassisSetBootvalid(intf: *Intf, set_flag: u8, clr_flag: u8) c_int {
    var rc: c_int = undefined;

    chassisBootparamSetInProgress(intf, SET_IN_PROGRESS);
    rc = chassisBootparamClearAck(intf, BIOS_POST_ACK);

    if (rc == 0) {
        const bootvalid = chassisGetBootvalid(intf);
        if (bootvalid < 0) {
            log.print(log.Level.err, "Failed to read boot valid flag", .{});
            rc = bootvalid;
        } else {
            const flags = [1]u8{(@as(u8, @intCast(bootvalid)) & ~clr_flag) | set_flag};
            rc = chassisSetBootparam(intf, IPMI_CHASSIS_BOOTPARAM_FLAG_VALID, &flags, 1);
            if (rc == IPMI_CC_OK) chassisBootparamSetInProgress(intf, COMMIT_WRITE);
        }
    }

    chassisBootparamSetInProgress(intf, SET_COMPLETE);
    return rc;
}

/// `ipmi_chassis_set_bootdev()`.
fn writeChassisBootdevAck(writer: *std.Io.Writer, arg: ?[*:0]const u8) std.Io.Writer.Error!void {
    try writer.print("Set Boot Device to {s}\n", .{if (arg) |value| std.mem.span(value) else "(null)"});
}

fn emitChassisBootdevAck(writer: *std.Io.Writer, arg: ?[*:0]const u8, preflush: anytype) BootparamOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisBootdevAck(writer, arg) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisSetBootdevTo(
    intf: *Intf,
    arg: ?[*:0]const u8,
    iflags: ?*const [BF_BYTE_COUNT]u8,
    writer: *std.Io.Writer,
    preflush: anytype,
) BootparamOutputError!c_int {
    var flags = [_]u8{0} ** BF_BYTE_COUNT;
    var rc: c_int = undefined;
    var output_error: ?BootparamOutputError = null;

    chassisBootparamSetInProgress(intf, SET_IN_PROGRESS);
    rc = chassisBootparamClearAck(intf, BIOS_POST_ACK);

    if (rc >= 0) {
        if (iflags) |f| flags = f.*;

        var known = true;
        if (arg) |a| {
            if (eqlArg(a, "none")) {
                flags[1] |= 0x00;
            } else if (eqlArg(a, "pxe") or eqlArg(a, "force_pxe")) {
                flags[1] |= 0x04;
            } else if (eqlArg(a, "disk") or eqlArg(a, "force_disk")) {
                flags[1] |= 0x08;
            } else if (eqlArg(a, "safe") or eqlArg(a, "force_safe")) {
                flags[1] |= 0x0c;
            } else if (eqlArg(a, "diag") or eqlArg(a, "force_diag")) {
                flags[1] |= 0x10;
            } else if (eqlArg(a, "cdrom") or eqlArg(a, "force_cdrom")) {
                flags[1] |= 0x14;
            } else if (eqlArg(a, "remotecd") or eqlArg(a, "force_remotecd")) {
                flags[1] |= 0x20;
            } else if (eqlArg(a, "floppy") or eqlArg(a, "force_floppy")) {
                flags[1] |= 0x3c;
            } else if (eqlArg(a, "bios") or eqlArg(a, "force_bios")) {
                flags[1] |= 0x18;
            } else {
                log.print(log.Level.err, "Invalid argument: %s", .{a});
                rc = -1;
                known = false;
            }
        } else {
            flags[1] |= 0x00;
        }

        if (known) {
            // set flag valid bit
            flags[0] |= 0x80;

            rc = chassisSetBootparam(
                intf,
                IPMI_CHASSIS_BOOTPARAM_BOOT_FLAGS,
                &flags,
                BF_BYTE_COUNT,
            );
            if (rc == IPMI_CC_OK) {
                chassisBootparamSetInProgress(intf, COMMIT_WRITE);
                emitChassisBootdevAck(writer, arg, preflush) catch |err| {
                    output_error = err;
                };
            }
        }
    }

    chassisBootparamSetInProgress(intf, SET_COMPLETE);
    if (output_error) |err| return err;
    return rc;
}

fn chassisSetBootdev(intf: *Intf, arg: ?[*:0]const u8, iflags: ?*const [BF_BYTE_COUNT]u8) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisSetBootdevTo(intf, arg, iflags, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis bootdev stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis bootdev stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis bootdev stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis bootdev stdout matches C acknowledgment bytes" {
    for ([_]?[*:0]const u8{ "none", "pxe", "force_pxe", "disk", "force_disk", "remotecd", null }) |arg| {
        var expected: [96]u8 = undefined;
        const n = c.snprintf(&expected, expected.len, "Set Boot Device to %s\n", arg);
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var storage: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisBootdevAck(&writer, arg);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis bootdev stdout propagates preflush write and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisBootdevAck(&writer, "force_pxe", Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisBootdevAck(&early, "force_pxe", Stub.preflushOk));
    var short: [25]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisBootdevAck(&late, "force_pxe", Stub.preflushOk));
    try std.testing.expectEqualStrings("Set Boot Device to ", late.buffered()[0..19]);
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisBootdevAck(&writer, "force_pxe", Stub.preflushOk));
    try std.testing.expectEqualStrings("Set Boot Device to force_pxe\n", writer.buffered());
}

test "chassis bootdev stdout keeps set complete after output failures" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: [5]u8 = undefined;
        var count: usize = 0;
        var fail_flags = false;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x8);
            std.debug.assert(count < requests.len);
            requests[count] = req.msg.data[0];
            count += 1;
            response.ccode = if (fail_flags and count == 3) 0xc1 else 0;
            return &response;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn preflushOk() error{CStdoutFlushFailed}!void {}
    };
    const original_progress = use_progress;
    defer use_progress = original_progress;
    use_progress = true;
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    Stub.count = 0;
    Stub.fail_flags = false;
    try std.testing.expectError(error.CStdoutFlushFailed, chassisSetBootdevTo(&intf, "pxe", null, &writer, Stub.preflushFail));
    try std.testing.expectEqualSlices(u8, &.{ 0, 4, 5, 0, 0 }, Stub.requests[0..Stub.count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    Stub.count = 0;
    Stub.fail_flags = true;
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0xc1), try chassisSetBootdevTo(&intf, "pxe", null, &writer, Stub.preflushFail));
    try std.testing.expectEqualSlices(u8, &.{ 0, 4, 5, 0 }, Stub.requests[0..Stub.count]);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    Stub.count = 0;
    Stub.fail_flags = false;
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisSetBootdevTo(&intf, "pxe", null, &writer, Stub.preflushOk));
    try std.testing.expectEqualStrings("Set Boot Device to pxe\n", writer.buffered());
    try std.testing.expectEqualSlices(u8, &.{ 0, 4, 5, 0, 0 }, Stub.requests[0..Stub.count]);
}

test "chassis bootdev stdout orders buffered C around Zig acknowledgment" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisBootdevAck(&stdout.interface, "pxe", stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [96]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings("before|Set Boot Device to pxe\n|after\n", captured[0..@intCast(length)]);
}

// ---------------------------------------------------------------------------
// Boot initiator mailbox
// ---------------------------------------------------------------------------

/// `mbox_t`: the block selector followed by sixteen bytes, whose first three
/// are the IANA PEN when the selector is zero.
const Mbox = extern struct {
    block: u8,
    data: [CHASSIS_BOOT_MBOX_BLOCK_SZ]u8,
};

/// `chassis_bootmailbox_help()`.
fn chassisBootmailboxHelp() void {
    const usage =
        \\bootmbox get [text] [block <block>]
        \\  Read the entire Boot Initiator Mailbox or the specified <block>.
        \\  If 'text' option is specified, the data is output as plain text, otherwise
        \\  hex dump mode is used.
        \\
        \\bootmbox set text [block <block>] <IANA_PEN> "<data_string>"
        \\bootmbox set [block <block>] <IANA_PEN> <data_byte> [<data_byte> ...]
        \\  Write the specified <block> or the entire Boot Initiator Mailbox.
        \\  It is required to specify a decimal IANA Enterprise Number recognized
        \\  by the boot initiator on the target system. Refer to your target system
        \\  manufacturer for details. The rest of the arguments are either separate
        \\  data byte values separated by spaces, or a single text string argument.
        \\
        \\  When single block write is requested, the total length of <data> may not
        \\  exceed 13 bytes for block 0, or 16 bytes otherwise.
        \\
        \\bootmbox help
        \\  Show this help.
    ;
    log.print(log.Level.notice, usage, .{});
}

/// `chassis_set_bootmailbox()`.
fn chassisSetBootmailbox(
    intf: *Intf,
    block_in: i16,
    use_text: bool,
    argc_in: c_int,
    argv_in: [*]const [*:0]u8,
) c_int {
    var block = block_in;
    var argc = argc_in;
    var argv = argv_in;

    var rc: c_int = -1;
    var iana: i32 = 0;
    var blocks: usize = 0;
    var datasize: usize = 0;
    var string_offset: usize = 0;

    log.print(log.Level.info, "Writing Boot Mailbox...", .{});

    if (argc < 1 or c.str2int(argv[0], &iana) != 0) {
        log.print(log.Level.err, "No valid IANA PEN specified!\n", .{});
        chassisBootmailboxHelp();
        return rc;
    }
    argv += 1;
    argc -= 1;

    if (argc < 1) {
        log.print(log.Level.err, "No data provided!\n", .{});
        chassisBootmailboxHelp();
        return rc;
    }

    // For text mode the size is the single argument string length plus one
    // byte for \0 termination.  For byte mode it is the number of byte
    // arguments without any additional termination.
    if (!use_text) {
        datasize = @intCast(argc);
    } else {
        datasize = std.mem.len(argv[0]) + 1;
    }

    log.print(log.Level.info, "Data size: %u", .{datasize});

    // Decide how many blocks we will be writing.
    if (block >= 0) {
        blocks = 1;
    } else {
        blocks = CHASSIS_BOOT_MBOX_IANA_SZ;
        blocks += datasize;
        blocks += CHASSIS_BOOT_MBOX_BLOCK_SZ - 1;
        blocks /= CHASSIS_BOOT_MBOX_BLOCK_SZ;

        block = 0;
    }

    log.print(log.Level.info, "Blocks to write: %d", .{blocks});

    if (blocks > CHASSIS_BOOT_MBOX_MAX_BLOCKS) {
        log.print(
            log.Level.err,
            "Data size %zu exceeds maximum (%d)",
            .{
                datasize,
                @as(c_int, (CHASSIS_BOOT_MBOX_BLOCK_SZ * CHASSIS_BOOT_MBOX_MAX_BLOCKS) -
                    CHASSIS_BOOT_MBOX_IANA_SZ),
            },
        );
        return rc;
    }

    // Check all byte arguments before writing any mailbox block.
    if (!use_text) {
        for (0..@as(usize, @intCast(argc))) |i| {
            var byte: u8 = 0;
            if (c.str2uchar(argv[i], &byte) != 0) {
                log.print(log.Level.err, "Bad byte value: %s", .{argv[i]});
                return rc;
            }
        }
    }

    // Indicate that we're touching the boot parameters.
    chassisBootparamSetInProgress(intf, SET_IN_PROGRESS);

    var bindex: usize = 0;
    var hit_error = false;
    while (datasize > 0 and bindex < blocks) : ({
        bindex += 1;
        block +%= 1;
    }) {
        var mbox = Mbox{ .block = @truncate(@as(u16, @bitCast(block))), .data = .{0} ** CHASSIS_BOOT_MBOX_BLOCK_SZ };

        var data: [*]u8 = &mbox.data;
        var maxblocksize: usize = CHASSIS_BOOT_MBOX_BLOCK_SZ;

        // Block 0 needs special care as it has IANA PEN specifier.
        if (block == 0) {
            data = mbox.data[CHASSIS_BOOT_MBOX_IANA_SZ..];
            maxblocksize = CHASSIS_BOOT_MBOX_BLOCK0_SZ;
            c.htoipmi24(@bitCast(iana), &mbox.data);
        }

        const blocksize = if (datasize > maxblocksize) maxblocksize else datasize;
        datasize -= blocksize;

        if (!use_text) {
            _ = c.args2buf(argc, @ptrCast(@constCast(argv)), data, blocksize);
            argc -= @intCast(blocksize);
            argv += blocksize;
        } else {
            @memcpy(data[0..blocksize], argv[0][string_offset..][0..blocksize]);
            string_offset += blocksize;
        }

        log.print(
            log.Level.info,
            "Block %3d: %s",
            .{
                @as(c_int, block),
                c.buf2str_extended(data, @intCast(blocksize), " "),
            },
        );

        const unused = maxblocksize - blocksize;
        rc = chassisSetBootparam(
            intf,
            IPMI_CHASSIS_BOOTPARAM_INIT_MBOX,
            @ptrCast(&mbox),
            @intCast(@sizeOf(Mbox) - unused),
        );
        if (rc == IPMI_CC_PARAM_OUT_OF_RANGE) {
            log.print(log.Level.err, "Hit end of mailbox writing block %d", .{@as(c_int, block)});
        }
        if (rc != 0) {
            hit_error = true;
            break;
        }
    }

    if (!hit_error) {
        log.print(log.Level.info, "Wrote %zu blocks of Boot Initiator Mailbox", .{blocks});
        chassisBootparamSetInProgress(intf, COMMIT_WRITE);

        rc = chassisBootparamClearAck(intf, BIOS_POST_ACK | OS_LOADER_ACK);
    }

    chassisBootparamSetInProgress(intf, SET_COMPLETE);
    return rc;
}

/// `chassis_get_bootmailbox()`.
fn formatBootmailboxParam(param_str: *[2]u8) void {
    _ = std.fmt.bufPrintSentinel(param_str, "{d}", .{IPMI_CHASSIS_BOOTPARAM_INIT_MBOX}, 0) catch unreachable;
}

fn formatBootmailboxBlock(block_str: *[4]u8, block: c_int) void {
    const byte: u8 = @truncate(@as(c_uint, @bitCast(block)));
    _ = std.fmt.bufPrintSentinel(block_str, "{d}", .{byte}, 0) catch unreachable;
}

fn chassisGetBootmailboxWith(intf: *Intf, block: i16, use_text: bool, get: anytype) BootparamOutputError!c_int {
    var rc: c_int = IPMI_CC_UNSPECIFIED_ERROR;
    var param_str = [_]u8{0} ** 2; // Max "7"
    var block_str = [_]u8{0} ** 4; // Max "255"
    const bpargv = [2][*:0]const u8{
        @ptrCast(&param_str),
        @ptrCast(&block_str),
    };

    var flags: c_int = if (use_text) bpFlag(MBOX_PARSE_USE_TEXT) else 0;

    formatBootmailboxParam(&param_str);

    if (block >= 0) {
        formatBootmailboxBlock(&block_str, block);

        rc = try get(intf, bpargv.len, &bpargv, flags);
    } else {
        flags |= bpFlag(MBOX_PARSE_ALLBLOCKS);
        var currblk: c_int = 0;
        while (currblk <= 255) : (currblk += 1) {
            formatBootmailboxBlock(&block_str, currblk);

            if (currblk != 0) {
                // If block 0 succeeded, we don't want to print generic info
                // for each next block, and we don't want range error to be
                // reported when we hit the end of blocks.
                flags |= bpFlag(PARAM_NO_GENERIC_INFO);
                flags |= bpFlag(PARAM_NO_RANGE_ERROR);
            }

            rc = try get(intf, bpargv.len, &bpargv, flags);

            if (rc != 0) {
                if (currblk != 0) rc = IPMI_CC_OK;
                break;
            }
        }
    }

    return rc;
}

fn chassisGetBootmailbox(intf: *Intf, block: i16, use_text: bool) BootparamOutputError!c_int {
    return chassisGetBootmailboxWith(intf, block, use_text, chassisGetBootparam);
}

test "chassis mailbox request strings match C bytes and NUL tails for every block" {
    var param_actual = [_]u8{0xa5} ** 2;
    var param_expected = param_actual;
    const param_len = c.snprintf(&param_expected, param_expected.len, "%u", @as(c_uint, IPMI_CHASSIS_BOOTPARAM_INIT_MBOX));
    formatBootmailboxParam(&param_actual);
    try std.testing.expectEqual(@as(c_int, 1), param_len);
    try std.testing.expectEqualSlices(u8, &param_expected, &param_actual);
    try std.testing.expectEqualStrings("7", std.mem.sliceTo(&param_actual, 0));

    var block_actual = [_]u8{0xa5} ** 4;
    var block_expected = block_actual;
    for (0..256) |value| {
        const block: c_int = @intCast(value);
        const c_byte: u8 = @truncate(@as(c_uint, @bitCast(block)));
        const n = c.snprintf(&block_expected, block_expected.len, "%u", @as(c_uint, c_byte));
        formatBootmailboxBlock(&block_actual, block);
        try std.testing.expectEqual(@as(c_int, @intCast(std.mem.sliceTo(&block_expected, 0).len)), n);
        try std.testing.expectEqualSlices(u8, &block_expected, &block_actual);
    }
    // Decreasing lengths also leave the same bytes after the terminator.
    for ([_]c_int{ 32767, 511, 256, 255, 100, 99, 10, 9, 1, 0, -1, -256, -32768 }) |block| {
        const c_byte: u8 = @truncate(@as(c_uint, @bitCast(block)));
        _ = c.snprintf(&block_expected, block_expected.len, "%u", @as(c_uint, c_byte));
        formatBootmailboxBlock(&block_actual, block);
        try std.testing.expectEqualSlices(u8, &block_expected, &block_actual);
    }
}

test "chassis mailbox request order flags and statuses match single and multi-block C paths" {
    const Stub = struct {
        var count: usize = 0;
        var stop_at: usize = 0;
        var stop_status: c_int = -1;
        var output_fail_at: usize = 0;
        var output_error: BootparamOutputError = error.StdoutWriteFailed;
        var request_bytes: [256][3]u8 = undefined;
        var request_flags: [256]c_int = undefined;
        var block_ptr: usize = 0;

        fn reset() void {
            count = 0;
            stop_at = 0;
            stop_status = -1;
            output_fail_at = 0;
            block_ptr = 0;
        }

        fn get(_: *Intf, argc: c_int, argv: [*]const [*:0]const u8, flags: c_int) BootparamOutputError!c_int {
            std.debug.assert(argc == 2 and count < request_bytes.len);
            std.debug.assert(std.mem.eql(u8, std.mem.span(argv[0]), "7"));
            if (block_ptr != 0) std.debug.assert(block_ptr == @intFromPtr(argv[1]));
            block_ptr = @intFromPtr(argv[1]);
            const block = std.fmt.parseInt(u8, std.mem.span(argv[1]), 10) catch unreachable;
            request_bytes[count] = .{ 7, block, 0 };
            request_flags[count] = flags;
            count += 1;
            if (count == output_fail_at) return output_error;
            if (count == stop_at) return stop_status;
            return 0;
        }
    };
    var intf = std.mem.zeroes(Intf);
    for ([_]i16{ 0, 1, 9, 10, 99, 100, 254, 255, 256, 257, 511, 32767 }) |block| {
        for ([_]bool{ false, true }) |use_text| {
            Stub.reset();
            try std.testing.expectEqual(@as(c_int, 0), try chassisGetBootmailboxWith(&intf, block, use_text, Stub.get));
            try std.testing.expectEqual(@as(usize, 1), Stub.count);
            try std.testing.expectEqualSlices(u8, &.{ 7, @as(u8, @truncate(@as(u16, @bitCast(block)))), 0 }, &Stub.request_bytes[0]);
            try std.testing.expectEqual(@as(c_int, if (use_text) bpFlag(MBOX_PARSE_USE_TEXT) else 0), Stub.request_flags[0]);
        }
    }

    for ([_]bool{ false, true }) |use_text| {
        Stub.reset();
        Stub.stop_at = 3;
        try std.testing.expectEqual(@as(c_int, 0), try chassisGetBootmailboxWith(&intf, -1, use_text, Stub.get));
        try std.testing.expectEqual(@as(usize, 3), Stub.count);
        for (0..Stub.count) |index| {
            try std.testing.expectEqualSlices(u8, &.{ 7, @as(u8, @intCast(index)), 0 }, &Stub.request_bytes[index]);
            const expected_flags = (if (use_text) bpFlag(MBOX_PARSE_USE_TEXT) else @as(c_int, 0)) |
                bpFlag(MBOX_PARSE_ALLBLOCKS) |
                (if (index == 0) @as(c_int, 0) else bpFlag(PARAM_NO_GENERIC_INFO) | bpFlag(PARAM_NO_RANGE_ERROR));
            try std.testing.expectEqual(expected_flags, Stub.request_flags[index]);
        }
    }
    Stub.reset();
    Stub.stop_at = 1;
    Stub.stop_status = IPMI_CC_UNSPECIFIED_ERROR;
    try std.testing.expectEqual(IPMI_CC_UNSPECIFIED_ERROR, try chassisGetBootmailboxWith(&intf, -1, false, Stub.get));
    try std.testing.expectEqual(@as(usize, 1), Stub.count);

    Stub.reset();
    try std.testing.expectEqual(@as(c_int, 0), try chassisGetBootmailboxWith(&intf, -1, false, Stub.get));
    try std.testing.expectEqual(@as(usize, 256), Stub.count);
    for (0..Stub.count) |index| {
        try std.testing.expectEqualSlices(u8, &.{ 7, @as(u8, @intCast(index)), 0 }, &Stub.request_bytes[index]);
    }

    for ([_]BootparamOutputError{ error.CStdoutFlushFailed, error.StdoutWriteFailed, error.StdoutFlushFailed }) |err| {
        Stub.reset();
        Stub.output_fail_at = 2;
        Stub.output_error = err;
        try std.testing.expectError(err, chassisGetBootmailboxWith(&intf, -1, false, Stub.get));
        try std.testing.expectEqual(@as(usize, 2), Stub.count);
    }
}

/// `chassis_bootmailbox()`.
fn chassisBootmailbox(intf: *Intf, argc_in: c_int, argv_in: [*]const [*:0]u8) BootparamOutputError!c_int {
    var argc = argc_in;
    var argv = argv_in;

    var rc: c_int = IPMI_CC_UNSPECIFIED_ERROR;
    var use_text = false; // Default to data dump I/O mode
    var block: i16 = -1; // By default print all blocks

    if (argc < 1 or eqlArg(argv[0], "help")) {
        chassisBootmailboxHelp();
        return rc;
    }

    const cmd = argv[0];
    argv += 1;
    argc -= 1;

    if (argc > 0 and eqlArg(argv[0], "text")) {
        use_text = true;
        argv += 1;
        argc -= 1;
    }

    if (argc > 0 and eqlArg(argv[0], "block")) {
        if (argc < 2) {
            chassisBootmailboxHelp();
            return rc;
        }
        if (c.str2short(argv[1], &block) != 0) {
            log.print(log.Level.err, "Invalid block %s", .{argv[1]});
            return rc;
        }
        argv += 2;
        argc -= 2;
    }

    if (eqlArg(cmd, "get")) {
        rc = try chassisGetBootmailbox(intf, block, use_text);
    } else if (eqlArg(cmd, "set")) {
        rc = chassisSetBootmailbox(intf, block, use_text, argc, argv);
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Power restore policy
// ---------------------------------------------------------------------------

/// `ipmi_chassis_power_policy()`.
const PolicyOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeChassisPowerPolicy(writer: *std.Io.Writer, policy: u8, supported: u8) std.Io.Writer.Error!void {
    if (policy == IPMI_CHASSIS_POLICY_NO_CHANGE) {
        try writer.writeAll("Supported chassis power policy:  ");
        if (supported & (@as(u8, 1) << IPMI_CHASSIS_POLICY_ALWAYS_OFF) != 0)
            try writer.writeAll("always-off ");
        if (supported & (@as(u8, 1) << IPMI_CHASSIS_POLICY_ALWAYS_ON) != 0)
            try writer.writeAll("always-on ");
        if (supported & (@as(u8, 1) << IPMI_CHASSIS_POLICY_PREVIOUS) != 0)
            try writer.writeAll("previous");
        try writer.writeByte('\n');
    } else {
        try writer.writeAll("Set chassis power restore policy to ");
        try writer.writeAll(switch (policy) {
            IPMI_CHASSIS_POLICY_ALWAYS_ON => "always-on\n",
            IPMI_CHASSIS_POLICY_ALWAYS_OFF => "always-off\n",
            IPMI_CHASSIS_POLICY_PREVIOUS => "previous\n",
            else => "unknown\n",
        });
    }
}

fn emitChassisPowerPolicy(writer: *std.Io.Writer, policy: u8, supported: u8, preflush: anytype) PolicyOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeChassisPowerPolicy(writer, policy, supported) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn chassisPowerPolicyTo(intf: *Intf, policy: u8, writer: *std.Io.Writer, preflush: anytype) PolicyOutputError!c_int {
    var policy_byte = policy;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x6;
    req.msg.data = @ptrCast(&policy_byte);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error in Power Restore Policy command", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Power Restore Policy command failed: %s", .{ccString(rsp.ccode)});
        return -1;
    }

    try emitChassisPowerPolicy(writer, policy, rsp.data[0], preflush);
    return 0;
}

fn chassisPowerPolicy(intf: *Intf, policy: u8) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return chassisPowerPolicyTo(intf, policy, &stdout.interface, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Chassis policy stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Chassis policy stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Chassis policy stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
}

test "chassis policy stdout matches C for supported masks and policy values" {
    var expected: [96]u8 = undefined;
    var storage: [96]u8 = undefined;
    for (0..256) |mask| {
        const supported: u8 = @intCast(mask);
        const n = c.snprintf(
            &expected,
            expected.len,
            "Supported chassis power policy:  %s%s%s\n",
            if (supported & 1 != 0) "always-off " else "",
            if (supported & 4 != 0) "always-on " else "",
            if (supported & 2 != 0) "previous" else "",
        );
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisPowerPolicy(&writer, IPMI_CHASSIS_POLICY_NO_CHANGE, supported);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
    for (0..256) |value| {
        const policy: u8 = @intCast(value);
        if (policy == IPMI_CHASSIS_POLICY_NO_CHANGE) continue;
        const label: [*:0]const u8 = switch (policy) {
            IPMI_CHASSIS_POLICY_ALWAYS_ON => "always-on",
            IPMI_CHASSIS_POLICY_ALWAYS_OFF => "always-off",
            IPMI_CHASSIS_POLICY_PREVIOUS => "previous",
            else => "unknown",
        };
        const n = c.snprintf(&expected, expected.len, "Set chassis power restore policy to %s\n", label);
        try std.testing.expect(n > 0 and @as(usize, @intCast(n)) < expected.len);
        var writer = std.Io.Writer.fixed(&storage);
        try writeChassisPowerPolicy(&writer, policy, 0xff);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "chassis policy stdout propagates preflush, early, late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitChassisPowerPolicy(&writer, IPMI_CHASSIS_POLICY_NO_CHANGE, 7, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerPolicy(&early, IPMI_CHASSIS_POLICY_NO_CHANGE, 7, Stub.preflushOk));
    var short: [36]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitChassisPowerPolicy(&late, IPMI_CHASSIS_POLICY_NO_CHANGE, 7, Stub.preflushOk));
    try std.testing.expectEqualStrings("Supported chassis power policy:  ", late.buffered()[0..33]);
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitChassisPowerPolicy(&writer, IPMI_CHASSIS_POLICY_ALWAYS_ON, 0, Stub.preflushOk));
    try std.testing.expectEqualStrings("Set chassis power restore policy to always-on\n", writer.buffered());
}

test "chassis policy stdout orders buffered C and Zig output" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitChassisPowerPolicy(&stdout.interface, IPMI_CHASSIS_POLICY_NO_CHANGE, 5, stdout_io.trySyncC);
    _ = c.printf("|between|");
    try emitChassisPowerPolicy(&stdout.interface, IPMI_CHASSIS_POLICY_PREVIOUS, 0, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [192]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|Supported chassis power policy:  always-off always-on \n|between|Set chassis power restore policy to previous\n|after\n",
        captured[0..@intCast(length)],
    );
}

test "chassis policy stdout preserves request and response statuses" {
    const Stub = struct {
        var response = std.mem.zeroes(Response);
        var requests: usize = 0;
        var present = true;
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            requests += 1;
            std.debug.assert(req.msg.netfn_lun.netfn == netfn_chassis and req.msg.cmd == 0x6 and req.msg.data_len == 1);
            std.debug.assert(req.msg.data[0] == IPMI_CHASSIS_POLICY_NO_CHANGE);
            return if (present) &response else null;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    Stub.response = std.mem.zeroes(Response);
    Stub.response.data[0] = 5;
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try chassisPowerPolicyTo(&intf, IPMI_CHASSIS_POLICY_NO_CHANGE, &writer, stdout_io.trySyncC));
    try std.testing.expectEqualStrings("Supported chassis power policy:  always-off always-on \n", writer.buffered());
    try std.testing.expectEqual(@as(usize, 1), Stub.requests);

    for ([_]bool{ false, true }) |present| {
        Stub.present = present;
        Stub.response.ccode = 0xc1;
        var empty: [96]u8 = undefined;
        var silent = std.Io.Writer.fixed(&empty);
        try std.testing.expectEqual(@as(c_int, -1), try chassisPowerPolicyTo(&intf, IPMI_CHASSIS_POLICY_NO_CHANGE, &silent, Stub.preflushFail));
        try std.testing.expectEqual(@as(usize, 0), silent.buffered().len);
    }
    try std.testing.expectEqual(@as(usize, 3), Stub.requests);
    Stub.present = true;
    Stub.response.ccode = 0;
    var silent = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, chassisPowerPolicyTo(&intf, IPMI_CHASSIS_POLICY_NO_CHANGE, &silent, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), silent.buffered().len);
    try std.testing.expectEqual(@as(usize, 4), Stub.requests);
}

// ---------------------------------------------------------------------------
// Command entry points
// ---------------------------------------------------------------------------

const power_usage = "chassis power Commands: status, on, off, cycle, reset, diag, soft";

/// Shared by `ipmi_power_main()` and the `chassis power` branch of
/// `ipmi_chassis_main()`: map a state word onto a Chassis Control byte.
fn powerControlByte(arg: [*:0]const u8) ?u8 {
    if (eqlArg(arg, "up") or eqlArg(arg, "on")) return IPMI_CHASSIS_CTL_POWER_UP;
    if (eqlArg(arg, "down") or eqlArg(arg, "off")) return IPMI_CHASSIS_CTL_POWER_DOWN;
    if (eqlArg(arg, "cycle")) return IPMI_CHASSIS_CTL_POWER_CYCLE;
    if (eqlArg(arg, "reset")) return IPMI_CHASSIS_CTL_HARD_RESET;
    if (eqlArg(arg, "diag")) return IPMI_CHASSIS_CTL_PULSE_DIAG;
    if (eqlArg(arg, "acpi") or eqlArg(arg, "soft")) return IPMI_CHASSIS_CTL_ACPI_SOFT;
    return null;
}

/// `ipmi_power_main()`.
fn powerMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    if (argc < 1 or eqlArg(argv[0], "help")) {
        log.print(log.Level.notice, power_usage, .{});
        return 0;
    }
    if (eqlArg(argv[0], "status")) {
        return chassisPrintPowerStatus(intf);
    }

    const ctl = powerControlByte(argv[0]) orelse {
        log.print(log.Level.err, "Invalid chassis power command: %s", .{argv[0]});
        return -1;
    };

    return chassisPowerControl(intf, ctl);
}

/// `ipmi_chassis_set_bootflag_help()`.
fn chassisSetBootflagHelp() callconv(.c) void {
    var set_flag: u8 = undefined;
    var clr_flag: u8 = undefined;
    log.print(log.Level.notice, "bootparam set bootflag <device> [options=...]", .{});
    log.print(log.Level.notice, " Legal devices are:", .{});
    log.print(log.Level.notice, "  none           : No override", .{});
    log.print(log.Level.notice, "  force_pxe      : Force PXE boot", .{});
    log.print(log.Level.notice, "  force_disk     : Force boot from default Hard-drive", .{});
    log.print(log.Level.notice, "  force_safe     : Force boot from default Hard-drive, request Safe Mode", .{});
    log.print(log.Level.notice, "  force_diag     : Force boot from Diagnostic Partition", .{});
    log.print(log.Level.notice, "  force_cdrom    : Force boot from CD/DVD", .{});
    log.print(log.Level.notice, "  force_bios     : Force boot into BIOS Setup", .{});
    log.print(log.Level.notice, "  force_remotecd : Force boot from remote CD/DVD", .{});
    _ = getBootparamOptions(@constCast(@as([*:0]const u8, "options=help")), &set_flag, &clr_flag);
}

const BootdevOption = struct {
    name: [*:0]const u8,
    offset: usize,
    mask: u8,
    value: u8,
    desc: [*:0]const u8,
};

/// The `options[]` table inside `bootdev_parse_options()`.
const bootdev_options = [_]BootdevOption{
    // data 1
    .{ .name = "valid", .offset = BF1_OFFSET, .mask = BF1_VALID, .value = BF1_VALID, .desc = "Boot flags valid" },
    .{ .name = "persistent", .offset = BF1_OFFSET, .mask = BF1_PERSIST, .value = BF1_PERSIST, .desc = "Changes are persistent for all future boots" },
    .{ .name = "efiboot", .offset = BF1_OFFSET, .mask = BF1_BOOT_TYPE_EFI, .value = BF1_BOOT_TYPE_EFI, .desc = "Extensible Firmware Interface Boot (EFI)" },
    // data 2
    .{ .name = "clear-cmos", .offset = BF2_OFFSET, .mask = BF2_CMOS_CLEAR, .value = BF2_CMOS_CLEAR, .desc = "CMOS clear" },
    .{ .name = "lockkbd", .offset = BF2_OFFSET, .mask = BF2_KEYLOCK, .value = BF2_KEYLOCK, .desc = "Lock Keyboard" },
    // data2[5:2] is parsed elsewhere
    .{ .name = "screenblank", .offset = BF2_OFFSET, .mask = BF2_BLANK_SCREEN, .value = BF2_BLANK_SCREEN, .desc = "Screen Blank" },
    .{ .name = "lockoutreset", .offset = BF2_OFFSET, .mask = BF2_RESET_LOCKOUT, .value = BF2_RESET_LOCKOUT, .desc = "Lock out Reset buttons" },
    // data 3
    .{ .name = "lockout_power", .offset = BF3_OFFSET, .mask = BF3_POWER_LOCKOUT, .value = BF3_POWER_LOCKOUT, .desc = "Lock out (power off/sleep request) via Power Button" },
    .{ .name = "verbose=default", .offset = BF3_OFFSET, .mask = BF3_VERBOSITY_MASK, .value = BF3_VERBOSITY_DEFAULT, .desc = "Request quiet BIOS display" },
    .{ .name = "verbose=no", .offset = BF3_OFFSET, .mask = BF3_VERBOSITY_MASK, .value = BF3_VERBOSITY_QUIET, .desc = "Request quiet BIOS display" },
    .{ .name = "verbose=yes", .offset = BF3_OFFSET, .mask = BF3_VERBOSITY_MASK, .value = BF3_VERBOSITY_VERBOSE, .desc = "Request verbose BIOS display" },
    .{ .name = "force_pet", .offset = BF3_OFFSET, .mask = BF3_EVENT_TRAPS, .value = BF3_EVENT_TRAPS, .desc = "Force progress event traps" },
    .{ .name = "upw_bypass", .offset = BF3_OFFSET, .mask = BF3_PASSWD_BYPASS, .value = BF3_PASSWD_BYPASS, .desc = "User password bypass" },
    .{ .name = "lockout_sleep", .offset = BF3_OFFSET, .mask = BF3_SLEEP_LOCKOUT, .value = BF3_SLEEP_LOCKOUT, .desc = "Lock out the Sleep button" },
    .{ .name = "cons_redirect=default", .offset = BF3_OFFSET, .mask = BF3_CONSOLE_REDIR_MASK, .value = BF3_CONSOLE_REDIR_DEFAULT, .desc = "Console redirection occurs per BIOS configuration setting" },
    .{ .name = "cons_redirect=skip", .offset = BF3_OFFSET, .mask = BF3_CONSOLE_REDIR_MASK, .value = BF3_CONSOLE_REDIR_SUPPRESS, .desc = "Suppress (skip) console redirection if enabled" },
    .{ .name = "cons_redirect=enable", .offset = BF3_OFFSET, .mask = BF3_CONSOLE_REDIR_MASK, .value = BF3_CONSOLE_REDIR_ENABLE, .desc = "Request console redirection be enabled" },
    // data 4
    // data4[7:4] reserved
    // data4[3] BIOS Shared Mode Override, not implemented here
    // data4[2:0] BIOS Mux Control Override, not implemented here

    // data5 reserved
};

/// `bootdev_parse_options()` - a helper for `ipmi_chassis_main()`.
///
/// `optstring` must be writable; commas are split in place.
fn bootdevParseOptions(optstring: [*:0]u8, flags: *[BF_BYTE_COUNT]u8) bool {
    var option_error = false;

    @memset(flags, 0);

    var tokens = CommaTokens.init(optstring);
    while (tokens.next()) |token| {
        if (eqlArg(token, "help")) {
            option_error = true;
            break;
        }
        var found = false;
        for (bootdev_options) |op| {
            if (eqlArg(token, op.name)) {
                flags[op.offset] &= ~op.mask;
                flags[op.offset] |= op.value;
                found = true;
                break;
            }
        }
        if (!found) {
            // Option not found.
            option_error = true;
            log.print(log.Level.err, "Invalid option: %s", .{token});
        }
    }

    if (option_error) {
        log.print(log.Level.notice, "Legal options settings are:", .{});
        log.print(
            log.Level.notice,
            "  %-22s: %s",
            .{
                @as([*:0]const u8, "help"),
                @as([*:0]const u8, "print this message"),
            },
        );
        for (bootdev_options) |op| {
            log.print(log.Level.notice, "  %-22s: %s", .{ op.name, op.desc });
        }
        return false;
    }

    return true;
}

test "chassis comma tokens retain bootflag and bootdev option masks" {
    const bootflag = try std.testing.allocator.dupeZ(u8, "options=,PEF,,no-watchdog,reset,");
    defer std.testing.allocator.free(bootflag);
    var set_flag: u8 = undefined;
    var clr_flag: u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), getBootparamOptions(bootflag.ptr, &set_flag, &clr_flag));
    try std.testing.expectEqual(@as(u8, 0x04), set_flag);
    try std.testing.expectEqual(@as(u8, 0x12), clr_flag);

    const empty = try std.testing.allocator.dupeZ(u8, "options=,,,");
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqual(@as(c_int, 0), getBootparamOptions(empty.ptr, &set_flag, &clr_flag));
    try std.testing.expectEqual(@as(u8, 0), set_flag);
    try std.testing.expectEqual(@as(u8, 0), clr_flag);

    const bootdev = try std.testing.allocator.dupeZ(u8, ",persistent,,efiboot,verbose=default,verbose=yes,");
    defer std.testing.allocator.free(bootdev);
    var flags: [BF_BYTE_COUNT]u8 = undefined;
    try std.testing.expect(bootdevParseOptions(bootdev.ptr, &flags));
    try std.testing.expectEqual(BF1_PERSIST | BF1_BOOT_TYPE_EFI, flags[BF1_OFFSET]);
    try std.testing.expectEqual(BF3_VERBOSITY_VERBOSE, flags[BF3_OFFSET] & BF3_VERBOSITY_MASK);

    const invalid = try std.testing.allocator.dupeZ(u8, "persistent,,unknown");
    defer std.testing.allocator.free(invalid);
    try std.testing.expect(!bootdevParseOptions(invalid.ptr, &flags));
    try std.testing.expectEqual(BF1_PERSIST, flags[BF1_OFFSET]);
}

/// `ipmi_chassis_main()`.
fn chassisMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var rc: c_int = -1;

    if (argc == 0 or eqlArg(argv[0], "help")) {
        const usage =
            \\Chassis Commands:
            \\  status, power, policy, restart_cause
            \\  poh, identify, selftest,
            \\  bootdev, bootparam, bootmbox
        ;
        log.print(log.Level.notice, usage, .{});
    } else if (eqlArg(argv[0], "status")) {
        rc = chassisStatus(intf);
    } else if (eqlArg(argv[0], "selftest")) {
        rc = chassisSelftest(intf);
    } else if (eqlArg(argv[0], "power")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            log.print(log.Level.notice, power_usage, .{});
            return 0;
        }
        if (eqlArg(argv[1], "status")) {
            return chassisPrintPowerStatus(intf);
        }
        const ctl = powerControlByte(argv[1]) orelse {
            log.print(log.Level.err, "Invalid chassis power command: %s", .{argv[1]});
            return rc;
        };
        rc = chassisPowerControl(intf, ctl);
    } else if (eqlArg(argv[0], "identify")) {
        if (argc < 2) {
            rc = chassisIdentify(intf, null);
        } else if (eqlArg(argv[1], "help")) {
            log.print(log.Level.notice, "chassis identify <interval>", .{});
            log.print(log.Level.notice, "                 default is 15 seconds", .{});
            log.print(log.Level.notice, "                 0 to turn off", .{});
            log.print(log.Level.notice, "                 force to turn on indefinitely", .{});
        } else {
            rc = chassisIdentify(intf, argv[1]);
        }
    } else if (eqlArg(argv[0], "poh")) {
        rc = chassisPoh(intf);
    } else if (eqlArg(argv[0], "restart_cause")) {
        rc = chassisRestartCause(intf);
    } else if (eqlArg(argv[0], "policy")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            log.print(log.Level.notice, "chassis policy <state>", .{});
            log.print(log.Level.notice, "   list        : return supported policies", .{});
            log.print(log.Level.notice, "   always-on   : turn on when power is restored", .{});
            log.print(log.Level.notice, "   previous    : return to previous state when power is restored", .{});
            log.print(log.Level.notice, "   always-off  : stay off after power is restored", .{});
        } else {
            var ctl: u8 = undefined;
            if (eqlArg(argv[1], "list")) {
                ctl = IPMI_CHASSIS_POLICY_NO_CHANGE;
            } else if (eqlArg(argv[1], "always-on")) {
                ctl = IPMI_CHASSIS_POLICY_ALWAYS_ON;
            } else if (eqlArg(argv[1], "previous")) {
                ctl = IPMI_CHASSIS_POLICY_PREVIOUS;
            } else if (eqlArg(argv[1], "always-off")) {
                ctl = IPMI_CHASSIS_POLICY_ALWAYS_OFF;
            } else {
                log.print(log.Level.err, "Invalid chassis policy: %s", .{argv[1]});
                return -1;
            }
            rc = chassisPowerPolicy(intf, ctl);
        }
    } else if (eqlArg(argv[0], "bootparam")) {
        if (argc < 3 or eqlArg(argv[1], "help")) {
            log.print(log.Level.notice, "bootparam get <param #>", .{});
            chassisSetBootflagHelp();
        } else if (eqlArg(argv[1], "get")) {
            rc = chassisGetBootparam(intf, argc - 2, argv + 2, 0) catch -1;
        } else if (eqlArg(argv[1], "set")) {
            var set_flag: u8 = 0;
            var clr_flag: u8 = 0;
            if (eqlArg(argv[2], "help") or argc < 4 or !eqlArg(argv[2], "bootflag")) {
                chassisSetBootflagHelp();
            } else {
                if (argc == 5) {
                    _ = getBootparamOptions(argv[4], &set_flag, &clr_flag);
                }
                rc = chassisSetBootdev(intf, argv[3], null);
                if (argc == 5 and (set_flag != 0 or clr_flag != 0)) {
                    rc = chassisSetBootvalid(intf, set_flag, clr_flag);
                }
            }
        } else {
            log.print(log.Level.notice, "bootparam get|set <option> [value ...]", .{});
        }
    } else if (eqlArg(argv[0], "bootdev")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            log.print(log.Level.notice, "bootdev <device> [clear-cmos=yes|no]", .{});
            log.print(log.Level.notice, "bootdev <device> [options=help,...]", .{});
            log.print(log.Level.notice, "  none     : Do not change boot device order", .{});
            log.print(log.Level.notice, "  pxe      : Force PXE boot", .{});
            log.print(log.Level.notice, "  disk     : Force boot from default Hard-drive", .{});
            log.print(log.Level.notice, "  safe     : Force boot from default Hard-drive, request Safe Mode", .{});
            log.print(log.Level.notice, "  diag     : Force boot from Diagnostic Partition", .{});
            log.print(log.Level.notice, "  cdrom    : Force boot from CD/DVD", .{});
            log.print(log.Level.notice, "  bios     : Force boot into BIOS Setup", .{});
            log.print(log.Level.notice, "  floppy   : Force boot from Floppy/primary removable media", .{});
            log.print(log.Level.notice, "  remotecd : Force boot from remote CD/DVD", .{});
        } else {
            const kw: [*:0]const u8 = "options=";
            var optstr: ?[*:0]u8 = null;
            var flags: [BF_BYTE_COUNT]u8 = undefined;
            var use_flags = false;

            if (argc >= 3) {
                if (eqlArg(argv[2], "clear-cmos=yes")) {
                    // Exclusive clear-cmos, no other flags.
                    optstr = @constCast(@as([*:0]const u8, "clear-cmos"));
                } else if (hasArgPrefix(argv[2], kw)) {
                    optstr = argv[2] + std.mem.len(kw);
                }
            }
            if (optstr) |s| {
                if (!bootdevParseOptions(s, &flags)) return rc;
                use_flags = true;
            }
            rc = chassisSetBootdev(intf, argv[1], if (use_flags) &flags else null);
        }
    } else if (eqlArg(argv[0], "bootmbox")) {
        rc = chassisBootmailbox(intf, argc - 1, argv + 1) catch -1;
    } else {
        log.print(log.Level.err, "Invalid chassis command: %s", .{argv[0]});
    }

    return rc;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(chassisMain), @TypeOf(c.ipmi_chassis_main));
    abi.assertCallSignature(@TypeOf(powerMain), @TypeOf(c.ipmi_power_main));
    abi.assertCallSignature(@TypeOf(chassisPowerStatus), @TypeOf(c.ipmi_chassis_power_status));
    abi.assertCallSignature(@TypeOf(chassisPowerControl), @TypeOf(c.ipmi_chassis_power_control));
    abi.assertCallSignature(@TypeOf(chassisStatus), @TypeOf(c.ipmi_chassis_status));
    abi.assertCallSignature(@TypeOf(chassisSetBootflagHelp), @TypeOf(c.ipmi_chassis_set_bootflag_help));

    @export(&chassisMain, .{ .name = "ipmi_chassis_main", .linkage = .strong });
    @export(&powerMain, .{ .name = "ipmi_power_main", .linkage = .strong });
    @export(&chassisPowerStatus, .{ .name = "ipmi_chassis_power_status", .linkage = .strong });
    @export(&chassisPowerControl, .{ .name = "ipmi_chassis_power_control", .linkage = .strong });
    @export(&chassisStatus, .{ .name = "ipmi_chassis_status", .linkage = .strong });
    @export(&chassisSetBootflagHelp, .{ .name = "ipmi_chassis_set_bootflag_help", .linkage = .strong });
}
