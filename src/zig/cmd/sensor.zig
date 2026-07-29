//! Port of `lib/ipmi_sensor.c`: the `sensor` command - `list`, `get`,
//! `reading` and `thresh` - plus the two entry points other translation units
//! call, `ipmi_sensor_print_fc()` and
//! `ipmi_sensor_get_sensor_reading_factors()`.
//!
//! Selected with `zig build -Dzig-modules=sensor`, which drops
//! `lib/ipmi_sensor.c` from the compile and links this module instead.
//!
//! Five symbols have external linkage and all five keep their C names and
//! signatures:
//!
//! * `ipmi_sensor_main()` - `ipmitool_cmd_list[]` in `src/ipmitool.c`.
//! * `ipmi_sensor_print_fc()` - called from `lib/ipmi_sel.c` when it renders a
//!   SEL entry's sensor.
//! * `ipmi_sensor_get_sensor_reading_factors()` - called from `lib/ipmi_sdr.c`
//!   for records whose linearization byte is in 70h..7Fh.
//! * `print_sensor_get_usage()` and `print_sensor_thresh_usage()` - global, but
//!   forward declared only inside `lib/ipmi_sensor.c`.
//!
//! Things worth knowing before reading on:
//!
//! * **SDR records are read through byte offsets, not a struct mirror.**
//!   `struct sdr_record_common_sensor` and the full/compact records that embed
//!   it are all bitfields and `#pragma pack`, which `translate-c` turns into
//!   `opaque {}`.  Mirroring 60-odd bytes of masks this module never reads
//!   would be more code and more risk than naming the dozen offsets it does,
//!   so the offsets come from `abi_layout.h` - computed by the real C compiler
//!   for the real target - and the record is indexed as bytes.  This is the
//!   same approach `cmd/event.zig` takes.
//! * **`struct sensor_reading` is *not* packed**, so `translate-c` represents
//!   it faithfully and it is used directly.
//! * **All decoding stays in C.**  `sdr_convert_sensor_reading()`,
//!   `sdr_convert_sensor_tolerance()`, `sdr_convert_sensor_value_to_raw()`,
//!   `ipmi_sdr_read_sensor_value()` and the SDR iterator are still
//!   `lib/ipmi_sdr.c`'s; this module only drives them.  So is every `printf`
//!   format: the threshold printer takes its format string as a parameter and
//!   passes it to libc unchanged, exactly as the C does.
//! * **Upstream defects are reproduced deliberately.**  See issue #41:
//!   - `ipmi_sensor_get_sensor_reading_factors()` copies six bytes out of the
//!     response without checking `rsp->data_len`, so a short Get Sensor
//!     Reading Factors reply silently seeds the reading factors from whatever
//!     the transport buffer held before.
//!   - The single-threshold path of `ipmi_sensor_set_threshold()` calls
//!     `ipmi_sdr_get_sensor_reading_ipmb()` and immediately overwrites the
//!     result with `ipmi_sdr_get_sensor_thresholds()`.  The request still goes
//!     on the wire; the answer is discarded.
//!   - The same path indexes `rsp->data[1..6]` without checking
//!     `rsp->data_len`, so a short Get Sensor Thresholds reply validates the
//!     new setting against stale bytes.
//!   - The `upper` and `lower` bulk paths assign to `ret` three times, so only
//!     the third Set Sensor Thresholds result is returned.
//!
//! Everything this module needs from C - `printf`, `lprintf`, `val2str`,
//! `str2double`, the SDR helpers and the sensor-type table - is reached
//! through the `ipmi_c` bridge.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");

const Intf = intf_mod.Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const SensorReading = c.struct_sensor_reading;
const CommonSensor = c.struct_sdr_record_common_sensor;
const FullSensor = c.struct_sdr_record_full_sensor;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const netfn_se: u6 = @intCast(c.IPMI_NETFN_SE);

const cmd_get_sensor_factors: u8 = @intCast(c.GET_SENSOR_FACTORS);
const cmd_set_sensor_thresholds: u8 = @intCast(c.SET_SENSOR_THRESHOLDS);

const upper_non_recov_specified: u8 = @intCast(c.UPPER_NON_RECOV_SPECIFIED);
const upper_crit_specified: u8 = @intCast(c.UPPER_CRIT_SPECIFIED);
const upper_non_crit_specified: u8 = @intCast(c.UPPER_NON_CRIT_SPECIFIED);
const lower_non_recov_specified: u8 = @intCast(c.LOWER_NON_RECOV_SPECIFIED);
const lower_crit_specified: u8 = @intCast(c.LOWER_CRIT_SPECIFIED);
const lower_non_crit_specified: u8 = @intCast(c.LOWER_NON_CRIT_SPECIFIED);

const record_type_full: u8 = @intCast(c.SDR_RECORD_TYPE_FULL_SENSOR);
const record_type_compact: u8 = @intCast(c.SDR_RECORD_TYPE_COMPACT_SENSOR);

const invalid_threshold =
    "Invalid Threshold data values. Cannot Set Threshold Data.";

/// `threshold_vals[]`: the mask-to-name table `val2str()` is handed when the
/// module announces which threshold it is about to set.
const threshold_vals = [_]c.struct_valstr{
    .{ .val = upper_non_recov_specified, .str = "Upper Non-Recoverable" },
    .{ .val = upper_crit_specified, .str = "Upper Critical" },
    .{ .val = upper_non_crit_specified, .str = "Upper Non-Critical" },
    .{ .val = lower_non_recov_specified, .str = "Lower Non-Recoverable" },
    .{ .val = lower_crit_specified, .str = "Lower Critical" },
    .{ .val = lower_non_crit_specified, .str = "Lower Non-Critical" },
    .{ .val = 0x00, .str = null },
};

// ---------------------------------------------------------------------------
// SDR record layout
// ---------------------------------------------------------------------------

/// Byte offsets inside `struct sdr_record_common_sensor`, which is `opaque {}`
/// on the Zig side.  Every one comes from `abi_layout.h`, so they follow the
/// C compiler's idea of the layout for the target actually being built.
const common = struct {
    const owner_id = c.ABI_OFFSETOF_sdr_common__keys__owner_id;
    /// The byte holding `keys.lun:2`, `keys.__reserved:2` and `keys.channel:4`.
    const keys_flags = c.ABI_OFFSETOF_sdr_common__keys__flags;
    const sensor_num = c.ABI_OFFSETOF_sdr_common__keys__sensor_num;
    const entity_id = c.ABI_OFFSETOF_sdr_common__entity__id;
    /// The byte holding `entity.instance:7` and `entity.logical:1`.
    const entity_instance = c.ABI_OFFSETOF_sdr_common__entity__instance;
    const sensor_type = c.ABI_OFFSETOF_sdr_common__sensor__type;
    const event_type = c.ABI_OFFSETOF_sdr_common__event_type;
    /// Units 1: the byte holding `unit.pct:1`, `unit.modifier:2`,
    /// `unit.rate:3` and `unit.analog:2`.
    const unit = c.ABI_OFFSETOF_sdr_common__unit;
};

/// Byte offsets inside `struct sdr_record_full_sensor`.  `cmn` is at offset 0,
/// so a full record doubles as a common record without adjustment - which is
/// exactly what the C casts rely on.
const full_sensor = struct {
    const mtol = c.ABI_OFFSETOF_sdr_full__mtol;
    const mtol_size = c.ABI_SIZEOF_sdr_full__mtol;
    const bacc = c.ABI_OFFSETOF_sdr_full__bacc;
    const bacc_size = c.ABI_SIZEOF_sdr_full__bacc;
    const hysteresis_positive = c.ABI_OFFSETOF_sdr_full__hysteresis__positive;
    const hysteresis_negative = c.ABI_OFFSETOF_sdr_full__hysteresis__negative;
    const id_string = c.ABI_OFFSETOF_sdr_full__id_string;
};

/// Byte offsets inside `struct sdr_record_compact_sensor`.
const compact_sensor = struct {
    const hysteresis_positive = c.ABI_OFFSETOF_sdr_compact__hysteresis__positive;
    const hysteresis_negative = c.ABI_OFFSETOF_sdr_compact__hysteresis__negative;
};

/// `struct sdr_get_rs`, the five byte SDR record header the iterator returns.
/// Mirrored rather than taken from `translate-c` because the C type is inside
/// a `#pragma pack` region; only `type` is ever read.
const SdrGetRs = extern struct {
    next: u16 align(1),
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
};

/// `struct sensor_set_thresh_rq`: the Set Sensor Thresholds request body.  The
/// order of the six threshold bytes is the wire order, so it is what decides
/// which byte of the request a setting lands in.
const SensorSetThreshRq = extern struct {
    sensor_num: u8 = 0,
    set_mask: u8 = 0,
    lower_non_crit: u8 = 0,
    lower_crit: u8 = 0,
    lower_non_recov: u8 = 0,
    upper_non_crit: u8 = 0,
    upper_crit: u8 = 0,
    upper_non_recov: u8 = 0,
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

/// One `intf->sendrecv()` round trip.
fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

/// The bytes of a common/full/compact sensor record.  All three share a prefix,
/// and the C freely casts between them.
fn recordBytes(sensor: anytype) [*]u8 {
    return @ptrCast(sensor);
}

/// `IS_THRESHOLD_SENSOR()`.
fn isThresholdSensor(sensor: *CommonSensor) bool {
    return recordBytes(sensor)[common.event_type] == 1;
}

/// `UNITS_ARE_DISCRETE()`: Units 1 analog data format 3 means the sensor does
/// not return a numeric reading.
fn unitsAreDiscrete(sensor: *CommonSensor) bool {
    return (recordBytes(sensor)[common.unit] >> 6) & 0x03 == 3;
}

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

/// The `verbose` global lives in `src/ipmitool.c`.
fn verbose() c_int {
    return c.verbose;
}

fn csvOutput() bool {
    return c.csv_output != 0;
}

// ---------------------------------------------------------------------------
// Reading factors
// ---------------------------------------------------------------------------

/// `ipmi_sensor_get_sensor_reading_factors()`: refresh a non-linear sensor's
/// M/B/exponent factors for the raw value about to be converted.
///
/// The response layout is byte-for-byte the SDR's own, so the C copies it in
/// with two `memcpy()`s and this port does the same.  Neither checks
/// `rsp->data_len` first - see issue #41.
fn getSensorReadingFactors(
    intf: ?*Intf,
    sensor: ?*FullSensor,
    reading: u8,
) callconv(.c) c_int {
    var req = std.mem.zeroes(Request);
    var req_data: [2]u8 = undefined;

    var id: [17]u8 = @splat(0);

    const in = intf orelse return -1;
    const rec = recordBytes(sensor orelse return -1);

    @memcpy(id[0..16], rec[full_sensor.id_string..][0..16]);

    req_data[0] = rec[common.sensor_num];
    req_data[1] = reading;

    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(rec[common.keys_flags] & 0x3);
    req.msg.cmd = cmd_get_sensor_factors;
    req.msg.data = &req_data;
    req.msg.data_len = req_data.len;

    const rsp = sendrecv(in, &req) orelse {
        c.lprintf(
            log.Level.err,
            "Error updating reading factor for sensor %s (#%02x)",
            &id,
            @as(c_int, rec[common.sensor_num]),
        );
        return -1;
    };
    if (rsp.ccode != 0) return -1;

    // Note: rsp->data[0] points at the next valid entry in the sampling table.
    @memcpy(rec[full_sensor.mtol..][0..mtol_size], rsp.data[1..][0..mtol_size]);
    @memcpy(rec[full_sensor.bacc..][0..bacc_size], rsp.data[3..][0..bacc_size]);
    return 0;
}

const mtol_size: usize = full_sensor.mtol_size;
const bacc_size: usize = full_sensor.bacc_size;

/// `__TO_TOL()`: the tolerance is the low six bits of the *high* byte of the
/// packed M/tolerance word, which the macro reaches by byte-swapping the word.
fn toTol(rec: [*]const u8) u16 {
    const mtol = std.mem.readInt(u16, rec[full_sensor.mtol..][0..2], .little);
    const host = if (@import("builtin").cpu.arch.endian() == .little) mtol else @byteSwap(mtol);
    return @byteSwap(host) & 0x3f;
}

// ---------------------------------------------------------------------------
// Set Sensor Thresholds
// ---------------------------------------------------------------------------

/// `ipmi_sensor_set_sensor_thresholds()`: one Set Sensor Thresholds request
/// carrying exactly one threshold.
fn setSensorThresholds(
    intf: *Intf,
    sensor: u8,
    threshold: u8,
    setting: u8,
    target: u8,
    lun: u8,
    channel: u8,
) ?*Response {
    var req = std.mem.zeroes(Request);
    var set_thresh_rq: SensorSetThreshRq = .{};

    set_thresh_rq.sensor_num = sensor;
    set_thresh_rq.set_mask = threshold;
    if (threshold == upper_non_recov_specified) {
        set_thresh_rq.upper_non_recov = setting;
    } else if (threshold == upper_crit_specified) {
        set_thresh_rq.upper_crit = setting;
    } else if (threshold == upper_non_crit_specified) {
        set_thresh_rq.upper_non_crit = setting;
    } else if (threshold == lower_non_crit_specified) {
        set_thresh_rq.lower_non_crit = setting;
    } else if (threshold == lower_crit_specified) {
        set_thresh_rq.lower_crit = setting;
    } else if (threshold == lower_non_recov_specified) {
        set_thresh_rq.lower_non_recov = setting;
    } else {
        return null;
    }

    var bridged_request = false;
    var save_addr: u32 = 0;
    var save_channel: u32 = 0;
    if (bridgeToSensor(intf, target, channel)) {
        bridged_request = true;
        save_addr = intf.target_addr;
        intf.target_addr = target;
        save_channel = intf.target_channel;
        intf.target_channel = channel;
    }

    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = cmd_set_sensor_thresholds;
    req.msg.data = @ptrCast(&set_thresh_rq);
    req.msg.data_len = @sizeOf(SensorSetThreshRq);

    const rsp = sendrecv(intf, &req);
    if (bridged_request) {
        intf.target_addr = save_addr;
        intf.target_channel = @truncate(save_channel);
    }
    return rsp;
}

/// `BRIDGE_TO_SENSOR()`.
fn bridgeToSensor(intf: *Intf, addr: u8, chan: u8) bool {
    return intf.target_addr != addr and
        (intf.target_channel != chan or chan != 0);
}

/// `__ipmi_sensor_set_threshold()`.
fn setThresholdOne(
    intf: *Intf,
    num: u8,
    mask: u8,
    setting: u8,
    target: u8,
    lun: u8,
    channel: u8,
) c_int {
    const rsp = setSensorThresholds(intf, num, mask, setting, target, lun, channel) orelse {
        c.lprintf(log.Level.err, "Error setting threshold");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error setting threshold: %s", ccString(rsp.ccode));
        return -1;
    }
    return 0;
}

/// `__ipmi_sensor_threshold_value_to_raw()`: sensors that return an analog
/// reading go through mx+b; the rest clamp the requested value into a byte.
fn thresholdValueToRaw(full: *FullSensor, value: f64) u8 {
    if (!unitsAreDiscrete(@ptrCast(full))) {
        return c.sdr_convert_sensor_value_to_raw(full, value);
    }
    if (value > 255) return 255;
    if (value < 0) return 0;
    return @intFromFloat(value);
}

// ---------------------------------------------------------------------------
// Discrete sensors
// ---------------------------------------------------------------------------

/// `ipmi_sensor_print_fc_discrete()`.
fn printFcDiscrete(
    intf: *Intf,
    sensor: *CommonSensor,
    sdr_record_type: u8,
) c_int {
    const sr: *SensorReading = c.ipmi_sdr_read_sensor_value(
        cIntf(intf),
        @ptrCast(sensor),
        sdr_record_type,
        3,
    ) orelse return -1;

    const rec = recordBytes(sensor);

    if (csvOutput()) {
        _ = c.printf("%s", &sr.s_id);
        if (sr.s_reading_valid != 0) {
            if (sr.s_has_analog_value != 0) {
                // don't show discrete component
                _ = c.printf(",%s,%s,%s", &sr.s_a_str, sr.s_a_units, "ok");
            } else {
                _ = c.printf(
                    ",0x%x,%s,0x%02x%02x",
                    @as(c_int, sr.s_reading),
                    "discrete",
                    @as(c_int, sr.s_data2),
                    @as(c_int, sr.s_data3),
                );
            }
        } else {
            _ = c.printf(",%s,%s,%s", "na", "discrete", "na");
        }
        _ = c.printf(",%s,%s,%s,%s,%s,%s", "na", "na", "na", "na", "na", "na");
        _ = c.printf("\n");
    } else if (verbose() == 0) {
        // output format
        //   id value units status thresholds....
        _ = c.printf("%-16s ", &sr.s_id);
        if (sr.s_reading_valid != 0) {
            if (sr.s_has_analog_value != 0) {
                // don't show discrete component
                _ = c.printf("| %-10s | %-10s | %-6s", &sr.s_a_str, sr.s_a_units, "ok");
            } else {
                _ = c.printf(
                    "| 0x%-8x | %-10s | 0x%02x%02x",
                    @as(c_int, sr.s_reading),
                    "discrete",
                    @as(c_int, sr.s_data2),
                    @as(c_int, sr.s_data3),
                );
            }
        } else {
            _ = c.printf("| %-10s | %-10s | %-6s", "na", "discrete", "na");
        }
        _ = c.printf(
            "| %-10s| %-10s| %-10s| %-10s| %-10s| %-10s",
            "na",
            "na",
            "na",
            "na",
            "na",
            "na",
        );
        _ = c.printf("\n");
    } else {
        _ = c.printf(
            "Sensor ID              : %s (0x%x)\n",
            &sr.s_id,
            @as(c_int, rec[common.sensor_num]),
        );
        _ = c.printf(
            " Entity ID             : %d.%d\n",
            @as(c_int, rec[common.entity_id]),
            @as(c_int, rec[common.entity_instance] & 0x7f),
        );
        _ = c.printf(
            " Sensor Type (Discrete): %s\n",
            c.ipmi_get_sensor_type(cIntf(intf), rec[common.sensor_type]),
        );
        if (sr.s_reading_valid != 0) {
            if (sr.s_has_analog_value != 0) {
                _ = c.printf(" Sensor Reading        : %s %s\n", &sr.s_a_str, sr.s_a_units);
            }
            c.ipmi_sdr_print_discrete_state(
                cIntf(intf),
                "States Asserted",
                rec[common.sensor_type],
                rec[common.event_type],
                sr.s_data2,
                sr.s_data3,
            );
            _ = c.printf("\n");
        } else {
            _ = c.printf(" Unable to read sensor: Device Not Present\n\n");
        }
    }

    return if (sr.s_reading_valid != 0) 0 else -1;
}

// ---------------------------------------------------------------------------
// Threshold sensors
// ---------------------------------------------------------------------------

/// `print_thresh_setting()`.
///
/// The three format strings are chosen by the caller and handed straight to
/// libc, so the plain, csv and verbose layouts share one implementation - and
/// so the port has to pass them through unchanged too.
fn printThreshSetting(
    full: ?*FullSensor,
    thresh_is_avail: u8,
    setting: u8,
    field_sep: [*:0]const u8,
    analog_fmt: [*:0]const u8,
    discrete_fmt: [*:0]const u8,
    na_fmt: [*:0]const u8,
) void {
    _ = c.printf("%s", field_sep);
    if (thresh_is_avail == 0) {
        _ = c.printf(na_fmt, "na");
        return;
    }
    if (full != null and !unitsAreDiscrete(@ptrCast(full.?))) {
        _ = c.printf(analog_fmt, c.sdr_convert_sensor_reading(full, setting));
    } else {
        _ = c.printf(discrete_fmt, @as(c_int, setting));
    }
}

/// The six `PTS()` invocations, in the order the C emits them: lower
/// non-recoverable, lower critical, lower non-critical, then the three upper
/// ones.  `dataidx` is the index into the Get Sensor Thresholds response.
const pts_order = [6]struct { bit: u8, dataidx: u8 }{
    .{ .bit = lower_non_recov_specified, .dataidx = 3 },
    .{ .bit = lower_crit_specified, .dataidx = 2 },
    .{ .bit = lower_non_crit_specified, .dataidx = 1 },
    .{ .bit = upper_non_crit_specified, .dataidx = 4 },
    .{ .bit = upper_crit_specified, .dataidx = 5 },
    .{ .bit = upper_non_recov_specified, .dataidx = 6 },
};

/// The six labels the verbose layout uses as its field separator.
const pts_labels = [6][*:0]const u8{
    " Lower Non-Recoverable : ",
    " Lower Critical        : ",
    " Lower Non-Critical    : ",
    " Upper Non-Critical    : ",
    " Upper Critical        : ",
    " Upper Non-Recoverable : ",
};

/// `dump_sensor_fc_thredshold_csv()`.
fn dumpThresholdCsv(
    thresh_available: c_int,
    thresh_status: [*c]const u8,
    rsp: ?*Response,
    sr: *SensorReading,
) void {
    _ = c.printf("%s", &sr.s_id);
    if (sr.s_reading_valid != 0) {
        if (sr.s_has_analog_value != 0) {
            _ = c.printf(",%.3f,%s,%s", sr.s_a_val, sr.s_a_units, thresh_status);
        } else {
            _ = c.printf(
                ",0x%x,%s,%s",
                @as(c_int, sr.s_reading),
                sr.s_a_units,
                thresh_status,
            );
        }
    } else {
        _ = c.printf(",%s,%s,%s", "na", sr.s_a_units, "na");
    }
    if (thresh_available != 0 and sr.full != null) {
        for (pts_order) |pts| {
            printThreshSetting(
                sr.full,
                rsp.?.data[0] & pts.bit,
                rsp.?.data[pts.dataidx],
                ",",
                "%.3f",
                "0x%x",
                "%s",
            );
        }
    } else {
        _ = c.printf(",%s,%s,%s,%s,%s,%s", "na", "na", "na", "na", "na", "na");
    }
    _ = c.printf("\n");
}

/// `dump_sensor_fc_thredshold()`: id value units status thresholds....
fn dumpThreshold(
    thresh_available: c_int,
    thresh_status: [*c]const u8,
    rsp: ?*Response,
    sr: *SensorReading,
) void {
    _ = c.printf("%-16s ", &sr.s_id);
    if (sr.s_reading_valid != 0) {
        if (sr.s_has_analog_value != 0) {
            _ = c.printf("| %-10.3f | %-10s | %-6s", sr.s_a_val, sr.s_a_units, thresh_status);
        } else {
            _ = c.printf(
                "| 0x%-8x | %-10s | %-6s",
                @as(c_int, sr.s_reading),
                sr.s_a_units,
                thresh_status,
            );
        }
    } else {
        _ = c.printf("| %-10s | %-10s | %-6s", "na", sr.s_a_units, "na");
    }
    if (thresh_available != 0 and sr.full != null) {
        for (pts_order) |pts| {
            printThreshSetting(
                sr.full,
                rsp.?.data[0] & pts.bit,
                rsp.?.data[pts.dataidx],
                "| ",
                "%-10.3f",
                "0x%-8x",
                "%-10s",
            );
        }
    } else {
        _ = c.printf(
            "| %-10s| %-10s| %-10s| %-10s| %-10s| %-10s",
            "na",
            "na",
            "na",
            "na",
            "na",
            "na",
        );
    }
    _ = c.printf("\n");
}

/// `dump_sensor_fc_thredshold_verbose()`.
fn dumpThresholdVerbose(
    thresh_available: c_int,
    thresh_status: [*c]const u8,
    intf: *Intf,
    sensor: *CommonSensor,
    rsp: ?*Response,
    sr: *SensorReading,
) void {
    const rec = recordBytes(sensor);

    _ = c.printf(
        "Sensor ID              : %s (0x%x)\n",
        &sr.s_id,
        @as(c_int, rec[common.sensor_num]),
    );
    _ = c.printf(
        " Entity ID             : %d.%d\n",
        @as(c_int, rec[common.entity_id]),
        @as(c_int, rec[common.entity_instance] & 0x7f),
    );
    _ = c.printf(
        " Sensor Type (Threshold)  : %s\n",
        c.ipmi_get_sensor_type(cIntf(intf), rec[common.sensor_type]),
    );

    _ = c.printf(" Sensor Reading        : ");
    if (sr.s_reading_valid != 0) {
        if (sr.full) |full| {
            const raw_tol = toTol(recordBytes(full));
            if (sr.s_has_analog_value != 0) {
                const tol = c.sdr_convert_sensor_tolerance(full, @truncate(raw_tol));
                _ = c.printf(
                    "%.*f (+/- %.*f) %s\n",
                    @as(c_int, if (sr.s_a_val == @trunc(sr.s_a_val)) 0 else 3),
                    sr.s_a_val,
                    @as(c_int, if (tol == @trunc(tol)) 0 else 3),
                    tol,
                    sr.s_a_units,
                );
            } else {
                _ = c.printf(
                    "0x%x (+/- 0x%x) %s\n",
                    @as(c_int, sr.s_reading),
                    @as(c_int, raw_tol),
                    sr.s_a_units,
                );
            }
        } else {
            _ = c.printf("0x%x %s\n", @as(c_int, sr.s_reading), sr.s_a_units);
        }
        _ = c.printf(" Status                : %s\n", thresh_status);

        if (thresh_available != 0) {
            if (sr.full != null) {
                for (pts_order, pts_labels) |pts, label| {
                    printThreshSetting(
                        sr.full,
                        rsp.?.data[0] & pts.bit,
                        rsp.?.data[pts.dataidx],
                        label,
                        "%.3f\n",
                        "0x%x\n",
                        "%s\n",
                    );
                }
            }
            const positive = if (sr.full) |f|
                recordBytes(f)[full_sensor.hysteresis_positive]
            else
                recordBytes(sr.compact.?)[compact_sensor.hysteresis_positive];
            c.ipmi_sdr_print_sensor_hysteresis(
                @ptrCast(sensor),
                sr.full,
                positive,
                "Positive Hysteresis",
            );

            const negative = if (sr.full) |f|
                recordBytes(f)[full_sensor.hysteresis_negative]
            else
                recordBytes(sr.compact.?)[compact_sensor.hysteresis_negative];
            c.ipmi_sdr_print_sensor_hysteresis(
                @ptrCast(sensor),
                sr.full,
                negative,
                "Negative Hysteresis",
            );
        } else {
            _ = c.printf(" Sensor Threshold Settings not available\n");
        }
    } else {
        _ = c.printf(" Unable to read sensor: Device Not Present\n\n");
    }

    _ = c.ipmi_sdr_print_sensor_event_status(
        cIntf(intf),
        rec[common.sensor_num],
        rec[common.sensor_type],
        rec[common.event_type],
        c.ANALOG_SENSOR,
        rec[common.owner_id],
        rec[common.keys_flags] & 0x3,
        (rec[common.keys_flags] >> 4) & 0xf,
    );
    _ = c.ipmi_sdr_print_sensor_event_enable(
        cIntf(intf),
        rec[common.sensor_num],
        rec[common.sensor_type],
        rec[common.event_type],
        c.ANALOG_SENSOR,
        rec[common.owner_id],
        rec[common.keys_flags] & 0x3,
        (rec[common.keys_flags] >> 4) & 0xf,
    );

    _ = c.printf("\n");
}

/// `ipmi_sensor_print_fc_threshold()`.
fn printFcThreshold(
    intf: *Intf,
    sensor: *CommonSensor,
    sdr_record_type: u8,
) c_int {
    const sr: *SensorReading = c.ipmi_sdr_read_sensor_value(
        cIntf(intf),
        @ptrCast(sensor),
        sdr_record_type,
        3,
    ) orelse return -1;

    const thresh_status = c.ipmi_sdr_get_thresh_status(sr, "ns");

    const rec = recordBytes(sensor);
    const rsp: ?*Response = @ptrCast(c.ipmi_sdr_get_sensor_thresholds(
        cIntf(intf),
        rec[common.sensor_num],
        rec[common.owner_id],
        rec[common.keys_flags] & 0x3,
        (rec[common.keys_flags] >> 4) & 0xf,
    ));

    var thresh_available: c_int = 1;
    if (rsp == null or rsp.?.ccode != 0 or rsp.?.data_len == 0) thresh_available = 0;

    if (csvOutput()) {
        dumpThresholdCsv(thresh_available, thresh_status, rsp, sr);
    } else if (verbose() == 0) {
        dumpThreshold(thresh_available, thresh_status, rsp, sr);
    } else {
        dumpThresholdVerbose(thresh_available, thresh_status, intf, sensor, rsp, sr);
    }

    return if (sr.s_reading_valid != 0) 0 else -1;
}

/// `ipmi_sensor_print_fc()`: the entry point `lib/ipmi_sel.c` calls.
fn printFc(
    intf: ?*Intf,
    sensor: ?*CommonSensor,
    sdr_record_type: u8,
) callconv(.c) c_int {
    const s = sensor.?;
    if (isThresholdSensor(s)) {
        return printFcThreshold(intf.?, s, sdr_record_type);
    }
    return printFcDiscrete(intf.?, s, sdr_record_type);
}

// ---------------------------------------------------------------------------
// Subcommands
// ---------------------------------------------------------------------------

/// `ipmi_sensor_list()`: walk the SDR repository and print every full or
/// compact sensor record.
fn sensorList(intf: *Intf) c_int {
    const rc: c_int = 0;

    c.lprintf(log.Level.debug, "Querying SDR for sensor list");

    const itr = c.ipmi_sdr_start(cIntf(intf), 0) orelse {
        c.lprintf(log.Level.err, "Unable to open SDR for reading");
        return -1;
    };

    while (c.ipmi_sdr_get_next_header(cIntf(intf), itr)) |raw_header| {
        const header: *const SdrGetRs = @ptrCast(raw_header);
        const rec = c.ipmi_sdr_get_record(cIntf(intf), raw_header, itr) orelse {
            c.lprintf(log.Level.debug, "rec == NULL");
            continue;
        };

        switch (header.type) {
            record_type_full, record_type_compact => {
                _ = printFc(intf, @ptrCast(rec), header.type);
            },
            else => {},
        }
        c.free(rec);

        // fix for CR6604909:
        // mask failure of individual reads in sensor list command
        // rc = (r == 0) ? rc : r;
    }

    c.ipmi_sdr_end(itr);
    return rc;
}

/// `ipmi_sensor_set_threshold()`: the `sensor thresh` subcommand.
fn setThreshold(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    var setting_mask: u8 = 0;
    var setting1: f64 = 0.0;
    var setting2: f64 = 0.0;
    var setting3: f64 = 0.0;
    var all_upper = false;
    var all_lower = false;
    var ret: c_int = 0;
    var val: [10]f64 = @splat(0);

    if (argc < 3 or eql(@ptrCast(argv[0]), "help")) {
        printThreshUsage();
        return 0;
    }

    const id = argv[0];
    const thresh: [*:0]const u8 = @ptrCast(argv[1]);

    if (eql(thresh, "upper")) {
        if (argc < 5) {
            c.lprintf(
                log.Level.err,
                "usage: sensor thresh <id> upper <unc> <ucr> <unr>",
            );
            return -1;
        }
        all_upper = true;
        if (c.str2double(argv[2], &setting1) != 0) {
            c.lprintf(log.Level.err, "Given unc '%s' is invalid.", argv[2]);
            return -1;
        }
        if (c.str2double(argv[3], &setting2) != 0) {
            c.lprintf(log.Level.err, "Given ucr '%s' is invalid.", argv[3]);
            return -1;
        }
        if (c.str2double(argv[4], &setting3) != 0) {
            c.lprintf(log.Level.err, "Given unr '%s' is invalid.", argv[4]);
            return -1;
        }
    } else if (eql(thresh, "lower")) {
        if (argc < 5) {
            c.lprintf(
                log.Level.err,
                "usage: sensor thresh <id> lower <lnr> <lcr> <lnc>",
            );
            return -1;
        }
        all_lower = true;
        if (c.str2double(argv[2], &setting1) != 0) {
            c.lprintf(log.Level.err, "Given lnc '%s' is invalid.", argv[2]);
            return -1;
        }
        if (c.str2double(argv[3], &setting2) != 0) {
            c.lprintf(log.Level.err, "Given lcr '%s' is invalid.", argv[3]);
            return -1;
        }
        if (c.str2double(argv[4], &setting3) != 0) {
            c.lprintf(log.Level.err, "Given lnr '%s' is invalid.", argv[4]);
            return -1;
        }
    } else {
        if (eql(thresh, "unr")) {
            setting_mask = upper_non_recov_specified;
        } else if (eql(thresh, "ucr")) {
            setting_mask = upper_crit_specified;
        } else if (eql(thresh, "unc")) {
            setting_mask = upper_non_crit_specified;
        } else if (eql(thresh, "lnc")) {
            setting_mask = lower_non_crit_specified;
        } else if (eql(thresh, "lcr")) {
            setting_mask = lower_crit_specified;
        } else if (eql(thresh, "lnr")) {
            setting_mask = lower_non_recov_specified;
        } else {
            c.lprintf(
                log.Level.err,
                "Valid threshold '%s' for sensor '%s' not specified!",
                thresh,
                id,
            );
            return -1;
        }
        if (c.str2double(argv[2], &setting1) != 0) {
            c.lprintf(
                log.Level.err,
                "Given %s threshold value '%s' is invalid.",
                thresh,
                argv[2],
            );
            return -1;
        }
    }

    _ = c.printf("Locating sensor record '%s'...\n", id);

    // lookup by sensor name
    const sdr: *const SdrRecordList = @ptrCast(c.ipmi_sdr_find_sdr_byid(cIntf(intf), id) orelse {
        c.lprintf(log.Level.err, "Sensor data record not found!");
        return -1;
    });

    if (sdr.type != record_type_full) {
        c.lprintf(log.Level.err, "Invalid sensor type %02x", @as(c_int, sdr.type));
        return -1;
    }

    const record = sdr.record.?;
    const sensor: *CommonSensor = @ptrCast(@constCast(record));
    const full: *FullSensor = @ptrCast(@constCast(record));

    if (!isThresholdSensor(sensor)) {
        c.lprintf(
            log.Level.err,
            "Invalid sensor event type %02x",
            @as(c_int, record[common.event_type]),
        );
        return -1;
    }

    const num = record[common.sensor_num];
    const owner = record[common.owner_id];
    const lun = record[common.keys_flags] & 0x3;
    const channel = (record[common.keys_flags] >> 4) & 0xf;
    const id_string = record + full_sensor.id_string;

    if (all_upper) {
        // The C assigns to `ret` three times, so only the third result is
        // returned; see issue #41.
        for ([3]u8{
            upper_non_crit_specified,
            upper_crit_specified,
            upper_non_recov_specified,
        }, [3]f64{ setting1, setting2, setting3 }) |mask, setting| {
            _ = c.printf(
                "Setting sensor \"%s\" %s threshold to %.3f\n",
                id_string,
                c.val2str(mask, &threshold_vals),
                setting,
            );
            ret = setThresholdOne(
                intf,
                num,
                mask,
                thresholdValueToRaw(full, setting),
                owner,
                lun,
                channel,
            );
        }
    } else if (all_lower) {
        for ([3]u8{
            lower_non_recov_specified,
            lower_crit_specified,
            lower_non_crit_specified,
        }, [3]f64{ setting1, setting2, setting3 }) |mask, setting| {
            _ = c.printf(
                "Setting sensor \"%s\" %s threshold to %.3f\n",
                id_string,
                c.val2str(mask, &threshold_vals),
                setting,
            );
            ret = setThresholdOne(
                intf,
                num,
                mask,
                thresholdValueToRaw(full, setting),
                owner,
                lun,
                channel,
            );
        }
    } else {
        // The current implementation reads back every threshold and validates
        // the requested value against its neighbours.
        //
        // The result of this first request is discarded immediately - the C
        // overwrites `rsp` on the very next line.  The request still goes on
        // the wire; see issue #41.
        _ = c.ipmi_sdr_get_sensor_reading_ipmb(cIntf(intf), num, owner, lun, channel);
        const rsp: ?*Response = @ptrCast(c.ipmi_sdr_get_sensor_thresholds(
            cIntf(intf),
            num,
            owner,
            lun,
            channel,
        ));
        if (rsp == null or rsp.?.ccode != 0) {
            c.lprintf(log.Level.err, "Sensor data record not found!");
            return -1;
        }
        const data = &rsp.?.data;
        // No `data_len' check: a short response is validated against whatever
        // the transport buffer held before.  See issue #41.
        for (1..7) |i| {
            val[i] = c.sdr_convert_sensor_reading(full, data[i]);
            if (val[i] < 0) val[i] = 0;
        }

        if (setting_mask & upper_non_recov_specified != 0) {
            if ((data[0] & upper_non_recov_specified) != 0 and
                (((data[0] & upper_crit_specified) != 0 and setting1 <= val[5]) or
                    ((data[0] & upper_non_crit_specified) != 0 and setting1 <= val[4])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else if (setting_mask & upper_crit_specified != 0) {
            if ((data[0] & upper_crit_specified) != 0 and
                (((data[0] & upper_non_recov_specified) != 0 and setting1 >= val[6]) or
                    ((data[0] & upper_non_crit_specified) != 0 and setting1 <= val[4])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else if (setting_mask & upper_non_crit_specified != 0) {
            if ((data[0] & upper_non_crit_specified) != 0 and
                (((data[0] & upper_non_recov_specified) != 0 and setting1 >= val[6]) or
                    ((data[0] & upper_crit_specified) != 0 and setting1 >= val[5]) or
                    ((data[0] & lower_non_crit_specified) != 0 and setting1 <= val[1])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else if (setting_mask & lower_non_crit_specified != 0) {
            if ((data[0] & lower_non_crit_specified) != 0 and
                (((data[0] & lower_crit_specified) != 0 and setting1 <= val[2]) or
                    ((data[0] & lower_non_recov_specified) != 0 and setting1 <= val[3]) or
                    ((data[0] & upper_non_crit_specified) != 0 and setting1 >= val[4])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else if (setting_mask & lower_crit_specified != 0) {
            if ((data[0] & lower_crit_specified) != 0 and
                (((data[0] & lower_non_crit_specified) != 0 and setting1 >= val[1]) or
                    ((data[0] & lower_non_recov_specified) != 0 and setting1 <= val[3])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else if (setting_mask & lower_non_recov_specified != 0) {
            if ((data[0] & lower_non_recov_specified) != 0 and
                (((data[0] & lower_non_crit_specified) != 0 and setting1 >= val[1]) or
                    ((data[0] & lower_crit_specified) != 0 and setting1 >= val[2])))
            {
                c.lprintf(log.Level.err, invalid_threshold);
                return -1;
            }
        } else {
            // Unreachable: every path above either set `setting_mask' to one of
            // the six bits or returned.  Kept because the C keeps it.
            c.lprintf(log.Level.err, invalid_threshold);
            return -1;
        }

        _ = c.printf(
            "Setting sensor \"%s\" %s threshold to %.3f\n",
            id_string,
            c.val2str(setting_mask, &threshold_vals),
            setting1,
        );

        ret = setThresholdOne(
            intf,
            num,
            setting_mask,
            thresholdValueToRaw(full, setting1),
            owner,
            lun,
            channel,
        );
    }

    return ret;
}

/// `ipmi_sensor_get_reading()`: the `sensor reading` subcommand.
fn getReading(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    var rc: c_int = 0;

    if (argc < 1 or eql(@ptrCast(argv[0]), "help")) {
        c.lprintf(log.Level.notice, "sensor reading <id> ... [id]");
        c.lprintf(log.Level.notice, "   id        : name of desired sensor");
        return -1;
    }

    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const sdr: *const SdrRecordList = @ptrCast(
            c.ipmi_sdr_find_sdr_byid(cIntf(intf), argv[i]) orelse {
                c.lprintf(log.Level.err, "Sensor \"%s\" not found!", argv[i]);
                rc = -1;
                continue;
            },
        );

        switch (sdr.type) {
            record_type_full, record_type_compact => {
                const sensor = sdr.record.?;
                const sr: *SensorReading = c.ipmi_sdr_read_sensor_value(
                    cIntf(intf),
                    @ptrCast(@constCast(sensor)),
                    sdr.type,
                    3,
                ) orelse {
                    rc = -1;
                    continue;
                };

                if (sr.full == null) continue;
                if (sr.s_reading_valid == 0) continue;
                if (sr.s_has_analog_value == 0) {
                    c.lprintf(
                        log.Level.err,
                        "Sensor \"%s\" is a discrete sensor!",
                        argv[i],
                    );
                    continue;
                }
                if (csvOutput()) {
                    _ = c.printf("%s,%s\n", argv[i], &sr.s_a_str);
                } else {
                    _ = c.printf("%-16s | %s\n", argv[i], &sr.s_a_str);
                }
            },
            else => continue,
        }
    }

    return rc;
}

/// `ipmi_sensor_get()`: the `sensor get` subcommand.
fn sensorGet(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    var rc: c_int = 0;

    if (argc < 1) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        printGetUsage();
        return -1;
    } else if (eql(@ptrCast(argv[0]), "help")) {
        printGetUsage();
        return 0;
    }
    _ = c.printf("Locating sensor record...\n");

    // lookup by sensor name
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const sdr: *const SdrRecordList = @ptrCast(
            c.ipmi_sdr_find_sdr_byid(cIntf(intf), argv[i]) orelse {
                c.lprintf(
                    log.Level.err,
                    "Sensor data record \"%s\" not found!",
                    argv[i],
                );
                rc = -1;
                continue;
            },
        );
        // need to set verbose level to 1
        const v = c.verbose;
        c.verbose = 1;
        switch (sdr.type) {
            record_type_full, record_type_compact => {
                if (printFc(intf, @ptrCast(@constCast(sdr.record.?)), sdr.type) != 0) {
                    rc = -1;
                }
            },
            else => {
                if (c.ipmi_sdr_print_listentry(cIntf(intf), @ptrCast(@alignCast(@constCast(sdr)))) < 0) {
                    rc = -1;
                }
            },
        }
        c.verbose = v;
    }
    return rc;
}

/// `struct sdr_record_list`, as returned by `ipmi_sdr_find_sdr_byid()`.
///
/// `translate-c` does produce a type for this one, but it silently drops the
/// `ATTRIBUTE_PACKING`, so its `record` sits at offset 24 instead of 21 and
/// every pointer read through it is garbage.  Hence the mirror, and hence the
/// `assertOpaqueLayout` at the bottom of the file.
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
// Usage
// ---------------------------------------------------------------------------

/// `print_sensor_get_usage()`.
fn printGetUsage() callconv(.c) void {
    c.lprintf(log.Level.notice, "sensor get <id> ... [id]");
    c.lprintf(log.Level.notice, "   id        : name of desired sensor");
}

/// `print_sensor_thresh_usage()`.
fn printThreshUsage() callconv(.c) void {
    c.lprintf(log.Level.notice, "sensor thresh <id> <threshold> <setting>");
    c.lprintf(
        log.Level.notice,
        "   id        : name of the sensor for which threshold is to be set",
    );
    c.lprintf(log.Level.notice, "   threshold : which threshold to set");
    c.lprintf(log.Level.notice, "                 unr = upper non-recoverable");
    c.lprintf(log.Level.notice, "                 ucr = upper critical");
    c.lprintf(log.Level.notice, "                 unc = upper non-critical");
    c.lprintf(log.Level.notice, "                 lnc = lower non-critical");
    c.lprintf(log.Level.notice, "                 lcr = lower critical");
    c.lprintf(log.Level.notice, "                 lnr = lower non-recoverable");
    c.lprintf(
        log.Level.notice,
        "   setting   : the value to set the threshold to",
    );
    c.lprintf(log.Level.notice, "");
    c.lprintf(
        log.Level.notice,
        "sensor thresh <id> lower <lnr> <lcr> <lnc>",
    );
    c.lprintf(
        log.Level.notice,
        "   Set all lower thresholds at the same time",
    );
    c.lprintf(log.Level.notice, "");
    c.lprintf(
        log.Level.notice,
        "sensor thresh <id> upper <unc> <ucr> <unr>",
    );
    c.lprintf(
        log.Level.notice,
        "   Set all upper thresholds at the same time",
    );
    c.lprintf(log.Level.notice, "");
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// `ipmi_sensor_main()`.
fn sensorMain(intf: ?*Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    var rc: c_int = 0;

    if (argc == 0) {
        rc = sensorList(intf.?);
    } else if (eql(@ptrCast(argv[0]), "help")) {
        c.lprintf(log.Level.notice, "Sensor Commands:  list thresh get reading");
    } else if (eql(@ptrCast(argv[0]), "list")) {
        rc = sensorList(intf.?);
    } else if (eql(@ptrCast(argv[0]), "thresh")) {
        rc = setThreshold(intf.?, argc - 1, argv + 1);
    } else if (eql(@ptrCast(argv[0]), "get")) {
        rc = sensorGet(intf.?, argc - 1, argv + 1);
    } else if (eql(@ptrCast(argv[0]), "reading")) {
        rc = getReading(intf.?, argc - 1, argv + 1);
    } else {
        c.lprintf(log.Level.err, "Invalid sensor command: %s", argv[0]);
        rc = -1;
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

pub fn exportSymbols() void {
    comptime {
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
        abi.assertOpaqueLayout(SdrGetRs, .{
            .size = c.ABI_SIZEOF_sdr_get_rs,
            .alignment = 1,
            .fields = &.{
                .{ .name = "next", .offset = c.ABI_OFFSETOF_sdr_get_rs__next },
                .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_get_rs__id },
                .{ .name = "version", .offset = c.ABI_OFFSETOF_sdr_get_rs__version },
                .{ .name = "type", .offset = c.ABI_OFFSETOF_sdr_get_rs__type },
                .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_get_rs__length },
            },
        });
        abi.assertOpaqueLayout(SensorSetThreshRq, .{
            .size = c.ABI_SIZEOF_sensor_set_thresh_rq,
            .alignment = 1,
            .fields = &.{
                .{
                    .name = "sensor_num",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__sensor_num,
                },
                .{
                    .name = "set_mask",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__set_mask,
                },
                .{
                    .name = "lower_non_crit",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__lower_non_crit,
                },
                .{
                    .name = "lower_crit",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__lower_crit,
                },
                .{
                    .name = "lower_non_recov",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__lower_non_recov,
                },
                .{
                    .name = "upper_non_crit",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__upper_non_crit,
                },
                .{
                    .name = "upper_crit",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__upper_crit,
                },
                .{
                    .name = "upper_non_recov",
                    .offset = c.ABI_OFFSETOF_sensor_set_thresh_rq__upper_non_recov,
                },
            },
        });

        abi.assertCallSignature(
            @TypeOf(getSensorReadingFactors),
            @TypeOf(c.ipmi_sensor_get_sensor_reading_factors),
        );
        @export(&getSensorReadingFactors, .{
            .name = "ipmi_sensor_get_sensor_reading_factors",
            .linkage = .strong,
        });

        abi.assertCallSignature(@TypeOf(printFc), @TypeOf(c.ipmi_sensor_print_fc));
        @export(&printFc, .{ .name = "ipmi_sensor_print_fc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sensorMain), @TypeOf(c.ipmi_sensor_main));
        @export(&sensorMain, .{ .name = "ipmi_sensor_main", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printGetUsage), @TypeOf(c.print_sensor_get_usage));
        @export(&printGetUsage, .{ .name = "print_sensor_get_usage", .linkage = .strong });

        abi.assertCallSignature(
            @TypeOf(printThreshUsage),
            @TypeOf(c.print_sensor_thresh_usage),
        );
        @export(&printThreshUsage, .{
            .name = "print_sensor_thresh_usage",
            .linkage = .strong,
        });
    }
}
