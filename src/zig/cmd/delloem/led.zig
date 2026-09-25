const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const log = common.log;

pub fn usage() void {
    common.notice(&.{
        "",                                                           "   setled <b:d.f> <state..>",
        "      Set backplane LED state",                              "      b:d.f = PCI Bus:Device.Function of drive (lspci format)",
        "      state = present|online|hotspare|identify|rebuilding|", "              fault|predict|critical|failed",
        "",
    });
}

fn driveMap(intf: *Intf, bus: c_int, dev: c_int, func: c_int, bay: *u8, slot: *u8) c_int {
    const data = [8]u8{ 1, 7, 6, 0, 0, 0, @truncate(@as(c_uint, @bitCast(bus))), @truncate(@as(c_uint, @bitCast((dev << 3) + func))) };
    const rsp = common.send(intf, 0x30, 0xd5, &data) orelse {
        c.lprintf(log.Level.err, "Error issuing getdrivemap command.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error issuing getdrivemap command: %s", common.cc(rsp.ccode));
        return -1;
    }
    const body = common.bytes(rsp, 9) orelse return common.short("getdrivemap");
    bay.* = body[7];
    slot.* = body[8];
    if (bay.* == 0xff or slot.* == 0xff) {
        c.lprintf(log.Level.err, "Error could not get drive bay:slot mapping");
        return -1;
    }
    return 0;
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    const addr = common.arg(argv, argc, 1);
    if (addr == null or common.eq(addr, "help")) {
        usage();
        return 0;
    }
    const support = [10]u8{ 1, 0, 8, 0, 0, 0, 0, 0, 0, 0 };
    const rsp = common.send(intf, 0x30, 0xd5, &support) orelse {
        c.lprintf(log.Level.err, "'setled' is not supported on this system.");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "'setled' is not supported on this system.");
        return -1;
    }
    var b: c_int = 0;
    var d: c_int = 0;
    var f: c_int = 0;
    var bay: u8 = 0xff;
    var slot: u8 = 0xff;
    if (c.sscanf(addr.?, "%*x:%x:%x.%x", &b, &d, &f) == 3) {
        // Preserve the double lookup on domain-qualified BDFs.
        _ = driveMap(intf, b, d, f, &bay, &slot);
    } else if (c.sscanf(addr.?, "%x:%x.%x", &b, &d, &f) != 3) {
        usage();
        return -1;
    }
    if (b < 0 or b > 255 or d < 0 or d > 31 or f < 0 or f > 7) {
        c.lprintf(log.Level.err, "Drive PCI address is out of range");
        return -1;
    }
    var state: u16 = 0;
    var index: usize = 2;
    while (common.arg(argv, argc, index)) |token| : (index += 1) {
        const names = [_][]const u8{
            "present", "online",  "hotspare", "identify", "rebuilding",
            "fault",   "predict", "critical", "failed",
        };
        const bits = [_]u4{ 0, 1, 2, 3, 4, 5, 6, 9, 10 };
        for (names, bits) |name, bit| {
            if (common.eq(token, name)) state |= @as(u16, 1) << bit;
        }
    }
    if (driveMap(intf, b, d, f, &bay, &slot) != 0) return -1;
    var data = [_]u8{0} ** 20;
    data[1] = 4;
    data[2] = 14;
    data[6] = 14;
    data[8] = bay;
    data[9] = slot;
    common.put16(data[10..12], state);
    const set_rsp = common.send(intf, 0x30, 0xd5, &data) orelse {
        c.lprintf(log.Level.err, "Error issuing setled command.");
        return -1;
    };
    if (set_rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error issuing setled command: %s", common.cc(set_rsp.ccode));
        return -1;
    }
    return 0;
}

test "SES bits never escape the 16-bit status word" {
    const std = @import("std");
    var value = [_]u8{0} ** 20;
    common.put16(value[10..12], @as(u16, 1) << 10);
    try std.testing.expectEqual(@as(u8, 4), value[11]);
    try std.testing.expectEqual(@as(u8, 0), value[12]);
}
