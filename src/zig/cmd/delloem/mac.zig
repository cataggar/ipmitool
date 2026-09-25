const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const log = common.log;

pub var embedded: [64]u8 = .{0} ** 64;
pub var embedded10: [48]u8 = .{0} ** 48;
pub var use_virtual: u8 = 0;

fn fixed(comptime size: usize, comptime text: []const u8) [size]u8 {
    var value = [_]u8{0} ** size;
    @memcpy(value[0..text.len], text);
    return value;
}

pub var active_lom = [_][10]u8{
    fixed(10, "None"), fixed(10, "LOM1"), fixed(10, "LOM2"),
    fixed(10, "LOM3"), fixed(10, "LOM4"), fixed(10, "dedicated"),
};
pub var selection = [_][50]u8{
    fixed(50, "shared"),    fixed(50, "shared with failover lom2"),
    fixed(50, "dedicated"), fixed(50, "shared with Failover all loms"),
};
pub var selection12 = [_][50]u8{
    fixed(50, "dedicated"),                 fixed(50, "shared with lom1"),
    fixed(50, "shared with lom2"),          fixed(50, "shared with lom3"),
    fixed(50, "shared with lom4"),          fixed(50, "shared with failover lom1"),
    fixed(50, "shared with failover lom2"), fixed(50, "shared with failover lom3"),
    fixed(50, "shared with failover lom4"), fixed(50, "shared with failover all loms"),
};

pub fn exportGlobals() void {
    comptime {
        @export(&embedded, .{ .name = "EmbeddedNICMacAddress" });
        @export(&embedded10, .{ .name = "EmbeddedNICMacAddress_10G" });
        @export(&use_virtual, .{ .name = "UseVirtualMacAddress" });
        @export(&active_lom, .{ .name = "ActiveLOM_String" });
        @export(&selection, .{ .name = "NIC_Selection_Mode_String" });
        @export(&selection12, .{ .name = "NIC_Selection_Mode_String_12g" });
    }
}

fn usage() void {
    common.notice(&.{
        "",                        "   mac list",                                                                  "      Lists the MAC address of LOMs", "",
        "   mac get <NIC number>", "      Shows the MAC address of specified LOM. 0-7 System LOM, 8- DRAC/iDRAC.", "",
    });
}

fn label() [*:0]const u8 {
    return switch (common.imc_type) {
        0x08 => "DRAC MAC Address ",
        0x0a, 0x0b => "iDRAC6 MAC Address ",
        0x10, 0x11 => "iDRAC7 MAC Address ",
        0x20, 0x21 => "iDRAC8 MAC Address ",
        else => "BMC MAC Address ",
    };
}

fn macPtr(data: []const u8) [*c]const u8 {
    return @ptrCast(data.ptr);
}

fn resetEmbedded() void {
    @memset(&embedded, 0);
    @memset(&embedded10, 0);
    for (0..8) |i| embedded[i * 8] = 0xf0;
}

fn virtual(intf: *Intf, nic: u8) void {
    if (nic != 0xff and nic != 8) return;
    use_virtual = 0;
    const rsp = common.send(intf, 0x30, 0xc9, &.{1}) orelse return;
    if (rsp.ccode != 0) return;
    const has_server_mac = common.imc_type == 0x10 or common.imc_type == 0x11 or
        common.imc_type == 0x20 or common.imc_type == 0x21;
    const data = common.bytes(rsp, if (has_server_mac) 13 else 7) orelse return;
    var addr = data[1..7];
    if (has_server_mac and std.mem.allEqual(u8, addr, 0)) addr = data[7..13];
    if (std.mem.allEqual(u8, addr, 0)) return;
    use_virtual = 1;
    _ = c.printf("\n%s%s\n", label(), c.mac2str(macPtr(addr)));
}

fn idrac(intf: *Intf, nic: u8) void {
    virtual(intf, nic);
    if ((nic != 0xff and nic != 8) or use_virtual != 0) return;
    const rsp = common.send(intf, 0x0c, 0x02, &.{ 1, 5, 0, 0 }) orelse {
        c.lprintf(log.Level.err, "Error in getting MAC Address");
        return;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error in getting MAC Address (%s)", common.cc(rsp.ccode));
        return;
    }
    const data = common.bytes(rsp, 7) orelse {
        _ = common.short("MAC Address");
        return;
    };
    if (common.imc_type == 0x0d or common.imc_type == 0x0e) {
        _ = c.printf("\n\r%s%s\n", label(), c.mac2str(macPtr(data[1..7])));
    } else {
        _ = c.printf("\n%s%s\n", label(), c.mac2str(macPtr(data[1..7])));
    }
}

fn legacy(intf: *Intf, nic: u8) c_int {
    resetEmbedded();
    const rsp = common.send(intf, 0x06, 0x59, &.{ 0, 0xcb, 0, 0 }) orelse {
        c.lprintf(log.Level.err, "Error in getting MAC Address");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error in getting MAC Address (%s)", common.cc(rsp.ccode));
        return -1;
    }
    const header = common.bytes(rsp, 2) orelse return common.short("MAC Address");
    const count: usize = header[1];
    // C copied `count * 6` into an eight-entry static array without a bound.
    if (count > 8 or (nic != 8 and header.len < 2 + count * 6)) return common.short("MAC Address");
    if (nic != 8) {
        if (nic == 0xff) _ = c.printf("\nSystem LOMs");
        _ = c.printf("\nNIC Number\tMAC Address\n");
        for (0..count) |i| {
            const addr = header[2 + i * 6 ..][0..6];
            @memcpy(embedded10[i * 6 ..][0..6], addr);
            if (nic == 0xff or nic == i) {
                _ = c.printf("\n%d\t\t%s", @as(c_int, @intCast(i)), c.mac2str(macPtr(addr)));
            }
        }
        _ = c.printf("\n");
    }
    idrac(intf, nic);
    return 0;
}

fn modern(intf: *Intf, nic: u8) c_int {
    resetEmbedded();
    const header_rsp = common.send(intf, 0x06, 0x59, &.{ 0, 0xda, 0, 0, 0, 0 }) orelse {
        c.lprintf(log.Level.err, "Error in getting MAC Address");
        return -1;
    };
    if (header_rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error in getting MAC Address (%s)", common.cc(header_rsp.ccode));
        return -1;
    }
    const header = common.bytes(header_rsp, 2) orelse return common.short("MAC Address");
    const blocks: usize = header[1] / 8;
    if (blocks > 8) return common.short("MAC Address");
    if (nic != 8) {
        if (nic == 0xff) _ = c.printf("\nSystem LOMs");
        _ = c.printf("\nNIC Number\tMAC Address\t\tStatus\n");
        for (0..blocks) |i| {
            const data = [6]u8{ 0, 0xda, 0, 0, @intCast(i * 8), 8 };
            const rsp = common.send(intf, 0x06, 0x59, &data) orelse {
                c.lprintf(log.Level.err, "Error in getting MAC Address");
                return -1;
            };
            if (rsp.ccode != 0) {
                c.lprintf(log.Level.err, "Error in getting MAC Address (%s)", common.cc(rsp.ccode));
                return -1;
            }
            const body = common.bytes(rsp, 9) orelse return common.short("MAC Address");
            @memcpy(embedded[i * 8 ..][0..8], body[1..9]);
            const mac_type: u8 = (body[1] >> 4) & 3;
            const enabled: u8 = body[1] >> 6;
            const number: u8 = body[2] & 31;
            if (mac_type == 0 and (nic == 0xff or nic == number)) {
                _ = c.printf("\n%d\t\t%s\t%s", @as(c_int, number), c.mac2str(macPtr(body[3..9])), @as([*:0]const u8, if (enabled == 0) "Enabled" else "Disabled"));
            }
        }
        _ = c.printf("\n");
    }
    idrac(intf, nic);
    return 0;
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    if (common.eq(common.arg(argv, argc, 1), "help")) {
        usage();
        return 0;
    }
    common.validator(intf);
    var nic: u8 = 0xff;
    if (common.eq(common.arg(argv, argc, 1), "get")) {
        const str = common.arg(argv, argc, 2) orelse {
            usage();
            return -1;
        };
        var value: c_int = 0;
        if (c.str2int(str, &value) != 0 or value < 0 or value > 8) {
            c.lprintf(log.Level.err, "Invalid NIC number. The NIC number should be between 0-8");
            return -1;
        }
        nic = @intCast(value);
    } else if (common.arg(argv, argc, 1) != null and !common.eq(common.arg(argv, argc, 1), "list")) {
        usage();
        return 0;
    }
    return switch (common.imc_type) {
        0x08 => legacy(intf, nic),
        0x0a, 0x0b, 0x0d, 0x0e, 0x10, 0x11, 0x20, 0x21 => modern(intf, nic),
        else => blk: {
            c.lprintf(log.Level.err, "Error in getting MAC Address : Not supported platform");
            break :blk -1;
        },
    };
}

test "LOM packed bitfields and maximum block count" {
    try std.testing.expectEqual(@as(u8, 1), @as(u8, 0x21) & 31);
    try std.testing.expectEqual(@as(u8, 2), @as(u8, 0x10) / 8);
}
