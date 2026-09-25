//! Staged port of `lib/ipmi_fru.c`. Inventory reads, section-aware writes,
//! print/list (including SDR discovery, area strings and multirecords), get,
//! upgEkey and internal-use commands are implemented here. The PICMG
//! extension decoder, edit and public FRU helpers still use the original C
//! code through `fru_legacy.c`, not placeholders. Keep the shim until all
//! commands and exported helpers have been ported.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const Allocator = std.mem.Allocator;
const Request = ipmi.Request;
const Response = ipmi.Response;

const Info = struct {
    size: u16,
    access: bool,
    max_read: usize = 0,
};

const ReadError = error{ OutOfRange, InvalidMaxSize, Failed, ShortResponse };

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn equals(a: [*c]u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(a))), b);
}

fn validFilename(path: [*c]u8) bool {
    if (path == null) {
        c.lprintf(log.Level.err, "ERROR: NULL pointer passed.");
        return false;
    }
    const length = c.strlen(path);
    if (length < 1) {
        c.lprintf(log.Level.err, "File/path is invalid.");
        return false;
    }
    if (length >= 512) {
        c.lprintf(log.Level.err, "File/path must be shorter than 512 bytes.");
        return false;
    }
    return true;
}

/// Read FRU Inventory Area Info, validating the three bytes before decoding
/// them. A malformed response must never read stale transport-buffer contents.
fn getInfo(intf: *Intf, id: u8) ?Info {
    var data = [1]u8{id};
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &data;
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse return null;
    if (rsp.ccode != 0) {
        if (rsp.ccode == c.IPMI_CC_TIMEOUT)
            _ = c.printf("  Timeout accessing FRU info. (Device not present?)\n");
        return null;
    }
    if (rsp.data_len < 3) {
        c.lprintf(log.Level.err, "FRU info response too short");
        return null;
    }
    return .{
        .size = @as(u16, rsp.data[0]) | (@as(u16, rsp.data[1]) << 8),
        .access = (rsp.data[2] & 1) != 0,
    };
}

fn isTooLarge(code: u8) bool {
    return code == c.IPMI_CC_REQ_DATA_INV_LENGTH or
        code == c.IPMI_CC_REQ_DATA_FIELD_EXCEED or
        code == c.IPMI_CC_CANT_RET_NUM_REQ_BYTES;
}

/// `read_fru_area()`'s request-size, retry and offset rules, using a bounded
/// destination slice. Callers choose whether a failed transfer is fatal.
fn readArea(intf: *Intf, id: u8, info: *Info, offset: usize, dest: []u8) ReadError!void {
    if (offset > info.size) {
        c.lprintf(log.Level.err, "Read FRU Area offset incorrect: %d > %d", @as(c_int, @intCast(offset)), @as(c_int, info.size));
        return error.OutOfRange;
    }
    const finish = @min(offset + dest.len, @as(usize, info.size));
    if (offset + dest.len > info.size) {
        c.lprintf(
            log.Level.notice,
            "Read FRU Area length %d too large, Adjusting to %d",
            @as(c_int, @intCast(offset + dest.len)),
            @as(c_int, @intCast(finish - offset)),
        );
    }

    if (info.max_read == 0) {
        const max_response = c.ipmi_intf_get_max_response_data_size(cIntf(intf));
        if (max_response <= 2) {
            c.lprintf(log.Level.@"error", "Maximum response size is too small to send a read request");
            return error.InvalidMaxSize;
        }
        info.max_read = @min(@as(usize, max_response) - 2, 255);
        if (info.access) info.max_read &= ~@as(usize, 1);
        if (info.max_read == 0) return error.InvalidMaxSize;
    }

    var request_data: [4]u8 = .{ id, 0, 0, 0 };
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data = &request_data;
    req.msg.data_len = request_data.len;

    var off = offset;
    while (true) {
        const wire_offset: usize = if (info.access) off >> 1 else off;
        request_data[1] = @truncate(wire_offset);
        request_data[2] = @truncate(wire_offset >> 8);
        request_data[3] = @intCast(@min(finish - off, info.max_read));

        const rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.notice, "FRU Read failed");
            return error.Failed;
        };
        if (rsp.ccode != 0) {
            if (isTooLarge(rsp.ccode) and info.max_read > 8) {
                info.max_read -= if (info.max_read > 32) 8 else 1;
                c.lprintf(log.Level.info, "Retrying FRU read with request size %d", @as(c_int, @intCast(info.max_read)));
                continue;
            }
            c.lprintf(log.Level.notice, "FRU Read failed: %s", c.val2str(rsp.ccode, c.completion_code_vals));
            return error.Failed;
        }

        const data_len: usize = if (rsp.data_len < 0) 0 else @intCast(rsp.data_len);
        if (data_len < 1) {
            _ = c.printf(" Not enough buffer size");
            return error.ShortResponse;
        }
        const count: usize = if (info.access) @as(usize, rsp.data[0]) << 1 else rsp.data[0];
        if (count > data_len - 1 or count > finish - off) {
            _ = c.printf(" Not enough buffer size");
            return error.ShortResponse;
        }
        @memcpy(dest[off - offset ..][0..count], rsp.data[1..][0..count]);
        off += count;
        if (off >= finish or count == 0) return;
    }
}

const bcd_plus = "0123456789 -.:,_";
const chassis_types = [_][*:0]const u8{
    "Unspecified",           "Other",              "Unknown",             "Desktop",            "Low Profile Desktop",
    "Pizza Box",             "Mini Tower",         "Tower",               "Portable",           "LapTop",
    "Notebook",              "Hand Held",          "Docking Station",     "All in One",         "Sub Notebook",
    "Space-saving",          "Lunch Box",          "Main Server Chassis", "Expansion Chassis",  "SubChassis",
    "Bus Expansion Chassis", "Peripheral Chassis", "RAID Chassis",        "Rack Mount Chassis", "Sealed-case PC",
    "Multi-system Chassis",  "CompactPCI",         "AdvancedTCA",         "Blade",              "Blade Enclosure",
};

/// Decode one FRU type/length field without accepting an out-of-area read.
/// `storage` belongs to the caller, so each value lives exactly as long as
/// the corresponding printf; the C implementation allocates every field.
fn field(area: []const u8, pos: *usize, storage: *[128]u8) []const u8 {
    if (pos.* >= area.len) return "";
    const descriptor = area[pos.*];
    pos.* += 1;
    const format = descriptor >> 6;
    const len: usize = descriptor & 0x3f;
    if (area.len - pos.* < len) {
        pos.* = area.len;
        return "";
    }
    const raw = area[pos.*..][0..len];
    pos.* += len;
    var output_len: usize = 0;
    switch (format) {
        0 => {
            const hex = "0123456789abcdef";
            for (raw) |byte| {
                storage[output_len] = hex[byte >> 4];
                storage[output_len + 1] = hex[byte & 0xf];
                output_len += 2;
            }
        },
        1 => {
            for (raw) |byte| {
                storage[output_len] = bcd_plus[byte >> 4];
                storage[output_len + 1] = bcd_plus[byte & 0xf];
                output_len += 2;
            }
        },
        2 => {
            var at: usize = 0;
            while (at < raw.len) : (at += 3) {
                var bits: u32 = 0;
                for (raw[at..@min(at + 3, raw.len)], 0..) |byte, shift|
                    bits |= @as(u32, byte) << @as(u5, @intCast(shift * 8));
                for (0..4) |_| {
                    storage[output_len] = @as(u8, @truncate(bits & 0x3f)) + 0x20;
                    output_len += 1;
                    bits >>= 6;
                }
            }
        },
        3 => {
            @memcpy(storage[0..len], raw);
            output_len = len;
        },
        else => unreachable,
    }
    return storage[0 .. std.mem.indexOfScalar(u8, storage[0..output_len], 0) orelse output_len];
}

fn showField(area: []const u8, pos: *usize, comptime format: [*:0]const u8, require_verbose: bool) void {
    var storage: [128]u8 = undefined;
    const text = field(area, pos, &storage);
    if (text.len == 0 or (require_verbose and c.verbose == 0)) return;
    _ = c.printf(format, @as(c_int, @intCast(text.len)), text.ptr);
}

const AreaKind = enum { chassis, board, product };

fn areaPrint(intf: *Intf, id: u8, info: *Info, offset: usize, kind: AreaKind, allocator: Allocator) void {
    var length_bytes: [2]u8 = .{ 0, 0 };
    readArea(intf, id, info, offset, &length_bytes) catch return;
    const area_len: usize = @as(usize, length_bytes[1]) * 8;
    if (area_len == 0) return;
    const area = allocator.alloc(u8, area_len) catch {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return;
    };
    defer allocator.free(area);
    @memset(area, 0);
    readArea(intf, id, info, offset, area) catch return;

    var pos: usize = if (kind == .board) 6 else 3;
    switch (kind) {
        .chassis => {
            if (area.len < 3) return;
            const index: usize = if (area[2] < chassis_types.len) area[2] else 2;
            _ = c.printf(" Chassis Type          : %s\n", chassis_types[index]);
            showField(area, &pos, " Chassis Part Number   : %.*s\n", false);
            showField(area, &pos, " Chassis Serial        : %.*s\n", false);
        },
        .board => {
            if (area.len < 6) return;
            const minutes: u32 = @as(u32, area[3]) |
                (@as(u32, area[4]) << 8) |
                (@as(u32, area[5]) << 16);
            const date: u32 = if (minutes == 0) c.IPMI_TIME_UNSPECIFIED else minutes * 60 + 820454400;
            _ = c.printf(" Board Mfg Date        : %s\n", c.ipmi_timestamp_string(date));
            showField(area, &pos, " Board Mfg             : %.*s\n", false);
            showField(area, &pos, " Board Product         : %.*s\n", false);
            showField(area, &pos, " Board Serial          : %.*s\n", false);
            showField(area, &pos, " Board Part Number     : %.*s\n", false);
            showField(area, &pos, " Board FRU ID          : %.*s\n", true);
        },
        .product => {
            if (area.len < 3) return;
            showField(area, &pos, " Product Manufacturer  : %.*s\n", false);
            showField(area, &pos, " Product Name          : %.*s\n", false);
            showField(area, &pos, " Product Part Number   : %.*s\n", false);
            showField(area, &pos, " Product Version       : %.*s\n", false);
            showField(area, &pos, " Product Serial        : %.*s\n", false);
            showField(area, &pos, " Product Asset Tag     : %.*s\n", false);
            showField(area, &pos, " Product FRU ID        : %.*s\n", true);
        },
    }

    const extra_format: [*:0]const u8 = switch (kind) {
        .chassis => " Chassis Extra         : %.*s\n",
        .board => " Board Extra           : %.*s\n",
        .product => " Product Extra         : %.*s\n",
    };
    while (pos < area.len and area[pos] != c.FRU_END_OF_FIELDS) {
        const previous = pos;
        var storage: [128]u8 = undefined;
        const text = field(area, &pos, &storage);
        if (text.len != 0)
            _ = c.printf(extra_format, @as(c_int, @intCast(text.len)), text.ptr);
        if (pos == previous) break;
    }

    var checksum: u8 = 0;
    for (area) |byte| checksum +%= byte;
    _ = c.printf(switch (kind) {
        .chassis => " Chassis Area Checksum : %s\n",
        .board => " Board Area Checksum   : %s\n",
        .product => " Product Area Checksum : %s\n",
    }, if (checksum == 0) @as([*:0]const u8, "OK") else @as([*:0]const u8, "INVALID"));
}

fn le16(data: []const u8) u16 {
    return @as(u16, data[0]) | @as(u16, data[1]) << 8;
}

fn signed16(data: []const u8) i16 {
    return @bitCast(le16(data));
}

fn showMultirecord(body: []const u8, record_type: u8, buffer: *[260]u8) void {
    switch (record_type) {
        c.FRU_RECORD_TYPE_POWER_SUPPLY_INFORMATION => {
            if (body.len < 24) return;
            const capacity = le16(body[0..2]) & 0x0fff;
            const peak = le16(body[18..20]);
            const voltages = [_][*:0]const u8{ "12 V", "-12 V", "5 V", "3.3 V" };
            _ = c.printf(" Power Supply Record\n");
            _ = c.printf("  Capacity                   : %d W\n", @as(c_int, capacity));
            _ = c.printf("  Peak VA                    : %d VA\n", @as(c_int, le16(body[2..4])));
            _ = c.printf("  Inrush Current             : %d A\n", @as(c_int, body[4]));
            _ = c.printf("  Inrush Interval            : %d ms\n", @as(c_int, body[5]));
            _ = c.printf("  Input Voltage Range 1      : %d-%d V\n", @as(c_int, le16(body[6..8]) / 100), @as(c_int, le16(body[8..10]) / 100));
            _ = c.printf("  Input Voltage Range 2      : %d-%d V\n", @as(c_int, le16(body[10..12]) / 100), @as(c_int, le16(body[12..14]) / 100));
            _ = c.printf("  Input Frequency Range      : %d-%d Hz\n", @as(c_int, body[14]), @as(c_int, body[15]));
            _ = c.printf("  A/C Dropout Tolerance      : %d ms\n", @as(c_int, body[16]));
            const flags = body[17];
            const predictive = (flags & 1) != 0;
            _ = c.printf("  Flags                      : %s%s%s%s%s\n", if (predictive) @as([*:0]const u8, "'Predictive fail' ") else @as([*:0]const u8, ""), if ((flags & 2) != 0) @as([*:0]const u8, "'Power factor correction' ") else @as([*:0]const u8, ""), if ((flags & 4) != 0) @as([*:0]const u8, "'Autoswitch voltage' ") else @as([*:0]const u8, ""), if ((flags & 8) != 0) @as([*:0]const u8, "'Hot swap' ") else @as([*:0]const u8, ""), if (predictive) (if (body[23] != 0) (if ((flags & 16) != 0) @as([*:0]const u8, "'Two pulses per rotation'") else @as([*:0]const u8, "'One pulse per rotation'")) else (if ((flags & 16) != 0) @as([*:0]const u8, "'Failure on pin de-assertion'") else @as([*:0]const u8, "'Failure on pin assertion'"))) else @as([*:0]const u8, ""));
            _ = c.printf("  Peak capacity              : %d W\n", @as(c_int, peak & 0x0fff));
            _ = c.printf("  Peak capacity holdup       : %d s\n", @as(c_int, peak >> 12));
            const combined_capacity = le16(body[21..23]);
            if (combined_capacity == 0)
                _ = c.printf("  Combined capacity          : not specified\n")
            else
                _ = c.printf("  Combined capacity          : %d W (%s and %s)\n", @as(c_int, combined_capacity), voltages[(body[20] >> 4) & 3], voltages[body[20] & 3]);
            if (predictive) _ = c.printf("  Fan lower threshold        : %d RPS\n", @as(c_int, body[23]));
        },
        c.FRU_RECORD_TYPE_DC_OUTPUT => {
            if (body.len < 13) return;
            _ = c.printf(" DC Output Record\n");
            _ = c.printf("  Output Number              : %d\n", @as(c_int, body[0] & 0xf));
            _ = c.printf("  Standby power              : %s\n", if ((body[0] & 0x80) != 0) @as([*:0]const u8, "Yes") else @as([*:0]const u8, "No"));
            _ = c.printf("  Nominal voltage            : %.2f V\n", @as(f64, @floatFromInt(signed16(body[1..3]))) / 100);
            _ = c.printf("  Max negative deviation     : %.2f V\n", @as(f64, @floatFromInt(signed16(body[3..5]))) / 100);
            _ = c.printf("  Max positive deviation     : %.2f V\n", @as(f64, @floatFromInt(signed16(body[5..7]))) / 100);
            _ = c.printf("  Ripple and noise pk-pk     : %d mV\n", @as(c_int, le16(body[7..9])));
            _ = c.printf("  Minimum current draw       : %.3f A\n", @as(f64, @floatFromInt(le16(body[9..11]))) / 1000);
            _ = c.printf("  Maximum current draw       : %.3f A\n", @as(f64, @floatFromInt(le16(body[11..13]))) / 1000);
        },
        c.FRU_RECORD_TYPE_DC_LOAD => {
            if (body.len < 13) return;
            _ = c.printf(" DC Load Record\n");
            _ = c.printf("  Output Number              : %d\n", @as(c_int, body[0] & 0xf));
            _ = c.printf("  Nominal voltage            : %.2f V\n", @as(f64, @floatFromInt(signed16(body[1..3]))) / 100);
            _ = c.printf("  Min voltage allowed        : %.2f V\n", @as(f64, @floatFromInt(signed16(body[3..5]))) / 100);
            _ = c.printf("  Max voltage allowed        : %.2f V\n", @as(f64, @floatFromInt(signed16(body[5..7]))) / 100);
            _ = c.printf("  Ripple and noise pk-pk     : %d mV\n", @as(c_int, le16(body[7..9])));
            _ = c.printf("  Minimum current load       : %.3f A\n", @as(f64, @floatFromInt(le16(body[9..11]))) / 1000);
            _ = c.printf("  Maximum current load       : %.3f A\n", @as(f64, @floatFromInt(le16(body[11..13]))) / 1000);
        },
        c.FRU_RECORD_TYPE_OEM_EXTENSION => {
            if (body.len < 3) return;
            const iana: u32 = @as(u32, body[0]) | (@as(u32, body[1]) << 8) | (@as(u32, body[2]) << 16);
            if (iana == c.IPMI_OEM_PICMG) {
                _ = c.printf("  PICMG Extension Record\n");
                c.ipmi_fru_zig_picmg_print(buffer, 5, @intCast(body.len));
            } else {
                _ = c.printf("  OEM (%s) Record\n", c.val2str(iana, c.ipmi_oem_info));
            }
        },
        c.FRU_RECORD_TYPE_MANAGEMENT_ACCESS => {
            if (body.len < 1) return;
            const subtype = body[0];
            const names = [_][*:0]const u8{
                "",                         "System Management URL", "System Name",            "System Ping Address",
                "Component Management URL", "Component Name",        "Component Ping Address", "System Unique ID",
            };
            const minimum = [_]usize{ 0, 16, 8, 8, 16, 8, 8, 16 };
            const maximum = [_]usize{ 0, 256, 64, 64, 256, 64, 64, 16 };
            if (subtype < 1 or subtype >= names.len) {
                c.lprintf(log.Level.warn, "Unsupported subtype 0x%02x found for multi-record area management record\n", @as(c_uint, subtype));
                return;
            }
            const text = body[1..];
            if (text.len < minimum[subtype] or text.len > maximum[subtype])
                c.lprintf(log.Level.warn, "Wrong data length %zu, must be %zu < X < %zu\n", text.len, minimum[subtype], maximum[subtype]);
            var value: [257]u8 = @splat(0);
            if (subtype == 7) {
                if (text.len < 16) return;
                _ = c.ipmi_guid2str(&value, text.ptr, c.GUID_AUTO);
            } else {
                @memcpy(value[0..text.len], text);
            }
            _ = c.printf(" %-22s: %s\n", names[subtype], &value);
        },
        else => {},
    }
}

fn multirecordPrint(intf: *Intf, id: u8, info: *Info, offset: usize) void {
    var record: [260]u8 = @splat(0);
    var off = offset;
    while (true) {
        readArea(intf, id, info, off, record[0..5]) catch break;
        const body_len: usize = record[2];
        if (body_len != 0)
            readArea(intf, id, info, off + 5, record[5..][0..body_len]) catch break;
        off += 5 + body_len;
        showMultirecord(record[5..][0..body_len], record[0], &record);
        if ((record[1] & 0x80) != 0 or off >= info.size) break;
    }
    c.lprintf(log.Level.debug, "Multi-Record area ends at: %i (%xh)", @as(c_int, @intCast(off)), @as(c_uint, @intCast(off)));
}

/// `__ipmi_fru_print()` for builtin and SDR-located FRU devices.
fn printFru(intf: *Intf, id: u8, allocator: Allocator) c_int {
    var info_data = [1]u8{id};
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &info_data;
    req.msg.data_len = 1;

    const info_rsp = sendrecv(intf, &req) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return -1;
    };
    if (info_rsp.ccode != 0) {
        _ = c.printf(" Device not present (%s)\n", c.val2str(info_rsp.ccode, c.completion_code_vals));
        return -1;
    }
    if (info_rsp.data_len < 3) {
        c.lprintf(log.Level.err, "FRU info response too short");
        return -1;
    }
    var info = Info{
        .size = @as(u16, info_rsp.data[0]) | (@as(u16, info_rsp.data[1]) << 8),
        .access = (info_rsp.data[2] & 1) != 0,
    };
    c.lprintf(log.Level.debug, "fru.size = %d bytes (accessed by %s)", @as(c_int, info.size), if (info.access) @as([*:0]const u8, "words") else @as([*:0]const u8, "bytes"));
    if (info.size < 1) {
        c.lprintf(log.Level.err, " Invalid FRU size %d", @as(c_int, info.size));
        return -1;
    }

    var header_data: [4]u8 = .{ id, 0, 0, 8 };
    req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data = &header_data;
    req.msg.data_len = header_data.len;
    const rsp = sendrecv(intf, &req) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return 1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf(" Device not present (%s)\n", c.val2str(rsp.ccode, c.completion_code_vals));
        return 1;
    }
    if (c.verbose > 1)
        c.printbuf(&rsp.data, rsp.data_len, "FRU DATA");
    var header: [8]u8 = @splat(0);
    if (rsp.data_len > 1) {
        const count = @min(@as(usize, @intCast(rsp.data_len - 1)), header.len);
        @memcpy(header[0..count], rsp.data[1..][0..count]);
    } else {
        // The C command copies eight unchecked bytes from data[1..] even
        // when the response has only the count byte. The dummy transport
        // retains Get FRU Info's high size byte in data[1]; reproduce that
        // observable malformed-response case without reading stale memory.
        header[0] = @truncate(info.size >> 8);
    }
    if (header[0] != 1) {
        c.lprintf(log.Level.err, " Unknown FRU header version 0x%02x", @as(c_uint, header[0]));
        return -1;
    }
    c.lprintf(log.Level.debug, "fru.header.version:         0x%x", @as(c_uint, header[0]));
    c.lprintf(log.Level.debug, "fru.header.offset.internal: 0x%x", @as(c_uint, header[1]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.chassis:  0x%x", @as(c_uint, header[2]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.board:    0x%x", @as(c_uint, header[3]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.product:  0x%x", @as(c_uint, header[4]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.multi:    0x%x", @as(c_uint, header[5]) * 8);
    if (header[2] != 0) areaPrint(intf, id, &info, @as(usize, header[2]) * 8, .chassis, allocator);
    if (header[3] != 0) areaPrint(intf, id, &info, @as(usize, header[3]) * 8, .board, allocator);
    if (header[4] != 0) areaPrint(intf, id, &info, @as(usize, header[4]) * 8, .product, allocator);
    if (c.verbose != 0 and header[5] != 0) multirecordPrint(intf, id, &info, @as(usize, header[5]) * 8);
    return 0;
}

/// An SDR FRU locator's string starts at byte eleven; both locator structs
/// contain packed bitfields, so the short records get checked before decoding.
fn printLocator(intf: *Intf, record: []const u8, allocator: Allocator) c_int {
    if (record.len < 11) return -1;
    const dev_type = record[5];
    const modifier = record[6];
    if (dev_type != 0x10 and (modifier != 2 or dev_type < 8 or dev_type > 15))
        return -1;
    if (record[0] == ipmi.bmc_slave_addr and record[1] == 0) return 0;
    var description: [17]u8 = @splat(0);
    const count = @min(@as(usize, record[10] & 0x1f), description.len - 1, record.len - 11);
    @memcpy(description[0..count], record[11..][0..count]);
    _ = c.printf("FRU Device Description : %s (ID %d)\n", &description, @as(c_int, record[1]));

    var rc: c_int = 0;
    switch (modifier) {
        0, 2 => {
            const channel: u8 = record[3] >> 4;
            const target = record[0];
            const bridge = !((channel == 0 and intf.target_ipmb_addr != 0 and
                intf.target_ipmb_addr == target) or
                (intf.target_addr == target and intf.target_channel == channel));
            if (bridge) {
                const old_addr = intf.target_addr;
                const old_channel = intf.target_channel;
                intf.target_addr = target;
                intf.target_channel = channel;
                rc = printFru(intf, record[1], allocator);
                intf.target_addr = old_addr;
                intf.target_channel = old_channel;
            } else {
                rc = printFru(intf, record[1], allocator);
            }
        },
        1 => rc = c.ipmi_spd_print_fru(cIntf(intf), record[1]),
        else => {
            if (c.verbose != 0)
                _ = c.printf(" Unsupported device 0x%02x type 0x%02x with modifier 0x%02x\n", @as(c_uint, record[1]), @as(c_uint, dev_type), @as(c_uint, modifier))
            else
                _ = c.printf(" Unsupported device\n");
        },
    }
    _ = c.printf("\n");
    return rc;
}

/// `fru print` without an explicit id enumerates FRUs in the SDR repository.
/// The SDR iterator remains in the SDR command module; FRU selection,
/// routing, target-address restoration and output live here.
fn printAll(intf: *Intf, allocator: Allocator) c_int {
    _ = c.printf("FRU Device Description : Builtin FRU Device (ID 0)\n");
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = c.BMC_GET_DEVICE_ID;
    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Get Device ID command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get Device ID command failed: %s", c.val2str(rsp.ccode, c.completion_code_vals));
        return -1;
    }
    if (rsp.data_len < 6) {
        c.lprintf(log.Level.err, "Get Device ID response too short");
        return -1;
    }
    var rc: c_int = 0;
    if ((rsp.data[5] & 0x08) != 0) {
        rc = printFru(intf, 0, allocator);
        _ = c.printf("\n");
    }
    const itr = c.ipmi_sdr_start(cIntf(intf), 0);
    if (itr == null) return -1;
    defer c.ipmi_sdr_end(itr);

    while (true) {
        const header = c.ipmi_sdr_get_next_header(cIntf(intf), itr);
        if (header == null) break;
        const bytes: [*]const u8 = @ptrCast(header);
        const typ = bytes[5];
        if (typ != c.SDR_RECORD_TYPE_MC_DEVICE_LOCATOR and
            typ != c.SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR) continue;

        const data = c.ipmi_sdr_get_record(cIntf(intf), header, itr);
        if (data == null) continue;
        defer c.free(data);
        const record = data[0..bytes[6]];
        if (typ == c.SDR_RECORD_TYPE_MC_DEVICE_LOCATOR) {
            if (record.len < 11 or (record[3] & 0x08) == 0 or
                intf.target_addr == record[0]) continue;
            const old_addr = intf.target_addr;
            intf.target_addr = record[0];
            var name: [17]u8 = @splat(0);
            const name_len = @min(record.len - 11, name.len - 1);
            @memcpy(name[0..name_len], record[11..][0..name_len]);
            _ = c.printf("FRU Device Description : %-16s\n", &name);
            rc = printFru(intf, 0, allocator);
            _ = c.printf("\n");
            intf.target_addr = old_addr;
            continue;
        }
        if (record.len < 11 or (record[2] & 0x80) == 0) continue;
        rc = printLocator(intf, record, allocator);
    }
    return rc;
}

const Block = struct {
    start: usize,
    end: usize,
    name: [*:0]const u8,
    record_type: ?u8 = null,
};

fn blockName(block: Block, storage: *[32]u8) [*:0]const u8 {
    if (block.record_type) |record_type| {
        _ = c.snprintf(storage, storage.len, "Multi-Rec Area: Type %i", @as(c_int, record_type));
        return @ptrCast(storage);
    }
    return block.name;
}

/// Parse the common-header section boundaries and the multi-record chain.
/// This is the write-protection map `build_fru_bloc()` builds in C. The
/// source image used for writing does not decide where its boundaries are:
/// the target FRU's own header and multirecord headers do.
fn buildBlocks(intf: *Intf, id: u8, info: *Info, allocator: Allocator) !std.ArrayList(Block) {
    var blocks: std.ArrayList(Block) = .empty;
    errdefer blocks.deinit(allocator);

    var request_data: [4]u8 = .{ id, 0, 0, 8 };
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data = &request_data;
    req.msg.data_len = request_data.len;
    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, " Device not present (No Response)");
        return blocks;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, " Device not present (%s)", c.val2str(rsp.ccode, c.completion_code_vals));
        return blocks;
    }
    if (rsp.data_len < 9) {
        c.lprintf(log.Level.err, " Bad header checksum");
        return blocks;
    }
    const header = rsp.data[1..9];
    var checksum: u8 = 0;
    for (header) |byte| checksum +%= byte;
    if (checksum != 0) {
        c.lprintf(log.Level.err, " Bad header checksum");
        return blocks;
    }
    if (header[0] != 1) {
        c.lprintf(log.Level.err, " Unknown FRU header version 0x%02x", @as(c_uint, header[0]));
        return blocks;
    }

    try blocks.append(allocator, .{ .start = 0, .end = info.size, .name = "Common Header Section" });
    const section_names = [_][*:0]const u8{
        "Internal Use Section", "Chassis Section", "Board Section", "Product Section",
    };
    for (section_names, 0..) |name, index| {
        if (header[index + 1] == 0) continue;
        const start: usize = @as(usize, header[index + 1]) * 8;
        blocks.items[blocks.items.len - 1].end = start;
        try blocks.append(allocator, .{ .start = start, .end = info.size, .name = name });
    }
    if (header[5] != 0) {
        var off: usize = @as(usize, header[5]) * 8;
        while (off < info.size) {
            if (info.access and (off & 1) != 0) {
                c.lprintf(log.Level.err, " Unaligned offset for a block: %d", @as(c_int, @intCast(off)));
                off += 1;
                break;
            }
            var record: [5]u8 = @splat(0);
            readArea(intf, id, info, off, &record) catch break;
            blocks.items[blocks.items.len - 1].end = off;
            try blocks.append(allocator, .{
                .start = off,
                .end = info.size,
                .name = "Multi-Rec Area",
                .record_type = record[0],
            });
            off += @as(usize, record[2]) + record.len;
            checksum = 0;
            for (record) |byte| checksum +%= byte;
            if (checksum != 0 or (record[1] & 0x80) != 0) break;
        }
        if (info.size > off) {
            blocks.items[blocks.items.len - 1].end = off;
            try blocks.append(allocator, .{ .start = off, .end = info.size, .name = "Unused space" });
        }
    }
    for (blocks.items, 0..) |block, index| {
        var storage: [32]u8 = undefined;
        c.lprintf(log.Level.debug, "Bloc Numb : %i", @as(c_int, @intCast(index)));
        c.lprintf(log.Level.debug, "Bloc Id   : %s", blockName(block, &storage));
        c.lprintf(log.Level.debug, "Bloc Start: %i", @as(c_int, @intCast(block.start)));
        c.lprintf(log.Level.debug, "Bloc Size : %i", @as(c_int, @intCast(block.end -| block.start)));
        c.lprintf(log.Level.debug, "");
    }
    return blocks;
}

/// Write in bounded chunks without crossing the FRU's existing section
/// boundaries. A protected section is skipped, not treated as success for
/// the same bytes; all allocations and the interface response stay borrowed.
fn writeArea(intf: *Intf, id: u8, info: *Info, dest_offset: usize, source: []const u8, allocator: Allocator) !bool {
    if (dest_offset > info.size or source.len > info.size - dest_offset) {
        c.lprintf(log.Level.@"error", "Return error");
        return false;
    }
    if (info.access and ((dest_offset | source.len) & 1) != 0) {
        c.lprintf(log.Level.@"error", "Odd offset or length specified");
        return false;
    }
    const finish = dest_offset + source.len;
    var blocks = try buildBlocks(intf, id, info, allocator);
    defer blocks.deinit(allocator);
    const max_request = c.ipmi_intf_get_max_request_data_size(cIntf(intf));
    if (max_request <= 3) {
        c.lprintf(log.Level.@"error", "Maximum request size is too small to send a write request");
        return false;
    }
    var max_write: usize = @min(@as(usize, max_request) - 3, 255);
    if (info.access) max_write &= ~@as(usize, 1);
    if (max_write == 0) return false;

    var request_data: [258]u8 = undefined;
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.SET_FRU_DATA;
    req.msg.data = &request_data;
    var offset = dest_offset;
    var block_index: usize = 0;
    while (true) {
        if (offset >= finish) return true;
        while (block_index < blocks.items.len and blocks.items[block_index].end <= offset)
            block_index += 1;
        const block: ?Block = if (block_index < blocks.items.len) blocks.items[block_index] else null;
        const end = if (block) |b| @min(b.end, finish) else finish;
        const remaining = end -| offset;
        var length = @min(remaining, max_write);
        if (info.access) length &= ~@as(usize, 1);
        if (length == 0) return false;
        @memcpy(request_data[3..][0..length], source[offset - dest_offset ..][0..length]);

        const wire_offset = if (info.access) offset >> 1 else offset;
        request_data[0] = id;
        request_data[1] = @truncate(wire_offset);
        request_data[2] = @truncate(wire_offset >> 8);
        req.msg.data_len = @intCast(length + 3);
        if (block) |b| {
            var storage: [32]u8 = undefined;
            c.lprintf(log.Level.info, "Writing %d bytes (Bloc #%i: %s)", @as(c_int, @intCast(length)), @as(c_int, @intCast(block_index)), blockName(b, &storage));
        } else {
            c.lprintf(log.Level.info, "Writing %d bytes", @as(c_int, @intCast(length)));
        }

        const rsp = sendrecv(intf, &req) orelse break;
        if (isTooLarge(rsp.ccode) and max_write > 32) {
            max_write -= 8;
            c.lprintf(log.Level.info, "Retrying FRU write with request size %d", @as(c_int, @intCast(max_write)));
            continue;
        }
        if (rsp.ccode == c.IPMI_CC_FRU_WRITE_PROTECTED_OFFSET) {
            if (block) |b| {
                var storage: [32]u8 = undefined;
                c.lprintf(log.Level.info, "Bloc [%s] protected at offset: %i (size %i bytes)", blockName(b, &storage), @as(c_int, @intCast(b.start)), @as(c_int, @intCast(b.end -| b.start)));
                c.lprintf(log.Level.info, "Jumping over this bloc");
            } else {
                c.lprintf(log.Level.info, "Remaining FRU is protected following offset: %i", @as(c_int, @intCast(offset)));
            }
            offset = end;
        } else if (rsp.ccode != 0) {
            break;
        } else {
            c.lprintf(log.Level.info, "Wrote %d bytes", @as(c_int, @intCast(length)));
            offset += length;
        }
    }
    return offset >= finish;
}

const InternalUse = struct {
    info: Info,
    offset: usize,
    size: usize,
};

fn internalUseInfo(intf: *Intf, id: u8) ?InternalUse {
    var request_data: [4]u8 = .{ id, 0, 0, 0 };
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &request_data;
    req.msg.data_len = 1;
    const rsp = sendrecv(intf, &req) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return null;
    };
    if (rsp.ccode != 0) {
        _ = c.printf(" Device not present (%s)\n", c.val2str(rsp.ccode, c.completion_code_vals));
        return null;
    }
    if (rsp.data_len < 3) return null;
    const info = Info{
        .size = @as(u16, rsp.data[0]) | (@as(u16, rsp.data[1]) << 8),
        .access = (rsp.data[2] & 1) != 0,
    };
    c.lprintf(log.Level.debug, "fru.size = %d bytes (accessed by %s)", @as(c_int, info.size), if (info.access) @as([*:0]const u8, "words") else @as([*:0]const u8, "bytes"));
    if (info.size == 0) {
        c.lprintf(log.Level.err, " Invalid FRU size %d", @as(c_int, info.size));
        return null;
    }
    request_data = .{ id, 0, 0, 8 };
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data_len = 4;
    const header_rsp = sendrecv(intf, &req) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return null;
    };
    if (header_rsp.ccode != 0) {
        _ = c.printf(" Device not present (%s)\n", c.val2str(header_rsp.ccode, c.completion_code_vals));
        return null;
    }
    var header: [8]u8 = @splat(0);
    if (header_rsp.data_len > 1) {
        const count = @min(@as(usize, @intCast(header_rsp.data_len - 1)), header.len);
        @memcpy(header[0..count], header_rsp.data[1..][0..count]);
    }
    if (header[0] != 1) {
        c.lprintf(log.Level.err, " Unknown FRU header version 0x%02x", @as(c_uint, header[0]));
        return null;
    }
    c.lprintf(log.Level.debug, "fru.header.version:         0x%x", @as(c_uint, header[0]));
    c.lprintf(log.Level.debug, "fru.header.offset.internal: 0x%x", @as(c_uint, header[1]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.chassis:  0x%x", @as(c_uint, header[2]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.board:    0x%x", @as(c_uint, header[3]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.product:  0x%x", @as(c_uint, header[4]) * 8);
    c.lprintf(log.Level.debug, "fru.header.offset.multi:    0x%x", @as(c_uint, header[5]) * 8);

    if (header[1] == 0) return .{ .info = info, .offset = 0, .size = 0 };
    const offset: usize = @as(usize, header[1]) * 8;
    for (header[2..6]) |next| {
        if (next != 0) {
            const next_offset: usize = @as(usize, next) * 8;
            return .{ .info = info, .offset = offset, .size = next_offset -| offset };
        }
    }
    return .{ .info = info, .offset = offset, .size = @as(usize, info.size) -| offset };
}

fn internalUse(intf: *Intf, id: u8, verb: [*c]u8, filename: [*c]u8, allocator: Allocator) c_int {
    var internal = internalUseInfo(intf, id) orelse {
        c.lprintf(log.Level.err, "Cannot access internal use area");
        return if (equals(verb, "info")) -1 else 0;
    };
    c.lprintf(log.Level.debug, "Internal Use Area Offset: %i", @as(c_int, @intCast(internal.offset)));
    _ = c.printf("Internal Use Area Size  : %i\n", @as(c_int, @intCast(internal.size)));
    if (equals(verb, "info")) return 0;

    if (equals(verb, "write")) {
        const file = c.fopen(filename, "r") orelse return 0;
        defer _ = c.fclose(file);
        if (c.fseek(file, 0, c.SEEK_END) != 0) return 0;
        const file_length = c.ftell(file);
        c.lprintf(log.Level.err, "File Size: %i", @as(c_int, @truncate(file_length)));
        c.lprintf(log.Level.err, "Area Size: %i", @as(c_int, @intCast(internal.size)));
        if (file_length < 0 or @as(usize, @intCast(file_length)) != internal.size) {
            c.lprintf(log.Level.err, "File size does not fit Eeprom Size");
            return 0;
        }
        _ = c.fseek(file, 0, c.SEEK_SET);
        const data = allocator.alloc(u8, internal.size) catch return 0;
        defer allocator.free(data);
        if (c.fread(data.ptr, 1, data.len, file) != data.len) return 0;
        const wrote = writeArea(intf, id, &internal.info, internal.offset, data, allocator) catch false;
        if (!wrote) c.lprintf(log.Level.info, "Done\n");
        return 0;
    }

    const data = allocator.alloc(u8, internal.size) catch return 0;
    defer allocator.free(data);
    @memset(data, 0);
    // read_fru_area_section starts at 20 bytes, capped at 16 for word access.
    internal.info.max_read = if (internal.info.access) 16 else 20;
    if (readArea(intf, id, &internal.info, internal.offset, data)) |_| {
        if (equals(verb, "print")) {
            for (data, 0..) |byte, index| {
                if (index % 16 == 0) _ = c.printf("\n%02i- ", @as(c_int, @intCast(index / 16)));
                _ = c.printf("%02X ", @as(c_uint, byte));
            }
        } else {
            const file = c.fopen(filename, "wb") orelse {
                c.lprintf(log.Level.err, "Error opening file %s\n", filename);
                return -1;
            };
            defer _ = c.fclose(file);
            _ = c.fwrite(data.ptr, data.len, 1, file);
            _ = c.printf("Done\n");
        }
    } else |_| {}
    _ = c.printf("\n");
    return 0;
}

fn transfer(intf: *Intf, id: u8, path: [*c]u8, allocator: Allocator, write: bool) void {
    var info = getInfo(intf, id) orelse return;
    if (c.verbose != 0) {
        _ = c.printf("Fru Size   = %d bytes\n", @as(c_int, info.size));
        _ = c.printf("Fru Access = %xh\n", @as(c_uint, @intFromBool(info.access)));
    }
    const data = allocator.alloc(u8, info.size) catch {
        c.lprintf(log.Level.err, "Cannot allocate %d bytes\n", @as(c_int, info.size));
        return;
    };
    defer allocator.free(data);
    @memset(data, 0);

    if (write) {
        var length: usize = 0;
        if (c.fopen(path, "rb")) |file| {
            length = c.fread(data.ptr, 1, data.len, file);
            _ = c.printf("Fru Size         : %d bytes\n", @as(c_int, info.size));
            _ = c.printf("Size to Write    : %d bytes\n", @as(c_int, @intCast(length)));
            _ = c.fclose(file);
        } else {
            c.lprintf(log.Level.err, "Error opening file %s\n", path);
        }
        if (length > 0) {
            _ = writeArea(intf, id, &info, 0, data[0..length], allocator) catch false;
            c.lprintf(log.Level.info, "Done");
        }
    } else {
        _ = c.printf("Fru Size         : %d bytes\n", @as(c_int, info.size));
        // The C CLI writes a file even if its FRU read failed. Keep that
        // observable CLI behavior, but never write uninitialized bytes.
        readArea(intf, id, &info, 0, data) catch {};
        const file = c.fopen(path, "wb") orelse {
            c.lprintf(log.Level.err, "Error opening file %s\n", path);
            return;
        };
        defer _ = c.fclose(file);
        _ = c.fwrite(data.ptr, data.len, 1, file);
        _ = c.printf("Done\n");
    }
}

const MultirecordLocation = struct {
    info: Info,
    offset: usize,
    size: usize,
};

fn multirecordLocation(intf: *Intf, id: u8) ?MultirecordLocation {
    var data: [4]u8 = .{ id, 0, 0, 0 };
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &data;
    req.msg.data_len = 1;
    const info_rsp = sendrecv(intf, &req) orelse {
        if (c.verbose > 1) _ = c.printf("no response\n");
        return null;
    };
    if (info_rsp.ccode != 0) {
        if (info_rsp.ccode == c.IPMI_CC_TIMEOUT)
            _ = c.printf("  Timeout accessing FRU info. (Device not present?)\n")
        else
            _ = c.printf("   CCODE = 0x%02x\n", @as(c_uint, info_rsp.ccode));
        return null;
    }
    if (info_rsp.data_len < 3) return null;
    const info = Info{
        .size = @as(u16, info_rsp.data[0]) | (@as(u16, info_rsp.data[1]) << 8),
        .access = (info_rsp.data[2] & 1) != 0,
    };
    if (c.verbose > 1)
        _ = c.printf("pFruInfo->size = %d bytes (accessed by %s)\n", @as(c_int, info.size), if (info.access) @as([*:0]const u8, "words") else @as([*:0]const u8, "bytes"));
    if (info.size == 0) return null;

    data = .{ id, 0, 0, 8 };
    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data_len = 4;
    const rsp = sendrecv(intf, &req) orelse return null;
    if (rsp.ccode != 0) {
        if (rsp.ccode == c.IPMI_CC_TIMEOUT)
            _ = c.printf("  Timeout while reading FRU data. (Device not present?)\n");
        return null;
    }
    if (c.verbose > 1) c.printbuf(&rsp.data, rsp.data_len, "FRU DATA");
    if (rsp.data_len < 9) return null;
    const header = rsp.data[1..9];
    if (header[0] != 1) {
        _ = c.printf("  Unknown FRU header version %02x.\n", @as(c_uint, header[0]));
        return null;
    }
    const offset: usize = @as(usize, header[5]) * 8;
    return .{ .info = info, .offset = offset, .size = info.size };
}

fn adjustMultirecordSize(data: []const u8) ?usize {
    var offset: usize = 0;
    while (offset + 5 <= data.len) {
        const header = data[offset..][0..5];
        if (c.verbose != 0) _ = c.printf("Adding (");
        var checksum: u8 = 0;
        for (header) |byte| {
            if (c.verbose != 0) _ = c.printf(" %02X", @as(c_uint, byte));
            checksum +%= byte;
        }
        if (c.verbose != 0) _ = c.printf(")");
        if (checksum != 0) {
            c.lprintf(log.Level.err, "Bad checksum in Multi Records");
            if (c.verbose != 0) _ = c.printf("--> FAIL");
        } else if (c.verbose != 0) {
            _ = c.printf("--> OK");
        }
        const length = @as(usize, header[2]) + 5;
        if (length > data.len - offset) {
            if (c.verbose != 0) _ = c.printf("\n");
            c.lprintf(log.Level.err, "Bad checksum in Multi Records");
            return null;
        }
        if (c.verbose > 1 and checksum == 0) {
            for (data[offset + 5 ..][0..header[2]]) |byte| {
                _ = c.printf(" %02X", @as(c_uint, byte));
            }
        }
        if (c.verbose != 0) _ = c.printf("\n");
        offset += length;
        if (checksum != 0) {
            c.lprintf(log.Level.debug, "Size of multirec: %lu\n", @as(c_ulong, @intCast(offset)));
            return null;
        }
        if ((header[1] & 0x80) != 0) {
            c.lprintf(log.Level.debug, "Size of multirec: %lu\n", @as(c_ulong, @intCast(offset)));
            return offset;
        }
    }
    c.lprintf(log.Level.err, "Bad checksum in Multi Records");
    return null;
}

fn upgradeEkey(intf: *Intf, id: u8, filename: [*c]u8, allocator: Allocator) c_int {
    const location = multirecordLocation(intf, id) orelse {
        c.lprintf(log.Level.err, "Failed to get multirec location from FRU.");
        return -1;
    };
    c.lprintf(log.Level.debug, "FRU Size        : %lu\n", @as(c_ulong, @intCast(location.size)));
    c.lprintf(log.Level.debug, "Multi Rec offset: %lu\n", @as(c_ulong, @intCast(location.offset)));

    const file = c.fopen(filename, "rb");
    var file_length: usize = 0;
    var header: [8]u8 = @splat(0);
    var header_length: usize = 0;
    if (file) |fp| {
        defer _ = c.fclose(fp);
        header_length = c.fread(&header, 1, header.len, fp);
        if (c.fseek(fp, 0, c.SEEK_END) == 0) {
            const length = c.ftell(fp);
            if (length >= 0) file_length = @intCast(length);
        }
    }
    c.lprintf(log.Level.debug, "File Size = %lu\n", @as(c_ulong, @intCast(file_length)));
    c.lprintf(log.Level.debug, "Len = %u\n", @as(c_uint, @intCast(header_length)));
    if (header_length != 8) {
        _ = c.printf("Error with file %s in getting size\n", filename);
    } else if (header[0] != 1) {
        _ = c.printf("Unknown FRU header version %02x.\n", @as(c_uint, header[0]));
    }
    if (header_length != 8 or header[0] != 1 or file_length < @as(usize, header[5]) * 8) {
        c.lprintf(log.Level.err, "Failed to get multirec size from file '%s'.", filename);
        return -1;
    }
    const file_offset = @as(usize, header[5]) * 8;
    const size = file_length - file_offset;
    const data = allocator.alloc(u8, size) catch {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return -1;
    };
    defer allocator.free(data);

    const source = c.fopen(filename, "rb") orelse {
        c.lprintf(log.Level.err, "Error opening file '%s': %i -> %s.", filename, c.__errno_location().*, c.strerror(c.__errno_location().*));
        c.lprintf(log.Level.err, "Failed to get multirec from file '%s'.", filename);
        return -1;
    };
    defer _ = c.fclose(source);
    if (c.fseek(source, @intCast(file_offset), c.SEEK_SET) != 0 or c.fread(data.ptr, size, 1, source) != 1) {
        c.lprintf(log.Level.err, "Error in file '%s'.", filename);
        c.lprintf(log.Level.err, "Failed to get multirec from file '%s'.", filename);
        return -1;
    }
    const used = adjustMultirecordSize(data) orelse {
        c.lprintf(log.Level.err, "Failed to adjust size from buffer.");
        return -1;
    };
    var info = location.info;
    if (writeArea(intf, id, &info, location.offset, data[0..used], allocator) catch false) {
        c.lprintf(log.Level.err, "Failed to write FRU area.");
        return -1;
    }
    c.lprintf(log.Level.info, "Done upgrading Ekey.");
    return 0;
}

fn upgradeEkeyHelp() void {
    c.lprintf(log.Level.notice, "fru upgEkey <fru id> <fru file>");
    c.lprintf(log.Level.notice, "Note: FRU ID and file(incl. full path) must be specified.");
    c.lprintf(log.Level.notice, "Example: ipmitool fru upgEkey 0 /root/fru.bin");
}

fn kontronGet(body: []const u8, argc: c_int, argv: [*c][*c]u8) void {
    if (argc < 5 or argv[7] == null) {
        _ = c.printf("usage: oem <iana> <recordid>\n");
        _ = c.printf("usage: oem 15000 3\n");
        return;
    }
    if (body.len < 6 or body[3] != 3) return;
    _ = c.printf("Kontron OEM Information Record\n");
    var instance: u8 = 0;
    if (c.str2uchar(argv[7], &instance) != 0) {
        c.lprintf(log.Level.err, "Instance argument '%s' is either invalid or out of range.", argv[7]);
        return;
    }
    const version = body[4];
    const count = body[5];
    var pos: usize = 6;
    for (0..count) |_| {
        if (pos >= body.len) return;
        const name_len: usize = body[pos] & 0x3f;
        pos += 1;
        if (name_len > body.len - pos) return;
        _ = c.printf("  Name: %*.*s\n", @as(c_int, @intCast(name_len)), @as(c_int, @intCast(name_len)), @as([*c]const u8, @ptrCast(body[pos..].ptr)));
        pos += name_len;
        _ = c.printf("  Record Version: %d\n", @as(c_int, version));
        const version_size: usize = if (version == 1) 10 else 8;
        if (version != 0 and version != 1) {
            _ = c.printf("  Unsupported version %d\n", @as(c_int, version));
            continue;
        }
        const record_size: usize = version_size + 3 * 8 + 4;
        if (record_size + 1 > body.len - pos) return;
        const values = [_][*:0]const u8{ "Version", "Build Date", "Update Date", "Checksum" };
        for (values, 0..) |label, index| {
            const length: usize = if (index == 0) version_size else 8;
            pos += 1;
            _ = c.printf("  %s: %*.*s\n", label, @as(c_int, @intCast(length)), @as(c_int, @intCast(length)), @as([*c]const u8, @ptrCast(body[pos..].ptr)));
            pos += length;
        }
        pos += 1;
        _ = c.printf("\n");
    }
}

fn getMultirecord(intf: *Intf, id: u8, argc: c_int, argv: [*c][*c]u8, allocator: Allocator) c_int {
    const location = multirecordLocation(intf, id) orelse return 0xffff;
    c.lprintf(log.Level.debug, "FRU Size        : %lu\n", @as(c_ulong, @intCast(location.size)));
    c.lprintf(log.Level.debug, "Multi Rec offset: %lu\n", @as(c_ulong, @intCast(location.offset)));

    // The C command separately queries the inventory size after locating
    // the multirecord area. Preserve both requests for wire-level parity.
    var info = getInfo(intf, id) orelse return -1;
    c.lprintf(log.Level.debug, "fru.size = %d bytes (accessed by %s)", @as(c_int, info.size), if (info.access) @as([*:0]const u8, "words") else @as([*:0]const u8, "bytes"));
    if (info.size == 0) {
        c.lprintf(log.Level.err, " Invalid FRU size %d", @as(c_int, info.size));
        return -1;
    }
    const data = allocator.alloc(u8, @as(usize, info.size) + 1) catch {
        c.lprintf(log.Level.err, " Out of memory!");
        return -1;
    };
    defer allocator.free(data);
    @memset(data, 0);
    var index = location.offset;
    var last_off = index;
    while (index + 5 <= info.size) {
        if (last_off < index + 5 or last_off < index + data[index + 2]) {
            if (last_off >= info.size) break;
            const length = @min(@as(usize, info.size) - last_off, 260);
            readArea(intf, id, &info, last_off, data[0..length]) catch break;
            last_off += length;
        }
        const header = data[index..][0..5];
        const body_len: usize = header[2];
        if (index + 5 + body_len > data.len) break;
        const body = data[index + 5 ..][0..body_len];
        if (header[0] == c.FRU_RECORD_TYPE_OEM_EXTENSION and body.len >= 5) {
            const iana = @as(u32, body[0]) | (@as(u32, body[1]) << 8) | (@as(u32, body[2]) << 16);
            var supplied: u32 = 0;
            if (argc >= 3 and equals(argv[2], "oem")) {
                if (argc <= 3) {
                    c.lprintf(log.Level.err, "oem iana <record> <format>");
                    break;
                }
                if (c.str2uint(argv[3], &supplied) != 0) {
                    c.lprintf(log.Level.err, "Given IANA '%s' is invalid.", argv[3]);
                    break;
                }
                c.lprintf(log.Level.debug, "using iana: %d", @as(c_int, @bitCast(supplied)));
            }
            if (supplied == iana) {
                c.lprintf(log.Level.debug, "Matching record found");
                if (iana == c.IPMI_OEM_KONTRON) {
                    kontronGet(body, argc, argv);
                } else {
                    _ = c.printf("  OEM IANA (%s) Record not supported in this mode\n", c.val2str(iana, c.ipmi_oem_info));
                    break;
                }
            }
        }
        index += body_len + 5;
        if ((header[1] & 0x80) != 0) break;
    }
    return 0;
}

fn getHelp() void {
    c.lprintf(log.Level.notice, "fru get <fruid> oem iana <record> <format> <args> - limited OEM support");
}

fn fruMain(intf: ?*Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    const in = intf orelse return -1;
    if (argc >= 1 and equals(argv[0], "get")) {
        if (argc > 1 and equals(argv[1], "help")) {
            getHelp();
            return 0;
        }
        if (argc < 2) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            getHelp();
            return -1;
        }
        var id: u8 = 0;
        if (c.is_fru_id(argv[1], &id) != 0) return -1;
        if (c.verbose != 0) _ = c.printf("FRU ID           : %d\n", @as(c_int, id));
        if (argc >= 3 and !equals(argv[2], "oem")) {
            c.lprintf(log.Level.err, "Invalid command: %s", argv[2]);
            getHelp();
            return -1;
        }
        return getMultirecord(in, id, argc, argv, std.heap.page_allocator);
    }
    if (argc >= 1 and equals(argv[0], "upgEkey")) {
        if (argc > 1 and equals(argv[1], "help")) {
            upgradeEkeyHelp();
            return 0;
        }
        if (argc < 3) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            upgradeEkeyHelp();
            return -1;
        }
        var id: u8 = 0;
        if (c.is_fru_id(argv[1], &id) != 0 or !validFilename(argv[2])) return -1;
        return upgradeEkey(in, id, argv[2], std.heap.page_allocator);
    }
    if (argc >= 3 and equals(argv[0], "internaluse") and
        (equals(argv[2], "info") or equals(argv[2], "print") or
            (argc >= 4 and (equals(argv[2], "read") or equals(argv[2], "write")))))
    {
        var id: u8 = 0;
        if (c.is_fru_id(argv[1], &id) != 0) return -1;
        const path: [*c]u8 = if (argc >= 4) argv[3] else null;
        if (path != null and !validFilename(path)) return -1;
        return internalUse(in, id, argv[2], path, std.heap.page_allocator);
    }
    if (argc < 1)
        return printAll(in, std.heap.page_allocator);
    if (argc == 1 and
        (equals(argv[0], "print") or equals(argv[0], "list")))
        return printAll(in, std.heap.page_allocator);
    if (argc > 1 and (equals(argv[0], "print") or equals(argv[0], "list"))) {
        if (equals(argv[1], "help")) return c.ipmi_fru_main_legacy(cIntf(in), argc, argv);
        var id: u8 = 0;
        if (c.is_fru_id(argv[1], &id) != 0) return -1;
        return printFru(in, id, std.heap.page_allocator);
    }
    if (argc < 1 or (!equals(argv[0], "read") and !equals(argv[0], "write")))
        return c.ipmi_fru_main_legacy(cIntf(in), argc, argv);

    const write = equals(argv[0], "write");
    if (argc > 1 and equals(argv[1], "help")) {
        if (write) c.ipmi_fru_write_help() else c.ipmi_fru_read_help();
        return 0;
    }
    if (argc < 3) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        if (write) c.ipmi_fru_write_help() else c.ipmi_fru_read_help();
        return -1;
    }
    var id: u8 = 0;
    if (c.is_fru_id(argv[1], &id) != 0 or !validFilename(argv[2]))
        return -1;
    if (c.verbose != 0) {
        _ = c.printf("FRU ID           : %d\n", @as(c_int, id));
        _ = c.printf("FRU File         : %s\n", argv[2]);
    }
    transfer(in, id, argv[2], std.heap.page_allocator, write);
    return 0;
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(fruMain), @TypeOf(c.ipmi_fru_main));
        @export(&fruMain, .{ .name = "ipmi_fru_main", .linkage = .strong });
    }
}
