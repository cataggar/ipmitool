//! Serial over LAN command and interactive session, selected by
//! `zig build -Dzig-modules=sol` in place of lib/ipmi_sol.c.
//! The request/response and payload types are shared ABI-checked Zig mirrors;
//! libc handles formatting and terminal control to preserve CLI behaviour.
//! Diagnostics use typed `log.print()` from the same selected archive as the
//! logger state; without the Zig logger it retains the C `lprintf` fallback.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const log = @import("../util/log.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
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
        _ = c.printf("User %d on channel %d is %sabled\n", @as(c_int, userid), @as(c_int, channel), choose(rsp.data[0] & 2 != 0, "en", "dis"));
        return 0;
    }
    log.print(log.Level.err, "Error getting SOL payload status for user %d on channel %d: %s", .{ @as(c_int, userid), @as(c_int, channel), cc(rsp.ccode) });
    return -1;
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

fn printSolInfo(intf: *Intf, channel: u8) c_int {
    var p = std.mem.zeroes(Config);
    if (getSolInfo(intf, channel, &p) != 0) return -1;
    const progress = c.val2str(p.set_in_progress & 3, c.ipmi_set_in_progress_vals);
    const privilege = c.val2str(p.privilege_level, c.ipmi_privlvl_vals);
    const volatile_rate = c.val2str(p.volatile_bit_rate, c.ipmi_bit_rate_vals);
    const nonvolatile_rate = c.val2str(p.non_volatile_bit_rate, c.ipmi_bit_rate_vals);
    if (c.csv_output != 0) {
        _ = c.printf("%s,%s,%s,%s,%s,%d,%d,%d,%d,%s,%s,%d,%d\n", progress, choose(p.enabled != 0, "true", "false"), choose(p.force_encryption != 0, "true", "false"), choose(p.force_encryption != 0, "true", "false"), privilege, @as(c_int, p.character_accumulate_level) * 5, @as(c_int, p.character_send_threshold), @as(c_int, p.retry_count), @as(c_int, p.retry_interval) * 10, volatile_rate, nonvolatile_rate, @as(c_int, p.payload_channel), @as(c_int, p.payload_port));
    } else {
        _ = c.printf("Set in progress                 : %s\n", progress);
        _ = c.printf("Enabled                         : %s\n", choose(p.enabled != 0, "true", "false"));
        _ = c.printf("Force Encryption                : %s\n", choose(p.force_encryption != 0, "true", "false"));
        _ = c.printf("Force Authentication            : %s\n", choose(p.force_authentication != 0, "true", "false"));
        _ = c.printf("Privilege Level                 : %s\n", privilege);
        _ = c.printf("Character Accumulate Level (ms) : %d\n", @as(c_int, p.character_accumulate_level) * 5);
        _ = c.printf("Character Send Threshold        : %d\n", @as(c_int, p.character_send_threshold));
        _ = c.printf("Retry Count                     : %d\n", @as(c_int, p.retry_count));
        _ = c.printf("Retry Interval (ms)             : %d\n", @as(c_int, p.retry_interval) * 10);
        _ = c.printf("Volatile Bit Rate (kbps)        : %s\n", volatile_rate);
        _ = c.printf("Non-Volatile Bit Rate (kbps)    : %s\n", nonvolatile_rate);
        _ = c.printf("Payload Channel                 : %d (0x%02x)\n", @as(c_int, p.payload_channel), @as(c_uint, p.payload_channel));
        _ = c.printf("Payload Port                    : %d\n", @as(c_int, p.payload_port));
    }
    return 0;
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

fn printEscapes(intf: *Intf) void {
    const e: c_int = intf.ssn_params.sol_escape_char;
    _ = c.printf(
        "%c?\n\tSupported escape sequences:\n\t%c.  - terminate connection\n" ++
            "\t%c^Z - suspend ipmitool\n\t%c^X - suspend ipmitool, but don't restore tty on restart\n" ++
            "\t%cB  - send break\n\t%c?  - this message\n" ++
            "\t%c%c  - send the escape character by typing it twice\n" ++
            "\t(Note that escapes are only recognized immediately after newline.)\n",
        e,
        e,
        e,
        e,
        e,
        e,
        e,
        e,
    );
}

const EscapeState = struct {
    pending: bool = false,
    last_cr: bool = true,
};
var escape_state: EscapeState = .{};

fn processUserInput(intf: *Intf, input: []const u8) c_int {
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
                    _ = c.printf("%c. [terminated ipmitool]\n", @as(c_int, e));
                    result = 1;
                },
                26 => {
                    _ = c.printf("%c^Z [suspend ipmitool]\n", @as(c_int, e));
                    suspendSelf(true);
                    continue;
                },
                24 => {
                    _ = c.printf("%c^Z [suspend ipmitool]\n", @as(c_int, e));
                    suspendSelf(false);
                    continue;
                },
                'B' => {
                    _ = c.printf("%cB [send break]\n", @as(c_int, e));
                    sendBreak(intf);
                    continue;
                },
                '?' => {
                    printEscapes(intf);
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

fn sessionLoop(intf: *Intf, instance: c_int) c_int {
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
            const rc = processUserInput(intf, buffer[0..@intCast(count)]);
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

fn activate(intf: *Intf, looptest: bool, interval: c_int, instance: c_int) c_int {
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
    _ = c.printf("[SOL Session operational.  Use %c? for help]\n", @as(c_int, intf.ssn_params.sol_escape_char));
    if (looptest) {
        _ = deactivate(intf, instance);
        if (interval > 0) _ = c.usleep(@as(c_uint, @intCast(interval)) *% 1000);
        return 0;
    }
    if (sessionLoop(intf, instance) != 0) {
        _ = deactivate(intf, instance);
        log.print(log.Level.err, "Error in SOL session", .{});
        return -1;
    }
    return 0;
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
        while (count > 0) : (count -= 1) {
            _ = c.printf("remain loop test counter: %d\n", count);
            const result = activate(intf, true, interval, instance);
            if (result != 0) {
                _ = c.printf("SOL looptest failed: %d\n", result);
                return result;
            }
        }
        return 0;
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
