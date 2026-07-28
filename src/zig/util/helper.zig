//! Port of the data types in `include/ipmitool/helper.h`.
//!
//! `lib/helper.c` itself is issue #8; what this file pins down now is the pair
//! of lookup-table structs that essentially every command module embeds as a
//! static array, so the first `cmd/` ports have somewhere to put their tables.

const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");

/// `IPMI_UID_MIN`.
pub const uid_min = 1;

/// `IPMI_UID_MAX`.
pub const uid_max = 63;

/// `BUF2STR_MAXIMUM_OUTPUT_SIZE`.
pub const buf2str_max_output_size = 3 * 1024 + 1;

/// `struct valstr`: a value/description pair, terminated by `{ 0xFFFF, NULL }`
/// in the C tables.
pub const ValStr = extern struct {
    val: u32,
    str: ?[*:0]const u8,
};

/// `struct oemvalstr`: like `ValStr` but keyed by IANA number as well.
pub const OemValStr = extern struct {
    oem: u32,
    val: u16,
    str: ?[*:0]const u8,
};

comptime {
    abi.assertLayout(ValStr, c.struct_valstr);
    abi.assertLayout(OemValStr, c.struct_oemvalstr);
}

test "uid bounds match helper.h" {
    try std.testing.expectEqual(@as(c_int, c.IPMI_UID_MIN), uid_min);
    try std.testing.expectEqual(@as(c_int, c.IPMI_UID_MAX), uid_max);
    try std.testing.expectEqual(
        @as(c_int, c.BUF2STR_MAXIMUM_OUTPUT_SIZE),
        buf2str_max_output_size,
    );
}
