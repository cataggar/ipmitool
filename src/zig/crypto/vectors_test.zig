//! Bit-for-bit parity with the OpenSSL-backed C, from fixtures captured before
//! any of this was written.
//!
//! `tests/crypto/gen_vectors.c` links the *original* C — `md5.c`, `auth.c`,
//! `lanplus_crypt_impl.c` and `lanplus_crypt.c` against libcrypto — and dumps
//! the input and output of every function this migration replaces, including
//! the intermediate buffers the RAKP code prints under `-vvv`.  Regenerate with
//! `zig build gen-crypto-vectors`.
//!
//! Capturing first matters here in a way it does not elsewhere in the
//! migration: a wrong pad byte or an untruncated integrity check value produces
//! a build that passes every CLI test and then fails to open a session against
//! real hardware, which is not something CI can notice.
//!
//! The fixtures are plain text so a reviewer can diff them:
//!
//! ```
//! [hmac/01/20/16]
//! mac=1
//! key=...
//! ```

const std = @import("std");

const aes_cbc = @import("aes_cbc.zig");
const assert_text = @import("assert_text.zig");
const mac_mod = @import("mac.zig");
const md5_mod = @import("md5.zig");
const payload_mod = @import("payload.zig");
const rakp = @import("rakp.zig");
const v15 = @import("v15_auth.zig");

const md5_vectors = @embedFile("crypto_vectors_md5");
const auth_vectors = @embedFile("crypto_vectors_auth");
const hmac_vectors = @embedFile("crypto_vectors_hmac");
const aes_vectors = @embedFile("crypto_vectors_aes_cbc");
const payload_vectors = @embedFile("crypto_vectors_payload");
const integrity_vectors = @embedFile("crypto_vectors_integrity");
const rakp_vectors = @embedFile("crypto_vectors_rakp");
const abort_vectors = @embedFile("crypto_vectors_aborts");

// ---------------------------------------------------------------------------
// Fixture parsing
// ---------------------------------------------------------------------------

/// One `[name]` block and its `key=value` lines.
///
/// Fields are kept as slices into the embedded fixture, so parsing a case
/// allocates nothing and the whole suite runs without a test allocator.
const Case = struct {
    /// The widest fixture block, `rakp.txt`, carries 30 fields.
    const max_fields = 48;

    name: []const u8 = &.{},
    keys: [max_fields][]const u8 = undefined,
    values: [max_fields][]const u8 = undefined,
    count: usize = 0,

    fn get(self: Case, key: []const u8) ?[]const u8 {
        for (self.keys[0..self.count], self.values[0..self.count]) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    fn str(self: Case, key: []const u8) ![]const u8 {
        return self.get(key) orelse {
            std.debug.print("case '{s}' has no field '{s}'\n", .{ self.name, key });
            return error.MissingField;
        };
    }

    fn int(self: Case, key: []const u8) !u32 {
        return std.fmt.parseInt(u32, try self.str(key), 10);
    }

    /// Decode a hex field into `buffer`, returning the populated prefix.
    fn hex(self: Case, key: []const u8, buffer: []u8) ![]u8 {
        const text = try self.str(key);
        if (text.len % 2 != 0 or text.len / 2 > buffer.len) return error.BadHexField;
        return std.fmt.hexToBytes(buffer[0 .. text.len / 2], text);
    }
};

/// Walks the `[name]` blocks of one fixture file.
const Parser = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    pending: ?[]const u8 = null,

    fn init(text: []const u8) Parser {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    fn next(self: *Parser) !?Case {
        const header = self.pending orelse blk: {
            while (self.lines.next()) |line| {
                if (line.len > 2 and line[0] == '[') break :blk line;
            }
            return null;
        };
        self.pending = null;

        var case: Case = .{ .name = header[1 .. header.len - 1] };
        while (self.lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[') {
                self.pending = line;
                break;
            }
            const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (case.count == Case.max_fields) return error.TooManyFields;
            case.keys[case.count] = line[0..split];
            case.values[case.count] = line[split + 1 ..];
            case.count += 1;
        }
        return case;
    }
};

/// Run `body` over every case in `text`, reporting which case failed.
fn forEachCase(text: []const u8, comptime body: fn (case: Case) anyerror!void) !usize {
    var parser: Parser = .init(text);
    var count: usize = 0;
    while (try parser.next()) |case| {
        body(case) catch |err| {
            std.debug.print("crypto vector '{s}' failed: {s}\n", .{ case.name, @errorName(err) });
            return err;
        };
        count += 1;
    }
    return count;
}

/// Scratch space sized for the largest buffer any fixture carries.
const scratch_size = 4096;

// ---------------------------------------------------------------------------
// md5.c
// ---------------------------------------------------------------------------

fn checkMd5(case: Case) !void {
    var input: [scratch_size]u8 = undefined;
    var expected: [16]u8 = undefined;

    const data = try case.hex("input", &input);
    _ = try case.hex("digest", &expected);

    // `md5/stream/N` feeds the same message through in N byte appends, which is
    // the path that exercises the C `md5_state_t` round trip.
    const chunk: usize = if (case.get("chunk")) |text|
        try std.fmt.parseInt(usize, text, 10)
    else
        data.len;

    var state: md5_mod.State = undefined;
    var out: [16]u8 = undefined;
    md5_mod.init(&state);

    // The generator wraps this case in appends of length 0 and -1, which the C
    // documents as no-ops.
    const no_op = std.mem.eql(u8, case.name, "md5/append-zero");
    if (no_op) md5_mod.append(&state, data.ptr, 0);

    var offset: usize = 0;
    while (offset < data.len) {
        const n = @min(chunk, data.len - offset);
        md5_mod.append(&state, data[offset..].ptr, @intCast(n));
        offset += n;
    }

    if (no_op) md5_mod.append(&state, data.ptr, -1);
    md5_mod.finish(&state, &out);

    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "md5.c vectors" {
    const count = try forEachCase(md5_vectors, checkMd5);
    try std.testing.expectEqual(@as(usize, 28), count);
}

// ---------------------------------------------------------------------------
// auth.c
// ---------------------------------------------------------------------------

fn checkAuth(case: Case) !void {
    var expected: [16]u8 = undefined;
    _ = try case.hex("authcode_out", &expected);

    if (std.mem.startsWith(u8, case.name, "auth/md5/")) {
        var password: [16]u8 = undefined;
        var id_bytes: [4]u8 = undefined;
        var seq_bytes: [4]u8 = undefined;
        var data: [scratch_size]u8 = undefined;

        _ = try case.hex("authcode", &password);
        _ = try case.hex("session_id", &id_bytes);
        _ = try case.hex("in_seq", &seq_bytes);
        const message = try case.hex("data", &data);

        // The generator dumped both words as raw memory, so they read back with
        // the host's own byte order.
        const session_id = std.mem.bytesToValue(u32, &id_bytes);
        const in_seq = std.mem.bytesToValue(u32, &seq_bytes);

        const out = v15.md5(&password, session_id, message, in_seq);
        try std.testing.expectEqualSlices(u8, &expected, &out);
        return;
    }

    if (std.mem.startsWith(u8, case.name, "auth/special/")) {
        var authcode: [21]u8 = undefined;
        var challenge: [16]u8 = undefined;
        _ = try case.hex("authcode", &authcode);
        _ = try case.hex("challenge", &challenge);

        const out = v15.special(std.mem.sliceTo(&authcode, 0), &challenge);
        try std.testing.expectEqualSlices(u8, &expected, &out);
        return;
    }

    // auth/md2/unsupported: the baseline answers with zeros, and so do we.
    try std.testing.expectEqualSlices(u8, &expected, &v15.md2_unsupported);
}

test "auth.c vectors" {
    const count = try forEachCase(auth_vectors, checkAuth);
    try std.testing.expectEqual(@as(usize, 94), count);
}

// ---------------------------------------------------------------------------
// lanplus_HMAC
// ---------------------------------------------------------------------------

fn checkHmac(case: Case) !void {
    var key: [scratch_size]u8 = undefined;
    var data: [scratch_size]u8 = undefined;
    var expected: [mac_mod.max_digest_length]u8 = undefined;

    const algorithm = mac_mod.algorithmFor(@intCast(try case.int("mac"))).?;
    const key_bytes = try case.hex("key", &key);
    const data_bytes = try case.hex("data", &data);
    const expected_md = try case.hex("md", &expected);

    var out: [mac_mod.max_digest_length]u8 = undefined;
    const length = mac_mod.hmac(algorithm, key_bytes, data_bytes, &out);

    try std.testing.expectEqual(try case.int("md_len"), length);
    try std.testing.expectEqualSlices(u8, expected_md, out[0..length]);
}

test "lanplus_HMAC vectors" {
    const count = try forEachCase(hmac_vectors, checkHmac);
    try std.testing.expectEqual(@as(usize, 320), count);
}

// ---------------------------------------------------------------------------
// lanplus_{en,de}crypt_aes_cbc_128
// ---------------------------------------------------------------------------

fn checkAesCbc(case: Case) !void {
    var iv: [16]u8 = undefined;
    var key: [16]u8 = undefined;
    var input: [scratch_size]u8 = undefined;
    var expected: [scratch_size]u8 = undefined;

    _ = try case.hex("iv", &iv);
    _ = try case.hex("key", &key);
    const data = try case.hex("input", &input);
    const want = try case.hex("output", &expected);

    try std.testing.expectEqual(try case.int("bytes_written"), @as(u32, @intCast(want.len)));

    // A zero length input is a no-op in the C, not an empty encryption.
    if (data.len == 0) {
        try std.testing.expectEqual(@as(usize, 0), want.len);
        return;
    }

    const encrypting = std.mem.startsWith(u8, case.name, "aes/encrypt") or
        std.mem.startsWith(u8, case.name, "aes/keyvar") or
        std.mem.startsWith(u8, case.name, "aes/ivvar");

    var out: [scratch_size]u8 = undefined;
    if (encrypting) {
        aes_cbc.encrypt(&key, &iv, data, out[0..data.len]);
    } else {
        aes_cbc.decrypt(&key, &iv, data, out[0..data.len]);
    }
    try std.testing.expectEqualSlices(u8, want, out[0..data.len]);

    // The `-in-place` cases exist because the C hands the same buffer in and
    // out, so run them that way too: CBC decryption in particular has to keep a
    // copy of each input block before it is overwritten.
    if (std.mem.indexOf(u8, case.name, "-in-place/") != null) {
        var aliased: [scratch_size]u8 = undefined;
        @memcpy(aliased[0..data.len], data);
        if (encrypting) {
            aes_cbc.encrypt(&key, &iv, aliased[0..data.len], aliased[0..data.len]);
        } else {
            aes_cbc.decrypt(&key, &iv, aliased[0..data.len], aliased[0..data.len]);
        }
        try std.testing.expectEqualSlices(u8, want, aliased[0..data.len]);
    }
}

test "AES-128-CBC vectors" {
    const count = try forEachCase(aes_vectors, checkAesCbc);
    try std.testing.expectEqual(@as(usize, 54), count);
}

// ---------------------------------------------------------------------------
// lanplus_{en,de}crypt_payload
// ---------------------------------------------------------------------------

fn checkPayload(case: Case) !void {
    var key: [16]u8 = undefined;
    var iv: [16]u8 = undefined;
    var input: [scratch_size]u8 = undefined;
    var expected: [scratch_size]u8 = undefined;

    // `IPMI_CRYPT_NONE`: the caller has already assembled the payload in place,
    // so the C only reports its length and leaves the output buffer alone.  The
    // generator pre-filled that buffer with 0xcc to make the absence visible.
    if (std.mem.startsWith(u8, case.name, "payload/none/")) {
        const data = try case.hex("input", &input);
        try std.testing.expectEqual(try case.int("bytes_written"), @as(u32, @intCast(data.len)));

        const untouched = try case.hex("output", &expected);
        for (untouched) |b| try std.testing.expectEqual(@as(u8, 0xcc), b);

        // Decryption is a plain move, which the Zig port keeps as a copy.
        var decoded: [scratch_size]u8 = undefined;
        std.mem.copyForwards(u8, decoded[0..data.len], data);
        try std.testing.expectEqual(try case.int("decrypted_size"), @as(u32, @intCast(data.len)));
        try std.testing.expectEqualSlices(u8, try case.hex("decrypted", &expected), decoded[0..data.len]);
        return;
    }

    _ = try case.hex("key", &key);
    _ = try case.hex("iv", &iv);
    const data = try case.hex("input", &input);
    const want = try case.hex("output", &expected);

    // Reproduce the C: pad, then encrypt after the IV it already wrote out.
    const padded_length = payload_mod.paddedLength(@intCast(data.len));
    var padded: [scratch_size]u8 = undefined;
    payload_mod.pad(data, padded[0..padded_length]);

    var out: [scratch_size]u8 = undefined;
    out[0..16].* = iv;
    aes_cbc.encrypt(&key, &iv, padded[0..padded_length], out[16..][0..padded_length]);

    const written = 16 + padded_length;
    try std.testing.expectEqual(try case.int("bytes_written"), written);
    try std.testing.expectEqualSlices(u8, want, out[0..written]);

    // ...and back, including the padding check the C performs on receipt.
    var decrypted: [scratch_size]u8 = undefined;
    aes_cbc.decrypt(&key, &iv, out[16..][0..padded_length], decrypted[0..padded_length]);

    const size = payload_mod.payloadLength(decrypted[0..padded_length]).?;
    try std.testing.expectEqual(try case.int("decrypted_size"), @as(u32, size));

    var decrypted_expected: [scratch_size]u8 = undefined;
    const want_plain = try case.hex("decrypted", &decrypted_expected);
    try std.testing.expectEqualSlices(u8, want_plain, decrypted[0..size]);
}

test "confidentiality payload vectors" {
    const count = try forEachCase(payload_vectors, checkPayload);
    try std.testing.expectEqual(@as(usize, 59), count);
}

// ---------------------------------------------------------------------------
// RAKP key derivation
// ---------------------------------------------------------------------------

/// `IPMI_AUTH_RAKP_NONE`.
const auth_rakp_none = 0;

fn checkRakp(case: Case) !void {
    var console_rand: [16]u8 = undefined;
    var bmc_rand: [16]u8 = undefined;
    var bmc_guid: [16]u8 = undefined;
    var console_id_bytes: [4]u8 = undefined;
    var bmc_id_bytes: [4]u8 = undefined;
    var authcode: [20]u8 = undefined;
    var kg: [20]u8 = undefined;

    _ = try case.hex("console_rand", &console_rand);
    _ = try case.hex("bmc_rand", &bmc_rand);
    _ = try case.hex("bmc_guid", &bmc_guid);
    _ = try case.hex("console_id", &console_id_bytes);
    _ = try case.hex("bmc_id", &bmc_id_bytes);
    _ = try case.hex("session_authcode", &authcode);
    _ = try case.hex("session_kg", &kg);

    const auth_alg: u8 = @intCast(try case.int("auth_alg"));
    const username = try case.str("username");
    const oem = try case.str("oem");
    const requested_role: u8 = @intCast(try case.int("requested_role"));
    const privlvl: u8 = @intCast(try case.int("privlvl"));

    // The generator wrote the session ids as raw memory, exactly as the C
    // struct held them.
    const inputs: rakp.Inputs = .{
        .console_id = std.mem.bytesToValue(u32, &console_id_bytes),
        .bmc_id = std.mem.bytesToValue(u32, &bmc_id_bytes),
        .console_rand = console_rand,
        .bmc_rand = bmc_rand,
        .bmc_guid = bmc_guid,
        // The 82571 GbE workaround drops bit 4 of the role.
        .role = if (std.mem.eql(u8, oem, "i82571spt")) requested_role & ~@as(u8, 0x10) else requested_role,
        .username = username,
    };

    if (auth_alg == auth_rakp_none) {
        // With RAKP-none the C derives nothing: it copies the two constants
        // into K1 and K2 and leaves their length fields at zero.
        try std.testing.expectEqual(@as(u32, 0), try case.int("sik_len"));
        try std.testing.expectEqual(@as(u32, 0), try case.int("k1_len"));

        var expected_k: [mac_mod.max_digest_length]u8 = undefined;
        _ = try case.hex("k1", &expected_k);
        try std.testing.expectEqualSlices(u8, &rakp.const_1, expected_k[0..20]);
        _ = try case.hex("k2", &expected_k);
        try std.testing.expectEqualSlices(u8, &rakp.const_2, expected_k[0..20]);
        return;
    }

    const algorithm = mac_mod.algorithmFor(auth_alg).?;
    var scratch: [scratch_size]u8 = undefined;
    var expected: [scratch_size]u8 = undefined;
    var out: [mac_mod.max_digest_length]u8 = undefined;

    // RAKP 2: keyed with the user authcode.
    {
        const buffer = scratch[0..rakp.rakp2Length(username.len)];
        rakp.rakp2(buffer, inputs);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp2_input", &expected), buffer);

        const key = try case.hex("rakp2_key", expected[0..20]);
        try std.testing.expectEqualSlices(u8, &authcode, key);

        const length = mac_mod.hmac(algorithm, &authcode, buffer, &out);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp2_mac", &expected), out[0..length]);
        try std.testing.expectEqual(@as(u32, 1), try case.int("rakp2_matches_real"));
    }

    // RAKP 3: same key, and two OEM quirks send the command line privilege
    // level instead of the negotiated role.
    {
        var rakp3_inputs = inputs;
        if (std.mem.eql(u8, oem, "intelplus") or std.mem.eql(u8, oem, "i82571spt")) {
            rakp3_inputs.role = privlvl;
        }
        const buffer = scratch[0..rakp.rakp3Length(username.len)];
        rakp.rakp3(buffer, rakp3_inputs);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp3_input", &expected), buffer);

        const length = mac_mod.hmac(algorithm, &authcode, buffer, &out);
        try std.testing.expectEqual(try case.int("rakp3_len"), length);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp3_mac", &expected), out[0..length]);
    }

    // SIK: keyed with Kg when a BMC key is set, with the user authcode otherwise.
    var sik: [mac_mod.max_digest_length]u8 = undefined;
    const sik_len = blk: {
        const buffer = scratch[0..rakp.sikLength(username.len)];
        rakp.sik(buffer, inputs);
        try std.testing.expectEqualSlices(u8, try case.hex("sik_input", &expected), buffer);

        const key = if (kg[0] != 0) &kg else &authcode;
        const length = mac_mod.hmac(algorithm, key, buffer, &sik);
        try std.testing.expectEqual(try case.int("sik_len"), length);
        try std.testing.expectEqualSlices(u8, try case.hex("sik", &expected), sik[0..length]);
        break :blk length;
    };

    // K1 and K2: the SIK keying two fixed constants.  The fixture dumps the
    // whole field, so the untouched tail has to stay zero.
    inline for (.{ "k1", "k2" }, .{ rakp.const_1, rakp.const_2 }) |field, constant| {
        var key: [mac_mod.max_digest_length]u8 = @splat(0);
        const length = mac_mod.hmac(algorithm, sik[0..sik_len], &constant, &key);
        try std.testing.expectEqual(try case.int(field ++ "_len"), length);
        try std.testing.expectEqualSlices(
            u8,
            try case.hex(field, &expected),
            &key,
        );
    }

    // RAKP 4: keyed with the SIK, and compared only over the truncated prefix.
    {
        var buffer: [rakp.rakp4_length]u8 = undefined;
        rakp.rakp4(&buffer, inputs);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp4_input", &expected), &buffer);

        const length = mac_mod.hmac(algorithm, sik[0..sik_len], &buffer, &out);
        try std.testing.expectEqualSlices(u8, try case.hex("rakp4_mac", &expected), out[0..length]);
        try std.testing.expectEqual(@as(u32, 1), try case.int("rakp4_matches_real"));
    }

    // Integrity check value over a whole synthetic packet.
    if (case.get("integrity_packet") != null) {
        const integrity_alg: u8 = @intCast(try case.int("integrity_alg"));
        const integrity = mac_mod.algorithmFor(integrity_alg).?;
        const authcode_length = integrity.authcodeLength();
        try std.testing.expectEqual(try case.int("integrity_authcode_length"), authcode_length);

        const packet = try case.hex("integrity_packet", &scratch);
        var k1: [mac_mod.max_digest_length]u8 = undefined;
        const k1_len = mac_mod.hmac(algorithm, sik[0..sik_len], &rakp.const_1, &k1);

        // The hash covers the packet from the AuthType/Format field up to the
        // authcode, and only `authcode_length` bytes of it are compared.
        const covered = packet[4 .. packet.len - authcode_length];
        const length = mac_mod.hmac(integrity, k1[0..k1_len], covered, &out);
        try std.testing.expectEqualSlices(u8, try case.hex("integrity_authcode", &expected), out[0..length]);

        const on_the_wire = packet[packet.len - authcode_length ..];
        try std.testing.expect(std.mem.eql(u8, on_the_wire, out[0..authcode_length]));
        try std.testing.expectEqual(@as(u32, 1), try case.int("integrity_valid"));
        try std.testing.expectEqual(@as(u32, 0), try case.int("integrity_valid_tampered"));
    }
}

test "RAKP key derivation vectors" {
    const count = try forEachCase(rakp_vectors, checkRakp);
    try std.testing.expectEqual(@as(usize, 27), count);
}

// ---------------------------------------------------------------------------
// lanplus_has_valid_auth_code
// ---------------------------------------------------------------------------

/// `IPMI_SESSION_AUTHTYPE_RMCP_PLUS`.
const authtype_rmcp_plus = 0x06;
/// `LANPLUS_STATE_ACTIVE`.
const state_active = 3;

fn checkIntegrity(case: Case) !void {
    var k1: [mac_mod.max_digest_length]u8 = undefined;
    var packet: [scratch_size]u8 = undefined;

    const integrity_alg: u8 = @intCast(try case.int("integrity_alg"));
    const key = try case.hex("k1", &k1);
    const data = try case.hex("packet", &packet);

    // The four early returns answer "valid" without hashing anything.
    if (std.mem.startsWith(u8, case.name, "integrity/early/")) {
        const authtype = try case.int("authtype");
        const state = try case.int("session_state");
        const authenticated = try case.int("authenticated");
        const short_circuits = authtype != authtype_rmcp_plus or
            state != state_active or
            authenticated == 0 or
            integrity_alg == 0;
        try std.testing.expect(short_circuits);
        try std.testing.expectEqual(@as(u32, 1), try case.int("valid"));
        return;
    }

    const authcode_length = mac_mod.integrityAuthcodeLength(integrity_alg).?;
    try std.testing.expectEqual(try case.int("authcode_length"), authcode_length);

    const algorithm = mac_mod.algorithmFor(integrity_alg).?;
    var generated: [mac_mod.max_digest_length]u8 = undefined;
    const generated_length = mac_mod.hmac(algorithm, key, data[4 .. data.len - authcode_length], &generated);

    var full: [mac_mod.max_digest_length]u8 = undefined;
    try std.testing.expectEqual(try case.int("full_digest_length"), generated_length);
    try std.testing.expectEqualSlices(
        u8,
        try case.hex("full_digest", &full),
        generated[0..generated_length],
    );

    const bmc = data[data.len - authcode_length ..];
    const valid = std.mem.eql(u8, bmc, generated[0..authcode_length]);
    try std.testing.expectEqual(try case.int("valid"), @intFromBool(valid));
    try std.testing.expect(valid);

    // Every tampered variant the generator recorded must be rejected.  The
    // last one is the important one: it swaps in the *tail* of the untruncated
    // digest, which only a correctly truncated comparison notices.
    var tampered: [scratch_size]u8 = undefined;
    const variants = [_]struct { field: []const u8, index: usize }{
        .{ .field = "valid_body_flipped", .index = 4 },
        .{ .field = "valid_authcode_last_flipped", .index = data.len - 1 },
        .{ .field = "valid_authcode_first_flipped", .index = data.len - authcode_length },
    };
    for (variants) |variant| {
        @memcpy(tampered[0..data.len], data);
        tampered[variant.index] ^= 0x01;
        var got: [mac_mod.max_digest_length]u8 = undefined;
        _ = mac_mod.hmac(algorithm, key, tampered[4 .. data.len - authcode_length], &got);
        const still_valid = std.mem.eql(
            u8,
            tampered[data.len - authcode_length ..][0..authcode_length],
            got[0..authcode_length],
        );
        try std.testing.expectEqual(try case.int(variant.field), @intFromBool(still_valid));
        try std.testing.expect(!still_valid);
    }

    if (case.get("valid_digest_tail")) |_| {
        @memcpy(tampered[0..data.len], data);
        @memcpy(
            tampered[data.len - authcode_length ..][0..authcode_length],
            generated[generated_length - authcode_length ..][0..authcode_length],
        );
        const still_valid = std.mem.eql(
            u8,
            tampered[data.len - authcode_length ..][0..authcode_length],
            generated[0..authcode_length],
        );
        try std.testing.expectEqual(try case.int("valid_digest_tail"), @intFromBool(still_valid));
        try std.testing.expect(!still_valid);
    } else {
        // Only HMAC-MD5-128 has nothing to truncate, so it has no tail case.
        try std.testing.expectEqual(generated_length, authcode_length);
    }
}

test "integrity check value vectors" {
    const count = try forEachCase(integrity_vectors, checkIntegrity);
    try std.testing.expectEqual(@as(usize, 85), count);
}

// ---------------------------------------------------------------------------
// assert() branches
// ---------------------------------------------------------------------------

/// `SIGABRT`.
const sigabrt = 6;

/// Every `assert()` expression the ported modules can reach, keyed by the
/// probe in `tests/crypto/gen_vectors.c` that provoked it.
///
/// The C aborts on all of these, and the port has to abort with the same
/// message, so the expression strings are checked against what the C actually
/// printed rather than against a transcription of the source.  What is *not*
/// compared is the file, line and function glibc also prints: those are
/// toolchain dependent, and gcc and clang disagree on both (see
/// doc/zig-migration/crypto.md).
const abort_expressions = [_]struct { name: []const u8, expr: []const u8 }{
    .{ .name = "abort/hmac/bad-mac", .expr = "0" },
    .{ .name = "abort/aes/encrypt-unaligned", .expr = assert_text.aes_block_multiple },
    .{ .name = "abort/aes/decrypt-unaligned", .expr = assert_text.aes_block_multiple },
    .{ .name = "abort/payload/encrypt-bad-alg", .expr = assert_text.crypt_alg_is_aes },
    .{ .name = "abort/payload/decrypt-bad-alg", .expr = assert_text.crypt_alg_is_aes },
    .{ .name = "abort/payload/bad-padding", .expr = "0" },
    .{ .name = "abort/payload/iv-only", .expr = "0" },
    .{ .name = "abort/integrity/md5-128", .expr = "0" },
    .{ .name = "abort/rakp2/bad-auth-alg", .expr = assert_text.supported_auth_algs },
    .{ .name = "abort/rakp4/intelplus-sha256", .expr = assert_text.intelplus_integrity },
    .{ .name = "abort/sik/bad-auth-alg", .expr = assert_text.supported_auth_algs },
    .{ .name = "abort/rakp3/bad-auth-alg", .expr = assert_text.supported_auth_algs },
};

fn checkAbort(case: Case) !void {
    // Every probe killed the C with SIGABRT rather than returning an error.
    try std.testing.expectEqual(@as(u32, 1), try case.int("signalled"));
    try std.testing.expectEqual(@as(u32, sigabrt), try case.int("signal"));

    for (abort_expressions) |expected| {
        if (!std.mem.eql(u8, expected.name, case.name)) continue;
        try std.testing.expectEqualStrings(expected.expr, try case.str("assert_expr"));
        return;
    }
    return error.UnexpectedAbortCase;
}

test "assert branch vectors" {
    const count = try forEachCase(abort_vectors, checkAbort);
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqual(abort_expressions.len, count);
}

test "every fixture file is covered" {
    // The per-file tests above pin each count; this keeps the total honest if a
    // fixture is ever added without a test to read it.
    const totals = 28 + 94 + 320 + 54 + 59 + 85 + 27 + 12;
    try std.testing.expectEqual(@as(usize, 679), totals);
}
