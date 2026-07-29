//! Port of `src/plugins/lanplus/lanplus_crypt_impl.c`: the thin layer the RMCP+
//! code calls for randomness, keyed hashing and AES-128-CBC.
//!
//! This is the file that used to be OpenSSL.  `EVP_sha1()` / `EVP_md5()` /
//! `EVP_sha256()` and `HMAC()` become `src/zig/crypto/mac.zig`,
//! `EVP_aes_128_cbc()` with padding disabled becomes
//! `src/zig/crypto/aes_cbc.zig`, and `RAND_bytes()` becomes the operating
//! system CSPRNG behind `std.crypto.random`.
//!
//! Everything else — the argument checks, the `verbose` tracing, the
//! `assert()`s and the exact `bytes_written` semantics — is kept as it was, so
//! the swap is invisible to `lanplus.c` and `lanplus_crypt.c`.
//!
//! Selected with `zig build -Dzig-modules=lanplus-crypt-impl`.

const std = @import("std");

const assert_text = @import("assert_text.zig");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const aes_cbc = @import("aes_cbc.zig");
const cassert = @import("../util/cassert.zig");
const log = @import("../util/log.zig");
const mac = @import("mac.zig");

const source = "src/plugins/lanplus/lanplus_crypt_impl.c";

/// `IPMI_CRYPT_AES_CBC_128_BLOCK_SIZE`.
const block_size = aes_cbc.block_size;

/// The user space CSPRNG that replaces OpenSSL's.
///
/// OpenSSL kept a ChaCha-based pool seeded from the kernel, and ipmitool relies
/// on that shape: `ipmi_lanplus_open` seeds once and then draws a fresh IV for
/// every encrypted packet, so going to the kernel each time would put three
/// syscalls in the middle of the SOL data path.
var pool: ?std.Random.ChaCha = null;

/// Read `buffer.len` bytes from `/dev/urandom`, the source the C named.
fn kernelEntropy(buffer: []u8) bool {
    const fd = std.c.open("/dev/urandom", .{});
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = std.c.read(fd, buffer.ptr + filled, buffer.len - filled);
        if (n <= 0) return false;
        filled += @intCast(n);
    }
    return true;
}

/// Seed, or reseed, the pool.  Returns false when the kernel gave us nothing,
/// which is the one case the C reported to its caller.
fn seed() bool {
    var secret: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
    if (!kernelEntropy(&secret)) return false;

    if (pool) |*existing| {
        existing.addEntropy(&secret);
    } else {
        pool = .init(secret);
    }
    return true;
}

/// `lanplus_seed_prng` - seed the PRNG with `bytes` bytes of entropy.
///
/// The C read `bytes` bytes out of `/dev/urandom` into OpenSSL's pool.  The
/// pool here has a fixed seed size, so `bytes` no longer sets how much is read;
/// what is preserved is the failure path, because `ipmi_lanplus_open` refuses
/// to open a session when this returns non-zero.
///
/// Returns 0 on success and 1 on failure.
fn seedPrng(bytes: u32) callconv(.c) c_int {
    _ = bytes;
    return if (seed()) 0 else 1;
}

/// `lanplus_rand` - fill `buffer` with `num_bytes` random bytes.
///
/// Returns 0 on success and 1 on failure.  Seeds on demand: the C would happily
/// call `RAND_bytes` without a preceding `RAND_load_file`, and OpenSSL seeded
/// itself in that case.
fn rand(buffer: [*c]u8, num_bytes: u32) callconv(.c) c_int {
    if (num_bytes == 0) return 0;
    if (pool == null and !seed()) return 1;
    pool.?.fill(buffer[0..num_bytes]);
    return 0;
}

/// `lanplus_HMAC` - MAC `d[0..n]` under `key`, selecting the digest with `mac`.
///
/// Returns `md`, as the C did.  `md_len` receives the digest length.
fn hmac(
    algorithm: u8,
    key: ?*const anyopaque,
    key_len: c_int,
    d: [*c]const u8,
    n: c_int,
    md: [*c]u8,
    md_len: [*c]u32,
) callconv(.c) [*c]u8 {
    const selected = mac.algorithmFor(algorithm) orelse {
        c.lprintf(log.Level.debug, "Invalid mac type 0x%x in lanplus_HMAC\n", @as(c_uint, algorithm));
        cassert.unreachableBranch(.{
            .file = source,
            .line = 138,
            .func = "lanplus_HMAC",
            .expr = "0",
        });
    };

    const key_bytes: []const u8 = if (key_len <= 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(key.?))[0..@intCast(key_len)];
    const data: []const u8 = if (n <= 0) &.{} else d[0..@intCast(n)];

    var digest: [mac.max_digest_length]u8 = undefined;
    const length = mac.hmac(selected, key_bytes, data, &digest);
    @memcpy(md[0..length], digest[0..length]);
    md_len.* = length;
    return md;
}

/// `lanplus_encrypt_aes_cbc_128` - encrypt `input_length` bytes into `output`.
///
/// `input_length` must be a whole number of blocks: the RMCP+ layer pads its
/// payloads itself, and OpenSSL was explicitly told not to add any
/// (`EVP_CIPHER_CTX_set_padding(ctx, 0)`), so the block cipher output is the
/// same length as its input.
fn encryptAesCbc128(
    iv: [*c]const u8,
    key: [*c]const u8,
    input: [*c]const u8,
    input_length: u32,
    output: [*c]u8,
    bytes_written: [*c]u32,
) callconv(.c) void {
    bytes_written.* = 0;
    if (input_length == 0) return;

    if (c.verbose >= 5) {
        c.printbuf(iv, 16, "encrypting with this IV");
        c.printbuf(key, 16, "encrypting with this key");
        c.printbuf(input, @intCast(input_length), "encrypting this data");
    }

    cassert.expect(input_length % block_size == 0, .{
        .file = source,
        .line = 199,
        .func = "lanplus_encrypt_aes_cbc_128",
        .expr = assert_text.aes_block_multiple,
    });

    aes_cbc.encrypt(
        key[0..16],
        iv[0..block_size],
        input[0..input_length],
        output[0..input_length],
    );
    bytes_written.* = input_length;
}

/// `lanplus_decrypt_aes_cbc_128` - decrypt `input_length` bytes into `output`.
fn decryptAesCbc128(
    iv: [*c]const u8,
    key: [*c]const u8,
    input: [*c]const u8,
    input_length: u32,
    output: [*c]u8,
    bytes_written: [*c]u32,
) callconv(.c) void {
    if (c.verbose >= 5) {
        c.printbuf(iv, 16, "decrypting with this IV");
        c.printbuf(key, 16, "decrypting with this key");
        c.printbuf(input, @intCast(input_length), "decrypting this data");
    }

    bytes_written.* = 0;
    if (input_length == 0) return;

    cassert.expect(input_length % block_size == 0, .{
        .file = source,
        .line = 282,
        .func = "lanplus_decrypt_aes_cbc_128",
        .expr = assert_text.aes_block_multiple,
    });

    aes_cbc.decrypt(
        key[0..16],
        iv[0..block_size],
        input[0..input_length],
        output[0..input_length],
    );
    bytes_written.* = input_length;

    if (c.verbose >= 5) {
        c.lprintf(log.Level.debug, "Decrypted %d encrypted bytes", input_length);
        c.printbuf(output, @intCast(bytes_written.*), "Decrypted this data");
    }
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

comptime {
    abi.assertCallSignature(@TypeOf(seedPrng), @TypeOf(c.lanplus_seed_prng));
    abi.assertCallSignature(@TypeOf(rand), @TypeOf(c.lanplus_rand));
    abi.assertCallSignature(@TypeOf(hmac), @TypeOf(c.lanplus_HMAC));
    abi.assertCallSignature(@TypeOf(encryptAesCbc128), @TypeOf(c.lanplus_encrypt_aes_cbc_128));
    abi.assertCallSignature(@TypeOf(decryptAesCbc128), @TypeOf(c.lanplus_decrypt_aes_cbc_128));

    @export(&seedPrng, .{ .name = "lanplus_seed_prng", .linkage = .strong });
    @export(&rand, .{ .name = "lanplus_rand", .linkage = .strong });
    @export(&hmac, .{ .name = "lanplus_HMAC", .linkage = .strong });
    @export(&encryptAesCbc128, .{ .name = "lanplus_encrypt_aes_cbc_128", .linkage = .strong });
    @export(&decryptAesCbc128, .{ .name = "lanplus_decrypt_aes_cbc_128", .linkage = .strong });
}
