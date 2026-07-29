//! The keyed-hash side of RMCP+: which digest an IPMI algorithm number selects,
//! how long its output is, and the HMAC itself.
//!
//! This is the `std.crypto` replacement for the `EVP_sha1()` / `EVP_md5()` /
//! `EVP_sha256()` dispatch and the `HMAC()` call in
//! `src/plugins/lanplus/lanplus_crypt_impl.c`.  It is kept free of any
//! dependency on the rest of ipmitool so it can be unit tested directly against
//! the vectors captured from OpenSSL.
//!
//! The algorithm numbers overlap between the two IPMI tables and the C relies
//! on that: `IPMI_AUTH_RAKP_HMAC_SHA256` (0x03) has the same value as
//! `IPMI_INTEGRITY_MD5_128`, and `lanplus_HMAC` maps it to SHA-256 regardless
//! of which table the caller meant.  `algorithmFor` reproduces that mapping
//! exactly rather than the specification's.

const std = @import("std");

const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Md5 = std.crypto.hash.Md5;

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacMd5 = std.crypto.auth.hmac.HmacMd5;

/// `IPMI_MAX_MD_SIZE`: the widest digest any of the algorithms produces.
pub const max_digest_length = 0x20;

/// The digests `lanplus_HMAC` knows how to select.
pub const Algorithm = enum {
    /// `IPMI_AUTH_RAKP_HMAC_SHA1` / `IPMI_INTEGRITY_HMAC_SHA1_96`.
    sha1,
    /// `IPMI_AUTH_RAKP_HMAC_MD5` / `IPMI_INTEGRITY_HMAC_MD5_128`.
    md5,
    /// `IPMI_AUTH_RAKP_HMAC_SHA256` / `IPMI_INTEGRITY_HMAC_SHA256_128`.
    sha256,

    /// `IPMI_SHA_DIGEST_LENGTH`, `IPMI_MD5_DIGEST_LENGTH`,
    /// `IPMI_SHA256_DIGEST_LENGTH`.
    pub fn digestLength(self: Algorithm) u32 {
        return switch (self) {
            .sha1 => Sha1.digest_length,
            .md5 => Md5.digest_length,
            .sha256 => Sha256.digest_length,
        };
    }

    /// How much of the digest actually travels as an integrity check value.
    ///
    /// This is the parity trap in the whole port: the algorithm names say so —
    /// HMAC-SHA1-**96** and HMAC-SHA256-**128** — but the digests are 160 and
    /// 256 bits, so comparing the full output against what a BMC sends would
    /// reject every session.  `IPMI_SHA1_AUTHCODE_SIZE`,
    /// `IPMI_HMAC_MD5_AUTHCODE_SIZE` and `IPMI_HMAC_SHA256_AUTHCODE_SIZE` from
    /// `src/plugins/lanplus/lanplus.h`.
    pub fn authcodeLength(self: Algorithm) u32 {
        return switch (self) {
            .sha1 => 12,
            .md5 => 16,
            .sha256 => 16,
        };
    }
};

/// The `if` ladder at the top of `lanplus_HMAC`, as a lookup.
///
/// Returns null for the values that fall through to its `assert(0)`.
pub fn algorithmFor(mac: u8) ?Algorithm {
    return switch (mac) {
        // IPMI_AUTH_RAKP_HMAC_SHA1, IPMI_INTEGRITY_HMAC_SHA1_96
        0x01 => .sha1,
        // IPMI_AUTH_RAKP_HMAC_MD5, IPMI_INTEGRITY_HMAC_MD5_128
        0x02 => .md5,
        // IPMI_AUTH_RAKP_HMAC_SHA256, IPMI_INTEGRITY_HMAC_SHA256_128
        0x03, 0x04 => .sha256,
        else => null,
    };
}

/// HMAC `data` under `key`, writing the digest to the front of `out`.
///
/// Returns the digest length, which is what the C hands back through `md_len`.
/// `out` has to be at least `max_digest_length` bytes, exactly like the
/// `uint8_t md[IPMI_MAX_MD_SIZE]` buffers every caller passes.
pub fn hmac(
    algorithm: Algorithm,
    key: []const u8,
    data: []const u8,
    out: *[max_digest_length]u8,
) u32 {
    switch (algorithm) {
        .sha1 => HmacSha1.create(out[0..HmacSha1.mac_length], data, key),
        .md5 => HmacMd5.create(out[0..HmacMd5.mac_length], data, key),
        .sha256 => HmacSha256.create(out[0..HmacSha256.mac_length], data, key),
    }
    return algorithm.digestLength();
}

test "algorithm numbers follow lanplus_HMAC, not the specification tables" {
    try std.testing.expectEqual(Algorithm.sha1, algorithmFor(0x01).?);
    try std.testing.expectEqual(Algorithm.md5, algorithmFor(0x02).?);
    // IPMI_INTEGRITY_MD5_128 shares 0x03 with IPMI_AUTH_RAKP_HMAC_SHA256; the
    // C picks SHA-256 for both.
    try std.testing.expectEqual(Algorithm.sha256, algorithmFor(0x03).?);
    try std.testing.expectEqual(Algorithm.sha256, algorithmFor(0x04).?);
    try std.testing.expectEqual(@as(?Algorithm, null), algorithmFor(0x00));
    try std.testing.expectEqual(@as(?Algorithm, null), algorithmFor(0x05));
    try std.testing.expectEqual(@as(?Algorithm, null), algorithmFor(0xff));
}

test "digest lengths match the lanplus.h constants" {
    try std.testing.expectEqual(@as(u32, 20), Algorithm.sha1.digestLength());
    try std.testing.expectEqual(@as(u32, 16), Algorithm.md5.digestLength());
    try std.testing.expectEqual(@as(u32, 32), Algorithm.sha256.digestLength());
}

test "integrity check values are truncated, not whole digests" {
    try std.testing.expectEqual(@as(u32, 12), Algorithm.sha1.authcodeLength());
    try std.testing.expectEqual(@as(u32, 16), Algorithm.md5.authcodeLength());
    try std.testing.expectEqual(@as(u32, 16), Algorithm.sha256.authcodeLength());

    inline for (.{ Algorithm.sha1, Algorithm.md5, Algorithm.sha256 }) |algorithm| {
        try std.testing.expect(algorithm.authcodeLength() <= algorithm.digestLength());
    }
}

test "RFC 2202 / RFC 4231 HMAC test case 2" {
    var out: [max_digest_length]u8 = undefined;

    try std.testing.expectEqual(@as(u32, 20), hmac(.sha1, "Jefe", "what do ya want for nothing?", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xef, 0xfc, 0xdf, 0x6a, 0xe5, 0xeb, 0x2f, 0xa2, 0xd2, 0x74,
        0x16, 0xd5, 0xf1, 0x84, 0xdf, 0x9c, 0x25, 0x9a, 0x7c, 0x79,
    }, out[0..20]);

    try std.testing.expectEqual(@as(u32, 16), hmac(.md5, "Jefe", "what do ya want for nothing?", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x75, 0x0c, 0x78, 0x3e, 0x6a, 0xb0, 0xb5, 0x03,
        0xea, 0xa8, 0x6e, 0x31, 0x0a, 0x5d, 0xb7, 0x38,
    }, out[0..16]);

    try std.testing.expectEqual(@as(u32, 32), hmac(.sha256, "Jefe", "what do ya want for nothing?", &out));
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
        0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
        0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
        0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
    }, out[0..32]);
}
