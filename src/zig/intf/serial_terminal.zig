// Copyright (c) 2007-2012 Pigeon Point Systems.  All Rights Reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//
// Redistribution of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//
// Redistribution in binary form must reproduce the above copyright
// notice, this list of conditions and the following disclaimer in the
// documentation and/or other materials provided with the distribution.
//
// Neither the name of Pigeon Point Systems nor the names of
// contributors may be used to endorse or promote products derived
// from this software without specific prior written permission.
//
// This software is provided "AS IS," without a warranty of any kind.
// ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
// INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A
// PARTICULAR PURPOSE OR NON-INFRINGEMENT, ARE HEREBY EXCLUDED.
// PIGEON POINT SYSTEMS ("PPS") AND ITS LICENSORS SHALL NOT BE LIABLE
// FOR ANY DAMAGES SUFFERED BY LICENSEE AS A RESULT OF USING, MODIFYING
// OR DISTRIBUTING THIS SOFTWARE OR ITS DERIVATIVES.  IN NO EVENT WILL
// PPS OR ITS LICENSORS BE LIABLE FOR ANY LOST REVENUE, PROFIT OR DATA,
// OR FOR DIRECT, INDIRECT, SPECIAL, CONSEQUENTIAL, INCIDENTAL OR
// PUNITIVE DAMAGES, HOWEVER CAUSED AND REGARDLESS OF THE THEORY OF
// LIABILITY, ARISING OUT OF THE USE OF OR INABILITY TO USE THIS SOFTWARE,
// EVEN IF PPS HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

//! IPMI Serial Terminal Mode: bracketed hexadecimal records over an 8N1 tty.
const std = @import("std");
const c = @import("ipmi_c");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("intf.zig").Intf;
const serial = @import("serial.zig");
const log = @import("../util/log.zig");

const max_message = 256;
const Context = serial.Context;
var system_interface = false;
var response: ipmi.Response = std.mem.zeroes(ipmi.Response);

fn setup(intf: *Intf) callconv(.c) c_int {
    intf.max_request_data_size = 37;
    intf.max_response_data_size = 36;
    return 0;
}
fn open(intf: *Intf) callconv(.c) c_int {
    return serial.open(intf, &system_interface);
}
fn close(intf: *Intf) callconv(.c) void {
    serial.close(intf);
}

const digits = "0123456789abcdef";
fn encode(data: []const u8, out: []u8) []const u8 {
    out[0] = '[';
    for (data, 0..) |byte, i| {
        out[1 + i * 2] = digits[byte >> 4];
        out[2 + i * 2] = digits[byte & 0xf];
    }
    const end = data.len * 2 + 1;
    @memcpy(out[end..][0..3], "]\r\n");
    return out[0 .. end + 3];
}

fn hex(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}
fn decode(text: []const u8, out: []u8) serial.Error![]const u8 {
    if (std.mem.startsWith(u8, text, "ERR ")) return error.Timeout;
    var n: usize = 0;
    var high: ?u8 = null;
    for (text) |ch| {
        if (hex(ch)) |digit| {
            if (high) |h| {
                if (n == out.len) return error.InvalidResponse;
                out[n] = h * 16 + digit;
                n += 1;
                high = null;
            } else high = digit;
        } else if (std.ascii.isWhitespace(ch)) {
            if (high != null) return error.InvalidResponse;
        } else return error.InvalidResponse;
    }
    if (high != null) return error.InvalidResponse;
    return out[0..n];
}

fn readPacket(intf: *Intf, out: []u8) serial.Error![]const u8 {
    var line: [max_message * 3]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try serial.wait(intf.fd, intf.ssn_params.timeout, c.POLLIN);
        var b: u8 = undefined;
        const n = c.read(intf.fd, &b, 1);
        if (n < 0 and (std.c._errno().* == c.EINTR or std.c._errno().* == c.EAGAIN)) continue;
        if (n != 1) return error.Io;
        if (b == '\n' or b == '\r') {
            if (len == 0 or line[len - 1] != ']') {
                if (std.mem.indexOfScalar(u8, line[0..len], '[') == null) {
                    len = 0;
                } else if (len < line.len) {
                    line[len] = ' ';
                    len += 1;
                } else {
                    return error.InvalidResponse;
                }
                continue;
            }
            const open_bracket = std.mem.lastIndexOfScalar(u8, line[0..len], '[') orelse {
                log.print(log.Level.err, "Serial response is invalid", .{});
                return error.InvalidResponse;
            };
            return decode(line[open_bracket + 1 .. len - 1], out) catch |err| {
                log.print(log.Level.err, "Serial response is invalid", .{});
                return err;
            };
        }
        if (len == line.len) {
            len = 0;
            return error.InvalidResponse;
        }
        line[len] = b;
        len += 1;
    }
}

fn waitResponse(intf: *Intf, ctx: Context, out: []u8) serial.Error![]const u8 {
    while (true) {
        const packet = try readPacket(intf, out);
        if (serial.match(.terminal, packet, ctx)) |matched| return matched;
    }
}

fn send(intf: *Intf, data: []const u8) serial.Error!void {
    var encoded: [max_message * 2 + 4]u8 = undefined;
    try serial.writeAll(intf, encode(data, &encoded));
}

fn queued(intf: *Intf, context: Context, out: []u8) serial.Error!?[]const u8 {
    const start = serial.monotonicMs();
    var raw: [max_message]u8 = undefined;
    while (serial.monotonicMs() - start < @as(i64, intf.ssn_params.timeout) * 1000) {
        const seq = serial.nextSequence(.terminal);
        serial.flush(intf.fd);
        try send(intf, &.{ 0x18, seq, 0x33 });
        const part = waitResponse(intf, .{ .netfn = 0x18, .seq = seq, .cmd = 0x33 }, &raw) catch |err| {
            if (err == error.Timeout) return null;
            return err;
        };
        if (part.len < 1) return error.InvalidResponse;
        if (part[0] == 0x80) continue;
        if (part[0] != 0) return null;
        if (part.len < 9) return error.InvalidResponse;
        const netfn = ((context.netfn | 4) & ~@as(u8, 3)) | (context.seq & 3);
        if (part[2] != netfn or part[4] != context.sa or
            part[5] != (context.seq & ~@as(u8, 3)) or part[6] != context.cmd) continue;
        const body = part[7 .. part.len - 1];
        if (body.len > out.len) return error.InvalidResponse;
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }
    return null;
}

fn sendrecv(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    if (intf.opened == 0 and (intf.open orelse return null)(intf) < 0) return null;
    var msg: [max_message]u8 = undefined;
    var queued_data: [max_message]u8 = undefined;
    var retry: c_int = 0;
    while (retry < intf.ssn_params.retry) : (retry += 1) {
        const built = serial.build(.terminal, intf, req, &msg, system_interface) catch {
            log.print(log.Level.err, "ipmitool: Message data is too long", .{});
            return null;
        };
        serial.flush(intf.fd);
        send(intf, msg[0..built.len]) catch return null;
        var part = waitResponse(intf, built.ctx[0], &msg) catch |err| {
            if (err == error.Timeout or err == error.InvalidResponse) continue;
            return null;
        };
        if (built.depth != 0 and part[0] == 0) {
            if (system_interface) {
                part = (queued(intf, built.ctx[1], &queued_data) catch return null) orelse continue;
            } else if (part.len == 1) {
                part = waitResponse(intf, built.ctx[1], &msg) catch |err| {
                    if (err == error.Timeout or err == error.InvalidResponse) continue;
                    return null;
                };
            } else {
                part = serial.unpack(part, built.depth) orelse return null;
            }
        }
        if (built.depth == 2 and part.len > 1 and part[0] == 0) {
            part = serial.unpack(part, 1) orelse return null;
        }
        if (part.len == 0 or part.len - 1 > response.data.len) return null;
        response.ccode = part[0];
        response.data_len = @intCast(part.len - 1);
        @memcpy(response.data[0..@intCast(response.data_len)], part[1..]);
        return &response;
    }
    return null;
}

var terminal_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    @memcpy(i.name[0.."serial-terminal".len], "serial-terminal");
    @memcpy(i.desc[0.."Serial Interface, Terminal Mode".len], "Serial Interface, Terminal Mode");
    i.setup = setup;
    i.open = open;
    i.close = close;
    i.sendrecv = sendrecv;
    break :blk i;
};

pub fn exportSymbols() void {
    @export(&terminal_intf, .{ .name = "ipmi_serial_term_intf" });
}

test "serial terminal hex framing and invalid data" {
    var output: [15]u8 = undefined;
    try std.testing.expectEqualStrings("[180401a5]\r\n", encode(&.{ 0x18, 4, 1, 0xa5 }, &output));
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0x18, 4, 1, 0xa5 }, try decode("18 04 01 a5", &bytes));
    try std.testing.expectError(error.InvalidResponse, decode("18 0", &bytes));
    try std.testing.expectError(error.InvalidResponse, decode("18 zz", &bytes));
    try std.testing.expectError(error.Timeout, decode("ERR 80", &bytes));
}
