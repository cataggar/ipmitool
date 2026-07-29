//! Port of `src/plugins/open/open.c`: the `open` transport, i.e. the Linux
//! OpenIPMI kernel driver reached through `/dev/ipmi*`.
//!
//! Everything crosses the kernel boundary as an `ioctl(2)`, so the structs
//! below are the driver ABI and not an internal convention.  They are
//! hand-written here rather than translated from `<linux/ipmi.h>`, because the
//! goal of the migration is a tree that builds without kernel headers.  Two
//! independent checks keep them honest:
//!
//! * `abi.assertLayout()` against ipmitool's own `src/plugins/open/open.h`,
//!   which is what upstream falls back to when no driver header exists; and
//! * `test "the driver ABI matches <linux/ipmi.h>"`, which pins every size,
//!   offset and `ioctl` number against the numbers that header produces.
//!
//! The first catches drift from upstream, the second catches drift from the
//! kernel.  Neither is redundant: `open.h` is a *copy*, and a copy can be wrong.
//!
//! ## Testing
//!
//! No unprivileged process can create a file descriptor that answers
//! `IPMICTL_*`, so `open()`, `ioctl()` and `select()` are reached through three
//! one-line seams that call libc in every build except `zig build test`, where
//! they route to the model OpenIPMI driver at the bottom of this file.  The
//! model checks what a driver would check -- address type and length, IPMB
//! slave address and channel, both `Send Message` checksums, message id growth
//! -- so a mutation in the packet assembly is caught by the same mechanism
//! `tests/transport/Bmc.zig` uses for `lan`.
//!
//! ## Upstream behaviour reproduced deliberately
//!
//! 1. `ipmi_openipmi_open()` leaks `intf->fd` when
//!    `IPMICTL_SET_GETS_EVENTS_CMD` fails: it returns -1 with the descriptor
//!    still open and `intf->opened` still 0.
//! 2. It leaks it again when `set_my_addr` fails, and this time `intf->opened`
//!    has already been set to 1, so the interface looks open to everything that
//!    checks that flag.
//! 3. `index` in the bridged `Send Message` encapsulation is a `uint8_t`, so a
//!    request whose payload pushes the total past 255 bytes wraps and rewrites
//!    the front of the buffer.  `max_request_data_size` is 38, so this is not
//!    reachable through the normal path.
//! 4. The decapsulation runs `memmove(data, data + 7, data_len - 7)` and then
//!    `data_len -= 8`.  The two disagree by one, and `data_len - 7` is computed
//!    as a *signed* int on an `unsigned short`, so a response shorter than 7
//!    bytes turns into a `size_t` near `SIZE_MAX`.
//! 5. It also reads `recv.msg.data[0]` before checking that anything arrived.
//! 6. `rsp.data_len = recv.msg.data_len - 1` is -1 for an empty response, and
//!    that -1 reaches the caller.
//! 7. `fd_set rset` is filled once, *outside* the retransmit loop, but
//!    `select(2)` overwrites it.  A second iteration therefore selects on
//!    whatever the first left behind.
//! 8. `read_timeout` is likewise passed straight back to `select(2)`, which on
//!    Linux decrements it in place, so the second iteration inherits the
//!    remainder rather than a fresh 15 seconds.
//! 9. An `IPMICTL_RECEIVE_MSG_TRUNC` failure with `errno == EMSGSIZE` is logged
//!    and then *ignored*: the truncated message is processed as if it arrived
//!    intact.
//! 10. `struct ipmi_addr addr` is never initialised.  Only the `verbose > 4`
//!     dump reads it, and only the driver ever writes it.
//! 11. The first line of that dump, `"Got message:"`, has no trailing newline.
//! 12. The `!intf` and `!req` guards in `ipmi_openipmi_send_cmd()` are dead: the
//!     vtable's parameter types are non-optional pointers here, so neither
//!     check has a Zig counterpart.

const builtin = @import("builtin");
const std = @import("std");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("intf.zig");
const helper = @import("../util/helper.zig");
const log = @import("../util/log.zig");

const Intf = intf_mod.Intf;

/// Maximum input message size for KCS/SMIC is 40 with 2 utility bytes and 38
/// bytes of data; for BT it is 42 with 4 utility bytes and 38 bytes of data.
const max_rq_data_size = 38;

/// Maximum output message size for KCS/SMIC is 38 with 2 utility bytes, a byte
/// for the completion code and 35 bytes of data; for BT it is 40 with 4 utility
/// bytes, a byte for the completion code and 35 bytes of data.
const max_rs_data_size = 35;

/// Timeout for reading data from the BMC, in seconds.
const read_timeout_seconds = 15;

// ---------------------------------------------------------------------------
// OpenIPMI driver ABI
// ---------------------------------------------------------------------------

/// `IPMI_MAX_ADDR_SIZE`.
pub const max_addr_size = 0x20;

/// `IPMI_BMC_CHANNEL`.
pub const bmc_channel = 0xf;

/// `IPMI_SYSTEM_INTERFACE_ADDR_TYPE`.
pub const system_interface_addr_type = 0x0c;

/// `IPMI_IPMB_ADDR_TYPE`.
pub const ipmb_addr_type = 0x01;

/// `struct ipmi_addr`: the driver's generic address, big enough for any of the
/// specific ones below.
pub const Addr = extern struct {
    addr_type: c_int,
    channel: c_short,
    data: [max_addr_size]u8,
};

/// `struct ipmi_msg`.
pub const Msg = extern struct {
    netfn: u8,
    cmd: u8,
    data_len: c_ushort,
    data: ?[*]u8,
};

/// `struct ipmi_req`: the payload of `IPMICTL_SEND_COMMAND`.
pub const Req = extern struct {
    addr: ?[*]u8,
    addr_len: c_uint,
    msgid: c_long,
    msg: Msg,
};

/// `struct ipmi_recv`: the payload of `IPMICTL_RECEIVE_MSG_TRUNC`.
pub const Recv = extern struct {
    recv_type: c_int,
    addr: ?[*]u8,
    addr_len: c_uint,
    msgid: c_long,
    msg: Msg,
};

/// `struct ipmi_system_interface_addr`.
pub const SystemInterfaceAddr = extern struct {
    addr_type: c_int,
    channel: c_short,
    lun: u8,
};

/// `struct ipmi_ipmb_addr`.
pub const IpmbAddr = extern struct {
    addr_type: c_int,
    channel: c_short,
    slave_addr: u8,
    lun: u8,
};

/// `_IOC()` from `<asm-generic/ioctl.h>`, which every architecture ipmitool
/// builds for uses.  The result is an `unsigned int` in C and is therefore
/// zero-extended into `ioctl()`'s `unsigned long` request, not sign-extended --
/// the `_IOR` numbers below all have bit 31 set, so the difference is real.
fn ioc(dir: u32, io_type: u32, nr: u32, size: usize) c_ulong {
    return (dir << 30) | (@as(u32, @intCast(size)) << 16) | (io_type << 8) | nr;
}

const ioc_write = 1;
const ioc_read = 2;

/// `IPMI_IOC_MAGIC`.
const ioc_magic = 'i';

fn ior(nr: u32, comptime T: type) c_ulong {
    return ioc(ioc_read, ioc_magic, nr, @sizeOf(T));
}

fn iowr(nr: u32, comptime T: type) c_ulong {
    return ioc(ioc_read | ioc_write, ioc_magic, nr, @sizeOf(T));
}

/// `IPMICTL_RECEIVE_MSG_TRUNC`.
pub const ipmictl_receive_msg_trunc = iowr(11, Recv);

/// `IPMICTL_RECEIVE_MSG`.
pub const ipmictl_receive_msg = iowr(12, Recv);

/// `IPMICTL_SEND_COMMAND`.
pub const ipmictl_send_command = ior(13, Req);

/// `IPMICTL_SET_GETS_EVENTS_CMD`.
pub const ipmictl_set_gets_events_cmd = ior(16, c_int);

/// `IPMICTL_SET_MY_ADDRESS_CMD`.
pub const ipmictl_set_my_address_cmd = ior(17, c_uint);

// ---------------------------------------------------------------------------
// Syscall seams
// ---------------------------------------------------------------------------

/// True only in `zig build test`.  Everything below calls libc otherwise, and
/// the model driver is not compiled into the product at all.
const use_model_driver = builtin.is_test;

fn sysOpen(path: [*:0]const u8, flags: c_int) c_int {
    if (use_model_driver) return ModelDriver.open(path, flags);
    return c.open(path, flags);
}

fn sysIoctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) c_int {
    if (use_model_driver) return ModelDriver.ioctl(fd, request, arg);
    return c.ioctl(fd, request, arg);
}

fn sysSelect(nfds: c_int, readfds: *c.fd_set, timeout: *c.struct_timeval) c_int {
    if (use_model_driver) return ModelDriver.select(nfds, readfds, timeout);
    return c.select(nfds, readfds, null, null, timeout);
}

// ---------------------------------------------------------------------------
// fd_set, which is macros in C
// ---------------------------------------------------------------------------

const fd_mask_bits = @bitSizeOf(c.__fd_mask);

fn fdZero(set: *c.fd_set) void {
    @memset(&set.__fds_bits, 0);
}

fn fdSet(fd: c_int, set: *c.fd_set) void {
    const bit = @as(usize, @intCast(fd));
    set.__fds_bits[bit / fd_mask_bits] |= @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
}

fn fdIsSet(fd: c_int, set: *const c.fd_set) bool {
    const bit = @as(usize, @intCast(fd));
    const mask = @as(c.__fd_mask, 1) << @intCast(bit % fd_mask_bits);
    return (set.__fds_bits[bit / fd_mask_bits] & mask) != 0;
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

/// `ipmi_openipmi_open()`: find the device node, enable the event receiver and
/// announce our IPMB address.
fn open(intf: *Intf) callconv(.c) c_int {
    var ipmi_dev: [16]u8 = undefined;
    var ipmi_devfs: [16]u8 = undefined;
    var ipmi_devfs2: [17]u8 = undefined;
    var devnum: c_int = 0;

    devnum = intf.devnum;

    _ = c.sprintf(&ipmi_dev, "/dev/ipmi%d", devnum);
    _ = c.sprintf(&ipmi_devfs, "/dev/ipmi/%d", devnum);
    _ = c.sprintf(&ipmi_devfs2, "/dev/ipmidev/%d", devnum);
    c.lprintf(log.Level.debug, "Using ipmi device %d", devnum);

    intf.fd = sysOpen(@ptrCast(&ipmi_dev), c.O_RDWR);

    if (intf.fd < 0) {
        intf.fd = sysOpen(@ptrCast(&ipmi_devfs), c.O_RDWR);
        if (intf.fd < 0) {
            intf.fd = sysOpen(@ptrCast(&ipmi_devfs2), c.O_RDWR);
        }
        if (intf.fd < 0) {
            c.lperror(
                log.Level.err,
                "Could not open device at %s or %s or %s",
                &ipmi_dev,
                &ipmi_devfs,
                &ipmi_devfs2,
            );
            return -1;
        }
    }

    var receive_events: c_int = c.TRUE;

    if (sysIoctl(intf.fd, ipmictl_set_gets_events_cmd, &receive_events) < 0) {
        // The descriptor stays open; see note 1 above.
        c.lperror(log.Level.err, "Could not enable event receiver");
        return -1;
    }

    intf.opened = 1;

    // This is never set to 0, the default is IPMI_BMC_SLAVE_ADDR.
    if (intf.my_addr != 0) {
        if (intf.set_my_addr.?(intf, @truncate(intf.my_addr)) < 0) {
            // `opened` is already 1 and the descriptor is still open; note 2.
            c.lperror(log.Level.err, "Could not set IPMB address");
            return -1;
        }
        c.lprintf(log.Level.debug, "Set IPMB address to 0x%x", intf.my_addr);
    }

    intf.manufacturer_id = @enumFromInt(c.ipmi_get_oem(@ptrCast(intf)));
    return intf.fd;
}

/// `ipmi_openipmi_set_my_addr()`.
fn setMyAddr(intf: *Intf, addr: u8) callconv(.c) c_int {
    var a: c_uint = addr;
    if (sysIoctl(intf.fd, ipmictl_set_my_address_cmd, &a) < 0) {
        c.lperror(log.Level.err, "Could not set IPMB address");
        return -1;
    }
    intf.my_addr = addr;
    return 0;
}

/// `ipmi_openipmi_close()`.
fn close(intf: *Intf) callconv(.c) void {
    if (intf.fd >= 0) {
        _ = c.close(intf.fd);
        intf.fd = -1;
    }

    intf.opened = 0;
    intf.manufacturer_id = @enumFromInt(c.IPMI_OEM_UNKNOWN);
}

/// The `static struct ipmi_rs rsp` inside `ipmi_openipmi_send_cmd()`.  Its
/// address is what the function returns, so it outlives the call.
var rsp: ipmi.Response = std.mem.zeroes(ipmi.Response);

/// The `static int curr_seq` inside `ipmi_openipmi_send_cmd()`: one message id
/// counter shared by every call, never reset.
var curr_seq: c_int = 0;

/// `ipmi_openipmi_send_cmd()`.
fn sendrecv(intf: *Intf, req: *ipmi.Request) callconv(.c) ?*ipmi.Response {
    var recv: Recv = std.mem.zeroes(Recv);
    // Deliberately uninitialised, exactly as upstream; see note 10 above.
    var addr: Addr = undefined;
    var bmc_addr: SystemInterfaceAddr = .{
        .addr_type = system_interface_addr_type,
        .channel = bmc_channel,
        .lun = 0,
    };
    var ipmb_addr: IpmbAddr = .{
        .addr_type = ipmb_addr_type,
        .channel = 0,
        .slave_addr = 0,
        .lun = 0,
    };
    var _req: Req = undefined;
    var read_timeout: c.struct_timeval = undefined;
    var rset: c.fd_set = undefined;

    var data: ?[*]u8 = null;
    var data_len: c_int = 0;
    var retval: c_int = 0;

    ipmb_addr.channel = intf.target_channel & 0x0f;

    if (intf.opened == 0 and intf.open != null) {
        if (intf.open.?(intf) < 0) return null;
    }

    if (c.verbose > 2) {
        _ = c.fprintf(c.stderr, "OpenIPMI Request Message Header:\n");
        _ = c.fprintf(c.stderr, "  netfn     = 0x%x\n", @as(c_int, req.msg.netfn_lun.netfn));
        _ = c.fprintf(c.stderr, "  cmd       = 0x%x\n", @as(c_int, req.msg.cmd));
        c.printbuf(req.msg.data, req.msg.data_len, "OpenIPMI Request Message Data");
    }

    // Set up and send the message.

    _req = std.mem.zeroes(Req);

    if (intf.target_addr != 0 and intf.target_addr != intf.my_addr) {
        // Use the IPMB address if needed.
        ipmb_addr.slave_addr = @truncate(intf.target_addr);
        ipmb_addr.lun = req.msg.netfn_lun.lun;
        c.lprintf(
            log.Level.debug,
            "Sending request 0x%x to IPMB target @ 0x%x:0x%x (from 0x%x)",
            @as(c_int, req.msg.cmd),
            intf.target_addr,
            @as(c_int, intf.target_channel),
            intf.my_addr,
        );

        if (intf.transit_addr != 0 and intf.transit_addr != intf.my_addr) {
            var index: u8 = 0;

            c.lprintf(
                log.Level.debug,
                "Encapsulating data sent to end target [0x%02x,0x%02x] using transit [0x%02x,0x%02x] from 0x%x ",
                @as(c_int, 0x40 | intf.target_channel),
                intf.target_addr,
                @as(c_int, intf.transit_channel),
                intf.transit_addr,
                intf.my_addr,
            );

            // Convert the message to a 'Send Message'.  The supplied request is
            // `req`, the internal one is `_req`.

            if (c.verbose > 4) {
                _ = c.fprintf(c.stderr, "Converting message:\n");
                _ = c.fprintf(c.stderr, "  netfn     = 0x%x\n", @as(c_int, req.msg.netfn_lun.netfn));
                _ = c.fprintf(c.stderr, "  cmd       = 0x%x\n", @as(c_int, req.msg.cmd));
                if (req.msg.data != null and req.msg.data_len != 0) {
                    _ = c.fprintf(c.stderr, "  data_len  = %d\n", @as(c_int, req.msg.data_len));
                    _ = c.fprintf(c.stderr, "  data      = %s\n", c.buf2str(req.msg.data, req.msg.data_len));
                }
            }

            // Modify the target address to use the transit one instead.
            ipmb_addr.slave_addr = @truncate(intf.transit_addr);
            ipmb_addr.channel = intf.transit_channel;

            // FIXME backup "My address"
            data_len = @as(c_int, req.msg.data_len) + 8;
            data = @ptrCast(@alignCast(c.malloc(@intCast(data_len))));
            if (data == null) {
                c.lprintf(log.Level.err, "ipmitool: malloc failure");
                return null;
            }

            const buf = data.?;
            @memset(buf[0..@intCast(data_len)], 0);

            // `index` is a uint8_t upstream and is not widened here; note 3.
            buf[index] = 0x40 | intf.target_channel;
            index +%= 1;
            buf[index] = @truncate(intf.target_addr);
            index +%= 1;
            buf[index] = (@as(u8, req.msg.netfn_lun.netfn) << 2) | req.msg.netfn_lun.lun;
            index +%= 1;
            buf[index] = helper.ipmiCsum(buf + 1, 2);
            index +%= 1;
            // Normally 0x20, overwritten by the IPMC.
            buf[index] = 0xFF;
            index +%= 1;
            // FIXME
            buf[index] = (0 << 2) | 0;
            index +%= 1;
            buf[index] = req.msg.cmd;
            index +%= 1;
            if (req.msg.data_len != 0) {
                @memcpy(buf[index..][0..req.msg.data_len], req.msg.data.?[0..req.msg.data_len]);
            }
            index +%= @truncate(req.msg.data_len);
            buf[index] = helper.ipmiCsum(buf + 4, @as(c_int, req.msg.data_len) + 3);
            index +%= 1;

            if (c.verbose > 4) {
                _ = c.fprintf(c.stderr, "Encapsulated message:\n");
                _ = c.fprintf(c.stderr, "  netfn     = 0x%x\n", @as(c_int, ipmi.NetFn.app));
                _ = c.fprintf(c.stderr, "  cmd       = 0x%x\n", @as(c_int, 0x34));
                if (data != null and data_len != 0) {
                    _ = c.fprintf(c.stderr, "  data_len  = %d\n", data_len);
                    _ = c.fprintf(c.stderr, "  data      = %s\n", c.buf2str(data, data_len));
                }
            }
        }
        _req.addr = @ptrCast(&ipmb_addr);
        _req.addr_len = @sizeOf(IpmbAddr);
    } else {
        // Otherwise use the system interface.
        c.lprintf(
            log.Level.debug + 2,
            "Sending request 0x%x to System Interface",
            @as(c_int, req.msg.cmd),
        );
        bmc_addr.lun = req.msg.netfn_lun.lun;
        _req.addr = @ptrCast(&bmc_addr);
        _req.addr_len = @sizeOf(SystemInterfaceAddr);
    }

    _req.msgid = curr_seq;
    curr_seq +%= 1;

    // In case of a bridge request.
    if (data != null and data_len != 0) {
        _req.msg.data = data;
        _req.msg.data_len = @intCast(data_len);
        _req.msg.netfn = ipmi.NetFn.app;
        _req.msg.cmd = 0x34;
    } else {
        _req.msg.data = req.msg.data;
        _req.msg.data_len = req.msg.data_len;
        _req.msg.netfn = req.msg.netfn_lun.netfn;
        _req.msg.cmd = req.msg.cmd;
    }

    if (sysIoctl(intf.fd, ipmictl_send_command, &_req) < 0) {
        c.lperror(log.Level.err, "Unable to send command");
        c.free_n(@ptrCast(&data));
        return null;
    }

    // Wait for and retrieve the response.

    if (intf.noanswer != 0) {
        c.free_n(@ptrCast(&data));
        return null;
    }

    // Both of these are filled in once, outside the loop, and `select(2)`
    // overwrites both; see notes 7 and 8.
    fdZero(&rset);
    fdSet(intf.fd, &rset);
    read_timeout.tv_sec = read_timeout_seconds;
    read_timeout.tv_usec = 0;
    while (true) {
        while (true) {
            retval = sysSelect(intf.fd + 1, &rset, &read_timeout);
            if (!(retval < 0 and std.c._errno().* == c.EINTR)) break;
        }
        if (retval < 0) {
            c.lperror(log.Level.err, "I/O Error");
            c.free_n(@ptrCast(&data));
            return null;
        } else if (retval == 0) {
            c.lprintf(log.Level.err, "No data available");
            c.free_n(@ptrCast(&data));
            return null;
        }
        if (!fdIsSet(intf.fd, &rset)) {
            c.lprintf(log.Level.err, "No data available");
            c.free_n(@ptrCast(&data));
            return null;
        }

        recv.addr = @ptrCast(&addr);
        recv.addr_len = @sizeOf(Addr);
        recv.msg.data = &rsp.data;
        recv.msg.data_len = @intCast(rsp.data.len);

        // Get data.
        if (sysIoctl(intf.fd, ipmictl_receive_msg_trunc, &recv) < 0) {
            c.lperror(log.Level.err, "Error receiving message");
            if (std.c._errno().* != c.EMSGSIZE) {
                c.free_n(@ptrCast(&data));
                return null;
            }
            // Otherwise the truncated message is used as-is; see note 9.
        }

        // If the message received wasn't expected, try to grab the next message
        // until it's out of messages.  -EAGAIN is returned if the list is empty,
        // but basically if it returns a message, check if it's alright.
        if (_req.msgid != recv.msgid) {
            c.lprintf(
                log.Level.notice,
                "Received a response with unexpected ID %ld vs. %ld",
                recv.msgid,
                _req.msgid,
            );
        }
        if (_req.msgid == recv.msgid) break;
    }

    if (c.verbose > 4) {
        // No trailing newline on the first line; see note 11.
        _ = c.fprintf(c.stderr, "Got message:");
        _ = c.fprintf(c.stderr, "  type      = %d\n", recv.recv_type);
        _ = c.fprintf(c.stderr, "  channel   = 0x%x\n", @as(c_int, addr.channel));
        _ = c.fprintf(c.stderr, "  msgid     = %ld\n", recv.msgid);
        _ = c.fprintf(c.stderr, "  netfn     = 0x%x\n", @as(c_int, recv.msg.netfn));
        _ = c.fprintf(c.stderr, "  cmd       = 0x%x\n", @as(c_int, recv.msg.cmd));
        if (recv.msg.data != null and recv.msg.data_len != 0) {
            _ = c.fprintf(c.stderr, "  data_len  = %d\n", @as(c_int, recv.msg.data_len));
            _ = c.fprintf(c.stderr, "  data      = %s\n", c.buf2str(recv.msg.data, recv.msg.data_len));
        }
    }

    if (intf.transit_addr != 0 and intf.transit_addr != intf.my_addr) {
        c.lprintf(
            log.Level.debug,
            "Decapsulating data received from transit IPMB target @ 0x%x",
            intf.transit_addr,
        );

        // Completion code, then check the data.
        if (recv.msg.data.?[0] == 0) {
            recv.msg.netfn = recv.msg.data.?[2] >> 2;
            recv.msg.cmd = recv.msg.data.?[6];

            // `data_len - 7` is signed and `data_len -= 8` is not the same
            // amount; see note 4.
            const move: c_int = @as(c_int, recv.msg.data_len) -% 7;
            const move_len: usize = @bitCast(@as(isize, move));
            std.mem.copyForwards(
                u8,
                recv.msg.data.?[0..move_len],
                recv.msg.data.?[7..][0..move_len],
            );
            recv.msg.data_len -%= 8;

            if (c.verbose > 4) {
                _ = c.fprintf(c.stderr, "Decapsulated  message:\n");
                _ = c.fprintf(c.stderr, "  netfn     = 0x%x\n", @as(c_int, recv.msg.netfn));
                _ = c.fprintf(c.stderr, "  cmd       = 0x%x\n", @as(c_int, recv.msg.cmd));
                if (recv.msg.data != null and recv.msg.data_len != 0) {
                    _ = c.fprintf(c.stderr, "  data_len  = %d\n", @as(c_int, recv.msg.data_len));
                    _ = c.fprintf(c.stderr, "  data      = %s\n", c.buf2str(recv.msg.data, recv.msg.data_len));
                }
            }
        }
    }

    // Save the completion code.  Nothing has checked that a byte arrived; note 5.
    rsp.ccode = recv.msg.data.?[0];
    rsp.data_len = @as(c_int, recv.msg.data_len) -% 1;

    // Save the response data for the caller.
    if (rsp.ccode == 0 and rsp.data_len > 0) {
        const n: usize = @intCast(rsp.data_len);
        std.mem.copyForwards(u8, rsp.data[0..n], rsp.data[1..][0..n]);
        rsp.data[n] = 0;
    }

    c.free_n(@ptrCast(&data));

    return &rsp;
}

/// `ipmi_openipmi_setup()`: the only entry point the C exports besides the
/// vtable itself.
fn setup(intf: *Intf) callconv(.c) c_int {
    // Set the default payload size.
    intf.max_request_data_size = max_rq_data_size;
    intf.max_response_data_size = max_rs_data_size;

    return 0;
}

/// `struct ipmi_intf ipmi_open_intf`.  Everything the C initializer leaves out
/// is zero, including `target_addr`, which is spelled out upstream so that
/// `-m local_addr` does not cause bridging.
var open_intf: Intf = blk: {
    var i: Intf = std.mem.zeroes(Intf);
    const name = "open";
    const desc = "Linux OpenIPMI Interface";
    @memcpy(i.name[0..name.len], name);
    @memcpy(i.desc[0..desc.len], desc);
    i.setup = setup;
    i.open = open;
    i.close = close;
    i.sendrecv = sendrecv;
    i.set_my_addr = setMyAddr;
    i.my_addr = c.IPMI_BMC_SLAVE_ADDR;
    i.target_addr = 0;
    break :blk i;
};

// ---------------------------------------------------------------------------
// ABI parity
// ---------------------------------------------------------------------------

comptime {
    abi.assertLayout(Addr, c.struct_ipmi_addr);
    abi.assertLayout(Msg, c.struct_ipmi_msg);
    abi.assertLayout(Req, c.struct_ipmi_req);
    abi.assertLayout(Recv, c.struct_ipmi_recv);
    abi.assertLayout(SystemInterfaceAddr, c.struct_ipmi_system_interface_addr);
    abi.assertLayout(IpmbAddr, c.struct_ipmi_ipmb_addr);
}

pub fn exportSymbols() void {
    abi.assertCallSignature(@TypeOf(setup), @TypeOf(c.ipmi_openipmi_setup));
    @export(&setup, .{ .name = "ipmi_openipmi_setup" });

    @export(&open_intf, .{ .name = "ipmi_open_intf" });
}

// ---------------------------------------------------------------------------
// Model OpenIPMI driver
// ---------------------------------------------------------------------------

/// A stand-in for `/dev/ipmi0` that lives entirely in the test binary.
///
/// It is not a recording of a real driver: it *checks* what a driver checks.
/// `IPMICTL_SEND_COMMAND` verifies the address type, the address length, the
/// IPMB slave address and channel and both `Send Message` checksums, so a
/// packet-assembly mutation fails here rather than showing up as a diff nobody
/// reads.  Everything it records is exposed for assertions.
const ModelDriver = struct {
    const max_paths = 4;
    const max_data = 512;

    /// What a driver expects the caller to have room for: one whole message.
    const ipmi_max_msg_size = 1024;

    /// What `open()` should succeed on.  Everything else gets `ENOENT`.
    var present: []const []const u8 = &.{};

    /// Every path `open()` was tried with, in order.
    var attempts: [max_paths][32]u8 = @splat(@splat(0));
    var attempt_flags: [max_paths]c_int = @splat(0);
    var attempt_count: usize = 0;

    /// The descriptor `open()` hands back, and the other end of the pipe, kept
    /// so that a real file descriptor number flows through the port.
    var fds: [2]c_int = .{ -1, -1 };

    var events_arg: c_int = -1;
    var events_calls: usize = 0;
    var events_rc: c_int = 0;

    var my_addr_arg: c_uint = 0;
    var my_addr_calls: usize = 0;
    var my_addr_rc: c_int = 0;

    /// The last `struct ipmi_req` seen, unpacked.
    var sent_addr: [64]u8 = @splat(0);
    var sent_addr_len: c_uint = 0;
    var sent_msgid: c_long = 0;
    var sent_netfn: u8 = 0;
    var sent_cmd: u8 = 0;
    var sent_data: [max_data]u8 = @splat(0);
    var sent_data_len: usize = 0;
    var sent_count: usize = 0;
    var send_rc: c_int = 0;
    /// `:BAD` markers, in the spirit of `tests/transport/Bmc.zig`.
    var complaints: [8][]const u8 = @splat("");
    var complaint_count: usize = 0;

    /// Queued replies, consumed one per `IPMICTL_RECEIVE_MSG_TRUNC`.
    const Reply = struct {
        msgid: ?c_long = null,
        recv_type: c_int = 1,
        netfn: u8 = 0,
        cmd: u8 = 0,
        channel: c_short = 0,
        data: []const u8 = &.{},
        rc: c_int = 0,
        errno: c_int = 0,
    };
    var replies: [4]Reply = @splat(.{});
    var reply_count: usize = 0;
    var reply_next: usize = 0;

    /// What `select()` should do, and what it saw.
    var select_clear_fd: bool = false;
    var select_rc: [4]c_int = @splat(1);
    var select_errno: [4]c_int = @splat(0);
    var select_calls: usize = 0;
    var select_nfds: c_int = 0;
    var select_tv_sec: c_long = 0;
    var select_tv_usec: c_long = 0;
    var select_had_fd: bool = false;

    /// The two buffer sizes the caller offers `IPMICTL_RECEIVE_MSG_TRUNC`.
    /// A real driver writes up to both of them, so understating either is a
    /// truncation the model has to notice.
    var recv_addr_len: c_uint = 0;
    var recv_capacity: c_ushort = 0;

    fn reset() void {
        present = &.{};
        attempts = @splat(@splat(0));
        attempt_flags = @splat(0);
        attempt_count = 0;
        if (fds[0] >= 0) _ = c.close(fds[0]);
        if (fds[1] >= 0) _ = c.close(fds[1]);
        fds = .{ -1, -1 };
        events_arg = -1;
        events_calls = 0;
        events_rc = 0;
        my_addr_arg = 0;
        my_addr_calls = 0;
        my_addr_rc = 0;
        sent_addr = @splat(0);
        sent_addr_len = 0;
        sent_msgid = 0;
        sent_netfn = 0;
        sent_cmd = 0;
        sent_data = @splat(0);
        sent_data_len = 0;
        sent_count = 0;
        send_rc = 0;
        complaints = @splat("");
        complaint_count = 0;
        replies = @splat(.{});
        reply_count = 0;
        reply_next = 0;
        select_clear_fd = false;
        select_rc = @splat(1);
        select_errno = @splat(0);
        select_calls = 0;
        select_nfds = 0;
        select_tv_sec = 0;
        select_tv_usec = 0;
        select_had_fd = false;
        recv_addr_len = 0;
        recv_capacity = 0;
        curr_seq = 0;
        rsp = std.mem.zeroes(ipmi.Response);
        crypto_stubs.printbuf_calls = 0;
        crypto_stubs.printbuf_len = -1;
        crypto_stubs.printbuf_desc = null;
        crypto_stubs.printbuf_data = @splat(0);
        stubs.oem_calls = 0;
    }

    fn complain(what: []const u8) void {
        if (complaint_count < complaints.len) {
            complaints[complaint_count] = what;
            complaint_count += 1;
        }
    }

    fn push(reply: Reply) void {
        replies[reply_count] = reply;
        reply_count += 1;
    }

    fn open(path: [*:0]const u8, flags: c_int) c_int {
        const slice = std.mem.sliceTo(path, 0);
        if (attempt_count < max_paths) {
            @memcpy(attempts[attempt_count][0..slice.len], slice);
            attempt_flags[attempt_count] = flags;
            attempt_count += 1;
        }
        for (present) |p| {
            if (std.mem.eql(u8, p, slice)) {
                if (fds[0] < 0) {
                    if (c.pipe(&fds) != 0) return -1;
                }
                return fds[0];
            }
        }
        std.c._errno().* = c.ENOENT;
        return -1;
    }

    fn ioctl(fd: c_int, request: c_ulong, arg: ?*anyopaque) c_int {
        if (fd != fds[0]) complain("ioctl on an unexpected descriptor");
        switch (request) {
            ipmictl_set_gets_events_cmd => {
                events_arg = @as(*c_int, @ptrCast(@alignCast(arg.?))).*;
                events_calls += 1;
                return events_rc;
            },
            ipmictl_set_my_address_cmd => {
                my_addr_arg = @as(*c_uint, @ptrCast(@alignCast(arg.?))).*;
                my_addr_calls += 1;
                return my_addr_rc;
            },
            ipmictl_send_command => return send(@ptrCast(@alignCast(arg.?))),
            ipmictl_receive_msg_trunc => return receive(@ptrCast(@alignCast(arg.?))),
            else => {
                complain("unknown ioctl");
                std.c._errno().* = c.ENOTTY;
                return -1;
            },
        }
    }

    fn send(req: *const Req) c_int {
        sent_count += 1;
        sent_addr_len = req.addr_len;
        if (req.addr_len > sent_addr.len) {
            complain("addr_len larger than any driver address");
            return -1;
        }
        @memcpy(sent_addr[0..req.addr_len], req.addr.?[0..req.addr_len]);
        sent_msgid = req.msgid;
        sent_netfn = req.msg.netfn;
        sent_cmd = req.msg.cmd;
        sent_data_len = req.msg.data_len;
        if (sent_data_len > sent_data.len) {
            complain("data_len larger than the model's buffer");
            return -1;
        }
        if (sent_data_len != 0) {
            @memcpy(sent_data[0..sent_data_len], req.msg.data.?[0..sent_data_len]);
        }

        // What a driver validates: the address it was handed has to be one of
        // the two shapes, with the length that shape implies.
        const addr_type = std.mem.bytesToValue(c_int, sent_addr[0..@sizeOf(c_int)]);
        switch (addr_type) {
            system_interface_addr_type => {
                if (req.addr_len != @sizeOf(SystemInterfaceAddr)) {
                    complain("system interface address with the wrong length");
                }
            },
            ipmb_addr_type => {
                if (req.addr_len != @sizeOf(IpmbAddr)) {
                    complain("IPMB address with the wrong length");
                }
            },
            else => complain("unknown address type"),
        }

        // A `Send Message` carries an encapsulated IPMB request, and a BMC
        // rejects it if either checksum is wrong.
        if (req.msg.netfn == ipmi.NetFn.app and req.msg.cmd == 0x34) {
            const body = sent_data[0..sent_data_len];
            if (body.len < 8) {
                complain("Send Message shorter than its own header");
            } else {
                if (helper.ipmiCsum(body.ptr + 1, 2) != body[3]) {
                    complain("Send Message connection header checksum");
                }
                const payload_len: c_int = @intCast(body.len - 8);
                if (helper.ipmiCsum(body.ptr + 4, payload_len + 3) != body[body.len - 1]) {
                    complain("Send Message message checksum");
                }
            }
        }

        if (send_rc == 0) {
            // Make the descriptor readable so `select()` has something real to
            // report, even though the model answers it.  One byte per queued
            // reply, because `receive()` consumes one each time.
            const byte: [1]u8 = .{0};
            var left = reply_count - reply_next;
            while (left > 0) : (left -= 1) _ = c.write(fds[1], &byte, 1);
        }
        return send_rc;
    }

    fn receive(out: *Recv) c_int {
        if (reply_next >= reply_count) {
            std.c._errno().* = c.EAGAIN;
            return -1;
        }
        const reply = replies[reply_next];
        reply_next += 1;

        recv_addr_len = out.addr_len;
        recv_capacity = out.msg.data_len;
        if (out.addr_len < @sizeOf(Addr)) {
            complain("receive offered less room than one struct ipmi_addr");
        }
        if (out.msg.data_len < ipmi_max_msg_size) {
            complain("receive offered less room than one IPMI message");
        }

        var byte: [1]u8 = undefined;
        _ = c.read(fds[0], &byte, 1);

        out.recv_type = reply.recv_type;
        out.msgid = reply.msgid orelse sent_msgid;
        out.msg.netfn = reply.netfn;
        out.msg.cmd = reply.cmd;
        if (out.addr) |a| {
            const model: Addr = .{
                .addr_type = system_interface_addr_type,
                .channel = reply.channel,
                .data = @splat(0),
            };
            @memcpy(a[0..@sizeOf(Addr)], std.mem.asBytes(&model));
        }
        if (reply.data.len > out.msg.data_len) {
            complain("reply longer than the buffer the caller offered");
            return -1;
        }
        @memcpy(out.msg.data.?[0..reply.data.len], reply.data);
        out.msg.data_len = @intCast(reply.data.len);
        if (reply.rc != 0) std.c._errno().* = reply.errno;
        return reply.rc;
    }

    fn select(nfds: c_int, readfds: *c.fd_set, timeout: *c.struct_timeval) c_int {
        const call = select_calls;
        select_calls += 1;
        if (call == 0) {
            select_nfds = nfds;
            select_tv_sec = timeout.tv_sec;
            select_tv_usec = timeout.tv_usec;
            select_had_fd = fdIsSet(fds[0], readfds);
        }
        const rc = if (call < select_rc.len) select_rc[call] else 1;
        if (rc <= 0) {
            std.c._errno().* = if (call < select_errno.len) select_errno[call] else 0;
            fdZero(readfds);
            return rc;
        }
        // A real `select()` narrows the set to what is ready and decrements the
        // timeout; both are what notes 7 and 8 are about.
        fdZero(readfds);
        if (!select_clear_fd) fdSet(fds[0], readfds);
        timeout.tv_sec -= 1;
        return rc;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const stubs = @import("test_stubs.zig");
const crypto_stubs = @import("../crypto/test_stubs.zig");

test {
    _ = stubs;
    _ = crypto_stubs;
}

/// Constants the model driver is driven with.
///
/// Every one is non-zero and no two share a byte, so a mutation that swaps two
/// fields, masks the wrong nibble or drops a write is visible.  A zero would
/// hide a short write, because the packet is assembled in a zeroed buffer.
const t = struct {
    const my_addr: u32 = 0x91;
    const target_addr: u32 = 0x3c;
    const transit_addr: u32 = 0x7e;
    /// High nibble set and bit 3 of the low nibble set, so `& 0x0f`, `& 0x07`,
    /// `& 0x1f` and "no mask" all disagree.
    const target_channel: u8 = 0xbd;
    const transit_channel: u8 = 0x6b;
    const netfn: u6 = 0x2c;
    const lun: u2 = 0x03;
    const cmd: u8 = 0x94;
    const data = [_]u8{ 0x17, 0x4e, 0x92, 0xdb };
    const oem: c_uint = 0x2a7f;
};

fn testIntf() Intf {
    var i = open_intf;
    i.fd = -1;
    i.my_addr = t.my_addr;
    return i;
}

fn testRequest(data: []u8) ipmi.Request {
    return .{ .msg = .{
        .netfn_lun = .{ .netfn = t.netfn, .lun = t.lun },
        .cmd = t.cmd,
        .target_cmd = 0,
        .data_len = @intCast(data.len),
        .data = data.ptr,
    } };
}

/// Open the model device and leave the interface in the state the real one is
/// in after `ipmi_openipmi_open()` returns.
fn openModel(intf: *Intf) !void {
    ModelDriver.present = &.{"/dev/ipmi0"};
    stubs.oem = t.oem;
    try std.testing.expect(open(intf) >= 0);
}

test "the driver ABI matches <linux/ipmi.h>" {
    // Recorded from a C program that includes the kernel header on this
    // machine.  `open.h` is only a copy of that ABI, so comparing against it
    // alone would not notice if the copy were wrong.
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Addr));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Msg));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(Req));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Recv));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SystemInterfaceAddr));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(IpmbAddr));

    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Addr, "channel"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(Addr, "data"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Msg, "data_len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Msg, "data"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Req, "addr_len"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Req, "msgid"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Req, "msg"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Recv, "addr"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Recv, "addr_len"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Recv, "msgid"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Recv, "msg"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(IpmbAddr, "slave_addr"));
    try std.testing.expectEqual(@as(usize, 7), @offsetOf(IpmbAddr, "lun"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(SystemInterfaceAddr, "lun"));

    // These all have bit 31 set, so a sign-extending `_IOC` would produce
    // 0xffffffff........ here and the kernel would answer ENOTTY.
    try std.testing.expectEqual(@as(c_ulong, 0xc030690b), ipmictl_receive_msg_trunc);
    try std.testing.expectEqual(@as(c_ulong, 0xc030690c), ipmictl_receive_msg);
    try std.testing.expectEqual(@as(c_ulong, 0x8028690d), ipmictl_send_command);
    try std.testing.expectEqual(@as(c_ulong, 0x80046910), ipmictl_set_gets_events_cmd);
    try std.testing.expectEqual(@as(c_ulong, 0x80046911), ipmictl_set_my_address_cmd);

    try std.testing.expectEqual(@as(c_int, 0x0c), system_interface_addr_type);
    try std.testing.expectEqual(@as(c_int, 0x01), ipmb_addr_type);
    try std.testing.expectEqual(@as(c_int, 0x0f), bmc_channel);
    try std.testing.expectEqual(@as(usize, 0x20), max_addr_size);
}

test "the hand-written ioctl numbers agree with src/plugins/open/open.h" {
    try std.testing.expectEqual(@as(c_ulong, c.IPMICTL_RECEIVE_MSG_TRUNC), ipmictl_receive_msg_trunc);
    try std.testing.expectEqual(@as(c_ulong, c.IPMICTL_RECEIVE_MSG), ipmictl_receive_msg);
    try std.testing.expectEqual(@as(c_ulong, c.IPMICTL_SEND_COMMAND), ipmictl_send_command);
    try std.testing.expectEqual(@as(c_ulong, c.IPMICTL_SET_GETS_EVENTS_CMD), ipmictl_set_gets_events_cmd);
    try std.testing.expectEqual(@as(c_ulong, c.IPMICTL_SET_MY_ADDRESS_CMD), ipmictl_set_my_address_cmd);
}

test "the vtable matches the C initializer" {
    try std.testing.expectEqualStrings("open", std.mem.sliceTo(&open_intf.name, 0));
    try std.testing.expectEqualStrings(
        "Linux OpenIPMI Interface",
        std.mem.sliceTo(&open_intf.desc, 0),
    );
    try std.testing.expect(open_intf.setup == setup);
    try std.testing.expect(open_intf.open == open);
    try std.testing.expect(open_intf.close == close);
    try std.testing.expect(open_intf.sendrecv == sendrecv);
    try std.testing.expect(open_intf.set_my_addr == setMyAddr);
    try std.testing.expectEqual(@as(u32, 0x20), open_intf.my_addr);
    try std.testing.expectEqual(@as(u32, 0), open_intf.target_addr);
    // Slots the C initializer leaves out.
    try std.testing.expect(open_intf.recv_sol == null);
    try std.testing.expect(open_intf.send_sol == null);
    try std.testing.expect(open_intf.keepalive == null);
}

test "setup publishes the KCS/SMIC/BT payload limits" {
    var intf = testIntf();
    intf.max_request_data_size = 0xffff;
    intf.max_response_data_size = 0xffff;
    try std.testing.expectEqual(@as(c_int, 0), setup(&intf));
    try std.testing.expectEqual(@as(u16, 38), intf.max_request_data_size);
    try std.testing.expectEqual(@as(u16, 35), intf.max_response_data_size);
}

test "open tries the three device names in order and gives up" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    intf.devnum = 7;

    try std.testing.expectEqual(@as(c_int, -1), open(&intf));
    try std.testing.expectEqual(@as(usize, 3), ModelDriver.attempt_count);
    try std.testing.expectEqualStrings(
        "/dev/ipmi7",
        std.mem.sliceTo(&ModelDriver.attempts[0], 0),
    );
    try std.testing.expectEqualStrings(
        "/dev/ipmi/7",
        std.mem.sliceTo(&ModelDriver.attempts[1], 0),
    );
    try std.testing.expectEqualStrings(
        "/dev/ipmidev/7",
        std.mem.sliceTo(&ModelDriver.attempts[2], 0),
    );
    for (ModelDriver.attempt_flags[0..3]) |flags| {
        try std.testing.expectEqual(@as(c_int, c.O_RDWR), flags);
    }
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
}

test "open falls through to /dev/ipmidev/<devnum>" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    ModelDriver.present = &.{"/dev/ipmidev/3"};
    stubs.oem = t.oem;
    var intf = testIntf();
    intf.devnum = 3;

    const fd = open(&intf);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(usize, 3), ModelDriver.attempt_count);
    try std.testing.expectEqual(fd, intf.fd);
}

test "open enables the event receiver, announces the address and asks for the OEM" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    stubs.oem_calls = 0;

    try openModel(&intf);

    try std.testing.expectEqual(@as(usize, 1), ModelDriver.attempt_count);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.events_calls);
    try std.testing.expectEqual(@as(c_int, c.TRUE), ModelDriver.events_arg);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.my_addr_calls);
    try std.testing.expectEqual(@as(c_uint, t.my_addr), ModelDriver.my_addr_arg);
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);
    try std.testing.expectEqual(@as(usize, 1), stubs.oem_calls);
    try std.testing.expectEqual(@as(u32, t.oem), @intFromEnum(intf.manufacturer_id));
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);
}

test "open does not announce an address of zero" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    intf.my_addr = 0;
    try openModel(&intf);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.my_addr_calls);
}

test "BUG: open leaks the descriptor when the event ioctl fails" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    ModelDriver.present = &.{"/dev/ipmi0"};
    ModelDriver.events_rc = -1;
    var intf = testIntf();

    try std.testing.expectEqual(@as(c_int, -1), open(&intf));
    // Upstream note 1: neither closed nor marked closed, and `set_my_addr` was
    // never reached.
    try std.testing.expect(intf.fd >= 0);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.my_addr_calls);
}

test "BUG: open leaves the interface marked open when the address ioctl fails" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    ModelDriver.present = &.{"/dev/ipmi0"};
    ModelDriver.my_addr_rc = -1;
    var intf = testIntf();

    try std.testing.expectEqual(@as(c_int, -1), open(&intf));
    // Upstream note 2.
    try std.testing.expect(intf.fd >= 0);
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);
}

test "set_my_addr stores the address it announced" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    ModelDriver.present = &.{"/dev/ipmi0"};
    var intf = testIntf();
    try openModel(&intf);

    try std.testing.expectEqual(@as(c_int, 0), setMyAddr(&intf, 0x5b));
    try std.testing.expectEqual(@as(c_uint, 0x5b), ModelDriver.my_addr_arg);
    try std.testing.expectEqual(@as(u32, 0x5b), intf.my_addr);

    ModelDriver.my_addr_rc = -1;
    try std.testing.expectEqual(@as(c_int, -1), setMyAddr(&intf, 0x6d));
    // The failed address is not recorded.
    try std.testing.expectEqual(@as(u32, 0x5b), intf.my_addr);
}

test "close releases the descriptor and forgets the OEM" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);

    close(&intf);
    try std.testing.expectEqual(@as(c_int, -1), intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(intf.manufacturer_id));
    // The model's descriptor is gone; do not let `reset()` close it twice.
    ModelDriver.fds[0] = -1;
}

test "close on an unopened interface touches no descriptor" {
    var intf = testIntf();
    intf.fd = -1;
    intf.opened = 1;
    close(&intf);
    try std.testing.expectEqual(@as(c_int, -1), intf.fd);
    try std.testing.expectEqual(@as(c_int, 0), intf.opened);
}

test "a system interface request carries the BMC channel and the request LUN" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{ 0x00, 0x5b, 0x6d, 0xc2, 0x39 } });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req);

    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);
    try std.testing.expectEqual(@as(c_uint, 8), ModelDriver.sent_addr_len);
    const addr = std.mem.bytesToValue(SystemInterfaceAddr, ModelDriver.sent_addr[0..8]);
    try std.testing.expectEqual(@as(c_int, 0x0c), addr.addr_type);
    try std.testing.expectEqual(@as(c_short, 0x0f), addr.channel);
    try std.testing.expectEqual(@as(u8, t.lun), addr.lun);

    try std.testing.expectEqual(@as(u8, t.netfn), ModelDriver.sent_netfn);
    try std.testing.expectEqual(@as(u8, t.cmd), ModelDriver.sent_cmd);
    try std.testing.expectEqualSlices(
        u8,
        &t.data,
        ModelDriver.sent_data[0..ModelDriver.sent_data_len],
    );
}

test "an IPMB request carries the target address and the low nibble of the channel" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);

    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);
    try std.testing.expectEqual(@as(c_uint, 8), ModelDriver.sent_addr_len);
    const addr = std.mem.bytesToValue(IpmbAddr, ModelDriver.sent_addr[0..8]);
    try std.testing.expectEqual(@as(c_int, 0x01), addr.addr_type);
    try std.testing.expectEqual(@as(c_short, t.target_channel & 0x0f), addr.channel);
    try std.testing.expectEqual(@as(u8, t.target_addr), addr.slave_addr);
    try std.testing.expectEqual(@as(u8, t.lun), addr.lun);
    // Not encapsulated: no transit address.
    try std.testing.expectEqual(@as(u8, t.netfn), ModelDriver.sent_netfn);
    try std.testing.expectEqual(@as(u8, t.cmd), ModelDriver.sent_cmd);
}

test "a request to my own address goes to the system interface" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.my_addr;
    intf.target_channel = t.target_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);

    const addr = std.mem.bytesToValue(SystemInterfaceAddr, ModelDriver.sent_addr[0..8]);
    try std.testing.expectEqual(@as(c_int, 0x0c), addr.addr_type);
}

test "a bridged request is wrapped in a Send Message" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    intf.transit_addr = t.transit_addr;
    intf.transit_channel = t.transit_channel;
    // 15 bytes, so the decapsulation below has something to move.
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{
        0x00, 0x11, 0xb3, 0x22, 0x33, 0x44, 0x94,
        0x00, 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88,
        0x99,
    } });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);

    // The transit address replaces the target one, and its channel is used
    // whole rather than masked.
    const addr = std.mem.bytesToValue(IpmbAddr, ModelDriver.sent_addr[0..8]);
    try std.testing.expectEqual(@as(c_int, 0x01), addr.addr_type);
    try std.testing.expectEqual(@as(c_short, t.transit_channel), addr.channel);
    try std.testing.expectEqual(@as(u8, t.transit_addr), addr.slave_addr);
    try std.testing.expectEqual(@as(u8, t.lun), addr.lun);

    try std.testing.expectEqual(@as(u8, ipmi.NetFn.app), ModelDriver.sent_netfn);
    try std.testing.expectEqual(@as(u8, 0x34), ModelDriver.sent_cmd);
    try std.testing.expectEqualSlices(u8, &.{
        0xfd, // 0x40 | target_channel
        0x3c, // target_addr
        0xb3, // netfn << 2 | lun
        0x11, // checksum over the two bytes before it
        0xff, // overwritten by the IPMC
        0x00, // rq_seq << 2 | rq_lun, hard-coded upstream
        0x94, // cmd
        0x17,
        0x4e,
        0x92,
        0xdb,
        0x9b, // checksum over the seven bytes before it
    }, ModelDriver.sent_data[0..ModelDriver.sent_data_len]);

    // Decapsulation: netfn from byte 2, cmd from byte 6, then the seven-byte
    // header is dropped but eight bytes are subtracted from the length.
    try std.testing.expectEqual(@as(c_int, 6), got.?.data_len);
    try std.testing.expectEqual(@as(u8, 0), got.?.ccode);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88 },
        got.?.data[0..6],
    );
}

test "message ids grow by one and are never reused" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);

    var data = t.data;
    var req = testRequest(&data);

    var previous: c_long = -1;
    for (0..3) |_| {
        ModelDriver.reply_count = 0;
        ModelDriver.reply_next = 0;
        ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });
        try std.testing.expect(sendrecv(&intf, &req) != null);
        try std.testing.expectEqual(previous + 1, ModelDriver.sent_msgid);
        previous = ModelDriver.sent_msgid;
    }
}

test "a reply with the wrong message id is dropped and the next one is taken" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .msgid = 0x5b6d, .netfn = 0x11, .cmd = 0x22, .data = &.{ 0x00, 0xaa } });
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{ 0x00, 0x4e, 0x92 } });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req);

    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 2), ModelDriver.reply_next);
    try std.testing.expectEqual(@as(c_int, 2), got.?.data_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x4e, 0x92 }, got.?.data[0..2]);
}

test "select is asked for the interface descriptor with a fifteen second timeout" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);

    try std.testing.expectEqual(intf.fd + 1, ModelDriver.select_nfds);
    try std.testing.expectEqual(@as(c_long, 15), ModelDriver.select_tv_sec);
    try std.testing.expectEqual(@as(c_long, 0), ModelDriver.select_tv_usec);
    try std.testing.expect(ModelDriver.select_had_fd);
}

test "a select timeout gives up" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.select_rc = @splat(0);

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    // The request went out before the wait.
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.sent_count);
}

test "select is retried while it reports EINTR" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.select_rc = .{ -1, -1, 1, 1 };
    ModelDriver.select_errno = .{ c.EINTR, c.EINTR, 0, 0 };
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{ 0x00, 0xc2 } });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);
    try std.testing.expectEqual(@as(usize, 3), ModelDriver.select_calls);
}

test "a select error that is not EINTR gives up" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.select_rc = @splat(-1);
    ModelDriver.select_errno = @splat(c.EIO);

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.select_calls);
}

test "a ready count with the descriptor missing from the set gives up" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.select_clear_fd = true;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    // The receive ioctl was never reached.
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.reply_next);
}

test "a failed send ioctl gives up before waiting" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.send_rc = -1;

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.select_calls);
}

test "noanswer sends the request and does not wait for a reply" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.noanswer = 1;

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.sent_count);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.select_calls);
}

test "sendrecv opens a closed interface first" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    ModelDriver.present = &.{"/dev/ipmi0"};
    stubs.oem = t.oem;
    var intf = testIntf();
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);
    try std.testing.expectEqual(@as(c_int, 1), intf.opened);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.events_calls);
}

test "a failed open aborts the request" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.sent_count);
}

test "the completion code is stripped off the response data" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{
        .netfn = t.netfn | 1,
        .cmd = t.cmd,
        .data = &.{ 0x00, 0x5b, 0x6d, 0xc2, 0x39 },
    });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req).?;

    try std.testing.expectEqual(@as(u8, 0), got.ccode);
    try std.testing.expectEqual(@as(c_int, 4), got.data_len);
    try std.testing.expectEqualSlices(u8, &.{ 0x5b, 0x6d, 0xc2, 0x39 }, got.data[0..4]);
    // The shifted buffer is terminated in place.
    try std.testing.expectEqual(@as(u8, 0), got.data[4]);
}

test "a non-zero completion code leaves the data where it landed" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{ 0x83, 0x5b, 0x6d } });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req).?;

    try std.testing.expectEqual(@as(u8, 0x83), got.ccode);
    try std.testing.expectEqual(@as(c_int, 2), got.data_len);
    // No memmove: byte 0 is still the completion code.
    try std.testing.expectEqualSlices(u8, &.{ 0x83, 0x5b, 0x6d }, got.data[0..3]);
}

test "BUG: an empty response yields a data_len of minus one" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{} });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req).?;

    // Upstream note 6: `recv.msg.data_len - 1` with nothing received.
    try std.testing.expectEqual(@as(c_int, -1), got.data_len);
}

test "BUG: a truncated receive is reported and then used anyway" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{
        .netfn = t.netfn | 1,
        .cmd = t.cmd,
        .data = &.{ 0x00, 0x5b, 0x6d },
        .rc = -1,
        .errno = c.EMSGSIZE,
    });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req);

    // Upstream note 9.
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(c_int, 2), got.?.data_len);
}

test "a receive failure that is not EMSGSIZE gives up" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{
        .netfn = t.netfn | 1,
        .cmd = t.cmd,
        .data = &.{ 0x00, 0x5b },
        .rc = -1,
        .errno = c.EIO,
    });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) == null);
}

test "a request with no payload sends none" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var empty: [0]u8 = .{};
    var req = testRequest(&empty);
    req.msg.data = null;
    try std.testing.expect(sendrecv(&intf, &req) != null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.sent_data_len);
}

test "a bridged request with no payload still carries both checksums" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    intf.transit_addr = t.transit_addr;
    intf.transit_channel = t.transit_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{
        0x00, 0x11, 0xb3, 0x22, 0x33, 0x44, 0x94, 0x00,
    } });

    var empty: [0]u8 = .{};
    var req = testRequest(&empty);
    req.msg.data = null;
    try std.testing.expect(sendrecv(&intf, &req) != null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);
    try std.testing.expectEqual(@as(usize, 8), ModelDriver.sent_data_len);
    try std.testing.expectEqualSlices(u8, &.{
        0xfd, 0x3c, 0xb3, 0x11, 0xff, 0x00, 0x94, 0x6d,
    }, ModelDriver.sent_data[0..8]);
}

/// Redirect file descriptor 2 into a pipe for the duration of a call.
///
/// `zig build test` fails the whole run if a test writes to stderr, and the
/// `verbose` paths write there by design, so the only way to exercise them is
/// to catch what they emit.
const Stderr = struct {
    saved: c_int,
    read_end: c_int,
    write_end: c_int,

    fn begin() Stderr {
        var fds: [2]c_int = .{ -1, -1 };
        std.debug.assert(c.pipe(&fds) == 0);
        const saved = c.dup(2);
        std.debug.assert(saved >= 0);
        std.debug.assert(c.dup2(fds[1], 2) >= 0);
        return .{ .saved = saved, .read_end = fds[0], .write_end = fds[1] };
    }

    fn finish(self: *Stderr, buf: []u8) []u8 {
        _ = c.fflush(c.stderr);
        _ = c.dup2(self.saved, 2);
        _ = c.close(self.saved);
        _ = c.close(self.write_end);
        const n = c.read(self.read_end, buf.ptr, buf.len);
        _ = c.close(self.read_end);
        return if (n > 0) buf[0..@intCast(n)] else buf[0..0];
    }
};

test "verbose above two dumps the request header" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 3;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    const text = capture.finish(&buf);

    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(
        "OpenIPMI Request Message Header:\n  netfn     = 0x2c\n  cmd       = 0x94\n",
        text,
    );
}

test "verbose above four dumps the received message without a first newline" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{
        .netfn = 0x2d,
        .cmd = t.cmd,
        .channel = 0x6b,
        .data = &.{ 0x00, 0x5b },
    });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 5;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    const text = capture.finish(&buf);

    try std.testing.expect(got != null);
    // Upstream note 11: "Got message:" runs straight into the next line.  The
    // message id is whatever `curr_seq` was, which is 0 for the first request.
    try std.testing.expectEqualStrings(
        \\OpenIPMI Request Message Header:
        \\  netfn     = 0x2c
        \\  cmd       = 0x94
        \\Got message:  type      = 1
        \\  channel   = 0x6b
        \\  msgid     = 0
        \\  netfn     = 0x2d
        \\  cmd       = 0x94
        \\  data_len  = 2
        \\  data      = 005b
        \\
    ,
        text,
    );
}

test "the request payload is dumped with its own buffer and length" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 3;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    _ = capture.finish(&buf);

    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 1), crypto_stubs.printbuf_calls);
    try std.testing.expectEqual(@as(c_int, t.data.len), crypto_stubs.printbuf_len);
    try std.testing.expectEqualSlices(u8, &t.data, crypto_stubs.printbuf_data[0..t.data.len]);
    try std.testing.expectEqualStrings(
        "OpenIPMI Request Message Data",
        std.mem.sliceTo(crypto_stubs.printbuf_desc, 0),
    );
}

test "verbose of exactly two prints nothing" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 2;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    const text = capture.finish(&buf);

    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("", text);
    try std.testing.expectEqual(@as(usize, 0), crypto_stubs.printbuf_calls);
}

test "verbose of exactly four dumps neither the conversion nor the reply" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    intf.transit_addr = t.transit_addr;
    intf.transit_channel = t.transit_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{
        0x00, 0x11, 0xb3, 0x22, 0x33, 0x44, 0x94,
        0x00, 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88,
        0x99,
    } });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 4;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    const text = capture.finish(&buf);

    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(
        \\OpenIPMI Request Message Header:
        \\  netfn     = 0x2c
        \\  cmd       = 0x94
        \\
    ,
        text,
    );
}

test "verbose above four dumps every stage of a bridged exchange" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    intf.transit_addr = t.transit_addr;
    intf.transit_channel = t.transit_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{
        0x00, 0x11, 0xb3, 0x22, 0x33, 0x44, 0x94,
        0x00, 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88,
        0x99,
    } });

    var data = t.data;
    var req = testRequest(&data);

    var buf: [4096]u8 = undefined;
    var capture = Stderr.begin();
    c.verbose = 5;
    const got = sendrecv(&intf, &req);
    c.verbose = 0;
    const text = capture.finish(&buf);

    try std.testing.expect(got != null);
    // The decapsulated netfn comes from byte 2 of the reply (0xb3 >> 2 = 0x2c)
    // and the decapsulated command from byte 6, and neither is used for
    // anything else -- this dump is the only place they are observable.
    try std.testing.expectEqualStrings(
        \\OpenIPMI Request Message Header:
        \\  netfn     = 0x2c
        \\  cmd       = 0x94
        \\Converting message:
        \\  netfn     = 0x2c
        \\  cmd       = 0x94
        \\  data_len  = 4
        \\  data      = 174e92db
        \\Encapsulated message:
        \\  netfn     = 0x6
        \\  cmd       = 0x34
        \\  data_len  = 12
        \\  data      = fd3cb311ff0094174e92db9b
        \\Got message:  type      = 1
        \\  channel   = 0x0
        \\  msgid     = 0
        \\  netfn     = 0x2d
        \\  cmd       = 0x94
        \\  data_len  = 15
        \\  data      = 0011b322334494005b6dc239778899
        \\Decapsulated  message:
        \\  netfn     = 0x2c
        \\  cmd       = 0x94
        \\  data_len  = 7
        \\  data      = 005b6dc2397788
        \\
    ,
        text,
    );
}

test "a second request does not reopen the device" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.events_calls);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.attempt_count);

    var data = t.data;
    var req = testRequest(&data);
    for (0..2) |_| {
        ModelDriver.reply_count = 0;
        ModelDriver.reply_next = 0;
        ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{0x00} });
        try std.testing.expect(sendrecv(&intf, &req) != null);
    }

    // `opened` is already 1, so `intf->open` must not be called again.
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.events_calls);
    try std.testing.expectEqual(@as(usize, 1), ModelDriver.attempt_count);
    try std.testing.expectEqual(@as(usize, 1), stubs.oem_calls);
}

test "a transit address equal to my own is not a bridge" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    intf.target_addr = t.target_addr;
    intf.target_channel = t.target_channel;
    intf.transit_addr = t.my_addr;
    intf.transit_channel = t.transit_channel;
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{
        0x00, 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88, 0x99,
    } });

    var data = t.data;
    var req = testRequest(&data);
    const got = sendrecv(&intf, &req);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);

    // No Send Message wrapper: the target's own address and channel, the
    // caller's netfn and command, and the payload as supplied.
    const addr = std.mem.bytesToValue(IpmbAddr, ModelDriver.sent_addr[0..8]);
    try std.testing.expectEqual(@as(c_short, t.target_channel & 0x0f), addr.channel);
    try std.testing.expectEqual(@as(u8, t.target_addr), addr.slave_addr);
    try std.testing.expectEqual(@as(u8, t.netfn), ModelDriver.sent_netfn);
    try std.testing.expectEqual(@as(u8, t.cmd), ModelDriver.sent_cmd);
    try std.testing.expectEqualSlices(
        u8,
        &t.data,
        ModelDriver.sent_data[0..ModelDriver.sent_data_len],
    );

    // And no decapsulation on the way back: the completion code is stripped
    // and nothing else is.
    try std.testing.expectEqual(@as(c_int, 7), got.?.data_len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88, 0x99 },
        got.?.data[0..7],
    );
}

test "the receive is offered a whole address and a whole message of room" {
    ModelDriver.reset();
    defer ModelDriver.reset();
    var intf = testIntf();
    try openModel(&intf);
    ModelDriver.push(.{ .netfn = t.netfn | 1, .cmd = t.cmd, .data = &.{ 0x00, 0x5b } });

    var data = t.data;
    var req = testRequest(&data);
    try std.testing.expect(sendrecv(&intf, &req) != null);

    try std.testing.expectEqual(@as(usize, 0), ModelDriver.complaint_count);
    try std.testing.expectEqual(@as(c_uint, @sizeOf(Addr)), ModelDriver.recv_addr_len);
    try std.testing.expectEqual(@as(c_ushort, rsp.data.len), ModelDriver.recv_capacity);
}
