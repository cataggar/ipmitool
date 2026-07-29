//! Port of `lib/ipmi_sel.c`: the `sel` command - System Event Log info,
//! listing, saving, raw dump/restore, clear/delete, time get/set - plus the
//! event-description machinery (`ipmi_get_event_desc()`, `ipmi_get_oem()`,
//! `ipmi_get_sensor_type()`, the four OEM decoders) that `lib/ipmi_sdr.c`,
//! `lib/ipmi_event.c`, `lib/ipmi_pef.c` and every transport plugin link
//! against.
//!
//! Selected with `zig build -Dzig-modules=sel`, which drops `lib/ipmi_sel.c`
//! from the compile and links this module instead.
//!
//! Things worth knowing before reading on:
//!
//! * **Twenty symbols cross the ABI.**  Fourteen are declared in
//!   `include/ipmitool/ipmi_sel.h`; five functions (`get_dell_evt_desc`,
//!   `get_kontron_evt_desc`, `get_supermicro_evt_desc`,
//!   `ipmi_get_generic_sensor_type`, `ipmi_get_oem_sensor_type`) and one data
//!   object (`sel_oem_msg`) are global only because C forgot a `static`, and
//!   are declared for the bridge in `src/zig/ipmi_c.h`.  `sel_oem_msg` is kept
//!   exported because removing it would be a visible ABI change, not a port.
//!
//! * **The event tables come from the bridge.**  `generic_event_types[]`,
//!   `sensor_specific_event_types[]`, `vita_sensor_event_types[]` and
//!   `oem_kontron_event_types[]` are `static const` *inside* `ipmi_sel.h`, so
//!   every translation unit already owns a private copy; `translate-c` gives
//!   this module its own in exactly the same way.  `ipmi_get_first_...` and
//!   `ipmi_get_next_...` are both ported, so a C caller receives a pointer
//!   into the Zig copy and hands it straight back to the Zig `next` - the
//!   pair stays self-consistent.
//!
//! * **`struct sel_event_record` reaches Zig as `opaque {}`** because of the
//!   `event_type:7` / `event_dir:1` bitfield pair, so it gets a hand written
//!   mirror checked against `abi_layout.h`.  Same for `struct entity_id` and
//!   `struct sdr_record_list` (whose `ATTRIBUTE_PACKING` `translate-c` drops).
//!   The SDR records themselves are only read at byte offsets taken from
//!   `abi_layout.h`.
//!
//! * **Upstream defects are reproduced deliberately** - see issue #48:
//!   - `ipmi_sel_get_std_entry()` never checks `rsp->data_len`, so a BMC that
//!     returns a short Get SEL Entry response has the remaining fields read
//!     out of the stale tail of the response buffer.  `tests/transcripts/
//!     sel_truncated.tr` and the `sl_short_*` cases pin that behaviour.
//!   - `ipmi_sel_get_info()` stores the entry count in a `uint16_t` and then
//!     does `e *= 16`, which wraps modulo 65536 before the percent-full
//!     division.
//!   - `get_dell_evt_desc()` writes `str = '\0'` where it meant `*str = '\0'`,
//!     assigning NULL to a `char *` right after `*str++ = ','` overwrote the
//!     terminator.  The string still ends because `desc` was zeroed, one byte
//!     later than intended.
//!   - `ipmi_sel_add_entries_fromfile()` walks back over trailing whitespace
//!     with `while (isspace(*ptr) && ptr >= buf)`, dereferencing before the
//!     bound is tested.
//!   - `ipmi_sel_interpret()` leaves `struct sel_event_record evt` entirely
//!     uninitialised and never fills in the timestamp, so `sel interpret`
//!     prints stack garbage as the event time.
//!   - `ipmi_get_event_desc()` leaks `sfx` on the `flag == 0x02` path.
//!   - `ipmi_sel_show_entry()` leaves `entity.logical` uninitialised.
//!     `ipmi_sdr_find_sdr_byentity()` reads only `->id` and `->instance`
//!     (`lib/ipmi_sdr.c:3591`), so zero-initialising here is unobservable.
//!   - `ipmi_sel_get_std_entry()` memsets `evt` and then branches on
//!     `evt->record_type`, which is always 0 at that point: two of the three
//!     clearing arms are dead.
//!
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `sel` is selected.
//!
//! Allocation: `malloc`/`calloc`/`free` through the bridge, because the
//! description strings and the OEM message table cross the C ABI and are freed
//! by C code (and by `lib/ipmi_sdr.c`).

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");

const Intf = intf_mod.Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const EventSensorTypes = c.struct_ipmi_event_sensor_types;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const netfn_app: u6 = @intCast(c.IPMI_NETFN_APP);
const netfn_storage: u6 = @intCast(c.IPMI_NETFN_STORAGE);

const cmd_get_device_id: u8 = @intCast(c.BMC_GET_DEVICE_ID);
const cmd_get_sel_info: u8 = @intCast(c.IPMI_CMD_GET_SEL_INFO);
const cmd_get_sel_alloc_info: u8 = @intCast(c.IPMI_CMD_GET_SEL_ALLOC_INFO);
const cmd_reserve_sel: u8 = @intCast(c.IPMI_CMD_RESERVE_SEL);
const cmd_get_sel_entry: u8 = @intCast(c.IPMI_CMD_GET_SEL_ENTRY);
const cmd_add_sel_entry: u8 = @intCast(c.IPMI_CMD_ADD_SEL_ENTRY);
const cmd_delete_sel_entry: u8 = @intCast(c.IPMI_CMD_DELETE_SEL_ENTRY);
const cmd_clear_sel: u8 = @intCast(c.IPMI_CMD_CLEAR_SEL);
const cmd_get_sel_time: u8 = @intCast(c.IPMI_GET_SEL_TIME);
const cmd_set_sel_time: u8 = @intCast(c.IPMI_SET_SEL_TIME);

const oem_unknown: c.IPMI_OEM = @intCast(c.IPMI_OEM_UNKNOWN);

/// `SIZE_OF_DESC`: max size of the description string shown per SEL entry.
const size_of_desc: usize = 128;
/// `MAX_DIMM_STR`.
const max_dimm_str: usize = 32;

/// `EVENT_OFFSET_MASK`.
const event_offset_mask: u8 = @intCast(c.EVENT_OFFSET_MASK);

const sel_oem_ts_data_len: usize = c.SEL_OEM_TS_DATA_LEN;
const sel_oem_nots_data_len: usize = c.SEL_OEM_NOTS_DATA_LEN;

/// `SEL_BYTE(n)`: byte 3 of a log entry is at index 0.
inline fn selByte(n: usize) usize {
    return n - 3;
}

/// `BIT(x)`.
inline fn bit(x: anytype) c_int {
    return @as(c_int, 1) << @intCast(x);
}

// ---------------------------------------------------------------------------
// File statics
// ---------------------------------------------------------------------------

var sel_extended: c_int = 0;
var sel_oem_nrecs: c_int = 0;
var sel_iana: c.IPMI_OEM = oem_unknown;

/// `struct ipmi_sel_oem_msg_rec`.
const OemMsgRec = extern struct {
    value: [14]c_int,
    string: [14]?[*:0]u8,
    text: ?[*:0]u8,
};

/// `sel_oem_msg`.  Missing a `static` upstream, so it is a linker-visible
/// object and stays one here.
var sel_oem_msg: ?[*]OemMsgRec = null;

/// `event_dir_vals[]`.
const event_dir_vals = [_]c.struct_valstr{
    .{ .val = 0, .str = "Assertion Event" },
    .{ .val = 1, .str = "Deassertion Event" },
    .{ .val = 0, .str = null },
};

/// `hex2ascii()`'s function-static return buffer.
var hex_string: [sel_oem_nots_data_len + 1]u8 = @splat(0);

// ---------------------------------------------------------------------------
// Mirrors of the bitfield-carrying C structs
// ---------------------------------------------------------------------------

/// The byte shared by `event_type:7` and `event_dir:1`.
const TypeDir = packed struct(u8) {
    event_type: u7 = 0,
    event_dir: u1 = 0,
};

/// `struct standard_spec_sel_rec`.
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
    oem_defined: [sel_oem_ts_data_len]u8,
};

/// `struct oem_nots_spec_sel_rec`.
const OemNotsSpecSelRec = extern struct {
    oem_defined: [sel_oem_nots_data_len]u8,
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

/// `struct entity_id`.
const EntityId = extern struct {
    id: u8 = 0,
    /// `instance:7` / `logical:1`.
    instance_logical: packed struct(u8) {
        instance: u7 = 0,
        logical: u1 = 0,
    } = .{},
};

/// `struct sdr_record_list`.  `translate-c` silently drops its
/// `ATTRIBUTE_PACKING`, so the mirror is checked against `abi_layout.h`.
const SdrRecordList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrRecordList align(1),
    record: ?[*]const u8 align(1),
};

/// Byte offsets inside the SDR record types.  All of them are `opaque {}` on
/// the Zig side and only a handful of fields are read.
const sdr_off = struct {
    const common_entity_id = c.ABI_OFFSETOF_sdr_common__entity__id;
    const common_entity_instance = c.ABI_OFFSETOF_sdr_common__entity__instance;
    /// Units 1: `unit.pct:1`, `unit.modifier:2`, `unit.rate:3`, `unit.analog:2`.
    const common_unit = c.ABI_OFFSETOF_sdr_common__unit;
    const common_unit_base = c.ABI_OFFSETOF_sdr_common__unit__type__base;
    const common_unit_modifier = c.ABI_OFFSETOF_sdr_common__unit__type__modifier;

    const full_id_string = c.ABI_OFFSETOF_sdr_full__id_string;
    const compact_id_string = c.ABI_OFFSETOF_sdr_compact__id_string;
    const eventonly_id_string = c.ABI_OFFSETOF_sdr_eventonly__id_string;
    const eventonly_entity_id = c.ABI_OFFSETOF_sdr_eventonly__entity__id;
    const eventonly_entity_instance = c.ABI_OFFSETOF_sdr_eventonly__entity__instance;
    const fruloc_id_string = c.ABI_OFFSETOF_sdr_fruloc__id_string;
    const mcloc_id_string = c.ABI_OFFSETOF_sdr_mcloc__id_string;
    const genloc_id_string = c.ABI_OFFSETOF_sdr_genloc__id_string;
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn cRec(rec: *SelEventRecord) ?*c.struct_sel_event_record {
    return @ptrCast(rec);
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

/// One `intf->sendrecv()` round trip.
fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
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

/// C's `?:` over two string literals, which have different Zig types.
fn pick(cond: bool, a: [*:0]const u8, b: [*:0]const u8) [*:0]const u8 {
    return if (cond) a else b;
}

/// `errno`.
fn errno() c_int {
    return c.__errno_location().*;
}

fn setErrno(v: c_int) void {
    c.__errno_location().* = v;
}

/// C pointer arithmetic that stays well defined when the pointer is NULL,
/// which `ipmi_sel_interpret()` relies on after a failed `index()`.
fn advance(p: [*c]u8, n: usize) [*c]u8 {
    return @ptrFromInt(@intFromPtr(p) + n);
}

// ---------------------------------------------------------------------------
// OEM message translation file
// ---------------------------------------------------------------------------

/// `ipmi_sel_oem_readval()`: -1 for `XX`, -2 for `R`, -3 for non-hex, else the
/// hex value.
fn oemReadval(str: [*c]u8) c_int {
    if (c.strcmp(str, "XX") == 0) {
        return -1;
    }
    if (c.strcmp(str, "R") == 0) {
        return -2;
    }
    var ret: c_int = undefined;
    if (c.sscanf(str, "0x%x", &ret) != 1) {
        return -3;
    }
    return ret;
}

/// `ipmi_sel_oem_match()`.
fn oemMatch(evt: [*]const u8, rec: *const OemMsgRec) c_int {
    if (evt[2] == rec.value[selByte(3)] and
        (rec.value[selByte(4)] < 0 or evt[3] == rec.value[selByte(4)]) and
        (rec.value[selByte(5)] < 0 or evt[4] == rec.value[selByte(5)]) and
        (rec.value[selByte(6)] < 0 or evt[5] == rec.value[selByte(6)]) and
        (rec.value[selByte(7)] < 0 or evt[6] == rec.value[selByte(7)]) and
        (rec.value[selByte(11)] < 0 or evt[10] == rec.value[selByte(11)]) and
        (rec.value[selByte(12)] < 0 or evt[11] == rec.value[selByte(12)]))
    {
        return 1;
    } else {
        return 0;
    }
}

/// `ipmi_sel_oem_init()`, reached from `ipmitool -O <file>` and from
/// `ipmi_oem_setup()`.
fn selOemInit(filename: [*c]const u8) callconv(.c) c_int {
    var buf: [15][150]u8 = undefined;

    if (filename == null) {
        c.lprintf(log.Level.err, "No SEL OEM filename provided");
        return -1;
    }

    var fp = c.ipmi_open_file_read(filename);
    if (fp == null) {
        c.lprintf(log.Level.err, "Could not open %s file", filename);
        return -1;
    }

    // count number of records (lines) in input file
    sel_oem_nrecs = 0;
    while (c.fscanf(fp, "%*[^\n]\n") == 0) {
        sel_oem_nrecs += 1;
    }

    _ = c.printf("nrecs=%d\n", sel_oem_nrecs);

    c.rewind(fp);
    sel_oem_msg = @ptrCast(@alignCast(c.calloc(
        @intCast(sel_oem_nrecs),
        @sizeOf(OemMsgRec),
    )));

    var i: c_int = 0;
    while (i < sel_oem_nrecs) : (i += 1) {
        const n = c.fscanf(
            fp,
            "\"%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"" ++
                "%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"" ++
                "%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"%[^\"]\",\"" ++
                "%[^\"]\",\"%[^\"]\",\"%[^\"]\"\n",
            &buf[0],
            &buf[1],
            &buf[2],
            &buf[3],
            &buf[4],
            &buf[5],
            &buf[6],
            &buf[7],
            &buf[8],
            &buf[9],
            &buf[10],
            &buf[11],
            &buf[12],
            &buf[13],
            &buf[14],
        );

        if (n != 15) {
            c.lprintf(
                log.Level.err,
                "Encountered problems reading line %d of %s",
                i + 1,
                filename,
            );
            _ = c.fclose(fp);
            fp = null;
            sel_oem_nrecs = 0;
            // free all the memory allocated so far
            const table = sel_oem_msg.?;
            var j: c_int = 0;
            while (j < i) : (j += 1) {
                var k: usize = 3;
                while (k < 17) : (k += 1) {
                    if (table[@intCast(j)].value[selByte(k)] == -3) {
                        c.free(table[@intCast(j)].string[selByte(k)]);
                        table[@intCast(j)].string[selByte(k)] = null;
                    }
                }
            }
            c.free(table);
            sel_oem_msg = null;
            return -1;
        }

        const rec = &sel_oem_msg.?[@intCast(i)];
        var byte: usize = 3;
        while (byte < 17) : (byte += 1) {
            rec.value[selByte(byte)] = oemReadval(&buf[selByte(byte)]);
            if (rec.value[selByte(byte)] == -3) {
                rec.string[selByte(byte)] = @ptrCast(c.malloc(
                    c.strlen(&buf[selByte(byte)]) + 1,
                ));
                _ = c.strcpy(rec.string[selByte(byte)], &buf[selByte(byte)]);
            }
        }
        rec.text = @ptrCast(c.malloc(c.strlen(&buf[selByte(17)]) + 1));
        _ = c.strcpy(rec.text, &buf[selByte(17)]);
    }

    _ = c.fclose(fp);
    fp = null;
    return 0;
}

/// `ipmi_sel_oem_message()`.
fn oemMessage(evt: *SelEventRecord) void {
    const bytes: [*]const u8 = @ptrCast(evt);

    var i: c_int = 0;
    while (i < sel_oem_nrecs) : (i += 1) {
        const rec = &sel_oem_msg.?[@intCast(i)];
        if (oemMatch(bytes, rec) != 0) {
            _ = c.printf(pick(csvOutput(), ",\"%s\"", " | %s"), rec.text);
            var j: usize = 4;
            while (j < 17) : (j += 1) {
                if (rec.value[selByte(j)] == -3) {
                    _ = c.printf(
                        pick(csvOutput(), ",%s=0x%x", " %s = 0x%x"),
                        rec.string[selByte(j)],
                        @as(c_int, bytes[selByte(j)]),
                    );
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Event and sensor type names
// ---------------------------------------------------------------------------

/// `ipmi_get_event_type()`.
fn getEventType(code: u8) [*:0]const u8 {
    if (code == 0) return "Unspecified";
    if (code == 1) return "Threshold";
    if (code >= 0x02 and code <= 0x0b) return "Generic Discrete";
    if (code == 0x6f) return "Sensor-specific Discrete";
    if (code >= 0x70 and code <= 0x7f) return "OEM";
    return "Reserved";
}

/// `hex2ascii()`.  Returns the module's static buffer, exactly as C did.
fn hex2ascii(hex_chars: [*]const u8, num_bytes_in: u8) [*c]u8 {
    var num_bytes = num_bytes_in;
    if (num_bytes > sel_oem_nots_data_len) {
        num_bytes = @intCast(sel_oem_nots_data_len);
    }

    var count: usize = 0;
    while (count < num_bytes) : (count += 1) {
        if (hex_chars[count] < 0x40 or hex_chars[count] > 0x7e) {
            hex_string[count] = '.';
        } else {
            hex_string[count] = hex_chars[count];
        }
    }
    hex_string[num_bytes] = 0;
    return &hex_string;
}

/// `ipmi_get_oem()`: a Get Device ID round trip, cached on the interface.
fn getOem(intf: ?*Intf) callconv(.c) c.IPMI_OEM {
    const in = intf.?;

    if (in.fd == 0) {
        if (sel_iana != oem_unknown) {
            return sel_iana;
        }
        return oem_unknown;
    }

    // Return the cached manufacturer id if the device is open and we got an
    // identified OEM owner.  Otherwise just attempt to read it.
    if (in.opened != 0 and @intFromEnum(in.manufacturer_id) != oem_unknown) {
        return @intFromEnum(in.manufacturer_id);
    }

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_device_id;
    req.msg.data_len = 0;

    const rsp = sendrecv(in, &req) orelse {
        c.lprintf(log.Level.err, "Get Device ID command failed");
        return oem_unknown;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get Device ID command failed: %#x %s",
            @as(c_int, rsp.ccode),
            ccString(rsp.ccode),
        );
        return oem_unknown;
    }

    const devid: *c.struct_ipm_devid_rsp = @ptrCast(@alignCast(&rsp.data[0]));

    c.lprintf(log.Level.debug, "Iana: %u", c.ipmi24toh(&devid.manufacturer_id));

    return @intCast(c.ipmi24toh(&devid.manufacturer_id));
}

// ---------------------------------------------------------------------------
// sel add
// ---------------------------------------------------------------------------

/// `ipmi_sel_add_entry()`.
fn selAddEntry(intf: *Intf, rec: *SelEventRecord) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_add_sel_entry;
    req.msg.data = @ptrCast(rec);
    req.msg.data_len = 16;

    printStdEntry(intf, rec);

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Add SEL Entry failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Add SEL Entry failed: %s", ccString(rsp.ccode));
        return -1;
    }

    return 0;
}

/// `ipmi_sel_add_entries_fromfile()`.
fn selAddEntriesFromfile(intf: *Intf, filename: [*c]const u8) c_int {
    var buf: [1024]u8 = undefined;
    var rqdata: [8]u8 = undefined;
    var sel_event: SelEventRecord = undefined;
    var rc: c_int = 0;

    if (filename == null) {
        return -1;
    }

    const fp = c.ipmi_open_file_read(filename);
    if (fp == null) {
        return -1;
    }

    while (c.feof(fp) == 0) {
        if (c.fgets(&buf, 1024, fp) == null) {
            continue;
        }

        // clip off optional comment tail indicated by #
        var ptr = c.strchr(&buf, '#');
        if (ptr != null) {
            ptr[0] = 0;
        } else {
            ptr = @as([*c]u8, &buf) + c.strlen(&buf);
        }

        // clip off trailing and leading whitespace.  The bound test comes
        // after the dereference upstream; reproduced.
        ptr -= 1;
        while (c.isspace(ptr[0]) != 0 and @intFromPtr(ptr) >= @intFromPtr(&buf)) {
            ptr[0] = 0;
            ptr -= 1;
        }
        ptr = &buf;
        while (c.isspace(ptr[0]) != 0) {
            ptr += 1;
        }
        if (c.strlen(ptr) == 0) {
            continue;
        }

        // parse the event, 7 bytes with optional comment
        // 0x00 0x00 0x00 0x00 0x00 0x00 0x00 # event
        var i: usize = 0;
        var tok = c.strtok(ptr, " ");
        while (tok != null) {
            if (i == 7) break;
            const j = i;
            i += 1;
            if (c.str2uchar(tok, &rqdata[j]) != 0) {
                break;
            }
            tok = c.strtok(null, " ");
        }
        if (i < 7) {
            c.lprintf(
                log.Level.err,
                "Invalid Event: %s",
                c.buf2str(&rqdata, rqdata.len),
            );
            continue;
        }

        sel_event = .{};
        sel_event.record_id = 0x0000;
        sel_event.record_type = 0x02;
        // IPMI spec 32.1 generator ID: bit 0 = 1 "Software defined",
        // bits 1-7 SWID, 2 = "System management software".
        sel_event.sel_type.standard_type.gen_id = 0x41;
        sel_event.sel_type.standard_type.evm_rev = rqdata[0];
        sel_event.sel_type.standard_type.sensor_type = rqdata[1];
        sel_event.sel_type.standard_type.sensor_num = rqdata[2];
        sel_event.sel_type.standard_type.td.event_type = @truncate(rqdata[3] & 0x7f);
        sel_event.sel_type.standard_type.td.event_dir = @truncate((rqdata[3] & 0x80) >> 7);
        sel_event.sel_type.standard_type.event_data[0] = rqdata[4];
        sel_event.sel_type.standard_type.event_data[1] = rqdata[5];
        sel_event.sel_type.standard_type.event_data[2] = rqdata[6];

        rc = selAddEntry(intf, &sel_event);
        if (rc < 0) break;
    }

    _ = c.fclose(fp);
    return rc;
}

// ---------------------------------------------------------------------------
// OEM event descriptions
// ---------------------------------------------------------------------------

/// `get_kontron_evt_desc()`.  The `intf` argument is unused upstream.
fn getKontronEvtDesc(intf: ?*Intf, rec: ?*SelEventRecord) callconv(.c) [*c]u8 {
    _ = intf;
    const r = rec.?;

    // Only standard records are defined so far
    if (r.record_type < 0xC0) {
        var i: usize = 0;
        while (c.oem_kontron_event_types[i].desc != null) : (i += 1) {
            const st = &c.oem_kontron_event_types[i];
            if (st.code == r.sel_type.standard_type.td.event_type) {
                const len = c.strlen(st.desc);
                const description: [*c]u8 = @ptrCast(c.malloc(len + 1));
                _ = c.memcpy(description, st.desc, len);
                description[len] = 0;
                return description;
            }
        }
    }

    return null;
}

/// `get_viking_evt_desc()`: the description comes back from an OEM command.
fn getVikingEvtDesc(intf: ?*Intf, rec: ?*SelEventRecord) callconv(.c) [*c]u8 {
    const in = intf.?;
    const r = rec.?;
    var msg_data: [6]u8 = undefined;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = 0x2E;
    req.msg.cmd = 0x01;
    req.msg.data_len = msg_data.len;

    msg_data[0] = 0x15; // IANA LSB
    msg_data[1] = 0x24; // IANA
    msg_data[2] = 0x00; // IANA MSB
    msg_data[3] = 0x01; // Subcommand
    msg_data[4] = @truncate(r.record_id & 0x00FF); // SEL Record ID LSB
    msg_data[5] = @truncate((r.record_id & 0xFF00) >> 8); // SEL Record ID MSB

    req.msg.data = &msg_data;

    const rsp = sendrecv(in, &req) orelse {
        if (verbose() != 0) {
            c.lprintf(log.Level.err, "Error issuing OEM command");
        }
        return null;
    };
    if (rsp.ccode != 0) {
        if (verbose() != 0) {
            c.lprintf(
                log.Level.err,
                "OEM command returned error code: %s",
                ccString(rsp.ccode),
            );
        }
        return null;
    }

    // Verify our response before we use it
    if (rsp.data_len < 5) {
        c.lprintf(log.Level.err, "Viking OEM response too short");
        return null;
    } else if (rsp.data_len != 4 + @as(c_int, rsp.data[3])) {
        c.lprintf(log.Level.err, "Viking OEM response has unexpected length");
        return null;
    } else if (c.ipmi24toh(&rsp.data[0]) != c.IPMI_OEM_VIKING) {
        c.lprintf(log.Level.err, "Viking OEM response has unexpected length");
        return null;
    }

    const description: [*c]u8 = @ptrCast(c.malloc(@as(usize, rsp.data[3]) + 1));
    _ = c.memcpy(description, &rsp.data[4], rsp.data[3]);
    description[rsp.data[3]] = 0;

    return description;
}

/// `get_supermicro_evt_desc()`.
fn getSupermicroEvtDesc(intf: ?*Intf, rec: ?*SelEventRecord) callconv(.c) [*c]u8 {
    const in = intf.?;
    const r = rec.?;
    var chipset_type: c_int = 4;
    var i: u8 = 0;

    // Get the OEM event Bytes of the SEL Records byte 13, 14, 15 to
    // data1,data2,data3
    const data1: c_int = r.sel_type.standard_type.event_data[0];
    const data2: c_int = r.sel_type.standard_type.event_data[1];
    const data3: c_int = r.sel_type.standard_type.event_data[2];

    // Check for the Standard Event type == 0x6F
    if (r.sel_type.standard_type.td.event_type != 0x6F) {
        return null;
    }
    // Allocate mem for the Description string
    const desc: [*c]u8 = @ptrCast(c.malloc(size_of_desc));
    if (desc == null) {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    }
    _ = c.memset(desc, '\x00', size_of_desc);

    const sensor_type: c_int = r.sel_type.standard_type.sensor_type;
    switch (sensor_type) {
        c.SENSOR_TYPE_MEMORY => {
            var req = std.mem.zeroes(Request);
            req.msg.netfn_lun.netfn = netfn_app;
            req.msg.netfn_lun.lun = 0;
            req.msg.cmd = cmd_get_device_id;
            req.msg.data = null;
            req.msg.data_len = 0;

            const rsp = sendrecv(in, &req) orelse {
                c.lprintf(log.Level.err, " Error getting system info");
                c.free(desc);
                return null;
            };
            if (rsp.ccode != 0) {
                c.lprintf(
                    log.Level.err,
                    " Error getting system info: %s",
                    ccString(rsp.ccode),
                );
                c.free(desc);
                return null;
            }
            // check the chipset type
            const oem_id = c.ipmi_get_oem_id(cIntf(in));
            if (oem_id == 0) {
                c.free(desc);
                return null;
            }
            i = 0;
            while (c.supermicro_X8[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_X8[i]) {
                    chipset_type = 0;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_older[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_older[i]) {
                    chipset_type = 0;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_romely[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_romely[i]) {
                    chipset_type = 1;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_x9[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_x9[i]) {
                    chipset_type = 2;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_brickland[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_brickland[i]) {
                    chipset_type = 3;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_x10QRH[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_x10QRH[i]) {
                    chipset_type = 4;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_x10QBL[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_x10QBL[i]) {
                    chipset_type = 4;
                    break;
                }
            }
            i = 0;
            while (c.supermicro_x10OBi[i] != 0xFFFF) : (i += 1) {
                if (oem_id == c.supermicro_x10OBi[i]) {
                    chipset_type = 5;
                    break;
                }
            }
            if (chipset_type == 0) {
                _ = c.snprintf(desc, size_of_desc, "@DIMM%2X(CPU%x)", data2, (data3 & 0x03) + 1);
            } else if (chipset_type == 1) {
                _ = c.snprintf(
                    desc,
                    size_of_desc,
                    "@DIMM%c%c(CPU%x)",
                    (data2 >> 4) + 0x40 + (data3 & 0x3) * 4,
                    (data2 & 0xf) + 0x27,
                    (data3 & 0x03) + 1,
                );
            } else if (chipset_type == 2) {
                _ = c.snprintf(
                    desc,
                    size_of_desc,
                    "@DIMM%c%c(CPU%x)",
                    (data2 >> 4) + 0x40 + (data3 & 0x3) * 3,
                    (data2 & 0xf) + 0x27,
                    (data3 & 0x03) + 1,
                );
            } else if (chipset_type == 3) {
                _ = c.snprintf(
                    desc,
                    size_of_desc,
                    "@DIMM%c%d(P%dM%d)",
                    if (((data2 & 0xf) >> 4) > 4)
                        @as(c_int, '@') - 4 + ((data2 & 0xff) >> 4)
                    else
                        @as(c_int, '@') + ((data2 & 0xff) >> 4),
                    (data2 & 0xf) - 0x09,
                    (data3 & 0x0f) + 1,
                    @as(c_int, if ((data2 & 0xff) >> 4 > 4) 2 else 1),
                );
            } else if (chipset_type == 4) {
                _ = c.snprintf(
                    desc,
                    size_of_desc,
                    "@DIMM%c%c(CPU%x)",
                    (data2 >> 4) + 0x40,
                    (data2 & 0xf) + 0x27,
                    (data3 & 0x03) + 1,
                );
            } else if (chipset_type == 5) {
                _ = c.snprintf(
                    desc,
                    size_of_desc,
                    "@DIMM%c%c(CPU%x)",
                    (data2 >> 4) + 0x40,
                    (data2 & 0xf) + 0x27,
                    (data3 & 0x07) + 1,
                );
            } else {
                // No description.
                desc[0] = 0;
            }
        },
        c.SENSOR_TYPE_SUPERMICRO_OEM => {
            if (data1 == 0x80 and data3 == 0xFF) {
                if (data2 == 0x0) {
                    _ = c.snprintf(desc, size_of_desc, "BMC unexpected reset");
                } else if (data2 == 0x1) {
                    _ = c.snprintf(desc, size_of_desc, "BMC cold reset");
                } else if (data2 == 0x2) {
                    _ = c.snprintf(desc, size_of_desc, "BMC warm reset");
                }
            }
        },
        else => {},
    }
    return desc;
}

/// `get_dell_evt_desc()`: appends Dell-specific detail to the standard event
/// description.
fn getDellEvtDesc(intf: ?*Intf, rec: ?*SelEventRecord) callconv(.c) [*c]u8 {
    const in = intf.?;
    const r = rec.?;

    var count: u8 = 0;
    var node: u8 = 0;
    var dimm_num: u8 = 0;
    var dimms_per_node: u8 = 0;
    var dimm_str: [max_dimm_str]u8 = undefined;
    var tmpdesc: [size_of_desc]u8 = undefined;
    var str: [*c]u8 = null;
    var incr: u8 = 0;
    var i: u8 = 0;
    var j: u8 = 0;
    var desc: [*c]u8 = null;

    // Get the OEM event Bytes of the SEL Records byte 13, 14, 15 to
    // Data1,data2,data3
    const data1: c_int = r.sel_type.standard_type.event_data[0];
    const data2: c_int = r.sel_type.standard_type.event_data[1];
    const data3: c_int = r.sel_type.standard_type.event_data[2];

    // Check for the Standard Event type == 0x6F
    if (0x6F == r.sel_type.standard_type.td.event_type) {
        const sensor_type: c_int = r.sel_type.standard_type.sensor_type;
        // Allocate mem for the Description string
        desc = @ptrCast(c.malloc(size_of_desc));
        if (desc == null) {
            return null;
        }
        _ = c.memset(desc, 0, size_of_desc);
        _ = c.memset(&tmpdesc, 0, size_of_desc);

        sw: switch (sensor_type) {
            // Processor/CPU related OEM Sel Byte Decoding for DELL Platforms only
            c.SENSOR_TYPE_PROCESSOR => {
                if (c.OEM_CODE_IN_BYTE2 == (data1 & c.DATA_BYTE2_SPECIFIED_MASK)) {
                    if (0x00 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.snprintf(desc, size_of_desc, "CPU Internal Err | ");
                    }
                    if (0x06 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.snprintf(desc, size_of_desc, "CPU Protocol Err | ");
                    }

                    // change bit location to a number
                    count = 0;
                    while (count < 8) : (count += 1) {
                        if (bit(count) & data2 != 0) {
                            count += 1;
                            // 0x0A - CPU sensor number
                            if (0x06 == (data1 & c.MASK_LOWER_NIBBLE) and
                                0x0A == r.sel_type.standard_type.sensor_num)
                            {
                                // Which CPU Has generated the FSB
                                _ = c.snprintf(desc, size_of_desc, "FSB %d ", @as(c_int, count));
                            } else {
                                // Specific CPU related info
                                _ = c.snprintf(
                                    desc,
                                    size_of_desc,
                                    "CPU %d | APIC ID %d ",
                                    @as(c_int, count),
                                    data3,
                                );
                            }
                            break;
                        }
                    }
                }
            },
            // Memory/DIMM and event-logging OEM Sel Byte Decoding, DELL only
            c.SENSOR_TYPE_MEMORY, c.SENSOR_TYPE_EVT_LOG => {
                // Get the current version of the IPMI Spec; the memory decode
                // depends on it.
                var req = std.mem.zeroes(Request);
                req.msg.netfn_lun.netfn = netfn_app;
                req.msg.netfn_lun.lun = 0;
                req.msg.cmd = cmd_get_device_id;
                req.msg.data = null;
                req.msg.data_len = 0;

                const rsp = sendrecv(in, &req) orelse {
                    c.lprintf(log.Level.err, " Error getting system info");
                    c.free(desc);
                    return null;
                };
                if (rsp.ccode != 0) {
                    c.lprintf(
                        log.Level.err,
                        " Error getting system info: %s",
                        ccString(rsp.ccode),
                    );
                    c.free(desc);
                    return null;
                }
                const version: c_int = rsp.data[4];

                // Memory DIMMS
                if ((data1 & c.OEM_CODE_IN_BYTE2) != 0 or (data1 & c.OEM_CODE_IN_BYTE3) != 0) {
                    // Memory Redundancy related oem bytes decoding
                    if (c.SENSOR_TYPE_MEMORY == sensor_type and
                        0x0B == r.sel_type.standard_type.td.event_type)
                    {
                        if (0x00 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, " Redundancy Regained | ");
                        } else if (0x01 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "Redundancy Lost | ");
                        }
                    }
                    // Correctable and uncorrectable ECC Error Decoding
                    else if (c.SENSOR_TYPE_MEMORY == sensor_type) {
                        if (0x00 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            // 0x1C - Memory Sensor Number
                            if (0x1C == r.sel_type.standard_type.sensor_num) {
                                // Add the complete information about the Memory Configs.
                                if ((data1 & c.OEM_CODE_IN_BYTE2) != 0 and
                                    (data1 & c.OEM_CODE_IN_BYTE3) != 0)
                                {
                                    count = 0;
                                    _ = c.snprintf(desc, size_of_desc, "CRC Error on:");
                                    i = 0;
                                    while (i < 4) : (i += 1) {
                                        if (bit(i) & data2 != 0) {
                                            if (count != 0) {
                                                str = desc + c.strlen(desc);
                                                str[0] = ',';
                                                str += 1;
                                                // Upstream writes `str = '\0'`,
                                                // assigning NULL to the pointer.
                                                str = null;
                                                count = 0;
                                            }
                                            // Which type of memory config is present
                                            switch (i) {
                                                0 => {
                                                    _ = c.snprintf(&tmpdesc, size_of_desc, "South Bound Memory");
                                                    _ = c.strcat(desc, &tmpdesc);
                                                    count += 1;
                                                },
                                                1 => {
                                                    _ = c.snprintf(&tmpdesc, size_of_desc, "South Bound Config");
                                                    _ = c.strcat(desc, &tmpdesc);
                                                    count += 1;
                                                },
                                                2 => {
                                                    _ = c.snprintf(&tmpdesc, size_of_desc, "North Bound memory");
                                                    _ = c.strcat(desc, &tmpdesc);
                                                    count += 1;
                                                },
                                                3 => {
                                                    _ = c.snprintf(&tmpdesc, size_of_desc, "North Bound memory-corr");
                                                    _ = c.strcat(desc, &tmpdesc);
                                                    count += 1;
                                                },
                                                else => {},
                                            }
                                        }
                                    }
                                    if (data3 >= 0x00 and data3 < 0xFF) {
                                        _ = c.snprintf(&tmpdesc, size_of_desc, "|Failing_Channel:%d", data3);
                                        _ = c.strcat(desc, &tmpdesc);
                                    }
                                }
                                break :sw;
                            }
                            _ = c.snprintf(desc, size_of_desc, "Correctable ECC | ");
                        } else if (0x01 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "UnCorrectable ECC | ");
                        }
                    }
                    // Corr Memory log disabled
                    else if (c.SENSOR_TYPE_EVT_LOG == sensor_type) {
                        if (0x00 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "Corr Memory Log Disabled | ");
                        }
                    }
                } else {
                    if (c.SENSOR_TYPE_SYS_EVENT == sensor_type) {
                        if (0x02 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "Unknown System Hardware Failure ");
                        }
                    }
                    if (c.SENSOR_TYPE_EVT_LOG == sensor_type) {
                        if (0x03 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "All Even Logging Disabled");
                        }
                    }
                }

                // Based on the above error, find which memory slot or card
                // generated the SEL entry.
                if (data1 & c.OEM_CODE_IN_BYTE2 != 0) {
                    // Find the Card Type
                    if (0x0F != (data2 >> 4) and (data2 >> 4) < 0x08) {
                        const tmp_data: u8 = @intCast('A' + (data2 >> 4));
                        if (c.SENSOR_TYPE_MEMORY == sensor_type and
                            0x0B == r.sel_type.standard_type.td.event_type)
                        {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "Bad Card %c", @as(c_int, tmp_data));
                        } else {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "Card %c", @as(c_int, tmp_data));
                        }
                        _ = c.strcat(desc, &tmpdesc);
                    }
                    // Find the Bank Number of the DIMM
                    if (0x0F != (data2 & c.MASK_LOWER_NIBBLE)) {
                        if (0x51 == version) {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "Bank %d", (data2 & 0x0F) + 1);
                            _ = c.strcat(desc, &tmpdesc);
                        } else {
                            incr = @intCast((data2 & 0x0f) << 3);
                        }
                    }
                }

                // Find the DIMM Number of the Memory which generated the fault
                if (data1 & c.OEM_CODE_IN_BYTE3 != 0) {
                    // Based on the IPMI Spec, identify the DIMM details.
                    // For spec 1.5 only the DIMM Number is valid.
                    if (0x51 == version) {
                        _ = c.snprintf(&tmpdesc, size_of_desc, "DIMM %c", @as(c_int, 'A') + data3);
                        _ = c.strcat(desc, &tmpdesc);
                    }
                    // For spec 2.0 decode the DIMM number as it supports more.
                    else if ((data2 >> 4) > 0x07 and 0x0F != (data2 >> 4)) {
                        _ = c.strcpy(&dimm_str, " DIMM");
                        str = desc + c.strlen(desc);
                        dimms_per_node = 4;
                        if (0x09 == (data2 >> 4)) {
                            dimms_per_node = 6;
                        } else if (0x0A == (data2 >> 4)) {
                            dimms_per_node = 8;
                        } else if (0x0B == (data2 >> 4)) {
                            dimms_per_node = 9;
                        } else if (0x0C == (data2 >> 4)) {
                            dimms_per_node = 12;
                        } else if (0x0D == (data2 >> 4)) {
                            dimms_per_node = 24;
                        } else if (0x0E == (data2 >> 4)) {
                            dimms_per_node = 3;
                        }
                        count = 0;
                        i = 0;
                        while (i < 8) : (i += 1) {
                            if (bit(i) & data3 != 0) {
                                if (count != 0) {
                                    _ = c.strcat(str, ",");
                                    count = 0x00;
                                }
                                node = @intCast(@divTrunc(
                                    @as(c_int, incr) + @as(c_int, i),
                                    @as(c_int, dimms_per_node),
                                ));
                                dimm_num = @intCast(@rem(
                                    @as(c_int, incr) + @as(c_int, i),
                                    @as(c_int, dimms_per_node),
                                ) + 1);
                                dimm_str[5] = node +% 'A';
                                _ = c.sprintf(&tmpdesc, "%d", @as(c_int, dimm_num));
                                j = 0;
                                while (j < c.strlen(&tmpdesc)) : (j += 1) {
                                    dimm_str[6 + j] = tmpdesc[j];
                                }
                                dimm_str[6 + j] = 0;
                                // final DIMM Details
                                _ = c.strcat(str, &dimm_str);
                                count += 1;
                            }
                        }
                    } else {
                        _ = c.strcpy(&dimm_str, " DIMM");
                        str = desc + c.strlen(desc);
                        count = 0;
                        i = 0;
                        while (i < 8) : (i += 1) {
                            if (bit(i) & data3 != 0) {
                                // check if more than one DIMM, if so add a comma
                                _ = c.sprintf(&tmpdesc, "%d", @as(c_int, i) + @as(c_int, incr) + 1);
                                if (count != 0) {
                                    _ = c.strcat(str, ",");
                                    count = 0x00;
                                }
                                j = 0;
                                while (j < c.strlen(&tmpdesc)) : (j += 1) {
                                    dimm_str[5 + j] = tmpdesc[j];
                                }
                                dimm_str[5 + j] = 0;
                                _ = c.strcat(str, &dimm_str);
                                count += 1;
                            }
                        }
                    }
                }
            },
            // Sensor In system characterization Error Decoding, sensor type 0x20
            c.SENSOR_TYPE_TXT_CMD_ERROR => {
                if (0x00 == (data1 & c.MASK_LOWER_NIBBLE) and
                    ((data1 & c.OEM_CODE_IN_BYTE2) != 0 and (data1 & c.OEM_CODE_IN_BYTE3) != 0))
                {
                    switch (data3) {
                        0x01 => _ = c.snprintf(desc, size_of_desc, "BIOS TXT Error"),
                        0x02 => _ = c.snprintf(desc, size_of_desc, "Processor/FIT TXT"),
                        0x03 => _ = c.snprintf(desc, size_of_desc, "BIOS ACM TXT Error"),
                        0x04 => _ = c.snprintf(desc, size_of_desc, "SINIT ACM TXT Error"),
                        0xff => _ = c.snprintf(desc, size_of_desc, "Unrecognized TT Error12"),
                        else => {},
                    }
                }
            },
            // OS Watch Dog Timer Sel Events
            c.SENSOR_TYPE_WTDOG => {
                if (c.SENSOR_TYPE_OEM_SEC_EVENT == data1) {
                    if (0x04 == data2) {
                        _ = c.snprintf(
                            desc,
                            size_of_desc,
                            "Hard Reset|Interrupt type None,SMS/OS Timer used at expiration",
                        );
                    }
                }
            },
            // This event is for BMC to other hardware or CPU
            c.SENSOR_TYPE_VER_CHANGE => {
                if (0x02 == (data1 & c.MASK_LOWER_NIBBLE) and
                    ((data1 & c.OEM_CODE_IN_BYTE2) != 0 and (data1 & c.OEM_CODE_IN_BYTE3) != 0))
                {
                    if (0x02 == data2) {
                        if (0x00 == data3) {
                            _ = c.snprintf(
                                desc,
                                size_of_desc,
                                "between BMC/iDRAC Firmware and other hardware",
                            );
                        } else if (0x01 == data3) {
                            _ = c.snprintf(
                                desc,
                                size_of_desc,
                                "between BMC/iDRAC Firmware and CPU",
                            );
                        }
                    }
                }
            },
            // Flex or Mac tuning OEM Decoding for DELL
            c.SENSOR_TYPE_OEM_SEC_EVENT => {
                // 0x25 - Virtual MAC sensor number - Dell OEM
                if (0x25 == r.sel_type.standard_type.sensor_num) {
                    if (0x01 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.snprintf(desc, size_of_desc, "Failed to program Virtual Mac Address");
                        if ((data1 & c.OEM_CODE_IN_BYTE2) != 0 and (data1 & c.OEM_CODE_IN_BYTE3) != 0) {
                            _ = c.snprintf(
                                &tmpdesc,
                                size_of_desc,
                                " at bus:%.2x device:%.2x function:%x",
                                data3 & 0x7F,
                                (data2 >> 3) & 0x1F,
                                data2 & 0x07,
                            );
                            _ = c.strcat(desc, &tmpdesc);
                        }
                    } else if (0x02 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.snprintf(
                            desc,
                            size_of_desc,
                            "Device option ROM failed to support link tuning or flex address",
                        );
                    } else if (0x03 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.snprintf(
                            desc,
                            size_of_desc,
                            "Failed to get link tuning or flex address data from BMC/iDRAC",
                        );
                    }
                }
            },
            c.SENSOR_TYPE_CRIT_INTR,
            // Non-fatal PCIe Express Error Decoding
            c.SENSOR_TYPE_OEM_NFATAL_ERROR,
            // Fatal IO Error Decoding
            c.SENSOR_TYPE_OEM_FATAL_ERROR,
            => {
                // 0x29 - QPI Linx Error Sensor Dell OEM
                if (0x29 == r.sel_type.standard_type.sensor_num) {
                    if (0x02 == (data1 & c.MASK_LOWER_NIBBLE) and
                        ((data1 & c.OEM_CODE_IN_BYTE2) != 0 and (data1 & c.OEM_CODE_IN_BYTE3) != 0))
                    {
                        _ = c.snprintf(
                            &tmpdesc,
                            size_of_desc,
                            "Partner-(LinkId:%d,AgentId:%d)|",
                            data2 & 0xC0,
                            data2 & 0x30,
                        );
                        _ = c.strcat(desc, &tmpdesc);
                        _ = c.snprintf(
                            &tmpdesc,
                            size_of_desc,
                            "ReportingAgent(LinkId:%d,AgentId:%d)|",
                            data2 & 0x0C,
                            data2 & 0x03,
                        );
                        _ = c.strcat(desc, &tmpdesc);
                        if (0x00 == (data3 & 0xFC)) {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "LinkWidthDegraded|");
                            _ = c.strcat(desc, &tmpdesc);
                        }
                        if (bit(1) & data3 != 0) {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "PA_Type:IOH|");
                        } else {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "PA-Type:CPU|");
                        }
                        _ = c.strcat(desc, &tmpdesc);
                        if (bit(0) & data3 != 0) {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "RA-Type:IOH");
                        } else {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "RA-Type:CPU");
                        }
                        _ = c.strcat(desc, &tmpdesc);
                    }
                } else {
                    if (0x02 == (data1 & c.MASK_LOWER_NIBBLE)) {
                        _ = c.sprintf(desc, "%s", "IO channel Check NMI");
                    } else {
                        if (0x00 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "%s", "PCIe Error |");
                        } else if (0x01 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "%s", "I/O Error |");
                        } else if (0x04 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "%s", "PCI PERR |");
                        } else if (0x05 == (data1 & c.MASK_LOWER_NIBBLE)) {
                            _ = c.snprintf(desc, size_of_desc, "%s", "PCI SERR |");
                        } else {
                            _ = c.snprintf(desc, size_of_desc, "%s", " ");
                        }
                        if (data3 & 0x80 != 0) {
                            _ = c.snprintf(&tmpdesc, size_of_desc, "Slot %d", data3 & 0x7F);
                        } else {
                            _ = c.snprintf(
                                &tmpdesc,
                                size_of_desc,
                                "PCI bus:%.2x device:%.2x function:%x",
                                data3 & 0x7F,
                                (data2 >> 3) & 0x1F,
                                data2 & 0x07,
                            );
                        }
                        _ = c.strcat(desc, &tmpdesc);
                    }
                }
            },
            // POST Fatal Errors generated from the server, with much more info
            c.SENSOR_TYPE_FRM_PROG => {
                if (0x0F == (data1 & c.MASK_LOWER_NIBBLE) and (data1 & c.OEM_CODE_IN_BYTE2) != 0) {
                    switch (data2) {
                        0x80 => _ = c.snprintf(desc, size_of_desc, "No memory is detected."),
                        0x81 => _ = c.snprintf(desc, size_of_desc, "Memory is detected but is not configurable."),
                        0x82 => _ = c.snprintf(desc, size_of_desc, "Memory is configured but not usable."),
                        0x83 => _ = c.snprintf(desc, size_of_desc, "System BIOS shadow failed."),
                        0x84 => _ = c.snprintf(desc, size_of_desc, "CMOS failed."),
                        0x85 => _ = c.snprintf(desc, size_of_desc, "DMA controller failed."),
                        0x86 => _ = c.snprintf(desc, size_of_desc, "Interrupt controller failed."),
                        0x87 => _ = c.snprintf(desc, size_of_desc, "Timer refresh failed."),
                        0x88 => _ = c.snprintf(desc, size_of_desc, "Programmable interval timer error."),
                        0x89 => _ = c.snprintf(desc, size_of_desc, "Parity error."),
                        0x8A => _ = c.snprintf(desc, size_of_desc, "SIO failed."),
                        0x8B => _ = c.snprintf(desc, size_of_desc, "Keyboard controller failed."),
                        0x8C => _ = c.snprintf(desc, size_of_desc, "System management interrupt initialization failed."),
                        0x8D => _ = c.snprintf(desc, size_of_desc, "TXT-SX Error."),
                        0xC0 => _ = c.snprintf(desc, size_of_desc, "Shutdown test failed."),
                        0xC1 => _ = c.snprintf(desc, size_of_desc, "BIOS POST memory test failed."),
                        0xC2 => _ = c.snprintf(desc, size_of_desc, "RAC configuration failed."),
                        0xC3 => _ = c.snprintf(desc, size_of_desc, "CPU configuration failed."),
                        0xC4 => _ = c.snprintf(desc, size_of_desc, "Incorrect memory configuration."),
                        0xFE => _ = c.snprintf(desc, size_of_desc, "General failure after video."),
                        else => {},
                    }
                }
            },
            else => {},
        }
    } else {
        // Upstream assigns `sensor_type = rec->...event_type` here; the value
        // is never read again.
    }
    return desc;
}

/// `ipmi_get_oem_desc()`.
fn getOemDesc(intf: ?*Intf, rec: ?*SelEventRecord) callconv(.c) [*c]u8 {
    var desc: [*c]u8 = null;

    switch (getOem(intf)) {
        c.IPMI_OEM_VIKING => desc = getVikingEvtDesc(intf, rec),
        c.IPMI_OEM_KONTRON => desc = getKontronEvtDesc(intf, rec),
        // Dell decoding of the OEM bytes from the SEL record
        c.IPMI_OEM_DELL => desc = getDellEvtDesc(intf, rec),
        c.IPMI_OEM_SUPERMICRO, c.IPMI_OEM_SUPERMICRO_47488 => desc = getSupermicroEvtDesc(intf, rec),
        c.IPMI_OEM_QUANTA => desc = c.oem_qct_get_evt_desc(cIntf(intf.?), cRec(rec.?)),
        else => {},
    }

    return desc;
}

// ---------------------------------------------------------------------------
// Event table walk
// ---------------------------------------------------------------------------

/// `ipmi_get_first_event_sensor_type()`.
fn getFirstEventSensorType(
    intf: ?*Intf,
    sensor_type: u8,
    event_type: u8,
) callconv(.c) [*c]const EventSensorTypes {
    var start: [*c]const EventSensorTypes = undefined;
    var next: [*c]const EventSensorTypes = null;
    var code: u8 = undefined;

    if (event_type == 0x6f) {
        if (sensor_type >= 0xC0 and sensor_type < 0xF0 and
            getOem(intf) == c.IPMI_OEM_KONTRON)
        {
            // check Kontron OEM sensor event types
            start = &c.oem_kontron_event_types;
        } else if (intf.?.vita_avail != 0) {
            // check VITA sensor event types first
            start = &c.vita_sensor_event_types;

            // then check generic sensor types
            next = &c.sensor_specific_event_types;
        } else {
            // check generic sensor types
            start = &c.sensor_specific_event_types;
        }
        code = sensor_type;
    } else {
        start = &c.generic_event_types;
        code = event_type;
    }

    var evt = start;
    while (evt.*.desc != null or next != null) : (evt += 1) {
        // check if VITA sensor event types has finished
        if (evt.*.desc == null) {
            // proceed with next table
            evt = next;
            next = null;
        }

        if (code == evt.*.code) {
            return evt;
        }
    }

    return null;
}

/// `ipmi_get_next_event_sensor_type()`.
fn getNextEventSensorType(
    evt_in: [*c]const EventSensorTypes,
) callconv(.c) [*c]const EventSensorTypes {
    const start = evt_in;

    var evt = start + 1;
    while (evt.*.desc != null) : (evt += 1) {
        if (evt.*.code == start.*.code) {
            return evt;
        }
    }

    return null;
}

/// `ipmi_get_event_desc()`: the description for one SEL record, malloc'ed for
/// the caller to free.
fn getEventDesc(intf: ?*Intf, rec: ?*SelEventRecord, desc: [*c][*c]u8) callconv(.c) void {
    // This is assigned when the platform is DELL/Supermicro/Quanta;
    // additional info is appended to the current description.
    var sfx: [*c]u8 = null;
    const r = rec.?;

    if (desc == null) {
        return;
    }
    desc.* = null;

    if (r.sel_type.standard_type.td.event_type >= 0x70 and
        r.sel_type.standard_type.td.event_type < 0x7F)
    {
        desc.* = getOemDesc(intf, rec);
        return;
    } else if (r.sel_type.standard_type.td.event_type == 0x6f) {
        if (r.sel_type.standard_type.sensor_type >= 0xC0 and
            r.sel_type.standard_type.sensor_type < 0xF0)
        {
            const iana = getOem(intf);

            switch (iana) {
                c.IPMI_OEM_KONTRON => c.lprintf(
                    log.Level.debug,
                    "oem sensor type %x %d using oem type supplied description",
                    @as(c_int, r.sel_type.standard_type.sensor_type),
                    iana,
                ),
                // OEM Bytes Decoding for DELL
                c.IPMI_OEM_DELL => {
                    if (c.OEM_CODE_IN_BYTE2 == (r.sel_type.standard_type.event_data[0] & c.DATA_BYTE2_SPECIFIED_MASK) or
                        c.OEM_CODE_IN_BYTE3 == (r.sel_type.standard_type.event_data[0] & c.DATA_BYTE3_SPECIFIED_MASK))
                    {
                        sfx = getOemDesc(intf, rec);
                    }
                },
                c.IPMI_OEM_SUPERMICRO, c.IPMI_OEM_SUPERMICRO_47488 => {
                    sfx = getOemDesc(intf, rec);
                },
                // add your oem sensor assignation here
                c.IPMI_OEM_QUANTA => {
                    sfx = getOemDesc(intf, rec);
                },
                else => c.lprintf(
                    log.Level.debug,
                    "oem sensor type %x  using standard type supplied description",
                    @as(c_int, r.sel_type.standard_type.sensor_type),
                ),
            }
        } else {
            switch (getOem(intf)) {
                c.IPMI_OEM_SUPERMICRO, c.IPMI_OEM_SUPERMICRO_47488 => {
                    sfx = getOemDesc(intf, rec);
                },
                c.IPMI_OEM_QUANTA => {
                    sfx = getOemDesc(intf, rec);
                },
                else => {},
            }
        }
        // Check for the OEM DELL Interface based on the Dell specific vendor
        // code.  If it is a Dell platform, do the OEM byte decode from the SEL
        // records.  Additional information should be written by getOemDesc().
        if (getOem(intf) == c.IPMI_OEM_DELL) {
            if (c.OEM_CODE_IN_BYTE2 == (r.sel_type.standard_type.event_data[0] & c.DATA_BYTE2_SPECIFIED_MASK) or
                c.OEM_CODE_IN_BYTE3 == (r.sel_type.standard_type.event_data[0] & c.DATA_BYTE3_SPECIFIED_MASK))
            {
                sfx = getOemDesc(intf, rec);
            } else if (c.SENSOR_TYPE_OEM_SEC_EVENT == r.sel_type.standard_type.event_data[0]) {
                // 0x23 : Sensor Number.
                if (0x23 == r.sel_type.standard_type.sensor_num) {
                    sfx = getOemDesc(intf, rec);
                }
            }
        }
    }

    const offset: u8 = r.sel_type.standard_type.event_data[0] & 0xf;

    var evt = getFirstEventSensorType(
        intf,
        r.sel_type.standard_type.sensor_type,
        r.sel_type.standard_type.td.event_type,
    );
    while (evt != null) : (evt = getNextEventSensorType(evt)) {
        if ((evt.*.offset == offset and evt.*.desc != null) and
            (evt.*.data == c.ALL_OFFSETS_SPECIFIED or
                ((r.sel_type.standard_type.event_data[0] & c.DATA_BYTE2_SPECIFIED_MASK) != 0 and
                    evt.*.data == r.sel_type.standard_type.event_data[1])))
        {
            // Increase the malloc size to current size + Dell specific size
            desc.* = @ptrCast(c.malloc(c.strlen(evt.*.desc) + 48 + size_of_desc));
            if (desc.* == null) {
                c.lprintf(log.Level.err, "ipmitool: malloc failure");
                return;
            }
            _ = c.memset(desc.*, 0, c.strlen(evt.*.desc) + 48 + size_of_desc);
            // Additional info is present for the DELL platforms; append it to
            // the evt->desc string.
            if (sfx != null) {
                _ = c.sprintf(desc.*, "%s (%s)", evt.*.desc, sfx);
                c.free(sfx);
                sfx = null;
            } else {
                _ = c.sprintf(desc.*, "%s", evt.*.desc);
            }
            return;
        }
    }
    // The above loop condition was not met because the below sensor types were
    // newly defined OEM secondary events: 0xC1, 0xC2, 0xC3.
    if (sfx != null and 0x6F == r.sel_type.standard_type.td.event_type) {
        var flag: u8 = 0x00;
        switch (r.sel_type.standard_type.sensor_type) {
            c.SENSOR_TYPE_FRM_PROG => {
                if (0x0F == offset) flag = 0x01;
            },
            c.SENSOR_TYPE_OEM_SEC_EVENT => {
                if (0x01 == offset or 0x02 == offset or 0x03 == offset) flag = 0x01;
            },
            c.SENSOR_TYPE_OEM_NFATAL_ERROR => {
                if (0x00 == offset or 0x02 == offset) flag = 0x01;
            },
            c.SENSOR_TYPE_OEM_FATAL_ERROR => {
                if (0x01 == offset) flag = 0x01;
            },
            c.SENSOR_TYPE_SUPERMICRO_OEM => {
                flag = 0x02;
            },
            else => {},
        }
        if (flag != 0) {
            desc.* = @ptrCast(c.malloc(48 + size_of_desc));
            if (desc.* == null) {
                c.lprintf(log.Level.err, "ipmitool: malloc failure");
                return;
            }
            _ = c.memset(desc.*, 0, 48 + size_of_desc);
            if (flag == 0x02) {
                // Upstream returns without freeing `sfx`.
                _ = c.sprintf(desc.*, "%s", sfx);
                return;
            }
            _ = c.sprintf(desc.*, "(%s)", sfx);
        }
        c.free(sfx);
        sfx = null;
    }
}

/// `ipmi_get_generic_sensor_type()`.
fn getGenericSensorType(code: u8) callconv(.c) [*c]const u8 {
    if (code <= c.SENSOR_TYPE_MAX) {
        return c.ipmi_generic_sensor_type_vals[code];
    }

    return null;
}

/// `ipmi_get_oem_sensor_type()`.
fn getOemSensorType(intf: ?*Intf, code: u8) callconv(.c) [*c]const u8 {
    var found: [*c]const c.struct_oemvalstr = null;
    const iana: u32 = getOem(intf);

    var v = c.ipmi_oem_sensor_type_vals;
    while (v.*.str != null) : (v += 1) {
        if (v.*.oem == iana and v.*.val == code) {
            return v.*.str;
        }

        if ((intf.?.picmg_avail != 0 and v.*.oem == c.IPMI_OEM_PICMG and v.*.val == code) or
            (intf.?.vita_avail != 0 and v.*.oem == c.IPMI_OEM_VITA and v.*.val == code))
        {
            found = v;
        }
    }

    return if (found != null) found.*.str else null;
}

/// `ipmi_get_sensor_type()`.
fn getSensorType(intf: ?*Intf, code: u8) callconv(.c) [*c]const u8 {
    var @"type": [*c]const u8 = undefined;

    if (code >= 0xC0) {
        @"type" = getOemSensorType(intf, code);
    } else {
        @"type" = getGenericSensorType(code);
    }

    if (@"type" == null) {
        @"type" = "Unknown";
    }

    return @"type";
}

// ---------------------------------------------------------------------------
// SDR field access
// ---------------------------------------------------------------------------

/// The `record` union of a `struct sdr_record_list`, as raw bytes.
fn sdrBytes(sdr: *const SdrRecordList) [*]const u8 {
    return sdr.record.?;
}

/// A NUL-terminated `id_string` inside an SDR record.
fn sdrIdString(sdr: *const SdrRecordList, off: usize) [*c]const u8 {
    return sdrBytes(sdr) + off;
}

fn sdrFull(sdr: *const SdrRecordList) ?*c.struct_sdr_record_full_sensor {
    return @ptrCast(@constCast(sdrBytes(sdr)));
}

/// `ipmi_sdr_get_unit_string(sdr->record.common->unit.pct,
/// sdr->record.common->unit.modifier, sdr->record.common->unit.type.base,
/// sdr->record.common->unit.type.modifier)`.  `unit` is a bitfield byte:
/// `pct:1`, `modifier:2`, `rate:3`, `analog:2`.
fn sdrUnitString(sdr: *const SdrRecordList) [*c]const u8 {
    const bytes = sdrBytes(sdr);
    const unit = bytes[sdr_off.common_unit];
    return c.ipmi_sdr_get_unit_string(
        (unit & 1) != 0,
        (unit >> 1) & 3,
        bytes[sdr_off.common_unit_base],
        bytes[sdr_off.common_unit_modifier],
    );
}

/// C's `(int)f == f` test that selects between `%.0f` and `%.2f`.
fn wholeNumber(v: f32) bool {
    return @trunc(v) == v;
}

// ---------------------------------------------------------------------------
// SEL info and record retrieval
// ---------------------------------------------------------------------------

/// `ipmi_sel_get_info()`.
fn selGetInfo(intf: *Intf) c_int {
    const fs: u32 = 0xffffffff;
    const zeros: u32 = 0;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_get_sel_info;

    var rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get SEL Info command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get SEL Info command failed: %s", ccString(rsp.ccode));
        return -1;
    } else if (rsp.data_len != 14) {
        c.lprintf(
            log.Level.err,
            "Get SEL Info command failed: Invalid data length %d",
            @as(c_int, rsp.data_len),
        );
        return -1;
    }
    if (verbose() > 2) {
        c.printbuf(&rsp.data, rsp.data_len, "sel_info");
    }

    _ = c.printf("SEL Information\n");
    const version: u16 = rsp.data[0];
    _ = c.printf(
        "Version          : %d.%d (%s)\n",
        @as(c_int, version & 0xf),
        @as(c_int, (version >> 4) & 0xf),
        pick(version == 0x51 or version == 0x02, "v1.5, v2 compliant", "Unknown"),
    );

    // save the entry count and free space to determine percent full
    var e: u16 = c.buf2short(&rsp.data[1]);
    var f: u32 = c.buf2short(&rsp.data[3]);
    _ = c.printf("Entries          : %d\n", @as(c_int, e));
    _ = c.printf("Free Space       : %d bytes %s\n", f, pick(f == 65535, "or more", ""));

    var pctfull: c_int = 0;
    if (e != 0) {
        // `e` is uint16_t, so the multiplication wraps modulo 65536.
        e = e *% 16;
        f +%= e;
        pctfull = @intFromFloat(100 * (@as(f64, @floatFromInt(e)) / @as(f64, @floatFromInt(f))));
    }

    if (f >= 65535) {
        _ = c.printf("Percent Used     : %s\n", "unknown");
    } else {
        _ = c.printf("Percent Used     : %d%%\n", pctfull);
    }

    if (c.memcmp(&rsp.data[5], &fs, 4) == 0 or c.memcmp(&rsp.data[5], &zeros, 4) == 0) {
        _ = c.printf("Last Add Time    : Not Available\n");
    } else {
        _ = c.printf("Last Add Time    : %s\n", c.ipmi_timestamp_numeric(c.buf2long(&rsp.data[5])));
    }

    if (c.memcmp(&rsp.data[9], &fs, 4) == 0 or c.memcmp(&rsp.data[9], &zeros, 4) == 0) {
        _ = c.printf("Last Del Time    : Not Available\n");
    } else {
        _ = c.printf("Last Del Time    : %s\n", c.ipmi_timestamp_numeric(c.buf2long(&rsp.data[9])));
    }

    _ = c.printf("Overflow         : %s\n", pick(rsp.data[13] & 0x80 != 0, "true", "false"));
    _ = c.printf("Supported Cmds   : ");
    if (rsp.data[13] & 0x0f != 0) {
        if (rsp.data[13] & 0x08 != 0) _ = c.printf("'Delete' ");
        if (rsp.data[13] & 0x04 != 0) _ = c.printf("'Partial Add' ");
        if (rsp.data[13] & 0x02 != 0) _ = c.printf("'Reserve' ");
        if (rsp.data[13] & 0x01 != 0) _ = c.printf("'Get Alloc Info' ");
    } else {
        _ = c.printf("None");
    }
    _ = c.printf("\n");

    // get sel allocation info if supported
    if (rsp.data[13] & 1 != 0) {
        req = std.mem.zeroes(Request);
        req.msg.netfn_lun.netfn = netfn_storage;
        req.msg.cmd = cmd_get_sel_alloc_info;

        rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.err, "Get SEL Allocation Info command failed");
            return -1;
        };
        if (rsp.ccode != 0) {
            c.lprintf(
                log.Level.err,
                "Get SEL Allocation Info command failed: %s",
                ccString(rsp.ccode),
            );
            return -1;
        }

        _ = c.printf("# of Alloc Units : %d\n", @as(c_int, c.buf2short(&rsp.data)));
        _ = c.printf("Alloc Unit Size  : %d\n", @as(c_int, c.buf2short(&rsp.data[2])));
        _ = c.printf("# Free Units     : %d\n", @as(c_int, c.buf2short(&rsp.data[4])));
        _ = c.printf("Largest Free Blk : %d\n", @as(c_int, c.buf2short(&rsp.data[6])));
        _ = c.printf("Max Record Size  : %d\n", @as(c_int, rsp.data[8]));
    }
    return 0;
}

/// `ipmi_sel_get_std_entry()`: fetch one record and unpack it.  Upstream never
/// checks `rsp->data_len`, so a short response is read past its end; that is
/// reproduced here.
fn getStdEntry(intf: ?*Intf, id: u16, evt: ?*SelEventRecord) callconv(.c) u16 {
    const in = intf.?;
    const e = evt.?;

    var msg_data: [6]u8 = @splat(0);
    msg_data[0] = 0x00; // no reserve id, not partial get
    msg_data[1] = 0x00;
    msg_data[2] = @intCast(id & 0xff);
    msg_data[3] = @intCast((id >> 8) & 0xff);
    msg_data[4] = 0x00; // offset
    msg_data[5] = 0xff; // length

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_get_sel_entry;
    req.msg.data = &msg_data;
    req.msg.data_len = 6;

    const rsp = sendrecv(in, &req) orelse {
        c.lprintf(log.Level.err, "Get SEL Entry %x command failed", @as(c_int, id));
        return 0;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get SEL Entry %x command failed: %s",
            @as(c_int, id),
            ccString(rsp.ccode),
        );
        return 0;
    }

    // save next entry id
    const next: u16 = (@as(u16, rsp.data[1]) << 8) | rsp.data[0];

    c.lprintf(
        log.Level.debug,
        "SEL Entry: %s",
        c.buf2str(&rsp.data[2], @as(c_int, rsp.data_len) - 2),
    );
    e.* = .{};

    // Upstream re-clears the structure field by field after `memset()`, having
    // just set `record_type` to zero, so only the first branch can be taken.
    e.record_id = 0;
    e.record_type = 0;
    if (e.record_type < 0xc0) {
        e.sel_type.standard_type.timestamp = 0;
        e.sel_type.standard_type.gen_id = 0;
        e.sel_type.standard_type.evm_rev = 0;
        e.sel_type.standard_type.sensor_type = 0;
        e.sel_type.standard_type.sensor_num = 0;
        e.sel_type.standard_type.td.event_type = 0;
        e.sel_type.standard_type.td.event_dir = 0;
        e.sel_type.standard_type.event_data[0] = 0;
        e.sel_type.standard_type.event_data[1] = 0;
        e.sel_type.standard_type.event_data[2] = 0;
    }

    // save response into SEL event structure
    e.record_id = (@as(u16, rsp.data[3]) << 8) | rsp.data[2];
    e.record_type = rsp.data[4];
    if (e.record_type < 0xc0) {
        e.sel_type.standard_type.timestamp = (@as(u32, rsp.data[8]) << 24) |
            (@as(u32, rsp.data[7]) << 16) |
            (@as(u32, rsp.data[6]) << 8) | rsp.data[5];
        e.sel_type.standard_type.gen_id = (@as(u16, rsp.data[10]) << 8) | rsp.data[9];
        e.sel_type.standard_type.evm_rev = rsp.data[11];
        e.sel_type.standard_type.sensor_type = rsp.data[12];
        e.sel_type.standard_type.sensor_num = rsp.data[13];
        e.sel_type.standard_type.td.event_type = @intCast(rsp.data[14] & 0x7f);
        e.sel_type.standard_type.td.event_dir = @intCast((rsp.data[14] & 0x80) >> 7);
        e.sel_type.standard_type.event_data[0] = rsp.data[15];
        e.sel_type.standard_type.event_data[1] = rsp.data[16];
        e.sel_type.standard_type.event_data[2] = rsp.data[17];
    } else if (e.record_type < 0xe0) {
        e.sel_type.oem_ts_type.timestamp = (@as(u32, rsp.data[8]) << 24) |
            (@as(u32, rsp.data[7]) << 16) |
            (@as(u32, rsp.data[6]) << 8) | rsp.data[5];
        e.sel_type.oem_ts_type.manf_id[0] = rsp.data[11];
        e.sel_type.oem_ts_type.manf_id[1] = rsp.data[10];
        e.sel_type.oem_ts_type.manf_id[2] = rsp.data[9];
        for (0..sel_oem_ts_data_len) |i| {
            e.sel_type.oem_ts_type.oem_defined[i] = rsp.data[i + 12];
        }
    } else {
        for (0..sel_oem_nots_data_len) |i| {
            e.sel_type.oem_nots_type.oem_defined[i] = rsp.data[i + 5];
        }
    }
    return next;
}

// ---------------------------------------------------------------------------
// Printers
// ---------------------------------------------------------------------------

/// `ipmi_sel_print_event_file()`.
fn printEventFile(intf: *Intf, evt: *SelEventRecord, fp: ?*c.FILE) void {
    if (fp == null) {
        return;
    }

    var description: [*c]u8 = null;
    getEventDesc(intf, evt, &description);

    _ = c.fprintf(
        fp,
        "0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x # %s #0x%02x %s\n",
        @as(c_int, evt.sel_type.standard_type.evm_rev),
        @as(c_int, evt.sel_type.standard_type.sensor_type),
        @as(c_int, evt.sel_type.standard_type.sensor_num),
        @as(c_int, evt.sel_type.standard_type.td.event_type) |
            (@as(c_int, evt.sel_type.standard_type.td.event_dir) << 7),
        @as(c_int, evt.sel_type.standard_type.event_data[0]),
        @as(c_int, evt.sel_type.standard_type.event_data[1]),
        @as(c_int, evt.sel_type.standard_type.event_data[2]),
        getSensorType(intf, evt.sel_type.standard_type.sensor_type),
        @as(c_int, evt.sel_type.standard_type.sensor_num),
        if (description != null) description else @as([*c]const u8, "Unknown"),
    );

    if (description != null) {
        c.free(description);
        description = null;
    }
}

/// `ipmi_sel_print_extended_entry()`.
fn printExtendedEntry(intf: ?*Intf, evt: ?*SelEventRecord) callconv(.c) void {
    sel_extended += 1;
    printStdEntry(intf, evt);
    sel_extended -= 1;
}

/// `ipmi_sel_print_std_entry()`.
fn printStdEntry(intf: ?*Intf, evt: ?*SelEventRecord) callconv(.c) void {
    var sdr: ?*SdrRecordList = null;

    // Upstream dereferences `evt` here, before its own NULL check below.
    if (sel_extended != 0 and evt.?.record_type < 0xc0) {
        sdr = @ptrCast(c.ipmi_sdr_find_sdr_bynumtype(
            cIntf(intf.?),
            evt.?.sel_type.standard_type.gen_id,
            evt.?.sel_type.standard_type.sensor_num,
            evt.?.sel_type.standard_type.sensor_type,
        ));
    }

    if (evt == null) {
        return;
    }
    const e = evt.?;

    if (csvOutput()) {
        _ = c.printf("%x,", @as(c_int, e.record_id));
    } else {
        _ = c.printf("%4x | ", @as(c_int, e.record_id));
    }

    if (e.record_type == 0xf0) {
        if (csvOutput()) {
            _ = c.printf(",,");
        }
        _ = c.printf("Linux kernel panic: %.11s\n", @as([*c]const u8, @ptrCast(e)) + 5);
        return;
    }

    if (e.record_type < 0xe0) {
        // Both union arms alias the same `uint32_t`; the second test is
        // redundant, and reproduced as written.
        if (e.sel_type.standard_type.timestamp < 0x20000000 or
            e.sel_type.oem_ts_type.timestamp < 0x20000000)
        {
            _ = c.printf(" Pre-Init ");

            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf(" |");
            }

            _ = c.printf("%010d", @as(c_int, @bitCast(e.sel_type.standard_type.timestamp)));
            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf("| ");
            }
        } else {
            if (e.record_type < 0xc0) {
                _ = c.printf("%s", c.ipmi_timestamp_date(e.sel_type.standard_type.timestamp));
            } else {
                _ = c.printf("%s", c.ipmi_timestamp_date(e.sel_type.oem_ts_type.timestamp));
            }

            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf(" | ");
            }

            if (e.record_type < 0xc0) {
                _ = c.printf("%s", c.ipmi_timestamp_time(e.sel_type.standard_type.timestamp));
            } else {
                _ = c.printf("%s", c.ipmi_timestamp_time(e.sel_type.oem_ts_type.timestamp));
            }

            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf(" | ");
            }
        }
    } else {
        if (csvOutput()) {
            _ = c.printf(",,");
        }
    }

    if (e.record_type >= 0xc0) {
        _ = c.printf("OEM record %02x", @as(c_int, e.record_type));
        if (csvOutput()) {
            _ = c.printf(",");
        } else {
            _ = c.printf(" | ");
        }

        if (e.record_type <= 0xdf) {
            _ = c.printf(
                "%02x%02x%02x",
                @as(c_int, e.sel_type.oem_ts_type.manf_id[0]),
                @as(c_int, e.sel_type.oem_ts_type.manf_id[1]),
                @as(c_int, e.sel_type.oem_ts_type.manf_id[2]),
            );
            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf(" | ");
            }
            for (0..sel_oem_ts_data_len) |i| {
                _ = c.printf("%02x", @as(c_int, e.sel_type.oem_ts_type.oem_defined[i]));
            }
        } else {
            for (0..sel_oem_nots_data_len) |i| {
                _ = c.printf("%02x", @as(c_int, e.sel_type.oem_nots_type.oem_defined[i]));
            }
        }
        oemMessage(e);
        _ = c.printf("\n");
        return;
    }

    // lookup SDR entry based on sensor number and type
    if (sdr) |s| {
        _ = c.printf("%s ", getSensorType(intf, e.sel_type.standard_type.sensor_type));
        switch (s.type) {
            c.SDR_RECORD_TYPE_FULL_SENSOR => _ = c.printf("%s", sdrIdString(s, sdr_off.full_id_string)),
            c.SDR_RECORD_TYPE_COMPACT_SENSOR => _ = c.printf("%s", sdrIdString(s, sdr_off.compact_id_string)),
            c.SDR_RECORD_TYPE_EVENTONLY_SENSOR => _ = c.printf("%s", sdrIdString(s, sdr_off.eventonly_id_string)),
            c.SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => _ = c.printf("%s", sdrIdString(s, sdr_off.fruloc_id_string)),
            c.SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => _ = c.printf("%s", sdrIdString(s, sdr_off.mcloc_id_string)),
            c.SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => _ = c.printf("%s", sdrIdString(s, sdr_off.genloc_id_string)),
            else => _ = c.printf("#%02x", @as(c_int, e.sel_type.standard_type.sensor_num)),
        }
    } else {
        _ = c.printf("%s", getSensorType(intf, e.sel_type.standard_type.sensor_type));
        if (e.sel_type.standard_type.sensor_num != 0) {
            _ = c.printf(" #0x%02x", @as(c_int, e.sel_type.standard_type.sensor_num));
        }
    }

    if (csvOutput()) {
        _ = c.printf(",");
    } else {
        _ = c.printf(" | ");
    }

    var description: [*c]u8 = null;
    getEventDesc(intf, e, &description);
    if (description != null) {
        _ = c.printf("%s", description);
        c.free(description);
        description = null;
    }

    if (csvOutput()) {
        _ = c.printf(",");
    } else {
        _ = c.printf(" | ");
    }

    if (e.sel_type.standard_type.td.event_dir != 0) {
        _ = c.printf("Deasserted");
    } else {
        _ = c.printf("Asserted");
    }

    if (sdr != null and e.sel_type.standard_type.td.event_type == 1) {
        // Threshold Event.  Upstream does not check `sdr->type` here, so a
        // non-full SDR is reinterpreted as a full one.
        const s = sdr.?;
        var trigger_reading: f32 = 0.0;
        var threshold_reading: f32 = 0.0;
        var threshold_reading_provided: u8 = 0;

        // trigger reading in event data byte 2
        if (((e.sel_type.standard_type.event_data[0] >> 6) & 3) == 1) {
            trigger_reading = @floatCast(c.sdr_convert_sensor_reading(
                sdrFull(s),
                e.sel_type.standard_type.event_data[1],
            ));
        }

        // trigger threshold in event data byte 3
        if (((e.sel_type.standard_type.event_data[0] >> 4) & 3) == 1) {
            threshold_reading = @floatCast(c.sdr_convert_sensor_reading(
                sdrFull(s),
                e.sel_type.standard_type.event_data[2],
            ));
            threshold_reading_provided = 1;
        }

        if (csvOutput()) {
            _ = c.printf(",");
        } else {
            _ = c.printf(" | ");
        }

        _ = c.printf(
            "Reading %.*f",
            @as(c_int, if (wholeNumber(trigger_reading)) 0 else 2),
            @as(f64, trigger_reading),
        );
        if (threshold_reading_provided != 0) {
            // According to Table 29-6, Event Data byte 1 contains, among other
            // info, the offset from the Threshold type code.  According to
            // Table 42-2, all even offsets are 'going low', and all odd
            // offsets are 'going high'.
            var going_high: bool =
                (e.sel_type.standard_type.event_data[0] & event_offset_mask) % 2 != 0;
            if (e.sel_type.standard_type.td.event_dir != 0) {
                // Event is de-asserted so the inequality is reversed
                going_high = !going_high;
            }
            _ = c.printf(
                " %s Threshold %.*f %s",
                pick(going_high, ">", "<"),
                @as(c_int, if (wholeNumber(threshold_reading)) 0 else 2),
                @as(f64, threshold_reading),
                sdrUnitString(s),
            );
        }
    } else if (e.sel_type.standard_type.td.event_type == 0x6f) {
        var print_sensor: c_int = 1;
        switch (getOem(intf)) {
            c.IPMI_OEM_SUPERMICRO, c.IPMI_OEM_SUPERMICRO_47488 => print_sensor = 0,
            c.IPMI_OEM_QUANTA => print_sensor = 0,
            else => {},
        }
        // Sensor-Specific Discrete
        if (print_sensor != 0 and e.sel_type.standard_type.sensor_type == 0xC and
            e.sel_type.standard_type.sensor_num == 0 and
            (e.sel_type.standard_type.event_data[0] & 0x30) == 0x20)
        {
            // break down memory ECC reporting if we can
            if (csvOutput()) {
                _ = c.printf(",");
            } else {
                _ = c.printf(" | ");
            }

            _ = c.printf(
                "CPU %d DIMM %d",
                @as(c_int, e.sel_type.standard_type.event_data[2] & 0x0f),
                @as(c_int, (e.sel_type.standard_type.event_data[2] & 0xf0) >> 4),
            );
        }
    }

    _ = c.printf("\n");
}

/// `ipmi_sel_print_std_entry_verbose()`.
fn printStdEntryVerbose(intf: ?*Intf, evt: ?*SelEventRecord) callconv(.c) void {
    if (evt == null) {
        return;
    }
    const e = evt.?;

    _ = c.printf("SEL Record ID          : %04x\n", @as(c_int, e.record_id));

    if (e.record_type == 0xf0) {
        _ = c.printf(
            " Record Type           : Linux kernel panic (OEM record %02x)\n",
            @as(c_int, e.record_type),
        );
        _ = c.printf(" Panic string          : %.11s\n\n", @as([*c]const u8, @ptrCast(e)) + 5);
        return;
    }

    _ = c.printf(" Record Type           : %02x", @as(c_int, e.record_type));
    if (e.record_type >= 0xc0) {
        if (e.record_type < 0xe0) {
            _ = c.printf("  (OEM timestamped)");
        } else {
            _ = c.printf("  (OEM non-timestamped)");
        }
    }
    _ = c.printf("\n");

    if (e.record_type < 0xe0) {
        _ = c.printf(" Timestamp             : ");
        if (e.record_type < 0xc0) {
            _ = c.printf("%s ", c.ipmi_timestamp_date(e.sel_type.standard_type.timestamp));
            _ = c.printf("%s\n", c.ipmi_timestamp_time(e.sel_type.standard_type.timestamp));
        } else {
            _ = c.printf("%s ", c.ipmi_timestamp_date(e.sel_type.oem_ts_type.timestamp));
            _ = c.printf("%s\n", c.ipmi_timestamp_time(e.sel_type.oem_ts_type.timestamp));
        }
    }

    if (e.record_type >= 0xc0) {
        if (e.record_type <= 0xdf) {
            _ = c.printf(
                " Manufactacturer ID    : %02x%02x%02x\n",
                @as(c_int, e.sel_type.oem_ts_type.manf_id[0]),
                @as(c_int, e.sel_type.oem_ts_type.manf_id[1]),
                @as(c_int, e.sel_type.oem_ts_type.manf_id[2]),
            );
            _ = c.printf(" OEM Defined           : ");
            for (0..sel_oem_ts_data_len) |i| {
                _ = c.printf("%02x", @as(c_int, e.sel_type.oem_ts_type.oem_defined[i]));
            }
            _ = c.printf(" [%s]\n\n", hex2ascii(
                &e.sel_type.oem_ts_type.oem_defined,
                sel_oem_ts_data_len,
            ));
        } else {
            _ = c.printf(" OEM Defined           : ");
            for (0..sel_oem_nots_data_len) |i| {
                _ = c.printf("%02x", @as(c_int, e.sel_type.oem_nots_type.oem_defined[i]));
            }
            _ = c.printf(" [%s]\n\n", hex2ascii(
                &e.sel_type.oem_nots_type.oem_defined,
                sel_oem_nots_data_len,
            ));
            oemMessage(e);
        }
        return;
    }

    _ = c.printf(" Generator ID          : %04x\n", @as(c_int, e.sel_type.standard_type.gen_id));
    _ = c.printf(" EvM Revision          : %02x\n", @as(c_int, e.sel_type.standard_type.evm_rev));
    _ = c.printf(" Sensor Type           : %s\n", getSensorType(intf, e.sel_type.standard_type.sensor_type));
    _ = c.printf(" Sensor Number         : %02x\n", @as(c_int, e.sel_type.standard_type.sensor_num));
    _ = c.printf(" Event Type            : %s\n", getEventType(e.sel_type.standard_type.td.event_type));
    _ = c.printf(" Event Direction       : %s\n", c.val2str(e.sel_type.standard_type.td.event_dir, &event_dir_vals));
    _ = c.printf(
        " Event Data            : %02x%02x%02x\n",
        @as(c_int, e.sel_type.standard_type.event_data[0]),
        @as(c_int, e.sel_type.standard_type.event_data[1]),
        @as(c_int, e.sel_type.standard_type.event_data[2]),
    );
    var description: [*c]u8 = null;
    getEventDesc(intf, e, &description);
    _ = c.printf(
        " Description           : %s\n",
        if (description != null) description else @as([*c]const u8, ""),
    );
    c.free(description);
    description = null;

    _ = c.printf("\n");
}

/// `ipmi_sel_print_extended_entry_verbose()`.
fn printExtendedEntryVerbose(intf: ?*Intf, evt: ?*SelEventRecord) callconv(.c) void {
    if (evt == null) {
        return;
    }
    const e = evt.?;

    const sdr: ?*SdrRecordList = @ptrCast(c.ipmi_sdr_find_sdr_bynumtype(
        cIntf(intf.?),
        e.sel_type.standard_type.gen_id,
        e.sel_type.standard_type.sensor_num,
        e.sel_type.standard_type.sensor_type,
    ));
    if (sdr == null) {
        printStdEntryVerbose(intf, evt);
        return;
    }
    const s = sdr.?;

    _ = c.printf("SEL Record ID          : %04x\n", @as(c_int, e.record_id));

    if (e.record_type == 0xf0) {
        _ = c.printf(
            " Record Type           : Linux kernel panic (OEM record %02x)\n",
            @as(c_int, e.record_type),
        );
        _ = c.printf(" Panic string          : %.11s\n\n", @as([*c]const u8, @ptrCast(e)) + 5);
        return;
    }

    _ = c.printf(" Record Type           : %02x\n", @as(c_int, e.record_type));
    if (e.record_type < 0xe0) {
        _ = c.printf(" Timestamp             : ");
        _ = c.printf("%s ", c.ipmi_timestamp_date(e.sel_type.standard_type.timestamp));
        _ = c.printf("%s\n", c.ipmi_timestamp_time(e.sel_type.standard_type.timestamp));
    }

    _ = c.printf(" Generator ID          : %04x\n", @as(c_int, e.sel_type.standard_type.gen_id));
    _ = c.printf(" EvM Revision          : %02x\n", @as(c_int, e.sel_type.standard_type.evm_rev));
    _ = c.printf(" Sensor Type           : %s\n", getSensorType(intf, e.sel_type.standard_type.sensor_type));
    _ = c.printf(" Sensor Number         : %02x\n", @as(c_int, e.sel_type.standard_type.sensor_num));
    _ = c.printf(" Event Type            : %s\n", getEventType(e.sel_type.standard_type.td.event_type));
    _ = c.printf(" Event Direction       : %s\n", c.val2str(e.sel_type.standard_type.td.event_dir, &event_dir_vals));
    _ = c.printf(
        " Event Data (RAW)      : %02x%02x%02x\n",
        @as(c_int, e.sel_type.standard_type.event_data[0]),
        @as(c_int, e.sel_type.standard_type.event_data[1]),
        @as(c_int, e.sel_type.standard_type.event_data[2]),
    );

    // break down event data field as per IPMI Spec 2.0 Table 29-6
    if (e.sel_type.standard_type.td.event_type == 1 and
        s.type == c.SDR_RECORD_TYPE_FULL_SENSOR)
    {
        // Threshold
        switch ((e.sel_type.standard_type.event_data[0] >> 6) & 3) { // EV1[7:6]
            0 => {}, // unspecified byte 2
            1 => {
                // trigger reading in byte 2
                _ = c.printf(" Trigger Reading       : %.3f", c.sdr_convert_sensor_reading(
                    sdrFull(s),
                    e.sel_type.standard_type.event_data[1],
                ));
                // determine units with possible modifiers
                _ = c.printf("%s\n", sdrUnitString(s));
            },
            2 => _ = c.printf(
                " OEM Data              : %02x\n",
                @as(c_int, e.sel_type.standard_type.event_data[1]),
            ),
            3 => _ = c.printf(
                " Sensor Extension Code : %02x\n",
                @as(c_int, e.sel_type.standard_type.event_data[1]),
            ),
            else => unreachable,
        }
        switch ((e.sel_type.standard_type.event_data[0] >> 4) & 3) { // EV1[5:4]
            0 => {}, // unspecified byte 3
            1 => {
                // trigger threshold value in byte 3
                _ = c.printf(" Trigger Threshold     : %.3f", c.sdr_convert_sensor_reading(
                    sdrFull(s),
                    e.sel_type.standard_type.event_data[2],
                ));
                _ = c.printf("%s\n", sdrUnitString(s));
            },
            2 => _ = c.printf(
                " OEM Data              : %02x\n",
                @as(c_int, e.sel_type.standard_type.event_data[2]),
            ),
            3 => _ = c.printf(
                " Sensor Extension Code : %02x\n",
                @as(c_int, e.sel_type.standard_type.event_data[2]),
            ),
            else => unreachable,
        }
    } else if (e.sel_type.standard_type.td.event_type >= 0x2 and
        e.sel_type.standard_type.td.event_type <= 0xc)
    {
        // Generic Discrete
    } else if (e.sel_type.standard_type.td.event_type == 0x6f) {
        // Sensor-Specific Discrete
        if (e.sel_type.standard_type.sensor_type == 0xC and
            e.sel_type.standard_type.sensor_num == 0 and
            (e.sel_type.standard_type.event_data[0] & 0x30) == 0x20)
        {
            // break down memory ECC reporting if we can
            _ = c.printf(
                " Event Data            : CPU %d DIMM %d\n",
                @as(c_int, e.sel_type.standard_type.event_data[2] & 0x0f),
                @as(c_int, (e.sel_type.standard_type.event_data[2] & 0xf0) >> 4),
            );
        } else if (e.sel_type.standard_type.sensor_type == 0x2b and // Version change
            e.sel_type.standard_type.event_data[0] == 0xC1) // Data in Data 2
        {
            // Upstream body is empty.
        } else {
            // FIXME : Add sensor specific discrete types
            _ = c.printf(" Event Interpretation  : Missing\n");
        }
    } else if (e.sel_type.standard_type.td.event_type >= 0x70 and
        e.sel_type.standard_type.td.event_type <= 0x7f)
    {
        // OEM
    } else {
        _ = c.printf(
            " Event Data            : %02x%02x%02x\n",
            @as(c_int, e.sel_type.standard_type.event_data[0]),
            @as(c_int, e.sel_type.standard_type.event_data[1]),
            @as(c_int, e.sel_type.standard_type.event_data[2]),
        );
    }

    var description: [*c]u8 = null;
    getEventDesc(intf, e, &description);
    _ = c.printf(
        " Description           : %s\n",
        if (description != null) description else @as([*c]const u8, ""),
    );
    c.free(description);
    description = null;

    _ = c.printf("\n");
}

// ---------------------------------------------------------------------------
// Listing and saving
// ---------------------------------------------------------------------------

/// C's implicit narrowing of a `long` into a small unsigned field.
fn narrow(comptime T: type, v: c_long) T {
    return @truncate(@as(u64, @bitCast(@as(i64, v))));
}

/// `__ipmi_sel_savelist_entries()`.
fn savelistEntries(intf: *Intf, count_in: c_int, savefile: [*c]const u8, binary: c_int) c_int {
    var count = count_in;
    var next_id: u16 = 0;
    var curr_id: u16 = 0;
    var evt: SelEventRecord = undefined;
    var n: c_int = 0;
    var fp: ?*c.FILE = null;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_get_sel_info;

    var rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get SEL Info command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get SEL Info command failed: %s", ccString(rsp.ccode));
        return -1;
    }
    if (verbose() > 2) {
        c.printbuf(&rsp.data, rsp.data_len, "sel_info");
    }

    if (rsp.data[1] == 0 and rsp.data[2] == 0) {
        c.lprintf(log.Level.err, "SEL has no entries");
        return 0;
    }

    if (count < 0) {
        // Show only the most recent 'count' records.
        req.msg.cmd = cmd_get_sel_info;
        rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.err, "Get SEL Info command failed");
            return -1;
        };
        if (rsp.ccode != 0) {
            c.lprintf(log.Level.err, "Get SEL Info command failed: %s", ccString(rsp.ccode));
            return -1;
        }
        const entries: u16 = c.buf2short(&rsp.data[1]);
        if (-count > entries) {
            count = -@as(c_int, entries);
        }

        var i: c_int = 0;
        while (i < @as(c_int, entries) + count) : (i += 1) {
            next_id = getStdEntry(intf, next_id, &evt);
            if (next_id == 0) {
                // usually next_id of zero means end but retry because some
                // hardware has quirks and will return 0 randomly.
                next_id = getStdEntry(intf, next_id, &evt);
                if (next_id == 0) {
                    break;
                }
            }
        }
    }

    if (savefile != null) {
        fp = c.ipmi_open_file_write(savefile);
    }

    while (next_id != 0xffff) {
        curr_id = next_id;
        c.lprintf(log.Level.debug, "SEL Next ID: %04x", @as(c_int, curr_id));

        next_id = getStdEntry(intf, curr_id, &evt);
        if (next_id == 0) {
            // usually next_id of zero means end but retry because some
            // hardware has quirks and will return 0 randomly.
            next_id = getStdEntry(intf, curr_id, &evt);
            if (next_id == 0) {
                break;
            }
        }

        if (verbose() != 0) {
            printStdEntryVerbose(intf, &evt);
        } else {
            printStdEntry(intf, &evt);
        }

        if (fp) |f| {
            if (binary != 0) {
                _ = c.fwrite(&evt, 1, 16, f);
            } else {
                printEventFile(intf, &evt, f);
            }
        }

        n += 1;
        if (n == count) {
            break;
        }
    }

    if (fp) |f| {
        _ = c.fclose(f);
    }

    return 0;
}

/// `ipmi_sel_list_entries()`.
fn listEntries(intf: *Intf, count: c_int) c_int {
    return savelistEntries(intf, count, null, 0);
}

/// `ipmi_sel_save_entries()`.
fn saveEntries(intf: *Intf, count: c_int, savefile: [*c]const u8) c_int {
    return savelistEntries(intf, count, savefile, 0);
}

/// `ipmi_sel_interpret()`.  Upstream leaves `evt` uninitialised and never fills
/// in the timestamp (its own `FIXME`), so the successful path prints stack
/// garbage; that is reproduced here.
fn selInterpret(
    intf: *Intf,
    iana: c_ulong,
    readfile: [*c]const u8,
    format: [*c]const u8,
) c_int {
    var evt: SelEventRecord = undefined;
    var buffer: [*c]u8 = null;
    var cursor: [*c]u8 = null;
    var status: c_int = 0;
    // since the interface is not used, iana is taken from the command line
    sel_iana = @intCast(iana);
    if (c.strcmp("pps", format) == 0) {
        // Parser for the following format:
        // 0x001F: Event: at Mar 27 06:41:10 2007;from:(0x9a,0,7);
        // sensor:(0xc3,119); event:0x6f(asserted): 0xA3 0x00 0x88
        // commonly found in PPS shelf managers.
        const fp = c.ipmi_open_file(readfile, 0);
        if (fp == null) {
            c.lprintf(log.Level.err, "Failed to open file '%s' for reading.", readfile);
            return -1;
        }
        buffer = @ptrCast(c.malloc(256));
        if (buffer == null) {
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
            _ = c.fclose(fp);
            return -1;
        }
        while (true) {
            // Only allow complete lines to be parsed, hardcoded maximum line
            // length.
            if (c.fgets(buffer, 256, fp) == null) {
                status = -1;
                break;
            }
            // `fgets()` above caps the line at 255 characters, so this test can
            // never fire.
            if (c.strlen(buffer) > 255) {
                c.lprintf(log.Level.err, "ipmitool: invalid entry found in file.");
                if (status != 0) break;
                continue;
            }
            cursor = buffer;
            // assume normal "System" event
            evt.record_type = 2;
            setErrno(0);
            evt.record_id = narrow(u16, c.strtol(cursor, null, 16));
            if (errno() != 0) {
                c.lprintf(log.Level.err, "Invalid record ID.");
                status = -1;
                break;
            }
            evt.sel_type.standard_type.evm_rev = 4;

            // FIXME: convert
            // evt.sel_type.standard_type.timestamp;

            // skip timestamp
            cursor = advance(c.index(cursor, ';'), 1);

            // FIXME: parse originator
            evt.sel_type.standard_type.gen_id = 0x0020;

            // skip originator info
            cursor = advance(c.index(cursor, ';'), 1);

            // Get sensor type
            cursor = advance(c.index(cursor, '('), 1);

            setErrno(0);
            evt.sel_type.standard_type.sensor_type = narrow(u8, c.strtol(cursor, null, 16));
            if (errno() != 0) {
                c.lprintf(log.Level.err, "Invalid Sensor Type.");
                status = -1;
                break;
            }
            cursor = advance(c.index(cursor, ','), 1);

            setErrno(0);
            evt.sel_type.standard_type.sensor_num = narrow(u8, c.strtol(cursor, null, 10));
            if (errno() != 0) {
                c.lprintf(log.Level.err, "Invalid Sensor Number.");
                status = -1;
                break;
            }

            // skip to event type info
            cursor = advance(c.index(cursor, ':'), 1);

            setErrno(0);
            evt.sel_type.standard_type.td.event_type = narrow(u7, c.strtol(cursor, null, 16));
            if (errno() != 0) {
                c.lprintf(log.Level.err, "Invalid Event Type.");
                status = -1;
                break;
            }

            // skip to event dir info
            cursor = advance(c.index(cursor, '('), 1);
            if (cursor[0] == 'a') {
                evt.sel_type.standard_type.td.event_dir = 0;
            } else {
                evt.sel_type.standard_type.td.event_dir = 1;
            }
            // skip to data info
            cursor = advance(c.index(cursor, ' '), 1);

            if (evt.sel_type.standard_type.sensor_type == 0xF0) {
                // got to FRU id
                while (c.isdigit(cursor[0]) == 0) {
                    cursor += 1;
                }
                // store FRUid
                setErrno(0);
                evt.sel_type.standard_type.event_data[2] = narrow(u8, c.strtol(cursor, null, 10));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#2.");
                    status = -1;
                    break;
                }

                // Get to previous state
                cursor = advance(c.index(cursor, 'M'), 1);

                // Set previous state
                setErrno(0);
                evt.sel_type.standard_type.event_data[1] = narrow(u8, c.strtol(cursor, null, 10));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#1.");
                    status = -1;
                    break;
                }

                // Get to current state
                cursor = advance(c.index(cursor, 'M'), 1);

                // Set current state
                setErrno(0);
                evt.sel_type.standard_type.event_data[0] =
                    0xA0 | narrow(u8, c.strtol(cursor, null, 10));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#0.");
                    status = -1;
                    break;
                }

                // skip to cause
                cursor = advance(c.index(cursor, '='), 1);
                setErrno(0);
                evt.sel_type.standard_type.event_data[1] |=
                    narrow(u8, c.strtol(cursor, null, 16) << 4);
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#1.");
                    status = -1;
                    break;
                }
            } else if (cursor[0] == '0') {
                setErrno(0);
                evt.sel_type.standard_type.event_data[0] = narrow(u8, c.strtol(cursor, null, 16));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#0.");
                    status = -1;
                    break;
                }
                cursor = advance(c.index(cursor, ' '), 1);

                setErrno(0);
                evt.sel_type.standard_type.event_data[1] = narrow(u8, c.strtol(cursor, null, 16));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#1.");
                    status = -1;
                    break;
                }

                cursor = advance(c.index(cursor, ' '), 1);

                setErrno(0);
                evt.sel_type.standard_type.event_data[2] = narrow(u8, c.strtol(cursor, null, 16));
                if (errno() != 0) {
                    c.lprintf(log.Level.err, "Invalid Event Data#2.");
                    status = -1;
                    break;
                }
            } else {
                c.lprintf(log.Level.err, "ipmitool: can't guess format.");
            }
            // parse the PPS line into a sel_event_record
            if (verbose() != 0) {
                printStdEntryVerbose(intf, &evt);
            } else {
                printStdEntry(intf, &evt);
            }
            cursor = null;
            if (status != 0) break; // until file is completely read
        }
        cursor = null;
        c.free(buffer);
        buffer = null;
        _ = c.fclose(fp);
    } else {
        c.lprintf(log.Level.err, "Given format '%s' is unknown.", format);
        status = -1;
    }
    return status;
}

/// `ipmi_sel_writeraw()`.
fn selWriteraw(intf: *Intf, savefile: [*c]const u8) c_int {
    return savelistEntries(intf, 0, savefile, 1);
}

/// `ipmi_sel_readraw()`.
fn selReadraw(intf: *Intf, inputfile: [*c]const u8) c_int {
    var evt: SelEventRecord = undefined;
    var ret: c_int = 0;

    const fp = c.ipmi_open_file(inputfile, 0);
    if (fp != null) {
        while (true) {
            const bytes_read = c.fread(&evt, 1, 16, fp);
            if (bytes_read == 16) {
                if (verbose() != 0) {
                    printStdEntryVerbose(intf, &evt);
                } else {
                    printStdEntry(intf, &evt);
                }
            } else {
                if (bytes_read != 0) {
                    c.lprintf(log.Level.err, "ipmitool: incomplete record found in file.");
                    ret = -1;
                }
                break;
            }
        }
        _ = c.fclose(fp);
    } else {
        c.lprintf(log.Level.err, "ipmitool: could not open input file.");
        ret = -1;
    }
    return ret;
}

/// `ipmi_sel_reserve()`.
fn selReserve(intf: *Intf) u16 {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_reserve_sel;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.warn, "Unable to reserve SEL");
        return 0;
    };
    if (rsp.ccode != 0) {
        _ = c.printf("Unable to reserve SEL: %s", ccString(rsp.ccode));
        return 0;
    }

    return @as(u16, rsp.data[0]) | (@as(u16, rsp.data[1]) << 8);
}

/// `ipmi_sel_get_time()`.
fn selGetTime(intf: *Intf) c_int {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_get_sel_time;

    const rsp = sendrecv(intf, &req);

    if (rsp == null or rsp.?.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Get SEL Time command failed: %s",
            if (rsp != null) ccString(rsp.?.ccode) else @as([*c]const u8, "Unknown"),
        );
        return -1;
    }
    if (rsp.?.data_len != 4) {
        c.lprintf(
            log.Level.err,
            "Get SEL Time command failed: Invalid data length %d",
            @as(c_int, rsp.?.data_len),
        );
        return -1;
    }

    const t: c.time_t = c.ipmi32toh(&rsp.?.data);
    _ = c.printf("%s\n", c.ipmi_timestamp_numeric(@intCast(t)));

    return 0;
}

/// `ipmi_sel_set_time()`.
fn selSetTime(intf: *Intf, time_string: [*c]const u8) c_int {
    var tm = std.mem.zeroes(c.struct_tm);
    var msg_data: [4]u8 = @splat(0);
    var t: c.time_t = undefined;
    const time_format = "%x %X"; // Use locale-defined format

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_set_sel_time;

    // See if user requested set to current client system time
    if (c.strcasecmp(time_string, "now") == 0) {
        t = c.time(null);
        // Now we have local time in t, but BMC requires UTC
        t = c.ipmi_localtime2utc(t);
    } else {
        var err = true; // Assume the string is invalid
        // Now let's extract time_t from the supplied string
        if (c.strptime(time_string, time_format, &tm) != null) {
            tm.tm_isdst = -1; // look up DST information
            t = c.mktime(&tm);
            if (t >= 0) {
                // Surprisingly, the user hasn't mistaken ;)
                err = false;
            }
        }

        if (err) {
            c.lprintf(log.Level.err, "Specified time could not be parsed");
            return -1;
        }

        // If `-c` wasn't specified then t we've just got is in local timezone
        if (!c.time_in_utc) {
            t = c.ipmi_localtime2utc(t);
        }
    }

    // At this point `t` is UTC.  Convert it to LE and send.
    req.msg.data = &msg_data;
    c.htoipmi32(@truncate(@as(u64, @bitCast(t))), req.msg.data);
    req.msg.data_len = msg_data.len;

    const rsp = sendrecv(intf, &req);
    if (rsp == null or rsp.?.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Set SEL Time command failed: %s",
            if (rsp != null) ccString(rsp.?.ccode) else @as([*c]const u8, "Unknown"),
        );
        return -1;
    }

    _ = selGetTime(intf);

    return 0;
}

/// `ipmi_sel_clear()`.
fn selClear(intf: *Intf) c_int {
    const reserve_id = selReserve(intf);
    if (reserve_id == 0) {
        return -1;
    }

    var msg_data: [6]u8 = @splat(0);
    msg_data[0] = @truncate(reserve_id & 0xff);
    msg_data[1] = @truncate(reserve_id >> 8);
    msg_data[2] = 'C';
    msg_data[3] = 'L';
    msg_data[4] = 'R';
    msg_data[5] = 0xaa;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = cmd_clear_sel;
    req.msg.data = &msg_data;
    req.msg.data_len = 6;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Unable to clear SEL");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Unable to clear SEL: %s", ccString(rsp.ccode));
        return -1;
    }

    _ = c.printf("Clearing SEL.  Please allow a few seconds to erase.\n");
    return 0;
}

/// `ipmi_sel_delete()`.
fn selDelete(intf: *Intf, argc_in: c_int, argv: [*c][*c]u8) c_int {
    var argc = argc_in;
    var rc: c_int = 0;

    if (argc == 0 or eql(@ptrCast(argv[0]), "help")) {
        c.lprintf(log.Level.err, "usage: delete <id>...<id>\n");
        return -1;
    }

    var id = selReserve(intf);
    if (id == 0) {
        return -1;
    }

    var msg_data: [4]u8 = @splat(0);
    msg_data[0] = @truncate(id & 0xff);
    msg_data[1] = @truncate(id >> 8);

    while (argc != 0) : (argc -= 1) {
        if (c.str2ushort(argv[@intCast(argc - 1)], &id) != 0) {
            c.lprintf(
                log.Level.err,
                "Given SEL ID '%s' is invalid.",
                argv[@intCast(argc - 1)],
            );
            rc = -1;
            continue;
        }
        msg_data[2] = @truncate(id & 0xff);
        msg_data[3] = @truncate(id >> 8);

        var req = std.mem.zeroes(Request);
        req.msg.netfn_lun.netfn = netfn_storage;
        req.msg.cmd = cmd_delete_sel_entry;
        req.msg.data = &msg_data;
        req.msg.data_len = 4;

        const rsp = sendrecv(intf, &req);
        if (rsp == null) {
            c.lprintf(log.Level.err, "Unable to delete entry %d", @as(c_int, id));
            rc = -1;
        } else if (rsp.?.ccode != 0) {
            c.lprintf(
                log.Level.err,
                "Unable to delete entry %d: %s",
                @as(c_int, id),
                ccString(rsp.?.ccode),
            );
            rc = -1;
        } else {
            _ = c.printf("Deleted entry %d\n", @as(c_int, id));
        }
    }

    return rc;
}

/// `ipmi_sel_show_entry()`.  Upstream leaves `entity.logical` uninitialised;
/// `ipmi_sdr_find_sdr_byentity()` never reads it, so zero here is unobservable.
fn selShowEntry(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    var entity: EntityId = .{};
    var evt: SelEventRecord = undefined;
    var rc: c_int = 0;
    var id: u16 = undefined;

    if (argc == 0 or eql(@ptrCast(argv[0]), "help")) {
        c.lprintf(log.Level.err, "usage: sel get <id>...<id>");
        return -1;
    }

    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (c.str2ushort(argv[@intCast(i)], &id) != 0) {
            c.lprintf(log.Level.err, "Given SEL ID '%s' is invalid.", argv[@intCast(i)]);
            rc = -1;
            continue;
        }

        c.lprintf(log.Level.debug, "Looking up SEL entry 0x%x", @as(c_int, id));

        // lookup SEL entry based on ID
        if (getStdEntry(intf, id, &evt) == 0) {
            c.lprintf(log.Level.debug, "SEL Entry 0x%x not found.", @as(c_int, id));
            rc = -1;
            continue;
        }
        if (evt.sel_type.standard_type.sensor_num == 0 and
            evt.sel_type.standard_type.sensor_type == 0 and
            evt.record_type == 0)
        {
            c.lprintf(log.Level.warn, "SEL Entry 0x%x not found", @as(c_int, id));
            rc = -1;
            continue;
        }

        // lookup SDR entry based on sensor number and type
        printExtendedEntryVerbose(intf, &evt);

        const sdr: ?*SdrRecordList = @ptrCast(c.ipmi_sdr_find_sdr_bynumtype(
            cIntf(intf),
            evt.sel_type.standard_type.gen_id,
            evt.sel_type.standard_type.sensor_num,
            evt.sel_type.standard_type.sensor_type,
        ));
        const s = sdr orelse continue;

        // print SDR entry
        const oldv = c.verbose;
        c.verbose = if (c.verbose != 0) c.verbose else 1;
        switch (s.type) {
            c.SDR_RECORD_TYPE_FULL_SENSOR, c.SDR_RECORD_TYPE_COMPACT_SENSOR => {
                _ = c.ipmi_sensor_print_fc(
                    cIntf(intf),
                    @ptrCast(@constCast(sdrBytes(s))),
                    s.type,
                );
                entity.id = sdrBytes(s)[sdr_off.common_entity_id];
                entity.instance_logical.instance =
                    @truncate(sdrBytes(s)[sdr_off.common_entity_instance]);
            },
            c.SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                _ = c.ipmi_sdr_print_sensor_eventonly(
                    cIntf(intf),
                    @ptrCast(@constCast(sdrBytes(s))),
                );
                entity.id = sdrBytes(s)[sdr_off.eventonly_entity_id];
                entity.instance_logical.instance =
                    @truncate(sdrBytes(s)[sdr_off.eventonly_entity_instance]);
            },
            else => {
                c.verbose = oldv;
                continue;
            },
        }
        c.verbose = oldv;

        // lookup SDR entry based on entity id
        const list: ?*SdrRecordList = @ptrCast(c.ipmi_sdr_find_sdr_byentity(
            cIntf(intf),
            @ptrCast(&entity),
        ));
        var entry = list;
        while (entry) |e| : (entry = e.next) {
            // print FRU devices we find for this entity
            if (e.type == c.SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR) {
                _ = c.ipmi_fru_print(cIntf(intf), @ptrCast(@constCast(sdrBytes(e))));
            }
        }

        if (argc > 1 and i < argc - 1) {
            _ = c.printf("----------------------\n\n");
        }
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

/// `ipmi_sel_main()`.
fn selMain(intf: ?*Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    var rc: c_int = 0;
    const in = intf.?;

    if (argc == 0) {
        rc = selGetInfo(in);
    } else if (eql(@ptrCast(argv[0]), "help")) {
        c.lprintf(
            log.Level.err,
            "SEL Commands:  info clear delete list elist get add time save readraw writeraw interpret",
        );
    } else if (eql(@ptrCast(argv[0]), "interpret")) {
        var iana: u32 = 0;
        if (argc < 4) {
            c.lprintf(log.Level.notice, "usage: sel interpret iana filename format(pps)");
            return 0;
        }
        if (c.str2uint(argv[1], &iana) != 0) {
            c.lprintf(log.Level.err, "Given IANA '%s' is invalid.", argv[1]);
            return -1;
        }
        rc = selInterpret(in, iana, argv[2], argv[3]);
    } else if (eql(@ptrCast(argv[0]), "info")) {
        rc = selGetInfo(in);
    } else if (eql(@ptrCast(argv[0]), "save")) {
        if (argc < 2) {
            c.lprintf(log.Level.notice, "usage: sel save <filename>");
            return 0;
        }
        rc = saveEntries(in, 0, argv[1]);
    } else if (eql(@ptrCast(argv[0]), "add")) {
        if (argc < 2) {
            c.lprintf(log.Level.notice, "usage: sel add <filename>");
            return 0;
        }
        rc = selAddEntriesFromfile(in, argv[1]);
    } else if (eql(@ptrCast(argv[0]), "writeraw")) {
        if (argc < 2) {
            c.lprintf(log.Level.notice, "usage: sel writeraw <filename>");
            return 0;
        }
        rc = selWriteraw(in, argv[1]);
    } else if (eql(@ptrCast(argv[0]), "readraw")) {
        if (argc < 2) {
            c.lprintf(log.Level.notice, "usage: sel readraw <filename>");
            return 0;
        }
        rc = selReadraw(in, argv[1]);
    } else if (eql(@ptrCast(argv[0]), "ereadraw")) {
        if (argc < 2) {
            c.lprintf(log.Level.notice, "usage: sel ereadraw <filename>");
            return 0;
        }
        sel_extended = 1;
        rc = selReadraw(in, argv[1]);
    } else if (eql(@ptrCast(argv[0]), "list") or eql(@ptrCast(argv[0]), "elist")) {
        // Usage:
        //   list           - show all SEL entries
        //   list first <n> - show the first (oldest) <n> SEL entries
        //   list last <n>  - show the last (newest) <n> SEL entries
        var count: c_int = 0;
        var sign: c_int = 1;
        var countstr: [*c]u8 = null;

        if (eql(@ptrCast(argv[0]), "elist")) {
            sel_extended = 1;
        } else {
            sel_extended = 0;
        }

        if (argc == 2) {
            countstr = argv[1];
        } else if (argc == 3) {
            countstr = argv[2];

            if (eql(@ptrCast(argv[1]), "last")) {
                sign = -1;
            } else if (!eql(@ptrCast(argv[1]), "first")) {
                c.lprintf(log.Level.err, "Unknown sel list option");
                return -1;
            }
        }

        if (countstr != null) {
            if (c.str2int(countstr, &count) != 0) {
                c.lprintf(
                    log.Level.err,
                    "Numeric argument required; got '%s'",
                    countstr,
                );
                return -1;
            }
        }
        count *= sign;

        rc = listEntries(in, count);
    } else if (eql(@ptrCast(argv[0]), "clear")) {
        rc = selClear(in);
    } else if (eql(@ptrCast(argv[0]), "delete")) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "usage: sel delete <id>...<id>");
        } else {
            rc = selDelete(in, argc - 1, argv + 1);
        }
    } else if (eql(@ptrCast(argv[0]), "get")) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "usage: sel get <entry>");
        } else {
            rc = selShowEntry(in, argc - 1, argv + 1);
        }
    } else if (eql(@ptrCast(argv[0]), "time")) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "sel time commands: get set");
        } else if (eql(@ptrCast(argv[1]), "get")) {
            _ = selGetTime(in);
        } else if (eql(@ptrCast(argv[1]), "set")) {
            if (argc < 3) {
                c.lprintf(log.Level.err, "usage: sel time set \"mm/dd/yyyy hh:mm:ss\"");
            } else {
                rc = selSetTime(in, argv[2]);
            }
        } else {
            c.lprintf(log.Level.err, "sel time commands: get set");
        }
    } else {
        c.lprintf(log.Level.err, "Invalid SEL command: %s", argv[0]);
        rc = -1;
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Exports
// ---------------------------------------------------------------------------

pub fn exportSymbols() void {
    comptime {
        abi.assertOpaqueLayout(SelEventRecord, .{
            .size = c.ABI_SIZEOF_sel_event_record,
            .alignment = c.ABI_ALIGNOF_sel_event_record,
            .fields = &.{
                .{ .name = "record_id", .offset = c.ABI_OFFSETOF_sel_event_record__record_id },
                .{ .name = "record_type", .offset = c.ABI_OFFSETOF_sel_event_record__record_type },
                .{ .name = "sel_type", .offset = c.ABI_OFFSETOF_sel_event_record__sel_type },
            },
        });
        abi.assertOpaqueLayout(EntityId, .{
            .size = c.ABI_SIZEOF_entity_id,
            .alignment = c.ABI_ALIGNOF_entity_id,
            .fields = &.{
                .{ .name = "id", .offset = c.ABI_OFFSETOF_entity_id__id },
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

        abi.assertCallSignature(@TypeOf(selMain), @TypeOf(c.ipmi_sel_main));
        @export(&selMain, .{ .name = "ipmi_sel_main", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printStdEntry), @TypeOf(c.ipmi_sel_print_std_entry));
        @export(&printStdEntry, .{ .name = "ipmi_sel_print_std_entry", .linkage = .strong });

        abi.assertCallSignature(
            @TypeOf(printStdEntryVerbose),
            @TypeOf(c.ipmi_sel_print_std_entry_verbose),
        );
        @export(&printStdEntryVerbose, .{
            .name = "ipmi_sel_print_std_entry_verbose",
            .linkage = .strong,
        });

        abi.assertCallSignature(
            @TypeOf(printExtendedEntry),
            @TypeOf(c.ipmi_sel_print_extended_entry),
        );
        @export(&printExtendedEntry, .{
            .name = "ipmi_sel_print_extended_entry",
            .linkage = .strong,
        });

        abi.assertCallSignature(
            @TypeOf(printExtendedEntryVerbose),
            @TypeOf(c.ipmi_sel_print_extended_entry_verbose),
        );
        @export(&printExtendedEntryVerbose, .{
            .name = "ipmi_sel_print_extended_entry_verbose",
            .linkage = .strong,
        });

        abi.assertCallSignature(@TypeOf(getEventDesc), @TypeOf(c.ipmi_get_event_desc));
        @export(&getEventDesc, .{ .name = "ipmi_get_event_desc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorType), @TypeOf(c.ipmi_get_sensor_type));
        @export(&getSensorType, .{ .name = "ipmi_get_sensor_type", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getStdEntry), @TypeOf(c.ipmi_sel_get_std_entry));
        @export(&getStdEntry, .{ .name = "ipmi_sel_get_std_entry", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getVikingEvtDesc), @TypeOf(c.get_viking_evt_desc));
        @export(&getVikingEvtDesc, .{ .name = "get_viking_evt_desc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getKontronEvtDesc), @TypeOf(c.get_kontron_evt_desc));
        @export(&getKontronEvtDesc, .{ .name = "get_kontron_evt_desc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getDellEvtDesc), @TypeOf(c.get_dell_evt_desc));
        @export(&getDellEvtDesc, .{ .name = "get_dell_evt_desc", .linkage = .strong });

        abi.assertCallSignature(
            @TypeOf(getSupermicroEvtDesc),
            @TypeOf(c.get_supermicro_evt_desc),
        );
        @export(&getSupermicroEvtDesc, .{
            .name = "get_supermicro_evt_desc",
            .linkage = .strong,
        });

        abi.assertCallSignature(@TypeOf(getOem), @TypeOf(c.ipmi_get_oem));
        @export(&getOem, .{ .name = "ipmi_get_oem", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getOemDesc), @TypeOf(c.ipmi_get_oem_desc));
        @export(&getOemDesc, .{ .name = "ipmi_get_oem_desc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(selOemInit), @TypeOf(c.ipmi_sel_oem_init));
        @export(&selOemInit, .{ .name = "ipmi_sel_oem_init", .linkage = .strong });

        abi.assertCallSignature(
            @TypeOf(getFirstEventSensorType),
            @TypeOf(c.ipmi_get_first_event_sensor_type),
        );
        @export(&getFirstEventSensorType, .{
            .name = "ipmi_get_first_event_sensor_type",
            .linkage = .strong,
        });

        abi.assertCallSignature(
            @TypeOf(getNextEventSensorType),
            @TypeOf(c.ipmi_get_next_event_sensor_type),
        );
        @export(&getNextEventSensorType, .{
            .name = "ipmi_get_next_event_sensor_type",
            .linkage = .strong,
        });

        abi.assertCallSignature(
            @TypeOf(getGenericSensorType),
            @TypeOf(c.ipmi_get_generic_sensor_type),
        );
        @export(&getGenericSensorType, .{
            .name = "ipmi_get_generic_sensor_type",
            .linkage = .strong,
        });

        abi.assertCallSignature(
            @TypeOf(getOemSensorType),
            @TypeOf(c.ipmi_get_oem_sensor_type),
        );
        @export(&getOemSensorType, .{
            .name = "ipmi_get_oem_sensor_type",
            .linkage = .strong,
        });

        @export(&sel_oem_msg, .{ .name = "sel_oem_msg", .linkage = .strong });
    }
}
