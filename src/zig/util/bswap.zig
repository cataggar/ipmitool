//! Port of `include/ipmitool/bswap.h`.
//!
//! The C header is a pair of macros that fall back to `<byteswap.h>` when it
//! exists.  `translate-c` cannot express function-like macros, so this is the
//! one header that is reimplemented rather than mirrored; `@byteSwap` compiles
//! to the same instruction the libc macro does.

const std = @import("std");

/// `BSWAP_16`.
pub fn bswap16(value: u16) u16 {
    return @byteSwap(value);
}

/// `BSWAP_32`.
pub fn bswap32(value: u32) u32 {
    return @byteSwap(value);
}

/// Host to IPMI (little endian) conversion for a 16 bit field.
pub fn hostToIpmi16(value: u16) u16 {
    return std.mem.nativeToLittle(u16, value);
}

/// IPMI (little endian) to host conversion for a 16 bit field.
pub fn ipmiToHost16(value: u16) u16 {
    return std.mem.littleToNative(u16, value);
}

test "bswap matches the C macro definitions" {
    try std.testing.expectEqual(@as(u16, 0x3412), bswap16(0x1234));
    try std.testing.expectEqual(@as(u32, 0x78563412), bswap32(0x12345678));
    try std.testing.expectEqual(@as(u16, 0x1234), bswap16(bswap16(0x1234)));
    try std.testing.expectEqual(@as(u32, 0x12345678), bswap32(bswap32(0x12345678)));
}
