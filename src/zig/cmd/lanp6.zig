//! IPv6 LAN parameter commands and their Get/Set LAN Configuration transport.
//! `lib/ipmi_cfgp.c` remains the shared selector/iteration engine; this module
//! supplies all of the IPv6 descriptors, parsing, formatting and wire I/O.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Request = @import("../core/ipmi.zig").Request;
const Response = @import("../core/ipmi.zig").Response;

const Lanp = c.struct_ipmi_lanp;
const Priv = c.struct_ipmi_lanp_priv;
const CfgpCtx = c.struct_ipmi_cfgp_ctx;
const CfgpSel = c.struct_ipmi_cfgp_sel;
const Action = c.struct_ipmi_cfgp_action;
const Valstr = c.struct_valstr;
const File = c.FILE;

// The shared cfgp engine consumes unsigned-int bitfields, which translate-c
// exposes as opaque. The layout is pinned to the C header in abi_layout.h.
const Flags = switch (builtin.target.cpu.arch.endian()) {
    .little => packed struct(u32) {
        access: u2,
        is_set: u1,
        first_set: u1,
        has_blocks: u1,
        first_block: u1,
        reserved: u26 = 0,
    },
    .big => packed struct(u32) {
        reserved: u26 = 0,
        first_block: u1,
        has_blocks: u1,
        first_set: u1,
        is_set: u1,
        access: u2,
    },
};
const Cfgp = extern struct {
    name: [*c]const u8,
    format: [*c]const u8,
    size: c_uint,
    flags: Flags,
    specific: c_int,
};

const cmd_save = 0;
const cmd_set = 1;
const cmd_print = 2;
const cmd_lock = 3;
const cmd_commit = 4;
const cmd_discard = 5;
const cmd_help = 6;
const cmd_any = 0xff;

const support = 50;
const enables = 51;
const traffic_class = 52;
const static_hops = 53;
const flow_label = 54;
const status = 55;
const static_addr = 56;
const static_duid_stg = 57;
const static_duid = 58;
const dynamic_addr = 59;
const dynamic_duid_stg = 60;
const dynamic_duid = 61;
const dhcp_cfg_sup = 62;
const dhcp_cfg = 63;
const router_cfg = 64;
const static_router = 65;
const static_router2 = 69;
const num_dynamic_rtrs = 73;
const dynamic_router = 74;
const dynamic_hops = 78;
const ndslaac_cfg_sup = 79;
const ndslaac_cfg = 80;

const generic_lanp6 = [_]Lanp{
    .{ .selector = 0, .name = "Set In Progress", .size = 1 },
    .{ .selector = 50, .name = "IPv6/IPv4 Support", .size = 1 },
    .{ .selector = 51, .name = "IPv6/IPv4 Addressing Enables", .size = 1 },
    .{ .selector = 52, .name = "IPv6 Header Traffic Class", .size = 1 },
    .{ .selector = 53, .name = "IPv6 Header Static Hop Limit", .size = 1 },
    .{ .selector = 54, .name = "IPv6 Header Flow Label", .size = 3 },
    .{ .selector = 55, .name = "IPv6 Status", .size = 3 },
    .{ .selector = 56, .name = "IPv6 Static Address", .size = 20 },
    .{ .selector = 57, .name = "IPv6 DHCPv6 Static DUID Storage Length", .size = 1 },
    .{ .selector = 58, .name = "IPv6 DHCPv6 Static DUID", .size = 18 },
    .{ .selector = 59, .name = "IPv6 Dynamic Address", .size = 20 },
    .{ .selector = 60, .name = "IPv6 DHCPv6 Dynamic DUID Storage Length", .size = 1 },
    .{ .selector = 61, .name = "IPv6 DHCPv6 Dynamic DUID", .size = 18 },
    .{ .selector = 62, .name = "IPv6 DHCPv6 Timing Configuration Support", .size = 1 },
    .{ .selector = 63, .name = "IPv6 DHCPv6 Timing Configuration", .size = 18 },
    .{ .selector = 64, .name = "IPv6 Router Address Configuration Control", .size = 1 },
    .{ .selector = 65, .name = "IPv6 Static Router 1 IP Address", .size = 16 },
    .{ .selector = 66, .name = "IPv6 Static Router 1 MAC Address", .size = 6 },
    .{ .selector = 67, .name = "IPv6 Static Router 1 Prefix Length", .size = 1 },
    .{ .selector = 68, .name = "IPv6 Static Router 1 Prefix Value", .size = 16 },
    .{ .selector = 69, .name = "IPv6 Static Router 2 IP Address", .size = 16 },
    .{ .selector = 70, .name = "IPv6 Static Router 2 MAC Address", .size = 6 },
    .{ .selector = 71, .name = "IPv6 Static Router 2 Prefix Length", .size = 1 },
    .{ .selector = 72, .name = "IPv6 Static Router 2 Prefix Value", .size = 16 },
    .{ .selector = 73, .name = "IPv6 Number of Dynamic Router Info Sets", .size = 1 },
    .{ .selector = 74, .name = "IPv6 Dynamic Router Info IP Address", .size = 17 },
    .{ .selector = 75, .name = "IPv6 Dynamic Router Info MAC Address", .size = 7 },
    .{ .selector = 76, .name = "IPv6 Dynamic Router Info Prefix Length", .size = 2 },
    .{ .selector = 77, .name = "IPv6 Dynamic Router Info Prefix Value", .size = 17 },
    .{ .selector = 78, .name = "IPv6 Dynamic Router Received Hop Limit", .size = 1 },
    .{ .selector = 79, .name = "IPv6 ND/SLAAC Timing Configuration Support", .size = 1 },
    .{ .selector = 80, .name = "IPv6 ND/SLAAC Timing Configuration", .size = 18 },
    .{ .selector = 0, .name = null, .size = 0 },
};

const lanp_cc_vals = [_]Valstr{
    .{ .val = 0x80, .str = "Parameter not supported" },
    .{ .val = 0x81, .str = "Set already in progress" },
    .{ .val = 0x82, .str = "Parameter is read-only" },
    .{ .val = 0x83, .str = "Write-only parameter" },
    .{ .val = 0, .str = null },
};
const ip6_enable_vals = [_]Valstr{
    .{ .val = 0, .str = "ipv4" }, .{ .val = 1, .str = "ipv6" },
    .{ .val = 2, .str = "both" }, .{ .val = 0xff, .str = null },
};
const ip6_addr_enable_vals = [_]Valstr{
    .{ .val = 0, .str = "disable" }, .{ .val = 0x80, .str = "enable" },
    .{ .val = 0xff, .str = null },
};
const ip6_addr_sources = [_]Valstr{
    .{ .val = 0, .str = "static" }, .{ .val = 1, .str = "SLAAC" },
    .{ .val = 2, .str = "DHCPv6" }, .{ .val = 0, .str = null },
};
const ip6_addr_statuses = [_]Valstr{
    .{ .val = 0, .str = "active" },     .{ .val = 1, .str = "disabled" },
    .{ .val = 2, .str = "pending" },    .{ .val = 3, .str = "failed" },
    .{ .val = 4, .str = "deprecated" }, .{ .val = 5, .str = "invalid" },
    .{ .val = 0xff, .str = null },
};
const ip6_duid_types = [_]Valstr{
    .{ .val = 0, .str = "unknown" }, .{ .val = 1, .str = "DUID-LLT" },
    .{ .val = 2, .str = "DUID-EN" }, .{ .val = 3, .str = "DUID-LL" },
    .{ .val = 0xff, .str = null },
};
const ip6_cfg_sup_vals = [_]Valstr{
    .{ .val = 0, .str = "not supported" }, .{ .val = 1, .str = "global" },
    .{ .val = 2, .str = "per interface" }, .{ .val = 0xff, .str = null },
};
const ip6_rtr_configs = [_]Valstr{
    .{ .val = 1, .str = "static" }, .{ .val = 2, .str = "dynamic" },
    .{ .val = 3, .str = "both" },   .{ .val = 0xff, .str = null },
};
const ip6_command_vals = [_]Valstr{
    .{ .val = cmd_set, .str = "set" },       .{ .val = cmd_save, .str = "save" },
    .{ .val = cmd_print, .str = "print" },   .{ .val = cmd_lock, .str = "lock" },
    .{ .val = cmd_commit, .str = "commit" }, .{ .val = cmd_discard, .str = "discard" },
    .{ .val = cmd_help, .str = "help" },     .{ .val = cmd_any, .str = null },
};

fn descriptor(
    name: [*:0]const u8,
    format: ?[*:0]const u8,
    size: c_uint,
    access: u2,
    is_set: u1,
    first_set: u1,
    has_blocks: u1,
    specific: c_int,
) Cfgp {
    return .{
        .name = name,
        .format = if (format) |f| f else null,
        .size = size,
        .flags = .{
            .access = access,
            .is_set = is_set,
            .first_set = first_set,
            .has_blocks = has_blocks,
            .first_block = 0,
        },
        .specific = specific,
    };
}

const rw = 0;
const ro = 1;
const lan_cfgp = [_]Cfgp{
    descriptor("support", null, 1, ro, 0, 0, 0, support),
    descriptor("enables", "{ipv4|ipv6|both}", 1, rw, 0, 0, 0, enables),
    descriptor("traffic_class", "<value>", 1, rw, 0, 0, 0, traffic_class),
    descriptor("static_hops", "<value>", 1, rw, 0, 0, 0, static_hops),
    descriptor("flow_label", "<value>", 3, rw, 0, 0, 0, flow_label),
    descriptor("status", null, 3, ro, 0, 0, 0, status),
    descriptor("static_addr", "{enable|disable} <addr> <pfx_len>", 20, rw, 1, 0, 0, static_addr),
    descriptor("static_duid_stg", null, 1, ro, 0, 0, 0, static_duid_stg),
    descriptor("static_duid", "<data>", 18, rw, 1, 0, 1, static_duid),
    descriptor("dynamic_addr", null, 20, ro, 1, 0, 0, dynamic_addr),
    descriptor("dynamic_duid_stg", null, 1, ro, 0, 0, 0, dynamic_duid_stg),
    descriptor("dynamic_duid", "<data>", 18, rw, 1, 0, 1, dynamic_duid),
    descriptor("dhcp6_cfg_sup", null, 1, ro, 0, 0, 0, dhcp_cfg_sup),
    descriptor("dhcp6_cfg", "<data> <data>", 36, rw, 1, 0, 0, dhcp_cfg),
    descriptor("rtr_cfg", "{static|dynamic|both}", 1, rw, 0, 0, 0, router_cfg),
    descriptor("static_rtr", "<addr> <macaddr> <prefix> <prefix_len>", 43, rw, 1, 1, 0, static_router),
    descriptor("num_dynamic_rtrs", null, 1, ro, 0, 0, 0, num_dynamic_rtrs),
    descriptor("dynamic_rtr", null, 43, ro, 1, 0, 0, dynamic_router),
    descriptor("dynamic_hops", null, 1, ro, 0, 0, 0, dynamic_hops),
    descriptor("ndslaac_cfg_sup", null, 1, ro, 0, 0, 0, ndslaac_cfg_sup),
    descriptor("ndslaac_cfg", "<data>", 18, rw, 1, 0, 0, ndslaac_cfg),
};

fn vals(table: anytype) [*c]const Valstr {
    return @ptrCast(table);
}

fn val(table: anytype, value: u32) [*c]const u8 {
    return c.val2str(value, vals(table));
}

fn parseVal(text: [*c]const u8, table: anytype) u8 {
    return @truncate(c.str2val32(text, vals(table)));
}

fn lookup(param: c_int) callconv(.c) ?*const Lanp {
    for (generic_lanp6[0 .. generic_lanp6.len - 1]) |*item| {
        if (item.selector == param) return item;
    }
    return null;
}

fn lanError(rsp: ?*Response, param: *const Lanp, action: [*:0]const u8, quiet: c_int) c_int {
    const reason: [*c]const u8 = if (rsp) |response| blk: {
        const cc = response.ccode;
        if (quiet == 1 and (cc == 0x80 or cc == c.IPMI_CC_PARAM_OUT_OF_RANGE or
            cc == c.IPMI_CC_INV_DATA_FIELD_IN_REQ)) return cc;
        break :blk c.val2str(cc, if (cc >= 0xc0) c.completion_code_vals else vals(&lanp_cc_vals));
    } else "No response";
    c.lprintf(if (rsp != null and rsp.?.ccode == 0) log.Level.debug else log.Level.err, "Failed to %s %s: %s", action, param.name, reason);
    return if (rsp) |response| response.ccode else -1;
}

fn copyReply(rsp: *const Response, out: []u8) bool {
    if (rsp.data_len < 1 or rsp.data_len > rsp.data.len) return false;
    @memset(out, 0);
    const n = @min(out.len, @as(usize, @intCast(rsp.data_len - 1)));
    @memcpy(out[0..n], rsp.data[1..][0..n]);
    return true;
}

fn getDynamic(
    priv: ?*anyopaque,
    maybe_param: ?*const Lanp,
    base: c_int,
    set: c_int,
    block: c_int,
    maybe_data: ?*anyopaque,
    quiet: c_int,
) callconv(.c) c_int {
    const lp: *Priv = @ptrCast(@alignCast(priv orelse return -1));
    const param = maybe_param orelse return -1;
    const raw: [*]u8 = @ptrCast(maybe_data orelse return -1);
    if (lp.intf == null or param.size < 0 or param.size > 1024 or
        base < 0 or base > 255 or param.selector < 0 or param.selector > 255 - base or
        set < 0 or set > 255 or block < 0 or block > 255 or
        lp.channel < 0 or lp.channel > 255) return -1;
    const intf: *Intf = @ptrCast(@alignCast(lp.intf));
    const send = intf.sendrecv orelse return -1;
    var payload = [_]u8{
        @intCast(lp.channel), @intCast(param.selector + base), @intCast(set), @intCast(block),
    };
    var req: Request = .{ .msg = .{
        .netfn_lun = .{ .netfn = 0x0c, .lun = 0 },
        .cmd = 2,
        .target_cmd = 0,
        .data_len = 4,
        .data = &payload,
    } };
    c.lprintf(log.Level.info, "Getting parameter '%s' set %d block %d", param.name, set, block);
    const rsp = send(intf, &req) orelse return lanError(null, param, "get", quiet);
    if (rsp.ccode != 0) return lanError(rsp, param, "get", quiet);
    // A successful reply includes a parameter revision byte. The C version
    // copied from data + 1 even if data_len was zero (a negative copy size).
    if (!copyReply(rsp, raw[0..@intCast(param.size)])) {
        c.lprintf(log.Level.err, "Failed to get %s: Invalid response length", param.name);
        return -1;
    }
    return 0;
}

fn get(
    priv: ?*anyopaque,
    param: c_int,
    set: c_int,
    block: c_int,
    data: ?*anyopaque,
    quiet: c_int,
) callconv(.c) c_int {
    return getDynamic(priv, lookup(param), 0, set, block, data, quiet);
}

fn setDynamic(
    priv: ?*anyopaque,
    maybe_param: ?*const Lanp,
    base: c_int,
    maybe_data: ?*const anyopaque,
) callconv(.c) c_int {
    const lp: *Priv = @ptrCast(@alignCast(priv orelse return -1));
    const param = maybe_param orelse return -1;
    const data: [*]const u8 = @ptrCast(maybe_data orelse return -1);
    if (lp.intf == null or param.size < 0 or param.size > 30 or
        base < 0 or base > 255 or param.selector < 0 or param.selector > 255 - base or
        lp.channel < 0 or lp.channel > 255) return -1;
    const intf: *Intf = @ptrCast(@alignCast(lp.intf));
    const send = intf.sendrecv orelse return -1;
    const n: usize = @intCast(param.size);
    var payload: [32]u8 = undefined;
    payload[0] = @intCast(lp.channel);
    payload[1] = @intCast(param.selector + base);
    @memcpy(payload[2..][0..n], data[0..n]);
    var req: Request = .{ .msg = .{
        .netfn_lun = .{ .netfn = 0x0c, .lun = 0 },
        .cmd = 1,
        .target_cmd = 0,
        .data_len = @intCast(n + 2),
        .data = &payload,
    } };
    c.lprintf(log.Level.info, "Setting parameter '%s'", param.name);
    const rsp = send(intf, &req);
    if (rsp == null or rsp.?.ccode != 0) return lanError(rsp, param, "set", 0);
    return 0;
}

fn setParam(priv: ?*anyopaque, param: c_int, data: ?*const anyopaque) callconv(.c) c_int {
    return setDynamic(priv, lookup(param), 0, data);
}

fn invalidValue() c_int {
    c.lprintf(log.Level.err, "invalid value");
    return -1;
}

fn validPrefix(prefix: u8) bool {
    return prefix <= 128;
}

fn parseCfgp(
    p: *const Cfgp,
    set_selector: c_int,
    block_selector: c_int,
    argc: c_int,
    argv: [*c][*c]const u8,
    data: []u8,
) c_int {
    if (argc == 0) return -1;
    if (set_selector < 0 or set_selector > 255 or block_selector < 0 or block_selector > 255)
        return invalidValue();
    const set_byte: u8 = @intCast(set_selector);
    const block_byte: u8 = @intCast(block_selector);

    switch (p.specific) {
        enables => {
            data[0] = parseVal(argv[0], &ip6_enable_vals);
            if (data[0] == 0xff) return invalidValue();
        },
        flow_label => {
            var v: c_uint = 0;
            if (c.str2uint(argv[0], &v) != 0) return invalidValue();
            data[0] = @truncate((v >> 16) & 0x0f);
            data[1] = @truncate(v >> 8);
            data[2] = @truncate(v);
        },
        status => {
            if (argc < 3) return -1;
            if (c.str2uchar(argv[0], &data[0]) != 0 or
                c.str2uchar(argv[1], &data[1]) != 0 or
                c.str2uchar(argv[2], &data[2]) != 0) return invalidValue();
        },
        static_addr, dynamic_addr => {
            if (argc < 3) return -1;
            data[0] = set_byte;
            data[1] = parseVal(argv[0], if (p.specific == static_addr) &ip6_addr_enable_vals else &ip6_addr_sources);
            if (data[1] == 0xff) return invalidValue();
            if (c.inet_pton(c.AF_INET6, argv[1], &data[2]) != 1 or
                c.str2uchar(argv[2], &data[18]) != 0 or !validPrefix(data[18])) return invalidValue();
            if (argc >= 4) data[19] = parseVal(argv[3], &ip6_addr_statuses);
        },
        static_duid, dynamic_duid, ndslaac_cfg => {
            data[0] = set_byte;
            data[1] = block_byte;
            if (c.ipmi_parse_hex(argv[0], &data[2], 16) < 0) return invalidValue();
        },
        dhcp_cfg => {
            data[0] = set_byte;
            data[1] = 0;
            data[18] = set_byte;
            data[19] = 1;
            if (c.ipmi_parse_hex(argv[0], &data[2], 16) < 0 or
                (argc > 1 and c.ipmi_parse_hex(argv[1], &data[20], 6) < 0))
                return invalidValue();
        },
        router_cfg => {
            data[0] = parseVal(argv[0], &ip6_rtr_configs);
            if (data[0] == 0xff) return invalidValue();
        },
        static_router, dynamic_router => {
            if (p.specific == static_router and set_selector > 2) return invalidValue();
            if (argc < 4) return -1;
            data[0] = set_byte;
            data[17] = set_byte;
            data[24] = set_byte;
            data[26] = set_byte;
            if (c.inet_pton(c.AF_INET6, argv[0], &data[1]) != 1 or
                c.str2mac(argv[1], &data[18]) != 0 or
                c.inet_pton(c.AF_INET6, argv[2], &data[27]) != 1 or
                c.str2uchar(argv[3], &data[25]) != 0 or !validPrefix(data[25])) return invalidValue();
        },
        else => if (c.str2uchar(argv[0], &data[0]) != 0) return invalidValue(),
    }
    return 0;
}

fn setCfgp(priv: ?*anyopaque, p: *const Cfgp, data: []const u8) c_int {
    var param = p.specific;
    switch (param) {
        dhcp_cfg => {
            const ret = setParam(priv, param, &data[0]);
            return if (ret == 0) setParam(priv, param, &data[18]) else ret;
        },
        static_router, dynamic_router => {
            const offset: usize = if (param == static_router) 1 else 0;
            if (offset == 1 and data[0] == 2) param = static_router2;
            const offsets = [_]usize{ 0 + offset, 17 + offset, 24 + offset, 26 + offset };
            for (offsets, 0..) |i, n| {
                const ret = setParam(priv, param + @as(c_int, @intCast(n)), &data[i]);
                if (ret != 0) return ret;
            }
            return 0;
        },
        else => return setParam(priv, param, &data[0]),
    }
}

fn getCfgp(priv: ?*anyopaque, p: *const Cfgp, selector: c_int, block: c_int, data: []u8, quiet: c_int) c_int {
    var param = p.specific;
    switch (param) {
        dhcp_cfg => {
            const ret = get(priv, param, selector, 0, &data[0], quiet);
            return if (ret == 0) get(priv, param, selector, 1, &data[18], quiet) else ret;
        },
        static_router, dynamic_router => {
            var wire_set = selector;
            const offset: usize = if (param == static_router) 1 else 0;
            if (offset == 1) {
                if (selector > 2) return -1;
                if (selector == 2) param = static_router2;
                wire_set = 0;
                for ([_]usize{ 0, 17, 24, 26 }) |i| data[i] = 0;
            }
            const offsets = [_]usize{ 0 + offset, 17 + offset, 24 + offset, 26 + offset };
            for (offsets, 0..) |i, n| {
                const ret = get(priv, param + @as(c_int, @intCast(n)), wire_set, block, &data[i], if (n == 0) quiet else 0);
                if (ret != 0) return ret;
            }
            return 0;
        },
        else => return get(priv, param, selector, block, &data[0], quiet),
    }
}

fn ipv6(file_data: []const u8, buffer: *[c.INET6_ADDRSTRLEN]u8) [*c]const u8 {
    return c.inet_ntop(c.AF_INET6, @ptrCast(file_data.ptr), buffer, buffer.len);
}

fn saveCfgp(p: *const Cfgp, data: []const u8, file: *File) c_int {
    var address: [c.INET6_ADDRSTRLEN]u8 = undefined;
    var prefix: [c.INET6_ADDRSTRLEN]u8 = undefined;
    switch (p.specific) {
        enables => _ = c.fputs(val(&ip6_enable_vals, data[0]), file),
        flow_label => _ = c.fprintf(file, "0x%xd", (@as(c_int, data[0]) << 16) |
            (@as(c_int, data[1]) << 8) | data[2]),
        status => _ = c.fprintf(file, "%d %d %d", @as(c_int, data[0]), @as(c_int, data[1]), @as(c_int, data[2])),
        static_addr, dynamic_addr => {
            const source = val(if (p.specific == static_addr) &ip6_addr_enable_vals else &ip6_addr_sources, data[1]);
            _ = c.fprintf(file, "%s %s %d %s", source, ipv6(data[2..18], &address), @as(c_int, data[18]), val(&ip6_addr_statuses, data[19]));
        },
        static_duid, dynamic_duid, ndslaac_cfg => {
            _ = c.fprintf(file, "%s", c.buf2str(&data[2], 16));
        },
        dhcp_cfg => {
            _ = c.fprintf(file, "%s", c.buf2str(&data[2], 16));
            _ = c.fprintf(file, " %s", c.buf2str(&data[20], 6));
        },
        router_cfg => _ = c.fputs(val(&ip6_rtr_configs, data[0]), file),
        static_router, dynamic_router => {
            _ = c.fprintf(file, "%s %s %s %d", ipv6(data[1..17], &address), c.mac2str(&data[18]), ipv6(data[27..43], &prefix), @as(c_int, data[25]));
        },
        else => _ = c.fprintf(file, "%d", @as(c_int, data[0])),
    }
    return 0;
}

fn printCfgp(p: *const Cfgp, selector: c_int, block: c_int, data: []const u8, file: *File) c_int {
    const param = lookup(p.specific) orelse return -1;
    const name = param.name;
    var address: [c.INET6_ADDRSTRLEN]u8 = undefined;
    var prefix: [c.INET6_ADDRSTRLEN]u8 = undefined;
    switch (p.specific) {
        support => _ = c.fprintf(file, "%s:\n" ++
            "    IPv6 only: %s\n" ++
            "    IPv4 and IPv6: %s\n" ++
            "    IPv6 Destination Addresses for LAN alerting: %s\n", name, yes(data[0] & 1 != 0), yes(data[0] & 2 != 0), yes(data[0] & 4 != 0)),
        enables => _ = c.fprintf(file, "%s: %s\n", name, val(&ip6_enable_vals, data[0])),
        flow_label => _ = c.fprintf(file, "%s: %d\n", name, (@as(c_int, data[0]) << 16) | (@as(c_int, data[1]) << 8) | data[2]),
        status => _ = c.fprintf(file, "%s:\n" ++
            "    Static address max:  %d\n" ++
            "    Dynamic address max: %d\n" ++
            "    DHCPv6 support:      %s\n" ++
            "    SLAAC support:       %s\n", name, @as(c_int, data[0]), @as(c_int, data[1]), yes(data[2] & 1 != 0), yes(data[2] & 2 != 0)),
        static_addr => _ = c.fprintf(file, "%s %d:\n" ++
            "    Enabled:        %s\n" ++
            "    Address:        %s/%d\n" ++
            "    Status:         %s\n", name, selector, yes(data[1] & 0x80 != 0), ipv6(data[2..18], &address), @as(c_int, data[18]), val(&ip6_addr_statuses, data[19] & 0xf)),
        dynamic_addr => _ = c.fprintf(file, "%s %d:\n" ++
            "    Source/Type:    %s\n" ++
            "    Address:        %s/%d\n" ++
            "    Status:         %s\n", name, selector, val(&ip6_addr_sources, data[1] & 0xf), ipv6(data[2..18], &address), @as(c_int, data[18]), val(&ip6_addr_statuses, data[19] & 0xf)),
        static_duid, dynamic_duid => {
            if (block == 0) _ = c.fprintf(file, "%s %d:\n" ++
                "    Length:   %d\n" ++
                "    Type:     %s\n", name, selector, @as(c_int, data[2]), val(&ip6_duid_types, (@as(u32, data[3]) << 8) + data[4]));
            _ = c.fprintf(file, "    %s\n", c.buf2str(&data[2], 16));
        },
        dhcp_cfg_sup, ndslaac_cfg_sup => _ = c.fprintf(file, "%s: %s\n", name, val(&ip6_cfg_sup_vals, data[0])),
        dhcp_cfg => {
            _ = c.fprintf(file, "%s %d:\n", name, selector);
            _ = c.fprintf(file, "    SOL_MAX_DELAY:   %d\n" ++
                "    SOL_TIMEOUT:     %d\n" ++
                "    SOL_MAX_RT:      %d\n" ++
                "    REQ_TIMEOUT:     %d\n" ++
                "    REQ_MAX_RT:      %d\n" ++
                "    REQ_MAX_RC:      %d\n" ++
                "    CNF_MAX_DELAY:   %d\n" ++
                "    CNF_TIMEOUT:     %d\n" ++
                "    CNF_MAX_RT:      %d\n" ++
                "    CNF_MAX_RD:      %d\n" ++
                "    REN_TIMEOUT:     %d\n" ++
                "    REN_MAX_RT:      %d\n" ++
                "    REB_TIMEOUT:     %d\n" ++
                "    REB_MAX_RT:      %d\n" ++
                "    INF_MAX_DELAY:   %d\n" ++
                "    INF_TIMEOUT:     %d\n" ++
                "    INF_MAX_RT:      %d\n" ++
                "    REL_TIMEOUT:     %d\n" ++
                "    REL_MAX_RC:      %d\n" ++
                "    DEC_TIMEOUT:     %d\n" ++
                "    DEC_MAX_RC:      %d\n" ++
                "    HOP_COUNT_LIMIT: %d\n", @as(c_int, data[2]), @as(c_int, data[3]), @as(c_int, data[4]), @as(c_int, data[5]), @as(c_int, data[6]), @as(c_int, data[7]), @as(c_int, data[8]), @as(c_int, data[9]), @as(c_int, data[10]), @as(c_int, data[11]), @as(c_int, data[12]), @as(c_int, data[13]), @as(c_int, data[14]), @as(c_int, data[15]), @as(c_int, data[16]), @as(c_int, data[17]), @as(c_int, data[20]), @as(c_int, data[21]), @as(c_int, data[22]), @as(c_int, data[23]), @as(c_int, data[24]), @as(c_int, data[25]));
        },
        router_cfg => _ = c.fprintf(file, "%s:\n" ++
            "    Enable static router address:  %s\n" ++
            "    Enable dynamic router address: %s\n", name, yes(data[0] & 1 != 0), yes(data[0] & 2 != 0)),
        static_router, dynamic_router => {
            const label: [*:0]const u8 =
                if (p.specific == static_router) "IPv6 Static Router" else "IPv6 Dynamic Router";
            _ = c.fprintf(file, "%s %d:\n" ++
                "    Address: %s\n" ++
                "    MAC:     %s\n" ++
                "    Prefix:  %s/%d\n", label, selector, ipv6(data[1..17], &address), c.mac2str(&data[18]), ipv6(data[27..43], &prefix), @as(c_int, data[25]));
        },
        ndslaac_cfg => _ = c.fprintf(file, "%s %d:\n" ++
            "    MAX_RTR_SOLICITATION_DELAY: %d\n" ++
            "    RTR_SOLICITATION_INTERVAL:  %d\n" ++
            "    MAX_RTR_SOLICITATIONS:      %d\n" ++
            "    DupAddrDetectTransmits:     %d\n" ++
            "    MAX_MULTICAST_SOLICIT:      %d\n" ++
            "    MAX_UNICAST_SOLICIT:        %d\n" ++
            "    MAX_ANYCAST_DELAY_TIME:     %d\n" ++
            "    MAX_NEIGHBOR_ADVERTISEMENT: %d\n" ++
            "    REACHABLE_TIME:             %d\n" ++
            "    RETRANS_TIMER:              %d\n" ++
            "    DELAY_FIRST_PROBE_TIME:     %d\n" ++
            "    MAX_RANDOM_FACTOR:          %d\n" ++
            "    MIN_RANDOM_FACTOR:          %d\n", name, selector, @as(c_int, data[2]), @as(c_int, data[3]), @as(c_int, data[4]), @as(c_int, data[5]), @as(c_int, data[6]), @as(c_int, data[7]), @as(c_int, data[8]), @as(c_int, data[9]), @as(c_int, data[10]), @as(c_int, data[11]), @as(c_int, data[12]), @as(c_int, data[13]), @as(c_int, data[14])),
        else => _ = c.fprintf(file, "%s: %d\n", name, @as(c_int, data[0])),
    }
    return 0;
}

fn yes(condition: bool) [*:0]const u8 {
    return if (condition) "yes" else "no";
}

fn handler(priv: ?*anyopaque, raw: ?*const c.struct_ipmi_cfgp, raw_action: [*c]const Action, raw_data: [*c]u8) callconv(.c) c_int {
    if (raw == null or raw_action == null or raw_data == null) return -1;
    const p: *const Cfgp = @ptrCast(@alignCast(raw));
    const action = &raw_action[0];
    if (p.size == 0 or p.size > 43) return -1;
    const data = raw_data[0..p.size];
    return switch (action.type) {
        c.CFGP_PARSE => parseCfgp(p, action.set, action.block, action.argc, action.argv, data),
        c.CFGP_GET => getCfgp(priv, p, action.set, action.block, data, action.quiet),
        c.CFGP_SET => setCfgp(priv, p, data),
        c.CFGP_SAVE => if (action.file) |file| saveCfgp(p, data, file) else -1,
        c.CFGP_PRINT => if (action.file) |file| printCfgp(p, action.set, action.block, data, file) else -1,
        else => -1,
    };
}

fn usage(cmd: c_int) void {
    if (cmd == cmd_any or cmd == cmd_help) _ = c.printf("  help [command]\n");
    if (cmd == cmd_any or cmd == cmd_save) _ = c.printf("  save <channel> [<parameter> [<set_sel> [<block_sel>]]]\n");
    if (cmd == cmd_any or cmd == cmd_set) _ = c.printf("  set <channel> [nolock] <parameter> [<set_sel> [<block_sel>]] <values...>\n");
    if (cmd == cmd_any or cmd == cmd_print) _ = c.printf("  print <channel> [<parameter> [<set_sel> [<block_sel>]]]\n");
    if (cmd == cmd_any or cmd == cmd_lock) _ = c.printf("  lock <channel>\n");
    if (cmd == cmd_any or cmd == cmd_commit) _ = c.printf("  commit <channel>\n");
    if (cmd == cmd_any or cmd == cmd_discard) _ = c.printf("  discard <channel>\n");
    if (cmd == cmd_save or cmd == cmd_print or cmd == cmd_set) {
        _ = c.printf("\n   available parameters:\n");
        c.ipmi_cfgp_usage(@ptrCast(&lan_cfgp), lan_cfgp.len, @intFromBool(cmd != cmd_print));
    }
}

fn lock(lp: *Priv) c_int {
    var byte: u8 = 1;
    return setParam(lp, 0, &byte);
}

fn discard(lp: *Priv) c_int {
    var byte: u8 = 0;
    return setParam(lp, 0, &byte);
}

fn commit(lp: *Priv) c_int {
    var byte: u8 = 2;
    const ret = setParam(lp, 0, &byte);
    return if (ret == 0) discard(lp) else ret;
}

fn main(intf: *Intf, input_argc: c_int, input_argv: [*c][*c]u8) callconv(.c) c_int {
    var argc = input_argc;
    var argv = input_argv;
    if (argc == 0) {
        usage(cmd_any);
        return 0;
    }

    var cmd: c_int = parseVal(argv[0], &ip6_command_vals);
    if (cmd == cmd_any) {
        usage(cmd);
        return -1;
    }
    if (cmd == cmd_help) {
        cmd = if (argc == 1) cmd_any else parseVal(argv[1], &ip6_command_vals);
        usage(cmd);
        return 0;
    }

    var channel: c_int = 0;
    var nolock = false;
    if (argc == 1) {
        if (cmd != cmd_save and cmd != cmd_print) {
            usage(cmd);
            return -1;
        }
        channel = c.find_lan_channel(@ptrCast(intf), 1);
        if (channel == 0) {
            c.lprintf(log.Level.err, "No LAN channel found");
            return -1;
        }
        argc -= 1;
        argv += 1;
    } else {
        if (c.str2int(argv[1], &channel) != 0) {
            c.lprintf(log.Level.err, "Invalid channel: %s", argv[1]);
            return -1;
        }
        // A LAN channel is 0..14 or 0xe (current channel). Do not truncate a
        // signed int into a different on-wire channel.
        if (channel < 0 or channel > 0x0e) {
            c.lprintf(log.Level.err, "Invalid channel: %s", argv[1]);
            return -1;
        }
        argc -= 2;
        argv += 2;
        if (cmd == cmd_set and argc != 0 and c.strcasecmp(argv[0], "nolock") == 0) {
            nolock = true;
            argc -= 1;
            argv += 1;
        }
    }

    var lp: Priv = .{ .intf = @ptrCast(intf), .channel = channel };
    switch (cmd) {
        cmd_lock => {
            c.lprintf(log.Level.notice, "Lock parameter(s)...");
            return lock(&lp);
        },
        cmd_commit => {
            c.lprintf(log.Level.notice, "Commit parameter(s)...");
            return commit(&lp);
        },
        cmd_discard => {
            c.lprintf(log.Level.notice, "Discard parameter(s)...");
            return discard(&lp);
        },
        else => {},
    }

    var ctx: CfgpCtx = undefined;
    if (c.ipmi_cfgp_init(&ctx, @ptrCast(&lan_cfgp), lan_cfgp.len, "lan6 set nolock", handler, &lp) != 0) return -1;
    defer _ = c.ipmi_cfgp_uninit(&ctx);
    var sel: CfgpSel = undefined;
    const parsed = c.ipmi_cfgp_parse_sel(&ctx, argc, @ptrCast(argv), &sel);
    if (parsed == -1) {
        usage(cmd);
        return -1;
    }
    argc -= parsed;
    argv += @intCast(parsed);

    switch (cmd) {
        cmd_save, cmd_print => {
            c.lprintf(log.Level.notice, "Getting parameter(s)...");
            if (c.ipmi_cfgp_get(&ctx, &sel) != 0) return -1;
            if (cmd == cmd_print) return c.ipmi_cfgp_print(&ctx, &sel, c.stdout);
            var saved_cmd: [20]u8 = undefined;
            _ = c.snprintf(&saved_cmd, saved_cmd.len - 1, "lan6 set %d nolock", channel);
            saved_cmd[saved_cmd.len - 1] = 0;
            ctx.cmdname = &saved_cmd;
            _ = c.fprintf(c.stdout, "lan6 lock %d\n", channel);
            const ret = c.ipmi_cfgp_save(&ctx, &sel, c.stdout);
            _ = c.fprintf(c.stdout, "lan6 commit %d\nlan6 discard %d\nexit\n", channel, channel);
            return ret;
        },
        cmd_set => {
            if (c.ipmi_cfgp_parse_data(&ctx, &sel, argc, @ptrCast(argv)) != 0) return -1;
            c.lprintf(log.Level.notice, "Setting parameter(s)...");
            if (!nolock and lock(&lp) != 0) return -1;
            const ret = c.ipmi_cfgp_set(&ctx, &sel);
            if (nolock) return ret;
            if (ret == 0) return commit(&lp);
            _ = discard(&lp);
            return ret;
        },
        else => return -1,
    }
}

comptime {
    abi.assertOpaqueLayout(Cfgp, .{
        .size = c.ABI_SIZEOF_ipmi_cfgp,
        .alignment = c.ABI_ALIGNOF_ipmi_cfgp,
        .fields = &.{
            .{ .name = "name", .offset = c.ABI_OFFSETOF_ipmi_cfgp__name },
            .{ .name = "format", .offset = c.ABI_OFFSETOF_ipmi_cfgp__format },
            .{ .name = "size", .offset = c.ABI_OFFSETOF_ipmi_cfgp__size },
            .{ .name = "specific", .offset = c.ABI_OFFSETOF_ipmi_cfgp__specific },
        },
    });
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(lookup), @TypeOf(c.lookup_lanp));
    abi.assertCallSignature(@TypeOf(getDynamic), @TypeOf(c.ipmi_get_dynamic_oem_lanp));
    abi.assertCallSignature(@TypeOf(get), @TypeOf(c.ipmi_get_lanp));
    abi.assertCallSignature(@TypeOf(setDynamic), @TypeOf(c.ipmi_set_dynamic_oem_lanp));
    abi.assertCallSignature(@TypeOf(setParam), @TypeOf(c.ipmi_set_lanp));
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_lan6_main));
    @export(&generic_lanp6, .{ .name = "generic_lanp6", .linkage = .strong });
    @export(&lanp_cc_vals, .{ .name = "lanp_cc_vals", .linkage = .strong });
    @export(&ip6_enable_vals, .{ .name = "ip6_enable_vals", .linkage = .strong });
    @export(&ip6_addr_enable_vals, .{ .name = "ip6_addr_enable_vals", .linkage = .strong });
    @export(&ip6_addr_sources, .{ .name = "ip6_addr_sources", .linkage = .strong });
    @export(&ip6_addr_statuses, .{ .name = "ip6_addr_statuses", .linkage = .strong });
    @export(&ip6_duid_types, .{ .name = "ip6_duid_types", .linkage = .strong });
    @export(&ip6_cfg_sup_vals, .{ .name = "ip6_cfg_sup_vals", .linkage = .strong });
    @export(&ip6_rtr_configs, .{ .name = "ip6_rtr_configs", .linkage = .strong });
    @export(&ip6_command_vals, .{ .name = "ip6_command_vals", .linkage = .strong });
    @export(&lookup, .{ .name = "lookup_lanp", .linkage = .strong });
    @export(&getDynamic, .{ .name = "ipmi_get_dynamic_oem_lanp", .linkage = .strong });
    @export(&get, .{ .name = "ipmi_get_lanp", .linkage = .strong });
    @export(&setDynamic, .{ .name = "ipmi_set_dynamic_oem_lanp", .linkage = .strong });
    @export(&setParam, .{ .name = "ipmi_set_lanp", .linkage = .strong });
    @export(&main, .{ .name = "ipmi_lan6_main", .linkage = .strong });
}

test "LAN6 short BMC replies are zero-padded without reading past the payload" {
    var rsp: Response = std.mem.zeroes(Response);
    var bytes = [_]u8{0xaa} ** 4;
    try std.testing.expect(!copyReply(&rsp, &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa }, &bytes);
    rsp.data_len = 1;
    try std.testing.expect(copyReply(&rsp, &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &bytes);
    rsp.data_len = 3;
    rsp.data[1] = 0x12;
    rsp.data[2] = 0x34;
    try std.testing.expect(copyReply(&rsp, &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0, 0 }, &bytes);
    rsp.data_len = 1025;
    try std.testing.expect(!copyReply(&rsp, &bytes));
}

test "LAN6 IPv6 prefix limits" {
    try std.testing.expect(validPrefix(0));
    try std.testing.expect(validPrefix(128));
    try std.testing.expect(!validPrefix(129));
    try std.testing.expect(!validPrefix(255));
}
