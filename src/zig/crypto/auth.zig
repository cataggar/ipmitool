//! Port of `src/plugins/lan/auth.c`: the IPMI v1.5 per-message authentication
//! codes carried in an RMCP session header.
//!
//! The C had two interchangeable implementations of the same hash selected by
//! `HAVE_CRYPTO_MD5` — libcrypto's `MD5_*` or the bundled `md5.c` — and this
//! port replaces both with `std.crypto.hash.Md5`, which is why `auth.c` drops
//! off the list of translation units that need libcrypto.
//!
//! ## MD2
//!
//! `ipmi_auth_md2` is compiled from its `#else` branch: OpenSSL 3 removed MD2,
//! so `HAVE_CRYPTO_MD2` is never defined and the baseline binary already
//! answers `-A MD2` with a warning and sixteen zero bytes.  This port
//! reproduces that byte for byte and deliberately does not implement MD2; see
//! doc/zig-migration/crypto.md.  The `comptime` guard below turns a build that
//! somehow does define `HAVE_CRYPTO_MD2` into a compile error rather than a
//! silent behaviour change.
//!
//! Selected with `zig build -Dzig-modules=auth`.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const Session = @import("../intf/intf.zig").Session;
const v15 = @import("v15_auth.zig");

comptime {
    if (@hasDecl(c, "HAVE_CRYPTO_MD2")) @compileError(
        "src/zig/crypto/auth.zig implements the !HAVE_CRYPTO_MD2 branch of " ++
            "auth.c only; see doc/zig-migration/crypto.md",
    );
}

/// The `static uint8_t md[16]` inside `ipmi_auth_md5`.  Each C function had its
/// own, and callers keep the returned pointer, so they stay separate here.
var md5_authcode: [16]u8 = @splat(0);

/// The `static uint8_t md[16]` inside `ipmi_auth_md2`.
var md2_authcode: [16]u8 = @splat(0);

/// The `static uint8_t md[16]` inside `ipmi_auth_special`.
var special_authcode: [16]u8 = @splat(0);

/// `ipmi_auth_md5` - multi-session authcode generation for MD5.
///
/// `H(password + session_id + msg + session_seq + password)`, where the
/// password is the first 16 bytes of the session authcode buffer.
pub fn authMd5(s: *Session, data: [*c]u8, data_len: c_int) callconv(.c) [*c]u8 {
    const message: []const u8 = if (data_len > 0) data[0..@intCast(data_len)] else &.{};
    md5_authcode = v15.md5(s.authcode[0..16], s.session_id, message, s.in_seq);

    if (c.verbose > 3) {
        _ = std.c.printf("  MD5 AuthCode    : %s\n", c.buf2str(&md5_authcode, 16));
    }
    return &md5_authcode;
}

/// `ipmi_auth_md2` - multi-session authcode generation for MD2.
///
/// MD2 is not available: it left OpenSSL in version 3 and ipmitool never had an
/// internal implementation, so this is the warning and the zero authcode the C
/// already produces.
pub fn authMd2(s: *Session, data: [*c]u8, data_len: c_int) callconv(.c) [*c]u8 {
    _ = s;
    _ = data;
    _ = data_len;

    md2_authcode = v15.md2_unsupported;
    _ = std.c.printf(
        "WARNING: No internal support for MD2!  " ++
            "Please re-compile with OpenSSL.\n",
    );
    return &md2_authcode;
}

/// `ipmi_auth_special` - the "special" (OEM) authentication method.
///
/// `H(H(password) XOR challenge)`, with the password taken as a C string rather
/// than as a fixed 16 byte field.
pub fn authSpecial(s: *Session) callconv(.c) [*c]u8 {
    special_authcode = v15.special(std.mem.sliceTo(&s.authcode, 0), &s.challenge);
    return &special_authcode;
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

comptime {
    abi.assertCallSignature(@TypeOf(authMd5), @TypeOf(c.ipmi_auth_md5));
    abi.assertCallSignature(@TypeOf(authMd2), @TypeOf(c.ipmi_auth_md2));
    abi.assertCallSignature(@TypeOf(authSpecial), @TypeOf(c.ipmi_auth_special));

    @export(&authMd5, .{ .name = "ipmi_auth_md5", .linkage = .strong });
    @export(&authMd2, .{ .name = "ipmi_auth_md2", .linkage = .strong });
    @export(&authSpecial, .{ .name = "ipmi_auth_special", .linkage = .strong });
}
