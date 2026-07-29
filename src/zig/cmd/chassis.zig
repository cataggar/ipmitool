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
//! * **Formatting stays in libc.**  `printf`, `snprintf` and `lprintf` are
//!   called through the `ipmi_c` bridge rather than reimplemented, because
//!   `%3d`, `%08lXh`, `%-22s` and `%s` on a `buf2str()` result are all
//!   observable.  So are `strcmp`, `strncmp`, `strtok_r` and `str2uchar`: the
//!   module hands them the same pointers C handed them, including the writable
//!   `argv` strings `strtok_r()` chops up in place.
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
//! * **Two upstream defects are reproduced deliberately**, because a port that
//!   fixed them would change behaviour:
//!   - `ipmi_chassis_get_bootparam()` reports an unparsable set selector as
//!     "given to bootparam %u" using `msg_data[1]`, the selector slot it
//!     failed to fill, rather than `msg_data[0]`, the parameter number.
//!   - `chassis_set_bootmailbox()` ignores the return value of `args2buf()`,
//!     so a bad byte in the middle of a mailbox write is reported and then
//!     written as a zero.
//!   Both are reported as issue #33.
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
    return c.strcmp(arg, want) == 0;
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
        c.lprintf(log.Level.err, "Unable to get Chassis Power Status");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Chassis Power Status failed: %s", ccString(rsp.ccode));
        return -1;
    }

    return rsp.data[0] & 1;
}

/// `ipmi_chassis_print_power_status()`.
fn chassisPrintPowerStatus(intf: *Intf) c_int {
    const ps = chassisPowerStatus(intf);
    if (ps < 0) return -1;

    _ = c.printf("Chassis Power is %s\n", pick(ps != 0, "on", "off"));
    return 0;
}

/// `ipmi_chassis_power_control()`.
fn chassisPowerControl(intf: *Intf, ctl: u8) callconv(.c) c_int {
    var ctl_byte = ctl;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x2;
    req.msg.data = @ptrCast(&ctl_byte);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(
            log.Level.err,
            "Unable to set Chassis Power Control to %s",
            c.val2str(ctl, c.ipmi_chassis_power_control_vals),
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Set Chassis Power Control to %s failed: %s",
            c.val2str(ctl, c.ipmi_chassis_power_control_vals),
            ccString(rsp.ccode),
        );
        return -1;
    }

    _ = c.printf(
        "Chassis Power Control: %s\n",
        c.val2str(ctl, c.ipmi_chassis_power_control_vals),
    );
    return 0;
}

// ---------------------------------------------------------------------------
// Identify
// ---------------------------------------------------------------------------

/// `ipmi_chassis_identify()`.
///
/// With no argument the request carries no data at all; with `force` it
/// carries both bytes so the BMC can reject the optional second one.
fn chassisIdentify(intf: *Intf, arg: ?[*:0]const u8) c_int {
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
                    c.lprintf(log.Level.err, "Invalid interval given.");
                } else {
                    c.lprintf(log.Level.err, "Given interval is too big.");
                }
                return -1;
            }
        }
        req.msg.data = &identify_data;
        req.msg.data_len = if (force_on.* != 0) 2 else 1;
    }

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Unable to set Chassis Identify");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Set Chassis Identify failed: %s", ccString(rsp.ccode));
        if (force_on.* != 0) {
            // Intel SE7501WV2 F/W 1.2 returns CC 0xC7, but the IPMI v1.5 spec
            // does not standardize a CC if unsupported, so we warn.
            c.lprintf(log.Level.warning, "Chassis may not support Force Identify On\n");
        }
        return -1;
    }

    _ = c.printf("Chassis identify interval: ");
    if (arg == null) {
        _ = c.printf("default (15 seconds)\n");
    } else if (force_on.* != 0) {
        _ = c.printf("indefinite\n");
    } else if (interval.* == 0) {
        _ = c.printf("off\n");
    } else {
        _ = c.printf("%i seconds\n", @as(c_int, interval.*));
    }
    return 0;
}

// ---------------------------------------------------------------------------
// POH counter
// ---------------------------------------------------------------------------

/// `ipmi_chassis_poh()`.
///
/// The arithmetic is single precision on purpose, and the two subtractions
/// are not symmetrical in C either: the first converts `days` to `float`
/// before multiplying, the second multiplies `hours` as an integer.
fn chassisPoh(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0xf;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Unable to get Chassis Power-On-Hours");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Chassis Power-On-Hours failed: %s", ccString(rsp.ccode));
        return -1;
    }

    const mins_per_count: u8 = rsp.data[0];
    const count = std.mem.readInt(u32, rsp.data[1..5], .little);

    var minutes: f32 = @as(f32, @floatFromInt(count)) * @as(f32, @floatFromInt(mins_per_count));
    const days: u32 = @intFromFloat(minutes / 1440);
    minutes -= @as(f32, @floatFromInt(days)) * 1440;
    const hours: u32 = @intFromFloat(minutes / 60);
    minutes -= @floatFromInt(hours *% 60);

    if (mins_per_count < 60) {
        _ = c.printf(
            "POH Counter  : %i days, %i hours, %li minutes\n",
            days,
            hours,
            @as(c_long, @intFromFloat(minutes)),
        );
    } else {
        _ = c.printf("POH Counter  : %i days, %i hours\n", days, hours);
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Restart cause, status, self test
// ---------------------------------------------------------------------------

/// `ipmi_chassis_restart_cause()`.
fn chassisRestartCause(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x7;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Unable to get Chassis Restart Cause");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Chassis Restart Cause failed: %s", ccString(rsp.ccode));
        return -1;
    }

    _ = c.printf(
        "System restart cause: %s\n",
        c.val2str(rsp.data[0] & 0xf, c.ipmi_chassis_restart_cause_vals),
    );
    return 0;
}

/// `ipmi_chassis_status()`.
fn chassisStatus(intf: *Intf) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x1;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error sending Chassis Status command");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error sending Chassis Status command: %s", ccString(rsp.ccode));
        return -1;
    }

    // byte 1
    _ = c.printf("System Power         : %s\n", pick(rsp.data[0] & 0x1 != 0, "on", "off"));
    _ = c.printf("Power Overload       : %s\n", pick(rsp.data[0] & 0x2 != 0, "true", "false"));
    _ = c.printf("Power Interlock      : %s\n", pick(rsp.data[0] & 0x4 != 0, "active", "inactive"));
    _ = c.printf("Main Power Fault     : %s\n", pick(rsp.data[0] & 0x8 != 0, "true", "false"));
    _ = c.printf("Power Control Fault  : %s\n", pick(rsp.data[0] & 0x10 != 0, "true", "false"));
    _ = c.printf("Power Restore Policy : ");
    switch ((rsp.data[0] & 0x60) >> 5) {
        0x0 => _ = c.printf("always-off\n"),
        0x1 => _ = c.printf("previous\n"),
        0x2 => _ = c.printf("always-on\n"),
        else => _ = c.printf("unknown\n"),
    }

    // byte 2
    _ = c.printf("Last Power Event     : ");
    if (rsp.data[1] & 0x1 != 0) _ = c.printf("ac-failed ");
    if (rsp.data[1] & 0x2 != 0) _ = c.printf("overload ");
    if (rsp.data[1] & 0x4 != 0) _ = c.printf("interlock ");
    if (rsp.data[1] & 0x8 != 0) _ = c.printf("fault ");
    if (rsp.data[1] & 0x10 != 0) _ = c.printf("command");
    _ = c.printf("\n");

    // byte 3
    _ = c.printf("Chassis Intrusion    : %s\n", pick(rsp.data[2] & 0x1 != 0, "active", "inactive"));
    _ = c.printf("Front-Panel Lockout  : %s\n", pick(rsp.data[2] & 0x2 != 0, "active", "inactive"));
    _ = c.printf("Drive Fault          : %s\n", pick(rsp.data[2] & 0x4 != 0, "true", "false"));
    _ = c.printf("Cooling/Fan Fault    : %s\n", pick(rsp.data[2] & 0x8 != 0, "true", "false"));

    if (rsp.data_len > 3) {
        // optional byte 4
        if (rsp.data[3] == 0) {
            _ = c.printf("Front Panel Control  : none\n");
        } else {
            const allowed = struct {
                fn f(set: bool) [*:0]const u8 {
                    return pick(set, "allowed", "not allowed");
                }
            }.f;
            const truth = struct {
                fn f(set: bool) [*:0]const u8 {
                    return pick(set, "true", "false");
                }
            }.f;
            _ = c.printf("Sleep Button Disable : %s\n", allowed(rsp.data[3] & 0x80 != 0));
            _ = c.printf("Diag Button Disable  : %s\n", allowed(rsp.data[3] & 0x40 != 0));
            _ = c.printf("Reset Button Disable : %s\n", allowed(rsp.data[3] & 0x20 != 0));
            _ = c.printf("Power Button Disable : %s\n", allowed(rsp.data[3] & 0x10 != 0));
            _ = c.printf("Sleep Button Disabled: %s\n", truth(rsp.data[3] & 0x08 != 0));
            _ = c.printf("Diag Button Disabled : %s\n", truth(rsp.data[3] & 0x04 != 0));
            _ = c.printf("Reset Button Disabled: %s\n", truth(rsp.data[3] & 0x02 != 0));
            _ = c.printf("Power Button Disabled: %s\n", truth(rsp.data[3] & 0x01 != 0));
        }
    }

    return 0;
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
fn chassisSelftest(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = 0x4;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error sending Get Self Test command");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error sending Get Self Test command: %s", ccString(rsp.ccode));
        return -1;
    }

    _ = c.printf("Self Test Results    : ");
    switch (rsp.data[0]) {
        0x55 => _ = c.printf("passed\n"),
        0x56 => _ = c.printf("not implemented\n"),
        0x57 => {
            _ = c.printf("device error\n");
            var i: u4 = 0;
            while (i < 8) : (i += 1) {
                if (rsp.data[1] & (@as(u8, 1) << @intCast(i)) != 0) {
                    _ = c.printf(
                        "                       [%s]\n",
                        c.val2str(@as(u32, i), @ptrCast(&broken_dev_vals)),
                    );
                }
            }
        },
        0x58 => _ = c.printf("Fatal hardware error: %02xh\n", @as(c_uint, rsp.data[1])),
        else => _ = c.printf(
            "Device-specific failure %02xh:%02xh\n",
            @as(c_uint, rsp.data[0]),
            @as(c_uint, rsp.data[1]),
        ),
    }

    return 0;
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
        c.lprintf(log.Level.err, "Error setting Chassis Boot Parameter %d", @as(c_int, param));
        return -1;
    };

    rc = rsp.ccode;
    if (rc != 0) {
        if (param != 0) {
            c.lprintf(
                log.Level.err,
                "Set Chassis Boot Parameter %d failed: %s",
                @as(c_int, param),
                bootparamCcString(rsp.ccode, &set_bootparam_cc_vals),
            );
        }
        return rc;
    }

    c.lprintf(
        log.Level.debug,
        "Chassis Set Boot Parameter %d to %s",
        @as(c_int, param),
        c.buf2str(data, len),
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

/// `chassis_bootmailbox_parse()`.
///
/// `buf` points at the parameter data, whose first byte is the block selector.
fn chassisBootmailboxParse(buf: [*]const u8, len: usize, flags: c_int) void {
    const use_text = flags & bpFlag(MBOX_PARSE_USE_TEXT) != 0;
    const all_blocks = flags & bpFlag(MBOX_PARSE_ALLBLOCKS) != 0;

    if (len == 0) return;

    const block = buf[0];
    var blockdata: [*]const u8 = buf + 1;
    var datalen: usize = len - 1;

    if (!all_blocks) {
        // Print block selector only if a single block is printed.
        _ = c.printf(" Selector       : %d\n", @as(c_int, block));
    }
    if (block == 0) {
        const iana = c.ipmi24toh(@constCast(buf + 1));
        // For block zero print the IANA Private Enterprise Number.
        _ = c.printf(
            " IANA PEN       : %u [%s]\n",
            iana,
            c.val2str(iana, c.ipmi_oem_info),
        );
        blockdata = buf + 1 + CHASSIS_BOOT_MBOX_IANA_SZ;
        datalen -%= CHASSIS_BOOT_MBOX_IANA_SZ;
    }

    _ = c.printf(" Block ");
    if (all_blocks) {
        _ = c.printf("%3u Data : ", @as(c_uint, block));
    } else {
        _ = c.printf("Data     : ");
    }
    if (use_text) {
        // Ensure the data string is null-terminated.
        var text = [_]u8{0} ** (CHASSIS_BOOT_MBOX_BLOCK_SZ + 1);
        @memcpy(text[0..datalen], blockdata[0..datalen]);
        _ = c.printf("'%s'\n", &text);
    } else {
        _ = c.printf("%s\n", c.buf2str(blockdata, @intCast(datalen)));
    }
}

/// `ipmi_chassis_get_bootparam()`.
fn chassisGetBootparam(
    intf: *Intf,
    argc_in: c_int,
    argv_in: [*]const [*:0]const u8,
    flags: c_int,
) c_int {
    var argc = argc_in;
    var argv = argv_in;

    var param_id: u8 = 0;
    const skip_generic = flags & bpFlag(PARAM_NO_GENERIC_INFO) != 0;
    const skip_data = flags & bpFlag(PARAM_NO_DATA_DUMP) != 0;
    const skip_range = flags & bpFlag(PARAM_NO_RANGE_ERROR) != 0;

    if (argc < 1) return -1;

    if (c.str2uchar(argv[0], &param_id) != 0) {
        c.lprintf(
            log.Level.err,
            "Invalid parameter '%s' given instead of bootparam.",
            argv[0],
        );
        return -1;
    }

    argc -= 1;
    argv += 1;

    var msg_data = [3]u8{ 0, 0, 0 };
    msg_data[0] = param_id & 0x7f;

    if (argc != 0) {
        if (c.str2uchar(argv[0], &msg_data[1]) != 0) {
            // Upstream reports msg_data[1], the selector it failed to parse,
            // where it means msg_data[0], the parameter number.  Issue #33.
            c.lprintf(
                log.Level.err,
                "Invalid argument '%s' given to bootparam %u",
                argv[0],
                @as(c_uint, msg_data[1]),
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
        c.lprintf(
            log.Level.err,
            "Error Getting Chassis Boot Parameter %u",
            @as(c_uint, msg_data[0]),
        );
        return -1;
    };
    if (rsp.ccode == IPMI_CC_PARAM_OUT_OF_RANGE and skip_range) {
        return -1;
    }
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get Chassis Boot Parameter %u failed: %s",
            @as(c_uint, msg_data[0]),
            bootparamCcString(rsp.ccode, &get_bootparam_cc_vals),
        );
        return -1;
    }

    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "Boot Option");

    param_id = rsp.data[1] & 0x7f;

    if (!skip_generic) {
        _ = c.printf("Boot parameter version: %d\n", @as(c_int, rsp.data[0]));
        _ = c.printf(
            "Boot parameter %d is %s\n",
            @as(c_int, rsp.data[1] & 0x7f),
            pick(rsp.data[1] & 0x80 != 0, "invalid/locked", "valid/unlocked"),
        );
        if (!skip_data) {
            _ = c.printf(
                "Boot parameter data: %s\n",
                c.buf2str(rsp.data[2..], rsp.data_len - 2),
            );
        }
    }

    switch (param_id) {
        0 => {
            _ = c.printf(" Set In Progress : ");
            switch (rsp.data[2] & 0x03) {
                0 => _ = c.printf("set complete\n"),
                1 => _ = c.printf("set in progress\n"),
                2 => _ = c.printf("commit write\n"),
                else => _ = c.printf("error, reserved bit\n"),
            }
        },
        1 => {
            _ = c.printf(" Service Partition Selector : ");
            if (rsp.data[2] == 0) {
                _ = c.printf("unspecified\n");
            } else {
                _ = c.printf("%d\n", @as(c_int, rsp.data[2]));
            }
        },
        2 => {
            _ = c.printf(" Service Partition Scan :\n");
            if (rsp.data[2] & 0x03 != 0) {
                if (rsp.data[2] & 0x01 == 0x01)
                    _ = c.printf("     - Request BIOS to scan\n");
                if (rsp.data[2] & 0x02 == 0x02)
                    _ = c.printf("     - Service Partition Discovered\n");
            } else {
                _ = c.printf("     No flag set\n");
            }
        },
        3 => {
            _ = c.printf(" BMC boot flag valid bit clearing :\n");
            if (rsp.data[2] & 0x1f != 0) {
                if (rsp.data[2] & 0x10 == 0x10)
                    _ = c.printf("     - Don't clear valid bit on reset/power cycle cause by PEF\n");
                if (rsp.data[2] & 0x08 == 0x08)
                    _ = c.printf("     - Don't automatically clear boot flag valid bit on timeout\n");
                if (rsp.data[2] & 0x04 == 0x04)
                    _ = c.printf("     - Don't clear valid bit on reset/power cycle cause by watchdog\n");
                if (rsp.data[2] & 0x02 == 0x02)
                    _ = c.printf("     - Don't clear valid bit on push button reset // soft reset\n");
                if (rsp.data[2] & 0x01 == 0x01)
                    _ = c.printf("     - Don't clear valid bit on power up via power push button or wake event\n");
            } else {
                _ = c.printf("     No flag set\n");
            }
        },
        4 => {
            _ = c.printf(" Boot Info Acknowledge :\n");
            if (rsp.data[3] & 0x1f != 0) {
                if (rsp.data[3] & 0x10 == 0x10)
                    _ = c.printf("    - OEM has handled boot info\n");
                if (rsp.data[3] & 0x08 == 0x08)
                    _ = c.printf("    - SMS has handled boot info\n");
                if (rsp.data[3] & 0x04 == 0x04)
                    _ = c.printf("    - OS // service partition has handled boot info\n");
                if (rsp.data[3] & 0x02 == 0x02)
                    _ = c.printf("    - OS Loader has handled boot info\n");
                if (rsp.data[3] & 0x01 == 0x01)
                    _ = c.printf("    - BIOS/POST has handled boot info\n");
            } else {
                _ = c.printf("     No flag set\n");
            }
        },
        5 => printBootFlags(rsp),
        6 => {
            var session_id: c_ulong = @as(c_ulong, rsp.data[3]);
            session_id |= @as(c_ulong, rsp.data[4]) << 8;
            session_id |= @as(c_ulong, rsp.data[5]) << 16;
            session_id |= @as(c_ulong, rsp.data[6]) << 24;

            const timestamp = c.ipmi32toh(&rsp.data[7]);

            _ = c.printf(" Boot Initiator Info :\n");
            _ = c.printf("    Channel Number : %d\n", @as(c_int, rsp.data[2] & 0x0f));
            _ = c.printf("    Session Id     : %08lXh\n", session_id);
            _ = c.printf("    Timestamp      : %s\n", c.ipmi_timestamp_numeric(timestamp));
        },
        7 => chassisBootmailboxParse(
            rsp.data[2..],
            @intCast(rsp.data_len - 2),
            flags,
        ),
        else => _ = c.printf(" Unsupported parameter %u\n", @as(c_uint, param_id)),
    }

    return IPMI_CC_OK;
}

/// The boot flags (parameter 5) decoder, split out of the `switch` above only
/// because it is long.
fn printBootFlags(rsp: *Response) void {
    _ = c.printf(" Boot Flags :\n");

    if (rsp.data[2] & BF1_VALID != 0) {
        _ = c.printf("   - Boot Flag Valid\n");
    } else {
        _ = c.printf("   - Boot Flag Invalid\n");
    }

    if (rsp.data[2] & BF1_PERSIST != 0) {
        _ = c.printf("   - Options apply to all future boots\n");
    } else {
        _ = c.printf("   - Options apply to only next boot\n");
    }

    if (rsp.data[2] & BF1_BOOT_TYPE_EFI != 0) {
        _ = c.printf("   - BIOS EFI boot \n");
    } else {
        _ = c.printf("   - BIOS PC Compatible (legacy) boot \n");
    }

    if (rsp.data[3] & BF2_CMOS_CLEAR != 0) _ = c.printf("   - CMOS Clear\n");
    if (rsp.data[3] & BF2_KEYLOCK != 0) _ = c.printf("   - Lock Keyboard\n");
    _ = c.printf("   - Boot Device Selector : ");
    switch (rsp.data[3] & BF2_BOOTDEV_MASK) {
        BF2_BOOTDEV_DEFAULT => _ = c.printf("No override\n"),
        BF2_BOOTDEV_PXE => _ = c.printf("Force PXE\n"),
        BF2_BOOTDEV_HDD => _ = c.printf("Force Boot from default Hard-Drive\n"),
        BF2_BOOTDEV_HDD_SAFE => _ = c.printf("Force Boot from default Hard-Drive, request Safe-Mode\n"),
        BF2_BOOTDEV_DIAG_PART => _ = c.printf("Force Boot from Diagnostic Partition\n"),
        BF2_BOOTDEV_CDROM => _ = c.printf("Force Boot from CD/DVD\n"),
        BF2_BOOTDEV_SETUP => _ = c.printf("Force Boot into BIOS Setup\n"),
        BF2_BOOTDEV_REMOTE_FDD => _ = c.printf("Force Boot from remotely connected Floppy/primary removable media\n"),
        BF2_BOOTDEV_REMOTE_CDROM => _ = c.printf("Force Boot from remotely connected CD/DVD\n"),
        BF2_BOOTDEV_REMOTE_PRIMARY_MEDIA => _ = c.printf("Force Boot from primary remote media\n"),
        BF2_BOOTDEV_REMOTE_HDD => _ = c.printf("Force Boot from remotely connected Hard-Drive\n"),
        BF2_BOOTDEV_FDD => _ = c.printf("Force Boot from Floppy/primary removable media\n"),
        else => _ = c.printf("Flag error\n"),
    }
    if (rsp.data[3] & BF2_BLANK_SCREEN != 0) _ = c.printf("   - Screen blank\n");
    if (rsp.data[3] & BF2_RESET_LOCKOUT != 0) _ = c.printf("   - Lock out Reset buttons\n");

    if (rsp.data[4] & BF3_POWER_LOCKOUT != 0)
        _ = c.printf("   - Lock out (power off/sleep request) via Power Button\n");

    _ = c.printf("   - BIOS verbosity : ");
    switch (rsp.data[4] & BF3_VERBOSITY_MASK) {
        BF3_VERBOSITY_DEFAULT => _ = c.printf("System Default\n"),
        BF3_VERBOSITY_QUIET => _ = c.printf("Request Quiet Display\n"),
        BF3_VERBOSITY_VERBOSE => _ = c.printf("Request Verbose Display\n"),
        else => _ = c.printf("Flag error\n"),
    }
    if (rsp.data[4] & BF3_EVENT_TRAPS != 0) _ = c.printf("   - Force progress event traps\n");
    if (rsp.data[4] & BF3_PASSWD_BYPASS != 0) _ = c.printf("   - User password bypass\n");
    if (rsp.data[4] & BF3_SLEEP_LOCKOUT != 0) _ = c.printf("   - Lock Out Sleep Button\n");
    _ = c.printf("   - Console Redirection control : ");
    switch (rsp.data[4] & BF3_CONSOLE_REDIR_MASK) {
        BF3_CONSOLE_REDIR_DEFAULT => _ = c.printf("Console redirection occurs per BIOS configuration setting (default)\n"),
        BF3_CONSOLE_REDIR_SUPPRESS => _ = c.printf("Suppress (skip) console redirection if enabled\n"),
        BF3_CONSOLE_REDIR_ENABLE => _ = c.printf("Request console redirection be enabled\n"),
        else => _ = c.printf("Flag error\n"),
    }

    if (rsp.data[5] & BF4_SHARED_MODE != 0) _ = c.printf("   - BIOS Shared Mode Override\n");
    _ = c.printf("   - BIOS Mux Control Override : ");
    switch (rsp.data[5] & BF4_BIOS_MUX_MASK) {
        BF4_BIOS_MUX_DEFAULT => _ = c.printf("BIOS uses recommended setting of the mux at the end of POST\n"),
        BF4_BIOS_MUX_BMC => _ = c.printf("Requests BIOS to force mux to BMC at conclusion of POST/start of OS boot\n"),
        BF4_BIOS_MUX_SYSTEM => _ = c.printf("Requests BIOS to force mux to system at conclusion of POST/start of OS boot\n"),
        else => _ = c.printf("Flag error\n"),
    }
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

/// `get_bootparam_options()`.
///
/// `optstring` must be writable: `strtok_r()` chops it up in place, exactly as
/// in C.  The only caller that passes a literal is
/// `ipmi_chassis_set_bootflag_help()`, whose "options=help" contains no comma
/// and so is never written to.
fn getBootparamOptions(optstring: [*:0]u8, set_flag: *u8, clr_flag: *u8) c_int {
    var saveptr: [*c]u8 = null;
    var option_error = false;
    set_flag.* = 0;
    clr_flag.* = 0;

    const optkw: [*:0]const u8 = "options=";
    if (c.strncmp(optstring, optkw, c.strlen(optkw)) != 0) {
        c.lprintf(log.Level.err, "No options= keyword found \"%s\"", optstring);
        return -1;
    }

    var token: [*c]u8 = c.strtok_r(optstring + 8, ",", &saveptr);
    while (token != null) : (token = c.strtok_r(null, ",", &saveptr)) {
        var setbit = false;
        var name: [*c]u8 = token;
        if (c.strcmp(name, "help") == 0) {
            option_error = true;
            break;
        }
        if (c.strncmp(name, "no-", 3) == 0) {
            setbit = true;
            name += 3;
        }
        var found = false;
        for (bootparam_options) |op| {
            if (c.strcmp(name, op.name) == 0) {
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
            c.lprintf(log.Level.err, "Invalid option: %s", name);
        }
    }

    if (option_error) {
        c.lprintf(log.Level.notice, " Legal options are:");
        c.lprintf(log.Level.notice, "  %-8s: print this message", @as([*:0]const u8, "help"));
        for (bootparam_options) |op| {
            c.lprintf(log.Level.notice, "  %-8s: %s", op.name, op.desc);
        }
        c.lprintf(
            log.Level.notice,
            " Any Option may be prepended with no- to invert sense of operation\n",
        );
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
        c.lprintf(
            log.Level.err,
            "Error Getting Chassis Boot Parameter %d",
            @as(c_int, param_id),
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get Chassis Boot Parameter %d failed: %s",
            @as(c_int, param_id),
            bootparamCcString(rsp.ccode, &get_bootparam_cc_vals),
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
            c.lprintf(log.Level.err, "Failed to read boot valid flag");
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
fn chassisSetBootdev(intf: *Intf, arg: ?[*:0]const u8, iflags: ?*const [BF_BYTE_COUNT]u8) c_int {
    var flags = [_]u8{0} ** BF_BYTE_COUNT;
    var rc: c_int = undefined;

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
                c.lprintf(log.Level.err, "Invalid argument: %s", a);
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
                _ = c.printf("Set Boot Device to %s\n", @as([*c]const u8, @ptrCast(arg)));
            }
        }
    }

    chassisBootparamSetInProgress(intf, SET_COMPLETE);
    return rc;
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
    c.lprintf(log.Level.notice,
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
    );
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

    c.lprintf(log.Level.info, "Writing Boot Mailbox...");

    if (argc < 1 or c.str2int(argv[0], &iana) != 0) {
        c.lprintf(log.Level.err, "No valid IANA PEN specified!\n");
        chassisBootmailboxHelp();
        return rc;
    }
    argv += 1;
    argc -= 1;

    if (argc < 1) {
        c.lprintf(log.Level.err, "No data provided!\n");
        chassisBootmailboxHelp();
        return rc;
    }

    // For text mode the size is the single argument string length plus one
    // byte for \0 termination.  For byte mode it is the number of byte
    // arguments without any additional termination.
    if (!use_text) {
        datasize = @intCast(argc);
    } else {
        datasize = c.strlen(argv[0]) + 1;
    }

    c.lprintf(log.Level.info, "Data size: %u", datasize);

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

    c.lprintf(log.Level.info, "Blocks to write: %d", blocks);

    if (blocks > CHASSIS_BOOT_MBOX_MAX_BLOCKS) {
        c.lprintf(
            log.Level.err,
            "Data size %zu exceeds maximum (%d)",
            datasize,
            @as(c_int, (CHASSIS_BOOT_MBOX_BLOCK_SZ * CHASSIS_BOOT_MBOX_MAX_BLOCKS) -
                CHASSIS_BOOT_MBOX_IANA_SZ),
        );
        return rc;
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

        c.lprintf(
            log.Level.info,
            "Block %3d: %s",
            @as(c_int, block),
            c.buf2str_extended(data, @intCast(blocksize), " "),
        );

        const unused = maxblocksize - blocksize;
        rc = chassisSetBootparam(
            intf,
            IPMI_CHASSIS_BOOTPARAM_INIT_MBOX,
            @ptrCast(&mbox),
            @intCast(@sizeOf(Mbox) - unused),
        );
        if (rc == IPMI_CC_PARAM_OUT_OF_RANGE) {
            c.lprintf(log.Level.err, "Hit end of mailbox writing block %d", @as(c_int, block));
        }
        if (rc != 0) {
            hit_error = true;
            break;
        }
    }

    if (!hit_error) {
        c.lprintf(log.Level.info, "Wrote %zu blocks of Boot Initiator Mailbox", blocks);
        chassisBootparamSetInProgress(intf, COMMIT_WRITE);

        rc = chassisBootparamClearAck(intf, BIOS_POST_ACK | OS_LOADER_ACK);
    }

    chassisBootparamSetInProgress(intf, SET_COMPLETE);
    return rc;
}

/// `chassis_get_bootmailbox()`.
fn chassisGetBootmailbox(intf: *Intf, block: i16, use_text: bool) c_int {
    var rc: c_int = IPMI_CC_UNSPECIFIED_ERROR;
    var param_str = [_]u8{0} ** 2; // Max "7"
    var block_str = [_]u8{0} ** 4; // Max "255"
    const bpargv = [2][*:0]const u8{
        @ptrCast(&param_str),
        @ptrCast(&block_str),
    };

    var flags: c_int = if (use_text) bpFlag(MBOX_PARSE_USE_TEXT) else 0;

    _ = c.snprintf(&param_str, param_str.len, "%u", @as(c_uint, IPMI_CHASSIS_BOOTPARAM_INIT_MBOX));

    if (block >= 0) {
        _ = c.snprintf(
            &block_str,
            block_str.len,
            "%u",
            @as(c_uint, @as(u8, @truncate(@as(u16, @bitCast(block))))),
        );

        rc = chassisGetBootparam(intf, bpargv.len, &bpargv, flags);
    } else {
        flags |= bpFlag(MBOX_PARSE_ALLBLOCKS);
        var currblk: c_int = 0;
        while (currblk <= 255) : (currblk += 1) {
            _ = c.snprintf(
                &block_str,
                block_str.len,
                "%u",
                @as(c_uint, @as(u8, @truncate(@as(c_uint, @bitCast(currblk))))),
            );

            if (currblk != 0) {
                // If block 0 succeeded, we don't want to print generic info
                // for each next block, and we don't want range error to be
                // reported when we hit the end of blocks.
                flags |= bpFlag(PARAM_NO_GENERIC_INFO);
                flags |= bpFlag(PARAM_NO_RANGE_ERROR);
            }

            rc = chassisGetBootparam(intf, bpargv.len, &bpargv, flags);

            if (rc != 0) {
                if (currblk != 0) rc = IPMI_CC_OK;
                break;
            }
        }
    }

    return rc;
}

/// `chassis_bootmailbox()`.
fn chassisBootmailbox(intf: *Intf, argc_in: c_int, argv_in: [*]const [*:0]u8) c_int {
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
            c.lprintf(log.Level.err, "Invalid block %s", argv[1]);
            return rc;
        }
        argv += 2;
        argc -= 2;
    }

    if (eqlArg(cmd, "get")) {
        rc = chassisGetBootmailbox(intf, block, use_text);
    } else if (eqlArg(cmd, "set")) {
        rc = chassisSetBootmailbox(intf, block, use_text, argc, argv);
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Power restore policy
// ---------------------------------------------------------------------------

/// `ipmi_chassis_power_policy()`.
fn chassisPowerPolicy(intf: *Intf, policy: u8) c_int {
    var policy_byte = policy;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_chassis;
    req.msg.cmd = 0x6;
    req.msg.data = @ptrCast(&policy_byte);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error in Power Restore Policy command");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Power Restore Policy command failed: %s", ccString(rsp.ccode));
        return -1;
    }

    if (policy == IPMI_CHASSIS_POLICY_NO_CHANGE) {
        _ = c.printf("Supported chassis power policy:  ");
        if (rsp.data[0] & (@as(u8, 1) << @intCast(IPMI_CHASSIS_POLICY_ALWAYS_OFF)) != 0)
            _ = c.printf("always-off ");
        if (rsp.data[0] & (@as(u8, 1) << @intCast(IPMI_CHASSIS_POLICY_ALWAYS_ON)) != 0)
            _ = c.printf("always-on ");
        if (rsp.data[0] & (@as(u8, 1) << @intCast(IPMI_CHASSIS_POLICY_PREVIOUS)) != 0)
            _ = c.printf("previous");
        _ = c.printf("\n");
    } else {
        _ = c.printf("Set chassis power restore policy to ");
        switch (policy) {
            IPMI_CHASSIS_POLICY_ALWAYS_ON => _ = c.printf("always-on\n"),
            IPMI_CHASSIS_POLICY_ALWAYS_OFF => _ = c.printf("always-off\n"),
            IPMI_CHASSIS_POLICY_PREVIOUS => _ = c.printf("previous\n"),
            else => _ = c.printf("unknown\n"),
        }
    }
    return 0;
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
        c.lprintf(log.Level.notice, power_usage);
        return 0;
    }
    if (eqlArg(argv[0], "status")) {
        return chassisPrintPowerStatus(intf);
    }

    const ctl = powerControlByte(argv[0]) orelse {
        c.lprintf(log.Level.err, "Invalid chassis power command: %s", argv[0]);
        return -1;
    };

    return chassisPowerControl(intf, ctl);
}

/// `ipmi_chassis_set_bootflag_help()`.
fn chassisSetBootflagHelp() callconv(.c) void {
    var set_flag: u8 = undefined;
    var clr_flag: u8 = undefined;
    c.lprintf(log.Level.notice, "bootparam set bootflag <device> [options=...]");
    c.lprintf(log.Level.notice, " Legal devices are:");
    c.lprintf(log.Level.notice, "  none           : No override");
    c.lprintf(log.Level.notice, "  force_pxe      : Force PXE boot");
    c.lprintf(log.Level.notice, "  force_disk     : Force boot from default Hard-drive");
    c.lprintf(log.Level.notice, "  force_safe     : Force boot from default Hard-drive, request Safe Mode");
    c.lprintf(log.Level.notice, "  force_diag     : Force boot from Diagnostic Partition");
    c.lprintf(log.Level.notice, "  force_cdrom    : Force boot from CD/DVD");
    c.lprintf(log.Level.notice, "  force_bios     : Force boot into BIOS Setup");
    c.lprintf(log.Level.notice, "  force_remotecd : Force boot from remote CD/DVD");
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
/// `optstring` must be writable; `strtok_r()` chops it up in place.
fn bootdevParseOptions(optstring: [*:0]u8, flags: *[BF_BYTE_COUNT]u8) bool {
    var saveptr: [*c]u8 = null;
    var option_error = false;

    @memset(flags, 0);

    var token: [*c]u8 = c.strtok_r(optstring, ",", &saveptr);
    while (token != null) : (token = c.strtok_r(null, ",", &saveptr)) {
        if (c.strcmp(token, "help") == 0) {
            option_error = true;
            break;
        }
        var found = false;
        for (bootdev_options) |op| {
            if (c.strcmp(token, op.name) == 0) {
                flags[op.offset] &= ~op.mask;
                flags[op.offset] |= op.value;
                found = true;
                break;
            }
        }
        if (!found) {
            // Option not found.
            option_error = true;
            c.lprintf(log.Level.err, "Invalid option: %s", token);
        }
    }

    if (option_error) {
        c.lprintf(log.Level.notice, "Legal options settings are:");
        c.lprintf(
            log.Level.notice,
            "  %-22s: %s",
            @as([*:0]const u8, "help"),
            @as([*:0]const u8, "print this message"),
        );
        for (bootdev_options) |op| {
            c.lprintf(log.Level.notice, "  %-22s: %s", op.name, op.desc);
        }
        return false;
    }

    return true;
}

/// `ipmi_chassis_main()`.
fn chassisMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var rc: c_int = -1;

    if (argc == 0 or eqlArg(argv[0], "help")) {
        c.lprintf(log.Level.notice,
            \\Chassis Commands:
            \\  status, power, policy, restart_cause
            \\  poh, identify, selftest,
            \\  bootdev, bootparam, bootmbox
        );
    } else if (eqlArg(argv[0], "status")) {
        rc = chassisStatus(intf);
    } else if (eqlArg(argv[0], "selftest")) {
        rc = chassisSelftest(intf);
    } else if (eqlArg(argv[0], "power")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            c.lprintf(log.Level.notice, power_usage);
            return 0;
        }
        if (eqlArg(argv[1], "status")) {
            return chassisPrintPowerStatus(intf);
        }
        const ctl = powerControlByte(argv[1]) orelse {
            c.lprintf(log.Level.err, "Invalid chassis power command: %s", argv[1]);
            return rc;
        };
        rc = chassisPowerControl(intf, ctl);
    } else if (eqlArg(argv[0], "identify")) {
        if (argc < 2) {
            rc = chassisIdentify(intf, null);
        } else if (eqlArg(argv[1], "help")) {
            c.lprintf(log.Level.notice, "chassis identify <interval>");
            c.lprintf(log.Level.notice, "                 default is 15 seconds");
            c.lprintf(log.Level.notice, "                 0 to turn off");
            c.lprintf(log.Level.notice, "                 force to turn on indefinitely");
        } else {
            rc = chassisIdentify(intf, argv[1]);
        }
    } else if (eqlArg(argv[0], "poh")) {
        rc = chassisPoh(intf);
    } else if (eqlArg(argv[0], "restart_cause")) {
        rc = chassisRestartCause(intf);
    } else if (eqlArg(argv[0], "policy")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            c.lprintf(log.Level.notice, "chassis policy <state>");
            c.lprintf(log.Level.notice, "   list        : return supported policies");
            c.lprintf(log.Level.notice, "   always-on   : turn on when power is restored");
            c.lprintf(log.Level.notice, "   previous    : return to previous state when power is restored");
            c.lprintf(log.Level.notice, "   always-off  : stay off after power is restored");
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
                c.lprintf(log.Level.err, "Invalid chassis policy: %s", argv[1]);
                return -1;
            }
            rc = chassisPowerPolicy(intf, ctl);
        }
    } else if (eqlArg(argv[0], "bootparam")) {
        if (argc < 3 or eqlArg(argv[1], "help")) {
            c.lprintf(log.Level.notice, "bootparam get <param #>");
            chassisSetBootflagHelp();
        } else if (eqlArg(argv[1], "get")) {
            rc = chassisGetBootparam(intf, argc - 2, argv + 2, 0);
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
            c.lprintf(log.Level.notice, "bootparam get|set <option> [value ...]");
        }
    } else if (eqlArg(argv[0], "bootdev")) {
        if (argc < 2 or eqlArg(argv[1], "help")) {
            c.lprintf(log.Level.notice, "bootdev <device> [clear-cmos=yes|no]");
            c.lprintf(log.Level.notice, "bootdev <device> [options=help,...]");
            c.lprintf(log.Level.notice, "  none     : Do not change boot device order");
            c.lprintf(log.Level.notice, "  pxe      : Force PXE boot");
            c.lprintf(log.Level.notice, "  disk     : Force boot from default Hard-drive");
            c.lprintf(log.Level.notice, "  safe     : Force boot from default Hard-drive, request Safe Mode");
            c.lprintf(log.Level.notice, "  diag     : Force boot from Diagnostic Partition");
            c.lprintf(log.Level.notice, "  cdrom    : Force boot from CD/DVD");
            c.lprintf(log.Level.notice, "  bios     : Force boot into BIOS Setup");
            c.lprintf(log.Level.notice, "  floppy   : Force boot from Floppy/primary removable media");
            c.lprintf(log.Level.notice, "  remotecd : Force boot from remote CD/DVD");
        } else {
            const kw: [*:0]const u8 = "options=";
            var optstr: ?[*:0]u8 = null;
            var flags: [BF_BYTE_COUNT]u8 = undefined;
            var use_flags = false;

            if (argc >= 3) {
                if (eqlArg(argv[2], "clear-cmos=yes")) {
                    // Exclusive clear-cmos, no other flags.
                    optstr = @constCast(@as([*:0]const u8, "clear-cmos"));
                } else if (c.strncmp(argv[2], kw, c.strlen(kw)) == 0) {
                    optstr = argv[2] + c.strlen(kw);
                }
            }
            if (optstr) |s| {
                if (!bootdevParseOptions(s, &flags)) return rc;
                use_flags = true;
            }
            rc = chassisSetBootdev(intf, argv[1], if (use_flags) &flags else null);
        }
    } else if (eqlArg(argv[0], "bootmbox")) {
        rc = chassisBootmailbox(intf, argc - 1, argv + 1);
    } else {
        c.lprintf(log.Level.err, "Invalid chassis command: %s", argv[0]);
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
