//! C-compatible lookup entry layouts, without the translated C bridge.

/// `struct valstr`: one value/name pair, terminated by a `.str == null` entry.
pub const ValStr = extern struct {
    val: u32,
    str: ?[*:0]const u8,
};

/// `struct oemvalstr`: as `ValStr`, but keyed by IANA number as well.
/// The terminator has `.oem == 0xffffff`.
pub const OemValStr = extern struct {
    oem: u32,
    val: u16,
    str: ?[*:0]const u8,
};
