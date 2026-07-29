//! Port of `lib/ipmi_mc.c`: the `mc` / `bmc` command tree - device ID, GUID,
//! self test, BMC global enables, the watchdog timer and the system info
//! parameters.
//!
//! Selected with `zig build -Dzig-modules=mc`, which drops `lib/ipmi_mc.c`
//! from the compile and links this module instead.  `src/ipmitool.c` reaches
//! `ipmi_mc_main()` through `ipmitool_cmd_list[]`; `lib/ipmi_pef.c`,
//! `lib/ipmi_fru.c` and `lib/ipmi_delloem.c` call `_ipmi_mc_get_guid()`,
//! `ipmi_guid2str()`, `ipmi_mc_getsysinfo()` and `ipmi_mc_setsysinfo()`
//! directly.  All of them link against this file unchanged and unaware.
//!
//! Four things are worth knowing before reading on:
//!
//! * **Formatting stays in libc.**  `printf`, `sprintf` and `lprintf` are
//!   called through the `ipmi_c` bridge rather than reimplemented, because
//!   `%0.1f`, `%02Xh`, `%-40s` and the exact rendering of `%08x` on a value
//!   that C truncated to `int` are all observable.  So do `strcmp`, `strlen`,
//!   `strncpy` and `strtol`: the module hands them pointers that C also handed
//!   them, including the NULL ones (see below).
//! * **Two upstream defects are reproduced deliberately**, because a port that
//!   fixed them would change behaviour:
//!   - `ipmi_mc_set_enables()` compares the whole argument against the option
//!     name with `strcmp()` and then reads `argv[i] + strlen(name) + 1` - one
//!     past the NUL - for the value.  The documented `option=on` spelling
//!     therefore never matches, while `option on` "works" by reading into the
//!     next `argv` string.
//!   - `find_set_wdt_string()` walks the reserved rows of the timer tables,
//!     whose `set` member is NULL, and hands that to `strcmp()`; and
//!     `parse_set_wdt_options()` hands `strtol()` the NULL that `strchr()`
//!     returns for an option written without `=`.  Both abort the process.
//!   Neither is fixed here; both are reported as issue #31.
//!   `tests/cases/41-mc.cases` pins both.
//! * **`char` signedness matters once.**  `ipmi_sysinfo_main()` derives a block
//!   count from `paramdata[3]`, a plain `char`, which is signed on x86-64 and
//!   unsigned on aarch64.  The buffer is declared `c_char` so that Zig makes
//!   the same choice the C compiler would on the same target.  On a target
//!   where `char` is unsigned a length byte of 239 or more makes C's read loop
//!   run off the end of its 256-byte `infostr` - a stack overflow, and the one
//!   upstream defect (issue #31) this port does not reproduce, because the
//!   corrupted bytes are whatever the C compiler happened to lay out next and
//!   so are not a behaviour a port can match.  No golden case reaches it; one
//!   that did would snapshot differently on the two CI architectures.
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `mc` is selected;
//!   see the note there.
//!
//! Allocation: none.  Every buffer here is a local, exactly as in C.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const netfn_app: u6 = 0x06;

const BMC_GET_DEVICE_ID: u8 = 0x01;
const BMC_COLD_RESET: u8 = 0x02;
const BMC_WARM_RESET: u8 = 0x03;
const BMC_GET_SELF_TEST: u8 = 0x04;
const BMC_RESET_WATCHDOG_TIMER: u8 = 0x22;
const BMC_SET_WATCHDOG_TIMER: u8 = 0x24;
const BMC_GET_WATCHDOG_TIMER: u8 = 0x25;
const BMC_SET_GLOBAL_ENABLES: u8 = 0x2e;
const BMC_GET_GLOBAL_ENABLES: u8 = 0x2f;
const BMC_GET_GUID: u8 = 0x37;
const IPMI_SET_SYS_INFO: u8 = 0x58;
const IPMI_GET_SYS_INFO: u8 = 0x59;

const IPMI_SYSINFO_SET0_SIZE = 14;
const IPMI_SYSINFO_SETN_SIZE = 16;

const IPMI_SYSINFO_SYSTEM_FW_VERSION = 0x01;
const IPMI_SYSINFO_HOSTNAME = 0x02;
const IPMI_SYSINFO_PRIMARY_OS_NAME = 0x03;
const IPMI_SYSINFO_OS_NAME = 0x04;
const IPMI_SYSINFO_DELL_OS_VERSION = 0xe4;
const IPMI_SYSINFO_DELL_URL = 0xde;

const IPM_SFT_CODE_OK: u8 = 0x55;
const IPM_SFT_CODE_NOT_IMPLEMENTED: u8 = 0x56;
const IPM_SFT_CODE_DEV_CORRUPTED: u8 = 0x57;
const IPM_SFT_CODE_FATAL_ERROR: u8 = 0x58;
const IPM_SFT_CODE_RESERVED: u8 = 0xff;

const IPM_WATCHDOG_RESET_ERROR: u8 = 0x80;
const IPM_WATCHDOG_SMS_OS: u8 = 0x04;
const IPM_WATCHDOG_NO_ACTION: u8 = 0x00;
const IPM_WATCHDOG_CLEAR_SMS_OS: u8 = 0x10;

const IPMI_WDT_USE_NOLOG_SHIFT = 7;
const IPMI_WDT_USE_DONTSTOP_SHIFT = 6;
const IPMI_WDT_USE_RUNNING_SHIFT = 6;
const IPMI_WDT_USE_MASK: u8 = 0x07;
const IPMI_WDT_INTR_SHIFT = 4;
const IPMI_WDT_INTR_MASK: u8 = 0x07;
const IPMI_WDT_ACTION_MASK: u8 = 0x07;

const GUID_NODE_SZ = 6;
const GUID_STR_MAXLEN = 36;

const guid_rfc4122: c_uint = 0;
const guid_ipmi: c_uint = 1;
const guid_smbios: c_uint = 2;
const guid_real_modes: c_uint = 3;
const guid_auto: c_uint = 3;
const guid_dump: c_uint = 4;

const guid_version_unknown: c_uint = 0;
const guid_version_time: c_uint = 1;
const guid_version_max: c_uint = 5;

// ---------------------------------------------------------------------------
// Little helpers that stand in for the `static inline` byte-order functions in
// include/ipmitool/helper.h and for `ntohs`/`ntohl` applied to a struct field.
// ---------------------------------------------------------------------------

fn le16(p: [*]const u8) u16 {
    return @as(u16, p[1]) << 8 | p[0];
}

fn le32(p: [*]const u8) u32 {
    return @as(u32, p[3]) << 24 | @as(u32, p[2]) << 16 | @as(u32, p[1]) << 8 | p[0];
}

fn be16(p: [*]const u8) u16 {
    return @as(u16, p[0]) << 8 | p[1];
}

fn be32(p: [*]const u8) u32 {
    return @as(u32, p[0]) << 24 | @as(u32, p[1]) << 16 | @as(u32, p[2]) << 8 | p[3];
}

fn htole16(h: u16, p: [*]u8) void {
    p[0] = @truncate(h);
    p[1] = @intCast(h >> 8);
}

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

// A `?:` over two string literals yields a slice, which cannot cross a
// variadic boundary; this picks the NUL-terminated pointer instead.
fn pick(cond: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (cond) yes else no;
}

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    return intf.sendrecv.?(intf, req);
}

// ---------------------------------------------------------------------------
// mc reset
// ---------------------------------------------------------------------------

/// `ipmi_mc_reset()`.
fn mcReset(intf: *Intf, cmd: c_int) c_int {
    if (intf.opened == 0) _ = intf.open.?(intf);

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = @truncate(@as(c_uint, @bitCast(cmd)));
    req.msg.data_len = 0;

    if (cmd == BMC_COLD_RESET) intf.noanswer = 1;

    const rsp = sendrecv(intf, &req);

    if (cmd == BMC_COLD_RESET) intf.abort = 1;

    if (cmd == BMC_COLD_RESET and rsp == null) {
        // Expected. See 20.2 Cold Reset Command, p.243, IPMIv2.0 rev1.0.
    } else if (rsp == null) {
        c.lprintf(log.Level.err, "MC reset command failed.");
        return -1;
    } else if (rsp.?.ccode != 0) {
        c.lprintf(log.Level.err, "MC reset command failed: %s", ccString(rsp.?.ccode));
        return -1;
    }

    _ = c.printf(
        "Sent %s reset command to MC\n",
        pick(cmd == BMC_WARM_RESET, "warm", "cold"),
    );

    return 0;
}

// ---------------------------------------------------------------------------
// BMC global enables
// ---------------------------------------------------------------------------

/// `struct bitfield_data`.
const BitfieldData = extern struct {
    name: ?[*:0]const u8 = null,
    desc: ?[*:0]const u8 = null,
    mask: u32 = 0,
};

/// `mc_enables_bf[]`.  Note the gap: bit 4 is reserved and has no entry.
const mc_enables_bf_table = [_]BitfieldData{
    .{ .name = "recv_msg_intr", .desc = "Receive Message Queue Interrupt", .mask = 1 << 0 },
    .{ .name = "event_msg_intr", .desc = "Event Message Buffer Full Interrupt", .mask = 1 << 1 },
    .{ .name = "event_msg", .desc = "Event Message Buffer", .mask = 1 << 2 },
    .{ .name = "system_event_log", .desc = "System Event Logging", .mask = 1 << 3 },
    .{ .name = "oem0", .desc = "OEM 0", .mask = 1 << 5 },
    .{ .name = "oem1", .desc = "OEM 1", .mask = 1 << 6 },
    .{ .name = "oem2", .desc = "OEM 2", .mask = 1 << 7 },
    .{},
};

/// `printf_mc_reset_usage()`.
fn printfMcResetUsage() void {
    c.lprintf(log.Level.notice, "usage: mc reset <warm|cold>");
}

/// `printf_mc_usage()`.
fn printfMcUsage() void {
    c.lprintf(log.Level.notice, "MC Commands:");
    c.lprintf(log.Level.notice, "  reset <warm|cold>");
    c.lprintf(log.Level.notice, "  guid [auto|smbios|ipmi|rfc4122|dump]");
    c.lprintf(log.Level.notice, "  info");
    c.lprintf(log.Level.notice, "  watchdog <get|reset|off>");
    c.lprintf(log.Level.notice, "  selftest");
    c.lprintf(log.Level.notice, "  getenables");
    c.lprintf(log.Level.notice, "  setenables <option=on|off> ...");
    for (mc_enables_bf_table) |bf| {
        if (bf.name == null) break;
        c.lprintf(log.Level.notice, "    %-20s  %s", bf.name, bf.desc);
    }
    printfSysinfoUsage(0);
}

/// `printf_sysinfo_usage()`.
fn printfSysinfoUsage(full_help: c_int) void {
    if (full_help != 0) c.lprintf(log.Level.notice, "usage:");

    c.lprintf(log.Level.notice, "  getsysinfo <argument>");

    if (full_help != 0) {
        c.lprintf(log.Level.notice, "    Retrieves system info from BMC for given argument");
    }

    c.lprintf(log.Level.notice, "  setsysinfo <argument> <string>");

    if (full_help != 0) {
        c.lprintf(log.Level.notice, "    Stores system info string for given argument to BMC");
        c.lprintf(log.Level.notice, "");
        c.lprintf(log.Level.notice, "  Valid arguments are:");
    }
    c.lprintf(log.Level.notice, "    system_fw_version   System firmware (e.g. BIOS) version");
    c.lprintf(log.Level.notice, "    primary_os_name     Primary operating system name");
    c.lprintf(log.Level.notice, "    os_name             Operating system name");
    c.lprintf(log.Level.notice, "    system_name         System Name of server(vendor dependent)");
    c.lprintf(log.Level.notice, "    delloem_os_version  Running version of operating system");
    c.lprintf(log.Level.notice, "    delloem_url         URL of BMC webserver");
    c.lprintf(log.Level.notice, "");
}

/// `print_watchdog_usage()`.
fn printWatchdogUsage() void {
    c.lprintf(log.Level.notice,
        \\usage: watchdog <command>:
        \\
        \\   set <option[=value]> [<option[=value]> ...]
        \\     Set Watchdog settings
        \\     Options: (* = mandatory)
        \\       timeout=<1-6553>                    - [0] Initial countdown value, sec
        \\       pretimeout=<1-255>                  - [0] Pre-timeout interval, sec
        \\       int=<smi|nmi|msg>                   - [-] Pre-timeout interrupt type
        \\       use=<frb2|post|osload|sms|oem>      - [-] Timer use
        \\       clear=<frb2|post|osload|sms|oem>    - [-] Clear timer use expiration
        \\                                                 flag, can be specified
        \\                                                 multiple times
        \\       action=<reset|poweroff|cycle|none>  - [none] Timer action
        \\       nolog                               - [-] Don't log the timer use
        \\       dontstop                            - [-] Don't stop the timer
        \\                                                 while applying settings
        \\
        \\   get
        \\     Get Current settings
        \\
        \\   reset
        \\     Restart Watchdog timer based on the most recent settings
        \\
        \\   off
        \\     Shut off a running Watchdog timer
    );
}

/// `ipmi_mc_get_enables()`.
fn mcGetEnables(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_GLOBAL_ENABLES;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Global Enables command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Global Enables command failed: %s", ccString(rsp.ccode));
        return -1;
    }

    for (mc_enables_bf_table) |bf| {
        if (bf.name == null) break;
        _ = c.printf(
            "%-40s : %sabled\n",
            bf.desc,
            pick(rsp.data[0] & @as(u8, @truncate(bf.mask)) != 0, "en", "dis"),
        );
    }

    return 0;
}

/// `ipmi_mc_set_enables()`.
///
/// The `strcmp()` guard and the `argv[i] + nl + 1` read past the NUL are
/// upstream defects, reproduced verbatim; see the module comment.
fn mcSetEnables(intf: *Intf, argc: c_int, argv: [*][*:0]u8) c_int {
    if (argc < 1) {
        printfMcUsage();
        return -1;
    } else if (c.strcmp(argv[0], "help") == 0) {
        printfMcUsage();
        return 0;
    }

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_GLOBAL_ENABLES;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Global Enables command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Global Enables command failed: %s", ccString(rsp.ccode));
        return -1;
    }

    const original = rsp.data[0];
    var en = original;

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        const arg = argv[@intCast(i)];
        for (mc_enables_bf_table) |bf| {
            const name = bf.name orelse break;
            const nl = c.strlen(name);
            if (c.strcmp(arg, name) != 0) continue;
            const value: [*c]const u8 = @as([*c]const u8, @ptrCast(arg)) + nl + 1;
            if (c.strcmp(value, "off") == 0) {
                _ = c.printf("Disabling %s\n", bf.desc);
                en &= ~@as(u8, @truncate(bf.mask));
            } else if (c.strcmp(value, "on") == 0) {
                _ = c.printf("Enabling %s\n", bf.desc);
                en |= @as(u8, @truncate(bf.mask));
            } else {
                c.lprintf(log.Level.err, "Unrecognized option: %s", arg);
            }
        }
    }

    if (en == original) {
        _ = c.printf("\nNothing to change...\n");
        _ = mcGetEnables(intf);
        return 0;
    }

    req.msg.cmd = BMC_SET_GLOBAL_ENABLES;
    req.msg.data = @ptrCast(&en);
    req.msg.data_len = 1;

    const rsp2 = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Set Global Enables command failed");
        return -1;
    };
    if (rsp2.ccode != 0) {
        c.lprintf(log.Level.err, "Set Global Enables command failed: %s", ccString(rsp2.ccode));
        return -1;
    }

    _ = c.printf("\nVerifying...\n");
    _ = mcGetEnables(intf);

    return 0;
}

// ---------------------------------------------------------------------------
// mc info
// ---------------------------------------------------------------------------

/// `ipm_dev_adtl_dev_support[8]`.
const ipm_dev_adtl_dev_support_table = [8]?[*:0]const u8{
    "Sensor Device",
    "SDR Repository Device",
    "SEL Device",
    "FRU Inventory Device",
    "IPMB Event Receiver",
    "IPMB Event Generator",
    "Bridge",
    "Chassis Device",
};

/// `ipmi_mc_get_deviceid()`.
fn mcGetDeviceid(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_DEVICE_ID;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Device ID command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Device ID command failed: %s", ccString(rsp.ccode));
        return -1;
    }

    const devid: *c.struct_ipm_devid_rsp = @ptrCast(@alignCast(&rsp.data[0]));

    _ = c.printf("Device ID                 : %i\n", @as(c_int, devid.device_id));
    _ = c.printf("Device Revision           : %i\n", @as(c_int, devid.device_revision & 0x0F));
    _ = c.printf(
        "Firmware Revision         : %u.%02x\n",
        @as(c_uint, devid.fw_rev1 & 0x7f),
        @as(c_uint, devid.fw_rev2),
    );
    _ = c.printf(
        "IPMI Version              : %x.%x\n",
        @as(c_uint, devid.ipmi_version & 0x0F),
        @as(c_uint, (devid.ipmi_version & 0xF0) >> 4),
    );
    const mfg = c.ipmi24toh(&devid.manufacturer_id);
    _ = c.printf("Manufacturer ID           : %lu\n", @as(c_long, mfg));
    _ = c.printf("Manufacturer Name         : %s\n", c.val2str(mfg, c.ipmi_oem_info));

    _ = c.printf(
        "Product ID                : %u (0x%02x%02x)\n",
        @as(c_uint, c.buf2short(&devid.product_id)),
        @as(c_uint, devid.product_id[1]),
        @as(c_uint, devid.product_id[0]),
    );

    const product = c.oemval2str(mfg, c.ipmi16toh(&devid.product_id), c.ipmi_oem_product_info);

    if (product != null) {
        _ = c.printf("Product Name              : %s\n", product);
    }

    _ = c.printf(
        "Device Available          : %s\n",
        pick(devid.fw_rev1 & 0x80 != 0, "no", "yes"),
    );
    _ = c.printf(
        "Provides Device SDRs      : %s\n",
        pick(devid.device_revision & 0x80 != 0, "yes", "no"),
    );
    _ = c.printf("Additional Device Support :\n");
    for (ipm_dev_adtl_dev_support_table, 0..) |name, i| {
        if (devid.adtl_device_support & (@as(u8, 1) << @intCast(i)) != 0) {
            _ = c.printf("    %s\n", name);
        }
    }
    if (rsp.data_len == @sizeOf(c.struct_ipm_devid_rsp)) {
        _ = c.printf("Aux Firmware Rev Info     : \n");
        // These values could be looked-up by vendor if documented, so we put
        // them on individual lines for better treatment later.
        _ = c.printf(
            "    0x%02x\n    0x%02x\n    0x%02x\n    0x%02x\n",
            @as(c_uint, devid.aux_fw_rev[0]),
            @as(c_uint, devid.aux_fw_rev[1]),
            @as(c_uint, devid.aux_fw_rev[2]),
            @as(c_uint, devid.aux_fw_rev[3]),
        );
    }
    return 0;
}

// ---------------------------------------------------------------------------
// GUID
// ---------------------------------------------------------------------------

/// `_ipmi_mc_get_guid()`.
fn mcGetGuid(intf: [*c]Intf, guid: [*c]c.ipmi_guid_t) callconv(.c) c_int {
    if (guid == null) return -3;

    guid.* = std.mem.zeroes(c.ipmi_guid_t);

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_GUID;

    const rsp = sendrecv(@ptrCast(intf), &req) orelse return -1;
    if (rsp.ccode != 0) {
        return rsp.ccode;
    } else if (rsp.data_len != 16 or rsp.data_len != @sizeOf(c.ipmi_guid_t)) {
        return -2;
    }
    @memcpy(
        @as([*]u8, @ptrCast(guid))[0..@sizeOf(c.ipmi_guid_t)],
        rsp.data[0..@sizeOf(c.ipmi_guid_t)],
    );
    return 0;
}

/// `_guid_time()`: convert a 60-bit GUID timestamp to `time_t`.
fn guidTime(t_low: u64, t_mid: u64, t_hi: u64) i64 {
    const t100ns_in_sec: u64 = 10000000;
    const epoch_since_gregorian: u64 = 12219292800;

    var gregorian: u64 = ((t_hi & 0x0fff) << 48) | (t_mid << 32) | t_low;

    gregorian /= t100ns_in_sec;
    return @bitCast(gregorian -% epoch_since_gregorian);
}

/// `_is_time_valid()`.
fn isTimeValid(t: i64) bool {
    const t_now = c.time(null);
    var tm: c.struct_tm = undefined;
    var now: c.struct_tm = undefined;

    var t_copy: c.time_t = t;
    var now_copy: c.time_t = t_now;
    _ = c.gmtime_r(&t_copy, &tm);
    _ = c.gmtime_r(&now_copy, &now);

    // It's enough to check that the year fits in [Epoch .. now] interval.

    if (tm.tm_year + 1900 < 1970) return false;

    if (tm.tm_year > now.tm_year) {
        // GUID timestamp can't be in future.
        return false;
    }

    return true;
}

/// `ipmi_parse_guid()`.
fn parseGuid(guid: ?*anyopaque, guid_mode_in: c.ipmi_guid_mode_t) callconv(.c) c.parsed_guid_t {
    var guid_mode = guid_mode_in;
    const raw: [*]u8 = @ptrCast(guid.?);
    var parsed_guid = std.mem.zeroes(c.parsed_guid_t);
    var t_low: [guid_real_modes]u32 = undefined;
    var t_mid: [guid_real_modes]u16 = undefined;
    var t_hi: [guid_real_modes]u16 = undefined;
    var clk: [guid_real_modes]u16 = undefined;
    var seconds: [guid_real_modes]i64 = undefined;
    var detect = false;

    // Unless another mode is detected, default to dumping.
    if (guid_mode == guid_auto) {
        detect = true;
        guid_mode = guid_dump;
    }

    // For IPMI all fields are little-endian (LSB first).  ipmi_guid_t is
    // node[6], clock_seq[2], time_hi[2], time_mid[2], time_low[4].
    t_hi[guid_ipmi] = le16(raw + 8);
    t_mid[guid_ipmi] = le16(raw + 10);
    t_low[guid_ipmi] = le32(raw + 12);
    clk[guid_ipmi] = le16(raw + 6);

    // For RFC4122 all fields are in network byte order (MSB first).
    // rfc_guid_t is time_low[4], time_mid[2], time_hi[2], clock_seq[2],
    // node[6].
    t_hi[guid_rfc4122] = be16(raw + 6);
    t_mid[guid_rfc4122] = be16(raw + 4);
    t_low[guid_rfc4122] = be32(raw + 0);
    clk[guid_rfc4122] = be16(raw + 8);

    // For SMBIOS time fields are little-endian (as in IPMI), the rest is in
    // network order (as in RFC4122).
    t_hi[guid_smbios] = le16(raw + 6);
    t_mid[guid_smbios] = le16(raw + 4);
    t_low[guid_smbios] = le32(raw + 0);
    clk[guid_smbios] = be16(raw + 8);

    // Using 0 here to allow for reordering of modes in ipmi_guid_mode_t.
    var i: c_uint = 0;
    while (i < guid_real_modes) : (i += 1) {
        seconds[i] = guidTime(t_low[i], t_mid[i], t_hi[i]);

        // If autodetection was initially requested and mode hasn't been
        // detected yet.
        if (detect) {
            const ver: c_uint = (t_hi[i] >> 12) & 0x0F;
            if (ver > guid_version_unknown and ver <= guid_version_max) {
                guid_mode = i;
                if (ver == guid_version_time and isTimeValid(seconds[i])) break;
            }
        }
    }

    if (guid_mode >= guid_real_modes) {
        guid_mode = guid_dump;
        // The endianness and field order are irrelevant for dump mode.
        @memcpy(
            std.mem.asBytes(&parsed_guid)[0..@sizeOf(c.ipmi_guid_t)],
            raw[0..@sizeOf(c.ipmi_guid_t)],
        );
        parsed_guid.mode = guid_mode;
        return parsed_guid;
    }

    // Return only a valid version in the parsed version field.  If one needs
    // the raw value, they still may use
    // GUID_VERSION(parsed_guid.time_hi_and_version).
    parsed_guid.ver = (t_hi[guid_mode] >> 12) & 0x0F;
    if (parsed_guid.ver > guid_version_max) {
        parsed_guid.ver = guid_version_unknown;
    }

    if (parsed_guid.ver == guid_version_time) {
        parsed_guid.time = seconds[guid_mode];
    }

    if (guid_mode == guid_ipmi) {
        // In IPMI all fields are little-endian (LSB first).  That is, first
        // byte last.  Hence, swap before copying - in place, as C does.
        const swapped = c.array_byteswap(raw, GUID_NODE_SZ);
        @memcpy(parsed_guid.node[0..GUID_NODE_SZ], swapped[0..GUID_NODE_SZ]);
    } else {
        // For RFC4122 and SMBIOS the node field is in network byte order.
        // That is first byte first.  Hence, copy as is.
        @memcpy(parsed_guid.node[0..GUID_NODE_SZ], (raw + 10)[0..GUID_NODE_SZ]);
    }

    parsed_guid.time_low = t_low[guid_mode];
    parsed_guid.time_mid = t_mid[guid_mode];
    parsed_guid.time_hi_and_version = t_hi[guid_mode];
    parsed_guid.clock_seq_and_rsvd = clk[guid_mode];

    parsed_guid.mode = guid_mode;
    return parsed_guid;
}

/// `ipmi_guid2str()`.
fn guid2str(str: [*c]u8, data: ?*const anyopaque, mode: c.ipmi_guid_mode_t) callconv(.c) c.parsed_guid_t {
    const guid = parseGuid(@constCast(data), mode);

    if (guid.mode == guid_dump) {
        _ = c.sprintf(str, "%s", c.buf2str(@ptrCast(data), @sizeOf(c.ipmi_guid_t)));
        return guid;
    }

    _ = c.sprintf(
        str,
        "%08x-%04x-%04x-%04x-%02x%02x%02x%02x%02x%02x",
        toInt(guid.time_low),
        toInt(guid.time_mid),
        toInt(guid.time_hi_and_version),
        @as(c_int, guid.clock_seq_and_rsvd),
        @as(c_int, guid.node[0]),
        @as(c_int, guid.node[1]),
        @as(c_int, guid.node[2]),
        @as(c_int, guid.node[3]),
        @as(c_int, guid.node[4]),
        @as(c_int, guid.node[5]),
    );
    return guid;
}

/// C's `(int)` applied to a `uint64_t`: truncate, then reinterpret.
fn toInt(v: u64) c_int {
    return @bitCast(@as(u32, @truncate(v)));
}

/// `ipmi_mc_print_guid()`.
fn mcPrintGuid(intf: *Intf, guid_mode: c.ipmi_guid_mode_t) c_int {
    // Allocate a byte array for ease of use in dump mode.
    var guid_data: [@sizeOf(c.ipmi_guid_t)]u8 = undefined;

    const guid_ver_str = [_][*:0]const u8{
        "Unknown/unsupported",
        "Time-based",
        "DCE Security with POSIX UIDs (not for IPMI)",
        "Name-based using MD5",
        "Random or pseudo-random",
        "Name-based using SHA-1",
    };

    const guid_mode_str = [_][*:0]const u8{
        "RFC4122",
        "IPMI",
        "SMBIOS",
        "Automatic (if you see this, report a bug)",
        "Unknown (data dumped)",
    };

    const rc = mcGetGuid(intf, @ptrCast(@alignCast(&guid_data)));
    if (c.eval_ccode(rc) != 0) {
        return -1;
    }

    _ = c.printf("System GUID   : ");

    var buf: [GUID_STR_MAXLEN + 1]u8 = undefined;
    const guid = guid2str(&buf, &guid_data, guid_mode);
    _ = c.printf("%s\n", &buf);

    // Print the GUID properties.
    if (guid_mode == guid_auto) {
        // ipmi_parse_guid() returns only valid modes in guid.ver.
        _ = c.printf("GUID Encoding : %s", guid_mode_str[guid.mode]);
        if (guid.mode != guid_ipmi) {
            _ = c.printf(" (WARNING: IPMI Specification violation!)");
        }
        _ = c.printf("\n");
    }

    _ = c.printf("GUID Version  : %s", guid_ver_str[guid.ver]);

    switch (guid.ver) {
        guid_version_unknown => {
            _ = c.printf(" (%d)\n", (toInt(guid.time_hi_and_version) >> 12) & 0x0F);
        },
        guid_version_time => {
            _ = c.printf(
                "\nTimestamp     : %s\n",
                c.ipmi_timestamp_numeric(@truncate(@as(u64, @bitCast(guid.time)))),
            );
        },
        else => {
            _ = c.printf("\n");
        },
    }

    return 0;
}

// ---------------------------------------------------------------------------
// mc selftest
// ---------------------------------------------------------------------------

/// `ipmi_mc_get_selftest()`.
fn mcGetSelftest(intf: *Intf) c_int {
    var rv: c_int = 0;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_SELF_TEST;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "No response from devices\n");
        return -1;
    };

    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Bad response: (%s)", ccString(rsp.ccode));
        return -1;
    }

    const code = rsp.data[0];
    const test_byte = rsp.data[1];

    if (code == IPM_SFT_CODE_OK) {
        _ = c.printf("Selftest: passed\n");
        rv = 0;
    } else if (code == IPM_SFT_CODE_NOT_IMPLEMENTED) {
        _ = c.printf("Selftest: not implemented\n");
        rv = -1;
    } else if (code == IPM_SFT_CODE_DEV_CORRUPTED) {
        _ = c.printf("Selftest: device corrupted\n");
        rv = -1;

        if (test_byte & 0x80 != 0) _ = c.printf(" -> SEL device not accessible\n");
        if (test_byte & 0x40 != 0) _ = c.printf(" -> SDR repository not accessible\n");
        if (test_byte & 0x20 != 0) _ = c.printf("FRU device not accessible\n");
        if (test_byte & 0x10 != 0) _ = c.printf("IPMB signal lines do not respond\n");
        if (test_byte & 0x08 != 0) _ = c.printf("SDR repository empty\n");
        if (test_byte & 0x04 != 0) _ = c.printf("Internal Use Area corrupted\n");
        if (test_byte & 0x02 != 0) _ = c.printf("Controller update boot block corrupted\n");
        if (test_byte & 0x01 != 0) _ = c.printf("controller operational firmware corrupted\n");
    } else if (code == IPM_SFT_CODE_FATAL_ERROR) {
        _ = c.printf("Selftest     : fatal error\n");
        _ = c.printf("Failure code : %02x\n", @as(c_uint, test_byte));
        rv = -1;
    } else if (code == IPM_SFT_CODE_RESERVED) {
        _ = c.printf("Selftest: N/A");
        rv = -1;
    } else {
        _ = c.printf("Selftest     : device specific (%02Xh)\n", @as(c_uint, code));
        _ = c.printf("Failure code : %02Xh\n", @as(c_uint, test_byte));
        rv = 0;
    }

    return rv;
}

// ---------------------------------------------------------------------------
// Watchdog timer
// ---------------------------------------------------------------------------

/// `struct wdt_string_s`.
const WdtString = extern struct {
    /// The name of 'timer use' for `watchdog get` command.
    get: ?[*:0]const u8,
    /// The name of 'timer use' for `watchdog set` command.
    set: ?[*:0]const u8,
};

const wdt_use_rows = [_]WdtString{
    .{ .get = "Reserved", .set = "none" },
    .{ .get = "BIOS FRB2", .set = "frb2" },
    .{ .get = "BIOS/POST", .set = "post" },
    .{ .get = "OS Load", .set = "osload" },
    .{ .get = "SMS/OS", .set = "sms" },
    .{ .get = "OEM", .set = "oem" },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
};

const wdt_int_rows = [_]WdtString{
    .{ .get = "None", .set = "none" },
    .{ .get = "SMI", .set = "smi" },
    .{ .get = "NMI/Diagnostic", .set = "nmi" },
    .{ .get = "Messaging", .set = "msg" },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
};

const wdt_action_rows = [_]WdtString{
    .{ .get = "No action", .set = "none" },
    .{ .get = "Hard Reset", .set = "reset" },
    .{ .get = "Power Down", .set = "poweroff" },
    .{ .get = "Power Cycle", .set = "cycle" },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
    .{ .get = "Reserved", .set = null },
};

fn wdtTable(comptime rows: []const WdtString) [rows.len + 1]?*const WdtString {
    var out: [rows.len + 1]?*const WdtString = undefined;
    for (0..rows.len) |i| out[i] = &rows[i];
    out[rows.len] = null;
    return out;
}

const wdt_use_table = wdtTable(&wdt_use_rows);
const wdt_int_table = wdtTable(&wdt_int_rows);
const wdt_action_table = wdtTable(&wdt_action_rows);

/// `find_set_wdt_string()`.
///
/// The reserved rows carry a NULL `set`, which this hands straight to
/// `strcmp()` - an upstream defect, reproduced; see the module comment.
fn findSetWdtString(w: [*c]const ?*const WdtString, s: [*c]const u8) callconv(.c) c_int {
    var val: c_int = 0;
    while (w[@intCast(val)] != null) {
        if (c.strcmp(s, @ptrCast(w[@intCast(val)].?.set)) == 0) break;
        val += 1;
    }
    if (w[@intCast(val)] == null) {
        return -1;
    }
    return val;
}

/// `ipmi_mc_get_watchdog()`.
fn mcGetWatchdog(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_GET_WATCHDOG_TIMER;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Watchdog Timer command failed");
        return -1;
    };

    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Watchdog Timer command failed: %s", ccString(rsp.ccode));
        return -1;
    }

    const d: [*]const u8 = &rsp.data;
    const use = d[0];
    const intr_action = d[1];
    const pre_timeout = d[2];
    const exp_flags = d[3];

    // Convert 100ms intervals to seconds.
    const init_cnt: f64 = @as(f64, @floatFromInt(le16(d + 4))) / 10.0;
    const pres_cnt: f64 = @as(f64, @floatFromInt(le16(d + 6))) / 10.0;

    _ = c.printf(
        "Watchdog Timer Use:     %s (0x%02x)\n",
        wdt_use_table[use & IPMI_WDT_USE_MASK].?.get,
        @as(c_uint, use),
    );
    _ = c.printf(
        "Watchdog Timer Is:      %s\n",
        pick(use & (1 << IPMI_WDT_USE_RUNNING_SHIFT) != 0, "Started/Running", "Stopped"),
    );
    _ = c.printf(
        "Watchdog Timer Logging: %s\n",
        pick(use & (1 << IPMI_WDT_USE_NOLOG_SHIFT) != 0, "Off", "On"),
    );
    _ = c.printf(
        "Watchdog Timer Action:  %s (0x%02x)\n",
        wdt_action_table[intr_action & IPMI_WDT_ACTION_MASK].?.get,
        @as(c_uint, intr_action),
    );
    _ = c.printf(
        "Pre-timeout interrupt:  %s\n",
        wdt_int_table[(intr_action >> IPMI_WDT_INTR_SHIFT) & IPMI_WDT_INTR_MASK].?.get,
    );
    _ = c.printf("Pre-timeout interval:   %d seconds\n", @as(c_int, pre_timeout));
    _ = c.printf(
        "Timer Expiration Flags: %s(0x%02x)\n",
        pick(exp_flags != 0, "", "None "),
        @as(c_uint, exp_flags),
    );
    for (0..8) |i| {
        if (exp_flags & (@as(u8, 1) << @intCast(i)) != 0) {
            _ = c.printf("                        * %s\n", wdt_use_table[i].?.get);
        }
    }
    _ = c.printf("Initial Countdown:      %0.1f sec\n", init_cnt);
    _ = c.printf("Present Countdown:      %0.1f sec\n", pres_cnt);

    return 0;
}

/// `wdt_conf_t`: configuration to set with `ipmi_mc_set_watchdog()`.
const WdtConf = struct {
    timeout: u16 = 0,
    pretimeout: u8 = 0,
    intr: u8 = 0,
    use: u8 = 0,
    clear: u8 = 0,
    action: u8 = 0,
    nolog: bool = false,
    dontstop: bool = false,
};

/// `parse_set_wdt_options()`.
///
/// `vstr` is NULL whenever the option was written without `=`; C passes that
/// straight to `strtol()` and `find_set_wdt_string()`, and so does this.
fn parseSetWdtOptions(conf: *WdtConf, argc: c_int, argv: [*][*:0]u8) bool {
    // Seconds, makes almost USHRT_MAX when converted to 100ms intervals.
    const MAX_TIMEOUT: c_int = 6553;
    // Seconds.
    const MAX_PRETIMEOUT: c_int = 255;
    var err = true;

    if (argc == 0 or c.strcmp(argv[0], "help") == 0) {
        return err;
    }

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        var val: c_long = undefined;
        const arg = argv[@intCast(i)];
        var vstr = c.strchr(arg, '=');
        if (vstr != null) vstr += 1; // Point to the value

        // Only check the first letter to allow for shortcuts.
        switch (arg[0]) {
            't' => { // timeout
                val = c.strtol(vstr, null, 10);
                if (val < 1 or val > MAX_TIMEOUT) {
                    c.lprintf(
                        log.Level.err,
                        "Timeout value %lu is out of range (1-%d)\n",
                        @as(c_ulong, @bitCast(val)),
                        MAX_TIMEOUT,
                    );
                    return err;
                }
                conf.timeout = @truncate(@as(c_ulong, @bitCast(val *% 10)));
            },
            'p' => { // pretimeout
                val = c.strtol(vstr, null, 10);
                if (val < 1 or val > MAX_PRETIMEOUT) {
                    c.lprintf(
                        log.Level.err,
                        "Pretimeout value %lu is out of range (1-%d)\n",
                        @as(c_ulong, @bitCast(val)),
                        MAX_PRETIMEOUT,
                    );
                    return err;
                }
                conf.pretimeout = @truncate(@as(c_ulong, @bitCast(val)));
            },
            'i' => { // int
                val = findSetWdtString(&wdt_int_table, vstr);
                if (val < 0) {
                    c.lprintf(log.Level.err, "Interrupt type '%s' is not valid\n", vstr);
                    return err;
                }
                conf.intr = @truncate(@as(c_ulong, @bitCast(val)));
            },
            'u' => { // use
                val = findSetWdtString(&wdt_use_table, vstr);
                if (val < 0) {
                    c.lprintf(log.Level.err, "Use '%s' is not valid\n", vstr);
                    return err;
                }
                conf.use = @truncate(@as(c_ulong, @bitCast(val)));
            },
            'a' => { // action
                val = findSetWdtString(&wdt_action_table, vstr);
                if (val < 0) {
                    c.lprintf(log.Level.err, "Use '%s' is not valid\n", vstr);
                    return err;
                }
                conf.action = @truncate(@as(c_ulong, @bitCast(val)));
            },
            'c' => { // clear
                val = findSetWdtString(&wdt_use_table, vstr);
                if (val < 0) {
                    c.lprintf(log.Level.err, "Use '%s' is not valid\n", vstr);
                    return err;
                }
                conf.clear |= @truncate(@as(c_uint, 1) << @intCast(@as(c_ulong, @bitCast(val)) & 31));
            },
            'n' => conf.nolog = true, // nolog
            'd' => conf.dontstop = true, // dontstop
            else => {
                c.lprintf(log.Level.err, "Invalid option '%s'", arg);
            },
        }
    }

    err = false;
    return err;
}

/// `ipmi_mc_set_watchdog()`.
fn mcSetWatchdog(intf: *Intf, argc: c_int, argv: [*][*:0]u8) c_int {
    var msg_data = [_]u8{0} ** 6;
    var rc: c_int = -1;
    var conf = WdtConf{};
    const options_error = parseSetWdtOptions(&conf, argc, argv);

    // Fill data bytes according to IPMI 2.0 Spec section 27.6.
    msg_data[0] = @as(u8, @intFromBool(conf.nolog)) << IPMI_WDT_USE_NOLOG_SHIFT;
    msg_data[0] |= @as(u8, @intFromBool(conf.dontstop)) << IPMI_WDT_USE_DONTSTOP_SHIFT;
    msg_data[0] |= conf.use & IPMI_WDT_USE_MASK;

    msg_data[1] = (conf.intr & IPMI_WDT_INTR_MASK) << IPMI_WDT_INTR_SHIFT;
    msg_data[1] |= conf.action & IPMI_WDT_ACTION_MASK;

    msg_data[2] = conf.pretimeout;

    msg_data[3] = conf.clear;

    htole16(conf.timeout, msg_data[4..]);

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_SET_WATCHDOG_TIMER;
    req.msg.data_len = 6;
    req.msg.data = &msg_data;

    c.lprintf(
        log.Level.info,
        "Sending Set Watchdog command [%02X %02X %02X %02X %02X %02X]:",
        @as(c_uint, msg_data[0]),
        @as(c_uint, msg_data[1]),
        @as(c_uint, msg_data[2]),
        @as(c_uint, msg_data[3]),
        @as(c_uint, msg_data[4]),
        @as(c_uint, msg_data[5]),
    );
    c.lprintf(log.Level.info, "  - nolog      = %d", @as(c_int, @intFromBool(conf.nolog)));
    c.lprintf(log.Level.info, "  - dontstop   = %d", @as(c_int, @intFromBool(conf.dontstop)));
    c.lprintf(log.Level.info, "  - use        = 0x%02hhX", @as(c_uint, conf.use));
    c.lprintf(log.Level.info, "  - intr       = 0x%02hhX", @as(c_uint, conf.intr));
    c.lprintf(log.Level.info, "  - action     = 0x%02hhX", @as(c_uint, conf.action));
    c.lprintf(log.Level.info, "  - pretimeout = %hhu", @as(c_uint, conf.pretimeout));
    c.lprintf(log.Level.info, "  - clear      = 0x%02hhX", @as(c_uint, conf.clear));
    c.lprintf(log.Level.info, "  - timeout    = %hu", @as(c_uint, conf.timeout));

    if (sendrecv(intf, &req)) |rsp| {
        rc = rsp.ccode;
        if (rc != 0) {
            c.lprintf(
                log.Level.err,
                "Set Watchdog Timer command failed: %s",
                ccString(rsp.ccode),
            );
        } else {
            c.lprintf(log.Level.notice, "Watchdog Timer was successfully configured");
        }
    } else {
        c.lprintf(log.Level.err, "Set Watchdog Timer command failed");
    }

    if (options_error) printWatchdogUsage();

    return rc;
}

/// `ipmi_mc_shutoff_watchdog()`.
fn mcShutoffWatchdog(intf: *Intf) c_int {
    var msg_data: [6]u8 = undefined;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_SET_WATCHDOG_TIMER;
    req.msg.data = &msg_data;
    req.msg.data_len = 6;

    // The only set cmd we're allowing is to shut off the timer.  Turning on
    // the timer should be the job of the ipmi watchdog driver.
    msg_data[0] = IPM_WATCHDOG_SMS_OS;
    msg_data[1] = IPM_WATCHDOG_NO_ACTION;
    msg_data[2] = 0x00; // pretimeout interval
    msg_data[3] = IPM_WATCHDOG_CLEAR_SMS_OS;
    msg_data[4] = 0xb8; // countdown lsb (100 ms/count)
    msg_data[5] = 0x0b; // countdown msb - 5 mins

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Watchdog Timer Shutoff command failed!");
        return -1;
    };

    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Watchdog Timer Shutoff command failed! %s", ccString(rsp.ccode));
        return -1;
    }

    _ = c.printf("Watchdog Timer Shutoff successful -- timer stopped\n");
    return 0;
}

/// `ipmi_mc_rst_watchdog()`.
fn mcRstWatchdog(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = BMC_RESET_WATCHDOG_TIMER;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Reset Watchdog Timer command failed!");
        return -1;
    };

    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Reset Watchdog Timer command failed: %s",
            if (rsp.ccode == IPM_WATCHDOG_RESET_ERROR)
                @as([*c]const u8, "Attempt to reset uninitialized watchdog")
            else
                ccString(rsp.ccode),
        );
        return -1;
    }

    _ = c.printf("IPMI Watchdog Timer Reset -  countdown restarted!\n");
    return 0;
}

// ---------------------------------------------------------------------------
// System info parameters
// ---------------------------------------------------------------------------

/// `sysinfo_param()`.
fn sysinfoParam(str: [*c]const u8, maxset: *c_int) c_int {
    if (str == null) return -1;

    maxset.* = 4;
    if (c.strcmp(str, "system_name") == 0) {
        return IPMI_SYSINFO_HOSTNAME;
    } else if (c.strcmp(str, "primary_os_name") == 0) {
        return IPMI_SYSINFO_PRIMARY_OS_NAME;
    } else if (c.strcmp(str, "os_name") == 0) {
        return IPMI_SYSINFO_OS_NAME;
    } else if (c.strcmp(str, "delloem_os_version") == 0) {
        return IPMI_SYSINFO_DELL_OS_VERSION;
    } else if (c.strcmp(str, "delloem_url") == 0) {
        maxset.* = 2;
        return IPMI_SYSINFO_DELL_URL;
    } else if (c.strcmp(str, "system_fw_version") == 0) {
        return IPMI_SYSINFO_SYSTEM_FW_VERSION;
    }

    return -1;
}

/// `ipmi_mc_getsysinfo()`.
fn mcGetsysinfo(
    intf: [*c]Intf,
    param: c_int,
    block: c_int,
    set: c_int,
    len_in: c_int,
    buffer: ?*anyopaque,
) callconv(.c) c_int {
    var data = [_]u8{0} ** 4;
    var len = len_in;

    // C writes `memset(buffer, 0, len)` unguarded; `lib/ipmi_delloem.c:1114`
    // calls in with `len == 0, buffer == NULL`, which is a no-op there and
    // here.
    if (buffer) |b| {
        @memset(@as([*]u8, @ptrCast(b))[0..@intCast(@max(len, 0))], 0);
    }

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.netfn_lun.lun = 0;
    req.msg.cmd = IPMI_GET_SYS_INFO;
    req.msg.data_len = 4;
    req.msg.data = &data;

    if (c.verbose > 1) {
        _ = c.printf(
            "getsysinfo: %.2x/%.2x/%.2x\n",
            @as(c_int, param),
            @as(c_int, block),
            @as(c_int, set),
        );
    }

    data[0] = 0; // get/set
    data[1] = @truncate(@as(c_uint, @bitCast(param)));
    data[2] = @truncate(@as(c_uint, @bitCast(block)));
    data[3] = @truncate(@as(c_uint, @bitCast(set)));

    // Format of get output is:
    //   u8 param_rev
    //   u8 selector
    //   u8 encoding  bit[0-3];
    //   u8 length
    //   u8 data0[14]
    const rsp = sendrecv(@ptrCast(intf), &req) orelse return -1;

    if (rsp.ccode == 0) {
        if (len > rsp.data_len) len = rsp.data_len;
        if (len != 0 and buffer != null) {
            @memcpy(
                @as([*]u8, @ptrCast(buffer.?))[0..@intCast(len)],
                rsp.data[0..@intCast(len)],
            );
        }
    }
    return rsp.ccode;
}

/// `ipmi_mc_setsysinfo()`.
fn mcSetsysinfo(intf: [*c]Intf, len: c_int, buffer: ?*anyopaque) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.netfn_lun.lun = 0;
    req.msg.cmd = IPMI_SET_SYS_INFO;
    req.msg.data_len = @bitCast(@as(c_ushort, @truncate(@as(c_uint, @bitCast(len)))));
    req.msg.data = @ptrCast(buffer);

    // Format of set input:
    //   u8 param rev
    //   u8 selector
    //   u8 data1[16]
    if (sendrecv(@ptrCast(intf), &req)) |rsp| {
        return rsp.ccode;
    }
    return -1;
}

/// `ipmi_sysinfo_main()`.
fn sysinfoMain(intf: *Intf, argc: c_int, argv: [*][*:0]u8, is_set: c_int) c_int {
    var infostr = [_]u8{0} ** 256;
    // `char`, not `uint8_t`: paramdata[3] feeds an int expression below and
    // plain char is signed on x86-64 but unsigned on aarch64.
    var paramdata = [_]c_char{0} ** 18;
    var maxset: c_int = 0;
    var set: c_int = 0;

    if (argc == 2 and c.strcmp(argv[1], "help") == 0) {
        printfSysinfoUsage(1);
        return 0;
    } else if (argc < 2 or (is_set == 1 and argc < 3)) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        printfSysinfoUsage(1);
        return -1;
    }

    // Get Parameters
    const param = sysinfoParam(argv[1], &maxset);
    if (param < 0) {
        c.lprintf(log.Level.err, "Invalid mc/bmc %s command: %s", argv[0], argv[1]);
        printfSysinfoUsage(1);
        return -1;
    }

    var rc: c_int = 0;
    if (is_set != 0) {
        const str = argv[2];
        var pos: c_int = 0;
        set = 0;
        var len: c_int = @intCast(c.strlen(str));

        // First block holds 14 bytes, all others hold 16.
        if (@divTrunc(len + 2 + 15, 16) >= maxset) {
            len = (maxset * 16) - 2;
        }

        while (true) {
            @memset(&paramdata, 0);
            paramdata[0] = @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(param)))));
            paramdata[1] = @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(set)))));
            if (set == 0) {
                // First block is special case.
                paramdata[2] = 0; // ascii encoding
                paramdata[3] = @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast(len))))); // length
                _ = c.strncpy(
                    @ptrCast(paramdata[4..].ptr),
                    str + @as(usize, @intCast(pos)),
                    IPMI_SYSINFO_SET0_SIZE,
                );
                pos += IPMI_SYSINFO_SET0_SIZE;
            } else {
                _ = c.strncpy(
                    @ptrCast(paramdata[2..].ptr),
                    str + @as(usize, @intCast(pos)),
                    IPMI_SYSINFO_SETN_SIZE,
                );
                pos += IPMI_SYSINFO_SETN_SIZE;
            }
            rc = mcSetsysinfo(intf, 18, &paramdata);

            if (rc != 0) break;

            set += 1;
            if (pos >= len) break;
        }
    } else {
        @memset(&infostr, 0);
        // Read blocks of data.
        var pos: usize = 0;
        set = 0;
        while (set < maxset) : (set += 1) {
            rc = mcGetsysinfo(intf, param, set, 0, 18, &paramdata);

            if (rc != 0) break;

            if (set == 0) {
                // First block is special case.
                if ((@as(c_int, paramdata[2]) & 0xF) == 0) {
                    // Determine max number of blocks to read.
                    maxset = @divTrunc((@as(c_int, paramdata[3]) + 2) + 15, 16);
                }
                @memcpy(
                    infostr[pos..][0..IPMI_SYSINFO_SET0_SIZE],
                    @as([*]const u8, @ptrCast(paramdata[4..].ptr))[0..IPMI_SYSINFO_SET0_SIZE],
                );
                pos += IPMI_SYSINFO_SET0_SIZE;
            } else {
                @memcpy(
                    infostr[pos..][0..IPMI_SYSINFO_SETN_SIZE],
                    @as([*]const u8, @ptrCast(paramdata[2..].ptr))[0..IPMI_SYSINFO_SETN_SIZE],
                );
                pos += IPMI_SYSINFO_SETN_SIZE;
            }
        }
        _ = c.printf("%s\n", &infostr);
    }
    if (rc < 0) {
        c.lprintf(log.Level.err, "%s %s set %d command failed", argv[0], argv[1], set);
    } else if (rc == 0x80) {
        c.lprintf(log.Level.err, "%s %s parameter not supported", argv[0], argv[1]);
    } else if (rc > 0) {
        c.lprintf(log.Level.err, "%s command failed: %s", argv[0], c.val2str(
            @bitCast(rc),
            c.completion_code_vals,
        ));
    }
    return rc;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// `ipmi_mc_main()`.
fn mcMain(intf_ptr: [*c]Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const intf: *Intf = @ptrCast(intf_ptr);
    var rc: c_int = 0;

    if (argc < 1) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        printfMcUsage();
        rc = -1;
    } else if (c.strcmp(argv[0], "help") == 0) {
        printfMcUsage();
        rc = 0;
    } else if (c.strcmp(argv[0], "reset") == 0) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            printfMcResetUsage();
            rc = -1;
        } else if (c.strcmp(argv[1], "help") == 0) {
            printfMcResetUsage();
            rc = 0;
        } else if (c.strcmp(argv[1], "cold") == 0) {
            rc = mcReset(intf, BMC_COLD_RESET);
        } else if (c.strcmp(argv[1], "warm") == 0) {
            rc = mcReset(intf, BMC_WARM_RESET);
        } else {
            c.lprintf(log.Level.err, "Invalid mc/bmc %s command: %s", argv[0], argv[1]);
            printfMcResetUsage();
            rc = -1;
        }
    } else if (c.strcmp(argv[0], "info") == 0) {
        rc = mcGetDeviceid(intf);
    } else if (c.strcmp(argv[0], "guid") == 0) {
        var guid_mode: c.ipmi_guid_mode_t = guid_auto;

        // Allow for 'rfc' and 'rfc4122'.
        if (argc > 1) {
            if (c.strcmp(argv[1], "rfc") == 0) {
                guid_mode = guid_rfc4122;
            } else if (c.strcmp(argv[1], "smbios") == 0) {
                guid_mode = guid_smbios;
            } else if (c.strcmp(argv[1], "ipmi") == 0) {
                guid_mode = guid_ipmi;
            } else if (c.strcmp(argv[1], "auto") == 0) {
                guid_mode = guid_auto;
            } else if (c.strcmp(argv[1], "dump") == 0) {
                guid_mode = guid_dump;
            }
        }
        rc = mcPrintGuid(intf, guid_mode);
    } else if (c.strcmp(argv[0], "getenables") == 0) {
        rc = mcGetEnables(intf);
    } else if (c.strcmp(argv[0], "setenables") == 0) {
        rc = mcSetEnables(intf, argc - 1, argv + 1);
    } else if (c.strcmp(argv[0], "selftest") == 0) {
        rc = mcGetSelftest(intf);
    } else if (c.strcmp(argv[0], "watchdog") == 0) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            printWatchdogUsage();
            rc = -1;
        } else if (c.strcmp(argv[1], "help") == 0) {
            printWatchdogUsage();
            rc = 0;
        } else if (c.strcmp(argv[1], "set") == 0) {
            if (argc < 3) { // Requires options
                c.lprintf(log.Level.err, "Not enough parameters given.");
                printWatchdogUsage();
                rc = -1;
            } else {
                rc = mcSetWatchdog(intf, argc - 2, argv + 2);
            }
        } else if (c.strcmp(argv[1], "get") == 0) {
            rc = mcGetWatchdog(intf);
        } else if (c.strcmp(argv[1], "off") == 0) {
            rc = mcShutoffWatchdog(intf);
        } else if (c.strcmp(argv[1], "reset") == 0) {
            rc = mcRstWatchdog(intf);
        } else {
            c.lprintf(log.Level.err, "Invalid mc/bmc %s command: %s", argv[0], argv[1]);
            printWatchdogUsage();
            rc = -1;
        }
    } else if (c.strcmp(argv[0], "getsysinfo") == 0) {
        rc = sysinfoMain(intf, argc, argv, 0);
    } else if (c.strcmp(argv[0], "setsysinfo") == 0) {
        rc = sysinfoMain(intf, argc, argv, 1);
    } else {
        c.lprintf(log.Level.err, "Invalid mc/bmc command: %s", argv[0]);
        printfMcUsage();
        rc = -1;
    }
    return rc;
}

// ---------------------------------------------------------------------------
// C ABI surface
//
// The twelve symbols `lib/ipmi_mc.c` exported: seven functions and five data
// objects.  Only `ipmi_mc_main`, `_ipmi_mc_get_guid`, `ipmi_parse_guid`,
// `ipmi_guid2str`, `ipmi_mc_getsysinfo` and `ipmi_mc_setsysinfo` are used from
// another translation unit, but the rest were global in C too and stay global
// here so that `nm -g` matches.
// ---------------------------------------------------------------------------

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(mcMain), @TypeOf(c.ipmi_mc_main));
    abi.assertCallSignature(@TypeOf(mcGetGuid), @TypeOf(c._ipmi_mc_get_guid));
    abi.assertCallSignature(@TypeOf(parseGuid), @TypeOf(c.ipmi_parse_guid));
    abi.assertCallSignature(@TypeOf(guid2str), @TypeOf(c.ipmi_guid2str));
    abi.assertCallSignature(@TypeOf(mcGetsysinfo), @TypeOf(c.ipmi_mc_getsysinfo));
    abi.assertCallSignature(@TypeOf(mcSetsysinfo), @TypeOf(c.ipmi_mc_setsysinfo));
    abi.assertCallSignature(@TypeOf(findSetWdtString), @TypeOf(c.find_set_wdt_string));

    @export(&mcMain, .{ .name = "ipmi_mc_main", .linkage = .strong });
    @export(&mcGetGuid, .{ .name = "_ipmi_mc_get_guid", .linkage = .strong });
    @export(&parseGuid, .{ .name = "ipmi_parse_guid", .linkage = .strong });
    @export(&guid2str, .{ .name = "ipmi_guid2str", .linkage = .strong });
    @export(&mcGetsysinfo, .{ .name = "ipmi_mc_getsysinfo", .linkage = .strong });
    @export(&mcSetsysinfo, .{ .name = "ipmi_mc_setsysinfo", .linkage = .strong });
    @export(&findSetWdtString, .{ .name = "find_set_wdt_string", .linkage = .strong });

    @export(&ipm_dev_adtl_dev_support_table, .{ .name = "ipm_dev_adtl_dev_support", .linkage = .strong });
    @export(&mc_enables_bf_table, .{ .name = "mc_enables_bf", .linkage = .strong });
    @export(&wdt_use_table, .{ .name = "wdt_use", .linkage = .strong });
    @export(&wdt_int_table, .{ .name = "wdt_int", .linkage = .strong });
    @export(&wdt_action_table, .{ .name = "wdt_action", .linkage = .strong });
}
