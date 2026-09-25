// Copyright (c) 2012 Pigeon Point Systems.  All Rights Reserved.
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

//! IPMI Serial Basic Mode: binary IPMB frames with A0/A5 delimiters and AA escaping.
const std = @import("std");
const c = @import("ipmi_c");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("intf.zig").Intf;
const serial = @import("serial.zig");
const log = @import("../util/log.zig");

const max_message = 47;
const Context = serial.Context;
var system_interface = false;
var response: ipmi.Response = std.mem.zeroes(ipmi.Response);

fn setup(intf: *Intf) callconv(.c) c_int {
    intf.max_request_data_size = 33;
    intf.max_response_data_size = 32;
    return 0;
}
fn open(intf: *Intf) callconv(.c) c_int {
    return serial.open(intf, &system_interface);
}
fn close(intf: *Intf) callconv(.c) void {
    serial.close(intf);
}

fn escaped(byte: u8) ?u8 {
    return switch (byte) {
        0xa0 => 0xb0,
        0xa5 => 0xb5,
        0xa6 => 0xb6,
        0xaa => 0xba,
        0x1b => 0x3b,
        else => null,
    };
}
fn unescaped(byte: u8) ?u8 {
    return switch (byte) {
        0xb0 => 0xa0,
        0xb5 => 0xa5,
        0xb6 => 0xa6,
        0xba => 0xaa,
        0x3b => 0x1b,
        else => null,
    };
}
fn frame(bytes: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    out[n] = 0xa0;
    n += 1;
    for (bytes) |b| {
        if (escaped(b)) |escape| {
            out[n] = 0xaa;
            out[n + 1] = escape;
            n += 2;
        } else {
            out[n] = b;
            n += 1;
        }
    }
    out[n] = 0xa5;
    return out[0 .. n + 1];
}

const Parser = struct {
    len: usize = 0,
    started: bool = false,
    escape: bool = false,
    msg: [max_message]u8 = undefined,

    fn feed(self: *Parser, b: u8) ?[]const u8 {
        if (b == 0xa0) {
            self.started = true;
            self.escape = false;
            self.len = 0;
            return null;
        }
        if (!self.started) return null;
        if (self.escape) {
            self.escape = false;
            const decoded = unescaped(b) orelse {
                log.print(log.Level.err, "ipmitool: bad response", .{});
                self.started = false;
                return null;
            };
            if (self.len == self.msg.len) {
                log.print(log.Level.err, "ipmitool: response is too long", .{});
                self.started = false;
                return null;
            }
            self.msg[self.len] = decoded;
            self.len += 1;
        } else if (b == 0xaa) {
            self.escape = true;
        } else if (b == 0xa5) {
            self.started = false;
            return self.msg[0..self.len];
        } else if (b != 0xa6) {
            if (self.len == self.msg.len) {
                log.print(log.Level.err, "ipmitool: response is too long", .{});
                self.started = false;
                return null;
            }
            self.msg[self.len] = b;
            self.len += 1;
        }
        return null;
    }
};

fn waitResponse(intf: *Intf, parser: *Parser, context: Context) serial.Error![]const u8 {
    while (true) {
        try serial.wait(intf.fd, intf.ssn_params.timeout, c.POLLIN);
        var byte: u8 = undefined;
        const n = c.read(intf.fd, &byte, 1);
        if (n < 0 and (std.c._errno().* == c.EINTR or std.c._errno().* == c.EAGAIN)) continue;
        if (n != 1) return error.Io;
        if (parser.feed(byte)) |packet| {
            if (packet.len < 8) {
                log.print(log.Level.err, "ipmitool: response is too short", .{});
                continue;
            }
            if (serial.checksum(packet[0..3]) != 0) {
                log.print(log.Level.err, "ipmitool: bad checksum 1", .{});
                continue;
            }
            if (serial.checksum(packet[3..]) != 0) {
                log.print(log.Level.err, "ipmitool: bad checksum 2", .{});
                continue;
            }
            if (serial.match(.basic, packet, context)) |matched| return matched;
        }
    }
}

fn send(intf: *Intf, data: []const u8) serial.Error!void {
    var encoded: [2 * max_message + 2]u8 = undefined;
    try serial.writeAll(intf, frame(data, &encoded));
}

fn queued(intf: *Intf, parser: *Parser, context: Context, out: []u8) serial.Error!?[]const u8 {
    var msg: [7]u8 = .{ 0x20, 0x18, 0xc8, 0x81, 0, 0x33, 0 };
    const start = serial.monotonicMs();
    while (serial.monotonicMs() - start < @as(i64, intf.ssn_params.timeout) * 1000) {
        const seq = serial.nextSequence(.basic);
        msg[4] = seq;
        msg[6] = serial.checksum(msg[3..6]);
        serial.flush(intf.fd);
        try send(intf, &msg);
        const payload = waitResponse(intf, parser, .{ .sa = 0x20, .requester = 0x81, .netfn = 0x18, .seq = seq, .cmd = 0x33 }) catch |err| {
            if (err == error.Timeout) return null;
            return err;
        };
        if (payload.len < 1) return error.InvalidResponse;
        if (payload[0] == 0x80) continue;
        if (payload[0] != 0) return null;
        // Get Message response: completion, channel, inner netfn, checksum1,
        // responder address, requester seq, cmd, completion, data, checksum2.
        if (payload.len < 9) return error.InvalidResponse;
        const expected_netfn = ((context.netfn | 4) & ~@as(u8, 3)) | (context.seq & 3);
        const expected_seq = (context.seq & ~@as(u8, 3)) | (context.netfn & 3);
        if (payload[2] != expected_netfn or payload[4] != context.sa or
            payload[5] != expected_seq or payload[6] != context.cmd) continue;
        const body = payload[7 .. payload.len - 1];
        if (body.len > out.len) return error.InvalidResponse;
        @memcpy(out[0..body.len], body);
        return out[0..body.len];
    }
    return null;
}

fn sendrecv(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    if (intf.opened == 0 and (intf.open orelse return null)(intf) < 0) return null;
    var parser: Parser = .{};
    var msg: [max_message]u8 = undefined;
    var queued_data: [max_message]u8 = undefined;
    var retry: c_int = 0;
    while (retry < intf.ssn_params.retry) : (retry += 1) {
        const built = serial.build(.basic, intf, req, &msg, system_interface) catch {
            log.print(log.Level.err, "ipmitool: Message data is too long", .{});
            return null;
        };
        serial.flush(intf.fd);
        send(intf, msg[0..built.len]) catch return null;
        var part = waitResponse(intf, &parser, built.ctx[0]) catch |err| {
            if (err == error.Timeout) continue;
            return null;
        };
        if (built.depth != 0 and part[0] == 0) {
            if (system_interface) {
                part = (queued(intf, &parser, built.ctx[1], &queued_data) catch return null) orelse continue;
            } else if (part.len == 1) {
                part = waitResponse(intf, &parser, built.ctx[1]) catch |err| {
                    if (err == error.Timeout) continue;
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

var basic_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    @memcpy(i.name[0.."serial-basic".len], "serial-basic");
    @memcpy(i.desc[0.."Serial Interface, Basic Mode".len], "Serial Interface, Basic Mode");
    i.setup = setup;
    i.open = open;
    i.close = close;
    i.sendrecv = sendrecv;
    break :blk i;
};

pub fn exportSymbols() void {
    @export(&basic_intf, .{ .name = "ipmi_serial_bm_intf" });
}

test "serial basic escaping and fragmented parser" {
    const data = [_]u8{ 0xa0, 0xa5, 0xa6, 0xaa, 0x1b, 0x00 };
    var buf: [2 * data.len + 2]u8 = undefined;
    const encoded = frame(&data, &buf);
    try std.testing.expectEqualSlices(u8, &.{ 0xa0, 0xaa, 0xb0, 0xaa, 0xb5, 0xaa, 0xb6, 0xaa, 0xba, 0xaa, 0x3b, 0, 0xa5 }, encoded);
    var parser: Parser = .{};
    for (encoded[0 .. encoded.len - 1]) |b| try std.testing.expect(parser.feed(b) == null);
    try std.testing.expectEqualSlices(u8, &data, parser.feed(encoded[encoded.len - 1]).?);
    for ([_]u8{ 0xa0, 0xaa, 0x99, 0xa5 }) |b| try std.testing.expect(parser.feed(b) == null);
    for (encoded) |b| {
        if (parser.feed(b)) |packet| try std.testing.expectEqualSlices(u8, &data, packet);
    }
}
