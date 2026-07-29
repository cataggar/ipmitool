//! Port of `src/plugins/lan/md5.c`: the bundled RFC 1321 MD5, kept because
//! `--enable-internal-md5` builds ipmitool without libcrypto's MD5 and because
//! `lib/ipmi_hpmfwupg.c` hashes firmware images with it unconditionally.
//!
//! The algorithm itself is `std.crypto.hash.Md5`.  What this file has to
//! reproduce is the *streaming state*: `md5_state_t` is a public struct that
//! callers put on the stack, so the three exported functions have to keep
//! working on the C layout rather than on a Zig one.  That is a lossless
//! mapping — MD5's streaming state is exactly a chaining value, a partial block
//! and a message length, and both representations carry all three:
//!
//! | `md5_state_t` | `std.crypto.hash.Md5`         |
//! | ------------- | ----------------------------- |
//! | `abcd[4]`     | `s[4]`                        |
//! | `buf[64]`     | `buf[64]`                     |
//! | `count[2]`    | `total_len` (bytes, not bits) |
//!
//! `count` is a 64 bit *bit* counter split low word first, so it is
//! `total_len * 8` and the partial block length is `(count[0] >> 3) & 63`.
//!
//! Selected with `zig build -Dzig-modules=md5`.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");

const Md5 = std.crypto.hash.Md5;

/// `md5_state_t` from `src/plugins/lan/md5.h`.
pub const State = extern struct {
    /// Message length in bits, least significant word first.
    count: [2]u32,
    /// Digest buffer.
    abcd: [4]u32,
    /// Accumulated partial block.
    buf: [64]u8,
};

/// Rebuild a `std.crypto` MD5 context from the C state.
fn restore(state: *const State) Md5 {
    const bits = (@as(u64, state.count[1]) << 32) | @as(u64, state.count[0]);
    return .{
        .s = state.abcd,
        .buf = state.buf,
        .buf_len = @intCast((state.count[0] >> 3) & 63),
        .total_len = bits >> 3,
    };
}

/// Write a `std.crypto` MD5 context back into the C state.
fn save(digest: *const Md5, state: *State) void {
    const bits = digest.total_len *% 8;
    state.count[0] = @truncate(bits);
    state.count[1] = @truncate(bits >> 32);
    state.abcd = digest.s;
    state.buf = digest.buf;
}

/// `md5_init` - initialise the algorithm.
pub fn init(pms: *State) callconv(.c) void {
    save(&Md5.init(.{}), pms);
}

/// `md5_append` - append a string to the message.
///
/// A non-positive `nbytes` is a no-op, as in the C.
pub fn append(pms: *State, data: [*c]const u8, nbytes: c_int) callconv(.c) void {
    if (nbytes <= 0) return;
    var digest = restore(pms);
    digest.update(data[0..@intCast(nbytes)]);
    save(&digest, pms);
}

/// `md5_finish` - finish the message and return the digest.
pub fn finish(pms: *State, digest: [*c]u8) callconv(.c) void {
    var state = restore(pms);
    state.final(digest[0..Md5.digest_length]);
    // The C leaves `abcd` holding the digest words; a caller that reads the
    // state instead of the output buffer sees the same thing here.
    save(&state, pms);
}

// ---------------------------------------------------------------------------
// C ABI surface
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(State, c.md5_state_t);

    abi.assertCallSignature(@TypeOf(init), @TypeOf(c.md5_init));
    abi.assertCallSignature(@TypeOf(append), @TypeOf(c.md5_append));
    abi.assertCallSignature(@TypeOf(finish), @TypeOf(c.md5_finish));

    @export(&init, .{ .name = "md5_init", .linkage = .strong });
    @export(&append, .{ .name = "md5_append", .linkage = .strong });
    @export(&finish, .{ .name = "md5_finish", .linkage = .strong });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// `md5_init` + one `md5_append` + `md5_finish`, the shape every caller uses.
fn oneShot(data: []const u8) [16]u8 {
    var state: State = undefined;
    var out: [16]u8 = undefined;
    init(&state);
    append(&state, data.ptr, @intCast(data.len));
    finish(&state, &out);
    return out;
}

test "RFC 1321 appendix A.5" {
    const cases = [_]struct { in: []const u8, out: *const [32:0]u8 }{
        .{ .in = "", .out = "d41d8cd98f00b204e9800998ecf8427e" },
        .{ .in = "a", .out = "0cc175b9c0f1b6a831c399e269772661" },
        .{ .in = "abc", .out = "900150983cd24fb0d6963f7d28e17f72" },
        .{ .in = "message digest", .out = "f96b697d7cb7938d525a2f31aaf161d0" },
        .{ .in = "abcdefghijklmnopqrstuvwxyz", .out = "c3fcd3d76192e4007dfb496cca67e13b" },
        .{
            .in = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
            .out = "d174ab98d277d9f5a5611c2c9f419d9f",
        },
        .{
            .in = "1234567890123456789012345678901234567890" ++
                "1234567890123456789012345678901234567890",
            .out = "57edf4a22be3c955ac49da2e2107b67a",
        },
    };

    for (cases) |case| {
        var expected: [16]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, case.out);
        try std.testing.expectEqualSlices(u8, &expected, &oneShot(case.in));
    }
}

test "streaming through the C state matches a single append" {
    var data: [200]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xff);
    const expected = oneShot(&data);

    var chunk: usize = 1;
    while (chunk <= 128) : (chunk *= 2) {
        var state: State = undefined;
        var out: [16]u8 = undefined;
        init(&state);
        var offset: usize = 0;
        while (offset < data.len) {
            const n = @min(chunk, data.len - offset);
            append(&state, data[offset..].ptr, @intCast(n));
            offset += n;
        }
        finish(&state, &out);
        try std.testing.expectEqualSlices(u8, &expected, &out);
    }
}

test "a non-positive length is ignored" {
    var state: State = undefined;
    var out: [16]u8 = undefined;
    init(&state);
    append(&state, "abc", 0);
    append(&state, "abc", 3);
    append(&state, "abc", -1);
    finish(&state, &out);
    try std.testing.expectEqualSlices(u8, &oneShot("abc"), &out);
}

test "md5_init leaves the documented initial state" {
    var state: State = undefined;
    init(&state);
    try std.testing.expectEqual([2]u32{ 0, 0 }, state.count);
    try std.testing.expectEqual(
        [4]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 },
        state.abcd,
    );
}
