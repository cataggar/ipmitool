//! Port of `src/plugins/lanplus/lanplus_crypt.c`: the RMCP+ session layer that
//! sits between `lanplus.c` and the primitives in `lanplus_crypt_impl.zig`.
//!
//! Nothing here talks to a cipher directly.  It marshals session state into the
//! hash inputs the IPMI v2 specification defines (`src/zig/crypto/rakp.zig`),
//! applies the confidentiality padding (`src/zig/crypto/payload.zig`), and
//! keeps the truncation rules straight:
//!
//! | integrity algorithm | digest | authcode on the wire |
//! | ------------------- | ------ | -------------------- |
//! | HMAC-SHA1-96        | 20     | 12                   |
//! | HMAC-MD5-128        | 16     | 16                   |
//! | HMAC-SHA256-128     | 32     | 16                   |
//!
//! The comparisons against a BMC-supplied authcode use only the truncated
//! prefix, exactly as the C did — comparing the full digest would reject every
//! real session.
//!
//! Selected with `zig build -Dzig-modules=lanplus-crypt`.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const cassert = @import("../util/cassert.zig");
const intf_mod = @import("../intf/intf.zig");
const ipmi = @import("../core/ipmi.zig");
const log = @import("../util/log.zig");
const mac_mod = @import("mac.zig");
const payload_mod = @import("payload.zig");
const rakp = @import("rakp.zig");

const Intf = intf_mod.Intf;
const Session = intf_mod.Session;

const source = "src/plugins/lanplus/lanplus_crypt.c";

/// `IPMI_AUTHCODE_BUFFER_SIZE`: the fixed key length passed to every RAKP HMAC.
const authcode_buffer_size = intf_mod.authcode_buffer_size;

/// `IPMI_MAX_MD_SIZE`.
const max_md_size = ipmi.max_md_size;

/// `IPMI_CRYPT_AES_CBC_128_BLOCK_SIZE`.
const block_size = payload_mod.block_size;

/// Table 13-17 authentication algorithm numbers.
const auth_rakp_none = 0x00;
const auth_rakp_hmac_sha1 = 0x01;
const auth_rakp_hmac_md5 = 0x02;
const auth_rakp_hmac_sha256 = 0x03;

/// Table 13-18 integrity algorithm numbers.
const integrity_none = 0x00;
const integrity_hmac_sha1_96 = 0x01;
const integrity_hmac_md5_128 = 0x02;
const integrity_hmac_sha256_128 = 0x04;

/// Table 13-19 confidentiality algorithm numbers.
const crypt_none = 0x00;
const crypt_aes_cbc_128 = 0x01;

/// Truncated authcode lengths, from `src/plugins/lanplus/lanplus.h`.
const sha1_authcode_size = 12;
const hmac_md5_authcode_size = 16;
const hmac_sha256_authcode_size = 16;

/// The C allocated every scratch buffer with `malloc`, and reported a failure
/// to the caller rather than aborting.  Using libc's allocator keeps both the
/// footprint and that error path identical.
const allocator = std.heap.c_allocator;

fn mallocFailure() c_int {
    c.lprintf(log.Level.err, "ipmitool: malloc failure");
    return 1;
}

fn username(intf: *Intf) []const u8 {
    return std.mem.sliceTo(&intf.ssn_params.username, 0);
}

fn oemActive(intf: *Intf, name: [*:0]const u8) bool {
    return c.ipmi_oem_active(@ptrCast(intf), name) != 0;
}

/// The RAKP inputs common to the key derivations, read out of the session.
///
/// `i82571spt` clears bit 4 of the requested role: the HMAC implementation in
/// the Intel 82571 GbE leaves it out, so the console has to leave it out too or
/// the session never comes up.
fn inputsFor(session: *const Session, intf: *Intf, apply_role_quirk: bool) rakp.Inputs {
    var role = session.v2_data.requested_role;
    if (apply_role_quirk and oemActive(intf, "i82571spt")) role &= ~@as(u8, 0x10);
    return .{
        .console_id = session.v2_data.console_id,
        .bmc_id = session.v2_data.bmc_id,
        .console_rand = session.v2_data.console_rand,
        .bmc_rand = session.v2_data.bmc_rand,
        .bmc_guid = session.v2_data.bmc_guid,
        .role = role,
        .username = username(intf),
    };
}

/// The C guards the supported RAKP algorithms with an `assert`; `SHA256` only
/// appears in the list when `HAVE_CRYPTO_SHA256` is defined.
fn assertSupportedAuthAlg(auth_alg: u8, comptime site: cassert.Site) void {
    const supported = auth_alg == auth_rakp_hmac_sha1 or
        auth_alg == auth_rakp_hmac_md5 or
        (have_sha256 and auth_alg == auth_rakp_hmac_sha256);
    cassert.expect(supported, site);
}

const have_sha256 = @hasDecl(c, "HAVE_CRYPTO_SHA256");

const supported_auth_algs_expr = if (have_sha256)
    "(session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA1) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_MD5) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA256)"
else
    "(session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_SHA1) " ++
        "|| (session->v2_data.auth_alg == IPMI_AUTH_RAKP_HMAC_MD5)";

/// How much of a RAKP authentication code is compared against the BMC's.
///
/// The C reaches this through a switch that also asserts the digest length, so
/// an unknown algorithm aborts rather than falling through with an
/// uninitialised length.
fn rakpAuthcodeLength(auth_alg: u8, comptime site: cassert.Site) u32 {
    return switch (auth_alg) {
        auth_rakp_hmac_sha1 => sha1_authcode_size,
        auth_rakp_hmac_md5 => hmac_md5_authcode_size,
        auth_rakp_hmac_sha256 => if (have_sha256)
            hmac_sha256_authcode_size
        else
            cassert.unreachableBranch(site),
        else => cassert.unreachableBranch(site),
    };
}

/// The same, keyed by integrity algorithm: Intel BMCs answer RAKP 4 with one.
///
/// Note that `IPMI_INTEGRITY_MD5_128` (0x03) is deliberately absent — the C
/// asserts on it even though `lanplus_HMAC` would happily hash it as SHA-256.
fn integrityAuthcodeLength(integrity_alg: u8, comptime site: cassert.Site) u32 {
    return switch (integrity_alg) {
        integrity_hmac_sha1_96 => sha1_authcode_size,
        integrity_hmac_md5_128 => hmac_md5_authcode_size,
        else => cassert.unreachableBranch(site),
    };
}

/// The C follows every RAKP HMAC with a switch asserting the digest length it
/// just produced.  Nothing depends on the result; it only pins the algorithm.
fn assertRakpDigestLength(auth_alg: u8, mac_length: u32, comptime site: cassert.Site) void {
    const expected: u32 = switch (auth_alg) {
        auth_rakp_hmac_sha1 => 20,
        auth_rakp_hmac_md5 => 16,
        auth_rakp_hmac_sha256 => if (have_sha256) 32 else cassert.unreachableBranch(site),
        else => cassert.unreachableBranch(site),
    };
    cassert.expect(mac_length == expected, site);
}

/// Run one of the RAKP HMACs.
fn keyedHash(algorithm: u8, key: []const u8, data: []const u8, out: *[max_md_size]u8) u32 {
    const selected = mac_mod.algorithmFor(algorithm) orelse {
        c.lprintf(log.Level.debug, "Invalid mac type 0x%x in lanplus_HMAC\n", @as(c_uint, algorithm));
        cassert.unreachableBranch(.{
            .file = "src/plugins/lanplus/lanplus_crypt_impl.c",
            .line = 138,
            .func = "lanplus_HMAC",
            .expr = "0",
        });
    };
    return mac_mod.hmac(selected, key, data, out);
}

/// `lanplus_rakp2_hmac_matches` - check the RAKP 2 key exchange authentication code.
///
/// Returns 1 when the code matches and 0 when it does not; an authentication
/// algorithm of RAKP-none is reported as a match.
fn rakp2HmacMatches(session: *const Session, bmc_mac: [*c]const u8, intf: *Intf) callconv(.c) c_int {
    if (session.v2_data.auth_alg == auth_rakp_none) return 1;

    assertSupportedAuthAlg(session.v2_data.auth_alg, .{
        .file = source,
        .line = if (have_sha256) 88 else 93,
        .func = "lanplus_rakp2_hmac_matches",
        .expr = supported_auth_algs_expr,
    });

    const inputs = inputsFor(session, intf, true);
    const buffer = allocator.alloc(u8, rakp.rakp2Length(inputs.username.len)) catch
        return mallocFailure();
    defer allocator.free(buffer);
    rakp.rakp2(buffer, inputs);

    if (c.verbose > 2) {
        c.printbuf(buffer.ptr, @intCast(buffer.len), ">> rakp2 mac input buffer");
        c.printbuf(&session.authcode, authcode_buffer_size, ">> rakp2 mac key");
    }

    var mac: [max_md_size]u8 = undefined;
    const mac_length = keyedHash(
        session.v2_data.auth_alg,
        session.authcode[0..authcode_buffer_size],
        buffer,
        &mac,
    );

    if (c.verbose > 2) {
        c.printbuf(&mac, @intCast(mac_length), ">> rakp2 mac as computed by the remote console");
    }

    return @intFromBool(std.mem.eql(u8, bmc_mac[0..mac_length], mac[0..mac_length]));
}

/// `lanplus_rakp4_hmac_matches` - check the RAKP 4 integrity check value.
///
/// Returns 1 when the value matches and 0 when it does not.  Intel BMCs answer
/// RAKP 4 keyed with the *integrity* algorithm instead of the authentication
/// one, which is what the `intelplus` OEM branch is for.
fn rakp4HmacMatches(session: *const Session, bmc_mac: [*c]const u8, intf: *Intf) callconv(.c) c_int {
    const intelplus = oemActive(intf, "intelplus");

    if (intelplus) {
        if (session.v2_data.integrity_alg == integrity_none) return 1;
        cassert.expect(
            session.v2_data.integrity_alg == integrity_hmac_sha1_96 or
                session.v2_data.integrity_alg == integrity_hmac_md5_128,
            .{
                .file = source,
                .line = 251,
                .func = "lanplus_rakp4_hmac_matches",
                .expr = "(session->v2_data.integrity_alg == IPMI_INTEGRITY_HMAC_SHA1_96) " ++
                    "|| (session->v2_data.integrity_alg == IPMI_INTEGRITY_HMAC_MD5_128)",
            },
        );
    } else {
        if (session.v2_data.auth_alg == auth_rakp_none) return 1;
        assertSupportedAuthAlg(session.v2_data.auth_alg, .{
            .file = source,
            .line = if (have_sha256) 259 else 264,
            .func = "lanplus_rakp4_hmac_matches",
            .expr = supported_auth_algs_expr,
        });
    }

    const inputs = inputsFor(session, intf, false);
    const buffer = allocator.alloc(u8, rakp.rakp4_length) catch return mallocFailure();
    defer allocator.free(buffer);
    rakp.rakp4(buffer[0..rakp.rakp4_length], inputs);

    if (c.verbose > 2) {
        c.printbuf(buffer.ptr, @intCast(buffer.len), ">> rakp4 mac input buffer");
        c.printbuf(&session.v2_data.sik, session.v2_data.sik_len, ">> rakp4 mac key (sik)");
    }

    const algorithm = if (intelplus) session.v2_data.integrity_alg else session.v2_data.auth_alg;
    var mac: [max_md_size]u8 = undefined;
    const mac_length = keyedHash(
        algorithm,
        session.v2_data.sik[0..session.v2_data.sik_len],
        buffer,
        &mac,
    );

    if (c.verbose > 2) {
        c.printbuf(bmc_mac, @intCast(mac_length), ">> rakp4 mac as computed by the BMC");
        c.printbuf(&mac, @intCast(mac_length), ">> rakp4 mac as computed by the remote console");
    }

    const compare_length = if (intelplus)
        integrityAuthcodeLength(algorithm, .{
            .file = source,
            .line = 353,
            .func = "lanplus_rakp4_hmac_matches",
            .expr = "0",
        })
    else
        rakpAuthcodeLength(algorithm, .{
            .file = source,
            .line = 374,
            .func = "lanplus_rakp4_hmac_matches",
            .expr = "0",
        });

    cassert.expect(mac_length >= compare_length, .{
        .file = source,
        .line = 381,
        .func = "lanplus_rakp4_hmac_matches",
        .expr = "macLength >= cmpLength",
    });
    return @intFromBool(std.mem.eql(u8, bmc_mac[0..compare_length], mac[0..compare_length]));
}

/// `lanplus_generate_rakp3_authcode` - compute the RAKP 3 authentication code.
///
/// Returns 0 on success and 1 on failure.
fn generateRakp3Authcode(
    output_buffer: [*c]u8,
    session: *const Session,
    mac_length: [*c]u32,
    intf: *Intf,
) callconv(.c) c_int {
    if (session.v2_data.auth_alg == auth_rakp_none) {
        mac_length.* = 0;
        return 0;
    }

    assertSupportedAuthAlg(session.v2_data.auth_alg, .{
        .file = source,
        .line = if (have_sha256) 429 else 434,
        .func = "lanplus_generate_rakp3_authcode",
        .expr = supported_auth_algs_expr,
    });

    var inputs = inputsFor(session, intf, false);
    // RAKP 3 sends the privilege level asked for on the command line rather
    // than the role negotiated in RAKP 1 on these two OEM paths.
    if (oemActive(intf, "intelplus") or oemActive(intf, "i82571spt")) {
        inputs.role = intf.ssn_params.privlvl;
    }

    const buffer = allocator.alloc(u8, rakp.rakp3Length(inputs.username.len)) catch
        return mallocFailure();
    defer allocator.free(buffer);
    rakp.rakp3(buffer, inputs);

    if (c.verbose > 2) {
        c.printbuf(buffer.ptr, @intCast(buffer.len), ">> rakp3 mac input buffer");
        c.printbuf(&session.authcode, authcode_buffer_size, ">> rakp3 mac key");
    }

    var mac: [max_md_size]u8 = undefined;
    const length = keyedHash(
        session.v2_data.auth_alg,
        session.authcode[0..authcode_buffer_size],
        buffer,
        &mac,
    );
    @memcpy(output_buffer[0..length], mac[0..length]);
    mac_length.* = length;

    if (c.verbose > 2) {
        c.printbuf(output_buffer, @intCast(length), "generated rakp3 mac");
    }
    return 0;
}

/// `lanplus_generate_sik` - derive the session integrity key.
///
/// Keyed with Kg when a BMC key is configured (two-key login) and with the user
/// authcode otherwise.  Returns 0 on success and 1 on failure.
fn generateSik(session: *Session, intf: *Intf) callconv(.c) c_int {
    session.v2_data.sik = @splat(0);
    session.v2_data.sik_len = 0;

    if (session.v2_data.auth_alg == auth_rakp_none) return 0;

    assertSupportedAuthAlg(session.v2_data.auth_alg, .{
        .file = source,
        .line = if (have_sha256) 555 else 560,
        .func = "lanplus_generate_sik",
        .expr = supported_auth_algs_expr,
    });

    const inputs = inputsFor(session, intf, true);
    const buffer = allocator.alloc(u8, rakp.sikLength(inputs.username.len)) catch
        return mallocFailure();
    defer allocator.free(buffer);
    rakp.sik(buffer, inputs);

    // Section 13.31: Kg is used whole, it is not truncated.
    const key = if (intf.ssn_params.kg[0] != 0)
        intf.ssn_params.kg[0..authcode_buffer_size]
    else
        session.authcode[0..authcode_buffer_size];

    if (c.verbose >= 2) {
        c.printbuf(buffer.ptr, @intCast(buffer.len), "session integrity key input");
    }

    var mac: [max_md_size]u8 = undefined;
    const mac_length = keyedHash(session.v2_data.auth_alg, key, buffer, &mac);
    @memcpy(session.v2_data.sik[0..mac_length], mac[0..mac_length]);

    assertRakpDigestLength(session.v2_data.auth_alg, mac_length, .{
        .file = source,
        .line = 664,
        .func = "lanplus_generate_sik",
        .expr = "0",
    });
    session.v2_data.sik_len = @intCast(mac_length);

    if (c.verbose >= 2) {
        c.printbuf(&session.v2_data.sik, session.v2_data.sik_len, "Generated session integrity key");
    }
    return 0;
}

/// Shared body of `lanplus_generate_k1` and `lanplus_generate_k2`.
///
/// With RAKP-none the constant is copied through unhashed and the length field
/// is left alone, which is what the C does; the field starts out zero, so the
/// `printbuf` below prints nothing.
fn generateK(
    session: *Session,
    constant: *const [20]u8,
    key: *[max_md_size]u8,
    key_len: *u8,
    label: [*:0]const u8,
    comptime site: cassert.Site,
) c_int {
    if (session.v2_data.auth_alg == auth_rakp_none) {
        @memcpy(key[0..20], constant);
    } else {
        var mac: [max_md_size]u8 = undefined;
        const mac_length = keyedHash(
            session.v2_data.auth_alg,
            session.v2_data.sik[0..session.v2_data.sik_len],
            constant,
            &mac,
        );
        @memcpy(key[0..mac_length], mac[0..mac_length]);
        assertRakpDigestLength(session.v2_data.auth_alg, mac_length, site);
        key_len.* = @intCast(mac_length);
    }

    if (c.verbose >= 2) c.printbuf(key, key_len.*, label);
    return 0;
}

/// `lanplus_generate_k1` - derive K1, the integrity authcode key.
fn generateK1(session: *Session) callconv(.c) c_int {
    return generateK(
        session,
        &rakp.const_1,
        &session.v2_data.k1,
        &session.v2_data.k1_len,
        "Generated K1",
        .{ .file = source, .line = 729, .func = "lanplus_generate_k1", .expr = "0" },
    );
}

/// `lanplus_generate_k2` - derive K2, whose first 16 bytes are the AES key.
fn generateK2(session: *Session) callconv(.c) c_int {
    return generateK(
        session,
        &rakp.const_2,
        &session.v2_data.k2,
        &session.v2_data.k2_len,
        "Generated K2",
        .{ .file = source, .line = 789, .func = "lanplus_generate_k2", .expr = "0" },
    );
}

/// `lanplus_encrypt_payload` - encrypt a payload into `output`.
///
/// `output` receives the confidentiality header (the IV) followed by the
/// ciphertext.  With confidentiality disabled nothing is copied and only
/// `bytes_written` is set, because the caller has already assembled the
/// plaintext in place.  Returns 0 on success and 1 on failure.
fn encryptPayload(
    crypt_alg: u8,
    key: [*c]const u8,
    input: [*c]const u8,
    input_length: u32,
    output: [*c]u8,
    bytes_written: [*c]u16,
) callconv(.c) c_int {
    if (crypt_alg == crypt_none) {
        bytes_written.* = @truncate(input_length);
        return 0;
    }

    cassert.expect(crypt_alg == crypt_aes_cbc_128, .{
        .file = source,
        .line = 841,
        .func = "lanplus_encrypt_payload",
        .expr = "crypt_alg == IPMI_CRYPT_AES_CBC_128",
    });
    cassert.expect(input_length <= 0xFFFF, .{
        .file = source,
        .line = 842,
        .func = "lanplus_encrypt_payload",
        .expr = "input_length <= IPMI_MAX_PAYLOAD_SIZE",
    });

    const padded_length = payload_mod.paddedLength(input_length);
    const padded_input = allocator.alloc(u8, padded_length) catch return mallocFailure();
    defer allocator.free(padded_input);
    payload_mod.pad(input[0..input_length], padded_input);

    if (c.lanplus_rand(output, block_size) != 0) {
        c.lprintf(log.Level.err, "lanplus_encrypt_payload: Error generating IV");
        return 1;
    }

    if (c.verbose > 2) c.printbuf(output, block_size, ">> Initialization vector");

    var bytes_encrypted: u32 = undefined;
    c.lanplus_encrypt_aes_cbc_128(
        output,
        key,
        padded_input.ptr,
        padded_length,
        output + block_size,
        &bytes_encrypted,
    );

    bytes_written.* = @truncate(block_size + bytes_encrypted);
    return 0;
}

/// `lanplus_has_valid_auth_code` - check a response's integrity authcode.
///
/// Returns 1 when the packet is acceptable — which includes every case where
/// there is nothing to check — and 0 when the authcode is wrong.
fn hasValidAuthCode(rs: *ipmi.Response, session: *Session) callconv(.c) c_int {
    if (rs.session.authtype != c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS or
        @intFromEnum(session.v2_data.session_state) != c.LANPLUS_STATE_ACTIVE or
        rs.session.bAuthenticated == 0 or
        session.v2_data.integrity_alg == integrity_none)
    {
        return 1;
    }

    const authcode_length: u32 = switch (session.v2_data.integrity_alg) {
        integrity_hmac_sha1_96 => sha1_authcode_size,
        integrity_hmac_md5_128 => hmac_md5_authcode_size,
        integrity_hmac_sha256_128 => if (have_sha256)
            hmac_sha256_authcode_size
        else
            cassert.unreachableBranch(unsupported_integrity_alg),
        else => cassert.unreachableBranch(unsupported_integrity_alg),
    };

    // The authcode sits at the end of the packet and the hash covers everything
    // from the AuthType/Format field up to it.
    const offset = 4;
    const data_length: u32 = @bitCast(rs.data_len -% offset -% @as(c_int, @intCast(authcode_length)));
    const data = rs.data[offset..][0..data_length];
    const authcode_offset: u32 = @bitCast(rs.data_len -% @as(c_int, @intCast(authcode_length)));
    const bmc_authcode = @as([*]const u8, &rs.data) + authcode_offset;

    var generated: [max_md_size]u8 = undefined;
    const generated_length = keyedHash(
        session.v2_data.integrity_alg,
        session.v2_data.k1[0..session.v2_data.k1_len],
        data,
        &generated,
    );

    if (c.verbose > 3) {
        c.lprintf(log.Level.debug + 2, "Validating authcode");
        c.printbuf(&session.v2_data.k1, session.v2_data.k1_len, "K1");
        c.printbuf(data.ptr, @intCast(data_length), "Authcode Input Data");
        c.printbuf(&generated, @intCast(generated_length), "Generated authcode");
        c.printbuf(bmc_authcode, @intCast(authcode_length), "Expected authcode");
    }

    cassert.expect(generated_length >= authcode_length, .{
        .file = source,
        .line = 984,
        .func = "lanplus_has_valid_auth_code",
        .expr = "generated_authcode_length >= authcode_length",
    });
    return @intFromBool(std.mem.eql(
        u8,
        bmc_authcode[0..authcode_length],
        generated[0..authcode_length],
    ));
}

const unsupported_integrity_alg: cassert.Site = .{
    .file = source,
    .line = 955,
    .func = "lanplus_has_valid_auth_code",
    .expr = "0",
};

/// `lanplus_decrypt_payload` - decrypt a payload and strip its padding.
///
/// `input` starts at the confidentiality header, so the first block is the IV.
/// Returns 0 on success and 1 on failure.
fn decryptPayload(
    crypt_alg: u8,
    key: [*c]const u8,
    input: [*c]const u8,
    input_length: u32,
    output: [*c]u8,
    payload_size: [*c]u16,
) callconv(.c) c_int {
    if (crypt_alg == crypt_none) {
        payload_size.* = @truncate(input_length);
        std.mem.copyForwards(u8, output[0..input_length], input[0..input_length]);
        return 0;
    }

    cassert.expect(crypt_alg == crypt_aes_cbc_128, .{
        .file = source,
        .line = 1019,
        .func = "lanplus_decrypt_payload",
        .expr = "crypt_alg == IPMI_CRYPT_AES_CBC_128",
    });

    const decrypted = allocator.alloc(u8, input_length) catch return mallocFailure();
    defer allocator.free(decrypted);

    var bytes_decrypted: u32 = undefined;
    c.lanplus_decrypt_aes_cbc_128(
        input,
        key,
        input + block_size,
        input_length -% block_size,
        decrypted.ptr,
        &bytes_decrypted,
    );

    if (bytes_decrypted == 0) {
        c.lprintf(log.Level.err, "ERROR: lanplus_decrypt_aes_cbc_128 decryptd 0 bytes");
        cassert.unreachableBranch(.{
            .file = source,
            .line = 1070,
            .func = "lanplus_decrypt_payload",
            .expr = "0",
        });
    }

    std.mem.copyForwards(u8, output[0..bytes_decrypted], decrypted[0..bytes_decrypted]);

    const size = payload_mod.payloadLength(decrypted[0..bytes_decrypted]) orelse {
        c.lprintf(log.Level.err, "Malformed payload padding");
        cassert.unreachableBranch(.{
            .file = source,
            .line = 1063,
            .func = "lanplus_decrypt_payload",
            .expr = "0",
        });
    };
    payload_size.* = size;
    return 0;
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

comptime {
    abi.assertCallSignature(@TypeOf(rakp2HmacMatches), @TypeOf(c.lanplus_rakp2_hmac_matches));
    abi.assertCallSignature(@TypeOf(rakp4HmacMatches), @TypeOf(c.lanplus_rakp4_hmac_matches));
    abi.assertCallSignature(@TypeOf(generateRakp3Authcode), @TypeOf(c.lanplus_generate_rakp3_authcode));
    abi.assertCallSignature(@TypeOf(generateSik), @TypeOf(c.lanplus_generate_sik));
    abi.assertCallSignature(@TypeOf(generateK1), @TypeOf(c.lanplus_generate_k1));
    abi.assertCallSignature(@TypeOf(generateK2), @TypeOf(c.lanplus_generate_k2));
    abi.assertCallSignature(@TypeOf(encryptPayload), @TypeOf(c.lanplus_encrypt_payload));
    abi.assertCallSignature(@TypeOf(hasValidAuthCode), @TypeOf(c.lanplus_has_valid_auth_code));
    abi.assertCallSignature(@TypeOf(decryptPayload), @TypeOf(c.lanplus_decrypt_payload));

    @export(&rakp2HmacMatches, .{ .name = "lanplus_rakp2_hmac_matches", .linkage = .strong });
    @export(&rakp4HmacMatches, .{ .name = "lanplus_rakp4_hmac_matches", .linkage = .strong });
    @export(&generateRakp3Authcode, .{ .name = "lanplus_generate_rakp3_authcode", .linkage = .strong });
    @export(&generateSik, .{ .name = "lanplus_generate_sik", .linkage = .strong });
    @export(&generateK1, .{ .name = "lanplus_generate_k1", .linkage = .strong });
    @export(&generateK2, .{ .name = "lanplus_generate_k2", .linkage = .strong });
    @export(&encryptPayload, .{ .name = "lanplus_encrypt_payload", .linkage = .strong });
    @export(&hasValidAuthCode, .{ .name = "lanplus_has_valid_auth_code", .linkage = .strong });
    @export(&decryptPayload, .{ .name = "lanplus_decrypt_payload", .linkage = .strong });
}
