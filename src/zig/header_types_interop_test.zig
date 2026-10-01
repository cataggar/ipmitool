//! Test-only C fixtures; none of these declarations enter production roots.
const std = @import("std");
const c = @import("ipmi_c");
const ipmi = @import("core/ipmi.zig");
const intf = @import("intf/intf.zig");

comptime {
    _ = @import("header_types_validation.zig");
}

extern fn ipmitool_test_header_bitfield(u8, u8) u8;
extern fn ipmitool_test_header_session_size() usize;
extern fn ipmitool_test_header_session_align() usize;
extern fn ipmitool_test_header_socket(*intf.Session, c_int) c_int;
extern fn ipmitool_test_header_ipv4_cast(*intf.Session) c_int;

test {
    _ = @import("header_types_test.zig");
}

test "native bitfield bytes agree with C for every netfn and lun" {
    for (0..64) |netfn| {
        for (0..4) |lun| {
            const bits: ipmi.NetFnLun = .{ .netfn = @intCast(netfn), .lun = @intCast(lun) };
            try std.testing.expectEqual(
                ipmitool_test_header_bitfield(@intCast(netfn), @intCast(lun)),
                @as(u8, @bitCast(bits)),
            );
        }
    }
}

test "native Session layout agrees with the compiled C fixture" {
    try std.testing.expectEqual(@sizeOf(intf.Session), ipmitool_test_header_session_size());
    try std.testing.expectEqual(@alignOf(intf.Session), ipmitool_test_header_session_align());
}

test "Session storage supports C getsockname and TSOL IPv4 casts" {
    for ([_]c_int{ c.AF_INET, c.AF_INET6 }) |family| {
        var session = std.mem.zeroes(intf.Session);
        session.timeout = 0x12345678;
        session.v2_data.session_state = .active;
        session.v2_data.console_id = 0xfedcba98;
        session.sol_data.sequence_number = 0xa5;
        const result = ipmitool_test_header_socket(&session, family);
        if (result == -2 and family == c.AF_INET6) continue;
        try std.testing.expectEqual(@as(c_int, 0), result);
        try std.testing.expectEqual(@as(u32, 0x12345678), session.timeout);
        try std.testing.expectEqual(intf.LanplusSessionState.active, session.v2_data.session_state);
        try std.testing.expectEqual(@as(u32, 0xfedcba98), session.v2_data.console_id);
        try std.testing.expectEqual(@as(u8, 0xa5), session.sol_data.sequence_number);
        try std.testing.expectEqual(family, session.addr.family);
        try std.testing.expectEqual(
            @as(c.socklen_t, if (family == c.AF_INET) @sizeOf(c.struct_sockaddr_in) else @sizeOf(c.struct_sockaddr_in6)),
            session.addrlen,
        );
        if (family == c.AF_INET) {
            try std.testing.expectEqual(@as(c_int, 0), ipmitool_test_header_ipv4_cast(&session));
            try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 42 }, std.mem.asBytes(&session.addr)[4..8]);
        }
    }
}
