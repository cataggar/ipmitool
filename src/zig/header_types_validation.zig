//! Isolated C interop checks for the native request, OEM and interface types.
//! Mixed-selection production roots and the ABI test roots import this module;
//! standalone native consumers do not. Retained until #249/#250 retire the
//! translated-header validation infrastructure.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("abi.zig");
const ipmi = @import("core/ipmi.zig");
const oem = @import("core/oem.zig");
const intf = @import("intf/intf.zig");

comptime {
    if (@typeInfo(ipmi.Oem).@"enum".tag_type != c.IPMI_OEM or
        @typeInfo(intf.LanplusSessionState).@"enum".tag_type != c.enum_LANPLUS_SESSION_STATE or
        @typeInfo(intf.CipherSuiteId).@"enum".tag_type != c.enum_cipher_suite_ids)
    {
        @compileError("native header enum storage differs from the C ABI");
    }

    abi.assertLayout(ipmi.Response, c.struct_ipmi_rs);
    abi.assertLayout(ipmi.Response.Msg, @FieldType(c.struct_ipmi_rs, "msg"));
    abi.assertLayout(ipmi.Response.Session, @FieldType(c.struct_ipmi_rs, "session"));
    abi.assertLayout(ipmi.Response.Payload, @FieldType(c.struct_ipmi_rs, "payload"));
    abi.assertLayout(ipmi.V2Payload, c.struct_ipmi_v2_payload);
    abi.assertLayout(ipmi.V2Payload.Payload, @FieldType(c.struct_ipmi_v2_payload, "payload"));

    // translate-c demotes these bitfield-containing types to opaque.
    abi.assertOpaqueLayout(ipmi.Request, .{
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
    abi.assertOpaqueLayout(ipmi.RequestEntry, .{
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

    abi.assertLayout(oem.OemHandle, c.struct_ipmi_oem_handle);
    abi.assertLayout(intf.Intf, c.struct_ipmi_intf);
    abi.assertLayout(intf.SessionParams, c.struct_ipmi_session_params);
    abi.assertLayout(intf.Session, c.struct_ipmi_session);
    abi.assertLayout(intf.Session.V2Data, @FieldType(c.struct_ipmi_session, "v2_data"));
    abi.assertLayout(intf.Session.SolData, @FieldType(c.struct_ipmi_session, "sol_data"));
    abi.assertLayout(intf.Cmd, c.struct_ipmi_cmd);
    abi.assertLayout(intf.IntfSupport, c.struct_ipmi_intf_support);
    abi.assertLayout(intf.CipherSuiteInfo, c.struct_cipher_suite_info);

    if (@sizeOf(intf.SockAddrStorage) != @sizeOf(c.struct_sockaddr_storage) or
        @alignOf(intf.SockAddrStorage) != @alignOf(c.struct_sockaddr_storage) or
        @offsetOf(intf.SockAddrStorage, "family") != @offsetOf(c.struct_sockaddr_storage, "ss_family"))
    {
        @compileError("native session socket storage differs from the C ABI");
    }
}

test "constants match the C headers" {
    try std.testing.expectEqual(@as(c_int, c.IPMI_BUF_SIZE), ipmi.buf_size);
    try std.testing.expectEqual(@as(c_int, c.IPMI_MAX_MD_SIZE), ipmi.max_md_size);
    try std.testing.expectEqual(@as(c_int, c.IPMI_NETFN_APP), ipmi.NetFn.app);
    try std.testing.expectEqual(@as(c_int, c.IPMI_NETFN_STORAGE), ipmi.NetFn.storage);
    try std.testing.expectEqual(@as(c_int, c.IPMI_BMC_SLAVE_ADDR), ipmi.bmc_slave_addr);
    try std.testing.expectEqual(
        @as(c_int, c.IPMI_PAYLOAD_TYPE_RAKP_4),
        @intFromEnum(ipmi.PayloadType.rakp_4),
    );
    try std.testing.expectEqual(c.IPMI_OEM_KONTRON, @intFromEnum(ipmi.Oem.kontron));
}

test "session state enums agree with the C headers" {
    try std.testing.expectEqual(
        c.LANPLUS_STATE_ACTIVE,
        @intFromEnum(intf.LanplusSessionState.active),
    );
    try std.testing.expectEqual(
        c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED,
        @intFromEnum(intf.CipherSuiteId.reserved),
    );
    try std.testing.expectEqual(
        @as(c_int, c.IPMI_AUTHCODE_BUFFER_SIZE),
        intf.authcode_buffer_size,
    );
    try std.testing.expectEqual(@as(c_int, c.IPMI_KG_BUFFER_SIZE), intf.kg_buffer_size);
}
