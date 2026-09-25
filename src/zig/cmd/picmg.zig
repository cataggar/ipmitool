//! PICMG/ATCA/AMC command implementation, replacing lib/ipmi_picmg.c.
//! Requests and output use the C ABI; all response fields are checked against
//! data_len before access (the original C assumed full responses).

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const log = @import("../util/log.zig");

const Args = [*c][*c]u8;
const query = 0;
const enabled_only = 2;
const disabled_only = 3;
const atca = 2;
const amc = 4;
var card_type: u8 = 0xff;

const AddrMap = extern struct {
    ipmbLAddr: u8,
    amcBayId: ?[*:0]u8,
    siteNum: u8,
};
var amc_addr_map = [_]AddrMap{
    .{ .ipmbLAddr = 0xff, .amcBayId = @constCast("reserved"), .siteNum = 0 },
    .{ .ipmbLAddr = 0x72, .amcBayId = @constCast("A1"), .siteNum = 1 },
    .{ .ipmbLAddr = 0x74, .amcBayId = @constCast("A2"), .siteNum = 2 },
    .{ .ipmbLAddr = 0x76, .amcBayId = @constCast("A3"), .siteNum = 3 },
    .{ .ipmbLAddr = 0x78, .amcBayId = @constCast("A4"), .siteNum = 4 },
    .{ .ipmbLAddr = 0x7a, .amcBayId = @constCast("B1"), .siteNum = 5 },
    .{ .ipmbLAddr = 0x7c, .amcBayId = @constCast("B2"), .siteNum = 6 },
    .{ .ipmbLAddr = 0x7e, .amcBayId = @constCast("B3"), .siteNum = 7 },
    .{ .ipmbLAddr = 0x80, .amcBayId = @constCast("B4"), .siteNum = 8 },
    .{ .ipmbLAddr = 0x82, .amcBayId = @constCast("reserved"), .siteNum = 0 },
    .{ .ipmbLAddr = 0x84, .amcBayId = @constCast("reserved"), .siteNum = 0 },
    .{ .ipmbLAddr = 0x86, .amcBayId = @constCast("reserved"), .siteNum = 0 },
    .{ .ipmbLAddr = 0x88, .amcBayId = @constCast("reserved"), .siteNum = 0 },
};

const colors = [_][*:0]const u8{
    "reserved", "BLUE", "RED", "GREEN", "AMBER", "ORANGE", "WHITE", "reserved",
};

fn colorName(color: c_int) callconv(.c) [*:0]const u8 {
    if (color < 0 or color >= colors.len) return "invalid";
    return colors[@intCast(color)];
}

fn arg(argv: Args, index: usize) ?[*:0]const u8 {
    if (argv == null or argv[index] == null) return null;
    return @ptrCast(argv[index]);
}

fn eq(argv: Args, index: usize, name: []const u8) bool {
    const item = arg(argv, index) orelse return false;
    return std.mem.eql(u8, std.mem.span(item), name);
}

fn ptrArg(argv: Args, index: usize) [*c]const u8 {
    return if (arg(argv, index)) |p| @ptrCast(p) else null;
}

fn fru(argv: Args, index: usize, dest: *u8) bool {
    return c.is_fru_id(ptrArg(argv, index), dest) == 0;
}

fn parseByte(argv: Args, index: usize, dest: *u8, comptime label: [*:0]const u8, limit: u8) bool {
    if (c.str2uchar(ptrArg(argv, index), dest) == 0 and dest.* <= limit) return true;
    c.lprintf(log.Level.err, "Given %s '%s' is invalid.", label, ptrArg(argv, index));
    return false;
}

fn byteValidator(
    comptime symbol: []const u8,
    comptime label: [*:0]const u8,
    comptime limit: u8,
) type {
    return struct {
        fn check(input: ?[*:0]const u8, dest: ?*u8) callconv(.c) c_int {
            if (input == null or dest == null) {
                c.lprintf(log.Level.err, symbol ++ "(): invalid argument(s).");
                return -1;
            }
            if (c.str2uchar(input, dest) == 0 and dest.?.* <= limit) return 0;
            c.lprintf(log.Level.err, "Given %s '%s' is invalid.", label, input);
            return -1;
        }
    };
}

const chan = byteValidator("is_amc_channel", "AMC Channel", 255).check;
const clk_acc = byteValidator("is_clk_acc", "Clock Accuracy", 255).check;
const clk_family = byteValidator("is_clk_family", "Clock Family", 255).check;
const clk_id = byteValidator("is_clk_id", "Clock ID", 255).check;
const clk_index = byteValidator("is_clk_index", "Clock Index", 255).check;
const clk_setting = byteValidator("is_clk_setting", "Clock Setting", 255).check;
const led_id = byteValidator("is_led_id", "LED ID", 255).check;
const link_group = byteValidator("is_link_group", "Link Group", 255).check;
const link_type = byteValidator("is_link_type", "Link Type", 255).check;
const link_ext = byteValidator("is_link_type_ext", "Link Type Extension", 15).check;
const enable = byteValidator("is_enable", "Enable", 1).check;
const led_function = byteValidator("is_led_function", "LED Function", 255).check;

fn ledColor(input: ?[*:0]const u8, dest: ?*u8) callconv(.c) c_int {
    if (input == null or dest == null) {
        c.lprintf(log.Level.err, "is_led_color(): invalid argument(s).");
        return -1;
    }
    if (c.str2uchar(input, dest) != 0) {
        c.lprintf(log.Level.err, "Given LED Color '%s' is invalid.", input);
    } else if ((dest.?.* >= 1 and dest.?.* <= 6) or (dest.?.* >= 14 and dest.?.* <= 15)) {
        return 0;
    } else {
        c.lprintf(log.Level.err, "Given LED Color '%s' is out of range.", input);
    }
    c.lprintf(log.Level.err, "LED Color must be from ranges: <1..6>, <0xE..0xF>");
    return -1;
}

fn ledFunction(input: ?[*:0]const u8, dest: ?*u8) callconv(.c) c_int {
    if (led_function(input, dest) != 0) return -1;
    if (dest.?.* != 0xfd and dest.?.* != 0xfe) return 0;
    c.lprintf(log.Level.err, "Given LED Function '%s' is invalid.", input);
    return -1;
}

fn intValidator(comptime name: []const u8, comptime label: []const u8) type {
    return struct {
        fn check(input: ?[*:0]const u8, dest: ?*i32) callconv(.c) c_int {
            if (input == null or dest == null) {
                c.lprintf(log.Level.err, name ++ "(): invalid argument(s).");
                return -1;
            }
            if (c.str2int(input, dest) == 0 and dest.?.* >= 0) return 0;
            c.lprintf(log.Level.err, "Given " ++ label ++ " '%s' is invalid.", input);
            return -1;
        }
    };
}

const amc_dev = intValidator("is_amc_dev", "PICMG Device").check;
const amc_intf = intValidator("is_amc_intf", "PICMG Interface").check;
const amc_port = intValidator("is_amc_port", "PICMG Port").check;

fn clkFreq(input: ?[*:0]const u8, dest: ?*u32) callconv(.c) c_int {
    if (input == null or dest == null) {
        c.lprintf(log.Level.err, "is_clk_freq(): invalid argument(s).");
        return -1;
    }
    if (c.str2uint(input, dest) == 0) return 0;
    c.lprintf(log.Level.err, "Given Clock Frequency '%s' is invalid.", input);
    return -1;
}

fn clkResid(input: ?[*:0]const u8, dest: ?*i8) callconv(.c) c_int {
    if (input == null or dest == null) {
        c.lprintf(log.Level.err, "is_clk_resid(): invalid argument(s).");
        return -1;
    }
    if (c.str2char(input, dest) == 0 and dest.?.* >= 0) return 0;
    c.lprintf(log.Level.err, "Given Resource ID '%s' is invalid.", input);
    return -1;
}

fn send(intf: *Intf, cmd: u8, data: []u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = ipmi.NetFn.picmg, .lun = 0 };
    req.msg.cmd = cmd;
    req.msg.data = data.ptr;
    req.msg.data_len = @intCast(data.len);
    return intf.sendrecv.?(intf, &req);
}

fn response(intf: *Intf, cmd: u8, data: []u8, comptime name: [*:0]const u8, min_len: usize) ?*Response {
    const rsp = send(intf, cmd, data) orelse {
        c.lprintf(log.Level.err, "No valid response received.");
        return null;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "%s failed with CC code 0x%02x", name, @as(c_uint, rsp.ccode));
        return null;
    }
    if (rsp.data_len < min_len) {
        c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
        return null;
    }
    return rsp;
}

fn properties(intf: *Intf, show: c_int) callconv(.c) c_int {
    var data = [_]u8{0};
    const rsp = send(intf, c.PICMG_GET_PICMG_PROPERTIES_CMD, &data) orelse {
        c.lprintf(log.Level.err, "Error getting address information.");
        return -1;
    };
    if (rsp.ccode != 0 or rsp.data_len < 4) {
        c.lprintf(log.Level.err, "Error getting address information.");
        return -1;
    }
    if (show != 0) {
        _ = c.printf("PICMG identifier\t: 0x%02x\n", @as(c_uint, rsp.data[0]));
        _ = c.printf("PICMG Ext. Version : %i.%i\n", @as(c_int, rsp.data[1] & 0xf), @as(c_int, rsp.data[1] >> 4));
        _ = c.printf("Max FRU Device ID\t: 0x%02x\n", @as(c_uint, rsp.data[2]));
        _ = c.printf("FRU Device ID\t\t: 0x%02x\n", @as(c_uint, rsp.data[3]));
    }
    switch (rsp.data[1] & 0xf) {
        1, 2, 4 => card_type = rsp.data[1] & 0xf,
        else => {},
    }
    return 0;
}

fn discover(intf: *Intf) callconv(.c) u8 {
    var data = [_]u8{0};
    c.lprintf(log.Level.debug, "Running Get PICMG Properties my_addr %#x, transit %#x, target %#x", @as(c_uint, intf.my_addr), @as(c_uint, intf.transit_addr), @as(c_uint, intf.target_addr));
    const rsp = send(intf, c.PICMG_GET_PICMG_PROPERTIES_CMD, &data) orelse {
        c.lprintf(log.Level.debug, "No response from Get PICMG Properties");
        return 0;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.debug, "Error response %#x from Get PICMG Properties", @as(c_uint, rsp.ccode));
    } else if (rsp.data_len < 4) {
        c.lprintf(log.Level.info, "Invalid Get PICMG Properties response length %d", rsp.data_len);
    } else if (rsp.data[0] != 0) {
        c.lprintf(log.Level.info, "Invalid Get PICMG Properties group extension %#x", @as(c_uint, rsp.data[0]));
    } else if (rsp.data[1] & 0xf != 2 and rsp.data[1] & 0xf != 4 and rsp.data[1] & 0xf != 5) {
        c.lprintf(log.Level.info, "Unknown PICMG Extension Version %d.%d", @as(c_int, rsp.data[1] & 0xf), @as(c_int, rsp.data[1] >> 4));
    } else {
        c.lprintf(log.Level.debug, "Discovered PICMG Extension Version %d.%d", @as(c_int, rsp.data[1] & 0xf), @as(c_int, rsp.data[1] >> 4));
        return 1;
    }
    return 0;
}

fn ipmbAddress(intf: *Intf) callconv(.c) u8 {
    if (intf.picmg_avail == 0) return 0;
    var data = [_]u8{0};
    const rsp = send(intf, c.PICMG_GET_ADDRESS_INFO_CMD, &data);
    if (rsp) |answer| {
        if (answer.ccode == 0 and answer.data_len >= 3) return answer.data[2];
        c.lprintf(log.Level.debug, "Get Address Info failed: %#x %s", @as(c_uint, answer.ccode), c.val2str(answer.ccode, c.completion_code_vals));
    } else {
        c.lprintf(log.Level.debug, "Get Address Info failed: No Response");
    }
    return 0;
}

fn getAddr(intf: *Intf, argc: c_int, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0 };
    if (argc > 0 and !fru(argv, 0, &data[1])) return -1;
    const rsp = send(intf, c.PICMG_GET_ADDRESS_INFO_CMD, &data) orelse {
        c.lprintf(log.Level.err, "Error. No valid response received.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error getting address information CC: 0x%02x", @as(c_uint, rsp.ccode));
        return -1;
    }
    if (rsp.data_len < 7) {
        c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
        return -1;
    }
    _ = c.printf("Hardware Address : 0x%02x\n", @as(c_uint, rsp.data[1]));
    _ = c.printf("IPMB-0 Address   : 0x%02x\n", @as(c_uint, rsp.data[2]));
    _ = c.printf("FRU ID           : 0x%02x\n", @as(c_uint, rsp.data[4]));
    _ = c.printf("Site ID          : 0x%02x\n", @as(c_uint, rsp.data[5]));
    _ = c.printf("Site Type        : ");
    switch (rsp.data[6]) {
        0 => _ = c.printf("ATCA board\n"),
        1 => _ = c.printf("Power Entry Module\n"),
        2 => _ = c.printf("Shelf FRU\n"),
        3 => _ = c.printf("Dedicated Shelf Manager\n"),
        4 => _ = c.printf("Fan Tray\n"),
        5 => _ = c.printf("Fan Filter Tray\n"),
        6 => _ = c.printf("Alarm module\n"),
        7 => {
            _ = c.printf("AMC");
            if (rsp.data[5] < amc_addr_map.len) {
                _ = c.printf("  -> IPMB-L Address: 0x%02x\n", @as(c_uint, amc_addr_map[rsp.data[5]].ipmbLAddr));
            } else {
                _ = c.printf("  -> IPMB-L Address: unknown\n");
            }
        },
        8 => _ = c.printf("PMC\n"),
        9 => _ = c.printf("RTM\n"),
        0xc0...0xcf => _ = c.printf("OEM\n"),
        else => _ = c.printf("unknown\n"),
    }
    return 0;
}

fn activation(intf: *Intf, argv: Args, state: u8) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, state };
    if (!fru(argv, 0, &data[1])) return -1;
    const rsp = send(intf, c.PICMG_FRU_ACTIVATION_CMD, &data) orelse {
        c.lprintf(log.Level.err, "Error activation/deactivation of FRU.");
        return -1;
    };
    if (rsp.ccode != 0 or rsp.data_len < 1) {
        c.lprintf(log.Level.err, "Error activation/deactivation of FRU.");
        return -1;
    }
    if (rsp.data[0] != 0) c.lprintf(log.Level.err, "Error activation/deactivation of FRU.");
    return 0;
}

fn policyGet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0 };
    if (!fru(argv, 0, &data[1])) return -1;
    const rsp = response(intf, c.PICMG_GET_FRU_POLICY_CMD, &data, "FRU activation policy get", 2) orelse return -1;
    _ = c.printf(" %s\n", @as([*:0]const u8, if (rsp.data[1] & 1 != 0) "activation locked" else "activation not locked"));
    _ = c.printf(" %s\n", @as([*:0]const u8, if (rsp.data[1] & 2 != 0) "deactivation locked" else "deactivation not locked"));
    return 0;
}

fn policySet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0, 0 };
    if (!fru(argv, 0, &data[1]) or
        !parseByte(argv, 1, &data[2], "FRU Lock Mask", 3) or
        !parseByte(argv, 2, &data[3], "FRU Activation Policy", 3)) return -1;
    _ = response(intf, c.PICMG_SET_FRU_POLICY_CMD, &data, "FRU activation policy set", 0) orelse return -1;
    return 0;
}

fn portGet(intf: *Intf, interface: i32, channel: u8, mode: c_int) callconv(.c) c_int {
    var data = [_]u8{ 0, (@as(u8, @truncate(@as(u32, @bitCast(interface)))) & 3) << 6 | (channel & 0x3f) };
    const rsp = send(intf, c.PICMG_GET_PORT_STATE_CMD, &data) orelse {
        c.lprintf(log.Level.err, "No valid response received.");
        return -1;
    };
    if (rsp.ccode != 0) {
        if (mode == query) c.lprintf(log.Level.err, "FRU portstate get failed with CC code 0x%02x", @as(c_uint, rsp.ccode));
        return -1;
    }
    if (rsp.data_len < 6) {
        c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
        return 0;
    }
    for (0..4) |index| {
        const offset = 1 + index * 5;
        if (offset + 5 > @as(usize, @intCast(rsp.data_len))) break;
        const state = rsp.data[offset + 4];
        if (mode == enabled_only and state != 1 or mode == disabled_only and state != 0) continue;
        const descriptor = rsp.data[offset .. offset + 4];
        const typ: u8 = (descriptor[1] >> 4) | (descriptor[2] & 0xf) << 4;
        const iface: u8 = descriptor[0] >> 6;
        _ = c.printf("      Link Grouping ID:     0x%02x\n", @as(c_uint, descriptor[3]));
        _ = c.printf("      Link Type Extension:  0x%02x\n", @as(c_uint, descriptor[2] >> 4));
        _ = c.printf("      Link Type:            0x%02x  ", @as(c_uint, typ));
        const desc: [*:0]const u8 = switch (typ) {
            0, 0xff => if (typ == 0) "Reserved 0\n" else "Reserved 255\n",
            1 => "PICMG 3.0 Base Interface 10/100/1000\n",
            2 => "PICMG 3.1 Ethernet Fabric Interface\n",
            3 => "PICMG 3.2 Infiniband Fabric Interface\n",
            4 => "PICMG 3.3 Star Fabric Interface\n",
            5 => "PCI Express Fabric Interface\n",
            6...0xef => "Reserved\n",
            0xf0...0xfe => "OEM GUID Definition\n",
        };
        _ = c.printf("%s", desc);
        _ = c.printf("      Link Designator: \n");
        _ = c.printf("        Port Flag:          0x%02x\n", @as(c_uint, descriptor[1] & 0xf));
        _ = c.printf("        Interface:          0x%02x - %s", @as(c_uint, iface), @as([*:0]const u8, switch (iface) {
            0 => "Base Interface\n",
            1 => "Fabric Interface\n",
            2 => "Update Channel\n",
            3 => "Reserved\n",
            else => unreachable,
        }));
        _ = c.printf("        Channel Number:     0x%02x\n", @as(c_uint, descriptor[0] & 0x3f));
        _ = c.printf("      STATE:                %s\n\n", @as([*:0]const u8, if (state == 1) "enabled" else "disabled"));
    }
    return 0;
}

fn portSet(intf: *Intf, interface: i32, channel: u8, port: i32, typ: u8, ext: u8, group: u8, state: u8) callconv(.c) c_int {
    const iface: u8 = @truncate(@as(u32, @bitCast(interface)));
    const port_bits: u8 = @truncate(@as(u32, @bitCast(port)));
    var data = [_]u8{
        0,                                    (channel & 0x3f) | (iface & 3) << 6,
        (port_bits & 0xf) | (typ & 0xf) << 4, (typ >> 4) | (ext & 0xf) << 4,
        group,                                state & 1,
    };
    _ = response(intf, c.PICMG_SET_PORT_STATE_CMD, &data, "Picmg portstate set", 0) orelse return -1;
    return 0;
}

const amc_types = [_][*:0]const u8{
    "RESERVED",            "RESERVED1", "PCI EXPRESS", "ADVANCED SWITCHING1",
    "ADVANCED SWITCHING2", "ETHERNET",  "RAPIDIO",     "STORAGE",
};
const amc_extensions = [8][16][*:0]const u8{
    .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "Gen 1 - NSSC", "Gen 1 - SSC", "Gen 2 - NSSC", "Gen 2 - SSC", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "Gen 1 - NSSC", "Gen 1 - SSC", "Gen 2 - NSSC", "Gen 2 - SSC", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "Gen 1 - NSSC", "Gen 1 - SSC", "Gen 2 - NSSC", "Gen 2 - SSC", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "1000BASE-BX (SerDES Gigabit)", "10GBASE-BX410 Gigabit XAUI", "", "", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "1.25 Gbaud transmission rate", "2.5 Gbaud transmission rate", "3.125 Gbaud transmission rate", "", "", "", "", "", "", "", "", "", "", "", "", "" },
    .{ "Fibre Channel", "Serial ATA", "Serial Attached SCSI", "", "", "", "", "", "", "", "", "", "", "", "", "" },
};

fn amcPortGet(intf: *Intf, device: i32, channel: u8, mode: c_int) callconv(.c) c_int {
    var data = [_]u8{ 0, channel, @truncate(@as(u32, @bitCast(device))) };
    const rsp = send(intf, c.PICMG_AMC_GET_PORT_STATE_CMD, data[0..if (device == -1 or card_type != atca) 2 else 3]) orelse {
        c.lprintf(log.Level.err, "No valid response received.");
        return -1;
    };
    if (rsp.ccode != 0) {
        if (mode == query) c.lprintf(log.Level.err, "Amc portstate get failed with CC code 0x%02x", @as(c_uint, rsp.ccode));
        return -1;
    }
    if (rsp.data_len < 5) {
        c.lprintf(log.Level.notice, "ipmi_picmg_amc_portstate_getUnexpected answer, can't print result");
        return 0;
    }
    for (0..4) |index| {
        const offset = 1 + 4 * index;
        if (offset + 4 > @as(usize, @intCast(rsp.data_len))) break;
        const link = rsp.data[offset .. offset + 4];
        const state = link[3];
        if (mode == enabled_only and state != 1 or mode == disabled_only and state != 0) continue;
        const typ: u8 = (link[0] >> 4) | (link[1] & 0xf);
        const ext: u8 = link[1] >> 4;
        if (device == -1 or card_type != atca) {
            _ = c.printf("   Link device :         AMC\n");
        } else {
            _ = c.printf("   Link device :         0x%02x\n", @as(c_uint, @intCast(device)));
        }
        _ = c.printf("   Link Grouping ID:     0x%02x\n", @as(c_uint, link[2]));
        if (typ == 0 or typ == 1 or typ == 0xff) {
            _ = c.printf("   Link Type Extension:  0x%02x\n", @as(c_uint, ext));
            _ = c.printf("   Link Type:            Reserved\n");
        } else if (typ >= 0xf0 and typ <= 0xfe) {
            _ = c.printf("   Link Type Extension:  0x%02x\n", @as(c_uint, ext));
            _ = c.printf("   Link Type:            OEM GUID Definition\n");
        } else if (typ < amc_types.len) {
            _ = c.printf("   Link Type Extension:  %s\n", amc_extensions[typ][ext]);
            _ = c.printf("   Link Type:            %s\n", amc_types[typ]);
        } else {
            _ = c.printf("   Link Type Extension:  0x%02x\n", @as(c_uint, ext));
            _ = c.printf("   Link Type:            undefined\n");
        }
        _ = c.printf("   Link Designator: \n");
        _ = c.printf("      Channel Number:    0x%02x\n", @as(c_uint, channel));
        _ = c.printf("      Port Flag:         0x%02x\n", @as(c_uint, link[0] & 0xf));
        _ = c.printf("   STATE:                %s\n\n", @as([*:0]const u8, if (state == 1) "enabled" else "disabled"));
    }
    return 0;
}

fn amcPortSet(intf: *Intf, channel: u8, port: i32, typ: u8, ext: u8, group: u8, state: u8, device: i32) callconv(.c) c_int {
    const port_bits: u8 = @truncate(@as(u32, @bitCast(port)));
    var data = [_]u8{
        0,                                     channel,
        (port_bits & 0xf) | (typ & 0xf) << 4,  (typ >> 4) | (ext & 0xf) << 4,
        group,                                 state & 1,
        @truncate(@as(u32, @bitCast(device))),
    };
    _ = response(intf, c.PICMG_AMC_SET_PORT_STATE_CMD, data[0..if (device >= 0) 7 else 6], "Amc portstate set", 0) orelse return -1;
    return 0;
}

fn ledProp(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0 };
    if (!fru(argv, 0, &data[1])) return -1;
    const rsp = response(intf, c.PICMG_GET_FRU_LED_PROPERTIES_CMD, &data, "LED get properties", 3) orelse return -1;
    _ = c.printf("General Status LED Properties:  0x%2x\n", @as(c_uint, rsp.data[1]));
    _ = c.printf("App. Specific  LED Count:       0x%2x\n", @as(c_uint, rsp.data[2]));
    return 0;
}

fn ledCap(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0 };
    if (!fru(argv, 0, &data[1]) or led_id(arg(argv, 1), &data[2]) != 0) return -1;
    const rsp = response(intf, c.PICMG_GET_LED_COLOR_CAPABILITIES_CMD, &data, "LED get capabilities", 4) orelse return -1;
    _ = c.printf("LED Color Capabilities: ");
    for (0..8) |index| {
        if (rsp.data[1] & (@as(u8, 1) << @as(u3, @intCast(index))) != 0)
            _ = c.printf("%s, ", colorName(@intCast(index)));
    }
    _ = c.printf("\nDefault LED Color in\n");
    _ = c.printf("      LOCAL control:  %s\n", colorName(rsp.data[2]));
    _ = c.printf("      OVERRIDE state: %s\n", colorName(rsp.data[3]));
    return 0;
}

fn ledGet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0 };
    if (!fru(argv, 0, &data[1]) or led_id(arg(argv, 1), &data[2]) != 0) return -1;
    const rsp = response(intf, c.PICMG_GET_FRU_LED_STATE_CMD, &data, "LED get state", 2) orelse return -1;
    _ = c.printf("LED states:\t\t\t\t\t\t  %x\t", @as(c_uint, rsp.data[1]));
    if (rsp.data[1] & 1 == 0) {
        _ = c.printf("[NO LOCAL CONTROL]\n");
        return 0;
    }
    if (rsp.data_len < 5 or (rsp.data[1] & 2 != 0 and rsp.data_len < 8) or
        (rsp.data[1] & 4 != 0 and rsp.data_len < 9))
    {
        c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
        return -1;
    }
    _ = c.printf("[LOCAL CONTROL");
    if (rsp.data[1] & 2 != 0) _ = c.printf("|OVERRIDE");
    if (rsp.data[1] & 4 != 0) _ = c.printf("|LAMPTEST");
    _ = c.printf("]\n");
    _ = c.printf("  Local Control function:     %x  %s\n", @as(c_uint, rsp.data[2]), ledFunctionName(rsp.data[2]));
    _ = c.printf("  Local Control On-Duration:  %x\n", @as(c_uint, rsp.data[3]));
    _ = c.printf("  Local Control Color:        %x  [%s]\n", @as(c_uint, rsp.data[4]), colorName(rsp.data[4]));
    if (rsp.data[1] & 2 != 0) {
        _ = c.printf("  Override function:     %x  %s\n", @as(c_uint, rsp.data[5]), ledFunctionName(rsp.data[2]));
        _ = c.printf("  Override On-Duration:  %x\n", @as(c_uint, rsp.data[6]));
        _ = c.printf("  Override Color:        %x  [%s]\n", @as(c_uint, rsp.data[7]), colorName(rsp.data[7]));
    }
    if (rsp.data[1] & 4 != 0)
        _ = c.printf("  Lamp test duration:    %x\n", @as(c_uint, rsp.data[8]));
    return 0;
}

fn ledFunctionName(value: u8) [*:0]const u8 {
    return if (value == 0) "[OFF]" else if (value == 0xff) "[ON]" else "[BLINKING]";
}

fn ledSet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0, 0, 0, 0 };
    if (!fru(argv, 0, &data[1]) or led_id(arg(argv, 1), &data[2]) != 0 or
        ledFunction(arg(argv, 2), &data[3]) != 0 or ledColor(arg(argv, 4), &data[5]) != 0) return -1;
    if (arg(argv, 3) == null) {
        c.lprintf(log.Level.err, "LED Duration: invalid argument(s).");
        return -1;
    }
    if (c.str2uchar(ptrArg(argv, 3), &data[4]) != 0 or (data[3] == 0xfb and data[4] > 127)) {
        c.lprintf(log.Level.err, "Given LED Duration '%s' is invalid", ptrArg(argv, 3));
        return -1;
    }
    if (data[4] != 0 and (data[3] == 0 or data[3] > 0xfb)) {
        c.lprintf(log.Level.warn, "Setting LED Duration '%s' to '0'", ptrArg(argv, 3));
        data[4] = 0;
    }
    _ = response(intf, c.PICMG_SET_FRU_LED_STATE_CMD, &data, "LED set state", 0) orelse return -1;
    return 0;
}

fn powerGet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0 };
    if (!fru(argv, 0, &data[1])) return -1;
    if (c.str2uchar(ptrArg(argv, 1), &data[2]) != 0 or data[2] > 3) {
        c.lprintf(log.Level.err, "Given Power Type '%s' is invalid", ptrArg(argv, 1));
        return -1;
    }
    const rsp = response(intf, c.PICMG_GET_POWER_LEVEL_CMD, &data, "Power level get", 4) orelse return -1;
    _ = c.printf("Dynamic Power Configuration: %s\n", @as([*:0]const u8, if (rsp.data[1] & 0x80 != 0) "enabled" else "disabled"));
    _ = c.printf("Actual Power Level:          %i\n", @as(c_int, rsp.data[1] & 0xf));
    _ = c.printf("Delay to stable Power:       %i\n", @as(c_int, rsp.data[2]));
    _ = c.printf("Power Multiplier:            %i\n", @as(c_int, rsp.data[3]));
    for (4..@as(usize, @intCast(rsp.data_len))) |index|
        _ = c.printf("   Power Draw %i:            %i\n", @as(c_int, @intCast(index - 3)), @divTrunc(@as(c_int, rsp.data[index]) * @as(c_int, rsp.data[3]), 10));
    return 0;
}

fn powerSet(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0, 0 };
    if (!fru(argv, 0, &data[1])) return -1;
    if (c.str2uchar(ptrArg(argv, 1), &data[2]) != 0 or (data[2] > 0x14 and data[2] != 0xff)) {
        c.lprintf(log.Level.err, "Given PICMG Power Level '%s' is invalid.", ptrArg(argv, 1));
        return -1;
    }
    if (c.str2uchar(ptrArg(argv, 2), &data[3]) != 0 or data[3] > 1) {
        c.lprintf(log.Level.err, "Given PICMG Present-to-desired '%s' is invalid.", ptrArg(argv, 2));
        return -1;
    }
    _ = response(intf, c.PICMG_SET_POWER_LEVEL_CMD, &data, "Power level set", 0) orelse return -1;
    return 0;
}

fn busres(intf: *Intf, mode: c_int) callconv(.c) c_int {
    if (mode != 0) return 0;
    var data = [_]u8{ 0, 0, 0 };
    for (0..5) |index| {
        data[2] = @intCast(index);
        const rsp = send(intf, c.PICMG_BUSED_RESOURCE_CMD, &data) orelse {
            _ = c.printf("bused resource control: no response\n");
            return -1;
        };
        if (rsp.ccode != 0) {
            _ = c.printf("bused resource control: returned CC code 0x%02x\n", @as(c_uint, rsp.ccode));
            return -1;
        }
        if (rsp.data_len < 2) {
            c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
            return -1;
        }
        _ = c.printf("Resource 0x%02x '%-26s' : 0x%02x [%s] \n", @as(c_uint, @intCast(index)), c.val2str(@intCast(index), c.picmg_busres_id_vals), @as(c_uint, rsp.data[1]), c.oemval2str(0, rsp.data[1], c.picmg_busres_board_status_vals));
    }
    return 0;
}

fn fruControl(intf: *Intf, argv: Args) callconv(.c) c_int {
    var data = [_]u8{ 0, 0, 0 };
    if (!fru(argv, 0, &data[1])) return -1;
    if (!parseByte(argv, 1, &data[2], "FRU Control Option", 4)) return -1;
    _ = c.printf("FRU Device Id: %d FRU Control Option: %s\n", @as(c_int, data[1]), c.val2str(data[2], c.picmg_frucontrol_vals));
    _ = response(intf, c.PICMG_FRU_CONTROL_CMD, &data, "frucontrol", 0) orelse return -1;
    _ = c.printf("frucontrol: ok\n");
    return 0;
}

fn clkGet(intf: *Intf, id: u8, res: i8, mode: c_int) callconv(.c) c_int {
    var data = [_]u8{ 0, id, @bitCast(res) };
    const rsp = send(intf, c.PICMG_AMC_GET_CLK_STATE_CMD, data[0..if (res == -1 or card_type != atca) 2 else 3]) orelse {
        c.lprintf(log.Level.err, "No valid response received.");
        return -1;
    };
    if (rsp.ccode != 0) {
        if (mode == query) {
            c.lprintf(log.Level.err, "Clk get failed with CC code 0x%02x", @as(c_uint, rsp.ccode));
            return -1;
        }
        return 0;
    }
    if (rsp.data_len < 2) {
        c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
        return -1;
    }
    const state = rsp.data[1];
    const on = state & 8 != 0;
    if (mode == enabled_only and !on or mode == disabled_only and on) return 0;
    const resource: i8 = if (card_type == amc) 0x40 else res;
    if (card_type == amc) {
        _ = c.printf("CLK resource id   : N/A [ AMC Module ]\n");
    } else {
        const r: u8 = @bitCast(res);
        _ = c.printf("CLK resource id   : %3d [ %s ]\n", @as(c_int, res), c.oemval2str((r >> 6) & 3, r & 0xf, c.picmg_clk_resource_vals));
    }
    const r: u8 = @bitCast(resource);
    _ = c.printf("CLK id            : %3d [ %s ]\n", @as(c_int, id), c.oemval2str((r >> 6) & 3, id, c.picmg_clk_id_vals));
    _ = c.printf("CLK setting       : 0x%02x\n", @as(c_uint, state));
    _ = c.printf(" - state:     %s\n", @as([*:0]const u8, if (on) "enabled" else "disabled"));
    _ = c.printf(" - direction: %s\n", @as([*:0]const u8, if (state & 4 != 0) "Source" else "Receiver"));
    _ = c.printf(" - PLL ctrl:  0x%x\n", @as(c_uint, state & 3));
    if (on) {
        if (rsp.data_len < 9) {
            c.lprintf(log.Level.err, "Unexpected answer, can't print result.");
            return -1;
        }
        const frequency: c_ulong = @as(c_ulong, rsp.data[5]) | @as(c_ulong, rsp.data[6]) << 8 |
            @as(c_ulong, rsp.data[7]) << 16 | @as(c_ulong, rsp.data[8]) << 24;
        _ = c.printf("  - Index:  %3d\n", @as(c_int, rsp.data[2]));
        _ = c.printf("  - Family: %3d [ %s ] \n", @as(c_int, rsp.data[3]), c.val2str(rsp.data[3], c.picmg_clk_family_vals));
        _ = c.printf("  - AccLVL: %3d [ %s ] \n", @as(c_int, rsp.data[4]), c.oemval2str(rsp.data[3], rsp.data[4], c.picmg_clk_accuracy_vals));
        _ = c.printf("  - Freq:   %ld\n", frequency);
    }
    return 0;
}

fn clkSet(intf: *Intf, argc: c_int, argv: Args) callconv(.c) c_int {
    var data: [11]u8 = @splat(0);
    var frequency: u32 = 0;
    if (clk_id(arg(argv, 0), &data[1]) != 0 or clk_index(arg(argv, 1), &data[2]) != 0 or
        clk_setting(arg(argv, 2), &data[3]) != 0 or clk_family(arg(argv, 3), &data[4]) != 0 or
        clk_acc(arg(argv, 4), &data[5]) != 0 or clkFreq(arg(argv, 5), &frequency) != 0) return -1;
    data[6] = @truncate(frequency);
    data[7] = @truncate(frequency >> 8);
    data[8] = @truncate(frequency >> 16);
    data[9] = @truncate(frequency >> 24);
    var len: usize = 10;
    if (card_type == atca) {
        if (argc <= 7) {
            c.lprintf(log.Level.err, "Missing resource id for atca board.");
            return -1;
        }
        var resource: i8 = 0;
        if (clkResid(arg(argv, 6), &resource) != 0) return -1;
        data[10] = @bitCast(resource);
        len = 11;
    }
    _ = response(intf, c.PICMG_AMC_SET_CLK_STATE_CMD, data[0..len], "Clk set", 0) orelse return -1;
    return 0;
}

fn help() callconv(.c) void {
    const lines = [_][*:0]const u8{
        "PICMG commands:",
        " properties           - get PICMG properties",
        " frucontrol           - FRU control",
        " addrinfo             - get address information",
        " activate             - activate a FRU",
        " deactivate           - deactivate a FRU",
        " policy get           - get the FRU activation policy",
        " policy set           - set the FRU activation policy",
        " portstate get        - get port state",
        " portstate getdenied  - get all denied[disabled] port description",
        " portstate getgranted - get all granted[enabled] port description",
        " portstate getall     - get all port state description",
        " portstate set        - set port state",
        " amcportstate get     - get port state",
        " amcportstate set     - set port state",
        " led prop             - get led properties",
        " led cap              - get led color capabilities",
        " led get              - get led state",
        " led set              - set led state",
        " power get            - get power level info",
        " power set            - set power level",
        " clk get              - get clk state",
        " clk getdenied        - get all(up to 16) denied[disabled] clock descriptions",
        " clk getgranted       - get all(up to 16) granted[enabled] clock descriptions",
        " clk getall           - get all(up to 16) clock descriptions",
        " clk set              - set clk state",
        " busres summary       - display brief bused resource status info",
    };
    for (lines) |line| c.lprintf(log.Level.notice, "%s", line);
}

fn main(intf: *Intf, argc: c_int, argv: Args) callconv(.c) c_int {
    if (argc <= 0 or eq(argv, 0, "help")) {
        help();
        return 0;
    }
    const show = eq(argv, 0, "properties");
    const rc = properties(intf, @intFromBool(show));
    if (eq(argv, 0, "addrinfo")) return getAddr(intf, argc - 1, argv + 1);
    if (eq(argv, 0, "busres")) {
        if (argc > 1 and eq(argv, 1, "summary")) {
            _ = busres(intf, 0);
        } else if (argc <= 1) {
            c.lprintf(log.Level.notice, "usage: busres summary");
        }
        return rc;
    }
    if (eq(argv, 0, "frucontrol")) {
        if (argc > 2) return fruControl(intf, argv + 1);
        c.lprintf(log.Level.notice, "usage: frucontrol <FRU-ID> <OPTION>");
        c.lprintf(log.Level.notice, "   OPTION:");
        c.lprintf(log.Level.notice, "      0      - Cold Reset");
        c.lprintf(log.Level.notice, "      1      - Warm Reset");
        c.lprintf(log.Level.notice, "      2      - Graceful Reboot");
        c.lprintf(log.Level.notice, "      3      - Issue Diagnostic Interrupt");
        c.lprintf(log.Level.notice, "      4      - Quiesce [AMC only]");
        c.lprintf(log.Level.notice, "      5-255  - Reserved");
        return -1;
    }
    if (eq(argv, 0, "activate") or eq(argv, 0, "deactivate")) {
        if (argc > 1) return activation(intf, argv + 1, @intFromBool(eq(argv, 0, "activate")));
        c.lprintf(log.Level.err, if (eq(argv, 0, "activate")) "Specify the FRU to activate." else "Specify the FRU to deactivate.");
        return -1;
    }
    if (eq(argv, 0, "policy")) {
        if (argc <= 1) {
            c.lprintf(log.Level.err, "Wrong parameters.");
            return -1;
        }
        if (eq(argv, 1, "get")) {
            if (argc > 2) return policyGet(intf, argv + 2);
            c.lprintf(log.Level.notice, "usage: get <fruid>");
        } else if (eq(argv, 1, "set")) {
            if (argc > 4) return policySet(intf, argv + 2);
            c.lprintf(log.Level.notice, "usage: set <fruid> <lockmask> <lock>");
            c.lprintf(log.Level.notice, "    lockmask:  [1] affect the deactivation locked bit");
            c.lprintf(log.Level.notice, "               [0] affect the activation locked bit");
            c.lprintf(log.Level.notice, "    lock:      [1] set/clear deactivation locked");
            c.lprintf(log.Level.notice, "               [0] set/clear locked");
        } else {
            c.lprintf(log.Level.err, "Specify FRU.");
            return -1;
        }
        return rc;
    }
    if (eq(argv, 0, "portstate")) {
        c.lprintf(log.Level.debug, "PICMG: portstate API");
        if (argc <= 1) {
            c.lprintf(log.Level.notice, "<set>|<getall>|<getgranted>|<getdenied>");
            return -1;
        }
        // In C the three "getall" spellings are nested inside the exact
        // "get" branch and thus do not send a request.
        if (eq(argv, 1, "get")) {
            c.lprintf(log.Level.debug, "PICMG: get");
            if (argc > 3) {
                var interface: i32 = 0;
                var channel_id: u8 = 0;
                if (amc_intf(arg(argv, 2), &interface) != 0 or chan(arg(argv, 3), &channel_id) != 0) return -1;
                c.lprintf(log.Level.debug, "PICMG: requesting interface %d", interface);
                c.lprintf(log.Level.debug, "PICMG: requesting channel %d", @as(c_int, channel_id));
                return portGet(intf, interface, channel_id, query);
            }
            c.lprintf(log.Level.notice, "<intf> <chn>|getall|getgranted|getdenied");
        } else if (eq(argv, 1, "set")) {
            if (argc != 9) {
                c.lprintf(log.Level.notice, "<intf> <chn> <port> <type> <ext> <group> <1|0>");
                return -1;
            }
            var interface: i32 = 0;
            var channel_id: u8 = 0;
            var port: i32 = 0;
            var typ: u8 = 0;
            var ext: u8 = 0;
            var group: u8 = 0;
            var state: u8 = 0;
            if (amc_intf(arg(argv, 2), &interface) != 0 or chan(arg(argv, 3), &channel_id) != 0 or
                amc_port(arg(argv, 4), &port) != 0 or link_type(arg(argv, 5), &typ) != 0 or
                link_ext(arg(argv, 6), &ext) != 0 or link_group(arg(argv, 7), &group) != 0 or
                enable(arg(argv, 8), &state) != 0) return -1;
            c.lprintf(log.Level.debug, "PICMG: interface %d", interface);
            c.lprintf(log.Level.debug, "PICMG: channel %d", @as(c_int, channel_id));
            c.lprintf(log.Level.debug, "PICMG: port %d", port);
            c.lprintf(log.Level.debug, "PICMG: type %d", @as(c_int, typ));
            c.lprintf(log.Level.debug, "PICMG: typeext %d", @as(c_int, ext));
            c.lprintf(log.Level.debug, "PICMG: group %d", @as(c_int, group));
            c.lprintf(log.Level.debug, "PICMG: enable %d", @as(c_int, state));
            return portSet(intf, interface, channel_id, port, typ, ext, group, state);
        }
        return rc;
    }
    if (eq(argv, 0, "amcportstate")) {
        c.lprintf(log.Level.debug, "PICMG: amcportstate API");
        if (argc <= 1) {
            c.lprintf(log.Level.notice, "<set>|<get>|<getall>|<getgranted>|<getdenied>");
            return -1;
        }
        if (eq(argv, 1, "get")) {
            c.lprintf(log.Level.debug, "PICMG: get");
            if (argc > 2) {
                var channel_id: u8 = 0;
                if (chan(arg(argv, 2), &channel_id) != 0) return -1;
                var device: i32 = -1;
                if (argc > 3 and amc_dev(arg(argv, 3), &device) != 0) return -1;
                c.lprintf(log.Level.debug, "PICMG: requesting device %d", device);
                c.lprintf(log.Level.debug, "PICMG: requesting channel %d", @as(c_int, channel_id));
                return amcPortGet(intf, device, channel_id, query);
            }
            c.lprintf(log.Level.notice, "<chn> <device>|getall|getgranted|getdenied");
        } else if (eq(argv, 1, "set")) {
            if (argc <= 7) {
                c.lprintf(log.Level.notice, "<chn> <portflags> <type> <ext> <group> <1|0> [<device>]");
                return -1;
            }
            var channel_id: u8 = 0;
            var port: i32 = 0;
            var typ: u8 = 0;
            var ext: u8 = 0;
            var group: u8 = 0;
            var state: u8 = 0;
            var device: i32 = -1;
            if (chan(arg(argv, 2), &channel_id) != 0 or amc_port(arg(argv, 3), &port) != 0 or
                link_type(arg(argv, 4), &typ) != 0 or link_ext(arg(argv, 5), &ext) != 0 or
                link_group(arg(argv, 6), &group) != 0 or enable(arg(argv, 7), &state) != 0) return -1;
            if (argc > 8 and amc_dev(arg(argv, 8), &device) != 0) return -1;
            c.lprintf(log.Level.debug, "PICMG: channel %d", @as(c_int, channel_id));
            c.lprintf(log.Level.debug, "PICMG: portflags %d", port);
            c.lprintf(log.Level.debug, "PICMG: type %d", @as(c_int, typ));
            c.lprintf(log.Level.debug, "PICMG: typeext %d", @as(c_int, ext));
            c.lprintf(log.Level.debug, "PICMG: group %d", @as(c_int, group));
            c.lprintf(log.Level.debug, "PICMG: enable %d", @as(c_int, state));
            c.lprintf(log.Level.debug, "PICMG: device %d", device);
            return amcPortSet(intf, channel_id, port, typ, ext, group, state, device);
        }
        return rc;
    }
    if (eq(argv, 0, "led")) {
        if (argc <= 1) return rc;
        if (eq(argv, 1, "prop")) {
            if (argc > 2) return ledProp(intf, argv + 2);
            c.lprintf(log.Level.notice, "led prop <FRU-ID>");
        } else if (eq(argv, 1, "cap")) {
            if (argc > 3) return ledCap(intf, argv + 2);
            c.lprintf(log.Level.notice, "led cap <FRU-ID> <LED-ID>");
        } else if (eq(argv, 1, "get")) {
            if (argc > 3) return ledGet(intf, argv + 2);
            c.lprintf(log.Level.notice, "led get <FRU-ID> <LED-ID>");
        } else if (eq(argv, 1, "set")) {
            if (argc > 6) return ledSet(intf, argv + 2);
            for ([_][*:0]const u8{
                "led set <FRU-ID> <LED-ID> <function> <duration> <color>",
                "   <FRU-ID>",
                "   <LED-ID>    0:         Blue LED",
                "               1:         LED 1",
                "               2:         LED 2",
                "               3:         LED 3",
                "               0x04-0xFE: OEM defined",
                "               0xFF:      All LEDs under management control",
                "   <function>  0:       LED OFF override",
                "               1 - 250: LED blinking override (off duration)",
                "               251:     LED Lamp Test",
                "               252:     LED restore to local control",
                "               255:     LED ON override",
                "   <duration>  0 - 127: LED Lamp Test duration",
                "               0 - 255: LED Lamp ON duration",
                "   <color>     0:   reserved",
                "               1:   BLUE",
                "               2:   RED",
                "               3:   GREEN",
                "               4:   AMBER",
                "               5:   ORANGE",
                "               6:   WHITE",
                "               7:   reserved",
                "               0xE: do not change",
                "               0xF: use default color",
            }) |line| c.lprintf(log.Level.notice, "%s", line);
        } else {
            c.lprintf(log.Level.notice, "prop | cap | get | set");
        }
        return rc;
    }
    if (eq(argv, 0, "power")) {
        if (argc <= 1) {
            c.lprintf(log.Level.notice, "<set>|<get>");
            return -1;
        }
        if (eq(argv, 1, "get")) {
            if (argc > 3) return powerGet(intf, argv + 2);
            c.lprintf(log.Level.notice, "power get <FRU-ID> <type>");
            c.lprintf(log.Level.notice, "   <type>   0 : steady state power draw levels");
            c.lprintf(log.Level.notice, "            1 : desired steady state draw levels");
            c.lprintf(log.Level.notice, "            2 : early power draw levels");
            c.lprintf(log.Level.notice, "            3 : desired early levels");
        } else if (eq(argv, 1, "set")) {
            if (argc > 4) return powerSet(intf, argv + 2);
            c.lprintf(log.Level.notice, "power set <FRU-ID> <level> <present-desired>");
            c.lprintf(log.Level.notice, "   <level>  0 :        Power Off");
            c.lprintf(log.Level.notice, "            0x1-0x14 : Power level");
            c.lprintf(log.Level.notice, "            0xFF :     do not change");
            c.lprintf(log.Level.notice, "\n   <present-desired> 0: do not change present levels");
            c.lprintf(log.Level.notice, "                     1: copy desired to present level");
        } else {
            c.lprintf(log.Level.notice, "<set>|<get>");
        }
        return -1;
    }
    if (eq(argv, 0, "clk")) {
        if (argc <= 1) {
            c.lprintf(log.Level.notice, "<set>|<get>|<getall>|<getgranted>|<getdenied>");
            return -1;
        }
        if (eq(argv, 1, "get")) {
            if (argc <= 2) {
                c.lprintf(log.Level.notice, "clk get");
                c.lprintf(log.Level.notice, "<CLK-ID> [<DEV-ID>] |getall|getgranted|getdenied");
                return -1;
            }
            var id: u8 = 0;
            var resource: i8 = -1;
            if (clk_id(arg(argv, 2), &id) != 0) return -1;
            if (argc > 3 and clkResid(arg(argv, 3), &resource) != 0) return -1;
            return clkGet(intf, id, resource, query);
        }
        if (eq(argv, 1, "set")) {
            if (argc > 7) return clkSet(intf, argc - 1, argv + 2);
            c.lprintf(log.Level.notice, "clk set <CLK-ID> <index> <setting> <family> <acc-lvl> <freq> [<DEV-ID>]");
            return -1;
        }
        c.lprintf(log.Level.notice, "<set>|<get>|<getall>|<getgranted>|<getdenied>");
        return -1;
    }
    if (!show) {
        help();
        return -1;
    }
    return rc;
}

pub fn exportSymbols() void {
    comptime {
        @setEvalBranchQuota(1000000);
        abi.assertLayout(AddrMap, c.struct_sAmcAddrMap);
        const names = .{
            .{ &colorName, c.picmg_led_color_str, "picmg_led_color_str" },
            .{ &help, c.ipmi_picmg_help, "ipmi_picmg_help" },
            .{ &chan, c.is_amc_channel, "is_amc_channel" },
            .{ &amc_dev, c.is_amc_dev, "is_amc_dev" },
            .{ &amc_intf, c.is_amc_intf, "is_amc_intf" },
            .{ &amc_port, c.is_amc_port, "is_amc_port" },
            .{ &clk_acc, c.is_clk_acc, "is_clk_acc" },
            .{ &clk_family, c.is_clk_family, "is_clk_family" },
            .{ &clkFreq, c.is_clk_freq, "is_clk_freq" },
            .{ &clk_id, c.is_clk_id, "is_clk_id" },
            .{ &clk_index, c.is_clk_index, "is_clk_index" },
            .{ &clkResid, c.is_clk_resid, "is_clk_resid" },
            .{ &clk_setting, c.is_clk_setting, "is_clk_setting" },
            .{ &enable, c.is_enable, "is_enable" },
            .{ &ledColor, c.is_led_color, "is_led_color" },
            .{ &ledFunction, c.is_led_function, "is_led_function" },
            .{ &led_id, c.is_led_id, "is_led_id" },
            .{ &link_group, c.is_link_group, "is_link_group" },
            .{ &link_type, c.is_link_type, "is_link_type" },
            .{ &link_ext, c.is_link_type_ext, "is_link_type_ext" },
            .{ &getAddr, c.ipmi_picmg_getaddr, "ipmi_picmg_getaddr" },
            .{ &properties, c.ipmi_picmg_properties, "ipmi_picmg_properties" },
            .{ &activation, c.ipmi_picmg_fru_activation, "ipmi_picmg_fru_activation" },
            .{ &policyGet, c.ipmi_picmg_fru_activation_policy_get, "ipmi_picmg_fru_activation_policy_get" },
            .{ &policySet, c.ipmi_picmg_fru_activation_policy_set, "ipmi_picmg_fru_activation_policy_set" },
            .{ &portGet, c.ipmi_picmg_portstate_get, "ipmi_picmg_portstate_get" },
            .{ &portSet, c.ipmi_picmg_portstate_set, "ipmi_picmg_portstate_set" },
            .{ &amcPortGet, c.ipmi_picmg_amc_portstate_get, "ipmi_picmg_amc_portstate_get" },
            .{ &amcPortSet, c.ipmi_picmg_amc_portstate_set, "ipmi_picmg_amc_portstate_set" },
            .{ &ledProp, c.ipmi_picmg_get_led_properties, "ipmi_picmg_get_led_properties" },
            .{ &ledCap, c.ipmi_picmg_get_led_capabilities, "ipmi_picmg_get_led_capabilities" },
            .{ &ledGet, c.ipmi_picmg_get_led_state, "ipmi_picmg_get_led_state" },
            .{ &ledSet, c.ipmi_picmg_set_led_state, "ipmi_picmg_set_led_state" },
            .{ &powerGet, c.ipmi_picmg_get_power_level, "ipmi_picmg_get_power_level" },
            .{ &powerSet, c.ipmi_picmg_set_power_level, "ipmi_picmg_set_power_level" },
            .{ &busres, c.ipmi_picmg_bused_resource, "ipmi_picmg_bused_resource" },
            .{ &fruControl, c.ipmi_picmg_fru_control, "ipmi_picmg_fru_control" },
            .{ &clkGet, c.ipmi_picmg_clk_get, "ipmi_picmg_clk_get" },
            .{ &clkSet, c.ipmi_picmg_clk_set, "ipmi_picmg_clk_set" },
            .{ &main, c.ipmi_picmg_main, "ipmi_picmg_main" },
            .{ &ipmbAddress, c.ipmi_picmg_ipmb_address, "ipmi_picmg_ipmb_address" },
            .{ &discover, c.picmg_discover, "picmg_discover" },
        };
        for (names) |entry| {
            abi.assertCallSignature(@typeInfo(@TypeOf(entry[0])).pointer.child, @TypeOf(entry[1]));
            @export(entry[0], .{ .name = entry[2], .linkage = .strong });
        }
        @export(&amc_addr_map, .{ .name = "amcAddrMap", .linkage = .strong });
    }
}
