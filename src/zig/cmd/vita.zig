//! VITA 46.11 VSO discovery, IPMB address acquisition, and the `vita` command.
//! Selected with `-Dzig-modules=vita` in place of `lib/ipmi_vita.c`.
//! Requests, responses, C parsing, and libc printf formatting retain the
//! C ABI; diagnostics use the typed logger. The three public entry points
//! are checked against their C headers.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const ValStr = @import("../util/helper.zig").ValStr;

const group: u8 = c.GROUP_EXT_VITA;
const netfn: u6 = ipmi.NetFn.picmg;

const Cmd = enum(u8) {
    help = 0,
    properties,
    frucontrol,
    addrinfo,
    activate,
    deactivate,
    policy_get,
    policy_set,
    led_prop,
    led_cap,
    led_get,
    led_set,
    unknown = 255,
};

const site_types = [_]ValStr{
    .{ .val = c.VITA_FRONT_VPX_MODULE, .str = "Front Loading VPX Plug-In Module" },
    .{ .val = c.VITA_POWER_ENTRY, .str = "Power Entry Module" },
    .{ .val = c.VITA_CHASSIS_FRU, .str = "Chassic FRU Information Module" },
    .{ .val = c.VITA_DEDICATED_CHMC, .str = "Dedicated Chassis Manager" },
    .{ .val = c.VITA_FAN_TRAY, .str = "Fan Tray" },
    .{ .val = c.VITA_FAN_TRAY_FILTER, .str = "Fan Tray Filter" },
    .{ .val = c.VITA_ALARM_PANEL, .str = "Alarm Panel" },
    .{ .val = c.VITA_XMC, .str = "XMC" },
    .{ .val = c.VITA_VPX_RTM, .str = "VPX Rear Transition Module" },
    .{ .val = c.VITA_FRONT_VME_MODULE, .str = "Front Loading VME Plug-In Module" },
    .{ .val = c.VITA_FRONT_VXS_MODULE, .str = "Front Loading VXS Plug-In Module" },
    .{ .val = c.VITA_POWER_SUPPLY, .str = "Power Supply" },
    .{ .val = c.VITA_FRONT_VITA62_MODULE, .str = "Front Loading VITA 62 Module\n" },
    .{ .val = c.VITA_71_MODULE, .str = "VITA 71 Module\n" },
    .{ .val = c.VITA_FMC, .str = "FMC\n" },
    .{ .val = 0, .str = null },
};

const help_strings = [_]ValStr{
    .{ .val = @intFromEnum(Cmd.help), .str = "VITA commands:\n" ++
        "    properties        - get VSO properties\n" ++
        "    frucontrol        - FRU control\n" ++
        "    addrinfo          - get address information\n" ++
        "    activate          - activate a FRU\n" ++
        "    deactivate        - deactivate a FRU\n" ++
        "    policy get        - get the FRU activation policy\n" ++
        "    policy set        - set the FRU activation policy\n" ++
        "    led prop          - get led properties\n" ++
        "    led cap           - get led color capabilities\n" ++
        "    led get           - get led state\n" ++
        "    led set           - set led state" },
    .{ .val = @intFromEnum(Cmd.frucontrol), .str = "usage: frucontrol <FRU-ID> <OPTION>\n" ++
        "    OPTION: 0 - Cold Reset\n" ++
        "            1 - Warm Reset\n" ++
        "            2 - Graceful Reboot\n" ++
        "            3 - Issue Diagnostic Interrupt" },
    .{ .val = @intFromEnum(Cmd.addrinfo), .str = "usage: addrinfo [<FRU-ID>]" },
    .{ .val = @intFromEnum(Cmd.activate), .str = "usage: activate <FRU-ID>" },
    .{ .val = @intFromEnum(Cmd.deactivate), .str = "usage: deactivate <FRU-ID>" },
    .{ .val = @intFromEnum(Cmd.policy_get), .str = "usage: policy get <FRU-ID>" },
    .{ .val = @intFromEnum(Cmd.policy_set), .str = "usage: policy set <FRU-ID> <MASK> <VALUE>\n" ++
        "    MASK:  [3] affect the Default-Activation-Locked Policy Bit\n" ++
        "           [2] affect the Commanded-Deactivation-Ignored Policy Bit\n" ++
        "           [1] affect the Deactivation-Locked Policy Bit\n" ++
        "           [0] affect the Activation-Locked Policy Bit\n" ++
        "    VALUE: [3] value for the Default-Activation-Locked Policy Bit\n" ++
        "           [2] value for the Commanded-Deactivation-Ignored Policy Bit\n" ++
        "           [1] value for the Deactivation-Locked Policy Bit\n" ++
        "           [0] value for the Activation-Locked Policy Bit" },
    .{ .val = @intFromEnum(Cmd.led_prop), .str = "usage: led prop <FRU-ID>" },
    .{ .val = @intFromEnum(Cmd.led_cap), .str = "usage: led cap <FRU-ID> <LED-ID" },
    .{ .val = @intFromEnum(Cmd.led_get), .str = "usage: led get <FRU-ID> <LED-ID" },
    .{ .val = @intFromEnum(Cmd.led_set), .str = "usage: led set <FRU-ID> <LED-ID> <FUNCTION> <DURATION> <COLOR>\n" ++
        "    <FRU-ID>\n" ++
        "    <LED-ID>   0-0xFE:    Specified LED\n" ++
        "               0xFF:      All LEDs under management control\n" ++
        "    <FUNCTION> 0:       LED OFF override\n" ++
        "               1 - 250: LED blinking override (off duration)\n" ++
        "               251:     LED Lamp Test\n" ++
        "               252:     LED restore to local control\n" ++
        "               255:     LED ON override\n" ++
        "    <DURATION> 1 - 127: LED Lamp Test / on duration\n" ++
        "    <COLOR>    1:   BLUE\n" ++
        "               2:   RED\n" ++
        "               3:   GREEN\n" ++
        "               4:   AMBER\n" ++
        "               5:   ORANGE\n" ++
        "               6:   WHITE\n" ++
        "               0xE: do not change\n" ++
        "               0xF: use default color" },
    .{ .val = @intFromEnum(Cmd.unknown), .str = "Unknown command" },
    .{ .val = 0, .str = null },
};

fn request(cmd: u8, data: []u8) Request {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = netfn, .lun = 0 };
    req.msg.cmd = cmd;
    req.msg.data = data.ptr;
    req.msg.data_len = @intCast(data.len);
    return req;
}

fn completion(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

/// Validate before reading response bytes. Address-info's no-reply diagnostic
/// has no period; all other CLI operations have one.
fn sendChecked(intf: *Intf, req: *Request, min_len: c_int, address: bool, led_state: bool) ?*Response {
    const rsp = intf.sendrecv.?(intf, req) orelse {
        log.print(log.Level.err, if (address) "No valid response received" else "No valid response received.", .{});
        return null;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Invalid completion code received: %s", .{completion(rsp.ccode)});
        return null;
    }
    if (rsp.data_len < min_len or (led_state and
        ((rsp.data[1] & 0x02 != 0 and rsp.data_len < 8) or
            (rsp.data[1] & 0x04 != 0 and rsp.data_len < 9))))
    {
        log.print(log.Level.err, "Invalid response length %d", .{rsp.data_len});
        return null;
    }
    if (rsp.data[0] != group) {
        log.print(log.Level.err, "Invalid group extension %#x", .{@as(c_uint, rsp.data[0])});
        return null;
    }
    return rsp;
}

fn discover(intf: *Intf) callconv(.c) u8 {
    var data = [_]u8{group};
    var req = request(c.VITA_GET_VSO_CAPABILITIES_CMD, &data);
    log.print(log.Level.info, "Running Get VSO Capabilities my_addr %#x, transit %#x, target %#x", .{ intf.my_addr, intf.transit_addr, intf.target_addr });
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        log.print(log.Level.err, "No valid response received", .{});
        return 0;
    };
    if (rsp.ccode == 0xcc) {
        log.print(log.Level.info, "Invalid data field received: %s", .{completion(rsp.ccode)});
    } else if (rsp.ccode != 0) {
        log.print(log.Level.info, "Invalid completion code received: %s", .{completion(rsp.ccode)});
    } else if (rsp.data_len < 5) {
        log.print(log.Level.info, "Invalid response length %d", .{rsp.data_len});
    } else if (rsp.data[0] != group) {
        log.print(log.Level.info, "Invalid group extension %#x", .{@as(c_uint, rsp.data[0])});
    } else if (rsp.data[3] & 0x03 != 0) {
        log.print(log.Level.info, "Unknown VSO Standard %d", .{@as(c_int, rsp.data[3] & 0x03)});
    } else if (rsp.data[4] & 0x0f != 1) {
        log.print(log.Level.info, "Unknown VSO Specification Revision %d.%d", .{ @as(c_int, rsp.data[4] & 0x0f), @as(c_int, rsp.data[4] >> 4) });
    } else {
        log.print(log.Level.info, "Discovered VITA 46.11 Revision %d.%d", .{ @as(c_int, rsp.data[4] & 0x0f), @as(c_int, rsp.data[4] >> 4) });
        return 1;
    }
    return 0;
}

fn ipmbAddress(intf: *Intf) callconv(.c) u8 {
    var data = [_]u8{group};
    var req = request(c.VITA_GET_FRU_ADDRESS_INFO_CMD, &data);
    const rsp = sendChecked(intf, &req, 7, true, false) orelse return 0;
    return rsp.data[2];
}

fn addrInfo(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0 };
    if (args.len > 0 and c.is_fru_id(args[0], &data[1]) != 0) return -1;
    var req = request(c.VITA_GET_FRU_ADDRESS_INFO_CMD, &data);
    const rsp = sendChecked(intf, &req, 7, true, false) orelse return -1;
    _ = c.printf("Hardware Address : 0x%02x\n", @as(c_uint, rsp.data[1]));
    _ = c.printf("IPMB-0 Address   : 0x%02x\n", @as(c_uint, rsp.data[2]));
    _ = c.printf("FRU ID           : 0x%02x\n", @as(c_uint, rsp.data[4]));
    _ = c.printf("Site ID          : 0x%02x\n", @as(c_uint, rsp.data[5]));
    _ = c.printf("Site Type        : %s\n", c.val2str(rsp.data[6], @ptrCast(&site_types)));
    if (rsp.data_len > 8) {
        _ = c.printf("Channel 7 Address: 0x%02x\n", @as(c_uint, rsp.data[8]));
    }
    return 0;
}

fn properties(intf: *Intf) c_int {
    var data = [_]u8{group};
    var req = request(c.VITA_GET_VSO_CAPABILITIES_CMD, &data);
    // The C check is five bytes, but the printer reads bytes five and six.
    // Reject an incomplete reply rather than exposing stale response data.
    const rsp = sendChecked(intf, &req, 7, false, false) orelse return -1;
    _ = c.printf("VSO Identifier    : 0x%02x\n", @as(c_uint, rsp.data[0]));
    _ = c.printf("IPMC Identifier   : 0x%02x\n", @as(c_uint, rsp.data[1]));
    _ = c.printf("    Tier  %d\n", @as(c_int, rsp.data[1] & 3) + 1);
    _ = c.printf("    Layer %d\n", @as(c_int, (rsp.data[1] & 0x30) >> 4) + 1);
    _ = c.printf("IPMB Capabilities : 0x%02x\n", @as(c_uint, rsp.data[2]));
    const frequency = (rsp.data[2] & 0x30) >> 4;
    _ = c.printf("    Frequency  %skHz\n", @as([*:0]const u8, if (frequency == 0) "100" else if (frequency == 1) "400" else "RESERVED"));
    switch (rsp.data[2] & 3) {
        0 => _ = c.printf("    1 IPMB interface supported\n"),
        1 => _ = c.printf("    2 IPMB interfaces supported\n"),
        else => {},
    }
    _ = c.printf("VSO Standard      : %s\n", @as([*:0]const u8, if (rsp.data[3] & 3 == 0) "VITA 46.11" else "RESERVED"));
    _ = c.printf("VSO Spec Revision : %d.%d\n", @as(c_int, rsp.data[4] & 15), @as(c_int, rsp.data[4] >> 4));
    _ = c.printf("Max FRU Device ID : 0x%02x\n", @as(c_uint, rsp.data[5]));
    _ = c.printf("FRU Device ID     : 0x%02x\n", @as(c_uint, rsp.data[6]));
    return 0;
}

fn activation(intf: *Intf, fru: [*:0]u8, active: u8) c_int {
    var data = [_]u8{ group, 0, active };
    if (c.is_fru_id(fru, &data[1]) != 0) return -1;
    var req = request(c.VITA_SET_FRU_ACTIVATION_CMD, &data);
    _ = sendChecked(intf, &req, 1, false, false) orelse return -1;
    _ = c.printf("FRU has been successfully %s\n", @as([*:0]const u8, if (active != 0) "activated" else "deactivated"));
    return 0;
}

fn policyGet(intf: *Intf, fru: [*:0]u8) c_int {
    var data = [_]u8{ group, 0 };
    if (c.is_fru_id(fru, &data[1]) != 0) return -1;
    var req = request(c.VITA_GET_FRU_STATE_POLICY_BITS_CMD, &data);
    const rsp = sendChecked(intf, &req, 2, false, false) orelse return -1;
    const bits = rsp.data[1];
    _ = c.printf("FRU State Policy Bits:\t%xh\n", @as(c_uint, bits));
    _ = c.printf("    Default-Activation-Locked Policy Bit is %d\n", @as(c_int, @intFromBool(bits & 8 != 0)));
    _ = c.printf("    Commanded-Deactivation-Ignored Policy Bit is %d\n", @as(c_int, @intFromBool(bits & 4 != 0)));
    _ = c.printf("    Deactivation-Locked Policy Bit is %d\n", @as(c_int, @intFromBool(bits & 2 != 0)));
    _ = c.printf("    Activation-Locked Policy Bit is %d\n", @as(c_int, bits & 1));
    return 0;
}

fn policySet(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0, 0, 0 };
    if (c.is_fru_id(args[0], &data[1]) != 0 or
        c.str2uchar(args[1], &data[2]) != 0 or
        c.str2uchar(args[2], &data[3]) != 0) return -1;
    var req = request(c.VITA_SET_FRU_STATE_POLICY_BITS_CMD, &data);
    _ = sendChecked(intf, &req, 1, false, false) orelse return -1;
    _ = c.printf("FRU state policy bits have been updated\n");
    return 0;
}

fn ledProperties(intf: *Intf, fru: [*:0]u8) c_int {
    var data = [_]u8{ group, 0 };
    if (c.is_fru_id(fru, &data[1]) != 0) return -1;
    var req = request(c.VITA_GET_FRU_LED_PROPERTIES_CMD, &data);
    const rsp = sendChecked(intf, &req, 3, false, false) orelse return -1;
    _ = c.printf("LED Count:\t   %#x\n", @as(c_uint, rsp.data[2]));
    return 0;
}

fn ledColorCapabilities(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0, 0 };
    if (c.is_fru_id(args[0], &data[1]) != 0 or
        c.str2uchar(args[1], &data[2]) != 0) return -1;
    var req = request(c.VITA_GET_LED_COLOR_CAPABILITIES_CMD, &data);
    const rsp = sendChecked(intf, &req, 4, false, false) orelse return -1;
    _ = c.printf("LED Color Capabilities: ");
    for (0..8) |i| {
        if (rsp.data[1] & (@as(u8, 1) << @intCast(i)) != 0) {
            _ = c.printf("%s, ", c.picmg_led_color_str(@intCast(i)));
        }
    }
    _ = c.putchar('\n');
    _ = c.printf("Default LED Color in\n");
    _ = c.printf("      LOCAL control:  %s\n", c.picmg_led_color_str(rsp.data[2]));
    _ = c.printf("      OVERRIDE state: %s\n", c.picmg_led_color_str(rsp.data[3]));
    if (rsp.data_len == 5) {
        _ = c.printf("LED flags:\n");
        if (rsp.data[4] & 2 != 0) _ = c.printf("      [HW RESTRICT]\n");
        if (rsp.data[4] & 1 != 0) _ = c.printf("      [PAYLOAD PWR]\n");
    }
    return 0;
}

fn ledState(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0, 0 };
    if (c.is_fru_id(args[0], &data[1]) != 0 or
        c.str2uchar(args[1], &data[2]) != 0) return -1;
    var req = request(c.VITA_GET_FRU_LED_STATE_CMD, &data);
    const rsp = sendChecked(intf, &req, 5, false, true) orelse return -1;
    const flags = rsp.data[1];
    _ = c.printf("LED states:                   %x\t", @as(c_uint, flags));
    if (flags & 1 != 0) _ = c.printf("[LOCAL CONTROL] ");
    if (flags & 2 != 0) _ = c.printf("[OVERRIDE] ");
    if (flags & 4 != 0) _ = c.printf("[LAMPTEST] ");
    if (flags & 8 != 0) _ = c.printf("[HW RESTRICT] ");
    _ = c.putchar('\n');
    if (flags & 1 != 0) {
        _ = c.printf("  Local Control function:     %x\t", @as(c_uint, rsp.data[2]));
        _ = c.printf("%s\n", @as([*:0]const u8, ledFunction(rsp.data[2])));
        _ = c.printf("  Local Control On-Duration:  %x\n", @as(c_uint, rsp.data[3]));
        _ = c.printf("  Local Control Color:        %x\t[%s]\n", @as(c_uint, rsp.data[4]), c.picmg_led_color_str(rsp.data[4] & 7));
    }
    if (flags & 6 != 0) {
        _ = c.printf("  Override function:     %x\t", @as(c_uint, rsp.data[5]));
        _ = c.printf("%s\n", @as([*:0]const u8, ledFunction(rsp.data[5])));
        _ = c.printf("  Override On-Duration:  %x\n", @as(c_uint, rsp.data[6]));
        _ = c.printf("  Override Color:        %x\t[%s]\n", @as(c_uint, rsp.data[7]), c.picmg_led_color_str(rsp.data[7] & 7));
        if (flags == 0x04) _ = c.printf("  Lamp test duration:    %x\n", @as(c_uint, rsp.data[8]));
    }
    return 0;
}

fn ledFunction(value: u8) [*:0]const u8 {
    return if (value == 0) "[OFF]" else if (value == 255) "[ON]" else "[BLINKING]";
}

fn ledSet(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0, 0, 0, 0, 0 };
    if (c.is_fru_id(args[0], &data[1]) != 0 or
        c.str2uchar(args[1], &data[2]) != 0 or
        c.str2uchar(args[2], &data[3]) != 0 or
        c.str2uchar(args[3], &data[4]) != 0 or
        c.str2uchar(args[4], &data[5]) != 0) return -1;
    var req = request(c.VITA_SET_FRU_LED_STATE_CMD, &data);
    _ = sendChecked(intf, &req, 1, false, false) orelse return -1;
    _ = c.printf("LED state has been updated\n");
    return 0;
}

fn fruControl(intf: *Intf, args: []const [*:0]u8) c_int {
    var data = [_]u8{ group, 0, 0 };
    if (c.is_fru_id(args[0], &data[1]) != 0 or
        c.str2uchar(args[1], &data[2]) != 0) return -1;
    _ = c.printf("FRU Device Id: %d FRU Control Option: %s\n", @as(c_int, data[1]), c.val2str(data[2], c.picmg_frucontrol_vals));
    var req = request(c.VITA_FRU_CONTROL_CMD, &data);
    _ = sendChecked(intf, &req, 1, false, false) orelse return -1;
    _ = c.printf("FRU Control: ok\n");
    return 0;
}

fn eql(arg: [*:0]const u8, str: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(arg), str);
}

fn getCmd(args: []const [*:0]const u8) Cmd {
    if (args.len == 0 or eql(args[0], "help")) return .help;
    if (eql(args[0], "properties")) return .properties;
    if (eql(args[0], "frucontrol")) return .frucontrol;
    if (eql(args[0], "addrinfo")) return .addrinfo;
    if (eql(args[0], "activate")) return .activate;
    if (eql(args[0], "deactivate")) return .deactivate;
    if (eql(args[0], "policy")) {
        if (args.len < 2) return .unknown;
        if (eql(args[1], "get")) return .policy_get;
        if (eql(args[1], "set")) return .policy_set;
    }
    if (eql(args[0], "led")) {
        if (args.len < 2) return .unknown;
        if (eql(args[1], "prop")) return .led_prop;
        if (eql(args[1], "cap")) return .led_cap;
        if (eql(args[1], "get")) return .led_get;
        if (eql(args[1], "set")) return .led_set;
    }
    return .unknown;
}

fn vitaMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    const args = argv[0..@intCast(@max(argc, 0))];
    var cmd = getCmd(args);
    var rc: c_int = -1;
    var show_help = false;
    switch (cmd) {
        .help => {
            cmd = getCmd(if (args.len == 0) args else args[1..]);
            show_help = true;
            rc = 0;
        },
        .properties => rc = properties(intf),
        .frucontrol => if (args.len > 2) {
            rc = fruControl(intf, args[1..]);
        } else {
            show_help = true;
        },
        .addrinfo => rc = addrInfo(intf, args[1..]),
        .activate, .deactivate => if (args.len > 1) {
            rc = activation(intf, args[1], @intFromBool(cmd == .activate));
        } else {
            show_help = true;
        },
        .policy_get => if (args.len > 2) {
            rc = policyGet(intf, args[2]);
        } else {
            show_help = true;
        },
        .policy_set => if (args.len > 4) {
            rc = policySet(intf, args[2..]);
        } else {
            show_help = true;
        },
        .led_prop => if (args.len > 2) {
            rc = ledProperties(intf, args[2]);
        } else {
            show_help = true;
        },
        .led_cap => if (args.len > 3) {
            rc = ledColorCapabilities(intf, args[2..]);
        } else {
            show_help = true;
        },
        .led_get => if (args.len > 3) {
            rc = ledState(intf, args[2..]);
        } else {
            show_help = true;
        },
        .led_set => if (args.len > 6) {
            rc = ledSet(intf, args[2..]);
        } else {
            show_help = true;
        },
        .unknown => {
            log.print(log.Level.notice, "Unknown command", .{});
            cmd = .help;
            show_help = true;
        },
    }
    if (show_help) {
        log.print(log.Level.notice, "%s", .{c.val2str(@intFromEnum(cmd), @ptrCast(&help_strings))});
    }
    return rc;
}

test "VITA dispatch includes every nested verb and rejects incomplete subcommands" {
    try std.testing.expectEqual(Cmd.help, getCmd(&.{}));
    try std.testing.expectEqual(Cmd.help, getCmd(&.{"help"}));
    inline for (.{
        .{ "properties", Cmd.properties },
        .{ "frucontrol", Cmd.frucontrol },
        .{ "addrinfo", Cmd.addrinfo },
        .{ "activate", Cmd.activate },
        .{ "deactivate", Cmd.deactivate },
    }) |entry| {
        try std.testing.expectEqual(entry[1], getCmd(&.{entry[0]}));
    }
    try std.testing.expectEqual(Cmd.policy_get, getCmd(&.{ "policy", "get" }));
    try std.testing.expectEqual(Cmd.policy_set, getCmd(&.{ "policy", "set" }));
    try std.testing.expectEqual(Cmd.led_prop, getCmd(&.{ "led", "prop" }));
    try std.testing.expectEqual(Cmd.led_cap, getCmd(&.{ "led", "cap" }));
    try std.testing.expectEqual(Cmd.led_get, getCmd(&.{ "led", "get" }));
    try std.testing.expectEqual(Cmd.led_set, getCmd(&.{ "led", "set" }));
    try std.testing.expectEqual(Cmd.unknown, getCmd(&.{"policy"}));
    try std.testing.expectEqual(Cmd.unknown, getCmd(&.{"led"}));
    try std.testing.expectEqual(Cmd.unknown, getCmd(&.{ "led", "bogus" }));
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(discover), @TypeOf(c.vita_discover));
    abi.assertCallSignature(@TypeOf(ipmbAddress), @TypeOf(c.ipmi_vita_ipmb_address));
    abi.assertCallSignature(@TypeOf(vitaMain), @TypeOf(c.ipmi_vita_main));
    @export(&discover, .{ .name = "vita_discover", .linkage = .strong });
    @export(&ipmbAddress, .{ .name = "ipmi_vita_ipmb_address", .linkage = .strong });
    @export(&vitaMain, .{ .name = "ipmi_vita_main", .linkage = .strong });
}
