//! Port of `lib/ipmi_channel.c`: the `channel` command and the Get/Set Channel
//! Access, Get Channel Info and Get Channel Cipher Suites primitives that the
//! rest of ipmitool calls into.
//!
//! Selected with `zig build -Dzig-modules=channel`, which drops
//! `lib/ipmi_channel.c` from the compile and links this module instead.
//!
//! Unlike the other command ports this file is not a leaf: eleven of its
//! symbols have external linkage and are called from `lib/ipmi_lanp.c`,
//! `lib/ipmi_user.c`, `lib/ipmi_pef.c`, `lib/ipmi_event.c`,
//! `src/plugins/lanplus/lanplus.c` and `src/ipmitool.c`.  All eleven keep their
//! C names and signatures, including `_ipmi_set_channel_access()`, which takes
//! its `struct channel_access_t` *by value*.
//!
//! Things worth knowing before reading on:
//!
//! * **`struct get_channel_auth_cap_rsp` is `opaque {}`.**  It is three bytes
//!   of bitfields between two plain ones, so `translate-c` gives up on it.  The
//!   `AuthCapRsp` mirror below is written out by hand with `packed struct(u8)`
//!   for each bitfield byte and pinned against `abi_layout.h`.  A Zig packed
//!   struct fills from bit 0 up, which is what C does on little endian targets;
//!   the header spells the big endian order out separately, so the mirror
//!   switches on the target endianness the same way `core/ipmi.zig` does for
//!   `netfn`/`lun`.
//! * **The two cipher suite records are inside a `#pragma pack` region**, which
//!   `translate-c` silently ignores.  Both are all-`uint8_t` so the packed and
//!   unpacked layouts happen to agree, but rather than rely on that the parser
//!   below indexes the byte buffer directly and takes only the record *sizes*
//!   from `abi_layout.h`.
//! * **`struct channel_info_t` and `struct channel_access_t` are used straight
//!   from the bridge.**  Neither has a bitfield and neither is inside a
//!   `#pragma pack` region, so `translate-c` represents them faithfully -
//!   including the fact that `channel_access_t.alerting` is an `enum`, and so
//!   four bytes wide with three bytes of padding in front of it.
//! * **Two upstream defects are reproduced deliberately.**  See issue #37:
//!   - `ipmi_print_channel_cipher_suites()` passes `sizeof(*suites)` - the size
//!     of one `struct cipher_suite_info`, i.e. 12 - as the capacity of a
//!     `MAX_CIPHER_SUITE_COUNT` (204) element array, so at most twelve cipher
//!     suites are ever printed however many the BMC reports.
//!   - `parse_channel_cipher_suite_data()` logs a `size_t` through `%d`.
//!
//! Everything this module needs from C - `printf`, `lprintf`, `val2str`,
//! `str2val`, `str2uchar`, `eval_ccode`, the `is_ipmi_*` validators and the
//! three `_ipmi_*_user_*` primitives that still live in `lib/ipmi_user.c` - is
//! reached through the `ipmi_c` bridge.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");

const Intf = intf_mod.Intf;
const CipherSuiteInfo = intf_mod.CipherSuiteInfo;
const Request = ipmi.Request;
const Response = ipmi.Response;

const ChannelInfo = c.struct_channel_info_t;
const ChannelAccess = c.struct_channel_access_t;
const UserAccess = c.struct_user_access_t;
const UserName = c.struct_user_name_t;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const netfn_app: u6 = @intCast(c.IPMI_NETFN_APP);

const cmd_get_channel_auth_cap: u8 = @intCast(c.IPMI_GET_CHANNEL_AUTH_CAP);
const cmd_set_channel_access: u8 = @intCast(c.IPMI_SET_CHANNEL_ACCESS);
const cmd_get_channel_access: u8 = @intCast(c.IPMI_GET_CHANNEL_ACCESS);
const cmd_get_channel_info: u8 = @intCast(c.IPMI_GET_CHANNEL_INFO);
const cmd_get_channel_cipher_suites: u8 = @intCast(c.IPMI_GET_CHANNEL_CIPHER_SUITES);

const std_record_size: usize = c.ABI_SIZEOF_std_cipher_suite_record;
const oem_record_size: usize = c.ABI_SIZEOF_oem_cipher_suite_record;

const standard_cipher_suite: u8 = @intCast(c.STANDARD_CIPHER_SUITE);
const oem_cipher_suite: u8 = @intCast(c.OEM_CIPHER_SUITE);
const cipher_alg_mask: u8 = @intCast(c.CIPHER_ALG_MASK);
const max_cipher_suite_record_offset: usize = c.MAX_CIPHER_SUITE_RECORD_OFFSET;
const max_cipher_suite_data_len: usize = c.MAX_CIPHER_SUITE_DATA_LEN;
const list_algorithms_by_cipher_suite: u8 = @intCast(c.LIST_ALGORITHMS_BY_CIPHER_SUITE);

/// `MAX_CIPHER_SUITE_COUNT`: 0x40 * 0x10 / sizeof(struct std_cipher_suite_record_t).
const max_cipher_suite_count: usize =
    max_cipher_suite_record_offset * max_cipher_suite_data_len / std_record_size;

const ch_current: u8 = @intCast(c.CH_CURRENT);
const ch_unknown: u8 = 0xff;

/// `struct get_channel_auth_cap_rsp`, which `translate-c` demotes to
/// `opaque {}` because bytes 1, 2 and 3 are entirely bitfields.
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

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

/// One `intf->sendrecv()` round trip.
fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

// ---------------------------------------------------------------------------
// Channel access / info primitives
// ---------------------------------------------------------------------------

/// `_ipmi_get_channel_access()`.
///
/// Negative return values are errors, positive ones are completion codes.
fn getChannelAccess(
    intf: *Intf,
    channel_access: ?*ChannelAccess,
    get_volatile_settings: u8,
) callconv(.c) c_int {
    const ca = channel_access orelse return -3;

    var data: [2]u8 = undefined;
    data[0] = ca.channel & 0x0f;
    // volatile - 0x80; non-volatile - 0x40
    data[1] = if (get_volatile_settings != 0) 0x80 else 0x40;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_channel_access;
    req.msg.data = &data;
    req.msg.data_len = 2;

    const rsp = sendrecv(intf, &req) orelse return -1;
    if (rsp.ccode != 0) return rsp.ccode;
    if (rsp.data_len != 2) return -2;

    ca.alerting = rsp.data[0] & 0x20;
    ca.per_message_auth = rsp.data[0] & 0x10;
    ca.user_level_auth = rsp.data[0] & 0x08;
    ca.access_mode = rsp.data[0] & 0x07;
    ca.privilege_limit = rsp.data[1] & 0x0f;
    return 0;
}

/// `_ipmi_get_channel_info()`.
fn getChannelInfoRaw(intf: *Intf, channel_info: ?*ChannelInfo) callconv(.c) c_int {
    const ci = channel_info orelse return -3;

    var data: [1]u8 = undefined;
    data[0] = ci.channel & 0x0f;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_channel_info;
    req.msg.data = &data;
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req) orelse return -1;
    if (rsp.ccode != 0) return rsp.ccode;
    if (rsp.data_len != 9) return -2;

    ci.channel = rsp.data[0] & 0x0f;
    ci.medium = rsp.data[1] & 0x7f;
    ci.protocol = rsp.data[2] & 0x1f;
    ci.session_support = rsp.data[3] & 0xc0;
    ci.active_sessions = rsp.data[3] & 0x3f;
    @memcpy(ci.vendor_id[0..3], rsp.data[4..7]);
    @memcpy(ci.aux_info[0..2], rsp.data[7..9]);
    return 0;
}

/// `_ipmi_set_channel_access()`.
///
/// `channel_access` is passed by value, exactly as in C.
fn setChannelAccess(
    intf: *Intf,
    channel_access: ChannelAccess,
    access_option: u8,
    privilege_option: u8,
) callconv(.c) c_int {
    // Only values from <0..2> are accepted as valid.
    if (access_option > 2 or privilege_option > 2) return -3;

    var data = [_]u8{ 0, 0, 0 };
    data[0] = channel_access.channel & 0x0f;
    data[1] = @truncate(@as(u32, access_option) << 6);
    if (channel_access.alerting != 0) data[1] |= 0x20;
    if (channel_access.per_message_auth != 0) data[1] |= 0x10;
    if (channel_access.user_level_auth != 0) data[1] |= 0x08;
    data[1] |= channel_access.access_mode & 0x07;
    data[2] = @truncate(@as(u32, privilege_option) << 6);
    data[2] |= channel_access.privilege_limit & 0x0f;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_set_channel_access;
    req.msg.data = &data;
    req.msg.data_len = 3;

    const rsp = sendrecv(intf, &req) orelse return -1;
    return rsp.ccode;
}

/// `iana_string()`.
///
/// Keeps the `static char s[10]` of the original, so the returned pointer is
/// invalidated by the next call - which is fine, because the only caller
/// consumes it immediately.
var iana_buf: [10]u8 = undefined;

fn ianaString(iana: u32) [*:0]const u8 {
    if (iana != 0) {
        _ = c.sprintf(&iana_buf, "%06x", iana);
        return @ptrCast(&iana_buf);
    }
    return "N/A";
}

/// `ipmi_1_5_authtypes()`: the space separated list of v1.5 auth types in `n`.
var supported_types: [128]u8 = undefined;

fn authTypes15(n: u8) [*:0]const u8 {
    @memset(&supported_types, 0);
    var i: usize = 0;
    while (c.ipmi_authtype_vals[i].val != 0) : (i += 1) {
        if ((n & @as(u8, @truncate(c.ipmi_authtype_vals[i].val))) != 0) {
            _ = c.strcat(&supported_types, c.ipmi_authtype_vals[i].str);
            _ = c.strcat(&supported_types, " ");
        }
    }
    return @ptrCast(&supported_types);
}

/// `ipmi_current_channel_info()`.
fn currentChannelInfo(intf: *Intf, chinfo: *ChannelInfo) callconv(.c) void {
    chinfo.channel = ch_current;
    const ccode = getChannelInfoRaw(intf, chinfo);
    if (ccode != 0) {
        if (ccode != c.IPMI_CC_INV_DATA_FIELD_IN_REQ) {
            if (ccode > 0) {
                c.lprintf(
                    log.Level.err,
                    "Get Channel Info command failed: %s",
                    ccString(@truncate(@as(c_uint, @bitCast(ccode)))),
                );
            } else {
                _ = c.eval_ccode(ccode);
            }
        }
        chinfo.channel = ch_unknown;
        chinfo.medium = @intCast(c.IPMI_CHANNEL_MEDIUM_RESERVED);
    }
}

// ---------------------------------------------------------------------------
// channel authcap
// ---------------------------------------------------------------------------

/// `ipmi_get_channel_auth_cap()`.  Returns 0 on success and -1 on failure.
fn getChannelAuthCap(intf: *Intf, channel: u8, priv: u8) callconv(.c) c_int {
    var msg_data: [2]u8 = undefined;
    // Ask for IPMI v2 data as well
    msg_data[0] = channel | 0x80;
    msg_data[1] = priv;

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_channel_auth_cap;
    req.msg.data = &msg_data;
    req.msg.data_len = 2;

    var rsp = sendrecv(intf, &req);

    if (rsp == null or rsp.?.ccode != 0) {
        // It's very possible that this failed because we asked for IPMI v2
        // data.  Ask again, without requesting IPMI v2 data.
        msg_data[0] &= 0x7f;

        rsp = sendrecv(intf, &req);
        const retry = rsp orelse {
            c.lprintf(log.Level.err, "Unable to Get Channel Authentication Capabilities");
            return -1;
        };
        if (retry.ccode != 0) {
            c.lprintf(
                log.Level.err,
                "Get Channel Authentication Capabilities failed: %s",
                ccString(retry.ccode),
            );
            return -1;
        }
    }

    var auth_cap: AuthCapRsp = undefined;
    @memcpy(std.mem.asBytes(&auth_cap), rsp.?.data[0..@sizeOf(AuthCapRsp)]);

    _ = c.printf("Channel number             : %d\n", @as(c_int, auth_cap.channel_number));
    _ = c.printf(
        "IPMI v1.5  auth types      : %s\n",
        authTypes15(auth_cap.b1.enabled_auth_types),
    );

    if (auth_cap.b1.v20_data_available != 0) {
        _ = c.printf(
            "KG status                  : %s\n",
            yesNo(auth_cap.b2.kg_status, "non-zero", "default (all zeroes)"),
        );
    }

    _ = c.printf(
        "Per message authentication : %sabled\n",
        yesNo(auth_cap.b2.per_message_auth, "dis", "en"),
    );
    _ = c.printf(
        "User level authentication  : %sabled\n",
        yesNo(auth_cap.b2.user_level_auth, "dis", "en"),
    );

    _ = c.printf(
        "Non-null user names exist  : %s\n",
        yesNo(auth_cap.b2.non_null_usernames, "yes", "no"),
    );
    _ = c.printf(
        "Null user names exist      : %s\n",
        yesNo(auth_cap.b2.null_usernames, "yes", "no"),
    );
    _ = c.printf(
        "Anonymous login enabled    : %s\n",
        yesNo(auth_cap.b2.anon_login_enabled, "yes", "no"),
    );

    if (auth_cap.b1.v20_data_available != 0) {
        _ = c.printf(
            "Channel supports IPMI v1.5 : %s\n",
            yesNo(auth_cap.b3.ipmiv15_support, "yes", "no"),
        );
        _ = c.printf(
            "Channel supports IPMI v2.0 : %s\n",
            yesNo(auth_cap.b3.ipmiv20_support, "yes", "no"),
        );
    }

    // If there is support for an OEM authentication type, there is some
    // information.
    if ((auth_cap.b1.enabled_auth_types & @as(u6, @intCast(c.IPMI_1_5_AUTH_TYPE_BIT_OEM))) != 0) {
        _ = c.printf(
            "IANA Number for OEM        : %d\n",
            @as(c_int, auth_cap.oem_id[0]) |
                @as(c_int, auth_cap.oem_id[1]) << 8 |
                @as(c_int, auth_cap.oem_id[2]) << 16,
        );
        _ = c.printf(
            "OEM Auxiliary Data         : 0x%x\n",
            @as(c_uint, auth_cap.oem_aux_data),
        );
    }

    return 0;
}

fn yesNo(bit: u1, when_set: [*:0]const u8, when_clear: [*:0]const u8) [*:0]const u8 {
    return if (bit != 0) when_set else when_clear;
}

// ---------------------------------------------------------------------------
// channel getciphers
// ---------------------------------------------------------------------------

const incomplete_msg = "Incomplete data record in cipher suite data";

/// `parse_cipher_suite()`: decode one record and return its size, or 0.
fn parseCipherSuite(
    data: []const u8,
    iana: *u32,
    auth_alg: *u8,
    integrity_alg: *u8,
    crypt_alg: *u8,
    cipher_suite_id: *intf_mod.CipherSuiteId,
) usize {
    if (data[0] == standard_cipher_suite) {
        // Verify that we have at least a full record left; id + 3 algs
        if (data.len < std_record_size) {
            c.lprintf(log.Level.info, "%s", @as([*:0]const u8, incomplete_msg));
            return 0;
        }
        // IANA code remains default (0)
        cipher_suite_id.* = @enumFromInt(data[1]);
        auth_alg.* = cipher_alg_mask & data[2];
        integrity_alg.* = cipher_alg_mask & data[3];
        crypt_alg.* = cipher_alg_mask & data[4];
        return std_record_size;
    } else if (data[0] == oem_cipher_suite) {
        // OEM record type.  Verify that we have at least a full record left:
        // id + iana + 3 algs
        if (data.len < oem_record_size) {
            c.lprintf(log.Level.info, "%s", @as([*:0]const u8, incomplete_msg));
            return 0;
        }
        // Grab the IANA
        iana.* = @as(u32, data[2]) | @as(u32, data[3]) << 8 | @as(u32, data[4]) << 16;
        cipher_suite_id.* = @enumFromInt(data[1]);
        auth_alg.* = cipher_alg_mask & data[5];
        integrity_alg.* = cipher_alg_mask & data[6];
        crypt_alg.* = cipher_alg_mask & data[7];
        return oem_record_size;
    }

    c.lprintf(
        log.Level.info,
        "Bad start of record byte in cipher suite data (value %x)",
        @as(c_uint, data[0]),
    );
    return 0;
}

/// `parse_channel_cipher_suite_data()`.
fn parseChannelCipherSuiteData(
    data: []const u8,
    suites: []CipherSuiteInfo,
) usize {
    var count: usize = 0;
    var offset: usize = 0;

    // Default everything to zeroes
    @memset(std.mem.sliceAsBytes(suites), 0);

    while (offset < data.len and count < suites.len) {
        // Set non-zero defaults
        suites[count].auth_alg = @intCast(c.IPMI_AUTH_RAKP_NONE);
        suites[count].integrity_alg = @intCast(c.IPMI_INTEGRITY_NONE);
        suites[count].crypt_alg = @intCast(c.IPMI_CRYPT_NONE);

        // Update fields from cipher suite data
        const suite_size = parseCipherSuite(
            data[offset..],
            &suites[count].iana,
            &suites[count].auth_alg,
            &suites[count].integrity_alg,
            &suites[count].crypt_alg,
            &suites[count].cipher_suite_id,
        );

        if (suite_size == 0) {
            // `offset` is a size_t passed through `%d`, which is an upstream
            // format bug.  On every ABI ipmitool builds for, varargs promote
            // the 64-bit value into the same register or stack slot a 32-bit
            // one would occupy, so printf reads the low half; reproduce that
            // by truncating explicitly.  See issue #37.
            c.lprintf(
                log.Level.info,
                "Failed to parse cipher suite data at offset %d",
                @as(c_int, @truncate(@as(isize, @bitCast(offset)))),
            );
            break;
        }

        offset += suite_size;
        count += 1;
    }
    return count;
}

/// `ipmi_get_channel_cipher_suites()`.
fn getChannelCipherSuites(
    intf: *Intf,
    payload_type: ?[*:0]const u8,
    channel: u8,
    suites: ?[*]CipherSuiteInfo,
    count: ?*usize,
) callconv(.c) c_int {
    var rqdata: [3]u8 = undefined;
    var list_index: u8 = 0;
    // 0x40 sets * 16 bytes per set
    var cipher_suite_data: [max_cipher_suite_record_offset * max_cipher_suite_data_len]u8 = undefined;
    var offset: usize = 0;

    const out_count = count orelse return -1;
    const out_suites = suites orelse return -1;
    if (out_count.* == 0) return -1;

    const nr_suites = out_count.*;
    out_count.* = 0;
    @memset(&cipher_suite_data, 0);

    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_app;
    req.msg.cmd = cmd_get_channel_cipher_suites;
    req.msg.data = &rqdata;
    req.msg.data_len = rqdata.len;

    rqdata[0] = channel;
    rqdata[1] = if (c.strcmp(payload_type, "ipmi") != 0) 1 else 0;

    while (true) {
        // Always ask for cipher suite format
        rqdata[2] = list_algorithms_by_cipher_suite | list_index;
        const rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.err, "Unable to Get Channel Cipher Suites");
            return -1;
        };
        if (rsp.ccode != 0 or
            rsp.data_len < 1 or
            rsp.data_len > 1 + max_cipher_suite_data_len)
        {
            c.lprintf(
                log.Level.err,
                "Get Channel Cipher Suites failed: %s",
                ccString(rsp.ccode),
            );
            return -1;
        }
        // We got back cipher suite data -- store it.
        const chunk: usize = @intCast(rsp.data_len - 1);
        @memcpy(cipher_suite_data[offset..][0..chunk], rsp.data[1..][0..chunk]);
        offset += chunk;

        // Increment our list for the next call
        list_index += 1;

        if (!(rsp.data_len == 1 + max_cipher_suite_data_len and
            list_index < max_cipher_suite_record_offset)) break;
    }

    out_count.* = parseChannelCipherSuiteData(
        cipher_suite_data[0..offset],
        out_suites[0..nr_suites],
    );
    return 0;
}

/// `ipmi_print_channel_cipher_suites()`.
fn printChannelCipherSuites(
    intf: *Intf,
    payload_type: [*:0]const u8,
    channel: u8,
) c_int {
    var suites: [max_cipher_suite_count]CipherSuiteInfo = undefined;
    // Upstream passes `sizeof(*suites)` where `ARRAY_SIZE(suites)` was meant,
    // capping the parse at twelve records.  Reproduced; see issue #37.
    var nr_suites: usize = @sizeOf(CipherSuiteInfo);
    const header_str = "ID   IANA    Auth Alg        Integrity Alg   Confidentiality Alg";

    const rc = getChannelCipherSuites(intf, payload_type, channel, &suites, &nr_suites);
    if (rc < 0) return rc;

    if (c.csv_output == 0) {
        _ = c.printf("%s\n", @as([*:0]const u8, header_str));
    }
    for (suites[0..nr_suites]) |suite| {
        // We have everything we need to spit out a cipher suite record
        _ = c.printf(
            if (c.csv_output != 0)
                @as([*:0]const u8, "%d,%s,%s,%s,%s\n")
            else
                @as([*:0]const u8, "%-4d %-7s %-15s %-15s %-15s\n"),
            @as(c_int, @intCast(@intFromEnum(suite.cipher_suite_id))),
            ianaString(suite.iana),
            c.val2str(suite.auth_alg, c.ipmi_auth_algorithms),
            c.val2str(suite.integrity_alg, c.ipmi_integrity_algorithms),
            c.val2str(suite.crypt_alg, c.ipmi_encryption_algorithms),
        );
    }
    return 0;
}

// ---------------------------------------------------------------------------
// channel info
// ---------------------------------------------------------------------------

fn printAccessMode(access_mode: u8) void {
    switch (access_mode) {
        0 => _ = c.printf("disabled\n"),
        1 => _ = c.printf("pre-boot only\n"),
        2 => _ = c.printf("always available\n"),
        3 => _ = c.printf("shared\n"),
        else => _ = c.printf("unknown\n"),
    }
}

fn printAccessBlock(ca: ChannelAccess) void {
    _ = c.printf("    Alerting            : %sabled\n", disEn(ca.alerting != 0));
    _ = c.printf("    Per-message Auth    : %sabled\n", disEn(ca.per_message_auth != 0));
    _ = c.printf("    User Level Auth     : %sabled\n", disEn(ca.user_level_auth != 0));
    _ = c.printf("    Access Mode         : ");
    printAccessMode(ca.access_mode);
}

fn disEn(set: bool) [*:0]const u8 {
    return if (set) "dis" else "en";
}

/// `ipmi_get_channel_info()`.  Returns 0 on success and -1 on failure.
fn getChannelInfo(intf: *Intf, channel: u8) callconv(.c) c_int {
    var channel_info = std.mem.zeroes(ChannelInfo);
    var channel_access = std.mem.zeroes(ChannelAccess);

    channel_info.channel = channel;
    var ccode = getChannelInfoRaw(intf, &channel_info);
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(log.Level.err, "Unable to Get Channel Info");
        return -1;
    }

    _ = c.printf("Channel 0x%x info:\n", @as(c_uint, channel_info.channel));
    _ = c.printf(
        "  Channel Medium Type   : %s\n",
        c.val2str(channel_info.medium, c.ipmi_channel_medium_vals),
    );
    _ = c.printf(
        "  Channel Protocol Type : %s\n",
        c.val2str(channel_info.protocol, c.ipmi_channel_protocol_vals),
    );
    _ = c.printf("  Session Support       : ");
    switch (channel_info.session_support) {
        c.IPMI_CHANNEL_SESSION_LESS => _ = c.printf("session-less\n"),
        c.IPMI_CHANNEL_SESSION_SINGLE => _ = c.printf("single-session\n"),
        c.IPMI_CHANNEL_SESSION_MULTI => _ = c.printf("multi-session\n"),
        c.IPMI_CHANNEL_SESSION_BASED => _ = c.printf("session-based\n"),
        else => _ = c.printf("unknown\n"),
    }
    _ = c.printf("  Active Session Count  : %d\n", @as(c_int, channel_info.active_sessions));
    _ = c.printf(
        "  Protocol Vendor ID    : %d\n",
        @as(c_int, channel_info.vendor_id[0]) |
            @as(c_int, channel_info.vendor_id[1]) << 8 |
            @as(c_int, channel_info.vendor_id[2]) << 16,
    );

    // only proceed if this is LAN channel
    if (channel_info.medium != c.IPMI_CHANNEL_MEDIUM_LAN and
        channel_info.medium != c.IPMI_CHANNEL_MEDIUM_LAN_OTHER)
    {
        return 0;
    }

    channel_access.channel = channel_info.channel;
    ccode = getChannelAccess(intf, &channel_access, 1);
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(log.Level.err, "Unable to Get Channel Access (volatile)");
        return -1;
    }

    _ = c.printf("  Volatile(active) Settings\n");
    printAccessBlock(channel_access);

    channel_access = std.mem.zeroes(ChannelAccess);
    channel_access.channel = channel_info.channel;
    // get non-volatile settings
    ccode = getChannelAccess(intf, &channel_access, 0);
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(log.Level.err, "Unable to Get Channel Access (non-volatile)");
        return -1;
    }

    _ = c.printf("  Non-Volatile Settings\n");
    printAccessBlock(channel_access);
    return 0;
}

/// `ipmi_get_channel_medium()`.
///
/// Returns `IPMI_CHANNEL_MEDIUM_RESERVED` when the completion code was not OK.
fn getChannelMedium(intf: *Intf, channel: u8) callconv(.c) u8 {
    var channel_info = std.mem.zeroes(ChannelInfo);

    channel_info.channel = channel;
    const ccode = getChannelInfoRaw(intf, &channel_info);
    if (ccode != 0) {
        if (ccode != c.IPMI_CC_INV_DATA_FIELD_IN_REQ) {
            if (ccode > 0) {
                c.lprintf(
                    log.Level.err,
                    "Get Channel Info command failed: %s",
                    ccString(@truncate(@as(c_uint, @bitCast(ccode)))),
                );
            } else {
                _ = c.eval_ccode(ccode);
            }
        }
        return @intCast(c.IPMI_CHANNEL_MEDIUM_RESERVED);
    }
    c.lprintf(
        log.Level.debug,
        "Channel type: %s",
        c.val2str(channel_info.medium, c.ipmi_channel_medium_vals),
    );
    return channel_info.medium;
}

// ---------------------------------------------------------------------------
// channel getaccess / setaccess
// ---------------------------------------------------------------------------

/// `ipmi_get_user_access()`.  A `user_id` of 0 lists every user.
fn printUserAccess(intf: *Intf, channel: u8, user_id: u8) c_int {
    var user_access: UserAccess = undefined;
    var user_name: UserName = undefined;
    var init = true;
    var max_uid: c_int = 0;

    var curr_uid: c_int = if (user_id != 0) user_id else 1;
    while (true) {
        user_access = std.mem.zeroes(UserAccess);
        user_access.channel = channel;
        user_access.user_id = @truncate(@as(c_uint, @bitCast(curr_uid)));
        var ccode = c._ipmi_get_user_access(cIntf(intf), &user_access);
        if (c.eval_ccode(ccode) != 0) {
            c.lprintf(
                log.Level.err,
                "Unable to Get User Access (channel %d id %d)",
                @as(c_int, channel),
                curr_uid,
            );
            return -1;
        }

        user_name = std.mem.zeroes(UserName);
        user_name.user_id = @truncate(@as(c_uint, @bitCast(curr_uid)));
        ccode = c._ipmi_get_user_name(cIntf(intf), &user_name);
        if (ccode == 0xcc) {
            user_name.user_id = @truncate(@as(c_uint, @bitCast(curr_uid)));
            @memset(user_name.user_name[0..17], 0);
        } else if (c.eval_ccode(ccode) != 0) {
            c.lprintf(log.Level.err, "Unable to Get User Name (id %d)", curr_uid);
            return -1;
        }
        if (init) {
            _ = c.printf("Maximum User IDs     : %d\n", @as(c_int, user_access.max_user_ids));
            _ = c.printf("Enabled User IDs     : %d\n", @as(c_int, user_access.enabled_user_ids));
            max_uid = user_access.max_user_ids;
            init = false;
        }

        _ = c.printf("\n");
        _ = c.printf("User ID              : %d\n", curr_uid);
        _ = c.printf("User Name            : %s\n", &user_name.user_name);
        _ = c.printf(
            "Fixed Name           : %s\n",
            yesNoStr(curr_uid <= user_access.fixed_user_ids),
        );
        _ = c.printf(
            "Access Available     : %s\n",
            @as([*:0]const u8, if (user_access.callin_callback != 0)
                "callback"
            else
                "call-in / callback"),
        );
        _ = c.printf(
            "Link Authentication  : %sabled\n",
            enDis(user_access.link_auth != 0),
        );
        _ = c.printf(
            "IPMI Messaging       : %sabled\n",
            enDis(user_access.ipmi_messaging != 0),
        );
        _ = c.printf(
            "Privilege Level      : %s\n",
            c.val2str(user_access.privilege_limit, c.ipmi_privlvl_vals),
        );
        _ = c.printf(
            "Enable Status        : %s\n",
            c.val2str(user_access.enable_status, c.ipmi_user_enable_status_vals),
        );
        curr_uid += 1;

        if (!(user_id == 0 and curr_uid <= max_uid)) break;
    }

    return 0;
}

fn yesNoStr(set: bool) [*:0]const u8 {
    return if (set) "Yes" else "No";
}

fn enDis(set: bool) [*:0]const u8 {
    return if (set) "en" else "dis";
}

const OptionType = enum { integer, boolean, boolean_inverse };

const Option = struct {
    option: []const u8,
    type: OptionType,
    /// Index into the `field_ptrs` array built at run time, because Zig cannot
    /// take a pointer to a field of a not-yet-declared local in a const table.
    field: Field,
    min: u8,
    max: u8,
};

const Field = enum { callin_callback, link_auth, ipmi_messaging, privilege_limit };

const set_access_options = [_]Option{
    .{ .option = "callin=", .type = .boolean_inverse, .field = .callin_callback, .min = 0, .max = 0 },
    .{ .option = "link=", .type = .boolean, .field = .link_auth, .min = 0, .max = 0 },
    .{ .option = "ipmi=", .type = .boolean, .field = .ipmi_messaging, .min = 0, .max = 0 },
    .{
        .option = "privilege=",
        .type = .integer,
        .field = .privilege_limit,
        .min = @intCast(c.IPMI_SESSION_PRIV_CALLBACK),
        .max = @intCast(c.IPMI_SESSION_PRIV_NOACCESS),
    },
};

fn optionField(ua: *UserAccess, field: Field) *u8 {
    return switch (field) {
        .callin_callback => &ua.callin_callback,
        .link_auth => &ua.link_auth,
        .ipmi_messaging => &ua.ipmi_messaging,
        .privilege_limit => &ua.privilege_limit,
    };
}

/// `ipmi_set_user_access()`.
fn setUserAccess(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var user_access = std.mem.zeroes(UserAccess);
    var channel: u8 = 0;
    var user_id: u8 = 0;

    if (argc > 0 and eql(argv[0], "help")) {
        channelUsage();
        return 0;
    } else if (argc < 3) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        channelUsage();
        return -1;
    }
    if (c.is_ipmi_channel_num(argv[0], &channel) != 0 or
        c.is_ipmi_user_id(argv[1], &user_id) != 0)
    {
        return -1;
    }
    user_access.channel = channel;
    user_access.user_id = user_id;
    var ccode = c._ipmi_get_user_access(cIntf(intf), &user_access);
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(
            log.Level.err,
            "Unable to Get User Access (channel %d id %d)",
            @as(c_int, channel),
            @as(c_int, user_id),
        );
        return -1;
    }

    var i: usize = 2;
    while (i < argc) : (i += 1) {
        var j: usize = 0;
        while (j < set_access_options.len) : (j += 1) {
            const entry = set_access_options[j];
            const opt = std.mem.span(argv[i]);
            if (opt.len < entry.option.len) continue;
            if (!std.mem.eql(u8, opt[0..entry.option.len], entry.option)) continue;

            const optval = argv[i] + entry.option.len;
            const optval_slice = opt[entry.option.len..];
            const field = optionField(&user_access, entry.field);

            if (entry.type != .integer) {
                var boolval: bool = entry.type != .boolean_inverse;
                if (std.mem.eql(u8, optval_slice, "off") or
                    std.mem.eql(u8, optval_slice, "disable") or
                    std.mem.eql(u8, optval_slice, "no"))
                {
                    boolval = !boolval;
                }
                field.* = @intFromBool(boolval);
            } else blk: {
                const val = c.str2val(optval, c.ipmi_privlvl_vals);
                if (val != std.math.maxInt(u8)) {
                    field.* = @truncate(val);
                    break :blk;
                }
                if (c.str2uchar(optval, field) != 0) {
                    c.lprintf(
                        log.Level.err,
                        "Numeric [%hhu-%hhu] value expected, but '%s' given.",
                        @as(c_uint, entry.min),
                        @as(c_uint, entry.max),
                        optval,
                    );
                    return -1;
                }
            }
            c.lprintf(
                log.Level.debug,
                "Option %s=%hhu",
                @as([*:0]const u8, @ptrCast(entry.option.ptr)),
                @as(c_uint, field.*),
            );
            break;
        }
        if (j == set_access_options.len) {
            c.lprintf(log.Level.err, "Invalid option: %s\n", argv[i]);
            return -1;
        }
    }
    ccode = c._ipmi_set_user_access(cIntf(intf), &user_access, 0);
    if (c.eval_ccode(ccode) != 0) {
        c.lprintf(
            log.Level.err,
            "Unable to Set User Access (channel %d id %d)",
            @as(c_int, channel),
            @as(c_int, user_id),
        );
        return -1;
    }
    _ = c.printf(
        "Set User Access (channel %d id %d) successful.\n",
        @as(c_int, channel),
        @as(c_int, user_id),
    );
    return 0;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// `ipmi_channel_main()`.
fn channelMain(intf: *Intf, argc: c_int, argv: [*]const [*:0]u8) callconv(.c) c_int {
    var retval: c_int = 0;
    var channel: u8 = undefined;
    var priv: u8 = 0;

    if (argc < 1) {
        c.lprintf(log.Level.err, "Not enough parameters given.");
        channelUsage();
        return -1;
    } else if (eql(argv[0], "help")) {
        channelUsage();
        return 0;
    } else if (eql(argv[0], "authcap")) {
        if (argc != 3) {
            channelUsage();
            return -1;
        }
        if (c.is_ipmi_channel_num(argv[1], &channel) != 0 or
            c.is_ipmi_user_priv_limit(argv[2], &priv) != 0)
        {
            return -1;
        }
        retval = getChannelAuthCap(intf, channel, priv);
    } else if (eql(argv[0], "getaccess")) {
        var user_id: u8 = 0;
        if (argc < 2 or argc > 3) {
            c.lprintf(log.Level.err, "Not enough parameters given.");
            channelUsage();
            return -1;
        }
        if (c.is_ipmi_channel_num(argv[1], &channel) != 0) {
            return -1;
        }
        if (argc == 3) {
            if (c.is_ipmi_user_id(argv[2], &user_id) != 0) {
                return -1;
            }
        }
        retval = printUserAccess(intf, channel, user_id);
    } else if (eql(argv[0], "setaccess")) {
        return setUserAccess(intf, argc - 1, argv + 1);
    } else if (eql(argv[0], "info")) {
        channel = 0xe;
        if (argc > 2) {
            channelUsage();
            return -1;
        }
        if (argc == 2) {
            if (c.is_ipmi_channel_num(argv[1], &channel) != 0) {
                return -1;
            }
        }
        retval = getChannelInfo(intf, channel);
    } else if (eql(argv[0], "getciphers")) {
        // channel getciphers <ipmi|sol> [channel]
        channel = 0xe;
        if (argc < 2 or argc > 3 or
            (!eql(argv[1], "ipmi") and !eql(argv[1], "sol")))
        {
            channelUsage();
            return -1;
        }
        if (argc == 3) {
            if (c.is_ipmi_channel_num(argv[2], &channel) != 0) {
                return -1;
            }
        }
        retval = printChannelCipherSuites(intf, argv[1], channel);
    } else {
        c.lprintf(log.Level.err, "Invalid CHANNEL command: %s\n", argv[0]);
        channelUsage();
        retval = -1;
    }
    return retval;
}

/// `printf_channel_usage()`.
fn channelUsage() callconv(.c) void {
    c.lprintf(log.Level.notice, "Channel Commands: authcap   <channel number> <max privilege>");
    c.lprintf(log.Level.notice, "                  getaccess <channel number> [user id]");
    c.lprintf(log.Level.notice, "                  setaccess <channel number> " ++
        "<user id> [callin=on|off] [ipmi=on|off] [link=on|off] [privilege=level]");
    c.lprintf(log.Level.notice, "                  info      [channel number]");
    c.lprintf(log.Level.notice, "                  getciphers <ipmi | sol> [channel]");
    c.lprintf(log.Level.notice, "");
    c.lprintf(log.Level.notice, "Possible privilege levels are:");
    c.lprintf(log.Level.notice, "   1   Callback level");
    c.lprintf(log.Level.notice, "   2   User level");
    c.lprintf(log.Level.notice, "   3   Operator level");
    c.lprintf(log.Level.notice, "   4   Administrator level");
    c.lprintf(log.Level.notice, "   5   OEM Proprietary level");
    c.lprintf(log.Level.notice, "  15   No access");
}

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertOpaqueLayout(AuthCapRsp, .{
        .size = c.ABI_SIZEOF_get_channel_auth_cap_rsp,
        .alignment = c.ABI_ALIGNOF_get_channel_auth_cap_rsp,
        .fields = &.{
            .{
                .name = "channel_number",
                .offset = c.ABI_OFFSETOF_get_channel_auth_cap_rsp__channel_number,
            },
            .{ .name = "oem_id", .offset = c.ABI_OFFSETOF_get_channel_auth_cap_rsp__oem_id },
            .{
                .name = "oem_aux_data",
                .offset = c.ABI_OFFSETOF_get_channel_auth_cap_rsp__oem_aux_data,
            },
        },
    });

    // The cipher suite records are read byte by byte, so only their sizes and
    // the two interior offsets the parser depends on are asserted.
    if (std_record_size != 5) @compileError("std_cipher_suite_record_t is not 5 bytes");
    if (oem_record_size != 8) @compileError("oem_cipher_suite_record_t is not 8 bytes");
    if (c.ABI_OFFSETOF_oem_cipher_suite_record__iana != 2)
        @compileError("oem_cipher_suite_record_t.iana moved");
    if (c.ABI_OFFSETOF_oem_cipher_suite_record__auth_alg != 5)
        @compileError("oem_cipher_suite_record_t.auth_alg moved");
    if (max_cipher_suite_count != 204) @compileError("MAX_CIPHER_SUITE_COUNT changed");
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(getChannelAccess), @TypeOf(c._ipmi_get_channel_access));
    abi.assertCallSignature(@TypeOf(getChannelInfoRaw), @TypeOf(c._ipmi_get_channel_info));
    abi.assertCallSignature(@TypeOf(setChannelAccess), @TypeOf(c._ipmi_set_channel_access));
    abi.assertCallSignature(@TypeOf(currentChannelInfo), @TypeOf(c.ipmi_current_channel_info));
    abi.assertCallSignature(@TypeOf(getChannelCipherSuites), @TypeOf(c.ipmi_get_channel_cipher_suites));
    abi.assertCallSignature(@TypeOf(getChannelMedium), @TypeOf(c.ipmi_get_channel_medium));
    abi.assertCallSignature(@TypeOf(getChannelAuthCap), @TypeOf(c.ipmi_get_channel_auth_cap));
    abi.assertCallSignature(@TypeOf(getChannelInfo), @TypeOf(c.ipmi_get_channel_info));
    // `ipmi_set_user_access()` and `printf_channel_usage()` have no prototype
    // in any header - they are bare globals defined in `lib/ipmi_channel.c`
    // (and `ipmi_set_user_access` is shadowed by an unrelated `static` of the
    // same name in `lib/ipmi_lanp.c`), so there is nothing for
    // `assertCallSignature` to compare them against.
    abi.assertCallSignature(@TypeOf(channelMain), @TypeOf(c.ipmi_channel_main));

    @export(&getChannelAccess, .{ .name = "_ipmi_get_channel_access", .linkage = .strong });
    @export(&getChannelInfoRaw, .{ .name = "_ipmi_get_channel_info", .linkage = .strong });
    @export(&setChannelAccess, .{ .name = "_ipmi_set_channel_access", .linkage = .strong });
    @export(&currentChannelInfo, .{ .name = "ipmi_current_channel_info", .linkage = .strong });
    @export(&getChannelAuthCap, .{ .name = "ipmi_get_channel_auth_cap", .linkage = .strong });
    @export(&getChannelCipherSuites, .{ .name = "ipmi_get_channel_cipher_suites", .linkage = .strong });
    @export(&getChannelInfo, .{ .name = "ipmi_get_channel_info", .linkage = .strong });
    @export(&getChannelMedium, .{ .name = "ipmi_get_channel_medium", .linkage = .strong });
    @export(&setUserAccess, .{ .name = "ipmi_set_user_access", .linkage = .strong });
    @export(&channelMain, .{ .name = "ipmi_channel_main", .linkage = .strong });
    @export(&channelUsage, .{ .name = "printf_channel_usage", .linkage = .strong });
}
