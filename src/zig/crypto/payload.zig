//! The RMCP+ confidentiality padding from `src/plugins/lanplus/lanplus_crypt.c`.
//!
//! AES-128-CBC needs whole blocks, so IPMI v2 appends a pad and then a pad
//! length byte, and the pad length byte itself counts towards the block.  The
//! pad is not zeros and not PKCS#7: section 13.29 specifies the ascending run
//! `0x01, 0x02, 0x03, ...`, which is what a BMC checks on receipt.
//!
//! Kept free of C so it can be checked against vectors captured from the C
//! build directly in `zig build test`.

const std = @import("std");

/// `IPMI_CRYPT_AES_CBC_128_BLOCK_SIZE`.
pub const block_size = 16;

/// Bytes of pad needed before the trailing pad length byte.
pub fn padLength(input_length: u32) u8 {
    const mod = (input_length + 1) % block_size;
    return if (mod == 0) 0 else @intCast(block_size - mod);
}

/// Total length of `input` once padded, i.e. what goes into the block cipher.
pub fn paddedLength(input_length: u32) u32 {
    return input_length + padLength(input_length) + 1;
}

/// Write `input` followed by its confidentiality pad and pad length byte.
///
/// `out` must be `paddedLength(input.len)` bytes.
pub fn pad(input: []const u8, out: []u8) void {
    const length: u32 = @intCast(input.len);
    const pad_length = padLength(length);
    std.debug.assert(out.len == paddedLength(length));

    @memcpy(out[0..input.len], input);
    for (out[input.len..][0..pad_length], 0..) |*b, i| b.* = @intCast(i + 1);
    out[input.len + pad_length] = pad_length;
}

/// The payload length carried by `decrypted`, or null if the pad is malformed.
///
/// The C computes this into a `uint16_t` and then walks the pad, so a BMC that
/// sends a pad length longer than the packet makes it read past the buffer.
/// Here the same arithmetic wraps and an out of range pad simply reports
/// malformed, which is the branch the caller was heading for anyway.
pub fn payloadLength(decrypted: []const u8) ?u16 {
    std.debug.assert(decrypted.len != 0);

    const pad_length = decrypted[decrypted.len - 1];
    const size: u16 = @truncate(decrypted.len -% pad_length -% 1);
    if (@as(usize, size) + pad_length > decrypted.len) return null;

    for (decrypted[size..][0..pad_length], 0..) |b, i| {
        if (b != i + 1) return null;
    }
    return size;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the pad fills the block including its own length byte" {
    // One free byte in the block is always spent on the pad length byte, so a
    // 15 byte payload needs no pad and a 16 byte one needs a whole extra block.
    try std.testing.expectEqual(@as(u8, 15), padLength(0));
    try std.testing.expectEqual(@as(u8, 1), padLength(14));
    try std.testing.expectEqual(@as(u8, 0), padLength(15));
    try std.testing.expectEqual(@as(u8, 15), padLength(16));
    try std.testing.expectEqual(@as(u8, 0), padLength(31));

    var length: u32 = 0;
    while (length < 200) : (length += 1) {
        try std.testing.expectEqual(@as(u32, 0), paddedLength(length) % block_size);
    }
}

test "pad round trips through payloadLength" {
    var input: [64]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(0xc0 +% i);

    var buffer: [96]u8 = undefined;
    for (0..input.len + 1) |length| {
        const out = buffer[0..paddedLength(@intCast(length))];
        pad(input[0..length], out);
        try std.testing.expectEqualSlices(u8, input[0..length], out[0..length]);
        try std.testing.expectEqual(@as(?u16, @intCast(length)), payloadLength(out));
    }
}

test "the ascending pad pattern is checked" {
    var buffer: [16]u8 = undefined;
    pad("abc", buffer[0..paddedLength(3)]);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 'a', 'b', 'c', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 12 },
        &buffer,
    );

    buffer[5] = 0xff;
    try std.testing.expectEqual(@as(?u16, null), payloadLength(&buffer));
}

test "a pad longer than the packet is malformed rather than a read overrun" {
    var buffer: [16]u8 = @splat(0);
    buffer[15] = 0xff;
    try std.testing.expectEqual(@as(?u16, null), payloadLength(&buffer));
}
