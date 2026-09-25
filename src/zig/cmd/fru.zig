//! Staged port of `lib/ipmi_fru.c`. File transfer (`fru read` and `fru write`)
//! and non-verbose explicit-id `fru print/list` with bounded area decoding
//! are implemented here. Other commands still execute the original C code
//! through `fru_legacy.c`, not placeholders:
//! do not remove the shim until print, edit, get, upgEkey, internaluse and the
//! remaining public FRU helper functions have all been ported.

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

/// The non-verbose explicit-id path of `__ipmi_fru_print()`. Other print
/// paths remain in C until the multirecord and SDR parsers are ported.
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
    if (header[2] != 0) areaPrint(intf, id, &info, @as(usize, header[2]) * 8, .chassis, allocator);
    if (header[3] != 0) areaPrint(intf, id, &info, @as(usize, header[3]) * 8, .board, allocator);
    if (header[4] != 0) areaPrint(intf, id, &info, @as(usize, header[4]) * 8, .product, allocator);
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
            _ = c.ipmi_fru_zig_write(cIntf(intf), info.size, @intFromBool(info.access), id, @intCast(length), data.ptr);
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

fn fruMain(intf: ?*Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    const in = intf orelse return -1;
    if (argc > 1 and (equals(argv[0], "print") or equals(argv[0], "list")) and c.verbose == 0) {
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
