//! DCMI 1.5 command driver. Selected with `-Dzig-modules=dcmi`.
//! Responses belong to the interface and are consumed before another sendrecv.
//! Unlike the C implementation, no reply byte is read beyond `data_len`.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const err_level: c_int = 3;
const notice_level: c_int = 5;
const group: u8 = 0xdc;

const Item = struct {
    val: u16,
    name: [*:0]const u8,
    desc: [*:0]const u8 = "",
};
const commands = [_]Item{
    .{ .val = 0, .name = "discover", .desc = "Used to discover supported DCMI capabilities" },
    .{ .val = 1, .name = "power", .desc = "Platform power limit command options" },
    .{ .val = 2, .name = "sensors", .desc = "Prints the available DCMI sensors" },
    .{ .val = 3, .name = "asset_tag", .desc = "Prints the platform's asset tag" },
    .{ .val = 4, .name = "set_asset_tag", .desc = "Sets the platform's asset tag" },
    .{ .val = 5, .name = "get_mc_id_string", .desc = "Get management controller ID string" },
    .{ .val = 6, .name = "set_mc_id_string", .desc = "Set management controller ID string" },
    .{ .val = 7, .name = "thermalpolicy", .desc = "Thermal policy get/set" },
    .{ .val = 8, .name = "get_temp_reading", .desc = "Get Temperature Readings" },
    .{ .val = 9, .name = "get_conf_param", .desc = "Get DCMI Config Parameters" },
    .{ .val = 10, .name = "set_conf_param", .desc = "Set DCMI Config Parameters" },
    .{ .val = 11, .name = "oob_discover", .desc = "Ping/Pong Message for DCMI Discovery" },
};
const capabilities = [_]Item{
    .{ .val = 1, .name = "platform", .desc = "Lists the system capabilities" },
    .{ .val = 2, .name = "mandatory_attributes", .desc = "Lists SEL, identification andtemperature attributes" },
    .{ .val = 3, .name = "optional_attributes", .desc = "Lists power capabilities" },
    .{ .val = 4, .name = "managebility access", .desc = "Lists OOB channel information" },
};
const mandatory = [_]Item{
    .{ .val = 1, .name = "Identification support available" },
    .{ .val = 2, .name = "SEL logging available" },
    .{ .val = 3, .name = "Chassis power available" },
    .{ .val = 4, .name = "Temperature monitor available" },
};
const optional = [_]Item{.{ .val = 1, .name = "Power management available" }};
const access = [_]Item{
    .{ .val = 1, .name = "In-band KCS channel available" },
    .{ .val = 2, .name = "Out-of-band serial TMODE available" },
    .{ .val = 3, .name = "Out-of-band secondary LAN channel available" },
    .{ .val = 4, .name = "Out-of-band primary LAN channel available" },
    .{ .val = 5, .name = "SOL enabled" },
    .{ .val = 6, .name = "VLAN capable" },
};
const identification = [_]Item{
    .{ .val = 1, .name = "GUID" },
    .{ .val = 2, .name = "DHCP hostname" },
    .{ .val = 3, .name = "Asset tag" },
};
const temp_names = [_]Item{
    .{ .val = 0x40, .name = "Inlet", .desc = "Inlet air temperature(40h)" },
    .{ .val = 0x41, .name = "CPU", .desc = "CPU temperature sensors(41h)" },
    .{ .val = 0x42, .name = "Baseboard", .desc = "Baseboard temperature sensors(42h)" },
};
const temp_caps = [_]Item{
    .{ .val = 1, .name = "inlet" },
    .{ .val = 2, .name = "cpu" },
    .{ .val = 3, .name = "baseboard" },
};
const power_cmds = [_]Item{
    .{ .val = 0, .name = "reading", .desc = "Get power related readings from the system" },
    .{ .val = 1, .name = "get_limit", .desc = "Get the configured power limits" },
    .{ .val = 2, .name = "set_limit", .desc = "Set a power limit option" },
    .{ .val = 3, .name = "activate", .desc = "Activate the set power limit" },
    .{ .val = 4, .name = "deactivate", .desc = "Deactivate the set power limit" },
};
const set_limit_opts = [_]Item{
    .{ .val = 0, .name = "action", .desc = "<no_action | sel_logging | power_off>" },
    .{ .val = 1, .name = "limit", .desc = "<number in Watts>" },
    .{ .val = 2, .name = "correction", .desc = "<number in milliseconds>" },
    .{ .val = 3, .name = "sample", .desc = "<number in seconds>" },
};
const samples = [_]Item{
    .{ .val = 0x05, .name = "5_sec" },  .{ .val = 0x0f, .name = "15_sec" },
    .{ .val = 0x1e, .name = "30_sec" }, .{ .val = 0x41, .name = "1_min" },
    .{ .val = 0x43, .name = "3_min" },  .{ .val = 0x47, .name = "7_min" },
    .{ .val = 0x4f, .name = "15_min" }, .{ .val = 0x5e, .name = "30_min" },
    .{ .val = 0x81, .name = "1_hour" },
};
const thermal_cmds = [_]Item{
    .{ .val = 0, .name = "get", .desc = "Get thermal policy" },
    .{ .val = 1, .name = "set", .desc = "Set thermal policy" },
};
const thermal_opts = [_]Item{
    .{ .val = 0, .name = "volatile", .desc = "Current Power Cycle" },
    .{ .val = 1, .name = "nonvolatile", .desc = "Set across power cycles" },
    .{ .val = 1, .name = "poweroff", .desc = "Hard Power Off system" },
    .{ .val = 0, .name = "nopoweroff", .desc = "No 'Hard Power Off' action" },
    .{ .val = 1, .name = "sel", .desc = "Log event to SEL" },
    .{ .val = 0, .name = "nosel", .desc = "No 'Log event to SEL' action" },
    .{ .val = 0, .name = "disabled", .desc = "Disabled" },
};
const config_opts = [_]Item{
    .{ .val = 1, .name = "activate_dhcp", .desc = "\tActivate DHCP" },
    .{ .val = 2, .name = "dhcp_config", .desc = "\tDHCP Configuration" },
    .{ .val = 3, .name = "init", .desc = "\t\tInitial timeout interval" },
    .{ .val = 4, .name = "timeout", .desc = "\t\tServer contact timeout interval" },
    .{ .val = 5, .name = "retry", .desc = "\t\tServer contact retry interval" },
};
const action_names = [_]Item{
    .{ .val = 0, .name = "No Action" },
    .{ .val = 1, .name = "Hard Power Off & Log Event to SEL" },
    .{ .val = 2, .name = "OEM reserved (02h)" },
    .{ .val = 3, .name = "OEM reserved (03h)" },
    .{ .val = 4, .name = "OEM reserved (04h)" },
    .{ .val = 5, .name = "OEM reserved (05h)" },
    .{ .val = 6, .name = "OEM reserved (06h)" },
    .{ .val = 7, .name = "OEM reserved (07h)" },
    .{ .val = 8, .name = "OEM reserved (08h)" },
    .{ .val = 9, .name = "OEM reserved (09h)" },
    .{ .val = 10, .name = "OEM reserved (0ah)" },
    .{ .val = 11, .name = "OEM reserved (0bh)" },
    .{ .val = 12, .name = "OEM reserved (0ch)" },
    .{ .val = 13, .name = "OEM reserved (0dh)" },
    .{ .val = 14, .name = "OEM reserved (0eh)" },
    .{ .val = 15, .name = "OEM reserved (0fh)" },
    .{ .val = 16, .name = "OEM reserved (10h)" },
    .{ .val = 17, .name = "Log Event to SEL" },
};

fn name(table: []const Item, val: u16) [*:0]const u8 {
    for (table) |item| if (item.val == val) return item.name;
    // All callers use this immediately, before the next unknown lookup.
    _ = c.snprintf(&unknown, unknown.len, "Unknown (0x%x)", @as(c_uint, val));
    return @ptrCast(&unknown);
}
var unknown: [32]u8 = @splat(0);

fn find(table: []const Item, text: ?[*:0]const u8) u16 {
    const arg = text orelse return 0xff;
    for (table) |item| if (c.strcasecmp(arg, item.name) == 0) return item.val;
    return 0xff;
}
fn argAt(args: []const ?[*:0]u8, i: usize) ?[*:0]u8 {
    return if (i < args.len) args[i] else null;
}
fn is(arg: ?[*:0]u8, text: [*:0]const u8) bool {
    return arg != null and c.strcmp(arg.?, text) == 0;
}
fn choose(b: bool, yes: [*:0]const u8, no: [*:0]const u8) [*:0]const u8 {
    return if (b) yes else no;
}
fn usage(table: []const Item, title: [*:0]const u8) void {
    c.lprintf(err_level, "\n%s", title);
    for (table) |entry| c.lprintf(err_level, "    %s    %s", entry.name, entry.desc);
    c.lprintf(err_level, "");
}
fn bits(table: []const Item, mask: u8) void {
    for (table, 0..) |entry, idx| {
        if (mask & (@as(u8, 1) << @intCast(idx)) != 0)
            _ = c.printf("        %s\n", entry.name);
    }
}
fn req(intf: *Intf, cmd: u8, data: []u8) ?*Response {
    var request = std.mem.zeroes(Request);
    request.msg.netfn_lun.netfn = ipmi.NetFn.dcgrp;
    request.msg.cmd = cmd;
    request.msg.data = data.ptr;
    request.msg.data_len = @intCast(data.len);
    const send = intf.sendrecv orelse return null;
    return send(intf, &request);
}
fn length(rsp: *Response) usize {
    if (rsp.data_len < 0) return 0;
    return @min(@as(usize, @intCast(rsp.data_len)), rsp.data.len);
}
fn valid(rsp: ?*Response, size: usize) bool {
    const r = rsp orelse {
        c.lprintf(err_level, "\n    Unable to get DCMI information");
        return false;
    };
    if (r.ccode != 0) {
        const cc: [*c]const c.struct_valstr = if (r.ccode >= 0x80 and r.ccode <= 0x8f)
            @ptrCast(&dcmi_ccode_vals)
        else
            c.completion_code_vals;
        c.lprintf(err_level, "\n    DCMI request failed because: %s (%x)", c.val2str(r.ccode, cc), @as(c_uint, r.ccode));
        return false;
    }
    if (length(r) < 1) {
        c.lprintf(err_level, "\n    Unable to get DCMI information");
        return false;
    }
    if (r.data[0] != group) {
        _ = c.printf("\n    A valid DCMI command was not returned! (%x)", @as(c_uint, r.data[0]));
        return false;
    }
    if (length(r) < size) {
        c.lprintf(err_level, "DCMI response is too short");
        return false;
    }
    return true;
}
const dcmi_ccode_vals = [_]c.struct_valstr{
    .{ .val = 0x80, .str = "Parameter not supported" },
    .{ .val = 0x81, .str = "Something else has already claimed these parameters" },
    .{ .val = 0x82, .str = "Not supported or failed to write a read-only parameter" },
    .{ .val = 0x83, .str = "Access mode is not supported" },
    .{ .val = 0x84, .str = "Power/Thermal limit out of range" },
    .{ .val = 0x85, .str = "Correction/Exception time out of range" },
    .{ .val = 0x89, .str = "Sample/Statistics Reporting period out of range" },
    .{ .val = 0x8a, .str = "Power limit already active" },
    .{ .val = 0xff, .str = null },
};
fn word(d: []const u8, i: usize) u16 {
    return std.mem.readInt(u16, d[i..][0..2], .little);
}
fn dword(d: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, d[i..][0..4], .little);
}
fn putWord(d: []u8, i: usize, n: u16) void {
    std.mem.writeInt(u16, d[i..][0..2], n, .little);
}
fn putDword(d: []u8, i: usize, n: u32) void {
    std.mem.writeInt(u32, d[i..][0..4], n, .little);
}
fn parse(comptime T: type, value: ?[*:0]u8) ?T {
    const text = value orelse return null;
    var result: T = 0;
    const rc = switch (T) {
        u8 => c.str2uchar(text, &result),
        u16 => c.str2ushort(text, &result),
        u32 => c.str2uint(text, &result),
        else => @compileError("unsupported numeric type"),
    };
    return if (rc == 0) result else null;
}

fn discover(intf: *Intf) c_int {
    for (1..5) |selector| {
        var msg = [2]u8{ group, @intCast(selector) };
        const rsp = req(intf, 1, &msg);
        if (!valid(rsp, 1)) {
            c.lprintf(err_level, "Error discovering %s capabilities!\n", name(&capabilities, @intCast(selector)));
            return -1;
        }
        if (length(rsp.?) < 8) {
            c.lprintf(err_level, "ERROR!  This command is not compatible with this version");
            c.lprintf(err_level, "Error discovering %s capabilities!\n", name(&capabilities, @intCast(selector)));
            return -1;
        }
        const d = &rsp.?.data;
        const conform = word(d, 1);
        if (conform != 1 and conform != 0x101 and conform != 0x501) {
            c.lprintf(err_level, "ERROR!  This command is not available on this platform");
            c.lprintf(err_level, "Error discovering %s capabilities!\n", name(&capabilities, @intCast(selector)));
            return -1;
        }
        if (d[3] != 1 and d[3] != 2) {
            c.lprintf(err_level, "ERROR!  This command is not compatible with this version");
            c.lprintf(err_level, "Error discovering %s capabilities!\n", name(&capabilities, @intCast(selector)));
            return -1;
        }
        switch (selector) {
            1 => {
                _ = c.printf("    Supported DCMI capabilities:\n\n         Mandatory platform capabilities\n");
                bits(&mandatory, d[4]);
                _ = c.printf("\n         Optional platform capabilities\n");
                bits(&optional, d[5]);
                _ = c.printf("\n         Managebility access capabilities\n");
                bits(&access, d[6]);
            },
            2 => {
                _ = c.printf("\n    Mandatory platform attributes:\n\n         SEL Attributes: \n               SEL automatic rollover is %s", choose(d[5] & 0x80 != 0, "enabled", "not present"));
                _ = c.printf("\n               %d SEL entries\n", @as(c_int, word(d, 4) & 0xfff));
                _ = c.printf("\n         Identification Attributes: \n");
                bits(&identification, d[6]);
                _ = c.printf("\n         Temperature Monitoring Attributes: \n");
                bits(&temp_caps, d[7]);
            },
            3 => {
                _ = c.printf("\n    Optional Platform Attributes: \n\n         Power Management:\n");
                if (d[4] == 0x40)
                    _ = c.printf("                Slave address of device: 20h (BMC)\n")
                else
                    _ = c.printf("                Slave address of device: %xh (8bits)(Satellite/External controller)\n", @as(c_uint, d[4]));
                if (d[5] >> 4 == 0)
                    _ = c.printf("                Channel number is 0h (Primary BMC)\n")
                else
                    _ = c.printf("                Channel number is %xh \n", @as(c_uint, d[5] >> 4));
                _ = c.printf("                    Device revision is %d \n", @as(c_int, d[5] & 0xf));
            },
            4 => {
                _ = c.printf("\n    Manageability Access Attributes: \n");
                if (d[4] == 0xff)
                    _ = c.printf("         Primary LAN channel is not available for OOB\n")
                else
                    _ = c.printf("         Primary LAN channel number: %d is available\n", @as(c_int, d[4]));
                if (d[5] == 0xff)
                    _ = c.printf("         Secondary LAN channel is not available for OOB\n")
                else
                    _ = c.printf("         Secondary LAN channel number: %d is available\n", @as(c_int, d[5]));
                if (d[6] == 0xff)
                    _ = c.printf("         No serial channel is available\n")
                else
                    _ = c.printf("         Serial channel number: %d is available\n", @as(c_int, d[6]));
            },
            else => unreachable,
        }
    }
    return 0;
}

fn getString(intf: *Intf, mc: bool) c_int {
    const cmd: u8 = if (mc) 9 else 6;
    var initial = [3]u8{ group, 0, @intFromBool(mc) };
    const first = req(intf, cmd, &initial);
    if (!valid(first, 2)) return -1;
    var remaining: usize = first.?.data[1];
    var offset: usize = 0;
    _ = c.printf(if (mc) "\n Get Management Controller Identifier String: " else "\n Asset tag: ");
    while (remaining > 0) {
        const count = @min(remaining, 16);
        var msg = [3]u8{ group, @intCast(offset), @intCast(count) };
        const rsp = req(intf, cmd, &msg);
        if (rsp) |r| {
            if (!mc and r.ccode >= 0x80 and r.ccode <= 0x83) r.ccode = 0;
        }
        if (!valid(rsp, count + 2)) return -1;
        for (rsp.?.data[2 .. count + 2]) |byte| _ = c.printf("%c", @as(c_int, byte));
        remaining -= count;
        offset += count;
    }
    _ = c.printf("\n");
    return 0;
}
fn setString(intf: *Intf, mc: bool, arg: [*:0]u8) c_int {
    const text = std.mem.span(arg);
    const size = text.len + @intFromBool(mc);
    if (size > 64) {
        c.lprintf(err_level, "\nValue is too long.");
        return -1;
    }
    _ = c.printf(if (mc) "\n Set Management Controller Identifier String Command: " else "\n Set Asset Tag: ");
    var offset: usize = 0;
    while (offset < size) {
        const count = @min(size - offset, 16);
        var msg: [19]u8 = @splat(0);
        msg[0] = group;
        msg[1] = @intCast(offset);
        msg[2] = @intCast(count);
        for (0..count) |i| {
            msg[3 + i] = if (offset + i == text.len) 0 else text[offset + i];
        }
        const rsp = req(intf, if (mc) 10 else 8, msg[0 .. count + 3]);
        if (!(mc and std.mem.eql(u8, std.mem.sliceTo(&intf.name, 0), "lanplus")) and !valid(rsp, 1)) return -1;
        for (msg[3 .. count + 3]) |byte| _ = c.printf("%c", @as(c_int, byte));
        offset += count;
    }
    _ = c.printf("\n");
    return 0;
}

fn powerReading(intf: *Intf, sample: u8) c_int {
    var msg = [4]u8{ group, if (sample == 0) 1 else 2, sample, 0 };
    const rsp = req(intf, 2, &msg);
    if (!valid(rsp, 18)) return -1;
    const d = &rsp.?.data;
    _ = c.printf("\n");
    _ = c.printf("    Instantaneous power reading:              %8d Watts\n", @as(c_int, word(d, 1)));
    _ = c.printf("    Minimum during sampling period:           %8d Watts\n", @as(c_int, word(d, 3)));
    _ = c.printf("    Maximum during sampling period:           %8d Watts\n", @as(c_int, word(d, 5)));
    _ = c.printf("    Average power reading over sample period: %8d Watts\n", @as(c_int, word(d, 7)));
    _ = c.printf("    IPMI timestamp:                           %s", c.ipmi_timestamp_numeric(dword(d, 9)));
    _ = c.printf("    Sampling period:                          ");
    if (sample != 0)
        _ = c.printf("%s \n", name(&samples, @truncate(dword(d, 13))))
    else
        _ = c.printf("%08u Seconds.\n", @as(c_uint, dword(d, 13) / 1000));
    _ = c.printf("    Power reading state is:                   %s\n\n", choose(d[17] & 0x40 != 0, "activated", "deactivated"));
    return 0;
}
fn getLimit(intf: *Intf, render: bool) ?[14]u8 {
    var msg = [3]u8{ group, 0, 0 };
    const rsp = req(intf, 3, &msg);
    const active = if (rsp) |r| r.ccode == 0 else false;
    if (rsp) |r| if (r.ccode == 0x80) {
        r.ccode = 0;
    };
    if (!valid(rsp, 14)) return null;
    const data: [14]u8 = rsp.?.data[0..14].*;
    if (render) {
        _ = c.printf("\n    Current Limit State: %s\n", choose(active, "Power Limit Active", "No Active Power Limit"));
        _ = c.printf("    Exception actions:   %s\n", name(&action_names, data[3]));
        _ = c.printf("    Power Limit:         %i Watts\n", @as(c_int, word(&data, 4)));
        _ = c.printf("    Correction time:     %i milliseconds\n", @as(c_int, @bitCast(dword(&data, 6))));
        _ = c.printf("    Sampling period:     %i seconds\n\n", @as(c_int, word(&data, 12)));
    }
    return data;
}
fn setLimitWire(intf: *Intf, data: [15]u8) c_int {
    var msg = data;
    if (!valid(req(intf, 4, &msg), 1)) return -1;
    return 0;
}
fn powerSet(intf: *Intf, args: []const ?[*:0]u8) c_int {
    if (args.len < 3) {
        usage(&set_limit_opts, "set_limit <parameter> <value>");
        return -1;
    }
    if (args.len == 9) {
        var msg: [15]u8 = @splat(0);
        msg[0] = group;
        const action = find(&.{ .{ .val = 0, .name = "no_action" }, .{ .val = 1, .name = "power_off" }, .{ .val = 17, .name = "sel_logging" } }, argAt(args, 2));
        if (action == 0xff) {
            c.lprintf(err_level, "Given Action '%s' is invalid.", argAt(args, 2));
            return -1;
        }
        msg[4] = @intCast(action);
        const limit = parse(u16, argAt(args, 4)) orelse {
            c.lprintf(err_level, "Given Limit '%s' is invalid.", argAt(args, 4));
            return -1;
        };
        const correction = parse(u32, argAt(args, 6)) orelse {
            c.lprintf(err_level, "Given Correction '%s' is invalid.", argAt(args, 6));
            return -1;
        };
        const sample = parse(u16, argAt(args, 8)) orelse {
            c.lprintf(err_level, "Given Sample '%s' is invalid.", argAt(args, 8));
            return -1;
        };
        putWord(&msg, 5, limit);
        putDword(&msg, 7, correction);
        putWord(&msg, 13, sample);
        if (setLimitWire(intf, msg) < 0) return -1;
    } else {
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 2) {
            const option = argAt(args, i);
            const value = argAt(args, i + 1);
            const old = getLimit(intf, false) orelse return -1;
            var msg: [15]u8 = @splat(0);
            msg[0] = old[0];
            msg[4] = old[3];
            @memcpy(msg[5..11], old[4..10]);
            @memcpy(msg[13..15], old[12..14]);
            switch (find(&set_limit_opts, option)) {
                0 => {
                    const action: u16 = blk: {
                        if (is(value, "no_action")) break :blk 0;
                        if (is(value, "power_off")) break :blk 1;
                        if (is(value, "sel_logging")) break :blk 17;
                        inline for (2..17) |n| {
                            const label = std.fmt.comptimePrint("oem_{x:0>2}", .{n});
                            if (is(value, label)) break :blk n;
                        }
                        break :blk 0xff;
                    };
                    if (action == 0xff) {
                        c.lprintf(err_level, "Given %s '%s' is invalid.", option, value);
                        return -1;
                    }
                    msg[4] = @intCast(action);
                },
                1, 2, 3 => |opt| {
                    const n = parse(u32, value) orelse {
                        c.lprintf(err_level, "Given %s '%s' is invalid.", option, value);
                        return -1;
                    };
                    if (opt == 2) putDword(&msg, 7, n) else putWord(&msg, if (opt == 1) 5 else 13, @truncate(n));
                },
                else => return -1,
            }
            if (setLimitWire(intf, msg) < 0) return -1;
        }
    }
    return if (getLimit(intf, true) == null) -1 else 0;
}
fn power(intf: *Intf, args: []const ?[*:0]u8) c_int {
    switch (find(&power_cmds, argAt(args, 0))) {
        0 => {
            var sample: u8 = 0;
            if (argAt(args, 1)) |v| {
                const result = find(&samples, v);
                if (result == 0xff) {
                    // print_strs(..., verthorz=1) does not log the names;
                    // its horizontal list is written to stdout.
                    c.lprintf(err_level, "\nInvalid sample time. Valid times are: ");
                    for (samples, 0..) |entry, i| {
                        _ = c.printf("%s", entry.name);
                        if (i + 1 < samples.len) _ = c.printf(" | ");
                    }
                    _ = c.printf("\n");
                    return -1;
                }
                sample = @intCast(result);
            }
            return powerReading(intf, sample);
        },
        1 => return if (getLimit(intf, true) == null) -1 else 0,
        2 => return powerSet(intf, args),
        3, 4 => |opt| {
            var msg = [4]u8{ group, if (opt == 3) 1 else 0, 0, 0 };
            if (!valid(req(intf, 5, &msg), 1)) return -1;
            _ = c.printf("\n    Power limit successfully %s\n", choose(opt == 3, "activated", "deactivated"));
            return 0;
        },
        else => {
            usage(&power_cmds, "power <command>");
            return 0;
        },
    }
}

fn sensorRecord(intf: *Intf, id: u16) c_int {
    const itr = c.ipmi_sdr_start(@ptrCast(intf), 0);
    if (itr == null) {
        c.lprintf(err_level, "Unable to open SDR for reading");
        return -1;
    }
    defer c.ipmi_sdr_end(itr);
    while (c.ipmi_sdr_get_next_header(@ptrCast(intf), itr)) |header| {
        const b: [*]const u8 = @ptrCast(header);
        if (word(b[0..7], 2) != id) continue;
        const rec = c.ipmi_sdr_get_record(@ptrCast(intf), header, itr);
        if (rec == null) return -1;
        defer c.free(rec);
        if (b[5] == c.SDR_RECORD_TYPE_FULL_SENSOR or b[5] == c.SDR_RECORD_TYPE_COMPACT_SENSOR)
            return c.ipmi_sdr_print_rawentry(@ptrCast(intf), b[5], rec, b[6]);
        return -1;
    }
    return -1;
}
fn sensors(intf: *Intf) c_int {
    var rc: c_int = 0;
    for (temp_names) |item| {
        rc = 0;
        var msg = [5]u8{ group, 1, @intCast(item.val), 0, 0 };
        const first = req(intf, 7, &msg);
        if (!valid(first, 2)) {
            rc = -1;
            continue;
        }
        var remaining: usize = first.?.data[1];
        _ = c.printf("\n%s: %d temperature sensor%s found:\n", item.name, @as(c_int, @intCast(remaining)), choose(remaining > 1, "s", ""));
        var offset: usize = 0;
        while (remaining > 0) {
            msg[4] = @intCast(offset);
            const rsp = req(intf, 7, &msg);
            if (!valid(rsp, 3)) {
                rc = -1;
                break;
            }
            const count: usize = rsp.?.data[2];
            if (count == 0 or count > 8 or count > remaining or length(rsp.?) < 3 + count * 2) {
                c.lprintf(err_level, "DCMI sensor response has an invalid record count");
                rc = -1;
                break;
            }
            var ids: [8]u16 = undefined;
            for (0..count) |i| ids[i] = word(&rsp.?.data, 3 + i * 2);
            for (ids[0..count]) |id| {
                _ = c.printf("Record ID 0x%04x: ", @as(c_uint, id));
                _ = sensorRecord(intf, id);
            }
            remaining -= count;
            offset += 8;
        }
    }
    return rc;
}
fn temps(intf: *Intf) c_int {
    _ = c.printf("\n\tEntity ID\t\t\tEntity Instance\t   Temp. Readings");
    for (temp_names) |item| {
        var msg = [5]u8{ group, 1, @intCast(item.val), 0, 0 };
        const first = req(intf, 0x10, &msg);
        if (!valid(first, 2)) continue;
        var remaining: usize = first.?.data[1];
        var offset: usize = 1;
        while (remaining > 0) {
            const count = @min(remaining, 8);
            msg[4] = @intCast(offset);
            const rsp = req(intf, 0x10, &msg);
            if (!valid(rsp, 3)) return -1;
            const returned: usize = rsp.?.data[2];
            if (returned == 0 or returned > count or length(rsp.?) < 3 + 2 * returned) {
                c.lprintf(err_level, "DCMI temperature response has an invalid reading count");
                return -1;
            }
            for (0..returned) |i| {
                const temperature = rsp.?.data[3 + i * 2];
                const instance = rsp.?.data[4 + i * 2];
                _ = c.printf("\n%s\t\t%i\t\t%c%i C", item.desc, @as(c_int, instance), @as(c_int, if (temperature & 0x80 != 0) @as(u8, '-') else '+'), @as(c_int, temperature & 0x7f));
            }
            remaining -= returned;
            offset += returned;
        }
    }
    return 0;
}

fn thermalGet(intf: *Intf, entity: u8, instance: u8) c_int {
    var msg = [3]u8{ group, entity, instance };
    const rsp = req(intf, 0x0c, &msg);
    if (!valid(rsp, 5)) return -1;
    const d = &rsp.?.data;
    _ = c.printf("\n    Persistence flag is:                      %s\n", choose(d[1] & 0x80 != 0, "set", "notset"));
    _ = c.printf("    Exception Actions, taken if the Temperature Limit exceeded:\n");
    _ = c.printf("        Hard Power Off system and log event:  %s\n", choose(d[1] & 0x40 != 0, "active", "inactive"));
    _ = c.printf("        Log event to SEL only:                %s\n", choose(d[1] & 0x20 != 0, "active", "inactive"));
    _ = c.printf("    Temperature Limit                         %d degrees\n", @as(c_int, d[2]));
    _ = c.printf("    Exception Time                            %d seconds\n\n\n", @as(c_int, word(d, 3)));
    return 0;
}
fn thermalSet(intf: *Intf, entity: u8, instance: u8, persistence: u8, hard: u8, sel: u8, limit: u8, seconds_lo: u8, seconds_hi: u8) c_int {
    var msg = [7]u8{ group, entity, instance, ((@as(u8, @intFromBool(persistence != 0))) << 7) | (@as(u8, @intFromBool(hard != 0)) << 6) | (@as(u8, @intFromBool(sel != 0)) << 5), limit, seconds_lo, seconds_hi };
    if (!valid(req(intf, 0x0b, &msg), 1)) return -1;
    _ = c.printf("\nThermal policy %d for %0Xh entity successfully set.\n\n", @as(c_int, instance), @as(c_uint, entity));
    return 0;
}
fn thermal(intf: *Intf, args: []const ?[*:0]u8) c_int {
    const action = find(&thermal_cmds, argAt(args, 1));
    if (action == 0xff) {
        usage(&thermal_cmds, "thermalpolicy <command>");
        return -1;
    }
    if (args.len < 4) {
        c.lprintf(notice_level, if (action == 0) "Get <entityID> <instanceID>" else "Set <entityID> <instanceID>");
        return -1;
    }
    if (action == 1 and args.len < 9) {
        usage(&thermal_opts, "Set thermalpolicy instance parameters: <volatile/nonvolatile/disabled> <poweroff/nopoweroff/disabled> <sel/nosel/disabled> <templimitByte> <exceptionTime>");
        return -1;
    }
    const entity = parse(u8, argAt(args, 2)) orelse {
        c.lprintf(err_level, "Given Entity ID '%s' is invalid.", argAt(args, 2));
        return -1;
    };
    const instance = parse(u8, argAt(args, 3)) orelse {
        c.lprintf(err_level, "Given Instance ID '%s' is invalid.", argAt(args, 3));
        return -1;
    };
    if (action == 0) return thermalGet(intf, entity, instance);
    const temp = parse(u8, argAt(args, 7)) orelse {
        c.lprintf(err_level, "Given Temp Limit '%s' is invalid.", argAt(args, 7));
        return -1;
    };
    const seconds = parse(u16, argAt(args, 8)) orelse {
        c.lprintf(err_level, "Given Sampling Time '%s' is invalid.", argAt(args, 8));
        return -1;
    };
    const persistence = find(&thermal_opts, argAt(args, 4));
    const hard = find(&thermal_opts, argAt(args, 5));
    const sel = find(&thermal_opts, argAt(args, 6));
    return thermalSet(
        intf,
        entity,
        instance,
        @intFromBool(persistence != 0xff and persistence != 0),
        @intFromBool(hard != 0xff and hard != 0),
        @intFromBool(sel != 0xff and sel != 0),
        temp,
        @truncate(seconds),
        @truncate(seconds >> 8),
    );
}
fn getConfig(intf: *Intf) c_int {
    for (2..6) |selector| {
        var msg = [3]u8{ group, @intCast(selector), 0 };
        const rsp = req(intf, 0x13, &msg);
        if (!valid(rsp, if (selector > 3) 6 else 5)) {
            c.lprintf(err_level, "Error Get DCMI Configuration Parameters!");
            return -1;
        }
        const d = &rsp.?.data;
        switch (selector) {
            2 => {
                _ = c.printf("\n\tDHCP Discovery method\t: ");
                _ = c.printf("\n\t\tManagement Controller ID String is %s", choose(d[4] & 1 != 0, "enabled", "disabled"));
                _ = c.printf("\n\t\tVendor class identifier DCMI IANA and Vendor class-specific Informationa are %s", choose(d[4] & 2 != 0, "enabled", "disabled"));
            },
            3 => _ = c.printf("\n\tInitial timeout interval\t: %i seconds", @as(c_int, d[4])),
            4 => _ = c.printf("\n\tServer contact timeout interval\t: %i seconds", @as(c_int, word(d, 4))),
            5 => _ = c.printf("\n\tServer contact retry interval\t: %i seconds", @as(c_int, word(d, 4))),
            else => unreachable,
        }
    }
    return 0;
}
fn setConfigWire(intf: *Intf, param: u8, value: u16) ?*Response {
    var msg = [5]u8{ group, param, 0, @truncate(value), @truncate(value >> 8) };
    return req(intf, 0x12, msg[0..(if (param > 3) 5 else 4)]);
}
fn setConfig(intf: *Intf, args: []const ?[*:0]u8) c_int {
    if ((args.len == 2 and !is(argAt(args, 1), "activate_dhcp")) or
        (args.len != 2 and (args.len != 3 or is(argAt(args, 1), "help"))))
    {
        usage(&config_opts, "DCMI Configuration Parameters");
        return -1;
    }
    var param: u8 = 1;
    var value: u16 = 1;
    if (!is(argAt(args, 1), "activate_dhcp")) {
        value = parse(u16, argAt(args, 2)) orelse {
            c.lprintf(err_level, "Given %s '%s' is invalid.", argAt(args, 1), argAt(args, 2));
            return -1;
        };
        param = @truncate(find(&config_opts, argAt(args, 1)));
    }
    if (!valid(setConfigWire(intf, param, value), 1)) c.lprintf(err_level, "Error Set DCMI Configuration Parameters!");
    return 0; // The C CLI does not propagate the BMC failure for this command.
}

fn oobDiscover(intf: *Intf) c_int {
    if (comptime @hasDecl(c, "IPMI_INTF_LANPLUS")) {
        if (intf.opened == 0) {
            if (intf.open) |open| if (open(intf) < 0) return -1;
        }
        if (intf.session == null) return -1;
        const params = &intf.ssn_params;
        if (params.port == 0) params.port = 0x26f;
        if (params.privlvl == 0) params.privlvl = 4;
        if (params.timeout == 0) params.timeout = c.IPMI_LAN_TIMEOUT;
        if (params.retry == 0) params.retry = c.IPMI_LAN_RETRY;
        if (params.hostname == null or params.hostname.?[0] == 0) {
            c.lprintf(err_level, "No hostname specified!");
            return -1;
        }
        intf.abort = 1;
        intf.session.?.sol_data.sequence_number = 1;
        if (c.ipmi_intf_socket_connect(@ptrCast(intf)) == -1) {
            c.lprintf(err_level, "Could not open socket!");
            return -1;
        }
        if (intf.fd < 0) {
            c.lperror(err_level, "Connect to %s failed", params.hostname);
            if (intf.close) |close| close(intf);
            return -1;
        }
        intf.opened = 1;
        return c.ipmiv2_lan_ping(@ptrCast(intf));
    }
    c.lprintf(err_level, "DCMI Discovery is available only when LANplus(IPMI v2.0) is enabled.");
    return -1;
}

fn dcmiMain(intf_opt: ?*Intf, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    const intf = intf_opt orelse return -1;
    const args: []const ?[*:0]u8 = if (argc > 0 and argv != null) argv.?[0..@intCast(argc)] else &.{};
    if (args.len == 0 or is(argAt(args, 0), "help")) {
        usage(&commands, "Data Center Management Interface commands");
        return -1;
    }
    var rc: c_int = 0;
    const command = find(&commands, argAt(args, 0));
    switch (command) {
        0 => rc = discover(intf),
        1 => {
            if (args.len < 2) {
                usage(&power_cmds, "power <command>");
                return -1;
            }
            rc = power(intf, args[1..]);
        },
        2 => rc = sensors(intf),
        3 => {
            rc = getString(intf, false);
            if (rc < 0) c.lprintf(err_level, "Error getting asset tag!");
        },
        4 => {
            if (args.len < 2) {
                usage(&commands, "Data Center Management Interface commands");
                return -1;
            }
            rc = setString(intf, false, args[1].?);
            if (rc < 0) c.lprintf(err_level, "\nError setting asset tag!");
        },
        5 => {
            rc = getString(intf, true);
            if (rc < 0) c.lprintf(err_level, "Error getting management controller identifier string!");
        },
        6 => {
            if (args.len < 2) {
                usage(&commands, "Data Center Management Interface commands");
                return -1;
            }
            rc = setString(intf, true, args[1].?);
            if (rc < 0) c.lprintf(err_level, "Error setting management controller identifier string!");
        },
        7 => rc = thermal(intf, args),
        8 => {
            rc = temps(intf);
            if (rc < 0) c.lprintf(err_level, "Error get temperature readings!");
        },
        9 => rc = getConfig(intf),
        10 => rc = setConfig(intf, args),
        11 => {
            if (intf.session == null) {
                c.lprintf(err_level, "\nOOB discovery is available only via RMCP interface.");
                return -1;
            }
            rc = oobDiscover(intf);
            if (rc < 0) {
                c.lprintf(err_level, "\nOOB discovering capabilities failed.");
                return -1;
            }
        },
        else => {
            usage(&commands, "Data Center Management Interface commands");
            return -1;
        },
    }
    if (rc >= 0 or command == 1 or command == 2 or command == 7) _ = c.printf("\n");
    return rc;
}

fn makeTable(comptime items: []const Item, comptime default_value: u16) [items.len + 1]c.struct_dcmi_cmd {
    var result: [items.len + 1]c.struct_dcmi_cmd = undefined;
    for (items, 0..) |item, i| {
        result[i] = .{ .val = item.val, .str = item.name, .desc = item.desc };
    }
    result[items.len] = .{ .val = default_value, .str = null, .desc = null };
    return result;
}

const tables = struct {
    const cmds = makeTable(&commands, 0xff);
    const capable = makeTable(&capabilities, 0xff);
    const mandatory_caps = makeTable(&mandatory, 0xff);
    const optional_caps = makeTable(&optional, 0xff);
    const access_caps = makeTable(&access, 0xff);
    const identification_caps = makeTable(&identification, 0xff);
    const conf = makeTable(&config_opts, 0xff);
    const temp_monitor = makeTable(&temp_caps, 0xff);
    const sensor_discovery = makeTable(&.{
        .{ .val = 0x40, .name = "Inlet", .desc = "Inlet air temperature sensors" },
        .{ .val = 0x41, .name = "CPU", .desc = "CPU temperature sensors" },
        .{ .val = 0x42, .name = "Baseboard", .desc = "Baseboard temperature sensors" },
    }, 0xff);
    const temp_read = makeTable(&temp_names, 0xff);
    const power = makeTable(&power_cmds, 0xff);
    const power_set_usage = makeTable(&set_limit_opts, 0xff);
    const power_action_read = makeTable(&action_names, 0xff);
    const power_action_write = makeTable(&.{
        .{ .val = 0, .name = "no_action", .desc = "No Action" },
        .{ .val = 1, .name = "power_off", .desc = "Hard Power Off & Log Event to SEL" },
        .{ .val = 17, .name = "sel_logging", .desc = "Log Event to SEL" },
        .{ .val = 2, .name = "oem_02", .desc = "OEM reserved (02h)" },
        .{ .val = 3, .name = "oem_03", .desc = "OEM reserved (03h)" },
        .{ .val = 4, .name = "oem_04", .desc = "OEM reserved (04h)" },
        .{ .val = 5, .name = "oem_05", .desc = "OEM reserved (05h)" },
        .{ .val = 6, .name = "oem_06", .desc = "OEM reserved (06h)" },
        .{ .val = 7, .name = "oem_07", .desc = "OEM reserved (07h)" },
        .{ .val = 8, .name = "oem_08", .desc = "OEM reserved (08h)" },
        .{ .val = 9, .name = "oem_09", .desc = "OEM reserved (09h)" },
        .{ .val = 10, .name = "oem_0a", .desc = "OEM reserved (0ah)" },
        .{ .val = 11, .name = "oem_0b", .desc = "OEM reserved (0bh)" },
        .{ .val = 12, .name = "oem_0c", .desc = "OEM reserved (0ch)" },
        .{ .val = 13, .name = "oem_0d", .desc = "OEM reserved (0dh)" },
        .{ .val = 14, .name = "oem_0e", .desc = "OEM reserved (0eh)" },
        .{ .val = 15, .name = "oem_0f", .desc = "OEM reserved (0fh)" },
        .{ .val = 16, .name = "oem_10", .desc = "OEM reserved (10h)" },
    }, 0xff);
    const thermal_policy = makeTable(&thermal_cmds, 0xff);
    const config_commands = makeTable(&.{ .{ .val = 0, .name = "get", .desc = "Get configuration parameters" }, .{ .val = 1, .name = "set", .desc = "Set configuration parameters" } }, 0xff);
    const thermal_parameters = makeTable(&thermal_opts, 0);
    const sampling = makeTable(&samples, 0);
};

fn printStrs(vs: [*c]const c.struct_dcmi_cmd, title: [*c]const u8, level: c_int, horizontal: c_int) callconv(.c) void {
    if (vs == null) return;
    if (title != null) {
        if (level < 0) {
            _ = c.printf("\n%s\n", title);
        } else {
            c.lprintf(level, "\n%s", title);
        }
    }
    var i: usize = 0;
    while (vs[i].str != null) : (i += 1) {
        if (level < 0) {
            if (horizontal == 0)
                _ = c.printf("    %s    %s\n", vs[i].str, vs[i].desc)
            else
                _ = c.printf("%s", vs[i].str);
        } else {
            c.lprintf(level, "    %s    %s", vs[i].str, vs[i].desc);
        }
        if (horizontal == 1 and vs[i + 1].str != null) _ = c.printf(" | ");
    }
    if (horizontal == 0) {
        if (level < 0) {
            _ = c.printf("\n");
        } else {
            c.lprintf(level, "");
        }
    }
}
fn strToVal(s: [*c]const u8, vs: [*c]const c.struct_dcmi_cmd) callconv(.c) u16 {
    if (s == null or vs == null) return 0;
    var i: usize = 0;
    while (vs[i].str != null) : (i += 1) {
        if (c.strcasecmp(s, vs[i].str) == 0) return vs[i].val;
    }
    return vs[i].val;
}
fn valToStr(value: u16, vs: [*c]const c.struct_dcmi_cmd) callconv(.c) [*c]const u8 {
    if (vs == null) return null;
    var i: usize = 0;
    while (vs[i].str != null) : (i += 1) {
        if (vs[i].val == value) return vs[i].str;
    }
    return name(&.{}, value);
}
fn cGetCapabilities(intf: ?*Intf, selector: u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [2]u8{ group, selector };
    return req(in, 1, &msg);
}
fn cGetAsset(intf: ?*Intf, offset: u8, amount: u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [3]u8{ group, offset, amount };
    return req(in, 6, &msg);
}
fn cSetAsset(intf: ?*Intf, offset: u8, amount: u8, data: [*c]u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    if (amount > 16 or (amount > 0 and data == null)) return null;
    var msg: [19]u8 = @splat(0);
    msg[0] = group;
    msg[1] = offset;
    msg[2] = amount;
    if (amount != 0) @memcpy(msg[3..][0..amount], data[0..amount]);
    return req(in, 8, msg[0 .. 3 + amount]);
}
fn cGetMcId(intf: ?*Intf, offset: u8, amount: u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [3]u8{ group, offset, amount };
    return req(in, 9, &msg);
}
fn cSetMcId(intf: ?*Intf, offset: u8, amount: u8, data: [*c]u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    if (amount > 16 or (amount > 0 and data == null)) return null;
    var msg: [19]u8 = @splat(0);
    msg[0] = group;
    msg[1] = offset;
    msg[2] = amount;
    if (amount != 0) @memcpy(msg[3..][0..amount], data[0..amount]);
    return req(in, 10, msg[0 .. 3 + amount]);
}
fn cSensor(intf: ?*Intf, entity: u8, offset: u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [5]u8{ group, 1, entity, 0, offset };
    return req(in, 7, &msg);
}
fn cTemperature(intf: ?*Intf, entity: u8, instance: u8, start: u8) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [5]u8{ group, 1, entity, instance, start };
    return req(in, 0x10, &msg);
}
fn cGetConfig(intf: ?*Intf, selector: c_int) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [3]u8{ group, @truncate(@as(c_uint, @bitCast(selector))), 0 };
    return req(in, 0x13, &msg);
}
fn cSetConfig(intf: ?*Intf, selector: u8, value: u16) callconv(.c) ?*Response {
    return setConfigWire(intf orelse return null, selector, value);
}
fn cPowerLimit(intf: ?*Intf) callconv(.c) ?*Response {
    const in = intf orelse return null;
    var msg = [3]u8{ group, 0, 0 };
    return req(in, 3, &msg);
}
fn cThermalGet(intf: ?*Intf, entity: u8, instance: u8) callconv(.c) c_int {
    return thermalGet(intf orelse return -1, entity, instance);
}
fn cThermalSet(intf: ?*Intf, entity: u8, instance: u8, persistence: u8, hard: u8, sel: u8, limit: u8, low: u8, high: u8) callconv(.c) c_int {
    return thermalSet(intf orelse return -1, entity, instance, persistence, hard, sel, limit, low, high);
}

pub fn exportSymbols() void {
    @setEvalBranchQuota(100_000);
    abi.assertCallSignature(@TypeOf(dcmiMain), @TypeOf(c.ipmi_dcmi_main));
    abi.assertCallSignature(@TypeOf(printStrs), @TypeOf(c.print_strs));
    abi.assertCallSignature(@TypeOf(strToVal), @TypeOf(c.str2val2));
    abi.assertCallSignature(@TypeOf(valToStr), @TypeOf(c.val2str2));
    abi.assertCallSignature(@TypeOf(cGetCapabilities), @TypeOf(c.ipmi_dcmi_getcapabilities));
    abi.assertCallSignature(@TypeOf(cGetAsset), @TypeOf(c.ipmi_dcmi_getassettag));
    abi.assertCallSignature(@TypeOf(cSetAsset), @TypeOf(c.ipmi_dcmi_setassettag));
    abi.assertCallSignature(@TypeOf(cGetMcId), @TypeOf(c.ipmi_dcmi_getmngctrlids));
    abi.assertCallSignature(@TypeOf(cSetMcId), @TypeOf(c.ipmi_dcmi_setmngctrlids));
    abi.assertCallSignature(@TypeOf(cSensor), @TypeOf(c.ipmi_dcmi_discvry_snsr));
    abi.assertCallSignature(@TypeOf(cTemperature), @TypeOf(c.ipmi_dcmi_get_temp_readings));
    abi.assertCallSignature(@TypeOf(cGetConfig), @TypeOf(c.ipmi_dcmi_getconfparam));
    abi.assertCallSignature(@TypeOf(cSetConfig), @TypeOf(c.ipmi_dcmi_setconfparam));
    abi.assertCallSignature(@TypeOf(cPowerLimit), @TypeOf(c.ipmi_dcmi_pwr_glimit));
    abi.assertCallSignature(@TypeOf(cThermalGet), @TypeOf(c.ipmi_dcmi_getthermalpolicy));
    abi.assertCallSignature(@TypeOf(cThermalSet), @TypeOf(c.ipmi_dcmi_setthermalpolicy));

    @export(&dcmiMain, .{ .name = "ipmi_dcmi_main", .linkage = .strong });
    @export(&printStrs, .{ .name = "print_strs", .linkage = .strong });
    @export(&strToVal, .{ .name = "str2val2", .linkage = .strong });
    @export(&valToStr, .{ .name = "val2str2", .linkage = .strong });
    @export(&cGetCapabilities, .{ .name = "ipmi_dcmi_getcapabilities", .linkage = .strong });
    @export(&cGetAsset, .{ .name = "ipmi_dcmi_getassettag", .linkage = .strong });
    @export(&cSetAsset, .{ .name = "ipmi_dcmi_setassettag", .linkage = .strong });
    @export(&cGetMcId, .{ .name = "ipmi_dcmi_getmngctrlids", .linkage = .strong });
    @export(&cSetMcId, .{ .name = "ipmi_dcmi_setmngctrlids", .linkage = .strong });
    @export(&cSensor, .{ .name = "ipmi_dcmi_discvry_snsr", .linkage = .strong });
    @export(&cTemperature, .{ .name = "ipmi_dcmi_get_temp_readings", .linkage = .strong });
    @export(&cGetConfig, .{ .name = "ipmi_dcmi_getconfparam", .linkage = .strong });
    @export(&cSetConfig, .{ .name = "ipmi_dcmi_setconfparam", .linkage = .strong });
    @export(&cPowerLimit, .{ .name = "ipmi_dcmi_pwr_glimit", .linkage = .strong });
    @export(&cThermalGet, .{ .name = "ipmi_dcmi_getthermalpolicy", .linkage = .strong });
    @export(&cThermalSet, .{ .name = "ipmi_dcmi_setthermalpolicy", .linkage = .strong });

    @export(&tables.cmds, .{ .name = "dcmi_cmd_vals", .linkage = .strong });
    @export(&tables.capable, .{ .name = "dcmi_capable_vals", .linkage = .strong });
    @export(&tables.mandatory_caps, .{ .name = "dcmi_mandatory_platform_capabilities", .linkage = .strong });
    @export(&tables.optional_caps, .{ .name = "dcmi_optional_platform_capabilities", .linkage = .strong });
    @export(&tables.access_caps, .{ .name = "dcmi_management_access_capabilities", .linkage = .strong });
    @export(&tables.identification_caps, .{ .name = "dcmi_id_capabilities_vals", .linkage = .strong });
    @export(&tables.conf, .{ .name = "dcmi_conf_param_vals", .linkage = .strong });
    @export(&tables.temp_monitor, .{ .name = "dcmi_temp_monitoring_vals", .linkage = .strong });
    @export(&tables.sensor_discovery, .{ .name = "dcmi_discvry_snsr_vals", .linkage = .strong });
    @export(&tables.temp_read, .{ .name = "dcmi_temp_read_vals", .linkage = .strong });
    @export(&tables.power, .{ .name = "dcmi_pwrmgmt_vals", .linkage = .strong });
    @export(&tables.power_set_usage, .{ .name = "dcmi_pwrmgmt_set_usage_vals", .linkage = .strong });
    @export(&tables.power_action_read, .{ .name = "dcmi_pwrmgmt_get_action_vals", .linkage = .strong });
    @export(&tables.power_action_write, .{ .name = "dcmi_pwrmgmt_action_vals", .linkage = .strong });
    @export(&tables.thermal_policy, .{ .name = "dcmi_thermalpolicy_vals", .linkage = .strong });
    @export(&tables.config_commands, .{ .name = "dcmi_confparameters_vals", .linkage = .strong });
    @export(&tables.thermal_parameters, .{ .name = "dcmi_thermalpolicy_set_parameters_vals", .linkage = .strong });
    @export(&tables.sampling, .{ .name = "dcmi_sampling_vals", .linkage = .strong });
    @export(&dcmi_ccode_vals, .{ .name = "dcmi_ccode_vals", .linkage = .strong });
    @import("nm.zig").exportSymbols();
}

test "DCMI reply length cannot exceed the transport payload" {
    var response = std.mem.zeroes(Response);
    response.data_len = -1;
    try std.testing.expectEqual(@as(usize, 0), length(&response));
    response.data_len = 3;
    try std.testing.expect(length(&response) < 2 + 16);
    response.data_len = ipmi.buf_size + 1;
    try std.testing.expectEqual(@as(usize, ipmi.buf_size), length(&response));
}
