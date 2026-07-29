//! Port of `src/plugins/dummy/dummy.c`: the `dummy` transport.
//!
//! It is a *client*, not a server: `open()` connects an `AF_UNIX`/`SOCK_STREAM`
//! socket to the path in `IPMI_DUMMY_SOCK` (falling back to the compiled-in
//! `/tmp/.ipmi_dummy`) and every request is the raw `struct dummy_rq` from
//! `src/plugins/dummy/dummy.h` written to that socket in native endianness and
//! native padding, optionally followed by the request payload.  The reply is a
//! `struct dummy_rs` plus its payload.
//!
//! This is what the 900-case golden suite is driven through, so the byte
//! layout and the framing have to stay exactly as they are.
//!
//! ## Upstream behaviour reproduced deliberately
//!
//! 1. `data_read()` and `data_write()` never advance `data_ptr` between
//!    iterations.  A short read or write therefore restarts at the beginning of
//!    the caller's buffer and overwrites what it already stored, and the loop
//!    condition `data_total < data_len` is satisfied by the duplicated bytes.
//!    `tests/golden/DummyBmc.zig` documents the consequence and writes each
//!    header and payload with a single `writeAll`.
//! 2. Neither loop makes progress when the peer closes the connection: `read()`
//!    returns 0 with `errno` untouched, so `data_total` and `try` both stay put
//!    and the loop spins forever.  Only reachable if the server disappears
//!    mid-message.
//! 3. `data_write()` reports failures as `perror("dummy failed on read(): ")` —
//!    the message is a copy-paste from `data_read()`.
//! 4. `ipmi_dummyipmi_open()` copies the socket path with `strcpy()` into
//!    `sun_path`, which is 108 bytes.  A longer `IPMI_DUMMY_SOCK` overflows the
//!    stack frame.
//! 5. `ipmi_dummyipmi_open()` leaks the socket when `connect()` fails: it
//!    returns -1 without closing `intf->fd` or clearing `intf->opened`.
//! 6. `ipmi_dummyipmi_send_cmd()` reads `rsp_dummy.data_len` bytes into
//!    `rsp.data`, which is `IPMI_BUF_SIZE` (1024) bytes, without checking the
//!    length the server sent.  It is also a *signed* `int` on the wire, so a
//!    negative value skips the read entirely.
//! 7. The `!intf` guard in `ipmi_dummyipmi_send_cmd()` is dead: `sendrecv` is
//!    only ever reached through a resolved `struct ipmi_intf *`.  The vtable
//!    type makes the parameter non-optional here, so the check has no Zig
//!    counterpart; the other two conditions are kept.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("intf.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;

const native_endian = builtin.target.cpu.arch.endian();

/// `IPMI_DUMMY_DEFAULTSOCK`, taken from the C header rather than restated, so
/// the fallback path cannot drift from `src/plugins/dummy/dummy.h`.
const default_sock = c.IPMI_DUMMY_DEFAULTSOCK;

/// `struct dummy_rq`.
pub const DummyRq = extern struct {
    pub const Msg = extern struct {
        netfn: u8,
        lun: u8,
        cmd: u8,
        target_cmd: u8,
        data_len: u16,
        data: ?[*]u8,
    };

    msg: Msg,
};

/// `struct dummy_rs`.
pub const DummyRs = extern struct {
    pub const Msg = extern struct {
        netfn: u8,
        cmd: u8,
        seq: u8,
        lun: u8,
    };

    msg: Msg,
    ccode: u8,
    /// Signed, and taken from the wire without validation.
    data_len: c_int,
    data: ?[*]u8,
};

// ---------------------------------------------------------------------------
// Socket I/O
// ---------------------------------------------------------------------------

/// `data_read()`: read `data_len` bytes from `fd`, 0 on success and -1 on error.
fn dataRead(fd: c_int, data_ptr: ?*anyopaque, data_len: c_int) callconv(.c) c_int {
    var rc: c_int = 0;
    var data_total: c_int = 0;
    var tries: c_int = 1;
    if (data_len < 0) {
        return -1;
    }
    while (data_total < data_len and tries < 4) {
        std.c._errno().* = 0;
        // `data_ptr` is deliberately not advanced; see note 1 above.
        const n: c_int = @truncate(c.read(fd, data_ptr, @intCast(data_len)));
        const errno_save = std.c._errno().*;
        if (n > 0) {
            data_total +%= n;
        }
        if (errno_save != 0) {
            if (errno_save == c.EINTR or errno_save == c.EAGAIN) {
                tries += 1;
                _ = c.sleep(2);
                continue;
            } else {
                std.c._errno().* = errno_save;
                c.perror("dummy failed on read(): ");
                rc = -1;
                break;
            }
        }
    }
    if (tries > 3 and data_total != data_len) {
        rc = -1;
    }
    return rc;
}

/// `data_write()`: write `data_len` bytes to `fd`, 0 on success and -1 on error.
fn dataWrite(fd: c_int, data_ptr: ?*anyopaque, data_len: c_int) callconv(.c) c_int {
    var rc: c_int = 0;
    var data_total: c_int = 0;
    var tries: c_int = 1;
    if (data_len < 0) {
        return -1;
    }
    while (data_total < data_len and tries < 4) {
        std.c._errno().* = 0;
        const n: c_int = @truncate(c.write(fd, data_ptr, @intCast(data_len)));
        const errno_save = std.c._errno().*;
        if (n > 0) {
            data_total +%= n;
        }
        if (errno_save != 0) {
            if (errno_save == c.EINTR or errno_save == c.EAGAIN) {
                tries += 1;
                _ = c.sleep(2);
                continue;
            } else {
                std.c._errno().* = errno_save;
                // Says "read" on the write path; see note 3 above.
                c.perror("dummy failed on read(): ");
                rc = -1;
                break;
            }
        }
    }
    if (tries > 3 and data_total != data_len) {
        rc = -1;
    }
    return rc;
}

// ---------------------------------------------------------------------------
// The transport
// ---------------------------------------------------------------------------

/// `ipmi_dummyipmi_close()`: send "BYE" and close the socket.
fn close(intf: *Intf) callconv(.c) void {
    var req: DummyRq = undefined;
    if (intf.fd < 0) {
        return;
    }
    req = std.mem.zeroes(DummyRq);
    req.msg.netfn = 0x3f;
    req.msg.cmd = 0xff;
    if (dataWrite(intf.fd, &req, @sizeOf(DummyRq)) != 0) {
        c.lprintf(log.Level.err, "dummy failed to send 'BYE'");
    }
    _ = c.close(intf.fd);
    intf.fd = -1;
    intf.opened = 0;
}

/// `ipmi_dummyipmi_open()`: connect the socket and mark the interface open.
fn open(intf: *Intf) callconv(.c) c_int {
    var address: c.struct_sockaddr_un = undefined;

    var dummy_sock_path = c.getenv("IPMI_DUMMY_SOCK");
    if (dummy_sock_path == null) {
        c.lprintf(
            log.Level.debug,
            "No IPMI_DUMMY_SOCK set. Using " ++ default_sock,
        );
        dummy_sock_path = @constCast(default_sock);
    }

    if (intf.opened == 1) {
        return intf.fd;
    }
    intf.fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (intf.fd == -1) {
        c.lprintf(log.Level.err, "dummy failed on socket()");
        return -1;
    }
    address.sun_family = @intCast(c.AF_UNIX);
    // Unbounded, exactly as upstream; see note 4 above.
    _ = c.strcpy(&address.sun_path, dummy_sock_path);
    const len: c_int = @sizeOf(c.struct_sockaddr_un);
    const rc = c.connect(intf.fd, @ptrCast(&address), @intCast(len));
    if (rc != 0) {
        c.perror("dummy failed on connect(): ");
        // The socket is neither closed nor un-opened; see note 5 above.
        return -1;
    }
    intf.opened = 1;
    return intf.fd;
}

/// The `static struct ipmi_rs rsp` inside `ipmi_dummyipmi_send_cmd()`.
///
/// Its address is what the function returns, so it has to outlive the call and
/// keep whatever the previous call left in it.
var rsp: ipmi.Response = std.mem.zeroes(ipmi.Response);

/// `ipmi_dummyipmi_send_cmd()`: send one request and read the reply.
fn sendrecv(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    var req_dummy: DummyRq = undefined;
    var rsp_dummy: DummyRs = undefined;

    if (intf.fd < 0 or intf.opened != 1) {
        c.lprintf(log.Level.err, "dummy failed on intf check.");
        return null;
    }

    req_dummy = std.mem.zeroes(DummyRq);
    req_dummy.msg.netfn = req.msg.netfn_lun.netfn;
    req_dummy.msg.lun = req.msg.netfn_lun.lun;
    req_dummy.msg.cmd = req.msg.cmd;
    req_dummy.msg.target_cmd = req.msg.target_cmd;
    req_dummy.msg.data_len = req.msg.data_len;
    req_dummy.msg.data = req.msg.data;
    if (c.verbose != 0) {
        c.lprintf(log.Level.notice, ">>> IPMI req");
        c.lprintf(log.Level.notice, "msg.data_len: %i", @as(c_int, req_dummy.msg.data_len));
        c.lprintf(log.Level.notice, "msg.netfn: %x", @as(c_int, req_dummy.msg.netfn));
        c.lprintf(log.Level.notice, "msg.cmd: %x", @as(c_int, req_dummy.msg.cmd));
        c.lprintf(log.Level.notice, "msg.target_cmd: %x", @as(c_int, req_dummy.msg.target_cmd));
        c.lprintf(log.Level.notice, "msg.lun: %x", @as(c_int, req_dummy.msg.lun));
        c.lprintf(log.Level.notice, ">>>");
    }
    if (dataWrite(intf.fd, &req_dummy, @sizeOf(DummyRq)) != 0) {
        return null;
    }
    if (req.msg.data_len > 0) {
        if (dataWrite(intf.fd, req.msg.data, req_dummy.msg.data_len) != 0) {
            return null;
        }
    }

    rsp_dummy = std.mem.zeroes(DummyRs);
    if (dataRead(intf.fd, &rsp_dummy, @sizeOf(DummyRs)) != 0) {
        return null;
    }
    if (rsp_dummy.data_len > 0) {
        // No bound check against `rsp.data`; see note 6 above.
        if (dataRead(intf.fd, &rsp.data, rsp_dummy.data_len) != 0) {
            return null;
        }
    }
    rsp.ccode = rsp_dummy.ccode;
    rsp.data_len = rsp_dummy.data_len;
    rsp.msg.netfn = rsp_dummy.msg.netfn;
    rsp.msg.cmd = rsp_dummy.msg.cmd;
    rsp.msg.seq = rsp_dummy.msg.seq;
    rsp.msg.lun = rsp_dummy.msg.lun;
    if (c.verbose != 0) {
        c.lprintf(log.Level.notice, "<<< IPMI rsp");
        c.lprintf(log.Level.notice, "ccode: %x", @as(c_int, rsp.ccode));
        c.lprintf(log.Level.notice, "data_len: %i", rsp.data_len);
        c.lprintf(log.Level.notice, "msg.netfn: %x", @as(c_int, rsp.msg.netfn));
        c.lprintf(log.Level.notice, "msg.cmd: %x", @as(c_int, rsp.msg.cmd));
        c.lprintf(log.Level.notice, "msg.seq: %x", @as(c_int, rsp.msg.seq));
        c.lprintf(log.Level.notice, "msg.lun: %x", @as(c_int, rsp.msg.lun));
        c.lprintf(log.Level.notice, "<<<");
    }
    return &rsp;
}

/// `struct ipmi_intf ipmi_dummy_intf`.  Everything the C initializer leaves
/// out is zero.
var dummy_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    const name = "dummy";
    const desc = "Linux DummyIPMI Interface";
    @memcpy(i.name[0..name.len], name);
    @memcpy(i.desc[0..desc.len], desc);
    i.open = open;
    i.close = close;
    i.sendrecv = sendrecv;
    i.my_addr = c.IPMI_BMC_SLAVE_ADDR;
    i.target_addr = c.IPMI_BMC_SLAVE_ADDR;
    break :blk i;
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(DummyRq, c.struct_dummy_rq);
    abi.assertLayout(DummyRq.Msg, @FieldType(c.struct_dummy_rq, "msg"));
    abi.assertLayout(DummyRs, c.struct_dummy_rs);
    abi.assertLayout(DummyRs.Msg, @FieldType(c.struct_dummy_rs, "msg"));
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(dataRead), @TypeOf(c.data_read));
    @export(&dataRead, .{ .name = "data_read" });

    abi.assertCallSignature(@TypeOf(dataWrite), @TypeOf(c.data_write));
    @export(&dataWrite, .{ .name = "data_write" });

    @export(&dummy_intf, .{ .name = "ipmi_dummy_intf" });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the vtable matches the C initializer" {
    try std.testing.expectEqualStrings("dummy", std.mem.sliceTo(&dummy_intf.name, 0));
    try std.testing.expectEqualStrings(
        "Linux DummyIPMI Interface",
        std.mem.sliceTo(&dummy_intf.desc, 0),
    );
    // Everything past the string is zero: `name` is 16 bytes and `desc` 128.
    try std.testing.expect(std.mem.allEqual(u8, dummy_intf.name[5..], 0));
    try std.testing.expect(std.mem.allEqual(u8, dummy_intf.desc[25..], 0));

    try std.testing.expectEqual(@as(u32, c.IPMI_BMC_SLAVE_ADDR), dummy_intf.my_addr);
    try std.testing.expectEqual(@as(u32, c.IPMI_BMC_SLAVE_ADDR), dummy_intf.target_addr);

    // The C initializer names exactly three of the ten callbacks.
    try std.testing.expect(dummy_intf.open != null);
    try std.testing.expect(dummy_intf.close != null);
    try std.testing.expect(dummy_intf.sendrecv != null);
    try std.testing.expect(dummy_intf.setup == null);
    try std.testing.expect(dummy_intf.recv_sol == null);
    try std.testing.expect(dummy_intf.send_sol == null);
    try std.testing.expect(dummy_intf.keepalive == null);
    try std.testing.expect(dummy_intf.set_my_addr == null);
    try std.testing.expect(dummy_intf.set_max_request_data_size == null);
    try std.testing.expect(dummy_intf.set_max_response_data_size == null);
    try std.testing.expectEqual(@as(c_int, 0), dummy_intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), dummy_intf.opened);
}

test "the fallback socket path is the one dummy.h names" {
    // Only taken when IPMI_DUMMY_SOCK is unset, which the golden harness never
    // leaves unset, so nothing else pins this string.
    try std.testing.expectEqualStrings(
        "/tmp/.ipmi_dummy",
        std.mem.span(@as([*:0]const u8, default_sock)),
    );
}

test "the wire structs are the sizes the golden BMC assumes" {
    // tests/golden/DummyBmc.zig hard-codes these; they are the framing.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DummyRq));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DummyRs));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DummyRq.Msg, "netfn"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(DummyRq.Msg, "lun"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(DummyRq.Msg, "cmd"));
    try std.testing.expectEqual(@as(usize, 3), @offsetOf(DummyRq.Msg, "target_cmd"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DummyRq.Msg, "data_len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DummyRq.Msg, "data"));

    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DummyRs, "ccode"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DummyRs, "data_len"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DummyRs, "data"));
}

test "a negative length is rejected before any syscall" {
    // fd -1 would fail immediately, so a return of 0 or a hang would both show
    // the guard is gone.
    try std.testing.expectEqual(@as(c_int, -1), dataRead(-1, null, -1));
    try std.testing.expectEqual(@as(c_int, -1), dataWrite(-1, null, -1));
}

test "a zero length neither reads nor writes" {
    // `data_total < data_len` is false on entry, so the loop body never runs
    // and the invalid descriptor is never touched.
    try std.testing.expectEqual(@as(c_int, 0), dataRead(-1, null, 0));
    try std.testing.expectEqual(@as(c_int, 0), dataWrite(-1, null, 0));
}

test "a hard error is reported as -1" {
    // -1 is never a valid descriptor, so `read()`/`write()` fail with EBADF.
    // EBADF is neither EINTR nor EAGAIN, so the loop takes the `perror()` path
    // and returns -1 on the first iteration rather than retrying.  The
    // `perror()` output is sent to /dev/null: `zig build test` treats anything
    // a test writes to stderr as a failure.
    const saved = c.dup(2);
    try std.testing.expect(saved >= 0);
    defer _ = c.close(saved);
    const null_fd = c.open("/dev/null", c.O_WRONLY);
    try std.testing.expect(null_fd >= 0);
    defer _ = c.close(null_fd);
    try std.testing.expect(c.dup2(null_fd, 2) >= 0);
    defer _ = c.dup2(saved, 2);

    var byte: u8 = 0;
    try std.testing.expectEqual(@as(c_int, -1), dataRead(-1, &byte, 1));
    try std.testing.expectEqual(@as(c_int, -1), dataWrite(-1, &byte, 1));
}

test "round trips a request header through a pipe" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);

    // Four distinct non-zero bytes in every field, so a swapped, dropped or
    // duplicated field cannot be mistaken for a correct one.
    var out: DummyRq = std.mem.zeroes(DummyRq);
    out.msg.netfn = 0x2e;
    out.msg.lun = 0x03;
    out.msg.cmd = 0x94;
    out.msg.target_cmd = 0x57;
    out.msg.data_len = 0x0123;

    try std.testing.expectEqual(@as(c_int, 0), dataWrite(fds[1], &out, @sizeOf(DummyRq)));

    var in: DummyRq = std.mem.zeroes(DummyRq);
    try std.testing.expectEqual(@as(c_int, 0), dataRead(fds[0], &in, @sizeOf(DummyRq)));

    try std.testing.expectEqual(out.msg.netfn, in.msg.netfn);
    try std.testing.expectEqual(out.msg.lun, in.msg.lun);
    try std.testing.expectEqual(out.msg.cmd, in.msg.cmd);
    try std.testing.expectEqual(out.msg.target_cmd, in.msg.target_cmd);
    // 0x0123 has two different non-zero bytes, so a byte-swapped u16 fails.
    try std.testing.expectEqual(out.msg.data_len, in.msg.data_len);
}

// ---------------------------------------------------------------------------
// Byte-level framing tests
//
// The golden suite exercises this transport 924 times, but the model BMC
// answers every request with `netfn | 1`, the request's own `cmd` and `lun`,
// and `target_cmd` is only ever set by `lan`/`lanplus`, so most of the header
// is zero on the wire.  The tests below drive `sendrecv()` over a socket pair
// with four distinct non-zero bytes in every field instead, which pins the
// offsets, the widths and the byte order of both structs directly.
// ---------------------------------------------------------------------------

/// A connected `AF_UNIX`/`SOCK_STREAM` pair: `intf_end` is handed to the
/// transport, `peer` stands in for the BMC.
const Pair = struct {
    intf_end: c_int,
    peer: c_int,

    fn open() !Pair {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.SocketPairFailed;
        return .{ .intf_end = fds[0], .peer = fds[1] };
    }

    fn close(p: Pair) void {
        _ = c.close(p.intf_end);
        _ = c.close(p.peer);
    }

    fn intf(p: Pair) Intf {
        var i = dummy_intf;
        i.fd = p.intf_end;
        i.opened = 1;
        return i;
    }
};

test "sendrecv puts every request field at the offset dummy.h gives it" {
    const pair = try Pair.open();
    defer pair.close();

    // 258 bytes: more than a u8 holds, and the two length bytes on the wire
    // (0x02, 0x01) differ, so neither a truncation to u8 nor a byte swap can
    // survive.
    const payload_len = 0x0102;
    var payload: [payload_len]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 7 +% 1);

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = 0x2c, .lun = 0x03 };
    req.msg.cmd = 0x94;
    req.msg.target_cmd = 0x57;
    req.msg.data_len = payload_len;
    req.msg.data = &payload;

    // The reply has to be queued first: `sendrecv()` blocks reading it, and
    // the socket buffers are far larger than these messages.
    var reply: [@sizeOf(DummyRs)]u8 = @splat(0);
    reply[0] = 0x2d;
    reply[1] = 0x94;
    reply[2] = 0x5b;
    reply[3] = 0x03;
    reply[4] = 0x83;
    std.mem.writeInt(i32, reply[8..12], 0, .little);
    try std.testing.expectEqual(@as(isize, reply.len), c.write(pair.peer, &reply, reply.len));

    var intf = pair.intf();
    try std.testing.expect(sendrecv(&intf, &req) != null);

    var header: [@sizeOf(DummyRq)]u8 = @splat(0xee);
    try std.testing.expectEqual(@as(isize, header.len), c.read(pair.peer, &header, header.len));

    try std.testing.expectEqual(@as(u8, 0x2c), header[0]);
    try std.testing.expectEqual(@as(u8, 0x03), header[1]);
    try std.testing.expectEqual(@as(u8, 0x94), header[2]);
    try std.testing.expectEqual(@as(u8, 0x57), header[3]);
    try std.testing.expectEqual(@as(u16, payload_len), std.mem.readInt(u16, header[4..6], native_endian));
    // The C writes the whole struct, padding included, out of a zeroed buffer.
    try std.testing.expectEqual(@as(u8, 0), header[6]);
    try std.testing.expectEqual(@as(u8, 0), header[7]);
    // ... and the caller's `data` pointer goes on the wire too, even though it
    // is an address in this process and means nothing to the peer.
    try std.testing.expectEqual(
        @intFromPtr(&payload),
        std.mem.readInt(usize, header[8..16], native_endian),
    );

    var seen: [payload_len]u8 = @splat(0xee);
    var got: usize = 0;
    while (got < seen.len) {
        const n = c.read(pair.peer, seen[got..].ptr, seen.len - got);
        try std.testing.expect(n > 0);
        got += @intCast(n);
    }
    try std.testing.expectEqualSlices(u8, &payload, &seen);
}

test "sendrecv copies every response field back out of dummy_rs" {
    const pair = try Pair.open();
    defer pair.close();

    // 261 bytes, again wider than a u8 and with two different non-zero length
    // bytes, this time in an `int` rather than a `uint16_t`.
    const payload_len = 0x0105;
    var payload: [payload_len]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 11 +% 3);

    var reply: [@sizeOf(DummyRs)]u8 = @splat(0);
    reply[0] = 0x2d;
    reply[1] = 0x94;
    reply[2] = 0x5b;
    reply[3] = 0x03;
    reply[4] = 0x83;
    std.mem.writeInt(i32, reply[8..12], payload_len, native_endian);
    try std.testing.expectEqual(@as(isize, reply.len), c.write(pair.peer, &reply, reply.len));
    try std.testing.expectEqual(@as(isize, payload.len), c.write(pair.peer, &payload, payload.len));

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = 0x06, .lun = 0x00 };
    req.msg.cmd = 0x01;

    var intf = pair.intf();
    const got = sendrecv(&intf, &req) orelse return error.SendrecvFailed;

    try std.testing.expectEqual(@as(u8, 0x2d), got.msg.netfn);
    try std.testing.expectEqual(@as(u8, 0x94), got.msg.cmd);
    try std.testing.expectEqual(@as(u8, 0x5b), got.msg.seq);
    try std.testing.expectEqual(@as(u8, 0x03), got.msg.lun);
    try std.testing.expectEqual(@as(u8, 0x83), got.ccode);
    try std.testing.expectEqual(@as(c_int, payload_len), got.data_len);
    try std.testing.expectEqualSlices(u8, &payload, got.data[0..payload_len]);
}

test "BUG: a negative response length is trusted and skips the payload read" {
    const pair = try Pair.open();
    defer pair.close();

    // `dummy_rs.data_len` is a signed `int` and the guard is `> 0`, so a
    // negative length neither reads a payload nor is rejected: it lands in
    // `rsp.data_len` as-is.  Reproduced, not fixed.
    var reply: [@sizeOf(DummyRs)]u8 = @splat(0);
    reply[0] = 0x2d;
    reply[1] = 0x94;
    reply[2] = 0x5b;
    reply[3] = 0x03;
    reply[4] = 0x00;
    std.mem.writeInt(i32, reply[8..12], -3, native_endian);
    try std.testing.expectEqual(@as(isize, reply.len), c.write(pair.peer, &reply, reply.len));

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = 0x06, .lun = 0x00 };

    var intf = pair.intf();
    const got = sendrecv(&intf, &req) orelse return error.SendrecvFailed;
    try std.testing.expectEqual(@as(c_int, -3), got.data_len);
}

test "sendrecv writes no payload when data_len is zero" {
    const pair = try Pair.open();
    defer pair.close();

    var reply: [@sizeOf(DummyRs)]u8 = @splat(0);
    reply[1] = 0x94;
    try std.testing.expectEqual(@as(isize, reply.len), c.write(pair.peer, &reply, reply.len));

    var req: ipmi.Request = std.mem.zeroes(ipmi.Request);
    req.msg.netfn_lun = .{ .netfn = 0x06, .lun = 0x00 };
    req.msg.cmd = 0x01;
    req.msg.data_len = 0;
    // A non-null pointer with a zero length: only the `data_len > 0` guard
    // keeps these bytes off the wire.
    var never_sent: [4]u8 = .{ 0xde, 0xad, 0xbe, 0xef };
    req.msg.data = &never_sent;

    var intf = pair.intf();
    try std.testing.expect(sendrecv(&intf, &req) != null);

    var header: [@sizeOf(DummyRq)]u8 = @splat(0xee);
    try std.testing.expectEqual(@as(isize, header.len), c.read(pair.peer, &header, header.len));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, header[4..6], native_endian));

    // Nothing followed the header.  The peer end is still open, so a blocking
    // read would hang; ask for the answer without blocking instead.
    var extra: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(isize, -1),
        c.recv(pair.peer, &extra, extra.len, c.MSG_DONTWAIT),
    );
    try std.testing.expectEqual(c.EAGAIN, std.c._errno().*);
}

test "close sends BYE and resets the interface" {
    const pair = try Pair.open();
    defer pair.close();

    var intf = pair.intf();
    close(&intf);

    try std.testing.expectEqual(@as(c_int, -1), intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);

    var bye: [@sizeOf(DummyRq)]u8 = @splat(0xee);
    try std.testing.expectEqual(@as(isize, bye.len), c.read(pair.peer, &bye, bye.len));
    try std.testing.expectEqual(@as(u8, 0x3f), bye[0]);
    try std.testing.expectEqual(@as(u8, 0x00), bye[1]);
    try std.testing.expectEqual(@as(u8, 0xff), bye[2]);
    try std.testing.expectEqual(@as(u8, 0x00), bye[3]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bye[4..6], native_endian));

    // `intf.fd` was closed by `close()`, so the pair's own close of it later is
    // a harmless EBADF.
}

test "close on an unopened interface does nothing" {
    var intf = dummy_intf;
    intf.fd = -1;
    intf.opened = 1;
    close(&intf);
    // The early return happens before `opened` is cleared.
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);
}

fn monotonicMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

fn writeShort(peer: c_int) void {
    const first = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    const second = [_]u8{ 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b };
    _ = c.usleep(100_000);
    _ = c.write(peer, &first, first.len);
    _ = c.usleep(400_000);
    _ = c.write(peer, &second, second.len);
}

test "BUG: a short read restarts at the front of the caller's buffer" {
    const pair = try Pair.open();
    defer pair.close();

    // `data_read()` loops until it has `data_len` bytes but never advances
    // `data_ptr`, so the second read overwrites what the first one stored.
    // The 16 bytes asked for here arrive as 5 then 11, and what is left in the
    // buffer is the *second* chunk followed by whatever the first chunk did
    // not reach.  Reproduced, not fixed.
    const writer = try std.Thread.spawn(.{}, writeShort, .{pair.peer});
    defer writer.join();

    var buf: [16]u8 = @splat(0xee);
    try std.testing.expectEqual(@as(c_int, 0), dataRead(pair.intf_end, &buf, buf.len));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0xee, 0xee, 0xee, 0xee, 0xee },
        &buf,
    );
}

test "the retry budget is three sleeps, then failure" {
    const pair = try Pair.open();
    defer pair.close();

    // Nothing is ever written to `peer`, and the socket is non-blocking, so
    // every `read()` fails with EAGAIN.  `try` starts at 1 and the loop runs
    // while `try < 4`, so there are three iterations and three `sleep(2)`
    // calls before `try > 3` turns into -1.
    //
    // The return value alone rules out a *smaller* bound: with `try < 3` or
    // `try < 2` the loop leaves `try` at 3 or 2, `try > 3` is false and the
    // function returns 0 having read nothing.  The elapsed time rules out a
    // larger one: a fourth iteration would add another two seconds.
    const flags = c.fcntl(pair.intf_end, c.F_GETFL, @as(c_int, 0));
    try std.testing.expect(flags >= 0);
    try std.testing.expect(c.fcntl(pair.intf_end, c.F_SETFL, flags | c.O_NONBLOCK) == 0);

    var buf: [4]u8 = undefined;
    const started = monotonicMs();
    try std.testing.expectEqual(@as(c_int, -1), dataRead(pair.intf_end, &buf, buf.len));
    const elapsed_ms = monotonicMs() - started;
    try std.testing.expect(elapsed_ms >= 5_000);
    try std.testing.expect(elapsed_ms < 7_500);
}
