const std = @import("std");
const tables = @import("cmd/dimm_spd_tables.zig");
const ValStr = @import("util/table_types.zig").ValStr;

test "all generated SPD tables import without C and end with a null name" {
    inline for (.{
        tables.spd_memtype_vals,
        tables.ddr3_density_vals,
        tables.ddr3_banks_vals,
        tables.ddr3_ecc_vals,
        tables.ddr4_density_vals,
        tables.ddr4_banks_vals,
        tables.ddr4_bank_groups,
        tables.ddr4_package_type,
        tables.ddr4_technology_type,
        tables.spd_config_vals,
        tables.spd_voltage_vals,
        tables.jedec_id1_vals,
        tables.jedec_id2_vals,
        tables.jedec_id3_vals,
        tables.jedec_id4_vals,
        tables.jedec_id5_vals,
        tables.jedec_id6_vals,
        tables.jedec_id7_vals,
        tables.jedec_id8_vals,
        tables.jedec_id9_vals,
    }) |table| {
        const entries: []const ValStr = &table;
        try std.testing.expect(entries.len > 0);
        try std.testing.expect(entries[entries.len - 1].str == null);
    }
    try std.testing.expectEqualStrings("DDR3 SDRAM", std.mem.span(tables.spd_memtype_vals[9].str.?));
    try std.testing.expectEqualStrings("Micron Technology", std.mem.span(tables.jedec_id1_vals[43].str.?));
}
