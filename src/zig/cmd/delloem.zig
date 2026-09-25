//! Dell OEM command families, replacing `lib/ipmi_delloem.c`.
//! Requests use the same C ABI vtable; BMC responses are length-checked before
//! decoding and no response buffer or borrowed SDR pointer is retained.
//! See `doc/zig-migration/delloem.md` for the oracle fixtures and explicit
//! malformed-response safety deviations.
const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const common = @import("delloem/common.zig");
const lcd = @import("delloem/lcd.zig");
const mac = @import("delloem/mac.zig");
const lan = @import("delloem/lan.zig");
const power = @import("delloem/power.zig");
const led = @import("delloem/led.zig");
const flash = @import("delloem/vflash.zig");
const Intf = common.Intf;

fn usage() void {
    common.notice(&.{
        "",                       "usage: delloem <command> [option...]", "",        "commands:",
        "    lcd",                "    mac",                              "    lan", "    setled",
        "    powermonitor",       "    vFlash",                           "",        "For help on individual commands type:",
        "delloem <command> help",
    });
}

fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    const command = common.arg(argv, argc, 0);
    if (command == null or common.eq(command, "help")) {
        usage();
        return 0;
    }
    if (common.eq(command, "lcd")) return lcd.main(intf, argc, argv);
    if (common.eq(command, "mac")) return mac.main(intf, argc, argv);
    if (common.eq(command, "lan")) return lan.main(intf, argc, argv);
    if (common.eq(command, "setled")) return led.main(intf, argc, argv);
    if (common.eq(command, "powermonitor")) return power.main(intf, argc, argv);
    if (common.eq(command, "vFlash")) return flash.main(intf, argc, argv);
    usage();
    return -1;
}

pub fn exportSymbols() void {
    comptime {
        abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_delloem_main));
        abi.assertCallSignature(@TypeOf(lcd.platformModelName), @TypeOf(c.ipmi_lcd_get_platform_model_name));
        @export(&main, .{ .name = "ipmi_delloem_main" });
        @export(&lcd.platformModelName, .{ .name = "ipmi_lcd_get_platform_model_name" });
        @export(&common.imc_type, .{ .name = "IMC_Type" });
        @export(&common.idrac_flag, .{ .name = "iDRAC_FLAG" });
        @export(&common.idrac_all, .{ .name = "iDRAC_FLAG_ALL" });
        @export(&common.idrac_12_13, .{ .name = "iDRAC_FLAG_12_13" });
        @export(&common.lcd_mode, .{ .name = "lcd_mode" });
        @export(&common.power_headroom, .{ .name = "powerheadroom" });
        @export(&common.power_cap_settable, .{ .name = "PowercapSetable_flag" });
        @export(&common.power_cap_enabled, .{ .name = "PowercapstatusFlag" });
        @export(&flash.codes, .{ .name = "vFlash_completion_code_vals" });
        mac.exportGlobals();
    }
}

test "Dell numeric and state boundaries" {
    try std.testing.expectEqual(@as(u16, 0xff01), common.le16(&.{ 1, 255 }));
    var out: [4]u8 = undefined;
    common.put32(&out, 0x12345678);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12 }, &out);
}
