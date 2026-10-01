//! Standalone native tests: no ipmi_c module, C sources or libc linkage.
const std = @import("std");
const builtin = @import("builtin");
const ipmi = @import("core/ipmi.zig");
const oem = @import("core/oem.zig");
const intf = @import("intf/intf.zig");

test "all native header declarations are usable without the bridge" {
    std.testing.refAllDecls(ipmi);
    std.testing.refAllDecls(oem);
    std.testing.refAllDecls(intf);
}

test "native enum storage and unknown wire values" {
    inline for (.{ ipmi.Oem, intf.LanplusSessionState, intf.CipherSuiteId }) |T| {
        try std.testing.expectEqual(c_uint, @typeInfo(T).@"enum".tag_type);
        try std.testing.expectEqual(@sizeOf(c_uint), @sizeOf(T));
        try std.testing.expectEqual(@alignOf(c_uint), @alignOf(T));
        const unknown: T = @enumFromInt(0xfedcba98);
        try std.testing.expectEqual(@as(c_uint, 0xfedcba98), @intFromEnum(unknown));
    }
    try std.testing.expectEqual(@as(u8, 0x15), @intFromEnum(ipmi.PayloadType.rakp_4));
    try std.testing.expectEqual(@as(c_uint, 15000), @intFromEnum(ipmi.Oem.kontron));
    try std.testing.expectEqual(@as(c_uint, 6), @intFromEnum(intf.LanplusSessionState.active));
    try std.testing.expectEqual(@as(c_uint, 0xff), @intFromEnum(intf.CipherSuiteId.reserved));
    try std.testing.expectEqual(@as(c_uint, 17), @intFromEnum(@as(intf.CipherSuiteId, @enumFromInt(17))));
}

test "native request bitfield exhaustively roundtrips wire bytes" {
    for (0..64) |netfn| {
        for (0..4) |lun| {
            var request = std.mem.zeroes(ipmi.Request);
            request.msg.netfn_lun = .{ .netfn = @intCast(netfn), .lun = @intCast(lun) };
            request.msg.cmd = 0x37;
            const expected: u8 = @intCast(switch (builtin.cpu.arch.endian()) {
                .little => netfn | (lun << 6),
                .big => (netfn << 2) | lun,
            });
            const bytes = std.mem.asBytes(&request);
            try std.testing.expectEqual(expected, bytes[0]);
            try std.testing.expectEqual(@as(u8, 0x37), bytes[1]);
            const decoded: ipmi.NetFnLun = @bitCast(expected);
            try std.testing.expectEqual(netfn, decoded.netfn);
            try std.testing.expectEqual(lun, decoded.lun);
        }
    }
}

test "native request response and callback layouts" {
    const pointer_size = @sizeOf(usize);
    const wide = pointer_size == 8;
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(ipmi.NetFnLun));
    try std.testing.expectEqual(@as(usize, 8) + pointer_size, @sizeOf(ipmi.Request));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(ipmi.Request.Msg, "cmd"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(ipmi.Request.Msg, "target_cmd"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(ipmi.Request.Msg, "data_len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ipmi.Request.Msg, "data"));
    try std.testing.expectEqual(@as(usize, if (wide) 56 else 36), @sizeOf(ipmi.RequestEntry));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ipmi.Response.Msg));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(ipmi.Response.Session));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(ipmi.Response.Payload));
    try std.testing.expectEqual(@as(usize, 1128), @sizeOf(ipmi.Response));
    try std.testing.expectEqual(@as(usize, 1028), @offsetOf(ipmi.Response, "data_len"));
    try std.testing.expectEqual(@as(usize, 1056), @offsetOf(ipmi.Response, "payload"));
    try std.testing.expectEqual(@as(usize, if (wide) 1048 else 1040), @sizeOf(ipmi.V2Payload));
    try std.testing.expectEqual(pointer_size, @offsetOf(ipmi.V2Payload, "payload"));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(intf.CipherSuiteInfo));
    try std.testing.expectEqual(3 * pointer_size, @sizeOf(oem.OemHandle));
    try std.testing.expectEqual(3 * pointer_size, @sizeOf(intf.Cmd));
    try std.testing.expectEqual(@as(usize, if (wide) 416 else 352), @sizeOf(intf.Intf));
    try std.testing.expectEqual(@as(usize, if (wide) 336 else 312), @offsetOf(intf.Intf, "setup"));
    try std.testing.expectEqual(pointer_size, @sizeOf(@FieldType(intf.Intf, "sendrecv")));
}

test "native Linux session socket storage layout" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(intf.SockAddrStorage));
    try std.testing.expectEqual(@alignOf(c_ulong), @alignOf(intf.SockAddrStorage));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(intf.SockAddrStorage, "family"));
    try std.testing.expectEqual(@as(usize, 192), @sizeOf(intf.Session.V2Data));
    const wide = @sizeOf(usize) == 8;
    try std.testing.expectEqual(@as(usize, if (wide) 64 else 60), @offsetOf(intf.Session, "addr"));
    try std.testing.expectEqual(@as(usize, if (wide) 196 else 192), @offsetOf(intf.Session, "v2_data"));
    try std.testing.expectEqual(@as(usize, if (wide) 416 else 400), @sizeOf(intf.Session));
    try std.testing.expectEqual(@as(usize, if (wide) 96 else 92), @sizeOf(intf.SessionParams));

    var storage = std.mem.zeroes(intf.SockAddrStorage);
    const ipv4: *std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
    ipv4.* = std.mem.zeroes(std.posix.sockaddr.in);
    ipv4.family = std.posix.AF.INET;
    ipv4.port = std.mem.nativeToBig(u16, 623);
    try std.testing.expectEqual(std.posix.AF.INET, storage.family);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x6f }, std.mem.asBytes(&storage)[2..4]);
    const ipv6: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
    ipv6.* = std.mem.zeroes(std.posix.sockaddr.in6);
    ipv6.family = std.posix.AF.INET6;
    ipv6.addr[15] = 1;
    try std.testing.expectEqual(std.posix.AF.INET6, storage.family);
    try std.testing.expectEqual(@as(u8, 1), std.mem.asBytes(&storage)[23]);
}
