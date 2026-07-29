//! Static half of the port of `lib/ipmi_strings.c`: the `struct valstr` and
//! `struct oemvalstr` lookup tables every human-readable line ipmitool prints
//! is looked up in.
//!
//! The tables themselves are in [`tables`], generated from the C by
//! `tools/gen_strings.zig` and committed as ordinary source; that file also
//! `@export`s each of them under its C name, so `lib/*.c` links against the Zig
//! data unchanged.  What lives here is the documentation of the lookup rules
//! the tables are written for, and the tests that pin them.
//!
//! The dynamic half — `ipmi_oem_info` and the IANA private enterprise number
//! registry it is loaded from — is in `strings_registry.zig`.  It is kept in a
//! separate file because it calls back into `lib/log.c`, which the ABI test
//! binary does not link.
//!
//! Selected with `zig build -Dzig-modules=strings`.

const std = @import("std");

const helper = @import("helper.zig");

/// The generated tables, one `pub const` per C array, in the C order.
pub const tables = @import("strings_tables.zig");

const ValStr = helper.ValStr;
const OemValStr = helper.OemValStr;

// ---------------------------------------------------------------------------
// The lookup rules these tables are written for
//
// `find_val_idx`, `val2str`, `oemval2str` and `unknown_val_str` live in
// `lib/helper.c`, so the functions below are not exported and not called by
// anything but the tests: they are a restatement of the C used to check that
// the ported tables still answer the way the C ones did.  Three details are
// easy to lose in a transcription and are what the tests are here for:
//
//   * the search stops at the *first* match, so a table with duplicate keys
//     depends on its entry order;
//   * the search stops at the first entry with a NULL string, so the
//     terminator's value is unreachable;
//   * an unmatched value renders as `Unknown (0xNN)` from a 32-byte static
//     buffer, which the caller must copy before the next lookup.
// ---------------------------------------------------------------------------

/// `find_val_idx` in `include/ipmitool/helper.h`.
fn findValIdx(val: u32, vs: []const ValStr) ?usize {
    for (vs, 0..) |entry, i| {
        if (entry.str == null) return null;
        if (entry.val == val) return i;
    }
    return null;
}

/// `val2str` in `lib/helper.c`, minus the `Unknown (0x..)` fallback.
fn val2str(val: u32, vs: []const ValStr) ?[]const u8 {
    const index = findValIdx(val, vs) orelse return null;
    return std.mem.span(vs[index].str.?);
}

/// `oemval2str` in `lib/helper.c`, minus the fallback.  PICMG entries match any
/// IANA number, which is the "FIXME: for now on we assume PICMG capability on
/// all IANAs" in the C.
fn oemval2str(oem: u32, val: u16, vs: []const OemValStr) ?[]const u8 {
    for (vs) |entry| {
        if (entry.oem == 0xffffff or entry.str == null) break;
        if ((entry.oem == oem or entry.oem == 12634) and entry.val == val) {
            return std.mem.span(entry.str.?);
        }
    }
    return null;
}

/// `unknown_val_str` in `include/ipmitool/helper.h`.
fn unknownValStr(buf: *[32]u8, val: u32) []const u8 {
    return std.fmt.bufPrint(buf, "Unknown (0x{X:0>2})", .{val}) catch unreachable;
}

test "completion codes resolve the way the C table did" {
    try std.testing.expectEqualStrings(
        "Command completed normally",
        val2str(0x00, &tables.completion_code_vals).?,
    );
    try std.testing.expectEqualStrings(
        "Invalid command",
        val2str(0xc1, &tables.completion_code_vals).?,
    );
    try std.testing.expectEqualStrings(
        "Insufficient privilege level",
        val2str(0xd4, &tables.completion_code_vals).?,
    );
    try std.testing.expectEqualStrings(
        "Unspecified error",
        val2str(0xff, &tables.completion_code_vals).?,
    );
}

test "an unmatched value renders as the C's Unknown fallback" {
    var buf: [32]u8 = undefined;
    try std.testing.expect(val2str(0x42, &tables.completion_code_vals) == null);
    try std.testing.expectEqualStrings("Unknown (0x42)", unknownValStr(&buf, 0x42));
    // `%02X` widens but never truncates, and it is upper case.
    try std.testing.expectEqualStrings("Unknown (0x0F)", unknownValStr(&buf, 0x0f));
    try std.testing.expectEqualStrings("Unknown (0xABCD)", unknownValStr(&buf, 0xabcd));
}

test "duplicate keys are resolved by entry order" {
    // `ipmi_oem_sensor_type_vals` lists Kontron 0xC2 twice; the C returns the
    // first spelling and never reaches "Board Reset(cPCI)".
    try std.testing.expectEqualStrings(
        "Init Agent",
        oemval2str(15000, 0xC2, &tables.ipmi_oem_sensor_type_vals).?,
    );

    // `ipmi_oem_product_info` has eighteen duplicated Supermicro and ADLINK
    // product IDs.  Reordering the table would silently rename boards.
    try std.testing.expectEqualStrings(
        "X8DTU+",
        oemval2str(10876, 0x060C, &tables.ipmi_oem_product_info).?,
    );
    try std.testing.expectEqualStrings(
        "aTCA-9700",
        oemval2str(24339, 0x9700, &tables.ipmi_oem_product_info).?,
    );
}

test "the terminator's value is unreachable" {
    // `completion_code_vals` ends with `{ 0x00, NULL }` while its first entry is
    // also 0x00, and `ipmi_privlvl_vals` ends with `{ UINT8_MAX, NULL }`.  The
    // search stops at the NULL string, so neither terminator can ever match.
    try std.testing.expectEqualStrings(
        "Command completed normally",
        val2str(0x00, &tables.completion_code_vals).?,
    );
    try std.testing.expectEqual(
        @as(u32, 0xff),
        tables.ipmi_privlvl_vals[tables.ipmi_privlvl_vals.len - 1].val,
    );
    try std.testing.expect(val2str(0xff, &tables.ipmi_privlvl_vals) == null);
}

test "oem lookups honour the PICMG wildcard and the IANA key" {
    try std.testing.expectEqualStrings(
        "TIGW1U",
        oemval2str(343, 0x0811, &tables.ipmi_oem_product_info).?,
    );
    // 343 is Intel, but PICMG entries answer for every IANA number.
    try std.testing.expectEqualStrings(
        "FRU Hot Swap",
        oemval2str(343, 0xF0, &tables.ipmi_oem_sensor_type_vals).?,
    );
    // VITA's 0xF0 is shadowed by PICMG's for exactly that reason.
    try std.testing.expectEqualStrings(
        "FRU Hot Swap",
        oemval2str(33196, 0xF0, &tables.ipmi_oem_sensor_type_vals).?,
    );
    try std.testing.expect(oemval2str(343, 0x1234, &tables.ipmi_oem_product_info) == null);
}

test "every table is terminated the way the lookups expect" {
    inline for (.{
        tables.completion_code_vals,
        tables.entity_id_vals,
        tables.entity_device_type_vals,
        tables.ipmi_netfn_vals,
        tables.ipmi_channel_activity_type_vals,
        tables.ipmi_privlvl_vals,
        tables.ipmi_bit_rate_vals,
        tables.ipmi_set_in_progress_vals,
        tables.ipmi_authtype_session_vals,
        tables.ipmi_authtype_vals,
        tables.ipmi_channel_protocol_vals,
        tables.ipmi_channel_medium_vals,
        tables.ipmi_chassis_power_control_vals,
        tables.ipmi_chassis_restart_cause_vals,
        tables.ipmi_auth_algorithms,
        tables.ipmi_integrity_algorithms,
        tables.ipmi_encryption_algorithms,
        tables.ipmi_user_enable_status_vals,
        tables.picmg_frucontrol_vals,
        tables.picmg_clk_family_vals,
        tables.picmg_busres_id_vals,
        tables.picmg_busres_board_cmd_vals,
        tables.picmg_busres_shmc_cmd_vals,
        tables.ipmi_oem_info_head,
        tables.ipmi_oem_info_tail,
        tables.ipmi_oem_info_dummy,
    }) |table| {
        try std.testing.expect(table.len > 0);
        try std.testing.expect(table[table.len - 1].str == null);
        for (table[0 .. table.len - 1]) |entry| {
            try std.testing.expect(entry.str != null);
        }
    }

    inline for (.{
        tables.ipmi_oem_product_info,
        tables.ipmi_oem_sensor_type_vals,
        tables.picmg_clk_accuracy_vals,
        tables.picmg_clk_resource_vals,
        tables.picmg_clk_id_vals,
        tables.picmg_busres_board_status_vals,
        tables.picmg_busres_shmc_status_vals,
    }) |table| {
        try std.testing.expect(table.len > 0);
        try std.testing.expect(table[table.len - 1].str == null);
        for (table[0 .. table.len - 1]) |entry| {
            try std.testing.expect(entry.str != null);
        }
    }

    try std.testing.expect(
        tables.ipmi_generic_sensor_type_vals[tables.ipmi_generic_sensor_type_vals.len - 1] == null,
    );
}

test "the generic sensor type list is indexed, not searched" {
    // `ipmi_sensor.c` and friends index this one directly by sensor type, so a
    // dropped entry would shift every name after it.
    try std.testing.expectEqual(@as(usize, 46), tables.ipmi_generic_sensor_type_vals.len);
    try std.testing.expectEqualStrings(
        "Temperature",
        std.mem.span(tables.ipmi_generic_sensor_type_vals[0x01].?),
    );
    try std.testing.expectEqualStrings(
        "Watchdog2",
        std.mem.span(tables.ipmi_generic_sensor_type_vals[0x23].?),
    );
    try std.testing.expectEqualStrings(
        "FRU State",
        std.mem.span(tables.ipmi_generic_sensor_type_vals[0x2c].?),
    );
}

test "sensor, entity and netfn names survived the port" {
    try std.testing.expectEqualStrings(
        "Power Supply",
        val2str(0x0a, &tables.entity_id_vals).?,
    );
    try std.testing.expectEqualStrings("Storage", val2str(0x0a, &tables.ipmi_netfn_vals).?);
    try std.testing.expectEqualStrings(
        "ADMINISTRATOR",
        val2str(0x04, &tables.ipmi_privlvl_vals).?,
    );
    try std.testing.expectEqualStrings("802.3 LAN", val2str(0x04, &tables.ipmi_channel_medium_vals).?);
}
