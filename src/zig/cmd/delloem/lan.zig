const common = @import("common.zig");
const c = common.c;
const Intf = common.Intf;
const log = common.log;

fn usage() void {
    common.notice(&.{
        "",                                                                                       "   lan set <Mode>",                                                                      "      sets the NIC Selection Mode :",
        "          on iDRAC12g OR iDRAC13g  :",                                                   "              dedicated, shared with lom1, shared with lom2,shared with lom3,shared",    "              with lom4,shared with failover lom1,shared with failover lom2,shared",
        "              with failover lom3,shared with failover lom4,shared with Failover all",    "              loms, shared with Failover None).",                                        "          on other systems :",
        "              dedicated, shared, shared with failover lom2,",                            "              shared with Failover all loms.",                                           "",
        "   lan get ",                                                                            "          on iDRAC12g or iDRAC13g  :",                                                   "              returns the current NIC Selection Mode (dedicated, shared with lom1, shared",
        "              with lom2, shared with lom3, shared with lom4,shared with failover lom1,", "              shared with failover lom2,shared with failover lom3,shared with failover", "              lom4,shared with Failover all loms,shared with Failover None).",
        "          on other systems :",                                                           "              dedicated, shared, shared with failover,",                                 "              lom2, shared with Failover all loms.",
        "",                                                                                       "   lan get active",                                                                      "      returns the current active NIC (dedicated, LOM1, LOM2, LOM3, LOM4).",
        "",
    });
}

fn get(intf: *Intf) c_int {
    const modern = common.idrac_12_13 != 0;
    const rsp = common.send(intf, 0x30, if (modern) 0x29 else 0x25, &.{}) orelse {
        log.print(log.Level.err, "Error in getting nic selection", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error in getting nic selection (%s)", .{common.cc(rsp.ccode)});
        return -1;
    }
    const data = common.bytes(rsp, if (modern) 2 else 1) orelse return common.short("nic selection");
    const names = [_][*:0]const u8{ "shared", "shared with failover lom2", "dedicated", "shared with Failover all loms" };
    const modern_names = [_][*:0]const u8{
        "dedicated",                 "shared with lom1",              "shared with lom2",          "shared with lom3",
        "shared with lom4",          "shared with failover lom1",     "shared with failover lom2", "shared with failover lom3",
        "shared with failover lom4", "shared with failover all loms",
    };
    if (!modern) {
        if (data[0] >= names.len) return common.short("nic selection");
        _ = c.printf("%s\n", names[data[0]]);
        return 0;
    }
    const selection = data[0];
    const failover = data[1];
    if (selection == 0 or selection >= 6 or failover >= 7) {
        log.print(log.Level.err, "Error Outof bond Value received (%d) (%d)", .{ @as(c_int, selection), @as(c_int, failover) });
        return -1;
    }
    if (selection == 1) {
        _ = c.printf("%s\n", modern_names[0]);
    } else {
        _ = c.printf("Shared LOM   :  %s\n", modern_names[selection - 1]);
        if (failover == 0) {
            _ = c.printf("Failover LOM :  None\n");
        } else if (failover >= 2) {
            _ = c.printf("Failover LOM :  %s\n", modern_names[failover + 3]);
        }
    }
    return 0;
}

fn active(intf: *Intf) c_int {
    const status = common.send(intf, 0x30, 0xc1, &.{ 0, 0, 0 }) orelse {
        log.print(log.Level.err, "Error in getting Active LOM Status", .{});
        return -1;
    };
    if (status.ccode != 0) {
        log.print(log.Level.err, "Error in getting Active LOM Status (%s)", .{common.cc(status.ccode)});
        return -1;
    }
    const body = common.bytes(status, 1) orelse return common.short("Active LOM Status");
    const current = body[0];
    const link = common.send(intf, 0x30, 0xc1, &.{ 1, 0, 0 }) orelse {
        log.print(log.Level.err, "Error in getting Active LOM Status", .{});
        return -1;
    };
    if (link.ccode != 0) {
        log.print(log.Level.err, "Error in getting Active LOM Status (%s)", .{common.cc(link.ccode)});
        return -1;
    }
    const data = common.bytes(link, 2) orelse return common.short("Active LOM Status");
    const names = [_][*:0]const u8{ "None", "LOM1", "LOM2", "LOM3", "LOM4", "dedicated" };
    _ = c.printf("\n%s\n", names[if (current < names.len and data[1] != 0) current else 0]);
    return 0;
}

fn at(argv: [*c][*c]u8, argc: c_int, index: usize, want: []const u8) bool {
    return common.eq(common.arg(argv, argc, index), want);
}

// Returns -1 for bad syntax and -2/-3/-4 for the three 12g policy errors.
fn parse12(intf: *Intf, argc: c_int, argv: [*c][*c]u8, result: *[2]u8) c_int {
    const rsp = common.send(intf, 0x30, 0x29, &.{}) orelse {
        log.print(log.Level.err, "Error in getting nic selection", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error in getting nic selection (%s)", .{common.cc(rsp.ccode)});
        return -1;
    }
    const data = common.bytes(rsp, 2) orelse return common.short("nic selection");
    result.* = .{ data[0], data[1] };
    if (at(argv, argc, 2, "dedicated")) {
        result.* = .{ 1, 0 };
        return 0;
    }
    if (!at(argv, argc, 2, "shared") or !at(argv, argc, 3, "with")) return -1;
    const failover = at(argv, argc, 4, "failover");
    const loc: usize = if (failover) 5 else 4;
    if (failover and at(argv, argc, loc, "none")) {
        if (common.imc_type == 0x11 or common.imc_type == 0x21) return -4;
        if (result[0] == 1) return -3;
        result[1] = 0;
        return 0;
    }
    if (failover and at(argv, argc, loc, "all") and at(argv, argc, loc + 1, "loms")) {
        if (common.imc_type == 0x11 or common.imc_type == 0x21) return -4;
        if (result[0] == 1) return -3;
        result[1] = 6;
        return 0;
    }
    const names = [_][]const u8{ "lom1", "lom2", "lom3", "lom4" };
    for (names, 2..) |name, value| {
        if (!at(argv, argc, loc, name)) continue;
        if (common.imc_type == 0x11 or common.imc_type == 0x21) return -4;
        const nic: u8 = @intCast(value);
        if (failover) {
            if (result[0] == nic) return -2;
            if (result[0] == 1) return -3;
            result[1] = nic;
        } else {
            result[0] = nic;
            if (result[1] == nic) result[1] = 0;
        }
        return 0;
    }
    return -1;
}

fn parseLegacy(argc: c_int, argv: [*c][*c]u8) c_int {
    if (at(argv, argc, 2, "dedicated")) return 2;
    if (!at(argv, argc, 2, "shared")) return -1;
    if (common.arg(argv, argc, 3) == null) return 0;
    if (!at(argv, argc, 3, "with") or !at(argv, argc, 4, "failover")) return -1;
    if (at(argv, argc, 5, "lom2")) return 1;
    if (at(argv, argc, 5, "all") and at(argv, argc, 6, "loms")) return 3;
    return -1;
}

pub fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    if (common.arg(argv, argc, 1) == null or at(argv, argc, 1, "help")) {
        usage();
        return 0;
    }
    common.validator(intf);
    if (common.imc_type == 0x0b) {
        log.print(log.Level.err, "lan is not supported on this system.", .{});
        return -1;
    }
    if (at(argv, argc, 1, "get")) {
        if (common.arg(argv, argc, 2) == null) return get(intf);
        if (at(argv, argc, 2, "active")) return active(intf);
        usage();
        return 0;
    }
    if (!at(argv, argc, 1, "set")) {
        usage();
        return -1;
    }
    if (common.arg(argv, argc, 2) == null) {
        usage();
        return -1;
    }
    if (common.idrac_12_13 != 0) {
        var selection: [2]u8 = .{ 0, 0 };
        const parsed = parse12(intf, argc, argv, &selection);
        if (parsed != 0) {
            switch (parsed) {
                -2 => log.print(log.Level.err, "ERROR: Cannot set shared with failover lom same as current shared lom.", .{}),
                -3 => log.print(log.Level.err, "ERROR: Cannot set shared with failover loms when NIC is set to dedicated Mode.", .{}),
                -4 => log.print(log.Level.err, "ERROR: Cannot set shared Mode for Blades.", .{}),
                else => usage(),
            }
            return -1;
        }
        const rsp = common.send(intf, 0x30, 0x28, &selection) orelse {
            log.print(log.Level.err, "Error in setting nic selection", .{});
            return 0; // C's lan main discards the set command's return value.
        };
        if (common.license(rsp.ccode)) return 0;
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Error in setting nic selection (%s)", .{common.cc(rsp.ccode)});
        } else {
            _ = c.printf("configured successfully");
        }
        return 0;
    }
    const parsed = parseLegacy(argc, argv);
    if (parsed < 0) {
        usage();
        return -1;
    }
    const data: [1]u8 = .{@intCast(parsed)};
    const rsp = common.send(intf, 0x30, 0x24, &data) orelse {
        log.print(log.Level.err, "Error in setting nic selection", .{});
        return 0;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Error in setting nic selection (%s)", .{common.cc(rsp.ccode)});
    } else {
        _ = c.printf("configured successfully");
    }
    return 0;
}
