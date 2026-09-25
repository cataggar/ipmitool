const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const Response = common.Response;
const log = common.log;

fn usage() void {
    common.notice(&.{
        "",                                                                    "   powermonitor",                                       "      Shows power tracking statistics ",    "",
        "   powermonitor clear cumulativepower",                               "      Reset cumulative power reading",                  "",                                          "   powermonitor clear peakpower",
        "      Reset peak power reading",                                      "",                                                      "   powermonitor powerconsumption",          "      Displays power consumption in <watt|btuphr>",
        "",                                                                    "   powermonitor powerconsumptionhistory <watt|btuphr>", "      Displays power consumption history ", "",
        "   powermonitor getpowerbudget",                                      "      Displays power cap in <watt|btuphr>",             "",                                          "   powermonitor setpowerbudget <val><watt|btuphr|percent>",
        "      Allows user to set the  power cap in <watt|BTU/hr|percentage>", "",                                                      "   powermonitor enablepowercap ",           "      To enable set power cap",
        "",                                                                    "   powermonitor disablepowercap ",                      "      To disable set power cap",            "",
    });
}

fn btu(watts: u32) u64 {
    return @intFromFloat(@as(f64, 3.413) * @as(f64, @floatFromInt(watts)));
}

fn fromBtu(value: u64) u32 {
    return @intFromFloat(@as(f64, @floatFromInt(value)) / 3.413);
}

fn status(intf: *Intf) c_int {
    const time_rsp = common.send(intf, 0x0a, 0x48, &.{}) orelse {
        log.print(log.Level.err, "Error getting BMC time info.", .{});
        return -1;
    };
    if (time_rsp.ccode != 0) {
        log.print(log.Level.err, "Error getting power management information, return code %x", .{@as(c_int, time_rsp.ccode)});
        return -1;
    }
    const t = common.bytes(time_rsp, 4) orelse return common.short("BMC time");
    const now = common.le32(t);
    const rsp = common.send(intf, 0x30, 0x9c, &.{ 7, 1 }) orelse {
        log.print(log.Level.err, "Error getting power management information.", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode == 0xc1 or rsp.ccode == 0xcb) {
        log.print(log.Level.err, "Error getting power management information: Command not supported on this system.", .{});
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error getting power management information, return code %x", .{@as(c_int, rsp.ccode)});
        return -1;
    }
    const data = common.bytes(rsp, 24) orelse return common.short("power management");
    const energy = common.le32(data[4..8]);
    const amps = common.le16(data[16..18]);
    _ = c.printf("Power Tracking Statistics\n");
    _ = c.printf("Statistic      : Cumulative Energy Consumption\n");
    _ = c.printf("Start Time     : %s", c.ipmi_timestamp_numeric(common.le32(data[0..4])));
    _ = c.printf("Finish Time    : %s", c.ipmi_timestamp_numeric(now));
    _ = c.printf("Reading        : %d.%d kWh\n\n", @as(c_int, @intCast(energy / 1000)), @as(c_int, @intCast(((energy % 1000) + 50) / 100)));
    _ = c.printf("Statistic      : System Peak Power\n");
    _ = c.printf("Start Time     : %s", c.ipmi_timestamp_numeric(common.le32(data[8..12])));
    _ = c.printf("Peak Time      : %s", c.ipmi_timestamp_numeric(common.le32(data[18..22])));
    _ = c.printf("Peak Reading   : %d W\n\n", @as(c_int, common.le16(data[22..24])));
    _ = c.printf("Statistic      : System Peak Amperage\n");
    _ = c.printf("Start Time     : %s", c.ipmi_timestamp_numeric(common.le32(data[8..12])));
    _ = c.printf("Peak Time      : %s", c.ipmi_timestamp_numeric(common.le32(data[12..16])));
    _ = c.printf("Peak Reading   : %d.%d A\n", @as(c_int, amps / 10), @as(c_int, amps % 10));
    return 0;
}

fn clear(intf: *Intf, peak: bool) c_int {
    const rsp = common.send(intf, 0x30, 0x9d, &.{ 7, 1, if (peak) 2 else 1 }) orelse {
        log.print(log.Level.err, "Error clearing power values.", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode == 0xc1) {
        log.print(log.Level.err, "Error clearing power values, command not supported on this system.", .{});
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error clearing power values: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    return 0;
}

fn capStatus(intf: *Intf) c_int {
    const rsp = common.send(intf, 0x30, 0xba, &.{ 1, 0xff }) orelse {
        log.print(log.Level.err, "Error getting powercap status", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error getting powercap statusr: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    const data = common.bytes(rsp, 1) orelse return common.short("powercap status");
    if (data[0] & 2 != 0) common.power_cap_settable = 1;
    if (data[0] & 1 != 0) common.power_cap_enabled = 1;
    return 0;
}

fn toggle(intf: *Intf, enable: bool) c_int {
    if (capStatus(intf) != 0) return -1;
    if (common.power_cap_settable == 0) {
        log.print(log.Level.err, "Can not set powercap on this system", .{});
        return -1;
    }
    const rsp = common.send(intf, 0x30, 0xba, &.{ 0, if (enable) 1 else 0 }) orelse {
        log.print(log.Level.err, "Error setting powercap status", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error setting powercap statusr: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    return 0;
}

fn getBudgetData(intf: *Intf, data: *[16]u8, setting: bool) c_int {
    const rc = common.getSys(intf, 0xea, 0, data);
    if (rc < 0) {
        log.print(log.Level.err, "Error getting power cap.", .{});
        return -1;
    }
    if (common.license(@intCast(rc))) return -1;
    if (rc == 0xc1 or (!setting and rc == 0xcb)) {
        log.print(
            log.Level.err,
            if (setting)
                "Error getting power cap, command not supported on this system."
            else
                "Error getting power cap: Command not supported on this system.",
            .{},
        );
        return -1;
    }
    if (rc != 0) {
        log.print(log.Level.err, "Error getting power cap: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    if (c.verbose > 1) {
        // Preserve C's extra (12th) byte in the dump.
        _ = c.printf("power cap  Data               :%x %x %x %x %x %x %x %x %x %x ", @as(c_int, data[1]), @as(c_int, data[2]), @as(c_int, data[3]), @as(c_int, data[4]), @as(c_int, data[5]), @as(c_int, data[6]), @as(c_int, data[7]), @as(c_int, data[8]), @as(c_int, data[9]), @as(c_int, data[10]), @as(c_int, data[11]));
    }
    return 0;
}

fn getBudget(intf: *Intf, unit: u8) c_int {
    var data: [16]u8 = undefined;
    if (getBudgetData(intf, &data, false) != 0) return -1;
    const maximum = common.le16(data[4..6]);
    const minimum = common.le16(data[6..8]);
    const cap = common.le16(data[1..3]);
    if (unit == 1) {
        _ = c.printf("Maximum power: %lld  BTU/hr\n", @as(i64, @intCast(btu(maximum))));
        _ = c.printf("Minimum power: %lld  BTU/hr\n", @as(i64, @intCast(btu(minimum))));
        _ = c.printf("Power cap    : %lld  BTU/hr\n", @as(i64, @intCast(btu(cap))));
    } else {
        _ = c.printf("Maximum power: %d Watt\n", @as(c_int, maximum));
        _ = c.printf("Minimum power: %d Watt\n", @as(c_int, minimum));
        _ = c.printf("Power cap    : %d Watt\n", @as(c_int, cap));
    }
    return 0;
}

fn setBudget(intf: *Intf, unit: u8, input: c_int) c_int {
    if (capStatus(intf) != 0) return -1;
    if (common.power_cap_settable == 0) {
        log.print(log.Level.err, "Can not set powercap on this system", .{});
        return -1;
    }
    if (common.power_cap_enabled == 0) {
        log.print(log.Level.err, "Power cap set feature is not enabled", .{});
        return -1;
    }
    var cap: [16]u8 = undefined;
    if (getBudgetData(intf, &cap, true) != 0) return -1;
    const maximum = common.le16(cap[4..6]);
    const minimum = common.le16(cap[6..8]);
    var request = [_]u8{0} ** 13;
    request[0] = 0xea;
    common.put16(request[1..3], @truncate(@as(u32, @bitCast(input))));
    request[3] = unit;
    @memcpy(request[4..8], cap[4..8]);
    request[8] = cap[8];
    @memcpy(request[9..11], cap[10..12]);
    request[11] = cap[12];
    var watts: i64 = input;
    if (unit == 1) {
        if (input < 0) return common.short("power cap value");
        watts = fromBtu(@intCast(input));
    } else if (unit == 3) {
        if (input < 0 or input > 100) {
            log.print(log.Level.err, "Cap value is out of boundary condition it should be between 0  - 100", .{});
            return -1;
        }
        watts = @divTrunc(@as(i64, input) * (@as(i64, maximum) - minimum), 100) + minimum;
        log.print(log.Level.err, "Cap value in percentage is  %d ", .{@as(c_int, @intCast(watts))});
        common.put16(request[1..3], @intCast(watts));
        request[3] = 0;
    }
    if (watts < minimum or watts > maximum) {
        if (unit == 1) {
            log.print(log.Level.err, "Cap value is out of boundary condition it should be between %d", .{@as(c_int, @bitCast(@as(u32, @truncate(btu(minimum)))))});
            log.print(log.Level.err, " -%d", .{@as(c_int, @bitCast(@as(u32, @truncate(btu(maximum)))))});
        } else if (unit == 0) {
            log.print(log.Level.err, "Cap value is out of boundary condition it should be between %d  - %d", .{ @as(c_int, minimum), @as(c_int, maximum) });
        }
        return -1;
    }
    const rc = common.setSys(intf, &request);
    if (rc < 0) {
        log.print(log.Level.err, "Error setting power cap", .{});
        return -1;
    }
    if (common.license(@intCast(rc))) return -1;
    if (rc != 0) {
        log.print(log.Level.err, "Error setting power cap: %s", .{common.cc(@intCast(rc))});
        return -1;
    }
    if (c.verbose > 1) _ = c.printf("CC for setpowercap :%d ", rc);
    return 0;
}

fn historyData(intf: *Intf, selector: u8, data: []u8) c_int {
    const rc = common.getSys(intf, selector, 0, data);
    const average = selector == 0xeb;
    if (rc < 0) {
        log.print(
            log.Level.err,
            if (average)
                "Error getting average power consumption history data."
            else if (selector == 0xec)
                "Error getting  peak power consumption history data."
            else
                "Error getting  peak power consumption history data .",
            .{},
        );
        return -1;
    }
    if (common.license(@intCast(rc))) return -1;
    if (rc == 0xc1 or rc == 0xcb) {
        log.print(
            log.Level.err,
            if (average)
                "Error getting average power consumption history data: Command not supported on this system."
            else
                "Error getting peak power consumption history data: Command not supported on this system.",
            .{},
        );
        return -1;
    }
    if (rc != 0) {
        log.print(
            log.Level.err,
            if (average)
                "Error getting average power consumption history data: %s"
            else
                "Error getting peak power consumption history data: %s",
            .{common.cc(@intCast(rc))},
        );
        return -1;
    }
    if (c.verbose > 1 and average) {
        _ = c.printf("Average power consumption history data       :%x %x %x %x %x %x %x %x\n\n", @as(c_int, data[0]), @as(c_int, data[1]), @as(c_int, data[2]), @as(c_int, data[3]), @as(c_int, data[4]), @as(c_int, data[5]), @as(c_int, data[6]), @as(c_int, data[7]));
    } else if (c.verbose > 1) {
        _ = c.printf("Peak power consmhistory  Data               : ");
        const count: usize = if (selector == 0xec) 24 else 23;
        for (data[0..count], 0..) |value, i| {
            _ = c.printf("%x", @as(c_int, value));
            if (i == 9) {
                _ = c.printf("\n   ");
            } else if (i + 1 != count) {
                _ = c.printf(" ");
            }
        }
        _ = c.printf("\n\n");
    }
    return 0;
}

fn powerRow(name: [*:0]const u8, data: []const u8, unit: u8, last: bool) void {
    _ = c.printf("%s", name);
    for (0..4) |i| {
        const value: u64 = if (unit == 1) btu(common.le16(data[1 + i * 2 ..][0..2])) else common.le16(data[1 + i * 2 ..][0..2]);
        if (unit == 1) {
            _ = c.printf(switch (i) {
                0 => "%4lld BTU/hr     ",
                1 => "%4lld BTU/hr   ",
                2 => "%4lld BTU/hr  ",
                else => "%4lld BTU/hr\n",
            }, @as(i64, @intCast(value)));
        } else {
            _ = c.printf(switch (i) {
                0 => "%4lld W          ",
                1 => "%4lld W        ",
                2 => "%4lld W       ",
                else => "%4lld W   \n",
            }, @as(i64, @intCast(value)));
        }
    }
    if (last and unit == 0) _ = c.printf("\n");
    if (last and unit == 1) _ = c.printf("\n");
}

fn powerTimes(name: [*:0]const u8, data: []const u8) void {
    _ = c.printf("%s", name);
    const labels = [_][*:0]const u8{ "Last Minute     : %s", "Last Hour       : %s", "Last Day        : %s", "Last Week       : %s" };
    for (labels, 0..) |label, i| _ = c.printf(label, c.ipmi_timestamp_numeric(common.le32(data[9 + i * 4 ..][0..4])));
}

fn history(intf: *Intf, unit: u8) c_int {
    var avg: [9]u8 = undefined;
    var peak: [25]u8 = undefined;
    var min: [25]u8 = undefined;
    if (historyData(intf, 0xeb, &avg) != 0 or historyData(intf, 0xec, &peak) != 0 or historyData(intf, 0xed, &min) != 0) return -1;
    _ = c.printf("Power Consumption History\n\n");
    _ = c.printf("Statistic                   Last Minute     Last Hour     Last Day     Last Week\n\n");
    powerRow("Average Power Consumption  ", &avg, unit, false);
    powerRow("Max Power Consumption      ", &peak, unit, false);
    powerRow("Min Power Consumption      ", &min, unit, true);
    powerTimes("Max Power Time\n", &peak);
    powerTimes("Min Power Time\n", &min);
    return 0;
}

fn headroom(intf: *Intf, unit: u8) c_int {
    const rsp = common.send(intf, 0x30, 0xbb, &.{}) orelse {
        log.print(log.Level.err, "Error getting power headroom status", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode == 0xc1 or rsp.ccode == 0xcb) {
        log.print(log.Level.err, "Error getting power headroom status: Command not supported on this system ", .{});
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error getting power headroom status: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    const data = common.bytes(rsp, 4) orelse return common.short("power headroom");
    @memcpy(&common.power_headroom, data[0..4]);
    if (c.verbose > 1) _ = c.printf("power headroom  Data               : %x %x %x %x ", @as(c_int, data[0]), @as(c_int, data[1]), @as(c_int, data[2]), @as(c_int, data[3]));
    const instant = common.le16(data[0..2]);
    const peak = common.le16(data[2..4]);
    _ = c.printf("Headroom\n");
    _ = c.printf("Statistic                     Reading\n");
    if (unit == 1) {
        _ = c.printf("System Instantaneous Headroom : %lld BTU/hr\n", @as(i64, @intCast(btu(instant))));
        _ = c.printf("System Peak Headroom          : %lld BTU/hr\n", @as(i64, @intCast(btu(peak))));
    } else {
        _ = c.printf("System Instantaneous Headroom : %d W\n", @as(c_int, instant));
        _ = c.printf("System Peak Headroom          : %d W\n", @as(c_int, peak));
    }
    return 0;
}

// The packed SDR list is not equivalent to translate-c's naturally aligned
// version: `record` is at offset 21, not 24.  Only the borrowed pointer to
// the full sensor is used; the SDR module owns and frees the list.
const SdrList = extern struct {
    id: u16 align(1),
    version: u8,
    type: u8,
    length: u8,
    raw: ?[*]u8 align(1),
    next: ?*SdrList align(1),
    record: ?[*]const u8 align(1),
};

fn sensorReading(value: f64) ?c_int {
    if (!std.math.isFinite(value) or value > std.math.maxInt(c_int) or value < std.math.minInt(c_int)) return null;
    return @intFromFloat(value);
}

fn sensorBtu(watts: c_int) c_int {
    return @bitCast(@as(u32, @truncate(btu(@bitCast(watts)))));
}

fn consumption(intf: *Intf, unit: u8) c_int {
    _ = c.printf("\nPower consumption information\n");
    const list_ptr = c.ipmi_sdr_find_sdr_byid(@ptrCast(intf), @constCast("System Level")) orelse {
        log.print(log.Level.err, "Error : Can not access the System Level sensor data", .{});
        return -1;
    };
    const sdr: *const SdrList = @ptrCast(@alignCast(list_ptr));
    const record = sdr.record orelse return common.short("System Level sensor");
    if (sdr.type != 1) return common.short("System Level sensor");
    const sensor = record[2];
    var reading: u8 = 0;
    const sensor_rsp = common.send(intf, 0x04, 0x2d, &.{sensor});
    if (sensor_rsp) |rsp| {
        if (rsp.ccode == 0) {
            const data = common.bytes(rsp, 4) orelse return common.short("sensor reading");
            reading = data[0];
        }
    }
    const threshold_rsp: ?*Response = @ptrCast(c.ipmi_sdr_get_sensor_thresholds(@ptrCast(intf), sensor, record[0], record[1] & 3, record[1] >> 4));
    const thresholds = threshold_rsp orelse {
        log.print(log.Level.err, "Error : Can not access the System Level sensor data", .{});
        return -1;
    };
    if (thresholds.ccode != 0) {
        log.print(log.Level.err, "Error : Can not access the System Level sensor data", .{});
        return -1;
    }
    const data = common.bytes(thresholds, 6) orelse return common.short("sensor thresholds");
    const full: *c.struct_sdr_record_full_sensor = @ptrCast(@constCast(record));
    var values = [_]c_int{
        sensorReading(c.sdr_convert_sensor_reading(full, reading)) orelse return common.short("sensor reading"),
        sensorReading(c.sdr_convert_sensor_reading(full, data[4])) orelse return common.short("sensor threshold"),
        sensorReading(c.sdr_convert_sensor_reading(full, data[5])) orelse return common.short("sensor threshold"),
    };
    _ = c.printf("System Board System Level\n");
    if (unit == 1) {
        for (&values) |*v| v.* = sensorBtu(v.*);
        _ = c.printf("Reading                        : %d BTU/hr\n", values[0]);
        _ = c.printf("Warning threshold      : %d BTU/hr\n", values[1]);
        _ = c.printf("Failure threshold      : %d BTU/hr\n", values[2]);
    } else {
        _ = c.printf("Reading                        : %d W \n", values[0]);
        _ = c.printf("Warning threshold      : %d W \n", values[1]);
        _ = c.printf("Failure threshold      : %d W \n", values[2]);
    }
    const rsp = common.send(intf, 0x30, 0xb3, &.{ 0x0a, 0 }) orelse {
        log.print(log.Level.err, "Error getting instantaneous power consumption data .", .{});
        return -1;
    };
    if (common.license(rsp.ccode)) return -1;
    if (rsp.ccode == 0xc1 or rsp.ccode == 0xcb) {
        log.print(log.Level.err, "Error getting instantaneous power consumption data: Command not supported on this system.", .{});
        return -1;
    }
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error getting instantaneous power consumption data: %s", .{common.cc(rsp.ccode)});
        return -1;
    }
    const instant = common.bytes(rsp, 7) orelse return common.short("instantaneous power");
    const amps = common.le16(instant[2..4]);
    _ = c.printf("\nAmperage value: %d.%d A \n", @as(c_int, amps / 10), @as(c_int, amps % 10));
    return headroom(intf, unit);
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    const command = common.arg(argv, argc, 1);
    if (common.eq(command, "help")) {
        usage();
        return 0;
    }
    common.validator(intf);
    if (command == null or common.eq(command, "status")) return status(intf);
    if (common.eq(command, "clear")) {
        const which = common.arg(argv, argc, 2);
        if (common.eq(which, "peakpower")) return clear(intf, true);
        if (common.eq(which, "cumulativepower")) return clear(intf, false);
        usage();
        return -1;
    }
    if (common.eq(command, "enablepowercap") or common.eq(command, "disablepowercap")) {
        _ = toggle(intf, common.eq(command, "enablepowercap"));
        return 0; // The C command dispatcher discards the toggle's return code.
    }
    if (common.eq(command, "setpowerbudget")) {
        const amount = common.arg(argv, argc, 2) orelse {
            usage();
            return -1;
        };
        if (std.mem.indexOfScalar(u8, std.mem.span(amount), '.') != null) {
            log.print(log.Level.err, "Cap value in Watts, Btu/hr or percent should be whole number", .{});
            return -1;
        }
        var value: c_int = 0;
        if (c.str2int(amount, &value) != 0) {
            log.print(log.Level.err, "Given capacity value '%s' is invalid.", .{amount});
            return -1;
        }
        const choice = common.arg(argv, argc, 3);
        if (choice == null) {
            usage();
            return 0;
        }
        if (common.eq(choice, "watt")) return setBudget(intf, 0, value);
        if (common.eq(choice, "btuphr")) return setBudget(intf, 1, value);
        if (common.eq(choice, "percent")) return setBudget(intf, 3, value);
        usage();
        return -1;
    }
    if (common.eq(command, "getpowerbudget") or common.eq(command, "powerconsumptionhistory") or common.eq(command, "powerconsumption")) {
        const choice = common.arg(argv, argc, 2);
        if (choice != null and !common.eq(choice, "watt") and !common.eq(choice, "btuphr")) {
            usage();
            return -1;
        }
        const unit: u8 = if (common.eq(choice, "btuphr")) 1 else 0;
        if (common.eq(command, "getpowerbudget")) return getBudget(intf, unit);
        if (common.eq(command, "powerconsumptionhistory")) return history(intf, unit);
        return consumption(intf, unit);
    }
    usage();
    return -1;
}

test "Dell power conversion preserves truncated BTU precision" {
    try std.testing.expectEqual(@as(u64, 341), btu(100));
    try std.testing.expectEqual(@as(u32, 99), fromBtu(341));
}
