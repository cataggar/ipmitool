//! HPM.2 LAN attach and channel capability queries (`lib/hpm2.c`).
//!
//! No allocations: the caller owns the capability structs and both request
//! bodies live on the stack. A failed query leaves its output zeroed except
//! for fields already copied from a well-formed response, as in the C API.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const Attach = extern struct {
    hpm2_revision_id: u8,
    lan_channel_mask: u16 align(1),
    hpm2_caps: u8,
    hpm2_lan_params_start: u8,
    hpm2_lan_params_rev: u8,
    hpm2_sol_params_start: u8,
    hpm2_sol_params_rev: u8,
};

const Channel = extern struct {
    capabilities: u8,
    attach_type: u8,
    bandwidth_class: u8,
    max_inbound_pld_size: u16 align(1),
    max_outbound_pld_size: u16 align(1),
};

fn getCapabilities(intf: *Intf, caps: *Attach) callconv(.c) c_int {
    caps.* = std.mem.zeroes(Attach);
    var rq = [_]u8{ 0, 2 };
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = @intCast(c.IPMI_NETFN_PICMG), .lun = 0 };
    req.msg.cmd = c.HPM2_GET_LAN_ATTACH_CAPABILITIES;
    req.msg.data = &rq;
    req.msg.data_len = rq.len;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.notice, "Error sending request.");
        return -1;
    };
    if (rsp.ccode == 0xc1) {
        c.lprintf(log.Level.debug, "IPM Controller is not HPM.2 compatible");
        return rsp.ccode;
    } else if (rsp.ccode != 0) {
        c.lprintf(log.Level.notice, "Get HPM.x Capabilities request failed, compcode = %x", @as(c_uint, rsp.ccode));
        return rsp.ccode;
    }

    if (rsp.data_len < 2 or rsp.data_len > 10) {
        c.lprintf(log.Level.notice, "Bad response length, len=%d", rsp.data_len);
        return -1;
    }
    if (rsp.data[1] != 2) {
        c.lprintf(log.Level.notice, "Bad HPM.x ID, id=%d", @as(c_int, rsp.data[1]));
        return rsp.ccode;
    }
    if (rsp.data_len < 4) {
        c.lprintf(log.Level.notice, "Bad response length, len=%d", rsp.data_len);
        return -1;
    }

    const len: usize = @intCast(rsp.data_len - 2);
    @memcpy(std.mem.asBytes(caps)[0..len], rsp.data[2..][0..len]);
    caps.lan_channel_mask = std.mem.littleToNative(u16, caps.lan_channel_mask);

    if (caps.hpm2_revision_id == 0) {
        c.lprintf(log.Level.notice, "Bad HPM.2 revision, rev=%d", @as(c_int, caps.hpm2_revision_id));
        return -1;
    }
    if (caps.lan_channel_mask == 0) return -1;
    if (rsp.data_len < 8) {
        c.lprintf(log.Level.notice, "Bad response length, len=%d", rsp.data_len);
        return -1;
    }
    if (caps.hpm2_lan_params_start < 0xc0) {
        c.lprintf(log.Level.notice, "Bad HPM.2 LAN params start, start=%x", @as(c_uint, caps.hpm2_lan_params_start));
        return -1;
    }
    if (caps.hpm2_lan_params_rev != c.HPM2_LAN_PARAMS_REV) {
        c.lprintf(log.Level.notice, "Bad HPM.2 LAN params revision, rev=%d", @as(c_int, caps.hpm2_lan_params_rev));
        return -1;
    }
    if (caps.hpm2_caps & c.HPM2_CAPS_SOL_EXTENSION == 0) return 0;
    if (rsp.data_len < 10) {
        c.lprintf(log.Level.notice, "Bad response length, len=%d", rsp.data_len);
        return -1;
    }
    if (caps.hpm2_sol_params_start < 0xc0) {
        c.lprintf(log.Level.notice, "Bad HPM.2 SOL params start, start=%x", @as(c_uint, caps.hpm2_sol_params_start));
        return -1;
    }
    if (caps.hpm2_sol_params_rev != c.HPM2_SOL_PARAMS_REV) {
        c.lprintf(log.Level.notice, "Bad HPM.2 SOL params revision, rev=%d", @as(c_int, caps.hpm2_sol_params_rev));
        return -1;
    }
    return 0;
}

fn getLanChannelCapabilities(intf: *Intf, start: u8, caps: *Channel) callconv(.c) c_int {
    caps.* = std.mem.zeroes(Channel);
    var rq = [_]u8{ 0xe, start, 0, 0 };
    var req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = @intCast(c.IPMI_NETFN_TRANSPORT), .lun = 0 };
    req.msg.cmd = 0x02;
    req.msg.data = &rq;
    req.msg.data_len = rq.len;
    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(log.Level.notice, "Error sending request.");
        return -1;
    };
    if (rsp.ccode == 0x80) {
        c.lprintf(log.Level.debug, "HPM.2 Channel Caps parameter is not supported");
        return rsp.ccode;
    } else if (rsp.ccode != 0) {
        c.lprintf(log.Level.notice, "Get LAN Configuration Parameters request failed, compcode = %x", @as(c_uint, rsp.ccode));
        return rsp.ccode;
    }
    if (rsp.data_len != @sizeOf(Channel) + 1) {
        c.lprintf(log.Level.notice, "Bad response length, len=%d", rsp.data_len);
        return -1;
    }
    if (rsp.data[0] != 0x11) {
        c.lprintf(log.Level.notice, "Bad HPM.2 LAN parameter revision, rev=%d", @as(c_int, rsp.data[0]));
        return -1;
    }
    @memcpy(std.mem.asBytes(caps), rsp.data[1 .. @sizeOf(Channel) + 1]);
    caps.max_inbound_pld_size = std.mem.littleToNative(u16, caps.max_inbound_pld_size);
    caps.max_outbound_pld_size = std.mem.littleToNative(u16, caps.max_outbound_pld_size);
    return 0;
}

fn detectMaxPayloadSize(intf: *Intf) callconv(.c) c_int {
    var attach: Attach = undefined;
    var channel: Channel = undefined;
    const first = getCapabilities(intf, &attach);
    if (first != 0 or attach.lan_channel_mask == 0) return first;
    const second = getLanChannelCapabilities(intf, attach.hpm2_lan_params_start, &channel);
    if (second != 0) return second;

    c.ipmi_intf_set_max_request_data_size(@ptrCast(intf), channel.max_inbound_pld_size -% 7);
    c.ipmi_intf_set_max_response_data_size(@ptrCast(intf), channel.max_outbound_pld_size -% 8);
    c.lprintf(
        log.Level.debug,
        "Set maximum request size to %d\nSet maximum response size to %d",
        @as(c_int, intf.max_request_data_size),
        @as(c_int, intf.max_response_data_size),
    );
    return 0;
}

pub fn exportSymbols() void {
    abi.assertOpaqueLayout(Attach, .{
        .size = c.ABI_SIZEOF_hpm2_attach,
        .alignment = c.ABI_ALIGNOF_hpm2_attach,
        .fields = &.{
            .{ .name = "hpm2_revision_id", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_revision_id },
            .{ .name = "lan_channel_mask", .offset = c.ABI_OFFSETOF_hpm2_attach__lan_channel_mask },
            .{ .name = "hpm2_caps", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_caps },
            .{ .name = "hpm2_lan_params_start", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_lan_params_start },
            .{ .name = "hpm2_lan_params_rev", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_lan_params_rev },
            .{ .name = "hpm2_sol_params_start", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_sol_params_start },
            .{ .name = "hpm2_sol_params_rev", .offset = c.ABI_OFFSETOF_hpm2_attach__hpm2_sol_params_rev },
        },
    });
    abi.assertOpaqueLayout(Channel, .{
        .size = c.ABI_SIZEOF_hpm2_channel,
        .alignment = c.ABI_ALIGNOF_hpm2_channel,
        .fields = &.{
            .{ .name = "capabilities", .offset = c.ABI_OFFSETOF_hpm2_channel__capabilities },
            .{ .name = "attach_type", .offset = c.ABI_OFFSETOF_hpm2_channel__attach_type },
            .{ .name = "bandwidth_class", .offset = c.ABI_OFFSETOF_hpm2_channel__bandwidth_class },
            .{ .name = "max_inbound_pld_size", .offset = c.ABI_OFFSETOF_hpm2_channel__max_inbound_pld_size },
            .{ .name = "max_outbound_pld_size", .offset = c.ABI_OFFSETOF_hpm2_channel__max_outbound_pld_size },
        },
    });
    abi.assertCallSignature(@TypeOf(getCapabilities), @TypeOf(c.hpm2_get_capabilities));
    abi.assertCallSignature(@TypeOf(getLanChannelCapabilities), @TypeOf(c.hpm2_get_lan_channel_capabilities));
    abi.assertCallSignature(@TypeOf(detectMaxPayloadSize), @TypeOf(c.hpm2_detect_max_payload_size));
    @export(&getCapabilities, .{ .name = "hpm2_get_capabilities", .linkage = .strong });
    @export(&getLanChannelCapabilities, .{ .name = "hpm2_get_lan_channel_capabilities", .linkage = .strong });
    @export(&detectMaxPayloadSize, .{ .name = "hpm2_detect_max_payload_size", .linkage = .strong });
}
