//! IPMI v1.5 Serial over LAN configuration and interactive session.
//!
//! Replaces `lib/ipmi_isol.c` when selected with `-Dzig-modules=isol`. The
//! three configuration reads, write, activation and deactivation retain their
//! C wire format, order, messages and exit codes. The interactive session
//! keeps the C escape-state machine and termios/select loop.
//!
//! Intentional safety differences: successful Get Config responses shorter
//! than two bytes are rejected rather than reading stale response data;
//! missing session/SOL transport callbacks and out-of-range descriptors
//! return errors rather than dereferencing null pointers or indexing past
//! `fd_set`. SOL output is clamped to the response buffer. An early select
//! error also restores terminal mode before returning.

const std = @import("std");
const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("../intf/intf.zig").Intf;
const log = @import("../util/log.zig");

const Request = ipmi.Request;
const Response = ipmi.Response;
const Payload = ipmi.V2Payload;
const escape: u8 = '~';

const Error = error{
    NoResponse,
    Unsupported,
    CompletionCode,
    ShortResponse,
    InvalidParameter,
    InvalidValue,
    SetFailed,
    Disabled,
    NoSession,
    ActivateFailed,
    InvalidResponse,
    SelectFailure,
    AllocationFailure,
    InvalidDescriptor,
    NoTransport,
};
const Config = struct { enabled: u8 = 0, privilege_level: u8 = 0, bit_rate: u8 = 0 };

var saved_tio: c.struct_termios = std.mem.zeroes(c.struct_termios);
var in_raw_mode = false;
var escape_pending = false;
var last_was_cr = true;

fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

fn getInfo(intf: *Intf) Error!Config {
    var params: Config = .{};
    var req = std.mem.zeroes(Request);
    var data: [6]u8 = @splat(0);
    req.msg.netfn_lun.netfn = ipmi.NetFn.isol;
    req.msg.cmd = c.GET_ISOL_CONFIG;
    req.msg.data = &data;
    req.msg.data_len = 4;

    const fields = [_]struct { selector: u8, field: *u8 }{
        .{ .selector = c.ISOL_ENABLE_PARAM, .field = &params.enabled },
        .{ .selector = c.ISOL_AUTHENTICATION_PARAM, .field = &params.privilege_level },
        .{ .selector = c.ISOL_BAUD_RATE_PARAM, .field = &params.bit_rate },
    };
    for (fields, 0..) |f, i| {
        @memset(&data, 0);
        data[1] = f.selector;
        const rsp = sendrecv(intf, &req) orelse {
            c.lprintf(log.Level.err, "Error in Get ISOL Config Command");
            return error.NoResponse;
        };
        if (i == 0 and rsp.ccode == 0xc1) {
            c.lprintf(log.Level.err, "IPMI v1.5 Serial Over Lan (ISOL) not supported!");
            return error.Unsupported;
        }
        if (rsp.ccode != 0) {
            c.lprintf(log.Level.err, "Error in Get ISOL Config Command: %s", c.val2str(rsp.ccode, c.completion_code_vals));
            return error.CompletionCode;
        }
        if (rsp.data_len < 2) {
            c.lprintf(log.Level.err, "Error in Get ISOL Config Command: short response (%d)", rsp.data_len);
            return error.ShortResponse;
        }
        f.field.* = rsp.data[1];
    }
    return params;
}

fn printInfo(intf: *Intf) Error!void {
    const params = try getInfo(intf);
    const enabled: [*:0]const u8 = if (params.enabled & 1 != 0) "true" else "false";
    const privilege = c.val2str(params.privilege_level & 0x0f, c.ipmi_privlvl_vals);
    const baud = c.val2str(params.bit_rate & 0x0f, c.ipmi_bit_rate_vals);
    if (c.csv_output != 0) {
        _ = c.printf("%s,%s,%s,", enabled, privilege, baud);
    } else {
        _ = c.printf("Enabled                         : %s\n", enabled);
        _ = c.printf("Privilege Level                 : %s\n", privilege);
        _ = c.printf("Bit Rate (kbps)                 : %s\n", baud);
    }
}

fn equals(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

fn setParam(intf: *Intf, param: [*:0]const u8, value: [*:0]const u8) Error!void {
    // C reads the existing configuration even for an invalid parameter.
    const params = try getInfo(intf);
    var req = std.mem.zeroes(Request);
    var data: [6]u8 = @splat(0);
    req.msg.netfn_lun.netfn = ipmi.NetFn.isol;
    req.msg.cmd = c.SET_ISOL_CONFIG;
    req.msg.data = &data;
    req.msg.data_len = 3;

    if (equals(param, "enabled")) {
        data[1] = c.ISOL_ENABLE_PARAM;
        if (equals(value, "true")) {
            data[2] = 1;
        } else if (equals(value, "false")) {
            data[2] = 0;
        } else {
            c.lprintf(log.Level.err, "Invalid value %s for parameter %s", value, param);
            c.lprintf(log.Level.err, "Valid values are true and false");
            return error.InvalidValue;
        }
    } else if (equals(param, "privilege-level")) {
        data[1] = c.ISOL_AUTHENTICATION_PARAM;
        data[2] = if (equals(value, "user"))
            2
        else if (equals(value, "operator"))
            3
        else if (equals(value, "admin"))
            4
        else if (equals(value, "oem"))
            5
        else {
            c.lprintf(log.Level.err, "Invalid value %s for parameter %s", value, param);
            c.lprintf(log.Level.err, "Valid values are user, operator, admin, and oem");
            return error.InvalidValue;
        };
        data[2] |= params.privilege_level & 0x80;
    } else if (equals(param, "bit-rate")) {
        data[1] = c.ISOL_BAUD_RATE_PARAM;
        data[2] = if (equals(value, "9.6"))
            6
        else if (equals(value, "19.2"))
            7
        else if (equals(value, "38.4"))
            8
        else if (equals(value, "57.6"))
            9
        else if (equals(value, "115.2"))
            10
        else {
            c.lprintf(log.Level.err, "ISOL - Unsupported baud rate: %s", value);
            c.lprintf(log.Level.err, "Valid values are 9.6, 19.2, 38.4, 57.6 and 115.2");
            return error.InvalidValue;
        };
    } else {
        c.lprintf(log.Level.err, "Error: invalid ISOL parameter %s", param);
        return error.InvalidParameter;
    }

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error setting ISOL parameter '%s'", param);
        return error.NoResponse;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error setting ISOL parameter '%s': %s", param, c.val2str(rsp.ccode, c.completion_code_vals));
        return error.SetFailed;
    }
}

fn leaveRawMode() void {
    if (!in_raw_mode) return;
    if (c.tcsetattr(c.fileno(c.stdin), c.TCSADRAIN, &saved_tio) == -1) {
        c.perror("tcsetattr");
    } else {
        in_raw_mode = false;
    }
}

fn enterRawMode() void {
    var tio: c.struct_termios = undefined;
    if (c.tcgetattr(c.fileno(c.stdin), &tio) == -1) {
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
    if (c.tcsetattr(c.fileno(c.stdin), c.TCSADRAIN, &tio) == -1) {
        c.perror("tcsetattr");
    } else {
        in_raw_mode = true;
    }
}

fn sendBreak(intf: *Intf) void {
    var payload = std.mem.zeroes(Payload);
    payload.payload.sol_packet.generate_break = 1;
    if (intf.send_sol) |send| {
        _ = send(intf, &payload);
    } else {
        c.lprintf(log.Level.err, "Error sending SOL data: transport has no SOL callback");
    }
}

fn suspendSelf(restore: bool) void {
    leaveRawMode();
    _ = c.kill(c.getpid(), c.SIGTSTP);
    if (restore) enterRawMode();
}

fn printEscapes() void {
    _ = c.printf(
        "~?\n\tSupported escape sequences:\n" ++
            "\t~.  - terminate connection\n" ++
            "\t~^Z - suspend ipmitool\n" ++
            "\t~^X - suspend ipmitool, but don't restore tty on restart\n" ++
            "\t~B  - send break\n" ++
            "\t~?  - this message\n" ++
            "\t~~  - send the escape character by typing it twice\n" ++
            "\t(Note that escapes are only recognized immediately after newline.)\n",
    );
}

fn boundedResponseLength(rsp: *const Response) usize {
    if (rsp.data_len <= 0) return 0;
    return @min(@as(usize, @intCast(rsp.data_len)), rsp.data.len);
}

fn output(rsp: ?*Response) callconv(.c) void {
    const r = rsp orelse return;
    const count = boundedResponseLength(r);
    if (count == 0) return;
    for (r.data[0..count]) |ch| _ = c.putc(ch, c.stdout);
    _ = c.fflush(c.stdout);
}

fn deactivate(intf: *Intf) Error!void {
    var req = std.mem.zeroes(Request);
    var data: [6]u8 = @splat(0);
    req.msg.netfn_lun.netfn = ipmi.NetFn.isol;
    req.msg.cmd = c.ACTIVATE_ISOL;
    req.msg.data = &data;
    req.msg.data_len = 5;
    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error deactivating ISOL");
        return error.NoResponse;
    };
    if (rsp.ccode != 0) {
        c.lprintf(log.Level.err, "Error deactivating ISOL: %s", c.val2str(rsp.ccode, c.completion_code_vals));
        return error.CompletionCode;
    }
}

fn processUserInput(intf: *Intf, input: []const u8) c_int {
    var payload = std.mem.zeroes(Payload);
    var len: usize = 0;
    var result: c_int = 0;
    for (input) |ch| {
        if (escape_pending) {
            escape_pending = false;
            switch (ch) {
                '.' => {
                    _ = c.printf("%c. [terminated ipmitool]\n", @as(c_int, escape));
                    result = 1;
                },
                'Z' - 64 => {
                    _ = c.printf("%c^Z [suspend ipmitool]\n", @as(c_int, escape));
                    suspendSelf(true);
                    continue;
                },
                'X' - 64 => {
                    _ = c.printf("%c^X [suspend ipmitool]\n", @as(c_int, escape));
                    suspendSelf(false);
                    continue;
                },
                'B' => {
                    _ = c.printf("%cb [send break]\n", @as(c_int, escape));
                    sendBreak(intf);
                    continue;
                },
                '?' => {
                    printEscapes();
                    continue;
                },
                else => {
                    if (ch != escape) {
                        if (len == ipmi.buf_size) return -1;
                        payload.payload.sol_packet.data[len] = escape;
                        len += 1;
                    }
                    if (len == ipmi.buf_size) return -1;
                    payload.payload.sol_packet.data[len] = ch;
                    len += 1;
                },
            }
        } else {
            if (last_was_cr and ch == escape) {
                escape_pending = true;
                continue;
            }
            if (len == ipmi.buf_size) return -1;
            payload.payload.sol_packet.data[len] = ch;
            len += 1;
        }
        last_was_cr = ch == '\r' or ch == '\n';
    }
    if (len > 0) {
        payload.payload.sol_packet.flush_outbound = 1;
        payload.payload.sol_packet.character_count = @intCast(len);
        const send = intf.send_sol orelse {
            c.lprintf(log.Level.err, "Error sending SOL data");
            return -1;
        };
        const rsp = send(intf, &payload) orelse {
            c.lprintf(log.Level.err, "Error sending SOL data");
            return -1;
        };
        if (rsp.session.payloadtype == @intFromEnum(ipmi.PayloadType.sol) and
            rsp.payload.sol_packet.packet_sequence_number != 0) output(rsp);
    }
    return result;
}

fn fdSet(fds: *c.fd_set, fd: usize) void {
    const bits = &fds.__fds_bits;
    const Word = @TypeOf(bits[0]);
    bits[fd / @bitSizeOf(Word)] |= @as(Word, 1) << @intCast(fd % @bitSizeOf(Word));
}

fn fdIsSet(fds: *const c.fd_set, fd: usize) bool {
    const bits = &fds.__fds_bits;
    const Word = @TypeOf(bits[0]);
    return (bits[fd / @bitSizeOf(Word)] & (@as(Word, 1) << @intCast(fd % @bitSizeOf(Word)))) != 0;
}

fn redPill(intf: *Intf) Error!void {
    const buffer = std.heap.c_allocator.alloc(u8, 255) catch {
        c.lprintf(log.Level.err, "ipmitool: malloc failure");
        return error.AllocationFailure;
    };
    defer std.heap.c_allocator.free(buffer);
    enterRawMode();
    defer leaveRawMode();
    if (intf.fd < 0 or intf.fd >= @as(c_int, @intCast(@sizeOf(c.fd_set) * 8))) {
        c.lprintf(log.Level.err, "Error: invalid ISOL socket descriptor");
        return error.InvalidDescriptor;
    }
    const fd: usize = @intCast(intf.fd);
    var should_exit = false;
    var bmc_closed = false;
    var timedout: u8 = 0;
    while (!should_exit) {
        var fds = std.mem.zeroes(c.fd_set);
        fdSet(&fds, 0);
        fdSet(&fds, fd);
        var tv = c.struct_timeval{ .tv_sec = 0, .tv_usec = 500000 };
        const result = c.select(intf.fd + 1, &fds, null, null, &tv);
        if (result < 0) {
            c.perror("select");
            return error.SelectFailure;
        }
        if (result == 0) {
            timedout += 1;
            if (timedout == 20) {
                const keepalive = intf.keepalive orelse {
                    c.lprintf(log.Level.err, "Error: ISOL transport has no keepalive callback");
                    return error.NoTransport;
                };
                _ = keepalive(intf);
                timedout = 0;
            }
            continue;
        }
        timedout = 0;
        if (fdIsSet(&fds, 0)) {
            @memset(buffer, 0);
            const n = c.read(c.fileno(c.stdin), buffer.ptr, buffer.len);
            if (n > 0) {
                const rc = processUserInput(intf, buffer[0..@intCast(n)]);
                if (rc != 0) {
                    should_exit = true;
                    bmc_closed = rc < 0;
                }
            } else {
                should_exit = true;
            }
        } else if (fdIsSet(&fds, fd)) {
            const receive = intf.recv_sol orelse {
                c.lprintf(log.Level.err, "Error: ISOL transport has no receive callback");
                return error.NoTransport;
            };
            if (receive(intf)) |rsp| {
                output(rsp);
            } else {
                bmc_closed = true;
                should_exit = true;
            }
        } else {
            c.lprintf(log.Level.err, "Error: Select returned with nothing to read");
            should_exit = true;
        }
    }
    if (bmc_closed) {
        c.lprintf(log.Level.err, "SOL session closed by BMC");
    } else {
        deactivate(intf) catch {};
    }
}

fn activate(intf: *Intf) Error!void {
    const params = try getInfo(intf);
    if (params.enabled & 1 == 0) {
        c.lprintf(log.Level.err, "ISOL is not enabled!");
        return error.Disabled;
    }
    const session = intf.session orelse {
        c.lprintf(log.Level.err, "Error: No ISOL session available");
        return error.NoSession;
    };
    session.sol_data.sol_input_handler = output;
    var req = std.mem.zeroes(Request);
    var data: [6]u8 = @splat(0);
    data[0] = 1;
    req.msg.netfn_lun.netfn = ipmi.NetFn.isol;
    req.msg.cmd = c.ACTIVATE_ISOL;
    req.msg.data = &data;
    req.msg.data_len = 5;
    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(log.Level.err, "Error: No response activating ISOL");
        return error.NoResponse;
    };
    switch (rsp.ccode) {
        0 => if (rsp.data_len != 4) {
            c.lprintf(log.Level.err, "Error: Unexpected data length (%d) received in ISOL activation response", rsp.data_len);
            return error.InvalidResponse;
        },
        0x80 => {
            c.lprintf(log.Level.err, "Info: ISOL already active on another session");
            return error.ActivateFailed;
        },
        0x81 => {
            c.lprintf(log.Level.err, "Info: ISOL disabled");
            return error.ActivateFailed;
        },
        0x82 => {
            c.lprintf(log.Level.err, "Info: ISOL activation limit reached");
            return error.ActivateFailed;
        },
        else => {
            c.lprintf(log.Level.err, "Error activating ISOL: %s", c.val2str(rsp.ccode, c.completion_code_vals));
            return error.ActivateFailed;
        },
    }
    _ = c.printf("[SOL Session operational.  Use %c? for help]\n", @as(c_int, escape));
    redPill(intf) catch |err| {
        c.lprintf(log.Level.err, "Error in SOL session");
        return err;
    };
}

fn printSetUsage() void {
    c.lprintf(log.Level.notice, "\nISOL set parameters and values: \n");
    c.lprintf(log.Level.notice, "  enabled                     true | false");
    c.lprintf(log.Level.notice, "  privilege-level             user | operator | admin | oem");
    c.lprintf(log.Level.notice, "  bit-rate                    9.6 | 19.2 | 38.4 | 57.6 | 115.2");
    c.lprintf(log.Level.notice, "");
}

fn printUsage() void {
    c.lprintf(log.Level.notice, "ISOL Commands: info");
    c.lprintf(log.Level.notice, "               set <parameter> <setting>");
    c.lprintf(log.Level.notice, "               activate");
}

fn isolMain(intf: *Intf, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    if (argc <= 0 or argv == null) {
        printUsage();
        return 0;
    }
    const args = argv.?;
    const command = args[0] orelse {
        printUsage();
        return 0;
    };
    if (equals(command, "help")) {
        printUsage();
        return 0;
    } else if (equals(command, "info")) {
        printInfo(intf) catch return -1;
        return 0;
    } else if (equals(command, "set")) {
        if (argc < 3) {
            printSetUsage();
            return -1;
        }
        setParam(intf, args[1].?, args[2].?) catch return -1;
        return 0;
    } else if (equals(command, "activate")) {
        activate(intf) catch return -1;
        return 0;
    }
    printUsage();
    return -1;
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(isolMain), @TypeOf(c.ipmi_isol_main));
    @export(&isolMain, .{ .name = "ipmi_isol_main", .linkage = .strong });
}

test "short successful Get Config response returns a typed error" {
    const Stub = struct {
        var call_count: usize = 0;
        var response: Response = std.mem.zeroes(Response);
        var short_selector: u8 = c.ISOL_ENABLE_PARAM;
        fn send(_: *Intf, request: *Request) callconv(.c) ?*Response {
            call_count += 1;
            response.ccode = 0;
            response.data_len = if (request.msg.data.?[1] == short_selector) 1 else 2;
            response.data[1] = 0xff;
            return &response;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    for ([_]u8{ c.ISOL_ENABLE_PARAM, c.ISOL_AUTHENTICATION_PARAM, c.ISOL_BAUD_RATE_PARAM }, 1..) |selector, n| {
        Stub.short_selector = selector;
        Stub.call_count = 0;
        try std.testing.expectError(error.ShortResponse, getInfo(&intf));
        try std.testing.expectEqual(n, Stub.call_count);
    }
}

test "the input escape state survives reads and preserves doubled escape" {
    const Stub = struct {
        var sent: [4]u8 = @splat(0);
        var n: usize = 0;
        var response: Response = std.mem.zeroes(Response);
        fn send(_: *Intf, payload: *Payload) callconv(.c) ?*Response {
            n = payload.payload.sol_packet.character_count;
            @memcpy(sent[0..n], payload.payload.sol_packet.data[0..n]);
            return &response;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.send_sol = Stub.send;
    escape_pending = false;
    last_was_cr = true;
    Stub.response.session.payloadtype = @intFromEnum(ipmi.PayloadType.sol);
    Stub.response.payload.sol_packet.packet_sequence_number = 0;
    try std.testing.expectEqual(@as(c_int, 0), processUserInput(&intf, "\r~"));
    try std.testing.expectEqual(@as(usize, 1), Stub.n);
    try std.testing.expectEqualSlices(u8, "\r", Stub.sent[0..Stub.n]);
    try std.testing.expectEqual(@as(c_int, 0), processUserInput(&intf, "~"));
    try std.testing.expectEqual(@as(usize, 1), Stub.n);
    try std.testing.expectEqualSlices(u8, "~", Stub.sent[0..Stub.n]);
    try std.testing.expectEqual(@as(c_int, 0), processUserInput(&intf, "x~"));
    try std.testing.expectEqual(@as(usize, 2), Stub.n);
    try std.testing.expectEqualSlices(u8, "x~", Stub.sent[0..Stub.n]);
}

test "successful activation with no session returns an error before sending" {
    const Stub = struct {
        var calls: usize = 0;
        var response: Response = std.mem.zeroes(Response);
        fn send(_: *Intf, req: *Request) callconv(.c) ?*Response {
            calls += 1;
            if (req.msg.cmd != c.GET_ISOL_CONFIG) return null;
            response.ccode = 0;
            response.data_len = 2;
            response.data[1] = 1;
            return &response;
        }
    };
    var intf = std.mem.zeroes(Intf);
    intf.sendrecv = Stub.send;
    Stub.calls = 0;
    try std.testing.expectError(error.NoSession, activate(&intf));
    try std.testing.expectEqual(@as(usize, 3), Stub.calls);
}

test "SOL input without a transport callback reports an error" {
    var intf = std.mem.zeroes(Intf);
    escape_pending = false;
    last_was_cr = true;
    try std.testing.expectEqual(@as(c_int, -1), processUserInput(&intf, "x"));
}

test "SOL output bounds malformed response lengths" {
    var rsp = std.mem.zeroes(Response);
    rsp.data_len = -1;
    try std.testing.expectEqual(@as(usize, 0), boundedResponseLength(&rsp));
    rsp.data_len = 0;
    try std.testing.expectEqual(@as(usize, 0), boundedResponseLength(&rsp));
    rsp.data_len = 1;
    try std.testing.expectEqual(@as(usize, 1), boundedResponseLength(&rsp));
    rsp.data_len = std.math.maxInt(c_int);
    try std.testing.expectEqual(@as(usize, ipmi.buf_size), boundedResponseLength(&rsp));
}
