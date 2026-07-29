//! The IPMI v1.5 per-message authentication codes, without the C plumbing.
//!
//! `src/plugins/lan/auth.c` wraps these in functions that return a pointer to a
//! `static` buffer and print trace output; the hashing itself is here so it can
//! be checked against vectors captured from the OpenSSL-backed build without
//! linking any C.
//!
//! Section 22.17 of IPMI v1.5 defines the MD5 authcode as
//! `H(password | session id | message | session sequence number | password)`.

const std = @import("std");
const builtin = @import("builtin");

const Md5 = std.crypto.hash.Md5;

/// Length of every v1.5 authcode.
pub const authcode_length = Md5.digest_length;

/// The MD5 multi-session authcode.
///
/// Two details are inherited from the C rather than from the specification: the
/// password is always the first 16 bytes of the 20 byte authcode buffer, and
/// the session id is hashed in *host* byte order while the sequence number is
/// hashed little endian.  The asymmetry looks like an oversight in the original
/// but it is observable, so it is kept.
pub fn md5(
    password: *const [16]u8,
    session_id: u32,
    data: []const u8,
    in_seq: u32,
) [authcode_length]u8 {
    const id_bytes = std.mem.toBytes(session_id);
    const seq_bytes = std.mem.toBytes(std.mem.nativeToLittle(u32, in_seq));

    var digest = Md5.init(.{});
    digest.update(password);
    digest.update(&id_bytes);
    digest.update(data);
    digest.update(&seq_bytes);
    digest.update(password);

    var out: [authcode_length]u8 = undefined;
    digest.final(&out);
    return out;
}

/// The "OEM special" authcode: `H(H(password) XOR challenge)`.
///
/// Unlike `md5` this takes the password as a string, so a short password is not
/// padded out to 16 bytes before hashing.
pub fn special(password: []const u8, challenge: *const [16]u8) [authcode_length]u8 {
    var out: [authcode_length]u8 = undefined;
    Md5.hash(password, &out, .{});

    var masked: [16]u8 = undefined;
    for (&masked, challenge, &out) |*b, given, mask| b.* = given ^ mask;

    Md5.hash(&masked, &out, .{});
    return out;
}

/// The MD2 authcode, which ipmitool cannot produce.
///
/// MD2 left OpenSSL in version 3 and ipmitool never carried an internal
/// implementation, so `-A MD2` has already been answering with sixteen zero
/// bytes and a warning in every supported build.  See doc/zig-migration/crypto.md.
pub const md2_unsupported: [authcode_length]u8 = @splat(0);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the sequence number is hashed little endian on every host" {
    const password: [16]u8 = @splat('p');
    const swapped = md5(&password, 0, &.{}, 0x01020304);

    var digest = Md5.init(.{});
    digest.update(&password);
    digest.update(&[_]u8{ 0, 0, 0, 0 });
    digest.update(&[_]u8{ 0x04, 0x03, 0x02, 0x01 });
    digest.update(&password);
    var expected: [16]u8 = undefined;
    digest.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &swapped);
}

test "the session id keeps host byte order" {
    const password: [16]u8 = @splat('p');
    const out = md5(&password, 0x01020304, &.{}, 0);

    const id_bytes: [4]u8 = if (builtin.target.cpu.arch.endian() == .big)
        .{ 0x01, 0x02, 0x03, 0x04 }
    else
        .{ 0x04, 0x03, 0x02, 0x01 };

    var digest = Md5.init(.{});
    digest.update(&password);
    digest.update(&id_bytes);
    digest.update(&[_]u8{ 0, 0, 0, 0 });
    digest.update(&password);
    var expected: [16]u8 = undefined;
    digest.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "special hashes the password as a string" {
    const challenge: [16]u8 = @splat(0);

    var inner: [16]u8 = undefined;
    Md5.hash("secret", &inner, .{});
    var expected: [16]u8 = undefined;
    Md5.hash(&inner, &expected, .{});

    try std.testing.expectEqualSlices(u8, &expected, &special("secret", &challenge));
}
