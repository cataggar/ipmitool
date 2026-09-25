//! Port of `lib/dimm_spd.c`: SPD field printing and FRU-backed SPD reads.
//! `-Dzig-modules=dimm-spd` replaces the C translation unit, including all
//! twenty global valstr tables (kept in `dimm_spd_tables.zig`).
//!
//! The C printer does not check the SPD header's declared length or CRC, and
//! treats every type except DDR3/DDR4 as a legacy SPD. Preserve that behavior
//! for complete images, including unrecognized JEDEC IDs. The DDR4 part number
//! extends through byte 348: a 348-byte image is *not* long enough.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");
const log = @import("../util/log.zig");
const ValStr = @import("../util/table_types.zig").ValStr;
const tables = @import("dimm_spd_tables.zig");

const Intf = intf_mod.Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

comptime {
    abi.assertLayout(ValStr, c.struct_valstr);
}

fn tableVal2str(val: u32, vs: []const ValStr) [*c]const u8 {
    return c.val2str(val, @ptrCast(vs.ptr));
}

fn requiredLength(memory_type: u8) usize {
    return switch (memory_type) {
        0x0b => 148,
        0x0c => 349,
        else => 100,
    };
}

fn scaled(base: u64, exponent: u8) u64 {
    return base << @intCast(exponent);
}

fn yesNo(yes: bool) [*:0]const u8 {
    return if (yes) "Yes" else "No";
}

fn manufacturer(bank: u8, code: u8) [*c]const u8 {
    const vals: []const ValStr = switch (bank) {
        0 => &tables.jedec_id1_vals,
        1 => &tables.jedec_id2_vals,
        2 => &tables.jedec_id3_vals,
        3 => &tables.jedec_id4_vals,
        4 => &tables.jedec_id5_vals,
        5 => &tables.jedec_id6_vals,
        6 => &tables.jedec_id7_vals,
        7 => &tables.jedec_id8_vals,
        8 => &tables.jedec_id9_vals,
        else => return "JEDEC JEP106 update required",
    };
    return tableVal2str(code, vals);
}

fn printSerial(serial: []const u8) void {
    _ = c.printf(
        " Serial Number         : %02x%02x%02x%02x\n",
        @as(c_uint, serial[0]),
        @as(c_uint, serial[1]),
        @as(c_uint, serial[2]),
        @as(c_uint, serial[3]),
    );
}

fn printDdr3(spd: []const u8) void {
    const capacity = scaled(256, spd[4] & 15);
    const primary_width = scaled(8, spd[8] & 7);
    const device_width = scaled(4, spd[7] & 7);
    const ranks = scaled(1, (spd[7] & 0x3f) >> 3);
    const size = (capacity / 8) * (primary_width / device_width) * ranks;

    _ = c.printf(" SDRAM Capacity        : %llu MB\n", @as(c_ulonglong, capacity));
    _ = c.printf(" Memory Banks          : %s\n", tableVal2str(spd[4] >> 4, &tables.ddr3_banks_vals));
    _ = c.printf(" Primary Bus Width     : %llu bits\n", @as(c_ulonglong, primary_width));
    _ = c.printf(" SDRAM Device Width    : %llu bits\n", @as(c_ulonglong, device_width));
    _ = c.printf(" Number of Ranks       : %llu\n", @as(c_ulonglong, ranks));
    _ = c.printf(" Memory size           : %llu MB\n", @as(c_ulonglong, size));
    _ = c.printf(" 1.5 V Nominal Op      : %s\n", yesNo(spd[6] & 1 == 0));
    _ = c.printf(" 1.35 V Nominal Op     : %s\n", yesNo(spd[6] & 2 == 0));
    _ = c.printf(" 1.2X V Nominal Op     : %s\n", yesNo(spd[6] & 4 == 0));
    _ = c.printf(" Error Detect/Cor      : %s\n", tableVal2str(spd[8] >> 3, &tables.ddr3_ecc_vals));
    _ = c.printf(" Manufacturer          : %s\n", manufacturer(spd[117] & 127, spd[118]));
    _ = c.printf(
        " Manufacture Date      : year %c%c week %c%c\n",
        @as(c_int, '0') + @as(c_int, spd[120] >> 4),
        @as(c_int, '0') + @as(c_int, spd[120] & 15),
        @as(c_int, '0') + @as(c_int, spd[121] >> 4),
        @as(c_int, '0') + @as(c_int, spd[121] & 15),
    );
    printSerial(spd[122..126]);
    _ = c.printf(" Part Number           : ");
    for (spd[128..146]) |byte| _ = c.printf("%c", @as(c_int, byte));
    _ = c.printf("\n");
}

fn printDdr4(spd: []const u8) void {
    var logical_ranks: u64 = @as(u64, (spd[12] >> 3) & 3) + 1;
    if (spd[6] & 3 == 2) logical_ranks *= @as(u64, (spd[6] >> 4) & 3) + 1;
    const capacity = scaled(256, spd[4] & 15);
    const primary_width = scaled(8, spd[13] & 7);
    const device_width = scaled(4, spd[12] & 7);
    const size = (capacity / 8) * (primary_width / device_width) * logical_ranks;

    _ = c.printf(" SDRAM Package Type    : %s\n", tableVal2str(spd[6] >> 7, &tables.ddr4_package_type));
    _ = c.printf(" Technology            : %s\n", tableVal2str(spd[3] & 15, &tables.ddr4_technology_type));
    _ = c.printf(" SDRAM Die Count       : %d\n", @as(c_int, (spd[6] >> 4) & 3) + 1);
    _ = c.printf(" SDRAM Capacity        : %llu Mb\n", @as(c_ulonglong, capacity));
    _ = c.printf(" Memory Bank Group     : %s\n", tableVal2str((spd[4] >> 6) & 3, &tables.ddr4_bank_groups));
    _ = c.printf(" Memory Banks          : %s\n", tableVal2str((spd[4] >> 4) & 3, &tables.ddr4_banks_vals));
    _ = c.printf(" Primary Bus Width     : %llu bits\n", @as(c_ulonglong, primary_width));
    _ = c.printf(" SDRAM Device Width    : %llu bits\n", @as(c_ulonglong, device_width));
    _ = c.printf(" Logical Rank per DIMM : %llu\n", @as(c_ulonglong, logical_ranks));
    _ = c.printf(" Memory size           : %llu MB\n", @as(c_ulonglong, size));
    _ = c.printf(" Memory Density        : %s\n", tableVal2str(spd[4] & 15, &tables.ddr4_density_vals));
    _ = c.printf(" 1.2 V Nominal Op      : %s\n", yesNo(spd[11] & 3 == 3));
    _ = c.printf(" TBD1 V Nominal Op     : %s\n", yesNo((spd[11] >> 2) & 3 == 3));
    _ = c.printf(" TBD2 V Nominal Op     : %s\n", yesNo((spd[11] >> 4) & 3 == 3));
    _ = c.printf(" Error Detect/Cor      : %s\n", tableVal2str(spd[13] >> 3, &tables.ddr3_ecc_vals));
    _ = c.printf(" Manufacturer          : %s\n", manufacturer(spd[320] & 127, spd[321]));
    const year = @as(c_int, spd[323] >> 4) * 10 + @as(c_int, spd[323] & 15);
    const week = @as(c_int, spd[324] >> 4) * 10 + @as(c_int, spd[324] & 15);
    _ = c.printf(" Manufacture Date      : year %4d week %2d\n", 2000 + year, week);
    printSerial(spd[325..329]);
    _ = c.printf(" Part Number           : ");
    for (spd[329..349]) |byte| _ = c.printf("%c", @as(c_int, byte));
    _ = c.printf("\n");
}

fn printLegacy(spd: []const u8) void {
    const exponent = @as(c_int, spd[3] & 15) + @as(c_int, spd[4] & 15) - 17;
    const multiplier = (@as(c_int, spd[5] & 7) + 1) * @as(c_int, spd[17]);
    if (exponent > 0 and exponent <= 12 and multiplier > 0) {
        const size = scaled(1, @intCast(exponent)) * @as(u64, @intCast(multiplier));
        _ = c.printf(" Memory Size           : %llu MB\n", @as(c_ulonglong, size));
    } else {
        _ = c.printf(
            " Memory Size    INVALID: %d, %d, %d, %d\n",
            @as(c_int, spd[3]),
            @as(c_int, spd[4]),
            @as(c_int, spd[5]),
            @as(c_int, spd[17]),
        );
    }
    _ = c.printf(" Voltage Intf          : %s\n", tableVal2str(spd[8], &tables.spd_voltage_vals));
    _ = c.printf(" Error Detect/Cor      : %s\n", tableVal2str(spd[11], &tables.spd_config_vals));
    var bank: usize = 0;
    while (bank < 8 and spd[64 + bank] == 0x7f) : (bank += 1) {}
    _ = c.printf(" Manufacturer          : %s\n", manufacturer(@intCast(bank), spd[64 + bank]));
    if (spd[73] != 0) {
        var part: [19]u8 = @splat(0);
        @memcpy(part[0..18], spd[73..91]);
        _ = c.printf(" Part Number           : %s\n", &part);
    }
    printSerial(spd[95..99]);
}

/// `ipmi_spd_print()`: the raw-SPD and FRU-SPD paths share this decoder.
fn spdPrint(spd_data: [*c]u8, len: c_int) callconv(.c) c_int {
    if (spd_data == null or len < 92) return -1;
    const spd = spd_data[0..@intCast(len)];
    _ = c.printf(" Memory Type           : %s\n", tableVal2str(spd[2], &tables.spd_memtype_vals));
    if (spd.len < requiredLength(spd[2])) return -1;

    switch (spd[2]) {
        0x0b => printDdr3(spd),
        0x0c => printDdr4(spd),
        else => printLegacy(spd),
    }
    if (c.verbose != 0) {
        _ = c.printf("\n");
        c.printbuf(spd_data, len, "SPD DATA");
    }
    return 0;
}

/// `ipmi_spd_print_fru()`: Get FRU Info followed by 16-byte Read FRU Data
/// requests. A short/zero-length response is an error, not an infinite loop.
fn spdPrintFru(intf: *Intf, id: u8) callconv(.c) c_int {
    const sendrecv = intf.sendrecv orelse return -1;
    var msg_data = [_]u8{ id, 0, 0, 0 };
    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &msg_data;
    req.msg.data_len = 1;
    var rsp: *Response = sendrecv(intf, &req) orelse {
        _ = c.printf(" Device not present (No Response)\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        _ = c.printf(" Device not present (%s)\n", c.val2str(rsp.ccode, c.completion_code_vals));
        return -1;
    }
    if (rsp.data_len < 3) {
        _ = c.printf(" Not enough buffer size");
        return -1;
    }
    const fru_size: usize = @as(usize, rsp.data[1]) << 8 | rsp.data[0];
    const access = rsp.data[2] & 1;
    log.print(c.LOG_DEBUG, "fru.size = %d bytes (accessed by %s)", .{
        @as(c_int, @intCast(fru_size)),
        if (access != 0) "words" else "bytes",
    });
    if (fru_size == 0) {
        log.print(c.LOG_ERR, " Invalid FRU size %d", .{@as(c_int, 0)});
        return -1;
    }
    const spd = std.heap.c_allocator.alloc(u8, fru_size) catch {
        _ = c.printf(" Unable to malloc memory for spd array of size=%d\n", @as(c_int, @intCast(fru_size)));
        return -1;
    };
    defer std.heap.c_allocator.free(spd);
    @memset(spd, 0);

    req.msg.cmd = c.GET_FRU_DATA;
    req.msg.data_len = 4;
    var offset: usize = 0;
    while (offset < fru_size) {
        msg_data[1] = @truncate(offset);
        msg_data[2] = @truncate(offset >> 8);
        msg_data[3] = 16;
        rsp = sendrecv(intf, &req) orelse {
            _ = c.printf(" Device not present (No Response)\n");
            return -1;
        };
        if (rsp.ccode != 0) {
            _ = c.printf(" Device not present (%s)\n", c.val2str(rsp.ccode, c.completion_code_vals));
            return if (rsp.ccode == 0xc3) 1 else -1;
        }
        if (rsp.data_len < 1) {
            _ = c.printf(" Not enough buffer size");
            return -1;
        }
        const count: usize = rsp.data[0];
        if (count == 0 or count > @as(usize, @intCast(rsp.data_len - 1)) or count > fru_size - offset) {
            _ = c.printf(" Not enough buffer size");
            return -1;
        }
        @memcpy(spd[offset..][0..count], rsp.data[1..][0..count]);
        offset += count;
    }
    return spdPrint(@ptrCast(spd.ptr), @intCast(offset));
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(spdPrint), @TypeOf(c.ipmi_spd_print));
        abi.assertCallSignature(@TypeOf(spdPrintFru), @TypeOf(c.ipmi_spd_print_fru));
        @export(&spdPrint, .{ .name = "ipmi_spd_print", .linkage = .strong });
        @export(&spdPrintFru, .{ .name = "ipmi_spd_print_fru", .linkage = .strong });
        tables.exportSymbols();
    }
}

test "SPD decoder requires every field including DDR4 part byte 348" {
    try std.testing.expectEqual(@as(usize, 100), requiredLength(0x08));
    try std.testing.expectEqual(@as(usize, 100), requiredLength(0x12));
    try std.testing.expectEqual(@as(usize, 148), requiredLength(0x0b));
    try std.testing.expectEqual(@as(usize, 349), requiredLength(0x0c));
}

test "JEDEC table boundaries and arithmetic agree with C layout" {
    try std.testing.expectEqualStrings("Micron Technology", std.mem.span(tables.jedec_id1_vals[43].str.?));
    try std.testing.expectEqualStrings("Kingston", std.mem.span(tables.jedec_id2_vals[23].str.?));
    try std.testing.expectEqual(@as(u64, 4096), scaled(256, 4));
    try std.testing.expectEqual(@as(u64, 8_388_608), scaled(256, 15));
}
