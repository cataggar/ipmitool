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
const stdout_io = @import("../util/stdout.zig");

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

fn cString(ptr: [*c]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn equals(arg: [*c]const u8, text: []const u8) bool {
    return std.mem.eql(u8, cString(arg), text);
}

fn isLan(name: *const [16]u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(name, 0), "lan");
}

const SessionOutputError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writeSessionInfo(writer: *std.Io.Writer, csv: bool, info: *const [info_size]u8, length: usize) std.Io.Writer.Error!void {
    var buffer: [18]u8 = undefined;
    const handle: c_int = info[0];
    const slots: c_int = info[1] & 0x3f;
    const active: c_int = info[2] & 0x3f;
    if (csv) {
        try writer.print("{d}", .{handle});
        try writer.print(",{d}", .{slots});
        try writer.print(",{d}", .{active});
        if (length == 3) {
            try writer.writeAll("\n");
            return;
        }
        try writer.print(",{d}", .{info[3] & 0x3f});
        try writer.print(",{s}", .{cString(c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals))});
        const session_type: []const u8 = if ((info[5] & 0xf0) != 0) "IPMIv2/RMCP+" else "IPMIv1.5";
        try writer.print(",{s}", .{session_type});
        try writer.print(",0x{x:0>2}", .{info[5] & 0x0f});
        if (length == 18) {
            try writer.print(",{s}", .{cString(ipAddress(info, channel_offset, &buffer))});
            try writer.print(",{s}", .{cString(c.mac2str(@ptrCast(&info[10])))});
            try writer.print(",{d}", .{port(info)});
        } else if (length == 12 or length == 14) {
            try writer.print(",{s}", .{cString(c.val2str(info[6], c.ipmi_channel_activity_type_vals))});
            try writer.print(",{d}", .{info[7] & 0x0f});
            try writer.print(",{s}", .{cString(ipAddress(info, 8, &buffer))});
            if (length == 14) try writer.print(",{d}", .{port(info)});
        }
        try writer.writeAll("\n");
        return;
    }

    try writer.print("session handle                : {d}\n", .{handle});
    try writer.print("slot count                    : {d}\n", .{slots});
    try writer.print("active sessions               : {d}\n", .{active});
    if (length == 3) {
        try writer.writeAll("\n");
        return;
    }
    try writer.print("user id                       : {d}\n", .{info[3] & 0x3f});
    try writer.print("privilege level               : {s}\n", .{cString(c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals))});
    const session_type: []const u8 = if ((info[5] & 0xf0) != 0) "IPMIv2/RMCP+" else "IPMIv1.5";
    try writer.print("session type                  : {s}\n", .{session_type});
    try writer.print("channel number                : 0x{x:0>2}\n", .{info[5] & 0x0f});
    if (length == 18) {
        try writer.print("console ip                    : {s}\n", .{cString(ipAddress(info, channel_offset, &buffer))});
        try writer.print("console mac                   : {s}\n", .{cString(c.mac2str(@ptrCast(&info[10])))});
        try writer.print("console port                  : {d}\n", .{port(info)});
    } else if (length == 12 or length == 14) {
        try writer.print("Session/Channel Activity Type : {s}\n", .{cString(c.val2str(info[6], c.ipmi_channel_activity_type_vals))});
        try writer.print("Destination selector          : {d}\n", .{info[7] & 0x0f});
        try writer.print("console ip                    : {s}\n", .{cString(ipAddress(info, 8, &buffer))});
        if (length == 14) try writer.print("console port                  : {d}\n", .{port(info)});
    }
    try writer.writeAll("\n");
}

fn emitSessionInfo(writer: *std.Io.Writer, csv: bool, info: *const [info_size]u8, length: usize, preflush: anytype) SessionOutputError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeSessionInfo(writer, csv, info, length) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn printSessionInfo(info: *const [info_size]u8, length: usize) bool {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    emitSessionInfo(&stdout.interface, c.csv_output != 0, info, length, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "Session info stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "Session info stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "Session info stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return false;
    };
    return true;
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
            log.print(log.Level.err, "Get Session Info command failed", .{});
        } else if (rsp.?.ccode != 0) {
            log.print(
                log.Level.err,
                "Get Session Info command failed: %s",
                .{c.val2str(rsp.?.ccode, c.completion_code_vals)},
            );
        } else {
            const len: usize = @intCast(@min(@max(rsp.?.data_len, 0), info_size));
            @memcpy(info[0..len], rsp.?.data[0..len]);
            return if (printSessionInfo(&info, len)) 0 else -1;
        }
        if (request_type == current and !isLan(&intf.name)) {
            log.print(log.Level.err, "It is likely that the channel in use does not support sessions", .{});
        }
        return -1;
    }

    req.msg.data_len = 1;
    var slot: c_int = 1;
    while (true) {
        data[0] = @intCast(slot);
        slot += 1;
        const rsp = intf.sendrecv.?(intf, &req) orelse {
            log.print(log.Level.err, "Get Session Info command failed", .{});
            return -1;
        };
        if (rsp.ccode != 0 and rsp.ccode != 0xcc and rsp.ccode != 0xcb) {
            log.print(log.Level.err, "Get Session Info command failed: %s", .{c.val2str(rsp.ccode, c.completion_code_vals)});
            return -1;
        }
        if (rsp.data_len < 3) return -1;
        const len: usize = @intCast(@min(rsp.data_len, info_size));
        @memcpy(info[0..len], rsp.data[0..len]);
        if (!printSessionInfo(&info, len)) return -1;
        if (slot > @as(c_int, info[1] & 0x3f)) return 0;
    }
}

fn usage() void {
    log.print(log.Level.notice, "Session Commands: info <active | all | id 0xnnnnnnnn | handle 0xnn>", .{});
}

fn main(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    if (argc == 0 or equals(argv[0], "help")) {
        usage();
        return 0;
    }
    if (!equals(argv[0], "info")) {
        log.print(log.Level.err, "Invalid SESSION command: %s", .{argv[0]});
        usage();
        return -1;
    }
    if (argc < 2 or equals(argv[1], "help")) {
        usage();
        return 0;
    }
    var request_type: c_int = current;
    var value: u32 = 0;
    if (equals(argv[1], "active")) {
        request_type = current;
    } else if (equals(argv[1], "all")) {
        request_type = all;
    } else if (equals(argv[1], "id") or equals(argv[1], "handle")) {
        const id = equals(argv[1], "id");
        if (argc < 3) {
            log.print(log.Level.err, if (id) "Missing id argument" else "Missing handle argument", .{});
            usage();
            return -1;
        }
        request_type = if (id) by_id else by_handle;
        if (c.str2uint(argv[2], &value) != 0) {
            log.print(log.Level.err, "HEX number expected, but '%s' given.", .{argv[2]});
            usage();
            return -1;
        }
    } else {
        log.print(log.Level.err, "Invalid SESSION info parameter: %s", .{argv[1]});
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

test "session command and interface names match libc equality" {
    const words = [_][*:0]const u8{ "help", "info", "active", "all", "id", "handle" };
    for (words) |word| {
        const text = std.mem.span(word);
        for (0..256) |byte| {
            var arg = [_:0]u8{ @intCast(byte), 'e', 'l', 'p', 0, 'x' };
            try std.testing.expectEqual(c.strcmp(&arg, word) == 0, equals(&arg, text));
        }
        try std.testing.expect(equals(word, text));
        var longer: [32:0]u8 = @splat(0);
        @memcpy(longer[0..text.len], text);
        longer[text.len] = 'x';
        try std.testing.expectEqual(c.strcmp(&longer, word) == 0, equals(&longer, text));
    }
    const names = [_][]const u8{ "", "lan", "LAN", "lanplus", "lan\x00plus", "lanx" };
    for (names) |text| {
        var name: [16]u8 = @splat(0);
        @memcpy(name[0..text.len], text);
        try std.testing.expectEqual(c.strcmp(&name, "lan") == 0, isLan(&name));
    }
    const unterminated: [16]u8 = @splat('l');
    try std.testing.expect(!isLan(&unterminated));
}

test "session info stdout matches C boundary formatting in csv and human modes" {
    const cases = [_]struct { bytes: []const u8, length: usize }{
        .{ .bytes = &.{ 255, 255, 255 }, .length = 3 },
        .{ .bytes = &.{ 0, 0x40, 0xc0, 0xff, 0x8e, 0x8f, 0 }, .length = 7 },
        .{ .bytes = &.{ 63, 0xbf, 0xfe, 0x7e, 0x84, 0x1f, 0xff, 0x9f, 255, 254, 128, 1 }, .length = 12 },
        .{ .bytes = &.{ 63, 0xbf, 0xfe, 0x7e, 0x84, 0x1f, 0xff, 0x9f, 255, 254, 128, 1, 0xff, 0xff }, .length = 14 },
        .{ .bytes = &.{ 63, 0xbf, 0xfe, 0x7e, 0x84, 0x1f, 255, 254, 128, 1, 0, 1, 2, 3, 4, 255, 0xff, 0xff }, .length = 18 },
    };
    for (cases) |case| {
        var info = std.mem.zeroes([info_size]u8);
        @memcpy(info[0..case.length], case.bytes);
        for ([_]bool{ false, true }) |csv| {
            var expected: [512]u8 = undefined;
            var address: [18]u8 = undefined;
            const n = if (case.length == 3)
                if (csv)
                    c.snprintf(&expected, expected.len, "%d,%d,%d\n", @as(c_int, info[0]), @as(c_int, info[1] & 0x3f), @as(c_int, info[2] & 0x3f))
                else
                    c.snprintf(
                        &expected,
                        expected.len,
                        "session handle                : %d\n" ++
                            "slot count                    : %d\n" ++
                            "active sessions               : %d\n\n",
                        @as(c_int, info[0]),
                        @as(c_int, info[1] & 0x3f),
                        @as(c_int, info[2] & 0x3f),
                    )
            else blk: {
                // Build the C oracle a field at a time: val2str's unknown-value
                // fallback uses a shared buffer which the next lookup overwrites.
                var cursor: usize = 0;
                const prefix = if (csv)
                    c.snprintf(
                        &expected,
                        expected.len,
                        "%d,%d,%d,%d,%s,%s,0x%02x",
                        @as(c_int, info[0]),
                        @as(c_int, info[1] & 0x3f),
                        @as(c_int, info[2] & 0x3f),
                        @as(c_int, info[3] & 0x3f),
                        c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals),
                        @as([*:0]const u8, if (info[5] & 0xf0 != 0) "IPMIv2/RMCP+" else "IPMIv1.5"),
                        @as(c_uint, info[5] & 0x0f),
                    )
                else
                    c.snprintf(
                        &expected,
                        expected.len,
                        "session handle                : %d\n" ++
                            "slot count                    : %d\n" ++
                            "active sessions               : %d\n" ++
                            "user id                       : %d\n" ++
                            "privilege level               : %s\n" ++
                            "session type                  : %s\n" ++
                            "channel number                : 0x%02x\n",
                        @as(c_int, info[0]),
                        @as(c_int, info[1] & 0x3f),
                        @as(c_int, info[2] & 0x3f),
                        @as(c_int, info[3] & 0x3f),
                        c.val2str(info[4] & 0x0f, c.ipmi_privlvl_vals),
                        @as([*:0]const u8, if (info[5] & 0xf0 != 0) "IPMIv2/RMCP+" else "IPMIv1.5"),
                        @as(c_uint, info[5] & 0x0f),
                    );
                try std.testing.expect(prefix >= 0 and prefix < expected.len);
                cursor = @intCast(prefix);
                if (case.length == 18) {
                    const suffix = if (csv)
                        c.snprintf(
                            expected[cursor..].ptr,
                            expected.len - cursor,
                            ",%s,%s,%d",
                            ipAddress(&info, channel_offset, &address),
                            c.mac2str(@ptrCast(&info[10])),
                            port(&info),
                        )
                    else
                        c.snprintf(
                            expected[cursor..].ptr,
                            expected.len - cursor,
                            "console ip                    : %s\n" ++
                                "console mac                   : %s\n" ++
                                "console port                  : %d\n",
                            ipAddress(&info, channel_offset, &address),
                            c.mac2str(@ptrCast(&info[10])),
                            port(&info),
                        );
                    try std.testing.expect(suffix >= 0 and suffix < expected.len - cursor);
                    cursor += @intCast(suffix);
                } else if (case.length == 12 or case.length == 14) {
                    const suffix = if (csv)
                        c.snprintf(
                            expected[cursor..].ptr,
                            expected.len - cursor,
                            if (case.length == 14) ",%s,%d,%s,%d" else ",%s,%d,%s",
                            c.val2str(info[6], c.ipmi_channel_activity_type_vals),
                            @as(c_int, info[7] & 0x0f),
                            ipAddress(&info, 8, &address),
                            port(&info),
                        )
                    else
                        c.snprintf(
                            expected[cursor..].ptr,
                            expected.len - cursor,
                            if (case.length == 14)
                                "Session/Channel Activity Type : %s\n" ++
                                    "Destination selector          : %d\n" ++
                                    "console ip                    : %s\n" ++
                                    "console port                  : %d\n"
                            else
                                "Session/Channel Activity Type : %s\n" ++
                                    "Destination selector          : %d\n" ++
                                    "console ip                    : %s\n",
                            c.val2str(info[6], c.ipmi_channel_activity_type_vals),
                            @as(c_int, info[7] & 0x0f),
                            ipAddress(&info, 8, &address),
                            port(&info),
                        );
                    try std.testing.expect(suffix >= 0 and suffix < expected.len - cursor);
                    cursor += @intCast(suffix);
                }
                expected[cursor] = '\n';
                break :blk @as(c_int, @intCast(cursor + 1));
            };
            try std.testing.expect(n >= 0 and n < expected.len);
            var actual: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&actual);
            try writeSessionInfo(&writer, csv, &info, case.length);
            try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
        }
    }
}

test "session info stdout propagates preflush, early, late and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var info = std.mem.zeroes([info_size]u8);
    info[0] = 2;
    info[1] = 4;
    info[2] = 1;
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitSessionInfo(&writer, false, &info, 3, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitSessionInfo(&early, true, &info, 3, Stub.preflushOk));

    const prefix = "session handle                : 2\nslot count                    : 4\n";
    var short: [prefix.len]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitSessionInfo(&late, false, &info, 3, Stub.preflushOk));
    try std.testing.expectEqualStrings(prefix, late.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitSessionInfo(&writer, true, &info, 3, Stub.preflushOk));
    try std.testing.expectEqualStrings("2,4,1\n", writer.buffered());
}

test "session info stdout orders buffered C before Zig and subsequent C" {
    const stdout_fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved_fd = c.dup(stdout_fd);
    try std.testing.expect(saved_fd >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved_fd, stdout_fd);
        _ = c.close(saved_fd);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(stdout_fd, c.dup2(fds[1], stdout_fd));
    _ = c.close(fds[1]);

    var info = std.mem.zeroes([info_size]u8);
    info[0] = 2;
    info[1] = 4;
    info[2] = 1;
    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitSessionInfo(&stdout.interface, true, &info, 3, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    _ = c.printf("before human|");
    var human = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitSessionInfo(&human.interface, false, &info, 3, stdout_io.trySyncC);
    _ = c.printf("|after human\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(stdout_fd, c.dup2(saved_fd, stdout_fd));

    var captured: [512]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings(
        "before|2,4,1\n|after\n" ++
            "before human|session handle                : 2\n" ++
            "slot count                    : 4\n" ++
            "active sessions               : 1\n\n|after human\n",
        captured[0..@intCast(length)],
    );
}
