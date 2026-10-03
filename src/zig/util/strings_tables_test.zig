const std = @import("std");
const tables = @import("strings_tables.zig");
const ValStr = @import("table_types.zig").ValStr;
const OemValStr = @import("table_types.zig").OemValStr;
const validation = @import("strings_tables_validation.zig");

test "all static tables and constants match the frozen C-origin baseline" {
    comptime {
        _ = validation;
    }
}

test "both frozen C baselines retain their recorded SHA256 digests" {
    var sums = std.mem.splitScalar(u8, validation.fixture_checksums, '\n');
    inline for (.{
        .{ "strings-c-sha256-0.txt", validation.fixture_without_sha256 },
        .{ "strings-c-sha256-1.txt", validation.fixture_with_sha256 },
    }) |fixture| {
        const line = sums.next() orelse return error.MissingChecksum;
        try std.testing.expectEqualStrings(fixture[0], line[66..]);
        var expected: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected, line[0..64]);
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(fixture[1], &actual, .{});
        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
    try std.testing.expectEqualStrings("", sums.next().?);
    try std.testing.expect(sums.next() == null);
}

fn compare(comptime Elem: type, rows: []const Elem, count: usize, fixture: []const u8) !void {
    var lines = std.mem.splitScalar(u8, fixture, '\n');
    try validation.checkTable(Elem, rows, count, &lines);
}

const sample = [_]ValStr{
    .{ .val = 1, .str = "ABC" },
    .{ .val = 1, .str = "DEF" },
    .{ .val = 0xff, .str = null },
};
const sample_fixture = "0|1|3|414243\n1|1|3|444546\n2|255|null\n";

test "frozen comparison detects value, complete text, duplicate order and sentinel corruption" {
    try compare(ValStr, &sample, sample.len, sample_fixture);
    var corrupted = sample;
    corrupted[0].val = 2;
    try std.testing.expectError(error.NumericValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted = sample;
    corrupted[0].str = "ABX";
    try std.testing.expectError(error.TextValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted[0].str = "ABCextra";
    try std.testing.expectError(error.TextValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted[0].str = "AB";
    try std.testing.expectError(error.TextValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted = .{ sample[1], sample[0], sample[2] };
    try std.testing.expectError(error.TextValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted = sample;
    corrupted[2].val = 0;
    try std.testing.expectError(error.NumericValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted[2] = .{ .val = 0xff, .str = "" };
    try std.testing.expectError(error.NullValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    corrupted = sample;
    corrupted[0].str = null;
    try std.testing.expectError(error.NullValue, compare(ValStr, &corrupted, sample.len, sample_fixture));
    try std.testing.expectError(error.EntryCount, compare(ValStr, sample[0..2], sample.len, sample_fixture));
    const behind_sentinel = sample ++ [_]ValStr{.{ .val = 42, .str = "extra" }};
    try std.testing.expectError(error.EntryCount, compare(ValStr, &behind_sentinel, sample.len, sample_fixture));
}

test "frozen OEM comparison checks both numeric keys and sentinel OEM" {
    const rows = [_]OemValStr{
        .{ .oem = 343, .val = 12, .str = "BMC" },
        .{ .oem = 0xffffff, .val = 0xffff, .str = null },
    };
    const fixture = "0|343|12|3|424d43\n1|0xffffff|0xffff|null\n";
    try compare(OemValStr, &rows, rows.len, fixture);
    var corrupted = rows;
    corrupted[0].oem = 344;
    try std.testing.expectError(error.NumericValue, compare(OemValStr, &corrupted, rows.len, fixture));
    corrupted = rows;
    corrupted[0].val = 13;
    try std.testing.expectError(error.NumericValue, compare(OemValStr, &corrupted, rows.len, fixture));
    corrupted = rows;
    corrupted[1].oem = 0;
    try std.testing.expectError(error.NumericValue, compare(OemValStr, &corrupted, rows.len, fixture));
    corrupted = rows;
    corrupted[1].val = 0;
    try std.testing.expectError(error.NumericValue, compare(OemValStr, &corrupted, rows.len, fixture));
}

test "indexed string comparison distinguishes empty, null, text and row order" {
    const Str = ?[*:0]const u8;
    const rows = [_]Str{ "", "AB", null };
    const fixture = "0|0|\n1|2|4142\n2|null\n";
    try compare(Str, &rows, rows.len, fixture);
    const swapped = [_]Str{ "AB", "", null };
    try std.testing.expectError(error.TextValue, compare(Str, &swapped, rows.len, fixture));
    const null_first = [_]Str{ null, "AB", null };
    try std.testing.expectError(error.NullValue, compare(Str, &null_first, rows.len, fixture));
    const changed = [_]Str{ "", "AC", null };
    try std.testing.expectError(error.TextValue, compare(Str, &changed, rows.len, fixture));
    try std.testing.expectError(error.EntryIndex, compare(Str, &rows, rows.len, "0|0|\n2|2|4142\n1|null\n"));
}

test "intentional upstream text corrections are part of the frozen contract" {
    var firmware_found = false;
    for (tables.completion_code_vals) |entry| {
        if (entry.val == 0xd1) {
            try std.testing.expectEqualStrings("Device firmware in update mode", std.mem.span(entry.str.?));
            firmware_found = true;
        }
    }
    try std.testing.expect(firmware_found);
    var tatlin_found = false;
    for (tables.ipmi_oem_product_info) |entry| {
        if (entry.oem == 49769 and entry.val == 0x15) {
            try std.testing.expectEqualStrings("TATLIN Series Storage Controller BMC", std.mem.span(entry.str.?));
            tatlin_found = true;
        }
    }
    try std.testing.expect(tatlin_found);
}

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
