//! Serial over LAN command and interactive session, selected by
//! `zig build -Dzig-modules=sol` in place of lib/ipmi_sol.c.
//! The request/response and payload types are shared ABI-checked Zig mirrors;
//! libc still handles terminal control and binary SOL payload bytes; SOL
//! interactive text, payload-access status and info use checked Zig stdout.
//! Diagnostics use typed `log.print()` from the same selected archive as the
//! logger state; without the Zig logger it retains the C `lprintf` fallback.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const stdout_io = @import("../util/stdout.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const Session = @import("../intf/intf.zig").Session;
const Request = ipmi.Request;
const Response = ipmi.Response;
const Config = c.struct_sol_config_parameters;

const param_names = [_][*:0]const u8{
    "Set In Progress (0)",
    "Enable (1)",
    "Authentication (2)",
    "Character Interval (3)",
    "Retry (4)",
    "Nonvolatile Bitrate (5)",
    "Volatile Bitrate (6)",
    "Payload Channel (7)",
    "Payload Port (8)",
};

pub const sol_parameter_vals: [10]c.struct_valstr = blk: {
    var table: [10]c.struct_valstr = undefined;
    for (param_names, 0..) |label, i| table[i] = .{ .val = @intCast(i), .str = label };
    table[9] = .{ .val = 0, .str = null };
    break :blk table;
};

var saved_tio: c.struct_termios = undefined;
var in_raw_mode = false;
var disable_keepalive = false;
var use_sol_keepalive = false;
var keepalive_start: c.struct_timeval = undefined;

fn eql(s: [*:0]const u8, value: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), value);
}

fn choose(yes: bool, a: [*:0]const u8, b: [*:0]const u8) [*:0]const u8 {
    return if (yes) a else b;
}

fn cc(code: u8) [*c]const u8 {
    return c.val2str(code, c.completion_code_vals);
}

fn name(index: usize) [*c]const u8 {
    return c.val2str(@intCast(index), &sol_parameter_vals);
}

fn reqWithData(netfn: u6, command: u8, bytes: []u8) Request {
    var req = std.mem.zeroes(Request);
    req.msg.netfn_lun = .{ .netfn = netfn, .lun = 0 };
    req.msg.cmd = command;
    req.msg.data = bytes.ptr;
    req.msg.data_len = @intCast(bytes.len);
    return req;
}

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    return if (intf.sendrecv) |send| send(intf, req) else null;
}

fn payloadAccess(intf: *Intf, channel: u8, userid: u8, enable: c_int) callconv(.c) c_int {
    var data = [6]u8{ channel & 0x0f, (userid & 0x3f) | (if (enable == 0) @as(u8, 0x40) else 0), 2, 0, 0, 0 };
    var req = reqWithData(ipmi.NetFn.app, 0x4c, &data);
    const rsp = sendrecv(intf, &req);
    if (rsp == null) {
        log.print(log.Level.err, "Error %sabling SOL payload for user %d on channel %d", .{ choose(enable != 0, "en", "dis"), @as(c_int, userid), @as(c_int, channel) });
        return -1;
    }
    if (rsp.?.ccode != 0) {
        log.print(log.Level.err, "Error %sabling SOL payload for user %d on channel %d: %s", .{ choose(enable != 0, "en", "dis"), @as(c_int, userid), @as(c_int, channel), cc(rsp.?.ccode) });
        return -1;
    }
    return 0;
}

const StdoutError = error{ CStdoutFlushFailed, StdoutWriteFailed, StdoutFlushFailed };

fn writePayloadStatus(writer: *std.Io.Writer, channel: u8, userid: u8, enabled: bool) std.Io.Writer.Error!void {
    try writer.print("User {d} on channel {d} is {s}\n", .{
        userid, channel, if (enabled) "enabled" else "disabled",
    });
}

fn emitPayloadStatus(writer: *std.Io.Writer, channel: u8, userid: u8, enabled: bool, preflush: anytype) StdoutError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writePayloadStatus(writer, channel, userid, enabled) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn payloadAccessStatus(intf: *Intf, channel: u8, userid: u8) callconv(.c) c_int {
    var data = [2]u8{ channel & 0x0f, userid & 0x3f };
    var req = reqWithData(ipmi.NetFn.app, 0x4d, &data);
    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error. No valid response received.", .{});
        return -1;
    };
    if (rsp.ccode == 0) {
        if (rsp.data_len != 4) {
            log.print(log.Level.err, "Error parsing SOL payload status for user %d on channel %d", .{ @as(c_int, userid), @as(c_int, channel) });
            return -1;
        }
        var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
        emitPayloadStatus(&stdout.interface, channel, userid, rsp.data[0] & 2 != 0, stdout_io.trySyncC) catch |err| {
            switch (err) {
                error.CStdoutFlushFailed => log.print(log.Level.err, "SOL payload status stdout C preflush failed (errno %d)", .{std.c._errno().*}),
                error.StdoutWriteFailed => log.print(log.Level.err, "SOL payload status stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
                error.StdoutFlushFailed => log.print(log.Level.err, "SOL payload status stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            }
            return -1;
        };
        return 0;
    }
    log.print(log.Level.err, "Error getting SOL payload status for user %d on channel %d: %s", .{ @as(c_int, userid), @as(c_int, channel), cc(rsp.ccode) });
    return -1;
}

test "payload status stdout matches C enabled and disabled formatting" {
    const cases = [_]struct { channel: u8, userid: u8, enabled: bool }{
        .{ .channel = 0, .userid = 0, .enabled = false },
        .{ .channel = 4, .userid = 2, .enabled = true },
        .{ .channel = 15, .userid = 63, .enabled = false },
        .{ .channel = 255, .userid = 255, .enabled = true },
    };
    for (cases) |case| {
        var expected: [96]u8 = undefined;
        const n = c.snprintf(
            &expected,
            expected.len,
            "User %d on channel %d is %sabled\n",
            @as(c_int, case.userid),
            @as(c_int, case.channel),
            @as([*:0]const u8, if (case.enabled) "en" else "dis"),
        );
        try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < expected.len);
        var actual: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&actual);
        try writePayloadStatus(&writer, case.channel, case.userid, case.enabled);
        try std.testing.expectEqualSlices(u8, expected[0..@intCast(n)], writer.buffered());
    }
}

test "payload status stdout detects preflush, early, late and final flush errors" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var storage: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, emitPayloadStatus(&writer, 4, 2, true, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitPayloadStatus(&early, 4, 2, true, Stub.preflushOk));

    const line = "User 2 on channel 4 is enabled\n";
    var short: [line.len - 1]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitPayloadStatus(&late, 4, 2, true, Stub.preflushOk));
    try std.testing.expectEqualStrings(line[0 .. line.len - 1], late.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitPayloadStatus(&writer, 4, 2, true, Stub.preflushOk));
    try std.testing.expectEqualStrings(line, writer.buffered());
}

test "payload status stdout preserves buffered C ordering" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitPayloadStatus(&stdout.interface, 4, 2, false, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));

    var captured: [96]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings("before|User 2 on channel 4 is disabled\n|after\n", captured[0..@intCast(length)]);
}

fn getSolInfo(intf: *Intf, channel: u8, params: *Config) callconv(.c) c_int {
    var data = [4]u8{ channel, 0, 0, 0 };
    var req = reqWithData(ipmi.NetFn.transport, 0x22, &data);
    for (0..9) |i| {
        data[1] = @intCast(i);
        const rsp = sendrecv(intf, &req) orelse {
            log.print(log.Level.err, "Error: No response requesting SOL parameter '%s'", .{name(i)});
            return -1;
        };
        switch (rsp.ccode) {
            0 => {
                const expected: c_int = if (i == 3 or i == 4 or i == 8) 3 else 2;
                if (rsp.data_len != expected) {
                    log.print(log.Level.err, "Error: Unexpected data length (%d) received for SOL parameter '%s'", .{ rsp.data_len, name(i) });
                    continue;
                }
                switch (i) {
                    0 => params.set_in_progress = rsp.data[1],
                    1 => params.enabled = rsp.data[1],
                    2 => {
                        params.force_encryption = @intFromBool(rsp.data[1] & 0x80 != 0);
                        params.force_authentication = @intFromBool(rsp.data[1] & 0x40 != 0);
                        params.privilege_level = rsp.data[1] & 0x0f;
                    },
                    3 => {
                        params.character_accumulate_level = rsp.data[1];
                        params.character_send_threshold = rsp.data[2];
                    },
                    4 => {
                        params.retry_count = rsp.data[1];
                        params.retry_interval = rsp.data[2];
                    },
                    5 => params.non_volatile_bit_rate = rsp.data[1] & 0x0f,
                    6 => params.volatile_bit_rate = rsp.data[1] & 0x0f,
                    7 => params.payload_channel = rsp.data[1],
                    8 => params.payload_port = @as(u16, rsp.data[1]) | @as(u16, rsp.data[2]) << 8,
                    else => unreachable,
                }
            },
            0x80 => {
                if (i == 7) {
                    log.print(log.Level.err, "Info: SOL parameter '%s' not supported - defaulting to 0x%02x", .{ name(i), @as(c_uint, channel) });
                    params.payload_channel = channel;
                } else if (i == 8) {
                    if (intf.session == null) {
                        log.print(log.Level.err, "Info: SOL parameter '%s' not supported - can't determine which payload port to use on NULL session", .{name(i)});
                        return -1;
                    }
                    log.print(log.Level.err, "Info: SOL parameter '%s' not supported - defaulting to %d", .{ name(i), intf.ssn_params.port });
                    params.payload_port = @truncate(@as(c_uint, @bitCast(intf.ssn_params.port)));
                } else log.print(log.Level.err, "Info: SOL parameter '%s' not supported", .{name(i)});
            },
            else => {
                log.print(log.Level.err, "Error requesting SOL parameter '%s': %s", .{ name(i), cc(rsp.ccode) });
                return -1;
            },
        }
    }
    return 0;
}

const InfoField = enum { progress, privilege, bit_rate };

fn infoValue(field: InfoField, value: u8) []const u8 {
    const table = switch (field) {
        .progress => c.ipmi_set_in_progress_vals,
        .privilege => c.ipmi_privlvl_vals,
        .bit_rate => c.ipmi_bit_rate_vals,
    };
    return std.mem.span(@as([*:0]const u8, @ptrCast(c.val2str(value, table))));
}

fn writeSolInfo(writer: *std.Io.Writer, csv: bool, p: Config, lookup: anytype) std.Io.Writer.Error!void {
    const enabled: []const u8 = if (p.enabled != 0) "true" else "false";
    const encryption: []const u8 = if (p.force_encryption != 0) "true" else "false";
    if (csv) {
        try writer.print("{s},", .{lookup(.progress, p.set_in_progress & 3)});
        // The original CSV printer repeats encryption instead of authentication.
        try writer.print("{s},{s},{s},", .{ enabled, encryption, encryption });
        try writer.print("{s},", .{lookup(.privilege, p.privilege_level)});
        try writer.print("{d},{d},{d},{d},", .{ @as(c_int, p.character_accumulate_level) * 5, p.character_send_threshold, p.retry_count, @as(c_int, p.retry_interval) * 10 });
        try writer.print("{s},", .{lookup(.bit_rate, p.volatile_bit_rate)});
        try writer.print("{s},", .{lookup(.bit_rate, p.non_volatile_bit_rate)});
        try writer.print("{d},{d}\n", .{ p.payload_channel, p.payload_port });
    } else {
        try writer.print("Set in progress                 : {s}\n", .{lookup(.progress, p.set_in_progress & 3)});
        try writer.print("Enabled                         : {s}\n", .{enabled});
        try writer.print("Force Encryption                : {s}\n", .{encryption});
        try writer.print("Force Authentication            : {s}\n", .{if (p.force_authentication != 0) @as([]const u8, "true") else "false"});
        try writer.print("Privilege Level                 : {s}\n", .{lookup(.privilege, p.privilege_level)});
        try writer.print("Character Accumulate Level (ms) : {d}\n", .{@as(c_int, p.character_accumulate_level) * 5});
        try writer.print("Character Send Threshold        : {d}\n", .{p.character_send_threshold});
        try writer.print("Retry Count                     : {d}\n", .{p.retry_count});
        try writer.print("Retry Interval (ms)             : {d}\n", .{@as(c_int, p.retry_interval) * 10});
        try writer.print("Volatile Bit Rate (kbps)        : {s}\n", .{lookup(.bit_rate, p.volatile_bit_rate)});
        try writer.print("Non-Volatile Bit Rate (kbps)    : {s}\n", .{lookup(.bit_rate, p.non_volatile_bit_rate)});
        try writer.print("Payload Channel                 : {d} (0x{x:0>2})\n", .{ p.payload_channel, p.payload_channel });
        try writer.print("Payload Port                    : {d}\n", .{p.payload_port});
    }
}

fn emitSolInfo(writer: *std.Io.Writer, csv: bool, p: Config, lookup: anytype, preflush: anytype) StdoutError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeSolInfo(writer, csv, p, lookup) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn printSolInfo(intf: *Intf, channel: u8) c_int {
    var p = std.mem.zeroes(Config);
    if (getSolInfo(intf, channel, &p) != 0) return -1;
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    emitSolInfo(&stdout.interface, c.csv_output != 0, p, infoValue, stdout_io.trySyncC) catch |err| {
        switch (err) {
            error.CStdoutFlushFailed => log.print(log.Level.err, "SOL info stdout C preflush failed (errno %d)", .{std.c._errno().*}),
            error.StdoutWriteFailed => log.print(log.Level.err, "SOL info stdout write failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
            error.StdoutFlushFailed => log.print(log.Level.err, "SOL info stdout final flush failed: %s", .{@errorName(stdout.err orelse error.WriteFailed).ptr}),
        }
        return -1;
    };
    return 0;
}

test "sol info stdout matches libc formatting at field boundaries" {
    const Names = struct {
        var progress: [*:0]const u8 = undefined;
        var privilege: [*:0]const u8 = undefined;
        var volatile_rate: [*:0]const u8 = undefined;
        var nonvolatile_rate: [*:0]const u8 = undefined;
        var fields: [4]InfoField = undefined;
        var values: [4]u8 = undefined;
        var count: usize = 0;

        fn get(field: InfoField, value: u8) []const u8 {
            fields[count] = field;
            values[count] = value;
            count += 1;
            const text = switch (field) {
                .progress => progress,
                .privilege => privilege,
                .bit_rate => if (count == 3) volatile_rate else nonvolatile_rate,
            };
            return std.mem.span(text);
        }
    };
    const cases = [_]struct {
        p: Config,
        progress: [*:0]const u8,
        privilege: [*:0]const u8,
        volatile_rate: [*:0]const u8,
        nonvolatile_rate: [*:0]const u8,
    }{
        .{ .p = std.mem.zeroes(Config), .progress = "set-complete", .privilege = "Unknown (0x00)", .volatile_rate = "IPMI-Over-Serial-Setting", .nonvolatile_rate = "IPMI-Over-Serial-Setting" },
        .{ .p = .{
            .set_in_progress = 0xff,
            .enabled = 2,
            .force_encryption = 0,
            .force_authentication = 1,
            .privilege_level = 0xfe,
            .character_accumulate_level = 255,
            .character_send_threshold = 255,
            .retry_count = 255,
            .retry_interval = 255,
            .volatile_bit_rate = 0x0f,
            .non_volatile_bit_rate = 0x05,
            .payload_channel = 255,
            .payload_port = 65535,
        }, .progress = "Unknown (0x03)", .privilege = "Unknown (0xFE)", .volatile_rate = "Unknown (0x0F)", .nonvolatile_rate = "Unknown (0x05)" },
        .{ .p = .{
            .set_in_progress = 2,
            .enabled = 0,
            .force_encryption = 1,
            .force_authentication = 0,
            .privilege_level = 4,
            .character_accumulate_level = 1,
            .character_send_threshold = 1,
            .retry_count = 1,
            .retry_interval = 1,
            .volatile_bit_rate = 10,
            .non_volatile_bit_rate = 7,
            .payload_channel = 10,
            .payload_port = 623,
        }, .progress = "commit-write", .privilege = "ADMINISTRATOR", .volatile_rate = "115.2", .nonvolatile_rate = "19.2" },
        .{ .p = .{ .set_in_progress = 1, .privilege_level = 5, .volatile_bit_rate = 6, .non_volatile_bit_rate = 8 }, .progress = "progress,100% done", .privilege = "OEM", .volatile_rate = "9.6\x00ignored", .nonvolatile_rate = "38.4" },
    };
    for (cases) |case| {
        Names.progress = case.progress;
        Names.privilege = case.privilege;
        Names.volatile_rate = case.volatile_rate;
        Names.nonvolatile_rate = case.nonvolatile_rate;
        const p = case.p;
        const enabled = choose(p.enabled != 0, "true", "false");
        const encryption = choose(p.force_encryption != 0, "true", "false");
        const authentication = choose(p.force_authentication != 0, "true", "false");
        for ([_]bool{ false, true }) |csv| {
            Names.count = 0;
            var expected: [1024]u8 = undefined;
            const length = if (csv)
                c.snprintf(
                    &expected,
                    expected.len,
                    "%s,%s,%s,%s,%s,%d,%d,%d,%d,%s,%s,%d,%d\n",
                    case.progress,
                    enabled,
                    encryption,
                    encryption,
                    case.privilege,
                    @as(c_int, p.character_accumulate_level) * 5,
                    @as(c_int, p.character_send_threshold),
                    @as(c_int, p.retry_count),
                    @as(c_int, p.retry_interval) * 10,
                    case.volatile_rate,
                    case.nonvolatile_rate,
                    @as(c_int, p.payload_channel),
                    @as(c_int, p.payload_port),
                )
            else
                c.snprintf(
                    &expected,
                    expected.len,
                    "Set in progress                 : %s\n" ++
                        "Enabled                         : %s\n" ++
                        "Force Encryption                : %s\n" ++
                        "Force Authentication            : %s\n" ++
                        "Privilege Level                 : %s\n" ++
                        "Character Accumulate Level (ms) : %d\n" ++
                        "Character Send Threshold        : %d\n" ++
                        "Retry Count                     : %d\n" ++
                        "Retry Interval (ms)             : %d\n" ++
                        "Volatile Bit Rate (kbps)        : %s\n" ++
                        "Non-Volatile Bit Rate (kbps)    : %s\n" ++
                        "Payload Channel                 : %d (0x%02x)\n" ++
                        "Payload Port                    : %d\n",
                    case.progress,
                    enabled,
                    encryption,
                    authentication,
                    case.privilege,
                    @as(c_int, p.character_accumulate_level) * 5,
                    @as(c_int, p.character_send_threshold),
                    @as(c_int, p.retry_count),
                    @as(c_int, p.retry_interval) * 10,
                    case.volatile_rate,
                    case.nonvolatile_rate,
                    @as(c_int, p.payload_channel),
                    @as(c_uint, p.payload_channel),
                    @as(c_int, p.payload_port),
                );
            try std.testing.expect(length >= 0 and length < expected.len);
            var actual: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&actual);
            try writeSolInfo(&writer, csv, p, Names.get);
            try std.testing.expectEqualSlices(u8, expected[0..@intCast(length)], writer.buffered());
            try std.testing.expectEqual(@as(usize, 4), Names.count);
            try std.testing.expectEqualSlices(InfoField, &.{ .progress, .privilege, .bit_rate, .bit_rate }, &Names.fields);
            try std.testing.expectEqualSlices(u8, &.{ p.set_in_progress & 3, p.privilege_level, p.volatile_bit_rate, p.non_volatile_bit_rate }, &Names.values);
        }
    }
}

test "sol info stdout consumes shared val2str unknown fallback before next lookup" {
    const Shared = struct {
        var text: [32]u8 = undefined;
        fn get(_: InfoField, value: u8) []const u8 {
            const length = c.snprintf(&text, text.len, "Unknown (0x%02X)", @as(c_uint, value));
            std.debug.assert(length > 0 and length < text.len);
            return text[0..@intCast(length)];
        }
    };
    const p: Config = .{
        .set_in_progress = 3,
        .privilege_level = 0x0e,
        .volatile_bit_rate = 0x05,
        .non_volatile_bit_rate = 0x0f,
    };
    for ([_]bool{ false, true }) |csv| {
        var storage: [640]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try writeSolInfo(&writer, csv, p, Shared.get);
        try std.testing.expectEqualStrings(
            if (csv)
                "Unknown (0x03),false,false,false,Unknown (0x0E),0,0,0,0,Unknown (0x05),Unknown (0x0F),0,0\n"
            else
                "Set in progress                 : Unknown (0x03)\n" ++
                    "Enabled                         : false\n" ++
                    "Force Encryption                : false\n" ++
                    "Force Authentication            : false\n" ++
                    "Privilege Level                 : Unknown (0x0E)\n" ++
                    "Character Accumulate Level (ms) : 0\n" ++
                    "Character Send Threshold        : 0\n" ++
                    "Retry Count                     : 0\n" ++
                    "Retry Interval (ms)             : 0\n" ++
                    "Volatile Bit Rate (kbps)        : Unknown (0x05)\n" ++
                    "Non-Volatile Bit Rate (kbps)    : Unknown (0x0F)\n" ++
                    "Payload Channel                 : 0 (0x00)\n" ++
                    "Payload Port                    : 0\n",
            writer.buffered(),
        );
    }
}

test "sol info stdout detects preflush early late and final flush failures" {
    const Stub = struct {
        var lookups: usize = 0;
        fn get(field: InfoField, _: u8) []const u8 {
            lookups += 1;
            return switch (field) {
                .progress => "commit-write",
                .privilege => "ADMINISTRATOR",
                .bit_rate => "115.2",
            };
        }
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    const p: Config = .{ .set_in_progress = 2, .enabled = 1, .force_encryption = 1, .privilege_level = 4, .volatile_bit_rate = 10, .non_volatile_bit_rate = 10 };
    var full: [640]u8 = undefined;
    var writer = std.Io.Writer.fixed(&full);
    Stub.lookups = 0;
    try std.testing.expectError(error.CStdoutFlushFailed, emitSolInfo(&writer, true, p, Stub.get, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), Stub.lookups);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    var early: std.Io.Writer = .failing;
    try std.testing.expectError(error.StdoutWriteFailed, emitSolInfo(&early, true, p, Stub.get, Stub.preflushOk));

    const prefix =
        "Set in progress                 : commit-write\n" ++
        "Enabled                         : true\n" ++
        "Force Encryption                : true\n" ++
        "Force Authentication            : false\n" ++
        "Privilege Level                 : ADMINISTRATOR\n";
    var short: [prefix.len]u8 = undefined;
    var late = std.Io.Writer.fixed(&short);
    try std.testing.expectError(error.StdoutWriteFailed, emitSolInfo(&late, false, p, Stub.get, Stub.preflushOk));
    try std.testing.expectEqualStrings(prefix, late.buffered());

    writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
    try std.testing.expectError(error.StdoutFlushFailed, emitSolInfo(&writer, true, p, Stub.get, Stub.preflushOk));
    try std.testing.expectEqualStrings("commit-write,true,true,true,ADMINISTRATOR,0,0,0,0,115.2,115.2,0,0\n", writer.buffered());
}

test "sol info stdout preserves preceding buffered C and subsequent C ordering" {
    const Stub = struct {
        var rates: usize = 0;
        fn get(field: InfoField, _: u8) []const u8 {
            return switch (field) {
                .progress => "commit-write",
                .privilege => "ADMINISTRATOR",
                .bit_rate => blk: {
                    rates += 1;
                    break :blk if (rates == 1) "115.2" else "19.2";
                },
            };
        }
    };
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("C before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    Stub.rates = 0;
    try emitSolInfo(&stdout.interface, true, .{ .set_in_progress = 2, .enabled = 1, .privilege_level = 4, .volatile_bit_rate = 10, .non_volatile_bit_rate = 7 }, Stub.get, stdout_io.trySyncC);
    _ = c.printf("|C after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));

    var captured: [256]u8 = undefined;
    const length = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(length >= 0);
    try std.testing.expectEqualStrings("C before|commit-write,true,false,false,ADMINISTRATOR,0,0,0,0,115.2,19.2,0,0\n|C after\n", captured[0..@intCast(length)]);
}

fn isValidU8(value: [*:0]const u8, param: [*:0]const u8, min: u8, max: u8, out: *u8) callconv(.c) c_int {
    if (c.str2uchar(value, out) != 0 or out.* < min or out.* > max) {
        log.print(log.Level.err, "Invalid value %s for parameter %s", .{ value, param });
        log.print(log.Level.err, "Valid values are %d-%d", .{ @as(c_int, min), @as(c_int, max) });
        return -1;
    }
    return 0;
}

const Settings = struct {
    selector: u8,
    data: [2]u8 = .{ 0, 0 },
    len: u16 = 3,
    guarded: bool = true,
};

fn failBoolean(value: [*:0]const u8, param: [*:0]const u8) c_int {
    log.print(log.Level.err, "Invalid value %s for parameter %s", .{ value, param });
    log.print(log.Level.err, "Valid values are true and false", .{});
    return -1;
}

fn setInProgress(intf: *Intf, channel: u8, code: u8) c_int {
    var data = [3]u8{ channel, 0, code };
    var req = reqWithData(ipmi.NetFn.transport, 0x21, &data);
    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress'", .{});
        return -1;
    };
    if (code == 2 or rsp.ccode == 0) return 0;
    switch (rsp.ccode) {
        0x80 => log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress': Parameter not supported", .{}),
        0x81 => log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress': Attempt to set set-in-progress when not in set-complete state", .{}),
        0x82 => log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress': Attempt to write read-only parameter", .{}),
        0x83 => log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress': Attempt to read write-only parameter", .{}),
        else => log.print(log.Level.err, "Error setting SOL parameter 'set-in-progress' to '%s': %s", .{ choose(code == 0, "set-complete", "set-in-progress"), cc(rsp.ccode) }),
    }
    return -1;
}

fn setParam(intf: *Intf, channel: u8, param: [*:0]const u8, value: [*:0]const u8, guarded: u8) c_int {
    var s: Settings = .{ .selector = 0, .guarded = guarded != 0 };
    if (eql(param, "set-in-progress")) {
        s.guarded = false;
        s.data[0] = if (eql(value, "set-complete")) 0 else if (eql(value, "set-in-progress")) 1 else if (eql(value, "commit-write")) 2 else {
            log.print(log.Level.err, "Invalid value %s for parameter %s", .{ value, param });
            log.print(log.Level.err, "Valid values are set-complete, set-in-progress and commit-write", .{});
            return -1;
        };
    } else if (eql(param, "enabled")) {
        s.selector = 1;
        s.data[0] = if (eql(value, "true")) 1 else if (eql(value, "false")) 0 else return failBoolean(value, param);
    } else if (eql(param, "force-encryption") or eql(param, "force-authentication") or eql(param, "privilege-level")) {
        s.selector = 2;
        const encryption = eql(param, "force-encryption");
        const authentication = eql(param, "force-authentication");
        if (encryption or authentication) {
            const bit: u8 = if (encryption) 0x80 else 0x40;
            s.data[0] = if (eql(value, "true")) bit else if (eql(value, "false")) 0 else return failBoolean(value, param);
        } else {
            s.data[0] = if (eql(value, "user")) 2 else if (eql(value, "operator")) 3 else if (eql(value, "admin")) 4 else if (eql(value, "oem")) 5 else {
                log.print(log.Level.err, "Invalid value %s for parameter %s", .{ value, param });
                log.print(log.Level.err, "Valid values are user, operator, admin, and oem", .{});
                return -1;
            };
        }
        var old = std.mem.zeroes(Config);
        if (getSolInfo(intf, channel, &old) != 0) {
            log.print(log.Level.err, "Error fetching SOL parameters for %s update", .{param});
            return -1;
        }
        if (!encryption and old.force_encryption != 0) s.data[0] |= 0x80;
        if (!authentication and old.force_authentication != 0) s.data[0] |= 0x40;
        if (encryption or authentication) s.data[0] |= old.privilege_level;
    } else if (eql(param, "character-accumulate-level") or eql(param, "character-send-threshold") or
        eql(param, "retry-count") or eql(param, "retry-interval"))
    {
        const accum = eql(param, "character-accumulate-level");
        const threshold = eql(param, "character-send-threshold");
        const retry_count = eql(param, "retry-count");
        s.selector = if (accum or threshold) 3 else 4;
        s.len = 4;
        const slot = if (accum or retry_count) &s.data[0] else &s.data[1];
        if (isValidU8(value, param, if (accum) 1 else 0, if (retry_count) 7 else 255, slot) != 0) return -1;
        var old = std.mem.zeroes(Config);
        if (getSolInfo(intf, channel, &old) != 0) {
            log.print(log.Level.err, "Error fetching SOL parameters for %s update", .{param});
            return -1;
        }
        if (accum) s.data[1] = old.character_send_threshold else if (threshold)
            s.data[0] = old.character_accumulate_level
        else if (retry_count)
            s.data[1] = old.retry_interval
        else
            s.data[0] = old.retry_count;
    } else if (eql(param, "non-volatile-bit-rate") or eql(param, "volatile-bit-rate")) {
        s.selector = if (eql(param, "non-volatile-bit-rate")) 5 else 6;
        s.data[0] = if (eql(value, "serial")) 0 else if (eql(value, "9.6")) 6 else if (eql(value, "19.2")) 7 else if (eql(value, "38.4")) 8 else if (eql(value, "57.6")) 9 else if (eql(value, "115.2")) 10 else {
            log.print(log.Level.err, "Invalid value \"%s\" for parameter \"%s\"", .{ value, param });
            log.print(log.Level.err, "Valid values are serial, 9.6 19.2, 38.4, 57.6 and 115.2", .{});
            return -1;
        };
    } else {
        log.print(log.Level.err, "Error: invalid SOL parameter %s", .{param});
        return -1;
    }

    if (s.guarded and setInProgress(intf, channel, 1) != 0) {
        log.print(log.Level.err, "Error: set of parameter \"%s\" failed", .{param});
        return -1;
    }
    var data = [4]u8{ channel, s.selector, s.data[0], s.data[1] };
    var req = reqWithData(ipmi.NetFn.transport, 0x21, data[0..s.len]);
    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error setting SOL parameter '%s'", .{param});
        return -1;
    };
    if (!(s.selector == 0 and s.data[0] == 2) and rsp.ccode != 0) {
        switch (rsp.ccode) {
            0x80 => log.print(log.Level.err, "Error setting SOL parameter '%s': Parameter not supported", .{param}),
            0x81 => log.print(log.Level.err, "Error setting SOL parameter '%s': Attempt to set set-in-progress when not in set-complete state", .{param}),
            0x82 => log.print(log.Level.err, "Error setting SOL parameter '%s': Attempt to write read-only parameter", .{param}),
            0x83 => log.print(log.Level.err, "Error setting SOL parameter '%s': Attempt to read write-only parameter", .{param}),
            else => log.print(log.Level.err, "Error setting SOL parameter '%s' to '%s': %s", .{ param, value, cc(rsp.ccode) }),
        }
        if (s.guarded and setInProgress(intf, channel, 0) != 0)
            log.print(log.Level.err, "Error could not set \"set-in-progress\" to \"set-complete\"", .{});
        return -1;
    }
    if (s.guarded) {
        _ = setInProgress(intf, channel, 2);
        if (setInProgress(intf, channel, 0) != 0) {
            log.print(log.Level.err, "Error could not set \"set-in-progress\" to \"set-complete\"", .{});
            return -1;
        }
    }
    return 0;
}

fn leaveRawMode() callconv(.c) void {
    if (!in_raw_mode) return;
    if (c.tcsetattr(0, c.TCSADRAIN, &saved_tio) == -1)
        c.perror("tcsetattr")
    else
        in_raw_mode = false;
}

fn enterRawMode() callconv(.c) void {
    var tio: c.struct_termios = undefined;
    if (c.tcgetattr(0, &tio) == -1) {
        c.perror("tcgetattr");
        return;
    }
    saved_tio = tio;
    tio.c_iflag |= c.IGNPAR;
    tio.c_iflag &= ~@as(@TypeOf(tio.c_iflag), c.ISTRIP | c.INLCR | c.IGNCR | c.ICRNL | c.IXON | c.IXANY | c.IXOFF);
    tio.c_lflag &= ~@as(@TypeOf(tio.c_lflag), c.ISIG | c.ICANON | c.ECHO | c.ECHOE | c.ECHOK | c.ECHONL | c.IEXTEN);
    tio.c_oflag &= ~@as(@TypeOf(tio.c_oflag), c.OPOST);
    tio.c_cc[c.VMIN] = 1;
    tio.c_cc[c.VTIME] = 0;
    if (c.tcsetattr(0, c.TCSADRAIN, &tio) == -1)
        c.perror("tcsetattr")
    else
        in_raw_mode = true;
}

fn output(rsp_opt: ?*Response) callconv(.c) void {
    const rsp = rsp_opt orelse return;
    if (rsp.session.authtype != c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS or
        rsp.session.payloadtype != @intFromEnum(ipmi.PayloadType.sol) or
        rsp.data_len <= 0) return;
    const size: usize = @intCast(@min(rsp.data_len, ipmi.buf_size));
    _ = c.fwrite(&rsp.data, 1, size, c.stdout);
    _ = c.fflush(c.stdout);
}

fn deactivate(intf: *Intf, instance: c_int) c_int {
    if (instance <= 0 or instance > 15) {
        log.print(log.Level.err, "Error: Instance must range from 1 to 15", .{});
        return -1;
    }
    var data = [6]u8{ 1, @intCast(instance), 0, 0, 0, 0 };
    var req = reqWithData(ipmi.NetFn.app, 0x49, &data);
    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error: No response de-activating SOL payload", .{});
        return -1;
    };
    switch (rsp.ccode) {
        0 => return 0,
        0x80 => log.print(log.Level.err, "Info: SOL payload already de-activated", .{}),
        0x81 => log.print(log.Level.err, "Info: SOL payload type disabled", .{}),
        else => log.print(log.Level.err, "Error de-activating SOL payload: %s", .{cc(rsp.ccode)}),
    }
    return -1;
}

fn sendBreak(intf: *Intf) void {
    var payload = std.mem.zeroes(ipmi.V2Payload);
    payload.payload.sol_packet.generate_break = 1;
    if (intf.send_sol) |send| _ = send(intf, &payload);
}

fn suspendSelf(restore_tty: bool) void {
    leaveRawMode();
    _ = c.kill(c.getpid(), c.SIGTSTP);
    if (restore_tty) enterRawMode();
}

const InteractiveText = union(enum) {
    help: u8,
    terminated: u8,
    suspended: u8,
    break_sent: u8,
    banner: u8,
    progress: c_int,
    failure: c_int,
};

fn writeInteractiveText(writer: *std.Io.Writer, text: InteractiveText) std.Io.Writer.Error!void {
    switch (text) {
        .help => |e| {
            try writer.writeByte(e);
            try writer.writeAll("?\n\tSupported escape sequences:\n\t");
            try writer.writeByte(e);
            try writer.writeAll(".  - terminate connection\n\t");
            try writer.writeByte(e);
            try writer.writeAll("^Z - suspend ipmitool\n\t");
            try writer.writeByte(e);
            try writer.writeAll("^X - suspend ipmitool, but don't restore tty on restart\n\t");
            try writer.writeByte(e);
            try writer.writeAll("B  - send break\n\t");
            try writer.writeByte(e);
            try writer.writeAll("?  - this message\n\t");
            try writer.writeByte(e);
            try writer.writeByte(e);
            try writer.writeAll("  - send the escape character by typing it twice\n" ++
                "\t(Note that escapes are only recognized immediately after newline.)\n");
        },
        .terminated => |e| {
            try writer.writeByte(e);
            try writer.writeAll(". [terminated ipmitool]\n");
        },
        .suspended => |e| {
            try writer.writeByte(e);
            try writer.writeAll("^Z [suspend ipmitool]\n");
        },
        .break_sent => |e| {
            try writer.writeByte(e);
            try writer.writeAll("B [send break]\n");
        },
        .banner => |e| {
            try writer.writeAll("[SOL Session operational.  Use ");
            try writer.writeByte(e);
            try writer.writeAll("? for help]\n");
        },
        .progress => |count| try writer.print("remain loop test counter: {d}\n", .{count}),
        .failure => |status| try writer.print("SOL looptest failed: {d}\n", .{status}),
    }
}

fn emitInteractiveText(writer: *std.Io.Writer, text: InteractiveText, preflush: anytype) StdoutError!void {
    preflush() catch return error.CStdoutFlushFailed;
    writeInteractiveText(writer, text) catch return error.StdoutWriteFailed;
    writer.flush() catch return error.StdoutFlushFailed;
}

fn logInteractiveOutputError(err: StdoutError, write_error: anyerror) void {
    switch (err) {
        error.CStdoutFlushFailed => log.print(log.Level.err, "SOL interactive stdout C preflush failed", .{}),
        error.StdoutWriteFailed => log.print(log.Level.err, "SOL interactive stdout write failed: %s", .{@errorName(write_error).ptr}),
        error.StdoutFlushFailed => log.print(log.Level.err, "SOL interactive stdout final flush failed: %s", .{@errorName(write_error).ptr}),
    }
}

fn printEscapes(intf: *Intf, writer: *std.Io.Writer, preflush: anytype) StdoutError!void {
    try emitInteractiveText(writer, .{ .help = intf.ssn_params.sol_escape_char }, preflush);
}

const EscapeState = struct {
    pending: bool = false,
    last_cr: bool = true,
};
var escape_state: EscapeState = .{};

fn processUserInput(intf: *Intf, input: []const u8, writer: *std.Io.Writer, preflush: anytype, suspend_fn: anytype) StdoutError!c_int {
    var payload = std.mem.zeroes(ipmi.V2Payload);
    // A pending escape from the preceding read can add one byte to this read.
    var data: [ipmi.buf_size + 1]u8 = undefined;
    var length: usize = 0;
    var result: c_int = 0;
    const e = intf.ssn_params.sol_escape_char;
    for (input) |ch| {
        if (escape_state.pending) {
            escape_state.pending = false;
            switch (ch) {
                '.' => {
                    try emitInteractiveText(writer, .{ .terminated = e }, preflush);
                    result = 1;
                },
                26 => {
                    try emitInteractiveText(writer, .{ .suspended = e }, preflush);
                    suspend_fn(true);
                    continue;
                },
                24 => {
                    try emitInteractiveText(writer, .{ .suspended = e }, preflush);
                    suspend_fn(false);
                    continue;
                },
                'B' => {
                    try emitInteractiveText(writer, .{ .break_sent = e }, preflush);
                    sendBreak(intf);
                    continue;
                },
                '?' => {
                    try printEscapes(intf, writer, preflush);
                    continue;
                },
                else => {
                    if (ch != e) {
                        data[length] = e;
                        length += 1;
                    }
                    data[length] = ch;
                    length += 1;
                },
            }
        } else {
            if (escape_state.last_cr and ch == e) {
                escape_state.pending = true;
                continue;
            }
            data[length] = ch;
            length += 1;
        }
        escape_state.last_cr = ch == '\r' or ch == '\n';
    }
    if (length == 0) return result;

    // Unlike the original fixed-size memcpy, each send stays inside the SOL
    // packet buffer even if a BMC advertises an excessive inbound size.
    const limit: usize = if (intf.session) |ssn| blk: {
        const max_size = ssn.sol_data.max_outbound_payload_size;
        break :blk if (max_size > 4) @min(max_size - 4, ipmi.buf_size) else ipmi.buf_size;
    } else ipmi.buf_size;
    var offset: usize = 0;
    while (offset < length) {
        const count = @min(length - offset, limit);
        @memcpy(payload.payload.sol_packet.data[0..count], data[offset..][0..count]);
        payload.payload.sol_packet.character_count = @intCast(count);
        var rsp: ?*Response = null;
        const retry: usize = @intCast(@max(0, intf.ssn_params.retry));
        for (0..retry) |_| {
            if (intf.send_sol) |send| rsp = send(intf, &payload);
            if (rsp != null) break;
            _ = c.usleep(5000);
        }
        if (rsp == null) {
            log.print(log.Level.err, "Error sending SOL data: FAIL", .{});
            return -1;
        }
        if (result == 0 and rsp.?.session.authtype == c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS and
            rsp.?.session.payloadtype == @intFromEnum(ipmi.PayloadType.sol) and
            rsp.?.payload.sol_packet.packet_sequence_number != 0) output(rsp);
        offset += count;
    }
    return result;
}

fn keepalive(intf: *Intf) c_int {
    if (disable_keepalive) return 0;
    var now: c.struct_timeval = undefined;
    _ = c.gettimeofday(&now, null);
    if (now.tv_sec - keepalive_start.tv_sec <= c.SOL_KEEPALIVE_TIMEOUT) return 0;
    if (use_sol_keepalive) {
        var payload = std.mem.zeroes(ipmi.V2Payload);
        const send = intf.send_sol orelse return -1;
        if (send(intf, &payload) == null) return -1;
    } else {
        const send = intf.keepalive orelse return -1;
        if (send(intf) != 0) return -1;
    }
    _ = c.gettimeofday(&keepalive_start, null);
    return 0;
}

fn sessionLoop(intf: *Intf, instance: c_int, writer: *std.Io.Writer, preflush: anytype) StdoutError!c_int {
    const ssn = intf.session orelse return -1;
    const cap: usize = @min(
        if (ssn.sol_data.max_inbound_payload_size > 4)
            @as(usize, ssn.sol_data.max_inbound_payload_size - 4)
        else
            @as(usize, ssn.sol_data.max_inbound_payload_size),
        ipmi.buf_size,
    );
    if (cap == 0) {
        log.print(log.Level.err, "Error: Invalid SOL inbound payload size", .{});
        return -1;
    }
    const buffer = std.heap.c_allocator.alloc(u8, cap) catch {
        log.print(log.Level.err, "ipmitool: malloc failure", .{});
        return -1;
    };
    defer std.heap.c_allocator.free(buffer);
    _ = c.gettimeofday(&keepalive_start, null);
    enterRawMode();
    defer leaveRawMode();

    var closed_by_bmc = false;
    var keepalive_failure: c_int = 0;
    var retries: u8 = 0;
    var output_error: ?StdoutError = null;
    while (true) {
        if (c.ipmi_oem_active(@ptrCast(intf), "i82571spt") == 0) {
            keepalive_failure = keepalive(intf);
            if (keepalive_failure != 0) {
                if (retries == 6) break;
                retries += 1;
            } else retries = 0;
        }
        var fds = [_]c.struct_pollfd{
            .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            .{ .fd = intf.fd, .events = c.POLLIN, .revents = 0 },
        };
        const n = c.poll(&fds, 2, 500);
        if (n < 0) {
            c.perror("select");
            return -1;
        }
        if (n == 0) continue;
        if (fds[0].revents != 0) {
            const count = c.read(0, buffer.ptr, buffer.len);
            if (count <= 0) break;
            const rc = processUserInput(intf, buffer[0..@intCast(count)], writer, preflush, suspendSelf) catch |err| {
                output_error = err;
                break;
            };
            if (rc != 0) {
                if (rc < 0) closed_by_bmc = true;
                break;
            }
        } else if (fds[1].revents != 0) {
            if (intf.recv_sol) |recv| {
                if (recv(intf)) |rsp| output(rsp) else {
                    closed_by_bmc = true;
                    break;
                }
            } else {
                closed_by_bmc = true;
                break;
            }
        } else {
            log.print(log.Level.err, "Error: Select returned with nothing to read", .{});
            break;
        }
    }
    leaveRawMode();
    if (output_error) |err| {
        _ = deactivate(intf, instance);
        return err;
    }
    if (keepalive_failure != 0) {
        log.print(log.Level.err, "Error: No response to keepalive - Terminating session", .{});
        _ = deactivate(intf, instance);
        c.exit(1);
    }
    if (closed_by_bmc) {
        log.print(log.Level.err, "SOL session closed by BMC", .{});
        c.exit(1);
    }
    _ = deactivate(intf, instance);
    return 0;
}

fn activateTo(intf: *Intf, looptest: bool, interval: c_int, instance: c_int, writer: *std.Io.Writer, preflush: anytype) StdoutError!c_int {
    if (!std.mem.eql(u8, std.mem.sliceTo(&intf.name, 0), "lanplus")) {
        log.print(log.Level.err, "Error: This command is only available over the lanplus interface", .{});
        return -1;
    }
    if (instance <= 0 or instance > 15) {
        log.print(log.Level.err, "Error: Instance must range from 1 to 15", .{});
        return -1;
    }
    const ssn = intf.session orelse {
        log.print(log.Level.err, "Error: No SOL session available", .{});
        return -1;
    };
    ssn.sol_data.sol_input_handler = output;
    var data = [6]u8{ 1, @intCast(instance), 0xc4, 0, 0, 0 };
    if (c.ipmi_oem_active(@ptrCast(intf), "intelplus") == 0) {
        if (c.ipmi_oem_active(@ptrCast(intf), "i82571spt") != 0) data[2] = 0x08 else data[2] |= 0x02;
    }
    var req = reqWithData(ipmi.NetFn.app, 0x48, &data);
    const rsp = sendrecv(intf, &req) orelse {
        log.print(log.Level.err, "Error: No response activating SOL payload", .{});
        return -1;
    };
    switch (rsp.ccode) {
        0 => if (rsp.data_len != 12) {
            log.print(log.Level.err, "Error: Unexpected data length (%d) received in payload activation response", .{rsp.data_len});
            return -1;
        },
        0x80 => {
            log.print(log.Level.err, "Info: SOL payload already active on another session", .{});
            return -1;
        },
        0x81 => {
            log.print(log.Level.err, "Info: SOL payload disabled", .{});
            return -1;
        },
        0x82 => {
            log.print(log.Level.err, "Info: SOL payload activation limit reached", .{});
            return -1;
        },
        0x83 => {
            log.print(log.Level.err, "Info: cannot activate SOL payload with encryption", .{});
            return -1;
        },
        0x84 => {
            log.print(log.Level.err, "Info: cannot activate SOL payload without encryption", .{});
            return -1;
        },
        else => {
            log.print(log.Level.err, "Error activating SOL payload: %s", .{cc(rsp.ccode)});
            return -1;
        },
    }
    ssn.sol_data.max_inbound_payload_size = std.mem.readInt(u16, rsp.data[4..6], .little);
    ssn.sol_data.max_outbound_payload_size = std.mem.readInt(u16, rsp.data[6..8], .little);
    ssn.sol_data.port = std.mem.readInt(u16, rsp.data[8..10], .little);
    if (ssn.sol_data.max_inbound_payload_size <= 4 or ssn.sol_data.max_outbound_payload_size <= 4) {
        log.print(log.Level.err, "Error: Invalid SOL payload size", .{});
        _ = deactivate(intf, instance);
        return -1;
    }
    if (ssn.sol_data.port != intf.ssn_params.port) {
        if (@byteSwap(ssn.sol_data.port) == intf.ssn_params.port)
            ssn.sol_data.port = @byteSwap(ssn.sol_data.port)
        else {
            log.print(log.Level.err, "Error: BMC requests SOL session on different port", .{});
            return -1;
        }
    }
    emitInteractiveText(writer, .{ .banner = intf.ssn_params.sol_escape_char }, preflush) catch |err| {
        _ = deactivate(intf, instance);
        return err;
    };
    if (looptest) {
        _ = deactivate(intf, instance);
        if (interval > 0) _ = c.usleep(@as(c_uint, @intCast(interval)) *% 1000);
        return 0;
    }
    if (try sessionLoop(intf, instance, writer, preflush) != 0) {
        _ = deactivate(intf, instance);
        log.print(log.Level.err, "Error in SOL session", .{});
        return -1;
    }
    return 0;
}

fn activate(intf: *Intf, looptest: bool, interval: c_int, instance: c_int) c_int {
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    return activateTo(intf, looptest, interval, instance, &stdout.interface, stdout_io.trySyncC) catch |err| {
        logInteractiveOutputError(err, stdout.err orelse error.WriteFailed);
        return -1;
    };
}

fn loopTestTo(intf: *Intf, initial_count: c_int, interval: c_int, instance: c_int, writer: *std.Io.Writer, preflush: anytype) StdoutError!c_int {
    var count = initial_count;
    while (count > 0) : (count -= 1) {
        try emitInteractiveText(writer, .{ .progress = count }, preflush);
        const result = try activateTo(intf, true, interval, instance, writer, preflush);
        if (result != 0) {
            try emitInteractiveText(writer, .{ .failure = result }, preflush);
            return result;
        }
    }
    return 0;
}

fn interactiveCBytes(buffer: []u8, text: InteractiveText) ![]const u8 {
    const n: c_int = switch (text) {
        .help => |e| c.snprintf(
            buffer.ptr,
            buffer.len,
            "%c?\n\tSupported escape sequences:\n\t%c.  - terminate connection\n" ++
                "\t%c^Z - suspend ipmitool\n\t%c^X - suspend ipmitool, but don't restore tty on restart\n" ++
                "\t%cB  - send break\n\t%c?  - this message\n" ++
                "\t%c%c  - send the escape character by typing it twice\n" ++
                "\t(Note that escapes are only recognized immediately after newline.)\n",
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
            @as(c_int, e),
        ),
        .terminated => |e| c.snprintf(buffer.ptr, buffer.len, "%c. [terminated ipmitool]\n", @as(c_int, e)),
        .suspended => |e| c.snprintf(buffer.ptr, buffer.len, "%c^Z [suspend ipmitool]\n", @as(c_int, e)),
        .break_sent => |e| c.snprintf(buffer.ptr, buffer.len, "%cB [send break]\n", @as(c_int, e)),
        .banner => |e| c.snprintf(buffer.ptr, buffer.len, "[SOL Session operational.  Use %c? for help]\n", @as(c_int, e)),
        .progress => |count| c.snprintf(buffer.ptr, buffer.len, "remain loop test counter: %d\n", count),
        .failure => |status| c.snprintf(buffer.ptr, buffer.len, "SOL looptest failed: %d\n", status),
    };
    try std.testing.expect(n >= 0 and @as(usize, @intCast(n)) < buffer.len);
    return buffer[0..@intCast(n)];
}

test "sol interactive stdout matches libc control and looptest bytes" {
    for ([_]u8{ 0, '~', '^', 0x80, 0xff }) |escape| {
        for ([_]InteractiveText{
            .{ .help = escape },
            .{ .terminated = escape },
            .{ .suspended = escape },
            .{ .break_sent = escape },
            .{ .banner = escape },
        }) |text| {
            var storage: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try writeInteractiveText(&writer, text);
            var expected: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, try interactiveCBytes(&expected, text), writer.buffered());
        }
    }
    for ([_]c_int{ std.math.minInt(c_int), -1, 0, 1, 200, std.math.maxInt(c_int) }) |count| {
        for ([_]InteractiveText{ .{ .progress = count }, .{ .failure = count } }) |text| {
            var storage: [512]u8 = undefined;
            var writer = std.Io.Writer.fixed(&storage);
            try writeInteractiveText(&writer, text);
            var expected: [512]u8 = undefined;
            try std.testing.expectEqualSlices(u8, try interactiveCBytes(&expected, text), writer.buffered());
        }
    }
}

test "sol interactive stdout rejects preflush early late and final flush failures" {
    const Stub = struct {
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    for ([_]InteractiveText{
        .{ .help = '~' },       .{ .terminated = '~' }, .{ .suspended = '~' },
        .{ .break_sent = '~' }, .{ .banner = '~' },     .{ .progress = 200 },
        .{ .failure = -1 },
    }) |text| {
        var storage: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectError(error.CStdoutFlushFailed, emitInteractiveText(&writer, text, Stub.preflushFail));
        try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

        var early: std.Io.Writer = .failing;
        try std.testing.expectError(error.StdoutWriteFailed, emitInteractiveText(&early, text, Stub.preflushOk));
        try emitInteractiveText(&writer, text, Stub.preflushOk);
        const complete = writer.buffered();
        var short: [512]u8 = undefined;
        var late = std.Io.Writer.fixed(short[0 .. complete.len - 1]);
        try std.testing.expectError(error.StdoutWriteFailed, emitInteractiveText(&late, text, Stub.preflushOk));
        try std.testing.expectEqualSlices(u8, complete[0 .. complete.len - 1], late.buffered());

        var final = std.Io.Writer.fixed(&short);
        final.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
        try std.testing.expectError(error.StdoutFlushFailed, emitInteractiveText(&final, text, Stub.preflushOk));
        try std.testing.expectEqualSlices(u8, complete, final.buffered());
    }
}

test "sol interactive stdout orders C buffering binary payload and Zig text" {
    const fd = c.fileno(c.stdout);
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    const saved = c.dup(fd);
    try std.testing.expect(saved >= 0);
    defer {
        _ = c.fflush(c.stdout);
        _ = c.dup2(saved, fd);
        _ = c.close(saved);
    }
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    try std.testing.expectEqual(fd, c.dup2(fds[1], fd));
    _ = c.close(fds[1]);

    _ = c.printf("before|");
    var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
    try emitInteractiveText(&stdout.interface, .{ .banner = '^' }, stdout_io.trySyncC);
    var rsp = std.mem.zeroes(Response);
    rsp.session.authtype = c.IPMI_SESSION_AUTHTYPE_RMCP_PLUS;
    rsp.session.payloadtype = @intFromEnum(ipmi.PayloadType.sol);
    rsp.data_len = 3;
    rsp.data[0] = 0;
    rsp.data[1] = 0xff;
    rsp.data[2] = '\r';
    output(&rsp);
    _ = c.printf("|between|");
    try emitInteractiveText(&stdout.interface, .{ .break_sent = '^' }, stdout_io.trySyncC);
    _ = c.printf("|after\n");
    try std.testing.expectEqual(@as(c_int, 0), c.fflush(c.stdout));
    try std.testing.expectEqual(fd, c.dup2(saved, fd));

    var captured: [512]u8 = undefined;
    const n = c.read(fds[0], &captured, captured.len);
    try std.testing.expect(n >= 0);
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writer.writeAll("before|");
    try writeInteractiveText(&writer, .{ .banner = '^' });
    try writer.writeAll(&.{ 0, 0xff, '\r' });
    try writer.writeAll("|between|");
    try writeInteractiveText(&writer, .{ .break_sent = '^' });
    try writer.writeAll("|after\n");
    try std.testing.expectEqualSlices(u8, writer.buffered(), captured[0..@intCast(n)]);
}

test "sol interactive stdout escape controls retain statuses wire data and side effects" {
    const Stub = struct {
        var response: Response = std.mem.zeroes(Response);
        var breaks: usize = 0;
        var data_sends: usize = 0;
        var sent: [32]u8 = undefined;
        var sent_len: usize = 0;
        var suspends: [2]bool = undefined;
        var suspend_count: usize = 0;

        fn send(_: *Intf, payload: *ipmi.V2Payload) callconv(.c) ?*Response {
            if (payload.payload.sol_packet.generate_break != 0) {
                breaks += 1;
            } else {
                data_sends += 1;
                sent_len = payload.payload.sol_packet.character_count;
                @memcpy(sent[0..sent_len], payload.payload.sol_packet.data[0..sent_len]);
            }
            return &response;
        }
        fn suspendStub(restore: bool) void {
            suspends[suspend_count] = restore;
            suspend_count += 1;
        }
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
    };
    escape_state = .{};
    defer escape_state = .{};
    var intf = std.mem.zeroes(Intf);
    intf.ssn_params.sol_escape_char = '~';
    intf.ssn_params.retry = 1;
    intf.send_sol = Stub.send;
    Stub.breaks = 0;
    Stub.data_sends = 0;
    Stub.suspend_count = 0;
    var storage: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);

    try std.testing.expectEqual(@as(c_int, 0), try processUserInput(&intf, "~?", &writer, Stub.preflushOk, Stub.suspendStub));
    try std.testing.expectEqual(@as(c_int, 0), try processUserInput(&intf, "~B", &writer, Stub.preflushOk, Stub.suspendStub));
    try std.testing.expectEqual(@as(c_int, 0), try processUserInput(&intf, "~\x1a~\x18", &writer, Stub.preflushOk, Stub.suspendStub));
    try std.testing.expectEqual(@as(c_int, 1), try processUserInput(&intf, "~.", &writer, Stub.preflushOk, Stub.suspendStub));
    try std.testing.expectEqual(@as(usize, 1), Stub.breaks);
    try std.testing.expectEqual(@as(usize, 0), Stub.data_sends);
    try std.testing.expectEqual(@as(usize, 2), Stub.suspend_count);
    try std.testing.expect(Stub.suspends[0]);
    try std.testing.expect(!Stub.suspends[1]);
    var expected_storage: [1024]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    for ([_]InteractiveText{
        .{ .help = '~' },      .{ .break_sent = '~' }, .{ .suspended = '~' },
        .{ .suspended = '~' }, .{ .terminated = '~' },
    }) |text| {
        var c_bytes: [512]u8 = undefined;
        try expected.writeAll(try interactiveCBytes(&c_bytes, text));
    }
    try std.testing.expectEqualSlices(u8, expected.buffered(), writer.buffered());

    escape_state = .{};
    var data_storage: [64]u8 = undefined;
    var data_writer = std.Io.Writer.fixed(&data_storage);
    try std.testing.expectEqual(@as(c_int, 0), try processUserInput(&intf, "\r~~\r~q", &data_writer, Stub.preflushFail, Stub.suspendStub));
    try std.testing.expectEqual(@as(usize, 1), Stub.data_sends);
    try std.testing.expectEqualStrings("\r~\r~q", Stub.sent[0..Stub.sent_len]);
    try std.testing.expectEqual(@as(usize, 0), data_writer.buffered().len);

    for ([_][]const u8{ "~?", "~B", "~\x1a", "~\x18", "~." }) |input| {
        escape_state = .{};
        var failed_storage: [512]u8 = undefined;
        var failed = std.Io.Writer.fixed(&failed_storage);
        try std.testing.expectError(error.CStdoutFlushFailed, processUserInput(&intf, input, &failed, Stub.preflushFail, Stub.suspendStub));
        try std.testing.expectEqual(@as(usize, 0), failed.buffered().len);
        try std.testing.expectEqual(@as(usize, 1), Stub.breaks);
        try std.testing.expectEqual(@as(usize, 2), Stub.suspend_count);
        try std.testing.expectEqual(@as(usize, 1), Stub.data_sends);
    }
}

test "sol interactive stdout activation and looptest preserve requests cleanup and statuses" {
    const Stub = struct {
        const Mode = enum { ok, missing, ccode, short, wrong_port };
        var mode: Mode = .ok;
        var response: Response = std.mem.zeroes(Response);
        var activations: usize = 0;
        var deactivations: usize = 0;
        var requests_ok = true;
        var preflush_calls: usize = 0;

        fn reset(next: Mode) void {
            mode = next;
            activations = 0;
            deactivations = 0;
            requests_ok = true;
            preflush_calls = 0;
        }
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            if (req.msg.netfn_lun.netfn != ipmi.NetFn.app or req.msg.data_len != 6 or req.msg.data == null) {
                requests_ok = false;
                return null;
            }
            response = std.mem.zeroes(Response);
            if (req.msg.cmd == 0x48) {
                activations += 1;
                requests_ok = requests_ok and std.mem.eql(u8, req.msg.data.?[0..6], &.{ 1, 7, 0xc6, 0, 0, 0 });
                if (mode == .missing) return null;
                response.ccode = if (mode == .ccode) 0x81 else 0;
                response.data_len = if (mode == .short) 0 else 12;
                response.data[4] = 64;
                response.data[6] = 64;
                response.data[8] = if (mode == .wrong_port) 0x70 else 0x6f;
                response.data[9] = 2;
            } else if (req.msg.cmd == 0x49) {
                deactivations += 1;
                requests_ok = requests_ok and std.mem.eql(u8, req.msg.data.?[0..6], &.{ 1, 7, 0, 0, 0, 0 });
            } else requests_ok = false;
            return &response;
        }
        fn preflushOk() error{CStdoutFlushFailed}!void {}
        fn preflushFail() error{CStdoutFlushFailed}!void {
            return error.CStdoutFlushFailed;
        }
        fn preflushSecond() error{CStdoutFlushFailed}!void {
            preflush_calls += 1;
            if (preflush_calls == 2) return error.CStdoutFlushFailed;
        }
        fn flushFail(_: *std.Io.Writer) std.Io.Writer.Error!void {
            return error.WriteFailed;
        }
    };
    var intf = std.mem.zeroes(Intf);
    @memcpy(intf.name[0..7], "lanplus");
    intf.ssn_params.sol_escape_char = '^';
    intf.ssn_params.port = 623;
    var session = std.mem.zeroes(Session);
    intf.session = &session;
    intf.sendrecv = Stub.send;

    for ([_]struct { mode: Stub.Mode, result: c_int, deactivations: usize }{
        .{ .mode = .missing, .result = -1, .deactivations = 0 },
        .{ .mode = .ccode, .result = -1, .deactivations = 0 },
        .{ .mode = .short, .result = -1, .deactivations = 0 },
        .{ .mode = .wrong_port, .result = -1, .deactivations = 0 },
        .{ .mode = .ok, .result = 0, .deactivations = 1 },
    }) |case| {
        Stub.reset(case.mode);
        var storage: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try std.testing.expectEqual(case.result, try activateTo(&intf, true, 0, 7, &writer, Stub.preflushOk));
        try std.testing.expectEqual(@as(usize, 1), Stub.activations);
        try std.testing.expectEqual(case.deactivations, Stub.deactivations);
        try std.testing.expect(Stub.requests_ok);
        var expected: [256]u8 = undefined;
        try std.testing.expectEqualSlices(
            u8,
            if (case.result == 0) try interactiveCBytes(&expected, .{ .banner = '^' }) else "",
            writer.buffered(),
        );
    }

    const FailureKind = enum { preflush, write, flush };
    for ([_]FailureKind{ .preflush, .write, .flush }) |kind| {
        Stub.reset(.ok);
        var storage: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        switch (kind) {
            .preflush => try std.testing.expectError(error.CStdoutFlushFailed, activateTo(&intf, true, 0, 7, &writer, Stub.preflushFail)),
            .write => {
                var early: std.Io.Writer = .failing;
                try std.testing.expectError(error.StdoutWriteFailed, activateTo(&intf, true, 0, 7, &early, Stub.preflushOk));
            },
            .flush => {
                writer.vtable = &.{ .drain = std.Io.Writer.failingDrain, .flush = Stub.flushFail };
                try std.testing.expectError(error.StdoutFlushFailed, activateTo(&intf, true, 0, 7, &writer, Stub.preflushOk));
            },
        }
        try std.testing.expectEqual(@as(usize, 1), Stub.activations);
        try std.testing.expectEqual(@as(usize, 1), Stub.deactivations);
        try std.testing.expect(Stub.requests_ok);
    }

    Stub.reset(.ok);
    var success_storage: [256]u8 = undefined;
    var success = std.Io.Writer.fixed(&success_storage);
    try std.testing.expectEqual(@as(c_int, 0), try loopTestTo(&intf, 2, 0, 7, &success, Stub.preflushOk));
    try std.testing.expectEqual(@as(usize, 2), Stub.activations);
    try std.testing.expectEqual(@as(usize, 2), Stub.deactivations);
    try std.testing.expect(Stub.requests_ok);
    var expected_storage: [256]u8 = undefined;
    var expected = std.Io.Writer.fixed(&expected_storage);
    for ([_]InteractiveText{ .{ .progress = 2 }, .{ .banner = '^' }, .{ .progress = 1 }, .{ .banner = '^' } }) |text| {
        var c_bytes: [512]u8 = undefined;
        try expected.writeAll(try interactiveCBytes(&c_bytes, text));
    }
    try std.testing.expectEqualSlices(u8, expected.buffered(), success.buffered());

    var bad_intf = std.mem.zeroes(Intf);
    Stub.reset(.ok);
    var failed_storage: [256]u8 = undefined;
    var failed = std.Io.Writer.fixed(&failed_storage);
    try std.testing.expectEqual(@as(c_int, -1), try loopTestTo(&bad_intf, 2, 0, 7, &failed, Stub.preflushOk));
    try std.testing.expectEqual(@as(usize, 0), Stub.activations);
    var failure_storage: [256]u8 = undefined;
    var failure = std.Io.Writer.fixed(&failure_storage);
    for ([_]InteractiveText{ .{ .progress = 2 }, .{ .failure = -1 } }) |text| {
        var c_bytes: [512]u8 = undefined;
        try failure.writeAll(try interactiveCBytes(&c_bytes, text));
    }
    try std.testing.expectEqualSlices(u8, failure.buffered(), failed.buffered());

    Stub.reset(.ok);
    var early_storage: [256]u8 = undefined;
    var early = std.Io.Writer.fixed(&early_storage);
    try std.testing.expectError(error.CStdoutFlushFailed, loopTestTo(&intf, 2, 0, 7, &early, Stub.preflushFail));
    try std.testing.expectEqual(@as(usize, 0), Stub.activations);
    try std.testing.expectEqual(@as(usize, 0), early.buffered().len);

    Stub.reset(.ok);
    var late_storage: [256]u8 = undefined;
    var late = std.Io.Writer.fixed(&late_storage);
    try std.testing.expectError(error.CStdoutFlushFailed, loopTestTo(&intf, 2, 0, 7, &late, Stub.preflushSecond));
    try std.testing.expectEqual(@as(usize, 1), Stub.activations);
    try std.testing.expectEqual(@as(usize, 1), Stub.deactivations);
    var progress_bytes: [64]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try interactiveCBytes(&progress_bytes, .{ .progress = 2 }), late.buffered());

    Stub.reset(.ok);
    var failed_line_storage: [256]u8 = undefined;
    var failed_line = std.Io.Writer.fixed(&failed_line_storage);
    try std.testing.expectError(error.CStdoutFlushFailed, loopTestTo(&bad_intf, 2, 0, 7, &failed_line, Stub.preflushSecond));
    try std.testing.expectEqualSlices(u8, try interactiveCBytes(&progress_bytes, .{ .progress = 2 }), failed_line.buffered());
}

test "sol interactive stdout mid-session failure restores raw mode and deactivates" {
    if (comptime @import("builtin").target.os.tag != .linux) return error.SkipZigTest;
    const Stub = struct {
        var response: Response = std.mem.zeroes(Response);
        var deactivations: usize = 0;
        var request_ok = false;
        var raw_on_failure = false;

        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            deactivations += 1;
            request_ok = req.msg.netfn_lun.netfn == ipmi.NetFn.app and req.msg.cmd == 0x49 and
                req.msg.data_len == 6 and req.msg.data != null and
                std.mem.eql(u8, req.msg.data.?[0..6], &.{ 1, 1, 0, 0, 0, 0 });
            return &response;
        }
        fn failWhileRaw() error{CStdoutFlushFailed}!void {
            var tio: c.struct_termios = undefined;
            raw_on_failure = c.tcgetattr(0, &tio) == 0 and (tio.c_lflag & c.ICANON) == 0;
            return error.CStdoutFlushFailed;
        }
    };
    const master = c.open("/dev/ptmx", c.O_RDWR | c.O_NOCTTY);
    try std.testing.expect(master >= 0);
    defer _ = c.close(master);
    var unlocked: c_int = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(master, c.TIOCSPTLCK, &unlocked));
    var pty_number: c_uint = 0;
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(master, c.TIOCGPTN, &pty_number));
    var path_buf: [64]u8 = undefined;
    const slave_path = try std.fmt.bufPrintSentinel(&path_buf, "/dev/pts/{d}", .{pty_number}, 0);
    const slave = c.open(slave_path.ptr, c.O_RDWR | c.O_NOCTTY);
    try std.testing.expect(slave >= 0);
    defer _ = c.close(slave);

    const old_stdin = c.dup(0);
    try std.testing.expect(old_stdin >= 0);
    defer {
        _ = c.dup2(old_stdin, 0);
        _ = c.close(old_stdin);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.dup2(slave, 0));
    var before: c.struct_termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.tcgetattr(0, &before));
    try std.testing.expect(before.c_lflag & c.ICANON != 0);

    const old_keepalive = disable_keepalive;
    const old_escape_state = escape_state;
    defer {
        disable_keepalive = old_keepalive;
        escape_state = old_escape_state;
    }
    disable_keepalive = true;
    escape_state = .{};
    var session = std.mem.zeroes(Session);
    session.sol_data.max_inbound_payload_size = 64;
    var intf = std.mem.zeroes(Intf);
    intf.session = &session;
    intf.ssn_params.sol_escape_char = '~';
    intf.sendrecv = Stub.send;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer {
        _ = c.close(fds[0]);
        _ = c.close(fds[1]);
    }
    intf.fd = fds[0];
    Stub.deactivations = 0;
    Stub.request_ok = false;
    Stub.raw_on_failure = false;
    try std.testing.expectEqual(@as(isize, 3), c.write(master, "~?\r", 3));
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.CStdoutFlushFailed, sessionLoop(&intf, 1, &writer, Stub.failWhileRaw));
    try std.testing.expect(Stub.raw_on_failure);
    try std.testing.expectEqual(@as(usize, 1), Stub.deactivations);
    try std.testing.expect(Stub.request_ok);
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    var after: c.struct_termios = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.tcgetattr(0, &after));
    try std.testing.expectEqual(before.c_lflag, after.c_lflag);
    try std.testing.expectEqual(before.c_iflag, after.c_iflag);
    try std.testing.expectEqual(before.c_oflag, after.c_oflag);
}

fn usage() void {
    log.print(log.Level.notice, "SOL Commands: info [<channel number>]", .{});
    log.print(log.Level.notice, "              set <parameter> <value> [channel]", .{});
    log.print(log.Level.notice, "              payload <enable|disable|status> [channel] [userid]", .{});
    log.print(log.Level.notice, "              activate [<usesolkeepalive|nokeepalive>] [instance=<number>]", .{});
    log.print(log.Level.notice, "              deactivate [instance=<number>]", .{});
    log.print(log.Level.notice, "              looptest [<loop times> [<loop interval(in ms)> [<instance>]]]", .{});
}

fn setUsage() void {
    log.print(log.Level.notice, "\nSOL set parameters and values: \n", .{});
    log.print(log.Level.notice, "  set-in-progress             set-complete | set-in-progress | commit-write", .{});
    log.print(log.Level.notice, "  enabled                     true | false", .{});
    log.print(log.Level.notice, "  force-encryption            true | false", .{});
    log.print(log.Level.notice, "  force-authentication        true | false", .{});
    log.print(log.Level.notice, "  privilege-level             user | operator | admin | oem", .{});
    log.print(log.Level.notice, "  character-accumulate-level  <in 5 ms increments>", .{});
    log.print(log.Level.notice, "  character-send-threshold    N", .{});
    log.print(log.Level.notice, "  retry-count                 N", .{});
    log.print(log.Level.notice, "  retry-interval              <in 10 ms increments>", .{});
    log.print(log.Level.notice, "  non-volatile-bit-rate       serial | 9.6 | 19.2 | 38.4 | 57.6 | 115.2", .{});
    log.print(log.Level.notice, "  volatile-bit-rate           serial | 9.6 | 19.2 | 38.4 | 57.6 | 115.2", .{});
    log.print(log.Level.notice, "", .{});
}

fn parseInstance(arg: [*:0]const u8, out: *u8) bool {
    if (c.str2uchar(arg + 9, out) == 0) return true;
    log.print(log.Level.err, "Given instance '%s' is invalid.", .{arg + 9});
    usage();
    return false;
}

fn main(intf: *Intf, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc == 0 or eql(argv[0], "help")) {
        usage();
        return 0;
    }
    if (eql(argv[0], "info")) {
        var channel: u8 = 0x0e;
        if (argc == 2) {
            if (c.is_ipmi_channel_num(argv[1], &channel) != 0) return -1;
        } else if (argc != 1) {
            usage();
            return -1;
        }
        return printSolInfo(intf, channel);
    }
    if (eql(argv[0], "payload")) {
        if (argc < 2 or argc > 4) {
            usage();
            return -1;
        }
        var channel: u8 = 0x0e;
        var userid: u8 = 1;
        if (argc >= 3 and c.is_ipmi_channel_num(argv[2], &channel) != 0) return -1;
        if (argc == 4 and c.is_ipmi_user_id(argv[3], &userid) != 0) return -1;
        if (eql(argv[1], "status")) return payloadAccessStatus(intf, channel, userid);
        if (eql(argv[1], "enable")) return payloadAccess(intf, channel, userid, 1);
        if (eql(argv[1], "disable")) return payloadAccess(intf, channel, userid, 0);
        usage();
        return -1;
    }
    if (eql(argv[0], "set")) {
        var channel: u8 = 0x0e;
        var guarded: u8 = 1;
        if (argc == 4) {
            if (eql(argv[3], "noguard")) guarded = 0 else if (c.is_ipmi_channel_num(argv[3], &channel) != 0) return -1;
        } else if (argc == 5) {
            if (c.is_ipmi_channel_num(argv[3], &channel) != 0) return -1;
            if (eql(argv[4], "noguard")) guarded = 0;
        } else if (argc != 3) {
            setUsage();
            return -1;
        }
        return setParam(intf, channel, argv[1], argv[2], guarded);
    }
    if (eql(argv[0], "activate") or eql(argv[0], "deactivate")) {
        const is_activate = eql(argv[0], "activate");
        var instance: u8 = 1;
        for (argv[1..@intCast(argc)]) |arg| {
            if (is_activate and eql(arg, "usesolkeepalive")) {
                use_sol_keepalive = true;
            } else if (is_activate and eql(arg, "nokeepalive")) {
                disable_keepalive = true;
            } else if (std.mem.startsWith(u8, std.mem.span(arg), "instance=")) {
                if (!parseInstance(arg, &instance)) return -1;
            } else {
                usage();
                return -1;
            }
        }
        return if (is_activate) activate(intf, false, 0, instance) else deactivate(intf, instance);
    }
    if (eql(argv[0], "looptest")) {
        if (argc > 4) {
            usage();
            return -1;
        }
        var count: c_int = 200;
        var interval: c_int = 100;
        var instance: u8 = 1;
        if (argc >= 2) {
            if (c.str2int(argv[1], &count) != 0) {
                log.print(log.Level.err, "Given cnt '%s' is invalid.", .{argv[1]});
                return -1;
            }
            if (count <= 0) count = 200;
        }
        if (argc >= 3) {
            if (c.str2int(argv[2], &interval) != 0) {
                log.print(log.Level.err, "Given interval '%s' is invalid.", .{argv[2]});
                return -1;
            }
            if (interval < 0) interval = 0;
        }
        if (argc == 4 and c.str2uchar(argv[3], &instance) != 0) {
            log.print(log.Level.err, "Given instance '%s' is invalid.", .{argv[3]});
            usage();
            return -1;
        }
        var stdout = std.Io.File.stdout().writerStreaming(std.Options.debug_io, &.{});
        return loopTestTo(intf, count, interval, instance, &stdout.interface, stdout_io.trySyncC) catch |err| {
            logInteractiveOutputError(err, stdout.err orelse error.WriteFailed);
            return -1;
        };
    }
    usage();
    return -1;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(main), @TypeOf(c.ipmi_sol_main));
    abi.assertCallSignature(@TypeOf(getSolInfo), @TypeOf(c.ipmi_get_sol_info));
    abi.assertCallSignature(@TypeOf(payloadAccess), @TypeOf(c.ipmi_sol_payload_access));
    abi.assertCallSignature(@TypeOf(payloadAccessStatus), @TypeOf(c.ipmi_sol_payload_access_status));
    abi.assertCallSignature(@TypeOf(isValidU8), @TypeOf(c.ipmi_sol_set_param_isvalid_uint8_t));
    abi.assertCallSignature(@TypeOf(leaveRawMode), @TypeOf(c.leave_raw_mode));
    abi.assertCallSignature(@TypeOf(enterRawMode), @TypeOf(c.enter_raw_mode));
    abi.assertLayout(Config, c.struct_sol_config_parameters);
    @export(&sol_parameter_vals, .{ .name = "sol_parameter_vals", .linkage = .strong });
    @export(&main, .{ .name = "ipmi_sol_main", .linkage = .strong });
    @export(&getSolInfo, .{ .name = "ipmi_get_sol_info", .linkage = .strong });
    @export(&payloadAccess, .{ .name = "ipmi_sol_payload_access", .linkage = .strong });
    @export(&payloadAccessStatus, .{ .name = "ipmi_sol_payload_access_status", .linkage = .strong });
    @export(&isValidU8, .{ .name = "ipmi_sol_set_param_isvalid_uint8_t", .linkage = .strong });
    @export(&enterRawMode, .{ .name = "enter_raw_mode", .linkage = .strong });
    @export(&leaveRawMode, .{ .name = "leave_raw_mode", .linkage = .strong });
}
