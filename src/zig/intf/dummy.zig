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
//! 4. `ipmi_dummyipmi_open()` previously copied the socket path with
//!    `strcpy()` into the 108-byte `sun_path`. A 108-byte pathname still works
//!    with the full sockaddr length; Zig rejects longer paths rather than
//!    reproducing the C stack overflow.
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
const linux = std.os.linux;

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("intf.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;

/// The C dummy's opt-in session for iSOL activation golden tests.
var isol_session: intf_mod.Session = std.mem.zeroes(intf_mod.Session);

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

fn rawRead(fd: c_int, data_ptr: ?*anyopaque, len: usize) usize {
    return linux.read(fd, @ptrCast(data_ptr), len);
}

fn rawWrite(fd: c_int, data_ptr: ?*anyopaque, len: usize) usize {
    return linux.write(fd, @ptrCast(data_ptr), len);
}

fn pauseRetry() void {
    _ = c.sleep(2);
}

fn socketAddress(path: [*:0]const u8) error{SocketPathTooLong}!linux.sockaddr.un {
    const bytes = std.mem.span(path);
    var address = std.mem.zeroes(linux.sockaddr.un);
    address.family = linux.AF.UNIX;
    if (bytes.len > address.path.len) return error.SocketPathTooLong;
    @memcpy(address.path[0..bytes.len], bytes);
    return address;
}

fn dataIo(fd: c_int, data_ptr: ?*anyopaque, data_len: c_int, comptime io: anytype, comptime pause: anytype) c_int {
    var rc: c_int = 0;
    var data_total: c_int = 0;
    var tries: c_int = 1;
    if (data_len < 0) return -1;
    while (data_total < data_len and tries < 4) {
        std.c._errno().* = 0;
        // The pointer deliberately stays at the beginning after short I/O.
        const result = io(fd, data_ptr, @intCast(data_len));
        const code = linux.errno(result);
        const errno_save: c_int = @intFromEnum(code);
        std.c._errno().* = errno_save;
        if (code == .SUCCESS and result > 0) data_total +%= @intCast(result);
        if (code != .SUCCESS) {
            if (code == .INTR or code == .AGAIN) {
                tries += 1;
                pause();
                continue;
            }
            // The C writer also calls perror with the "read" prefix.
            c.perror("dummy failed on read(): ");
            rc = -1;
            break;
        }
    }
    if (tries > 3 and data_total != data_len) rc = -1;
    return rc;
}

/// `data_read()`: read `data_len` bytes from `fd`, 0 on success and -1 on error.
fn dataRead(fd: c_int, data_ptr: ?*anyopaque, data_len: c_int) callconv(.c) c_int {
    return dataIo(fd, data_ptr, data_len, rawRead, pauseRetry);
}

/// `data_write()`: write `data_len` bytes to `fd`, 0 on success and -1 on error.
fn dataWrite(fd: c_int, data_ptr: ?*anyopaque, data_len: c_int) callconv(.c) c_int {
    return dataIo(fd, data_ptr, data_len, rawWrite, pauseRetry);
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
        log.print(log.Level.err, "dummy failed to send 'BYE'", .{});
    }
    const result = linux.close(intf.fd);
    if (linux.errno(result) != .SUCCESS) std.c._errno().* = @intFromEnum(linux.errno(result));
    intf.fd = -1;
    intf.opened = 0;
}

/// `ipmi_dummyipmi_open()`: connect the socket and mark the interface open.
fn open(intf: *Intf) callconv(.c) c_int {
    var dummy_sock_path = std.c.getenv("IPMI_DUMMY_SOCK");
    if (dummy_sock_path == null) {
        log.print(
            log.Level.debug,
            "No IPMI_DUMMY_SOCK set. Using " ++ default_sock,
            .{},
        );
        dummy_sock_path = @constCast(default_sock);
    }

    if (intf.opened == 1) {
        return intf.fd;
    }
    const socket_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (linux.errno(socket_result) != .SUCCESS) {
        std.c._errno().* = @intFromEnum(linux.errno(socket_result));
        intf.fd = -1;
        log.print(log.Level.err, "dummy failed on socket()", .{});
        return -1;
    }
    intf.fd = @intCast(socket_result);
    const address = socketAddress(@ptrCast(dummy_sock_path)) catch {
        _ = linux.close(intf.fd);
        intf.fd = -1;
        std.c._errno().* = @intFromEnum(linux.E.NAMETOOLONG);
        c.perror("dummy failed on connect(): ");
        return -1;
    };
    const connect_result = linux.connect(intf.fd, &address, @sizeOf(linux.sockaddr.un));
    if (linux.errno(connect_result) != .SUCCESS) {
        std.c._errno().* = @intFromEnum(linux.errno(connect_result));
        c.perror("dummy failed on connect(): ");
        // The socket is neither closed nor un-opened; see note 5 above.
        return -1;
    }
    if (std.c.getenv("IPMI_DUMMY_SOL_SESSION") != null) {
        intf.session = &isol_session;
    }
    intf.opened = 1;
    if (std.c.getenv("IPMI_DUMMY_EMULATE_OPEN")) |flag| {
        if (std.mem.eql(u8, std.mem.span(flag), "1")) {
            @memset(&intf.name, 0);
            @memcpy(intf.name[0..4], "open");
        }
    }
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
        log.print(log.Level.err, "dummy failed on intf check.", .{});
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
        log.print(log.Level.notice, ">>> IPMI req", .{});
        log.print(log.Level.notice, "msg.data_len: %i", .{@as(c_int, req_dummy.msg.data_len)});
        log.print(log.Level.notice, "msg.netfn: %x", .{@as(c_int, req_dummy.msg.netfn)});
        log.print(log.Level.notice, "msg.cmd: %x", .{@as(c_int, req_dummy.msg.cmd)});
        log.print(log.Level.notice, "msg.target_cmd: %x", .{@as(c_int, req_dummy.msg.target_cmd)});
        log.print(log.Level.notice, "msg.lun: %x", .{@as(c_int, req_dummy.msg.lun)});
        log.print(log.Level.notice, ">>>", .{});
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
        log.print(log.Level.notice, "<<< IPMI rsp", .{});
        log.print(log.Level.notice, "ccode: %x", .{@as(c_int, rsp.ccode)});
        log.print(log.Level.notice, "data_len: %i", .{rsp.data_len});
        log.print(log.Level.notice, "msg.netfn: %x", .{@as(c_int, rsp.msg.netfn)});
        log.print(log.Level.notice, "msg.cmd: %x", .{@as(c_int, rsp.msg.cmd)});
        log.print(log.Level.notice, "msg.seq: %x", .{@as(c_int, rsp.msg.seq)});
        log.print(log.Level.notice, "msg.lun: %x", .{@as(c_int, rsp.msg.lun)});
        log.print(log.Level.notice, "<<<", .{});
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
    if (@sizeOf(linux.sockaddr.un) != @sizeOf(c.struct_sockaddr_un) or
        @sizeOf(@FieldType(linux.sockaddr.un, "path")) != @sizeOf(@FieldType(c.struct_sockaddr_un, "sun_path")) or
        @offsetOf(linux.sockaddr.un, "family") != @offsetOf(c.struct_sockaddr_un, "sun_family") or
        @offsetOf(linux.sockaddr.un, "path") != @offsetOf(c.struct_sockaddr_un, "sun_path"))
        @compileError("dummy AF_UNIX sockaddr layout differs from C");
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

test "socket paths match bounded libc sockaddr bytes" {
    var name: [109:0]u8 = @splat('x');
    for ([_]usize{ 0, 1, 16, 106, 107 }) |length| {
        name[length] = 0;
        const address = try socketAddress(&name);
        var original = std.mem.zeroes(c.struct_sockaddr_un);
        original.sun_family = c.AF_UNIX;
        _ = c.strcpy(&original.sun_path, &name);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&address));
        name[length] = 'x';
    }
    name[108] = 0;
    const full = try socketAddress(&name);
    try std.testing.expectEqualSlices(u8, name[0..108], &full.path);
    name[108] = 'x';
    try std.testing.expectError(error.SocketPathTooLong, socketAddress(&name));
    const embedded = [_:0]u8{ 'a', 'b', 0, 'c' };
    const address = try socketAddress(&embedded);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0, 0 }, address.path[0..4]);
}

test "connect syscall errors match libc without changing process environment" {
    const address = try socketAddress("/dev/null/ipmi-dummy-test");
    const c_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    try std.testing.expect(c_fd >= 0);
    defer _ = c.close(c_fd);
    const zig_fd_result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(zig_fd_result));
    const zig_fd: c_int = @intCast(zig_fd_result);
    defer _ = linux.close(zig_fd);
    try std.testing.expectEqual(@as(c_int, -1), c.connect(c_fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un)));
    const c_errno = std.c._errno().*;
    const zig_result = linux.connect(zig_fd, &address, @sizeOf(linux.sockaddr.un));
    try std.testing.expectEqual(c_errno, @as(c_int, @intFromEnum(linux.errno(zig_result))));
}

test "injected short I/O and EINTR EAGAIN preserve pointer restart and retry budget" {
    const Stub = struct {
        var calls: usize = 0;
        var pauses: usize = 0;
        var first_ptr: usize = 0;
        var lengths_ok = true;
        var pointer_ok = true;
        var fail_only = false;

        fn io(_: c_int, pointer: ?*anyopaque, len: usize) usize {
            const index = calls;
            calls += 1;
            if (index == 0) first_ptr = @intFromPtr(pointer);
            pointer_ok = pointer_ok and first_ptr == @intFromPtr(pointer);
            lengths_ok = lengths_ok and len == 5;
            if (fail_only or index == 0)
                return @bitCast(-@as(isize, @intFromEnum(linux.E.INTR)));
            if (index == 1)
                return @bitCast(-@as(isize, @intFromEnum(linux.E.AGAIN)));
            const bytes: [*]u8 = @ptrCast(pointer);
            @memcpy(bytes[0..3], "xyz");
            return 3;
        }

        fn pause() void {
            pauses += 1;
        }
    };
    var buffer = [_]u8{0xee} ** 5;
    Stub.calls = 0;
    Stub.pauses = 0;
    Stub.pointer_ok = true;
    Stub.lengths_ok = true;
    Stub.fail_only = false;
    try std.testing.expectEqual(@as(c_int, 0), dataIo(7, &buffer, buffer.len, Stub.io, Stub.pause));
    try std.testing.expectEqual(@as(usize, 4), Stub.calls);
    try std.testing.expectEqual(@as(usize, 2), Stub.pauses);
    try std.testing.expect(Stub.pointer_ok and Stub.lengths_ok);
    try std.testing.expectEqualSlices(u8, &.{ 'x', 'y', 'z', 0xee, 0xee }, &buffer);
    try std.testing.expectEqual(@as(c_int, 0), std.c._errno().*);

    Stub.calls = 0;
    Stub.pauses = 0;
    Stub.fail_only = true;
    try std.testing.expectEqual(@as(c_int, -1), dataIo(7, &buffer, buffer.len, Stub.io, Stub.pause));
    try std.testing.expectEqual(@as(usize, 3), Stub.calls);
    try std.testing.expectEqual(@as(usize, 3), Stub.pauses);
    try std.testing.expectEqual(@as(c_int, c.EINTR), std.c._errno().*);
}

test "closed peer zero read preserves the original no-progress retry behavior" {
    const pair = try Pair.open();
    defer pair.close();
    try std.testing.expectEqual(@as(c_int, 0), c.shutdown(pair.peer, c.SHUT_WR));
    var byte: u8 = 0;
    try std.testing.expectEqual(@as(isize, 0), c.read(pair.intf_end, &byte, 1));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rawRead(pair.intf_end, &byte, 1)));

    const Stub = struct {
        var calls: usize = 0;
        var pauses: usize = 0;
        fn io(_: c_int, pointer: ?*anyopaque, len: usize) usize {
            calls += 1;
            if (calls < 3) return 0;
            const bytes: [*]u8 = @ptrCast(pointer);
            @memset(bytes[0..len], 0x42);
            return len;
        }
        fn pause() void {
            pauses += 1;
        }
    };
    Stub.calls = 0;
    Stub.pauses = 0;
    try std.testing.expectEqual(@as(c_int, 0), dataIo(pair.intf_end, &byte, 1, Stub.io, Stub.pause));
    try std.testing.expectEqual(@as(usize, 3), Stub.calls);
    try std.testing.expectEqual(@as(usize, 0), Stub.pauses);
    try std.testing.expectEqual(@as(u8, 0x42), byte);
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
    try std.testing.expectEqual(@as(isize, -1), c.read(-1, &byte, 1));
    const read_errno = std.c._errno().*;
    try std.testing.expectEqual(read_errno, @as(c_int, @intFromEnum(linux.errno(rawRead(-1, &byte, 1)))));
    try std.testing.expectEqual(@as(c_int, -1), dataRead(-1, &byte, 1));
    try std.testing.expectEqual(@as(isize, -1), c.write(-1, &byte, 1));
    const write_errno = std.c._errno().*;
    try std.testing.expectEqual(write_errno, @as(c_int, @intFromEnum(linux.errno(rawWrite(-1, &byte, 1)))));
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
