//! Port of `lib/ipmi_event.c`: the `event` command, which fabricates Platform
//! Event Message requests - either one of three canned samples, an event
//! derived from a sensor named in the SDR repository, or a file of raw event
//! bytes.
//!
//! Selected with `zig build -Dzig-modules=event`, which drops
//! `lib/ipmi_event.c` from the compile and links this module instead.
//! `src/ipmitool.c` reaches `ipmi_event_main()` through `ipmitool_cmd_list[]`;
//! it is the only symbol the C file exported, everything else there was
//! `static`.
//!
//! Things worth knowing before reading on:
//!
//! * **Two structs reach Zig as `opaque {}`.**  `struct platform_event_msg`
//!   and `struct sel_event_record` both carry an `event_type:7` /
//!   `event_dir:1` bitfield pair, and `struct sdr_record_common_sensor`
//!   carries several more, so `translate-c` demotes all three.  The first two
//!   get hand written `extern struct` mirrors checked against `abi_layout.h`;
//!   the third is only read at four byte offsets, which come from the same
//!   header, so no mirror is needed.
//! * **The event tables stay in C.**  `generic_event_types[]` and
//!   `sensor_specific_event_types[]` are `static const` *inside*
//!   `include/ipmitool/ipmi_sel.h`, which means every translation unit owns a
//!   private copy.  Duplicating them here would duplicate them again and make
//!   the port drift the moment the header changed, so offsets are resolved
//!   through `ipmi_get_first_event_sensor_type()` /
//!   `ipmi_get_next_event_sensor_type()` exactly as C does.
//! * **Formatting and string handling stay in libc.**  `printf`, `lprintf`,
//!   `strcmp`, `strcasecmp`, `strchr`, `strtok`, `isspace`, `fgets` and
//!   `str2uchar` are called through the `ipmi_c` bridge; `%-9s` padding, the
//!   `(null)` a NULL `%s` prints and `strtok`'s in-place chopping are all
//!   observable in the golden snapshots.
//! * **Three upstream defects are reproduced deliberately.**  See issue #35:
//!   - `ipmi_event_fromfile()` walks backwards over trailing whitespace with
//!     `while (isspace(*ptr) && ptr >= buf)`, which dereferences `ptr` before
//!     the bound is tested, so a line whose first character is `#` reads
//!     `buf[-1]`.
//!   - The same loop's `rc` is left at `-1` after a bad token but the outer
//!     `while (feof(fp) == 0)` keeps going, so a later good line overwrites
//!     the failure and `event file` exits 0.
//!   - `ipmi_event_fromsensor()` reports "Invalid Event" from a branch that
//!     the preceding `if`/`else if` pair makes unreachable.
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `event` is selected.
//!
//! Allocation: none.  Every buffer is a local, matching C.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const ValStr = @import("../util/helper.zig").ValStr;

const netfn_se: u6 = 0x04;

/// `IPMI_CMD_PLATFORM_EVENT`, the third member of `ipmi_event_cmd_t`.
const cmd_platform_event: u8 = 0x02;

const EVENT_DIR_ASSERT: u1 = 0;
const EVENT_DIR_DEASSERT: u1 = 1;

/// `EVENT_GENERATOR(SMS, 0)`: `((0x20 + 0) & 0x7f) << 1 | 1`.  A function-like
/// macro, so `translate-c` does not surface it.
const event_generator_sms_0: u8 = ((c.EVENT_SWID_SMS_BASE + 0) & 0x7f) << 1 | 1;

// ---------------------------------------------------------------------------
// Mirrors of the bitfield-carrying C structs
// ---------------------------------------------------------------------------

/// The byte shared by `event_type:7` and `event_dir:1`.
///
/// C declares the two orders under `#if WORDS_BIGENDIAN`, but both spell the
/// same byte: a big-endian compiler allocates the first-declared bitfield from
/// the most significant end, so `event_dir` is bit 7 either way.  A Zig
/// `packed struct(u8)` fills from bit 0 upwards, which matches.
const TypeDir = packed struct(u8) {
    event_type: u7 = 0,
    event_dir: u1 = 0,
};

/// `struct platform_event_msg`.
const PlatformEventMsg = extern struct {
    evm_rev: u8 = 0,
    sensor_type: u8 = 0,
    sensor_num: u8 = 0,
    td: TypeDir = .{},
    event_data: [3]u8 = .{ 0, 0, 0 },
};

/// `PLATFORM_EVENT_DATA_LEN_NON_SI`, `sizeof(struct platform_event_msg)`.
const platform_event_data_len_non_si: u16 = @sizeOf(PlatformEventMsg);
/// `PLATFORM_EVENT_DATA_LEN_SI`: system interfaces prepend a generator ID.
const platform_event_data_len_si: u16 = platform_event_data_len_non_si + 1;
/// `PLATFORM_EVENT_DATA_LEN_MAX`.
const platform_event_data_len_max: usize = platform_event_data_len_si;

/// `struct standard_spec_sel_rec`.  Unlike its container it is *not* packed,
/// so it keeps 4-byte alignment and 3 bytes of tail padding.
const StandardSpecSelRec = extern struct {
    timestamp: u32 = 0,
    gen_id: u16 = 0,
    evm_rev: u8 = 0,
    sensor_type: u8 = 0,
    sensor_num: u8 = 0,
    td: TypeDir = .{},
    event_data: [3]u8 = .{ 0, 0, 0 },
};

/// `struct oem_ts_spec_sel_rec`.
const OemTsSpecSelRec = extern struct {
    timestamp: u32,
    manf_id: [3]u8,
    oem_defined: [c.SEL_OEM_TS_DATA_LEN]u8,
};

/// `struct oem_nots_spec_sel_rec`.
const OemNotsSpecSelRec = extern struct {
    oem_defined: [c.SEL_OEM_NOTS_DATA_LEN]u8,
};

/// `struct sel_event_record`.
const SelEventRecord = extern struct {
    const SelType = extern union {
        standard_type: StandardSpecSelRec,
        oem_ts_type: OemTsSpecSelRec,
        oem_nots_type: OemNotsSpecSelRec,
    };

    record_id: u16 align(1) = 0,
    record_type: u8 = 0,
    sel_type: SelType align(1) = .{ .standard_type = .{} },
};

/// Byte offsets inside `struct sdr_record_common_sensor`.  The struct is
/// `opaque {}` on the Zig side, and only these four fields are read, so the
/// port indexes the record directly rather than mirroring 60-odd bytes of
/// masks and units it never touches.
const common_sensor = struct {
    const owner_id = c.ABI_OFFSETOF_sdr_common__keys__owner_id;
    /// The byte holding `keys.lun:2`, `keys.__reserved:2` and `keys.channel:4`.
    const keys_flags = c.ABI_OFFSETOF_sdr_common__keys__flags;
    const sensor_num = c.ABI_OFFSETOF_sdr_common__keys__sensor_num;
    const sensor_type = c.ABI_OFFSETOF_sdr_common__sensor__type;
    const event_type = c.ABI_OFFSETOF_sdr_common__event_type;
};

/// `struct sdr_record_list`, as returned by `ipmi_sdr_find_sdr_byid()`.
///
/// `translate-c` *does* produce a type for this one, but it silently drops the
/// `ATTRIBUTE_PACKING`, so its `record` sits at offset 24 instead of 21 and
/// every pointer read through it is garbage.  Hence the mirror, and hence the
/// `assertOpaqueLayout` at the bottom of the file: the numbers come from the C
/// compiler, not from translate-c.
///
/// Every arm of the C `record` union is a pointer to a sensor record, so one
/// untyped pointer represents all nine.
const SdrRecordList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrRecordList align(1),
    record: ?[*]const u8 align(1),
};

// ---------------------------------------------------------------------------
// Threshold state tables
// ---------------------------------------------------------------------------

const EVENT_THRESH_STATE_LNC_LO: u8 = 0;
const EVENT_THRESH_STATE_LNC_HI: u8 = 1;
const EVENT_THRESH_STATE_LCR_LO: u8 = 2;
const EVENT_THRESH_STATE_LCR_HI: u8 = 3;
const EVENT_THRESH_STATE_LNR_LO: u8 = 4;
const EVENT_THRESH_STATE_LNR_HI: u8 = 5;
const EVENT_THRESH_STATE_UNC_LO: u8 = 6;
const EVENT_THRESH_STATE_UNC_HI: u8 = 7;
const EVENT_THRESH_STATE_UCR_LO: u8 = 8;
const EVENT_THRESH_STATE_UCR_HI: u8 = 9;
const EVENT_THRESH_STATE_UNR_LO: u8 = 10;
const EVENT_THRESH_STATE_UNR_HI: u8 = 11;

/// `ipmi_event_thresh_lo[]`.
const ipmi_event_thresh_lo = [_]ValStr{
    .{ .val = EVENT_THRESH_STATE_LNC_LO, .str = "lnc" },
    .{ .val = EVENT_THRESH_STATE_LCR_LO, .str = "lcr" },
    .{ .val = EVENT_THRESH_STATE_LNR_LO, .str = "lnr" },
    .{ .val = EVENT_THRESH_STATE_UNC_LO, .str = "unc" },
    .{ .val = EVENT_THRESH_STATE_UCR_LO, .str = "ucr" },
    .{ .val = EVENT_THRESH_STATE_UNR_LO, .str = "unr" },
    .{ .val = 0, .str = null },
};

/// `ipmi_event_thresh_hi[]`.
const ipmi_event_thresh_hi = [_]ValStr{
    .{ .val = EVENT_THRESH_STATE_LNC_HI, .str = "lnc" },
    .{ .val = EVENT_THRESH_STATE_LCR_HI, .str = "lcr" },
    .{ .val = EVENT_THRESH_STATE_LNR_HI, .str = "lnr" },
    .{ .val = EVENT_THRESH_STATE_UNC_HI, .str = "unc" },
    .{ .val = EVENT_THRESH_STATE_UCR_HI, .str = "ucr" },
    .{ .val = EVENT_THRESH_STATE_UNR_HI, .str = "unr" },
    .{ .val = 0, .str = null },
};

/// `digi_on[]` and `digi_off[]` from the Digital Discrete arm, kept as one
/// table so the two arrays cannot drift out of step.
const digi_shortcuts = [_][2][*:0]const u8{
    .{ "present", "absent" },
    .{ "assert", "deassert" },
    .{ "limit", "nolimit" },
    .{ "fail", "nofail" },
    .{ "yes", "no" },
    .{ "on", "off" },
    .{ "up", "down" },
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    return intf.sendrecv.?(intf, req);
}

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn eql(a: [*:0]const u8, b: [*:0]const u8) bool {
    return c.strcmp(a, b) == 0;
}

fn eqlIgnoreCase(a: [*:0]const u8, b: [*:0]const u8) bool {
    return c.strcasecmp(a, b) == 0;
}

/// `is_system()`: a system interface needs the extra generator ID byte.
fn isSystem(chinfo: *const c.struct_channel_info_t) bool {
    return c.IPMI_CHANNEL_MEDIUM_SYSTEM == chinfo.medium or
        c.CH_SYSTEM == chinfo.channel;
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/// `ipmi_event_msg_print()`: render the event through the SEL printer so the
/// operator sees what is about to be sent.
fn eventMsgPrint(intf: *Intf, pmsg: *const PlatformEventMsg) void {
    var sel_event = std.mem.zeroes(SelEventRecord);

    sel_event.record_id = 0;
    c.htoipmi16(event_generator_sms_0, @ptrCast(&sel_event.sel_type.standard_type.gen_id));

    const std_type = &sel_event.sel_type.standard_type;
    std_type.evm_rev = pmsg.evm_rev;
    std_type.sensor_type = pmsg.sensor_type;
    std_type.sensor_num = pmsg.sensor_num;
    std_type.td.event_type = pmsg.td.event_type;
    std_type.td.event_dir = pmsg.td.event_dir;
    std_type.event_data[0] = pmsg.event_data[0];
    std_type.event_data[1] = pmsg.event_data[1];
    std_type.event_data[2] = pmsg.event_data[2];

    if (c.verbose != 0) {
        c.ipmi_sel_print_extended_entry_verbose(cIntf(intf), @ptrCast(&sel_event));
    } else {
        c.ipmi_sel_print_extended_entry(cIntf(intf), @ptrCast(&sel_event));
    }
}

/// `ipmi_send_platform_event()`.
fn sendPlatformEvent(intf: *Intf, emsg: *const PlatformEventMsg) c_int {
    var req = std.mem.zeroes(Request);
    var rqdata = std.mem.zeroes([platform_event_data_len_max]u8);
    var rqdata_start: [*]u8 = &rqdata;

    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.cmd = cmd_platform_event;
    req.msg.data = &rqdata;
    req.msg.data_len = platform_event_data_len_non_si;

    var chinfo = std.mem.zeroes(c.struct_channel_info_t);
    c.ipmi_current_channel_info(cIntf(intf), &chinfo);
    if (chinfo.channel == c.CH_UNKNOWN) {
        c.lprintf(log.Level.err, "Failed to send the platform event " ++
            "via an unknown channel");
        return -3;
    }

    if (isSystem(&chinfo)) {
        // system interface, need extra generator ID, see Fig. 29-2
        req.msg.data_len = platform_event_data_len_si;
        rqdata[0] = event_generator_sms_0;
        rqdata_start += 1;
    }

    @memcpy(rqdata_start[0..@sizeOf(PlatformEventMsg)], std.mem.asBytes(emsg));

    eventMsgPrint(intf, emsg);

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Platform Event Message command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Platform Event Message command failed: %s",
            ccString(rsp.ccode),
        );
        return -1;
    }

    return 0;
}

/// `ipmi_send_platform_event_num()`.  The `default:` arm is unreachable from
/// `ipmi_event_main()`, which only ever passes 1, 2 or 3, but it is kept so the
/// function behaves identically if anything else ever calls it.
fn sendPlatformEventNum(intf: *Intf, num: c_int) c_int {
    var emsg = std.mem.zeroes(PlatformEventMsg);

    // IPMB/LAN/etc
    switch (num) {
        1 => { // temperature
            _ = c.printf("Sending SAMPLE event: Temperature - " ++
                "Upper Critical - Going High\n");
            emsg.evm_rev = 0x04;
            emsg.sensor_type = 0x01;
            emsg.sensor_num = 0x30;
            emsg.td.event_dir = EVENT_DIR_ASSERT;
            emsg.td.event_type = 0x01;
            emsg.event_data[0] = EVENT_THRESH_STATE_UCR_HI;
            emsg.event_data[1] = 0xff;
            emsg.event_data[2] = 0xff;
        },
        2 => { // voltage error
            _ = c.printf("Sending SAMPLE event: Voltage Threshold - " ++
                "Lower Critical - Going Low\n");
            emsg.evm_rev = 0x04;
            emsg.sensor_type = 0x02;
            emsg.sensor_num = 0x60;
            emsg.td.event_dir = EVENT_DIR_ASSERT;
            emsg.td.event_type = 0x01;
            emsg.event_data[0] = EVENT_THRESH_STATE_LCR_LO;
            emsg.event_data[1] = 0xff;
            emsg.event_data[2] = 0xff;
        },
        3 => { // correctable ECC
            _ = c.printf("Sending SAMPLE event: Memory - Correctable ECC\n");
            emsg.evm_rev = 0x04;
            emsg.sensor_type = 0x0c;
            emsg.sensor_num = 0x53;
            emsg.td.event_dir = EVENT_DIR_ASSERT;
            emsg.td.event_type = 0x6f;
            emsg.event_data[0] = 0x00;
            emsg.event_data[1] = 0xff;
            emsg.event_data[2] = 0xff;
        },
        else => {
            c.lprintf(log.Level.err, "Invalid event number: %d", num);
            return -1;
        },
    }

    return sendPlatformEvent(intf, &emsg);
}

// ---------------------------------------------------------------------------
// Sensor lookup
// ---------------------------------------------------------------------------

/// `ipmi_event_find_offset()`: match a state description against the event
/// table for this sensor type / event type pair.
fn eventFindOffset(
    intf: *Intf,
    sensor_type: u8,
    event_type: u8,
    desc: ?[*:0]const u8,
) c_int {
    const wanted = desc orelse return 0x00;
    if (sensor_type == 0 or event_type == 0) return 0x00;

    var evt = c.ipmi_get_first_event_sensor_type(cIntf(intf), sensor_type, event_type);
    while (evt != null) : (evt = c.ipmi_get_next_event_sensor_type(evt)) {
        if (evt.*.desc != null and c.strcasecmp(wanted, evt.*.desc) == 0) {
            return evt.*.offset;
        }
    }

    c.lprintf(
        log.Level.warn,
        "Unable to find matching event offset for '%s'",
        wanted,
    );
    return -1;
}

/// `print_sensor_states()`.
fn printSensorStates(intf: *Intf, sensor_type: u8, event_type: u8) void {
    c.ipmi_sdr_print_discrete_state_mini(
        cIntf(intf),
        "Sensor States: \n  ",
        "\n  ",
        sensor_type,
        event_type,
        0xff,
        0xff,
    );
    _ = c.printf("\n");
}

/// `ipmi_event_fromsensor()`.
fn eventFromSensor(
    intf: *Intf,
    id: ?[*:0]u8,
    state: ?[*:0]u8,
    evdir: ?[*:0]u8,
) c_int {
    const sensor_id = id orelse {
        c.lprintf(log.Level.err, "No sensor ID supplied");
        return -1;
    };

    var emsg = std.mem.zeroes(PlatformEventMsg);
    emsg.evm_rev = 0x04;

    if (evdir) |dir_str| {
        if (eql(dir_str, "assert")) {
            emsg.td.event_dir = EVENT_DIR_ASSERT;
        } else if (eql(dir_str, "deassert")) {
            emsg.td.event_dir = EVENT_DIR_DEASSERT;
        } else {
            c.lprintf(
                log.Level.err,
                "Invalid event direction %s.  Must be 'assert' or 'deassert'",
                dir_str,
            );
            return -1;
        }
    } else {
        emsg.td.event_dir = EVENT_DIR_ASSERT;
    }

    _ = c.printf("Finding sensor %s... ", sensor_id);
    const sdr: ?*const SdrRecordList = @ptrCast(c.ipmi_sdr_find_sdr_byid(cIntf(intf), sensor_id));
    if (sdr == null) {
        _ = c.printf("not found!\n");
        return -1;
    }
    _ = c.printf("ok\n");

    var target: u8 = undefined;
    var lun: u8 = undefined;
    var channel: u8 = undefined;

    switch (sdr.?.type) {
        c.SDR_RECORD_TYPE_FULL_SENSOR, c.SDR_RECORD_TYPE_COMPACT_SENSOR => {
            const common = sdr.?.record.?;
            emsg.sensor_type = common[common_sensor.sensor_type];
            emsg.sensor_num = common[common_sensor.sensor_num];
            emsg.td.event_type = @truncate(common[common_sensor.event_type]);
            target = common[common_sensor.owner_id];
            lun = common[common_sensor.keys_flags] & 0x3;
            channel = (common[common_sensor.keys_flags] >> 4) & 0xf;
        },
        else => {
            c.lprintf(log.Level.err, "Unknown sensor type for id '%s'", sensor_id);
            return -1;
        },
    }

    emsg.event_data[1] = 0xff;
    emsg.event_data[2] = 0xff;

    var off: c_int = undefined;

    switch (emsg.td.event_type) {
        // Threshold Class
        1 => {
            var dir: c_int = 0;
            var hilo: c_int = 0;
            off = 1;

            if (state == null or eql(state.?, "list")) {
                _ = c.printf("Sensor States:\n");
                _ = c.printf("  lnr : Lower Non-Recoverable \n");
                _ = c.printf("  lcr : Lower Critical\n");
                _ = c.printf("  lnc : Lower Non-Critical\n");
                _ = c.printf("  unc : Upper Non-Critical\n");
                _ = c.printf("  ucr : Upper Critical\n");
                _ = c.printf("  unr : Upper Non-Recoverable\n");
                return -1;
            }

            const st = state.?;
            if (!eql(st, "lnr") and !eql(st, "lcr") and !eql(st, "lnc") and
                !eql(st, "unc") and !eql(st, "ucr") and !eql(st, "unr"))
            {
                c.lprintf(log.Level.err, "Invalid threshold identifier %s", st);
                return -1;
            }

            hilo = if (st[0] == 'u') 1 else 0;

            dir = if (emsg.td.event_dir == EVENT_DIR_ASSERT) hilo else @intFromBool(hilo == 0);

            if ((emsg.td.event_dir == EVENT_DIR_ASSERT and hilo == 1) or
                (emsg.td.event_dir == EVENT_DIR_DEASSERT and hilo == 0))
            {
                emsg.event_data[0] = @truncate(c.str2val(st, @ptrCast(&ipmi_event_thresh_hi)) & 0xf);
            } else if ((emsg.td.event_dir == EVENT_DIR_ASSERT and hilo == 0) or
                (emsg.td.event_dir == EVENT_DIR_DEASSERT and hilo == 1))
            {
                emsg.event_data[0] = @truncate(c.str2val(st, @ptrCast(&ipmi_event_thresh_lo)) & 0xf);
            } else {
                // Unreachable: the two arms above cover every (dir, hilo) pair.
                c.lprintf(log.Level.err, "Invalid Event");
                return -1;
            }

            const thr: *Response = @ptrCast(c.ipmi_sdr_get_sensor_thresholds(
                cIntf(intf),
                emsg.sensor_num,
                target,
                lun,
                channel,
            ) orelse {
                c.lprintf(
                    log.Level.err,
                    "Command Get Sensor Thresholds failed: invalid response.",
                );
                return -1;
            });
            if (thr.ccode != 0) {
                c.lprintf(
                    log.Level.err,
                    "Command Get Sensor Thresholds failed: %s",
                    ccString(thr.ccode),
                );
                return -1;
            }

            // threshold reading
            emsg.event_data[2] = thr.data[(emsg.event_data[0] / 2) + 1];

            const hyst: ?*Response = @ptrCast(c.ipmi_sdr_get_sensor_hysteresis(
                cIntf(intf),
                emsg.sensor_num,
                target,
                lun,
                channel,
            ));
            if (hyst != null and hyst.?.ccode == 0) {
                off = if (dir != 0) hyst.?.data[0] else hyst.?.data[1];
            }
            if (off <= 0) off = 1;

            // trigger reading
            if (dir != 0) {
                if ((@as(c_int, emsg.event_data[2]) + off) > 0xff) {
                    emsg.event_data[1] = 0xff;
                } else {
                    emsg.event_data[1] = @truncate(@as(c_uint, @bitCast(@as(c_int, emsg.event_data[2]) + off)));
                }
            } else {
                if ((@as(c_int, emsg.event_data[2]) - off) < 0) {
                    emsg.event_data[1] = 0;
                } else {
                    emsg.event_data[1] = @truncate(@as(c_uint, @bitCast(@as(c_int, emsg.event_data[2]) - off)));
                }
            }

            // trigger in byte 2, threshold in byte 3
            emsg.event_data[0] |= 0x50;
        },

        // Digital Discrete
        3, 4, 5, 6, 8, 9 => {
            // print list of available states for this sensor
            if (state == null or eqlIgnoreCase(state.?, "list")) {
                printSensorStates(intf, emsg.sensor_type, emsg.td.event_type);
                _ = c.printf("Sensor State Shortcuts:\n");
                for (digi_shortcuts) |pair| {
                    _ = c.printf("  %-9s  %-9s\n", pair[0], pair[1]);
                }
                return 0;
            }

            const st = state.?;
            off = 0;
            for (digi_shortcuts) |pair| {
                if (eqlIgnoreCase(st, pair[0])) {
                    emsg.event_data[0] = 1;
                    off = 1;
                    break;
                } else if (eqlIgnoreCase(st, pair[1])) {
                    emsg.event_data[0] = 0;
                    off = 1;
                    break;
                }
            }
            if (off == 0) {
                off = eventFindOffset(intf, emsg.sensor_type, emsg.td.event_type, st);
                if (off < 0) return -1;
                emsg.event_data[0] = @truncate(@as(c_uint, @bitCast(off)));
            }
        },

        // Generic Discrete
        2, 7, 10, 11, 12 => {
            // print list of available states for this sensor
            if (state == null or eqlIgnoreCase(state.?, "list")) {
                printSensorStates(intf, emsg.sensor_type, emsg.td.event_type);
                return 0;
            }
            off = eventFindOffset(intf, emsg.sensor_type, emsg.td.event_type, state.?);
            if (off < 0) return -1;
            emsg.event_data[0] = @truncate(@as(c_uint, @bitCast(off)));
        },

        // Sensor-Specific Discrete
        0x6f => {
            // print list of available states for this sensor
            if (state == null or eqlIgnoreCase(state.?, "list")) {
                printSensorStates(intf, emsg.sensor_type, emsg.td.event_type);
                return 0;
            }
            off = eventFindOffset(intf, emsg.sensor_type, emsg.td.event_type, state.?);
            if (off < 0) return -1;
            emsg.event_data[0] = @truncate(@as(c_uint, @bitCast(off)));
        },

        else => return -1,
    }

    return sendPlatformEvent(intf, &emsg);
}

// ---------------------------------------------------------------------------
// Reading events from a file
// ---------------------------------------------------------------------------

/// `ipmi_event_fromfile()`.
fn eventFromFile(intf: *Intf, file: ?[*:0]const u8) c_int {
    const name = file orelse return -1;

    const fp = c.ipmi_open_file(name, 0);
    if (fp == null) return -1;

    var buf: [1024]u8 = undefined;
    var rc: c_int = 0;

    while (c.feof(fp) == 0) {
        var count: usize = 0;
        if (c.fgets(&buf, 1024, fp) == null) continue;

        // Each line is a new event
        var rqdata = std.mem.zeroes([@sizeOf(PlatformEventMsg)]u8);

        // clip off optional comment tail indicated by #
        var ptr: [*c]u8 = c.strchr(&buf, '#');
        if (ptr != null) {
            ptr[0] = 0;
        } else {
            ptr = &buf;
            ptr += c.strlen(&buf);
        }

        // clip off trailing and leading whitespace
        //
        // Reproduced verbatim, including the out-of-bounds read: C tests
        // `isspace(*ptr)` before `ptr >= buf`, so a line beginning with `#`
        // inspects `buf[-1]`.  See issue #35.
        ptr -= 1;
        while (c.isspace(ptr[0]) != 0 and @intFromPtr(ptr) >= @intFromPtr(&buf)) {
            ptr[0] = 0;
            ptr -= 1;
        }
        ptr = &buf;
        while (c.isspace(ptr[0]) != 0) ptr += 1;
        if (c.strlen(ptr) == 0) continue;

        // parse the event, 7 bytes with optional comment
        // 0x00 0x00 0x00 0x00 0x00 0x00 0x00 # event
        var tok: [*c]u8 = c.strtok(ptr, " ");
        while (tok != null) {
            if (count == @sizeOf(PlatformEventMsg)) break;
            if (0 > c.str2uchar(tok, &rqdata[count])) {
                c.lprintf(log.Level.err, "Invalid token in file: [%s]", tok);
                rc = -1;
                break;
            }
            tok = c.strtok(null, " ");
            count += 1;
        }
        if (count < @sizeOf(PlatformEventMsg)) {
            c.lprintf(
                log.Level.err,
                "Invalid Event: %s",
                c.buf2str(&rqdata, rqdata.len),
            );
            continue;
        }

        // Now actually send it, failures will be logged by the sender
        rc = sendPlatformEvent(intf, @ptrCast(&rqdata));
        if (c.IPMI_CC_OK != rc) break;
    }

    _ = c.fclose(fp);
    return rc;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// `ipmi_event_usage()`.
fn eventUsage() void {
    c.lprintf(log.Level.notice, "");
    c.lprintf(log.Level.notice, "usage: event <num>");
    c.lprintf(log.Level.notice, "   Send generic test events");
    c.lprintf(log.Level.notice, "   1 : Temperature - Upper Critical - Going High");
    c.lprintf(log.Level.notice, "   2 : Voltage Threshold - Lower Critical - Going Low");
    c.lprintf(log.Level.notice, "   3 : Memory - Correctable ECC");
    c.lprintf(log.Level.notice, "");
    c.lprintf(log.Level.notice, "usage: event file <filename>");
    c.lprintf(log.Level.notice, "   Read and generate events from file");
    c.lprintf(log.Level.notice, "   Use the 'sel save' command to generate from SEL");
    c.lprintf(log.Level.notice, "");
    c.lprintf(log.Level.notice, "usage: event <sensorid> <state> [event_dir]");
    c.lprintf(log.Level.notice, "   sensorid  : Sensor ID string to use for event data");
    c.lprintf(log.Level.notice, "   state     : Sensor state, use 'list' to see possible states for sensor");
    c.lprintf(log.Level.notice, "   event_dir : assert, deassert [default=assert]");
    c.lprintf(log.Level.notice, "");
}

/// `ipmi_event_main()`.
fn eventMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var rc: c_int = 0;

    if (argc == 0 or eql(argv[0], "help")) {
        eventUsage();
        return 0;
    }
    if (eql(argv[0], "file")) {
        if (argc < 2) {
            eventUsage();
            return 0;
        }
        return eventFromFile(intf, argv[1]);
    }
    if (c.strlen(argv[0]) == 1) {
        switch (argv[0][0]) {
            '1' => return sendPlatformEventNum(intf, 1),
            '2' => return sendPlatformEventNum(intf, 2),
            '3' => return sendPlatformEventNum(intf, 3),
            else => {},
        }
    }
    if (argc < 2) {
        rc = eventFromSensor(intf, argv[0], null, null);
    } else if (argc < 3) {
        rc = eventFromSensor(intf, argv[0], argv[1], null);
    } else {
        rc = eventFromSensor(intf, argv[0], argv[1], argv[2]);
    }

    return rc;
}

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertOpaqueLayout(PlatformEventMsg, .{
        .size = c.ABI_SIZEOF_platform_event_msg,
        .alignment = c.ABI_ALIGNOF_platform_event_msg,
        .fields = &.{
            .{ .name = "evm_rev", .offset = c.ABI_OFFSETOF_platform_event_msg__evm_rev },
            .{ .name = "sensor_type", .offset = c.ABI_OFFSETOF_platform_event_msg__sensor_type },
            .{ .name = "sensor_num", .offset = c.ABI_OFFSETOF_platform_event_msg__sensor_num },
            .{ .name = "event_data", .offset = c.ABI_OFFSETOF_platform_event_msg__event_data },
        },
    });
    abi.assertOpaqueLayout(SdrRecordList, .{
        .size = c.ABI_SIZEOF_sdr_record_list,
        .alignment = c.ABI_ALIGNOF_sdr_record_list,
        .fields = &.{
            .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_record_list__id },
            .{ .name = "version", .offset = c.ABI_OFFSETOF_sdr_record_list__version },
            .{ .name = "type", .offset = c.ABI_OFFSETOF_sdr_record_list__type },
            .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_record_list__length },
            .{ .name = "raw", .offset = c.ABI_OFFSETOF_sdr_record_list__raw },
            .{ .name = "next", .offset = c.ABI_OFFSETOF_sdr_record_list__next },
            .{ .name = "record", .offset = c.ABI_OFFSETOF_sdr_record_list__record },
        },
    });
    abi.assertOpaqueLayout(SelEventRecord, .{
        .size = c.ABI_SIZEOF_sel_event_record,
        .alignment = c.ABI_ALIGNOF_sel_event_record,
        .fields = &.{
            .{ .name = "record_id", .offset = c.ABI_OFFSETOF_sel_event_record__record_id },
            .{ .name = "record_type", .offset = c.ABI_OFFSETOF_sel_event_record__record_type },
            .{ .name = "sel_type", .offset = c.ABI_OFFSETOF_sel_event_record__sel_type },
            .{ .name = "sel_type.standard_type.timestamp", .offset = c.ABI_OFFSETOF_sel_event_record__std__timestamp },
            .{ .name = "sel_type.standard_type.gen_id", .offset = c.ABI_OFFSETOF_sel_event_record__std__gen_id },
            .{ .name = "sel_type.standard_type.evm_rev", .offset = c.ABI_OFFSETOF_sel_event_record__std__evm_rev },
            .{ .name = "sel_type.standard_type.sensor_type", .offset = c.ABI_OFFSETOF_sel_event_record__std__sensor_type },
            .{ .name = "sel_type.standard_type.sensor_num", .offset = c.ABI_OFFSETOF_sel_event_record__std__sensor_num },
            .{ .name = "sel_type.standard_type.event_data", .offset = c.ABI_OFFSETOF_sel_event_record__std__event_data },
        },
    });
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(eventMain), @TypeOf(c.ipmi_event_main));

    @export(&eventMain, .{ .name = "ipmi_event_main", .linkage = .strong });
}
