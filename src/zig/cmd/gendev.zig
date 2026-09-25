//! Port of `lib/ipmi_gendev.c`: generic locator listing and EEPROM read/write.
//! Selected with `-Dzig-modules=gendev`; the only exported symbol is
//! `ipmi_gendev_main`. I2C, SDR lookup, safe file opening and logging still
//! use the existing C ABI.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Response = @import("../core/ipmi.zig").Response;

const max_transfer: u8 = 16;
const retry_count: u8 = 3; // The C loop increments twice per failure (0, 2, 4).
const generic_locator: u8 = @intCast(c.SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR);

// translate-c loses ATTRIBUTE_PACKING on the SDR list and demotes the
// locator's bitfields to opaque. Both mirrors are checked against C layouts.
const SdrRecordList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrRecordList align(1),
    record: ?*const GenLocator align(1),
};

const GenLocator = extern struct {
    access: u8,
    slave: u8,
    flags: u8,
    span_flags: u8,
    reserved: u8,
    device_type: u8,
    modifier: u8,
    entity: [2]u8,
    oem: u8,
    id_code: u8,
    id_string: [16]u8,

    fn channel(self: *const GenLocator) u8 {
        return self.flags >> 5;
    }

    fn bus(self: *const GenLocator) u8 {
        return self.flags & 7;
    }

    fn span(self: *const GenLocator) u8 {
        return self.span_flags >> 5;
    }
};

const Eeprom = struct {
    size: u32,
    page_size: u16,
    address_length: u8,
    span: u8,
};

fn eepromInfo(dev: *const GenLocator) ?Eeprom {
    const spec: struct { u32, u16, u8 } = switch (dev.device_type) {
        0x08 => .{ 128, 8, 1 },
        0x09 => .{ 256, 8, 1 },
        0x0a => .{ 512, 8, 2 },
        0x0b => .{ 1024, 8, 2 },
        0x0c, 0x0d => .{ 2048, 256, 2 },
        0x0e => .{ 4096, 8, 2 },
        0x0f => .{ 8192, 32, 2 },
        0xc0 => .{ 16384, 64, 2 },
        0xc1 => .{ 32748, 64, 2 }, // C's table says 32748, not 32768.
        0xc2 => .{ 65536, 128, 2 },
        0xc3 => .{ 131072, 128, 2 },
        else => return null,
    };
    return .{
        .size = spec.@"0",
        .page_size = spec.@"1",
        .address_length = spec.@"2",
        .span = dev.span(),
    };
}

fn busByte(dev: *const GenLocator) u8 {
    return (dev.channel() << 4) | (dev.bus() << 1) | 1;
}

// An EEPROM larger than the two-byte offset must have enough adjacent I2C
// addresses for banking. Smaller EEPROMs preserve the C oracle's addressing.
fn addressRangeValid(dev: *const GenLocator, info: Eeprom) bool {
    const addressable = @as(u32, 1) << @as(u5, @intCast(info.address_length * 8));
    if (info.size <= addressable) return true;
    const banks = @as(u32, info.span) + 1;
    return !(banks <= 1 or info.size % banks != 0 or info.size / banks > addressable or
        @as(u16, dev.slave) + @as(u16, info.span) * 2 > 255);
}

fn validAddressRange(dev: *const GenLocator, info: Eeprom) bool {
    if (addressRangeValid(dev, info)) return true;
    c.lprintf(log.Level.err, "EEPROM size exceeds address range");
    return false;
}

fn deviceAddress(dev: *const GenLocator, info: Eeprom, offset: u32) u8 {
    if (info.size <= 65536) return dev.slave;
    const bank_size = info.size / (@as(u32, info.span) + 1);
    return @intCast(@as(u32, dev.slave) + 2 * (offset / bank_size));
}

fn memoryOffset(info: Eeprom, offset: u32) u32 {
    if (info.size <= 65536) return offset;
    return offset % (info.size / (@as(u32, info.span) + 1));
}

fn transferSize(info: Eeprom, offset: u32) u8 {
    return @intCast(@min(info.size - offset, @as(u32, @min(info.page_size, max_transfer))));
}

fn transfer(
    intf: *Intf,
    dev: *const GenLocator,
    info: Eeprom,
    offset: u32,
    wr: *[max_transfer + 2]u8,
    write_len: u8,
    read_len: u8,
) ?*Response {
    const addr = deviceAddress(dev, info, offset);
    for (0..retry_count) |_| {
        const rsp = c.ipmi_master_write_read(
            @ptrCast(intf),
            busByte(dev),
            addr,
            &wr[0],
            write_len,
            read_len,
        );
        if (rsp != null) return @ptrCast(rsp);
        c.lprintf(log.Level.err, "Retry");
        _ = c.sleep(1);
    }
    return null;
}

fn progress(counter: u32, size: u32, previous: *u8, percent: *u8) void {
    percent.* = @intCast(counter * 100 / size);
    if (percent.* != previous.*) {
        _ = c.printf("\r%i percent completed", @as(c_int, percent.*));
        previous.* = percent.*;
    }
}

fn finishProgress(completed: bool, percent: u8) void {
    if (completed) {
        _ = c.printf("\r%%100 percent completed\n");
    } else {
        _ = c.printf("\rError: %i percent completed, read not completed \n", @as(c_int, percent));
    }
}

fn readFile(intf: *Intf, dev: *const GenLocator, filename: [*:0]const u8) c_int {
    const info = eepromInfo(dev) orelse {
        c.lprintf(log.Level.err, "The selected generic device is not an eeprom");
        return -1;
    };
    if (!validAddressRange(dev, info)) return -1;

    const fp = c.ipmi_open_file(filename, 1);
    if (fp == null) return -1;
    var rc: c_int = 0;
    var counter: u32 = 0;
    var percent: u8 = 0;
    var previous: u8 = 101;

    while (counter < info.size) {
        const chunk = transferSize(info, counter);
        const address = memoryOffset(info, counter);
        var wr: [max_transfer + 2]u8 = undefined;
        wr[0] = @truncate(address);
        if (info.address_length == 2) wr[1] = @truncate(address >> 8);
        const rsp = transfer(intf, dev, info, counter, &wr, info.address_length, chunk) orelse {
            rc = -1;
            break;
        };
        if (rsp.data_len < chunk) {
            c.lprintf(log.Level.err, "Short I2C Master Write-Read response: %d of %d bytes", rsp.data_len, @as(c_int, chunk));
            rc = -1;
            break;
        }
        if (c.fwrite(&rsp.data[0], 1, chunk, fp) != chunk) {
            c.lprintf(log.Level.err, "Error writing file %s", filename);
            rc = -1;
            break;
        }
        progress(counter, info.size, &previous, &percent);
        counter += chunk;
    }

    finishProgress(counter == info.size, percent);
    if (c.fclose(fp) != 0) {
        c.lprintf(log.Level.err, "Error closing file %s", filename);
        rc = -1;
    }
    return rc;
}

fn writeFile(intf: *Intf, dev: *const GenLocator, filename: [*:0]const u8) c_int {
    const info = eepromInfo(dev) orelse {
        c.lprintf(log.Level.err, "The selected generic device is not an eeprom");
        return -1;
    };
    if (!validAddressRange(dev, info)) return -1;

    const fp = c.ipmi_open_file(filename, 0);
    if (fp == null) return -1;
    if (c.fseek(fp, 0, c.SEEK_END) != 0) {
        c.lprintf(log.Level.err, "Error seeking file %s", filename);
        _ = c.fclose(fp);
        return -1;
    }
    const length = c.ftell(fp);
    c.lprintf(log.Level.err, "File   Size: %i", @as(c_int, @truncate(length)));
    c.lprintf(log.Level.err, "Eeprom Size: %i", @as(c_int, @intCast(info.size)));
    if (length != info.size) {
        c.lprintf(log.Level.err, "File size does not fit Eeprom Size");
        _ = c.fclose(fp);
        return -1;
    }
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) {
        c.lprintf(log.Level.err, "Error seeking file %s", filename);
        _ = c.fclose(fp);
        return -1;
    }

    var rc: c_int = 0;
    var counter: u32 = 0;
    var percent: u8 = 0;
    var previous: u8 = 101;
    while (counter < info.size) {
        const chunk = transferSize(info, counter);
        const address = memoryOffset(info, counter);
        var wr: [max_transfer + 2]u8 = undefined;
        wr[0] = @truncate(address);
        if (info.address_length == 2) wr[1] = @truncate(address >> 8);
        if (c.fread(&wr[info.address_length], 1, chunk, fp) != chunk) {
            c.lprintf(log.Level.err, "Error reading file %s", filename);
            rc = -1;
            break;
        }
        if (transfer(intf, dev, info, counter, &wr, info.address_length + chunk, 0) == null) {
            rc = -1;
            break;
        }
        progress(counter, info.size, &previous, &percent);
        counter += chunk;
    }

    finishProgress(counter == info.size, percent);
    if (c.fclose(fp) != 0) {
        c.lprintf(log.Level.err, "Error closing file %s", filename);
        rc = -1;
    }
    return rc;
}

fn main(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    const command: ?[*:0]u8 = if (argc > 0) argv[0] else null;
    c.lprintf(log.Level.err, "Rx gendev command: %s", command);

    if (argc <= 0 or std.mem.eql(u8, std.mem.span(command.?), "help")) {
        c.lprintf(log.Level.err, "SDR Commands:  list read write");
        c.lprintf(log.Level.err, "                     list                     List All Generic Device Locators");
        c.lprintf(log.Level.err, "                     read <sdr name> <file>   Read to file eeprom specify by Generic Device Locators");
        c.lprintf(log.Level.err, "                     write <sdr name> <file>  Write from file eeprom specify by Generic Device Locators");
        return 0;
    }
    if (std.mem.eql(u8, std.mem.span(command.?), "list")) {
        return c.ipmi_sdr_print_sdr(@ptrCast(intf), generic_locator);
    }
    const is_read = std.mem.eql(u8, std.mem.span(command.?), "read");
    const is_write = std.mem.eql(u8, std.mem.span(command.?), "write");
    if (!is_read and !is_write) {
        c.lprintf(log.Level.err, "Invalid gendev command: %s", command);
        return -1;
    }
    if (argc < 3) {
        if (is_read)
            c.lprintf(log.Level.err, "usage: gendev read <gendev> <filename>")
        else
            c.lprintf(log.Level.err, "usage: gendev write <gendev> <filename>");
        return -1;
    }
    c.lprintf(log.Level.err, if (is_read) "Gendev read sdr name : %s" else "Gendev write sdr name : %s", argv[1]);
    _ = c.printf("Locating sensor record '%s'...\n", argv[1]);
    const found = c.ipmi_sdr_find_sdr_byid(@ptrCast(intf), argv[1]);
    if (found == null) {
        c.lprintf(log.Level.err, "Sensor data record not found!");
        return -1;
    }
    const sdr: *const SdrRecordList = @ptrCast(found);
    if (sdr.type != generic_locator) {
        c.lprintf(log.Level.err, "Target SDR is not a generic device locator");
        return -1;
    }
    const dev = sdr.record orelse {
        c.lprintf(log.Level.err, "Generic device locator record is missing");
        return -1;
    };
    c.lprintf(log.Level.err, if (is_read) "Gendev read file name: %s" else "Gendev write file name: %s", argv[2]);
    if (is_read) return readFile(intf, dev, argv[2]);
    return writeFile(intf, dev, argv[2]);
}

pub fn exportSymbols() void {
    comptime {
        abi.assertOpaqueLayout(SdrRecordList, .{
            .size = c.ABI_SIZEOF_sdr_record_list,
            .alignment = 1,
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
        abi.assertOpaqueLayout(GenLocator, .{
            .size = c.ABI_SIZEOF_sdr_genloc,
            .alignment = c.ABI_ALIGNOF_sdr_genloc,
            .fields = &.{
                .{ .name = "slave", .offset = c.ABI_OFFSETOF_sdr_genloc__slave },
                .{ .name = "device_type", .offset = c.ABI_OFFSETOF_sdr_genloc__type },
                .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_genloc__id_string },
            },
        });
        abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_gendev_main));
        @export(&main, .{ .name = "ipmi_gendev_main", .linkage = .strong });
    }
}

test "EEPROM table and address boundaries" {
    var dev = std.mem.zeroes(GenLocator);
    for ([_]struct { u8, u32, u8 }{
        .{ 0x08, 128, 1 },   .{ 0x09, 256, 1 },   .{ 0x0a, 512, 2 },
        .{ 0x0b, 1024, 2 },  .{ 0x0c, 2048, 2 },  .{ 0x0d, 2048, 2 },
        .{ 0x0e, 4096, 2 },  .{ 0x0f, 8192, 2 },  .{ 0xc0, 16384, 2 },
        .{ 0xc1, 32748, 2 }, .{ 0xc2, 65536, 2 }, .{ 0xc3, 131072, 2 },
    }) |entry| {
        dev.device_type = entry.@"0";
        const info = eepromInfo(&dev).?;
        try std.testing.expectEqual(entry.@"1", info.size);
        try std.testing.expectEqual(entry.@"2", info.address_length);
    }
    dev.device_type = 0x07;
    try std.testing.expect(eepromInfo(&dev) == null);

    dev.device_type = 0xc1;
    var info = eepromInfo(&dev).?;
    try std.testing.expectEqual(@as(u8, 16), transferSize(info, 32720));
    try std.testing.expectEqual(@as(u8, 12), transferSize(info, 32736));

    dev.device_type = 0xc3;
    info = eepromInfo(&dev).?;
    try std.testing.expect(!addressRangeValid(&dev, info));
    dev.span_flags = 0x20;
    dev.slave = 0xa4;
    info = eepromInfo(&dev).?;
    try std.testing.expect(addressRangeValid(&dev, info));
    try std.testing.expectEqual(@as(u8, 0xa4), deviceAddress(&dev, info, 65535));
    try std.testing.expectEqual(@as(u8, 0xa6), deviceAddress(&dev, info, 65536));
    try std.testing.expectEqual(@as(u32, 0), memoryOffset(info, 65536));
    dev.slave = 0xff;
    try std.testing.expect(!addressRangeValid(&dev, info));
}
