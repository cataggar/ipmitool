const std = @import("std");
const tables = @import("intf/lanplus_strings.zig");
const ValStr = @import("util/table_types.zig").ValStr;

test "LAN+ tables import without C headers" {
    const rakp: []const ValStr = &tables.rakp_return_codes;
    const priv: []const ValStr = &tables.priv_levels;
    try std.testing.expectEqual(@as(usize, 20), rakp.len);
    try std.testing.expectEqual(@as(usize, 6), priv.len);
    try std.testing.expectEqualStrings("no errors", std.mem.span(rakp[0].str.?));
    try std.testing.expectEqualStrings("illegal parameter", std.mem.span(rakp[rakp.len - 2].str.?));
    try std.testing.expectEqualStrings("oem", std.mem.span(priv[priv.len - 2].str.?));
    try std.testing.expect(rakp[rakp.len - 1].str == null);
    try std.testing.expect(priv[priv.len - 1].str == null);
}
