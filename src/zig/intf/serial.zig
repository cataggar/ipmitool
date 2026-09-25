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

//! Shared device configuration and IPMB encapsulation for the two serial modes.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("ipmi_c");
const ipmi = @import("../core/ipmi.zig");
const Intf = @import("intf.zig").Intf;
const log = @import("../util/log.zig");

pub const Mode = enum { basic, terminal };
pub const Context = struct {
    netfn: u8 = 0,
    seq: u8 = 0,
    cmd: u8 = 0,
    sa: u8 = 0,
    requester: u8 = 0,
};
pub const Built = struct { len: usize, depth: usize, ctx: [2]Context };
pub const Error = error{ InvalidRequest, Io, Timeout, InvalidResponse };

const Rate = struct { baud: c.speed_t, value: u32 };
const rates = [_]Rate{
    .{ .baud = c.B2400, .value = 2400 },
    .{ .baud = c.B9600, .value = 9600 },
    .{ .baud = c.B19200, .value = 19200 },
    .{ .baud = c.B38400, .value = 38400 },
    .{ .baud = c.B57600, .value = 57600 },
    .{ .baud = c.B115200, .value = 115200 },
    .{ .baud = c.B230400, .value = 230400 },
} ++ if (@hasDecl(c, "B460800")) [_]Rate{.{ .baud = c.B460800, .value = 460800 }} else [_]Rate{};

pub fn open(intf: *Intf, system: *bool) c_int {
    const dev = intf.devfile orelse {
        log.print(log.Level.err, "Serial device is not specified", .{});
        return -1;
    };
    system.* = false;
    var rate: u32 = 9600;
    if (c.strchr(dev, ':')) |colon| {
        colon[0] = 0;
        const text = colon + 1;
        if (c.strchr(text, ':')) |second| {
            second[0] = 0;
            system.* = second[1] == 'S' or second[1] == 's';
        }
        if (c.str2uint(text, &rate) != 0) {
            log.print(log.Level.err, "Invalid baud rate specified", .{});
            return -1;
        }
    }
    var baud: ?c.speed_t = null;
    for (rates) |r| {
        if (rate == r.value) baud = r.baud;
    }
    if (baud == null) {
        log.print(log.Level.err, "Unsupported baud rate %u specified", .{rate});
        return -1;
    }
    const fd = c.open(dev, c.O_RDWR | c.O_NONBLOCK, @as(c_int, 0));
    if (fd < 0) {
        log.perror(log.Level.err, "Could not open device at %s", .{dev});
        return -1;
    }
    var ti: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &ti) != 0) {
        _ = c.close(fd);
        return -1;
    }
    _ = c.cfsetispeed(&ti, baud.?);
    _ = c.cfsetospeed(&ti, baud.?);
    ti.c_cflag = (ti.c_cflag & ~(@as(@TypeOf(ti.c_cflag), c.PARENB | c.CSTOPB | c.CSIZE) | @as(@TypeOf(ti.c_cflag), c.CRTSCTS))) | c.CS8 | c.CLOCAL | c.CREAD;
    ti.c_iflag &= ~@as(@TypeOf(ti.c_iflag), c.IGNBRK | c.IGNCR | c.INLCR | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON | c.IXOFF | c.IXANY);
    if (@hasDecl(c, "IUCLC")) ti.c_iflag &= ~@as(@TypeOf(ti.c_iflag), c.IUCLC);
    ti.c_oflag &= ~@as(@TypeOf(ti.c_oflag), c.OPOST);
    ti.c_lflag &= ~@as(@TypeOf(ti.c_lflag), c.ICANON | c.ISIG | c.ECHO | c.ECHONL | c.NOFLSH);
    if (c.tcsetattr(fd, c.TCSAFLUSH, &ti) != 0) {
        _ = c.close(fd);
        return -1;
    }
    intf.fd = fd;
    if (intf.ssn_params.timeout == 0) intf.ssn_params.timeout = 5;
    if (intf.ssn_params.retry == 0) intf.ssn_params.retry = 5;
    intf.opened = 1;
    return 0;
}

pub fn close(intf: *Intf) void {
    if (intf.opened != 0) {
        _ = c.close(intf.fd);
        intf.fd = -1;
    }
    c.ipmi_intf_session_cleanup(@ptrCast(intf));
    intf.opened = 0;
}

pub fn flush(fd: c_int) void {
    _ = c.tcflush(fd, c.TCIOFLUSH);
}

pub fn wait(fd: c_int, timeout: u32, events: c_short) Error!void {
    var pfd: c.struct_pollfd = .{ .fd = fd, .events = events, .revents = 0 };
    const millis: c_int = @intCast(@min(@as(u64, timeout) * 1000, @as(u64, std.math.maxInt(c_int))));
    while (true) {
        const n = c.poll(&pfd, 1, millis);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        if (n < 0 or (pfd.revents & (c.POLLERR | c.POLLNVAL | c.POLLHUP)) != 0) return error.Io;
        if (n == 0) return error.Timeout;
        return;
    }
}

pub fn writeAll(intf: *Intf, data: []const u8) Error!void {
    var at: usize = 0;
    while (at < data.len) {
        const n = c.write(intf.fd, data[at..].ptr, data.len - at);
        if (n > 0) {
            at += @intCast(n);
        } else if (n < 0 and std.c._errno().* == c.EINTR) {
            continue;
        } else if (n < 0 and std.c._errno().* == c.EAGAIN) {
            try wait(intf.fd, intf.ssn_params.timeout, c.POLLOUT);
        } else return error.Io;
    }
}

pub fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return 0 -% sum;
}

fn header(out: []u8, offset: usize, sa: u8, netfn: u8, requester: u8, seq: u8, cmd: u8) void {
    out[offset] = sa;
    out[offset + 1] = netfn;
    out[offset + 2] = 0 -% (sa +% netfn);
    out[offset + 3] = requester;
    out[offset + 4] = seq;
    out[offset + 5] = cmd;
}

var basic_seq: u8 = 0;
var terminal_seq: u8 = 0;

pub fn nextSequence(mode: Mode) u8 {
    const seq = if (mode == .basic) &basic_seq else &terminal_seq;
    seq.* = (seq.* + 1) % 64;
    return seq.* << 2;
}

pub fn monotonicMs() i64 {
    if (comptime builtin.target.abi == .musl) {
        var ts: std.os.linux.timespec = undefined;
        const err = std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &ts));
        if (err != .SUCCESS) {
            std.c._errno().* = @intFromEnum(err);
            @panic("clock_gettime(CLOCK_MONOTONIC) failed");
        }
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    } else {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
    }
}

pub fn build(mode: Mode, intf: *const Intf, req: *const ipmi.Request, out: []u8, system: bool) Error!Built {
    const depth: usize = c.ipmi_intf_get_bridging_level(@ptrCast(intf));
    if (depth > 2 or req.msg.data_len > 0 and req.msg.data == null) return error.InvalidRequest;
    const data_len: usize = req.msg.data_len;
    const length = data_len + (if (mode == .basic) @as(usize, 7) else 3) + depth * 8;
    if (length > out.len) return error.InvalidRequest;
    const seq = nextSequence(mode);
    const netfn: u8 = (@as(u8, req.msg.netfn_lun.netfn) << 2) | req.msg.netfn_lun.lun;
    const target: u8 = @truncate(intf.target_addr);
    const mine: u8 = @truncate(intf.my_addr);
    var ctx: [2]Context = .{ .{}, .{} };
    const outer_netfn: u8 = if (depth == 0) netfn else 0x18;
    const outer_cmd: u8 = if (depth == 0) req.msg.cmd else 0x34;
    const start: usize = if (mode == .basic) 6 else 3;
    if (mode == .basic) {
        header(out, 0, ipmi.bmc_slave_addr, outer_netfn, ipmi.remote_swid, seq, outer_cmd);
        ctx[0] = .{ .sa = ipmi.bmc_slave_addr, .requester = ipmi.remote_swid, .netfn = outer_netfn, .seq = seq, .cmd = outer_cmd };
    } else {
        out[0] = outer_netfn;
        out[1] = seq;
        out[2] = outer_cmd;
        ctx[0] = .{ .netfn = outer_netfn, .seq = seq, .cmd = outer_cmd };
    }
    var pos: usize = start;
    var first_channel: usize = 0;
    if (depth != 0) {
        first_channel = pos;
        if (depth == 2) {
            out[pos] = intf.transit_channel | 0x40;
            pos += 1;
            header(out, pos, @truncate(intf.transit_addr), 0x18, mine, seq, 0x34);
            pos += 6;
        }
        const inner_channel = pos;
        out[pos] = intf.target_channel | 0x40;
        pos += 1;
        header(out, pos, target, netfn, mine, seq, req.msg.cmd);
        pos += 6;
        if (depth == 1) first_channel = inner_channel;
        if (system) {
            out[first_channel] &= ~@as(u8, 0x40);
            // The outer requester's LUN 2 makes queued IPMB replies visible.
            out[first_channel + 5] |= 2;
            if (out[first_channel] != 0) out[first_channel + 4] = ipmi.bmc_slave_addr;
        }
        ctx[1] = .{
            .sa = out[first_channel + 1],
            .requester = out[first_channel + 4],
            .netfn = out[first_channel + 2],
            .seq = out[first_channel + 5],
            .cmd = out[first_channel + 6],
        };
    }
    if (data_len != 0) @memcpy(out[pos..][0..data_len], req.msg.data.?[0..data_len]);
    pos += data_len;
    if (depth != 0) {
        out[pos] = checksum(out[pos - data_len - 3 .. pos]);
        pos += 1;
        if (depth == 2) {
            out[pos] = checksum(out[first_channel + 4 .. first_channel + 8]);
            pos += 1;
        }
    }
    if (mode == .basic) {
        out[pos] = checksum(out[3..pos]);
        pos += 1;
    }
    std.debug.assert(pos == length);
    return .{ .len = pos, .depth = depth, .ctx = ctx };
}

pub fn match(mode: Mode, payload: []const u8, ctx: Context) ?[]const u8 {
    if (mode == .basic) {
        if (payload.len < 8 or checksum(payload[0..3]) != 0 or checksum(payload[3..]) != 0) return null;
        const netfn = ((ctx.netfn | 4) & ~@as(u8, 3)) | (ctx.seq & 3);
        const seq = (ctx.seq & ~@as(u8, 3)) | (ctx.netfn & 3);
        if (payload[0] != ctx.requester or payload[1] != netfn or payload[3] != ctx.sa or payload[4] != seq or payload[5] != ctx.cmd) return null;
        return payload[6 .. payload.len - 1];
    }
    if (payload.len < 4 or payload[0] != (ctx.netfn | 4) or (payload[1] & ~@as(u8, 3)) != ctx.seq or payload[2] != ctx.cmd) return null;
    return payload[3..];
}

pub fn unpack(payload: []const u8, depth: usize) ?[]const u8 {
    var part = payload;
    var remaining = depth;
    var unwrapped = false;
    while (remaining > 0 and part.len > 1 and part[0] == 0) : (remaining -= 1) {
        // A tracked Send Message reply only contains a completion code;
        // the addressed response then arrives as a separate frame.
        if (part.len < 9) return if (unwrapped) part else null;
        part = part[7 .. part.len - 1];
        unwrapped = true;
    }
    return if (part.len != 0) part else null;
}

test "serial IPMB checksum and response validation" {
    try std.testing.expectEqual(@as(u8, 0xc8), checksum(&.{ 0x20, 0x18 }));
    const ctx: Context = .{ .sa = 0x20, .requester = 0x81, .netfn = 0x18, .seq = 4, .cmd = 0x01 };
    var frame = [_]u8{ 0x81, 0x1c, 0, 0x20, 4, 1, 0, 0xa5, 0 };
    frame[2] = checksum(frame[0..2]);
    frame[8] = checksum(frame[3..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xa5 }, match(.basic, &frame, ctx).?);
    frame[8] +%= 1;
    try std.testing.expect(match(.basic, &frame, ctx) == null);
}

test "serial nested wire formats and maximum message size" {
    var intf: Intf = std.mem.zeroes(Intf);
    intf.my_addr = 0x20;
    intf.target_addr = 0x30;
    intf.target_channel = 1;
    intf.transit_addr = 0x32;
    intf.transit_channel = 2;
    var data: [32]u8 = @splat(0);
    @memcpy(data[0..5], &[_]u8{ 0xa0, 0xa5, 0xaa, 0x1b, 0 });
    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun.netfn = 0x2e;
    req.msg.cmd = 0x91;
    req.msg.data_len = 5;
    req.msg.data = &data;
    var msg: [256]u8 = undefined;
    basic_seq = 2;
    const basic = try build(.basic, &intf, &req, msg[0..47], false);
    try std.testing.expectEqual(@as(usize, 2), basic.depth);
    try std.testing.expectEqualSlices(u8, &.{
        0x20, 0x18, 0xc8, 0x81, 0x0c, 0x34, 0x42, 0x32,
        0x18, 0xb6, 0x20, 0x0c, 0x34, 0x41, 0x30, 0xb8,
        0x18, 0x20, 0x0c, 0x91, 0xa0, 0xa5, 0xaa, 0x1b,
        0x00, 0x39, 0x5f, 0xfd,
    }, msg[0..basic.len]);
    terminal_seq = 2;
    const term = try build(.terminal, &intf, &req, &msg, false);
    try std.testing.expectEqualSlices(u8, &.{
        0x18, 0x0c, 0x34, 0x42, 0x32, 0x18, 0xb6, 0x20,
        0x0c, 0x34, 0x41, 0x30, 0xb8, 0x18, 0x20, 0x0c,
        0x91, 0xa0, 0xa5, 0xaa, 0x1b, 0x00, 0x39, 0x5f,
    }, msg[0..term.len]);
    req.msg.data_len = 30;
    try std.testing.expectError(error.InvalidRequest, build(.basic, &intf, &req, msg[0..47], false));
    try std.testing.expectEqual(@as(usize, 49), (try build(.terminal, &intf, &req, &msg, false)).len);
}
