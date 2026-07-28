//! Port of `include/ipmitool/ipmi.h`: the request/response types every command
//! module and every transport passes around.
//!
//! The types are `extern struct` mirrors of the C declarations, checked field
//! by field by the `comptime` block at the bottom of the file, so a Zig module
//! and a C module can hand the same pointer back and forth.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const intf_mod = @import("../intf/intf.zig");

/// `IPMI_BUF_SIZE`.
pub const buf_size = 1024;

/// `IPMI_MAX_MD_SIZE`.
pub const max_md_size = 0x20;

/// `IPMI_BMC_SLAVE_ADDR`.
pub const bmc_slave_addr = 0x20;

/// `IPMI_REMOTE_SWID`.
pub const remote_swid = 0x81;

/// Network function codes, `IPMI_NETFN_*`.
pub const NetFn = struct {
    pub const chassis = 0x0;
    pub const bridge = 0x2;
    pub const se = 0x4;
    pub const app = 0x6;
    pub const firmware = 0x8;
    pub const storage = 0xa;
    pub const transport = 0xc;
    pub const picmg = 0x2c;
    pub const dcgrp = 0x2c;
    pub const oem = 0x2e;
    pub const isol = 0x34;
    pub const tsol = 0x30;
};

/// `IPMI_PAYLOAD_TYPE_*`, table 13.16 of the IPMI v2 specification.
pub const PayloadType = enum(u8) {
    ipmi = 0x00,
    sol = 0x01,
    oem = 0x02,
    rmcp_open_request = 0x10,
    rmcp_open_response = 0x11,
    rakp_1 = 0x12,
    rakp_2 = 0x13,
    rakp_3 = 0x14,
    rakp_4 = 0x15,
    _,
};

/// `typedef enum IPMI_OEM`: IANA private enterprise numbers ipmitool knows by
/// name.  Non-exhaustive because `ipmi_intf.manufacturer_id` holds whatever the
/// BMC reports.
pub const Oem = enum(c.IPMI_OEM) {
    unknown = 0,
    debug = 0xfffffe,
    reserved = 0x0fffff,
    ibm_2 = 2,
    hp = 11,
    sun = 42,
    nokia = 94,
    bull = 107,
    hitachi_116 = 116,
    nec = 119,
    toshiba = 186,
    ericsson = 193,
    intel = 343,
    tatung = 373,
    hitachi_399 = 399,
    dell = 674,
    lmc = 2168,
    radisys = 4337,
    broadcom = 4413,
    ibm_4769 = 4769,
    magnum = 5593,
    tyan = 6653,
    quanta = 7244,
    viking = 9237,
    advantech = 10297,
    fujitsu_siemens = 10368,
    avocent = 10418,
    peppercon = 10437,
    supermicro = 10876,
    osa = 11102,
    google = 11129,
    picmg = 12634,
    raritan = 13742,
    kontron = 15000,
    pps = 16394,
    ibm_20301 = 20301,
    ami = 20974,
    adlink_24339 = 24339,
    nokia_solutions_and_networks = 28458,
    vita = 33196,
    supermicro_47488 = 47488,
    yadro = 49769,
    _,
};

/// The `netfn:6` / `lun:2` bitfield at the head of `struct ipmi_rq`.
///
/// C allocates bitfields from the least significant bit on little endian
/// targets and from the most significant bit on big endian ones, while a Zig
/// packed struct always starts at the least significant bit of its backing
/// integer, so the declaration order has to follow the target.
pub const NetFnLun = switch (builtin.target.cpu.arch.endian()) {
    .little => packed struct(u8) { netfn: u6, lun: u2 },
    .big => packed struct(u8) { lun: u2, netfn: u6 },
};

/// `struct ipmi_rq`: one outbound IPMI request.
pub const Request = extern struct {
    pub const Msg = extern struct {
        /// `netfn:6` and `lun:2` share this byte.
        netfn_lun: NetFnLun,
        cmd: u8,
        target_cmd: u8,
        data_len: u16,
        data: ?[*]u8,
    };

    msg: Msg,
};

/// `struct ipmi_rs`: one inbound IPMI response.
pub const Response = extern struct {
    pub const Msg = extern struct {
        netfn: u8,
        cmd: u8,
        seq: u8,
        lun: u8,
    };

    pub const Session = extern struct {
        authtype: u8,
        seq: u32,
        id: u32,
        /// IPMI v2 only.
        bEncrypted: u8,
        /// IPMI v2 only.
        bAuthenticated: u8,
        /// IPMI v2 only.
        payloadtype: u8,
        /// Total length of the payload or IPMI message.
        msglen: u16,
    };

    pub const Payload = extern union {
        pub const IpmiResponse = extern struct {
            rq_addr: u8,
            netfn: u8,
            rq_lun: u8,
            rs_addr: u8,
            rq_seq: u8,
            rs_lun: u8,
            cmd: u8,
        };

        pub const OpenSessionResponse = extern struct {
            message_tag: u8,
            rakp_return_code: u8,
            max_priv_level: u8,
            console_id: u32,
            bmc_id: u32,
            auth_alg: u8,
            integrity_alg: u8,
            crypt_alg: u8,
        };

        pub const Rakp2Message = extern struct {
            message_tag: u8,
            rakp_return_code: u8,
            console_id: u32,
            bmc_rand: [16]u8,
            bmc_guid: [16]u8,
            key_exchange_auth_code: [max_md_size]u8,
        };

        pub const Rakp4Message = extern struct {
            message_tag: u8,
            rakp_return_code: u8,
            console_id: u32,
            integrity_check_value: [max_md_size]u8,
        };

        pub const SolPacket = extern struct {
            packet_sequence_number: u8,
            acked_packet_number: u8,
            accepted_character_count: u8,
            is_nack: u8,
            transfer_unavailable: u8,
            sol_inactive: u8,
            transmit_overrun: u8,
            break_detected: u8,
        };

        ipmi_response: IpmiResponse,
        open_session_response: OpenSessionResponse,
        rakp2_message: Rakp2Message,
        rakp4_message: Rakp4Message,
        sol_packet: SolPacket,
    };

    ccode: u8,
    data: [buf_size]u8,
    /// Length of the whole packet on arrival, then of the IPMI message data.
    data_len: c_int,
    msg: Msg,
    session: Session,
    payload: Payload,
};

/// `struct ipmi_v2_payload`: what `sendrcv_v2()` takes.
pub const V2Payload = extern struct {
    pub const Payload = extern union {
        pub const IpmiRequest = extern struct {
            rq_seq: u8,
            request: ?*Request,
        };

        pub const IpmiResponse = extern struct {
            rs_seq: u8,
            response: ?*Response,
        };

        /// Only used internally by the lanplus interface.
        pub const RawRequest = extern struct {
            request: ?[*]u8,
        };

        /// Only used internally by the lanplus interface.
        pub const RawMessage = extern struct {
            message: ?[*]u8,
        };

        pub const SolPacket = extern struct {
            data: [buf_size]u8,
            character_count: u16,
            packet_sequence_number: u8,
            acked_packet_number: u8,
            accepted_character_count: u8,
            is_nack: u8,
            assert_ring_wor: u8,
            generate_break: u8,
            deassert_cts: u8,
            deassert_dcd_dsr: u8,
            flush_inbound: u8,
            flush_outbound: u8,
        };

        ipmi_request: IpmiRequest,
        ipmi_response: IpmiResponse,
        open_session_request: RawRequest,
        rakp_1_message: RawMessage,
        rakp_2_message: RawMessage,
        rakp_3_message: RawMessage,
        rakp_4_message: RawMessage,
        sol_packet: SolPacket,
    };

    payload_length: u16,
    payload_type: u8,
    payload: Payload,
};

/// `struct ipmi_rq_entry`: an in-flight request tracked by a transport.
pub const RequestEntry = extern struct {
    req: Request,
    intf: ?*intf_mod.Intf,
    rq_seq: u8,
    msg_data: ?[*]u8,
    msg_len: c_int,
    bridging_level: c_int,
    next: ?*RequestEntry,
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(Response, c.struct_ipmi_rs);
    abi.assertLayout(Response.Msg, @FieldType(c.struct_ipmi_rs, "msg"));
    abi.assertLayout(Response.Session, @FieldType(c.struct_ipmi_rs, "session"));
    abi.assertLayout(Response.Payload, @FieldType(c.struct_ipmi_rs, "payload"));

    abi.assertLayout(V2Payload, c.struct_ipmi_v2_payload);
    abi.assertLayout(V2Payload.Payload, @FieldType(c.struct_ipmi_v2_payload, "payload"));

    // `struct ipmi_rq` and `struct ipmi_rq_entry` reach Zig as `opaque {}`
    // because of the `netfn:6` / `lun:2` bitfield, so their layout comes from
    // `abi_layout.h` instead.
    abi.assertOpaqueLayout(Request, .{
        .size = c.ABI_SIZEOF_ipmi_rq,
        .alignment = c.ABI_ALIGNOF_ipmi_rq,
        .fields = &.{
            .{ .name = "msg", .offset = c.ABI_OFFSETOF_ipmi_rq__msg },
            .{ .name = "msg.cmd", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__cmd },
            .{ .name = "msg.target_cmd", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__target_cmd },
            .{ .name = "msg.data_len", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__data_len },
            .{ .name = "msg.data", .offset = c.ABI_OFFSETOF_ipmi_rq__msg__data },
        },
    });
    abi.assertOpaqueLayout(RequestEntry, .{
        .size = c.ABI_SIZEOF_ipmi_rq_entry,
        .alignment = c.ABI_ALIGNOF_ipmi_rq_entry,
        .fields = &.{
            .{ .name = "req", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__req },
            .{ .name = "intf", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__intf },
            .{ .name = "rq_seq", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__rq_seq },
            .{ .name = "msg_data", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__msg_data },
            .{ .name = "msg_len", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__msg_len },
            .{ .name = "bridging_level", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__bridging_level },
            .{ .name = "next", .offset = c.ABI_OFFSETOF_ipmi_rq_entry__next },
        },
    });
}

test "constants match the C headers" {
    try std.testing.expectEqual(@as(c_int, c.IPMI_BUF_SIZE), buf_size);
    try std.testing.expectEqual(@as(c_int, c.IPMI_MAX_MD_SIZE), max_md_size);
    try std.testing.expectEqual(@as(c_int, c.IPMI_NETFN_APP), NetFn.app);
    try std.testing.expectEqual(@as(c_int, c.IPMI_NETFN_STORAGE), NetFn.storage);
    try std.testing.expectEqual(@as(c_int, c.IPMI_BMC_SLAVE_ADDR), bmc_slave_addr);
    try std.testing.expectEqual(
        @as(c_int, c.IPMI_PAYLOAD_TYPE_RAKP_4),
        @intFromEnum(PayloadType.rakp_4),
    );
    try std.testing.expectEqual(c.IPMI_OEM_KONTRON, @intFromEnum(Oem.kontron));
}

test "netfn/lun bitfield packs into one byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(NetFnLun));

    var request: Request = std.mem.zeroes(Request);
    request.msg.netfn_lun = .{ .netfn = 0x2e, .lun = 3 };
    request.msg.cmd = 0x37;

    // C packs the first declared bitfield into the low bits on little endian
    // targets and into the high bits on big endian ones.
    const expected: u8 = switch (builtin.target.cpu.arch.endian()) {
        .little => (3 << 6) | 0x2e,
        .big => (0x2e << 2) | 3,
    };
    const bytes = std.mem.asBytes(&request);
    try std.testing.expectEqual(expected, bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x37), bytes[1]);
}
