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

fn cText(text: [*c]const u8) []const u8 {
    return if (text == null) "(null)" else std.mem.span(@as([*:0]const u8, @ptrCast(text)));
}

fn printSerial(writer: *std.Io.Writer, serial: []const u8) std.Io.Writer.Error!void {
    try writer.print(" Serial Number         : {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{
        serial[0], serial[1], serial[2], serial[3],
    });
}

fn printDdr3(writer: *std.Io.Writer, spd: []const u8) std.Io.Writer.Error!void {
    const capacity = scaled(256, spd[4] & 15);
    const primary_width = scaled(8, spd[8] & 7);
    const device_width = scaled(4, spd[7] & 7);
    const ranks = scaled(1, (spd[7] & 0x3f) >> 3);
    const size = (capacity / 8) * (primary_width / device_width) * ranks;

    try writer.print(" SDRAM Capacity        : {d} MB\n", .{capacity});
    try writer.print(" Memory Banks          : {s}\n", .{cText(tableVal2str(spd[4] >> 4, &tables.ddr3_banks_vals))});
    try writer.print(" Primary Bus Width     : {d} bits\n", .{primary_width});
    try writer.print(" SDRAM Device Width    : {d} bits\n", .{device_width});
    try writer.print(" Number of Ranks       : {d}\n", .{ranks});
    try writer.print(" Memory size           : {d} MB\n", .{size});
    try writer.print(" 1.5 V Nominal Op      : {s}\n", .{std.mem.span(yesNo(spd[6] & 1 == 0))});
    try writer.print(" 1.35 V Nominal Op     : {s}\n", .{std.mem.span(yesNo(spd[6] & 2 == 0))});
    try writer.print(" 1.2X V Nominal Op     : {s}\n", .{std.mem.span(yesNo(spd[6] & 4 == 0))});
    try writer.print(" Error Detect/Cor      : {s}\n", .{cText(tableVal2str(spd[8] >> 3, &tables.ddr3_ecc_vals))});
    try writer.print(" Manufacturer          : {s}\n", .{cText(manufacturer(spd[117] & 127, spd[118]))});
    try writer.writeAll(" Manufacture Date      : year ");
    try writer.writeByte('0' + (spd[120] >> 4));
    try writer.writeByte('0' + (spd[120] & 15));
    try writer.writeAll(" week ");
    try writer.writeByte('0' + (spd[121] >> 4));
    try writer.writeByte('0' + (spd[121] & 15));
    try writer.writeByte('\n');
    try printSerial(writer, spd[122..126]);
    try writer.writeAll(" Part Number           : ");
    try writer.writeAll(spd[128..146]);
    try writer.writeByte('\n');
}

fn printDdr4(writer: *std.Io.Writer, spd: []const u8) std.Io.Writer.Error!void {
    var logical_ranks: u64 = @as(u64, (spd[12] >> 3) & 3) + 1;
    if (spd[6] & 3 == 2) logical_ranks *= @as(u64, (spd[6] >> 4) & 3) + 1;
    const capacity = scaled(256, spd[4] & 15);
    const primary_width = scaled(8, spd[13] & 7);
    const device_width = scaled(4, spd[12] & 7);
    const size = (capacity / 8) * (primary_width / device_width) * logical_ranks;

    try writer.print(" SDRAM Package Type    : {s}\n", .{cText(tableVal2str(spd[6] >> 7, &tables.ddr4_package_type))});
    try writer.print(" Technology            : {s}\n", .{cText(tableVal2str(spd[3] & 15, &tables.ddr4_technology_type))});
    try writer.print(" SDRAM Die Count       : {d}\n", .{@as(c_int, (spd[6] >> 4) & 3) + 1});
    try writer.print(" SDRAM Capacity        : {d} Mb\n", .{capacity});
    try writer.print(" Memory Bank Group     : {s}\n", .{cText(tableVal2str((spd[4] >> 6) & 3, &tables.ddr4_bank_groups))});
    try writer.print(" Memory Banks          : {s}\n", .{cText(tableVal2str((spd[4] >> 4) & 3, &tables.ddr4_banks_vals))});
    try writer.print(" Primary Bus Width     : {d} bits\n", .{primary_width});
    try writer.print(" SDRAM Device Width    : {d} bits\n", .{device_width});
    try writer.print(" Logical Rank per DIMM : {d}\n", .{logical_ranks});
    try writer.print(" Memory size           : {d} MB\n", .{size});
    try writer.print(" Memory Density        : {s}\n", .{cText(tableVal2str(spd[4] & 15, &tables.ddr4_density_vals))});
    try writer.print(" 1.2 V Nominal Op      : {s}\n", .{std.mem.span(yesNo(spd[11] & 3 == 3))});
    try writer.print(" TBD1 V Nominal Op     : {s}\n", .{std.mem.span(yesNo((spd[11] >> 2) & 3 == 3))});
    try writer.print(" TBD2 V Nominal Op     : {s}\n", .{std.mem.span(yesNo((spd[11] >> 4) & 3 == 3))});
    try writer.print(" Error Detect/Cor      : {s}\n", .{cText(tableVal2str(spd[13] >> 3, &tables.ddr3_ecc_vals))});
    try writer.print(" Manufacturer          : {s}\n", .{cText(manufacturer(spd[320] & 127, spd[321]))});
    const year = @as(c_int, spd[323] >> 4) * 10 + @as(c_int, spd[323] & 15);
    const week = @as(c_int, spd[324] >> 4) * 10 + @as(c_int, spd[324] & 15);
    try writer.print(" Manufacture Date      : year {d} week ", .{2000 + year});
    if (week < 10) try writer.writeByte(' ');
    try writer.print("{d}\n", .{week});
    try printSerial(writer, spd[325..329]);
    try writer.writeAll(" Part Number           : ");
    try writer.writeAll(spd[329..349]);
    try writer.writeByte('\n');
}

fn printLegacy(writer: *std.Io.Writer, spd: []const u8) std.Io.Writer.Error!void {
    const exponent = @as(c_int, spd[3] & 15) + @as(c_int, spd[4] & 15) - 17;
    const multiplier = (@as(c_int, spd[5] & 7) + 1) * @as(c_int, spd[17]);
    if (exponent > 0 and exponent <= 12 and multiplier > 0) {
        const size = scaled(1, @intCast(exponent)) * @as(u64, @intCast(multiplier));
        try writer.print(" Memory Size           : {d} MB\n", .{size});
    } else {
        try writer.print(" Memory Size    INVALID: {d}, {d}, {d}, {d}\n", .{
            spd[3], spd[4], spd[5], spd[17],
        });
    }
    try writer.print(" Voltage Intf          : {s}\n", .{cText(tableVal2str(spd[8], &tables.spd_voltage_vals))});
    try writer.print(" Error Detect/Cor      : {s}\n", .{cText(tableVal2str(spd[11], &tables.spd_config_vals))});
    var bank: usize = 0;
    while (bank < 8 and spd[64 + bank] == 0x7f) : (bank += 1) {}
    try writer.print(" Manufacturer          : {s}\n", .{cText(manufacturer(@intCast(bank), spd[64 + bank]))});
    if (spd[73] != 0) {
        var part: [19]u8 = @splat(0);
        @memcpy(part[0..18], spd[73..91]);
        try writer.print(" Part Number           : {s}\n", .{std.mem.sliceTo(&part, 0)});
    }
    try printSerial(writer, spd[95..99]);
}

/// `ipmi_spd_print()`: the raw-SPD and FRU-SPD paths share this decoder.
fn spdPrint(spd_data: [*c]u8, len: c_int) callconv(.c) c_int {
    if (spd_data == null or len < 92) return -1;
    return emitStdout(writeSpdPrint, .{ spd_data[0..@intCast(len)], spd_data, len, c.verbose != 0 });
}

fn writeSpdPrint(writer: *std.Io.Writer, spd: []const u8, spd_data: [*c]u8, len: c_int, verbose: bool) std.Io.Writer.Error!c_int {
    try writer.print(" Memory Type           : {s}\n", .{cText(tableVal2str(spd[2], &tables.spd_memtype_vals))});
    if (spd.len < requiredLength(spd[2])) return -1;

    switch (spd[2]) {
        0x0b => try printDdr3(writer, spd),
        0x0c => try printDdr4(writer, spd),
        else => try printLegacy(writer, spd),
    }
    if (verbose) {
        try writer.writeByte('\n');
        c.printbuf(spd_data, len, "SPD DATA");
    }
    return 0;
}

const CStdoutFlushError = error{CStdoutFlushFailed};
const SpdOutputError = std.Io.Writer.Error || CStdoutFlushError;

fn checkCStdoutFlush(result: c_int) CStdoutFlushError!void {
    if (result != 0) return error.CStdoutFlushFailed;
}

fn flushCStdout() CStdoutFlushError!void {
    try checkCStdoutFlush(c.fflush(c.stdout));
}

fn emitStdout(comptime write: anytype, args: anytype) c_int {
    // C callers may have buffered output on the same file descriptor.
    flushCStdout() catch {
        log.print(c.LOG_ERR, "SPD stdout C preflush failed (errno %d)", .{std.c._errno().*});
        return -1;
    };
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    const status = @call(.auto, write, .{&stdout.interface} ++ args) catch |err| {
        const cause: anyerror = err;
        if (cause == error.CStdoutFlushFailed) {
            log.print(c.LOG_ERR, "SPD stdout C flush after FRU callback failed (errno %d)", .{std.c._errno().*});
        } else {
            log.print(c.LOG_ERR, "SPD stdout Zig write failed: %s", .{@errorName(stdout.err orelse err).ptr});
        }
        return -1;
    };
    stdout.interface.flush() catch |err| {
        log.print(c.LOG_ERR, "SPD stdout Zig final flush failed: %s", .{@errorName(stdout.err orelse err).ptr});
        return -1;
    };
    return status;
}

/// `ipmi_spd_print_fru()`: Get FRU Info followed by 16-byte Read FRU Data
/// requests. A short/zero-length response is an error, not an infinite loop.
fn spdPrintFru(intf: *Intf, id: u8) callconv(.c) c_int {
    if (intf.sendrecv == null) return -1;
    return emitStdout(writeSpdPrintFru, .{ intf, id });
}

fn writeSpdPrintFru(writer: *std.Io.Writer, intf: *Intf, id: u8) SpdOutputError!c_int {
    const sendrecv = intf.sendrecv orelse return -1;
    var msg_data = [_]u8{ id, 0, 0, 0 };
    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.storage;
    req.msg.cmd = c.GET_FRU_INFO;
    req.msg.data = &msg_data;
    req.msg.data_len = 1;
    var rsp: *Response = sendrecv(intf, &req) orelse {
        try flushCStdout();
        try writer.writeAll(" Device not present (No Response)\n");
        return -1;
    };
    if (rsp.ccode != 0) {
        try flushCStdout();
        try writer.print(" Device not present ({s})\n", .{cText(c.val2str(rsp.ccode, c.completion_code_vals))});
        return -1;
    }
    if (rsp.data_len < 3) {
        try flushCStdout();
        try writer.writeAll(" Not enough buffer size");
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
        try flushCStdout();
        try writer.print(" Unable to malloc memory for spd array of size={d}\n", .{@as(c_int, @intCast(fru_size))});
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
            try flushCStdout();
            try writer.writeAll(" Device not present (No Response)\n");
            return -1;
        };
        if (rsp.ccode != 0) {
            try flushCStdout();
            try writer.print(" Device not present ({s})\n", .{cText(c.val2str(rsp.ccode, c.completion_code_vals))});
            return if (rsp.ccode == 0xc3) 1 else -1;
        }
        if (rsp.data_len < 1) {
            try flushCStdout();
            try writer.writeAll(" Not enough buffer size");
            return -1;
        }
        const count: usize = rsp.data[0];
        if (count == 0 or count > @as(usize, @intCast(rsp.data_len - 1)) or count > fru_size - offset) {
            try flushCStdout();
            try writer.writeAll(" Not enough buffer size");
            return -1;
        }
        @memcpy(spd[offset..][0..count], rsp.data[1..][0..count]);
        offset += count;
    }
    try flushCStdout();
    return writeSpdPrint(writer, spd, @ptrCast(spd.ptr), @intCast(offset), c.verbose != 0);
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

test "SPD decoder stdout serial hex matches libc for every byte" {
    var serial = [_]u8{ 0, 9, 0x80, 0xff };
    var storage: [64]u8 = undefined;
    var c_storage: [64]u8 = undefined;
    for (0..256) |value| {
        serial[0] = @intCast(value);
        var writer = std.Io.Writer.fixed(&storage);
        try printSerial(&writer, &serial);
        const len = c.snprintf(&c_storage, c_storage.len, " Serial Number         : %02x%02x%02x%02x\n", @as(c_uint, serial[0]), @as(c_uint, serial[1]), @as(c_uint, serial[2]), @as(c_uint, serial[3]));
        try std.testing.expect(len > 0 and len < c_storage.len);
        try std.testing.expectEqualSlices(u8, c_storage[0..@intCast(len)], writer.buffered());
    }
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, printSerial(&failing, &serial));
}

test "SPD decoder stdout preserves decimal, byte-hex, raw part numbers and manufacturer text" {
    var spd: [349]u8 = @splat(0);
    spd[2] = 0x0b;
    spd[4] = 0x0f;
    spd[117] = 9;
    spd[120] = 0xaf;
    spd[121] = 0x01;
    spd[122] = 0x00;
    spd[123] = 0x09;
    spd[124] = 0x80;
    spd[125] = 0xff;
    spd[128] = 0;
    spd[129] = 0x80;
    spd[130] = 0xff;
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try writeSpdPrint(&writer, spd[0..148], &spd, 148, false));
    const ddr3 = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, ddr3, " SDRAM Capacity        : 8388608 MB\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr3, " Manufacturer          : JEDEC JEP106 update required\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr3, " Manufacture Date      : year :? week 01\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr3, " Serial Number         : 000980ff\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr3, " Part Number           : \x00\x80\xff") != null);
    try std.testing.expectEqual(@as(u8, '\n'), ddr3[ddr3.len - 1]);

    spd[2] = 0x0c;
    spd[4] = 0x0f;
    spd[320] = 9;
    spd[321] = 23;
    spd[323] = 0x25;
    spd[324] = 0x02;
    spd[325] = 0x00;
    spd[326] = 0x09;
    spd[327] = 0x80;
    spd[328] = 0xff;
    spd[329] = 0;
    spd[330] = 0xff;
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try writeSpdPrint(&writer, &spd, &spd, 349, false));
    const ddr4 = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, ddr4, " SDRAM Capacity        : 8388608 Mb\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr4, " Manufacturer          : JEDEC JEP106 update required\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr4, " Manufacture Date      : year 2025 week  2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr4, " Serial Number         : 000980ff\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ddr4, " Part Number           : \x00\xff") != null);
    spd[324] = 0xff;
    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try writeSpdPrint(&writer, &spd, &spd, 349, false));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " year 2025 week 165\n") != null);
}

test "SPD decoder stdout legacy invalid size and C-string part truncation" {
    var spd: [100]u8 = @splat(0);
    spd[2] = 8;
    @memset(spd[64..72], 0x7f);
    spd[72] = 1;
    spd[73] = 'A';
    spd[74] = 0;
    spd[75] = 0xff;
    spd[95] = 0xa0;
    spd[96] = 0x0b;
    spd[97] = 0;
    spd[98] = 0xff;
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try writeSpdPrint(&writer, &spd, &spd, 100, false));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " Memory Size    INVALID: 0, 0, 0, 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " Manufacturer          : ") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " Part Number           : A\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), " Serial Number         : a00b00ff\n") != null);
}

test "SPD decoder stdout short input emits only memory type and propagates writer failures" {
    var spd: [349]u8 = @splat(0);
    spd[2] = 0x0c;
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, -1), try writeSpdPrint(&writer, spd[0..92], &spd, 92, false));
    // The standalone unit binary stubs val2str() with an empty string.
    try std.testing.expectEqualStrings(" Memory Type           : \n", writer.buffered());
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeSpdPrint(&failing, spd[0..92], &spd, 92, false));
    try std.testing.expectError(error.WriteFailed, writeSpdPrint(&failing, &spd, &spd, 349, false));

    writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, 0), try writeSpdPrint(&writer, &spd, &spd, 349, false));
    const size = writer.buffered().len;
    var short: [2048]u8 = undefined;
    var late = std.Io.Writer.fixed(short[0 .. size - 1]);
    try std.testing.expectError(error.WriteFailed, writeSpdPrint(&late, &spd, &spd, 349, false));
    try std.testing.expectEqualSlices(u8, writer.buffered()[0 .. size - 1], late.buffered());
}

fn noSpdResponse(_: *Intf, _: *Request) callconv(.c) ?*Response {
    return null;
}

test "SPD decoder stdout FRU failure message propagates writer errors" {
    var intf: Intf = std.mem.zeroes(Intf);
    intf.sendrecv = &noSpdResponse;
    var storage: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectEqual(@as(c_int, -1), try writeSpdPrintFru(&writer, &intf, 1));
    try std.testing.expectEqualStrings(" Device not present (No Response)\n", writer.buffered());

    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeSpdPrintFru(&failing, &intf, 1));
    var late = std.Io.Writer.fixed(storage[0 .. writer.buffered().len - 1]);
    try std.testing.expectError(error.WriteFailed, writeSpdPrintFru(&late, &intf, 1));
}

test "SPD decoder stdout tags C flush failures separately from Zig write failures" {
    try checkCStdoutFlush(0);
    try std.testing.expectError(error.CStdoutFlushFailed, checkCStdoutFlush(-1));
    var failing: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, printSerial(&failing, &.{ 0, 1, 2, 3 }));
}
