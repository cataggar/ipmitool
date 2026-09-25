//! Get Session Info command (`lib/ipmi_session.c`). This is the CLI query;
//! transport session establishment/teardown is owned by the LAN/LAN+ plugins,
//! not by this translation unit. Request/response buffers are stack-owned and
//! no allocator is needed. A send/parse failure returns -1.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const current = 0;
const all = 1;
const by_id = 2;
const by_handle = 3;
const channel_offset: usize = c.ABI_OFFSETOF_get_session_info_rsp__channel_data;
const info_size: usize = c.ABI_SIZEOF_get_session_info_rsp;

comptime {
    if (channel_offset != 6 or info_size != 18) @compileError("Get Session Info response layout changed");
}

fn port(info: *const [info_size]u8) c_int {
    return @intCast(std.mem.readInt(u16, info[16..18], .little));
}

fn ipAddress(info: *const [info_size]u8, offset: usize, buffer: *[18]u8) [*c]const u8 {
    return c.inet_ntop(c.AF_INET, @ptrCast(&info[offset]), buffer, 16);
}

fn printSessionInfo(info: *const [info_size]u8, length: usize) void {
    var buffer: [18]u8 = undefined;
    const handle: c_int = info[0];
    const slots: c_int = info[1] & 0x3f;
    const active: c_int = info[2] & 0x3f;
    if (c.csv_output != 0) {
        _ = c.printf("%d", handle);
        _ = c.printf(",%d", slots);
        _ = c.printf(",%d", active);
        if (length == 3) {
            _ = c.printf("\n");
            return;
        }
        _ = c.printf(",%d", @as(c_int, info[3] & 0x3f));
        _ = c.printf(",%s", c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals));
        const session_type: [*:0]const u8 = if ((info[5] & 0xf0) != 0) "IPMIv2/RMCP+" else "IPMIv1.5";
        _ = c.printf(",%s", session_type);
        _ = c.printf(",0x%02x", @as(c_uint, info[5] & 0x0f));
        if (length == 18) {
            _ = c.printf(",%s", ipAddress(info, channel_offset, &buffer));
            _ = c.printf(",%s", c.mac2str(@ptrCast(&info[10])));
            _ = c.printf(",%d", port(info));
        } else if (length == 12 or length == 14) {
            _ = c.printf(",%s", c.val2str(info[6], c.ipmi_channel_activity_type_vals));
            _ = c.printf(",%d", @as(c_int, info[7] & 0x0f));
            _ = c.printf(",%s", ipAddress(info, 8, &buffer));
            if (length == 14) _ = c.printf(",%d", port(info));
        }
        _ = c.printf("\n");
        return;
    }

    _ = c.printf("session handle                : %d\n", handle);
    _ = c.printf("slot count                    : %d\n", slots);
    _ = c.printf("active sessions               : %d\n", active);
    if (length == 3) {
        _ = c.printf("\n");
        return;
    }
    _ = c.printf("user id                       : %d\n", @as(c_int, info[3] & 0x3f));
    _ = c.printf("privilege level               : %s\n", c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals));
    const session_type: [*:0]const u8 = if ((info[5] & 0xf0) != 0) "IPMIv2/RMCP+" else "IPMIv1.5";
    _ = c.printf("session type                  : %s\n", session_type);
    _ = c.printf("channel number                : 0x%02x\n", @as(c_uint, info[5] & 0x0f));
    if (length == 18) {
        _ = c.printf("console ip                    : %s\n", ipAddress(info, channel_offset, &buffer));
        _ = c.printf("console mac                   : %s\n", c.mac2str(@ptrCast(&info[10])));
        _ = c.printf("console port                  : %d\n", port(info));
    } else if (length == 12 or length == 14) {
        _ = c.printf(
            "Session/Channel Activity Type : %s\n",
            c.val2str(info[6], c.ipmi_channel_activity_type_vals),
        );
        _ = c.printf("Destination selector          : %d\n", @as(c_int, info[7] & 0x0f));
        _ = c.printf("console ip                    : %s\n", ipAddress(info, 8, &buffer));
        if (length == 14) _ = c.printf("console port                  : %d\n", port(info));
    }
    _ = c.printf("\n");
}

fn getSessionInfo(intf: *Intf, request_type: c_int, id_or_handle: u32) callconv(.c) c_int {
    var req = std.mem.zeroes(ipmi.Request);
    var data: [5]u8 = undefined;
    var info = std.mem.zeroes([info_size]u8);
    req.msg.netfn_lun = .{ .netfn = @intCast(c.IPMI_NETFN_APP), .lun = 0 };
    req.msg.cmd = c.IPMI_GET_SESSION_INFO;
    req.msg.data = &data;

    if (request_type != all) {
        switch (request_type) {
            current => {
                data[0] = 0;
                req.msg.data_len = 1;
            },
            by_id => {
                data[0] = 0xff;
                std.mem.writeInt(u32, data[1..5], id_or_handle, .little);
                req.msg.data_len = 5;
            },
            by_handle => {
                data[0] = 0xfe;
                data[1] = @truncate(id_or_handle);
                req.msg.data_len = 2;
            },
            else => return 0,
        }
        const rsp = intf.sendrecv.?(intf, &req);
        if (rsp == null) {
            c.lprintf(log.Level.err, "Get Session Info command failed");
        } else if (rsp.?.ccode != 0) {
            c.lprintf(
                log.Level.err,
                "Get Session Info command failed: %s",
                c.val2str(rsp.?.ccode, c.completion_code_vals),
            );
        } else {
            const len: usize = @intCast(@min(@max(rsp.?.data_len, 0), info_size));
            @memcpy(info[0..len], rsp.?.data[0..len]);
            printSessionInfo(&info, len);
            return 0;
        }
        if (request_type == current and c.strcmp(@ptrCast(&intf.name), "lan") != 0) {
            c.lprintf(log.Level.err, "It is likely that the channel in use does not support sessions");
        }
        return -1;
    }

    req.msg.data_len = 1;
    var slot: c_int = 1;
    while (true) {
        data[0] = @intCast(slot);
        slot += 1;
        const rsp = intf.sendrecv.?(intf, &req) orelse {
            c.lprintf(log.Level.err, "Get Session Info command failed");
            return -1;
        };
        if (rsp.ccode != 0 and rsp.ccode != 0xcc and rsp.ccode != 0xcb) {
            c.lprintf(log.Level.err, "Get Session Info command failed: %s", c.val2str(rsp.ccode, c.completion_code_vals));
            return -1;
        }
        if (rsp.data_len < 3) return -1;
        const len: usize = @intCast(@min(rsp.data_len, info_size));
        @memcpy(info[0..len], rsp.data[0..len]);
        printSessionInfo(&info, len);
        if (slot > @as(c_int, info[1] & 0x3f)) return 0;
    }
}

fn usage() void {
    c.lprintf(log.Level.notice, "Session Commands: info <active | all | id 0xnnnnnnnn | handle 0xnn>");
}

fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc == 0 or c.strcmp(argv[0], "help") == 0) {
        usage();
        return 0;
    }
    if (c.strcmp(argv[0], "info") != 0) {
        c.lprintf(log.Level.err, "Invalid SESSION command: %s", argv[0]);
        usage();
        return -1;
    }
    if (argc < 2 or c.strcmp(argv[1], "help") == 0) {
        usage();
        return 0;
    }
    var request_type: c_int = current;
    var value: u32 = 0;
    if (c.strcmp(argv[1], "active") == 0) {
        request_type = current;
    } else if (c.strcmp(argv[1], "all") == 0) {
        request_type = all;
    } else if (c.strcmp(argv[1], "id") == 0 or c.strcmp(argv[1], "handle") == 0) {
        const id = c.strcmp(argv[1], "id") == 0;
        if (argc < 3) {
            c.lprintf(log.Level.err, if (id) "Missing id argument" else "Missing handle argument");
            usage();
            return -1;
        }
        request_type = if (id) by_id else by_handle;
        if (c.str2uint(argv[2], &value) != 0) {
            c.lprintf(log.Level.err, "HEX number expected, but '%s' given.", argv[2]);
            usage();
            return -1;
        }
    } else {
        c.lprintf(log.Level.err, "Invalid SESSION info parameter: %s", argv[1]);
        usage();
        return -1;
    }
    return getSessionInfo(intf, request_type, value);
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(getSessionInfo), @TypeOf(c.ipmi_get_session_info));
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_session_main));
    @export(&getSessionInfo, .{ .name = "ipmi_get_session_info", .linkage = .strong });
    @export(&main, .{ .name = "ipmi_session_main", .linkage = .strong });
}
