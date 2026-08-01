//! Port of `src/plugins/lanplus/lanplus.c`: the IPMI v2.0 / RMCP+ transport.
//!
//! The wire format is the one drawn in the C source:
//!
//! ```text
//! rmcp header          4 bytes
//! session header      10 bytes  authtype 0x06, payload type, session id, seq
//! payload length       2 bytes
//! [confidentiality header]
//! payload             var       possibly AES-CBC-128 encrypted
//! [confidentiality trailer]
//! [integrity pad]     var       so the authcode input is a multiple of 4
//! pad length           1 byte
//! next header          1 byte   0x07, hardcoded by table 13-8
//! [authcode]          var       12 (SHA1-96) or 16 (MD5-128, SHA256-128)
//! ```
//!
//! Session setup is the RMCP+ four-message handshake: Open Session
//! Request/Response negotiates the cipher suite and the two session ids, then
//! RAKP 1/2 exchanges random numbers and RAKP 3/4 proves both sides derived the
//! same session integrity key.  `src/zig/crypto/` supplies every primitive; this
//! module reaches them through the `ipmi_c` bridge so that a
//! `-Dzig-modules=lanplus` binary contains exactly one implementation of each.
//!
//! `tests/transport/` is what actually verifies this module: every datagram it
//! writes is byte-compared against a checked-in transcript *and* independently
//! validated by the model BMC in `tests/transport/Bmc.zig`, which recomputes
//! checksums, RAKP authcodes, integrity codes and AES padding from its own
//! `std.crypto` oracle.  The golden CLI suite runs through `dummy` and cannot
//! see any of it.
//!
//! ## Upstream behaviour reproduced deliberately
//!
//!  1. `ipmi_req_clear_entries()` frees each entry but never frees the
//!     `msg_data` hanging off it, so every packet buffer built for a command
//!     that was answered out of band is leaked.  `ipmi_req_remove_entry()` on
//!     the same struct does free it.
//!  2. `ipmi_lan_recv_packet()` writes `rsp.data[ret]` after a `recv()` of up
//!     to `IPMI_BUF_SIZE` bytes, one past the end of the buffer when the
//!     datagram fills it.
//!  3. `ipmi_handle_pong()` reads a `struct rmcp_pong` out of the response
//!     without checking that `data_len` is at least that long, and prints with
//!     `printf` rather than `lprintf`, so the two halves are not prefixed and
//!     go to stdout.
//!  4. `ipmi_lan_poll_single()` parses the RMCP class byte and then the whole
//!     session header before checking that the datagram is long enough to
//!     contain either.
//!  5. `ipmi_lanplus_build_v2x_msg()` returns without assigning `*msg_len` or
//!     `*msg_data` when `malloc`/`realloc` fails, so every caller then reads
//!     two uninitialised locals.  The Zig keeps the same shape: the out
//!     parameters are left untouched.
//!  6. The dead `len += payload->payload_length;` statements in the SOL,
//!     open-session, RAKP 1 and RAKP 3 arms of that switch.  `len` is
//!     unconditionally recomputed from `IPMI_LANPLUS_OFFSET_PAYLOAD` before its
//!     only later read, so the additions cannot be observed.  They are kept as
//!     comments rather than code, and listed in the PR body as known equivalent
//!     mutants.
//!  7. `ipmi_get_auth_capabilities_cmd()` saves `bridgePossible`, zeroes it,
//!     and then fails to restore it on either of its two error returns.
//!  8. That function also `memcpy`s `sizeof(struct get_channel_auth_cap_rsp)`
//!     bytes out of `rsp->data` without checking `rsp->data_len`.
//!  9. `ipmi_lanplus_rakp3()` tests `rsp->payload.open_session_response
//!     .rakp_return_code` -- the *open session* arm of the union -- to decide
//!     whether the RAKP 4 message carried an error, then prints
//!     `rsp->payload.rakp4_message.rakp_return_code`.  Both fields sit at
//!     offset 1 of the union, so the two reads agree; the code is confusing
//!     rather than wrong.
//! 10. `ipmi_lanplus_close()` ends with `intf = NULL`, which assigns to the
//!     local parameter and does nothing.
//! 11. `ipmi_lanplus_setup()` opens with `assert("ipmi_lanplus_setup")`.  A
//!     string literal is never null, so the assertion always holds: it is a
//!     no-op, not a check.  Another known equivalent mutant.
//! 12. `ipmi_lanplus_open()`'s `!intf` guard is dead: the vtable's parameter
//!     type is a non-optional pointer here, so it has no Zig counterpart.
//! 13. `ipmi_lanplus_send_payload()` rebuilds the message on every retry for
//!     the non-IPMI payload types, allocating a fresh buffer each time and
//!     dropping the previous one, then frees only the last.
//! 14. `read_rakp4_message()` copies `IPMI_HMAC_SHA256_AUTHCODE_SIZE` (16)
//!     bytes for SHA256, matching the comment "We need to copy 16 bytes" but
//!     not the 32-byte digest.  That is what the spec asks for -- the authcode
//!     is truncated -- and is reproduced as written.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const cassert = @import("../util/cassert.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("intf.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;
const Session = intf_mod.Session;
const Entry = ipmi.RequestEntry;

/// `HAVE_CRYPTO_SHA256`.  Same test as `src/zig/crypto/assert_text.zig`.
const have_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// `IPMI_LAN_MAX_REQUEST_SIZE`: 45 byte request transactions, less 7.
const max_request_size = 38;

/// `IPMI_LAN_MAX_RESPONSE_SIZE`: 42 byte response transactions, less 8.
const max_response_size = 34;

/// `IPMI_LANPLUS_PORT`.
const lanplus_port = 0x26f;

/// `IPMI_LAN_TIMEOUT`.  One second here, unlike `lan.c`'s two.
const lan_timeout = 1;

/// `IPMI_LAN_RETRY`.
const lan_retry = 4;

/// `IPMI_LAN_CHANNEL_E`.
const lan_channel_e = 0x0e;

/// `IPMI_GET_CHANNEL_AUTH_CAP`.
const get_channel_auth_cap = 0x38;

/// `IPMI_LANPLUS_OFFSET_*`, table 13-8 of the IPMI v2 specification.
const off_authtype = 0x04;
const off_payload_type = 0x05;
const off_session_id = 0x06;
const off_sequence_num = 0x0a;
const off_payload_size = 0x0e;
const off_payload = 0x10;

const pad_length_size = 1;
const next_header_size = 1;

/// `IPMI_MAX_INTEGRITY_PAD_SIZE` and `IPMI_MAX_AUTH_CODE_SIZE`, both
/// `IPMI_MAX_MD_SIZE`.
const max_integrity_pad_size = ipmi.max_md_size;
const max_auth_code_size = ipmi.max_md_size;

const sha1_authcode_size = 12;
const hmac_md5_authcode_size = 16;
const hmac_sha256_authcode_size = 16;

const sha_digest_length = 20;
const md5_digest_length = 16;
const sha256_digest_length = 32;

const open_session_request_size = 32;
const rakp1_message_size = 44;
const rakp3_message_max_size = 8 + ipmi.max_md_size;
const max_user_name_length = 16;

/// `IPMI_RAKP_STATUS_NO_ERRORS` and the one other status this file names.
const rakp_status_no_errors = 0x00;
const rakp_status_invalid_integrity_check_value = 0x0f;

/// `RMCP_VERSION_1`, `RMCP_CLASS_ASF`, `RMCP_CLASS_IPMI`.
const rmcp_version_1 = 0x06;
const rmcp_class_asf = 0x06;
const rmcp_class_ipmi = 0x07;

/// `ASF_RMCP_IANA` and `ASF_TYPE_PING`.
const asf_rmcp_iana = 0x000011be;
const asf_type_ping = 0x80;

/// `MAX_CIPHER_SUITE_COUNT` in `ipmi_channel.h`.
const max_cipher_suite_count: usize =
    @as(usize, c.MAX_CIPHER_SUITE_RECORD_OFFSET) *
    @as(usize, c.MAX_CIPHER_SUITE_DATA_LEN) /
    @as(usize, c.ABI_SIZEOF_std_cipher_suite_record);

// ---------------------------------------------------------------------------
// RMCP and ASF headers
// ---------------------------------------------------------------------------

/// `struct rmcp_hdr`.
const RmcpHdr = extern struct {
    ver: u8,
    __reserved: u8,
    seq: u8,
    class: u8,
};

/// `struct asf_hdr`.
const AsfHdr = extern struct {
    iana: u32,
    type: u8,
    tag: u8,
    __reserved: u8,
    len: u8,
};

/// The `struct rmcp_pong` declared locally inside `ipmi_handle_pong()`.
const RmcpPong = extern struct {
    rmcp: RmcpHdr,
    asf: AsfHdr,
    iana: u32,
    oem: u32,
    sup_entities: u8,
    sup_interact: u8,
    reserved: [6]u8,
};

/// `struct get_channel_auth_cap_rsp`, which `translate-c` demotes to
/// `opaque {}` because bytes 1, 2 and 3 are entirely bitfields.  Mirrored here
/// rather than imported from `cmd/channel.zig`: `root.zig` deliberately keeps
/// `intf/` free of `cmd/` dependencies.
const AuthCapRsp = extern struct {
    const Byte1 = switch (builtin.target.cpu.arch.endian()) {
        .little => packed struct(u8) {
            enabled_auth_types: u6,
            __reserved1: u1,
            v20_data_available: u1,
        },
        .big => packed struct(u8) {
            v20_data_available: u1,
            __reserved1: u1,
            enabled_auth_types: u6,
        },
    };

    const Byte2 = switch (builtin.target.cpu.arch.endian()) {
        .little => packed struct(u8) {
            anon_login_enabled: u1,
            null_usernames: u1,
            non_null_usernames: u1,
            user_level_auth: u1,
            per_message_auth: u1,
            kg_status: u1,
            __reserved2: u2,
        },
        .big => packed struct(u8) {
            __reserved2: u2,
            kg_status: u1,
            per_message_auth: u1,
            user_level_auth: u1,
            non_null_usernames: u1,
            null_usernames: u1,
            anon_login_enabled: u1,
        },
    };

    const Byte3 = switch (builtin.target.cpu.arch.endian()) {
        .little => packed struct(u8) {
            ipmiv15_support: u1,
            ipmiv20_support: u1,
            __reserved3: u6,
        },
        .big => packed struct(u8) {
            __reserved3: u6,
            ipmiv20_support: u1,
            ipmiv15_support: u1,
        },
    };

    channel_number: u8,
    b1: Byte1,
    b2: Byte2,
    b3: Byte3,
    oem_id: [3]u8 align(1),
    oem_aux_data: u8,
};

/// `plus_payload_types_vals[]`, used by the receive-path debug log.
const plus_payload_types_vals = [_]c.struct_valstr{
    .{ .val = @intFromEnum(ipmi.PayloadType.ipmi), .str = "IPMI (0)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.sol), .str = "SOL  (1)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.oem), .str = "OEM  (2)" },

    .{ .val = @intFromEnum(ipmi.PayloadType.rmcp_open_request), .str = "OpenSession Req (0x10)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.rmcp_open_response), .str = "OpenSession Resp (0x11)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.rakp_1), .str = "RAKP1 (0x12)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.rakp_2), .str = "RAKP2 (0x13)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.rakp_3), .str = "RAKP3 (0x14)" },
    .{ .val = @intFromEnum(ipmi.PayloadType.rakp_4), .str = "RAKP4 (0x15)" },
    .{ .val = 0x00, .str = null },
};

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn cSession(session: *Session) [*c]c.struct_ipmi_session {
    return @ptrCast(session);
}

fn cRsp(rsp: *ipmi.Response) [*c]c.struct_ipmi_rs {
    return @ptrCast(rsp);
}

/// A Zig string literal is `[:0]const u8`, which a C variadic will not take.
fn pick(cond: bool, a: [*:0]const u8, b: [*:0]const u8) [*:0]const u8 {
    return if (cond) a else b;
}

fn boolStr(v: anytype) [*:0]const u8 {
    return pick(v != 0, "true", "false");
}

// ---------------------------------------------------------------------------
// Cipher suite table
// ---------------------------------------------------------------------------

/// `lanplus_get_requested_ciphers()`: table 22-19 of the IPMI v2 spec.
fn getRequestedCiphers(
    cipher_suite_id: c.enum_cipher_suite_ids,
    auth_alg: *u8,
    integrity_alg: *u8,
    crypt_alg: *u8,
) callconv(.c) c_int {
    switch (cipher_suite_id) {
        c.IPMI_LANPLUS_CIPHER_SUITE_0 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_NONE;
            integrity_alg.* = c.IPMI_INTEGRITY_NONE;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_1 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA1;
            integrity_alg.* = c.IPMI_INTEGRITY_NONE;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_2 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA1;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA1_96;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_3 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA1;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA1_96;
            crypt_alg.* = c.IPMI_CRYPT_AES_CBC_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_4 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA1;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA1_96;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_5 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA1;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA1_96;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_40;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_6 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_NONE;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_7 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_8 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_AES_CBC_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_9 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_10 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_HMAC_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_40;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_11 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_NONE;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_12 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_AES_CBC_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_13 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_128;
        },
        c.IPMI_LANPLUS_CIPHER_SUITE_14 => {
            auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_MD5;
            integrity_alg.* = c.IPMI_INTEGRITY_MD5_128;
            crypt_alg.* = c.IPMI_CRYPT_XRC4_40;
        },
        else => {
            if (have_sha256) {
                switch (cipher_suite_id) {
                    c.IPMI_LANPLUS_CIPHER_SUITE_15 => {
                        auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA256;
                        integrity_alg.* = c.IPMI_INTEGRITY_NONE;
                        crypt_alg.* = c.IPMI_CRYPT_NONE;
                        return 0;
                    },
                    c.IPMI_LANPLUS_CIPHER_SUITE_16 => {
                        auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA256;
                        integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA256_128;
                        crypt_alg.* = c.IPMI_CRYPT_NONE;
                        return 0;
                    },
                    c.IPMI_LANPLUS_CIPHER_SUITE_17 => {
                        auth_alg.* = c.IPMI_AUTH_RAKP_HMAC_SHA256;
                        integrity_alg.* = c.IPMI_INTEGRITY_HMAC_SHA256_128;
                        crypt_alg.* = c.IPMI_CRYPT_AES_CBC_128;
                        return 0;
                    },
                    else => {},
                }
            }
            return 1;
        },
    }

    return 0;
}

// ---------------------------------------------------------------------------
// Request list
// ---------------------------------------------------------------------------

/// `static struct ipmi_rq_entry *ipmi_req_entries`.  Internal linkage here,
/// unlike `lan.c`'s variable of the same name.
var req_entries: ?*Entry = null;
var req_entries_tail: ?*Entry = null;

/// `static uint8_t bridgePossible`.
var bridge_possible: u8 = 0;

fn reqAddEntry(intf: *Intf, req: *ipmi.Request, req_seq: u8) ?*Entry {
    const e: *Entry = @ptrCast(@alignCast(c.malloc(@sizeOf(Entry)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    }));

    e.* = std.mem.zeroes(Entry);
    e.req = req.*;

    e.intf = intf;
    e.rq_seq = req_seq;

    if (req_entries == null) {
        req_entries = e;
    } else {
        req_entries_tail.?.next = e;
    }

    req_entries_tail = e;
    c.lprintf(
        log.Level.debug + 3,
        "added list entry seq=0x%02x cmd=0x%02x",
        @as(c_int, e.rq_seq),
        @as(c_int, e.req.msg.cmd),
    );
    return e;
}

fn reqLookupEntry(seq: u8, cmd: u8) ?*Entry {
    var e = req_entries;
    while (e) |cur| {
        if (cur.rq_seq == seq and cur.req.msg.cmd == cmd) break;
        if (cur.next == cur) return null;
        e = cur.next;
    }
    return e;
}

fn reqRemoveEntry(seq: u8, cmd: u8) void {
    var e = req_entries;
    var p = req_entries;

    while (e) |cur| {
        if (cur.rq_seq == seq and cur.req.msg.cmd == cmd) break;
        p = e;
        e = cur.next;
    }
    if (e) |cur| {
        c.lprintf(
            log.Level.debug + 3,
            "removed list entry seq=0x%02x cmd=0x%02x",
            @as(c_int, seq),
            @as(c_int, cmd),
        );
        const saved_next_entry = cur.next;
        // `p` is `e` itself when the match is the head, so this writes through
        // the entry that is about to be freed.
        p.?.next = if (p.?.next == cur.next) null else cur.next;
        if (req_entries == cur) {
            if (req_entries != p) {
                req_entries = p;
            } else {
                req_entries = saved_next_entry;
            }
        }
        if (req_entries_tail == cur) {
            if (req_entries_tail != p) {
                req_entries_tail = p;
            } else {
                req_entries_tail = null;
            }
        }

        if (cur.msg_data) |d| {
            c.free(d);
            cur.msg_data = null;
        }
        c.free(cur);
    }
}

/// Note 1: `msg_data` is not freed here.
fn reqClearEntries() void {
    var e = req_entries;
    while (e) |cur| {
        c.lprintf(
            log.Level.debug + 3,
            "cleared list entry seq=0x%02x cmd=0x%02x",
            @as(c_int, cur.rq_seq),
            @as(c_int, cur.req.msg.cmd),
        );
        const p = cur.next;
        c.free(cur);
        e = p;
    }

    req_entries = null;
    req_entries_tail = null;
}

// ---------------------------------------------------------------------------
// fd_set, which is macros in C
// ---------------------------------------------------------------------------

const fd_mask_bits = @bitSizeOf(c.__fd_mask);

fn fdZero(set: *c.fd_set) void {
    @memset(&set.__fds_bits, 0);
}

fn fdSet(fd: c_int, set: *c.fd_set) void {
    const bit: usize = @intCast(fd);
    set.__fds_bits[bit / fd_mask_bits] |= @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
}

fn fdIsSet(fd: c_int, set: *const c.fd_set) bool {
    const bit: usize = @intCast(fd);
    const mask = @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
    return (set.__fds_bits[bit / fd_mask_bits] & mask) != 0;
}

// ---------------------------------------------------------------------------
// Packet I/O
// ---------------------------------------------------------------------------

/// `ipmi_lan_send_packet()`.  Note the `verbose >= 5` gate and the `>> sending
/// packet` label, both different from `lan.c`.
fn sendPacket(intf: *Intf, data: [*]u8, data_len: c_int) c_int {
    if (c.verbose >= 5) c.printbuf(data, data_len, ">> sending packet");

    return @intCast(c.send(intf.fd, data, @intCast(data_len), 0));
}

/// The `static struct ipmi_rs rsp` inside `ipmi_lan_recv_packet()`.
var recv_rsp: ipmi.Response = std.mem.zeroes(ipmi.Response);

fn recvPacket(intf: *Intf) ?*ipmi.Response {
    const session = intf.session.?;

    var read_set: c.fd_set = undefined;
    var err_set: c.fd_set = undefined;
    var tmout: c.struct_timeval = undefined;
    var ret: c_int = 0;

    fdZero(&read_set);
    fdSet(intf.fd, &read_set);

    fdZero(&err_set);
    fdSet(intf.fd, &err_set);

    tmout.tv_sec = @intCast(session.timeout);
    tmout.tv_usec = 0;

    ret = c.select(intf.fd + 1, &read_set, null, &err_set, &tmout);
    if (ret < 0 or fdIsSet(intf.fd, &err_set) or !fdIsSet(intf.fd, &read_set)) return null;

    // The first read may return ECONNREFUSED because the RMCP ping packet --
    // sent to UDP port 623 -- is processed by both the BMC and the OS, and the
    // error is delivered ahead of any datagram already queued.
    ret = @intCast(c.recv(intf.fd, &recv_rsp.data, ipmi.buf_size, 0));

    if (ret < 0) {
        fdZero(&read_set);
        fdSet(intf.fd, &read_set);

        fdZero(&err_set);
        fdSet(intf.fd, &err_set);

        tmout.tv_sec = @intCast(session.timeout);
        tmout.tv_usec = 0;

        ret = c.select(intf.fd + 1, &read_set, null, &err_set, &tmout);
        if (ret < 0 or fdIsSet(intf.fd, &err_set) or !fdIsSet(intf.fd, &read_set)) return null;

        ret = @intCast(c.recv(intf.fd, &recv_rsp.data, ipmi.buf_size, 0));
        if (ret < 0) return null;
    }

    if (ret == 0) return null;

    // Note 2: one past the end when the datagram fills the buffer.
    recv_rsp.data[@intCast(ret)] = 0;
    recv_rsp.data_len = ret;

    if (c.verbose >= 5) c.printbuf(&recv_rsp.data, recv_rsp.data_len, "<< received packet");

    return &recv_rsp;
}

/// `ipmi_handle_pong()`.  Note 3: no length check, and `printf` rather than
/// `lprintf`.
fn handlePong(rsp: ?*ipmi.Response) c_int {
    const r = rsp orelse return -1;

    // `rsp->data` starts one byte into `struct ipmi_rs`, so this pointer is
    // unaligned; the C headers mark all three structs `__attribute__((packed))`
    // and the layout is byte-identical either way.
    const pong: *align(1) const RmcpPong = @ptrCast(&r.data);

    if (c.verbose != 0) {
        _ = c.printf(
            "Received IPMI/RMCP response packet: " ++
                "IPMI%s Supported\n",
            pick((pong.sup_entities & 0x80) != 0, "", " NOT"),
        );
    }

    if (c.verbose > 1) {
        _ = c.printf(
            "  ASF Version %s\n" ++
                "  RMCP Version %s\n" ++
                "  RMCP Sequence %d\n" ++
                "  IANA Enterprise %lu\n\n",
            pick((pong.sup_entities & 0x01) != 0, "1.0", "unknown"),
            pick(pong.rmcp.ver == 6, "1.0", "unknown"),
            @as(c_int, pong.rmcp.seq),
            @as(c_ulong, std.mem.bigToNative(u32, pong.iana)),
        );
    }

    return if ((pong.sup_entities & 0x80) != 0) 1 else 0;
}

/// `ipmiv2_lan_ping()`: build and send the RMCP presence ping.
fn lanPing(intf: *Intf) callconv(.c) c_int {
    const asf_ping: AsfHdr = .{
        .iana = std.mem.nativeToBig(u32, asf_rmcp_iana),
        .type = asf_type_ping,
        .tag = 0,
        .__reserved = 0,
        .len = 0,
    };
    const rmcp_ping: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_asf,
    };
    const len = @sizeOf(RmcpHdr) + @sizeOf(AsfHdr);

    const data: [*]u8 = @ptrCast(c.malloc(len) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return -1;
    });
    @memset(data[0..len], 0);
    @memcpy(data[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp_ping));
    @memcpy(data[@sizeOf(RmcpHdr)..][0..@sizeOf(AsfHdr)], std.mem.asBytes(&asf_ping));

    c.lprintf(log.Level.debug, "Sending IPMI/RMCP presence ping packet");

    const rv = sendPacket(intf, data, len);

    c.free(data);

    if (rv < 0) {
        c.lprintf(log.Level.err, "Unable to send IPMI presence ping packet");
        return -1;
    }

    if (pollRecv(intf) == null) return 0;

    return 1;
}

// ---------------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------------

/// `read_open_session_response()`.  The `memcpy` plus `#if WORDS_BIGENDIAN
/// BSWAP_32` pair is exactly a little-endian load.
fn readOpenSessionResponse(rsp: *ipmi.Response, offset: c_int) void {
    const o: usize = @intCast(offset);
    const p = &rsp.payload.open_session_response;

    p.* = std.mem.zeroes(@TypeOf(p.*));

    p.message_tag = rsp.data[o];
    p.rakp_return_code = rsp.data[o + 1];
    p.max_priv_level = rsp.data[o + 2];

    // offset + 3 is reserved.

    p.console_id = std.mem.readInt(u32, rsp.data[o + 4 ..][0..4], .little);

    // Only tag, status, privlvl and console id are returned on error.
    if (p.rakp_return_code != rakp_status_no_errors) return;

    p.bmc_id = std.mem.readInt(u32, rsp.data[o + 8 ..][0..4], .little);

    p.auth_alg = rsp.data[o + 16];
    p.integrity_alg = rsp.data[o + 24];
    p.crypt_alg = rsp.data[o + 32];
}

/// `read_rakp2_message()`.
fn readRakp2Message(rsp: *ipmi.Response, offset: c_int, auth_alg: u8) void {
    const o: usize = @intCast(offset);
    const p = &rsp.payload.rakp2_message;

    p.message_tag = rsp.data[o];
    p.rakp_return_code = rsp.data[o + 1];

    p.console_id = c.ipmi32toh(&rsp.data[o + 4]);

    @memcpy(&p.bmc_rand, c.array_letoh(&rsp.data[o + 8], 16)[0..16]);
    @memcpy(&p.bmc_guid, c.array_letoh(&rsp.data[o + 24], 16)[0..16]);

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => {},
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            for (0..sha_digest_length) |i| {
                p.key_exchange_auth_code[i] = rsp.data[o + 40 + i];
            }
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            for (0..md5_digest_length) |i| {
                p.key_exchange_auth_code[i] = rsp.data[o + 40 + i];
            }
        },
        else => {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                for (0..sha256_digest_length) |i| {
                    p.key_exchange_auth_code[i] = rsp.data[o + 40 + i];
                }
                return;
            }
            c.lprintf(
                log.Level.err,
                "read_rakp2_message: no support for authentication algorithm 0x%x",
                @as(c_int, auth_alg),
            );
            cassert.expect(false, .{
                .file = "src/plugins/lanplus/lanplus.c",
                .line = 1028,
                .func = "read_rakp2_message",
                .expr = "0",
            });
        },
    }
}

/// `read_rakp4_message()`.  Note 14: the SHA256 arm copies 16 bytes.
fn readRakp4Message(rsp: *ipmi.Response, offset: c_int, auth_alg: u8) void {
    const o: usize = @intCast(offset);
    const p = &rsp.payload.rakp4_message;

    p.message_tag = rsp.data[o];
    p.rakp_return_code = rsp.data[o + 1];

    p.console_id = c.ipmi32toh(&rsp.data[o + 4]);

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => {},
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            for (0..sha1_authcode_size) |i| {
                p.integrity_check_value[i] = rsp.data[o + 8 + i];
            }
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            for (0..hmac_md5_authcode_size) |i| {
                p.integrity_check_value[i] = rsp.data[o + 8 + i];
            }
        },
        else => {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                for (0..hmac_sha256_authcode_size) |i| {
                    p.integrity_check_value[i] = rsp.data[o + 8 + i];
                }
                return;
            }
            c.lprintf(
                log.Level.err,
                "read_rakp4_message: no support for authentication algorithm 0x%x",
                @as(c_int, auth_alg),
            );
            cassert.expect(false, .{
                .file = "src/plugins/lanplus/lanplus.c",
                .line = 1106,
                .func = "read_rakp4_message",
                .expr = "0",
            });
        },
    }
}

/// `read_session_data()`.  Note 4: nothing has checked `data_len` yet.
fn readSessionData(rsp: *ipmi.Response, offset: *c_int) void {
    if (rsp.data[@intCast(offset.*)] == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS) {
        readSessionDataV2x(rsp, offset);
    } else {
        readSessionDataV15(rsp, offset);
    }
}

fn readSessionDataV2x(rsp: *ipmi.Response, offset: *c_int) void {
    rsp.session.authtype = rsp.data[@intCast(offset.*)];
    offset.* += 1;

    rsp.session.bEncrypted = if ((rsp.data[@intCast(offset.*)] & 0x80) != 0) 1 else 0;
    rsp.session.bAuthenticated = if ((rsp.data[@intCast(offset.*)] & 0x40) != 0) 1 else 0;

    rsp.session.payloadtype = rsp.data[@intCast(offset.*)] & 0x3f;
    offset.* += 1;

    rsp.session.id = c.ipmi32toh(&rsp.data[@intCast(offset.*)]);
    offset.* += 4;

    rsp.session.seq = c.ipmi32toh(&rsp.data[@intCast(offset.*)]);
    offset.* += 4;

    rsp.session.msglen = c.ipmi16toh(&rsp.data[@intCast(offset.*)]);
    offset.* += 2;
}

fn readSessionDataV15(rsp: *ipmi.Response, offset: *c_int) void {
    rsp.session.payloadtype = @intFromEnum(ipmi.PayloadType.ipmi);

    rsp.session.authtype = rsp.data[@intCast(offset.*)];
    offset.* += 1;

    rsp.session.bEncrypted = 0;
    rsp.session.bAuthenticated = 0;

    // Skip the session id and sequence number fields.
    offset.* += 8;

    rsp.session.msglen = rsp.data[@intCast(offset.*)];
    offset.* += 1;
}

fn readIpmiResponse(rsp: *ipmi.Response, offset: *c_int) void {
    const p = &rsp.payload.ipmi_response;

    p.rq_addr = rsp.data[@intCast(offset.*)];
    offset.* += 1;
    p.netfn = rsp.data[@intCast(offset.*)] >> 2;
    p.rq_lun = rsp.data[@intCast(offset.*)] & 0x3;
    offset.* += 1;
    offset.* += 1; // checksum
    p.rs_addr = rsp.data[@intCast(offset.*)];
    offset.* += 1;
    p.rq_seq = rsp.data[@intCast(offset.*)] >> 2;
    p.rs_lun = rsp.data[@intCast(offset.*)] & 0x3;
    offset.* += 1;
    p.cmd = rsp.data[@intCast(offset.*)];
    offset.* += 1;
    rsp.ccode = rsp.data[@intCast(offset.*)];
    offset.* += 1;
}

fn readSolPacket(rsp: *ipmi.Response, offset: *c_int) void {
    const p = &rsp.payload.sol_packet;

    p.packet_sequence_number = rsp.data[@intCast(offset.*)] & 0x0f;
    offset.* += 1;

    p.acked_packet_number = rsp.data[@intCast(offset.*)] & 0x0f;
    offset.* += 1;

    p.accepted_character_count = rsp.data[@intCast(offset.*)];
    offset.* += 1;

    p.is_nack = rsp.data[@intCast(offset.*)] & 0x40;
    p.transfer_unavailable = rsp.data[@intCast(offset.*)] & 0x20;
    p.sol_inactive = rsp.data[@intCast(offset.*)] & 0x10;
    p.transmit_overrun = rsp.data[@intCast(offset.*)] & 0x08;
    p.break_detected = rsp.data[@intCast(offset.*)] & 0x04;
    offset.* += 1;

    c.lprintf(log.Level.debug, "<<<<<<<<<< RECV FROM BMC <<<<<<<<<<<");
    c.lprintf(log.Level.debug, "< SOL sequence number     : 0x%02x", @as(c_int, p.packet_sequence_number));
    c.lprintf(log.Level.debug, "< SOL acked packet        : 0x%02x", @as(c_int, p.acked_packet_number));
    c.lprintf(log.Level.debug, "< SOL accepted char count : 0x%02x", @as(c_int, p.accepted_character_count));
    c.lprintf(log.Level.debug, "< SOL is nack             : %s", boolStr(p.is_nack));
    c.lprintf(log.Level.debug, "< SOL xfer unavailable    : %s", boolStr(p.transfer_unavailable));
    c.lprintf(log.Level.debug, "< SOL inactive            : %s", boolStr(p.sol_inactive));
    c.lprintf(log.Level.debug, "< SOL transmit overrun    : %s", boolStr(p.transmit_overrun));
    c.lprintf(log.Level.debug, "< SOL break detected      : %s", boolStr(p.break_detected));
    c.lprintf(log.Level.debug, "<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<");

    if (c.verbose >= 5) {
        c.printbuf(rsp.data[@intCast(offset.* - 4)..].ptr, 4, "SOL MSG FROM BMC");
    }
}

// ---------------------------------------------------------------------------
// Receive path
// ---------------------------------------------------------------------------

/// `ipmi_lan_poll_single()` signals "read one more packet" by returning the
/// sentinel `(struct ipmi_rs *)1`.  `@ptrFromInt(1)` is a misaligned-pointer
/// compile error in Zig, and the sentinel is not observable outside this file,
/// so it becomes a tag.
const PollResult = union(enum) {
    none,
    again,
    got: *ipmi.Response,
};

fn pollSingle(intf: *Intf) PollResult {
    const session = intf.session.?;

    const rsp = recvPacket(intf) orelse return .none;

    const rmcp_rsp: *align(1) const RmcpHdr = @ptrCast(&rsp.data);

    if (rmcp_rsp.class == rmcp_class_asf) {
        const rv = handlePong(rsp);
        return if (rv <= 0) .none else .{ .got = rsp };
    }

    if (rmcp_rsp.class != rmcp_class_ipmi) {
        c.lprintf(log.Level.debug, "Invalid RMCP class: %x", @as(c_int, rmcp_rsp.class));
        return .again;
    }

    var offset: c_int = 4;
    var payload_size: u16 = undefined;

    readSessionData(rsp, &offset);

    // Skip packets that are not intended for this session.
    if (session.v2_data.session_state == .active and
        rsp.session.authtype == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS and
        rsp.session.id != session.v2_data.console_id)
    {
        c.lprintf(
            log.Level.info,
            "packet session id 0x%x does not match active session 0x%0x",
            rsp.session.id,
            session.v2_data.console_id,
        );
        c.lprintf(log.Level.err, "ERROR: Received an Unexpected message ID");
        return .again;
    }

    if (c.lanplus_has_valid_auth_code(cRsp(rsp), cSession(session)) == 0) {
        c.lprintf(log.Level.err, "ERROR: Received message with invalid authcode!");
        return .none;
    }

    if (session.v2_data.session_state == .active and
        rsp.session.authtype == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS and
        rsp.session.bEncrypted != 0)
    {
        _ = c.lanplus_decrypt_payload(
            session.v2_data.crypt_alg,
            &session.v2_data.k2,
            rsp.data[@intCast(offset)..].ptr,
            rsp.session.msglen,
            rsp.data[@intCast(offset)..].ptr,
            &payload_size,
        );
    } else {
        payload_size = rsp.session.msglen;
    }

    if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.ipmi)) {
        var payload_start = offset;
        var loop: c_int = 1;

        while (true) {
            const cont = loop != 0;
            loop -= 1;
            if (!cont) break;

            readIpmiResponse(rsp, &offset);

            const p = &rsp.payload.ipmi_response;
            c.lprintf(log.Level.debug + 1, "<< IPMI Response Session Header");
            c.lprintf(log.Level.debug + 1, "<<   Authtype                : %s", c.val2str(rsp.session.authtype, c.ipmi_authtype_session_vals));
            c.lprintf(log.Level.debug + 1, "<<   Payload type            : %s", c.val2str(rsp.session.payloadtype, &plus_payload_types_vals));
            c.lprintf(log.Level.debug + 1, "<<   Session ID              : 0x%08lx", @as(c_long, rsp.session.id));
            c.lprintf(log.Level.debug + 1, "<<   Sequence                : 0x%08lx", @as(c_long, rsp.session.seq));
            c.lprintf(log.Level.debug + 1, "<<   IPMI Msg/Payload Length : %d", @as(c_int, rsp.session.msglen));
            c.lprintf(log.Level.debug + 1, "<< IPMI Response Message Header");
            c.lprintf(log.Level.debug + 1, "<<   Rq Addr    : %02x", @as(c_int, p.rq_addr));
            c.lprintf(log.Level.debug + 1, "<<   NetFn      : %02x", @as(c_int, p.netfn));
            c.lprintf(log.Level.debug + 1, "<<   Rq LUN     : %01x", @as(c_int, p.rq_lun));
            c.lprintf(log.Level.debug + 1, "<<   Rs Addr    : %02x", @as(c_int, p.rs_addr));
            c.lprintf(log.Level.debug + 1, "<<   Rq Seq     : %02x", @as(c_int, p.rq_seq));
            c.lprintf(log.Level.debug + 1, "<<   Rs Lun     : %01x", @as(c_int, p.rs_lun));
            c.lprintf(log.Level.debug + 1, "<<   Command    : %02x", @as(c_int, p.cmd));
            c.lprintf(log.Level.debug + 1, "<<   Compl Code : 0x%02x", @as(c_int, rsp.ccode));

            const entry = reqLookupEntry(p.rq_seq, p.cmd) orelse {
                c.lprintf(log.Level.info, "IPMI Request Match NOT FOUND");
                return .again;
            };

            c.lprintf(log.Level.debug + 2, "IPMI Request Match found");

            if (entry.bridging_level != 0) {
                if (rsp.ccode != 0) {
                    c.lprintf(log.Level.debug, "WARNING: Bridged cmd ccode = 0x%02x", @as(c_int, rsp.ccode));
                } else {
                    entry.bridging_level -= 1;
                    if (entry.bridging_level == 0) {
                        entry.req.msg.cmd = entry.req.msg.target_cmd;
                    }

                    if (payload_size > 8) {
                        c.printbuf(
                            rsp.data[@intCast(offset)..].ptr,
                            rsp.data_len - offset - 1,
                            "bridge command response",
                        );
                        loop += 1;
                    } else {
                        c.lprintf(log.Level.debug, "Bridged command answer, waiting for next answer... ");
                        return .again;
                    }
                }
            }

            reqRemoveEntry(p.rq_seq, p.cmd);

            // Good packet: shift the response data to the start of the array.
            const extra_data_length: c_int = @as(c_int, payload_size) - (offset - payload_start) - 1;
            if (extra_data_length > 0) {
                rsp.data_len = extra_data_length;
                std.mem.copyForwards(
                    u8,
                    rsp.data[0..@intCast(extra_data_length)],
                    rsp.data[@intCast(offset)..][0..@intCast(extra_data_length)],
                );
                offset = 0;
                payload_start = 0;
                payload_size = @truncate(@as(u32, @bitCast(extra_data_length)));
            } else {
                rsp.data_len = 0;
            }
        }
    } else if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.rmcp_open_response)) {
        if (session.v2_data.session_state != .open_session_sent) {
            c.lprintf(log.Level.err, "Error: Received an Unexpected Open Session Response");
            return .again;
        }
        readOpenSessionResponse(rsp, offset);
    } else if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.rakp_2)) {
        if (session.v2_data.session_state != .rakp_1_sent) {
            c.lprintf(log.Level.err, "Error: Received an Unexpected RAKP 2 message");
            return .again;
        }
        readRakp2Message(rsp, offset, session.v2_data.auth_alg);
    } else if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.rakp_4)) {
        if (session.v2_data.session_state != .rakp_3_sent) {
            c.lprintf(log.Level.err, "Error: Received an Unexpected RAKP 4 message");
            return .again;
        }
        readRakp4Message(rsp, offset, session.v2_data.auth_alg);
    } else if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.sol)) {
        const payload_start = offset;

        if (session.v2_data.session_state != .active) {
            c.lprintf(log.Level.err, "Error: Received an Unexpected SOL packet");
            return .again;
        }
        readSolPacket(rsp, &offset);
        const extra_data_length: c_int = @as(c_int, payload_size) - (offset - payload_start);
        if (extra_data_length > 0) {
            rsp.data_len = extra_data_length;
            std.mem.copyForwards(
                u8,
                rsp.data[0..@intCast(extra_data_length)],
                rsp.data[@intCast(offset)..][0..@intCast(extra_data_length)],
            );
        } else {
            rsp.data_len = 0;
        }
    } else {
        c.lprintf(
            log.Level.err,
            "Invalid RMCP+ payload type : 0x%x",
            @as(c_int, rsp.session.payloadtype),
        );
        return .again;
    }

    return .{ .got = rsp };
}

fn pollRecv(intf: *Intf) ?*ipmi.Response {
    while (true) {
        switch (pollSingle(intf)) {
            .again => {},
            .none => return null,
            .got => |r| return r,
        }
    }
}

// ---------------------------------------------------------------------------
// Wire representation
// ---------------------------------------------------------------------------

/// `getIpmiPayloadWireRep()`: figure 13-4 of the IPMI v2.0 spec, with up to two
/// levels of Send Message encapsulation.
fn getIpmiPayloadWireRep(
    intf: *Intf,
    payload: *ipmi.V2Payload,
    msg: [*]u8,
    req: *ipmi.Request,
    rq_seq: u8,
    curr_seq: u8,
) void {
    var cs: c_int = undefined;
    var tmp: c_int = undefined;
    var len: c_int = undefined;
    var cs2: c_int = 0;
    var cs3: c_int = 0;
    var our_address: u8 = @truncate(intf.my_addr);
    var bridged_request: u8 = 0;

    if (our_address == 0) our_address = ipmi.bmc_slave_addr;

    len = 0;

    if (intf.target_addr == @as(u32, our_address) or bridge_possible == 0) {
        cs = len;
    } else {
        bridged_request = 1;

        if (intf.transit_addr != @as(u32, our_address) and intf.transit_addr != 0) {
            bridged_request += 1;
        }
        // Bridged request: encapsulate within Send Message.
        cs = len;
        msg[@intCast(len)] = ipmi.bmc_slave_addr;
        len += 1;
        msg[@intCast(len)] = ipmi.NetFn.app << 2;
        len += 1;
        tmp = len - cs;
        msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
        len += 1;
        cs2 = len;
        msg[@intCast(len)] = ipmi.remote_swid;
        len += 1;
        msg[@intCast(len)] = curr_seq << 2;
        len += 1;

        msg[@intCast(len)] = 0x34; // Send Message request
        len += 1;
        if (bridged_request == 2) {
            msg[@intCast(len)] = 0x40 | intf.transit_channel; // track request
        } else {
            msg[@intCast(len)] = 0x40 | intf.target_channel; // track request
        }
        len += 1;

        payload.payload_length +%= 7;
        cs = len;

        if (bridged_request == 2) {
            cs = len;
            msg[@intCast(len)] = @truncate(intf.transit_addr);
            len += 1;
            msg[@intCast(len)] = ipmi.NetFn.app << 2;
            len += 1;
            tmp = len - cs;
            msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
            len += 1;
            cs3 = len;
            msg[@intCast(len)] = ipmi.remote_swid;
            len += 1;
            msg[@intCast(len)] = curr_seq << 2;
            len += 1;
            msg[@intCast(len)] = 0x34; // Send Message request
            len += 1;
            msg[@intCast(len)] = 0x40 | intf.target_channel; // track request
            len += 1;

            payload.payload_length +%= 7;

            cs = len;
        }
    }

    c.lprintf(
        log.Level.debug,
        "%s RqAddr %#x transit %#x:%#x target %#x:%#x bridgePossible %d",
        pick(bridged_request != 0, "Bridging", "Local"),
        @as(c_uint, intf.my_addr),
        @as(c_uint, intf.transit_addr),
        @as(c_int, intf.transit_channel),
        @as(c_uint, intf.target_addr),
        @as(c_int, intf.target_channel),
        @as(c_int, bridge_possible),
    );

    // rsAddr
    if (bridged_request != 0) {
        msg[@intCast(len)] = @truncate(intf.target_addr);
    } else {
        msg[@intCast(len)] = ipmi.bmc_slave_addr;
    }
    len += 1;

    // netFn
    msg[@intCast(len)] = @as(u8, req.msg.netfn_lun.netfn) << 2 |
        (@as(u8, req.msg.netfn_lun.lun) & 3);
    len += 1;
    tmp = len - cs;

    // checksum
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;
    cs = len;

    // rqAddr
    if (bridged_request < 2) {
        msg[@intCast(len)] = ipmi.remote_swid;
    } else {
        msg[@intCast(len)] = @truncate(intf.my_addr);
    }
    len += 1;

    // rqSeq / rqLUN
    msg[@intCast(len)] = rq_seq << 2;
    len += 1;

    // cmd
    msg[@intCast(len)] = req.msg.cmd;
    len += 1;

    // message data
    if (req.msg.data_len != 0) {
        @memcpy(
            msg[@intCast(len)..][0..req.msg.data_len],
            req.msg.data.?[0..req.msg.data_len],
        );
        len += req.msg.data_len;
    }

    // second checksum
    tmp = len - cs;
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;

    // Dual bridged request: second checksum.
    if (bridged_request == 2) {
        tmp = len - cs3;
        msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs3)), tmp);
        len += 1;
        payload.payload_length +%= 1;
    }

    // Bridged request: second checksum.
    if (bridged_request != 0) {
        tmp = len - cs2;
        msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs2)), tmp);
        len += 1;
        payload.payload_length +%= 1;
    }
}

/// `getSolPayloadWireRep()`.
fn getSolPayloadWireRep(msg: [*]u8, payload: *ipmi.V2Payload) void {
    var i: usize = 0;
    const sol = &payload.payload.sol_packet;

    c.lprintf(log.Level.debug, ">>>>>>>>>> SENDING TO BMC >>>>>>>>>>");
    c.lprintf(log.Level.debug, "> SOL sequence number     : 0x%02x", @as(c_int, sol.packet_sequence_number));
    c.lprintf(log.Level.debug, "> SOL acked packet        : 0x%02x", @as(c_int, sol.acked_packet_number));
    c.lprintf(log.Level.debug, "> SOL accepted char count : 0x%02x", @as(c_int, sol.accepted_character_count));
    c.lprintf(log.Level.debug, "> SOL is nack             : %s", boolStr(sol.is_nack));
    c.lprintf(log.Level.debug, "> SOL assert ring wor     : %s", boolStr(sol.assert_ring_wor));
    c.lprintf(log.Level.debug, "> SOL generate break      : %s", boolStr(sol.generate_break));
    c.lprintf(log.Level.debug, "> SOL deassert cts        : %s", boolStr(sol.deassert_cts));
    c.lprintf(log.Level.debug, "> SOL deassert dcd dsr    : %s", boolStr(sol.deassert_dcd_dsr));
    c.lprintf(log.Level.debug, "> SOL flush inbound       : %s", boolStr(sol.flush_inbound));
    c.lprintf(log.Level.debug, "> SOL flush outbound      : %s", boolStr(sol.flush_outbound));

    msg[i] = sol.packet_sequence_number;
    i += 1;
    msg[i] = sol.acked_packet_number;
    i += 1;
    msg[i] = sol.accepted_character_count;
    i += 1;

    msg[i] = if (sol.is_nack != 0) 0x40 else 0;
    msg[i] |= if (sol.assert_ring_wor != 0) 0x20 else 0;
    msg[i] |= if (sol.generate_break != 0) 0x10 else 0;
    msg[i] |= if (sol.deassert_cts != 0) 0x08 else 0;
    msg[i] |= if (sol.deassert_dcd_dsr != 0) 0x04 else 0;
    msg[i] |= if (sol.flush_inbound != 0) 0x02 else 0;
    msg[i] |= if (sol.flush_outbound != 0) 0x01 else 0;
    i += 1;

    // We may have data to add.
    @memcpy(msg[i..][0..sol.character_count], sol.data[0..sol.character_count]);

    c.lprintf(log.Level.debug, "> SOL character count     : %d", @as(c_int, sol.character_count));
    c.lprintf(log.Level.debug, ">>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>");

    if (c.verbose >= 5 and sol.character_count != 0) {
        c.printbuf(&sol.data, sol.character_count, "SOL SEND DATA");
    }

    // The payload length now becomes the whole payload length, including the
    // four bytes at the start of the SOL packet.
    payload.payload_length = sol.character_count + 4;
}

/// `ipmi_lanplus_build_v2x_msg()`.
///
/// Note 5: the two allocation-failure paths return without writing `msg_len`
/// or `msg_data`, exactly as upstream does.
fn buildV2xMsg(
    intf: *Intf,
    payload: *ipmi.V2Payload,
    msg_len: *c_int,
    msg_data: *?[*]u8,
    curr_seq: u8,
) callconv(.c) void {
    var session_trailer_length: u32 = 0;
    const session = intf.session.?;
    const rmcp: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_ipmi,
    };

    var len: c_int = 0;

    len = @sizeOf(RmcpHdr) + // RMCP header (4)
        10 + // IPMI session header
        2 + // message length
        @as(c_int, payload.payload_length) + // the actual payload
        max_integrity_pad_size + // integrity pad
        1 + // pad length
        1 + // next header
        max_auth_code_size; // authcode

    var msg: [*]u8 = @ptrCast(c.malloc(@intCast(len)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return;
    });
    @memset(msg[0..@intCast(len)], 0);

    // RMCP header.
    @memcpy(msg[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp));
    len = @sizeOf(RmcpHdr);

    // IPMI session header.  Auth type / format is always 0x06 for IPMI v2.
    msg[off_authtype] = 0x06;

    msg[off_payload_type] = payload.payload_type;

    if (session.v2_data.session_state == .active) {
        msg[off_payload_type] |= if (session.v2_data.crypt_alg != c.IPMI_CRYPT_NONE) 0x80 else 0x00;
        msg[off_payload_type] |= if (session.v2_data.integrity_alg != c.IPMI_INTEGRITY_NONE) 0x40 else 0x00;
    }

    if (session.v2_data.session_state == .active) {
        // Session ID, LSB first.
        msg[off_session_id] = @truncate(session.v2_data.bmc_id);
        msg[off_session_id + 1] = @truncate(session.v2_data.bmc_id >> 8);
        msg[off_session_id + 2] = @truncate(session.v2_data.bmc_id >> 16);
        msg[off_session_id + 3] = @truncate(session.v2_data.bmc_id >> 24);

        // Sequence number, LSB first.
        msg[off_sequence_num] = @truncate(session.out_seq);
        msg[off_sequence_num + 1] = @truncate(session.out_seq >> 8);
        msg[off_sequence_num + 2] = @truncate(session.out_seq >> 16);
        msg[off_sequence_num + 3] = @truncate(session.out_seq >> 24);
    }

    switch (payload.payload_type) {
        @intFromEnum(ipmi.PayloadType.ipmi) => {
            getIpmiPayloadWireRep(
                intf,
                payload,
                msg + off_payload,
                payload.payload.ipmi_request.request.?,
                payload.payload.ipmi_request.rq_seq,
                curr_seq,
            );
        },

        @intFromEnum(ipmi.PayloadType.sol) => {
            getSolPayloadWireRep(msg + off_payload, payload);

            if (c.verbose >= 5) c.printbuf(msg + off_payload, 4, "SOL MSG TO BMC");

            // Note 6: dead store, `len` is rewritten before its only read.
            len += @as(c_int, payload.payload_length);
        },

        @intFromEnum(ipmi.PayloadType.rmcp_open_request) => {
            // Never encrypted, so our job is easy.
            @memcpy(
                (msg + off_payload)[0..payload.payload_length],
                payload.payload.open_session_request.request.?[0..payload.payload_length],
            );
            len += @as(c_int, payload.payload_length);
        },

        @intFromEnum(ipmi.PayloadType.rakp_1) => {
            @memcpy(
                (msg + off_payload)[0..payload.payload_length],
                payload.payload.rakp_1_message.message.?[0..payload.payload_length],
            );
            len += @as(c_int, payload.payload_length);
        },

        @intFromEnum(ipmi.PayloadType.rakp_3) => {
            @memcpy(
                (msg + off_payload)[0..payload.payload_length],
                payload.payload.rakp_3_message.message.?[0..payload.payload_length],
            );
            len += @as(c_int, payload.payload_length);
        },

        else => {
            c.lprintf(
                log.Level.err,
                "unsupported payload type 0x%x",
                @as(c_int, payload.payload_type),
            );
            c.free(msg);
            cassert.expect(false, .{
                .file = "src/plugins/lanplus/lanplus.c",
                .line = 1717,
                .func = "ipmi_lanplus_build_v2x_msg",
                .expr = "0",
            });
        },
    }

    // Encrypt the payload if necessary.
    if (session.v2_data.session_state == .active) {
        const old_payload_length = payload.payload_length;
        _ = c.lanplus_encrypt_payload(
            session.v2_data.crypt_alg,
            &session.v2_data.k2,
            msg + off_payload,
            payload.payload_length,
            msg + off_payload,
            &payload.payload_length,
        );

        if (old_payload_length != payload.payload_length) {
            len = off_payload +
                @as(c_int, payload.payload_length) +
                max_integrity_pad_size +
                pad_length_size +
                next_header_size +
                max_auth_code_size;

            const new_msg = c.realloc(msg, @intCast(len)) orelse {
                c.free(msg);
                c.lprintf(log.Level.err, "ipmitool: realloc failure");
                return;
            };
            msg = @ptrCast(new_msg);
        }
    }

    // Now we know the payload length.
    msg[off_payload_size] = @truncate(payload.payload_length);
    msg[off_payload_size + 1] = @truncate(payload.payload_length >> 8);

    // Session trailer.
    if (session.v2_data.session_state == .active and
        session.v2_data.integrity_alg != c.IPMI_INTEGRITY_NONE)
    {
        var hmac_length: u32 = undefined;
        var auth_length: u32 = 0;
        var integrity_pad_size: u32 = 0;
        const start_of_session_trailer: u32 = off_payload + @as(u32, payload.payload_length);

        // The data range covered by the authcode has to be a multiple of 4.
        var length_before_authcode: u32 = undefined;

        if (c.ipmi_oem_active(cIntf(intf), "icts") != 0) {
            length_before_authcode = 12 + // the stuff before the payload
                @as(u32, payload.payload_length);
        } else {
            length_before_authcode = 12 + // the stuff before the payload
                @as(u32, payload.payload_length) +
                1 + // pad length field
                1; // next header field
        }

        if (length_before_authcode % 4 != 0) {
            integrity_pad_size = 4 - (length_before_authcode % 4);
        }

        for (0..integrity_pad_size) |i| {
            msg[start_of_session_trailer + i] = 0xff;
        }

        // Pad length.
        msg[start_of_session_trailer + integrity_pad_size] = @truncate(integrity_pad_size);

        // Next header, hardcoded per the spec, table 13-8.
        msg[start_of_session_trailer + integrity_pad_size + 1] = 0x07;

        const hmac_input_size: u32 = 12 +
            @as(u32, payload.payload_length) +
            integrity_pad_size +
            2;

        const hmac_output: [*]u8 = msg +
            off_payload +
            @as(usize, payload.payload_length) +
            integrity_pad_size +
            2;

        if (c.verbose > 2) {
            c.printbuf(msg + off_authtype, @intCast(hmac_input_size), "authcode input");
        }

        _ = c.lanplus_HMAC(
            session.v2_data.integrity_alg,
            &session.v2_data.k1,
            @intCast(session.v2_data.k1_len),
            msg + off_authtype,
            @intCast(hmac_input_size),
            hmac_output,
            &hmac_length,
        );

        switch (session.v2_data.integrity_alg) {
            c.IPMI_INTEGRITY_HMAC_SHA1_96 => {
                cassert.expect(hmac_length == sha_digest_length, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 1843,
                    .func = "ipmi_lanplus_build_v2x_msg",
                    .expr = "hmac_length == IPMI_SHA_DIGEST_LENGTH",
                });
                auth_length = sha1_authcode_size;
            },
            c.IPMI_INTEGRITY_HMAC_MD5_128 => {
                cassert.expect(hmac_length == md5_digest_length, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 1847,
                    .func = "ipmi_lanplus_build_v2x_msg",
                    .expr = "hmac_length == IPMI_MD5_DIGEST_LENGTH",
                });
                auth_length = hmac_md5_authcode_size;
            },
            else => {
                if (have_sha256 and session.v2_data.integrity_alg == c.IPMI_INTEGRITY_HMAC_SHA256_128) {
                    cassert.expect(hmac_length == sha256_digest_length, .{
                        .file = "src/plugins/lanplus/lanplus.c",
                        .line = 1852,
                        .func = "ipmi_lanplus_build_v2x_msg",
                        .expr = "hmac_length == IPMI_SHA256_DIGEST_LENGTH",
                    });
                    auth_length = hmac_sha256_authcode_size;
                } else {
                    cassert.expect(false, .{
                        .file = "src/plugins/lanplus/lanplus.c",
                        .line = 1857,
                        .func = "ipmi_lanplus_build_v2x_msg",
                        .expr = "0",
                    });
                }
            },
        }

        if (c.verbose > 2) c.printbuf(hmac_output, @intCast(auth_length), "authcode output");

        // We only use the first 12 (SHA1) or 16 (MD5/SHA256) bytes.
        session_trailer_length = integrity_pad_size +
            2 + // pad length + next header
            auth_length;
    }

    session.out_seq +%= 1;
    if (session.out_seq == 0) session.out_seq +%= 1;

    msg_len.* = off_payload +
        @as(c_int, payload.payload_length) +
        @as(c_int, @intCast(session_trailer_length));
    msg_data.* = msg;
}

/// The `static uint8_t curr_seq` inside `ipmi_lanplus_build_v2x_ipmi_cmd()`.
var v2x_curr_seq: u8 = 0;

fn buildV2xIpmiCmd(intf: *Intf, req: *ipmi.Request, is_retry: c_int) ?*Entry {
    var v2_payload: ipmi.V2Payload = undefined;

    if (is_retry == 0) v2x_curr_seq +%= 1;

    if (v2x_curr_seq >= 64) v2x_curr_seq = 0;

    // IPMI message header, figure 13-4 of the IPMI v2.0 spec.
    var entry: ?*Entry = undefined;
    if (intf.target_addr == intf.my_addr or bridge_possible == 0) {
        entry = reqAddEntry(intf, req, v2x_curr_seq);
    } else {
        entry = reqAddEntry(intf, req, v2x_curr_seq);

        if (entry) |e| {
            e.req.msg.target_cmd = e.req.msg.cmd;
            e.req.msg.cmd = 0x34;

            if (intf.transit_addr != 0 and intf.transit_addr != intf.my_addr) {
                e.bridging_level = 2;
            } else {
                e.bridging_level = 1;
            }
        }
    }

    const e = entry orelse return null;

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.ipmi);
    v2_payload.payload_length = req.msg.data_len + 7;
    v2_payload.payload.ipmi_request.request = req;
    v2_payload.payload.ipmi_request.rq_seq = v2x_curr_seq;

    buildV2xMsg(intf, &v2_payload, &e.msg_len, &e.msg_data, v2x_curr_seq);

    return e;
}

/// `ipmi_lanplus_build_v15_ipmi_cmd()`.  The C also declares `mp`, assigns it
/// once and never reads it; there is nothing to translate.
fn buildV15IpmiCmd(intf: *Intf, req: *ipmi.Request) ?*Entry {
    const rmcp: RmcpHdr = .{
        .ver = rmcp_version_1,
        .__reserved = 0,
        .seq = 0xff,
        .class = rmcp_class_ipmi,
    };
    var cs: c_int = undefined;
    var len: c_int = 0;
    var tmp: c_int = undefined;
    const session = intf.session.?;

    const entry = reqAddEntry(intf, req, 0) orelse return null;

    len = @as(c_int, req.msg.data_len) + 21;

    const msg: [*]u8 = @ptrCast(c.malloc(@intCast(len)) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return null;
    });
    @memset(msg[0..@intCast(len)], 0);

    // RMCP header.
    @memcpy(msg[0..@sizeOf(RmcpHdr)], std.mem.asBytes(&rmcp));
    len = @sizeOf(RmcpHdr);

    // IPMI session header.  Authtype is always none for the 1.5 packets this
    // interface sends.
    msg[@intCast(len)] = c.IPMI_SESSION_AUTHTYPE_NONE;
    len += 1;

    msg[@intCast(len)] = @truncate(session.out_seq);
    len += 1;
    msg[@intCast(len)] = @truncate(session.out_seq >> 8);
    len += 1;
    msg[@intCast(len)] = @truncate(session.out_seq >> 16);
    len += 1;
    msg[@intCast(len)] = @truncate(session.out_seq >> 24);
    len += 1;

    // The session ID is all zeroes for pre-session commands.
    msg[@intCast(len)] = 0;
    len += 1;
    msg[@intCast(len)] = 0;
    len += 1;
    msg[@intCast(len)] = 0;
    len += 1;
    msg[@intCast(len)] = 0;
    len += 1;

    // Message length.
    msg[@intCast(len)] = @truncate(req.msg.data_len + 7);
    len += 1;

    // IPMI message header.
    cs = len;
    msg[@intCast(len)] = ipmi.bmc_slave_addr;
    len += 1;
    msg[@intCast(len)] = @as(u8, req.msg.netfn_lun.netfn) << 2;
    len += 1;
    tmp = len - cs;
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;
    cs = len;
    msg[@intCast(len)] = ipmi.remote_swid;
    len += 1;

    entry.rq_seq = 0;

    msg[@intCast(len)] = entry.rq_seq << 2;
    len += 1;
    msg[@intCast(len)] = req.msg.cmd;
    len += 1;

    c.lprintf(log.Level.debug + 1, ">> IPMI Request Session Header");
    c.lprintf(log.Level.debug + 1, ">>   Authtype   : %s", c.val2str(c.IPMI_SESSION_AUTHTYPE_NONE, c.ipmi_authtype_session_vals));
    c.lprintf(log.Level.debug + 1, ">>   Sequence   : 0x%08lx", @as(c_long, session.out_seq));
    c.lprintf(log.Level.debug + 1, ">>   Session ID : 0x%08lx", @as(c_long, 0));

    c.lprintf(log.Level.debug + 1, ">> IPMI Request Message Header");
    c.lprintf(log.Level.debug + 1, ">>   Rs Addr    : %02x", @as(c_int, ipmi.bmc_slave_addr));
    c.lprintf(log.Level.debug + 1, ">>   NetFn      : %02x", @as(c_int, req.msg.netfn_lun.netfn));
    c.lprintf(log.Level.debug + 1, ">>   Rs LUN     : %01x", @as(c_int, 0));
    c.lprintf(log.Level.debug + 1, ">>   Rq Addr    : %02x", @as(c_int, ipmi.remote_swid));
    c.lprintf(log.Level.debug + 1, ">>   Rq Seq     : %02x", @as(c_int, entry.rq_seq));
    c.lprintf(log.Level.debug + 1, ">>   Rq Lun     : %01x", @as(c_int, 0));
    c.lprintf(log.Level.debug + 1, ">>   Command    : %02x", @as(c_int, req.msg.cmd));

    // Message data.
    if (req.msg.data_len != 0) {
        @memcpy(
            msg[@intCast(len)..][0..req.msg.data_len],
            req.msg.data.?[0..req.msg.data_len],
        );
        len += req.msg.data_len;
    }

    // Second checksum.
    tmp = len - cs;
    msg[@intCast(len)] = c.ipmi_csum(msg + @as(usize, @intCast(cs)), tmp);
    len += 1;

    entry.msg_len = len;
    entry.msg_data = msg;

    return entry;
}

fn isSolPacket(rsp: ?*ipmi.Response) bool {
    const r = rsp orelse return false;
    return r.session.authtype == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS and
        r.session.payloadtype == @intFromEnum(ipmi.PayloadType.sol);
}

fn solResponseAcksPacket(rsp: ?*ipmi.Response, payload: ?*ipmi.V2Payload) bool {
    if (!isSolPacket(rsp)) return false;
    const p = payload orelse return false;
    return p.payload_type == @intFromEnum(ipmi.PayloadType.sol) and
        rsp.?.payload.sol_packet.acked_packet_number ==
            p.payload.sol_packet.packet_sequence_number;
}

// ---------------------------------------------------------------------------
// Send path
// ---------------------------------------------------------------------------

/// `ipmi_lanplus_send_payload()`.
fn sendPayload(intf: *Intf, payload: *ipmi.V2Payload) ?*ipmi.Response {
    var rsp: ?*ipmi.Response = null;
    var msg_data: ?[*]u8 = null;
    var msg_length: c_int = undefined;
    const session = intf.session.?;
    var entry: ?*Entry = null;
    var tries: c_int = 0;
    var xmit: bool = true;
    var ltime: c.time_t = undefined;

    if (intf.opened == 0) {
        if (intf.open) |open_fn| {
            if (open_fn(intf) < 0) return null;
        }
    }

    // The session timeout is initialised by the open above, so it is only
    // valid once the open completes.
    const saved_timeout = session.timeout;
    while (tries < intf.ssn_params.retry) {
        if (xmit) {
            ltime = c.time(null);

            if (payload.payload_type == @intFromEnum(ipmi.PayloadType.ipmi)) {
                const ipmi_request = payload.payload.ipmi_request.request.?;

                c.lprintf(log.Level.debug, "");
                c.lprintf(log.Level.debug, ">> Sending IPMI command payload");
                c.lprintf(log.Level.debug, ">>    netfn   : 0x%02x", @as(c_int, ipmi_request.msg.netfn_lun.netfn));
                c.lprintf(log.Level.debug, ">>    command : 0x%02x", @as(c_int, ipmi_request.msg.cmd));

                if (c.verbose > 1) {
                    _ = c.fprintf(c.stderr, ">>    data    : ");
                    var i: u16 = 0;
                    while (i < ipmi_request.msg.data_len) : (i += 1) {
                        _ = c.fprintf(c.stderr, "0x%02x ", @as(c_int, ipmi_request.msg.data.?[i]));
                    }
                    _ = c.fprintf(c.stderr, "\n\n");
                }

                // Pre-session Get Channel Authentication Capabilities goes out
                // in v1.5 format so that any server can be asked whether it
                // supports RMCP+ before a v2.x session is attempted.
                if (ipmi_request.msg.netfn_lun.netfn == ipmi.NetFn.app and
                    ipmi_request.msg.cmd == get_channel_auth_cap and
                    session.v2_data.bmc_id == 0)
                {
                    c.lprintf(log.Level.debug + 1, "BUILDING A v1.5 COMMAND");
                    entry = buildV15IpmiCmd(intf, ipmi_request);
                } else {
                    const is_retry: c_int = if (tries > 0) 1 else 0;

                    c.lprintf(log.Level.debug + 1, "BUILDING A v2 COMMAND");
                    entry = buildV2xIpmiCmd(intf, ipmi_request, is_retry);
                }

                const e = entry orelse {
                    c.lprintf(log.Level.err, "Aborting send command, unable to build");
                    return null;
                };

                msg_data = e.msg_data;
                msg_length = e.msg_len;
            } else if (payload.payload_type == @intFromEnum(ipmi.PayloadType.rmcp_open_request)) {
                c.lprintf(log.Level.debug, ">> SENDING AN OPEN SESSION REQUEST\n");
                cassert.expect(
                    session.v2_data.session_state == .presession or
                        session.v2_data.session_state == .open_session_sent,
                    .{
                        .file = "src/plugins/lanplus/lanplus.c",
                        .line = 2214,
                        .func = "ipmi_lanplus_send_payload",
                        .expr = "session->v2_data.session_state == LANPLUS_STATE_PRESESSION " ++
                            "|| session->v2_data.session_state == LANPLUS_STATE_OPEN_SESSION_SENT",
                    },
                );

                buildV2xMsg(intf, payload, &msg_length, &msg_data, 0);
            } else if (payload.payload_type == @intFromEnum(ipmi.PayloadType.rakp_1)) {
                c.lprintf(log.Level.debug, ">> SENDING A RAKP 1 MESSAGE\n");
                cassert.expect(session.v2_data.session_state == .open_session_received, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 2228,
                    .func = "ipmi_lanplus_send_payload",
                    .expr = "session->v2_data.session_state == LANPLUS_STATE_OPEN_SESSION_RECEIVED",
                });

                buildV2xMsg(intf, payload, &msg_length, &msg_data, 0);
            } else if (payload.payload_type == @intFromEnum(ipmi.PayloadType.rakp_3)) {
                c.lprintf(log.Level.debug, ">> SENDING A RAKP 3 MESSAGE\n");
                cassert.expect(session.v2_data.session_state == .rakp_2_received, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 2242,
                    .func = "ipmi_lanplus_send_payload",
                    .expr = "session->v2_data.session_state == LANPLUS_STATE_RAKP_2_RECEIVED",
                });

                buildV2xMsg(intf, payload, &msg_length, &msg_data, 0);
            } else if (payload.payload_type == @intFromEnum(ipmi.PayloadType.sol)) {
                c.lprintf(log.Level.debug, ">> SENDING A SOL MESSAGE\n");
                cassert.expect(session.v2_data.session_state == .active, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 2256,
                    .func = "ipmi_lanplus_send_payload",
                    .expr = "session->v2_data.session_state == LANPLUS_STATE_ACTIVE",
                });

                buildV2xMsg(intf, payload, &msg_length, &msg_data, 0);
            } else {
                c.lprintf(
                    log.Level.err,
                    "Payload type 0x%0x is unsupported!",
                    @as(c_int, payload.payload_type),
                );
                cassert.expect(false, .{
                    .file = "src/plugins/lanplus/lanplus.c",
                    .line = 2269,
                    .func = "ipmi_lanplus_send_payload",
                    .expr = "0",
                });
            }

            if (sendPacket(intf, msg_data.?, msg_length) < 0) {
                c.lprintf(log.Level.err, "IPMI LAN send command failed");
                return null;
            }
        }

        // If we are set to noanswer we do not expect a response.
        if (intf.noanswer != 0) break;

        _ = c.usleep(100); // Not sure what this is for.

        // Remember our connection state.
        switch (payload.payload_type) {
            @intFromEnum(ipmi.PayloadType.rmcp_open_request) => {
                session.v2_data.session_state = .open_session_sent;
                // Not retryable for timeouts, force no retry.
                tries = intf.ssn_params.retry;
            },
            @intFromEnum(ipmi.PayloadType.rakp_1) => {
                session.v2_data.session_state = .rakp_1_sent;
                tries = intf.ssn_params.retry;
            },
            @intFromEnum(ipmi.PayloadType.rakp_3) => {
                tries = intf.ssn_params.retry;
                session.v2_data.session_state = .rakp_3_sent;
            },
            else => {},
        }

        // Special case for SOL outbound packets.
        if (payload.payload_type == @intFromEnum(ipmi.PayloadType.sol)) {
            if (payload.payload.sol_packet.packet_sequence_number == 0) {
                // We are just sending an ACK.  No need to retry.
                break;
            }

            rsp = recvSol(intf); // Grab the next packet.

            if (!isSolPacket(rsp)) break;

            if (solResponseAcksPacket(rsp, payload)) {
                break;
            } else if (isSolPacket(rsp) and rsp.?.data_len != 0) {
                // Still waiting for our ACK, but we have more data from the
                // BMC.
                session.sol_data.sol_input_handler.?(rsp);
                // Avoid duplicate output by zeroing the length.
                rsp.?.data_len = 0;
                break;
            }
        } else {
            rsp = pollRecv(intf);

            // A Duplicate Request completion code most likely indicates a
            // response to a previous retry: ignore it and keep polling.
            while (rsp != null and rsp.?.ccode == 0xcf) {
                rsp = null;
                rsp = pollRecv(intf);
            }

            if (rsp != null) break;
            // This payload type is retryable for timeouts.
            if (payload.payload_type == @intFromEnum(ipmi.PayloadType.ipmi)) {
                if (entry) |e| reqRemoveEntry(e.rq_seq, e.req.msg.cmd);
            }
        }

        // Only time out if time exceeds the timeout value.
        xmit = (c.time(null) - ltime) >= @as(c.time_t, session.timeout);

        _ = c.usleep(5000);

        if (xmit) {
            // Increment the session timeout by one second each retry.
            session.timeout += 1;
        }

        tries += 1;
    }
    session.timeout = saved_timeout;

    // IPMI messages are deleted under ipmi_lan_poll_recv().
    switch (payload.payload_type) {
        @intFromEnum(ipmi.PayloadType.rmcp_open_request),
        @intFromEnum(ipmi.PayloadType.rakp_1),
        @intFromEnum(ipmi.PayloadType.rakp_3),
        @intFromEnum(ipmi.PayloadType.sol),
        => {
            c.free(msg_data);
            msg_data = null;
        },
        else => {},
    }

    return rsp;
}

/// `is_sol_partial_ack()`: how many characters have to be resent.
fn isSolPartialAck(
    intf: *Intf,
    v2_payload: ?*ipmi.V2Payload,
    rs: ?*ipmi.Response,
) callconv(.c) c_int {
    var chars_to_resend: c_int = 0;

    if (v2_payload != null and
        rs != null and
        isSolPacket(rs) and
        solResponseAcksPacket(rs, v2_payload) and
        rs.?.payload.sol_packet.accepted_character_count <
            v2_payload.?.payload.sol_packet.character_count)
    {
        if (c.ipmi_oem_active(cIntf(intf), "intelplus") != 0 and
            rs.?.payload.sol_packet.accepted_character_count == 0)
        {
            return 0;
        }

        chars_to_resend = @as(c_int, v2_payload.?.payload.sol_packet.character_count) -
            @as(c_int, rs.?.payload.sol_packet.accepted_character_count);
    }

    return chars_to_resend;
}

fn setSolPacketSequenceNumber(intf: *Intf, v2_payload: *ipmi.V2Payload) void {
    const sol = &intf.session.?.sol_data;

    // Keep our sequence number sane.
    if (sol.sequence_number > 0x0f) sol.sequence_number = 1;

    v2_payload.payload.sol_packet.packet_sequence_number = sol.sequence_number;
    sol.sequence_number +%= 1;
}

/// `ipmi_lanplus_send_sol()`.
fn sendSol(intf: *Intf, v2_payload: *ipmi.V2Payload) callconv(.c) ?*ipmi.Response {
    var chars_to_resend: c_int = 0;

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.sol);

    // The payload length is just the length of the character data here.
    v2_payload.payload_length = v2_payload.payload.sol_packet.character_count;

    v2_payload.payload.sol_packet.acked_packet_number = 0; // n/a

    setSolPacketSequenceNumber(intf, v2_payload);

    v2_payload.payload.sol_packet.accepted_character_count = 0; // n/a

    var rs = sendPayload(intf, v2_payload);

    chars_to_resend = isSolPartialAck(intf, v2_payload, rs);

    while (rs != null and
        rs.?.payload.sol_packet.transfer_unavailable == 0 and
        rs.?.payload.sol_packet.is_nack == 0 and
        chars_to_resend != 0)
    {
        // Handle any new data that arrived with the NACK first.
        if (rs.?.data_len != 0) intf.session.?.sol_data.sol_input_handler.?(rs);

        setSolPacketSequenceNumber(intf, v2_payload);

        // Just send the required data.
        const sol = &v2_payload.payload.sol_packet;
        const accepted = rs.?.payload.sol_packet.accepted_character_count;
        std.mem.copyForwards(
            u8,
            sol.data[0..@intCast(chars_to_resend)],
            sol.data[accepted..][0..@intCast(chars_to_resend)],
        );

        sol.character_count = @intCast(chars_to_resend);

        v2_payload.payload_length = sol.character_count;

        rs = sendPayload(intf, v2_payload);

        chars_to_resend = isSolPartialAck(intf, v2_payload, rs);
    }

    return rs;
}

/// The two function-level statics inside `check_sol_packet_for_new_data()`.
var sol_last_received_sequence_number: u8 = 0;
var sol_last_received_byte_count: u8 = 0;

fn checkSolPacketForNewData(rsp: ?*ipmi.Response) c_int {
    var new_data_size: c_int = 0;

    if (rsp) |r| {
        if (r.session.authtype == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS and
            r.session.payloadtype == @intFromEnum(ipmi.PayloadType.sol))
        {
            // Store the data length before it is modified.
            const unaltered_data_len: u8 = @truncate(@as(u32, @bitCast(r.data_len)));

            if (r.payload.sol_packet.packet_sequence_number ==
                sol_last_received_sequence_number)
            {
                // Same as the last packet, but may include extra data.
                new_data_size = r.data_len - @as(c_int, sol_last_received_byte_count);

                if (new_data_size > 0) {
                    std.mem.copyForwards(
                        u8,
                        r.data[0..@intCast(new_data_size)],
                        r.data[@intCast(r.data_len - new_data_size)..][0..@intCast(new_data_size)],
                    );
                }

                r.data_len = new_data_size;
            }

            // Remember the data for the next round.
            if (r.payload.sol_packet.packet_sequence_number != 0) {
                sol_last_received_sequence_number =
                    r.payload.sol_packet.packet_sequence_number;

                sol_last_received_byte_count = unaltered_data_len;
            }
        }
    }

    return new_data_size;
}

fn ackSolPacket(intf: *Intf, rsp: ?*ipmi.Response) void {
    const r = rsp orelse return;
    if (r.session.authtype != c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS) return;
    if (r.session.payloadtype != @intFromEnum(ipmi.PayloadType.sol)) return;
    if (r.payload.sol_packet.packet_sequence_number == 0) return;

    var ack: ipmi.V2Payload = std.mem.zeroes(ipmi.V2Payload);

    ack.payload_type = @intFromEnum(ipmi.PayloadType.sol);

    // The payload length is just the length of the character data here.
    ack.payload_length = 0;

    // ACK packets have sequence numbers of 0.
    ack.payload.sol_packet.packet_sequence_number = 0;

    ack.payload.sol_packet.acked_packet_number =
        r.payload.sol_packet.packet_sequence_number;

    ack.payload.sol_packet.accepted_character_count = @truncate(@as(u32, @bitCast(r.data_len)));

    _ = sendPayload(intf, &ack);
}

/// `ipmi_lanplus_recv_sol()`.
fn recvSol(intf: *Intf) callconv(.c) ?*ipmi.Response {
    const rsp = pollRecv(intf);

    if (rsp) |r| {
        if (r.session.authtype != 0) {
            ackSolPacket(intf, r);

            // Remembers the data sent, and alters the data to just include the
            // new bytes.
            _ = checkSolPacketForNewData(r);
        }
    }
    return rsp;
}

/// `ipmi_lanplus_send_ipmi_cmd()`.
fn sendIpmiCmd(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    var v2_payload: ipmi.V2Payload = undefined;

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.ipmi);
    v2_payload.payload.ipmi_request.request = req;

    return sendPayload(intf, &v2_payload);
}

// ---------------------------------------------------------------------------
// Session setup and teardown
// ---------------------------------------------------------------------------

/// `ipmi_get_auth_capabilities_cmd()`.
///
/// Note 7: `bridgePossible` is restored on the success path only.
/// Note 8: the `memcpy` is not guarded by a `data_len` check.
fn getAuthCapabilitiesCmd(intf: *Intf, auth_cap: *AuthCapRsp) c_int {
    var req: ipmi.Request = undefined;
    var msg_data: [2]u8 = undefined;

    const backup_bridge_possible = bridge_possible;

    bridge_possible = 0;

    msg_data[0] = lan_channel_e | 0x80; // ask for IPMI v2 data as well
    msg_data[1] = intf.ssn_params.privlvl;

    req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app; // 0x06
    req.msg.cmd = get_channel_auth_cap; // 0x38
    req.msg.data = &msg_data;
    req.msg.data_len = 2;

    var rsp = intf.sendrecv.?(intf, &req);

    if (rsp == null or rsp.?.ccode != 0) {
        // Very possibly a failure because IPMI v2 data was requested.  Ask
        // again without that bit.
        msg_data[0] &= 0x7f;

        rsp = intf.sendrecv.?(intf, &req);

        if (rsp == null) {
            c.lprintf(log.Level.info, "Get Auth Capabilities error");
            return 1;
        }
        if (rsp.?.ccode != 0) {
            c.lprintf(
                log.Level.info,
                "Get Auth Capabilities error: %s",
                c.val2str(rsp.?.ccode, c.completion_code_vals),
            );
            return 1;
        }
    }

    @memcpy(
        std.mem.asBytes(auth_cap),
        rsp.?.data[0..@sizeOf(AuthCapRsp)],
    );

    bridge_possible = backup_bridge_possible;

    return 0;
}

/// `ipmi_close_session_cmd()`.  `target_addr` is left overwritten and
/// `bridgePossible` is restored on the success path only.
fn closeSessionCmd(intf: *Intf) c_int {
    var req: ipmi.Request = undefined;
    var msg_data: [4]u8 = undefined;

    const session = intf.session orelse return -1;
    if (session.v2_data.session_state != .active) return -1;

    const backup_bridge_possible = bridge_possible;

    intf.target_addr = ipmi.bmc_slave_addr;
    bridge_possible = 0;

    c.htoipmi32(session.v2_data.bmc_id, &msg_data);

    req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x3c;
    req.msg.data = &msg_data;
    req.msg.data_len = 4;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        // Looks like the session was closed.
        c.lprintf(log.Level.err, "Close Session command failed");
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "close_session");

    if (rsp.ccode == 0x87) {
        c.lprintf(
            log.Level.err,
            "Failed to Close Session: invalid session ID %08lx",
            @as(c_long, session.v2_data.bmc_id),
        );
        return -1;
    }
    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Close Session command failed: %s",
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        return -1;
    }

    c.lprintf(
        log.Level.debug,
        "Closed Session %08lx\n",
        @as(c_long, session.v2_data.bmc_id),
    );

    bridge_possible = backup_bridge_possible;

    return 0;
}

/// `ipmi_lanplus_open_session()`: section 13.17 of the IPMI v2 specification.
/// Returns 0 on success, 1 on error, 2 on timeout.
fn openSession(intf: *Intf) c_int {
    var v2_payload: ipmi.V2Payload = undefined;
    const session = intf.session.?;
    var rc: c_int = 0;

    const msg: [*]u8 = @ptrCast(c.malloc(open_session_request_size) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return 1;
    });

    @memset(msg[0..open_session_request_size], 0);

    msg[0] = 0; // message tag
    if (c.ipmi_oem_active(cIntf(intf), "intelplus") != 0 or
        intf.ssn_params.privlvl != c.IPMI_SESSION_PRIV_ADMIN)
    {
        msg[1] = intf.ssn_params.privlvl;
    } else {
        // Give us the highest privilege level the algorithms support.
        msg[1] = 0;
    }
    msg[2] = 0; // reserved
    msg[3] = 0; // reserved

    // A recognisable session ID, for the packet dump.
    session.v2_data.console_id = 0xA0A2A3A4;
    msg[4] = @truncate(session.v2_data.console_id);
    msg[5] = @truncate(session.v2_data.console_id >> 8);
    msg[6] = @truncate(session.v2_data.console_id >> 16);
    msg[7] = @truncate(session.v2_data.console_id >> 24);

    if (getRequestedCiphers(
        @intFromEnum(intf.ssn_params.cipher_suite_id),
        &session.v2_data.requested_auth_alg,
        &session.v2_data.requested_integrity_alg,
        &session.v2_data.requested_crypt_alg,
    ) != 0) {
        c.lprintf(
            log.Level.warning,
            "Unsupported cipher suite ID : %d\n",
            @as(c_int, @intCast(@intFromEnum(intf.ssn_params.cipher_suite_id))),
        );
        c.free(msg);
        return 1;
    }

    // Authentication payload.
    msg[8] = 0; // specifies authentication payload
    msg[9] = 0; // reserved
    msg[10] = 0; // reserved
    msg[11] = 8; // payload length
    msg[12] = session.v2_data.requested_auth_alg;
    msg[13] = 0; // reserved
    msg[14] = 0; // reserved
    msg[15] = 0; // reserved

    // Integrity payload.
    msg[16] = 1; // specifies integrity payload
    msg[17] = 0; // reserved
    msg[18] = 0; // reserved
    msg[19] = 8; // payload length
    msg[20] = session.v2_data.requested_integrity_alg;
    msg[21] = 0; // reserved
    msg[22] = 0; // reserved
    msg[23] = 0; // reserved

    // Confidentiality / encryption payload.
    msg[24] = 2; // specifies confidentiality payload
    msg[25] = 0; // reserved
    msg[26] = 0; // reserved
    msg[27] = 8; // payload length
    msg[28] = session.v2_data.requested_crypt_alg;
    msg[29] = 0; // reserved
    msg[30] = 0; // reserved
    msg[31] = 0; // reserved

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.rmcp_open_request);
    v2_payload.payload_length = open_session_request_size;
    v2_payload.payload.open_session_request.request = msg;

    const rsp = sendPayload(intf, &v2_payload);

    c.free(msg);
    if (rsp == null) {
        c.lprintf(log.Level.debug, "Timeout in open session response message.");
        return 2;
    }
    const r = rsp.?;
    if (c.verbose != 0) c.lanplus_dump_open_session_response(cRsp(r));

    if (r.payload.open_session_response.rakp_return_code != rakp_status_no_errors) {
        c.lprintf(
            log.Level.warning,
            "Error in open session response message : %s\n",
            c.val2str(
                r.payload.open_session_response.rakp_return_code,
                c.ipmi_rakp_return_codes,
            ),
        );
        return 1;
    } else {
        if (r.payload.open_session_response.console_id != session.v2_data.console_id) {
            c.lprintf(
                log.Level.warning,
                "Warning: Console session ID is not what we requested",
            );
        }

        session.v2_data.max_priv_level = r.payload.open_session_response.max_priv_level;
        session.v2_data.bmc_id = r.payload.open_session_response.bmc_id;
        session.v2_data.auth_alg = r.payload.open_session_response.auth_alg;
        session.v2_data.integrity_alg = r.payload.open_session_response.integrity_alg;
        session.v2_data.crypt_alg = r.payload.open_session_response.crypt_alg;
        session.v2_data.session_state = .open_session_received;

        // Verify that we have agreed on a cipher suite.
        if (r.payload.open_session_response.auth_alg != session.v2_data.requested_auth_alg) {
            c.lprintf(
                log.Level.warning,
                "Authentication algorithm 0x%02x is not what we requested 0x%02x\n",
                @as(c_int, r.payload.open_session_response.auth_alg),
                @as(c_int, session.v2_data.requested_auth_alg),
            );
            rc = 1;
        } else if (r.payload.open_session_response.integrity_alg !=
            session.v2_data.requested_integrity_alg)
        {
            c.lprintf(
                log.Level.warning,
                "Integrity algorithm 0x%02x is not what we requested 0x%02x\n",
                @as(c_int, r.payload.open_session_response.integrity_alg),
                @as(c_int, session.v2_data.requested_integrity_alg),
            );
            rc = 1;
        } else if (r.payload.open_session_response.crypt_alg !=
            session.v2_data.requested_crypt_alg)
        {
            c.lprintf(
                log.Level.warning,
                "Encryption algorithm 0x%02x is not what we requested 0x%02x\n",
                @as(c_int, r.payload.open_session_response.crypt_alg),
                @as(c_int, session.v2_data.requested_crypt_alg),
            );
            rc = 1;
        }
    }

    return rc;
}

/// `ipmi_lanplus_rakp1()`: section 13.20 of the IPMI v2 specification.
fn rakp1(intf: *Intf) c_int {
    var v2_payload: ipmi.V2Payload = undefined;
    const session = intf.session.?;
    var rc: c_int = 0;

    const msg: [*]u8 = @ptrCast(c.malloc(rakp1_message_size) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return 1;
    });
    @memset(msg[0..rakp1_message_size], 0);

    msg[0] = 0; // message tag

    msg[1] = 0; // reserved
    msg[2] = 0; // reserved
    msg[3] = 0; // reserved

    // BMC session ID.
    msg[4] = @truncate(session.v2_data.bmc_id);
    msg[5] = @truncate(session.v2_data.bmc_id >> 8);
    msg[6] = @truncate(session.v2_data.bmc_id >> 16);
    msg[7] = @truncate(session.v2_data.bmc_id >> 24);

    // We need a 16 byte random number.
    if (c.lanplus_rand(&session.v2_data.console_rand, 16) != 0) {
        c.lprintf(log.Level.err, "ERROR generating random number in ipmi_lanplus_rakp1");
        c.free(msg);
        return 1;
    }
    @memcpy((msg + 8)[0..16], &session.v2_data.console_rand);
    _ = c.array_letoh(msg + 8, 16);

    if (c.verbose > 1) {
        c.printbuf(&session.v2_data.console_rand, 16, ">> Console generated random number");
    }

    // Requested maximum privilege level.
    msg[24] = intf.ssn_params.privlvl | intf.ssn_params.lookupbit;
    session.v2_data.requested_role = msg[24];
    msg[25] = 0; // reserved
    msg[26] = 0; // reserved

    // Username specification.
    msg[27] = @truncate(c.strlen(&intf.ssn_params.username));
    if (msg[27] > max_user_name_length) {
        c.lprintf(
            log.Level.err,
            "ERROR: user name too long.  (Exceeds %d characters)",
            @as(c_int, max_user_name_length),
        );
        c.free(msg);
        return 1;
    }
    @memcpy((msg + 28)[0..msg[27]], intf.ssn_params.username[0..msg[27]]);

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.rakp_1);
    if (c.ipmi_oem_active(cIntf(intf), "i82571spt") != 0) {
        // The IPMI v2.0 spec hints that all user name bytes must be occupied
        // (29:44).  The Intel 82571 GbE refuses to establish a session if this
        // field is shorter.
        v2_payload.payload_length = rakp1_message_size;
    } else {
        v2_payload.payload_length = rakp1_message_size - (16 - @as(u16, msg[27]));
    }
    v2_payload.payload.rakp_1_message.message = msg;

    const rsp = sendPayload(intf, &v2_payload);

    c.free(msg);

    const r = rsp orelse {
        c.lprintf(log.Level.warning, "> Error: no response from RAKP 1 message");
        return 2;
    };

    session.v2_data.session_state = .rakp_2_received;

    if (c.verbose != 0) c.lanplus_dump_rakp2_message(cRsp(r), session.v2_data.auth_alg);

    if (r.payload.rakp2_message.rakp_return_code != rakp_status_no_errors) {
        c.lprintf(
            log.Level.info,
            "RAKP 2 message indicates an error : %s",
            c.val2str(r.payload.rakp2_message.rakp_return_code, c.ipmi_rakp_return_codes),
        );
        rc = 1;
    } else {
        @memcpy(&session.v2_data.bmc_rand, &r.payload.rakp2_message.bmc_rand);
        @memcpy(&session.v2_data.bmc_guid, &r.payload.rakp2_message.bmc_guid);

        if (c.verbose > 2) c.printbuf(&session.v2_data.bmc_rand, 16, "bmc_rand");

        // Decode the random number and determine whether the BMC has
        // authenticated.
        if (c.lanplus_rakp2_hmac_matches(
            cSession(session),
            &r.payload.rakp2_message.key_exchange_auth_code,
            cIntf(intf),
        ) == 0) {
            c.lprintf(log.Level.info, "> RAKP 2 HMAC is invalid");
            session.v2_data.rakp2_return_code = rakp_status_invalid_integrity_check_value;
            rc = 1;
        } else {
            session.v2_data.rakp2_return_code = rakp_status_no_errors;
        }
    }

    return rc;
}

/// `ipmi_lanplus_rakp3()`.
///
/// Note 9: the RAKP 4 status is read through the `open_session_response` arm of
/// the union but logged through the `rakp4_message` arm.  Both fields sit at
/// offset 1, so the two reads agree.
fn rakp3(intf: *Intf) c_int {
    var v2_payload: ipmi.V2Payload = undefined;
    const session = intf.session.?;

    cassert.expect(session.v2_data.session_state == .rakp_2_received, .{
        .file = "src/plugins/lanplus/lanplus.c",
        .line = 3172,
        .func = "ipmi_lanplus_rakp3",
        .expr = "session->v2_data.session_state == LANPLUS_STATE_RAKP_2_RECEIVED",
    });

    const msg: [*]u8 = @ptrCast(c.malloc(rakp3_message_max_size) orelse {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return 1;
    });
    @memset(msg[0..rakp3_message_max_size], 0);

    msg[0] = 0; // message tag
    msg[1] = session.v2_data.rakp2_return_code;

    msg[2] = 0; // reserved
    msg[3] = 0; // reserved

    // BMC session ID.
    msg[4] = @truncate(session.v2_data.bmc_id);
    msg[5] = @truncate(session.v2_data.bmc_id >> 8);
    msg[6] = @truncate(session.v2_data.bmc_id >> 16);
    msg[7] = @truncate(session.v2_data.bmc_id >> 24);

    v2_payload.payload_type = @intFromEnum(ipmi.PayloadType.rakp_3);
    v2_payload.payload_length = 8;
    v2_payload.payload.rakp_3_message.message = msg;

    // If the RAKP 2 return code indicates an error there is no authcode or
    // session integrity key to generate: the RAKP 3 message only tells the BMC
    // that the RAKP 2 message caused an error.
    if (session.v2_data.rakp2_return_code == rakp_status_no_errors) {
        var auth_length: u32 = undefined;

        if (c.lanplus_generate_rakp3_authcode(msg + 8, cSession(session), &auth_length, cIntf(intf)) != 0) {
            c.lprintf(log.Level.info, "> Error generating RAKP 3 authcode");
            c.free(msg);
            return 1;
        } else {
            v2_payload.payload_length += @as(u16, @intCast(auth_length));
        }

        // Generate our session integrity key, K1 and K2.
        if (c.lanplus_generate_sik(cSession(session), cIntf(intf)) != 0) {
            c.lprintf(log.Level.info, "> Error generating session integrity key");
            c.free(msg);
            return 1;
        } else if (c.lanplus_generate_k1(cSession(session)) != 0) {
            c.lprintf(log.Level.info, "> Error generating K1 key");
            c.free(msg);
            return 1;
        } else if (c.lanplus_generate_k2(cSession(session)) != 0) {
            c.lprintf(log.Level.info, "> Error generating K1 key");
            c.free(msg);
            return 1;
        }
    }

    const rsp = sendPayload(intf, &v2_payload);

    c.free(msg);

    if (session.v2_data.rakp2_return_code != rakp_status_no_errors) {
        // The RAKP 3 message was only sent to report the RAKP 2 failure.
        return 1;
    }

    const r = rsp orelse {
        c.lprintf(log.Level.warning, "> Error: no response from RAKP 3 message");
        return 2;
    };

    // We have a RAKP 4 message to chew on.
    if (c.verbose != 0) c.lanplus_dump_rakp4_message(cRsp(r), session.v2_data.auth_alg);

    if (r.payload.open_session_response.rakp_return_code != rakp_status_no_errors) {
        c.lprintf(
            log.Level.info,
            "RAKP 4 message indicates an error : %s",
            c.val2str(r.payload.rakp4_message.rakp_return_code, c.ipmi_rakp_return_codes),
        );
        return 1;
    } else {
        if (c.lanplus_rakp4_hmac_matches(
            cSession(session),
            &r.payload.rakp4_message.integrity_check_value,
            cIntf(intf),
        ) != 0) {
            session.v2_data.session_state = .active;
        } else {
            c.lprintf(log.Level.info, "> RAKP 4 message has invalid integrity check value");
            return 1;
        }
    }

    intf.abort = 0;
    return 0;
}

/// `ipmi_lanplus_close()`.  Note 10: the trailing `intf = NULL` is a store to
/// the parameter and has no Zig counterpart.
fn close(intf: *Intf) callconv(.c) void {
    if (intf.abort == 0 and intf.session != null) _ = closeSessionCmd(intf);

    if (intf.fd >= 0) {
        _ = c.close(intf.fd);
        intf.fd = -1;
    }

    reqClearEntries();
    c.ipmi_intf_session_cleanup(cIntf(intf));
    intf.opened = 0;
    intf.manufacturer_id = @enumFromInt(c.IPMI_OEM_UNKNOWN);
}

fn setSessionPrivlvlCmd(intf: *Intf) c_int {
    var req: ipmi.Request = undefined;
    var privlvl: u8 = intf.ssn_params.privlvl;

    if (privlvl <= c.IPMI_SESSION_PRIV_USER) return 0; // no need to set higher

    const backup_bridge_possible = bridge_possible;

    bridge_possible = 0;

    req = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 0x3b;
    req.msg.data = @ptrCast(&privlvl);
    req.msg.data_len = 1;

    const rsp = intf.sendrecv.?(intf, &req) orelse {
        c.lprintf(
            log.Level.err,
            "Set Session Privilege Level to %s failed",
            c.val2str(privlvl, c.ipmi_privlvl_vals),
        );
        bridge_possible = backup_bridge_possible;
        return -1;
    };
    if (c.verbose > 2) c.printbuf(&rsp.data, rsp.data_len, "set_session_privlvl");

    if (rsp.ccode != 0) {
        c.lprintf(
            log.Level.err,
            "Set Session Privilege Level to %s failed: %s",
            c.val2str(privlvl, c.ipmi_privlvl_vals),
            c.val2str(rsp.ccode, c.completion_code_vals),
        );
        bridge_possible = backup_bridge_possible;
        return -1;
    }

    c.lprintf(
        log.Level.debug,
        "Set Session Privilege Level to %s\n",
        c.val2str(rsp.data[0], c.ipmi_privlvl_vals),
    );

    bridge_possible = backup_bridge_possible;

    return 0;
}

/// `ipmi_find_best_cipher_suite()`.  Everything but the suite 3 fallback is
/// inside `#ifdef HAVE_CRYPTO_SHA256`.
fn findBestCipherSuite(intf: *Intf) u8 {
    var best_suite: c.enum_cipher_suite_ids = c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED;

    if (have_sha256) {
        var suites: [max_cipher_suite_count]intf_mod.CipherSuiteInfo = undefined;
        var nr_suites: usize = suites.len;

        // Cipher suite order: HMAC-MD5 and MD5 are bad, xRC4 is bad, AES128 is
        // required, HMAC-SHA256 > HMAC-SHA1, secure authentication beats
        // encrypted content.  That leaves 17, then the mandatory 3.
        const cipher_order_preferred = [_]c.enum_cipher_suite_ids{
            c.IPMI_LANPLUS_CIPHER_SUITE_17,
            c.IPMI_LANPLUS_CIPHER_SUITE_3,
        };

        if (c.ipmi_get_channel_cipher_suites(
            cIntf(intf),
            "ipmi",
            lan_channel_e,
            @ptrCast(&suites),
            &nr_suites,
        ) < 0) {
            // Default legacy behaviour: fall back to cipher suite 3.
            return c.IPMI_LANPLUS_CIPHER_SUITE_3;
        }
        var ipref: usize = 0;
        while (ipref < cipher_order_preferred.len and
            best_suite == c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED) : (ipref += 1)
        {
            for (0..nr_suites) |i| {
                if (cipher_order_preferred[ipref] == @intFromEnum(suites[i].cipher_suite_id)) {
                    best_suite = cipher_order_preferred[ipref];
                    break;
                }
            }
        }
    }

    if (best_suite == c.IPMI_LANPLUS_CIPHER_SUITE_RESERVED) {
        // The IPMI 2.0 spec requires cipher suite 3, so it is always available
        // as a fallback.
        best_suite = c.IPMI_LANPLUS_CIPHER_SUITE_3;
    }
    c.lprintf(log.Level.info, "Using best available cipher suite %d\n", best_suite);
    return @truncate(@as(c_uint, @bitCast(best_suite)));
}

/// `ipmi_lanplus_open()`.  Note 12: the `!intf` guard has no counterpart.
fn open(intf: *Intf) callconv(.c) c_int {
    var rc: c_int = undefined;
    var auth_cap: AuthCapRsp = undefined;

    if (intf.opened != 0) return intf.fd;

    const params = &intf.ssn_params;

    if (params.port == 0) params.port = lanplus_port;
    if (params.privlvl == 0) params.privlvl = c.IPMI_SESSION_PRIV_ADMIN;
    if (params.timeout == 0) params.timeout = lan_timeout;
    if (params.retry == 0) params.retry = lan_retry;

    if (params.hostname == null or c.strlen(params.hostname) == 0) {
        c.lprintf(log.Level.err, "No hostname specified!");
        return -1;
    }

    fail: {
        if (c.ipmi_intf_socket_connect(cIntf(intf)) == -1) {
            c.lprintf(log.Level.err, "Could not open socket!");
            break :fail;
        }

        const session: *Session = @ptrCast(@alignCast(c.malloc(@sizeOf(Session)) orelse {
            c.lprintf(log.Level.err, "ipmitool: malloc failure");
            break :fail;
        }));

        intf.session = session;

        // Set up our lanplus session state.
        session.* = std.mem.zeroes(Session);
        session.timeout = params.timeout;
        @memcpy(&session.authcode, &params.authcode_set);
        session.v2_data.auth_alg = c.IPMI_AUTH_RAKP_NONE;
        session.v2_data.crypt_alg = c.IPMI_CRYPT_NONE;
        session.sol_data.sequence_number = 1;

        intf.opened = 1;
        intf.abort = 1;

        // Make sure the BMC supports IPMI v2 / RMCP+.
        if (c.ipmi_oem_active(cIntf(intf), "i82571spt") == 0 and
            getAuthCapabilitiesCmd(intf, &auth_cap) != 0)
        {
            c.lprintf(
                log.Level.info,
                "Error issuing Get Channel Authentication Capabilities request",
            );
            break :fail;
        }

        if (c.ipmi_oem_active(cIntf(intf), "i82571spt") == 0 and
            auth_cap.b1.v20_data_available == 0)
        {
            c.lprintf(log.Level.info, "This BMC does not support IPMI v2 / RMCP+");
            break :fail;
        }

        // If no cipher suite was provided, query the channel cipher suite list
        // and pick the best one available.
        if (intf.ssn_params.cipher_suite_id == .reserved) {
            c.ipmi_intf_session_set_cipher_suite_id(cIntf(intf), findBestCipherSuite(intf));
        }

        // If the open/rakp1/rakp3 sequence times out the whole sequence has to
        // restart: the individual messages are not retryable because the
        // session state is advancing.
        var retry: c_int = 0;
        while (retry < lan_retry) : (retry += 1) {
            session.v2_data.session_state = .presession;

            rc = openSession(intf);
            if (rc == 1) break :fail;
            if (rc == 2) {
                c.lprintf(log.Level.debug, "Retry lanplus open session, %d", retry);
                continue;
            }

            rc = rakp1(intf);
            if (rc == 1) break :fail;
            if (rc == 2) {
                c.lprintf(log.Level.debug, "Retry lanplus rakp1, %d", retry);
                continue;
            }

            rc = rakp3(intf);
            if (rc == 1) break :fail;
            if (rc == 0) break;
            c.lprintf(log.Level.debug, "Retry lanplus rakp3, %d", retry);
        }

        c.lprintf(log.Level.debug, "IPMIv2 / RMCP+ SESSION OPENED SUCCESSFULLY\n");

        intf.abort = 0;

        if (c.ipmi_oem_active(cIntf(intf), "i82571spt") == 0) {
            rc = setSessionPrivlvlCmd(intf);
            if (rc < 0) break :fail;

            // Automatically detect interface request and response sizes.
            _ = c.hpm2_detect_max_payload_size(cIntf(intf));
        }

        bridge_possible = 1;

        if (c.ipmi_oem_active(cIntf(intf), "i82571spt") == 0) {
            intf.manufacturer_id = @enumFromInt(c.ipmi_get_oem(cIntf(intf)));
        }

        return intf.fd;
    }

    c.lprintf(log.Level.err, "Error: Unable to establish IPMI v2 / RMCP+ session");
    intf.close.?(intf);
    return -1;
}

// ---------------------------------------------------------------------------
// Developer smoke tests, reachable only by editing the source
// ---------------------------------------------------------------------------

fn testCrypt1() callconv(.c) void {
    const key = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
    };

    var bytes_encrypted: u16 = undefined;
    var bytes_decrypted: u16 = undefined;
    var decrypt_buffer: [1000]u8 = undefined;
    var encrypt_buffer: [1000]u8 = undefined;

    const data = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12,
    };

    c.printbuf(&data, data.len, "original data");

    if (c.lanplus_encrypt_payload(
        c.IPMI_CRYPT_AES_CBC_128,
        &key,
        &data,
        data.len,
        &encrypt_buffer,
        &bytes_encrypted,
    ) != 0) {
        c.lprintf(log.Level.err, "Encrypt test failed");
        cassert.expect(false, .{
            .file = "src/plugins/lanplus/lanplus.c",
            .line = 3623,
            .func = "test_crypt1",
            .expr = "0",
        });
    }
    c.printbuf(&encrypt_buffer, bytes_encrypted, "encrypted payload");

    if (c.lanplus_decrypt_payload(
        c.IPMI_CRYPT_AES_CBC_128,
        &key,
        &encrypt_buffer,
        bytes_encrypted,
        &decrypt_buffer,
        &bytes_decrypted,
    ) != 0) {
        c.lprintf(log.Level.err, "Decrypt test failed\n");
        cassert.expect(false, .{
            .file = "src/plugins/lanplus/lanplus.c",
            .line = 3636,
            .func = "test_crypt1",
            .expr = "0",
        });
    }
    c.printbuf(&decrypt_buffer, bytes_decrypted, "decrypted payload");

    c.lprintf(log.Level.debug, "\nDone testing the encrypt/decyrpt methods!\n");
    c.exit(0);
}

fn testCrypt2() callconv(.c) void {
    const key = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
    };
    const iv = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
        0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14,
    };
    const data: [8]u8 = "12345678".*;

    var encrypt_buffer: [1000]u8 = undefined;
    var decrypt_buffer: [1000]u8 = undefined;
    var bytes_encrypted: u32 = undefined;
    var bytes_decrypted: u32 = undefined;

    c.printbuf(&data, @intCast(c.strlen(&data)), "input data");

    c.lanplus_encrypt_aes_cbc_128(
        &iv,
        &key,
        &data,
        @intCast(c.strlen(&data)),
        &encrypt_buffer,
        &bytes_encrypted,
    );
    c.printbuf(&encrypt_buffer, @intCast(bytes_encrypted), "encrypt_buffer");

    c.lanplus_decrypt_aes_cbc_128(
        &iv,
        &key,
        &encrypt_buffer,
        bytes_encrypted,
        &decrypt_buffer,
        &bytes_decrypted,
    );
    c.printbuf(&decrypt_buffer, @intCast(bytes_decrypted), "decrypt_buffer");

    c.lprintf(log.Level.info, "\nDone testing the encrypt/decyrpt methods!\n");
    c.exit(0);
}

// ---------------------------------------------------------------------------
// Vtable entry points
// ---------------------------------------------------------------------------

/// Send a Get Device ID command to keep the session active.
fn keepalive(intf: *Intf) callconv(.c) c_int {
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = ipmi.NetFn.app;
    req.msg.cmd = 1;

    if (intf.opened == 0) return 0;

    var rsp = intf.sendrecv.?(intf, &req);
    while (rsp != null and isSolPacket(rsp)) {
        // The response was SOL data rather than our answer.  Since it did not
        // go through the SOL receive path, do the SOL receive work here.
        ackSolPacket(intf, rsp);
        _ = checkSolPacketForNewData(rsp);
        if (rsp.?.data_len != 0) intf.session.?.sol_data.sol_input_handler.?(rsp);
        rsp = pollRecv(intf);
        // The Get Device ID answer never came back, but the retry mechanism was
        // bypassed by SOL data, so the connection is still alive.
        if (rsp == null) return 0;
    }

    if (rsp == null or rsp.?.ccode != 0) return -1;

    return 0;
}

/// `ipmi_lanplus_setup()`.  Note 11: the leading `assert("ipmi_lanplus_setup")`
/// is always true and has no counterpart, and `test_crypt1()` is commented out
/// upstream.
fn setup(intf: *Intf) callconv(.c) c_int {
    if (c.lanplus_seed_prng(16) != 0) return -1;

    // Default LAN maximum request and response sizes.
    intf.max_request_data_size = max_request_size;
    intf.max_response_data_size = max_response_size;

    return 0;
}

fn setMaxRqDataSize(intf: *Intf, size_in: u16) callconv(.c) void {
    var size = size_in;
    if (intf.ssn_params.cipher_suite_id == .suite_3) {
        // An encrypted payload can only be a multiple of 16 bytes.
        size &= ~@as(u16, 15);

        // Subtract the confidentiality header size plus the minimal
        // confidentiality trailer size.
        size -%= (16 + 1);
    }

    intf.max_request_data_size = size;
}

fn setMaxRpDataSize(intf: *Intf, size_in: u16) callconv(.c) void {
    var size = size_in;
    if (intf.ssn_params.cipher_suite_id == .suite_3) {
        size &= ~@as(u16, 15);
        size -%= (16 + 1);
    }

    intf.max_response_data_size = size;
}

/// `struct ipmi_intf ipmi_lanplus_intf`.
var lanplus_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    const name = "lanplus";
    const desc = "IPMI v2.0 RMCP+ LAN Interface";
    @memcpy(i.name[0..name.len], name);
    @memcpy(i.desc[0..desc.len], desc);
    i.setup = setup;
    i.open = open;
    i.close = close;
    i.sendrecv = sendIpmiCmd;
    i.recv_sol = recvSol;
    i.send_sol = sendSol;
    i.keepalive = keepalive;
    i.set_max_request_data_size = setMaxRqDataSize;
    i.set_max_response_data_size = setMaxRpDataSize;
    i.target_addr = ipmi.bmc_slave_addr;
    break :blk i;
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(RmcpHdr, c.struct_rmcp_hdr);
    abi.assertLayout(AsfHdr, c.struct_asf_hdr);
    abi.assertLayout(RmcpPong, c.struct_rmcp_pong);
}

comptime {
    // `val2str()`, `ipmi_csum()` and the rest of the C that the transport
    // reaches for are supplied by `intf/test_stubs.zig`, which only exists in
    // the test binary.
    if (builtin.is_test) _ = @import("test_stubs.zig");
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(open), @TypeOf(c.ipmi_lanplus_open));
    abi.assertCallSignature(@TypeOf(close), @TypeOf(c.ipmi_lanplus_close));
    abi.assertCallSignature(@TypeOf(lanPing), @TypeOf(c.ipmiv2_lan_ping));

    @export(&open, .{ .name = "ipmi_lanplus_open" });
    @export(&close, .{ .name = "ipmi_lanplus_close" });
    @export(&lanPing, .{ .name = "ipmiv2_lan_ping" });

    // The five symbols below have external linkage upstream but no prototype in
    // any header -- `lanplus.c` forward-declares them without `static` and then
    // never declares them again -- so there is nothing for
    // `assertCallSignature` to check them against.  Nothing outside
    // `lanplus.c` calls them; the exports exist to keep the symbol table
    // identical to the C translation unit's.
    @export(&buildV2xMsg, .{ .name = "ipmi_lanplus_build_v2x_msg" });
    @export(&isSolPartialAck, .{ .name = "is_sol_partial_ack" });
    @export(&getRequestedCiphers, .{ .name = "lanplus_get_requested_ciphers" });
    @export(&testCrypt1, .{ .name = "test_crypt1" });
    @export(&testCrypt2, .{ .name = "test_crypt2" });

    @export(&lanplus_intf, .{ .name = "ipmi_lanplus_intf" });
}
