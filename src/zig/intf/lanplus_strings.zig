//! Lookup tables from `src/plugins/lanplus/lanplus_strings.c`.

const ValStr = @import("../util/table_types.zig").ValStr;

pub const rakp_return_codes = [_]ValStr{
    .{ .val = 0x00, .str = "no errors" },
    .{ .val = 0x01, .str = "insufficient resources for session" },
    .{ .val = 0x02, .str = "invalid session ID" },
    .{ .val = 0x03, .str = "invalid payload type" },
    .{ .val = 0x04, .str = "invalid authentication algorithm" },
    .{ .val = 0x05, .str = "invalid integrity algorithm" },
    .{ .val = 0x06, .str = "no matching authentication algorithm" },
    .{ .val = 0x07, .str = "no matching integrity payload" },
    .{ .val = 0x08, .str = "inactive session ID" },
    .{ .val = 0x09, .str = "invalid role" },
    .{ .val = 0x0a, .str = "unauthorized role requested" },
    .{ .val = 0x0b, .str = "insufficient resources for role" },
    .{ .val = 0x0c, .str = "invalid name length" },
    .{ .val = 0x0d, .str = "unauthorized name" },
    .{ .val = 0x0e, .str = "unauthorized GUID" },
    .{ .val = 0x0f, .str = "invalid integrity check value" },
    .{ .val = 0x10, .str = "invalid confidentiality algorithm" },
    .{ .val = 0x11, .str = "no matching cipher suite" },
    .{ .val = 0x12, .str = "illegal parameter" },
    .{ .val = 0, .str = null },
};

pub const priv_levels = [_]ValStr{
    .{ .val = 1, .str = "callback" },
    .{ .val = 2, .str = "user" },
    .{ .val = 3, .str = "operator" },
    .{ .val = 4, .str = "admin" },
    .{ .val = 5, .str = "oem" },
    .{ .val = 0, .str = null },
};

pub fn exportSymbols() void {
    comptime {
        _ = @import("lanplus_strings_validation.zig");
    }
    @export(&rakp_return_codes, .{ .name = "ipmi_rakp_return_codes", .linkage = .strong });
    @export(&priv_levels, .{ .name = "ipmi_priv_levels", .linkage = .strong });
}
