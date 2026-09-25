//! Offline FRU/PICMG eKey analyzer. Replaces `lib/ipmi_ekanalyzer.c`.
//! The FRU and PICMG commands are independent of this module: their shared
//! contract is the on-disk FRU format and the C ABI in `ipmi_ekanalyzer.h`.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const ValStr = @import("../util/helper.zig").ValStr;

const star = "*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*-*";
const equal = "=================================================================";
const error_status: c_int = -1;
const ok_status: c_int = 0;
const star_ptr: [*:0]const u8 = star;
const equal_ptr: [*:0]const u8 = equal;
const size_of_file_type: c_int = 3;
const amc_module: u8 = 0x80;
const picmg_id_offset: c_int = 3;
const compare_candidate: c_uint = 2;
const start_data_offset: c_int = 5;
const lower_oem_type: c_int = 0xf0;
const upper_oem_type: c_int = 0xfe;
const disable_port: u8 = 0x1f;

const module_type = [_]ValStr{
    .{ .val = 9, .str = "On-Carrier Device" },   .{ .val = 1, .str = "AMC slot A1" },
    .{ .val = 2, .str = "AMC slot A2" },         .{ .val = 3, .str = "AMC slot A3" },
    .{ .val = 4, .str = "AMC slot A4" },         .{ .val = 5, .str = "AMC slot B1" },
    .{ .val = 6, .str = "AMC slot B2" },         .{ .val = 7, .str = "AMC slot B3" },
    .{ .val = 8, .str = "AMC slot B4" },         .{ .val = 0, .str = "RTM" },
    .{ .val = 10, .str = "Configuration file" }, .{ .val = 11, .str = "Shelf Manager" },
    .{ .val = 0xffff, .str = null },
};
const ipmbl_addr = [_]ValStr{
    .{ .val = 0x72, .str = "AMC slot A1" }, .{ .val = 0x74, .str = "AMC slot A2" },
    .{ .val = 0x76, .str = "AMC slot A3" }, .{ .val = 0x78, .str = "AMC slot A4" },
    .{ .val = 0x7a, .str = "AMC slot B1" }, .{ .val = 0x7c, .str = "AMC slot B2" },
    .{ .val = 0x7e, .str = "AMC slot B3" }, .{ .val = 0x80, .str = "AMC slot B4" },
    .{ .val = 0x90, .str = "RTM" },         .{ .val = 0xffff, .str = null },
};
const link_type = [_]ValStr{
    .{ .val = 0, .str = "Reserved" },                             .{ .val = 1, .str = "Reserved" },
    .{ .val = 2, .str = "AMC.1 PCI Express" },                    .{ .val = 3, .str = "AMC.1 PCI Express Advanced Switching" },
    .{ .val = 4, .str = "AMC.1 PCI Express Advanced Switching" }, .{ .val = 5, .str = "AMC.2 Ethernet" },
    .{ .val = 6, .str = "AMC.4 Serial RapidIO" },                 .{ .val = 7, .str = "AMC.3 Storage" },
    .{ .val = 0xf0, .str = "OEM Type 0" },                        .{ .val = 0xf1, .str = "OEM Type 1" },
    .{ .val = 0xf2, .str = "OEM Type 2" },                        .{ .val = 0xf3, .str = "OEM Type 3" },
    .{ .val = 0xf4, .str = "OEM Type 4" },                        .{ .val = 0xf5, .str = "OEM Type 5" },
    .{ .val = 0xf6, .str = "OEM Type 6" },                        .{ .val = 0xf7, .str = "OEM Type 7" },
    .{ .val = 0xf8, .str = "OEM Type 8" },                        .{ .val = 0xf9, .str = "OEM Type 9" },
    .{ .val = 0xfa, .str = "OEM Type 10" },                       .{ .val = 0xfb, .str = "OEM Type 11" },
    .{ .val = 0xfc, .str = "OEM Type 12" },                       .{ .val = 0xfd, .str = "OEM Type 13" },
    .{ .val = 0xfe, .str = "OEM Type 14" },                       .{ .val = 0xff, .str = "Reserved" },
    .{ .val = 0xffff, .str = null },
};
const pcie_ext = [_]ValStr{
    .{ .val = 0, .str = "Gen 1 capable - non SSC" },
    .{ .val = 1, .str = "Gen 1 capable - SSC" },
    .{ .val = 2, .str = "Gen 2 capable - non SSC" },
    .{ .val = 3, .str = "Gen 3 capable - SSC" },
    .{ .val = 15, .str = "Reserved" },
    .{ .val = 0xffff, .str = null },
};
const ethernet_ext = [_]ValStr{
    .{ .val = 0, .str = "1000BASE-BX (SerDES Gigabit) Ethernet link" },
    .{ .val = 1, .str = "10GBASE-BX4 10 Gigabit Ethernet link" },
    .{ .val = 0xffff, .str = null },
};
const storage_ext = [_]ValStr{
    .{ .val = 0, .str = "Fibre Channel  (FC)" },
    .{ .val = 1, .str = "Serial ATA (SATA)" },
    .{ .val = 2, .str = "Serial Attached SCSI (SAS/SATA)" },
    .{ .val = 0xffff, .str = null },
};
const pcie_asym = [_]ValStr{
    .{ .val = 0, .str = "exact match" },
    .{ .val = 1, .str = "provides a Primary PCI Express Port" },
    .{ .val = 2, .str = "provides a Secondary PCI Express Port" },
    .{ .val = 0xffff, .str = null },
};
const storage_asym = [_]ValStr{
    .{ .val = 0, .str = "FC or SAS interface {exact match}" },
    .{ .val = 1, .str = "SATA Server interface" },
    .{ .val = 2, .str = "SATA Client interface" },
    .{ .val = 3, .str = "Reserved" },
    .{ .val = 0xffff, .str = null },
};
const record_id = [_]ValStr{
    .{ .val = 0x04, .str = "Backplane Point to Point Connectivity Record" },
    .{ .val = 0x10, .str = "Address Table Record" },
    .{ .val = 0x11, .str = "Shelf Power Distribution Record" },
    .{ .val = 0x12, .str = "Shelf Activation and Power Management Record" },
    .{ .val = 0x13, .str = "Shelf Manager IP Connection Record" },
    .{ .val = 0x14, .str = "Board Point to Point Connectivity Record" },
    .{ .val = 0x15, .str = "Radial IPMB-0 Link Mapping Record" },
    .{ .val = 0x16, .str = "Module Current Requirements Record" },
    .{ .val = 0x17, .str = "Carrier Activation and Power Management Record" },
    .{ .val = 0x18, .str = "Carrier Point-to-Point Connectivity Record" },
    .{ .val = 0x19, .str = "AdvancedMC Point-to-Point Connectivity Record" },
    .{ .val = 0x1a, .str = "Carrier Information Table" },
    .{ .val = 0x1b, .str = "Shelf Fan Geography Record" },
    .{ .val = 0x2c, .str = "Carrier Clock Point-to-Point Connectivity Record" },
    .{ .val = 0x2d, .str = "Clock Configuration Record" },
    .{ .val = 0xffff, .str = null },
};

fn value(n: u32, table: []const ValStr) [*c]const u8 {
    return c.val2str(n, @ptrCast(table.ptr));
}

const Allocator = std.mem.Allocator;
const Record = struct {
    typ: u8,
    format: u8,
    checksum: u8,
    header_checksum: u8,
    data: []const u8,

    fn id(self: Record) u8 {
        return if (self.data.len > 3) self.data[3] else 0xff;
    }
};
const File = struct {
    name: [*:0]const u8,
    kind: u8,
    data: []const u8,
    records: []const Record = &.{},
};

fn getFileType(arg: []const u8) ?u8 {
    if (arg.len <= 2 or arg[2] != '=') return null;
    const prefixes = [_][]const u8{ "rt", "a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4", "oc", "rc", "sm" };
    for (prefixes, 0..) |prefix, index| {
        if (std.mem.eql(u8, arg[0..2], prefix)) return @intCast(index);
    }
    return null;
}

fn usage() void {
    c.lprintf(log.Level.notice, "Ekeying analyzer tool version 1.00");
    c.lprintf(log.Level.notice, "ekanalyzer Commands:");
    c.lprintf(log.Level.notice, "      print    [carrier | power | all] <oc=filename1> <b1=filename2>...");
    c.lprintf(log.Level.notice, "      frushow  <b2=filename>");
    c.lprintf(log.Level.notice, "      summary  [match | unmatch | all] <oc=filename1> <b1=filename2>...");
}

fn readFile(gpa: Allocator, name: [*:0]const u8, is_frushow: bool) ?[]const u8 {
    const fp = c.fopen(name, "rb") orelse {
        if (is_frushow) {
            c.lprintf(log.Level.err, "File '%s' not found.", name);
        } else {
            c.lprintf(log.Level.err, "File: '%s' is not found", name);
        }
        return null;
    };
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return null;
    const length = c.ftell(fp);
    if (length < 0 or length > 16 * 1024 * 1024 or c.fseek(fp, 0, c.SEEK_SET) != 0) {
        c.lprintf(log.Level.err, "Invalid FRU file size");
        return null;
    }
    const bytes = gpa.alloc(u8, @intCast(length)) catch {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    };
    if (bytes.len != 0 and c.fread(bytes.ptr, 1, bytes.len, fp) != bytes.len) {
        c.lprintf(log.Level.err, "Invalid FRU file data!");
        return null;
    }
    return bytes;
}

fn parseRecords(gpa: Allocator, file: *File) bool {
    const data = file.data;
    if (data.len <= 5) {
        c.lprintf(log.Level.err, "Invalid Offset!");
        return false;
    }
    if (data[5] == 0) {
        c.lprintf(log.Level.err, "There is no multi record in the file '%s'", file.name);
        return false;
    }
    var offset: usize = @as(usize, data[5]) * 8;
    c.lprintf(log.Level.debug, "start multi offset = 0x%02x", @as(c_uint, @intCast(offset)));
    var records: std.ArrayList(Record) = .empty;
    while (true) {
        if (offset > data.len or data.len - offset < 5) {
            c.lprintf(log.Level.err, "Invalid Header!");
            return false;
        }
        const len: usize = data[offset + 2];
        if (len == 0 or data.len - offset - 5 < len) {
            c.lprintf(log.Level.err, "Invalid Record Data!");
            return false;
        }
        const item: Record = .{
            .typ = data[offset],
            .format = data[offset + 1],
            .checksum = data[offset + 3],
            .header_checksum = data[offset + 4],
            .data = data[offset + 5 ..][0..len],
        };
        if (c.verbose > 0) _ = c.printf("Record %d has length = %02x\n", @as(c_int, @intCast(records.items.len)), @as(c_uint, @intCast(len)));
        if (c.verbose > 1) {
            _ = c.printf("Type: %02x", @as(c_uint, item.typ));
            for (item.data, 0..) |byte, i| {
                if (i % 8 == 0) _ = c.printf("\n0x%02x: ", @as(c_uint, @intCast(i)));
                _ = c.printf("%02x ", @as(c_uint, byte));
            }
            _ = c.printf("\n\n");
        }
        records.append(gpa, item) catch {
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
            return false;
        };
        offset += 5 + len;
        if (item.format & 0x80 != 0) break;
    }
    file.records = records.items;
    return true;
}

fn header(data: []const u8) bool {
    if (data.len < 8) {
        c.lprintf(log.Level.err, "Failed to read FRU header!");
        return false;
    }
    _ = c.printf("%s\nFRU Header Info\n%s\n", equal, equal);
    _ = c.printf("Format Version          :0x%02x %s\n", @as(c_uint, data[0] & 15), @as([*:0]const u8, if (data[0] & 15 == 1) "" else "{unsupported}"));
    _ = c.printf("Internal Use Offset     :0x%02x\n", @as(c_uint, data[1]));
    _ = c.printf("Chassis Info Offset     :0x%02x\n", @as(c_uint, data[2]));
    _ = c.printf("Board Info Offset       :0x%02x\n", @as(c_uint, data[3]));
    _ = c.printf("Product Info Offset     :0x%02x\n", @as(c_uint, data[4]));
    _ = c.printf("MultiRecord Offset      :0x%02x\n", @as(c_uint, data[5]));
    _ = c.printf("Common header Checksum  :0x%02x\n", @as(c_uint, data[7]));
    return true;
}

fn field(area: []const u8, offset: *usize, title: [*:0]const u8, remaining: *usize) bool {
    if (offset.* >= area.len or remaining.* == 0) {
        c.lprintf(log.Level.err, "Invalid Length!");
        return false;
    }
    const size_type = area[offset.*];
    offset.* += 1;
    remaining.* -= 1;
    const count: usize = size_type & 0x3f;
    if (count == 0) {
        _ = c.printf("%s: None\n", title);
        return true;
    }
    if (count > area.len - offset.* or count > remaining.*) {
        c.lprintf(log.Level.err, "Invalid board type size!");
        return false;
    }
    _ = c.printf("%s type: 0x%02x\n%s: ", title, @as(c_uint, size_type), title);
    var encoded: [64]u8 = undefined;
    encoded[0] = size_type;
    @memcpy(encoded[1..][0..count], area[offset.*..][0..count]);
    var pos: u32 = 0;
    const decoded = c.get_fru_area_str(&encoded, &pos);
    if (decoded != null) {
        _ = c.printf("%s\n", decoded);
        c.free(decoded);
    } else _ = c.printf("\n");
    offset.* += count;
    remaining.* -= count;
    return true;
}

fn custom(area: []const u8, offset: *usize, remaining: *usize) void {
    var count: usize = 0;
    while (offset.* < area.len and remaining.* > 0) {
        if (area[offset.*] == 0xc1) {
            _ = c.printf("%s (0xc1)\n", @as([*:0]const u8, if (count == 0) "No Additional Custom Mfg. fields" else "End of Custom Mfg. fields"));
            offset.* += 1;
            remaining.* -= 1;
            if (remaining.* > 1) _ = c.printf("Unused space: %d (bytes)\n", @as(c_int, @intCast(remaining.* - 1)));
            if (area.len != 0) _ = c.printf("Checksum: 0x%02x\n", @as(c_uint, area[area.len - 1]));
            return;
        }
        const length = area[offset.*] & 0x3f;
        _ = c.printf("Additional Custom Mfg. length: 0x%02x\n", @as(c_uint, area[offset.*]));
        if (length >= remaining.*) {
            _ = c.printf("ERROR: File has insufficient data (%d bytes) for the Additional Custom Mfg. field\n", @as(c_int, @intCast(remaining.* - 1)));
            return;
        }
        if (offset.* + 1 + length > area.len) {
            c.lprintf(log.Level.err, "Invalid Additional Data!");
            return;
        }
        var encoded: [64]u8 = undefined;
        encoded[0] = area[offset.*];
        @memcpy(encoded[1..][0..length], area[offset.* + 1 ..][0..length]);
        var index: u32 = 0;
        const decoded = c.get_fru_area_str(&encoded, &index);
        if (decoded != null) {
            _ = c.printf("Additional Custom Mfg. Data: %s\n", decoded);
            c.free(decoded);
        }
        offset.* += 1 + length;
        remaining.* -= 1 + length;
        count += 1;
    }
}

fn showArea(data: []const u8, block: u8, kind: enum { chassis, board, product }) bool {
    if (block == 0) return true;
    const start = @as(usize, block) * 8;
    const title: [*:0]const u8 = switch (kind) {
        .chassis => "Chassis Info Area",
        .board => "FRU Board Info Area",
        .product => "Product Info Area",
    };
    _ = c.printf("%s\n%s\n%s\n", equal, title, equal);
    if (start >= data.len) {
        c.lprintf(log.Level.err, if (kind == .product) "Invalid Data!" else "Invalid FRU Format Version!");
        return false;
    }
    const byte_len: usize = if (start + 1 < data.len) @as(usize, data[start + 1]) * 8 else 0;
    if (byte_len < 3) {
        c.lprintf(log.Level.err, "Invalid FRU Area Length!");
        return false;
    }
    const area = data[start..][0..@min(byte_len, data.len - start)];
    var pos: usize = 2;
    var remaining: usize = byte_len - 2;
    if (kind == .board) {
        _ = c.printf("Format Version: %d\nArea Length: %d\n", @as(c_int, area[0] & 15), @as(c_int, @intCast(byte_len)));
    } else {
        _ = c.printf("Format Version Number: %d\nArea Length: %d\n", @as(c_int, area[0] & 15), @as(c_int, @intCast(byte_len)));
    }
    if (pos >= area.len) return false;
    if (kind == .chassis) {
        _ = c.printf("Chassis Type: %d\n", @as(c_int, area[pos]));
        pos += 1;
        remaining -= 1;
        if (!field(area, &pos, "Chassis Part Number", &remaining)) return false;
        if (!field(area, &pos, "Chassis Serial Number", &remaining)) return false;
    } else {
        _ = c.printf("Language Code: %d\n", @as(c_int, area[pos]));
        pos += 1;
        remaining -= 1;
        if (kind == .board) {
            if (pos + 3 > area.len) return false;
            const minutes: u32 = @as(u32, area[pos]) | (@as(u32, area[pos + 1]) << 8) | (@as(u32, area[pos + 2]) << 16);
            const seconds: u32 = if (minutes == 0) 0 else minutes * 60 + 820454400;
            _ = c.printf("Board Mfg Date: %ld, %s\n", @as(c_long, seconds), c.ipmi_timestamp_numeric(if (minutes == 0) c.IPMI_TIME_UNSPECIFIED else seconds));
            pos += 3;
            remaining -= 3;
            if (!field(area, &pos, "Board Manufacture Data", &remaining)) return false;
            if (area.len < byte_len) {
                const fields = [_][*:0]const u8{ "Board Product Name", "Board Serial Number", "Board Part Number", "FRU File ID" };
                for (fields) |name| _ = field(area, &pos, name, &remaining);
                if (pos >= area.len) c.lprintf(log.Level.err, "Invalid Length!");
                return false;
            }
            if (!field(area, &pos, "Board Product Name", &remaining)) return false;
            if (!field(area, &pos, "Board Serial Number", &remaining)) return false;
            if (!field(area, &pos, "Board Part Number", &remaining)) return false;
        } else {
            if (!field(area, &pos, "Product Manufacture Data", &remaining)) return false;
            if (!field(area, &pos, "Product Name", &remaining)) return false;
            if (!field(area, &pos, "Product Part/Model Number", &remaining)) return false;
            if (!field(area, &pos, "Product Version", &remaining)) return false;
            if (!field(area, &pos, "Product Serial Number", &remaining)) return false;
            if (!field(area, &pos, "Asset Tag", &remaining)) return false;
        }
        if (!field(area, &pos, "FRU File ID", &remaining)) return false;
    }
    custom(area, &pos, &remaining);
    return true;
}

fn showDetails(data: []const u8) void {
    if (data.len < 8) return;
    if (data[1] != 0) {
        const start: usize = @as(usize, data[1]) * 8;
        const next = blk: {
            var closest: usize = data.len;
            for (data[2..6]) |block| {
                const off = @as(usize, block) * 8;
                if (block > data[1] and off < closest) closest = off;
            }
            break :blk @min(closest, data.len);
        };
        _ = c.printf("%s\nFRU Internal Use Info\n%s\n", equal, equal);
        if (start >= next) return;
        _ = c.printf("Format Version: %d\nLength: %ld\nData dump:\n", @as(c_int, data[start] & 15), @as(c_long, @intCast(next - start - 1)));
        for (data[start + 1 .. next]) |byte| _ = c.printf("0x%02x ", @as(c_uint, byte));
        _ = c.printf("\n");
    }
    if (!showArea(data, data[2], .chassis)) return;
    if (!showArea(data, data[3], .board)) return;
    _ = showArea(data, data[4], .product);
}

fn frushow(gpa: Allocator, file: *File) c_int {
    _ = c.printf("Start converting file '%s'...\n", file.name);
    const bytes = readFile(gpa, file.name, true) orelse return -1;
    file.data = bytes;
    if (!header(bytes)) return -1;
    showDetails(bytes);
    const ok = parseRecords(gpa, file);
    if (ok) {
        _ = c.printf("%s\nFRU Multi Info area\n%s\n", equal, equal);
        for (file.records) |rec| displayRecord(rec);
    } else _ = c.printf("***empty list***\n");
    if (c.verbose > 1) {
        for (file.records) |_| _ = c.printf("record has been removed!\n");
    }
    return if (ok) 0 else -1;
}

fn load(gpa: Allocator, file: *File) bool {
    file.data = readFile(gpa, file.name, false) orelse return false;
    return parseRecords(gpa, file);
}

fn u16le(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn u32le(bytes: []const u8) u32 {
    return @as(u32, u16le(bytes)) | (@as(u32, u16le(bytes[2..])) << 16);
}

fn amps(n: u16) f32 {
    return @as(f32, @floatFromInt(n)) * 0.1;
}

fn two(n: f32) f64 {
    return @as(f64, n);
}

const Port = struct { resource: u8, remote: u8, local: u8 };
const Resource = struct { id: u8, ports: []Port };

fn resources(gpa: Allocator, record: Record) ?[]Resource {
    if (record.data.len < 7) return null;
    var result: std.ArrayList(Resource) = .empty;
    var success = false;
    defer if (!success) {
        for (result.items) |entry| gpa.free(entry.ports);
        result.deinit(gpa);
    };
    var offset: usize = 5;
    while (offset < record.data.len) {
        if (record.data.len - offset < 2) return null;
        const id = record.data[offset];
        const count = record.data[offset + 1];
        offset += 2;
        if (@as(usize, count) > (record.data.len - offset) / 3) return null;
        const ports = gpa.alloc(Port, count) catch return null;
        for (ports) |*port| {
            port.* = .{
                .resource = record.data[offset],
                .remote = record.data[offset + 1] & 31,
                .local = @intCast((u16le(record.data[offset + 1 ..]) >> 5) & 31),
            };
            offset += 3;
        }
        result.append(gpa, .{ .id = id, .ports = ports }) catch return null;
    }
    const owned = result.toOwnedSlice(gpa) catch return null;
    success = true;
    return owned;
}

fn displayCarrier(gpa: Allocator, rec: Record) bool {
    const desc = resources(gpa, rec) orelse return false;
    if (c.verbose > 1) {
        _ = c.printf("Binary data of Carrier p2p connectivity record starting from mfg id\n");
        for (rec.data) |byte| _ = c.printf("%02x   ", @as(c_uint, byte));
        _ = c.printf("\n");
    }
    for (desc) |resource| {
        if (c.verbose > 0) _ = c.printf("resource id= %02x  port count= %d\n", @as(c_uint, resource.id), @as(c_int, @intCast(resource.ports.len)));
        if (resource.id & 0x80 != 0) {
            if (resource.id == 0x80) {
                _ = c.printf("   %s topology:\n", value(0x90, &ipmbl_addr));
            } else _ = c.printf("   %s topology:\n", value(resource.id & 15, &module_type));
        } else _ = c.printf("   On Carrier Device ID %d topology: \n", @as(c_int, resource.id & 15));
        for (resource.ports) |port| {
            if (port.resource & 0x80 != 0) {
                _ = c.printf("\tPort %d =====> %s, Port %d\n", @as(c_int, port.local), value(port.resource & 15, &module_type), @as(c_int, port.remote));
            } else {
                _ = c.printf("\tPort %d =====> On Carrier Device ID %d, Port %d\n", @as(c_int, port.local), @as(c_int, port.resource & 15), @as(c_int, port.remote));
            }
        }
    }
    return true;
}

fn displayPower(gpa: Allocator, files: []File, all: bool) c_int {
    var rc: c_int = -1;
    for (files) |*file| {
        if (file.kind == 10) continue;
        _ = c.printf("%s\n\nFrom %s file '%s'\n", star, value(file.kind, &module_type), file.name);
        if (!load(gpa, file)) continue;
        for (file.records) |rec| {
            const d = rec.data;
            switch (rec.id()) {
                0x18 => if (all) {
                    if (!displayCarrier(gpa, rec)) rc = -1;
                },
                0x1a => if (all and d.len >= 7) {
                    _ = c.printf("   Number of AMC bays supported by Carrier: %d\n", @as(c_int, d[6]));
                },
                0x17 => {
                    if (d.len < 9 or @as(usize, d[8]) > (d.len - 9) / 3) continue;
                    for (0..d[8]) |i| {
                        const p = d[9 + i * 3 ..];
                        const current = amps(p[1]);
                        _ = c.printf("   Carrier AMC power available on %s:\n", value(p[0], &ipmbl_addr));
                        _ = c.printf("\t- Local IPMB Address    \t: %02x\n", @as(c_uint, p[0]));
                        _ = c.printf("\t- Maximum module Current\t: %.2f Watts (%.2f Amps)\n", two(current * 12), two(current));
                    }
                    const current = amps(u16le(d[5..]));
                    _ = c.printf("   Carrier AMC total power available for all bays from file '%s': %.2f Watts (%.2f Amps)\n", file.name, two(current * 12), two(current));
                },
                0x16 => if (d.len >= 6) {
                    const current = amps(d[5]);
                    _ = c.printf("   %s power required (Current Draw): %.2f Watts (%.2f Amps)\n", value(file.kind, &module_type), two(current * 12), two(current));
                },
                else => {},
            }
        }
        rc = 0;
    }
    if (c.verbose > 1) {
        for (files) |_| _ = c.printf("Record list has been removed successfully\n");
    }
    _ = c.printf("%s\n", star);
    return rc;
}

fn print(gpa: Allocator, files: []File, option: []const u8) c_int {
    if (std.mem.eql(u8, option, "power")) {
        _ = c.printf("Print power information\n");
        return displayPower(gpa, files, false);
    }
    if (std.mem.eql(u8, option, "all")) {
        _ = c.printf("Print all information\n");
        return displayPower(gpa, files, true);
    }
    if (!std.mem.eql(u8, option, "default") and !std.mem.eql(u8, option, "carrier")) {
        c.lprintf(log.Level.err, "Invalid option %s", @as([*:0]const u8, @ptrCast(option.ptr)));
        return -1;
    }
    var found = false;
    var rc: c_int = 0;
    for (files) |*file| {
        if (file.kind != 9) continue;
        found = true;
        if (!load(gpa, file)) {
            rc = -1;
            continue;
        }
        var first = true;
        for (file.records) |rec| {
            const d = rec.data;
            if (rec.id() == 0x18) {
                if (first) {
                    _ = c.printf("%s\nFrom Carrier file: %s\n", star, file.name);
                    first = false;
                }
                if (!displayCarrier(gpa, rec)) rc = -1;
            } else if (rec.id() == 0x1a and d.len >= 7) {
                if (first) {
                    _ = c.printf("From Carrier file: %s\n", file.name);
                    first = false;
                }
                _ = c.printf("   Number of AMC bays supported by Carrier: %d\n", @as(c_int, d[6]));
            }
        }
    }
    if (!found) {
        _ = c.printf("No carrier file has been found\n");
        return -1;
    }
    if (c.verbose > 0) _ = c.printf("Record list has been removed successfully\n");
    return rc;
}

const Channel = struct {
    lanes: [4]u8,
};
const Link = struct {
    channel: u8,
    flags: u4,
    typ: u8,
    ext: u4,
    group: u8,
    asym: u2,
};
const Amc = struct {
    resource: u8,
    guids: []const u8,
    channels: []Channel,
    links: []Link,
};

fn parseAmc(gpa: Allocator, rec: Record) ?Amc {
    const d = rec.data;
    if (d.len < 8) return null;
    const n_guid: usize = d[5];
    if (n_guid > (d.len - 8) / 16) return null;
    const guid_end = 6 + n_guid * 16;
    const n_channel: usize = d[guid_end + 1];
    const channel_off = guid_end + 2;
    if (n_channel > (d.len - channel_off) / 3) return null;
    const link_off = channel_off + n_channel * 3;
    if (link_off == d.len or (d.len - link_off) % 5 != 0) return null;
    const channels = gpa.alloc(Channel, n_channel) catch return null;
    var success = false;
    defer if (!success) gpa.free(channels);
    for (channels, 0..) |*channel, i| {
        const pos = channel_off + i * 3;
        const bits = @as(u32, d[pos]) | (@as(u32, d[pos + 1]) << 8) | (@as(u32, d[pos + 2]) << 16);
        channel.* = .{ .lanes = .{
            @intCast(bits & 31),         @intCast((bits >> 5) & 31),
            @intCast((bits >> 10) & 31), @intCast((bits >> 15) & 31),
        } };
    }
    const links = gpa.alloc(Link, (d.len - link_off) / 5) catch return null;
    for (links, 0..) |*link, i| {
        const p = d[link_off + 5 * i ..];
        link.* = .{
            .channel = p[0],
            .flags = @truncate(p[1]),
            .typ = (p[1] >> 4) | ((p[2] & 15) << 4),
            .ext = @truncate(p[2] >> 4),
            .group = p[3],
            .asym = @truncate(p[4]),
        };
    }
    success = true;
    return .{ .resource = d[guid_end], .guids = d[6..guid_end], .channels = channels, .links = links };
}

fn matchingLink(a: Amc, l: Link, b: Amc, r: Link) bool {
    if (l.typ != r.typ or l.ext != r.ext or
        @popCount(l.flags) != @popCount(r.flags) or
        (l.asym != 0 and r.asym != 0 and l.asym & r.asym != 0)) return false;
    if (l.typ >= 0xf0 and l.typ <= 0xfe and (a.guids.len != 0 or b.guids.len != 0)) {
        var i: usize = 0;
        while (i + 16 <= a.guids.len) : (i += 16) {
            var j: usize = 0;
            while (j + 16 <= b.guids.len) : (j += 16) {
                if (std.mem.eql(u8, a.guids[i..][0..16], b.guids[j..][0..16])) return true;
            }
        }
        return false;
    }
    return true;
}

fn physical(gpa: Allocator, carrier: ?Record, a: Amc, ia: usize, b: Amc, ib: usize, kind_a: u8, kind_b: u8, option: []const u8) bool {
    const rec = carrier orelse {
        _ = c.printf("NO Carrier p2p connectivity !\n");
        return false;
    };
    if (ia >= a.channels.len or ib >= b.channels.len) return false;
    const resources_list = resources(gpa, rec) orelse return false;
    for (resources_list) |resource| {
        for (resource.ports, 0..) |port, start| {
            const site_a: u8 = if (kind_a == 9) b.resource else 0x80 | kind_a;
            const site_b: u8 = if (kind_b == 9) b.resource else 0x80 | kind_b;
            const aligned = (resource.id == site_a and port.resource == site_b) or
                (resource.id == site_b and port.resource == site_a);
            if (!aligned) continue;
            const a_lanes = a.channels[ia].lanes;
            const b_lanes = b.channels[ib].lanes;
            if (a_lanes[0] == 31) return true;
            for (0..4) |lane| {
                if (a_lanes[lane] == 31) break;
                if (start + lane >= resource.ports.len) break;
                const p = resource.ports[start + lane];
                const first_amc = resource.id & 0x80 != 0;
                if (a_lanes[lane] != (if (first_amc) p.local else p.remote) or
                    b_lanes[lane] != (if (first_amc) p.remote else p.local)) break;
                if (lane == 3 or a_lanes[lane + 1] == 31) {
                    if (!std.mem.eql(u8, option, "unmatch")) {
                        _ = c.printf("%s port %d ==> %s port %d\n", value(kind_a, &module_type), @as(c_int, a_lanes[0]), value(kind_b, &module_type), @as(c_int, b_lanes[0]));
                    }
                    return true;
                }
            }
        }
    }
    return false;
}

fn showLink(kind: u8, resource: u8, label: [*:0]const u8, link: Link) bool {
    if (kind == 9) {
        _ = c.printf("  - %s On-Carrier Device ID %d\n", label, @as(c_int, resource & 15));
    } else _ = c.printf("  - %s %s\n", label, value(kind, &module_type));
    _ = c.printf("    - Channel ID %d || ", @as(c_int, link.channel));
    for ([_][*:0]const u8{ "Lane 0: enable", ", Lane 1: enable", ", Lane 2: enable", ", Lane 3: enable" }, 0..) |text, lane| {
        if (link.flags & (@as(u4, 1) << @intCast(lane)) != 0) _ = c.printf("%s", text);
    }
    _ = c.printf("\n    - Link Type: %s \n", value(link.typ, &link_type));
    const ext_table: ?[]const ValStr = switch (link.typ) {
        2, 3, 4 => &pcie_ext,
        5 => &ethernet_ext,
        7 => &storage_ext,
        else => null,
    };
    if (ext_table) |table| {
        _ = c.printf("    - Link Type extension: %s\n", value(link.ext, table));
    } else _ = c.printf("    - Link Type extension: %i\n", @as(c_int, link.ext));
    _ = c.printf("    - Link Group ID: %d || ", @as(c_int, link.group));
    const asym_table: ?[]const ValStr = if (link.typ >= 2 and link.typ <= 5) &pcie_asym else if (link.typ == 7) &storage_asym else null;
    if (asym_table) |table| {
        _ = c.printf("Link Asym. Match: %d - %s\n", @as(c_int, link.asym), value(link.asym, table));
    } else _ = c.printf("Link Asym. Match: %i\n", @as(c_int, link.asym));
    return link.typ >= 0xf0 and link.typ <= 0xfe;
}

fn showGuids(amc: Amc) void {
    if (amc.guids.len == 0) _ = c.printf("\tThere is no OEM GUID for this module\n");
    for (amc.guids, 0..) |byte, i| {
        if (i % 16 == 0) _ = c.printf("    - GUID: ");
        _ = c.printf("%02x", @as(c_uint, byte));
        if ((i % 16) % 4 == 0) _ = c.printf("-");
        if (i % 16 == 15) _ = c.printf("\n");
    }
}

fn compareAmc(gpa: Allocator, carrier: ?Record, a: Amc, b: Amc, kind_b: u8, kind_a: u8, option: []const u8) void {
    const matched = gpa.alloc(bool, b.links.len) catch return;
    @memset(matched, false);
    for (a.links, 0..) |left, i| {
        for (b.links, 0..) |right, j| {
            if (!((left.group == 0 and right.group == 0) or (left.group != 0 and right.group != 0))) continue;
            if (!matchingLink(a, left, b, right)) continue;
            if (a.links.len == 0 or b.links.len == 0) continue;
            const ia = @as(usize, left.channel) -| a.links[0].channel;
            const ib = @as(usize, right.channel) -| b.links[0].channel;
            if (!physical(gpa, carrier, a, ia, b, ib, kind_a, kind_b, option)) continue;
            if (!std.mem.eql(u8, option, "unmatch")) {
                _ = c.printf(if (left.group == 0) " Matching Result\n" else "  Matching Result\n");
                if (showLink(kind_b, b.resource, "From", right)) showGuids(b);
                if (showLink(kind_a, a.resource, "To", left)) showGuids(a);
                _ = c.printf("  %s\n", star);
            }
            matched[j] = true;
            break;
        }
        _ = i;
    }
    if (std.mem.eql(u8, option, "all") or std.mem.eql(u8, option, "unmatch")) {
        _ = c.printf("  Unmatching result\n");
        for (a.links) |link| {
            if (showLink(kind_a, a.resource, "", link)) showGuids(a);
            _ = c.printf("   %s\n", star);
        }
        for (b.links, 0..) |link, j| {
            if (matched[j]) continue;
            if (showLink(kind_b, b.resource, "", link)) showGuids(b);
            _ = c.printf("   %s\n", star);
        }
    }
}

fn summary(gpa: Allocator, files: []File, option: []const u8) c_int {
    if (std.mem.eql(u8, option, "carrier") or std.mem.eql(u8, option, "power")) {
        c.lprintf(log.Level.err, "   ekanalyzer summary [match/ unmatch/ all] <xx=frufile> <xx=frufile> [xx=frufile]");
        return -1;
    }
    var amc = false;
    var carrier = false;
    for (files) |file| {
        if (file.kind != 9 and file.kind != 10 and file.kind != 11) amc = true;
        if (file.kind == 9 or file.kind == 10 or file.kind == 11) carrier = true;
    }
    if (!amc) {
        _ = c.printf("\nNo AMC FRU file is provided ---> No possible ekeying match!\n");
        return -1;
    }
    if (!carrier) {
        _ = c.printf("\nNo Carrier FRU file is provided ---> No possible ekeying match!\n");
        return -1;
    }
    var physical_record: ?Record = null;
    for (files) |*file| {
        if (file.kind == 10) continue;
        if (!load(gpa, file)) return -1;
        if (file.kind == 9) {
            for (file.records) |rec| {
                if (rec.id() == 0x18) {
                    physical_record = rec;
                    break;
                }
            }
        }
    }
    for (files, 0..) |left, i| {
        for (files[i + 1 ..]) |right| {
            if (left.kind == 10 or right.kind == 10 or
                (left.kind == 9 and right.kind == 9)) continue;
            _ = c.printf("%s vs %s\n", value(left.kind, &module_type), value(right.kind, &module_type));
            if (c.verbose > 0) _ = c.printf("Start matching process\n");
            const a_file: File = if (right.kind == 9) left else right;
            const b_file: File = if (right.kind == 9) right else left;
            const kind_b: u8 = b_file.kind;
            const kind_a: u8 = a_file.kind;
            var any = false;
            for (a_file.records) |a_record| {
                if (a_record.id() != 0x19) continue;
                const parsed_a = parseAmc(gpa, a_record) orelse continue;
                for (b_file.records) |b_record| {
                    if (b_record.id() != 0x19) continue;
                    const parsed_b = parseAmc(gpa, b_record) orelse continue;
                    compareAmc(gpa, physical_record, parsed_a, parsed_b, kind_b, kind_a, option);
                    any = true;
                }
                if (c.verbose > 0) _ = c.printf("Record list has been removed successfully\n");
            }
            if (!any) _ = c.printf("No amc record is found!\n");
        }
    }
    return 0;
}

const Cursor = struct {
    data: []const u8,
    at: usize = 5,

    fn take(self: *Cursor, n: usize) ?[]const u8 {
        if (self.at > self.data.len or n > self.data.len - self.at) return null;
        const slice = self.data[self.at..][0..n];
        self.at += n;
        return slice;
    }

    fn byte(self: *Cursor) ?u8 {
        return (self.take(1) orelse return null)[0];
    }
};

fn displayRecord(rec: Record) void {
    const d = rec.data;
    _ = c.printf("Record Type ID: 0x%02x\nRecord Format version: 0x%02x\n", @as(c_uint, rec.typ), @as(c_uint, rec.format));
    if (d.len <= 3) return;
    const id = rec.id();
    _ = c.printf("Manufacturer ID: %02x%02x%02x h\n", @as(c_uint, d[2]), @as(c_uint, d[1]), @as(c_uint, d[0]));
    if (id < 4 or id > 0x2d) {
        _ = c.printf("Picmg record ID: Unsupported {0x%02x}\n", @as(c_uint, id));
    } else _ = c.printf("Picmg record ID: %s {0x%02x}\n", value(id, &record_id), @as(c_uint, id));
    switch (id) {
        0x04 => displayBackplane(d),
        0x10 => displayAddress(d),
        0x11 => displayShelfPower(d),
        0x12 => displayShelfActivation(d),
        // The legacy Shelf Manager IP decoder's conditions are inverted and
        // do not print addresses in valid records.
        0x13 => {},
        0x14 => displayBoardP2p(d),
        0x15 => displayRadial(d),
        0x16 => if (d.len >= 6) {
            const current = @as(f32, @floatFromInt(d[5])) / 10.0;
            _ = c.printf("   Current draw: %.1f A @ 12V => %.2f Watt\n\n", two(current), two(current * 12));
        },
        0x17 => displayActivation(d),
        0x18 => {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            _ = displayCarrier(arena.allocator(), rec);
        },
        0x19 => displayAmc(d),
        0x1a => displayCarrierInfo(d),
        0x2c => displayClockP2p(d),
        0x2d => displayClockConfig(d),
        else => {
            if (c.verbose > 0) {
                _ = c.printf("%02x %02x %02x %02x %02x ", @as(c_uint, rec.typ), @as(c_uint, rec.format), @as(c_uint, @intCast(d.len)), @as(c_uint, rec.checksum), @as(c_uint, rec.header_checksum));
                for (d) |byte| _ = c.printf("%02x ", @as(c_uint, byte));
                _ = c.printf("\n");
            }
        },
    }
    _ = c.printf("%s\n", star);
}

fn displayBackplane(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    while (cur.take(3)) |slot| {
        _ = c.printf("   Channel Type: ");
        _ = c.printf("%s\n", @as([*:0]const u8, switch (slot[0]) {
            0, 7 => "PICMG 2.9",
            8 => "Single Port Fabric IF",
            9 => "Double Port Fabric IF",
            10 => "Full Channel Fabric IF",
            11 => "Base IF",
            12 => "Update Channel IF",
            else => "Unknown IF",
        }));
        _ = c.printf("   Slot Address:  %02x\n   Channel Count: %i\n", @as(c_uint, slot[1]), @as(c_int, slot[2]));
        for (0..slot[2]) |_| {
            const channel = cur.take(3) orelse return;
            if (c.verbose != 0) {
                const bits = @as(u32, channel[0]) | (@as(u32, channel[1]) << 8) | (@as(u32, channel[2]) << 16);
                _ = c.printf("\tChn: %02x   -->   Chn: %02x in Slot: %02x\n", @as(c_uint, (bits >> 13) & 31), @as(c_uint, (bits >> 8) & 31), @as(c_uint, channel[0]));
            }
        }
    }
}

fn displayAddress(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const type_len = cur.byte() orelse return;
    const address = cur.take(20) orelse return;
    const count = cur.byte() orelse return;
    _ = c.printf("   Type/Len:    0x%02x\n   Shelf Addr: ", @as(c_uint, type_len));
    for (address) |byte| _ = c.printf("0x%02x ", @as(c_uint, byte));
    _ = c.printf("\n   Addr Table Entries count: 0x%02x\n", @as(c_uint, count));
    for (0..count) |_| {
        const entry = cur.take(3) orelse return;
        _ = c.printf("\tHWAddr: 0x%02x  - SiteNum: 0x%02x - SiteType: 0x%02x \n", @as(c_uint, entry[0]), @as(c_uint, entry[1]), @as(c_uint, entry[2]));
    }
}

fn displayShelfPower(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const count = cur.byte() orelse return;
    _ = c.printf("   Number of Power Feeds: 0x%02x\n", @as(c_uint, count));
    for (0..count) |_| {
        const feed = cur.take(6) orelse return;
        _ = c.printf("   Max External Available Current: %ld Amps\n", @as(c_long, u16le(feed)) * 10);
        _ = c.printf("   Max Internal Current:\t   %ld Amps\n", @as(c_long, u16le(feed[2..])) * 10);
        _ = c.printf("   Min Expected Operating Voltage: %d Volts\n", @as(c_int, feed[4] / 2));
        _ = c.printf("   Feed to FRU count: 0x%02x\n", @as(c_uint, feed[5]));
        for (0..feed[5]) |_| {
            const entry = cur.take(2) orelse return;
            _ = c.printf("\tHW: 0x%02x\tFRU ID: 0x%02x\n", @as(c_uint, entry[0]), @as(c_uint, entry[1]));
        }
    }
}

fn displayShelfActivation(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const ready = cur.byte() orelse return;
    const count = cur.byte() orelse return;
    _ = c.printf("   Allowance for FRU Act Readiness: 0x%02x\n   FRU activation and Power Desc Cnt: 0x%02x\n", @as(c_uint, ready), @as(c_uint, count));
    for (0..count) |_| {
        const desc = cur.take(5) orelse return;
        _ = c.printf("   FRU activation and Power descriptor:\n");
        _ = c.printf("\tHardware Address:\t\t0x%02x\n", @as(c_uint, desc[0]));
        _ = c.printf("\tFRU Device ID:\t\t\t0x%02x\n", @as(c_uint, desc[1]));
        _ = c.printf("\tMax FRU Power Capability:\t0x%04x Watts\n", @as(c_uint, u16le(desc[2..])));
        _ = c.printf("\tConfiguration parameter:\t0x%02x\n", @as(c_uint, desc[4]));
    }
}

fn displayBoardP2p(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const count = cur.byte() orelse return;
    _ = c.printf("   GUID count: %2d\n", @as(c_int, count));
    for (0..count) |_| {
        const guid = cur.take(16) orelse return;
        _ = c.printf("\tGUID: ");
        for (guid) |byte| _ = c.printf("%02x", @as(c_uint, byte));
        _ = c.printf("\n");
    }
    while (cur.take(4)) |bytes| {
        const bits = u32le(bytes);
        const channel = bits & 63;
        const interface = (bits >> 6) & 3;
        const ports = (bits >> 8) & 15;
        const typ = (bits >> 12) & 255;
        const ext = (bits >> 20) & 15;
        const group = (bits >> 24) & 255;
        _ = c.printf("   Link Descriptor\n\tLink Grouping ID:\t0x%02x\n", @as(c_uint, group));
        const ext_name: [*:0]const u8 = if (typ == 1)
            switch (ext) {
                0 => "10/100/1000BASE-T Link (four-pair)",
                1 => "ShMC Cross-connect (two-pair)",
                else => "Unknown",
            }
        else if (typ == 2)
            switch (ext) {
                0 => "Fixed 1000Base-BX",
                1 => "Fixed 10GBASE-BX4 [XAUI]",
                2 => "FC-PI",
                else => "Unknown",
            }
        else
            "Unknown";
        _ = c.printf("\tLink Type Extension:\t0x%02x - %s\n", @as(c_uint, ext), ext_name);
        const type_name: [*:0]const u8 = if (typ == 0 or typ == 0xff or (typ >= 6 and typ <= 0xef)) "Reserved" else switch (typ) {
            1 => "PICMG 3.0 Base Interface 10/100/1000",
            2 => "PICMG 3.1 Ethernet Fabric Interface",
            3 => "PICMG 3.2 Infiniband Fabric Interface",
            4 => "PICMG 3.3 Star Fabric Interface",
            5 => "PICMG 3.4 PCI Express Fabric Interface",
            0xf0...0xfe => "OEM GUID Definition",
            else => "Invalid",
        };
        _ = c.printf("\tLink Type:\t\t0x%02x - %s\n\tLink Designator: \n", @as(c_uint, typ), type_name);
        for (0..4) |lane| {
            _ = c.printf("\t   Port %d Flag:   %s\n", @as(c_int, @intCast(lane)), @as([*:0]const u8, if (ports & (@as(u32, 1) << @intCast(lane)) != 0) "enable" else "disable"));
        }
        const interface_name: [*:0]const u8 = switch (interface) {
            0 => "Base Interface",
            1 => "Fabric Interface",
            2 => "Update Channel",
            else => "Reserved",
        };
        _ = c.printf("\t   Interface:    0x%02x - %s\n\t   Channel Number:    0x%02x\n", @as(c_uint, interface), interface_name, @as(c_uint, channel));
    }
}

fn displayRadial(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const definer = cur.take(3) orelse return;
    const version = cur.take(2) orelse return;
    const count = cur.byte() orelse return;
    _ = c.printf("   IPMB-0 Connector Definer: %02x %02x %02x h\n", @as(c_uint, definer[0]), @as(c_uint, definer[1]), @as(c_uint, definer[2]));
    _ = c.printf("   IPMB-0 Connector version ID: %02x %02x h\n", @as(c_uint, version[0]), @as(c_uint, version[1]));
    _ = c.printf("   IPMB-0 Hub Descriptor Count: 0x%02x", @as(c_uint, count));
    if (count == 0) return;
    while (cur.take(3)) |hub| {
        _ = c.printf("   IPMB-0 Hub Descriptor\n\tHardware Address: 0x%02x\n", @as(c_uint, hub[0]));
        const info: [*:0]const u8 = if (hub[1] & 1 != 0) "IPMB-A only" else if (hub[1] & 2 != 0) "IPMB-B only" else "Reserved.";
        _ = c.printf("\tHub Info {0x%02x}: %s\n\tAddress Entry count: 0x%02x", @as(c_uint, hub[1]), info, @as(c_uint, hub[2]));
        for (0..hub[2]) |_| {
            const entry = cur.take(2) orelse return;
            _ = c.printf("\t   Hardware Address: 0x%02x\n\t   IPMB-0 Link Entry: 0x%02x\n", @as(c_uint, entry[0]), @as(c_uint, entry[1]));
        }
    }
}

fn displayActivation(d: []const u8) void {
    if (d.len < 9) return;
    const current = @as(f32, @floatFromInt(u16le(d[5..]))) / 10;
    _ = c.printf("   Maximum Internal Current(@12V): %.2f A [ %.2f Watt ]\n", two(current), two(current * 12));
    _ = c.printf("   Module Activation Readiness:    %i sec.\n", @as(c_int, d[7]));
    _ = c.printf("   Descriptor Count: %i\n", @as(c_int, d[8]));
    var pos: usize = 9;
    while (pos + 3 <= d.len) : (pos += 3) {
        _ = c.printf("\tIPMB-Address:\t\t0x%x\n", @as(c_uint, d[pos]));
        _ = c.printf("\tMax. Module Current:\t%.2f A\n\n", two(@as(f32, @floatFromInt(d[pos + 1])) / 10));
    }
}

fn displayAmc(d: []const u8) void {
    if (d.len < 8) return;
    const guids: usize = d[5];
    if (guids > (d.len - 8) / 16) return;
    _ = c.printf("OEM GUID count: %02x\n", @as(c_uint, d[5]));
    for (0..guids) |i| {
        _ = c.printf("OEM GUID: ");
        for (d[6 + i * 16 ..][0..16], 1..) |byte, j| {
            _ = c.printf("%02x", @as(c_uint, byte));
            if (j % 5 == 0) _ = c.printf("-");
        }
        _ = c.printf("\n");
    }
    const resource = d[6 + guids * 16];
    if (resource & 0x80 != 0) _ = c.printf("AMC module connection\n") else _ = c.printf("On-Carrier Device %02x h\n", @as(c_uint, resource & 15));
    const count: usize = d[7 + guids * 16];
    _ = c.printf("AMC Channel Descriptor count: %02x h\n", @as(c_uint, @intCast(count)));
    var pos = 8 + guids * 16;
    if (count > (d.len - pos) / 3) return;
    for (0..count) |_| {
        const bytes = d[pos..][0..3];
        const bits = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
        _ = c.printf("   AMC Channel Descriptor {%02x%02x%02x}\n", @as(c_uint, bytes[2]), @as(c_uint, bytes[1]), @as(c_uint, bytes[0]));
        _ = c.printf("      Lane 0 Port: %d\n      Lane 1 Port: %d\n      Lane 2 Port: %d\n      Lane 3 Port: %d\n\n", @as(c_int, @intCast(bits & 31)), @as(c_int, @intCast((bits >> 5) & 31)), @as(c_int, @intCast((bits >> 10) & 31)), @as(c_int, @intCast((bits >> 15) & 31)));
        pos += 3;
    }
    while (pos + 5 <= d.len) : (pos += 5) {
        const p = d[pos..][0..5];
        const typ: u8 = (p[1] >> 4) | ((p[2] & 15) << 4);
        const ext: u8 = p[2] >> 4;
        const group: u8 = p[3];
        const asym: u8 = p[4] & 3;
        _ = c.printf("   AMC Link Descriptor:\n\t- Link Type: %s \n", value(typ, &link_type));
        switch (typ) {
            2, 3, 4, 5, 7 => {
                const table: []const ValStr = switch (typ) {
                    2, 3, 4 => &pcie_ext,
                    5 => &ethernet_ext,
                    else => &storage_ext,
                };
                const asym_table: []const ValStr = if (typ == 7) &storage_asym else &pcie_asym;
                _ = c.printf("\t- Link Type extension: %s\n", value(ext, table));
                if (typ == 2 or typ == 3 or typ == 4)
                    _ = c.printf("\t- Link Group ID: %d\n ", @as(c_int, group))
                else
                    _ = c.printf("\t- Link Group ID: %d \n", @as(c_int, group));
                _ = c.printf("\t- Link Asym. Match: %d - %s\n", @as(c_int, asym), value(asym, asym_table));
            },
            else => {
                _ = c.printf("\t- Link Type extension: %i (Unknown)\n", @as(c_int, ext));
                _ = c.printf("\t- Link Group ID: %d \n\t- Link Asym. Match: %i\n", @as(c_int, group), @as(c_int, asym));
            },
        }
        _ = c.printf("\t- AMC Link Designator:\n\t    Channel ID: %i\n", @as(c_int, p[0]));
        for (0..4) |lane| {
            const enabled = p[1] & (@as(u8, 1) << @intCast(lane)) != 0;
            _ = c.printf("\t\t Lane %d: %s\n", @as(c_int, @intCast(lane)), @as([*:0]const u8, if (enabled) "enable" else "disable"));
        }
    }
}

fn displayCarrierInfo(d: []const u8) void {
    if (d.len < 7 or @as(usize, d[6]) > d.len - 7) return;
    _ = c.printf("   AMC.0 extension version: R%d.%d\n", @as(c_int, d[5] & 15), @as(c_int, d[5] >> 4));
    _ = c.printf("   Carrier Site Number Count: %d\n", @as(c_int, d[6]));
    for (d[7..][0..d[6]]) |id| _ = c.printf("\tSite ID (%d): %s \n", @as(c_int, id), value(id, &module_type));
    _ = c.printf("\n");
}

fn displayClockP2p(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const count = cur.byte() orelse return;
    for (0..count) |_| {
        const desc = cur.take(2) orelse return;
        const id = desc[0];
        const kind: [*:0]const u8 = switch (id >> 6) {
            0 => "On-Carrier-Device",
            1 => "AMC slot",
            2 => "Backplane",
            else => "reserved",
        };
        _ = c.printf("   Clock Resource ID: 0x%02x\n   Type: %s\n   Channel Count: 0x%02x\n", @as(c_uint, id), kind, @as(c_uint, desc[1]));
        for (0..desc[1]) |_| {
            const channel = cur.take(3) orelse return;
            const remote: [*:0]const u8 = switch (channel[2] >> 6) {
                0 => "[ Carrier-Dev",
                1 => "[ AMC slot    ",
                2 => "[ Backplane    ",
                else => "reserved          ",
            };
            _ = c.printf("\tCLK-ID: 0x%02x   --->   remote CLKID: 0x%02x   %s 0x%02x ]\n", @as(c_uint, channel[0]), @as(c_uint, channel[1]), remote, @as(c_uint, channel[2] & 15));
        }
    }
    _ = c.printf("\n");
}

fn displayClockConfig(d: []const u8) void {
    var cur: Cursor = .{ .data = d };
    const id = cur.byte() orelse return;
    const count = cur.byte() orelse return;
    _ = c.printf("   Clock Resource ID: 0x%02x\n   Clock Configuration Descriptor Count: 0x%02x\n", @as(c_uint, id), @as(c_uint, count));
    for (0..count) |_| {
        const descriptor = cur.take(4) orelse return;
        _ = c.printf("\tCLK-ID: 0x%02x  -  CTRL 0x%02x [ %12s ]\n", @as(c_uint, descriptor[0]), @as(c_uint, descriptor[1]), @as([*:0]const u8, if (descriptor[1] & 1 == 0) "Carrier IPMC" else "Application"));
        _ = c.printf("\t   Count: Indirect 0x%02x   / Direct 0x%02x\n", @as(c_uint, descriptor[2]), @as(c_uint, descriptor[3]));
        for (0..descriptor[2]) |_| {
            const indirect = cur.take(2) orelse return;
            _ = c.printf("\t\tFeature: 0x%02x [%8s] -  Dep. CLK-ID: 0x%02x\n", @as(c_uint, indirect[0]), @as([*:0]const u8, if (indirect[0] & 1 != 0) "Source" else "Receiver"), @as(c_uint, indirect[1]));
        }
        for (0..descriptor[3]) |_| {
            const direct = cur.take(15) orelse return;
            _ = c.printf("\t- Feature: 0x%02x    - PLL: %x / Asym: %s\n", @as(c_uint, direct[0]), @as(c_uint, @intFromBool((direct[0] > 1) and (direct[0] & 1 != 0))), @as([*:0]const u8, if (direct[0] & 1 != 0) "Source" else "Receiver"));
            _ = c.printf("\tFamily:  0x%02x    - AccLVL: 0x%02x\n", @as(c_uint, direct[1]), @as(c_uint, direct[2]));
            _ = c.printf("\tFRQ: %-9ld - min: %-9ld - max: %-9ld\n", @as(c_long, u32le(direct[3..])), @as(c_long, u32le(direct[7..])), @as(c_long, u32le(direct[11..])));
        }
        _ = c.printf("\n");
    }
}

fn main(_: ?*Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc == 0) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        usage();
        return -1;
    }
    if (argc - 1 > 8) {
        c.lprintf(log.Level.err, "Too too many parameters given.");
        return -1;
    }
    const command = std.mem.span(argv[0]);
    if (std.mem.eql(u8, command, "help")) {
        usage();
        return 0;
    }
    const is_fru = std.mem.eql(u8, command, "frushow");
    const is_print = std.mem.eql(u8, command, "print");
    const is_summary = std.mem.eql(u8, command, "summary");
    if (!is_fru and !is_print and !is_summary) {
        c.lprintf(log.Level.err, "Invalid ekanalyzer command: %s", argv[0]);
        usage();
        return -1;
    }
    if (is_fru and argc < 2) {
        c.lprintf(log.Level.err, "Invalid ekanalyzer command: %s", argv[0]);
        usage();
        return -1;
    }
    if (!is_fru and argc < 2) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        c.lprintf(log.Level.err, if (is_print) "   ekanalyzer print [carrier/power/all] <xx=frufile> <xx=frufile> [xx=frufile]" else "   ekanalyzer summary [match/ unmatch/ all] <xx=frufile> <xx=frufile> [xx=frufile]");
        return -1;
    }
    var option: []const u8 = "default";
    var start: usize = 1;
    if (!is_fru) {
        const candidate = std.mem.span(argv[1]);
        if (std.mem.eql(u8, candidate, "carrier") or std.mem.eql(u8, candidate, "power") or
            std.mem.eql(u8, candidate, "all") or std.mem.eql(u8, candidate, "match") or
            std.mem.eql(u8, candidate, "unmatch"))
        {
            option = candidate;
            start = 2;
        } else if (candidate.len < 3 or candidate[2] != '=') {
            _ = c.printf("Invalid option '%s'\n", argv[1]);
            c.lprintf(log.Level.err, if (is_print) "   ekanalyzer print [carrier/power/all] <xx=frufile> <xx=frufile> [xx=frufile]" else "   ekanalyzer summary [match/ unmatch/ all] <xx=frufile> <xx=frufile> [xx=frufile]");
            return -1;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var files: [8]File = undefined;
    var count: usize = 0;
    for (start..@as(usize, @intCast(argc))) |i| {
        const arg = std.mem.span(argv[i]);
        const kind = getFileType(arg) orelse {
            if (is_fru) {
                c.lprintf(log.Level.err, "Invalid file type!");
                c.lprintf(log.Level.err, "   ekanalyzer frushow <xx=frufile> ...");
            } else {
                c.lprintf(log.Level.err, "Invalid file type: %c%c\n", @as(c_int, if (arg.len > 0) arg[0] else 0), @as(c_int, if (arg.len > 1) arg[1] else 0));
                usage();
            }
            return -1;
        };
        if (is_fru and kind == 10) {
            c.lprintf(log.Level.err, "Invalid file type!");
            c.lprintf(log.Level.err, "   ekanalyzer frushow <xx=frufile> ...");
            return -1;
        }
        files[count] = .{ .name = argv[i] + 3, .kind = kind, .data = &.{} };
        count += 1;
    }
    if (c.verbose > 0 and !is_fru) {
        for (files[0..count]) |file| _ = c.printf("Type: %s,   file name: %s\n", value(file.kind, &module_type), file.name);
    }
    if (is_fru) {
        var rc: c_int = -1;
        for (files[0..count]) |*file| rc = frushow(gpa, file);
        return rc;
    }
    if (is_print) return print(gpa, files[0..count], option);
    return summary(gpa, files[0..count], option);
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_ekanalyzer_main));
    @export(&main, .{ .name = "ipmi_ekanalyzer_main", .linkage = .strong });
    @export(&error_status, .{ .name = "ERROR_STATUS", .linkage = .strong });
    @export(&ok_status, .{ .name = "OK_STATUS", .linkage = .strong });
    @export(&star_ptr, .{ .name = "STAR_LINE_LIMITER", .linkage = .strong });
    @export(&equal_ptr, .{ .name = "EQUAL_LINE_LIMITER", .linkage = .strong });
    @export(&size_of_file_type, .{ .name = "SIZE_OF_FILE_TYPE", .linkage = .strong });
    @export(&amc_module, .{ .name = "AMC_MODULE", .linkage = .strong });
    @export(&picmg_id_offset, .{ .name = "PICMG_ID_OFFSET", .linkage = .strong });
    @export(&compare_candidate, .{ .name = "COMPARE_CANDIDATE", .linkage = .strong });
    @export(&start_data_offset, .{ .name = "START_DATA_OFFSET", .linkage = .strong });
    @export(&lower_oem_type, .{ .name = "LOWER_OEM_TYPE", .linkage = .strong });
    @export(&upper_oem_type, .{ .name = "UPPER_OEM_TYPE", .linkage = .strong });
    @export(&disable_port, .{ .name = "DISABLE_PORT", .linkage = .strong });
    @export(&module_type, .{ .name = "ipmi_ekanalyzer_module_type", .linkage = .strong });
    @export(&ipmbl_addr, .{ .name = "ipmi_ekanalyzer_IPMBL_addr", .linkage = .strong });
    @export(&link_type, .{ .name = "ipmi_ekanalyzer_link_type", .linkage = .strong });
    @export(&pcie_ext, .{ .name = "ipmi_ekanalyzer_extension_PCIE", .linkage = .strong });
    @export(&ethernet_ext, .{ .name = "ipmi_ekanalyzer_extension_ETHERNET", .linkage = .strong });
    @export(&storage_ext, .{ .name = "ipmi_ekanalyzer_extension_STORAGE", .linkage = .strong });
    @export(&pcie_asym, .{ .name = "ipmi_ekanalyzer_asym_PCIE", .linkage = .strong });
    @export(&storage_asym, .{ .name = "ipmi_ekanalyzer_asym_STORAGE", .linkage = .strong });
    @export(&record_id, .{ .name = "ipmi_ekanalyzer_picmg_record_id", .linkage = .strong });
}

test "AMC channel and link descriptors reject truncated and inconsistent counts" {
    const allocator = std.testing.allocator;
    const valid = [_]u8{
        0x5a, 0x31, 0,    0x19, 0,    0, 0x81, 1,
        0xe1, 0xff, 0x0f, 0,    0x51, 0, 0,    0,
    };
    for (0..8) |len| {
        try std.testing.expect(parseAmc(allocator, .{
            .typ = 0xc0,
            .format = 0x82,
            .checksum = 0,
            .header_checksum = 0,
            .data = valid[0..len],
        }) == null);
    }
    const parsed = parseAmc(allocator, .{
        .typ = 0xc0,
        .format = 0x82,
        .checksum = 0,
        .header_checksum = 0,
        .data = &valid,
    }) orelse return error.InvalidFixture;
    defer allocator.free(parsed.channels);
    defer allocator.free(parsed.links);
    try std.testing.expectEqual(@as(u8, 1), parsed.channels[0].lanes[0]);
    try std.testing.expectEqual(@as(u8, 31), parsed.channels[0].lanes[3]);
    try std.testing.expectEqual(@as(u8, 5), parsed.links[0].typ);
    var malformed = valid;
    malformed[5] = 255;
    try std.testing.expect(parseAmc(allocator, .{
        .typ = 0xc0,
        .format = 0x82,
        .checksum = 0,
        .header_checksum = 0,
        .data = &malformed,
    }) == null);
    malformed = valid;
    malformed[7] = 255;
    try std.testing.expect(parseAmc(allocator, .{
        .typ = 0xc0,
        .format = 0x82,
        .checksum = 0,
        .header_checksum = 0,
        .data = &malformed,
    }) == null);
    for (8..valid.len) |len| {
        try std.testing.expect(parseAmc(allocator, .{
            .typ = 0xc0,
            .format = 0x82,
            .checksum = 0,
            .header_checksum = 0,
            .data = valid[0..len],
        }) == null);
    }
}

test "carrier P2P resource counts never read past a short record" {
    const allocator = std.testing.allocator;
    const bytes = [_]u8{ 0x5a, 0x31, 0, 0x18, 0, 1, 1, 0x81, 0x41, 0 };
    const rec: Record = .{ .typ = 0xc0, .format = 0x82, .checksum = 0, .header_checksum = 0, .data = &bytes };
    for (0..bytes.len) |len| {
        try std.testing.expect(resources(allocator, .{
            .typ = rec.typ,
            .format = rec.format,
            .checksum = rec.checksum,
            .header_checksum = rec.header_checksum,
            .data = bytes[0..len],
        }) == null);
    }
    const parsed = resources(allocator, rec) orelse return error.InvalidFixture;
    defer {
        for (parsed) |entry| allocator.free(entry.ports);
        allocator.free(parsed);
    }
    try std.testing.expectEqual(@as(u8, 2), parsed[0].ports[0].local);
    try std.testing.expectEqual(@as(u8, 1), parsed[0].ports[0].remote);
}

test "every single-byte mutation of compact AMC and carrier records is bounded" {
    const allocator = std.testing.allocator;
    const link = [_]u8{
        0x5a, 0x31, 0,    0x19, 0,    0, 0x81, 1,
        0xe1, 0xff, 0x0f, 0,    0x51, 0, 0,    0,
    };
    const topology = [_]u8{ 0x5a, 0x31, 0, 0x18, 0, 1, 1, 0x81, 0x41, 0 };
    for (0..link.len) |index| {
        for (0..256) |byte| {
            var changed = link;
            changed[index] = @intCast(byte);
            const candidate: Record = .{
                .typ = 0xc0,
                .format = 0x82,
                .checksum = 0,
                .header_checksum = 0,
                .data = &changed,
            };
            if (parseAmc(allocator, candidate)) |amc| {
                allocator.free(amc.channels);
                allocator.free(amc.links);
            }
        }
    }
    for (0..topology.len) |index| {
        for (0..256) |byte| {
            var changed = topology;
            changed[index] = @intCast(byte);
            const candidate: Record = .{
                .typ = 0xc0,
                .format = 0x82,
                .checksum = 0,
                .header_checksum = 0,
                .data = &changed,
            };
            if (resources(allocator, candidate)) |descriptors| {
                for (descriptors) |entry| allocator.free(entry.ports);
                allocator.free(descriptors);
            }
        }
    }
}
