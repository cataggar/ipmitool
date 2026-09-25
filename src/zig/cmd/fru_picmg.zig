const c = @import("ipmi_c");

const Cursor = struct {
    data: []const u8,
    at: usize = 5,

    fn take(self: *Cursor, count: usize) ?[]const u8 {
        if (count > self.data.len -| self.at) return null;
        const bytes = self.data[self.at..][0..count];
        self.at += count;
        return bytes;
    }

    fn byte(self: *Cursor) ?u8 {
        return (self.take(1) orelse return null)[0];
    }

    fn word(self: *Cursor) ?u16 {
        const bytes = self.take(2) orelse return null;
        return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    }

    fn dword(self: *Cursor) ?u32 {
        const bytes = self.take(4) orelse return null;
        return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
    }
};

fn current(value: u16) f64 {
    return @as(f64, @floatFromInt(value)) / 10.0;
}

fn siteType(value: u8) [*:0]const u8 {
    const types = [_][*:0]const u8{
        "AdvancedTCA Board",      "Power Entry",       "Shelf FRU Information",
        "Dedicated ShMC",         "Fan Tray",          "Fan Filter Tray",
        "Alarm",                  "AdvancedMC Module", "PMC",
        "Rear Transition Module",
    };
    return if (value < types.len) types[value] else "Reserved";
}

fn backplane(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_BACKPLANE_P2P\n");
    while (reader.at + 3 <= body.len) {
        const kind = reader.byte() orelse return;
        const slot = reader.byte() orelse return;
        const count = reader.byte() orelse return;
        _ = c.printf("\n    Channel Type:  ");
        const label: ?[*:0]const u8 = switch (kind) {
            0, 7 => "PICMG 2.9",
            8 => "Single Port Fabric IF",
            9 => "Double Port Fabric IF",
            10 => "Full Channel Fabric IF",
            11 => "Base IF",
            12 => "Update Channel IF",
            13 => "ShMC Cross Connect",
            else => null,
        };
        if (label) |s| {
            _ = c.printf("%s\n", s);
        } else {
            _ = c.printf("Unknown IF (0x%x)\n", @as(c_uint, kind));
        }
        _ = c.printf("    Slot Addr.   : %02x\n", @as(c_uint, slot));
        _ = c.printf("    Channel Count: %i\n", @as(c_int, count));
        for (0..count) |_| {
            const bytes = reader.take(3) orelse return;
            const bits = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
            if (c.verbose != 0) _ = c.printf("       Chn: %02x  ->  Chn: %02x in Slot: %02x\n", @as(c_uint, @intCast((bits >> 13) & 0x1f)), @as(c_uint, @intCast((bits >> 8) & 0x1f)), @as(c_uint, bytes[0]));
        }
    }
}

fn addressTable(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_ADDRESS_TABLE\n");
    const type_len = reader.byte() orelse return;
    _ = c.printf("      Type/Len:  0x%02x\n      Shelf Addr: ", @as(c_uint, type_len));
    const address = reader.take(20) orelse return;
    for (address) |byte| _ = c.printf("0x%02x ", @as(c_uint, byte));
    _ = c.printf("\n");
    const entries = reader.byte() orelse return;
    _ = c.printf("      Addr Table Entries: 0x%02x\n", @as(c_uint, entries));
    for (0..entries) |_| {
        const fields = reader.take(3) orelse return;
        _ = c.printf("        HWAddr: 0x%02x (0x%02x) SiteNum: %d SiteType: 0x%02x %s\n", @as(c_uint, fields[0]), @as(c_uint, fields[0]) * 2, @as(c_uint, fields[1]), @as(c_uint, fields[2]), siteType(fields[2]));
    }
}

fn shelfPower(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_SHELF_POWER_DIST\n");
    const feeds = reader.byte() orelse return;
    _ = c.printf("      Number of Power Feeds:   0x%02x\n", @as(c_uint, feeds));
    for (0..feeds) |feed| {
        _ = c.printf("    Feed %d:\n", @as(c_int, @intCast(feed)));
        const external = reader.word() orelse return;
        const internal = reader.word() orelse return;
        const min_voltage = reader.byte() orelse return;
        const entries = reader.byte() orelse return;
        _ = c.printf("      Max External Current:   %d.%d Amps (0x%04x)\n", @as(c_uint, external / 10), @as(c_uint, external % 10), @as(c_uint, external));
        if (internal != 0xffff)
            _ = c.printf("      Max Internal Current:   %d.%d Amps (0x%04x)\n", @as(c_uint, internal / 10), @as(c_uint, internal % 10), @as(c_uint, internal))
        else
            _ = c.printf("      Max Internal Current:   Not Specified\n");
        if (min_voltage >= 0x48 and min_voltage <= 0x90)
            _ = c.printf("      Min Expected Voltage:   -%02d.%dV\n", @as(c_uint, min_voltage / 2), @as(c_uint, (min_voltage % 2) * 5))
        else
            _ = c.printf("      Min Expected Voltage:   -36V (actual invalid value 0x%x)\n", @as(c_uint, min_voltage));
        for (0..entries) |_| {
            const hw = reader.byte() orelse return;
            const id = reader.byte() orelse return;
            _ = c.printf("        FRU HW Addr: 0x%02x (0x%02x)   FRU ID: 0x%02x\n", @as(c_uint, hw), @as(c_uint, hw) * 2, @as(c_uint, id));
        }
    }
}

fn shelfActivation(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_SHELF_ACTIVATION\n");
    const readiness = reader.byte() orelse return;
    const count = reader.byte() orelse return;
    _ = c.printf("      Allowance for FRU Act Readiness:   0x%02x\n", @as(c_uint, readiness));
    _ = c.printf("      FRU activation and Power Desc Cnt: 0x%02x\n", @as(c_uint, count));
    for (0..count) |_| {
        const hw = reader.byte() orelse return;
        const id = reader.byte() orelse return;
        const power = reader.word() orelse return;
        const config = reader.byte() orelse return;
        _ = c.printf("         HW Addr: 0x%02x          FRU ID: 0x%02x          Max FRU Power: 0x%04x          Config: 0x%02x \n", @as(c_uint, hw), @as(c_uint, id), @as(c_uint, power), @as(c_uint, config));
    }
}

fn boardP2p(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_BOARD_P2P\n");
    const count = reader.byte() orelse return;
    _ = c.printf("      GUID count: %2d\n", @as(c_int, count));
    for (0..count) |index| {
        const guid = reader.take(16) orelse return;
        _ = c.printf("        GUID [%2d]: 0x", @as(c_int, @intCast(index)));
        for (guid) |byte| _ = c.printf("%02x", @as(c_uint, byte));
        _ = c.printf("\n");
    }
    _ = c.printf("\n");
    while (reader.at + 4 <= body.len) {
        const bits = reader.dword() orelse return;
        const grouping: u8 = @truncate(bits >> 24);
        const ext: u8 = @intCast((bits >> 20) & 0xf);
        const link_type: u8 = @intCast((bits >> 12) & 0xff);
        const port: u8 = @intCast((bits >> 8) & 0xf);
        const interface: u8 = @intCast((bits >> 6) & 3);
        const channel: u8 = @intCast(bits & 0x3f);
        _ = c.printf("      Link Grouping ID:     0x%02x\n      Link Type Extension:  0x%02x - ", @as(c_uint, grouping), @as(c_uint, ext));
        const extension: [*:0]const u8 = switch (link_type) {
            1 => switch (ext) {
                0 => "10/100/1000BASE-T Link (four-pair)",
                1 => "ShMC Cross-connect (two-pair)",
                else => "Unknown",
            },
            2 => switch (ext) {
                0 => "1000Base-BX",
                1 => "10GBase-BX4 [XAUI]",
                2 => "FC-PI",
                3 => "1000Base-KX",
                4 => "10GBase-KX4",
                else => "Unknown",
            },
            0x32 => switch (ext) {
                0 => "10GBase-KR",
                1 => "40GBase-KR4",
                else => "Unknown",
            },
            else => "Unknown",
        };
        _ = c.printf("%s\n      Link Type:            0x%02x - ", extension, @as(c_uint, link_type));
        switch (link_type) {
            1 => _ = c.printf("PICMG 3.0 Base Interface 10/100/1000\n"),
            2 => _ = c.printf("PICMG 3.1 Ethernet Fabric Interface\n                                   Base signaling Link Class\n"),
            3 => _ = c.printf("PICMG 3.2 Infiniband Fabric Interface\n"),
            4 => _ = c.printf("PICMG 3.3 Star Fabric Interface\n"),
            5 => _ = c.printf("PICMG 3.4 PCI Express Fabric Interface\n"),
            0x32 => _ = c.printf("PICMG 3.1 Ethernet Fabric Interface\n                                   10.3125Gbd signaling Link Class\n"),
            else => _ = c.printf("%s\n", if (link_type == 0 or link_type == 0xff or (link_type >= 6 and link_type <= 0xef)) @as([*:0]const u8, "Reserved") else if (link_type >= 0xf0 and link_type <= 0xfe) @as([*:0]const u8, "OEM GUID Definition") else @as([*:0]const u8, "Invalid")),
        }
        _ = c.printf("      Link Designator: \n        Port Flag:            0x%02x\n        Interface:            0x%02x - ", @as(c_uint, port), @as(c_uint, interface));
        switch (interface) {
            0 => _ = c.printf("Base Interface\n"),
            1 => _ = c.printf("Fabric Interface\n"),
            2 => _ = c.printf("Update Channel\n"),
            3 => _ = c.printf("Reserved\n"),
            else => unreachable,
        }
        _ = c.printf("        Channel Number:       0x%02x\n\n", @as(c_uint, channel));
    }
}

fn amcActivation(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_AMC_ACTIVATION\n");
    const max = reader.word() orelse return;
    const readiness = reader.byte() orelse return;
    const count = reader.byte() orelse return;
    _ = c.printf("      Maximum Internal Current(@12V): %.2f A [ %.2f Watt ]\n", current(max), current(max) * 12.0);
    _ = c.printf("      Module Activation Readiness:    %i sec.\n", @as(c_int, readiness));
    _ = c.printf("      Descriptor Count: %i\n\n", @as(c_int, count));
    while (reader.at + 3 <= body.len) {
        const record = reader.take(3) orelse return;
        _ = c.printf("        IPMB-Address:         0x%x\n        Max. Module Current:  %.2f A\n\n", @as(c_uint, record[0]), current(record[1]));
    }
}

fn carrierP2p(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_CARRIER_P2P\n");
    while (reader.at + 2 <= body.len) {
        const resource = reader.byte() orelse return;
        const count = reader.byte() orelse return;
        _ = c.printf("\n      Resource ID:      %i  Type: %s\n", @as(c_int, resource & 7), if ((resource & 0x80) != 0) @as([*:0]const u8, "AMC") else @as([*:0]const u8, "Local"));
        _ = c.printf("      Descriptor Count: %i\n", @as(c_int, count));
        for (0..count) |_| {
            const bytes = reader.take(3) orelse return;
            const ports = @as(u16, bytes[1]) | (@as(u16, bytes[2]) << 8);
            const remote: u8 = @intCast(ports & 0x1f);
            const local: u8 = @intCast((ports >> 5) & 0x1f);
            _ = c.printf("        Port: %02d\t->  Remote Port: %02d\t[%s ID: %02d ]\n", @as(c_int, local), @as(c_int, remote), if ((bytes[0] & 0x80) != 0) @as([*:0]const u8, " AMC  ") else @as([*:0]const u8, " local"), @as(c_int, bytes[0] & 0xf));
        }
    }
}

fn amcP2p(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_AMC_P2P\n");
    const count = reader.byte() orelse return;
    _ = c.printf("      GUID count: %2d\n", @as(c_int, count));
    for (0..count) |i| {
        const guid = reader.take(16) orelse return;
        _ = c.printf("        GUID %2d: ", @as(c_int, @intCast(i)));
        for (guid) |byte| _ = c.printf("%02x", @as(c_uint, byte));
        _ = c.printf("\n");
    }
    const resource = reader.byte() orelse return;
    _ = c.printf("      %s   Resource ID: %i\n", if ((resource & 0x80) != 0) @as([*:0]const u8, "AMC Module:") else @as([*:0]const u8, "On-Carrier Device"), @as(c_int, resource & 0xf));
    const channels = reader.byte() orelse return;
    _ = c.printf("       Descriptor Count: %i\n", @as(c_int, channels));
    for (0..channels) |_| {
        const bytes = reader.take(3) orelse return;
        const bits: u32 = @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
        _ = c.printf("        Lane 0 Port: %i\n        Lane 1 Port: %i\n        Lane 2 Port: %i\n        Lane 3 Port: %i\n\n", @as(c_int, @intCast(bits & 31)), @as(c_int, @intCast((bits >> 5) & 31)), @as(c_int, @intCast((bits >> 10) & 31)), @as(c_int, @intCast((bits >> 15) & 31)));
    }
    while (reader.at + 5 <= body.len) {
        const link = reader.take(5) orelse return;
        const bits: u32 = @as(u32, link[0]) | (@as(u32, link[1]) << 8) | (@as(u32, link[2]) << 16) | (@as(u32, link[3]) << 24);
        const typ: u8 = @intCast((bits >> 12) & 0xff);
        const ext: u8 = @intCast((bits >> 20) & 0xf);
        _ = c.printf("      Link Designator:  Channel ID: %i\n            Port Flag 0: %c%c%c%c\n", @as(c_int, link[0]), @as(c_int, if ((link[1] & 1) != 0) @as(u8, 'o') else '-'), @as(c_int, if ((link[1] & 2) != 0) @as(u8, 'o') else '-'), @as(c_int, if ((link[1] & 4) != 0) @as(u8, 'o') else '-'), @as(c_int, if ((link[1] & 8) != 0) @as(u8, 'o') else '-'));
        const name: [*:0]const u8 = switch (typ) {
            2 => "AMC.1 PCI Express",
            3, 4 => "AMC.1 PCI Express Advanced Switching",
            5 => "AMC.2 Ethernet",
            7 => "AMC.3 Storage",
            6 => "AMC.4 Serial Rapid IO",
            else => "reserved or OEM GUID",
        };
        _ = c.printf("        Link Type:       %02x - %s\n", @as(c_uint, typ), name);
        const extension: ?[*:0]const u8 = switch (typ) {
            2 => switch (ext) {
                0 => " Gen 1 capable - non SSC",
                1 => " Gen 1 capable - SSC",
                2 => " Gen 2 capable - non SSC",
                3 => " Gen 2 capable - SSC",
                else => " Invalid",
            },
            5 => switch (ext) {
                0 => " 1000Base-Bx (SerDES Gigabit) Ethernet Link",
                1 => " 10Gbit XAUI Ethernet Link",
                else => " Invalid",
            },
            7 => switch (ext) {
                0 => " Fibre Channel",
                1 => " Serial ATA",
                2 => " Serial Attached SCSI",
                else => " Invalid",
            },
            else => null,
        };
        if (extension) |value|
            _ = c.printf("        Link Type Ext:   %i -%s\n", @as(c_int, ext), value)
        else
            _ = c.printf("        Link Type Ext:   %i\n", @as(c_int, ext));
        _ = c.printf("        Link group Id:   %i\n        Link Asym Match: %i\n\n", @as(c_int, link[3]), @as(c_int, link[4] & 3));
    }
}

fn carrierInfo(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_CARRIER_INFO\n");
    const version = reader.byte() orelse return;
    const sites = reader.byte() orelse return;
    _ = c.printf("      AMC.0 extension version: R%d.%d\n", @as(c_int, version & 0xf), @as(c_int, version >> 4));
    _ = c.printf("      Carrier Site Number Cnt: %d\n", @as(c_int, sites));
    for (0..sites) |_| _ = c.printf("       Site ID: %i \n", @as(c_int, reader.byte() orelse return));
    _ = c.printf("\n");
}

fn clockResourceType(id: u8) [*:0]const u8 {
    return switch (id >> 6) {
        0 => "On-Carrier-Device",
        1 => "AMC slot",
        2 => "Backplane",
        else => "reserved",
    };
}

fn clockP2p(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_CLK_CARRIER_P2P\n");
    const count = reader.byte() orelse return;
    for (0..count) |_| {
        const resource = reader.byte() orelse return;
        const channels = reader.byte() orelse return;
        _ = c.printf("\n      Clock Resource ID: 0x%02x  Type: %s\n", @as(c_uint, resource), clockResourceType(resource));
        _ = c.printf("      Channel Count: 0x%02x\n", @as(c_uint, channels));
        for (0..channels) |_| {
            const local = reader.byte() orelse return;
            const remote = reader.byte() orelse return;
            const remote_resource = reader.byte() orelse return;
            const name: [*:0]const u8 = switch (remote_resource >> 6) {
                0 => "[ Carrier-Dev",
                1 => "[ AMC slot   ",
                2 => "[ Backplane  ",
                else => "reserved         ",
            };
            _ = c.printf("        CLK-ID: 0x%02x    -> remote CLKID: 0x%02x   %s 0x%02x ]\n", @as(c_uint, local), @as(c_uint, remote), name, @as(c_uint, remote_resource & 0xf));
        }
    }
    _ = c.printf("\n");
}

fn clockConfig(body: []const u8) void {
    var reader = Cursor{ .data = body };
    _ = c.printf("    FRU_PICMG_CLK_CONFIG\n");
    const resource = reader.byte() orelse return;
    const count = reader.byte() orelse return;
    _ = c.printf("\n      Clock Resource ID: 0x%02x\n      Descr. Count:      0x%02x\n", @as(c_uint, resource), @as(c_uint, count));
    for (0..count) |_| {
        const channel = reader.byte() orelse return;
        const control = reader.byte() orelse return;
        const indirect = reader.byte() orelse return;
        const direct = reader.byte() orelse return;
        _ = c.printf("        CLK-ID: 0x%02x  -  CTRL 0x%02x [ %12s ]\n", @as(c_uint, channel), @as(c_uint, control), if ((control & 1) == 0) @as([*:0]const u8, "Carrier IPMC") else @as([*:0]const u8, "Application"));
        _ = c.printf("         Cnt: Indirect 0x%02x  /  Direct 0x%02x\n", @as(c_uint, indirect), @as(c_uint, direct));
        for (0..indirect) |_| {
            const feature = reader.byte() orelse return;
            const dependent = reader.byte() orelse return;
            _ = c.printf("          Feature: 0x%02x [%8s] -           Dep. CLK-ID: 0x%02x\n", @as(c_uint, feature), if ((feature & 1) == 1) @as([*:0]const u8, "Source") else @as([*:0]const u8, "Receiver"), @as(c_uint, dependent));
        }
        for (0..direct) |_| {
            const feature = reader.byte() orelse return;
            const family = reader.byte() orelse return;
            const accuracy = reader.byte() orelse return;
            const frequency = reader.dword() orelse return;
            const minimum = reader.dword() orelse return;
            const maximum = reader.dword() orelse return;
            _ = c.printf("          - Feature: 0x%02x  - PLL: %x / Asym: %s\n", @as(c_uint, feature), @as(c_uint, @intFromBool((feature > 1) and ((feature & 1) == 1))), if ((feature & 1) != 0) @as([*:0]const u8, "Source") else @as([*:0]const u8, "Receiver"));
            _ = c.printf("            Family:  0x%02x  - AccLVL: 0x%02x\n", @as(c_uint, family), @as(c_uint, accuracy));
            _ = c.printf("            FRQ: %-9ld - min: %-9ld - max: %-9ld\n", @as(c_long, frequency), @as(c_long, minimum), @as(c_long, maximum));
        }
        _ = c.printf("\n");
    }
    _ = c.printf("\n");
}

/// Decode the PICMG OEM record already read by the bounded FRU transport.
/// Incomplete records stop at the last valid field rather than reading the
/// uninitialized padding that the C printer accessed.
pub fn print(body: []const u8) void {
    if (body.len < 5) return;
    switch (body[3]) {
        c.FRU_PICMG_BACKPLANE_P2P => backplane(body),
        c.FRU_PICMG_ADDRESS_TABLE => addressTable(body),
        c.FRU_PICMG_SHELF_POWER_DIST => shelfPower(body),
        c.FRU_PICMG_SHELF_ACTIVATION => shelfActivation(body),
        c.FRU_PICMG_SHMC_IP_CONN => _ = c.printf("    FRU_PICMG_SHMC_IP_CONN\n"),
        c.FRU_PICMG_BOARD_P2P => boardP2p(body),
        c.FRU_AMC_CURRENT => {
            var reader = Cursor{ .data = body };
            _ = c.printf("    FRU_AMC_CURRENT\n");
            const value = reader.byte() orelse return;
            _ = c.printf("      Current draw(@12V): %.2f A [ %.2f Watt ]\n\n", current(value), current(value) * 12.0);
        },
        c.FRU_AMC_ACTIVATION => amcActivation(body),
        c.FRU_AMC_CARRIER_P2P => carrierP2p(body),
        c.FRU_AMC_P2P => amcP2p(body),
        c.FRU_AMC_CARRIER_INFO => carrierInfo(body),
        c.FRU_PICMG_CLK_CARRIER_P2P => clockP2p(body),
        c.FRU_PICMG_CLK_CONFIG => clockConfig(body),
        0x20...0x2b => {
            _ = c.printf("    Not implemented yet. uTCA specific record found!!\n");
            _ = c.printf("     - Record ID: 0x%02x\n", @as(c_uint, body[3]));
        },
        else => _ = c.printf("    Unknown OEM Extension Record ID: %x\n", @as(c_uint, body[3])),
    }
}
