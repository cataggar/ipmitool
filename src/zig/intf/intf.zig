//! Port of `include/ipmitool/ipmi_intf.h`: the transport vtable and the session
//! state that hangs off it.
//!
//! `Intf` is the seam every transport in `src/plugins/` plugs into.  It is a
//! function-pointer struct exactly like the C original, so a Zig transport uses
//! `@fieldParentPtr` to recover its own state from the `*Intf` it is handed —
//! the same shape the sibling `azure-sdk-for-zig` runtime interfaces use.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const oem_mod = @import("../core/oem.zig");

/// `IPMI_AUTHCODE_BUFFER_SIZE`.
pub const authcode_buffer_size = 20;

/// `IPMI_SIK_BUFFER_SIZE`.
pub const sik_buffer_size = ipmi.max_md_size;

/// `IPMI_KG_BUFFER_SIZE`: key plus null byte.
pub const kg_buffer_size = 21;

/// `enum LANPLUS_SESSION_STATE`.
pub const LanplusSessionState = enum(c.enum_LANPLUS_SESSION_STATE) {
    presession = 0,
    open_session_sent,
    open_session_received,
    rakp_1_sent,
    rakp_2_received,
    rakp_3_sent,
    active,
    close_sent,
    _,
};

/// `enum cipher_suite_ids`.  Non-exhaustive: suites 15-17 only exist when
/// `HAVE_CRYPTO_SHA256` is defined, and the field also carries `0xff`.
pub const CipherSuiteId = enum(c.enum_cipher_suite_ids) {
    suite_0 = 0,
    suite_1 = 1,
    suite_2 = 2,
    suite_3 = 3,
    suite_4 = 4,
    suite_5 = 5,
    suite_6 = 6,
    suite_7 = 7,
    suite_8 = 8,
    suite_9 = 9,
    suite_10 = 10,
    suite_11 = 11,
    suite_12 = 12,
    suite_13 = 13,
    suite_14 = 14,
    reserved = 0xff,
    _,
};

/// `struct cipher_suite_info`.
pub const CipherSuiteInfo = extern struct {
    cipher_suite_id: CipherSuiteId,
    auth_alg: u8,
    integrity_alg: u8,
    crypt_alg: u8,
    iana: u32,
};

/// `struct ipmi_session_params`: everything the command line supplied.
pub const SessionParams = extern struct {
    hostname: ?[*:0]u8,
    username: [17]u8,
    authcode_set: [authcode_buffer_size + 1]u8,
    authtype_set: u8,
    privlvl: u8,
    cipher_suite_id: CipherSuiteId,
    sol_escape_char: u8,
    password: c_int,
    port: c_int,
    retry: c_int,
    timeout: u32,
    /// BMC key.
    kg: [kg_buffer_size]u8,
    lookupbit: u8,
};

/// `struct ipmi_session`: live session state owned by a transport.
pub const Session = extern struct {
    /// IPMI v2 / RMCP+ state.
    pub const V2Data = extern struct {
        session_state: LanplusSessionState,
        requested_auth_alg: u8,
        requested_integrity_alg: u8,
        requested_crypt_alg: u8,
        auth_alg: u8,
        integrity_alg: u8,
        crypt_alg: u8,
        max_priv_level: u8,
        console_id: u32,
        bmc_id: u32,
        console_rand: [16]u8,
        bmc_rand: [16]u8,
        bmc_guid: [16]u8,
        /// As sent in the RAKP 1 message.
        requested_role: u8,
        rakp2_return_code: u8,
        /// Session integrity key.
        sik: [sik_buffer_size]u8,
        sik_len: u8,
        /// BMC key.
        kg: [kg_buffer_size]u8,
        k1: [ipmi.max_md_size]u8,
        k1_len: u8,
        /// First 16 bytes are used for AES.
        k2: [ipmi.max_md_size]u8,
        k2_len: u8,
    };

    /// Serial Over LAN state.
    pub const SolData = extern struct {
        max_inbound_payload_size: u16,
        max_outbound_payload_size: u16,
        port: u16,
        sequence_number: u8,
        last_received_sequence_number: u8,
        last_received_byte_count: u8,
        sol_input_handler: ?*const fn (rsp: ?*ipmi.Response) callconv(.c) void,
    };

    active: c_int,
    session_id: u32,
    in_seq: u32,
    out_seq: u32,
    authcode: [authcode_buffer_size + 1]u8,
    challenge: [16]u8,
    authtype: u8,
    authstatus: u8,
    authextra: u8,
    timeout: u32,
    addr: std.posix.sockaddr.storage,
    addrlen: std.posix.socklen_t,
    v2_data: V2Data,
    sol_data: SolData,
};

/// `struct ipmi_cmd`: one entry of a command dispatch table.
pub const Cmd = extern struct {
    func: ?*const fn (intf: ?*Intf, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int,
    name: ?[*:0]const u8,
    desc: ?[*:0]const u8,
};

/// `struct ipmi_intf_support`: `name`/`supported` pair used by `-h` output.
pub const IntfSupport = extern struct {
    name: ?[*:0]const u8,
    supported: c_int,
};

/// `struct ipmi_intf`: the transport vtable plus its per-session state.
///
/// A Zig transport embeds this as its first field and recovers itself with
/// `@fieldParentPtr("intf", ptr)`, which is why the callbacks keep the C
/// signature and calling convention.
pub const Intf = extern struct {
    name: [16]u8,
    desc: [128]u8,
    devfile: ?[*:0]u8,
    fd: c_int,
    opened: c_int,
    abort: c_int,
    noanswer: c_int,
    picmg_avail: c_int,
    vita_avail: c_int,
    manufacturer_id: ipmi.Oem,
    ai_family: c_int,

    ssn_params: SessionParams,
    session: ?*Session,
    oem: ?*oem_mod.OemHandle,
    cmdlist: ?[*]Cmd,
    target_ipmb_addr: u8,
    my_addr: u32,
    target_addr: u32,
    target_lun: u8,
    target_channel: u8,
    transit_addr: u32,
    transit_channel: u8,
    max_request_data_size: u16,
    max_response_data_size: u16,

    devnum: u8,

    setup: ?*const fn (intf: *Intf) callconv(.c) c_int,
    open: ?*const fn (intf: *Intf) callconv(.c) c_int,
    close: ?*const fn (intf: *Intf) callconv(.c) void,
    sendrecv: ?*const fn (intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response,
    recv_sol: ?*const fn (intf: *Intf) callconv(.c) ?*ipmi.Response,
    send_sol: ?*const fn (intf: *Intf, payload: *ipmi.V2Payload) callconv(.c) ?*ipmi.Response,
    keepalive: ?*const fn (intf: *Intf) callconv(.c) c_int,
    set_my_addr: ?*const fn (intf: *Intf, addr: u8) callconv(.c) c_int,
    set_max_request_data_size: ?*const fn (intf: *Intf, size: u16) callconv(.c) void,
    set_max_response_data_size: ?*const fn (intf: *Intf, size: u16) callconv(.c) void,
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(Intf, c.struct_ipmi_intf);
    abi.assertLayout(SessionParams, c.struct_ipmi_session_params);
    abi.assertLayout(Session, c.struct_ipmi_session);
    abi.assertLayout(Session.V2Data, @FieldType(c.struct_ipmi_session, "v2_data"));
    abi.assertLayout(Session.SolData, @FieldType(c.struct_ipmi_session, "sol_data"));
    abi.assertLayout(Cmd, c.struct_ipmi_cmd);
    abi.assertLayout(IntfSupport, c.struct_ipmi_intf_support);
    abi.assertLayout(CipherSuiteInfo, c.struct_cipher_suite_info);
}

test "session state enums agree with the C headers" {
    try std.testing.expectEqual(
        c.LANPLUS_STATE_ACTIVE,
        @intFromEnum(LanplusSessionState.active),
    );
    try std.testing.expectEqual(
        c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED,
        @intFromEnum(CipherSuiteId.reserved),
    );
    try std.testing.expectEqual(
        @as(c_int, c.IPMI_AUTHCODE_BUFFER_SIZE),
        authcode_buffer_size,
    );
    try std.testing.expectEqual(@as(c_int, c.IPMI_KG_BUFFER_SIZE), kg_buffer_size);
}
