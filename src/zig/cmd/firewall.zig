//! Firmware firewall command, replacing `lib/ipmi_firewall.c`.
//! The discovery bitmap, command masks and subfunction masks retain the C
//! protocol's separate requests and completion-code behavior. In particular,
//! reset visits every command on every pair, including unsupported pairs.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const Request = ipmi.Request;
const Response = ipmi.Response;
const allocator = std.heap.c_allocator;

const max_lun: usize = c.MAX_LUN;
const max_netfn_pair: usize = c.MAX_NETFN_PAIR;
const max_command: usize = c.MAX_COMMAND;
const max_subfn: usize = c.MAX_SUBFN;
const command_bytes: usize = c.MAX_COMMAND_BYTES;
const subfn_bytes: usize = c.MAX_SUBFN_BYTES;
const available: u8 = c.BIT_AVAILABLE;
const configurable: u8 = c.BIT_CONFIGURABLE;
const enabled: u8 = c.BIT_ENABLED;

const Params = struct {
    channel: c_int = 0xe,
    lun: c_int = -1,
    netfn: c_int = -1,
    command: c_int = -1,
    subfn: c_int = -1,
    force: u8 = 0,
};

const Command = struct {
    support: u8 = 0,
    subfn_support: [subfn_bytes]u8 = @splat(0),
    subfn_config: [subfn_bytes]u8 = @splat(0),
    subfn_enable: [subfn_bytes]u8 = @splat(0),
};

const Pair = struct {
    support: u8 = 0,
    command: [max_command]Command = @splat(.{}),
    command_mask: [command_bytes]u8 = @splat(0),
    config_mask: [command_bytes]u8 = @splat(0),
    enable_mask: [command_bytes]u8 = @splat(0),
};

const Lun = struct {
    support: u8 = 0,
    netfn: [max_netfn_pair]Pair = @splat(.{}),
};

const Bmc = struct {
    lun: [max_lun]Lun = @splat(.{}),
};

fn eql(s: [*:0]const u8, text: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), text);
}

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

fn sendrecv(intf: *Intf, command: u8, data: []u8) ?*Response {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = @intCast(c.IPMI_NETFN_APP);
    req.msg.cmd = command;
    req.msg.data = data.ptr;
    req.msg.data_len = @intCast(data.len);
    return intf.sendrecv.?(intf, &req);
}

fn bitTest(bf: []const u8, index: usize) bool {
    return (bf[index >> 3] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
}

fn bitSet(bf: []u8, index: usize, value: bool) void {
    const mask = @as(u8, 1) << @as(u3, @intCast(index % 8));
    if (value) {
        bf[index >> 3] |= mask;
    } else {
        bf[index >> 3] &= ~mask;
    }
}

fn printBitfield(bf: []const u8, invert: bool, level: c_int) void {
    for (bf, 0..) |byte, i| {
        const value: u8 = if (invert) ~byte else byte;
        if (level < 0) {
            _ = c.printf("%02x", @as(c_uint, value));
            if ((i + 1) % 4 == 0) _ = c.printf(" ");
        } else {
            c.lprintf(level, "%02x", @as(c_uint, value));
            if ((i + 1) % 4 == 0) c.lprintf(level, " ");
        }
    }
    if (level < 0) {
        _ = c.printf("\n");
    } else {
        c.lprintf(level, "\n");
    }
}

fn usage() void {
    c.lprintf(log.Level.notice, "Firmware Firewall Commands:");
    c.lprintf(log.Level.notice, "\tinfo [channel H] [lun L]");
    c.lprintf(log.Level.notice, "\tinfo [channel H] [lun L [netfn N [command C [subfn S]]]]");
    c.lprintf(log.Level.notice, "\tenable [channel H] [lun L [netfn N [command C [subfn S]]]]");
    c.lprintf(log.Level.notice, "\tdisable [channel H] [lun L [netfn N [command C [subfn S]]]] [force])");
    c.lprintf(log.Level.notice, "\treset [channel H]");
    c.lprintf(log.Level.notice, "\t\twhere H is a Channel, L is a LUN, N is a NetFn,");
    c.lprintf(log.Level.notice, "\t\tC is a Command and S is a Sub-Function");
}

fn infoUsage() callconv(.c) void {
    c.lprintf(log.Level.notice, "info [channel H]");
    c.lprintf(log.Level.notice, "\tList all of the firewall information for all LUNs, NetFns");
    c.lprintf(log.Level.notice, "\tand Commands, This is a long list and is not very human readable.");
    c.lprintf(log.Level.notice, "info [channel H] lun L");
    c.lprintf(log.Level.notice, "\tThis also prints a long list that is not very human readable.");
    c.lprintf(log.Level.notice, "info [channel H] lun L netfn N");
    c.lprintf(log.Level.notice, "\tThis prints out information for a single LUN/NetFn pair.");
    c.lprintf(log.Level.notice, "\tThat is not really very usable, but at least it is short.");
    c.lprintf(log.Level.notice, "info [channel H] lun L netfn N command C");
    c.lprintf(log.Level.notice, "\tThis is the one you want -- it prints out detailed human");
    c.lprintf(log.Level.notice, "\treadable information.  It shows the support, configurable, and");
    c.lprintf(log.Level.notice, "\tenabled bits for the Command C on LUN/NetFn pair L,N and the");
    c.lprintf(log.Level.notice, "\tsame information about each of its Sub-functions.");
}

fn parseArgs(argv: [][*:0]u8, p: *Params) c_int {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (eql(argv[i], "channel") and i + 1 < argv.len) {
            i += 1;
            var channel: u8 = 0;
            if (c.is_ipmi_channel_num(argv[i], &channel) != 0) return -1;
            p.channel = channel;
        } else if (eql(argv[i], "lun") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.lun) != 0) {
                c.lprintf(log.Level.err, "Given lun '%s' is invalid.", argv[i]);
                return -1;
            }
        } else if (eql(argv[i], "force")) {
            p.force = 1;
        } else if (eql(argv[i], "netfn") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.netfn) != 0) {
                c.lprintf(log.Level.err, "Given netfn '%s' is invalid.", argv[i]);
                return -1;
            }
        } else if (eql(argv[i], "command") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.command) != 0) {
                c.lprintf(log.Level.err, "Given command '%s' is invalid.", argv[i]);
                return -1;
            }
        } else if (eql(argv[i], "subfn") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.subfn) != 0) {
                c.lprintf(log.Level.err, "Given subfn '%s' is invalid.", argv[i]);
                return -1;
            }
        }
    }
    if (p.subfn >= max_subfn) {
        c.lprintf(log.Level.err, "subfn is out of range (0-%d)", @as(c_int, max_subfn - 1));
        return -1;
    }
    if (p.command >= max_command) {
        c.lprintf(log.Level.err, "command is out of range (0-%d)", @as(c_int, max_command - 1));
        return -1;
    }
    if (p.netfn >= c.MAX_NETFN) {
        c.lprintf(log.Level.err, "netfn is out of range (0-%d)", @as(c_int, c.MAX_NETFN - 1));
        return -1;
    }
    if (p.lun >= max_lun) {
        c.lprintf(log.Level.err, "lun is out of range (0-%d)", @as(c_int, max_lun - 1));
        return -1;
    }
    if (p.netfn >= 0 and p.lun < 0) {
        c.lprintf(log.Level.err, "if netfn is set, so must be lun");
        return -1;
    }
    if (p.command >= 0 and p.netfn < 0) {
        c.lprintf(log.Level.err, "if command is set, so must be netfn");
        return -1;
    }
    if (p.subfn >= 0 and p.command < 0) {
        c.lprintf(log.Level.err, "if subfn is set, so must be command");
        return -1;
    }
    return 0;
}

fn getNetfnSupport(intf: *Intf, channel: c_int, lun: *[max_lun]u8, netfn: *[16]u8) c_int {
    var data = [_]u8{@truncate(@as(c_uint, @bitCast(channel)))};
    const rsp = sendrecv(intf, c.BMC_GET_NETFN_SUPPORT, &data) orelse {
        c.lprintf(log.Level.err, "Get NetFn Support command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Get NetFn Support command failed: %s", ccString(rsp.ccode));
        return -1;
    }
    for (lun, 0..) |*entry, l| entry.* = (rsp.data[0] >> @as(u3, @intCast(2 * l))) & 3;
    @memcpy(netfn, rsp.data[1..17]);
    return 0;
}

const MaskKind = enum {
    support,
    config,
    enable,

    fn command(self: MaskKind) u8 {
        return switch (self) {
            .support => c.BMC_GET_COMMAND_SUPPORT,
            .config => c.BMC_GET_CONFIGURABLE_COMMANDS,
            .enable => c.BMC_GET_COMMAND_ENABLES,
        };
    }

    fn label(self: MaskKind) [*:0]const u8 {
        return switch (self) {
            .support => "Get Command Support",
            .config => "Get Configurable Command",
            .enable => "Get Command Enables",
        };
    }
};

fn getCommandMask(intf: *Intf, p: *const Params, pair: *Pair, kind: MaskKind) c_int {
    const mask: *[command_bytes]u8 = switch (kind) {
        .support => &pair.command_mask,
        .config => &pair.config_mask,
        .enable => &pair.enable_mask,
    };
    for (0..2) |op| {
        var data = [_]u8{
            @truncate(@as(c_uint, @bitCast(p.channel))),
            @truncate(@as(c_uint, @bitCast(p.netfn)) | (if (op == 1) @as(c_uint, 0x40) else 0)),
            @truncate(@as(c_uint, @bitCast(p.lun))),
        };
        const rsp = sendrecv(intf, kind.command(), &data) orelse {
            c.lprintf(log.Level.err, "%s (LUN=%d, NetFn=%d, op=%d) command failed", kind.label(), p.lun, p.netfn, @as(c_int, @intCast(op)));
            return -1;
        };
        if (rsp.ccode != 0) {
            c.lprintf(log.Level.err, "%s (LUN=%d, NetFn=%d, op=%d) command failed: %s", kind.label(), p.lun, p.netfn, @as(c_int, @intCast(op)), ccString(rsp.ccode));
            return -1;
        }
        @memcpy(mask[op * 16 ..][0..16], rsp.data[0..16]);
        for (0..128) |index| {
            const raw = bitTest(rsp.data[0..16], index);
            if (if (kind == .support) !raw else raw) {
                pair.command[op * 128 + index].support |= switch (kind) {
                    .support => available,
                    .config => configurable,
                    .enable => enabled,
                };
            }
        }
    }
    return 0;
}

const SubfnKind = enum {
    support,
    config,
    enable,

    fn command(self: SubfnKind) u8 {
        return switch (self) {
            .support => c.BMC_GET_COMMAND_SUBFUNCTION_SUPPORT,
            .config => c.BMC_GET_CONFIGURABLE_COMMAND_SUBFUNCTIONS,
            .enable => c.BMC_GET_COMMAND_SUBFUNCTION_ENABLES,
        };
    }

    fn label(self: SubfnKind) [*:0]const u8 {
        return switch (self) {
            .support => "Get Command Sub-function Support",
            .config => "Get Configurable Command Sub-function",
            .enable => "Get Command Sub-function Enables",
        };
    }
};

fn getSubfnMask(intf: *Intf, p: *const Params, cmd: *Command, kind: SubfnKind) c_int {
    var data = [_]u8{
        @truncate(@as(c_uint, @bitCast(p.channel))),
        @truncate(@as(c_uint, @bitCast(p.netfn))),
        @truncate(@as(c_uint, @bitCast(p.lun))),
        @truncate(@as(c_uint, @bitCast(p.command))),
    };
    const rsp = sendrecv(intf, kind.command(), &data) orelse {
        c.lprintf(log.Level.err, "%s (LUN=%d, NetFn=%d, command=%d) command failed", kind.label(), p.lun, p.netfn, p.command);
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "%s (LUN=%d, NetFn=%d, command=%d) command failed: %s", kind.label(), p.lun, p.netfn, p.command, ccString(rsp.ccode));
        return -1;
    }
    const dest: *[subfn_bytes]u8 = switch (kind) {
        .support => &cmd.subfn_support,
        .config => &cmd.subfn_config,
        .enable => &cmd.subfn_enable,
    };
    @memcpy(dest, rsp.data[0..subfn_bytes]);
    return 0;
}

fn setCommandEnables(intf: *Intf, p: *const Params, pair: *const Pair, mask: *[command_bytes]u8, gun: bool) c_int {
    c.lprintf(log.Level.info, "support:            ");
    printBitfield(&pair.command_mask, true, log.Level.info);
    c.lprintf(log.Level.info, "configurable:       ");
    printBitfield(&pair.config_mask, false, log.Level.info);
    c.lprintf(log.Level.info, "enabled:            ");
    printBitfield(&pair.enable_mask, false, log.Level.info);
    c.lprintf(log.Level.info, "enable mask before: ");
    printBitfield(mask, false, log.Level.info);
    for (mask, 0..) |*byte, i| {
        byte.* = (pair.config_mask[i] & byte.*) | (~pair.config_mask[i] & pair.enable_mask[i]);
    }
    if (!gun) {
        const i: usize = c.SET_COMMAND_ENABLE_BYTE;
        // C's SET_COMMAND_ENABLE_BIT is the bit index, not a one-hot mask.
        mask[i] = (pair.config_mask[i] & @as(u8, c.SET_COMMAND_ENABLE_BIT)) |
            (~pair.config_mask[i] & pair.enable_mask[i]);
    }
    c.lprintf(log.Level.info, "enable mask after: ");
    printBitfield(mask, false, log.Level.info);

    for (0..2) |op| {
        var data: [19]u8 = undefined;
        data[0] = @truncate(@as(c_uint, @bitCast(p.channel)));
        data[1] = @truncate(@as(c_uint, @bitCast(p.netfn)) | (if (op == 1) @as(c_uint, 0x40) else 0));
        data[2] = @truncate(@as(c_uint, @bitCast(p.lun)));
        @memcpy(data[3..19], mask[op * 16 ..][0..16]);
        const rsp = sendrecv(intf, c.BMC_SET_COMMAND_ENABLES, &data) orelse {
            c.lprintf(log.Level.err, "Set Command Enables (LUN=%d, NetFn=%d, op=%d) command failed", p.lun, p.netfn, @as(c_int, @intCast(op)));
            return -1;
        };
        if (rsp.ccode != 0) {
            c.lprintf(log.Level.err, "Set Command Enables (LUN=%d, NetFn=%d, op=%d) command failed: %s", p.lun, p.netfn, @as(c_int, @intCast(op)), ccString(rsp.ccode));
            return -1;
        }
    }
    return 0;
}

fn setSubfnEnables(intf: *Intf, p: *const Params, cmd: *const Command, mask: *[subfn_bytes]u8) c_int {
    c.lprintf(log.Level.info, "support:            ");
    printBitfield(&cmd.subfn_support, true, log.Level.info);
    c.lprintf(log.Level.info, "configurable:       ");
    printBitfield(&cmd.subfn_config, false, log.Level.info);
    c.lprintf(log.Level.info, "enabled:            ");
    printBitfield(&cmd.subfn_enable, false, log.Level.info);
    c.lprintf(log.Level.info, "enable mask before: ");
    printBitfield(mask, false, log.Level.info);
    for (mask, 0..) |*byte, i| {
        byte.* = (cmd.subfn_config[i] & byte.*) | (~cmd.subfn_config[i] & cmd.subfn_enable[i]);
    }
    c.lprintf(log.Level.info, "enable mask after: ");
    printBitfield(mask, false, log.Level.info);

    var data: [8]u8 = undefined;
    data[0] = @truncate(@as(c_uint, @bitCast(p.channel)));
    data[1] = @truncate(@as(c_uint, @bitCast(p.netfn)));
    data[2] = @truncate(@as(c_uint, @bitCast(p.lun)));
    data[3] = @truncate(@as(c_uint, @bitCast(p.command)));
    @memcpy(data[4..8], mask);
    const rsp = sendrecv(intf, c.BMC_SET_COMMAND_SUBFUNCTION_ENABLES, &data) orelse {
        c.lprintf(log.Level.err, "Set Command Sub-function Enables (LUN=%d, NetFn=%d, command=%d) command failed", p.lun, p.netfn, p.command);
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Set Command Sub-function Enables (LUN=%d, NetFn=%d, command=%d) command failed: %s", p.lun, p.netfn, p.command, ccString(rsp.ccode));
        return -1;
    }
    return 0;
}

fn gatherInfo(intf: *Intf, p: *Params, bmc: *Bmc) void {
    var luns: [max_lun]u8 = undefined;
    var netfns: [16]u8 = undefined;
    var ret = getNetfnSupport(intf, p.channel, &luns, &netfns);
    if (ret == 0) {
        for (0..max_lun) |l| {
            if (p.lun >= 0 and p.lun != @as(c_int, @intCast(l))) continue;
            bmc.lun[l].support = luns[l];
            if (luns[l] != 0) {
                for (0..max_netfn_pair) |n| {
                    bmc.lun[l].netfn[n].support = @intFromBool(bitTest(&netfns, l * max_netfn_pair + n));
                }
            }
        }
    }
    if (p.netfn >= 0) {
        const l: usize = @intCast(p.lun);
        const n: usize = @intCast(@divTrunc(p.netfn, 2));
        if (bmc.lun[l].support == 0 or bmc.lun[l].netfn[n].support == 0) {
            c.lprintf(log.Level.err, "LUN or LUN/NetFn pair %d,%d not supported", p.lun, p.netfn);
            return;
        }
        const pair = &bmc.lun[l].netfn[n];
        ret = getCommandMask(intf, p, pair, .support);
        ret |= getCommandMask(intf, p, pair, .config);
        ret |= getCommandMask(intf, p, pair, .enable);
        if (ret == 0 and p.command >= 0) {
            const cmd = &pair.command[@intCast(p.command)];
            ret = getSubfnMask(intf, p, cmd, .support);
            ret |= getSubfnMask(intf, p, cmd, .config);
            ret |= getSubfnMask(intf, p, cmd, .enable);
        }
    } else if (p.lun >= 0) {
        const l: usize = @intCast(p.lun);
        if (bmc.lun[l].support != 0) {
            for (0..max_netfn_pair) |n| {
                p.netfn = @intCast(n * 2);
                if (bmc.lun[l].netfn[n].support != 0) {
                    ret = getCommandMask(intf, p, &bmc.lun[l].netfn[n], .support);
                    ret |= getCommandMask(intf, p, &bmc.lun[l].netfn[n], .config);
                    ret |= getCommandMask(intf, p, &bmc.lun[l].netfn[n], .enable);
                }
                if (ret != 0) bmc.lun[l].netfn[n].support = 0;
            }
        }
        p.netfn = -1;
    } else {
        for (0..max_lun) |l| {
            p.lun = @intCast(l);
            if (bmc.lun[l].support != 0) {
                for (0..max_netfn_pair) |n| {
                    p.netfn = @intCast(n * 2);
                    if (bmc.lun[l].netfn[n].support != 0) {
                        ret = getCommandMask(intf, p, &bmc.lun[l].netfn[n], .support);
                        ret |= getCommandMask(intf, p, &bmc.lun[l].netfn[n], .config);
                        ret |= getCommandMask(intf, p, &bmc.lun[l].netfn[n], .enable);
                    }
                    if (ret != 0) bmc.lun[l].netfn[n].support = 0;
                }
            }
        }
        p.lun = -1;
        p.netfn = -1;
    }
}

fn newBmc() ?*Bmc {
    const bmc = allocator.create(Bmc) catch {
        c.lprintf(log.Level.err, "malloc struct bmc_fn_support failed");
        return null;
    };
    bmc.* = .{};
    return bmc;
}

fn info(intf: *Intf, args: [][*:0]u8) c_int {
    var p = Params{};
    if ((args.len > 0 and eql(args[0], "help")) or parseArgs(args, &p) < 0) {
        infoUsage();
        return 0;
    }
    const bmc = newBmc() orelse return -1;
    defer allocator.destroy(bmc);
    gatherInfo(intf, &p, bmc);
    if (p.command >= 0) {
        const l: usize = @intCast(p.lun);
        const n: usize = @intCast(@divTrunc(p.netfn, 2));
        const cmd = &bmc.lun[l].netfn[n].command[@intCast(p.command)];
        if (bmc.lun[l].support == 0 or bmc.lun[l].netfn[n].support == 0 or cmd.support == 0) {
            c.lprintf(log.Level.err, "Command 0x%02x not supported on LUN/NetFn pair %02x,%02x", p.command, p.lun, p.netfn);
            return 0;
        }
        _ = c.printf("(A)vailable, (C)onfigurable, (E)nabled: | A | C | E |\n");
        _ = c.printf("-----------------------------------------------------\n");
        _ = c.printf("LUN %01d, NetFn 0x%02x, Command 0x%02x:        | %c | %c | %c |\n", p.lun, p.netfn, p.command, flag(cmd.support & available != 0), flag(cmd.support & configurable != 0), flag(cmd.support & enabled != 0));
        for (0..max_subfn) |subfn| {
            _ = c.printf("sub-function 0x%02x:                      | %c | %c | %c |\n", @as(c_uint, @intCast(subfn)), flag(!bitTest(&cmd.subfn_support, subfn)), flag(bitTest(&cmd.subfn_config, subfn)), flag(bitTest(&cmd.subfn_enable, subfn)));
        }
    } else if (p.netfn >= 0) {
        const l: usize = @intCast(p.lun);
        const n: usize = @intCast(@divTrunc(p.netfn, 2));
        const pair = &bmc.lun[l].netfn[n];
        if (bmc.lun[l].support == 0 or pair.support == 0) {
            c.lprintf(log.Level.err, "LUN or LUN/NetFn pair %02x,%02x not supported", p.lun, p.netfn);
            return 0;
        }
        _ = c.printf("Commands on LUN 0x%02x, NetFn 0x%02x\n", p.lun, p.netfn);
        _ = c.printf("support:      ");
        printBitfield(&pair.command_mask, true, -1);
        _ = c.printf("configurable: ");
        printBitfield(&pair.config_mask, false, -1);
        _ = c.printf("enabled:      ");
        printBitfield(&pair.enable_mask, false, -1);
    } else {
        for (0..max_lun) |l| {
            if (bmc.lun[l].support == 0) continue;
            for (0..max_netfn_pair) |n| {
                const pair = &bmc.lun[l].netfn[n];
                if (pair.support == 0) continue;
                _ = c.printf("%02x,%02x support:      ", @as(c_uint, @intCast(l)), @as(c_uint, @intCast(n * 2)));
                printBitfield(&pair.command_mask, true, -1);
                _ = c.printf("%02x,%02x configurable: ", @as(c_uint, @intCast(l)), @as(c_uint, @intCast(n * 2)));
                printBitfield(&pair.config_mask, false, -1);
                _ = c.printf("%02x,%02x enabled:      ", @as(c_uint, @intCast(l)), @as(c_uint, @intCast(n * 2)));
                printBitfield(&pair.enable_mask, false, -1);
            }
        }
    }
    return 0;
}

fn flag(condition: bool) c_int {
    return if (condition) 'X' else ' ';
}

fn enableDisableUsage(enable: bool) void {
    const s1: [*:0]const u8 = if (enable) "en" else "dis";
    const s2: [*:0]const u8 = if (enable) "" else " [force]";
    _ = c.printf("%sable [channel H] lun L netfn N%s\n", s1, s2);
    _ = c.printf("\t%sable all commands on this LUN/NetFn pair\n", s1);
    _ = c.printf("%sable [channel H] lun L netfn N command C%s\n", s1, s2);
    _ = c.printf("\t%sable Command C and all its Sub-functions for this LUN/NetFn pair\n", s1);
    _ = c.printf("%sable [channel H] lun L netfn N command C subfn S\n", s1);
    _ = c.printf("\t%sable Sub-function S for Command C for this LUN/NetFn pair\n", s1);
    if (!enable) {
        _ = c.printf("* force will allow you to disable the \"Command Set Enable\" command\n");
        _ = c.printf("\tthereby letting you shoot yourself in the foot\n");
        _ = c.printf("\tthis is only recommended for advanced users\n");
    }
}

fn enableDisable(intf: *Intf, enable: bool, args: [][*:0]u8) c_int {
    if (args.len == 0 or eql(args[0], "help")) {
        enableDisableUsage(enable);
        return 0;
    }
    var p = Params{};
    if (parseArgs(args, &p) < 0) return -1;
    const bmc = newBmc() orelse return -1;
    defer allocator.destroy(bmc);
    gatherInfo(intf, &p, bmc);
    var ret: c_int = 0;
    if (p.subfn >= 0) {
        const cmd = &bmc.lun[@intCast(p.lun)].netfn[@intCast(@divTrunc(p.netfn, 2))].command[@intCast(p.command)];
        var mask = cmd.subfn_enable;
        bitSet(&mask, @intCast(p.subfn), enable);
        ret = setSubfnEnables(intf, &p, cmd, &mask);
    } else if (p.command >= 0) {
        const pair = &bmc.lun[@intCast(p.lun)].netfn[@intCast(@divTrunc(p.netfn, 2))];
        const cmd = &pair.command[@intCast(p.command)];
        var subfn_mask: [subfn_bytes]u8 = @splat(if (enable) 0xff else 0);
        ret = setSubfnEnables(intf, &p, cmd, &subfn_mask);
        var mask = pair.enable_mask;
        bitSet(&mask, @intCast(p.command), enable);
        ret |= setCommandEnables(intf, &p, pair, &mask, p.force != 0);
    } else if (p.netfn >= 0) {
        const pair = &bmc.lun[@intCast(p.lun)].netfn[@intCast(@divTrunc(p.netfn, 2))];
        var mask: [command_bytes]u8 = @splat(if (enable) 0xff else 0);
        ret = setCommandEnables(intf, &p, pair, &mask, p.force != 0);
    }
    return ret;
}

fn reset(intf: *Intf, args: [][*:0]u8) c_int {
    if (args.len == 0) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        usage();
        return -1;
    }
    if (eql(args[0], "help")) {
        usage();
        return 0;
    }
    var p = Params{};
    if (parseArgs(args, &p) < 0) return -1;
    const bmc = newBmc() orelse return -1;
    defer allocator.destroy(bmc);
    gatherInfo(intf, &p, bmc);
    var ret: c_int = 0;
    for (0..max_lun) |l| {
        p.lun = @intCast(l);
        for (0..max_netfn_pair) |n| {
            p.netfn = @intCast(n * 2);
            const pair = &bmc.lun[l].netfn[n];
            for (0..max_command) |command| {
                p.command = @intCast(command);
                _ = c.printf("reset lun %d, netfn %d, command %d, subfn\n", @as(c_int, @intCast(l)), @as(c_int, @intCast(n)), @as(c_int, @intCast(command)));
                var subfn_mask: [subfn_bytes]u8 = @splat(0xff);
                ret = setSubfnEnables(intf, &p, &pair.command[command], &subfn_mask);
            }
            _ = c.printf("reset lun %d, netfn %d, command\n", @as(c_int, @intCast(l)), @as(c_int, @intCast(n)));
            var mask: [command_bytes]u8 = @splat(0xff);
            ret = setCommandEnables(intf, &p, pair, &mask, false);
        }
    }
    return ret;
}

fn main(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc < 1 or eql(argv[0], "help")) {
        usage();
        return 0;
    }
    const args = argv[1..@intCast(argc)];
    if (eql(argv[0], "info")) return info(intf, args);
    if (eql(argv[0], "enable")) return enableDisable(intf, true, args);
    if (eql(argv[0], "disable")) return enableDisable(intf, false, args);
    if (eql(argv[0], "reset")) return reset(intf, args);
    usage();
    return 0;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_firewall_main));
    abi.assertCallSignature(@TypeOf(infoUsage), @TypeOf(c.printf_firewall_info_usage));
    @export(&main, .{ .name = "ipmi_firewall_main", .linkage = .strong });
    @export(&infoUsage, .{ .name = "printf_firewall_info_usage", .linkage = .strong });
}
