const std = @import("std");
const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const log = common.log;

pub const codes = [_]c.struct_valstr{
    .{ .val = 0, .str = "SUCCESS" },
    .{ .val = 1, .str = "NO_SD_CARD" },
    .{ .val = 0x63, .str = "UNKNOWN_ERROR" },
    .{ .val = 0, .str = null },
};

fn usage() void {
    common.notice(&.{
        "", "   vFlash info Card", "      Shows Extended SD Card information", "",
    });
}

fn yesNo(value: bool) [*:0]const u8 {
    return if (value) "Yes" else "No";
}

fn card(intf: *Intf) c_int {
    const rsp = common.send(intf, 0x30, 0xa4, &.{ 0, 0 }) orelse {
        c.lprintf(log.Level.err, "Error in getting SD Card Extended Information");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error in getting SD Card Extended Information (%s)", common.cc(rsp.ccode));
        return -1;
    }
    const code = common.bytes(rsp, 1) orelse return common.short("SD Card Extended Information");
    if (common.idrac_12_13 != 0 and code[0] == 0x33) {
        c.lprintf(log.Level.err, "FM001 : A required license is missing or expired");
        return -1;
    }
    if (code[0] != 0) {
        c.lprintf(log.Level.err, "Error in getting SD Card Extended Information (%s)", c.val2str(code[0], &codes));
        return -1;
    }
    const data = common.bytes(rsp, 12) orelse return common.short("SD Card Extended Information");
    const flags = data[1];
    if (flags & 4 == 0) {
        c.lprintf(log.Level.err, "vFlash SD card is unavailable, please insert the card of");
        c.lprintf(log.Level.err, "size 256MB or greater");
        return -1;
    }
    const health: [*:0]const u8 = switch (flags & 3) {
        0 => "OK",
        1 => "Warning",
        2 => "Critical",
        else => "Undefined",
    };
    _ = c.printf("vFlash SD Card Properties\n");
    _ = c.printf("SD Card size       : %8dMB\n", @as(c_int, @bitCast(common.le32(data[2..6]))));
    _ = c.printf("Available size     : %8dMB\n", @as(c_int, @bitCast(common.le32(data[6..10]))));
    _ = c.printf("Initialized        : %10s\n", yesNo(flags & 0x80 != 0));
    _ = c.printf("Licensed           : %10s\n", yesNo(flags & 0x40 != 0));
    _ = c.printf("Attached           : %10s\n", yesNo(flags & 0x20 != 0));
    _ = c.printf("Enabled            : %10s\n", yesNo(flags & 0x10 != 0));
    _ = c.printf("Write Protected    : %10s\n", yesNo(flags & 0x08 != 0));
    _ = c.printf("Health             : %10s\n", health);
    _ = c.printf("Bootable partition : %10d\n", @as(c_int, data[10]));
    return 0;
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    const name = std.mem.sliceTo(&intf.name, 0);
    if (!std.mem.eql(u8, name, "open") and !std.mem.eql(u8, name, "wmi")) {
        c.lprintf(log.Level.err, "vFlash support is enabled only for wmi and open interface.");
        c.lprintf(log.Level.err, "Its not enabled for lan and lanplus interface.");
        return -1;
    }
    if (common.arg(argv, argc, 1) == null or common.eq(common.arg(argv, argc, 1), "help")) {
        usage();
        return 0;
    }
    common.validator(intf);
    if (common.eq(common.arg(argv, argc, 1), "info") and
        common.eq(common.arg(argv, argc, 2), "Card") and
        common.arg(argv, argc, 3) == null)
    {
        return card(intf);
    }
    usage();
    return -1;
}

test "vFlash status bit extraction" {
    try std.testing.expectEqualStrings("Warning", switch (@as(u8, 0xfd) & 3) {
        1 => "Warning",
        else => "other",
    });
}
