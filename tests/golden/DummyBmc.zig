//! Dummy-interface BMC server.
//!
//! ## How ipmitool's `dummy` interface is driven
//!
//! `src/plugins/dummy/dummy.c` is a *client*: on `open()` it connects a
//! `AF_UNIX`/`SOCK_STREAM` socket to the path in the `IPMI_DUMMY_SOCK`
//! environment variable (falling back to the compiled-in
//! `/tmp/.ipmi_dummy`). Something else has to be listening -- that is this
//! file. No kernel driver, no root, no hardware.
//!
//! The framing is the raw C structs from `src/plugins/dummy/dummy.h` written
//! with `write(2)`, i.e. native endianness and native padding. On the LP64
//! targets ipmitool supports this is:
//!
//! Request, `struct dummy_rq`, 16 bytes:
//!
//!     offset 0  u8   msg.netfn
//!     offset 1  u8   msg.lun
//!     offset 2  u8   msg.cmd
//!     offset 3  u8   msg.target_cmd
//!     offset 4  u16  msg.data_len      (native endian)
//!     offset 6  --   2 padding bytes
//!     offset 8  ptr  msg.data          (a pointer from the *client's* address
//!                                       space; it is written to the socket but
//!                                       is meaningless to us -- ignore it)
//!
//! If `data_len > 0` the client immediately writes `data_len` more bytes: the
//! request payload.
//!
//! Response, `struct dummy_rs`, 24 bytes:
//!
//!     offset 0  u8   msg.netfn
//!     offset 1  u8   msg.cmd
//!     offset 2  u8   msg.seq            (from the transcript rule's `seq')
//!     offset 3  u8   msg.lun
//!     offset 4  u8   ccode
//!     offset 5  --   3 padding bytes
//!     offset 8  i32  data_len          (native endian, signed)
//!     offset 12 --   4 padding bytes
//!     offset 16 ptr  data              (ignored by the client)
//!
//! followed by `data_len` payload bytes, which the client copies into
//! `struct ipmi_rs.data` (an `IPMI_BUF_SIZE` = 1024 byte array), so responses
//! must stay at or below 1024 bytes.
//!
//! Shutdown: `ipmi_dummyipmi_close()` sends a request with netfn `0x3f` and
//! cmd `0xff` ("BYE") and then closes the socket.
//!
//! Caveat that matters for the server: `data_read()` in dummy.c loops on short
//! reads but does *not* advance the destination pointer, so a short read
//! corrupts the message. This server therefore writes each response header and
//! its payload with a single `writeAll` + `flush` pair, which the kernel
//! delivers atomically for these sizes.

const std = @import("std");
const Io = std.Io;
const hex = @import("hex.zig");
const Transcript = @import("Transcript.zig");

pub const rq_size = 16;
pub const rs_size = 24;
/// `IPMI_BUF_SIZE` in include/ipmitool/ipmi.h.
pub const max_response_data = 1024;

pub const bye_netfn = 0x3f;
pub const bye_cmd = 0xff;

/// Harness-private "stop serving" request.
///
/// `Io`'s task cancelation cannot reliably interrupt a thread parked in
/// `accept`, so instead the harness connects once after the process under test
/// has exited and sends this. netfn `0xfe` is outside the 6-bit IPMI netfn
/// range, so no ipmitool code path can ever produce it; it is never logged and
/// never reaches a transcript.
pub const shutdown_netfn = 0xfe;
pub const shutdown_cmd = 0xfe;

pub const Result = struct {
    /// Human readable request/response log, snapshotted per test case.
    log: []const u8,
    /// Set when the server itself failed (as opposed to the client misbehaving).
    err: ?[]const u8 = null,
    exchanges: u32 = 0,
    /// True when at least one request fell through to `default_ccode`.
    had_unmatched: bool = false,
};

pub const State = struct {
    gpa: std.mem.Allocator,
    transcript: *Transcript,
    server: *Io.net.Server,
};

/// Serve connections until the caller cancels the task.
///
/// The caller cancels once the process under test has exited; a binary that
/// never opens the interface (`ipmitool -V`, argument errors, ...) simply
/// leaves the server blocked in `accept` until then, which is not an error.
///
/// Returns a `Result` rather than an error union so it can be handed to
/// `Io.concurrent` without the caller having to unwrap two layers.
pub fn serve(io: Io, state: *State) Result {
    const gpa = state.gpa;
    var log: std.ArrayList(u8) = .empty;
    var result: Result = .{ .log = "" };
    var connections: u32 = 0;

    while (true) {
        var stream = state.server.accept(io) catch |err| {
            if (err != error.Canceled and connections == 0) result.err = @errorName(err);
            break;
        };
        connections += 1;
        const stop = serveConnection(io, state, &stream, &log, &result);
        stream.close(io);
        if (stop or result.err != null) break;
    }

    result.log = log.toOwnedSlice(gpa) catch "";
    return result;
}

/// Serve one connection. Returns true when the harness asked the server to
/// stop accepting new connections.
fn serveConnection(
    io: Io,
    state: *State,
    stream: *Io.net.Stream,
    log: *std.ArrayList(u8),
    result: *Result,
) bool {
    const gpa = state.gpa;
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var data_buf: [64 * 1024]u8 = undefined;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);

    while (true) {
        var header: [rq_size]u8 = undefined;
        reader.interface.readSliceAll(&header) catch return false;

        const netfn = header[0];
        const lun = header[1];
        const cmd = header[2];
        const target_cmd = header[3];
        const data_len = std.mem.readInt(u16, header[4..6], native_endian);

        if (data_len > data_buf.len) {
            result.err = "request payload larger than the harness buffer";
            return false;
        }
        const request_data = data_buf[0..data_len];
        if (data_len > 0) reader.interface.readSliceAll(request_data) catch {
            result.err = "short read on request payload";
            return false;
        };

        if (netfn == shutdown_netfn and cmd == shutdown_cmd) return true;

        if (netfn == bye_netfn and cmd == bye_cmd) {
            log.appendSlice(gpa, "bye\n") catch {};
            return false;
        }

        result.exchanges += 1;
        const response = state.transcript.respond(
            gpa,
            &scratch,
            netfn,
            lun,
            cmd,
            request_data,
        ) catch {
            result.err = "out of memory building a transcript response";
            return false;
        };
        if (std.mem.eql(u8, response.rule_name, "default")) result.had_unmatched = true;

        logExchange(gpa, log, netfn, lun, cmd, target_cmd, request_data, response);

        if (response.data.len > max_response_data) {
            result.err = "transcript response is larger than IPMI_BUF_SIZE (1024)";
            return false;
        }

        var header_out: [rs_size]u8 = @splat(0);
        header_out[0] = netfn | 1; // responses use the odd "response" netfn
        header_out[1] = cmd;
        header_out[2] = response.seq;
        header_out[3] = lun;
        header_out[4] = response.ccode;
        std.mem.writeInt(i32, header_out[8..12], @intCast(response.data.len), native_endian);

        writer.interface.writeAll(&header_out) catch {
            result.err = "write of response header failed";
            return false;
        };
        writer.interface.writeAll(response.data) catch {
            result.err = "write of response payload failed";
            return false;
        };
        writer.interface.flush() catch {
            result.err = "flush of response failed";
            return false;
        };
    }
    return false;
}

/// Ask a running `serve` task to return. Called by the harness once the
/// process under test has exited.
pub fn requestShutdown(io: Io, address: Io.net.UnixAddress) void {
    const stream = address.connect(io) catch return;
    defer stream.close(io);
    var buf: [rq_size]u8 = undefined;
    var writer = stream.writer(io, &buf);
    var request: [rq_size]u8 = @splat(0);
    request[0] = shutdown_netfn;
    request[2] = shutdown_cmd;
    writer.interface.writeAll(&request) catch return;
    writer.interface.flush() catch return;
}

const native_endian = @import("builtin").cpu.arch.endian();

fn logExchange(
    gpa: std.mem.Allocator,
    log: *std.ArrayList(u8),
    netfn: u8,
    lun: u8,
    cmd: u8,
    target_cmd: u8,
    request_data: []const u8,
    response: Transcript.Response,
) void {
    log.print(gpa, "> netfn=0x{x:0>2} lun=0x{x:0>2} cmd=0x{x:0>2} target_cmd=0x{x:0>2} data=", .{
        netfn, lun, cmd, target_cmd,
    }) catch return;
    appendHex(gpa, log, request_data);
    log.print(gpa, "\n< rule={s} ccode=0x{x:0>2} len={d} data=", .{
        response.rule_name, response.ccode, response.data.len,
    }) catch return;
    appendHex(gpa, log, response.data);
    log.append(gpa, '\n') catch return;
}

fn appendHex(gpa: std.mem.Allocator, log: *std.ArrayList(u8), bytes: []const u8) void {
    for (bytes, 0..) |b, i| {
        if (i != 0) log.append(gpa, ' ') catch return;
        log.print(gpa, "{x:0>2}", .{b}) catch return;
    }
}
