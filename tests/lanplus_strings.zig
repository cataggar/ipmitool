//! The C oracle and the selected Zig export each link this exhaustive ABI test.

const std = @import("std");
const c = @import("ipmi_c");
const headers = @import("ipmi_zig");
const ValStr = headers.util.helper.ValStr;
const zig_tables = headers.intf.lanplus_strings;

comptime {
    headers.abi.assertLayout(ValStr, c.struct_valstr);
}

const Entry = struct { val: u32, str: []const u8 };

const rakp = [_]Entry{
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
};

const privileges = [_]Entry{
    .{ .val = 1, .str = "callback" },
    .{ .val = 2, .str = "user" },
    .{ .val = 3, .str = "operator" },
    .{ .val = 4, .str = "admin" },
    .{ .val = 5, .str = "oem" },
};

fn expectTable(expected: []const Entry, actual: [*c]const c.struct_valstr) !void {
    for (expected, 0..) |entry, i| {
        try std.testing.expectEqual(entry.val, actual[i].val);
        try std.testing.expect(actual[i].str != null);
        try std.testing.expectEqualStrings(entry.str, std.mem.span(actual[i].str));
    }
    try std.testing.expectEqual(@as(u32, 0), actual[expected.len].val);
    try std.testing.expect(actual[expected.len].str == null);
}

fn expectZigTable(expected: []const Entry, actual: []const ValStr) !void {
    try std.testing.expectEqual(expected.len + 1, actual.len);
    for (expected, 0..) |entry, i| {
        try std.testing.expectEqual(entry.val, actual[i].val);
        try std.testing.expect(actual[i].str != null);
        try std.testing.expectEqualStrings(entry.str, std.mem.span(actual[i].str.?));
    }
    try std.testing.expectEqual(@as(u32, 0), actual[expected.len].val);
    try std.testing.expect(actual[expected.len].str == null);
}

test "RAKP table has every C value, string, and terminating entry" {
    try expectTable(&rakp, c.ipmi_rakp_return_codes);
    try expectZigTable(&rakp, &zig_tables.rakp_return_codes);
}

test "privilege table has every C value, string, and terminating entry" {
    try expectTable(&privileges, c.ipmi_priv_levels);
    try expectZigTable(&privileges, &zig_tables.priv_levels);
}
