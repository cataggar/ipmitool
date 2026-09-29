//! Firmware firewall command, replacing `lib/ipmi_firewall.c`.
//! The discovery bitmap, command masks and subfunction masks retain the C
//! protocol's separate requests and completion-code behavior. In particular,
//! reset visits every command on every pair, including unsupported pairs.
//! Diagnostics use the shared typed logger, with the C logger as fallback.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");
const stdout_io = @import("../util/stdout.zig");

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
        log.print(level, "%02x", .{@as(c_uint, value)});
        if ((i + 1) % 4 == 0) log.print(level, " ", .{});
    }
    log.print(level, "\n", .{});
}

fn usage() void {
    log.print(log.Level.notice, "Firmware Firewall Commands:", .{});
    log.print(log.Level.notice, "\tinfo [channel H] [lun L]", .{});
    log.print(log.Level.notice, "\tinfo [channel H] [lun L [netfn N [command C [subfn S]]]]", .{});
    log.print(log.Level.notice, "\tenable [channel H] [lun L [netfn N [command C [subfn S]]]]", .{});
    log.print(log.Level.notice, "\tdisable [channel H] [lun L [netfn N [command C [subfn S]]]] [force])", .{});
    log.print(log.Level.notice, "\treset [channel H]", .{});
    log.print(log.Level.notice, "\t\twhere H is a Channel, L is a LUN, N is a NetFn,", .{});
    log.print(log.Level.notice, "\t\tC is a Command and S is a Sub-Function", .{});
}

fn infoUsage() callconv(.c) void {
    log.print(log.Level.notice, "info [channel H]", .{});
    log.print(log.Level.notice, "\tList all of the firewall information for all LUNs, NetFns", .{});
    log.print(log.Level.notice, "\tand Commands, This is a long list and is not very human readable.", .{});
    log.print(log.Level.notice, "info [channel H] lun L", .{});
    log.print(log.Level.notice, "\tThis also prints a long list that is not very human readable.", .{});
    log.print(log.Level.notice, "info [channel H] lun L netfn N", .{});
    log.print(log.Level.notice, "\tThis prints out information for a single LUN/NetFn pair.", .{});
    log.print(log.Level.notice, "\tThat is not really very usable, but at least it is short.", .{});
    log.print(log.Level.notice, "info [channel H] lun L netfn N command C", .{});
    log.print(log.Level.notice, "\tThis is the one you want -- it prints out detailed human", .{});
    log.print(log.Level.notice, "\treadable information.  It shows the support, configurable, and", .{});
    log.print(log.Level.notice, "\tenabled bits for the Command C on LUN/NetFn pair L,N and the", .{});
    log.print(log.Level.notice, "\tsame information about each of its Sub-functions.", .{});
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
                log.print(log.Level.err, "Given lun '%s' is invalid.", .{argv[i]});
                return -1;
            }
        } else if (eql(argv[i], "force")) {
            p.force = 1;
        } else if (eql(argv[i], "netfn") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.netfn) != 0) {
                log.print(log.Level.err, "Given netfn '%s' is invalid.", .{argv[i]});
                return -1;
            }
        } else if (eql(argv[i], "command") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.command) != 0) {
                log.print(log.Level.err, "Given command '%s' is invalid.", .{argv[i]});
                return -1;
            }
        } else if (eql(argv[i], "subfn") and i + 1 < argv.len) {
            i += 1;
            if (c.str2int(argv[i], &p.subfn) != 0) {
                log.print(log.Level.err, "Given subfn '%s' is invalid.", .{argv[i]});
                return -1;
            }
        }
    }
    if (p.subfn >= max_subfn) {
        log.print(log.Level.err, "subfn is out of range (0-%d)", .{@as(c_int, max_subfn - 1)});
        return -1;
    }
    if (p.command >= max_command) {
        log.print(log.Level.err, "command is out of range (0-%d)", .{@as(c_int, max_command - 1)});
        return -1;
    }
    if (p.netfn >= c.MAX_NETFN) {
        log.print(log.Level.err, "netfn is out of range (0-%d)", .{@as(c_int, c.MAX_NETFN - 1)});
        return -1;
    }
    if (p.lun >= max_lun) {
        log.print(log.Level.err, "lun is out of range (0-%d)", .{@as(c_int, max_lun - 1)});
        return -1;
    }
    if (p.netfn >= 0 and p.lun < 0) {
        log.print(log.Level.err, "if netfn is set, so must be lun", .{});
        return -1;
    }
    if (p.command >= 0 and p.netfn < 0) {
        log.print(log.Level.err, "if command is set, so must be netfn", .{});
        return -1;
    }
    if (p.subfn >= 0 and p.command < 0) {
        log.print(log.Level.err, "if subfn is set, so must be command", .{});
        return -1;
    }
    return 0;
}

fn getNetfnSupport(intf: *Intf, channel: c_int, lun: *[max_lun]u8, netfn: *[16]u8) c_int {
    var data = [_]u8{@truncate(@as(c_uint, @bitCast(channel)))};
    const rsp = sendrecv(intf, c.BMC_GET_NETFN_SUPPORT, &data) orelse {
        log.print(log.Level.err, "Get NetFn Support command failed", .{});
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Get NetFn Support command failed: %s", .{ccString(rsp.ccode)});
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
            log.print(log.Level.err, "%s (LUN=%d, NetFn=%d, op=%d) command failed", .{ kind.label(), p.lun, p.netfn, @as(c_int, @intCast(op)) });
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "%s (LUN=%d, NetFn=%d, op=%d) command failed: %s", .{ kind.label(), p.lun, p.netfn, @as(c_int, @intCast(op)), ccString(rsp.ccode) });
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
        log.print(log.Level.err, "%s (LUN=%d, NetFn=%d, command=%d) command failed", .{ kind.label(), p.lun, p.netfn, p.command });
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "%s (LUN=%d, NetFn=%d, command=%d) command failed: %s", .{ kind.label(), p.lun, p.netfn, p.command, ccString(rsp.ccode) });
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
    log.print(log.Level.info, "support:            ", .{});
    printBitfield(&pair.command_mask, true, log.Level.info);
    log.print(log.Level.info, "configurable:       ", .{});
    printBitfield(&pair.config_mask, false, log.Level.info);
    log.print(log.Level.info, "enabled:            ", .{});
    printBitfield(&pair.enable_mask, false, log.Level.info);
    log.print(log.Level.info, "enable mask before: ", .{});
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
    log.print(log.Level.info, "enable mask after: ", .{});
    printBitfield(mask, false, log.Level.info);

    for (0..2) |op| {
        var data: [19]u8 = undefined;
        data[0] = @truncate(@as(c_uint, @bitCast(p.channel)));
        data[1] = @truncate(@as(c_uint, @bitCast(p.netfn)) | (if (op == 1) @as(c_uint, 0x40) else 0));
        data[2] = @truncate(@as(c_uint, @bitCast(p.lun)));
        @memcpy(data[3..19], mask[op * 16 ..][0..16]);
        const rsp = sendrecv(intf, c.BMC_SET_COMMAND_ENABLES, &data) orelse {
            log.print(log.Level.err, "Set Command Enables (LUN=%d, NetFn=%d, op=%d) command failed", .{ p.lun, p.netfn, @as(c_int, @intCast(op)) });
            return -1;
        };
        if (rsp.ccode != 0) {
            log.print(log.Level.err, "Set Command Enables (LUN=%d, NetFn=%d, op=%d) command failed: %s", .{ p.lun, p.netfn, @as(c_int, @intCast(op)), ccString(rsp.ccode) });
            return -1;
        }
    }
    return 0;
}

fn setSubfnEnables(intf: *Intf, p: *const Params, cmd: *const Command, mask: *[subfn_bytes]u8) c_int {
    log.print(log.Level.info, "support:            ", .{});
    printBitfield(&cmd.subfn_support, true, log.Level.info);
    log.print(log.Level.info, "configurable:       ", .{});
    printBitfield(&cmd.subfn_config, false, log.Level.info);
    log.print(log.Level.info, "enabled:            ", .{});
    printBitfield(&cmd.subfn_enable, false, log.Level.info);
    log.print(log.Level.info, "enable mask before: ", .{});
    printBitfield(mask, false, log.Level.info);
    for (mask, 0..) |*byte, i| {
        byte.* = (cmd.subfn_config[i] & byte.*) | (~cmd.subfn_config[i] & cmd.subfn_enable[i]);
    }
    log.print(log.Level.info, "enable mask after: ", .{});
    printBitfield(mask, false, log.Level.info);

    var data: [8]u8 = undefined;
    data[0] = @truncate(@as(c_uint, @bitCast(p.channel)));
    data[1] = @truncate(@as(c_uint, @bitCast(p.netfn)));
    data[2] = @truncate(@as(c_uint, @bitCast(p.lun)));
    data[3] = @truncate(@as(c_uint, @bitCast(p.command)));
    @memcpy(data[4..8], mask);
    const rsp = sendrecv(intf, c.BMC_SET_COMMAND_SUBFUNCTION_ENABLES, &data) orelse {
        log.print(log.Level.err, "Set Command Sub-function Enables (LUN=%d, NetFn=%d, command=%d) command failed", .{ p.lun, p.netfn, p.command });
        return -1;
    };
    if (rsp.ccode != 0) {
        log.print(log.Level.err, "Set Command Sub-function Enables (LUN=%d, NetFn=%d, command=%d) command failed: %s", .{ p.lun, p.netfn, p.command, ccString(rsp.ccode) });
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
            log.print(log.Level.err, "LUN or LUN/NetFn pair %d,%d not supported", .{ p.lun, p.netfn });
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
        log.print(log.Level.err, "malloc struct bmc_fn_support failed", .{});
        return null;
    };
    bmc.* = .{};
    return bmc;
}

const MatrixOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeCommandMask(writer: *std.Io.Writer, bf: []const u8, invert: bool) std.Io.Writer.Error!void {
    const hex = "0123456789abcdef";
    for (bf, 0..) |byte, i| {
        const value: u8 = if (invert) ~byte else byte;
        try writer.writeAll(&.{ hex[value >> 4], hex[value & 0xf] });
        if ((i + 1) % 4 == 0) try writer.writeByte(' ');
    }
    try writer.writeByte('\n');
}

fn writePairMatrix(writer: *std.Io.Writer, pair: *const Pair, lun: usize, netfn: usize, listed: bool) std.Io.Writer.Error!void {
    if (!listed) try writer.print("Commands on LUN 0x{x:0>2}, NetFn 0x{x:0>2}\n", .{ lun, netfn });

    if (listed) try writer.print("{x:0>2},{x:0>2} ", .{ lun, netfn });
    try writer.writeAll("support:      ");
    try writeCommandMask(writer, &pair.command_mask, true);

    if (listed) try writer.print("{x:0>2},{x:0>2} ", .{ lun, netfn });
    try writer.writeAll("configurable: ");
    try writeCommandMask(writer, &pair.config_mask, false);

    if (listed) try writer.print("{x:0>2},{x:0>2} ", .{ lun, netfn });
    try writer.writeAll("enabled:      ");
    try writeCommandMask(writer, &pair.enable_mask, false);
}

fn emitCommandMatrix(writer: *std.Io.Writer, bmc: *const Bmc, p: *const Params, preflush: anytype) MatrixOutputError!void {
    if (p.netfn >= 0) {
        preflush() catch return error.CStdoutFlushFailed;
        writePairMatrix(writer, &bmc.lun[@intCast(p.lun)].netfn[@intCast(@divTrunc(p.netfn, 2))], @intCast(p.lun), @intCast(p.netfn), false) catch return error.StdoutWriteFailed;
    } else {
        var started = false;
        for (0..max_lun) |l| {
            if (bmc.lun[l].support == 0) continue;
            for (0..max_netfn_pair) |n| {
                const pair = &bmc.lun[l].netfn[n];
                if (pair.support == 0) continue;
                if (!started) {
                    preflush() catch return error.CStdoutFlushFailed;
                    started = true;
                }
                writePairMatrix(writer, pair, l, n * 2, true) catch return error.StdoutWriteFailed;
            }
        }
        if (!started) return;
    }
    writer.flush() catch return error.StdoutFlushFailed;
}

fn printCommandMatrix(bmc: *const Bmc, p: *const Params) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    emitCommandMatrix(&stdout.interface, bmc, p, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Firewall command matrix stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Firewall command matrix stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Firewall command matrix stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
    return 0;
}

fn cMaskOracle(writer: *std.Io.Writer, bf: []const u8, invert: bool) !void {
    var hex: [3]u8 = undefined;
    for (bf, 0..) |byte, i| {
        const value: u8 = if (invert) ~byte else byte;
        try std.testing.expectEqual(@as(c_int, 2), c.snprintf(&hex, hex.len, "%02x", @as(c_uint, value)));
        try writer.writeAll(hex[0..2]);
        if ((i + 1) % 4 == 0) try writer.writeByte(' ');
    }
    try writer.writeByte('\n');
}

fn cPairOracle(writer: *std.Io.Writer, pair: *const Pair, lun: usize, netfn: usize, listed: bool) !void {
    var text: [80]u8 = undefined;
    if (!listed) {
        const length = c.snprintf(&text, text.len, "Commands on LUN 0x%02x, NetFn 0x%02x\n", @as(c_uint, @intCast(lun)), @as(c_uint, @intCast(netfn)));
        try writer.writeAll(text[0..@intCast(length)]);
    }
    const labels = [_][:0]const u8{ "support:      ", "configurable: ", "enabled:      " };
    const masks = [_]*const [command_bytes]u8{ &pair.command_mask, &pair.config_mask, &pair.enable_mask };
    for (labels, masks, 0..) |label, mask, index| {
        if (listed) {
            const length = c.snprintf(&text, text.len, "%02x,%02x %s", @as(c_uint, @intCast(lun)), @as(c_uint, @intCast(netfn)), label.ptr);
            try writer.writeAll(text[0..@intCast(length)]);
        } else {
            try writer.writeAll(label);
        }
        try cMaskOracle(writer, mask, index == 0);
    }
}

test "firewall command matrix bitfield groups and inverts C bytes at boundaries" {
    const values = [_]u8{ 0, 0xff, 0x08, 0x80, 0x1f, 0xa5, 0x55, 0xfe };
    var mask: [command_bytes + 1]u8 = undefined;
    for (&mask, 0..) |*byte, i| byte.* = values[i % values.len];
    for ([_]usize{ 0, 1, 3, 4, 5, 15, 16, 31, 32, 33 }) |length| {
        for ([_]bool{ false, true }) |invert| {
            var expected_storage: [128]u8 = undefined;
            var expected = std.Io.Writer.fixed(&expected_storage);
            try cMaskOracle(&expected, mask[0..length], invert);
            var actual_storage: [128]u8 = undefined;
            var actual = std.Io.Writer.fixed(&actual_storage);
            try writeCommandMask(&actual, mask[0..length], invert);
            try std.testing.expectEqualSlices(u8, expected.buffered(), actual.buffered());
        }
    }
}

test "firewall command matrix selected and discovered pairs match C bytes" {
    const bmc = try std.testing.allocator.create(Bmc);
    defer std.testing.allocator.destroy(bmc);
    bmc.* = .{};
    bmc.lun[0].support = 1;
    bmc.lun[0].netfn[2].support = 1;
    bmc.lun[3].support = 1;
    bmc.lun[3].netfn[31].support = 1;
    bmc.lun[0].netfn[2].command_mask[0] = 0xde;
    bmc.lun[0].netfn[2].command_mask[16] = 0xf7;
    bmc.lun[0].netfn[2].command_mask[31] = 0x80;
    bmc.lun[0].netfn[2].config_mask[0] = 0x21;
    bmc.lun[0].netfn[2].enable_mask[4] = 0x10;
    bmc.lun[3].netfn[31].command_mask[15] = 0x00;
    bmc.lun[3].netfn[31].config_mask[31] = 0xfe;
    bmc.lun[3].netfn[31].enable_mask[0] = 0xff;

    for ([_]Params{ .{ .lun = 0, .netfn = 5 }, .{} }) |p| {
        var expected_storage: [1024]u8 = undefined;
        var expected = std.Io.Writer.fixed(&expected_storage);
        if (p.netfn >= 0) {
            try cPairOracle(&expected, &bmc.lun[0].netfn[2], 0, 5, false);
        } else {
            try cPairOracle(&expected, &bmc.lun[0].netfn[2], 0, 4, true);
            try cPairOracle(&expected, &bmc.lun[3].netfn[31], 3, 62, true);
        }
        var actual_storage: [1024]u8 = undefined;
        var actual = std.Io.Writer.fixed(&actual_storage);
        const Stub = struct {
            fn preflushOk() error{CStdoutFlushFailed}!void {}
        };
        try emitCommandMatrix(&actual, bmc, &p, Stub.preflushOk);
        try std.testing.expectEqualSlices(u8, expected.buffered(), actual.buffered());
    }
}

test "firewall command matrix preflushes once and reports preflush, write, final flush failures" {
    const Stub = struct {
        var preflushes: usize = 0;
        var flushes: usize = 0;
        fn preflushCount() error{CStdoutFlushFailed}!void {
            preflushes += 1;
        }
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushCount(_: *std.Io.Writer) std.Io.Writer.Error!void {
            flushes += 1;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    const bmc = try std.testing.allocator.create(Bmc);
    defer std.testing.allocator.destroy(bmc);
    bmc.* = .{};
    const all = Params{};
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushCount };
    try emitCommandMatrix(&writer, bmc, &all, Stub.preflushCount);
    try std.testing.expectEqual(@as(usize, 0), Stub.preflushes);
    try std.testing.expectEqual(@as(usize, 0), Stub.flushes);

    bmc.lun[0].support = 1;
    bmc.lun[0].netfn[2].support = 1;
    bmc.lun[2].support = 1;
    bmc.lun[2].netfn[3].support = 1;
    try std.testing.expectError(error.CStdoutFlushFailed, emitCommandMatrix(&writer, bmc, &all, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitCommandMatrix(&early, bmc, &all, Stub.preflushCount));
    var short: [32]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitCommandMatrix(&late, bmc, &all, Stub.preflushCount));
    try std.testing.expect(std.mem.startsWith(u8, late.buffered(), "00,04 support:"));

    try emitCommandMatrix(&writer, bmc, &all, Stub.preflushCount);
    try std.testing.expectEqual(@as(usize, 3), Stub.preflushes);
    try std.testing.expectEqual(@as(usize, 1), Stub.flushes);
    var final = std.Io.Writer.fixed(&storage);
    final.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitCommandMatrix(&final, bmc, &all, Stub.preflushCount));
    try std.testing.expect(final.buffered().len > 0);

    const selected = Params{ .lun = 0, .netfn = 5 };
    var pair_writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitCommandMatrix(&pair_writer, bmc, &selected, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), pair_writer.buffered().len);
    try std.testing.expectError(error.StdoutWriteFailed, emitCommandMatrix(&early, bmc, &selected, Stub.preflushCount));
    pair_writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitCommandMatrix(&pair_writer, bmc, &selected, Stub.preflushCount));
}

test "firewall command matrix preserves buffered C and Zig stdout order" {
    const bmc = try std.testing.allocator.create(Bmc);
    defer std.testing.allocator.destroy(bmc);
    bmc.* = .{};
    bmc.lun[0].support = 1;
    bmc.lun[0].netfn[2].support = 1;
    const p = Params{ .lun = 0, .netfn = 4 };

    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitCommandMatrix(&stdout.interface, bmc, &p, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));
    var captured: [1024]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    var expected_storage: [1024]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    try expected.writeAll("before|");
    try cPairOracle(&expected, &bmc.lun[0].netfn[2], 0, 4, false);
    try expected.writeAll("|after\n");
    try std.testing.expectEqualSlices(u8, expected.buffered(), captured[0..@intCast(length)]);
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
            log.print(log.Level.err, "Command 0x%02x not supported on LUN/NetFn pair %02x,%02x", .{ p.command, p.lun, p.netfn });
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
            log.print(log.Level.err, "LUN or LUN/NetFn pair %02x,%02x not supported", .{ p.lun, p.netfn });
            return 0;
        }
        return printCommandMatrix(bmc, &p);
    } else {
        return printCommandMatrix(bmc, &p);
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
        log.print(log.Level.err, "Not enough parameters given.", .{});
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
