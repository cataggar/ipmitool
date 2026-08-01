//! Port of `src/plugins/lanplus/lanplus_dump.c`: the `-vv` packet dump for the
//! three RMCP+ session-setup responses.
//!
//! Everything here is `printf`, gated on `verbose < 2`.  The output is
//! reproduced byte for byte, including two upstream quirks worth naming so they
//! are not mistaken for typos introduced by the port:
//!
//!  * "Negotiated authenticatin algorithm" is misspelled upstream.
//!  * The label column is not consistent between the arms of the key-exchange
//!    switch: the `none` and `invalid` arms in `lanplus_dump_rakp2_message()`
//!    pad to one width, the `sha1`/`md5` arms to another, and `sha256` to a
//!    third.  `lanplus_dump_rakp4_message()` pads its `none` arm differently
//!    again.  All four widths are preserved exactly.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");

/// `DUMP_PREFIX_INCOMING`.
const in_prefix: [*:0]const u8 = "<<";

/// `HAVE_CRYPTO_SHA256`.
const have_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");

const sha1_authcode_size = 12;
const hmac_md5_authcode_size = 16;
const hmac_sha256_authcode_size = 16;
const sha_digest_length = 20;
const md5_digest_length = 16;
const sha256_digest_length = 32;

const rakp_status_no_errors = 0x00;

fn dumpOpenSessionResponse(rsp: *const ipmi.Response) callconv(.c) void {
    if (c.verbose < 2) return;

    const p = &rsp.payload.open_session_response;

    _ = c.printf("%sOPEN SESSION RESPONSE\n", in_prefix);

    _ = c.printf(
        "%s  Message tag                        : 0x%02x\n",
        in_prefix,
        @as(c_int, p.message_tag),
    );
    _ = c.printf(
        "%s  RMCP+ status                       : %s\n",
        in_prefix,
        c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes),
    );
    _ = c.printf(
        "%s  Maximum privilege level            : %s\n",
        in_prefix,
        c.val2str(p.max_priv_level, c.ipmi_priv_levels),
    );
    _ = c.printf(
        "%s  Console Session ID                 : 0x%08lx\n",
        in_prefix,
        @as(c_long, p.console_id),
    );

    // Only tag, status, privlvl and console id are returned on error.
    if (p.rakp_return_code != rakp_status_no_errors) return;

    _ = c.printf(
        "%s  BMC Session ID                     : 0x%08lx\n",
        in_prefix,
        @as(c_long, p.bmc_id),
    );
    _ = c.printf(
        "%s  Negotiated authenticatin algorithm : %s\n",
        in_prefix,
        c.val2str(p.auth_alg, c.ipmi_auth_algorithms),
    );
    _ = c.printf(
        "%s  Negotiated integrity algorithm     : %s\n",
        in_prefix,
        c.val2str(p.integrity_alg, c.ipmi_integrity_algorithms),
    );
    _ = c.printf(
        "%s  Negotiated encryption algorithm    : %s\n",
        in_prefix,
        c.val2str(p.crypt_alg, c.ipmi_encryption_algorithms),
    );
    _ = c.printf("\n");
}

fn dumpRakp2Message(rsp: *const ipmi.Response, auth_alg: u8) callconv(.c) void {
    if (c.verbose < 2) return;

    const p = &rsp.payload.rakp2_message;

    _ = c.printf("%sRAKP 2 MESSAGE\n", in_prefix);

    _ = c.printf(
        "%s  Message tag                   : 0x%02x\n",
        in_prefix,
        @as(c_int, p.message_tag),
    );

    _ = c.printf(
        "%s  RMCP+ status                  : %s\n",
        in_prefix,
        c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes),
    );

    _ = c.printf(
        "%s  Console Session ID            : 0x%08lx\n",
        in_prefix,
        @as(c_long, p.console_id),
    );

    _ = c.printf("%s  BMC random number             : 0x", in_prefix);
    for (0..16) |i| _ = c.printf("%02x", @as(c_int, p.bmc_rand[i]));
    _ = c.printf("\n");

    _ = c.printf("%s  BMC GUID                      : 0x", in_prefix);
    for (0..16) |i| _ = c.printf("%02x", @as(c_int, p.bmc_guid[i]));
    _ = c.printf("\n");

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => {
            _ = c.printf("%s  Key exchange auth code         : none\n", in_prefix);
        },
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            _ = c.printf("%s  Key exchange auth code [sha1] : 0x", in_prefix);
            for (0..sha_digest_length) |i| {
                _ = c.printf("%02x", @as(c_int, p.key_exchange_auth_code[i]));
            }
            _ = c.printf("\n");
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            _ = c.printf("%s  Key exchange auth code [md5]   : 0x", in_prefix);
            for (0..md5_digest_length) |i| {
                _ = c.printf("%02x", @as(c_int, p.key_exchange_auth_code[i]));
            }
            _ = c.printf("\n");
        },
        else => blk: {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                _ = c.printf("%s  Key exchange auth code [sha256]: 0x", in_prefix);
                for (0..sha256_digest_length) |i| {
                    _ = c.printf("%02x", @as(c_int, p.key_exchange_auth_code[i]));
                }
                _ = c.printf("\n");
                break :blk;
            }
            _ = c.printf("%s  Key exchange auth code         : invalid", in_prefix);
        },
    }
    _ = c.printf("\n");
}

fn dumpRakp4Message(rsp: *const ipmi.Response, auth_alg: u8) callconv(.c) void {
    if (c.verbose < 2) return;

    const p = &rsp.payload.rakp4_message;

    _ = c.printf("%sRAKP 4 MESSAGE\n", in_prefix);

    _ = c.printf(
        "%s  Message tag                   : 0x%02x\n",
        in_prefix,
        @as(c_int, p.message_tag),
    );

    _ = c.printf(
        "%s  RMCP+ status                  : %s\n",
        in_prefix,
        c.val2str(p.rakp_return_code, c.ipmi_rakp_return_codes),
    );

    _ = c.printf(
        "%s  Console Session ID            : 0x%08lx\n",
        in_prefix,
        @as(c_long, p.console_id),
    );

    switch (auth_alg) {
        c.IPMI_AUTH_RAKP_NONE => {
            _ = c.printf("%s  Key exchange auth code        : none\n", in_prefix);
        },
        c.IPMI_AUTH_RAKP_HMAC_SHA1 => {
            _ = c.printf("%s  Key exchange auth code [sha1] : 0x", in_prefix);
            for (0..sha1_authcode_size) |i| {
                _ = c.printf("%02x", @as(c_int, p.integrity_check_value[i]));
            }
            _ = c.printf("\n");
        },
        c.IPMI_AUTH_RAKP_HMAC_MD5 => {
            _ = c.printf("%s  Key exchange auth code [md5]   : 0x", in_prefix);
            for (0..hmac_md5_authcode_size) |i| {
                _ = c.printf("%02x", @as(c_int, p.integrity_check_value[i]));
            }
            _ = c.printf("\n");
        },
        else => blk: {
            if (have_sha256 and auth_alg == c.IPMI_AUTH_RAKP_HMAC_SHA256) {
                _ = c.printf("%s  Key exchange auth code [sha256]: 0x", in_prefix);
                for (0..hmac_sha256_authcode_size) |i| {
                    _ = c.printf("%02x", @as(c_int, p.integrity_check_value[i]));
                }
                _ = c.printf("\n");
                break :blk;
            }
            _ = c.printf("%s  Key exchange auth code         : invalid", in_prefix);
        },
    }
    _ = c.printf("\n");
}

comptime {
    // `val2str()` and the `valstr` tables live in C; `intf/test_stubs.zig`
    // supplies them for the test binary only.
    if (builtin.is_test) _ = @import("test_stubs.zig");
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(dumpOpenSessionResponse), @TypeOf(c.lanplus_dump_open_session_response));
    abi.assertCallSignature(@TypeOf(dumpRakp2Message), @TypeOf(c.lanplus_dump_rakp2_message));
    abi.assertCallSignature(@TypeOf(dumpRakp4Message), @TypeOf(c.lanplus_dump_rakp4_message));

    @export(&dumpOpenSessionResponse, .{ .name = "lanplus_dump_open_session_response" });
    @export(&dumpRakp2Message, .{ .name = "lanplus_dump_rakp2_message" });
    @export(&dumpRakp4Message, .{ .name = "lanplus_dump_rakp4_message" });
}

test {
    std.testing.refAllDecls(@This());
}
