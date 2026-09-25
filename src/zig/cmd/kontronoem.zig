//! Kontron OEM commands and the optional channel-buffer negotiation from
//! `lib/ipmi_kontronoem.c`. Select with `-Dzig-modules=kontronoem`.
//!
//! FRU area reads, writes and string decoding intentionally call the exported
//! `lib/ipmi_fru.c` helpers. A future FRU port MUST export read_fru_area,
//! write_fru_area and get_fru_area_str with their existing C signatures;
//! otherwise selecting both ports will fail at link time.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const log = @import("../util/log.zig");

const oem_prefix = [_]u8{ 0xb4, 0x90, 0x91, 0x8b };
const bootdev = [_][:0]const u8{ "BIOS", "FDD", "HDD", "CDROM", "network" };

// C's `struct fru_info` contains a one-bit access field, so translate-c makes
// it opaque. The other seven bits in that byte are unused by these helpers.
const FruInfo = extern struct {
    size: u16 = 0,
    access_bits: u8 = 0,
    max_read_size: u8 = 0,
    max_write_size: u8 = 0,
    padding: u8 = 0,
};

const Fru = struct {
    info: FruInfo,
    board: u32,
    product: u32,
    multi: u32,
};

fn request(intf: *Intf, netfn: u6, lun: u2, cmd: u8, data: []u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = netfn, .lun = lun };
    req.msg.cmd = cmd;
    req.msg.data = data.ptr;
    req.msg.data_len = @intCast(data.len);
    return intf.sendrecv.?(intf, &req);
}

fn help() void {
    _ = c.printf("Kontron Commands:  setsn setmfgdate nextboot\n");
}

fn nextbootHelp() void {
    _ = c.printf("nextboot <device>\nSupported devices:\n");
    for (bootdev) |device| _ = c.printf("- %s\n", device.ptr);
}

fn nextboot(intf: *Intf, device: [*:0]u8) c_int {
    var data = [_]u8{ 0xb4, 0x90, 0x91, 0x8b, 0x9d, 0xff, 0xff };
    for (bootdev, 0..) |name, i| {
        if (std.mem.eql(u8, std.mem.span(device), name)) {
            data[5] = @intCast(i);
            break;
        }
    }
    if (data[5] == 0xff) {
        _ = c.printf("Unknown boot device: %s\n", device);
        return -1;
    }
    const rsp = request(intf, 0x3e, 3, 0x02, &data) orelse {
        _ = c.printf("Device not present (No Response)\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf("Device not present (%s)\n", c.val2str(rsp.ccode, c.completion_code_vals));
        return -1;
    }
    return 0;
}

fn sendLargeBuffer(intf: *Intf, channel: u8, size: u8) c_int {
    var data = [_]u8{ channel, size };
    const rsp = request(intf, 0x3e, 0, 0x82, &data) orelse {
        _ = c.printf("Cannot send large buffer command\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf("Invalid length for the selected interface (%s) %d\n", c.val2str(rsp.ccode, c.completion_code_vals), @as(c_int, rsp.ccode));
        return -1;
    }
    return 0;
}

fn setLargeBuffer(intf: *Intf, size: u8) callconv(.c) c_int {
    var error_occurs: u8 = 0;
    const previous = intf.target_addr;
    if (previous > 0 and previous != intf.my_addr) {
        intf.target_addr = intf.my_addr;
        _ = c.printf("Set local big buffer\n");
        if (sendLargeBuffer(intf, 0x0e, size) == 0) {
            _ = c.printf("Set local big buffer:success\n");
        } else {
            error_occurs = 1;
        }
        if (error_occurs == 0) {
            if (sendLargeBuffer(intf, 0, size) == 0) {
                _ = c.printf("IPMB was set\n");
            } else {
                error_occurs = 1;
                _ = sendLargeBuffer(intf, 0x0e, 0);
            }
        }
        intf.target_addr = previous;
    }
    if (error_occurs == 0 and sendLargeBuffer(intf, 0x0e, size) != 0) {
        if (intf.target_addr > 0 and intf.target_addr != intf.my_addr) {
            intf.target_addr = intf.my_addr;
            _ = sendLargeBuffer(intf, 0x0e, 0);
            intf.target_addr = previous;
        }
    }
    return error_occurs;
}

fn fruResponseError(rsp: ?*Response) bool {
    if (rsp) |response| {
        if (response.ccode == 0) return false;
        _ = c.printf(" Device not present (%s)\n", c.val2str(response.ccode, c.completion_code_vals));
    } else {
        _ = c.printf(" Device not present (No Response)\n");
    }
    return true;
}

fn getFru(intf: *Intf) ?Fru {
    var id = [_]u8{0};
    const info_rsp = request(intf, ipmi.NetFn.storage, 0, c.GET_FRU_INFO, &id);
    if (fruResponseError(info_rsp)) return null;
    const info_data = info_rsp.?;
    if (info_data.data_len < 3) {
        _ = c.printf(" Invalid FRU info response\n");
        return null;
    }
    var fru = Fru{
        .info = .{
            .size = @as(u16, info_data.data[0]) | (@as(u16, info_data.data[1]) << 8),
            .access_bits = if (builtin.target.cpu.arch.endian() == .big)
                (info_data.data[2] & 1) << 7
            else
                info_data.data[2] & 1,
        },
        .board = 0,
        .product = 0,
        .multi = 0,
    };
    if (fru.info.size == 0) {
        _ = c.printf(" Invalid FRU size %d", @as(c_int, fru.info.size));
        return null;
    }

    var header_request = [_]u8{ 0, 0, 0, 8 };
    const header_rsp = request(intf, ipmi.NetFn.storage, 0, c.GET_FRU_DATA, &header_request);
    if (fruResponseError(header_rsp)) return null;
    const header = header_rsp.?;
    if (c.verbose > 1) c.printbuf(&header.data, header.data_len, "FRU DATA");
    if (header.data_len < 9) {
        _ = c.printf(" Invalid FRU header response\n");
        return null;
    }
    if (header.data[1] != 1) {
        _ = c.printf(" Unknown FRU header version 0x%02x", @as(c_uint, header.data[1]));
        return null;
    }
    fru.board = @as(u32, header.data[4]) * 8;
    fru.product = @as(u32, header.data[5]) * 8;
    fru.multi = @as(u32, header.data[6]) * 8;
    return fru;
}

fn readArea(intf: *Intf, fru: *FruInfo, off: u32, len: u32, buf: [*]u8) bool {
    return c.read_fru_area(@ptrCast(intf), @ptrCast(fru), 0, off, len, buf) >= 0;
}

fn writeArea(intf: *Intf, fru: *FruInfo, off: u32, len: u32, buf: [*]u8) bool {
    var checksum: u8 = 0;
    for (off..off + len - 2) |i| checksum +%= buf[i];
    buf[off + len - 1] = @as(u8, 0) -% checksum;
    // The C caller only rejects a negative return. In particular the FRU
    // helper's return value 0 on a denied write still counts as success.
    return c.write_fru_area(@ptrCast(intf), @ptrCast(fru), 0, @truncate(off), @truncate(off), @truncate(len), buf) >= 0;
}

fn fieldFits(buf: [*]u8, offset: u32, capacity: u32) bool {
    return offset < capacity and @as(u32, buf[offset] & 0x3f) < capacity - offset;
}

fn skipString(buf: [*]u8, offset: *u32) void {
    const field = c.get_fru_area_str(buf, offset);
    if (field != null) c.free(field);
}

fn serialField(buf: [*]u8, capacity: u32, start: u32, skips: usize, serial: []const u8, section: [:0]const u8) bool {
    var offset = start;
    for (0..skips) |_| {
        if (!fieldFits(buf, offset, capacity)) {
            c.lprintf(log.Level.err, "Failed to read FRU Area string.");
            return false;
        }
        skipString(buf, &offset);
    }
    if (!fieldFits(buf, offset, capacity)) {
        c.lprintf(log.Level.err, "Failed to read FRU Area string.");
        return false;
    }
    var ignored = offset;
    const field = c.get_fru_area_str(buf, &ignored);
    if (field == null) {
        c.lprintf(log.Level.err, "Failed to read FRU Area string.");
        return false;
    }
    defer c.free(field);
    if (c.strlen(field) != serial.len) {
        _ = c.printf("The length of the serial number in the FRU %s Area is wrong.\n", section.ptr);
        return false;
    }
    if (serial.len > capacity - offset - 1) {
        c.lprintf(log.Level.err, "Failed to read FRU Area string.");
        return false;
    }
    @memcpy(buf[offset + 1 ..][0..serial.len], serial);
    return true;
}

fn validArea(fru: Fru, off: u32, end: u32) bool {
    return off <= fru.info.size and end <= fru.info.size and end > off + 2;
}

fn setSerial(intf: *Intf) c_int {
    var prefix = oem_prefix;
    const rsp = request(intf, 0x3e, 3, 0x0c, &prefix) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf(" This option is not implemented for this board\n");
        return -1;
    }
    const sn_size: u8 = @truncate(@as(u32, @intCast(@max(rsp.data_len, 0))));
    var sn: [256]u8 = @splat(0);
    @memcpy(sn[0..sn_size], rsp.data[0..sn_size]);
    if (c.verbose >= 1) _ = c.printf("Original serial number is : [%s]\n", &sn[0]);

    var fru = getFru(intf) orelse return -1;
    if (!validArea(fru, fru.board, fru.product) or !validArea(fru, fru.product, fru.multi) or
        fru.board + 6 >= fru.info.size or fru.product + 3 >= fru.info.size)
    {
        _ = c.printf(" Invalid FRU section offsets\n");
        return -1;
    }
    const allocation = c.malloc(fru.info.size) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return -1;
    };
    defer c.free(allocation);
    const data: [*]u8 = @ptrCast(allocation);
    @memset(data[0..fru.info.size], 0);

    const board_len = fru.product - fru.board;
    if (!readArea(intf, &fru.info, fru.board, board_len, data)) return -1;
    if (!serialField(data, fru.info.size, fru.board + 6, 2, sn[0..sn_size], "Board")) return -1;
    if (!writeArea(intf, &fru.info, fru.board, board_len, data)) return -1;

    const product_len = fru.multi - fru.product;
    if (!readArea(intf, &fru.info, fru.product, product_len, data)) return -1;
    if (!serialField(data, fru.info.size, fru.product + 3, 4, sn[0..sn_size], "Product")) return -1;
    if (!writeArea(intf, &fru.info, fru.product, product_len, data)) return -1;
    return 1;
}

fn setMfgDate(intf: *Intf) c_int {
    var prefix = oem_prefix;
    const rsp = request(intf, 0x3e, 3, 0x0e, &prefix) orelse {
        _ = c.printf("Device not present (No Response)\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf("This option is not implemented for this board\n");
        return -1;
    }
    if (rsp.data_len != 3) {
        _ = c.printf("Invalid response for the Manufacturing date\n");
        return -1;
    }
    const date = rsp.data[0..3].*;
    var fru = getFru(intf) orelse return -1;
    if (!validArea(fru, fru.board, fru.product) or fru.board + 6 > fru.info.size) {
        _ = c.printf(" Invalid FRU section offsets\n");
        return -1;
    }
    const allocation = c.malloc(fru.info.size) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return -1;
    };
    defer c.free(allocation);
    const data: [*]u8 = @ptrCast(allocation);
    @memset(data[0..fru.info.size], 0);
    const length = fru.product - fru.board;
    if (!readArea(intf, &fru.info, fru.board, length, data)) return -1;
    @memcpy(data[fru.board + 3 ..][0..3], &date);
    if (!writeArea(intf, &fru.info, fru.board, length, data)) return -1;
    return 1;
}

fn main(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc == 0) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        help();
        return -1;
    }
    const command = std.mem.span(argv[0]);
    if (std.mem.eql(u8, command, "help")) {
        help();
        return 0;
    }
    if (std.mem.eql(u8, command, "setsn")) {
        if (setSerial(intf) > 0) {
            _ = c.printf("FRU serial number set successfully\n");
            return 0;
        }
        _ = c.printf("FRU serial number set failed\n");
        return -1;
    }
    if (std.mem.eql(u8, command, "setmfgdate")) {
        if (setMfgDate(intf) > 0) {
            _ = c.printf("FRU manufacturing date set successfully\n");
            return 0;
        }
        _ = c.printf("FRU manufacturing date set failed\n");
        return -1;
    }
    if (std.mem.eql(u8, command, "nextboot")) {
        if (argc < 2) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            nextbootHelp();
            return -1;
        }
        if (nextboot(intf, argv[1]) == 0) {
            _ = c.printf("Nextboot set successfully\n");
            return 0;
        }
        _ = c.printf("Nextboot set failed\n");
        return -1;
    }
    c.lprintf(log.Level.err, "Invalid Kontron command: %s", argv[0]);
    help();
    return -1;
}

pub fn exportSymbols() void {
    abi.assertOpaqueLayout(FruInfo, .{
        .size = c.ABI_SIZEOF_fru_info,
        .alignment = c.ABI_ALIGNOF_fru_info,
        .fields = &.{
            .{ .name = "size", .offset = c.ABI_OFFSETOF_fru_info__size },
            .{ .name = "max_read_size", .offset = c.ABI_OFFSETOF_fru_info__max_read_size },
            .{ .name = "max_write_size", .offset = c.ABI_OFFSETOF_fru_info__max_write_size },
        },
    });
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_kontronoem_main));
    abi.assertCallSignature(@TypeOf(setLargeBuffer), @TypeOf(c.ipmi_kontronoem_set_large_buffer));
    @export(&main, .{ .name = "ipmi_kontronoem_main", .linkage = .strong });
    @export(&setLargeBuffer, .{ .name = "ipmi_kontronoem_set_large_buffer", .linkage = .strong });
}
