//! AES-128 in CBC mode, the confidentiality algorithm RMCP+ uses
//! (`IPMI_CRYPT_AES_CBC_128`, table 13-19 of the IPMI v2 specification).
//!
//! `std.crypto` ships the AES block cipher but no CBC mode, because CBC is
//! unauthenticated and nothing new should use it.  IPMI v2.0 mandates it, so
//! the mode is spelled out here, deliberately as its own small module: it is
//! pure, it has no dependency on the rest of ipmitool, and it is covered by the
//! parity vectors captured from OpenSSL's `EVP_aes_128_cbc()`.
//!
//! Both directions support `output` and `input` being the same buffer, which
//! the RMCP+ send path relies on.

const std = @import("std");

const Aes128 = std.crypto.core.aes.Aes128;

/// `IPMI_CRYPT_AES_CBC_128_BLOCK_SIZE`.
pub const block_size = 16;

/// Encrypt `input` into `output`, chaining from `iv`.
///
/// `input.len` must be a non-zero multiple of `block_size` and `output` must be
/// at least that long; the callers assert this, matching the C.
pub fn encrypt(key: *const [16]u8, iv: *const [block_size]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % block_size == 0);
    std.debug.assert(output.len >= input.len);

    const ctx = Aes128.initEnc(key.*);
    var chain = iv.*;
    var offset: usize = 0;
    while (offset < input.len) : (offset += block_size) {
        var block: [block_size]u8 = undefined;
        for (&block, input[offset..][0..block_size], &chain) |*out, in, prev| {
            out.* = in ^ prev;
        }
        ctx.encrypt(&chain, &block);
        @memcpy(output[offset..][0..block_size], &chain);
    }
}

/// Decrypt `input` into `output`, chaining from `iv`.
///
/// The previous ciphertext block is copied out before `output` is written, so
/// decrypting in place works.
pub fn decrypt(key: *const [16]u8, iv: *const [block_size]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % block_size == 0);
    std.debug.assert(output.len >= input.len);

    const ctx = Aes128.initDec(key.*);
    var chain = iv.*;
    var offset: usize = 0;
    while (offset < input.len) : (offset += block_size) {
        const cipher: [block_size]u8 = input[offset..][0..block_size].*;
        var plain: [block_size]u8 = undefined;
        ctx.decrypt(&plain, &cipher);
        for (output[offset..][0..block_size], &plain, &chain) |*out, p, prev| {
            out.* = p ^ prev;
        }
        chain = cipher;
    }
}

test "NIST SP 800-38A F.2 AES-128-CBC" {
    const key = [_]u8{
        0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
        0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
    };
    const iv = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const plain = [_]u8{
        0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96,
        0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
        0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c,
        0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
        0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11,
        0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
        0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17,
        0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10,
    };
    const expected = [_]u8{
        0x76, 0x49, 0xab, 0xac, 0x81, 0x19, 0xb2, 0x46,
        0xce, 0xe9, 0x8e, 0x9b, 0x12, 0xe9, 0x19, 0x7d,
        0x50, 0x86, 0xcb, 0x9b, 0x50, 0x72, 0x19, 0xee,
        0x95, 0xdb, 0x11, 0x3a, 0x91, 0x76, 0x78, 0xb2,
        0x73, 0xbe, 0xd6, 0xb8, 0xe3, 0xc1, 0x74, 0x3b,
        0x71, 0x16, 0xe6, 0x9e, 0x22, 0x22, 0x95, 0x16,
        0x3f, 0xf1, 0xca, 0xa1, 0x68, 0x1f, 0xac, 0x09,
        0x12, 0x0e, 0xca, 0x30, 0x75, 0x86, 0xe1, 0xa7,
    };

    var cipher: [64]u8 = undefined;
    encrypt(&key, &iv, &plain, &cipher);
    try std.testing.expectEqualSlices(u8, &expected, &cipher);

    var back: [64]u8 = undefined;
    decrypt(&key, &iv, &cipher, &back);
    try std.testing.expectEqualSlices(u8, &plain, &back);
}

test "in place round trip" {
    var key: [16]u8 = undefined;
    var iv: [block_size]u8 = undefined;
    var buffer: [80]u8 = undefined;
    for (&key, 0..) |*b, i| b.* = @intCast(i);
    for (&iv, 0..) |*b, i| b.* = @intCast(0x40 + i);
    for (&buffer, 0..) |*b, i| b.* = @intCast(i);
    const original = buffer;

    encrypt(&key, &iv, &buffer, &buffer);
    try std.testing.expect(!std.mem.eql(u8, &original, &buffer));
    decrypt(&key, &iv, &buffer, &buffer);
    try std.testing.expectEqualSlices(u8, &original, &buffer);
}
