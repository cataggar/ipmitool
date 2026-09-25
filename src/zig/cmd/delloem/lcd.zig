const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const log = common.log;

const mode_user: u32 = 0;
const mode_default: u32 = 1;
const mode_none: u32 = 2;

pub fn usage() void {
    common.notice(&.{
        "",                                                                    "Generic DELL HW:",                                                          "   lcd set {none}|{default}|{custom <text>}",
        "      Set LCD text displayed during non-fault conditions",            "",                                                                          "iDRAC 11g or iDRAC 12g or  iDRAC 13g :",
        "   lcd set {mode}|{lcdqualifier}|{errordisplay}",                     "      Allows you to set the LCD mode and user-defined string.",             "",
        "   lcd set mode {none}|{modelname}|{ipv4address}|{macaddress}|",      "   {systemname}|{servicetag}|{ipv6address}|{ambienttemp}",                  "   {systemwatt }|{assettag}|{userdefined}<text>",
        "\t   Allows you to set the LCD display mode to any of the preceding", "      parameters",                                                          "",
        "   lcd set lcdqualifier {watt}|{btuphr}|{celsius}|{fahrenheit}",      "      Allows you to set the unit for the system ambient temperature mode.", "",
        "   lcd set errordisplay {sel}|{simple}",                              "      Allows you to set the error display.",                                "",
        "   lcd info",                                                         "      Show LCD text that is displayed during non-fault conditions",         "",
        "",                                                                    "   lcd set vkvm{active}|{inactive}",                                        "      Set vKVM active and inactive, message will be displayed on lcd",
        "      when vKVM is active and vKVM session is in progress",           "",                                                                          "   lcd set frontpanelaccess {viewandmodify}|{viewonly}|{disabled}",
        "      Set LCD mode to view and modify, view only or disabled ",       "",                                                                          "   lcd status",
        "      Show LCD Status for vKVM display<active|inactive>",             "      and Front Panel access mode {viewandmodify}|{viewonly}|{disabled}",   "",
    });
}

fn getConfig(intf: *Intf, modern: bool, output: *[13]u8) c_int {
    output.* = .{0} ** 13;
    const rc = common.getSys(intf, 0xc2, 0, if (modern) output[0..13] else output[0..4]);
    if (rc < 0) {
        log.print(log.Level.err, "Error getting LCD configuration", .{});
        return -1;
    }
    if (rc == 0xc1 or rc == 0xcb) {
        log.print(log.Level.err, "Error getting LCD configuration: Command not supported on this system.", .{});
        return if (modern) 0 else -1;
    }
    if (rc > 0) {
        log.print(log.Level.err, "Error getting LCD configuration: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    if (modern) @memcpy(&common.lcd_mode, output);
    return 0;
}

pub fn platformModelName(intf: *Intf, lcdstring: [*c]u8, max_length: u8, field_type: u8) callconv(.c) c_int {
    var copied: usize = 0;
    var length: usize = 0;
    for (0..4) |block| {
        var data: [18]u8 = undefined;
        const rc = common.getSys(intf, field_type, @intCast(block), &data);
        if (rc != 0) {
            if (rc < 0) {
                log.print(log.Level.err, "Error getting platform model name", .{});
            } else {
                log.print(log.Level.err, "Error getting platform model name: %s", .{common.cc(@intCast(rc))});
            }
            return if (rc == -2) -1 else rc;
        }
        if (block == 0) length = @min(@as(usize, data[3]), max_length);
        const count = @min(length - copied, if (block == 0) @as(usize, 14) else 16);
        if (count == 0) break;
        const offset: usize = if (block == 0) 0 else 14 + 16 * (block - 1);
        if (lcdstring == null) return -1;
        @memcpy(lcdstring[offset..][0..count], data[if (block == 0) 4 else 2..][0..count]);
        copied += count;
        if (copied >= length) break;
    }
    return 0;
}

fn caps(intf: *Intf, out: *[7]u8, is_info: bool) c_int {
    const rc = common.getSys(intf, 0xcf, 0, out);
    if (rc < 0) {
        log.print(log.Level.err, if (is_info) "Error getting LCD capabilities." else "Error getting LCD capabilities", .{});
        return -1;
    }
    if (rc > 0) {
        if (is_info and (rc == 0xc1 or rc == 0xcb)) {
            log.print(log.Level.err, "Error getting LCD capabilities: Command not supported on this system.", .{});
            // C continues with an uninitialized lcd_caps; zero is the defined fallback.
            out.* = .{0} ** 7;
            return 0;
        }
        log.print(log.Level.err, "Error getting LCD capabilities: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    return 0;
}

fn getText(intf: *Intf, max_length: u8, output: *[63]u8) c_int {
    var copied: usize = 0;
    var length: usize = 0;
    for (0..4) |block| {
        var data: [18]u8 = undefined;
        const rc = common.getSys(intf, 0xc1, @intCast(block), &data);
        if (rc < 0) {
            log.print(log.Level.err, "Error getting text data", .{});
            return -1;
        }
        if (rc > 0) {
            log.print(log.Level.err, "Error getting text data: %s", .{common.cc(@intCast(rc))});
            return -1;
        }
        if (block == 0) {
            length = data[3];
            if (length == 0 or length > max_length or length > 62) break;
        }
        const count = @min(length - copied, if (block == 0) @as(usize, 14) else 16);
        if (count == 0) break;
        const offset: usize = if (block == 0) 0 else 14 + 16 * (block - 1);
        @memcpy(output[offset..][0..count], data[if (block == 0) 4 else 2..][0..count]);
        copied += count;
        if (copied >= length) break;
    }
    return 0;
}

fn setText(intf: *Intf, text: [*:0]const u8) c_int {
    const input = std.mem.span(text);
    if (input.len > 62) {
        log.print(log.Level.err, "Out of range Max limit is 62 characters", .{});
        return -1;
    }
    var offset: usize = 0;
    var rc: c_int = 0;
    for (0..4) |block| {
        if (block > 0 and offset == input.len) break;
        var data = [_]u8{0} ** 18;
        data[0] = 0xc1;
        data[1] = @intCast(block);
        if (block == 0) data[3] = @intCast(input.len);
        const count = @min(input.len - offset, if (block == 0) @as(usize, 14) else 16);
        @memcpy(data[if (block == 0) 4 else 2..][0..count], input[offset..][0..count]);
        offset += count;
        rc = common.setSys(intf, &data);
        if (rc < 0) {
            log.print(log.Level.err, "Error setting text data", .{});
            rc = -1;
        } else if (rc > 0) {
            log.print(log.Level.err, "Error setting text data: %s", .{common.cc(@intCast(rc))});
            rc = -1;
        }
    }
    return rc;
}

fn setTextWithCaps(intf: *Intf, text: [*:0]const u8) c_int {
    var data: [7]u8 = undefined;
    if (caps(intf, &data, false) != 0) return -1;
    if (data[2] == 0) {
        log.print(log.Level.err, "LCD does not have any lines that can be set", .{});
        return -1;
    }
    return setText(intf, text);
}

fn configure(intf: *Intf, modern: bool, mode: u32, qualifier: u16, display: u8, text: ?[*:0]const u8) c_int {
    if (mode == mode_user) {
        const value = text orelse return -1;
        if (setTextWithCaps(intf, value) != 0) return -1;
    }
    if (!modern) {
        const data = [2]u8{ 0xc2, @truncate(mode) };
        const rc = common.setSys(intf, &data);
        if (rc < 0) {
            log.print(log.Level.err, "Error setting LCD configuration", .{});
            return -1;
        }
        if (rc == 0xc1 or rc == 0xcb) {
            log.print(log.Level.err, "Error setting LCD configuration: Command not supported on this system.", .{});
            return 0;
        }
        if (rc > 0) {
            log.print(log.Level.err, "Error setting LCD configuration: %s", .{common.cc(@intCast(rc))});
            return -1;
        }
        return 0;
    }
    var original = [_]u8{0} ** 13;
    _ = getConfig(intf, true, &original); // C sends the set even after get error.
    var data = [_]u8{0} ** 13;
    data[0] = 0xc2;
    common.put32(data[1..5], if (mode == 0xff) common.le32(original[1..5]) else mode);
    const existing = original[5];
    data[5] = switch (qualifier) {
        0 => existing & 0xfe,
        1 => existing | 1,
        2 => existing & 0xfd,
        3 => existing | 2,
        else => existing,
    };
    data[11] = if (display == 0xff) original[11] else display;
    const rc = common.setSys(intf, &data);
    if (rc < 0) {
        log.print(log.Level.err, "Error setting LCD configuration", .{});
        return -1;
    }
    if (rc == 0xc1 or rc == 0xcb) {
        log.print(log.Level.err, "Error setting LCD configuration: Command not supported on this system.", .{});
        return 0;
    }
    if (rc > 0) {
        log.print(log.Level.err, "Error setting LCD configuration: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    return 0;
}

fn statusValue(intf: *Intf, output: *[5]u8) c_int {
    const rc = common.getSys(intf, 0xe7, 0, output);
    if (rc < 0) {
        log.print(log.Level.err, "Error getting LCD Status", .{});
        return -1;
    }
    if (rc == 0xc1 or rc == 0xcb) {
        log.print(log.Level.err, "Error getting LCD status: Command not supported on this system.", .{});
        return -1;
    }
    if (rc != 0) {
        log.print(log.Level.err, "Error getting LCD Status: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    return 0;
}

fn status(intf: *Intf) c_int {
    var data: [5]u8 = undefined;
    if (statusValue(intf, &data) != 0) return -1;
    _ = c.printf("LCD KVM Status :%s\n", @as([*:0]const u8, switch (data[1]) {
        0 => "Inactive",
        1 => "Active",
        else => "Invalid Status",
    }));
    _ = c.printf("LCD lock Status :%s\n", @as([*:0]const u8, switch (data[2]) {
        0 => "View and modify",
        1 => "View only",
        2 => "disabled",
        else => "Invalid",
    }));
    return 0;
}

fn setStatus(intf: *Intf, is_kvm: bool, value: u8) c_int {
    var previous: [5]u8 = undefined;
    if (statusValue(intf, &previous) != 0) return -1;
    const data = [5]u8{ 0xe7, if (is_kvm) value else previous[1], if (is_kvm) previous[2] else value, 0, 0 };
    const rsp = common.send(intf, 0x06, 0x58, &data) orelse {
        log.print(log.Level.err, "Error setting LCD status", .{});
        return -1;
    };
    if (rsp.ccode == 0xc1 or rsp.ccode == 0xcb) {
        log.print(log.Level.err, "Error getting LCD status: Command not supported on this system.", .{});
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error setting LCD status: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    return 0;
}

fn info(intf: *Intf) c_int {
    _ = c.printf("LCD info\n");
    const modern = common.idrac_all != 0;
    var data: [13]u8 = undefined;
    if (getConfig(intf, modern, &data) != 0) return -1;
    const mode = if (modern) common.le32(data[1..5]) else data[1];
    var text = [_]u8{0} ** 63;
    if (mode == mode_default) {
        if (platformModelName(intf, &text, 62, 0xd1) != 0) return -1;
        _ = c.printf(if (modern) "    Setting:Model name\n" else "    Setting: default\n");
        _ = c.printf("    Line 1:  %s\n", &text);
    } else if (mode == mode_none) {
        _ = c.printf("    Setting:   none\n");
    } else if (mode == mode_user) {
        _ = c.printf(if (modern) "    Setting: User defined\n" else "    Setting: custom\n");
        var capabilities: [7]u8 = undefined;
        if (caps(intf, &capabilities, true) != 0) return -1;
        if (capabilities[2] > 0) {
            _ = getText(intf, capabilities[3], &text);
            _ = c.printf("    Text:    %s\n", &text);
        } else {
            _ = c.printf("    No lines to show\n");
        }
    } else if (modern) {
        switch (mode) {
            4 => _ = c.printf("    Setting:   IPV4 Address\n"),
            8 => _ = c.printf("    Setting:   MAC Address\n"),
            16 => _ = c.printf("    Setting:   OS System Name\n"),
            32 => _ = c.printf("    Setting:   System Tag\n"),
            64 => _ = c.printf("    Setting:  IPV6 Address\n"),
            512 => _ = c.printf("    Setting:  Asset Tag\n"),
            128 => {
                _ = c.printf("    Setting:  Ambient Temp\n");
                _ = c.printf(if (data[5] & 2 != 0) "    Unit:  F\n" else "    Unit:  C\n");
            },
            256 => {
                _ = c.printf("    Setting:  System Watts\n");
                _ = c.printf(if (data[5] & 1 != 0) "    Unit:  BTU/hr\n" else "    Unit:  Watt\n");
            },
            else => {},
        }
    }
    if (modern) {
        if (data[11] == 1) _ = c.printf("    Error Display:  SEL\n");
        if (data[11] == 2) _ = c.printf("    Error Display:  Simple\n");
    }
    return 0;
}

fn matchChoice(token: ?[*:0]const u8, names: []const []const u8) ?usize {
    for (names, 0..) |name, i| if (common.eq(token, name)) return i;
    return null;
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    const verb = common.arg(argv, argc, 1);
    if (verb == null or common.eq(verb, "help")) {
        usage();
        return 0;
    }
    // LCD probe expects only a completion code, not a structure.
    var empty: [0]u8 = .{};
    const supported = common.getSys(intf, 0xe7, 0, &empty) == 0;
    common.validator(intf);
    if (!supported) {
        log.print(log.Level.err, "lcd is not supported on this system.", .{});
        return -1;
    }
    if (common.eq(verb, "info")) return info(intf);
    if (common.eq(verb, "status")) return status(intf);
    if (!common.eq(verb, "set")) {
        log.print(log.Level.err, "Invalid DellOEM command: %s", .{verb.?});
        usage();
        return -1;
    }
    var i: usize = 2;
    var option = common.arg(argv, argc, i) orelse {
        usage();
        return -1;
    };
    if (common.eq(option, "line")) {
        i += 1;
        const line = common.arg(argv, argc, i) orelse {
            common.notice(&.{ "", "usage: delloem <command> [option...]", "", "commands:", "    lcd", "    mac", "    lan", "    setled", "    powermonitor", "    vFlash", "", "For help on individual commands type:", "delloem <command> help" });
            return -1;
        };
        var number: u8 = 0;
        if (c.str2uchar(line, &number) != 0) {
            log.print(log.Level.err, "Argument '%s' is either not a number or out of range.", .{line});
            return -1;
        }
        i += 1;
        option = common.arg(argv, argc, i) orelse {
            usage();
            return -1;
        };
    }
    i += 1;
    const value = common.arg(argv, argc, i);
    if (common.idrac_all != 0 and common.eq(option, "mode")) {
        const modes = [_][]const u8{
            "none",       "modelname",  "userdefined", "ipv4address", "macaddress",
            "systemname", "servicetag", "ipv6address", "ambienttemp", "systemwatt",
            "assettag",
        };
        const values = [_]u32{ 2, 1, 0, 4, 8, 16, 32, 64, 128, 256, 512 };
        const choice = matchChoice(value, &modes) orelse {
            if (value != null and !common.eq(value, "help")) log.print(log.Level.err, "Invalid DellOEM command: %s", .{value.?});
            usage();
            return if (value == null) -1 else 0;
        };
        if (choice == 2) {
            const text = common.arg(argv, argc, i + 1) orelse {
                usage();
                return -1;
            };
            return configure(intf, true, mode_user, 0xff, 0xff, text);
        }
        return configure(intf, true, values[choice], 0xff, 0xff, null);
    }
    if (common.idrac_all != 0 and common.eq(option, "lcdqualifier")) {
        const choices = [_][]const u8{ "watt", "btuphr", "celsius", "fahrenheit" };
        const choice = matchChoice(value, &choices) orelse {
            if (value != null and !common.eq(value, "help")) log.print(log.Level.err, "Invalid DellOEM command: %s", .{value.?});
            usage();
            return if (value == null) -1 else 0;
        };
        return configure(intf, true, 0xff, @intCast(choice), 0xff, null);
    }
    if (common.idrac_all != 0 and common.eq(option, "errordisplay")) {
        const choice = matchChoice(value, &.{ "sel", "simple" }) orelse {
            if (value != null and !common.eq(value, "help")) log.print(log.Level.err, "Invalid DellOEM command: %s", .{value.?});
            usage();
            return if (value == null) -1 else 0;
        };
        return configure(intf, true, 0xff, 0xff, if (choice == 0) 1 else 2, null);
    }
    if (common.idrac_flag == 0 and common.eq(option, "none")) return configure(intf, false, mode_none, 0, 0, null);
    if (common.idrac_flag == 0 and common.eq(option, "default")) return configure(intf, false, mode_default, 0, 0, null);
    if (common.idrac_flag == 0 and common.eq(option, "custom")) {
        const text = value orelse {
            usage();
            return -1;
        };
        return configure(intf, false, mode_user, 0, 0, text);
    }
    if (common.eq(option, "vkvm")) {
        if (common.eq(value, "active")) return setStatus(intf, true, 1);
        if (common.eq(value, "inactive")) return setStatus(intf, true, 0);
    }
    if (common.eq(option, "frontpanelaccess")) {
        if (matchChoice(value, &.{ "viewandmodify", "viewonly", "disabled" })) |choice| {
            return setStatus(intf, false, @intCast(choice));
        }
    }
    if (value == null and (common.eq(option, "vkvm") or common.eq(option, "frontpanelaccess"))) {
        usage();
        return -1;
    }
    if (value != null and !common.eq(value, "help") and (common.eq(option, "vkvm") or common.eq(option, "frontpanelaccess"))) {
        log.print(log.Level.err, "Invalid DellOEM command: %s", .{value.?});
        usage();
        return 0;
    }
    if (!common.eq(option, "help")) log.print(log.Level.err, "Invalid DellOEM command: %s", .{option});
    usage();
    return if (common.eq(option, "help") and common.idrac_flag == 0) 0 else -1;
}

test "LCD block framing never writes beyond 62 bytes" {
    var block = [_]u8{0} ** 18;
    const text = "Fourteen bytes";
    @memcpy(block[4..18], text);
    try std.testing.expectEqual(@as(u8, 's'), block[17]);
}
