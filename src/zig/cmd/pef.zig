//! Platform Event Filtering command and public C ABI of lib/ipmi_pef.c.
//! All request and response sizes are validated before accessing BMC data.
//! Selected with `-Dzig-modules=pef`.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;
const log = @import("../util/log.zig");

const Desc = struct { text: [*:0]const u8, mask: u32 };
const Kind = enum { list, any, all };
const Map = struct { kind: Kind, entries: []const Desc };
const actions = Map{ .kind = .all, .entries = &.{
    .{ .text = "Alert", .mask = 1 },
    .{ .text = "Power-off", .mask = 2 },
    .{ .text = "Reset", .mask = 4 },
    .{ .text = "Power-cycle", .mask = 8 },
    .{ .text = "OEM-defined", .mask = 16 },
    .{ .text = "Diagnostic-interrupt", .mask = 32 },
} };
const severities = Map{ .kind = .any, .entries = &.{
    .{ .text = "Non-recoverable", .mask = 32 },
    .{ .text = "Critical", .mask = 16 },
    .{ .text = "Warning", .mask = 8 },
    .{ .text = "OK", .mask = 4 },
    .{ .text = "Information", .mask = 2 },
    .{ .text = "Monitor", .mask = 1 },
} };
const sensors = Map{ .kind = .list, .entries = &.{
    .{ .text = "Any", .mask = 255 },
    .{ .text = "Temperature", .mask = 1 },
    .{ .text = "Voltage", .mask = 2 },
    .{ .text = "Current", .mask = 3 },
    .{ .text = "Fan", .mask = 4 },
    .{ .text = "Chassis Intrusion", .mask = 5 },
    .{ .text = "Platform security breach", .mask = 6 },
    .{ .text = "Processor", .mask = 7 },
    .{ .text = "Power supply", .mask = 8 },
    .{ .text = "Power Unit", .mask = 9 },
    .{ .text = "Cooling device", .mask = 10 },
    .{ .text = "Other (units-based)", .mask = 11 },
    .{ .text = "Memory", .mask = 12 },
    .{ .text = "Drive Slot", .mask = 13 },
    .{ .text = "POST memory resize", .mask = 14 },
    .{ .text = "POST error", .mask = 15 },
    .{ .text = "Logging disabled", .mask = 16 },
    .{ .text = "Watchdog 1", .mask = 17 },
    .{ .text = "System event", .mask = 18 },
    .{ .text = "Critical Interrupt", .mask = 19 },
    .{ .text = "Button", .mask = 20 },
    .{ .text = "Module/board", .mask = 21 },
    .{ .text = "uController/coprocessor", .mask = 22 },
    .{ .text = "Add-in card", .mask = 23 },
    .{ .text = "Chassis", .mask = 24 },
    .{ .text = "Chipset", .mask = 25 },
    .{ .text = "Other (FRU)", .mask = 26 },
    .{ .text = "Cable/interconnect", .mask = 27 },
    .{ .text = "Terminator", .mask = 28 },
    .{ .text = "System boot", .mask = 29 },
    .{ .text = "Boot error", .mask = 30 },
    .{ .text = "OS boot", .mask = 31 },
    .{ .text = "OS critical stop", .mask = 32 },
    .{ .text = "Slot/connector", .mask = 33 },
    .{ .text = "ACPI power state", .mask = 34 },
    .{ .text = "Watchdog 2", .mask = 35 },
    .{ .text = "Platform alert", .mask = 36 },
    .{ .text = "Entity presence", .mask = 37 },
    .{ .text = "Monitor ASIC/IC", .mask = 38 },
    .{ .text = "LAN", .mask = 39 },
    .{ .text = "Management subsystem health", .mask = 40 },
    .{ .text = "Battery", .mask = 41 },
} };
const generic = [_]Map{
    .{ .kind = .list, .entries = &.{ .{ .text = "<LNC", .mask = 0 }, .{ .text = ">LNC", .mask = 1 }, .{ .text = "<LC", .mask = 2 }, .{ .text = ">LC", .mask = 3 }, .{ .text = "<LNR", .mask = 4 }, .{ .text = ">LNR", .mask = 5 }, .{ .text = ">UNC", .mask = 6 }, .{ .text = "<UNC", .mask = 7 }, .{ .text = ">UC", .mask = 8 }, .{ .text = "<UC", .mask = 9 }, .{ .text = ">UNR", .mask = 10 }, .{ .text = "<UNR", .mask = 11 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "transition to idle", .mask = 0 }, .{ .text = "transition to active", .mask = 1 }, .{ .text = "transition to busy", .mask = 2 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "state deasserted", .mask = 0 }, .{ .text = "state asserted", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "predictive failure deasserted", .mask = 0 }, .{ .text = "predictive failure asserted", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "limit not exceeded", .mask = 0 }, .{ .text = "limit exceeded", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "performance met", .mask = 0 }, .{ .text = "performance lags", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "ok", .mask = 0 }, .{ .text = "<warn", .mask = 1 }, .{ .text = "<fail", .mask = 2 }, .{ .text = "<dead", .mask = 3 }, .{ .text = ">warn", .mask = 4 }, .{ .text = ">fail", .mask = 5 }, .{ .text = "dead", .mask = 6 }, .{ .text = "monitor", .mask = 7 }, .{ .text = "informational", .mask = 8 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "device removed/absent", .mask = 0 }, .{ .text = "device inserted/present", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "device disabled", .mask = 0 }, .{ .text = "device enabled", .mask = 1 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "transition to running", .mask = 0 }, .{ .text = "transition to in test", .mask = 1 }, .{ .text = "transition to power off", .mask = 2 }, .{ .text = "transition to online", .mask = 3 }, .{ .text = "transition to offline", .mask = 4 }, .{ .text = "transition to off duty", .mask = 5 }, .{ .text = "transition to degraded", .mask = 6 }, .{ .text = "transition to power save", .mask = 7 }, .{ .text = "install error", .mask = 8 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "fully redundant", .mask = 0 }, .{ .text = "redundancy lost", .mask = 1 }, .{ .text = "redundancy degraded", .mask = 2 }, .{ .text = "<non-redundant/sufficient", .mask = 3 }, .{ .text = ">non-redundant/sufficient", .mask = 4 }, .{ .text = "non-redundant/insufficient", .mask = 5 }, .{ .text = "<redundancy degraded", .mask = 6 }, .{ .text = ">redundancy degraded", .mask = 7 } } },
    .{ .kind = .list, .entries = &.{ .{ .text = "D0 power state", .mask = 0 }, .{ .text = "D1 power state", .mask = 1 }, .{ .text = "D2 power state", .mask = 2 }, .{ .text = "D3 power state", .mask = 3 } } },
};
const policies = Map{ .kind = .list, .entries = &.{
    .{ .text = "Match-always", .mask = 0 },         .{ .text = "Try-next-entry", .mask = 1 },
    .{ .text = "Try-next-set", .mask = 2 },         .{ .text = "Try-next-channel", .mask = 3 },
    .{ .text = "Try-next-destination", .mask = 4 },
} };
const media = Map{ .kind = .list, .entries = &.{
    .{ .text = "IPMB (I2C)", .mask = 1 },            .{ .text = "ICMB v1.0", .mask = 2 },
    .{ .text = "ICMB v0.9", .mask = 3 },             .{ .text = "802.3 LAN", .mask = 4 },
    .{ .text = "Serial/Modem (RS-232)", .mask = 5 }, .{ .text = "Other LAN", .mask = 6 },
    .{ .text = "PCI SMBus", .mask = 7 },             .{ .text = "SMBus v1.0/1.1", .mask = 8 },
    .{ .text = "SMBus v2.0", .mask = 9 },            .{ .text = "USB 1.x", .mask = 10 },
    .{ .text = "USB 2.x", .mask = 11 },              .{ .text = "System I/F (KCS,SMIC,BT)", .mask = 12 },
} };
const controls = Map{ .kind = .all, .entries = &.{
    .{ .text = "PEF", .mask = 1 },               .{ .text = "PEF event messages", .mask = 2 },
    .{ .text = "PEF startup delay", .mask = 4 }, .{ .text = "Alert startup delay", .mask = 8 },
} };
const lan_types = Map{ .kind = .list, .entries = &.{
    .{ .text = "Acknowledged", .mask = 128 }, .{ .text = "PET", .mask = 0 },
    .{ .text = "OEM 1", .mask = 6 },          .{ .text = "OEM 2", .mask = 7 },
} };
const serial_types = Map{ .kind = .list, .entries = &.{
    .{ .text = "Acknowledged", .mask = 128 }, .{ .text = "TAP page", .mask = 1 },
    .{ .text = "PPP PET", .mask = 2 },        .{ .text = "Basic callback", .mask = 3 },
    .{ .text = "PPP callback", .mask = 4 },   .{ .text = "OEM 1", .mask = 14 },
    .{ .text = "OEM 2", .mask = 15 },
} };
const confirmations = Map{ .kind = .list, .entries = &.{
    .{ .text = "ACK", .mask = 0 },           .{ .text = "211+ACK", .mask = 1 },
    .{ .text = "{211|213}+ACK", .mask = 2 },
} };

var first_field = true;
var desc_buffer: [128]u8 = @splat(0);

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn send(intf: *Intf, netfn: u6, cmd: u8, data: []const u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn;
    req.msg.cmd = cmd;
    if (data.len != 0) req.msg.data = @ptrCast(@constCast(data.ptr));
    req.msg.data_len = @intCast(data.len);
    return intf.sendrecv.?(intf, &req);
}

fn val(rsp: ?*Response, expected: usize) c_int {
    const r = rsp orelse return -1;
    if (r.ccode != 0) return r.ccode;
    if (r.data_len != expected) return -2;
    return 0;
}

fn evaluate(rc: c_int) bool {
    return c.eval_ccode(rc) == 0;
}

fn exchange(intf: *Intf, netfn: u6, cmd: u8, data: []const u8, text: [*:0]const u8, min: usize) ?*Response {
    const rsp = send(intf, netfn, cmd, data) orelse return null;
    if (rsp.ccode == 0x80) return null;
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, " **Error %x in '%s' command", @as(c_uint, rsp.ccode), text);
        return null;
    }
    if (rsp.data_len < min) {
        c.lprintf(log.Level.err, "Unexpected data length received.");
        return null;
    }
    if (c.verbose > 2) c.printbuf(@ptrCast(&rsp.data), rsp.data_len, text);
    return rsp;
}

fn eql(str: [*:0]const u8, literal: [*:0]const u8) bool {
    return c.strcmp(str, literal) == 0;
}

fn description(map: Map, value: u32) [*:0]const u8 {
    var pos: usize = 0;
    for (map.entries) |entry| {
        const match = if (map.kind == .list) value == entry.mask else value & entry.mask == entry.mask;
        if (!match) continue;
        if (pos != 0 and map.kind == .all) {
            desc_buffer[pos] = ',';
            pos += 1;
        }
        const text = std.mem.span(entry.text);
        if (pos + text.len >= desc_buffer.len) break;
        @memcpy(desc_buffer[pos..][0..text.len], text);
        pos += text.len;
        if (map.kind != .all) break;
    }
    if (pos == 0) return "None";
    desc_buffer[pos] = 0;
    return @ptrCast(&desc_buffer);
}

fn bitDesc(map: [*c]c.struct_bit_desc_map, value: u32) callconv(.c) [*c]const u8 {
    if (map == null) return "None";
    var pos: usize = 0;
    for (map.*.desc_maps) |entry| {
        if (entry.desc == null) break;
        const match = if (map.*.desc_map_type == c.BIT_DESC_MAP_LIST)
            value == entry.mask
        else
            value & entry.mask == entry.mask;
        if (!match) continue;
        const text = std.mem.span(@as([*:0]const u8, @ptrCast(entry.desc)));
        if (pos != 0 and map.*.desc_map_type == c.BIT_DESC_MAP_ALL) {
            desc_buffer[pos] = ',';
            pos += 1;
        }
        if (pos + text.len >= desc_buffer.len) break;
        @memcpy(desc_buffer[pos..][0..text.len], text);
        pos += text.len;
        if (map.*.desc_map_type != c.BIT_DESC_MAP_ALL) break;
    }
    if (pos == 0) return "None";
    desc_buffer[pos] = 0;
    return @ptrCast(&desc_buffer);
}

fn flags(map: Map, kind: u8, bits: u32) void {
    var first = true;
    for (map.entries) |entry| {
        const present = bits & entry.mask != 0;
        if (c.verbose != 0) {
            const adjective: [*:0]const u8 = switch (kind) {
                1 => if (present) "" else "un",
                2 => if (present) "" else "in",
                3 => if (present) "en" else "dis",
                else => if (present) "true" else "false",
            };
            const suffix: [*:0]const u8 = switch (kind) {
                1 => "supported",
                2 => "active",
                3 => "abled",
                else => "",
            };
            _ = c.printf("%-*s : %s%s\n", @as(c_int, 24), description(map, entry.mask), adjective, suffix);
        } else if (present) {
            _ = c.printf(if (first) " | %s" else ",%s", description(map, bits & entry.mask));
            first = false;
        }
    }
}

fn printFlags(map: [*c]c.struct_bit_desc_map, kind: c.flg_e, bits: u32) callconv(.c) void {
    if (map == null) return;
    var first = true;
    for (map.*.desc_maps) |entry| {
        if (entry.desc == null) break;
        const present = bits & entry.mask != 0;
        if (c.verbose != 0) {
            const adjective: [*:0]const u8 = switch (kind) {
                c.P_SUPP => if (present) "" else "un",
                c.P_ACTV => if (present) "" else "in",
                c.P_ABLE => if (present) "en" else "dis",
                else => if (present) "true" else "false",
            };
            const suffix: [*:0]const u8 = switch (kind) {
                c.P_SUPP => "supported",
                c.P_ACTV => "active",
                c.P_ABLE => "abled",
                else => "",
            };
            _ = c.printf("%-*s : %s%s\n", @as(c_int, 24), bitDesc(map, entry.mask), adjective, suffix);
        } else if (present) {
            _ = c.printf(if (first) " | %s" else ",%s", bitDesc(map, bits & entry.mask));
            first = false;
        }
    }
}

fn printDec(label: [*c]const u8, value: u32) callconv(.c) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : %u\n", @as(c_int, 24), label, value);
    } else {
        _ = c.printf(if (first_field) " %u" else " | %u", value);
    }
    first_field = false;
}
fn printInt(label: [*c]const u8, value: u32) callconv(.c) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : %d\n", @as(c_int, 24), label, @as(i32, @bitCast(value)));
    } else {
        _ = c.printf(if (first_field) " %d" else " | %d", @as(i32, @bitCast(value)));
    }
    first_field = false;
}
fn printHex(label: [*c]const u8, value: u32) callconv(.c) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : 0x%x\n", @as(c_int, 24), label, value);
    } else {
        _ = c.printf(if (first_field) " 0x%x" else " | 0x%x", value);
    }
    first_field = false;
}
fn printStr(label: [*c]const u8, value: [*c]const u8) callconv(.c) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : %s\n", @as(c_int, 24), label, value);
    } else {
        _ = c.printf(if (first_field) " %s" else " | %s", value);
    }
    first_field = false;
}
fn print2xd(label: [*c]const u8, high: u8, low: u8) callconv(.c) void {
    const value: u32 = (@as(u32, high) << 8) | low;
    if (c.verbose != 0) {
        _ = c.printf("%-*s : 0x%04x\n", @as(c_int, 24), label, value);
    } else {
        _ = c.printf(if (first_field) " 0x%04x" else " | 0x%04x", value);
    }
    first_field = false;
}
fn print1xd(label: [*c]const u8, value: u32) callconv(.c) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : 0x%02x\n", @as(c_int, 24), label, value);
    } else {
        _ = c.printf(if (first_field) " 0x%02x" else " | 0x%02x", value);
    }
    first_field = false;
}

fn printGuid(guid: [*]const u8) void {
    if (c.verbose != 0) {
        _ = c.printf("%-*s : %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x\n", @as(c_int, 24), "System GUID", guid[0], guid[1], guid[2], guid[3], guid[4], guid[5], guid[6], guid[7], guid[8], guid[9], guid[10], guid[11], guid[12], guid[13], guid[14], guid[15]);
    } else {
        _ = c.printf(" | %02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", guid[0], guid[1], guid[2], guid[3], guid[4], guid[5], guid[6], guid[7], guid[8], guid[9], guid[10], guid[11], guid[12], guid[13], guid[14], guid[15]);
    }
}

const Capabilities = c.struct_pef_capabilities;
const FilterEntry = c.struct_pef_cfgparm_filter_table_entry;
const FilterCfg = c.struct_pef_cfgparm_filter_table_data_1;
const PolicyEntry = c.struct_pef_cfgparm_policy_table_entry;
const SystemGuid = c.struct_pef_cfgparm_system_guid;

fn getCapabilities(intf: *Intf, cap: ?*Capabilities) callconv(.c) c_int {
    const out = cap orelse return -3;
    out.* = std.mem.zeroes(Capabilities);
    const rsp = send(intf, ipmi.NetFn.se, 0x10, &.{});
    const rc = val(rsp, 3);
    if (rc != 0) return rc;
    out.* = .{
        .version = rsp.?.data[0],
        .actions = rsp.?.data[1],
        .event_filter_count = rsp.?.data[2],
    };
    return 0;
}

fn getConfig(intf: *Intf, selector: u8, set: u8, output: []u8) c_int {
    const rsp = send(intf, ipmi.NetFn.se, 0x13, &.{ selector, set, 0 });
    const rc = val(rsp, output.len + 1);
    if (rc != 0) return rc;
    @memcpy(output, rsp.?.data[1 .. 1 + output.len]);
    return 0;
}

fn getFilterEntry(intf: *Intf, id: u8, entry: *FilterEntry) c_int {
    entry.* = std.mem.zeroes(FilterEntry);
    return getConfig(intf, 6, id, std.mem.asBytes(entry));
}

fn getFilterCfg(intf: *Intf, id: u8, cfg: ?*FilterCfg) callconv(.c) c_int {
    const out = cfg orelse return -3;
    out.* = std.mem.zeroes(FilterCfg);
    return getConfig(intf, 7, id, std.mem.asBytes(out));
}

fn getPolicyEntry(intf: *Intf, id: u8, entry: *PolicyEntry) c_int {
    entry.* = std.mem.zeroes(PolicyEntry);
    return getConfig(intf, 9, id & 0x7f, std.mem.asBytes(entry));
}

fn getTableSize(intf: *Intf, selector: u8, output: *u8) c_int {
    output.* = 0;
    const rsp = send(intf, ipmi.NetFn.se, 0x13, &.{ selector, 0, 0 });
    const rc = val(rsp, 2);
    if (rc != 0) return rc;
    output.* = rsp.?.data[1] & 0x7f;
    return 0;
}

fn getSystemGuid(intf: *Intf, guid: ?*SystemGuid) callconv(.c) c_int {
    const out = guid orelse return -3;
    out.* = std.mem.zeroes(SystemGuid);
    const rsp = send(intf, ipmi.NetFn.se, 0x13, &.{ 10, 0, 0 });
    const rc = val(rsp, 18);
    if (rc != 0) return rc;
    out.data1 = rsp.?.data[1] & 1;
    @memcpy(out.guid[0..], rsp.?.data[2..18]);
    return 0;
}

fn setFilterCfg(intf: *Intf, id: u8, cfg: *const FilterCfg) c_int {
    const rsp = send(intf, ipmi.NetFn.se, 0x12, &.{ 7, id, cfg.cfg }) orelse return -1;
    return rsp.ccode;
}

fn setPolicyEntry(intf: *Intf, id: u8, entry: *const PolicyEntry) c_int {
    const buf = [5]u8{ 9, id & 0x7f, entry.entry.policy, entry.entry.chan_dest, entry.entry.alert_string_key };
    const rsp = send(intf, ipmi.NetFn.se, 0x12, &buf) orelse return -1;
    return rsp.ccode;
}

fn formatTrigger(t: u8, offmask: u16, buf: [*c]u8) void {
    if (offmask == 0xffff or t == 0xff) {
        _ = c.strcpy(buf, "Any");
    } else if (t == 0) {
        _ = c.strcpy(buf, "Unspecified");
    } else if (t == 0x6f) {
        _ = c.strcpy(buf, "Sensor-specific");
    } else if (t > 0x6f) {
        _ = c.strcpy(buf, "OEM");
    } else {
        var pos: usize = @intCast(c.sprintf(buf, "(0x%02x/0x%04x)", @as(c_uint, t), @as(c_uint, offmask)));
        var mask = offmask;
        for (0..generic.len) |i| {
            if (mask & 1 != 0) {
                const suffix: [*:0]const u8 = if (t > generic.len)
                    ", Unrecognized event trigger"
                else
                    description(generic[t - 1], @intCast(i));
                const written: c_int = if (t > generic.len)
                    c.snprintf(buf + pos, 128 - pos, "%s", suffix)
                else
                    c.snprintf(buf + pos, 128 - pos, ",%s", suffix);
                pos += @min(@as(usize, @intCast(written)), 127 - pos);
                if (pos == 127) break;
            }
            mask >>= 1;
        }
    }
}

fn printEventInfo(entry: ?*FilterEntry, buf: [*c]u8) callconv(.c) void {
    const filter = entry orelse return;
    if (buf == null) return;
    const e = filter.entry;
    printStr("Event severity", description(severities, e.severity));
    const t = e.event_trigger;
    printStr("Event class", if (t == 1) "Threshold" else if (t > 0x6f) "OEM" else "Discrete");
    const offmask: u16 = (@as(u16, e.event_data_1_offset_mask[1]) << 8) | e.event_data_1_offset_mask[0];
    formatTrigger(t, offmask, buf);
    printStr("Event trigger(s)", buf);
}

fn printFilterEntry(entry: *FilterEntry) void {
    var buf: [128]u8 = @splat(0);
    printDec("PEF Filter Table entry", entry.data1);
    const enabled = entry.entry.config & 0x80 != 0;
    const status: [*:0]const u8 = if (entry.entry.config & 0x60 == 0x40)
        (if (enabled) "enabled, pre-configured" else "disabled, pre-configured")
    else if (entry.entry.config & 0x60 == 0)
        (if (enabled) "enabled, configurable" else "disabled, configurable")
    else
        (if (enabled) "enabled, reserved" else "disabled, reserved");
    printStr("Status", status);
    if (!enabled) return;
    printStr("Sensor type", description(sensors, entry.entry.sensor_type));
    if (entry.entry.sensor_number == 0xff) {
        printStr("Sensor number", "Any");
    } else printDec("Sensor number", entry.entry.sensor_number);
    printEventInfo(entry, &buf);
    printStr("Action", description(actions, entry.entry.action));
    if (entry.entry.action & 1 != 0) printInt("Policy set", entry.entry.policy_number & 0x0f);
}

fn listFilters(intf: *Intf) c_int {
    var cap = std.mem.zeroes(Capabilities);
    if (!evaluate(getCapabilities(intf, &cap))) return -1;
    if (cap.event_filter_count == 0) {
        c.lprintf(log.Level.err, "PEF Event Filtering isn't supported.");
        return -1;
    }
    // C's uint8_t loop wraps at 255; use usize so the valid maximum terminates.
    for (1..@as(usize, cap.event_filter_count) + 1) |index| {
        first_field = true;
        var entry = std.mem.zeroes(FilterEntry);
        if (!evaluate(getFilterEntry(intf, @intCast(index), &entry))) {
            c.lprintf(log.Level.err, "Failed to get PEF Event Filter Entry %i.", @as(c_int, @intCast(index)));
            continue;
        }
        printFilterEntry(&entry);
        _ = c.printf("\n");
    }
    return 0;
}

fn filterEnable(intf: *Intf, enable: bool, id: u8) c_int {
    var size: u8 = 0;
    if (!evaluate(getTableSize(intf, 5, &size))) return -1;
    if (size == 0) {
        c.lprintf(log.Level.err, "PEF Filter isn't supported.");
        return -1;
    }
    if (id > size) {
        c.lprintf(log.Level.err, "PEF Filter ID out of range. Valid range is (1..%d).", @as(c_int, size));
        return -1;
    }
    var cfg = std.mem.zeroes(FilterCfg);
    if (!evaluate(setFilterCfg(intf, id, &cfg))) return -1;
    cfg.cfg = if (enable) cfg.cfg | 0x80 else cfg.cfg & 0x7f;
    if (!evaluate(setFilterCfg(intf, id, &cfg))) {
        c.lprintf(log.Level.err, "Failed to %s PEF Filter ID %d.", @as([*:0]const u8, if (enable) "enable" else "disable"), @as(c_int, id));
        return -1;
    }
    _ = c.printf("PEF Filter ID %u is %s now.\n", @as(c_uint, id), @as([*:0]const u8, if (enable) "enabled" else "disabled"));
    return 0;
}

fn retrieve(intf: *Intf, netfn: u6, cmd: u8, selector: *const [4]u8, label: [*:0]const u8, min: usize) ?*Response {
    return exchange(intf, netfn, cmd, selector, label, min) orelse {
        c.lprintf(log.Level.err, " **Error retrieving %s", label);
        return null;
    };
}

fn oemLanDestination(intf: *Intf, dest: u8) void {
    if (c.ipmi_get_oem(cIntf(intf)) != c.IPMI_OEM_DELL) return;
    var data: [32]u8 = @splat(0);
    if (c.ipmi_mc_getsysinfo(cIntf(intf), c.IPMI_SYSINFO_DELL_IPV6_COUNT, 0, 0, 4, &data) != 0 or dest > data[0]) return;
    printStr("Alert destination type", "xxx");
    printStr("PET Community", "xxx");
    printDec("ACK timeout/retry (secs)", 0);
    printDec("Retries", 0);

    data = @splat(0);
    if (c.ipmi_mc_getsysinfo(cIntf(intf), c.IPMI_SYSINFO_DELL_IPV6_DESTADDR, 0, dest, 19, &data) != 0) return;
    var address: [128]u8 = @splat(0);
    var length: usize = data[4];
    if (length >= address.len) {
        c.lprintf(log.Level.err, "Unexpected data length received.");
        return;
    }
    const initial = @min(length, @as(usize, c.IPMI_SYSINFO_SET0_SIZE - 3));
    @memcpy(address[0..initial], data[8..][0..initial]);
    var set: usize = 1;
    while (length > 11) : (set += 1) {
        if (set > 255 or set * 11 >= address.len) {
            c.lprintf(log.Level.err, "Unexpected data length received.");
            return;
        }
        if (c.ipmi_mc_getsysinfo(cIntf(intf), c.IPMI_SYSINFO_DELL_IPV6_DESTADDR, @intCast(set), dest, 19, &data) != 0) return;
        const part = @min(length - 11, @as(usize, c.IPMI_SYSINFO_SETN_SIZE - 2));
        if (set * 11 + part >= address.len) {
            c.lprintf(log.Level.err, "Unexpected data length received.");
            return;
        }
        @memcpy(address[set * 11 ..][0..part], data[3..][0..part]);
        length -|= part + 3;
    }
    printStr("IPv6 Address", &address);
}

fn lanDestination(intf: *Intf, ch: u8, dest: u8) void {
    var selector = [4]u8{ ch, 17, 0, 0 };
    _ = retrieve(intf, ipmi.NetFn.transport, 2, &selector, "Alert destination count", 2) orelse return;
    selector[1] = 18;
    selector[2] = dest;
    const dtype = retrieve(intf, ipmi.NetFn.transport, 2, &selector, "Alert destination type", 5) orelse return;
    if (dtype.data[1] != dest) {
        c.lprintf(log.Level.err, " **Error retrieving %s", "Alert destination type");
        return;
    }
    const kind: u8 = dtype.data[2] & 7;
    const timeout = dtype.data[3];
    const retries: u8 = dtype.data[4] & 7;
    printStr("Alert destination type", description(lan_types, kind));
    if (kind == 0) {
        selector[1] = 16;
        selector[2] = 0;
        if (retrieve(intf, ipmi.NetFn.transport, 2, &selector, "PET community", 20)) |rsp| {
            rsp.data[19] = 0;
            printStr("PET Community", @ptrCast(&rsp.data[1]));
        }
    }
    printDec("ACK timeout/retry (secs)", timeout);
    printDec("Retries", retries);
    selector[1] = 19;
    selector[2] = dest;
    const addr = retrieve(intf, ipmi.NetFn.transport, 2, &selector, "Alert destination info", 14) orelse return;
    if (addr.data[1] != dest) {
        c.lprintf(log.Level.err, " **Error retrieving %s", "Alert destination info");
        return;
    }
    var ipbuf: [32]u8 = @splat(0);
    _ = c.sprintf(&ipbuf, "%u.%u.%u.%u", @as(c_uint, addr.data[4]), @as(c_uint, addr.data[5]), @as(c_uint, addr.data[6]), @as(c_uint, addr.data[7]));
    printStr("IP address", &ipbuf);
    printStr("MAC address", c.mac2str(@ptrCast(&addr.data[8])));
}

fn serialDial(intf: *Intf, label: [*:0]const u8, selector: [4]u8) void {
    const count = [4]u8{ 0, 20, 0, 0 };
    const size = exchange(intf, ipmi.NetFn.transport, 0x11, &count, "Dial string count", 2) orelse return;
    if (size.data[1] & 0x0f == 0) return;
    var req = selector;
    req[1] = 21;
    req[3] = 1;
    var string: [97]u8 = @splat(0);
    var offset: usize = 0;
    while (offset < 96) {
        const rsp = retrieve(intf, ipmi.NetFn.transport, 0x11, &req, label, 19) orelse return;
        if (rsp.data[1] != selector[1] or rsp.data[2] != req[3]) {
            c.lprintf(log.Level.err, " **Error retrieving %s", label);
            return;
        }
        @memcpy(string[offset .. offset + 16], rsp.data[3..19]);
        if (std.mem.indexOfScalar(u8, string[offset .. offset + 17], 0) != null) break;
        offset += 16;
        if (offset >= 96) break;
        req[3] +%= 1;
    }
    printStr(label, &string);
}

fn serialTap(intf: *Intf, selector: [4]u8) void {
    const count = [4]u8{ 0, 24, 0, 0 };
    const size = exchange(intf, ipmi.NetFn.transport, 0x11, &count, "Number of TAP accounts", 2) orelse return;
    if (size.data[1] & 0x0f == 0) return;
    var req = selector;
    req[1] = 25;
    const account = retrieve(intf, ipmi.NetFn.transport, 0x11, &req, "TAP account info", 3) orelse return;
    if (account.data[1] != req[2]) {
        c.lprintf(log.Level.err, " **Error retrieving %s", "TAP account info");
        return;
    }
    const dial_id: u8 = account.data[2] >> 4;
    const settings_id: u8 = account.data[2] & 0x0f;
    req[2] = dial_id;
    serialDial(intf, "TAP Dial string", req);
    req[2] = settings_id;
    const settings = retrieve(intf, ipmi.NetFn.transport, 0x11, &req, "TAP service settings", 3) orelse return;
    if (settings.data[1] != req[2]) {
        c.lprintf(log.Level.err, " **Error retrieving %s", "TAP service settings");
        return;
    }
    printStr("TAP confirmation", description(confirmations, settings.data[2]));
}

fn serialDestination(intf: *Intf, ch: u8, dest: u8) void {
    var selector = [4]u8{ ch, 16, 0, 0 };
    const size = retrieve(intf, ipmi.NetFn.transport, 0x11, &selector, "Alert destination count", 2) orelse return;
    const count: u8 = size.data[1] & 0x0f;
    if (dest == 0 or count == 0) return;
    if (dest > count) {
        oemLanDestination(intf, dest - count);
        return;
    }
    selector[1] = 17;
    selector[2] = dest;
    const info = retrieve(intf, ipmi.NetFn.transport, 0x11, &selector, "Alert destination info", 5) orelse return;
    if (info.data[1] != dest) {
        c.lprintf(log.Level.err, " **Error retrieving %s", "Alert destination info");
        return;
    }
    // The C printer interprets the reply at data[0], not data[1]; retain
    // that behavior for valid replies, including its destination/type alias.
    const kind: u8 = info.data[1] & 0x0f;
    printStr("Alert destination type", description(serial_types, kind));
    printDec("ACK timeout (secs)", info.data[2]);
    printDec("Retries", info.data[3] & 0x77);
    if (kind == 0) serialDial(intf, "Serial dial string", selector);
    if (kind == 1) serialTap(intf, selector);
}

fn listPolicies(intf: *Intf) c_int {
    var size: u8 = 0;
    if (!evaluate(getTableSize(intf, 8, &size))) return -1;
    if (size == 0) {
        c.lprintf(log.Level.err, "PEF Alert Policy isn't supported.");
        return -1;
    }
    for (1..@as(usize, size) + 1) |index| {
        first_field = true;
        var entry = std.mem.zeroes(PolicyEntry);
        if (!evaluate(getPolicyEntry(intf, @intCast(index), &entry))) continue;
        printDec("Alert policy table entry", entry.data1 & 0x7f);
        printDec("Policy set", (entry.entry.policy & 0xf0) >> 4);
        printStr("State", if (entry.entry.policy & 8 != 0) "enabled" else "disabled");
        printStr("Policy entry rule", description(policies, entry.entry.policy & 7));
        if (entry.entry.alert_string_key & 0x80 != 0) printStr("Event-specific", "true");
        var channel = std.mem.zeroes(c.struct_channel_info_t);
        channel.channel = (entry.entry.chan_dest & 0xf0) >> 4;
        if (!evaluate(c._ipmi_get_channel_info(cIntf(intf), &channel))) continue;
        printDec("Channel number", channel.channel);
        printStr("Channel medium", description(media, channel.medium));
        const dest: u8 = entry.entry.chan_dest & 0x0f;
        switch (channel.medium) {
            4 => lanDestination(intf, channel.channel, dest),
            5 => serialDestination(intf, channel.channel, dest),
            else => printDec("Destination ID", dest),
        }
        _ = c.printf("\n");
    }
    return 0;
}

fn policyEnable(intf: *Intf, enable: bool, id: u8) c_int {
    var size: u8 = 0;
    if (!evaluate(getTableSize(intf, 8, &size))) return -1;
    if (size == 0) {
        c.lprintf(log.Level.err, "PEF Policy isn't supported.");
        return -1;
    }
    if (id > size) {
        c.lprintf(log.Level.err, "PEF Policy ID out of range. Valid range is (1..%d).", @as(c_int, size));
        return -1;
    }
    var entry = std.mem.zeroes(PolicyEntry);
    if (!evaluate(getPolicyEntry(intf, id, &entry))) return -1;
    entry.entry.policy = if (enable) entry.entry.policy | 8 else entry.entry.policy & 0xf7;
    if (!evaluate(setPolicyEntry(intf, id, &entry))) {
        c.lprintf(log.Level.err, "Failed to %s PEF Policy ID %d.", @as([*:0]const u8, if (enable) "enable" else "disable"), @as(c_int, id));
        return -1;
    }
    _ = c.printf("PEF Policy ID %u is %s now.\n", @as(c_uint, id), @as([*:0]const u8, if (enable) "enabled" else "disabled"));
    return 0;
}

fn getInfo(intf: *Intf) c_int {
    var size: u8 = 0;
    if (!evaluate(getTableSize(intf, 8, &size))) {
        c.lprintf(log.Level.warn, "Failed to get size of PEF Policy Table.");
        size = 0;
    }
    var cap = std.mem.zeroes(Capabilities);
    if (!evaluate(getCapabilities(intf, &cap))) {
        c.lprintf(log.Level.err, "Failed to get PEF Capabilities.");
        return -1;
    }
    print1xd("Version", cap.version);
    printDec("PEF Event Filter count", cap.event_filter_count);
    printDec("PEF Alert Policy Table size", size);
    var sys_guid = std.mem.zeroes(SystemGuid);
    const rc = getSystemGuid(intf, &sys_guid);
    if (rc != 0x80 and !evaluate(rc)) {
        c.lprintf(log.Level.err, "Failed to get PEF System GUID. %i", rc);
        return -1;
    }
    if (sys_guid.data1 == 1) {
        printGuid(&sys_guid.guid);
    } else {
        var guid = std.mem.zeroes(c.ipmi_guid_t);
        if (c._ipmi_mc_get_guid(cIntf(intf), &guid) == 0) {
            printGuid(@ptrCast(&guid));
        }
    }
    flags(actions, 1, cap.actions);
    _ = c.putchar('\n');
    return 0;
}

fn getStatus(intf: *Intf) c_int {
    const rsp = exchange(intf, ipmi.NetFn.se, 0x15, &.{}, "Last S/W processed ID", 10) orelse {
        c.lprintf(log.Level.err, " **Error retrieving %s", "Last S/W processed ID");
        return -1;
    };
    const timestamp = std.mem.readInt(u32, rsp.data[0..4], .little);
    printStr("Last SEL addition", c.ipmi_timestamp_numeric(@intCast(timestamp)));
    print2xd("Last SEL record ID", rsp.data[5], rsp.data[4]);
    print2xd("Last S/W processed ID", rsp.data[7], rsp.data[6]);
    print2xd("Last BMC processed ID", rsp.data[9], rsp.data[8]);
    const control = [3]u8{ 1, 0, 0 };
    const state = exchange(intf, ipmi.NetFn.se, 0x13, &control, "PEF control", 2) orelse {
        c.lprintf(log.Level.err, " **Error retrieving %s", "PEF control");
        return -1;
    };
    flags(controls, 3, state.data[1]);
    const active = [3]u8{ 2, 0, 0 };
    const action = exchange(intf, ipmi.NetFn.se, 0x13, &active, "PEF action", 2) orelse {
        c.lprintf(log.Level.err, " **Error retrieving %s", "PEF action");
        return -1;
    };
    flags(actions, 2, action.data[1]);
    _ = c.putchar('\n');
    return 0;
}

fn filterHelp() callconv(.c) void {
    c.lprintf(log.Level.notice, "usage: pef filter help\n" ++
        "\tpef filter list\n" ++
        "       pef filter enable <id = 1..n>\n" ++
        "       pef filter disable <id = 1..n>\n" ++
        "       pef filter create <id = 1..n> <params>\n" ++
        "       pef filter delete <id = 1..n>");
}

fn policyHelp() callconv(.c) void {
    c.lprintf(log.Level.notice, "usage: pef policy help\n" ++
        "       pef policy list\n" ++
        "       pef policy enable <id = 1..n>\n" ++
        "       pef policy disable <id = 1..n>\n" ++
        "       pef policy create <id = 1..n> <params>\n" ++
        "       pef policy delete <id = 1..n>");
}

fn pefHelp() callconv(.c) void {
    c.lprintf(log.Level.notice, "usage: pef help\n" ++
        "       pef capabilities\n" ++
        "       pef event <params>\n" ++
        "       pef filter list\n" ++
        "       pef filter enable <id = 1..n>\n" ++
        "       pef filter disable <id = 1..n>\n" ++
        "       pef filter create <id = 1..n> <params>\n" ++
        "       pef filter delete <id = 1..n>\n" ++
        "       pef info\n" ++
        "       pef policy list\n" ++
        "       pef policy enable <id = 1..n>\n" ++
        "       pef policy disable <id = 1..n>\n" ++
        "       pef policy create <id = 1..n> <params>\n" ++
        "       pef policy delete <id = 1..n>\n" ++
        "       pef pet ack <params>\n" ++
        "       pef status\n" ++
        "       pef timer get\n" ++
        "       pef timer set <0x00-0xFF>");
}

fn arg(argv: [*c][*c]u8, index: usize) [*:0]const u8 {
    return @ptrCast(argv[index]);
}

fn filterMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc < 1 or argv == null) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        filterHelp();
        return -1;
    }
    const sub = arg(argv, 0);
    if (eql(sub, "help")) {
        filterHelp();
        return 0;
    }
    if (eql(sub, "list")) return listFilters(intf);
    if (eql(sub, "enable") or eql(sub, "disable")) {
        if (argc != 2) {
            c.lprintf(log.Level.err, "Not enough arguments given.");
            filterHelp();
            return -1;
        }
        var id: u8 = 0;
        if (c.str2uchar(arg(argv, 1), &id) != 0) {
            c.lprintf(log.Level.err, "Invalid PEF Event Filter ID given: %s", arg(argv, 1));
            return -1;
        }
        if (id == 0) {
            c.lprintf(log.Level.err, "PEF Event Filter ID out of range. Valid range is <1..255>.");
            return -1;
        }
        return filterEnable(intf, eql(sub, "enable"), id);
    }
    if (eql(sub, "create") or eql(sub, "delete")) {
        c.lprintf(log.Level.err, "Not implemented.");
        return 1;
    }
    c.lprintf(log.Level.err, "Invalid PEF Filter command: %s", sub);
    filterHelp();
    return 1;
}

fn policyMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc < 1 or argv == null) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        policyHelp();
        return -1;
    }
    const sub = arg(argv, 0);
    if (eql(sub, "help")) {
        policyHelp();
        return 0;
    }
    if (eql(sub, "list")) return listPolicies(intf);
    if (eql(sub, "enable") or eql(sub, "disable")) {
        if (argc != 2) {
            c.lprintf(log.Level.err, "Not enough arguments given.");
            policyHelp();
            return -1;
        }
        var id: u8 = 0;
        if (c.str2uchar(arg(argv, 1), &id) != 0) {
            c.lprintf(log.Level.err, "Invalid PEF Policy ID given: %s", arg(argv, 1));
            return -1;
        }
        if (id == 0 or id > 127) {
            c.lprintf(log.Level.err, "PEF Policy ID out of range. Valid range is <1..127>.");
            return -1;
        }
        return policyEnable(intf, eql(sub, "enable"), id);
    }
    if (eql(sub, "create") or eql(sub, "delete")) {
        c.lprintf(log.Level.err, "Not implemented.");
        return 1;
    }
    c.lprintf(log.Level.err, "Invalid PEF Policy command: %s", sub);
    policyHelp();
    return 1;
}

fn pefMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc < 1 or argv == null) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        pefHelp();
        return -1;
    }
    const sub = arg(argv, 0);
    if (eql(sub, "help")) {
        pefHelp();
        return 0;
    }
    if (eql(sub, "filter")) return filterMain(intf, argc - 1, argv + 1);
    if (eql(sub, "policy")) return policyMain(intf, argc - 1, argv + 1);
    if (eql(sub, "info")) return getInfo(intf);
    if (eql(sub, "status")) return getStatus(intf);
    if (eql(sub, "capabilities") or eql(sub, "event") or eql(sub, "pet") or eql(sub, "timer")) {
        c.lprintf(log.Level.err, "Not implemented.");
        return 1;
    }
    c.lprintf(log.Level.err, "Invalid PEF command: '%s'\n", sub);
    return -1;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(pefMain), @TypeOf(c.ipmi_pef_main));
    abi.assertCallSignature(@TypeOf(pefHelp), @TypeOf(c.ipmi_pef2_help));
    abi.assertCallSignature(@TypeOf(filterHelp), @TypeOf(c.ipmi_pef2_filter_help));
    abi.assertCallSignature(@TypeOf(policyHelp), @TypeOf(c.ipmi_pef2_policy_help));
    abi.assertCallSignature(@TypeOf(filterMain), @TypeOf(c.ipmi_pef2_filter));
    abi.assertCallSignature(@TypeOf(policyMain), @TypeOf(c.ipmi_pef2_policy));
    abi.assertCallSignature(@TypeOf(getCapabilities), @TypeOf(c._ipmi_get_pef_capabilities));
    abi.assertCallSignature(@TypeOf(getFilterCfg), @TypeOf(c._ipmi_get_pef_filter_entry_cfg));
    abi.assertCallSignature(@TypeOf(getSystemGuid), @TypeOf(c._ipmi_get_pef_system_guid));
    abi.assertCallSignature(@TypeOf(printEventInfo), @TypeOf(c.ipmi_pef_print_event_info));
    abi.assertCallSignature(@TypeOf(bitDesc), @TypeOf(c.ipmi_pef_bit_desc));
    abi.assertCallSignature(@TypeOf(printFlags), @TypeOf(c.ipmi_pef_print_flags));
    abi.assertCallSignature(@TypeOf(printDec), @TypeOf(c.ipmi_pef_print_dec));
    abi.assertCallSignature(@TypeOf(printInt), @TypeOf(c.ipmi_pef_print_int));
    abi.assertCallSignature(@TypeOf(printHex), @TypeOf(c.ipmi_pef_print_hex));
    abi.assertCallSignature(@TypeOf(printStr), @TypeOf(c.ipmi_pef_print_str));
    abi.assertCallSignature(@TypeOf(print2xd), @TypeOf(c.ipmi_pef_print_2xd));
    abi.assertCallSignature(@TypeOf(print1xd), @TypeOf(c.ipmi_pef_print_1xd));

    @export(&pefMain, .{ .name = "ipmi_pef_main" });
    @export(&pefHelp, .{ .name = "ipmi_pef2_help" });
    @export(&filterHelp, .{ .name = "ipmi_pef2_filter_help" });
    @export(&policyHelp, .{ .name = "ipmi_pef2_policy_help" });
    @export(&filterMain, .{ .name = "ipmi_pef2_filter" });
    @export(&policyMain, .{ .name = "ipmi_pef2_policy" });
    @export(&getCapabilities, .{ .name = "_ipmi_get_pef_capabilities" });
    @export(&getFilterCfg, .{ .name = "_ipmi_get_pef_filter_entry_cfg" });
    @export(&getSystemGuid, .{ .name = "_ipmi_get_pef_system_guid" });
    @export(&printEventInfo, .{ .name = "ipmi_pef_print_event_info" });
    @export(&bitDesc, .{ .name = "ipmi_pef_bit_desc" });
    @export(&printFlags, .{ .name = "ipmi_pef_print_flags" });
    @export(&printDec, .{ .name = "ipmi_pef_print_dec" });
    @export(&printInt, .{ .name = "ipmi_pef_print_int" });
    @export(&printHex, .{ .name = "ipmi_pef_print_hex" });
    @export(&printStr, .{ .name = "ipmi_pef_print_str" });
    @export(&print2xd, .{ .name = "ipmi_pef_print_2xd" });
    @export(&print1xd, .{ .name = "ipmi_pef_print_1xd" });
}

test "PEF rejects incomplete responses without reading missing fields" {
    var response = std.mem.zeroes(Response);
    response.data_len = 1;
    try std.testing.expectEqual(@as(c_int, -2), val(&response, 2));
    try std.testing.expectEqual(@as(c_int, -2), val(&response, 10));
    try std.testing.expectEqual(@as(c_int, -1), val(null, 2));
    response.ccode = 0xd4;
    try std.testing.expectEqual(@as(c_int, 0xd4), val(&response, 2));
}

test "PEF malformed trigger text stays within the caller's 128-byte buffer" {
    var output = struct {
        bytes: [128]u8 = @splat(0),
        canary: u32 = 0xaabbccdd,
    }{};
    formatTrigger(13, 0x0fff, &output.bytes);
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), output.canary);
    try std.testing.expectEqual(@as(u8, 0), output.bytes[127]);
}

test "PEF list and any descriptions distinguish exact values from masks" {
    try std.testing.expectEqualStrings("Temperature", std.mem.span(description(sensors, 1)));
    try std.testing.expectEqualStrings("None", std.mem.span(description(sensors, 0xfe)));
    try std.testing.expectEqualStrings("Non-recoverable", std.mem.span(description(severities, 0x28)));
}

test "PEF action descriptions combine only matching bits" {
    try std.testing.expectEqualStrings("Alert,Diagnostic-interrupt", std.mem.span(description(actions, 0x21)));
    try std.testing.expectEqualStrings("None", std.mem.span(description(actions, 0)));
}

test "PEF trigger descriptions handle sentinel and boundary values" {
    var buf: [128]u8 = @splat(0);
    formatTrigger(0xff, 0, &buf);
    try std.testing.expectEqualStrings("Any", std.mem.sliceTo(&buf, 0));
    formatTrigger(0, 0, &buf);
    try std.testing.expectEqualStrings("Unspecified", std.mem.sliceTo(&buf, 0));
    formatTrigger(0x6f, 0, &buf);
    try std.testing.expectEqualStrings("Sensor-specific", std.mem.sliceTo(&buf, 0));
    formatTrigger(0x70, 0, &buf);
    try std.testing.expectEqualStrings("OEM", std.mem.sliceTo(&buf, 0));
    formatTrigger(1, 1, &buf);
    try std.testing.expectEqualStrings("(0x01/0x0001),<LNC", std.mem.sliceTo(&buf, 0));
}
