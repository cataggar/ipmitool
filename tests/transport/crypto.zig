//! BMC-side crypto for the RMCP+ model BMC.
//!
//! This is deliberately an *independent* implementation of the RAKP key
//! schedule, written from the IPMI v2.0 spec and from a reading of
//! `src/plugins/lanplus/lanplus_crypt.c`, built directly on `std.crypto`.
//!
//! It does **not** reuse `src/zig/crypto/`.  The whole point of the fixture
//! harness is to be an oracle for the transport, and an oracle that shares code
//! with the thing it checks proves nothing.  A future Zig `lanplus` port is
//! checked against these bytes; if the port and this file ever agree because
//! they are the same code, the check has silently become a tautology.
//!
//! Only what a model BMC needs is here: HMAC over the three algorithms IPMI
//! negotiates, AES-128-CBC, and the RAKP/SIK/K1/K2 derivations.

const std = @import("std");

/// Authentication and integrity algorithm identifiers, as they appear on the
/// wire in the RMCP+ Open Session Request/Response.
pub const Algorithm = enum {
    sha1,
    md5,
    sha256,

    /// `IPMI_AUTH_RAKP_*` from `src/plugins/lanplus/lanplus.h`.
    pub fn fromAuthId(id: u8) ?Algorithm {
        return switch (id) {
            0x01 => .sha1,
            0x02 => .md5,
            0x03 => .sha256,
            else => null,
        };
    }

    /// `IPMI_INTEGRITY_*` from `src/plugins/lanplus/lanplus.h`.
    pub fn fromIntegrityId(id: u8) ?Algorithm {
        return switch (id) {
            0x01 => .sha1,
            0x02 => .md5,
            0x04 => .sha256,
            else => null,
        };
    }

    pub fn digestLength(a: Algorithm) usize {
        return switch (a) {
            .sha1 => 20,
            .md5 => 16,
            .sha256 => 32,
        };
    }

    /// How many bytes of the digest travel in a packet's AuthCode field.
    ///
    /// `IPMI_SHA1_AUTHCODE_SIZE` (12), `IPMI_HMAC_MD5_AUTHCODE_SIZE` (16) and
    /// `IPMI_HMAC_SHA256_AUTHCODE_SIZE` (16) in `lanplus.h`.
    pub fn authcodeLength(a: Algorithm) usize {
        return switch (a) {
            .sha1 => 12,
            .md5 => 16,
            .sha256 => 16,
        };
    }
};

/// HMAC of `data` under `key`, written to the first `digestLength` bytes of
/// `out`.
pub fn hmac(alg: Algorithm, key: []const u8, data: []const u8, out: []u8) []u8 {
    switch (alg) {
        .sha1 => {
            const H = std.crypto.auth.hmac.HmacSha1;
            var mac: [H.mac_length]u8 = undefined;
            H.create(&mac, data, key);
            @memcpy(out[0..mac.len], &mac);
            return out[0..mac.len];
        },
        .md5 => {
            const H = std.crypto.auth.hmac.Hmac(std.crypto.hash.Md5);
            var mac: [H.mac_length]u8 = undefined;
            H.create(&mac, data, key);
            @memcpy(out[0..mac.len], &mac);
            return out[0..mac.len];
        },
        .sha256 => {
            const H = std.crypto.auth.hmac.sha2.HmacSha256;
            var mac: [H.mac_length]u8 = undefined;
            H.create(&mac, data, key);
            @memcpy(out[0..mac.len], &mac);
            return out[0..mac.len];
        },
    }
}

// ---------------------------------------------------------------------------
// AES-128-CBC
// ---------------------------------------------------------------------------

pub const aes_block = 16;

/// Encrypt `input` (a whole number of blocks) into `output` under `key`/`iv`.
pub fn aesCbcEncrypt(key: *const [16]u8, iv: *const [16]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % aes_block == 0);
    std.debug.assert(output.len >= input.len);
    const ctx = std.crypto.core.aes.Aes128.initEnc(key.*);
    var chain: [aes_block]u8 = iv.*;
    var i: usize = 0;
    while (i < input.len) : (i += aes_block) {
        var block: [aes_block]u8 = undefined;
        for (&block, input[i..][0..aes_block], &chain) |*b, p, c| b.* = p ^ c;
        ctx.encrypt(&chain, &block);
        @memcpy(output[i..][0..aes_block], &chain);
    }
}

/// Decrypt `input` (a whole number of blocks) into `output` under `key`/`iv`.
pub fn aesCbcDecrypt(key: *const [16]u8, iv: *const [16]u8, input: []const u8, output: []u8) void {
    std.debug.assert(input.len % aes_block == 0);
    std.debug.assert(output.len >= input.len);
    const ctx = std.crypto.core.aes.Aes128.initDec(key.*);
    var chain: [aes_block]u8 = iv.*;
    var i: usize = 0;
    while (i < input.len) : (i += aes_block) {
        var carry: [aes_block]u8 = undefined;
        @memcpy(&carry, input[i..][0..aes_block]);
        var block: [aes_block]u8 = undefined;
        ctx.decrypt(&block, &carry);
        for (output[i..][0..aes_block], &block, &chain) |*o, d, c| o.* = d ^ c;
        chain = carry;
    }
}

/// The confidentiality padding `lanplus_encrypt_payload` applies: enough bytes
/// of the ascending sequence 1, 2, 3, ... to make `len + 1` a multiple of 16,
/// followed by the pad length itself.
pub fn confidentialityPadLength(payload_len: usize) usize {
    const mod = (payload_len + 1) % aes_block;
    return if (mod == 0) 0 else aes_block - mod;
}

// ---------------------------------------------------------------------------
// RAKP
// ---------------------------------------------------------------------------

/// Everything both sides of a RAKP exchange need.
///
/// Field names follow the spec (SIDm, SIDc, Rm, Rc, GUIDc, ROLEm, UNAMEm) via
/// the names `lanplus_crypt.c` gives them.
pub const Rakp = struct {
    console_id: u32,
    bmc_id: u32,
    console_rand: [16]u8,
    bmc_rand: [16]u8,
    bmc_guid: [16]u8,
    role: u8,
    username: []const u8,
    /// Kuid: the password, zero padded to `IPMI_AUTHCODE_BUFFER_SIZE`.
    password_key: [20]u8,
    /// Kg, when the BMC is configured with one.  `null` selects Kuid, which is
    /// what `lanplus_generate_sik` does when `ssn_params.kg[0]` is zero.
    kg: ?[20]u8,

    /// SIDm | SIDc | Rm | Rc | GUIDc | ROLEm | ULENGTHm | UNAMEm.
    pub fn rakp2Input(r: Rakp, out: []u8) []u8 {
        const n = 58 + r.username.len;
        std.mem.writeInt(u32, out[0..4], r.console_id, .little);
        std.mem.writeInt(u32, out[4..8], r.bmc_id, .little);
        @memcpy(out[8..24], &r.console_rand);
        @memcpy(out[24..40], &r.bmc_rand);
        @memcpy(out[40..56], &r.bmc_guid);
        out[56] = r.role;
        out[57] = @intCast(r.username.len);
        @memcpy(out[58..n], r.username);
        return out[0..n];
    }

    /// Rc | SIDm | ROLEm | ULENGTHm | UNAMEm.
    pub fn rakp3Input(r: Rakp, out: []u8) []u8 {
        const n = 22 + r.username.len;
        @memcpy(out[0..16], &r.bmc_rand);
        std.mem.writeInt(u32, out[16..20], r.console_id, .little);
        out[20] = r.role;
        out[21] = @intCast(r.username.len);
        @memcpy(out[22..n], r.username);
        return out[0..n];
    }

    /// Rm | SIDc | GUIDc.
    pub fn rakp4Input(r: Rakp, out: []u8) []u8 {
        @memcpy(out[0..16], &r.console_rand);
        std.mem.writeInt(u32, out[16..20], r.bmc_id, .little);
        @memcpy(out[20..36], &r.bmc_guid);
        return out[0..36];
    }

    /// Rm | Rc | ROLEm | ULENGTHm | UNAMEm.
    pub fn sikInput(r: Rakp, out: []u8) []u8 {
        const n = 34 + r.username.len;
        @memcpy(out[0..16], &r.console_rand);
        @memcpy(out[16..32], &r.bmc_rand);
        out[32] = r.role;
        out[33] = @intCast(r.username.len);
        @memcpy(out[34..n], r.username);
        return out[0..n];
    }
};

/// The derived key material of an active RMCP+ session.
pub const Keys = struct {
    sik: [32]u8 = @splat(0),
    sik_len: usize = 0,
    k1: [32]u8 = @splat(0),
    k1_len: usize = 0,
    k2: [32]u8 = @splat(0),
    k2_len: usize = 0,

    const const_1: [20]u8 = @splat(0x01);
    const const_2: [20]u8 = @splat(0x02);

    pub fn derive(auth: Algorithm, r: Rakp) Keys {
        var keys: Keys = .{};
        var buffer: [256]u8 = undefined;
        const input = r.sikInput(&buffer);
        const key: []const u8 = if (r.kg) |*kg| kg else &r.password_key;
        keys.sik_len = hmac(auth, key, input, &keys.sik).len;
        keys.k1_len = hmac(auth, keys.sik[0..keys.sik_len], &const_1, &keys.k1).len;
        keys.k2_len = hmac(auth, keys.sik[0..keys.sik_len], &const_2, &keys.k2).len;
        return keys;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "AES-128-CBC round trips and chains" {
    const key: [16]u8 = @splat(0x2b);
    const iv: [16]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    var plain: [48]u8 = undefined;
    for (&plain, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);

    var cipher: [48]u8 = undefined;
    aesCbcEncrypt(&key, &iv, &plain, &cipher);
    // Identical plaintext blocks must not produce identical ciphertext blocks.
    var uniform: [32]u8 = @splat(0xaa);
    var uniform_cipher: [32]u8 = undefined;
    aesCbcEncrypt(&key, &iv, &uniform, &uniform_cipher);
    try std.testing.expect(!std.mem.eql(u8, uniform_cipher[0..16], uniform_cipher[16..32]));

    var round: [48]u8 = undefined;
    aesCbcDecrypt(&key, &iv, &cipher, &round);
    try std.testing.expectEqualSlices(u8, &plain, &round);
}

test "confidentiality pad length makes the payload plus its length byte a whole block" {
    for (0..64) |len| {
        const pad = confidentialityPadLength(len);
        try std.testing.expectEqual(@as(usize, 0), (len + pad + 1) % aes_block);
        try std.testing.expect(pad < aes_block);
    }
}

test "RAKP buffer lengths follow the spec field list" {
    const r: Rakp = .{
        .console_id = 0xa0a2a3a4,
        .bmc_id = 0x02003344,
        .console_rand = @splat(1),
        .bmc_rand = @splat(2),
        .bmc_guid = @splat(3),
        .role = 0x14,
        .username = "admin",
        .password_key = @splat(0),
        .kg = null,
    };
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 63), r.rakp2Input(&buffer).len);
    try std.testing.expectEqual(@as(usize, 27), r.rakp3Input(&buffer).len);
    try std.testing.expectEqual(@as(usize, 36), r.rakp4Input(&buffer).len);
    try std.testing.expectEqual(@as(usize, 39), r.sikInput(&buffer).len);
}
