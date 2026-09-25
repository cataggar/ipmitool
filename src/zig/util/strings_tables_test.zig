const std = @import("std");
const tables = @import("strings_tables.zig");
const ValStr = @import("table_types.zig").ValStr;

test "generated tables import without the translated C bridge" {
    const entries: []const ValStr = &tables.completion_code_vals;
    try std.testing.expectEqualStrings("Command completed normally", std.mem.span(entries[0].str.?));
    try std.testing.expectEqual(@as(u32, 0xc1), entries[2].val);
    try std.testing.expectEqual(@as(u32, 0x00), entries[entries.len - 1].val);
    try std.testing.expect(entries[entries.len - 1].str == null);
}

test "SHA256 table rows follow the configured feature" {
    const enabled = @import("build_options").have_crypto_sha256;
    try std.testing.expectEqual(enabled, tables.have_crypto_sha256);
    try std.testing.expectEqual(@as(usize, if (enabled) 5 else 4), tables.ipmi_auth_algorithms.len);
    try std.testing.expectEqual(@as(usize, if (enabled) 6 else 5), tables.ipmi_integrity_algorithms.len);
    const auth_last = tables.ipmi_auth_algorithms[tables.ipmi_auth_algorithms.len - 2];
    const integrity_last = tables.ipmi_integrity_algorithms[tables.ipmi_integrity_algorithms.len - 2];
    try std.testing.expectEqualStrings(if (enabled) "hmac_sha256" else "hmac_md5", std.mem.span(auth_last.str.?));
    try std.testing.expectEqualStrings(if (enabled) "sha256_128" else "md5_128", std.mem.span(integrity_last.str.?));
    try std.testing.expect(tables.ipmi_auth_algorithms[tables.ipmi_auth_algorithms.len - 1].str == null);
    try std.testing.expect(tables.ipmi_integrity_algorithms[tables.ipmi_integrity_algorithms.len - 1].str == null);
}
